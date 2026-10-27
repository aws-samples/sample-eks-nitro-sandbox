# Trust an image by its signer, not its digest

This page is the Confidential section's reference for signer-based image trust: what the
default image pin is, what a signer constraint replaces it with, which generator flags
write it, and what you keep and give up by choosing it. The benefit it buys is concrete,
and it is what the walkthrough measures: **an operator can keep running a provider's new
releases without re-pinning anything.** The workload here is deliberately dull, because it
is only there to make the mechanism visible.

Everything on this page about the default pin and the signer relaxation is a property of
`confidential-sandbox` and the policy generator, so it applies to any confidential pod, not
only to the one below.

**A confidential pod is pinned to one exact image, by default.** Generate a Cedar policy
for a pod with `confidential-sandbox` and the policy it writes names the digest the image
resolved to, and the guest will create that container and no other. That default belongs
to confidential mode, not to this sample: it is the tightest posture available, and it is
what you get without asking for anything.

It is also the posture that costs you something. Every new release of an image is a new
digest, so under the default every release means regenerating the policy and editing the
pod before anything can start. Confidential mode gives you one documented way to trade
that away, and only that: instead of naming a digest, the policy can say **run any image
signed by a signer I trust**. Configure the signing profile once and the provider can ship
release after release while nothing on your side changes.

The walkthrough below shows the choice, both halves of it, on one cluster:

- the default policy, pinned to release 1.0.0's digest, **refusing** release 1.1.0, which
  is what the pin is for and what it costs;
- the signer-based policy admitting release 1.0.0 and then release 1.1.0, a different image
  under a new tag signed by the same profile, with no policy regenerated and the annotation
  the same string byte for byte.

