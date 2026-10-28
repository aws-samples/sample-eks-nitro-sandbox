"""The same role and the same ciphertext, with no attestation document.

The control for the secrets-manager-secret sample, and the reason the sample can say that
the attestation is the boundary rather than the credentials. It runs in an **ordinary** pod
using the sample's service account, so EKS Pod Identity hands it the same IAM role the
sandboxed pod gets, and it stands for anyone holding those credentials without being the
attested sandbox. In confidential mode that includes the node: the parent instance can
read Pod Identity credentials as they are delivered, or mint them itself (Amazon EKS User
Guide, *Security model and parent instance trust assumptions*).

It takes the same path as the workload up to the attestation, importing the very same
envelope reader, and then calls `kms:Decrypt` with no `Recipient`:

  1. report which role it is running as;
  2. read the secret and report the stored envelope, which it is allowed to do: the
     Secrets Manager resource policy grants this role that read;
  3. ask KMS to decrypt the ciphertext with no attestation document, and report the answer.

It prints one of four results, and exits 0 only on the first:

  refused                        an authorization denial, which is what the sample claims
  decrypted without attestation  the key policy failed
  read refused                   the role could not reach the ciphertext either
  no decision                    it never got an answer from AWS, which shows nothing

Nothing it reads is printed in the clear. The envelope is reported by size and digest, and
if KMS ever did return plaintext the result line alone would say so: the plaintext is
dropped unread rather than printed, so a key-policy failure could not put the secret into
the logs of a pod that is not even a sandbox.
"""

from __future__ import annotations

import hashlib
import os
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

from app import read_envelope, redact

# Authorization denials are the answer this pod is after. Anything else, including a
# connection that never reached AWS, is no answer about the key policy at all, so it is
# retried: a pod's datapath can take a few seconds to settle after it starts.
# Four, not more: each attempt spends its own connect and read timeouts before it gives up,
# so a larger budget here would keep a pod whose datapath never came up alive past the point
# at which setup.sh would rather replace it.
_ATTEMPTS = 4
_RETRY_SLEEP_SECONDS = 5
_DENIAL_WORDS = ("accessdenied", "not authorized", "explicit deny")


def _is_denial(error: Exception) -> bool:
    message = str(error).lower()
    return any(word in message for word in _DENIAL_WORDS)


def main() -> int:
    region = os.environ["AWS_REGION"]
    secret_id = os.environ["SECRET_ID"]
    key_arn = os.environ["KMS_KEY_ARN"]

    config = Config(
        retries={"total_max_attempts": 2, "mode": "standard"},
        connect_timeout=5,
        read_timeout=15,
    )
    session = boto3.Session(region_name=region)
    sts = session.client("sts", config=config)
    secrets = session.client("secretsmanager", config=config)
    kms = session.client("kms", config=config)

    # Four outcomes, and only the first is the one the sample claims. "decrypted" means the
    # key policy failed. "read refused" means the role could not even reach the ciphertext,
    # so the sample's other claim is the one that broke. "no decision" means this run shows
    # nothing either way, which is a failure too, not a pass.
    outcome = "no decision"
    role_line = "role:    unavailable (no answer from STS)"
    # Named for what it carries: a line about the ciphertext ENVELOPE, never about the
    # secret. Nothing assigned to it below holds the secret value, and the secret value is
    # never in this process to begin with -- this pod is refused the decrypt.
    envelope_line = "secret:  not read"
    detail = "no answer from AWS"

    # The whole sequence is retried, not just the decrypt. A pod's datapath can take a few
    # seconds to settle after it starts, and until it has, every one of these three calls
    # fails the same way: with a connection that never reached AWS, which is not an answer
    # about anything. Only a decision ends the loop.
    for attempt in range(1, _ATTEMPTS + 1):
        try:
            role_line = f"role:    {redact(sts.get_caller_identity()['Arn'])}"
        except (ClientError, BotoCoreError) as error:
            # Which role this is only labels the output, so a failure here is recorded and
            # not retried on its own account: if the datapath is the problem, the read below
            # fails too and that is what drives the retry.
            role_line = f"role:    unavailable ({redact(str(error))})"

        try:
            ciphertext = read_envelope(secrets, secret_id, key_arn)
        except (ClientError, BotoCoreError) as error:
            if _is_denial(error):
                envelope_line = f"secret:  refused ({redact(str(error))})"
                outcome = "read refused"
                break
            print(f"retry:   attempt {attempt} could not reach Secrets Manager, retrying", flush=True)
            time.sleep(_RETRY_SLEEP_SECONDS)
            continue
        except (ValueError, KeyError) as error:
            envelope_line = f"secret:  unusable ({redact(str(error))})"
            outcome = "envelope not this sample's"
            break
        # A byte count and a digest of the CIPHERTEXT, computed into their own locals so
        # that what reaches the line is plainly an int and a hex string and not the bytes
        # themselves. The ciphertext is what Secrets Manager stores; it is not the secret,
        # and the page prints both so the reader can compare them with the sandbox's.
        ciphertext_bytes = len(ciphertext)
        ciphertext_digest = hashlib.sha256(ciphertext).hexdigest()
        envelope_line = (
            f"secret:  read {ciphertext_bytes} bytes of ciphertext, "
            f"sha256 {ciphertext_digest}"
        )

        try:
            response = kms.decrypt(KeyId=key_arn, CiphertextBlob=ciphertext)
        except (ClientError, BotoCoreError) as error:
            detail = redact(str(error))
            if _is_denial(error):
                outcome = "refused"
                break
            print(f"retry:   attempt {attempt} reached no decision from KMS, retrying", flush=True)
            time.sleep(_RETRY_SLEEP_SECONDS)
            continue
        # A success would mean the key policy had failed. Drop what came back without
        # looking at it, so the secret cannot reach the logs of a pod that is not a
        # sandbox, and report the outcome rather than the content.
        del response
        outcome = "decrypted without attestation"
        detail = "KMS returned a plaintext response; it was discarded unread"
        break

    print(role_line, flush=True)
    print(envelope_line, flush=True)
    print("request: kms:Decrypt on that ciphertext, with no attestation document", flush=True)
    print(f"result:  {outcome}", flush=True)
    print(f"detail:  {detail}", flush=True)
    print("no-attestation-done", flush=True)
    return 0 if outcome == "refused" else 1


if __name__ == "__main__":
    sys.exit(main())
