# Istio sidecars on Nitro sandboxes: what works and what does not

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
blueprint first so you have a cluster with the runtime classes. The commands below use files
from this repository, so clone it if you have not already, and run them from this blueprint's
folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/integrations/istio
```

On your own machine you also need `kubectl` and `helm` (3.x or later; these runs used 4.2.4).
Istio is a shared install: step 1 has you install it if the cluster does not have it, and
nothing in this blueprint's scripts installs, upgrades or reconfigures it. Beyond the cluster,
a run costs nothing: the workloads are small pods, and there are no model tokens or API credit.

[Istio](https://istio.io/latest/docs/) is a service mesh. It gives the pods in a namespace
mutual TLS between them, workload identities, and authorization rules, without changes to the
application. This blueprint runs three meshed workloads in Nitro sandboxes and shows which
Istio modes work with them today.

## What works and what does not

| Istio mode | On a Nitro sandbox | On this page |
|---|---|---|
| Sidecar, with the `istio-init` init container setting up the traffic redirect | Works | Shown with output from a run |
| Sidecar, with the Istio CNI plugin setting up the traffic redirect | Does not work today | Stated only |
| Ambient mesh (`ztunnel` and the `istio-cni` node agent) | Does not work today. Support is on the roadmap. | Stated only |

- **Use sidecar mode with `istio-init`.** The Istio injection webhook adds an `istio-init`
  init container, which sets up the redirect inside the pod, and an `istio-proxy` (Envoy)
  sidecar, which carries the traffic. This is Istio's default, and it needs no change to Istio
  or to the sandbox.
- **Do not use the Istio CNI plugin.** The CNI plugin cannot set up the traffic redirect for a
  pod that runs in a Nitro sandbox. Install Istio without it.
- **Do not use ambient mesh yet.** Ambient mesh does not work with Nitro sandboxes today.
  Ambient mesh support is on the roadmap for Nitro sandboxes. This page gives no date.

This blueprint shows the first row and states the other two. It does not run them.

The rest of the page covers sidecar mode. Each sandbox pod has its own kernel, and the
sidecar runs in that same sandbox, next to the workload. The Istio control plane (`istiod`) is an
ordinary pod. It gives each sidecar its configuration and a certificate that carries the pod's
identity.

*Figure 1: Two sandbox pods in one mesh. The sidecars in the sandboxes exchange mutual TLS,
and a plaintext client outside the mesh is refused.*

![Inside an Amazon EKS cluster in the AWS Cloud, istiod, an ordinary pod, sends configuration and certificates to the istio-proxy sidecar in each of two Nitro sandbox pods. The first sandbox pod holds client-a, a curl pod, and its istio-proxy. The second holds echo, a go-httpbin server, and its istio-proxy. A request goes from client-a to its istio-proxy (1), over mutual TLS to the istio-proxy of echo (2), and is delivered to echo (3). Below the second sandbox pod, client-plain, an ordinary pod with no sidecar, sends a plaintext request that is refused.](images/istio-sandbox-mesh.png)

This folder was built against these releases:

| Component | Version |
|---|---|
| Istio ([istio/istio](https://github.com/istio/istio/releases)), installed from the [`base` and `istiod` Helm charts](https://istio.io/latest/docs/setup/install/helm/) | 1.31.4, the newest patch release of Istio 1.31, from the Helm repository the Istio install guide names |
| go-httpbin ([mccutchen/go-httpbin](https://github.com/mccutchen/go-httpbin)) | 2.25.0 |
| curl ([curl/curl-container](https://hub.docker.com/r/curlimages/curl)) | 8.10.1 |

The files:

| File | What it is |
|---|---|
| [`scripts/setup.sh`](scripts/setup.sh) | Checks the prerequisites, creates the namespace if it is absent, and applies the workloads. |
| [`scripts/clean.sh`](scripts/clean.sh) | Removes the namespace, after checking it is this blueprint's. Leaves Istio alone. |
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The namespace, labeled so Istio injects its sidecar. |
| [`deploy/workloads.yaml`](deploy/workloads.yaml) | `echo`, `client-a` and `client-b` in sandboxes, and `client-plain` as an ordinary pod. |
| [`deploy/peer-authentication.yaml`](deploy/peer-authentication.yaml) | Requires mutual TLS in the namespace. |
| [`deploy/authorization-policy.yaml`](deploy/authorization-policy.yaml) | Admits `client-a` to `echo` and denies everything else. |

**Step 1: Install Istio, if the cluster does not have it.** The two charts below install the
Istio CRDs and `istiod`. They do not install the CNI plugin or ambient mesh, which is what
you want here. If `istiod` is already running in `istio-system`, skip this step: the
blueprint reuses it as it is.

```bash
helm repo add istio https://blob.istio.io/istio-release/charts
helm repo update istio
helm install istio-base istio/base -n istio-system --create-namespace --version 1.31.4 --wait
helm install istiod istio/istiod -n istio-system --version 1.31.4 --wait
```

```text
NAME: istio-base
LAST DEPLOYED: Mon Nov 16 21:15:24 2026
NAMESPACE: istio-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
```

Abridged: the same lines print for `istiod`. Your timestamps will differ.

If you run `./scripts/setup.sh` before this step, it stops and prints these commands. It
also stops when it finds the Istio CNI plugin or `ztunnel` already installed in any
namespace, by the labels their Helm charts set, because those do not work with Nitro
sandboxes and this blueprint does not change a shared install.

**Step 2: Create the namespace and the workloads.** The namespace carries
`istio-injection: enabled`, which is the only thing that turns on Istio for the pods in it.
Nothing in `workloads.yaml` names `istio-init` or `istio-proxy`: the webhook adds both. The
one line that puts a pod in a sandbox is `runtimeClassName`.

```yaml
# deploy/namespace.yaml (trimmed)
metadata:
  name: <NAMESPACE>
  labels:
    istio-injection: enabled
