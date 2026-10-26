"""Ask AWS KMS to decrypt, and prove to it that the caller is this sandbox.

The Confidential samples whose workload calls KMS itself share this helper. It does the
exchange the Confidential section page describes under "The attested decrypt": generate an
ephemeral RSA key inside the guest, get the Nitro Secure Module to sign an attestation
document carrying that key's public half, pass the document to `kms:Decrypt` as the
`Recipient`, and unwrap what comes back in `CiphertextForRecipient` with the private half,
which never leaves this process.

    with AttestedRecipient() as recipient:
        response  = kms.decrypt(KeyId=..., CiphertextBlob=..., Recipient=recipient.kms_recipient)
        plaintext = recipient.unwrap(response["CiphertextForRecipient"])

Sources. `Recipient`, `CiphertextForRecipient` and the `RSAES_OAEP_SHA_256` key encryption
algorithm are in the AWS KMS API Reference, Decrypt
(https://docs.aws.amazon.com/kms/latest/APIReference/API_Decrypt.html). That KMS returns a
CMS EnvelopedData structure to an attested recipient, rather than plaintext, is in
cryptographic attestation support in AWS KMS
(https://docs.aws.amazon.com/enclaves/latest/user/kms.html). The Amazon EKS User Guide,
*Security model and parent instance trust assumptions*, names the Nitro Secure Module and
its attestation document; it does not document how code inside the guest reaches the
module, so the device and the request encoding below come from the open-source Nitro
Enclaves NSM API (https://github.com/aws/aws-nitro-enclaves-nsm-api), and the samples that
use this helper show a run in which they work.
"""

from __future__ import annotations

import ctypes
import fcntl
from types import TracebackType

import cbor2
from asn1crypto import algos, cms
from cryptography.hazmat.primitives import hashes, padding, serialization
from cryptography.hazmat.primitives.asymmetric import padding as asymmetric_padding
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# The Nitro Secure Module's character device, inside the guest.
_NSM_DEVICE = "/dev/nsm"
# The driver's own request and response ceilings, from the NSM API above. A request over
# the first is rejected; a response buffer smaller than the second can truncate a document.
_NSM_REQUEST_MAX_SIZE = 0x1000
_NSM_RESPONSE_MAX_SIZE = 0x3000
# _IOWR(0x0A, 0, struct nsm_message), where struct nsm_message is two iovecs, so 32 bytes
# on a 64-bit kernel: direction 3 << 30 | 32 << 16 | 0x0A << 8 | 0 == 0xC0200A00.
_NSM_IOCTL = 0xC0200A00

# The public key is 4096-bit RSA. KMS accepts 2048, 3072 or 4096 for an attested recipient
# (AWS KMS API Reference, Decrypt); the largest is used because key release is the whole
# point of these samples and generating it costs a sandbox under a second.
_RSA_KEY_SIZE = 4096


class _IoVec(ctypes.Structure):
    _fields_ = [
        ("iov_base", ctypes.c_void_p),
        ("iov_len", ctypes.c_size_t),
    ]


class _NsmMessage(ctypes.Structure):
    _fields_ = [
        ("request", _IoVec),
        ("response", _IoVec),
    ]


def _request_attestation(public_key: bytes) -> bytes:
    """Return a signed attestation document carrying public_key, from /dev/nsm."""
    request = cbor2.dumps(
        {
            "Attestation": {
                "user_data": None,
                "nonce": None,
                "public_key": public_key,
            }
        }
    )
    if len(request) > _NSM_REQUEST_MAX_SIZE:
        raise ValueError("NSM attestation request is too large")

    request_buffer = ctypes.create_string_buffer(request, len(request))
    response_buffer = (ctypes.c_uint8 * _NSM_RESPONSE_MAX_SIZE)()
    message = _NsmMessage(
        request=_IoVec(
            ctypes.cast(request_buffer, ctypes.c_void_p),
            len(request),
        ),
        response=_IoVec(
            ctypes.cast(response_buffer, ctypes.c_void_p),
            _NSM_RESPONSE_MAX_SIZE,
        ),
    )

    with open(_NSM_DEVICE, "r+b", buffering=0) as device:
        fcntl.ioctl(device, _NSM_IOCTL, message)

    if message.response.iov_len > _NSM_RESPONSE_MAX_SIZE:
        raise RuntimeError("NSM returned an oversized response")
    response = bytes(response_buffer[: message.response.iov_len])
    decoded = cbor2.loads(response)
    if not isinstance(decoded, dict) or "Attestation" not in decoded:
        error = decoded.get("Error", "malformed response") if isinstance(decoded, dict) else decoded
        raise RuntimeError(f"NSM attestation failed: {error}")
    document = decoded["Attestation"].get("document")
    if not isinstance(document, bytes) or not document:
        raise RuntimeError("NSM returned an empty attestation document")
    return document


