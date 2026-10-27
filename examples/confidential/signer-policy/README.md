# Trust an image by its signer, not its digest

A software provider ships you a container image and keeps shipping new versions of it. You
run it in your own cluster, in a confidential sandbox, and you want each new release to
start without you doing anything first. That is what this page buys you: **configure the
provider's signing profile once, and every release they sign afterwards runs under the
policy you already have.** No policy regenerated, no annotation edited, no digest looked up.

What you give up for it, and what you keep, is set out below, because the trade is real and
narrow rather than free.

Everything here about the image pin and the signer option is a property of
`confidential-sandbox` and the Cedar policy generator, so it applies to any confidential
pod. The workload below is deliberately dull: it exists only to make the mechanism visible,
and this page is the Confidential section's reference for the mechanism itself.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page and the [Confidential section page](../README.md), which covers the trust
boundary these samples share. Two samples lead into this one:

- [cedar-policy](../../policy/cedar-policy/README.md) generates a Cedar policy for a
  `confidential-sandbox` pod and shows the guest enforce it.
- [hello sandbox](../../getting-started/hello-sandbox/README.md) introduces the readings
  that show a pod ran in a sandbox.

The commands below use files from this repository, so clone it if you have not already:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/confidential/signer-policy
cp .env.example .env    # then fill in CLUSTER_NAME, AWS_REGION and the two releases
```

On your own machine the scripts need the AWS CLI signed in to the account that holds the
cluster, `kubectl`, `jq`, `gzip`, `base64`, [Docker](https://docs.docker.com/get-docker/),
the [Notation CLI](https://github.com/notaryproject/notation) with the AWS Signer plugin
installed ([AWS Signer container workflow](https://docs.aws.amazon.com/signer/latest/developerguide/container-workflow.html)),
and the Cedar policy generator the Amazon EKS User Guide names
`eks-nitro-sandbox-genpolicy`. The scripts take the generator from a `GENPOLICY` variable,
so pass the name your copy has if it differs. The scripts run against your current
`kubectl` context; set `KUBE_CONTEXT=<your cluster's context>` and they pass `--context` on
every call and never change your current context.

A run stores two small images and two signatures in Amazon ECR, billed as ECR storage, and
runs one sandboxed pod while the sample is up. There is no additional charge for AWS Signer
used with Amazon ECR.

## The choice confidential mode gives you

**A confidential pod is pinned to one exact image, by default.** Generate a policy for a
pod with `runtimeClassName: confidential-sandbox` and the policy names the digest the image
resolved to. The guest will create that container and no other. Nothing asks for this: it
is what the `confidential` posture is, and the Amazon EKS User Guide describes that profile
as pinning all container admission fields, image digests among them (*Cedar policies*). It
is the tightest posture available, and it is the one you get without choosing anything.

<!-- FIGURE 1 -->

It is also the posture that costs you something, and here is where that bites. Picture two
companies: one writes the software, the other runs it on its own EKS cluster. The provider
would rather the operator could not read its image; the operator would rather the provider
could not read its data. A confidential sandbox suits them both. But every release the
provider cuts is a new digest, so under the default every release means the operator
regenerating the policy and editing the pod before anything can start. The provider ships;
the operator re-pins. That is the treadmill.

Confidential mode gives you one documented way off it, and only one: instead of naming a
digest, the policy can say **run any image signed by a signer I trust**.

<!-- FIGURE 2 -->

**Use the profile-level signing ARN, not a version ARN.** A profile-level ARN,
`arn:aws:signer:REGION:ACCOUNT:/signing-profiles/NAME`, matches any version of the signing
profile, because the guest's agent presents both profile-level and version-level ARNs to
the policy. So the provider can rotate its signing certificate and the operator's policy
keeps working. A full version ARN pins one rotation and stops working at the next one,
which is the kind of breakage nobody tells the operator about in advance.

The walkthrough below shows both halves of the choice on one cluster: the signer-based
policy admitting release one and then release two, a different image under a new tag, with
nothing regenerated; and the default digest-pinned policy refusing that same release two.

**The provider and the operator are two roles here, not two accounts.** One reader runs
both halves of this walkthrough in one AWS account, signing as the provider and running the
pod as the operator. Nothing on this page is evidence about a cross-account setup.

## The flags that change image trust

