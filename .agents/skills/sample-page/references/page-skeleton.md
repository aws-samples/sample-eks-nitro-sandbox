# Page skeleton

Copy the block below to `examples/<section>/<sample>/README.md` and replace every `<...>`.
Delete the parts the sample does not need. The relative links assume the page is two
folders below `examples/`, as every sample is.

````markdown
# <The outcome, in sentence case>

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
sample first so you have a cluster with the runtime classes. The commands below use files
from this repository, so clone it if you have not already, and run them from this sample's
folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/<section>/<sample>
```

For this sample you also need <extra tools and accounts>. <What a run costs beyond the
cluster.>

<Two or three short paragraphs: the problem, and how this sample places the risky part in
a Nitro sandbox.>

- **<Bold claim>.** <What runs where.>
- **<Bold claim>.** <What each part can reach, and what is refused.>

*Figure 1: <One sentence on what the figure shows.>*

![<Full-sentence alt text that describes every part of the figure and how they connect.>](images/<name>.png)

This folder was built against these releases:

| Component | Version |
|---|---|
| <name> ([link](<url>)) | <version> |

The files:

| File | What it is |
|---|---|
| [`deploy/<file>.yaml`](deploy/<file>.yaml) | <What it is> |

**Step 1: <Action>.** <Two or three sentences: input, component, purpose.>

```yaml
<the relevant excerpt, verbatim from the file>
```

```bash
<command>
```

```text
<output from a fresh run; say "Abridged" when it is>
```

<One sentence on what to look at in the output.>

**Step 2: Apply the network policy.** [`egress-policy.yaml`](deploy/egress-policy.yaml)
selects the sandbox pods. Here it is in full, without its header comment;
[How the network policy works](#how-the-network-policy-works) explains each rule:

```yaml
<the complete policy>
```

```bash
COREDNS_IP=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')
sed "s|<COREDNS_IP>|$COREDNS_IP|" deploy/egress-policy.yaml | kubectl apply -f -
until kubectl get policyendpoints -o name | grep -q '^policyendpoint.networking.k8s.aws/<policy-name>-'; do sleep 2; done
```

**Step 3: Look inside the sandbox.** <Show the proof: runtime class, guest kernel build,
uptime, virtio disks, credential variable names without values.>

## How the network policy works

| In the YAML | What it does |
|---|---|
| `podSelector`, `<label>` | <Which pods it selects> |
| `policyTypes`, `Ingress` and `Egress` | Makes the selected pods default-deny in both directions. |
| `egress`, to `<COREDNS_IP>/32` on UDP and TCP 53 | Lets the sandbox look up names with CoreDNS. |
| `egress`, to `domainNames: <host>` on TCP 443 | <Why the sandbox needs it> |

**Where it is enforced.** <On the node, outside the guest.>

<The limits: addresses, not names; the pod's own node.>

## Good to know

- **<Limit>.** <What it means for the reader.>

## Clean up

The commands use the variables from the walkthrough. In a new shell, set them again first,
with the values you used:

```bash
export CLUSTER_NAME=sandbox-demo AWS_REGION=us-west-2 NAMESPACE=nitro-sandboxes-demo
```

```bash
<delete in reverse order of creation>
```

If this is the last sample you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove
the namespace and the cluster.
````
