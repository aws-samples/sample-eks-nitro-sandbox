# Page skeleton

Copy the block below to `examples/<section>/<blueprint>/README.md` and replace every `<...>`.
Delete the parts the blueprint does not need. The relative links assume the page is two
folders below `examples/`, as every blueprint is.

````markdown
# <The outcome, in sentence case>

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
blueprint first so you have a cluster with the runtime classes. The commands below use files
from this repository, so clone it if you have not already, and run them from this blueprint's
folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/<section>/<blueprint>
```

For this blueprint you also need <extra tools and accounts>. <What a run costs beyond the
cluster.>

<Two or three short paragraphs: the problem, and how this blueprint places the risky part in
a Nitro sandbox.>

- **<Bold claim>.** <What runs where.>
- **<Bold claim>.** <What each part connects to. Claim a limit only where this blueprint is
  what enforces it: the pod's Pod Identity role, or a sandbox booted with no network at
  all. With no network policy, a sandbox that has a network reaches what any pod reaches.>

*Figure 1: <Title>. <One or two sentences on what the reader should notice.>*

![<Alt text in reading order: each boundary, what runs inside it, and each connection with its label. Draw a refused destination only where this blueprint refuses it.>](images/<name>.png)

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

<Step 2 only when the blueprint gives the pod AWS permissions. A blueprint that calls no AWS API
creates no role; delete this step and say on the page that it creates no Pod Identity
association.>

**Step 2: Give the pod a role.** <The ServiceAccount, the Pod Identity association, and the
role's policy document in full. This is a limit the blueprint enforces, so show what it permits
and nothing wider.>

```yaml
<the policy document, verbatim>
```

```bash
<command>
```

```text
<output from a fresh run>
```

**Step 3: Look inside the sandbox.** <Show the proof: runtime class, guest kernel build,
uptime, virtio disks, credential variable names without values.>

## Good to know

- **<Limit>.** <What it means for the reader.>

<Then exactly one of the two bullets below, whichever is true of this blueprint. Delete the
other: they contradict each other, and the wrong one is a claim the blueprint does not back.>

- **This blueprint does not restrict where the pod can connect.** It has a network, so it
  reaches what any pod on the cluster reaches. To restrict it, see the
  [network policy](../../isolation/network-policy/README.md) blueprint.
- **This sandbox has no network at all.** It boots with
  `sandbox.amazonaws.com/network-isolated: "true"`, so only `lo` has an address, there is no
  route and a lookup fails, as the step above shows. To restrict a sandbox that does have a
  network, see the [network policy](../../isolation/network-policy/README.md) blueprint.

## Clean up

The commands use the variables from the walkthrough. In a new shell, set them again first,
with the values you used (these are the shared defaults from the home page):

```bash
export CLUSTER_NAME=sandbox-demo AWS_REGION=us-west-2 NAMESPACE=nitro-sandboxes-demo
```

```bash
<delete in reverse order of creation>
```

If this is the last blueprint you ran, follow the
[hello sandbox](../../getting-started/hello-sandbox/README.md#clean-up) clean up to remove
the namespace and the cluster.
````
