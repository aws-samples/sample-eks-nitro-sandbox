# Reproduce the build and verify the KMS gate

A confidential sandbox boots its Cedar policy inside the guest VM and measures it into
PCR17. A KMS key policy that gates on that measurement releases the data key only to a pod
that presents the expected attestation. Because the Cedar policy embeds the image digest,
the measurement is determined entirely by the build.

This blueprint shows the full chain: build an image reproducibly, predict its PCR17 from
the digest, set a KMS key policy that expects that value, run the pod in a confidential
sandbox, and show that any operator can verify every link independently, and that a one-line
source change produces a different measurement the gate refuses.

[Prerequisites](../../README.md#prerequisites) — the same cluster from Getting started, plus
two more tools:

- `eks-nitro-sandbox-genpolicy` — the Cedar policy generator. The Amazon EKS User Guide,
  [*Cedar policies*](https://docs.aws.amazon.com/eks/latest/userguide/confidential-pods-cedar.html),
  explains what it generates and where to get it.
- Docker or Podman, for the Nix build container.

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/confidential/reproducible-build
```

Copy `.env.example` to `.env` and fill in your cluster name and Region. Set `GENPOLICY`
to the path of the policy generator if it is not on `PATH` as `eks-nitro-sandbox-genpolicy`.
Set `KUBE_CONTEXT` if you use a named context.

The generator is a Linux binary. On macOS, or on any machine where it does not run
directly, run it in a container with
[`scripts/genpolicy-container.sh`](scripts/genpolicy-container.sh): set `GENPOLICY_BIN` to
the Linux binary for your machine's architecture (`aarch64` on Apple silicon) and point
`GENPOLICY` at the wrapper, both as absolute paths in `.env`:

```bash
GENPOLICY_BIN=/path/to/eks-nitro-sandbox-genpolicy
GENPOLICY=/path/to/sample-eks-nitro-sandbox/examples/confidential/reproducible-build/scripts/genpolicy-container.sh
```

The wrapper runs the binary in a pinned `amazonlinux:2023` container with your container
runtime (`CONTAINER_RUNTIME`). It mounts the repository at its own path, so the scripts'
paths work unchanged, and mounts only the registry credentials the scripts write for the
generator, read-only.

## Overview

The key idea: an OCI image digest is a fixed point in the build. The Cedar policy generator
reads that digest and the pod manifest, then computes the PCR17 the confidential sandbox
will measure at boot. Write that prediction into a KMS key policy, and the key becomes
inaccessible to any pod whose build differs by even one byte.

This blueprint shows:

- **The same source always produces the same OCI digest.** The Nix flake locks nixpkgs and
  nix2container to pinned commits, names exactly the source files the build reads, and
  removes the random build directory from the binary with a Rust `--remap-path-prefix` flag.
  Two operators on different machines get the same digest from the same commit.
- **The key policy is set once, before the pod starts.** The Cedar policy generator reads
  the pod manifest and the pushed image digest, predicts PCR17, and writes it into the KMS
  key policy. The key is never accessible without that exact measurement.
- **Any operator can verify the chain read-only.** `verify.sh` rebuilds the image from an
  empty Nix store, compares its digest with ECR, predicts PCR17 from the rebuilt digest, and
  checks the prediction against the live key policy. No shared state from `setup.sh` is used.
- **A one-line source change breaks the gate.** Changing the application banner rebuilds to
  a different OCI digest. The generator predicts a different PCR17 for that build. The
  unchanged KMS key refuses the changed pod.
- **The decrypt endpoint is a decryption oracle, within three bounds**, named in the Decrypt
  section below.

*Figure 1: The build chain, the attestation gate, and the independent verify path.*

![The build chain. Left of the diagram: a source box and a nixos/nix build container outside the AWS Cloud, connected by a build arrow. The nix build pushes to Amazon ECR inside the cloud. A policy generator outside the cloud reads the image digest from ECR and feeds the predicted PCR17 to AWS KMS. The KMS key policy gates on that PCR17. Inside an EKS cluster frame and a Nitro sandbox pod frame, a Decrypt service receives the data key on match. Below: a Verifier and a fresh Nix rebuild, with compare-digest arrows to ECR and predict-PCR17 arrows to the generator.](images/architecture.png)

## Versions

| Component | Pin |
|-----------|-----|
| nixpkgs | nixos-26.05 commit `ab5c18fdedfc8f9bbc9d773f10a540790e2787a7` |
| nix2container | commit `42d1df94f001a9416ef08be7b305144074aca9d2` |
| nixos/nix (builder) | `sha256:9b6a776642088021e9251e7cdb47988747008178ca2f7398cb3e1b365bde3372` |
| Rust dependencies | pinned in `src/Cargo.lock` |

Both nixpkgs and nix2container commits are in `flake.lock`. The builder image digest is in
`scripts/build.sh`.

## Files

| File | Purpose |
|------|---------|
| `flake.nix` | Nix flake: the reproducible build definition |
| `flake.lock` | Pinned nixpkgs and nix2container commits |
| `scripts/setup.sh` | Builds the image, creates the KMS key with the full gate, starts the pods |
| `scripts/verify.sh` | Independent read-only verification of the full chain |
| `scripts/decrypt.sh` | Exercises the decrypt endpoint |
| `scripts/changed-source.sh` | Shows the gate refuses a changed build |
| `scripts/debug.sh` | Builds the debug image, runs the debug pod, and shows the production secret stays out of reach |
| `scripts/clean.sh` | Removes everything this blueprint created |
| `scripts/build.sh` | Runs the Nix build inside the pinned container |
| `deploy/pod.yaml` | The confidential-sandbox pod manifest |
| `deploy/plain-pod.yaml` | Ordinary pod for the sandbox-vs-node comparison |
| `deploy/service.yaml` | ClusterIP Service fronting the decrypt endpoint |
| `deploy/production-profile.yaml` | Cedar runtime profile for the production pod: logs and exec denied |
| `deploy/debug-profile.yaml` | Cedar runtime profile for the debug pod: exec allowed |
| `src/` | Rust source for the decrypt service |
| `../confidential/_shared/kms-key-policy.json` | Five-statement KMS key policy template |
| `../confidential/_shared/pod-identity/role-trust-policy.json` | Pod Identity IAM trust policy |

## Step 1: Run the setup.

`setup.sh` runs eight steps from first principles to both pods Ready:

```bash
./scripts/setup.sh
```

Output from a fresh run, abridged where marked `[...]`. The account ID, kube context, key and
association IDs, instance ID and local repository path are replaced with placeholders.

```text
TODO: output from the fresh run
```

The eight steps:

1. Check the tools, the cluster, and the Region.
2. Create the ECR repository (`reproducible-build`, or the name in `REPO_NAME`).
3. Build the image inside the pinned nixos/nix container and push it to ECR.
4. Run the Cedar policy generator to predict PCR17.
5. Create the IAM role with the Pod Identity trust policy.
6. Create the KMS key with the full attestation gate from the start.
7. Create the namespace, the service account, and the Pod Identity association.
8. Apply the confidential-sandbox pod, the Service, and the plain comparison pod; wait for both pods.

Pass `--no-pods` to stop after step 7 and return before the pods start.

## Step 2: How the build stays deterministic.

The Nix flake in `flake.nix` builds the Rust binary and assembles the OCI image. Three
properties keep the output identical on every machine.

**A locked dependency graph.** `flake.lock` pins nixpkgs to a single commit, so the Rust
toolchain, the C runtime, the CA certificates, and every system library come from a fixed
set of store paths. nix2container is pinned to the same commit for the same reason. Any
toolchain upgrade requires an explicit `flake.lock` update that changes the commit and with
it the image digest.

**An explicit source set.** The flake uses `lib.fileset.toSource` to include exactly
`Cargo.toml`, `Cargo.lock`, and the `.rs` source files:

```nix
src = lib.fileset.toSource {
  root = ./src;
  fileset = lib.fileset.unions [
    ./src/Cargo.toml
    ./src/Cargo.lock
    (lib.fileset.fileFilter (file: file.hasExt "rs") ./src/src)
  ];
};
```

A plain `./src` would include every file in the folder. A `.DS_Store` or a stale `target/`
would change the source hash and therefore the image digest.

**A fixed build directory in the binary.** Rust embeds source paths in the binary for panic
messages. Nix builds in a path whose name contains a process ID, so without correction that
path would vary between runs and machines. The flake removes it:

```nix
preBuild = ''
  export RUSTFLAGS="--remap-path-prefix=$NIX_BUILD_TOP=/build"
'';
```

This maps the random path to `/build` before compilation. The resulting binary is the same
regardless of which directory the build ran in. The vendored crate sources also sit under
`NIX_BUILD_TOP`, so their paths in the binary are remapped too.

**A fixed builder container.** `scripts/build.sh` runs the Nix build inside a pinned
`nixos/nix` container, always with `--platform linux/amd64`:

```bash
NIX_IMAGE="nixos/nix@sha256:9b6a776642088021e9251e7cdb47988747008178ca2f7398cb3e1b365bde3372"
```

An Apple Silicon machine runs the same `linux/amd64` image under QEMU emulation as an
x86_64 machine runs natively. Each build starts with an empty `/nix` store, so the sample's
derivations are built from source every time. The nixpkgs toolchain comes from
`cache.nixos.org`.

On non-x86_64 hosts the script adds `filter-syscalls = false` to the Nix configuration.
QEMU cannot load the seccomp BPF filter that Nix installs, and without that setting every
derivation fails to start. Turning it off does not affect content addressing.

**No timestamp in the image.** nix2container writes epoch 1 for all layer timestamps when
no creation time is supplied. The image has no random or time-based metadata.

The result: two operators who run `./scripts/build.sh` on the same commit, one on Apple
Silicon and one on x86_64 Linux, get the same `sha256:...` digest.

## Step 3: The key policy and the Pod Identity role.

**The KMS key policy** has five statements. Its template is in
`examples/confidential/_shared/kms-key-policy.json`.

| Statement | Effect | Principal | Actions |
|-----------|--------|-----------|---------|
| `KeyAdministration` | Allow | Account root | Key management actions. `kms:Decrypt` and `kms:ReEncryptFrom` are intentionally absent: a key administrator who could use `ReEncryptFrom` could wrap the data key under a second, ungated key and decrypt it there. |
| `BuildTimeEncrypt` | Allow | Account root | `kms:Encrypt` only. Any caller in the account can encrypt a value; the ciphertext cannot be decrypted outside an approved sandbox. |
| `AttestedDecryptOnly` | Allow | Pod Identity role | `kms:Decrypt`, conditional on `kms:RecipientAttestation:PCR17` equalling the predicted measurement, and `kms:RecipientAttestation:PCR8:ServiceName` equalling `eks.amazonaws.com`. Both conditions must hold. |
| `DenyUnlessThePolicyMeasurementMatches` | Deny | `*` | `kms:Decrypt` and `kms:ReEncryptFrom` when `PCR17` does not match. A negated condition operator is also true when the key is absent, so a request with no attestation document is caught here too. |
| `DenyUnlessTheAttestationComesFromAnEKSSandbox` | Deny | `*` | `kms:Decrypt` and `kms:ReEncryptFrom` when `PCR8:ServiceName` is not `eks.amazonaws.com`. |

Sources: AWS KMS Developer Guide,
[*AWS KMS condition keys for AWS Nitro Enclaves*](https://docs.aws.amazon.com/kms/latest/developerguide/conditions-nitro-enclaves.html);
Amazon EKS User Guide,
[*Cedar policies*](https://docs.aws.amazon.com/eks/latest/userguide/confidential-pods-cedar.html);
AWS Nitro Enclaves User Guide,
[*Cryptographic attestation support in AWS KMS*](https://docs.aws.amazon.com/enclaves/latest/user/kms.html).

The `Decrypt` call in this blueprint uses the `Recipient` and `CiphertextForRecipient`
parameters, which return the plaintext encrypted to an ephemeral RSA public key the guest
generated and placed inside its attestation document. Only the guest that holds the matching
private key can recover the value. See the AWS KMS API Reference,
[*Decrypt*](https://docs.aws.amazon.com/kms/latest/APIReference/API_Decrypt.html).

**Key policy timing.** The KMS alias ARN is predictable from account ID, Region, and alias
name before the key exists: `arn:aws:kms:<REGION>:<ACCOUNT_ID>:alias/reproducible-build-sample`.
`setup.sh` runs the Cedar policy generator in step 4 and creates the key with the full
attestation gate already written in step 6. The key never lives without the gate.

**The IAM role trust policy** trusts `pods.eks.amazonaws.com` and requires three
`aws:RequestTag` conditions that tie the credential to this cluster, namespace, and service
account. The role carries no identity policies: all the pod's permissions on the KMS key are
in the key policy. `setup.sh` reads `iam:ListRolePolicies` and
`iam:ListAttachedRolePolicies` and refuses to continue if the role carries any identity
policy, because an identity policy could allow `kms:Decrypt` without an attestation
condition.

## Step 4: Prove the pod ran in a confidential sandbox.

`setup.sh` starts two pods on the same node: the confidential-sandbox pod
(`reproducible-build-demo`) with `runtimeClassName: confidential-sandbox`, and a plain pod
(`reproducible-build-plain`) with no runtime class. Both run the same image. The plain pod
is pinned to the same node as the sandbox pod so both readings come from one machine, and
the comparison is about where the container ran, not what it ran.

`setup.sh` reads the sandbox pod's readings from `GET /readings` over HTTP, because the
production Cedar policy refuses `kubectl logs`. The plain pod's readings come from
`kubectl logs` as usual. The last part of `setup.sh`'s output shows them alongside each
other, the sandbox pod on the left and the plain pod on the right:

```text
TODO: output from the fresh run
```

A confidential-sandbox pod runs inside a lightweight VM with its own Linux kernel, booted
when the pod starts. The guest boots when the pod does, on its own virtual devices:

- `reading kernel=` shows the kernel release the pod sees. In this run the guest and the
  node report the same release, `6.18.62`, so this reading alone does not tell them apart;
  the disks and the product name do.
- `reading uptime_s=` is the uptime of the kernel each pod runs on, read when the reading
  was requested. In this run the two values are close, so uptime does not separate the
  pods either.
- `reading disks=` shows `vda,vdb,...` in the sandbox (virtio block devices in the guest
  VM) and `nvme0n1,...` in the plain pod (the EC2 instance's NVMe devices).
- `reading dmi_product=` shows an `.enclave` product name in the sandbox (`c8a.enclave` in
  this run) and the EC2 instance type in the plain pod (`c8a.large`).

## Step 5: Verify independently.

`verify.sh` checks the full chain without any shared state from `setup.sh`. It reads
`IMAGE_REPO`, `KEY_ARN`, and `AWS_REGION` from `.env` and makes only read-only AWS calls:

```bash
./scripts/verify.sh
```

Abridged where marked `[...]`, with the same placeholders as in Step 1.

```text
TODO: output from the fresh run
```

The four steps the script runs:

1. **Rebuild the image.** Same flake, same pinned builder container, fresh empty `/nix`
   store. The rebuilt digest must equal the pushed digest.
2. **Compare with ECR.** The script confirms the rebuilt digest is present in ECR and that
   the `v1-<digest12>` tag resolves to the same digest. If the digests differ, it fetches
   both image manifests and prints the first layer that differs.
3. **Predict PCR17.** The Cedar policy generator reads the pod manifest with the rebuilt
   image URI and prints the predicted PCR17.
4. **Compare with the live key policy.** `kms:GetKeyPolicy` reads the
   `AttestedDecryptOnly` statement. The predicted PCR17 must match the value in the policy.

The script exits 0 when all four checks pass, 1 when a comparison fails, and 2 when a
lookup fails and nothing was determined.

## Step 6: Decrypt.

`decrypt.sh` exercises the full decrypt path:

```bash
./scripts/decrypt.sh
```

Abridged where marked `[...]`, with the same placeholders as in Step 1.

```text
TODO: output from the fresh run
```

The script generates a random demo string (`demo-<hex>`), encrypts it with the KMS key
under the `BuildTimeEncrypt` statement, opens a `kubectl port-forward` to the ClusterIP
Service, and sends the ciphertext as a `PUT /decrypt` request to the sandbox pod.

**The endpoint is a decryption oracle.** Any caller with network access to the endpoint can
ask the service to decrypt any ciphertext whose data key came from this KMS key. Three
bounds define the scope in this blueprint:

1. The service listens on a ClusterIP only. The only path in from outside the cluster is
   `kubectl port-forward`, which requires cluster credentials.
2. The HTTP response carries `{"ok":true,"sha256":"..."}` and never carries the plaintext.
   The service logs only `decrypted sha256=…` on success; the plaintext is not retained.
3. KMS releases the data key only to this exact measurement. A pod running any other build,
   or one with no Cedar policy at all, is refused before it can reach the endpoint.

The decrypt service runs until the pod is deleted. It does not restart.

### The operator cannot log in or read logs

The production Cedar profile (`deploy/production-profile.yaml`) adds `logs: deny` and
`termination_logs: deny` to the shared confidential profile. `exec`, `stdin`, and
`stream_agent_logs` are already denied in the shared profile. The production image has no
shell: the `mkImage {}` call in `flake.nix` holds only `pkgs.cacert` in `copyToRoot`, and
an `assert` in the flake enforces this at eval time.

`setup.sh` and `decrypt.sh` both confirm that an operator with cluster access cannot read
the sandbox pod's logs or run commands in it:

```text
TODO: output from the fresh run
```

## Step 7: Show the gate refuses a changed build.

`changed-source.sh` makes a one-line change, rebuilds and pushes the changed image,
generates the Cedar policy for it, confirms PCR17 differs, and runs the changed pod to show
KMS refuses it:

```bash
./scripts/changed-source.sh
```

Abridged where marked `[...]`, with the same placeholders as in Step 1.

```text
TODO: output from the fresh run
```

The script changes `const BANNER: &str = "reproducible-build decrypt v1"` to `v2` in a
copy of the source under `tmp/reproducible-build/changed/`. It verifies that exactly two
diff lines result from the change.

The changed image has a different OCI digest. The Cedar policy the generator produces for it
has a different PCR17. The KMS key policy expects the original PCR17 and refuses a pod whose
attestation document carries the changed measurement.

If the response from the changed pod is 403, the script confirms the response body carries
`kms-denied` with `code=AccessDeniedException`.

If the response is 200, the script exits with an error: `KMS released the key to the
changed measurement <PCR17>: the gate is not enforcing the expected measurement`.

Delete the changed pod when you are done:

```bash
./scripts/changed-source.sh --delete
```

## Step 8: Debug mode.

The production pod has no shell and its logs and exec are denied. The debug mode adds one
busybox layer to the image and allows exec, logs and termination logs in the Cedar policy so an operator
can read the pod's logs and run commands in it.

**What debug adds to the image.** `flake.nix` builds both images from a single `mkImage`
function. The difference is `pkgs.busybox` in `copyToRoot` and `:/bin` appended to `PATH`:

```nix
roots = [ pkgs.cacert ] ++ pkgs.lib.optional debug pkgs.busybox;
"PATH=${server}/bin${pkgs.lib.optionalString debug ":/bin"}"
```

**What debug adds to the Cedar policy.** `deploy/debug-profile.yaml` differs from
`deploy/production-profile.yaml` in three fields:

```diff
--- deploy/production-profile.yaml
+++ deploy/debug-profile.yaml
@@ -44,11 +44,11 @@
   pin_sysctls: true
   pin_oci_hardening: false
 runtime:
-  exec: deny
-  logs: deny
+  exec: allow
+  logs: allow
   stdin: deny
   stats: allow
-  termination_logs: deny
+  termination_logs: allow
   imds: allow
   oom: allow
   sa_token: infer
```

**Why the production key stays out of reach.** The debug image and debug policy together
measure to a different PCR17 than the production build. The production KMS key's policy
names only the production PCR17. The decrypt service passes no `KeyId` parameter: KMS reads
the key from the ciphertext header, evaluates the production key's attestation condition
against the debug pod's PCR17, and refuses. The debug pod can decrypt only a ciphertext
encrypted with its own debug key.

```bash
./scripts/debug.sh
```

Abridged where marked `[...]`, with the same placeholders as in Step 1. One line is also
left out: a `kubectl logs` attempt made before the kubelet could serve the new pod's logs
failed with `remote error: tls: internal error`, and the script's retry produced the `log:`
lines shown.

```text
TODO: output from the fresh run
```

`debug.sh` runs six steps:

1. Builds the debug image (`image-debug` output from `flake.nix`, the production image plus
   busybox) and pushes it to ECR with a `v1-debug-<digest12>` tag.
2. Generates the Cedar policy using `deploy/debug-profile.yaml`, reads the debug PCR17, and
   stops if it equals the production PCR17 or is all zeros.
3. Creates a separate KMS key behind `alias/reproducible-build-debug` (or `DEBUG_KMS_ALIAS`
   in `.env`) and gates it on the debug PCR17.
4. Runs the debug pod (`reproducible-build-debug`) and waits for it to be Ready.
5. Confirms debug works: `kubectl logs` shows the readings and startup; `kubectl exec` opens
   a shell; a throwaway demo secret encrypted with the debug key decrypts to the expected
   sha256.
6. Confirms the production secret is out of reach: sends the production ciphertext to the
   debug pod. KMS evaluates the production key's policy against the debug PCR17 and refuses
   with `AccessDeniedException`; the service returns HTTP 403 with `kms-denied`.

The script ends with a summary showing both digests, both PCR17s, and which key each is
gated to.

Delete the debug pod when you are done with this step:

```bash
./scripts/debug.sh --delete
```

The debug key is left for `clean.sh` to remove.

## Good to know

- **The key is created with the full policy from the start.** PCR17 is predicted in step 4
  before the KMS key is created in step 6. The KMS alias ARN is predictable from the account
  ID, Region, and alias name, so the pod manifest and the Cedar policy can reference it
  before the key exists. There is no window where the key exists without the gate.

- **The pod role carries no identity policies.** All the pod's permissions on the KMS key
  come from the key policy, not from an attached identity policy. `setup.sh` checks that
  the role has zero inline and zero attached policies and refuses to continue if it finds any.

- **`verify.sh` is read-only.** It calls `ecr:GetAuthorizationToken`, `ecr:DescribeImages`,
  `ecr:BatchGetImage`, `kms:ListAliases`, and `kms:GetKeyPolicy`. It does not write to any
  AWS resource. An outside auditor needs only ECR and KMS read access.

- **The build takes 15 to 30 minutes** on the first run, depending on download speed. On
  x86_64 the nixpkgs toolchain comes from `cache.nixos.org`; on Apple Silicon it loads
  through QEMU emulation and takes longer. Subsequent builds reuse the container image layer
  cache for the nixos/nix base image.

- **`restartPolicy: Never`.** A pod that reaches KMS and is refused does not restart
  automatically. The refused pod stays in place until it is deleted.

## Network

This blueprint applies no network policy. The sandbox pod can reach the cluster network,
the instance metadata service, and the internet. The KMS attestation gate is the boundary
this blueprint creates.

To restrict where the pod can connect, see the
[network policy](../../isolation/network-policy/README.md) blueprint.

## Clean up

Set the values again if you are in a new shell, then run:

```bash
./scripts/clean.sh
```

```text
TODO: output from the fresh run
```

Pass `--keep-aws-resources` to delete only the cluster objects and leave the KMS key, ECR
repository, IAM role, and Pod Identity association in place:

```bash
./scripts/clean.sh --keep-aws-resources
```

**What stays after a full clean up:**

- **The KMS keys.** `clean.sh` removes both the production key (`alias/reproducible-build-sample`)
  and the debug key (`alias/reproducible-build-debug`), if the debug stage was run. Each alias
  is deleted immediately so the name is reusable on the next run. The keys themselves are
  scheduled for deletion with a 7-day waiting period, the minimum AWS allows.
- **The IAM role.** The script deletes the role only when it carries no identity policies.
  It refuses and prints the reason when any policy is attached. Detach them first, or set a
  new `ROLE_NAME` in `.env`.

See the [Getting started clean up](../../getting-started/hello-sandbox/README.md#clean-up)
for removing the namespace, the node group, and the cluster.

## Cost and time

The production KMS key costs $1.00 per month while it exists (the 7-day deletion period
counts). The debug key, when it exists, costs the same. Each `kms:Decrypt` request costs
$0.03 per 10,000. The ECR repository costs $0.10 per GB per month. Each sandbox pod holds
one vCPU and 1 GiB of memory on the cluster until it is deleted.