```

```yaml
# deploy/workloads.yaml, the echo Deployment's pod template (trimmed)
    spec:
      runtimeClassName: isolated-sandbox
      serviceAccountName: echo
      containers:
        - name: httpbin
          image: docker.io/mccutchen/go-httpbin:2.25.0
```

```bash
./scripts/setup.sh
```

```text
== 1/3 prerequisites, reused as they are
istiod ready, no Istio CNI or ztunnel DaemonSet

== 2/3 namespace istio-sandbox-demo
namespace/istio-sandbox-demo created
...
NAME                        READY   STATUS    RESTARTS   AGE
client-a-55b48f4cf5-hp2q8   2/2     Running   0          51s
client-b-5c7f9444dd-52r2d   2/2     Running   0          51s
client-plain                1/1     Running   0          50s
echo-bf7b955b-zskxj         2/2     Running   0          51s
```

Abridged. The first pod on a new sandbox node takes longer while Auto Mode adds the node.
The meshed pods show `2/2` and `client-plain` shows `1/1`, because only the meshed pods have
a sidecar. A pod showing `Ready` does not prove that traffic goes through the sidecar, so the
next steps send requests.

The commands below use the namespace the script created. Set it:

```bash
export NAMESPACE=istio-sandbox-demo
```

**Step 3: See the sidecar and the redirect.** The `echo` pod has the `istio-init` init
container and the `istio-proxy` container next to the workload. Istio lists `istio-proxy`
among the init containers because it runs as a native sidecar: it starts before the workload
and keeps running next to it.

```bash
kubectl -n $NAMESPACE get pod -l app=echo -o jsonpath='{range .items[0].spec.initContainers[*]}init: {.name}{"\n"}{end}{range .items[0].spec.containers[*]}container: {.name}{"\n"}{end}runtimeClassName: {.items[0].spec.runtimeClassName}{"\n"}'
```

```text
init: istio-init
init: istio-proxy
container: httpbin
runtimeClassName: isolated-sandbox
```

`istio-init` set up the redirect with netfilter rules inside the pod's own kernel. Its log
shows them:

```bash
kubectl -n $NAMESPACE logs deploy/echo -c istio-init | grep -E 'REDIRECT'
```

```text
INBOUND_INTERCEPTION_MODE=REDIRECT
-A ISTIO_REDIRECT -p tcp -j REDIRECT --to-ports 15001
-A ISTIO_IN_REDIRECT -p tcp -j REDIRECT --to-ports 15006
-A ISTIO_INBOUND -p tcp -j ISTIO_IN_REDIRECT
...
```

Abridged: the log prints the rule set more than once. Outbound traffic from the workload is
sent to port 15001 of the sidecar, and inbound traffic to port 15006.

**Step 4: Check that the pods run in a sandbox.** `client-a` is a sandbox pod and
`client-plain` is an ordinary pod. The kernel build, the boot time and the disks differ,
because the sandbox pod has its own kernel and its own virtual hardware.

```bash
kubectl -n $NAMESPACE exec deploy/client-a -c curl -- sh -c 'uname -rv; cat /proc/uptime; ls /sys/block; cat /sys/class/dmi/id/product_name'
```

```text
6.18.62 #1 SMP PREEMPT_DYNAMIC Thu Nov 12 22:44:15 UTC 2026
37.25 33.75
dm-0
vda
vdb
vdc
vdd
c8a.enclave
```

The same four readings from `client-plain`, the ordinary pod on a node:

```bash
kubectl -n $NAMESPACE exec client-plain -- sh -c 'uname -rv; cat /proc/uptime; ls /sys/block; cat /sys/class/dmi/id/product_name'
```

```text
6.18.62 #2 SMP PREEMPT_DYNAMIC Thu Nov 12 22:49:16 UTC 2026
18328.36 36261.79
dm-0
loop0
...
nvme0n1
nvme1n1
zram0
c8a.large
```

Abridged: the ordinary pod lists eight `loop` devices. The two kernels print the same
version, so compare the build (`#1` and `#2`), the uptime (the sandbox pod's guest had been up
for seconds, since the pod started, and the node for hours), the `vda` to `vdd` virtio disks against the node's `nvme`
disks, and the product name.

