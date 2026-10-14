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
   their patterns (the agent-sandbox `SandboxTemplate` and warm pool, Pod Identity, the
   egress network policy) instead of inventing new ones, and say in the spec which sample
   it builds on.
3. **Write the spec** with the sections below.
4. **File it** with the **Sample spec** issue form (`.github/ISSUE_TEMPLATE/sample-spec.yml`)
   or with `gh`, as shown at the end.
5. **Agree it.** Implementation starts once the maintainers accept the spec.
6. **Branch and build.** Use a branch named after the sample, follow the `sample-page`
   skill, and open a pull request whose description starts with `Closes #<issue>`.

## The sections

**Title:** `Add sample: <Readable name>`.

**Summary.** Two to four sentences: what runs, which part runs in a Nitro sandbox (name the
runtime class, normally `runtimeClassName: isolated-sandbox`), and which part stays an
ordinary pod. Link the upstream project's own documentation. Say where the sample sits on
the roadmap, or that it is new.

**What the sample shows.** Three to five bullets, each led by a short bold claim. Every
claim must be something the page will show with real output from a run: the pod's own
kernel, boot and disks, a key that is absent, a connection that is refused. Leave out
claims the sample cannot demonstrate. Mark optional variants as optional.

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

**Acceptance criteria.** A checklist. Start from these and add the sample's own:

- [ ] Sample folder at `examples/<section>/<sample>/`, laid out as above.
- [ ] Pinned versions stated in the README.
- [ ] Runs end to end on a cluster that has finished Getting started, from a fresh run.
- [ ] The README shows the sandbox pod running in a sandbox (its own kernel build, boot and virtio disks, each with what an ordinary pod shows instead), plus the sample's own claims, each with output from the run.
- [ ] No Ingress, LoadBalancer or NodePort. Sandbox egress is restricted by network policy and the page shows the complete policy, or the sandbox boots with no network and the page shows that.
- [ ] No values from your own account or environment (account ID, keys, tokens, names of your clusters or hosts, user names, internal URLs) in tracked files. Local values come from a gitignored env file.
- [ ] A clean-up section removes everything the sample created.
- [ ] Added to the `mkdocs.yml` nav, and `mkdocs build --strict` passes.
- [ ] `docs/ROADMAP.md` lists the sample as available.

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
