# Network policy on a sandboxed pod

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. The commands below use files
from this repository, so clone it if you have not already, and run them from this sample's
folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/isolation/network-policy
```

Before a platform team trusts a sandbox with untrusted code, it asks one question: does the
egress control it already uses, a plain Kubernetes
[`NetworkPolicy`](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
still get enforced when the workload runs in a Nitro sandbox? A sandboxed pod's containers
run in a lightweight VM of their own, which is what makes the question worth asking.

This sample answers it by running the same egress client twice, side by side, differing only
in `runtimeClassName: isolated-sandbox` versus an ordinary pod, under one namespace-scoped
egress `NetworkPolicy` that selects both. After the policy, both clients keep reaching the
server it allows and both are refused the server it denies: the policy holds on the sandboxed
pod's path exactly as it does on the ordinary pod's. The ordinary pod is the control, so the
result cannot be read any other way.

- **The same NetworkPolicy, enforced on the sandboxed path and the ordinary path alike.** Two
  clients, identical in every field a policy could select on and differing only in
  `runtimeClassName`, both lose exactly the one egress the policy denies and both keep the one
  it allows.
- **The ordinary pod is the control that makes the result mean something.** Before the policy,
  both clients reach both servers, so the connection that will be denied is genuinely open to
  begin with. The page shows that opening state, then the after state, for both clients in one
  run.
- **Enforced on the node, outside the guest.** The node's network policy agent attaches the
  enforcement to the pod's host-side interface, so a command run inside the sandbox, even as
  root, is subject to the policy and cannot reach the denied server.
- **It opts in with one line.** `runtimeClassName: isolated-sandbox` is the only spec field
  that differs between the two clients.

*Figure 1: The same egress NetworkPolicy on two clients. `client-sandboxed` runs in a
lightweight VM in a Nitro Partition; `client-standard` is an ordinary pod. The policy, enforced
on the node outside the guest, allows each client to CoreDNS and to `web-allowed`, and refuses
`web-blocked` on both paths alike.*

![An EKS Auto Mode node holds two client pods that one Kubernetes NetworkPolicy selects by the label app netpol-client: client-standard, an ordinary pod that shares the node kernel, and client-sandboxed, a Nitro sandbox pod whose containers run in a lightweight VM inside a Nitro Partition with runtimeClassName isolated-sandbox as the only differing field. Both clients make the same egress requests to two ordinary server pods reached by pod IP on ClusterIP port 8080, web-allowed and web-blocked, and to CoreDNS. The egress NetworkPolicy is drawn as an enforcement filter that the node's network policy agent applies on each pod's host-side interface, outside the guest; its allowed paths in green are each client to web-allowed on TCP 8080 and to CoreDNS on UDP and TCP 53, and its refused path in red dashed is each client to web-blocked, refused identically on the ordinary and the sandboxed path.](images/figure-1-network-policy.png)

The files:

| File | What it is |
|---|---|
| [`deploy/web-allowed.yaml`](deploy/web-allowed.yaml), [`deploy/web-blocked.yaml`](deploy/web-blocked.yaml) | The two ordinary server pods and their ClusterIP Services, reached by pod IP on port 8080 |
| [`deploy/client-standard.yaml`](deploy/client-standard.yaml) | The ordinary client: the control |
| [`deploy/client-sandboxed.yaml`](deploy/client-sandboxed.yaml) | The sandboxed client: identical but for `runtimeClassName: isolated-sandbox` |
| [`deploy/egress-policy.yaml`](deploy/egress-policy.yaml) | The egress `NetworkPolicy` that selects both clients |
| [`scripts/run-comparison.sh`](scripts/run-comparison.sh) | Deploys everything, runs the before/after comparison on both clients, prints a verdict |
| [`scripts/show-sandbox.sh`](scripts/show-sandbox.sh) | Shows the sandboxed client running in a sandbox, next to the ordinary client |
| [`deploy/app-egress-policy.yaml`](deploy/app-egress-policy.yaml), [`deploy/client-standard-dns.yaml`](deploy/client-standard-dns.yaml), [`deploy/client-sandboxed-dns.yaml`](deploy/client-sandboxed-dns.yaml), [`scripts/run-dns-comparison.sh`](scripts/run-dns-comparison.sh) | Optional variant: egress by hostname with an `ApplicationNetworkPolicy` |

You can run the whole walkthrough with [`scripts/run-comparison.sh`](scripts/run-comparison.sh),
which does steps 1 through 5 and prints a verdict. The steps below are what it does, so you can
follow each one and read its output.

## Versions

Nothing is pinned beyond the images in the manifests: the clients and the servers use stock
images, pinned by tag, and the sample installs no controller, SDK, client library or chart of
its own. Network policy enforcement is a cluster feature turned on with the `amazon-vpc-cni`
ConfigMap (step 1), and the `ApplicationNetworkPolicy` API in the optional variant is installed
by EKS Auto Mode.

| Component | Pin | Latest (2026-10-16) |
|---|---|---|
| Client image ([`alpine`](https://gallery.ecr.aws/docker/library/alpine)) | `public.ecr.aws/docker/library/alpine:3.20` | 3.20 |
| Server image ([`python`](https://gallery.ecr.aws/docker/library/python)) | `public.ecr.aws/docker/library/python:3.12-alpine` | 3.12-alpine |

**Step 1: Turn on network policy enforcement.** EKS Auto Mode accepts network policies without
enforcing them until the Network Policy Controller is enabled, once per cluster, through the
`amazon-vpc-cni` ConfigMap in `kube-system`. This affects the whole cluster; pods that no policy
selects are unaffected. If you have run the [coding agent](../../getting-started/coding-agent/README.md)
sample this is already on; otherwise:

```bash
kubectl get configmap -n kube-system amazon-vpc-cni \
  -o jsonpath='{.data.enable-network-policy-controller}{"\n"}'
