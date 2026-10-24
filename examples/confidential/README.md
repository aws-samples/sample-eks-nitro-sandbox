# Confidential sandboxes: attestation, not credentials

The samples in this section use `runtimeClassName: confidential-sandbox`, which treats the
node as untrusted. Each one gives a workload something only the sandbox should be able to
read, and makes AWS KMS, outside the cluster, decide whether to release the key.

This page is the part they share: the trust boundary, the shape of the KMS key policy, the
attested decrypt, how a sample proves it ran in a sandbox, and what the measurement does
and does not bind. Each sample's page links here instead of restating it, and reuses the
templates in [`_shared/`](#the-shared-files).

## The trust boundary

In confidential mode the sandbox is the security boundary, not the node. The Nitro
hypervisor keeps the parent instance from reading sandbox memory or CPU state, from forging
attestation documents, and from decrypting encrypted image layers; the container's writable
layer and its `emptyDir` volumes sit on an encrypted overlay inside the sandbox (Amazon EKS
User Guide, *Security model and parent instance trust assumptions*).

Two consequences shape every sample here.

- **Credentials are not a secret.** The parent instance can obtain the same EKS Pod
  Identity credentials the workload uses, either by reading them as they are delivered or
  by minting them from the kubelet's own Kubernetes credentials and the node role. IAM
  conditions such as `aws:SourceVpc`, principal tags and session tags do not tell the
  sandbox apart from the parent instance (Amazon EKS User Guide, *Security model and parent
  instance trust assumptions*). So a sample never relies on the pod's credentials staying
  secret: it assumes anything the role permits is reachable from outside the sandbox, and
  gives the role nothing but a conditional grant.
- **Measurement without a verifier decides nothing.** The sandbox measures the pod's Cedar
  policy into a register, but nothing inside the sandbox or on the node checks that
  measurement against an expected value. A cluster operator can write a different policy,
  attach it, and the sandbox will accept and enforce it: the attestation changes and
  nothing rejects the pod. The loop closes only when something outside checks the
  attestation before releasing a secret, which is what the KMS key policy below does
  (Amazon EKS User Guide, *Security model and parent instance trust assumptions*, and
  *Cedar policies*).

**The workload is outside the boundary.** Confidential mode protects the workload's data
from the node. It does not protect that data from the workload. Anything the container
chooses to do with its plaintext, writing it to stdout, to a shared volume, or to a network
destination of its own choosing, is outside what the runtime can prevent. Auditing the
image and the application code is the workload owner's job (Amazon EKS User Guide,
*Security model and parent instance trust assumptions*).

## The policy and its measurement

A `confidential-sandbox` pod needs a Cedar policy. Unlike `isolated-sandbox`, which applies
a permissive built-in default, confidential mode enforces a strict default-deny posture, so
a pod with no policy does not run. The policy generator the Amazon EKS User Guide names,
`eks-nitro-sandbox-genpolicy`, reads the pod manifest and emits the policy; it travels to
the guest as the `sandbox.amazonaws.com/policy` annotation, a base64-encoded, gzipped JSON
envelope (Amazon EKS User Guide, *Cedar policies*).

The generator also prints the measurement the sandbox will extend that policy into, which
is what the key policy is set to expect. Two registers matter:

| Register | What it measures |
|---|---|
| `PCR17` | The policy. The agent hashes the uncompressed envelope JSON with SHA-384 and extends the result into `PCR17`, so the generator can predict it before any pod runs. Change any pinned value in the pod spec and the policy changes, and so does this. |
| `PCR0` | The guest system image. |
| `PCR8` | The certificate that signed the sandbox environment image. Always condition on `kms:RecipientAttestation:PCR8:ServiceName`, never a raw `PCR8` value: AWS rotates the signing certificate, which changes the raw value, while the service-name condition stays valid across rotations. |

Source for all three, and for the generator's predicted value: Amazon EKS User Guide,
*Cedar policies*, and *Security model and parent instance trust assumptions*.

The [cedar-policy](../policy/cedar-policy/README.md) sample under Policy is the place to
start if you have not generated a policy before. It shows the generation, what the policy
pins, and the guest enforcing it, and stops short of attestation.

## The KMS key policy

Every sample here puts the same shape on its key, in
[`_shared/kms-key-policy.json`](_shared/kms-key-policy.json): allow on a matching
attestation, explicitly deny otherwise.

- **Key administration** lists its actions rather than using `kms:*`, and leaves out
  `kms:Decrypt` and `kms:ReEncryptFrom`. `ReEncryptFrom` matters as much as `Decrypt`,
  because it would let a key administrator re-wrap the protected key under a second,
  ungated key and decrypt it there.
- **One conditional allow** for `kms:Decrypt`, to the pod's dedicated role, when the
  attested `PCR17` is the approved policy's measurement and
  `PCR8:ServiceName` is `eks.amazonaws.com`.
- **Two denies**, on every principal, when either of those does not match. A negated
  condition operator is also true when the condition key is absent from the request, so a
  `Decrypt` carrying no attestation document at all is caught by both.