These are the generator's own descriptions, from `eks-nitro-sandbox-genpolicy --help`.

| Flag | What the generator says it does |
|---|---|
| `--require-signatures` | "Require verified image signatures". The matching `--no-require-signatures` is "Do not require image signatures". |
| `--require-any-signer <ARN>` | "Require a verified image signature from any of the given AWS Signer signing profile ARNs (repeatable, OR logic). The image must be signed by at least one of these profiles. Use the profile-level ARN (without version suffix) [...] The agent presents both profile-level and version-level ARNs in the Cedar context, so profile-level ARNs match any version". |
| `--require-all-signers <ARN>` | "Require verified image signatures from all of the given AWS Signer signing profile ARNs (repeatable, AND logic). The image must be signed by every listed profile. Use the profile-level ARN (without version suffix) to match any version, or the full version ARN to pin to a specific certificate rotation". This is how you require co-signing. |
| `--skip-image-ref-container <NAME>` | "Omit the image_ref constraint for the named container (repeatable). Use when image trust is established via [a signer flag] instead of pinning to a specific image reference". |
| `--no-pin-image` | "Do not pin the container image ref", for every container rather than a named one. The matching `--pin-image` is "Pin the container image ref". |

Four things about them change what you should write, and each was measured against the
generator rather than assumed.

- **`--require-signatures` on its own is refused.** It needs at least one signer flag:
  `error: require_signatures is enabled but no --require-any-signer or
  --require-all-signers provided`.
- **A signer flag on its own does not drop the digest pin.** Passing `--require-any-signer`
  alone produces a policy that requires *both* the pinned digest and the signature. That is
  a tighter policy, and a reasonable one, but it still has to be regenerated for every
  release. Dropping the pin is what `--skip-image-ref-container` or `--no-pin-image` is for.
- **`--skip-image-ref-container` writes its own warning into the policy**, which
  `--no-pin-image` does not: the generated Cedar carries the comment
  `// WARNING: image_ref not checked; any image signed by the trusted signers will be
  allowed`. The two have the same effect on a single-container pod, and this sample uses
  `--skip-image-ref-container` so that the policy a reader reads says what was traded away.
- **The help for `--skip-image-ref-container` names a flag that does not exist.** Where it
  says image trust is established "via" a signer flag, it gives a flag name the generator
  does not have, so the quotation in the table is edited at exactly that point and nowhere
  else. The two real flags are `--require-any-signer` and `--require-all-signers`.

## Versions

