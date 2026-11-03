# Release a secret only to an approved sandbox

This sample stores a secret in [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)
as ciphertext and gets it read. A setup machine encrypts a 64-byte token with an AWS KMS key
and stores the resulting envelope in Secrets Manager, so what the service holds is not the
secret. A small Python application in the sandbox reads that envelope, asks KMS to decrypt
it while presenting a signed attestation document, and checks the result against a length
and a digest its pod spec pins. It logs that check and never the value.

The pod uses `runtimeClassName: confidential-sandbox`, which treats the node as untrusted
and binds key release to a Cedar policy that pins what the pod may run. The setup machine is
trusted with the original value and stays outside the cluster. The Amazon EKS User Guide,
*Storage*, describes this shape for exactly this reason: when the threat model requires that
a secret stay out of reach of the parent instance, store it encrypted in Secrets Manager and
decrypt it inside the application with a KMS key gated on attestation.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page and the [Confidential section page](../README.md), which covers the trust
boundary, the key-policy shape, the attested decrypt and the measurement caveat that this
and the other Confidential samples share. Four samples lead into this one:

- [cedar-policy](../../policy/cedar-policy/README.md) generates a Cedar policy for a
  `confidential-sandbox` pod and shows the guest enforce it, with no attestation step.
- [encrypted-image](../encrypted-image/README.md) is the other side of the same gate: there
  the guest's image runtime makes the attested call, and the workload has no KMS code at all.
  Here the workload makes the call itself.
- [hello sandbox](../../getting-started/hello-sandbox/README.md) introduces the readings that
  show a pod ran in a sandbox.
- [coding agent](../../getting-started/coding-agent/README.md) introduces EKS Pod Identity,
  which is how this pod gets its AWS credentials.

The commands below use files from this repository, so clone it if you have not already:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/confidential/secrets-manager-secret
cp .env.example .env    # then fill in CLUSTER_NAME, AWS_REGION and KUBE_CONTEXT
```

On your own machine the scripts need the AWS CLI, `kubectl`, `jq`, `sha256sum` and a
container runtime to build the application image (`docker` by default; set `CONTAINER_CLI`
for `finch` or `podman`), plus the Cedar policy generator the Amazon EKS User Guide, *Cedar
policies*, names: `eks-nitro-sandbox-genpolicy`. It must be on your `PATH`; set `GENPOLICY`
in `.env` if your copy is named differently.

A run costs the KMS key, one stored secret, ECR storage for one small Python image (about
60 MB), and the compute of one sandboxed pod and two small ordinary pods, each of which does
its work and exits in well under a minute. The clean up removes the secret at once and
schedules the key for deletion, which AWS completes after a waiting period of at least 7 days.

## Overview

The sample has one sandboxed pod and two ordinary pods, all in one namespace, and all three
run the same image. The sandboxed pod is the workload. The two ordinary pods are controls:
one prints the machine readings so the page can show what an ordinary pod sees, and one holds
the sandboxed pod's own IAM role and asks KMS to decrypt the same ciphertext with no
attestation.

- **What Secrets Manager holds is not the secret.** The stored value is a small JSON envelope
  naming a KMS key and carrying base64 ciphertext. Its digest is not the plaintext's, and the
  plaintext does not appear anywhere in it. A caller that can read the envelope still does
  not have the secret.
- **The attestation is the boundary, not the credential.** The pod's role has no identity
  policy at all. Its two permissions are written where the conditions are: the secret's
  resource policy grants it the ciphertext read, and the key policy grants `kms:Decrypt` only
  on a matching attestation. An ordinary pod with the very same role reads the ciphertext
  and is refused the value by an explicit deny.
- **Change one pinned value and KMS stops releasing the secret.** A second pod runs the same
  image with one environment variable's value changed. Its Cedar policy differs, so its
  measurement differs, and KMS refuses. The application ends with an authorization denial and
  the pod ends `Failed`.
- **The plaintext stays in the guest.** The application validates the decrypted value against
  the length and SHA-256 its pod spec pins and logs only those two numbers. The setup script
  reads all three pods' logs back and fails if the value is in any of them.

*Figure 1: The secret's journey, from the setup machine to the sandbox that reads it back.
What AWS Secrets Manager holds is a ciphertext envelope, and the parent instance never sees
the value: it starts on the setup machine, which is trusted with it, and is recovered inside
the guest. Who AWS KMS will release it to is Figure 2.*

![A setup machine outside the cluster, labelled trusted with the value, holds a 64-byte token in plaintext. Two flows leave it. Step 1, kms:Encrypt, runs along the top of the AWS Cloud frame to AWS KMS on the far right; step 2, store the ciphertext, runs to AWS Secrets Manager, which holds the ciphertext envelope, in the upper left of the AWS Cloud frame. Inside the AWS Cloud frame an Amazon EKS cluster frame contains an EKS node frame labelled parent instance, which never sees the value. Inside the node is a Nitro sandbox pod frame with runtimeClassName confidential-sandbox, holding a Python application that decrypts in the guest and, to its left, the decrypted plaintext, which stays in the guest. Step 3, read the ciphertext envelope, runs from AWS Secrets Manager across and down into the Python application. The Python application then exchanges two flows with AWS KMS, outside the cluster to the right, whose label reads that it checks the attested PCR17 against the approved policy: step 4, an attested kms:Decrypt, and step 5, the value returned for this guest only. Step 6, validate by length and SHA-256, runs from the Python application back to the plaintext box inside the sandbox.](images/figure-1-secrets-manager-secret.png)

## Versions

| Component | Pinned to |
|---|---|
| Base image for the application | `python:3.12-slim-bookworm`, by digest, Python 3.12.15 ([`Dockerfile`](Dockerfile)) |
| [`boto3`](https://pypi.org/project/boto3/) | `1.43.118` ([`src/requirements.txt`](src/requirements.txt)) |
| [`cryptography`](https://pypi.org/project/cryptography/) | `50.0.2` |
| [`cbor2`](https://pypi.org/project/cbor2/) | `6.1.5` |
| [`asn1crypto`](https://pypi.org/project/asn1crypto/) | `1.5.1` |
| `eks-nitro-sandbox-genpolicy` | Reports no version string of its own. The pinned artifact is the image, resolved to a digest at generation time and visible in the generated policy. |

The four Python pins matter more here than in most samples. The Cedar policy pins the image
digest, and the KMS key is gated on that policy's measurement, so a rebuild that resolved a
different dependency set would be a different approved image.

## Files

| File | What it is |
|---|---|
| [`src/app.py`](src/app.py) | The workload: read the envelope, decrypt under attestation, validate, print the marker |
| [`src/readings.py`](src/readings.py) | The four machine readings. Run on its own by the comparison pod |
| [`src/no_attestation.py`](src/no_attestation.py) | The control: the same role and the same ciphertext, with no attestation document |
| [`src/requirements.txt`](src/requirements.txt) | The four pinned dependencies |
| [`Dockerfile`](Dockerfile) | The one image all three pods run |
| [`deploy/pod.yaml`](deploy/pod.yaml) | The workload: a `confidential-sandbox` pod that runs once and exits |
| [`deploy/plain-pod.yaml`](deploy/plain-pod.yaml) | An ordinary pod running the same image on the same node, for comparison |
| [`deploy/credentials-pod.yaml`](deploy/credentials-pod.yaml) | An ordinary pod with the same IAM role, asking KMS to decrypt with no attestation |
| [`deploy/secret-resource-policy.json`](deploy/secret-resource-policy.json) | The secret's resource policy: the ciphertext read and nothing else |
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The `secrets-manager-secret-sample` namespace, labelled as the sample's own |
| [`deploy/service-account.yaml`](deploy/service-account.yaml) | The service account both the sandboxed pod and the control use |
| [`../_shared/attested_recipient.py`](../_shared/attested_recipient.py) | The attested decrypt the Confidential samples share |
| [`../_shared/confidential-profile.yaml`](../_shared/confidential-profile.yaml) | The generator profile the Confidential samples share |
| [`../_shared/kms-key-policy.json`](../_shared/kms-key-policy.json) | The attestation gate: allow on a match, explicitly deny otherwise |
| [`../_shared/pod-identity/role-trust-policy.json`](../_shared/pod-identity/role-trust-policy.json) | The role trust policy, scoped to one cluster, namespace and service account |
| [`policy/policy.generated.yaml`](policy/policy.generated.yaml) | The generated Cedar policy from a real run, committed so you can read it without running anything |
| [`scripts/setup.sh`](scripts/setup.sh) | The whole flow, ending with the three pods finished |
| [`scripts/changed-pod.sh`](scripts/changed-pod.sh) | The refused case: one pinned value changed |
| [`scripts/clean.sh`](scripts/clean.sh) | Remove everything the sample created |
| [`scripts/gate.jq`](scripts/gate.jq) | The predicate both scripts read the live key policy back with |
| [`scripts/birth-policy.jq`](scripts/birth-policy.jq) | The predicate that proves the key's first policy allows no decrypt at all |
| [`scripts/lib.sh`](scripts/lib.sh) | The helpers the three scripts share |

## How it works

**Step 1: Run the setup.** One script does the whole flow. It creates five AWS resources,
each tagged `ManagedBy=secrets-manager-secret`, builds and publishes the application image,
encrypts a value and stores the ciphertext, generates the Cedar policy, sets the gate to the
policy's measurement, and runs the pods.

```bash
./scripts/setup.sh
```

```text
== 1/8 check the tools, the cluster and the Region ==
  context:  <your-context>
