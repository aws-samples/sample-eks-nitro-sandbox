# Read an encrypted S3 file that only the sandbox can decrypt

This sample uploads a file to [Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)
as AES-256-GCM ciphertext and gets it read back inside a sandbox. A setup machine encrypts
the file under a random data key, wraps only that key with an AWS KMS key, and uploads the
ciphertext with a small manifest holding the wrapped key. A Python application in the
sandbox reads both, asks KMS to release the data key while presenting a signed attestation
document, and decrypts the file in guest memory. KMS releases the key only to a sandbox
whose attested policy matches the approved one. The application validates the file by length
and SHA-256 and never prints its contents.

Wrapping a small data key, rather than handing the file to KMS, is what lets the file be
larger than KMS's own direct-encryption input
([KMS Encrypt API reference](https://docs.aws.amazon.com/kms/latest/APIReference/API_Encrypt.html)).
The pod uses `runtimeClassName: confidential-sandbox`, which treats the node as untrusted
and binds key release to a Cedar policy that pins what the pod may run. The setup machine is
trusted with the original file and stays outside the cluster.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page and the [Confidential section page](../README.md), which covers the trust
boundary, the key-policy shape and the attested decrypt that this and the other Confidential
samples share. Three samples lead into this one:

- [cedar-policy](../../policy/cedar-policy/README.md) generates a Cedar policy for a
  `confidential-sandbox` pod and shows the guest enforce it, with no attestation step.
- [hello sandbox](../../getting-started/hello-sandbox/README.md) introduces the readings
  that show a pod ran in a sandbox.
- [coding agent](../../getting-started/coding-agent/README.md) introduces EKS Pod Identity
  and an `ApplicationNetworkPolicy` with `domainNames`.

The commands below use files from this repository, so clone it if you have not already:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/confidential/s3-encrypted-file
cp .env.example .env    # then fill in CLUSTER_NAME, AWS_REGION, KUBE_CONTEXT and S3_BUCKET
```

`S3_BUCKET` has no default and you have to choose one: an S3 bucket name is global, so pick
a name nobody has taken. A name also stays unavailable for a while after the bucket is
deleted, so a second run after a clean up may need a new one.

On your own machine the scripts need the AWS CLI, `kubectl`, `jq`, `gzip`, `sha256sum` and a
container runtime (`docker` by default; set `CONTAINER_CLI` for `finch` or `podman`), plus
the Cedar policy generator:

| Tool | Where it is documented |
|---|---|
| `eks-nitro-sandbox-genpolicy`, the Cedar policy generator | Amazon EKS User Guide, *Cedar policies* |

It must be on your `PATH`; set `GENPOLICY` in `.env` if your copy is named differently. You
do not need Python packages on the setup machine: the script runs the encrypt helper in the
image it has just built.

A run costs the KMS key, S3 storage for one 100 KiB object and its manifest, ECR storage for
the application image, and the compute of one sandboxed pod and two small ordinary pods
while the sample is up. The clean up schedules the key for deletion, which AWS completes
after a waiting period of at least 7 days.

## Overview

The sample has one sandboxed pod and two ordinary pods, all in one namespace. The sandboxed
pod reads the object and decrypts it. The two ordinary pods are controls: one runs the same
image with `--readings-only` so the page can show what an ordinary pod reads of the machine,
and one holds the sandboxed pod's own IAM role and asks KMS to decrypt the very same wrapped
data key without an attestation.

- **The stored object is ciphertext, not the file.** What S3 holds is AES-256-GCM ciphertext
  and a manifest carrying the wrapped data key and the nonce. The object's digest differs
  from the file's, and it is exactly 16 bytes longer, which is the GCM authentication tag.
  The bucket blocks public access in all four ways and encrypts at rest.
- **The attestation is the boundary, not the credential.** The pod's role has no identity
  policy at all. Its one KMS permission lives in the key policy, conditional on the attested
  measurement, and its one S3 permission is a bucket policy naming two objects. An ordinary
  pod with the very same role reads the object and is then refused the data key by an
  explicit deny, so whoever holds the credentials outside the sandbox has the ciphertext and
  not the file.
- **Change one pinned value and KMS stops releasing the key.** A second pod runs the same
  image with one pinned environment value changed. Its Cedar policy differs, so its
  measurement differs, and KMS refuses the data key. The pod ends `Failed`, and the reason
  is an authorization denial rather than a generic failure.
- **The plaintext never leaves the guest.** The application holds the file in memory, checks
  it against the length and SHA-256 its policy pins, and prints only a marker with those two
  values. Nothing on this page, and nothing in any log, is the file.

*Figure 1: An encrypted file from the setup machine to the sandbox, and the attestation gate
in the middle. Only ciphertext reaches Amazon S3, and what unlocks it inside the sandbox is
the attestation, not the credentials: an ordinary pod holding the very same Pod Identity role
is refused.*

![A setup machine outside the cluster holds the file as plaintext and an encrypt and wrap step using AES-256-GCM. Three flows leave the setup machine: step 1 encrypt, from the file to the encrypt and wrap step; step 2, kms:Encrypt wraps the data key, running along the top of the AWS Cloud frame to AWS KMS on the far right; and step 3, upload ciphertext and manifest, to Amazon S3, which holds the ciphertext and the manifest. Inside the AWS Cloud frame, an Amazon EKS cluster frame contains an EKS node frame labelled parent instance, untrusted, and inside that a Nitro sandbox pod frame with runtimeClassName confidential-sandbox, holding a main container that decrypts in guest memory. Step 4, read the ciphertext, runs from Amazon S3 down into the Nitro sandbox pod frame, so the guest reads the object itself rather than the node reading it. The main container exchanges two flows with AWS KMS, outside the cluster to the right: step 5, an attested kms:Decrypt, and step 6, the data key returned for the sandbox. Lower in the same EKS cluster sits an ordinary pod, not a sandbox, holding the sandbox's own Pod Identity role. Its request to AWS KMS is drawn as a red dashed line labelled refused, no attestation, so the same credentials without an attestation document get nothing.](images/figure-1-s3-encrypted-file.png)

## Versions

| Component | Pinned to |
|---|---|
| Application base image | `python:3.12.11-slim-bookworm` |
| [`boto3`](https://pypi.org/project/boto3/), the AWS SDK for Python, for S3 and KMS | `1.43.118` |
| [`cryptography`](https://pypi.org/project/cryptography/), AES-256-GCM and the unwrap of the KMS recipient response | `50.0.2` |
| [`cbor2`](https://pypi.org/project/cbor2/), the attestation request encoding | `6.1.5` |
| [`asn1crypto`](https://pypi.org/project/asn1crypto/), the CMS envelope KMS returns | `1.5.1` |
| AWS CLI image, for the credentials control pod only | `public.ecr.aws/aws-cli/aws-cli:2.31.19` |
| `eks-nitro-sandbox-genpolicy` | Reports no version string of its own. The pinned artifact is the application image, resolved to a digest at generation time and visible in the generated policy. |

The four Python packages are in [`src/requirements.txt`](src/requirements.txt), each pinned
to the release that was current when the sample was built.

## Files

| File | What it is |
|---|---|
| [`src/app.py`](src/app.py) | The application: read, attested decrypt, decrypt, validate, print the marker |
| [`src/encrypt_file.py`](src/encrypt_file.py) | The operator side: encrypt the file and write the manifest |
| [`src/requirements.txt`](src/requirements.txt) | The four pinned Python packages |
| [`Dockerfile`](Dockerfile) | The application image, built from `examples/confidential/` so it can take in the shared attested recipient |
| [`deploy/pod.yaml`](deploy/pod.yaml) | The workload: a `confidential-sandbox` pod that reads the object and decrypts it |
| [`deploy/plain-pod.yaml`](deploy/plain-pod.yaml) | An ordinary pod running the same image with `--readings-only`, on the same node, for comparison |
| [`deploy/credentials-pod.yaml`](deploy/credentials-pod.yaml) | An ordinary pod with the same IAM role, reading the object and asking KMS to decrypt the data key with no attestation |
| [`deploy/bucket-policy.json`](deploy/bucket-policy.json) | The bucket policy: two object reads for the pod's role, no KMS action, and a TLS-only deny |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The sandbox's egress: DNS, Pod Identity, the KMS endpoint and the bucket's endpoint, nothing else |
| [`deploy/enable-network-policy.yaml`](deploy/enable-network-policy.yaml) | The one-line, once-per-cluster change that makes network policies enforced |
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The `s3-encrypted-file-sample` namespace, labelled as the sample's own |
| [`deploy/service-account.yaml`](deploy/service-account.yaml) | The pod's service account, which the Pod Identity association names |
| [`../_shared/confidential-profile.yaml`](../_shared/confidential-profile.yaml) | The generator profile the Confidential samples share |
| [`../_shared/kms-key-policy.json`](../_shared/kms-key-policy.json) | The attestation gate: allow on a match, explicitly deny otherwise |
| `../_shared/attested_recipient.py` | The shared attested KMS recipient: ephemeral key, attestation document, unwrap `CiphertextForRecipient` |
| [`../_shared/pod-identity/role-trust-policy.json`](../_shared/pod-identity/role-trust-policy.json) | The role trust policy, scoped to one cluster, namespace and service account |
| [`scripts/setup.sh`](scripts/setup.sh) | The whole flow, ending with the pods finished |
| [`scripts/kms-gate-check.jq`](scripts/kms-gate-check.jq) | The one reading of a live key policy that both scripts use |
| [`scripts/changed-pod.sh`](scripts/changed-pod.sh) | The refused case: one pinned value changed |
| [`scripts/clean.sh`](scripts/clean.sh) | Remove everything the sample created |

## How it works

**Step 1: Turn on network policy enforcement, once for the cluster.** An EKS Auto Mode
cluster accepts network policies without enforcing them until the `amazon-vpc-cni` ConfigMap
says so. This is a setting the whole cluster shares, so the sample's scripts never change
it: apply it yourself, and `setup.sh` checks it and stops with this command if it is off.
Pods that no policy selects are unaffected.

```bash
kubectl apply -f deploy/enable-network-policy.yaml
```

**Step 2: Run the setup.** One script does the whole flow. It creates five AWS resources,
each tagged `ManagedBy=s3-encrypted-file`, encrypts and uploads the file, generates the Cedar
policy, sets the gate to the policy's measurement, and runs the pods.

```bash
./scripts/setup.sh
```

```text
== 1/9 check the tools, the cluster and the Region ==
  context:  <your-context>
  network policy enforcement: on
== 2/9 create the private bucket, the ECR repository and the KMS key ==
  created S3 bucket s3-encrypted-file-sample-144fc0d7bb
  the bucket blocks public access (all four) and encrypts at rest (AES256)
  created ECR repository s3-encrypted-file-sample
  created KMS key arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/7f71390a-067d-4ef9-9f4e-1716bcf9d0a9
  it denies every decrypt already: created with a policy, not the default one
== 3/9 create the pod's IAM role, the born-denied key policy and the bucket policy ==
  created IAM role arn:aws:iam::<ACCOUNT_ID>:role/s3-encrypted-file-sample-pod
  the role has no identity policies (0 inline, 0 attached)
  waiting for the new IAM role to be visible to KMS...
  the key policy allows no decrypt yet (gated on an all-zero measurement)
  the bucket policy grants the pod s3:GetObject on the two objects and nothing else
== 4/9 create the namespace, the service account, the association and the egress policy ==
namespace/s3-encrypted-file-sample created
serviceaccount/s3-encrypted-file-pod created
  created Pod Identity association a-vvsc4dvf1qcenfldz
applicationnetworkpolicy.networking.k8s.aws/s3-encrypted-file-egress created
  egress policy applied and handed to the nodes (1 PolicyEndpoint)
```

Abridged: the account ID is replaced with `<ACCOUNT_ID>` and the kube context with
`<your-context>`. `s3-encrypted-file-sample-144fc0d7bb` is the bucket name this run used; you
choose your own in `.env`. The later steps are the ones below.

**The key is created with a policy, never with the default one.** `kms:CreateKey` with no
`--policy` attaches the
[default key policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html),
whose "Enable IAM policies" statement allows `kms:*` to the account root, and that includes
an unconditional `kms:Decrypt`. The script therefore creates the key with the gate's own
shape, with the conditional allow removed and an all-zero measurement no sandbox can present
in both denies, so the key refuses every decrypt from the moment it exists. The measurement
is replaced in step 6, once the policy has been generated.

**Step 3: What the setup machine encrypts, and what it uploads.** The file is 100 KiB of
random bytes: what matters is that only the sandbox can read them back. A random 32-byte data
key encrypts it with AES-256-GCM, and only that data key is handed to KMS. Neither the file
nor the data key ever goes on a command line; both are passed as file paths.

The additional authenticated data is `s3://<bucket>/<object key>`. It is covered by the GCM
tag without being secret, so the same ciphertext copied to another key or another bucket no
longer decrypts. The application derives that string from its own pinned environment rather
than reading it out of the manifest.

```text
== 6/9 encrypt the file, wrap its data key and upload both ==
  encrypted 102400 bytes with AES-256-GCM into 102416 bytes of ciphertext
  uploaded s3://s3-encrypted-file-sample-144fc0d7bb/confidential/report.bin and the manifest beside it
  the stored object differs from the file and is 16 bytes longer (the GCM tag)
```

The script reads the object back out of S3 rather than trusting what it uploaded, and stops
if the stored bytes are the plaintext file, if they are not the ciphertext this run made, or
if the length is not the file's plus the 16 byte GCM tag.

**Step 4: The manifest that travels beside the ciphertext.** This is the whole object, from
the run above:

```json
{
  "algorithm": "AES-256-GCM",
  "ciphertext_key": "confidential/report.bin",
  "encrypted_data_key": "AQICAHiKnQ5kELddKVKMBk6PGVaBAgKlcvT5bnN1Eyy88SJsNQFecvyHjAJCUOK9wv2e+GRoAAAAfjB8BgkqhkiG9w0BBwagbzBtAgEAMGgGCSqGSIb3DQEHATAeBglghkgBZQMEAS4wEQQMilnt/DWnAwK0qlXRAgEQgDuF0rlmGe6Z7+feXuMGllJPDYxHDhYXvErNrubI/+eDfcWgJCT3v+3ksGvG/LPmPFlB8grbgNP2TpBQww==",
  "key_arn": "arn:aws:kms:us-west-2:<ACCOUNT_ID>:key/7f71390a-067d-4ef9-9f4e-1716bcf9d0a9",
  "nonce": "CXwktLh7yX37pu0I",
  "version": 1
}
```

Nothing in it is a secret. `encrypted_data_key` is the data key as KMS wrapped it, and only
KMS can unwrap it, which it will do only for an attestation the key policy accepts. That is
the whole point: the manifest can sit in the open beside the ciphertext, and anyone who reads
both still has nothing.

**Step 5: Permit ciphertext reads, and nothing else.** The pod has a dedicated service
account and Pod Identity role with no attached or inline identity policies at all. An
[S3 bucket policy](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
is the role's only access to the bucket, and it names the two objects key by key: no
`s3:ListBucket`, no write, no delete, no prefix wildcard, and no KMS action. A second
statement refuses any request to the bucket that is not over TLS, using
`aws:SecureTransport`.

```json
{
  "Sid": "PodMayReadTheCiphertextAndItsManifest",
  "Effect": "Allow",
  "Principal": { "AWS": "<POD_ROLE_ARN>" },
  "Action": "s3:GetObject",
  "Resource": [
    "arn:aws:s3:::<S3_BUCKET>/<S3_CIPHERTEXT_KEY>",
    "arn:aws:s3:::<S3_BUCKET>/<S3_MANIFEST_KEY>"
  ]
}
```

That is the first of the two statements in [`deploy/bucket-policy.json`](deploy/bucket-policy.json);
`setup.sh` fills in the placeholders. It reads the installed policy back and stops unless it
holds exactly one `Allow`, for `s3:GetObject` on those two objects by the pod's role, and
grants no KMS action. Keeping KMS out of the bucket policy is what leaves the key policy as
the only thing between the credentials and the data key.

**Step 6: Bind key release to the approved policy.** The generator reads the rendered pod
manifest and emits the Cedar policy, pinning the image by digest, the numeric identity, the
environment, the mounts and the hostname. It also prints the measurement it predicts, which
is what the key policy is set to expect. The script checks the pinned image digest is the one
it just published and that the policy pins the bucket, the manifest key, the key ARN and the
expected length and digest, then installs the gate and reads it back.

```text
== 7/9 generate the Cedar policy and set the gate to its measurement ==
--- Predicted PCR17 ---
6bf01e47f37f16c5c02c2fedd3a284908976e02f24bdd22da76c5b4182622820eb81ca42abd225bd846156963364faf8
--- KMS Key Policy Condition ---
"Condition": {
  "StringEqualsIgnoreCase": {
    "kms:RecipientAttestation:PCR17": "6bf01e47f37f16c5c02c2fedd3a284908976e02f24bdd22da76c5b4182622820eb81ca42abd225bd846156963364faf8",
    "kms:RecipientAttestation:PCR8:ServiceName": "eks.amazonaws.com"
  }
}
  predicted PCR17: 6bf01e47f37f16c5c02c2fedd3a284908976e02f24bdd22da76c5b4182622820eb81ca42abd225bd846156963364faf8
  image digest pinned under the CreateContainer permit: <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/s3-encrypted-file-sample@sha256:35069e515818963c18101f9ea947d4dacc48023493df83353198832f1f6b75dd
  the policy pins the bucket, the manifest key, the key ARN, and the expected length and digest
  the gate now releases the data key only to this measurement
```

Abridged: the generator also prints the whole admission and runtime policy, which is several
hundred lines. The condition block is the generator's own output, pasted by `setup.sh` into
the key policy with no register added by hand. Why exactly these two conditions, and what
they do and do not bind, is on the
[Confidential section page](../README.md#the-kms-key-policy).

**Step 7: The gate, read back from the live key.** This is the two statements that decide
whether the data key is released, from `aws kms get-key-policy` on this run's key. The two
administration statements above them are in
[`../_shared/kms-key-policy.json`](../_shared/kms-key-policy.json).

```json
{
  "Sid": "AttestedDecryptOnly",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/s3-encrypted-file-sample-pod"
  },
  "Action": "kms:Decrypt",
  "Resource": "*",
  "Condition": {
    "StringEqualsIgnoreCase": {
      "kms:RecipientAttestation:PCR8:ServiceName": "eks.amazonaws.com",
      "kms:RecipientAttestation:PCR17": "6bf01e47f37f16c5c02c2fedd3a284908976e02f24bdd22da76c5b4182622820eb81ca42abd225bd846156963364faf8"
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
      "kms:RecipientAttestation:PCR17": "6bf01e47f37f16c5c02c2fedd3a284908976e02f24bdd22da76c5b4182622820eb81ca42abd225bd846156963364faf8"
    }
  }
}
```

A third statement, `DenyUnlessTheAttestationComesFromAnEKSSandbox`, is the same deny for
`kms:RecipientAttestation:PCR8:ServiceName`. Each register gets a deny of its own on purpose:
the keys inside one `StringNotEqualsIgnoreCase` block are ANDed, so a single deny listing both
would fire only when *both* failed to match, and a request matching one and not the other would
slip past it. Both scripts read the live policy through
[`scripts/kms-gate-check.jq`](scripts/kms-gate-check.jq) and refuse to go on if they find the
merged form, a second `Allow` that can reach a decrypt, or a deny that has lost `kms:Decrypt`.
A denial only means "the measurement was refused" if the gate that produced it is the gate the
page says is there.

The condition keys are the AWS KMS Nitro Enclaves ones
([AWS KMS condition keys for AWS Nitro Enclaves](https://docs.aws.amazon.com/kms/latest/developerguide/conditions-nitro-enclaves.html);
[cryptographic attestation support in AWS KMS](https://docs.aws.amazon.com/enclaves/latest/user/kms.html)),
and `Recipient` and `CiphertextForRecipient` are the
[KMS Decrypt](https://docs.aws.amazon.com/kms/latest/APIReference/API_Decrypt.html)
parameters.

**Step 8: The approved pod reads the file.** The application does the attested decrypt
itself, through the shared recipient in `../_shared/attested_recipient.py`: it generates an
ephemeral RSA key, asks the Nitro Secure Module for a document carrying the public key,
passes that document to `kms:Decrypt` as the `Recipient`, and requires the answer to come
back as `CiphertextForRecipient` and from the key it pinned. A response carrying a
`Plaintext` field, or a different key id, is refused rather than used. It then decrypts the
file with AES-256-GCM, checks it against the pinned length and SHA-256, and prints the
marker.

The pod decrypts and exits, so it prints its own machine readings first: the generated policy
denies `exec`, by design, so the sandbox proof has to be in the pod's own logs. These are
the whole logs of the approved pod from this run:

```bash
kubectl -n s3-encrypted-file-sample logs s3-encrypted-file-demo -c main
```

```text
variant: approved
kernel:  6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
uptime:  5.06s
disks:   dm-0 dm-1 dm-2 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 vda vdb vdc
product: m8i.enclave
waiting: 75s for the network policy to be in force on the node
blocked: https://example.com/ refused (URLError: <urlopen error [Errno 101] Network is unreachable>)
manifest: version=1 algorithm=AES-256-GCM wrapped_data_key=184B nonce=12B
s3:      read 102416 bytes of ciphertext sha256=94a742dd2c459c2480db019229655ab5e7fd3cea6cc371a1669acf4abf3ea251
kms:     CiphertextForRecipient 749B, no plaintext field
attested-s3-ok bytes=102400 sha256=975453e32b5b332ec67caa41a4f545182ee08c9cf07c1b9dfbfa2b38754ad060
```

`kms: CiphertextForRecipient 749B, no plaintext field` is the attested decrypt: KMS returned
the data key encrypted to the attestation document's public key and no plaintext at all, and
only the private key inside this guest could unwrap it. The last line is the result:
102400 bytes, matching the digest the setup machine recorded. The ciphertext the pod read has
a different digest, so the object in S3 is not the file.

**Step 9: The same readings from an ordinary pod on the same node.** `setup.sh` pins a plain
pod to the node the sandboxed pod landed on, running the same image and the same code with
`--readings-only`. Side by side, these show the sandboxed pod's containers ran in a VM of
their own:

```bash
kubectl -n s3-encrypted-file-sample logs s3-encrypted-file-plain -c main
```

```text
variant: plain
kernel:  6.18.54 #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026
uptime:  44294.73s
disks:   dm-0 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 nvme0n1 nvme1n1 zram0
product: m8i.xlarge
s3-encrypted-file-readings-done
```

| Reading | Sandboxed pod | Ordinary pod, same node |
|---|---|---|
| Kernel | `6.18.54 #1`, built `Thu Oct 22 17:38:11 UTC 2026` | `6.18.54 #2`, built `Thu Oct 22 00:16:59 UTC 2026` |
| Uptime | `5.06s`, which is the pod's age: the VM booted with the pod | `44294.73s`, the node's uptime |
| Disks | `vda vdb vdc`, virtio devices, plus the `dm-` devices of the encrypted overlay | `nvme0n1 nvme1n1`, the instance's own devices |
| Product name | `m8i.enclave`, the VM in the sandbox | `m8i.xlarge`, the EC2 instance type |

The kernel *version* is the same in both, which is why `uname -r` on its own is not evidence.
It is the build number and date, the boot, the disks and the product name that differ.

**Step 10: Credentials alone are not enough.** The last pod `setup.sh` runs is an ordinary
pod on the same service account, so EKS Pod Identity hands it the same IAM role. It reads the
same object, which the bucket policy permits, and then asks KMS to decrypt the same wrapped
data key. The only thing it does not have is an attestation document. In confidential mode
this stands for the node itself as much as for an operator: the parent instance can obtain
the same Pod Identity credentials the workload uses (Amazon EKS User Guide, *Security model
and parent instance trust assumptions*).

```bash
kubectl -n s3-encrypted-file-sample logs s3-encrypted-file-credentials -c main
```

```text
TODO: output from the fresh run
```

It read the ciphertext and was refused the data key. `setup.sh` requires both halves: a pod
that could not read the object would not show that reading it is not enough, and a non-zero
exit on its own is not enough either, because throttling, a network failure and an expired
credential all produce one. It looks for the authorization wording that the attestation
conditions, and only they, produce here.

**Step 11: A changed spec is refused.** The last part runs a second pod from the same image
with one pinned environment value changed, `SAMPLE_VARIANT`. The confidential profile pins
the container's environment, so the generated policy differs, its measurement differs, and
the gate `setup.sh` installed no longer matches. Nothing about the key policy is touched: it
stays bound to the approved pod's measurement, so this pod can never read the file, however
long it retries.

```bash
./scripts/changed-pod.sh
```

```text
TODO: output from the fresh run
```

The script checks the changed pod differs from the approved one in nothing but that one
value, that its predicted measurement really is different, and that the live key policy is
still the approved gate, before it starts the pod at all. Delete it when you have finished
looking at it:

```bash
./scripts/changed-pod.sh --delete
```

## How the network policy works

The sandbox has a network, so its egress is restricted. This is the complete policy, as the
file ships; `setup.sh` fills in the three placeholders at apply time.

```yaml
apiVersion: networking.k8s.aws/v1alpha1
kind: ApplicationNetworkPolicy
metadata:
  name: s3-encrypted-file-egress
spec:
  podSelector:
    matchLabels:
      app: s3-encrypted-file
  policyTypes:
    - Ingress
    - Egress
  egress:
    - to:
        - ipBlock: { cidr: <COREDNS_IP>/32 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - ipBlock: { cidr: 169.254.170.23/32 }   # EKS Pod Identity credentials
      ports:
        - { protocol: TCP, port: 80 }
    - to:
        - domainNames:
            - kms.<AWS_REGION>.amazonaws.com     # release the wrapped data key
      ports:
        - { protocol: TCP, port: 443 }
    - to:
        - domainNames:
            - <S3_BUCKET>.s3.<AWS_REGION>.amazonaws.com   # read the ciphertext
      ports:
        - { protocol: TCP, port: 443 }
```

`setup.sh` reads `<COREDNS_IP>` from `kubectl get svc -n kube-system kube-dns`, and
`<AWS_REGION>` and `<S3_BUCKET>` from `.env`.

| Part | What it does |
|---|---|
| `podSelector` | Selects only the sandboxed pod, by its `app: s3-encrypted-file` label. Neither control pod carries that label: the plain pod is the comparison for the readings, and the credentials pod is meant to reach S3 and KMS the ordinary way, so that what stops it is the key policy and not the network. |
| `policyTypes: [Ingress, Egress]` | Denies all ingress and all egress except the rules below. Nothing in the sample needs to reach the pod. |
| DNS rule | Lets the pod resolve names, against the cluster's CoreDNS Service address only. |
| Pod Identity rule | `169.254.170.23:80` is the credential endpoint. It is served inside the guest, but the sandbox passes the requests on to the Pod Identity Agent on the node, and this policy applies to them: without the rule they time out. |
| KMS rule | Where the wrapped data key is released. The `domainNames` form resolves the name and allows the addresses behind it. |
| S3 rule | The bucket's own virtual-hosted endpoint, which is the host boto3 connects to, rather than the Region's shared endpoint. |

**There are four rules because the application makes two kinds of request.** Two S3 reads,
for the manifest and the ciphertext, and one `kms:Decrypt`. Both need a name resolved and the
pod's AWS credentials, which is the other two rules. There is no ECR rule, because the node
pulls the image and transfers it into the sandbox; the guest never talks to the registry.

**It is enforced on the node, outside the guest.** The node's network policy agent attaches
eBPF programs to the pod's host-side interface, so a command inside the sandbox cannot change
it, even as root. Kubernetes always allows traffic between a pod and its own node.

**Both directions, from the pod's own logs.** Exec is denied, so the pod probes for itself.
The allowed destinations are the ones the run above used: two S3 reads and one `kms:Decrypt`
all completed, which is the `s3:` and `kms:` lines in step 8. The refused one is the line
above them:

```text
blocked: https://example.com/ refused (URLError: <urlopen error [Errno 101] Network is unreachable>)
```

`example.com` resolved, because DNS is allowed, and then got no connection at all. "Network
is unreachable" at once, rather than a timeout, is what a host that also publishes IPv6
addresses gives; both are the same refusal. `setup.sh` treats a probe that *connected* as a
failed run rather than a result, because it would mean the pod ran before the policy was in
force on its node.

**Its limits.** A `domainNames` rule allows the addresses the name resolves to, so any other
name served from those same addresses is reachable too. That matters more for the S3 rule
than for KMS: other buckets in the Region can share addresses with this one, so the rule
narrows the pod to S3 rather than to this bucket alone. What limits the pod to two objects is
the bucket policy, not the network policy. DNS stays open to CoreDNS, which is why the
blocked probe resolves before it fails to connect. And the pod can always reach its own node.

## Good to know

- **The pod's network readings come 75 seconds in, not at start-up.** A pod's network policy
  is programmed on the node shortly after the pod starts, and a probe in its first seconds can
  run before the policy is in force. The readings are worth nothing unless they are taken once
  the policy is in force, so the container waits, which is the `waiting: 75s` line.
- **A pod can come up on a recycled IP with a stale datapath.** On a busy cluster, a pod
  created soon after a policy appears in its namespace can get a network that does not match
  the policy and stay that way for as long as it lives. `setup.sh` applies the egress policy
  early, minutes before any pod, and starts the credentials pod up to three times, treating
  "no answer from KMS" as no evidence rather than as a denial.
- **The gate pins the policy measurement, not the guest image.** The two conditions this
  sample installs are the ones the generator emits, and `PCR17` binds key release to this
  exact policy document, and so to the image digest, the environment, the identity and the
  mounts it pins. Neither of them binds release to a particular guest system image: another
  guest image presenting the same `PCR17` is not excluded, and `PCR8:ServiceName` matches the
  signing certificate's service name rather than measuring the image. For production you
  would add `PCR0`, the system image measurement, which the Amazon EKS User Guide, *Security
  model and parent instance trust assumptions*, asks for alongside `PCR17` at minimum. `PCR0`
  has to come from a real attestation document, and nothing in this sample reads one, so it is
  left out rather than written by hand. The
  [Confidential section page](../README.md#the-policy-and-its-measurement) sets this out in
  full.
- **One file, read into memory in one piece.** The application reads the whole object and
  decrypts it in one AES-GCM operation, which is what lets it authenticate the file as a
  whole. A file too large for the pod's memory needs an authenticated streaming or chunked
  format, and this sample does not implement one. The pod therefore sets requests, where most
  samples here set none: the application imports `boto3` and `cryptography`, generates a
  4096-bit RSA key for the attestation document, and holds the file in memory, which does not
  fit the small default VM. It sets requests only and no limits, because a sandbox is sized
  from its requests.
- **The bucket uses SSE-S3, not this sample's KMS key.** Server-side encryption with the
  sample's own key would mean S3 calling `kms:Decrypt` itself to serve the object, and S3 has
  no attestation document, so the gate would refuse it and nobody could read the object at
  all. The confidentiality here comes from the application encryption; the bucket's default
  encryption is the at-rest default every object in it gets as well.
- **The additional authenticated data binds the ciphertext to its location.** It is
  `s3://<bucket>/<object key>`, derived inside the guest from pinned environment values rather
  than read from the manifest. The same bytes copied to another key, or another bucket, no
  longer decrypt. An operator who moves the object and repoints the pod at it changes the
  pinned environment, so the measurement changes and the data key is not released either.
- **A new IAM role is not immediately visible to KMS.** `kms:PutKeyPolicy` refuses a policy
  naming a role AWS has only just created, with "one or more invalid principals". It is an
  ordinary propagation delay; `setup.sh` retries on that error and on no other, which is the
  "waiting for the new IAM role to be visible to KMS" line.
- **The image tag carries a digest of the sources.** The tag is `v1-<first 12 of a digest of
  the Dockerfile, the requirements and the three Python files>`, so a change to the application
  or to the shared attested recipient publishes a new reference rather than reusing a stale one
  under a tag the repository will not let it overwrite.
- **A reduced generator profile on the preview guest.** The shared profile pins the container
  admission fields and denies exec and stdin, but omits the two the current preview guest's
  policy schema does not define: the OCI hardening attributes are not pinned, and the policy
  does not assert the encrypted ephemeral layer. The runtime class still gives the pod an
  encrypted overlay, as the `dm-` devices in step 8 show; the policy just does not assert it.
- **An attestation document names the instance.** It carries a module identifier built from
  the EC2 instance id, so anyone who receives one can tell which instance the sandbox ran on.
  Do not treat placement as confidential if you share attestation documents with third
  parties (Amazon EKS User Guide, *Security model and parent instance trust assumptions*).
- **The workload is outside the confidentiality boundary.** Confidential mode keeps the node
  from reading the plaintext. It does nothing about what the application does with it once it
  has it: this one validates it by length and digest and prints neither the file nor the data
  key, but that is the application's choice, not something the runtime enforces. See the
  [Confidential section page](../README.md#the-trust-boundary).
- **The shared profile permits instance metadata, and the network policy is what withholds
  it.** `_shared/confidential-profile.yaml` sets `imds: allow`, so the Cedar policy does not
  stand in the way of the metadata service. Here it is simply unreachable: the egress policy
  allows DNS, the Pod Identity address, the KMS endpoint and the bucket's endpoint, and
  `169.254.169.254` is not among them. The image also sets
  `AWS_EC2_METADATA_DISABLED=true`, so the SDK does not wait on an address the policy denies.
  If you reuse the profile without an egress policy like this one, the sandbox can reach
  instance metadata.

## Clean up

Set the variables again in a new shell if needed, then remove everything:

```bash
cd sample-eks-nitro-sandbox/examples/confidential/s3-encrypted-file
./scripts/changed-pod.sh --delete    # if you ran step 11 and have not removed it
./scripts/clean.sh
```

```text
TODO: output from the fresh run
```

`clean.sh` removes all five AWS resources, each only after reading that resource's own tags
and finding `ManagedBy=s3-encrypted-file` on it; a resource without the tag is left alone and
the clean up reports itself incomplete. That check matters most for the bucket: emptying one
deletes its objects, and their versions, and there is no undoing it. It deletes objects inside
the namespace only after confirming the namespace carries this sample's label, and each pod by
its exact name rather than by a label selector. A lookup that cannot run counts as a failure,
never as "already gone", and the script exits non-zero if anything was left behind.

It opens by naming the context, the Region and the namespace it is about to act on, and it
stops if `AWS_REGION` is not set rather than letting the AWS CLI pick one up from your ambient
configuration: an `ecr` or `kms` lookup in the wrong Region comes back with that service's own
not-found exception, which would otherwise be reported as "already gone" while the resource is
still there in the Region the run used. The run files under the repository's `tmp/`, which
include the plaintext file, are removed only when there is nothing to come back for.

Three things it does not do. The KMS key is scheduled, not destroyed: AWS enforces a waiting
period of at least 7 days and there is no way to remove a key sooner. The S3 bucket name stays
unavailable for a while after the bucket is deleted, so a later run may need a new
`S3_BUCKET`. And it leaves network policy enforcement on, because that is a cluster-wide
setting other workloads may depend on; remove it yourself if nothing else needs it.

To keep the AWS resources for another run:

```bash
./scripts/clean.sh --keep-aws-resources
```

To remove the cluster, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