| Component | This run |
|---|---|
| `eks-nitro-sandbox-genpolicy` | Reports no version string of its own. What it pinned is in the generated policy, which step 3 reads back. |
| Notation CLI ([notaryproject/notation](https://github.com/notaryproject/notation/releases)) | 1.3.1 |
| AWS Signer plugin for Notation | 1.0.2292 |
| AWS Signer signing platform | `Notation-OCI-SHA384-ECDSA` |
| Docker | 25.0.14 |
| Base image for the provider's releases | `public.ecr.aws/amazonlinux/amazonlinux:minimal`, by tag rather than digest, so an unrelated rebuild of the base changes the releases' digests too |

The AWS Signer plugin is published as a `latest` artifact rather than a fixed version
string, so the version above is what it resolved to at run time, read with
`notation plugin ls`.

## Files

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile) | The provider's application image, built once per release with a `RELEASE` build argument |
| [`deploy/pod.yaml`](deploy/pod.yaml) | The pod: `confidential-sandbox`, and as little else as the mechanism allows |
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
policy admits, not what the workload does. Here is the container, from
[`deploy/pod.yaml`](deploy/pod.yaml):

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
command that prints the release and the guest's own kernel. Four details are load-bearing,
and the file says why beside each. `imagePullPolicy: Always` makes the guest prepare and
verify the image on every start, which is the thing being shown. The `hostname` is set
explicitly because the generated policy pins it, and the digest-pinned arm later needs a
pod that differs from this one in the image and nothing else. Both `AWS_REGION` and
`AWS_DEFAULT_REGION` are declared because a policy generated with `--with-pod-identity`
expects both in the pinned environment, and the webhook injects the second only when the
first is already there. The pod does set CPU and memory requests, which most samples here
avoid: the guest unpacks every image layer inside the sandbox before the container starts,
and the smallest default sandbox has nowhere to put them.

There is no `network-isolated` annotation, and there cannot be: signature verification
needs to reach the AWS Signer endpoint, and a pod that sets that annotation "cannot use
image signature verification, because Pod Identity credentials and the Signer endpoint are
both unreachable" (Amazon EKS User Guide, *Cedar policies*).

**Step 2: The operator sets up once.** `scripts/setup.sh` creates the AWS Signer signing
profile and the ECR repository, has the provider build, push and sign release one, gives
the pod its role, generates both policies, and starts the pod under the signer-based one.
Every AWS resource it creates is tagged `ManagedBy`, and it reuses only a resource carrying
that tag, so it cannot touch another demo's resources in a shared account.

Signature verification is the one reason this pod needs AWS credentials at all. The guest
calls AWS Signer to check revocation before it admits a container, using the pod's own
role: the Amazon EKS User Guide requires `signer:GetSigningProfile` and
`signer:GetRevocationStatus` on it, and states that if either call fails or returns a
permission error, verification fails closed and the agent denies container creation
(*Cedar policies*). The guide lists the actions and does not say how to scope them. Scoping
them as narrowly as this is **this sample's own choice**, in
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

`GetRevocationStatus` takes no resource type, which is why it is on `*`. The role holds
nothing else: no ECR, no KMS, no write anywhere. `setup.sh` checks that, failing if the role
carries any other inline or attached policy, so a role adopted from an earlier run cannot
quietly bring extra permissions with it.

```bash
cp .env.example .env     # then edit CLUSTER_NAME, AWS_REGION and the two releases
./scripts/setup.sh
```

Abridged: the Docker build and layer-push lines are left out.

```text
== 1/7 check the cluster and read the identity ==
  kube context: <KUBE_CONTEXT>
  account <ACCOUNT_ID>, region us-west-2, cluster <CLUSTER_NAME>

== 2/7 ensure the AWS Signer signing profile ==
  created signing profile nitro_sample_signed_release (Notation-OCI-SHA384-ECDSA)

== 3/7 ensure the ECR repository ==
  created ECR repository nitro-sample-signer-policy (IMMUTABLE tags)

== 4/7 the provider builds, pushes and signs release 1.0.0 ==
  AWS Signer plugin version: 1.0.2292
1.0.0: digest: sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991 size: 736
Successfully signed <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy@sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991
  pushed and signed nitro-sample-signer-policy:1.0.0
  digest: sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991

== 5/7 give the pod a role that can only check this profile's revocation status ==
  created IAM role nitro-sample-signer-policy-verify
namespace/signer-policy-sample created
serviceaccount/signer-policy-pod created
  created the Pod Identity association for signer-policy-pod

== 6/7 generate the two policies from the same pod spec ==
info: fetching image configs from the registry to resolve pin_image, pin_working_dir, pin_identity, pin_args, pin_env (pulling layers for pin_identity)
info: fetching image config for <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy:1.0.0
  signer policy: .../tmp/signer-policy/policy.signer.yaml
  digest-pinned policy: .../tmp/signer-policy/policy.pinned.yaml (pins sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991)

== 7/7 start the pod under the signer policy ==
pod/signer-policy-demo created

signer-policy-demo is Ready on release 1.0.0, admitted because it is signed.
```

**Step 3: Read the two policies.** `setup.sh` generates both from the same pod spec and
decodes each into readable Cedar under the repository's `tmp/`. The annotation itself is a
gzipped, base64 string, so it is not readable by eye.

Both are generated from
[`../_shared/confidential-profile.yaml`](../_shared/confidential-profile.yaml), the profile
the Confidential samples share, and that profile is what makes this page's mechanism
possible: it pins every container admission field, which is why there is an image pin here
to relax in the first place; it allows log reading, which is how the steps below read the
container's own output, given that it denies exec; and it leaves out the two fields the
preview guest's policy schema does not define yet, which the generator's built-in
`confidential` profile would emit and the guest would then reject. `--with-pod-identity`
adds the projected volume the Pod Identity webhook injects to the mount set the policy
expects, which is what lets the credentials the verification uses reach the pod at all.

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

There is no `--image-architecture` here, which is worth a word because it is easy to reach
for: that flag narrows a multi-arch image index to one architecture, and the provider's
image is built for a single platform, so it is one manifest rather than an index. Passing
it makes the generator stop with `user requested specific architecture amd64 for a
non-index image`.

The two policies differ in exactly one way, and the diff between them is the point of the
sample. The substitution appears twice because the image is named in two permits,
`PrepareImage` and `CreateContainer`: the digest-pinned policy requires the exact
`image_ref` in both, and the signer-based one requires a verified signer in both instead.

```text
$ diff tmp/signer-policy/policy.pinned.yaml tmp/signer-policy/policy.signer.yaml
10c10,11
<       context.image_ref == "<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy@sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991" &&
---
>       // WARNING: image_ref not checked; any image signed by the trusted signers will be allowed
>       context.image_signers.contains("arn:aws:signer:us-west-2:<ACCOUNT_ID>:/signing-profiles/nitro_sample_signed_release") &&
122c123,124
<       context.image_ref == "<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy@sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991"
---
>       // WARNING: image_ref not checked; any image signed by the trusted signers will be allowed
>       context.image_signers.contains("arn:aws:signer:us-west-2:<ACCOUNT_ID>:/signing-profiles/nitro_sample_signed_release")
```

Here is the whole `PrepareImage` permit from the signer-based policy, which is what the
guest evaluated before it prepared each release:

```text
  // PrepareImage: <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy@sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991
  permit(
      principal,
      action == Agent::Action::"PrepareImage",
      resource
  )
  when {
      // WARNING: image_ref not checked; any image signed by the trusted signers will be allowed
      context.image_signers.contains("arn:aws:signer:us-west-2:<ACCOUNT_ID>:/signing-profiles/nitro_sample_signed_release")
  };
```

**The digest on that first line is a comment, not a constraint.** The generator records the
image the policy was generated from above each permit, so release one's digest is still
written in a policy that no longer checks it. Read the `when` block for what is enforced;
`setup.sh` checks for `image_ref ==` rather than searching for the digest for this reason.

**Step 4: The pod is running on release one.** The confidential profile denies exec, so the
container prints its evidence at start-up and `kubectl logs` reads it, which the policy
permits. The release it reports comes from a file in the image, so it is the image talking
and not the manifest:

```bash
kubectl -n signer-policy-sample logs signer-policy-demo
kubectl -n signer-policy-sample get pod signer-policy-demo \
  -o custom-columns=NAME:.metadata.name,RC:.spec.runtimeClassName,IMAGE:.spec.containers[0].image
```

```text
release: 1.0.0
kernel:  6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
uptime:  33.46s
disks:   dm-0 dm-1 dm-2 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 vda vdb vdc
signer-policy-ready

NAME                 RC                     IMAGE
signer-policy-demo   confidential-sandbox   <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy:1.0.0
```

The kernel build, the uptime and the disk list are what show it ran in a sandbox rather
than as an ordinary pod. Running the same three readings in an ordinary pod on the same
cluster, from the same image, gives a different answer to each of them:

```text
kernel:  6.18.54 #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026
uptime:  125299.64s
disks:   dm-0 nvme0n1 nvme1n1 zram0
```

The kernel *version* is the same, `6.18.54`, which is why it is not evidence on its own.
The build is not: `#1` built at 17:38 in the sandbox against `#2` built at 00:16 on the
node. The sandboxed pod's uptime of 33 seconds is its own VM's, booted with the pod, where
the ordinary pod reports the node's 125,299 seconds. And the sandbox's disks are the
guest's virtio devices, `vda`, `vdb` and `vdc`, where the ordinary pod sees the instance's
`nvme` devices.

**Step 5: The provider ships the next release.** `scripts/new-version.sh` builds a different
image, pushes it under the second release's tag, signs it with the same profile, and
restarts the pod on that tag carrying **the same policy annotation**. It refuses to go on
if the annotation is not the exact string `setup.sh` generated, or if the new pod differs
from the approved one anywhere the policy pins, because either would mean the pod starting
proved something else.

```bash
./scripts/new-version.sh
```

Abridged in the same way: the build and layer-push lines are left out.

```text
== 1/4 the provider builds, pushes and signs release 1.1.0 ==
1.1.0: digest: sha256:db32b50088a6138bc7dab2d78837044f97d09062129581ab3983e261ef20b54e size: 736
Successfully signed <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy@sha256:db32b50088a6138bc7dab2d78837044f97d09062129581ab3983e261ef20b54e
  release 1.0.0 was sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991
  release 1.1.0 is  sha256:db32b50088a6138bc7dab2d78837044f97d09062129581ab3983e261ef20b54e

== 2/4 point the pod at the new tag, with the policy untouched ==
  policy annotation sha256: 6bd0407815364e80f4c15acde7eff975fdd01a0f3b00942d168b4f5593020e3d (unchanged since setup.sh)
  the spec differs from the approved pod in the image tag and nothing else

== 3/4 restart the pod on the new release ==
pod/signer-policy-demo created

== 4/4 read back what is running ==
NAME                 READY   IMAGE                              IMAGEID
signer-policy-demo   true    .../nitro-sample-signer-policy:1.1.0   ...@sha256:db32b50088a6138bc7dab2d78837044f97d09062129581ab3983e261ef20b54e

signer-policy-demo is Ready on release 1.1.0, under the policy generated for release 1.0.0.
Nothing was regenerated: the annotation is the same string, sha256 6bd0407815364e80f4c15acde7eff975fdd01a0f3b00942d168b4f5593020e3d.
```

The `IMAGE` and `IMAGEID` columns are abridged to their last part so the table fits; the
registry prefix is the same as everywhere else on this page.

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
== 1/3 confirm the pinned policy pins release 1.0.0, not release 1.1.0 ==
  it pins sha256:ff38cb18774c9a86c9eafe7ea0b8d4631233f09bfec1fc74da65c6e432a6f991 and does not mention sha256:db32b50088a6138bc7dab2d78837044f97d09062129581ab3983e261ef20b54e

== 2/3 start the pinned pod on release 1.1.0's image ==
  the spec differs from the approved pod in the image tag and the policy only
pod/signer-policy-pinned created

== 3/3 wait for the guest to refuse it ==
NAME                   READY   STATUS              RESTARTS   AGE
signer-policy-pinned   0/1     RunContainerError   0          36s

failed to create containerd task: failed to create shim task: Others("Other: prepare_image: rpc status: Status { code: PERMISSION_DENIED, message: \"policy denied Agent::Action::\\\"PrepareImage\\\" for image \\\"<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-signer-policy@sha256:db32b50088a6138bc7dab2d78837044f97d09062129581ab3983e261ef20b54e\\\" reasons=[] errors=[]\", details: [], special_fields: SpecialFields { unknown_fields: UnknownFields { fields: None }, cached_size: CachedSize { size: 0 } } }")

The digest-pinned policy refused release 1.1.0, which it had never seen.
```

`policy denied Agent::Action::"PrepareImage"` is the guest naming the action its policy
refused, and the digest in the message is release 1.1.0's. So the image never reached a
container: the refusal came at the point the guest prepares the image, which is the same
permit the signer-based policy admitted both releases under.

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
profile, the namespace configuration and the sysctls, and it still denies exec and stdin.
So the trade is narrower than "the policy stops checking the image":

- **What the provider gains** is the freedom to change the image's *content* without the
  operator doing anything.
- **What the provider does not gain** is the freedom to change the container's
  *configuration*. A release whose image set a different `WORKDIR`, a different `USER` or a
  different environment variable would be refused by this policy even though it is signed,
  because those are pinned from the release the policy was generated for. That is worth
  agreeing with a provider up front, and it is why this sample's two releases differ in
  their content and in nothing else.
- **What the operator gives up is certainty about which bytes run.** A digest pin tells you
  exactly one image may start. A signer constraint tells you the image came from a signer
  you trust, and the provider decides what is in it.

**A signer constraint establishes provenance, not safety.** Configuring it says "I accept
releases from this provider", not "I have checked this build". If what you need is
certainty about exact bytes, the digest pin is the right choice and the cost is regenerating
the policy for every release. Both are legitimate; which one fits is a judgement about how
much you trust the provider's release process, and only you can make it.

## Good to know

- **The policy is not what gives the pod its network.** Both modes run pods with full
  network access unless the pod sets `sandbox.amazonaws.com/network-isolated` (Amazon EKS
  User Guide, *Isolated and confidential pods overview*), so this pod has a network because
  it does not set that annotation. The Cedar policy governs container admission, runtime
  operations such as exec and log reading, and the IMDS surrogate. The Amazon Time Sync
  Service and the EKS Pod Identity Agent in particular are not policy-controlled: the
  sandbox always reaches them directly (*Cedar policies*), which is why the credentials the
  verification uses arrive without the policy granting them. To restrict where this pod can
  connect, see the [network policy](../../isolation/network-policy/README.md) sample.
- **A canceled signing profile still verifies.** AWS Signer treats `CancelSigningProfile` as
  administrative retirement rather than trust withdrawal, so signatures from a canceled
  profile are still accepted; `RevokeSigningProfile` is what withdraws trust (Amazon EKS
  User Guide, *Cedar policies*). Worth knowing, because the clean up cancels the profile.
- **A policy is mandatory in confidential mode.** The runtime class enforces a strict
  default-deny posture, so a pod with no `sandbox.amazonaws.com/policy` annotation does not
  start. There is no "no policy" option to compare against, which is the other reason the
  digest-pinned arm is what the signer policy is measured against.
- **The policy is measured into PCR17, and the measurement does not change here.** Because
  the policy is never regenerated, its measurement stays the same across both releases. If
  you gate a KMS key on it, as the [encrypted image](../encrypted-image/README.md) sample
  does, that gate keeps working through a release the policy has never seen, which is the
  same benefit in another place.
- **An encrypted image can carry a signature too.** Keeping the provider's image unreadable
  to the operator is the other half of the arrangement this page describes, and the
  [encrypted image](../encrypted-image/README.md) sample shows that mechanism, with the
  layer key released only to an attested sandbox. A policy can require both. This sample
  stays on the signature so that it is the only thing moving.
- **The repository has `IMMUTABLE` tags**, so a release tag cannot be overwritten. To run
  the sample again without deleting the repository, set two release names it does not
  already hold.

## Clean up

Set the variables again in a new shell if needed (the scripts read `.env`). Remove the
pinned arm's pod first if you ran it, then the rest:

```bash
./scripts/pinned-arm.sh --delete
./scripts/clean.sh                          # the pods, the namespace, the Pod Identity association
./scripts/clean.sh --delete-aws-resources   # also the ECR repository, the IAM role, and CANCEL the signing profile
```

```text
$ ./scripts/pinned-arm.sh --delete
pod "signer-policy-pinned" deleted from signer-policy-sample namespace

$ ./scripts/clean.sh

== 1/5 the pods and the namespace ==
  deleted pod signer-policy-demo (if it was there)
  deleted pod signer-policy-pinned (if it was there)
  deleted namespace signer-policy-sample

== 2/5 the Pod Identity association ==
  deleted Pod Identity association <ASSOCIATION_ID>

== 3/5 AWS resources kept ==
  the ECR repository, the IAM role and the signing profile are still there.
  Remove them with: ./scripts/clean.sh --delete-aws-resources

Clean up complete.
AWS resources kept; see --delete-aws-resources above.

$ ./scripts/clean.sh --delete-aws-resources

== 1/5 the pods and the namespace ==
  namespace signer-policy-sample is already gone

== 2/5 the Pod Identity association ==
  no Pod Identity association for signer-policy-sample/signer-policy-pod

== 3/5 the IAM role ==
  deleted IAM role nitro-sample-signer-policy-verify

== 4/5 the ECR repository ==
  deleted ECR repository nitro-sample-signer-policy and the images and signatures in it

== 5/5 the signing profile ==
  canceled signing profile nitro_sample_signed_release (the name stays taken; set a new SIGNING_PROFILE in .env to run again)

Clean up complete.
```

`clean.sh` deletes only what carries this sample's mark: it checks the namespace label
before it removes anything inside the namespace, and each AWS resource for its `ManagedBy`
tag. A lookup it cannot complete counts as "could not determine", which is a failure and
never "gone", so it reports what it could not do and exits non-zero.

AWS Signer has no hard delete, so `--delete-aws-resources` cancels the signing profile and
confirms the status reads `Canceled`. A canceled profile lingers until its signatures expire
(about 141 months by default) and AWS Signer refuses to reuse the name, so to set the sample
up again afterwards, set a new `SIGNING_PROFILE` in `.env` first; `setup.sh` stops with that
instruction if the old name is still there. To remove the namespace and the cluster, follow
the [hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