**Omitting the digest changes one thing and leaves the rest of the policy standing.**
[What the signer policy still constrains](#what-the-signer-policy-still-constrains) sets
out exactly which constraints remain, because the trade is narrow and named rather than a
general loosening. The short version: a signer constraint tells you where an image came
from, not that it is safe, and it no longer tells you which exact bytes are running.

Why anyone wants the relaxation, as illustration rather than as the mechanism: a software
provider ships you an image and keeps shipping new versions, you run it in your own
cluster, and you each want your own side kept to yourselves. Two companies can run one
confidential sandbox between them on that basis, and the signer option is what keeps the
operator off the re-pinning treadmill while they do. The provider and the operator are two
roles, not two accounts: one reader runs both halves of this walkthrough in one account,
signing as the provider and running the pod as the operator, so nothing here is evidence
about a cross-account setup.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. The
[Confidential sandboxes](../README.md) section page covers what these samples share. The
commands below use files from this repository, so clone it if you have not already, and run
them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/confidential/signer-policy
```

This sample needs a host with [Docker](https://docs.docker.com/get-docker/), the
[Notation CLI](https://github.com/notaryproject/notation) with the AWS Signer plugin
installed ([AWS Signer container workflow](https://docs.aws.amazon.com/signer/latest/developerguide/container-workflow.html)),
the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
signed in to the account that holds the cluster, and the Cedar policy generator the
Amazon EKS User Guide names `eks-nitro-sandbox-genpolicy`. The scripts take the generator
from a `GENPOLICY` variable, so pass the name your copy has if it differs. A run stores two
small images and two signatures in Amazon ECR, billed as ECR storage; there is no
additional charge for AWS Signer used with Amazon ECR. Copy `.env.example` to `.env` (git
ignores it) and set your cluster name, Region and the two release names. The scripts run
against your current `kubectl` context; set `KUBE_CONTEXT=<your cluster's context>` and
they pass `--context` on every call, and never change your current context.

## Overview

The provider's side is ordinary: build an image, push it to Amazon ECR, sign it with
[AWS Signer](https://docs.aws.amazon.com/signer/latest/developerguide/Welcome.html) through
the Notation CLI. The signature is stored in the registry beside the image. The operator's
side is one decision, taken once, in the Cedar policy the pod carries.

- **The guest is what checks the signature, not the workload.** The agent inside the Nitro
  sandbox verifies the Notation signature and checks revocation before it creates the
  container, and refuses to create it if verification fails or the image is unsigned
  (Amazon EKS User Guide, *Isolated and confidential pods*). Nothing in the image does the
  checking, so there is no verifier for a tampered image to subvert.
- **The policy names the signing profile, and that is the whole configuration.** The
  generated policy drops the image digest for the named container and requires instead that
  the verified signers include the profile ARN you gave it.
- **A profile-level ARN survives a certificate rotation.** The generator's help is
  explicit: "The agent presents both profile-level and version-level ARNs in the Cedar
  context, so profile-level ARNs match any version." A full version ARN pins one rotation
  and stops working at the next one, which nobody would necessarily tell the operator
  about.
- **The pod's AWS role can do one thing.** Verification calls AWS Signer to check
  revocation status, so the pod gets a role through EKS Pod Identity that holds
  `signer:GetSigningProfile` on this sample's profile and `signer:GetRevocationStatus`, and
  nothing else. That role is the limit this sample creates, and
  [step 2](#step-2-the-operator-sets-up-once) shows the whole document.
- **The provider's image is not encrypted here.** Keeping it unreadable to the operator is
  the other half of the arrangement, and the
  [encrypted image](../encrypted-image/README.md) sample shows that mechanism, with the
  layer key released only to an attested sandbox. The two compose: an encrypted image can
  carry a signature, and the policy can require both. This sample stays on the signature so
  that it is the only thing moving.

*Figure 1: Image trust by signer rather than by digest. The provider builds each release,
pushes it to Amazon ECR and signs it with AWS Signer, so each release has its own digest
and its own signature. The operator generates one Cedar policy that names the signing
profile instead of a digest, and attaches it to the pod. The guest verifies the signature of
whichever release the pod points at and admits it, so release 1.1.0 starts under the policy
that was generated for release 1.0.0.*

![The software provider builds release 1.0.0 and release 1.1.0, pushes both to one Amazon ECR repository under their own tags, and signs each with the same AWS Signer signing profile, so each release has a different digest and its own Notation signature in the registry. The operator runs eks-nitro-sandbox-genpolicy once, with require-signatures, require-any-signer naming the profile-level ARN, and skip-image-ref-container, which produces a Cedar policy that constrains image_signers and does not constrain image_ref. That one policy is attached to the pod as the sandbox policy annotation and is never regenerated. Inside the Nitro sandbox the agent verifies the signature of whichever release the pod points at, calls AWS Signer to check revocation status using the pod's EKS Pod Identity role, and creates the container. A second pod carrying the default digest-pinned policy, which pins release 1.0.0's digest, is refused when it is pointed at release 1.1.0.](images/figure-1-signer-policy.png)

## The flags that change image trust

These are the generator's own descriptions, from `eks-nitro-sandbox-genpolicy --help`.

| Flag | What the generator says it does |
|---|---|
| `--require-signatures` | "Require verified image signatures". The matching `--no-require-signatures` is "Do not require image signatures". |
| `--require-any-signer <ARN>` | "Require a verified image signature from any of the given AWS Signer signing profile ARNs (repeatable, OR logic). The image must be signed by at least one of these profiles. Use the profile-level ARN (without version suffix) [...] The agent presents both profile-level and version-level ARNs in the Cedar context, so profile-level ARNs match any version". |
| `--require-all-signers <ARN>` | "Require verified image signatures from all of the given AWS Signer signing profile ARNs (repeatable, AND logic). The image must be signed by every listed profile. Use the profile-level ARN (without version suffix) to match any version, or the full version ARN to pin to a specific certificate rotation". This is how you require co-signing. |
| `--skip-image-ref-container <NAME>` | "Omit the image_ref constraint for the named container (repeatable). Use when image trust is established via [a signer flag] instead of pinning to a specific image reference". |
| `--no-pin-image` | "Do not pin the container image ref", for every container rather than a named one. The matching `--pin-image` is "Pin the container image ref". |

Four things about them are worth knowing before you write a command, and all four were
measured against the generator rather than assumed.

- **`--require-signatures` on its own is refused.** It needs at least one signer flag:
  `error: require_signatures is enabled but no --require-any-signer or
  --require-all-signers provided`.
- **A signer flag on its own does not drop the digest pin.** Passing `--require-any-signer`
  alone produces a policy that requires *both* the pinned digest and the signature. That is
  a tighter policy, and a perfectly reasonable one, but it still has to be regenerated for
  every release. Dropping the pin is what `--skip-image-ref-container` or `--no-pin-image`
  is for.
- **`--skip-image-ref-container` writes its own warning into the policy**, which
  `--no-pin-image` does not: the generated Cedar carries the comment
  `// WARNING: image_ref not checked; any image signed by the trusted signers will be
  allowed`. The two have the same effect on a single-container pod, and this sample uses
  `--skip-image-ref-container` so that the policy a reader reads says what was traded away.
- **The help text for `--skip-image-ref-container` names a flag that does not exist.** It
  refers to trust established "via `--require-signer`"; the real flags are
  `--require-any-signer` and `--require-all-signers`. The quotation above is edited for that
  reason, and only that reason.

## Versions

| Component | This run |
|---|---|
| Cedar policy generator (`eks-nitro-sandbox-genpolicy`) | TODO: output from the fresh run |
| Notation CLI ([notaryproject/notation](https://github.com/notaryproject/notation/releases)) | TODO: output from the fresh run |
| AWS Signer Notation plugin | TODO: output from the fresh run |
| AWS Signer signing platform | `Notation-OCI-SHA384-ECDSA` |
| Docker | TODO: output from the fresh run |

The AWS Signer plugin is published as a `latest` artifact rather than a fixed version
string, so the version above is what it resolved to at run time, read with
`notation plugin ls`. The signing platform for Notation and OCI signing is
`Notation-OCI-SHA384-ECDSA`, confirmed with `aws signer list-signing-platforms`.

## Files

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile) | The provider's application image, built once per release with a `RELEASE` build argument |
| [`deploy/pod.yaml`](deploy/pod.yaml) | The pod: `confidential-sandbox`, and nothing in it about the network |
| [`deploy/namespace.yaml`](deploy/namespace.yaml), [`deploy/service-account.yaml`](deploy/service-account.yaml) | The namespace, labelled as this sample's, and the pod's ServiceAccount |
| [`iam/signer-verify-policy.json`](iam/signer-verify-policy.json) | The pod's whole AWS permission: read this signing profile, check revocation status |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | The Pod Identity trust policy, scoped to this cluster, namespace and ServiceAccount |
| [`scripts/setup.sh`](scripts/setup.sh) | The operator's setup and the provider's first release: signing profile, repository, build, sign, role, both policies, start the pod |
| [`scripts/new-version.sh`](scripts/new-version.sh) | The provider's next release, and the pod restarted on it with the policy untouched |
| [`scripts/pinned-arm.sh`](scripts/pinned-arm.sh) | The digest-pinned policy refusing that same release |
| [`scripts/clean.sh`](scripts/clean.sh) | Delete what the sample created, and verify it is gone |
| [`scripts/lib.sh`](scripts/lib.sh) | The helpers the four scripts share |
| [`../_shared/confidential-profile.yaml`](../_shared/confidential-profile.yaml) | The generator profile the Confidential samples share |

**Step 1: The pod.** It is as plain as the mechanism allows, because the subject is what the
policy admits. There is no network-isolated annotation: the guest has to reach the registry
and the AWS Signer endpoint, so a sandbox booted with no network cannot verify a signature
at all. Here is the container, from [`deploy/pod.yaml`](deploy/pod.yaml):

```yaml
spec:
  runtimeClassName: confidential-sandbox
  serviceAccountName: signer-policy-pod
  hostname: signer-policy-demo
  containers:
    - name: app
      image: <IMAGE_URI>
      imagePullPolicy: Always
      env:
        - name: AWS_REGION
          value: <AWS_REGION>
        - name: AWS_DEFAULT_REGION
          value: <AWS_REGION>
```

Trimmed: the file also sets the security context, the resource requests and the start-up
command that prints the release and the guest's own kernel. Four of those lines are
load-bearing and the file says why beside each. `imagePullPolicy: Always` makes the guest
prepare and verify the image on every start, which is the thing being shown. The `hostname`
is set explicitly because the generated policy pins it, and the digest-pinned arm later
needs a pod that differs from this one in the image and nothing else. Both `AWS_REGION` and
`AWS_DEFAULT_REGION` are declared because a policy generated with `--with-pod-identity`
expects both in the pinned environment, and the webhook injects the second one only when the
first is already there.

**Step 2: The operator sets up once.** `scripts/setup.sh` creates the AWS Signer signing
profile and the ECR repository, has the provider build, push and sign release one, gives the
pod its role, generates both policies, and starts the pod under the signer-based one. Every
AWS resource it creates is tagged `ManagedBy`, and it reuses only a resource carrying that
tag, so it cannot touch another demo's resources in a shared account.

The pod's whole AWS permission is
[`iam/signer-verify-policy.json`](iam/signer-verify-policy.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyThisSamplesSigningProfile",
      "Effect": "Allow",
      "Action": "signer:GetSigningProfile",
      "Resource": "arn:aws:signer:<AWS_REGION>:<ACCOUNT_ID>:/signing-profiles/<SIGNING_PROFILE>"
    },
    {
      "Sid": "CheckRevocationStatus",
      "Effect": "Allow",
      "Action": "signer:GetRevocationStatus",
      "Resource": "*"
    }
  ]
}
```

Both actions are needed, and verification fails closed if either call is refused:
`signer:GetSigningProfile` is how the guest learns whether the profile has been revoked, and
`signer:GetRevocationStatus` covers the individual signing job and certificate (Amazon EKS
User Guide, *Isolated and confidential pods*). `GetRevocationStatus` takes no resource type,
which is why it is on `*`. The role holds nothing else: no ECR, no KMS, no write anywhere.
`setup.sh` checks that, failing if the role carries any other inline or attached policy, so
a role adopted from an earlier run cannot quietly bring extra permissions with it.

```bash
cp .env.example .env     # then edit CLUSTER_NAME, AWS_REGION and the two releases
./scripts/setup.sh
```

```text
TODO: output from the fresh run
```

**Step 3: Read the two policies.** `setup.sh` generates both from the same pod spec and
decodes each into readable Cedar under the repository's `tmp/`. The annotation itself is a
gzipped, base64 string, so it is not readable by eye.

The signer-based policy is generated like this, with the profile-level signing ARN:

```bash
eks-nitro-sandbox-genpolicy \
  --profile ../_shared/confidential-profile.yaml --with-pod-identity \
  --image-architecture amd64 \
  --require-signatures \
  --require-any-signer "arn:aws:signer:<AWS_REGION>:<ACCOUNT_ID>:/signing-profiles/<SIGNING_PROFILE>" \
  --skip-image-ref-container app \
  pod.json
```

`--image-architecture amd64` is there because the base image is multi-arch: without it the
generator emits one permit per Linux architecture in the index and stops with
`image config differs between linux/amd64 and linux/riscv64`. The two policies differ in
exactly one place, which is the point of the sample:

```text
TODO: output from the fresh run
```

**Step 4: The pod is running on release one.** Exec is denied by the confidential profile,
so the container prints its evidence at start-up and `kubectl logs` reads it, which the
policy permits. The release it is running comes from a file in the image, so it is the image
talking, not the manifest:

```bash
kubectl -n signer-policy-sample logs signer-policy-demo
kubectl -n signer-policy-sample get pod signer-policy-demo \
  -o custom-columns=NAME:.metadata.name,RC:.spec.runtimeClassName,IMAGE:.spec.containers[0].image
```

```text
TODO: output from the fresh run
```

The kernel build and the disk list are what show it ran in a sandbox rather than as an
ordinary pod. An ordinary pod on the same cluster shows a different kernel build, the
instance's `nvme` devices rather than the guest's virtio ones, and the node's uptime rather
than the pod's:

```text
TODO: output from the fresh run
```

**Step 5: The provider ships the next release.** `scripts/new-version.sh` builds a different
image, pushes it under the second release's tag, signs it with the same profile, and
restarts the pod on that tag carrying **the same policy annotation**. It refuses to go on if
the annotation is not the exact string `setup.sh` generated, or if the new pod differs from
the approved one anywhere the policy pins, because either would mean the pod starting proved
something else.

```bash
./scripts/new-version.sh
```

```text
TODO: output from the fresh run
```

Two digests, two tags, one policy. The `IMAGEID` is read from the running pod rather than
from the registry, so it is the digest the guest actually prepared.

**Step 6: The digest pin refuses the same release.** Without this a reader could not tell a
signer-based policy from no policy at all. `scripts/pinned-arm.sh` starts a second pod with
release two's image under the **default** policy `setup.sh` generated for release one, the
one that pins release one's digest. Everything the policy pins is identical to the approved
pod apart from the image, so a refusal is a refusal of the image:

```bash
./scripts/pinned-arm.sh
```

```text
TODO: output from the fresh run
```

The script fails if that pod becomes Ready, and also fails if it merely did not start
without the guest naming the policy, because a pull failure or an expired credential looks
like "not Ready" too. Delete it when you have read it:

```bash
./scripts/pinned-arm.sh --delete
```

## What the signer policy still constrains

Dropping `image_ref` drops one constraint, not the policy. Under the shared confidential
profile the generated policy still pins the process arguments, the environment, the working
directory, the hostname, the mount set, the user and group IDs, the capabilities, the
security settings, the masked and read-only paths, the seccomp default action, the AppArmor
profile, the namespace configuration and the sysctls, and it still denies exec and stdin. So
the trade is narrower than "the policy stops checking the image":

- **What the provider gains** is the freedom to change the image's *content* without the
  operator doing anything.
- **What the provider does not gain** is the freedom to change the container's
  *configuration*. A release whose image set a different `WORKDIR`, a different `USER` or a
  different environment variable would be refused by this policy even though it is signed,
  because those are pinned from the release the policy was generated for. That is worth
  agreeing with a provider up front, and it is why this sample's two releases differ in
  their content and in nothing else.
- **What the operator gives up is certainty about which bytes run.** A digest pin is the
  tightest constraint available and tells you exactly one image may start. A signer
  constraint tells you the image came from a signer you trust, and the provider decides what
  is in it.

**A signer constraint establishes provenance, not safety.** Configuring it says "I accept
releases from this provider", not "I have checked this build". If what you need is certainty
about exact bytes, the digest pin is the right choice and the cost is regenerating the policy
for every release. Both are legitimate; which one fits is a decision about how much you
trust the provider's release process, and only you can make it.

## Good to know

- **The Cedar policy is what delivers the credentials the verification uses, and it is not
  what makes the network reachable.** The policy controls container admission, the runtime
  operations such as exec and log reading, writes, and the IMDS surrogate. Reaching the
  registry and the AWS Signer endpoint is not policy-controlled: the sandbox always reaches
  the EKS Pod Identity Agent and the Amazon Time Sync Service directly (Amazon EKS User
  Guide, *Isolated and confidential pods*). What the policy does have to account for is the
  projected volume the Pod Identity webhook injects and the credential environment that
  comes with it, which is what `--with-pod-identity` adds. A policy generated without that
  flag for a pod that has a Pod Identity association is refused at container creation,
  because the mount set and the environment it pinned do not match what the webhook
  injected.
- **A sandbox with no network cannot use this at all.** `network-isolated` makes both the
  Pod Identity credentials and the AWS Signer endpoint unreachable, so signature
  verification cannot run (Amazon EKS User Guide, *Isolated and confidential pods
  limitations*). This sample ships no network policy and restricts nothing about where the
  pod can connect. To restrict that, see the
  [network policy](../../isolation/network-policy/README.md) sample.
- **A canceled signing profile still verifies.** AWS Signer treats `CancelSigningProfile` as
  administrative retirement rather than trust withdrawal, so signatures from a canceled
  profile are still accepted; `RevokeSigningProfile` is what withdraws trust. Worth knowing
  because the clean up cancels the profile.
- **A policy is mandatory in confidential mode.** The runtime class enforces strict
  default-deny, so a pod with no `sandbox.amazonaws.com/policy` annotation does not start.
  There is no "no policy" option to compare against here, which is the other reason the
  digest-pinned arm is what the signer policy is measured against.
- **The policy is measured into PCR17, and the measurement does not change here.** Because
  the policy is never regenerated, its measurement stays the same across both releases. If
  you gate a KMS key on it, as the [encrypted image](../encrypted-image/README.md) sample
  does, that gate keeps working through a release the policy has never seen, which is the
  same benefit in another place.
- **The repository has `IMMUTABLE` tags**, so a release tag cannot be overwritten. To run the
  sample again without deleting the repository, set two release names it does not already
  hold.

## Clean up

Set the variables again in a new shell if needed (the scripts read `.env`). Remove the
pinned arm's pod first if you ran it, then the rest:

```bash
./scripts/pinned-arm.sh --delete
./scripts/clean.sh                          # the pods, the namespace, the Pod Identity association
./scripts/clean.sh --delete-aws-resources   # also the ECR repository, the IAM role, and CANCEL the signing profile
```

```text
TODO: output from the fresh run
```

`clean.sh` deletes only what carries this sample's mark: it checks the namespace label before
it removes anything inside the namespace, and each AWS resource for its `ManagedBy` tag. A
lookup it cannot complete counts as "could not determine", which is a failure and never
"gone", so it reports what it could not do and exits non-zero.

AWS Signer has no hard delete, so `--delete-aws-resources` cancels the signing profile and
confirms the status reads `Canceled`. A canceled profile lingers until its signatures expire
(about 141 months by default) and AWS Signer refuses to reuse the name, so to set the sample
up again afterwards, set a new `SIGNING_PROFILE` in `.env` first; `setup.sh` stops with that
instruction if the old name is still there. To remove the namespace and the cluster, follow
the [hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
