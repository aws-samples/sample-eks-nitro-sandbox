"""Read a ciphertext envelope from AWS Secrets Manager and decrypt it inside the sandbox.

The workload of the secrets-manager-secret sample. It runs once and exits:

  1. print the four machine readings, so the page can show where this ran;
  2. read the secret, which holds a KMS ciphertext envelope and not the secret itself;
  3. ask KMS to decrypt it, presenting an attestation document from the Nitro Secure
     Module as the `Recipient`, and unwrap the response with a key that never leaves this
     process;
  4. check the plaintext against the length and SHA-256 the pod spec pins, and print the
     marker.

The plaintext is never printed, logged or written anywhere: what step 4 prints is its byte
count and its digest. The Amazon EKS User Guide, *Security model and parent instance trust
assumptions*, is explicit that a confidential workload's own stdout reaches the parent
instance when the policy permits reading logs, and this policy does permit it, because the
marker and the readings above are how the sample is read at all.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sys
from collections.abc import Callable

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from attested_recipient import AttestedRecipient
from readings import print_machine_readings

# Anything printed goes through this first. An AWS authorization error names the full role
# session, and an EKS Pod Identity session name is built from the cluster name and the pod
# name, so an unredacted error would put this account and this cluster into the logs and
# onto the page.
_ACCOUNT_ID = re.compile(r"\d{12}")
_ROLE_SESSION = re.compile(r"(assumed-role/[^/]+/)[^\s\"']+")


def redact(text: str) -> str:
    """Replace the account ID and the role session name in text with placeholders."""
    return _ROLE_SESSION.sub(r"\1<session>", _ACCOUNT_ID.sub("<ACCOUNT_ID>", text))


def read_envelope(secrets_client, secret_id: str, key_arn: str) -> bytes:
    """Return the ciphertext held in the secret, after checking the envelope.

    The stored value is a small JSON document, not the secret. It records which KMS key the
    ciphertext belongs to, and this function refuses an envelope naming a different key: a
    ciphertext from some other key would fail to decrypt under the pinned one, and the
    denial would read exactly like the attestation being refused.
    """
    response = secrets_client.get_secret_value(SecretId=secret_id)
    envelope = json.loads(response["SecretString"])
    if envelope.get("version") != 1:
        raise ValueError("secret does not hold a version 1 ciphertext envelope")
    if envelope.get("key_arn") != key_arn:
        raise ValueError("secret ciphertext envelope does not match the pinned KMS key")
    return base64.b64decode(envelope["ciphertext"], validate=True)


def decrypt_secret(
    secrets_client,
    kms_client,
    secret_id: str,
    key_arn: str,
    expected_sha256: str,
    expected_length: int,
    recipient_factory: Callable[[], AttestedRecipient] = AttestedRecipient,
) -> str:
    """Decrypt the secret under attestation and return the validation marker.

    Everything about the KMS response is checked before it is trusted. A response carrying
    `Plaintext` would mean KMS had not treated this as an attested call, so the attestation
    would have decided nothing; a response naming another key would mean the ciphertext was
    not the one the key policy gates.
    """
    ciphertext = read_envelope(secrets_client, secret_id, key_arn)

    with recipient_factory() as recipient:
        decrypted = kms_client.decrypt(
            KeyId=key_arn,
            CiphertextBlob=ciphertext,
            Recipient=recipient.kms_recipient,
        )
        if decrypted.get("Plaintext") is not None:
            raise ValueError("attested KMS Decrypt unexpectedly returned plaintext")
        if decrypted.get("KeyId") != key_arn:
            raise ValueError("KMS decrypted with a key other than the pinned key")
        protected = decrypted.get("CiphertextForRecipient")
        if not isinstance(protected, bytes):
            raise ValueError("KMS did not return CiphertextForRecipient")
        plaintext = recipient.unwrap(protected)

    digest = hashlib.sha256(plaintext).hexdigest()
    if len(plaintext) != expected_length or digest != expected_sha256:
        raise ValueError("the decrypted value is not the one this pod spec pins")
    return f"attested-secret-ok bytes={len(plaintext)} sha256={digest}"


def main() -> int:
    region = os.environ["AWS_REGION"]

    print_machine_readings()
    print("secrets-manager-secret-ready", flush=True)

    config = Config(
        retries={"total_max_attempts": 4, "mode": "adaptive"},
        connect_timeout=5,
        read_timeout=20,
    )
    session = boto3.Session(region_name=region)

    try:
        marker = decrypt_secret(
            session.client("secretsmanager", config=config),
            session.client("kms", config=config),
            os.environ["SECRET_ID"],
            os.environ["KMS_KEY_ARN"],
            os.environ["EXPECTED_SHA256"],
            int(os.environ["EXPECTED_LENGTH"]),
        )
    except (ClientError, KeyError, ValueError, RuntimeError, OSError) as error:
        print(f"attested-secret-error: {redact(str(error))}", file=sys.stderr, flush=True)
        return 1

    print(marker, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