def _validate_oaep(parameters: algos.RSAESOAEPParams) -> None:
    """Refuse an envelope whose RSA-OAEP parameters are not the ones KMS documents."""
    native = parameters.native
    if native["hash_algorithm"]["algorithm"] != "sha256":
        raise ValueError("KMS CMS envelope does not use SHA-256 for RSA-OAEP")
    mask = native["mask_gen_algorithm"]
    if mask["algorithm"] != "mgf1" or mask["parameters"]["algorithm"] != "sha256":
        raise ValueError("KMS CMS envelope does not use MGF1-SHA256")
    source = native["p_source_algorithm"]
    if source["algorithm"] != "p_specified" or source["parameters"] != b"":
        raise ValueError("KMS CMS envelope uses an unexpected OAEP label")


def _unwrap_cms(private_key: rsa.RSAPrivateKey, ciphertext: bytes) -> bytes:
    """Open the CMS EnvelopedData KMS returns in CiphertextForRecipient.

    Every field is checked against what KMS documents rather than taken on trust: the
    structure arrives over the network, and a caller that unwrapped whatever it was handed
    would be relying on the transport instead of on the key it holds.
    """
    content_info = cms.ContentInfo.load(ciphertext)
    if content_info["content_type"].native != "enveloped_data":
        raise ValueError("KMS response is not CMS EnvelopedData")

    enveloped = content_info["content"]
    recipients = enveloped["recipient_infos"]
    if len(recipients) != 1 or recipients[0].name != "ktri":
        raise ValueError("KMS CMS envelope must contain one key transport recipient")
    key_transport = recipients[0].chosen
    key_algorithm = key_transport["key_encryption_algorithm"]
    if key_algorithm["algorithm"].native != "rsaes_oaep":
        raise ValueError("KMS CMS envelope does not use RSAES-OAEP")
    _validate_oaep(key_algorithm["parameters"])

    content = enveloped["encrypted_content_info"]
    content_algorithm = content["content_encryption_algorithm"]
    if content_algorithm["algorithm"].native != "aes256_cbc":
        raise ValueError("KMS CMS envelope does not use AES-256-CBC")
    iv = content_algorithm["parameters"].native
    encrypted_content = content["encrypted_content"].native
    if not isinstance(iv, bytes) or len(iv) != 16:
        raise ValueError("KMS CMS envelope has an invalid AES-CBC IV")
    if not isinstance(encrypted_content, bytes) or not encrypted_content:
        raise ValueError("KMS CMS envelope has no encrypted content")

    content_key = private_key.decrypt(
        key_transport["encrypted_key"].native,
        asymmetric_padding.OAEP(
            mgf=asymmetric_padding.MGF1(algorithm=hashes.SHA256()),
            algorithm=hashes.SHA256(),
            label=None,
        ),
    )
    if len(content_key) != 32:
        raise ValueError("KMS CMS envelope did not contain an AES-256 key")

    decryptor = Cipher(algorithms.AES(content_key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(encrypted_content) + decryptor.finalize()
    unpadder = padding.PKCS7(algorithms.AES.block_size).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


class AttestedRecipient:
    """One ephemeral NSM-attested KMS recipient, for the life of a `with` block.

    The key pair is generated on entry and dropped on exit, so a document cannot be
    replayed with a key the process no longer holds, and the private half exists only for
    as long as the decrypt it is for.
    """

    def __init__(self) -> None:
        self._private_key: rsa.RSAPrivateKey | None = None
        self._document: bytes | None = None

    def __enter__(self) -> AttestedRecipient:
        self._private_key = rsa.generate_private_key(
            public_exponent=65537, key_size=_RSA_KEY_SIZE
        )
        public_key = self._private_key.public_key().public_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        self._document = _request_attestation(public_key)
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self._document = None
        self._private_key = None

    @property
    def kms_recipient(self) -> dict[str, object]:
        """The `Recipient` argument for `kms:Decrypt`."""
        if self._document is None:
            raise RuntimeError("AttestedRecipient must be used as a context manager")
        return {
            "KeyEncryptionAlgorithm": "RSAES_OAEP_SHA_256",
            "AttestationDocument": self._document,
        }

    def unwrap(self, ciphertext_for_recipient: bytes) -> bytes:
        """Return the plaintext KMS encrypted to this recipient's public key."""
        if self._private_key is None:
            raise RuntimeError("AttestedRecipient must be used as a context manager")
        return _unwrap_cms(self._private_key, ciphertext_for_recipient)