The condition keys are the AWS KMS Nitro Enclaves ones:
[`kms:RecipientAttestation:PCR<PCR_ID>`](https://docs.aws.amazon.com/kms/latest/developerguide/conditions-nitro-enclaves.html)
and
[cryptographic attestation support in AWS KMS](https://docs.aws.amazon.com/enclaves/latest/user/kms.html).
The administration statement replaces the
[default key policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html)'s
broad "Enable IAM policies" statement, which would otherwise let any sufficiently
privileged identity in the account decrypt.

**The role carries no identity policy.** Each sample gives the pod a dedicated role with
nothing attached or inline, and scopes its trust policy to one cluster, namespace and
service account with the `aws:RequestTag` conditions EKS Pod Identity sets
([`_shared/pod-identity/role-trust-policy.json`](_shared/pod-identity/role-trust-policy.json)).
Everything the role may do is in the key policy, where the attestation condition is, so
there is no second path to `kms:Decrypt` that skips the gate. The setup scripts check for
identity policies on the role and stop if they find one.

**For production, pin more than the policy.** Pinning `PCR17` binds key release to one
exact policy document, and so to the image digest, environment, identity and mounts that
policy pins. It does not bind release to a particular guest system image: another guest
image presenting the same `PCR17` is not excluded. The Amazon EKS User Guide's
recommendation is to include at minimum `PCR0`, the system image, as well as `PCR17`
(*Security model and parent instance trust assumptions*). The samples here gate on `PCR17`
and the `PCR8` service name, and say so on each page; they leave `PCR0` out because the
preview guest image's value changes with each release, which would make a sample that
pinned it stop working on the next one.

## The attested decrypt

A caller inside the guest does not ask KMS for plaintext. It asks the Nitro Secure Module
for a signed attestation document that carries an ephemeral public key, and passes that
document to `kms:Decrypt` as the `Recipient`. KMS validates the document, checks its
measurements against the key policy's conditions, and returns the plaintext encrypted to
that public key in
[`CiphertextForRecipient`](https://docs.aws.amazon.com/kms/latest/APIReference/API_Decrypt.html)
instead of returning plaintext. Only the matching private key, which never leaves the
guest, can unwrap it.

```text
attestation = NSM.attest(ephemeral_public_key)
response    = KMS.Decrypt(CiphertextBlob = wrapped_key, Recipient = attestation)
plaintext   = unwrap(response.CiphertextForRecipient, ephemeral_private_key)
```

Which component does this differs by sample. In
[encrypted-image](encrypted-image/README.md) the caller is the guest's own image runtime,
before the container starts, and the workload image contains no KMS code at all. In the
two application samples the workload makes the call itself.

**An attestation document names the instance.** It includes a module identifier of the form
`i-<instance-id>-enc<enclave-id>`, so anyone who receives one can tell which EC2 instance
the sandbox is running on. Do not treat placement as confidential if you share attestation
documents with third parties (Amazon EKS User Guide, *Security model and parent instance
trust assumptions*).

## How these samples prove a pod ran in a sandbox

The generated confidential policy denies `exec`, so the usual way of reading a pod from the
outside is not available, by design. Every sample here has its container print its own
readings at start-up and reads them with `kubectl logs`, which the policy permits, and runs
an ordinary pod on the same node for comparison:

| Reading | In the sandbox | In an ordinary pod on the same node |
|---|---|---|
| `uname -rv` | The guest's own kernel build | The node's kernel build |
| `cat /proc/uptime` | Seconds, matching the pod's age, because the VM booted with the pod | The node's uptime |
| `ls /sys/block` | Virtio devices (`vda`, `vdb`), plus the `dm-` and `loop` devices of the encrypted overlay | The instance's `nvme` devices |
| `cat /sys/class/dmi/id/product_name` | The VM in the sandbox | The EC2 instance type |

The kernel *version* can be the same in both; it is the build and the boot that differ. The
runtime class on the pod shows what was asked for, not what ran, so it supports the claim
without proving it. The [hello sandbox](../getting-started/hello-sandbox/README.md) page
introduces these readings.

## The shared files

| File | What it is |
|---|---|
| [`_shared/confidential-profile.yaml`](_shared/confidential-profile.yaml) | The generator profile the samples pass to `--profile`: the confidential posture, reduced to the fields the current preview guest's policy schema defines |
| [`_shared/kms-key-policy.json`](_shared/kms-key-policy.json) | The key policy template described above, with placeholders a setup script fills in |
| [`_shared/pod-identity/role-trust-policy.json`](_shared/pod-identity/role-trust-policy.json) | The Pod Identity role trust policy, scoped to one cluster, namespace and service account |

Each template keeps its explanation in a `_comment` key, which a setup script drops before
passing the document to AWS.

## The samples

- [encrypted-image](encrypted-image/README.md): an image whose every layer is ciphertext in
  Amazon ECR, decrypted inside the sandbox by the guest image runtime after KMS checks the
  attestation. The workload image carries no decryption code.

Two more are planned, both calling the attested decrypt from the application itself: a
secret read from AWS Secrets Manager, and an encrypted file read from Amazon S3. See the
[roadmap](https://github.com/aws-samples/sample-eks-nitro-sandbox/blob/main/docs/ROADMAP.md).

## Before you run one

Each sample's page lists what it needs, and they all share the
[prerequisites](../README.md#prerequisites) on the home page: a cluster with the
`confidential-sandbox` runtime class, and the policy generator on your `PATH`. The Amazon
EKS User Guide, *Cedar policies*, names the generator and says how to obtain it.
