"""Encrypt the file on the setup machine, and write the manifest that travels with it.

This is the operator side of the sample, and the only place the plaintext and the data key
are both present. It runs on the setup machine, outside the cluster, before anything is
uploaded: scripts/setup.sh runs it in the application image so that the setup machine
needs no Python packages of its own.

AES-256-GCM encrypts the file under a random 32-byte data key. Only that key is handed to
AWS KMS, in a separate kms:Encrypt call scripts/setup.sh makes, and only the wrapped form
reaches S3. Wrapping the key rather than the file is what lets the file be larger than
KMS's own direct-encryption input
(https://docs.aws.amazon.com/kms/latest/APIReference/API_Encrypt.html).

The additional authenticated data is "s3://<bucket>/<ciphertext key>". It is covered by
the GCM tag without being secret, so the ciphertext only decrypts in the place it was
uploaded to; the application derives the same string from its own pinned environment
rather than reading it out of the manifest.

The data key and the plaintext arrive as file paths, never on the command line, which is
readable by any local user.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plaintext", required=True, help="the file to encrypt")
    parser.add_argument("--data-key", required=True, help="file holding 32 random bytes")
    parser.add_argument("--ciphertext", required=True, help="write the ciphertext here")
    parser.add_argument("--manifest", required=True, help="write the manifest here")
    parser.add_argument("--bucket", required=True, help="the bucket, for the AAD")
    parser.add_argument("--ciphertext-key", required=True, help="the object key")
    parser.add_argument("--key-arn", required=True, help="the KMS key the data key is wrapped with")
    parser.add_argument(
        "--encrypted-data-key-file",
        required=True,
        help="file holding the base64 wrapped data key from kms:Encrypt",
    )
    args = parser.parse_args()

    # Imported here so --help works on a machine without the package installed.
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    with open(args.plaintext, "rb") as source:
        plaintext = source.read()
    with open(args.data_key, "rb") as source:
        data_key = source.read()
    if len(data_key) != 32:
        raise ValueError("the data key must hold exactly 32 bytes")
    with open(args.encrypted_data_key_file, encoding="utf-8") as source:
        encrypted_data_key = source.read().strip()
    if not encrypted_data_key:
        raise ValueError("the wrapped data key file is empty")
    # It must be the wrapped form, not the data key itself written to the wrong file: a
    # manifest carrying the plaintext data key would publish the key beside the ciphertext.
    if base64.b64decode(encrypted_data_key, validate=True) == data_key:
        raise ValueError("the wrapped data key file holds the data key itself, unwrapped")

    nonce = os.urandom(12)
    additional_data = f"s3://{args.bucket}/{args.ciphertext_key}".encode("utf-8")
    ciphertext = AESGCM(data_key).encrypt(nonce, plaintext, additional_data)
    with open(args.ciphertext, "wb") as output:
        output.write(ciphertext)

    manifest = {
        "version": 1,
        "algorithm": "AES-256-GCM",
        "key_arn": args.key_arn,
        "encrypted_data_key": encrypted_data_key,
        "nonce": base64.b64encode(nonce).decode("ascii"),
        "ciphertext_key": args.ciphertext_key,
    }
    with open(args.manifest, "w", encoding="utf-8") as output:
        json.dump(manifest, output, indent=2, sort_keys=True)
        output.write("\n")

    # The setup script reads these back: the two it pins in the pod's environment, and the
    # ciphertext's own digest, which it compares with the plaintext's.
    print(
        json.dumps(
            {
                "plaintext_length": len(plaintext),
                "plaintext_sha256": hashlib.sha256(plaintext).hexdigest(),
                "ciphertext_length": len(ciphertext),
                "ciphertext_sha256": hashlib.sha256(ciphertext).hexdigest(),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