== 2/8 create the ECR repository and the KMS key ==
  created ECR repository secrets-manager-secret-sample
  created KMS key arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/29cf5d0b-3042-49ea-8f3c-a2ea33b10d17
  it denies every decrypt already: created with a policy, not the default one
== 3/8 create the pod's IAM role and the born-denied key policy ==
  created IAM role arn:aws:iam::<ACCOUNT_ID>:role/secrets-manager-secret-sample-pod
  the role has no identity policies (0 inline, 0 attached)
  waiting for the new IAM role to be visible to KMS...
  the key policy allows no decrypt yet (gated on an all-zero measurement)
== 4/8 create the namespace, the service account and the association ==
  created Pod Identity association a-ov9advtsmjxuupijz
== 5/8 build the application image and push it to ECR ==
  published <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/secrets-manager-secret-sample:v1-0697546e0ff2
== 6/8 encrypt the secret value and store the ciphertext in Secrets Manager ==
  created secret secrets-manager-secret-sample
  the secret's resource policy grants this role secretsmanager:GetSecretValue and nothing else
  stored 220 bytes of ciphertext (sha256 8b73bc0478a03e25e18d845d676a059716ef176c9cbb66c781610390ef900da6)
  the plaintext (64 bytes, sha256 8ad93a5f0ede70677bb580a4dcbc30f04993f0a1ac2e0aa6753f203aa097bbbf) does not appear in it
== 7/8 generate the Cedar policy and set the gate to its measurement ==
  predicted PCR17: 5b5f4ff807d8b81e75685e7ce58c179eb3826a5b3e6e1c41b3e4756ed83eea310bc1a1a5c177513507e2b7d3257d694a
  image digest pinned under the CreateContainer permit: <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/secrets-manager-secret-sample@sha256:3a814fee227d2df52e90774a37ab3410ede230b8010156fe1c092365e50ab3ca
  the gate now releases the secret only to this measurement
== 8/8 run the pods ==
  the approved pod is on <NODE_INSTANCE_ID>
  the approved pod decrypted the secret in the guest and validated it
  the ordinary pod on the same node printed its own readings
  the same role, with no attestation, could read the ciphertext and was refused the secret
  the secret value is in none of the three pods' logs