**Step 5: Send a request through the mesh.** `client-a` calls `echo` by its Service name. The
sidecar in `client-a` catches the request, opens a mutual TLS connection to the sidecar in
`echo`, and that sidecar hands the request to the workload.

```bash
kubectl -n $NAMESPACE exec deploy/client-a -c curl -- curl -sS -i http://echo:8000/headers
```

```text
HTTP/1.1 200 OK
...
x-envoy-upstream-service-time: 17
server: envoy

{
  "headers": {
    ...
    "X-Forwarded-Client-Cert": [
      "By=spiffe://cluster.local/ns/istio-sandbox-demo/sa/echo;Hash=2a53b511...;Subject=\"\";URI=spiffe://cluster.local/ns/istio-sandbox-demo/sa/client-a"
    ],
    ...
  }
}
```

Abridged. The response comes from `server: envoy`, not from the workload, and the workload
received the caller's identity in `X-Forwarded-Client-Cert`: the SPIFFE identity of
`client-a`'s ServiceAccount, which the sidecars exchanged during mutual TLS. The sidecar
also counts the request:

```bash
kubectl -n $NAMESPACE exec deploy/echo -c istio-proxy -- pilot-agent request GET stats/prometheus | grep '^istio_requests_total' | sed -E 's/.*source_workload="([^"]*)".*response_code="([^"]*)".*\} ([0-9]+)$/source_workload=\1 response_code=\2 count=\3/'
```

```text
source_workload=client-a response_code=200 count=1
```

**Step 6: Require mutual TLS.** Until a policy says otherwise, Istio accepts plaintext
as well as mutual TLS. First send a plaintext request from `client-plain`, which has no
sidecar, then apply a `PeerAuthentication` with `mode: STRICT` and send it again.

```yaml
# deploy/peer-authentication.yaml (trimmed)
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl -n $NAMESPACE exec client-plain -- curl -sS -m 10 -o /dev/null -w 'HTTP %{http_code}\n' http://echo:8000/get
sed "s/<NAMESPACE>/$NAMESPACE/g" deploy/peer-authentication.yaml | kubectl apply -f -
sleep 10
kubectl -n $NAMESPACE exec client-plain -- curl -sS -m 10 http://echo:8000/get
kubectl -n $NAMESPACE exec deploy/client-a -c curl -- curl -sS -m 10 -o /dev/null -w 'HTTP %{http_code}\n' http://echo:8000/get
```

