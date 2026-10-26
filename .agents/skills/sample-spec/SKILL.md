---
name: sample-spec
description: Write the spec for a new sample in this repository as a GitHub issue, before any implementation starts. Use when someone proposes a new sample or demo, picks up a roadmap entry, or asks to start building one. Produces the issue body (summary, what the sample shows, proposed layout, versions, acceptance criteria, cost note) and the gh command that files it.
---

# Write a sample spec as a GitHub issue

A new sample starts as a spec in a GitHub issue. Nobody writes manifests, code or a page
for it until the issue exists, and the pull request that implements it says
`Closes #<issue>`. The issue is where scope and the definition of done are agreed, so the
review of the pull request checks against criteria everyone saw first.

Issue #2 (`gh issue view 2 --repo aws-samples/sample-eks-nitro-sandbox`) is the model:
follow its shape and its level of detail. Paths below are relative to the repository root.

## The flow

1. **Check it is new.** Read `docs/ROADMAP.md` for the planned entry and its section, and
   search the open issues:
   `gh issue list --repo aws-samples/sample-eks-nitro-sandbox --search "<name>" --state all`.
2. **Read the closest existing samples** under `examples/` before writing anything. Reuse
   their patterns (the agent-sandbox `SandboxTemplate` and warm pool, Pod Identity, a
   Secret read from a file) instead of inventing new ones, and say in the spec which sample
   it builds on. One pattern not to reuse: most of those pages ship an egress network
   policy, which a new sample does not. See [Network](#network) below.
3. **Write the spec** with the sections below.
4. **File it** with the **Sample spec** issue form (`.github/ISSUE_TEMPLATE/sample-spec.yml`)
   or with `gh`, as shown at the end.
5. **Agree it.** Implementation starts once the maintainers accept the spec and the issue
   is not labeled `blocked` (see [When a spec is blocked](#when-a-spec-is-blocked)).
   Whoever implements it claims it first, as "A sample starts as a spec in a GitHub issue"
   in `AGENTS.md` describes: a comment, the assignee and the `in progress` label. An issue
   that is assigned or labeled `in progress` belongs to someone else.
6. **Branch and build.** Use a branch named after the sample, follow the `sample-page`
   skill, and open one pull request for the whole issue, whose description starts with
   `Closes #<issue>`. A spec too big for one pull request is split into separate issues
   before anyone starts, not delivered in parts.

## The sections

**Title:** `Add sample: <Readable name>`.

**Summary.** Two to four sentences: what runs, which part runs in a Nitro sandbox (name the
runtime class, normally `runtimeClassName: isolated-sandbox`), and which part stays an
ordinary pod. Link the upstream project's own documentation. Say where the sample sits on
the roadmap, or that it is new.

**What the sample shows.** Three to five bullets, each led by a short bold claim. Every
claim must be something the page will show with real output from a run: the pod's own
kernel, boot and disks, a key that is absent, a connection that succeeds, or a refusal
something in the sample enforces. Leave out claims the sample cannot demonstrate, and see
[Network](#network) before you write a refusal: a new sample ships no network policy, so a
networked one usually has no refused connection to show. Mark optional variants as optional.

**Proposed layout.** A text tree under `examples/<section>/<sample>/`, following
`docs/ROADMAP.md`: a named folder (never numbered), the page as `README.md`, diagrams in
`images/`, manifests in `deploy/`, operator-side scripts in `scripts/`, source in `src/`.
Comment each entry. Then say which `mkdocs.yml` nav section the page goes in and that the
roadmap is updated.

**Versions.** When the sample pins anything beyond the cluster (a controller, an SDK, a
client library, a chart), a table of every pinned component with a link to each; otherwise
say "Nothing pinned beyond the images in the manifests":

| Component | Pin | Latest (YYYY-MM-DD) |
|---|---|---|

Call out major-version jumps and what must be re-checked because of them (API calls, not
only version strings).

**Network.** Decide whether the sandbox needs a network at all, and write the criterion to
match. **A new sample does not ship a network policy**, and a spec must not ask for one:
`examples/isolation/network-policy` is the one sample about that mechanism, and a new page
links it rather than repeating it. The maintainers set this on 2026-10-26.

- A workload that connects nowhere boots with
  `sandbox.amazonaws.com/network-isolated: "true"`, and the criterion is that the page
  shows it has only loopback, no route and no DNS. That is a property of the sandbox the
  spec asked for, so it is a limit the sample can claim and prove.
- A workload that does connect keeps its network, with no policy. The criterion names what
  it connects to and what the page shows of that connection working. **It must not claim
  the workload cannot reach anything else**, because nothing in the sample stops it: write
  the criterion as "the page shows the agent reaching `<service>`", never "the page shows
  the agent cannot reach the internet".
- Either way, name the limit the sample *does* enforce. Where the sample gives the pod AWS
  permissions, that is usually the Pod Identity role, and the criterion is that the role
  grants only what the sample needs and the page shows its policy document. Where it gives
  none, do not invent a role for the spec to point at: the limits to name are the ones the
  sample really has, such as the VM boundary, a sandbox with no network, or its RBAC.

Why: a spec that asks for a restriction the sample has no mechanism for puts a claim on the
page that nothing enforces, and a reader would believe it. One earlier spec also gave a
workload that connects nowhere a deny-all egress policy while refusing exec, so no run could
ever have shown the policy working.

Specs written before 2026-10-26, and the samples merged from them, carry the old criterion.
Leave those pages alone; they were proved with the policies they show.

**Cluster prerequisites.** Name anything cluster-wide the sample needs, such as a
controller, a CSI driver or an add-on, and make it a step the reader runs once, which the
sample's setup checks rather than performs. Check each one against the Amazon EKS User Guide
rather than assuming the platform provides it: EKS Auto Mode does not create a StorageClass,
for example. Why: one spec said Auto Mode supplied the class, and a test cluster that
happened to have one hid the mistake.

For a controller, CSI driver or add-on, say what the sample does when it is already
installed: it reuses it as it is ("A shared install is reused as it is, never changed" in
`AGENTS.md`). A spec never asks the sample to change a shared install's values, service
accounts, IAM roles or Pod Identity associations. If the sample needs a change like that, the
spec makes it a reader step and says what it does to the install's other users. Why: an
install already on the cluster belongs to whoever put it there.

**Storage class.** A sample that provisions EBS volumes says which class its claims use, and
its setup chooses it:

- If the cluster's default StorageClass fits (provisioner `ebs.csi.eks.amazonaws.com`, and
  the type and encryption the sample needs), the claims name that class and setup creates
  nothing.
- Otherwise setup creates the sample's own class: named for the sample, not the default,
  marked as the sample's, created only when absent. The claims name it, and the clean up
  deletes it when it carries the mark.

Why: a sample must not change the class every other workload provisions through, and must
still run on a cluster that has no suitable default.

**Acceptance criteria.** A checklist. Start from these and add the sample's own:

- [ ] Sample folder at `examples/<section>/<sample>/`, laid out as above.
- [ ] Pinned versions stated in the README.
- [ ] Runs end to end on a cluster that has finished Getting started, from a fresh run.
- [ ] The README shows the sandbox pod running in a sandbox (its own kernel build, boot and virtio disks, each with what an ordinary pod shows instead), plus the sample's own claims, each with output from the run.
- [ ] No Ingress, LoadBalancer or NodePort.
- [ ] The sample ships no network policy, and the page claims no network limit that nothing in the sample enforces. Where the sample has a sandbox that needs no network, it boots with `sandbox.amazonaws.com/network-isolated: "true"` and the page shows it has only loopback, no route and no DNS.
- [ ] If the sample gives the pod AWS permissions, its Pod Identity role grants only what the sample needs and the page shows its policy document. If it gives none, the page says so and claims no limit from a role.
- [ ] No values from your own account or environment (account ID, keys, tokens, names of your clusters or hosts, user names, internal URLs) in tracked files. Local values come from a gitignored env file.
- [ ] A clean-up section removes everything the sample created.
- [ ] Added to the `mkdocs.yml` nav, and `mkdocs build --strict` passes.
- [ ] `docs/ROADMAP.md` lists the sample as available.
- [ ] Listed in the root `README.md`, and `./scripts/check-sample-index.sh` passes.

**Cost note.** One or two lines on what a run costs beyond the cluster: model tokens, API
credit, a NAT gateway, a large instance. Say "No cost beyond the cluster" when that is true.

## What a spec leaves out

- Values from your own account or environment, including in example output. Use
  placeholders.
- Implementation detail that belongs in the pull request: file contents, code.
- Product details that the site's pages and the public AWS documentation do not state.
  The `nitro-sandbox-pods` skill lists what is safe to rely on.

## File it with gh

Write the body to a scratch file, then:

```bash
gh issue create --repo aws-samples/sample-eks-nitro-sandbox \
  --title "Add sample: <Readable name>" --label enhancement \
  --body-file "$SPEC_FILE"
```

`gh` prints the issue URL; the number at its end is what the pull request closes.

## When a spec is blocked

Label an issue `blocked` when it waits on something outside this repository and its
maintainers: a product launch, an upstream release, or a feature another project has not
shipped. Issue #22 is the model: it waits for general availability and for a change in
upstream OpenSandbox.

- **File the spec anyway**, so the sample is on the roadmap and ready to start. Open the
  body with a warning that says what it waits for, and make `Unblocked: <condition>` the
  first acceptance criterion.
- **Add the label** when you file it (`--label enhancement --label blocked`), or later with
  `gh issue edit <number> --repo aws-samples/sample-eks-nitro-sandbox --add-label blocked`.
- **Mark the roadmap entry** `(blocked until <condition>)`.
- **Do not implement a `blocked` issue.** Remove the label and the roadmap marker only once
  the condition is met, and say in an issue comment what changed.

A prove-first item still to be tried is not a block; the spec says to try it first. If it
fails because of something outside the repository, update the issue with what failed and
add the label then.

## Body template

```markdown
## Summary

<What runs, which part is in a Nitro sandbox (runtimeClassName: isolated-sandbox), which
part stays an ordinary pod. Link to the upstream docs. Roadmap position.>

## What the sample shows

- **<Claim>.** <How the page shows it.>
- **<Claim>.** <How the page shows it.>

## Proposed layout

Following the conventions in `docs/ROADMAP.md`:

    examples/<section>/<sample>/
    ├── README.md          # the website page
    ├── deploy/            # manifests the sample applies
    ├── scripts/           # operator-side scripts
    └── images/            # diagrams (.drawio and .png)

Plus a `<Section>` entry in the `mkdocs.yml` nav and a roadmap update.

## Versions

| Component | Pin | Latest (YYYY-MM-DD) |
|---|---|---|
| <name> ([link](<url>)) | <version> | <version> |

## Acceptance criteria

- [ ] <criteria from the skill, then the sample's own>

Note: <cost of a run beyond the cluster>.
```