secrets-manager-secret-demo ended Succeeded: it decrypted the secret inside the sandbox.
```

Abridged: `kubectl`'s own `created` lines, the container build and push, the whole Cedar
policy the generator prints, and the closing list of commands are all left out, and the
account ID, the context and the node are replaced with placeholders. Three lines are worth
reading twice.

The key is created with a policy of its own, not the default one, and that policy denies
every decrypt: `kms:CreateKey` with no policy attaches the AWS default key policy, whose
"Enable IAM policies" statement allows `kms:*` to the account, and the key would then spend
the time until the gate went on able to decrypt for any sufficiently privileged identity in
the account. The birth policy is the gate's template with the one conditional allow taken
out, so it names no role and needs none to exist yet, and both denies are already on it
carrying an all-zero measurement no sandbox can present. Step 3/8 adds the allow once the
role is there.

The two lines in step 6/8 are the first of the sample's claims: what went into Secrets
Manager hashes to something other than the value, and the value does not appear in it in
either form. Step 2 below reads the same thing back off the service.

And `ended Succeeded` is the headline result: the application could only reach that state
because KMS accepted its attestation, released the secret, and the decrypted value matched
the length and digest the pod spec pins.

**Step 2: What is stored is ciphertext, not the secret.** Read the value back from the
service. It is a JSON envelope: a version, the ARN of the key the ciphertext belongs to, and
base64 ciphertext.

```bash
aws secretsmanager get-secret-value --secret-id secrets-manager-secret-sample \
  --query SecretString --output text > stored.json
jq '{version, key_arn, ciphertext_base64_chars: (.ciphertext | length)}' stored.json
jq -r .ciphertext stored.json | base64 -d | wc -c
jq -r .ciphertext stored.json | base64 -d | sha256sum
```

```text
{
  "version": 1,
  "key_arn": "arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/29cf5d0b-3042-49ea-8f3c-a2ea33b10d17",
  "ciphertext_base64_chars": 296
}
220
8b73bc0478a03e25e18d845d676a059716ef176c9cbb66c781610390ef900da6  -
```

The byte count is taken by decoding the base64 and counting bytes, not with `jq`'s
`@base64d | length`: that decodes into a string and counts codepoints, so on ciphertext it
returns a number that is not the length of anything.

220 bytes of ciphertext for a 64-byte value. KMS encrypts a value this small directly, with
no separate data key to manage, and the rest is the framing it puts around it
([KMS Encrypt API reference](https://docs.aws.amazon.com/kms/latest/APIReference/API_Encrypt.html)).

That digest is the other half of the claim, because it is not the value's. `setup.sh` checks
three things here before it goes any further, which are the two lines it printed in step 6/8:
the stored value's digest is not the plaintext's; the plaintext does not appear in the
envelope, nor in the ciphertext once it is decoded; and the envelope names the key this run
gated, so a ciphertext left over from an earlier run under a different key is caught here
rather than appearing later as a decrypt denial that reads like a measurement mismatch.

```text
  stored 220 bytes of ciphertext (sha256 8b73bc0478a03e25e18d845d676a059716ef176c9cbb66c781610390ef900da6)
  the plaintext (64 bytes, sha256 8ad93a5f0ede70677bb580a4dcbc30f04993f0a1ac2e0aa6753f203aa097bbbf) does not appear in it
```

The stored digest there is the same one the command above read back off the service, and the
plaintext's is the one the application prints in step 8 after it has decrypted and validated
the value. The two are different numbers, which is what "the stored value is not the secret"
means in practice.

**Step 3: Permit the ciphertext read, and nothing else.** The pod's role carries no identity
policy, so every permission it has is written in a resource policy next to a condition. This
is the whole policy on the secret, read back off the secret itself:

```bash
aws secretsmanager get-resource-policy --secret-id secrets-manager-secret-sample \
  --query ResourcePolicy --output text | jq .
```

```text
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowThePodRoleToReadTheCiphertext",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/secrets-manager-secret-sample-pod"
      },
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "*"
    }
  ]
}
```

One statement, one action. A resource policy on its own is enough to authorize a principal
in the same account
([permissions policies attached to a secret](https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_resource-based-policies.html)),
which is what lets the role keep no identity policy. What it deliberately leaves out matters
as much as what it grants: no `PutSecretValue` or `UpdateSecret`, so the workload cannot
replace the ciphertext with one wrapped under a key it chose; no `DeleteSecret` or
`DeleteResourcePolicy`; and nothing at all on AWS KMS, so this is not a second path to the
value. Reading the secret decrypts it at rest under the AWS managed key
`aws/secretsmanager`, which the service does on the caller's behalf; the sample's own key,
the one the value is encrypted with, is reached only through the conditional allow in step 6.

`setup.sh` reads this policy back off the secret and requires exactly that shape, because a
policy that had also granted a write would quietly undo the paragraph above:

```text
  the secret's resource policy grants this role secretsmanager:GetSecretValue and nothing else
```

**Step 4: Describe the pod.** The pod picks the confidential runtime class and the service
account the Pod Identity association names, and it runs once and exits.

```yaml
spec:
  runtimeClassName: confidential-sandbox
  serviceAccountName: secrets-manager-secret-pod
  restartPolicy: Never
  hostname: secrets-manager-secret-demo
  automountServiceAccountToken: false
  securityContext:
    runAsUser: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    supplementalGroupsPolicy: Strict
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: <APP_IMAGE_URI>
      env:
        - name: AWS_REGION
          value: <AWS_REGION>
        - name: AWS_DEFAULT_REGION
          value: <AWS_REGION>
        - name: SECRET_ID
          value: <SECRET_ID>
        - name: KMS_KEY_ARN
          value: <KMS_KEY_ARN>
        - name: EXPECTED_LENGTH
          value: <EXPECTED_LENGTH>
        - name: EXPECTED_SHA256
          value: <EXPECTED_SHA256>
        - name: DEMO_VARIANT
          value: approved
```

`restartPolicy: Never` is what lets the pod's terminal state be the result: the approved pod
ends `Succeeded`, the changed pod in step 10 ends `Failed`, and both stay for inspection. A
pod that restarted would ask KMS to decrypt again on every attempt.

Both Region variables are set, to the same value, because the Pod Identity webhook injects
`AWS_DEFAULT_REGION` only when the manifest does not already declare `AWS_REGION` alone; a
policy generated with `--with-pod-identity` expects it in the pinned environment either way,
and the guest refuses to create a container whose environment does not match.

Neither `EXPECTED_LENGTH` nor `EXPECTED_SHA256` is a secret. `setup.sh` generates the value
at random for the run, and a SHA-256 of 64 random characters cannot be reversed. They are
there so that a decrypt returning the wrong bytes is a failure rather than a silent pass.

This pod sets CPU and memory requests, where most samples here set none. The guest unpacks
the image inside the sandbox before the container starts, and then the application runs
CPython with boto3 and generates a 4096-bit RSA key, which the small default VM has neither
the memory nor the time for:

```yaml
      resources:
        requests:
          cpu: "1"
          memory: 1Gi
