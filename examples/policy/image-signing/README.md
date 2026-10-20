# Verify an image signature inside the sandbox guest

This sample signs a container image with [AWS Signer](https://docs.aws.amazon.com/signer/latest/developerguide/Welcome.html)
and verifies the signature with the [Notation](https://github.com/notaryproject/notation)
CLI from the [Notary Project](https://notaryproject.dev/docs/) **inside the running
pod's guest**, not only in an admission controller outside it. The workload pod runs in a
Nitro sandbox (`runtimeClassName: isolated-sandbox`); the signing and the push to the
registry happen operator-side, on an ordinary host, before the pods start.

AWS Signer is a managed code-signing service. Used with the Notation CLI, it signs
container images in a registry such as Amazon ECR, and the signature is stored in the
registry next to the image, where it can be fetched to verify the image's authenticity and
integrity ([Amazon ECR image signing](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-signing.html)).
This sample runs that verification one step deeper: in the pod's own guest, where the
workload runs.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. This sample also builds on the
one-line network-isolated variant from hello sandbox and on the Pod Identity and egress
network policy from the [coding agent](../../getting-started/coding-agent/README.md) sample.
The commands below use files from this repository, so clone it if you have not already, and
run them from this sample's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/policy/image-signing
```

This sample needs a host with [Docker](https://docs.docker.com/get-docker/), the
[Notation CLI](https://github.com/notaryproject/notation), and the
[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
signed in to the account that holds the cluster. The optional offline variant also needs
[`oras`](https://oras.land/). A run stores two small images and one signature in Amazon
ECR, billed as ECR storage; there is no additional charge for AWS Signer used with Amazon
ECR ([AWS Signer](https://docs.aws.amazon.com/signer/latest/developerguide/Welcome.html)).
Copy `.env.example` to `.env` (git ignores it) and set your cluster name and Region. The
scripts run against your current `kubectl` context; on a machine whose context may point
elsewhere, set `KUBE_CONTEXT=<your cluster's context>` in the environment and the scripts
pass `--context` on every `kubectl` call (they never change your current context).

## Overview

One image is built and pushed to two Amazon ECR repositories. Only one copy is signed with
AWS Signer, through the Notation CLI and the AWS Signer plugin; the other is the negative
control. Three pods then run the same image under `runtimeClassName: isolated-sandbox` and
each verifies its own image reference in-guest with `notation verify`, driven by
`kubectl exec`, which reaches the guest over the sandbox's internal control channel.

- **The verifier image carries its trust material, not the signature.** It bakes the
  Notation CLI, the AWS Signer plugin, the AWS Signer root certificate in a trust store,
  and a Notation trust policy pinned to this sample's signing profile. The signature itself
  lives in the registry and is pulled at verify time, which is why the network-isolated pod
  cannot complete the check.
- **Verification runs in the guest, not at admission.** Each pod verifies its own image
  reference after it is already running. This is a check in the pod's own guest, where the
  workload runs, not a gate outside the sandbox.
- **Least-privilege pull.** The verifier's pod gets a role through EKS Pod Identity that
  may pull only this sample's two repositories, and holds no AWS Signer permissions.
  Verifying a registry reference reaches DNS, the Pod Identity credential endpoint and the
  Amazon ECR and S3 endpoints the image and signature pull needs. Revocation checking is
  turned off in the trust policy, so the guest never calls the AWS Signer revocation
  endpoint: no verify-time egress leaves for AWS Signer.

The three pods differ by a single line: which repository's reference they verify, and
whether they carry the no-network annotation.

| Pod | Image reference | Network | In-guest verify result |
|---|---|---|---|
| `verify-signed` | signed repository | full | succeeds |
| `verify-unsigned` | unsigned repository | full | fails: no signature associated |
| `verify-signed-denied` | signed repository | none (network-isolated) | fails: registry unreachable |

*Figure 1: One image, signed once operator-side, verified in-guest by three sandboxed pods.
On an ordinary host the image is pushed to a signed and an unsigned repository in Amazon
ECR, and AWS Signer signs only the signed copy. Each pod runs isolated-sandbox and verifies
its own reference with notation: the signed pod succeeds, the unsigned pod fails because no
signature is associated, and the network-isolated pod fails because it cannot reach the
registry to pull the signature.*

![One image is built and pushed to a signed and an unsigned repository in Amazon ECR, and AWS Signer signs only the signed copy. Three pods run under runtimeClassName isolated-sandbox. The verify-signed pod has full network and verifies the signed reference, which succeeds. The verify-unsigned pod has full network and verifies the unsigned reference, which fails because no signature is associated. The verify-signed-denied pod carries the network-isolated annotation and verifies the signed reference, which fails because the guest has no network device to reach the registry. notation verify is driven by kubectl exec over the sandbox control channel in every case.](images/figure-1-image-signing.png)

## Versions

The tools are pinned when the sample is built. The AWS Signer plugin is published as a
`latest` artifact rather than a fixed version string; the version below is what it resolved
to at build time, read with `notation plugin ls`.

| Component | Pin | This run |
|---|---|---|
| Notation CLI ([notaryproject/notation](https://github.com/notaryproject/notation/releases)) | v1.3.2 | v1.3.2 |
| AWS Signer Notation plugin ([AWS Signer container workflow](https://docs.aws.amazon.com/signer/latest/developerguide/container-workflow.html)) | latest | 1.0.2292 |
| Amazon ECR credential helper ([awslabs/amazon-ecr-credential-helper](https://github.com/awslabs/amazon-ecr-credential-helper/releases)) | v0.12.0 | v0.12.0 |
| AWS Signer signing platform | `Notation-OCI-SHA384-ECDSA` | `Notation-OCI-SHA384-ECDSA` |

The AWS Signer signing platform for Notation/OCI signing is `Notation-OCI-SHA384-ECDSA`
("Notation for container registries"), confirmed with
`aws signer list-signing-platforms`. The base image is not pinned by digest in the
`Dockerfile`; pin it there if byte-for-byte reproducibility matters.

## Files

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile) | The verifier image: Notation, the AWS Signer plugin, the AWS Signer root cert in a trust store, and a trust policy pinned to the signing profile |
| [`scripts/setup.sh`](scripts/setup.sh) | Build and push to two repositories, sign one copy, create the role, turn on and apply the network policy, launch the three pods |
| [`scripts/clean.sh`](scripts/clean.sh) | Delete what `setup.sh` created, and verify it is gone |
| [`deploy/namespace.yaml`](deploy/namespace.yaml), [`deploy/service-account.yaml`](deploy/service-account.yaml) | The `image-signing-sample` namespace and the verifier ServiceAccount |
| [`deploy/workloads.yaml`](deploy/workloads.yaml) | The three pods |
| [`deploy/enable-network-policy.yaml`](deploy/enable-network-policy.yaml), [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | Network policy enforcement and the egress policy for the networked pods |
| [`iam/`](iam/) | The Pod Identity trust policy and the least-privilege ECR-read policy |
| [`optional-offline/`](optional-offline/) | The optional variant: verify with no network at all |

**Step 1: Sign the image and launch the pods.** `scripts/setup.sh` reads `.env`, builds one
image, pushes the same bytes to two ECR repositories, signs only the signed copy with AWS
Signer, creates the verifier's Pod Identity role, turns on network policy enforcement,
applies the egress policy, and launches the three pods. Each resource it creates is tagged
`ManagedBy` and `auto-delete=no`, and only resources carrying that `ManagedBy` tag are
adopted on a re-run, so the sample never touches image-signing resources other demos may
already have in the account.

```bash
cp .env.example .env     # then edit CLUSTER_NAME and AWS_REGION
./scripts/setup.sh
```

```text
Identity: account <ACCOUNT_ID>, region us-west-2, cluster <CLUSTER_NAME>

=== 4/8 sign the image in nitro-sample-image-signing-signed with AWS Signer ===
AWS Signer plugin version: 1.0.2292
Successfully signed <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-signed@sha256:017d6f786bf74112ebfda095ea566249a5ab62e2ab371297833999c71ada9766
signed <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-signed@sha256:017d6f786bf7...ada9766 (the nitro-sample-image-signing-unsigned copy is deliberately left unsigned).

=== 8/8 wait for all three guest VMs to boot ===
pod/verify-signed condition met
pod/verify-unsigned condition met
pod/verify-signed-denied condition met

image-signing sample is up in namespace image-signing-sample.
```

Abridged. The signed image's digest is the same in both repositories, because both copies
come from one build; only the signed copy gets a signature.

**Step 2: Confirm each pod opted into the sandbox.** All three run `isolated-sandbox`, and
only the network-isolated pod carries the annotation:

```bash
for p in verify-signed verify-unsigned verify-signed-denied; do
  printf '%s: rc=%s netiso=%s\n' "$p" \
    "$(kubectl -n image-signing-sample get pod "$p" -o jsonpath='{.spec.runtimeClassName}')" \
    "$(kubectl -n image-signing-sample get pod "$p" -o jsonpath='{.metadata.annotations.sandbox\.amazonaws\.com/network-isolated}')"
done
```

```text
verify-signed: rc=isolated-sandbox netiso=
verify-unsigned: rc=isolated-sandbox netiso=
verify-signed-denied: rc=isolated-sandbox netiso=true
```

**Step 3: Prove the pod ran in a sandbox.** As in the hello sandbox sample, the guest has
its own kernel build, its own boot and virtio disks. Compare the signed pod with an ordinary
(non-sandbox) pod on the same cluster:

```bash
kubectl -n image-signing-sample exec verify-signed -c main -- uname -rv
kubectl -n image-signing-sample exec verify-signed -c main -- ls /sys/block
kubectl -n image-signing-sample exec verify-signed -c main -- cat /proc/uptime
kubectl -n image-signing-sample get pod verify-signed
```

```text
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
dm-0 vda vdb vdc
65.98 63.94
NAME            READY   STATUS    RESTARTS   AGE
verify-signed   1/1     Running   0          69s
```

An ordinary pod on the same cluster shows, instead:

```text
6.18.51 #2 SMP PREEMPT_DYNAMIC Wed Oct  7 22:33:11 UTC 2026
dm-0 nvme0n1 nvme1n1 zram0
64066.25 510583.69
NAME           READY   STATUS    RESTARTS   AGE
ordinary-ref   1/1     Running   0          7s
```

The kernel version string matches, but the build does not (`#1 ... Oct 1` against
`#2 ... Oct 7`): the guest runs its own kernel. The disk list is `vda vdb vdc`, the guest's
virtio devices, where the ordinary pod sees the instance's `nvme`. And the guest's uptime,
66 seconds, matches the just-started pod, because the VM booted with the pod; the ordinary
pod's `/proc/uptime` reports the node's uptime, over 17 hours.

**Step 4: Verify the signed image in-guest.** The caller must be allowed to `create
pods/exec` in the namespace, so a verify failure is Notation's and not RBAC:

```bash
kubectl auth can-i create pods/exec -n image-signing-sample
```

```text
yes
```

Run `notation verify` inside the signed pod, over the control channel:

```bash
SIGNED=<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-signed@sha256:017d6f786bf7...ada9766
kubectl -n image-signing-sample exec verify-signed -c main -- notation verify "$SIGNED"
```

```text
Successfully verified signature for <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-signed@sha256:017d6f786bf74112ebfda095ea566249a5ab62e2ab371297833999c71ada9766
```

The signature was pulled from the registry and checked against the AWS Signer root
certificate and the trust policy baked into the image, inside the guest.

**Step 5: The unsigned image is refused in-guest.** The same command against the unsigned
copy fails, and the failure names the missing signature, not a network problem. This is the
negative case, kept permanently:

```bash
UNSIGNED=<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-unsigned@sha256:017d6f786bf7...ada9766
kubectl -n image-signing-sample exec verify-unsigned -c main -- notation verify "$UNSIGNED"
```

```text
Error: signature verification failed: no signature is associated with "<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-unsigned@sha256:017d6f786bf74112ebfda095ea566249a5ab62e2ab371297833999c71ada9766", make sure the artifact was signed successfully
```

Both repositories hold the same image bytes at the same digest, so the only difference is
the signature the signed repository carries and the unsigned one does not.

**Step 6: Registry-backed verification needs a network.** The third pod runs the signed
reference under `sandbox.amazonaws.com/network-isolated: "true"`. The verify fails, but for
a different reason: it cannot reach the registry to pull the signature.

```bash
kubectl -n image-signing-sample exec verify-signed-denied -c main -- notation verify "$SIGNED"
```

```text
Error: failed to get manifest descriptor: Head "https://<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/v2/nitro-sample-image-signing-signed/manifests/sha256:017d6f786bf74112ebfda095ea566249a5ab62e2ab371297833999c71ada9766": dial tcp: lookup <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com on 10.100.0.10:53: dial udp 10.100.0.10:53: connect: network is unreachable
```

The error is `network is unreachable`, not `no signature is associated`, so a network
failure can never pass as a signature result. The guest has no routable device, only
loopback and a dummy interface, yet still runs code over the control channel:

```bash
kubectl -n image-signing-sample exec verify-signed-denied -c main -- \
  awk -F: 'NR>2{gsub(/ /,"",$1);print $1}' /proc/net/dev
kubectl -n image-signing-sample exec verify-signed-denied -c main -- \
  sh -c 'echo -n hello | sha256sum | cut -d" " -f1'
```

```text
lo
dummy0
2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
```

Only `lo` and `dummy0` have no route out, and the `sha256sum` of `hello` is the expected
value, so the command ran in the guest; only its network is gone.

## How the network policy works

The two networked pods, `verify-signed` and `verify-unsigned`, carry the label
`app: image-signing-verifier`, which the egress policy selects. The policy denies all
ingress and all egress except DNS, the Pod Identity credential endpoint, Amazon ECR, and
the Amazon S3 range ECR serves its layers and signature blobs from. `verify-signed-denied`
is network-isolated and is not selected: it has no network to restrict.

Network policy enforcement is turned on once per cluster. EKS Auto Mode accepts network
policies without enforcing them until the `amazon-vpc-cni` ConfigMap in `kube-system` sets
`enable-network-policy-controller: "true"`
([`deploy/enable-network-policy.yaml`](deploy/enable-network-policy.yaml)). This affects the
whole cluster; pods that no policy selects are unaffected.

Here is the whole egress policy
([`deploy/egress-policy.yaml`](deploy/egress-policy.yaml)), without its header comment.
`scripts/setup.sh` fills in the CoreDNS address, the account ID, and the S3 ranges at apply
time:

```yaml
apiVersion: networking.k8s.aws/v1alpha1
kind: ApplicationNetworkPolicy
metadata:
  name: image-signing-egress
  namespace: image-signing-sample
spec:
  podSelector:
    matchLabels:
      app: image-signing-verifier
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
        - ipBlock: { cidr: 169.254.170.23/32 }   # EKS Pod Identity credential endpoint
      ports:
        - { protocol: TCP, port: 80 }
    - to:
        - domainNames:
            - api.ecr.us-west-2.amazonaws.com              # ECR API: auth token, manifests, Referrers API
            - <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com # the ECR registry endpoint (image and signature manifests)
      ports:
        - { protocol: TCP, port: 443 }
    - to:
        - ipBlock: { cidr: 3.5.80.0/21 }   # Amazon S3, us-west-2 (from the AWS-managed prefix list)
        # ... the rest of the S3 ranges for the Region
      ports:
        - { protocol: TCP, port: 443 }
```

| Part | What it does |
|---|---|
| `podSelector` | Selects the two networked verifier pods by `app: image-signing-verifier`. |
| `policyTypes: [Ingress, Egress]` | Denies all ingress and all egress except the rules below. |
| DNS rule | Allows UDP and TCP 53 to the CoreDNS ClusterIP, so names resolve. |
| Pod Identity rule | Allows the link-local credential endpoint `169.254.170.23` on port 80, which the ECR credential helper reads to get an ECR auth token. |
| ECR rule | Allows HTTPS to the ECR API and the account's ECR registry endpoint, which serve the auth token, the image manifest and the signature manifest. |
| S3 rule | Allows HTTPS to the Amazon S3 ranges for the Region, where ECR stores image layers and the signature blob. |

A standard Kubernetes `NetworkPolicy` can only allow addresses; the Auto Mode
`ApplicationNetworkPolicy` accepts the same fields plus `domainNames`. A `domainNames` rule
allows the addresses those names resolve to, so another name served from the same addresses
is reachable too. ECR serves image layers and the Notation signature blob from Amazon S3
through a short-lived presigned URL whose host resolves across the whole S3 regional range,
which a `domainNames` rule cannot pin, so S3 is allowed by its published CIDRs from the
AWS-managed prefix list `com.amazonaws.<region>.s3`. That is broader than one bucket: it
admits any S3 bucket in the Region. Narrow it with a gateway VPC endpoint for S3 if your
cluster has one.

There is no rule for the Pod Identity data path at `169.254.170.23` beyond the one above;
in a Nitro sandbox that address is answered inside the guest, and the rule is what the node's
policy enforcement needs because its default-deny applies to the link-local address too. The
policy is enforced on the node, outside the guest: the node's network policy agent attaches
eBPF programs to the pod's host-side interface, so a command inside the sandbox, even as
root, cannot change it.

Show it working: one refused connection and one allowed, from inside the signed pod.

```bash
kubectl -n image-signing-sample exec verify-signed -c main -- \
  curl -sS -m 10 -o /dev/null https://example.com
kubectl -n image-signing-sample exec verify-signed -c main -- \
  curl -sS -m 10 -o /dev/null -w 'http_code=%{http_code}\n' https://api.ecr.us-west-2.amazonaws.com/
```

```text
curl: (28) Connection timed out after 10000 milliseconds
command terminated with exit code 28
http_code=404
```

`example.com` is not listed, so the connection times out. The ECR API is listed, so it
answers (404 on the bare path means the TLS connection reached ECR).

## Optional: verify with no network at all

Registry-backed verification cannot survive `network-isolated`, because Notation must pull
the signature from the registry. There is a posture that verifies with zero egress: pre-stage
the signed image **and its signature** into an on-disk OCI image layout, ship that into the
guest, and verify the layout. [`optional-offline/`](optional-offline/) does this. Prove it
before relying on it; the files here were proved on a fresh run.

`optional-offline/scripts/build-offline.sh` uses `oras` to copy the signed image and its AWS
Signer signature from ECR into a local OCI layout, bakes that layout and the same trust
material into a second image, pushes it to its own repository, and launches a pod that
carries `sandbox.amazonaws.com/network-isolated: "true"`. The node pulls the image before
the guest boots, so the guest comes up with no network and reads the signature from disk.

```bash
cd optional-offline
./scripts/build-offline.sh
```

The pod has no network, yet `notation verify --oci-layout` succeeds from the baked-in layout:

```bash
kubectl -n image-signing-sample exec verify-offline -c main -- \
  awk -F: 'NR>2{gsub(/ /,"",$1);print $1}' /proc/net/dev
kubectl -n image-signing-sample exec verify-offline -c main -- \
  curl -sS -m 5 -o /dev/null https://api.ecr.us-west-2.amazonaws.com
SCOPE=<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nitro-sample-image-signing-signed
kubectl -n image-signing-sample exec verify-offline -c main -- sh -c \
  "cd /var/lib/image-signing/layout && notation verify --oci-layout --scope '$SCOPE' 'nitro-sample-image-signing-signed@sha256:017d6f786bf7...ada9766'"
```

```text
lo
dummy0
curl: (6) Could not resolve host: api.ecr.us-west-2.amazonaws.com
command terminated with exit code 6
Warning: This feature is experimental and may not be fully tested or completed and may be deprecated. Report any issues to "https://github/notaryproject/notation"
Successfully verified signature for nitro-sample-image-signing-signed@sha256:017d6f786bf74112ebfda095ea566249a5ab62e2ab371297833999c71ada9766
```

The pod has only `lo` and `dummy0`, cannot resolve the ECR host, and still verifies the
signature from disk.

*Figure 2: The offline posture. On an ordinary host, oras copies the signed image and its
signature from Amazon ECR into an on-disk OCI layout, which is baked into a second image
along with the trust material. A pod running that image under the network-isolated
annotation reads the signature from disk and verifies it with notation, with no network at
all.*

![On an ordinary host, oras copies the signed image and its AWS Signer signature from Amazon ECR into an on-disk OCI layout. That layout and the AWS Signer trust material are baked into an offline verifier image, which is pushed to Amazon ECR. A pod running under runtimeClassName isolated-sandbox and the sandbox network-isolated annotation has only loopback, pulls nothing at verify time, and runs notation verify with the oci-layout flag against the baked-in layout, which succeeds.](images/figure-2-offline.png)

**The trade-off is real: revocation cannot be enforced offline.** The trust policy sets
`revocation: skip`, so the AWS Signer plugin makes no revocation-status call and the verify
needs no network. A revoked signing profile or certificate would not be detected in-guest.
If revocation must be enforced, the guest needs egress to the AWS Signer regional endpoint
and cannot run under a plain `network-isolated`.

## Good to know

- **Verification here is a post-start check, not an admission gate.** The pod is already
  running when `notation verify` runs in its guest. That is the point of the sample: the
  check runs where the workload runs. To stop an unverified pod from starting at all, add an
  admission-time verifier as well.
- **The role holds no AWS Signer permissions.** The verifier pulls from the registry with an
  ECR-read role and checks the signature against the baked-in root certificate, so the guest
  never calls AWS Signer. `setup.sh` fails closed if the role carries any policy beyond the
  one inline ECR-read policy, so an adopted role cannot keep a stray `signer:*`. Revocation
  is skipped in the trust policy, so no verify-time egress leaves for AWS Signer; the pull
  itself still reaches DNS, the Pod Identity endpoint, and the ECR and S3 endpoints.
- **The ECR repositories are `IMMUTABLE`.** A re-run adopts the existing `:v1` images rather
  than rebuilding, which is what keeps the signed and unsigned copies identical across runs.

## Clean up

Set the variables again in a new shell if needed (`scripts/clean.sh` reads `.env`). Remove
the offline variant first if you ran it, then the main sample:

```bash
# optional variant, if you ran it:
kubectl -n image-signing-sample delete pod verify-offline --ignore-not-found
aws ecr delete-repository --repository-name nitro-sample-image-signing-offline --region "$AWS_REGION" --force

# the main sample (set KUBE_CONTEXT if your current kubectl context may point elsewhere):
./scripts/clean.sh                      # pods, ServiceAccount, namespace, egress policy, Pod Identity association
./scripts/clean.sh --delete-aws-resources   # also the two ECR repositories, the IAM role, and CANCEL the signing profile
```

`clean.sh` verifies each deletion and exits non-zero if anything it was asked to remove is
still there, including when it only found a resource it does not own or a lookup it could not
complete. AWS Signer has no hard delete, so `--delete-aws-resources` cancels the signing
profile and confirms its status reads `Canceled`. A canceled profile lingers until its
signatures expire (about 141 months by default) and AWS Signer refuses to reuse the name, so
to set the sample up again after `--delete-aws-resources`, set a new `SIGNING_PROFILE` in
`.env` first; `setup.sh` stops with that instruction if the old name is still present.
Network policy enforcement is cluster-wide;
deleting the cluster removes it, or delete the `amazon-vpc-cni` ConfigMap in `kube-system` if
nothing else relies on it. To remove the namespace and the cluster, follow the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up).