```

If that prints `true`, enforcement is on. If it prints nothing, turn it on, once per cluster
([EKS network policy documentation](https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html)):

```bash
kubectl patch configmap -n kube-system amazon-vpc-cni --type merge \
  -p '{"data":{"enable-network-policy-controller":"true"}}'
```

The comparison script checks this setting and points you here if it is off, rather than changing
this shared setting for you.

**Step 2: Deploy the two servers and the two clients.** The servers are ordinary pods, each a
stock HTTP server reached by its pod IP on a ClusterIP port. The two clients are identical but
for one line: `client-sandboxed` sets `runtimeClassName: isolated-sandbox`, `client-standard`
does not.

```bash
kubectl apply -f deploy/web-allowed.yaml
kubectl apply -f deploy/web-blocked.yaml
kubectl apply -f deploy/client-standard.yaml
kubectl apply -f deploy/client-sandboxed.yaml
for p in web-allowed web-blocked client-standard client-sandboxed; do
  kubectl wait pod/$p --for=condition=Ready --timeout=300s
done
```

Here are the two client specs side by side. Every field a policy could select on is the same;
the highlighted line is the only difference.

```yaml
# client-standard.yaml                      # client-sandboxed.yaml
apiVersion: v1                              apiVersion: v1
kind: Pod                                   kind: Pod
metadata:                                   metadata:
  name: client-standard                       name: client-sandboxed
  labels:                                     labels:
    app: netpol-client                          app: netpol-client
    role: standard                              role: sandboxed
spec:                                       spec:
                                              runtimeClassName: isolated-sandbox   # <-- only this
  containers:                                 containers:
    - name: client                              - name: client
      image: .../alpine:3.20                      image: .../alpine:3.20
      command: ["sh","-c", ...]                   command: ["sh","-c", ...]