```

Requests only, and no limits: a sandbox is sized from its requests, so a limit above the
request would not give the VM any more room.

**Step 5: What the generated policy pins, and its measurement.** `setup.sh` runs the
generator with the shared profile and the Pod Identity flag:

```bash
eks-nitro-sandbox-genpolicy \
  --profile ../_shared/confidential-profile.yaml \
  --with-pod-identity \
  --output-file-b64 policy.b64 \
  rendered-pod.json
```

The admission policy permits creating the `main` container only on an exact match. Here is
the start of it, from [`policy/policy.generated.yaml`](policy/policy.generated.yaml):

```text
// Container: main
permit(
    principal,
    action == Agent::Action::"CreateContainer",
    resource == Workload::Container::"main"
)
when {
    context.image_ref == "<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/secrets-manager-secret-sample@sha256:3a814fee227d2df52e90774a37ab3410ede230b8010156fe1c092365e50ab3ca" &&
    context.working_dir == "/app" &&
    context.run_as_user == 65534 &&
    context.run_as_group == 65534 &&
    context.additional_gids == [65534] &&
    context.read_only_rootfs == true &&
    context.capabilities_effective.isEmpty() &&
```

The command the container runs is pinned too, which is why the two ordinary pods can share
this image without sharing this policy: each of them overrides `command`, and neither is a
sandbox.

See [using a signed image instead of a pinned image reference](../signer-policy/README.md).

```text
    context.process_args == "[\"python\",\"/app/app.py\"]" &&
```

And the environment is pinned by name and by value, which is what the changed pod in step 10
moves. This is the part of it the pod spec sets:

```text
                         {"name": "AWS_REGION", "value": "us-west-2"},
                         {"name": "AWS_DEFAULT_REGION", "value": "us-west-2"},
                         {"name": "SECRET_ID",
                          "value": "arn:aws:secretsmanager:us-west-2:<ACCOUNT_ID>:secret:secrets-manager-secret-sample-rPeKf0"},
                         {"name": "KMS_KEY_ARN",
                          "value": "arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/29cf5d0b-3042-49ea-8f3c-a2ea33b10d17"},
                         {"name": "EXPECTED_LENGTH", "value": "64"},
                         {"name": "EXPECTED_SHA256",
                          "value": "8ad93a5f0ede70677bb580a4dcbc30f04993f0a1ac2e0aa6753f203aa097bbbf"},
                         {"name": "DEMO_VARIANT", "value": "approved"},
```

`setup.sh` checks that the image digest is an enforced condition under the `CreateContainer`
permit, and that the digest it pins is the image this run published, rather than grepping for
the digest: the generator also writes it into a comment, so a grep would pass on a policy that
did not enforce it.

The generator prints the measurement the guest will extend this policy into, and a
ready-to-paste KMS condition with it. `PCR17` measures the policy, and `PCR8` measures the
certificate that signed the sandbox environment image. The condition always uses
`PCR8:ServiceName` rather than a raw `PCR8` value, because AWS rotates that certificate and
the raw value changes with it (Amazon EKS User Guide, *Cedar policies*).

```text
--- Predicted PCR17 ---
5b5f4ff807d8b81e75685e7ce58c179eb3826a5b3e6e1c41b3e4756ed83eea310bc1a1a5c177513507e2b7d3257d694a
--- KMS Key Policy Condition ---
"Condition": {
  "StringEqualsIgnoreCase": {
    "kms:RecipientAttestation:PCR17": "5b5f4ff807d8b81e75685e7ce58c179eb3826a5b3e6e1c41b3e4756ed83eea310bc1a1a5c177513507e2b7d3257d694a",
    "kms:RecipientAttestation:PCR8:ServiceName": "eks.amazonaws.com"
  }
}
```

Those two conditions are the whole gate this sample installs. They are what the generator
emitted, with nothing added by hand; the
[Confidential section page](../README.md#the-kms-key-policy) says why, and what pinning the
policy measurement does and does not bind.

**Step 6: The gate, read back from the live key.** `setup.sh` fills in
[`../_shared/kms-key-policy.json`](../_shared/kms-key-policy.json) and reads the policy back
off the key. These are its two decrypt statements, as the key reports them:

```bash
aws kms get-key-policy --key-id "$KMS_KEY_ARN" --policy-name default \
  --query Policy --output text \
  | jq '[.Statement[] | select(.Sid == "AttestedDecryptOnly"
         or .Sid == "DenyUnlessThePolicyMeasurementMatches")]'