```text
HTTP 200
peerauthentication.security.istio.io/istio-sandbox-strict created
curl: (56) Recv failure: Connection reset by peer
command terminated with exit code 56
HTTP 200
```

The plaintext request worked before the policy, so the refusal is the policy's doing and
not a broken pod. After it, the sidecar in the sandbox resets the plaintext connection, and
the meshed `client-a` still gets `200`.

**Step 7: Allow one caller.** An `AuthorizationPolicy` selects `echo` and admits only the
identity of `client-a`. A request that no rule matches is denied.

```yaml
# deploy/authorization-policy.yaml (trimmed)
spec:
  selector:
    matchLabels:
      app: echo
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/<NAMESPACE>/sa/client-a
```

```bash
sed "s/<NAMESPACE>/$NAMESPACE/g" deploy/authorization-policy.yaml | kubectl apply -f -
sleep 20
kubectl -n $NAMESPACE exec deploy/client-a -c curl -- curl -sS -m 10 -o /dev/null -w 'HTTP %{http_code}\n' http://echo:8000/get
kubectl -n $NAMESPACE exec deploy/client-b -c curl -- curl -sS -m 10 -w '\nHTTP %{http_code}\n' http://echo:8000/get
```

```text
authorizationpolicy.security.istio.io/echo-allow-client-a created
HTTP 200
RBAC: access denied
HTTP 403
```

Both clients are in sandboxes and both have a valid mesh identity. The sidecar in front of
`echo` decides by the caller's identity.

## Good to know

- **The Istio CNI plugin and ambient mesh do not work on Nitro sandboxes today.** This page
  states that and does not run them, so it shows no output for either. Ambient mesh support
  is on the roadmap for Nitro sandboxes, with no date. Install Istio as step 1 does, with
  `base` and `istiod` and nothing else, and use sidecars.
- **`setup.sh` stops when it finds the Istio CNI plugin or `ztunnel` installed.** It looks
  in every namespace for the labels the Istio Helm charts set (`k8s-app=istio-cni-node` and
  `app.kubernetes.io/name=ztunnel`), so an install made another way may not be found. Those
  do not work with Nitro sandboxes, and the script does not change a shared install.
- **Check traffic, not readiness.** A meshed pod shows `2/2` once its sidecar is up. Step 5
  and step 6 check the traffic itself.
- **This blueprint tested HTTP on one port,** with one replica of each workload and IPv4
  only.
- **The workload containers set no CPU or memory requests, but Istio's do.** The injected
  `istio-init` and `istio-proxy` containers carry Istio's chart defaults: requests of 100m
  CPU and 128Mi memory, and limits of 2 CPU and 1Gi. In the run above, a meshed sandbox's
  guest reported about 245 MiB of memory and one CPU. A production workload sizes its pods,
  and tunes the sidecar's resources, for its own needs.
- **This blueprint creates no Pod Identity association** and gives the pods no AWS
  permissions.
- **This blueprint does not restrict where the pods can connect.** They have a network, so
  they reach what any pod on the cluster reaches. Mutual TLS and the authorization policy
  govern calls to `echo`, not what a pod can reach. To restrict a pod, see the
  [network policy](../../isolation/network-policy/README.md) blueprint.

## Clean up

The commands use the variables from the walkthrough. In a new shell, set them again first,
with the values you used:

```bash
export NAMESPACE=istio-sandbox-demo
```

```bash
./scripts/clean.sh
```

The script checks that the namespace carries this blueprint's label, then removes the
namespace with the workloads, the `PeerAuthentication` and the `AuthorizationPolicy`. It
exits non-zero if it could not finish.

It leaves Istio in place, because other workloads may use it. If you installed Istio in
step 1 and nothing else uses it, remove it:

```bash
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
```

Helm keeps the Istio CustomResourceDefinitions when it uninstalls `istio-base`, and prints
the list it kept. It also leaves the `istio-system` namespace, which `--create-namespace`
made in step 1 and the uninstall leaves empty. Neither is removed by this blueprint. Delete
them yourself only after you confirm nothing else on the cluster uses Istio and that you
created `istio-system` for this walkthrough.

If this is the last blueprint you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove
the cluster.
