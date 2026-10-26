"""Read an encrypted file from Amazon S3 and decrypt it inside the sandbox.

The object in S3 is AES-256-GCM ciphertext. Its data key is not: that travels beside it,
in a small manifest, wrapped by an AWS KMS key whose policy releases it only to a sandbox
whose attestation matches. So this program:

  1. prints what it can read about the machine it is running on, which is how the page
     shows it ran in a sandbox and not on the node (exec is denied by the Cedar policy, so
     the pod has to report on itself);
  2. reads the manifest and the ciphertext from S3, which the bucket policy permits;
  3. asks KMS to decrypt the wrapped data key, presenting an attestation document, and
     requires the answer to come back encrypted to that document's public key;
  4. decrypts the file with AES-256-GCM in memory, checks it against the length and
     SHA-256 the Cedar policy pins in this container's environment, and prints the marker.

Nothing here prints the file. The only things it says about the plaintext are its length
and its digest, which is what makes "the approved sandbox got the file" checkable without
publishing it. Run it with --readings-only to do step 1 and stop, which is what the
ordinary pod on the same node does for comparison.

The file is read into memory in one piece. A file too large for that needs an
authenticated streaming or chunked format, and this sample does not implement one.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import traceback
from collections.abc import Callable

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from attested_recipient import AttestedRecipient

# Nothing identifying reaches the logs. An AWS error names the full role session, and an
# EKS Pod Identity session name is built from the cluster and the pod names, so an
# unredacted KMS denial would carry the account and the cluster into this pod's output.
#
# The account id is matched only where an account id actually appears: between the colons of
# an ARN, or before ".dkr.ecr." in a registry reference. An unanchored twelve-digit pattern
# also matches twelve consecutive digits inside a SHA-256, and this program prints digests:
# it rewrote part of one into <ACCOUNT_ID> and so reported a file as validated against a
# digest that was never computed. Anchoring is what keeps a digest intact.
_ACCOUNT_ID = re.compile(r"(?<=:)\d{12}(?=:)")
_REGISTRY_ACCOUNT = re.compile(r"\d{12}(?=\.dkr\.ecr\.)")
_ROLE_SESSION = re.compile(r"(assumed-role/[^/]+/)[^\s\"']+")

# The failures this program expects: a refusal from AWS, a response or a manifest that does
# not match what it pinned, a missing environment value, the attested recipient's own
# errors. Anything outside this set is this program being wrong rather than being refused,
# which is the only thing the traceback below is for.
EXPECTED_FAILURES = (ClientError, BotoCoreError, KeyError, ValueError, RuntimeError)


def redact(text: str) -> str:
    """Replace the account ID and the role session name in text with placeholders."""
    text = _ACCOUNT_ID.sub("<ACCOUNT_ID>", text)
    text = _REGISTRY_ACCOUNT.sub("<ACCOUNT_ID>", text)
    return _ROLE_SESSION.sub(r"\1<session>", text)


class _RedactingArgumentParser(argparse.ArgumentParser):
    """An argument parser whose error path is redacted like every other output.

    argparse writes the offending value back out verbatim, so without this a command line
    carrying an account id or a role session name would put it on standard error before any
    of the code below ran. The pod's arguments are pinned by its Cedar policy, so an
    operator cannot change them without losing the data key, but the guarantee this program
    makes about its output should not rest on that.
    """

    def error(self, message: str) -> None:  # type: ignore[override]
        self.exit(2, redact(f"{self.prog}: error: {message}\n"))


def print_readings() -> None:
    """What this container can see of the machine it is running on.

    In a sandbox these read the guest: its own kernel build, a boot that happened when the
    pod started, and virtio disks. In an ordinary pod on the same node they read the node.
    """
    uname = os.uname()
    print(f"kernel:  {uname.release} {uname.version}")
    with open("/proc/uptime", encoding="utf-8") as uptime_file:
        print(f"uptime:  {uptime_file.read().split()[0]}s")
    print(f"disks:   {' '.join(sorted(os.listdir('/sys/block')))}")
    try:
        with open("/sys/class/dmi/id/product_name", encoding="utf-8") as product_file:
            product = product_file.read().strip()
    except OSError as error:
        product = f"unavailable ({error.strerror})"
    print(f"product: {product}")


def _get_object(s3_client, bucket: str, key: str) -> bytes:
    response = s3_client.get_object(Bucket=bucket, Key=key)
    with response["Body"] as body:
        return body.read()


def decrypt_file(
    s3_client,
    kms_client,
    bucket: str,
    manifest_key: str,
    expected_key_arn: str,
    expected_sha256: str,
    expected_length: int,
    recipient_factory: Callable[[], AttestedRecipient] = AttestedRecipient,
) -> str:
    """Read the object, release its data key through attestation, and validate the file."""
    manifest = json.loads(_get_object(s3_client, bucket, manifest_key))
    if (
        manifest.get("version") != 1
        or manifest.get("algorithm") != "AES-256-GCM"
        or manifest.get("key_arn") != expected_key_arn
    ):
        raise ValueError("the S3 manifest does not match the pinned envelope format")

    ciphertext_key = manifest.get("ciphertext_key")
    if not isinstance(ciphertext_key, str) or not ciphertext_key:
        raise ValueError("the S3 manifest names no ciphertext object")
    wrapped_data_key = base64.b64decode(manifest["encrypted_data_key"], validate=True)
    nonce = base64.b64decode(manifest["nonce"], validate=True)
    if len(nonce) != 12:
        raise ValueError("the S3 manifest's nonce is not 12 bytes")
    # The additional authenticated data is derived here, not read from the manifest, so
    # the ciphertext is bound to the place it was uploaded to: the same bytes copied to
    # another key, or to another bucket, no longer decrypt.
    additional_data = f"s3://{bucket}/{ciphertext_key}".encode("utf-8")
    print(
        f"manifest: version={manifest['version']} algorithm={manifest['algorithm']} "
        f"wrapped_data_key={len(wrapped_data_key)}B nonce={len(nonce)}B"
    )

    ciphertext = _get_object(s3_client, bucket, ciphertext_key)
    print(
        f"s3:      read {len(ciphertext)} bytes of ciphertext "
        f"sha256={hashlib.sha256(ciphertext).hexdigest()}"
    )

    with recipient_factory() as recipient:
        decrypted = kms_client.decrypt(
            KeyId=expected_key_arn,
            CiphertextBlob=wrapped_data_key,
            Recipient=recipient.kms_recipient,
        )
        # KMS returns the data key encrypted to the attestation document's public key, in
        # CiphertextForRecipient, and no Plaintext at all. Anything else is not the
        # attested answer this program asked for, so it is refused rather than used.
        if decrypted.get("Plaintext") is not None:
            raise ValueError("attested KMS Decrypt unexpectedly returned plaintext")
        if decrypted.get("KeyId") != expected_key_arn:
            raise ValueError("KMS decrypted with a key other than the pinned key")
        protected = decrypted.get("CiphertextForRecipient")
        if not isinstance(protected, bytes) or not protected:
            raise ValueError("KMS did not return CiphertextForRecipient")
        print(f"kms:     CiphertextForRecipient {len(protected)}B, no plaintext field")
        data_key = recipient.unwrap(protected)
    if len(data_key) != 32:
        raise ValueError("the released data key is not 32 bytes")

    plaintext = AESGCM(data_key).decrypt(nonce, ciphertext, additional_data)
    digest = hashlib.sha256(plaintext).hexdigest()
    if len(plaintext) != expected_length or digest != expected_sha256:
        raise ValueError("the decrypted file does not match the pinned length and digest")
    return f"attested-s3-ok bytes={len(plaintext)} sha256={digest}"


def main() -> int:
    parser = _RedactingArgumentParser(description=__doc__)
    parser.add_argument(
        "--readings-only",
        action="store_true",
        help="print the machine readings and stop, for the ordinary pod's comparison",
    )
    args = parser.parse_args()

    print(f"variant: {os.environ.get('SAMPLE_VARIANT', 'unset')}")
    print_readings()
    if args.readings_only:
        print("s3-encrypted-file-readings-done")
        return 0

    config = Config(
        retries={"total_max_attempts": 4, "mode": "adaptive"},
        connect_timeout=5,
        read_timeout=30,
    )
    session = boto3.Session(region_name=os.environ["AWS_REGION"])

    try:
        result = decrypt_file(
            session.client("s3", config=config),
            session.client("kms", config=config),
            os.environ["S3_BUCKET"],
            os.environ["S3_MANIFEST_KEY"],
            os.environ["KMS_KEY_ARN"],
            os.environ["EXPECTED_SHA256"],
            int(os.environ["EXPECTED_LENGTH"]),
        )
    except Exception as error:  # noqa: BLE001
        # Every failure leaves by this one path, and everything the path emits is passed
        # through redact() before it is printed. A clause that listed its exception types
        # was the defect this replaces: a type it did not list left main() as an unhandled
        # traceback, which never reached redact(), so a KMS denial's role session name and
        # the account id went into the pod's log intact. The catch is broad so that the
        # redaction is a guarantee rather than a list that has to be kept in step with
        # every library in the call path.
        #
        # Nothing is hidden by it. The exit status is still non-zero, the report still goes
        # to standard error, and the exception's type is named, because a redacted message
        # on its own cannot be told apart from a bug in this program: ClientError is the
        # refusal the sample is about, anything else is this code being wrong.
        # Building the report is itself done inside a try. Formatting {error} calls the
        # exception's own __str__, which is arbitrary code; so is traceback formatting, and
        # redact() has to allocate. If any of them raises, the new exception would leave this
        # handler before anything had been redacted, and Python would print its traceback,
        # which is the very escape this clause exists to close.
        try:
            report = f"attested-s3-error: {type(error).__name__}: {error}"
            # The frames, for an unexpected type only. For the refusals this sample shows,
            # the one line is the whole story and a stack through botocore would bury it;
            # for anything else the frames are the only way a reader finds where it broke.
            if not isinstance(error, EXPECTED_FAILURES):
                report += "\n" + "".join(
                    traceback.format_exception(type(error), error, error.__traceback__)
                )
            report = redact(report)
        except Exception:  # noqa: BLE001
            # The type's name is a plain attribute of a class. Reading it runs none of the
            # failed exception's own code and allocates almost nothing, so it is the one
            # thing that can always be said here. Everything else is dropped rather than
            # risked: a report that cannot be redacted is not printed.
            report = f"attested-s3-error: {type(error).__name__}: report unavailable"
        print(report, file=sys.stderr)
        return 1

    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