```

```text
[
  {
    "Sid": "AttestedDecryptOnly",
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/secrets-manager-secret-sample-pod"
    },
    "Action": "kms:Decrypt",
    "Resource": "*",
    "Condition": {
      "StringEqualsIgnoreCase": {
        "kms:RecipientAttestation:PCR8:ServiceName": "eks.amazonaws.com",
        "kms:RecipientAttestation:PCR17": "5b5f4ff807d8b81e75685e7ce58c179eb3826a5b3e6e1c41b3e4756ed83eea310bc1a1a5c177513507e2b7d3257d694a"
      }
    }
  },
  {
    "Sid": "DenyUnlessThePolicyMeasurementMatches",
    "Effect": "Deny",
    "Principal": "*",
    "Action": [
      "kms:Decrypt",
      "kms:ReEncryptFrom"
    ],
    "Resource": "*",
    "Condition": {
      "StringNotEqualsIgnoreCase": {
        "kms:RecipientAttestation:PCR17": "5b5f4ff807d8b81e75685e7ce58c179eb3826a5b3e6e1c41b3e4756ed83eea310bc1a1a5c177513507e2b7d3257d694a"
      }
    }
  }
]
```

The measurement in both is the one the generator predicted in step 5, and the allow carries
the same two conditions the generator emitted, in the order KMS stores them.

The whole policy has five statements, and the other three matter too:

```bash
... | jq -c '[.Statement[] | {Sid, Effect, Action}]'
```

```text
[{"Sid":"KeyAdministration","Effect":"Allow","Action":["kms:CancelKeyDeletion","kms:CreateAlias","kms:DeleteAlias","kms:DescribeKey","kms:DisableKey","kms:EnableKey","kms:GetKeyPolicy","kms:GetKeyRotationStatus","kms:ListAliases","kms:ListGrants","kms:ListKeyPolicies","kms:ListResourceTags","kms:PutKeyPolicy","kms:ScheduleKeyDeletion","kms:TagResource","kms:UntagResource","kms:UpdateAlias"]},{"Sid":"BuildTimeEncrypt","Effect":"Allow","Action":"kms:Encrypt"},{"Sid":"AttestedDecryptOnly","Effect":"Allow","Action":"kms:Decrypt"},{"Sid":"DenyUnlessThePolicyMeasurementMatches","Effect":"Deny","Action":["kms:Decrypt","kms:ReEncryptFrom"]},{"Sid":"DenyUnlessTheAttestationComesFromAnEKSSandbox","Effect":"Deny","Action":["kms:Decrypt","kms:ReEncryptFrom"]}]
```

`KeyAdministration` lists its actions rather than using `kms:*`, and holds neither
`kms:Decrypt` nor `kms:ReEncryptFrom`. Leaving out `ReEncryptFrom` is as important as leaving
out `Decrypt`: it would let a key administrator re-wrap the secret under a second, ungated key
and decrypt it there, without touching this policy.

Be clear about what that does and does not buy. The same statement keeps `kms:PutKeyPolicy`,
because the key has to stay manageable, so a key administrator can always replace this
policy, remove the denies and then decrypt. What the gate binds is the pod's role and anyone
holding its credentials, which in confidential mode includes the node. Leaving out
`ReEncryptFrom` closes the administrator path that needs no policy change; it does not, and
cannot, shut out the account's key administrators.

`BuildTimeEncrypt` is what `setup.sh` used to encrypt the value, and encryption is
never gated on attestation, only decryption. The two denies apply to every principal, and
because a negated condition operator is also true when the condition key is absent, they
catch a request that carries no attestation document at all, which is step 9. The condition
keys are the public AWS KMS ones for Nitro Enclaves
([AWS KMS condition keys for AWS Nitro Enclaves](https://docs.aws.amazon.com/kms/latest/developerguide/conditions-nitro-enclaves.html),
[cryptographic attestation support in AWS KMS](https://docs.aws.amazon.com/enclaves/latest/user/kms.html));
the administration statement takes the place of the
[default key policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html)'s
broad "Enable IAM policies" statement.

Both scripts read this policy back with one file,
[`scripts/gate.jq`](scripts/gate.jq), before they draw any conclusion from a denial. It
requires that the only allow anywhere in the policy that can reach a decrypt is the
conditional one, that the conditional one names this role and carries exactly these two
conditions, and that each deny is on every principal, still covers `kms:Decrypt`, and names
one register of its own.

**Step 7: The attested decrypt, in the application.** The workload asks the Nitro Secure
Module for a document that carries an ephemeral public key, and passes it to `kms:Decrypt` as
the `Recipient`. KMS checks the document's measurements against the conditions above and
returns the plaintext encrypted to that public key in `CiphertextForRecipient`, which only
the private key inside the guest can open. This is the whole exchange, from
[`src/app.py`](src/app.py):

```python
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
```

A response carrying `Plaintext` would mean KMS had not treated this as an attested call, so
the attestation would have decided nothing; a response naming another key would mean the
ciphertext was not the one the key policy gates. Both are refused rather than used.

`AttestedRecipient` is in
[`../_shared/attested_recipient.py`](../_shared/attested_recipient.py), shared with the other
Confidential samples whose workload calls KMS itself. It generates a 4096-bit RSA key, reads
a signed document from the Nitro Secure Module's device, and opens the CMS structure KMS
returns, checking every field of it against what KMS documents. One thing to know about that
file: the Amazon EKS User Guide, *Security model and parent instance trust assumptions*, names
the Nitro Secure Module and its attestation document, but it does not document how code inside
the guest reaches the module, so the device path and the request encoding come from the
open-source [Nitro Enclaves NSM API](https://github.com/aws/aws-nitro-enclaves-nsm-api) and
this run is what shows they work.

**Step 8: The pod ran in a sandbox.** The generated policy denies exec (Amazon EKS User
Guide, *Cedar policies*), so the pod prints its readings itself and the page reads them with
`kubectl logs`, which the policy permits.

```bash
kubectl -n secrets-manager-secret-sample logs secrets-manager-secret-demo -c main
```

```text
kernel:  6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
uptime:  4.73s
disks:   dm-0 dm-1 dm-2 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 vda vdb vdc
product: m8i.enclave
secrets-manager-secret-ready
attested-secret-ok bytes=64 sha256=8ad93a5f0ede70677bb580a4dcbc30f04993f0a1ac2e0aa6753f203aa097bbbf
```

The last line is the result: 64 bytes, and a digest equal to the `EXPECTED_SHA256` the pod
spec pins and the one `setup.sh` printed for its plaintext in step 1. The value itself is not
there, and `setup.sh` searched these logs for it before it declared the run good.

The ordinary pod, running the same image and the same `readings.py` on the same node, reads:

```bash
kubectl -n secrets-manager-secret-sample logs secrets-manager-secret-plain -c main
```

```text
kernel:  6.18.54 #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026
uptime:  47683.01s
disks:   dm-0 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 nvme0n1 nvme1n1 zram0
product: m8i.xlarge
```

The kernel version is the same in both, `6.18.54`, and the build is not: `#1 ... Oct 22
17:38` against `#2 ... Oct 22 00:16`. The guest runs its own kernel. The uptime is under five
seconds against about thirteen hours, because the VM booted with the pod while the
ordinary pod reads the node's uptime. The disks are `vda vdb vdc`, the guest's virtio
devices, where the ordinary pod sees the instance's `nvme`; confidential mode's encrypted
overlay adds the `dm-` devices. And `product_name` reads `m8i.enclave` against the
`m8i.xlarge` instance type. Same machine, same image, two different places to be running.