```

The first sandboxed pod on a new cluster waits for Auto Mode to launch a sandbox-capable node;
after that a new one is Ready in about 5 to 6 seconds.

**Step 3: Before the policy, each client reaches both servers.** Read the two servers' pod IPs,
then make each client fetch each server. With no policy yet, all four succeed, so the connection
that the policy will deny is genuinely open to begin with:

```bash
ALLOWED_IP=$(kubectl get pod web-allowed -o jsonpath='{.status.podIP}')
BLOCKED_IP=$(kubectl get pod web-blocked -o jsonpath='{.status.podIP}')
for c in client-standard client-sandboxed; do
  for s in "web-allowed:$ALLOWED_IP" "web-blocked:$BLOCKED_IP"; do
    name=${s%%:*}; ip=${s##*:}
    echo -n "$c -> $name ($ip): "
    kubectl exec $c -- wget -q -T 8 -O /dev/null "http://$ip:8080/" && echo reached || echo FAILED
  done
done
```

```text
client-standard  -> web-allowed (192.168.165.37): reached
client-standard  -> web-blocked (192.168.165.36): reached
client-sandboxed -> web-allowed (192.168.165.37): reached
client-sandboxed -> web-blocked (192.168.165.36): reached
```

**Step 4: Apply the policy and wait for its `PolicyEndpoint`.**
[`egress-policy.yaml`](deploy/egress-policy.yaml) is a standard `networking.k8s.io/v1`
`NetworkPolicy` — the kind platform teams already use, with no sandbox-specific fields. It
selects both clients (`app: netpol-client`), allows egress to `web-allowed` on 8080 and to
CoreDNS on 53, and lists `Egress` in `policyTypes`, which makes everything else the default-deny
for the selected pods. CoreDNS is allowed by its Service IP with an `ipBlock`: EKS Auto Mode runs
CoreDNS locally on each node and matches DNS by that fixed Service IP, the same way
[Getting started > Coding agent](../../getting-started/coding-agent/README.md) allows it. Fill in
`<COREDNS_IP>` with your cluster's CoreDNS address (the script does this for you):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: netpol-client-egress
spec:
  podSelector:
    matchLabels:
      app: netpol-client          # selects BOTH clients
  policyTypes:
    - Egress
  egress:
    - to:                         # allow: the web-allowed server, by pod label, on its port
        - podSelector:
            matchLabels:
              app: web-allowed
      ports:
        - { protocol: TCP, port: 8080 }
    - to:                         # allow: CoreDNS, so name lookups keep working
        - ipBlock: { cidr: <COREDNS_IP>/32 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
```

Egress to `web-blocked` matches no allow rule, so it is refused. Apply the policy and wait for
its `PolicyEndpoint` before you judge enforcement: it shows the controller has picked the policy
up and handed it to the nodes, and the datapath is programmed a few seconds after the policy
lands. The `until` loop below is bounded so it cannot hang: if no `PolicyEndpoint` appears within
about two minutes, it stops and tells you the controller has not programmed the policy (check the
`amazon-vpc-cni` enforcement setting from step 1 and the network-policy-agent pods).

```bash
COREDNS_IP=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')
sed "s|<COREDNS_IP>|$COREDNS_IP|" deploy/egress-policy.yaml | kubectl apply -f -
for i in $(seq 1 60); do
  kubectl get policyendpoints -o name 2>/dev/null \
    | grep -q '^policyendpoint.networking.k8s.aws/netpol-client-egress-' && break
  [ "$i" = 60 ] && { echo "no PolicyEndpoint after ~2m -- is enforcement on? (step 1)"; break; }
  sleep 2
done
kubectl get networkpolicies,policyendpoints

```text
NAME                                                   POD-SELECTOR        AGE
networkpolicy.networking.k8s.io/netpol-client-egress   app=netpol-client   12s

NAME                                                           AGE
policyendpoint.networking.k8s.aws/netpol-client-egress-m7bn4   6s
```

**Step 5: After the policy, each client keeps `web-allowed` and loses `web-blocked`.** Run the
same four requests again. A refused egress shows up as a connection that never completes: the
`wget -T 8` times out after 8 seconds. An allowed one returns at once.

```bash
for c in client-standard client-sandboxed; do
  for name_ip in "web-allowed:$ALLOWED_IP" "web-blocked:$BLOCKED_IP"; do
    name=${name_ip%%:*}; ip=${name_ip##*:}
    echo -n "$c -> $name: "
    kubectl exec $c -- wget -q -T 8 -O /dev/null "http://$ip:8080/" && echo reached || echo "timed out (refused)"
  done
done
```

```text
client-standard  -> web-allowed: reached
client-standard  -> web-blocked: timed out (refused)
client-sandboxed -> web-allowed: reached
client-sandboxed -> web-blocked: timed out (refused)
```

Both clients lost exactly the one egress the policy denies and both kept the one it allows. The
sandboxed path behaved exactly as the ordinary path.

**From inside the sandbox.** The enforcement lives on the node, so a command run inside the
sandbox, even as root, cannot bypass it. Exec into the sandboxed client and make the same request
to `web-blocked`:

```bash
kubectl exec client-sandboxed -- wget -q -T 8 -O /dev/null "http://$BLOCKED_IP:8080/" \
  && echo reached || echo "timed out (refused)"
```

```text
timed out (refused)
```

## Reading the result

Because the ordinary client makes the same request on the node's normal path, the two results
together tell the outcomes apart. Read them with this table:

| `client-standard` → blocked | `client-sandboxed` → blocked | Meaning |
|---|---|---|
| refused | refused | The policy is enforced on the sandboxed path, as on the ordinary path. This is the result above. |
| refused | reached | The policy holds on the ordinary path but not on the sandboxed one. Stop and report it before writing the page. |
| reached | either | Enforcement is not on for the cluster (step 1); the comparison shows nothing about the sandbox. |

**Naming the refusal shapes, so a block is not mistaken for a broken cluster.** A refused egress
to a pod IP is a connection that gets no reply and runs to the timeout — what you see above, and
the shape this sample demonstrates. One other shape is worth knowing about so it is not misread:
when the denied target is a *name* that also publishes IPv6 (AAAA) records, a client that tries
the IPv6 address can fail at once with `Network is unreachable`, because the sandbox has no route
to global IPv6, rather than timing out on IPv4. The scripts here do not capture that message (the
probe tools report only reached-or-not), so treat it as background: both shapes mean the same
thing — the address is not in the allow list.

## The sandboxed client is really in a sandbox

The same evidence [Hello sandbox](../../getting-started/hello-sandbox/README.md) shows: the
sandboxed client runs its own kernel build, its uptime matches the pod's age because the VM
booted with the pod, and it sees virtio disks. Run
[`scripts/show-sandbox.sh`](scripts/show-sandbox.sh), or by hand (the `echo` prints the heading
each block shows below):

```bash
for p in client-sandboxed client-standard; do
  echo "# $p"
  kubectl exec $p -- sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo'
done
```

```text
# client-sandboxed
6.18.51 #1 SMP PREEMPT_DYNAMIC Thu Oct  1 23:28:07 UTC 2026
71.71
dm-0 vda vdb vdc
# client-standard
6.18.51 #2 SMP PREEMPT_DYNAMIC Wed Oct  7 22:33:11 UTC 2026
155191.57
dm-0 nvme0n1 nvme1n1 nvme2n1 nvme3n1 zram0
```

The sandboxed client's uptime (about 72 seconds) matches its pod's age, and it sees virtio disks
(`vda`, `vdb`, `vdc`); the ordinary client reports the node's uptime (about 43 hours) and the
instance's `nvme` disks. The kernel version string is the same for both, `6.18.51`; the build
(`#1` versus `#2`, and the date) and the boot are not.

## Optional: egress by hostname

A standard `NetworkPolicy` can only allow addresses — pods, namespaces, CIDRs. The EKS Auto Mode
`ApplicationNetworkPolicy` accepts the same fields plus `domainNames` in an egress rule, so you
can allow an endpoint by name. This variant reuses that pattern from
[Getting started > Coding agent](../../getting-started/coding-agent/README.md) and shows the same
side-by-side result for name-based egress: a second identical client pair
(`app: netpol-client-dns`) whose policy allows one AWS endpoint by name and refuses another.

[`app-egress-policy.yaml`](deploy/app-egress-policy.yaml) allows CoreDNS and
`sts.<AWS_REGION>.amazonaws.com`, and nothing else, so `kms.<AWS_REGION>.amazonaws.com` is
refused. Run it with [`scripts/run-dns-comparison.sh`](scripts/run-dns-comparison.sh) (set
`AWS_REGION` first; it fills in your CoreDNS address from the cluster, so no account value is
written into a tracked file):

```bash
export AWS_REGION=us-west-2
scripts/run-dns-comparison.sh
```

Like the main script, it proves the open control state first (both clients reach both endpoints
before the policy), then applies the policy and re-reads, then prints a verdict. Abridged:

```text
=== BEFORE the policy: each client reaches both endpoints (the open control state) ===
client-standard-dns    allowed(sts.us-west-2.amazonaws.com)=reached    blocked(kms.us-west-2.amazonaws.com)=reached
client-sandboxed-dns   allowed(sts.us-west-2.amazonaws.com)=reached    blocked(kms.us-west-2.amazonaws.com)=reached

=== AFTER the policy: sts.us-west-2.amazonaws.com allowed, kms.us-west-2.amazonaws.com refused ===
client-standard-dns    allowed(sts.us-west-2.amazonaws.com)=reached    blocked(kms.us-west-2.amazonaws.com)=refused
client-sandboxed-dns   allowed(sts.us-west-2.amazonaws.com)=reached    blocked(kms.us-west-2.amazonaws.com)=refused

=== Verdict ===
RESULT: name-based egress is enforced on the sandboxed path exactly as on the
ordinary path -- both keep sts.us-west-2.amazonaws.com and are refused kms.us-west-2.amazonaws.com.
```

Before the policy both clients reach both endpoints; after it, the allowed name connects and the
other is refused, on the ordinary and the sandboxed path alike — name-based egress is enforced on
the sandboxed pod exactly as address-based egress is.

## Clean up

Remove the pods and the policy this sample created. These scripts and commands do not touch the
cluster-wide enforcement setting from step 1; if you turned it on, it stays on until you remove it
(see the note below).

```bash
scripts/run-comparison.sh --cleanup
scripts/run-dns-comparison.sh --cleanup   # only if you ran the optional variant
```

Or by hand:

```bash
kubectl delete -f deploy/egress-policy.yaml --ignore-not-found
kubectl delete -f deploy/client-standard.yaml -f deploy/client-sandboxed.yaml --ignore-not-found
kubectl delete -f deploy/web-allowed.yaml -f deploy/web-blocked.yaml --ignore-not-found
```

The network policy enforcement is cluster-wide, and if you enabled it in step 1 this sample does
not turn it back off. Deleting the cluster removes it. On a cluster you keep, leave it on (it only
enforces policies that select a pod), or, if nothing else relies on it, turn it off by setting the
`amazon-vpc-cni` ConfigMap's `enable-network-policy-controller` back to `"false"` (or removing the
key). If it was already on before you started, leave it.