The uptimes are worth pinning down, because what they point at is the whole claim. The node's
launch time and each container's start time are enough:

```bash
aws ec2 describe-instances --instance-ids <NODE_INSTANCE_ID> \
  --query 'Reservations[0].Instances[0].LaunchTime' --output text
kubectl -n secrets-manager-secret-sample get pod secrets-manager-secret-demo \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}{"\n"}'
kubectl -n secrets-manager-secret-sample get pod secrets-manager-secret-plain \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}{"\n"}'
```

```text
2026-10-25T23:28:42+00:00
2026-10-26T12:43:32Z
2026-10-26T12:43:30Z
```

The ordinary pod's container started at 12:43:30 on 26 October and read 47683.01 seconds,
which puts the boot it is reporting at 23:28:47 the previous evening, about five seconds
after the node was launched at 23:28:42: it is reading the machine's own boot. The sandbox
pod's container started two seconds later, at 12:43:32, and read 4.73 seconds, which puts its
boot at 12:43:27 the same morning, about thirteen hours and fifteen minutes after the node's.
By the time the sandbox read that number the machine had been up for over thirteen hours, so
the 4.73 seconds cannot be the machine's: it is a boot of its own, which happened when the
pod started. (Each uptime is read a moment after its container starts rather than exactly at
`startedAt`, so as a measure of uptime *at* `startedAt` both readings are upper bounds, and
each derived boot time is correspondingly a little early. The gap the argument rests on is
thirteen hours, so a skew of milliseconds does not touch it. Both start times are
read from `state.terminated.startedAt`, because both pods run once and exit and had finished
by the time these commands ran.)

The runtime class and the policy annotation are on the pod:

```bash
kubectl -n secrets-manager-secret-sample get pod secrets-manager-secret-demo \
  -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n secrets-manager-secret-sample get pod secrets-manager-secret-demo \
  -o jsonpath='{.metadata.annotations.sandbox\.amazonaws\.com/policy}' | wc -c
```

```text
confidential-sandbox
3692
```

The policy denies exec, and the caller is allowed by Kubernetes to request one, so the refusal
is the guest's decision and not RBAC. Both commands were run while the pod was still running,
because a pod that has ended has no container to exec into. That window is only a few seconds
wide, since the application decrypts and exits, so catching it takes a tight poll rather than
a leisurely one:

```bash
kubectl auth can-i create pods/exec -n secrets-manager-secret-sample
kubectl -n secrets-manager-secret-sample exec secrets-manager-secret-demo -c main -- /bin/true
```

```text
yes
error: Internal error occurred: Internal error occurred: error executing command in
container: failed to exec in container: failed to create exec "8aff5ac8876d...": policy
denied Agent::Action::"Exec" on container "main" reasons=[] errors=[]
```

Wrapped here to fit the page, and the exec id is shortened.

**Step 9: The same credentials, with no attestation, get nothing.** The control pod is an
ordinary pod using the same service account, so EKS Pod Identity gives it the same IAM role,
and it runs the same image, importing the workload's own envelope reader from
[`src/app.py`](src/app.py). It reads the ciphertext, which its role is allowed to do, and then
asks KMS to decrypt it with no `Recipient`. Nothing about the network stands in its way: the
sample applies no network policy, so this pod reaches the same AWS endpoints the sandbox
does, and what refuses it is the key policy alone. If KMS ever did return plaintext it drops
the response unread, so the secret could not reach the logs of a pod that is not even a
sandbox; what it prints is the outcome and the error.

```bash
kubectl -n secrets-manager-secret-sample logs secrets-manager-secret-credentials -c main
```

```text
role:    arn:aws:sts::<ACCOUNT_ID>:assumed-role/secrets-manager-secret-sample-pod/<session>
secret:  read 220 bytes of ciphertext, sha256 8b73bc0478a03e25e18d845d676a059716ef176c9cbb66c781610390ef900da6
request: kms:Decrypt on that ciphertext, with no attestation document
result:  refused
detail:  An error occurred (AccessDeniedException) when calling the Decrypt operation: User:
arn:aws:sts::<ACCOUNT_ID>:assumed-role/secrets-manager-secret-sample-pod/<session> is not
authorized to perform: kms:Decrypt on resource:
arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/29cf5d0b-3042-49ea-8f3c-a2ea33b10d17 with an explicit
deny in a resource-based policy
no-attestation-done
```

Wrapped here to fit the page: the `detail` line is one long line. The pod redacts the account
ID and the role session itself, so nothing identifying reaches its logs.

Read the first three lines together. It is the same role as the sandbox pod's, and the 220
bytes and the digest are the same ciphertext the sandbox read, byte for byte, which is what
the resource policy in step 3 permits. Then the decrypt is refused, and "with an explicit
deny in a resource-based policy" is `DenyUnlessThePolicyMeasurementMatches` from step 6 doing
its job: a `StringNotEqualsIgnoreCase` condition is true when the key is absent from the
request, and this request carried no attestation document at all. `setup.sh` requires that
wording, and requires the ciphertext read to have succeeded, before it treats the run as
having shown anything: a pod that reached no answer at all is no evidence either way.

This matters because in confidential mode the node is untrusted and can obtain these same
credentials: the Amazon EKS User Guide, *Security model and parent instance trust
assumptions*, says the parent instance can read Pod Identity credentials as they are
delivered, or mint them itself from the kubelet's own credentials, and that IAM conditions
such as `aws:SourceVpc` and session tags do not tell the sandbox apart from it. So the role is
given nothing that is not conditional: the read it is allowed returns ciphertext, and the
decrypt it is not allowed is refused by an explicit deny.

*Figure 2: What AWS KMS will release the secret to. Both pods hold the same Pod Identity role
and read the very same ciphertext envelope; only the one that can present an attestation the
key policy accepts gets the value. The credential is not the boundary.*

![A focused view of the attestation gate. On the left, inside an AWS Cloud frame, is AWS Secrets Manager, holding the ciphertext envelope. To its right an Amazon EKS cluster frame holds two pods, one above the other. The upper one is a Nitro sandbox pod frame, labelled confidential-sandbox, same Pod Identity role, holding a Python application that presents an attestation. The lower one is an Ordinary pod frame, labelled not a sandbox, same Pod Identity role, holding a main container that presents none. Two solid arrows leave AWS Secrets Manager: one up and to the right into the Python application, labelled reads the ciphertext, and one down and to the right into the main container, labelled the same read, allowed. On the far right, outside the cluster, is AWS KMS, labelled the attestation gate. Two solid arrows connect the Python application and AWS KMS: an attested kms:Decrypt going out, and the value released coming back. From the ordinary pod's container a single red dashed arrow runs to AWS KMS, labelled refused, no attestation. Below AWS KMS a red dotted note headed key policy reads: allow kms:Decrypt only on a matching attestation, and explicitly deny otherwise.](images/figure-2-attestation-gate.png)

**Step 10: Change one pinned value and KMS refuses.** This script renders the same pod with
`DEMO_VARIANT` set to `changed`, regenerates its policy, confirms the measurement really did
change and that the gate is still the approved one, and runs it. It changes nothing about the
key policy, so this pod cannot succeed.

```bash
./scripts/changed-pod.sh
```

```text
== 1/4 render the same pod with one pinned value changed ==
  set env DEMO_VARIANT=changed; the rest of the spec is unchanged
== 2/4 generate the policy for the changed pod ==
  approved PCR17: 5b5f4ff807d8b81e75685e7ce58c179eb3826a5b3e6e1c41b3e4756ed83eea310bc1a1a5c177513507e2b7d3257d694a
  changed  PCR17: 2b8cee69b8697e19f8137d8fdc44c6422d9feab30f1e7ae099d449f20032404a1e0a409e8fc9493057c8a277390537ca
== 3/4 confirm the gate still expects the approved measurement ==
  the gate is bound to the approved measurement, unchanged
== 4/4 run the changed pod and wait for the refusal ==
pod/secrets-manager-secret-changed created
NAME                             READY   STATUS   RESTARTS   AGE
secrets-manager-secret-changed   0/1     Error    0          14s

kernel:  6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
uptime:  4.36s
disks:   dm-0 dm-1 dm-2 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 vda vdb vdc
product: m8i.enclave
secrets-manager-secret-ready
attested-secret-error: An error occurred (AccessDeniedException) when calling the Decrypt
operation: User: arn:aws:sts::<ACCOUNT_ID>:assumed-role/secrets-manager-secret-sample-pod/<session>
is not authorized to perform: kms:Decrypt on resource:
arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/29cf5d0b-3042-49ea-8f3c-a2ea33b10d17 with an explicit
deny in a resource-based policy

The changed pod was refused the secret by KMS and ended Failed.
```

Abridged: the generator's policy output is left out, and the error is one long line, wrapped
here to fit. The application redacts the account ID and the role session itself before it
prints an error, and the script redacts the logs again on the way out, so nothing identifying
reaches either.

One environment variable's value moved the measurement completely, from `5b5f4ff8...` to
`2b8cee69...`. `STATUS` reads `Error`, which is how `kubectl` shows a pod in phase `Failed`
whose container exited non-zero. Everything before the last line went exactly as it did for
the approved pod: the same image, the same readings, the same network, and the same read of
the same ciphertext. Only the decrypt was refused, and refused with an authorization denial,
which is the wording the script requires: `attested-secret-error` on its own is only the
application saying something went wrong, and throttling, a network error or an expired
credential would all wear it.

Remove it when you have read it:

```bash
./scripts/changed-pod.sh --delete
```

## Good to know

- **This sample applies no network policy.** The sandbox reaches whatever the cluster lets it
  reach, and what withholds the secret is the key policy, not the network. Restricting a
  sandbox's egress is the subject of its own sample,
  [network policy](../../isolation/network-policy/README.md), which shows the mechanism and
  both sides of it.
- **The gate is the two conditions the generator emits.** They are also the minimum the
  Amazon EKS User Guide, *Security model and parent instance trust assumptions*, asks for.
  `PCR17` binds key release to this exact policy document, and so to the image digest, the
  command, the environment, the identity and the mounts it pins. `PCR8:ServiceName` binds
  release to a sandbox environment image signed by the Amazon EKS signing certificate, which
  identifies the signer rather than one particular build of that image. A key policy can
  carry more registers; if you add one, give it a deny statement of its own: registers
  listed together in one deny are ANDed, so such a deny only fires when every one of them
  mismatches. The
  [Confidential section page](../README.md#the-policy-and-its-measurement) sets this out in
  full.
- **The workload is outside the confidentiality boundary.** Confidential mode keeps the node
  from reading the secret in transit and in the guest's memory. It does nothing about what the
  application does with the plaintext once it has it: this one hashes it and drops it, but an
  application that printed it would put it in the logs, which the parent instance can read
  when the policy permits reading logs, as this one does. Auditing the image and the
  application code is the workload owner's job. See the
  [Confidential section page](../README.md#the-trust-boundary).
- **`setup.sh` reads the logs back before it says the run worked.** The claim that the
  plaintext never reaches the logs is checked against the logs as they came back, not against
  the code that wrote them: the script keeps the generated value in a private temporary file
  until it has searched all three pods' logs for it, and fails if it finds it.
- **The secret's name stays taken for a while after it is deleted.** `clean.sh` deletes the
  secret with no recovery window, so the ciphertext goes at once and the name does come back,
  but Secrets Manager does the deletion asynchronously: a run started immediately afterwards
  can still be told the name is taken. `SECRET_NAME` in `.env` is there for that.
- **A new IAM role is not immediately visible to KMS.** `kms:PutKeyPolicy` refuses a policy
  naming a role AWS has only just created, with "one or more invalid principals". It is an
  ordinary propagation delay; `setup.sh` retries on that error and on no other, which is the
  "waiting for the new IAM role to be visible to KMS" line.
- **The key is created with a policy, not the default one.** `kms:CreateKey` with no `--policy`
  attaches the AWS default key policy, whose "Enable IAM policies" statement allows `kms:*` to
  the account: the key would spend the time until the gate went on able to decrypt for any
  sufficiently privileged identity. `setup.sh` creates it with the gate's template minus the
  one conditional allow, so it denies every decrypt from the moment it exists, and checks that
  document with [`scripts/birth-policy.jq`](scripts/birth-policy.jq) before it creates the key.
- **A pod that reached no answer from AWS is no evidence either way.** The control pod's
  refusal is only worth something if AWS actually decided: a pod whose datapath has not
  settled reaches nothing, and a timeout is not a denial. `setup.sh` runs the control pod up
  to three times, treating "no decision" as a pod to replace rather than a result to report,
  and requires both the successful ciphertext read and the authorization wording before it
  treats the run as having shown anything.
- **The image tag is derived from the build inputs.** It is `v1-<first 12 of a digest over the
  Dockerfile, the requirements and the four Python files>`, so a run that changes the
  application publishes a new reference and a run that does not reuses the one that is there.
  The repository's tags are immutable, which the content-derived tag is what makes workable.
- **A reduced generator profile on the preview guest.** The shared profile pins the container
  admission fields and denies exec and stdin, but omits the two the current preview guest's
  policy schema does not define: the OCI hardening attributes are not pinned, and the policy
  does not assert the encrypted ephemeral layer. The runtime class still gives the pod an
  encrypted overlay, as the `dm-` devices in step 8 show; the policy just does not assert it.
  Generate with `--profile confidential` once the guest schema defines those fields.
- **The shared profile permits instance metadata.** `_shared/confidential-profile.yaml` sets
  `imds: allow`, so the Cedar policy does not stand in the way of the metadata service, and
  this sample applies no network policy to withhold it either. Nothing the sample does needs
  it, and nothing it shows depends on it being unreachable; if you need it closed off, the
  [network policy](../../isolation/network-policy/README.md) sample has the mechanism.
- **`host_network` reads `true` in the generated policy.** That is not the pod using the
  node's network. The guest VM owns its own network stack, so no network namespace appears in
  the OCI spec the policy is generated from, and the generator says so in a comment beside the
  clause. The pod has its own VPC address, as `kubectl get pod -o wide` shows.
- **The setup machine's own AWS credentials encrypt the value.** `setup.sh` calls `kms:Encrypt`
  with whatever your credential chain resolves to, which on a workstation is often more than
  `kms:Encrypt`. The plaintext is written to a file in a private temporary directory, never to
  a command line, and the directory is removed when the script exits, however it exits.

## Clean up

Set the variables again in a new shell if needed, then remove everything:

```bash
cd sample-eks-nitro-sandbox/examples/confidential/secrets-manager-secret
./scripts/changed-pod.sh --delete    # if you ran step 10 and have not removed it
./scripts/clean.sh
```

```text
Cleaning up in context <your-context>, Region us-west-2, namespace secrets-manager-secret-sample.
Deleting pod secrets-manager-secret-sample/secrets-manager-secret-changed...
Deleting pod secrets-manager-secret-sample/secrets-manager-secret-credentials...
pod "secrets-manager-secret-credentials" deleted from secrets-manager-secret-sample namespace
Deleting pod secrets-manager-secret-sample/secrets-manager-secret-plain...
pod "secrets-manager-secret-plain" deleted from secrets-manager-secret-sample namespace
Deleting pod secrets-manager-secret-sample/secrets-manager-secret-demo...
pod "secrets-manager-secret-demo" deleted from secrets-manager-secret-sample namespace
serviceaccount "secrets-manager-secret-pod" deleted from secrets-manager-secret-sample namespace
Deleting namespace secrets-manager-secret-sample (carries app.kubernetes.io/managed-by=secrets-manager-secret)...
namespace "secrets-manager-secret-sample" deleted
Deleting Pod Identity association a-ov9advtsmjxuupijz...
Deleting the secret secrets-manager-secret-sample and the ciphertext in it...
Deleting IAM role secrets-manager-secret-sample-pod...
Deleting ECR repository secrets-manager-secret-sample and the application image in it...
Deleting the alias alias/secrets-manager-secret-sample...
Scheduling the KMS key 29cf5d0b-3042-49ea-8f3c-a2ea33b10d17 for deletion in 7 days (the shortest AWS allows)...
arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/29cf5d0b-3042-49ea-8f3c-a2ea33b10d17	2026-11-02T12:45:06.669000+00:00
Deleting the run files under .../tmp/secrets-manager-secret/run...

Clean up complete. The KMS key is scheduled, not yet destroyed; AWS removes it after its waiting period.
```

The first two `Deleting pod` lines have no "deleted" line under them, because those two pods
were already gone by the time the clean up reached them: the changed pod was removed with
`changed-pod.sh --delete` above, and the control pod, which had finished, was no longer
there either. `--ignore-not-found` is why that is not an error. The account ID, the context
and the local path are replaced with placeholders.

`clean.sh` removes all five AWS resources, each only after reading that resource's own tags
and finding `ManagedBy=secrets-manager-secret` on it; a resource without the tag is left alone
and the clean up reports itself incomplete. It deletes objects inside the namespace only after
confirming the namespace carries this sample's label, and each pod by its exact name rather
than by a label selector. A lookup that cannot run counts as a failure, never as "already
gone", and the script exits non-zero if anything was left behind.

It opens by naming the context, the Region and the namespace it is about to act on, and it
stops if `AWS_REGION` is not set rather than letting the AWS CLI pick one up from your ambient
configuration: an `ecr`, `secretsmanager` or `kms` lookup in the wrong Region comes back with
that service's own not-found exception, which would otherwise be reported as "already gone"
while the resource is still there in the Region the run used. The run files under the
repository's `tmp/` are removed only when there is nothing to come back for.

One thing it does not do. The KMS key is scheduled, not destroyed: AWS enforces a waiting
period of at least 7 days and there is no way to remove a key sooner. Its alias is deleted at
once, so a later run with the same `KMS_ALIAS` makes a new key rather than finding this one.
Nothing else is left behind, and the sample changes no cluster-wide setting, so there is
nothing to put back.

To keep the AWS resources for another run:

```bash
./scripts/clean.sh --keep-aws-resources
```

To remove the cluster, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
