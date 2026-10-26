---
name: sample-page
description: Build a sample in this repository and write its page (the sample folder's README.md) so it matches the existing samples - folder layout, stages that pair a short explanation with a diagram, the real code and the observed result, what to say about the network and what to link instead of a policy, clean up, the nav entry and the roadmap update. Use after the sample's spec issue exists, when implementing a sample, writing or revising a sample page, or checking one before a pull request.
---

# Build a sample and write its page

A sample is a page a reader follows on their own account, and a page someone presents
live. Each stage shows what the reader configures, where it takes effect, and how to
recognise the result, with output from a real run.

Paths below are relative to the repository root. Before you start:

1. **The spec issue exists and is agreed.** If it does not, use the `sample-spec` skill
   first. The pull request will say `Closes #<issue>`.
2. **Read the closest samples** and reuse their patterns:
   - `examples/getting-started/hello-sandbox/README.md`: the one-line opt-in, the proof
     that the pod runs in a VM, and a network-isolated pod shown to have only loopback.
   - `examples/getting-started/coding-agent/README.md`: Pod Identity, and a Secret read
     from a file.
   - `examples/getting-started/warm-pool/README.md`: agent-sandbox `SandboxTemplate`,
     `SandboxWarmPool` and `SandboxClaim`.
   - `examples/managed-agents/claude-managed-agents/README.md`: the full layout (`deploy/`,
     `scripts/`, `src/`), a versions table, an optional mode, "Good to know" and a
     thorough clean up.
   - `examples/isolation/network-policy/README.md`: the one sample that is about network
     policy. Link it from your page; do not copy it.

   **One thing in those pages is not the pattern to copy: their network policies.** Most of
   them ship an egress policy and explain it in a "How the network policy works" section,
   because that was the rule until the maintainers changed it on 2026-10-26. A new sample
   does not, and
   [The network: what to say, and what to link](#the-network-what-to-say-and-what-to-link)
   below says what to do instead. **Those pages are correct as they stand: they were proved
   with the policies they show, and nobody edits them to match this change.** Reuse
   everything else about them.
3. **Use the `nitro-sandbox-pods` skill** for every statement about how the sandbox works,
   and the `aws-diagrams` skill for every figure.

## Layout

```text
examples/<section>/<sample>/      # named, never numbered; section from docs/ROADMAP.md
├── README.md                     # the page
├── deploy/                       # manifests the sample applies (or at the top level when there are few)
├── scripts/                      # operator-side scripts the reader runs on their machine
├── src/                          # source for any image the sample builds
├── Dockerfile
├── .env.example                  # the local values the sample needs, with no values filled in
├── .gitignore                    # ignores .env and other local files
└── images/                       # <name>.drawio and <name>.png for each figure
```

Do not add any other `.md` file under `examples/`. `docs_dir` is `examples/`, so every
Markdown file there is published as a page.

Manifests use placeholders such as `<ACCOUNT_ID>`, `<AWS_REGION>` and `<COREDNS_IP>`, which
the page fills in with `sed` at apply time. Real values live in a gitignored local env file.

## Page structure

Follow this order. `references/page-skeleton.md` has it as a starting file.

1. **Title**: the outcome, in sentence case.
2. **Prerequisites and clone.** A paragraph linking the shared prerequisites on the home
   page (`../../README.md#prerequisites` from a page two folders below `examples/`) and
   the samples this one builds on, then the clone block:

   ```bash
   git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
   cd sample-eks-nitro-sandbox/examples/<section>/<sample>
   ```

   Then anything extra this sample needs, including each command-line tool its scripts
   call on the reader's machine (for example `notation` or `oras`) with the version the
   run used and where to get it, and what a run costs beyond the cluster.
3. **Overview.** Two or three short paragraphs and a few bullets, each led by a bold claim:
   what runs in the sandbox, what stays an ordinary pod, and what each part reaches. Write
   what the sample's own mechanisms limit and nothing more:
   [The network: what to say, and what to link](#the-network-what-to-say-and-what-to-link)
   below. Then the overview figure.
4. **Versions** table when anything is pinned, and a **files** table linking each file.
5. **Steps.** `**Step N: <Action>.**` leads each one, as on the existing pages.
6. **Optional variants** as `## Optional: <variant>` sections.
7. **Good to know**: the limits that change what a reader can rely on, kept visible.
8. **Clean up.**

There is no network policy section, and no step that applies a policy. That is deliberate,
and [The network: what to say, and what to link](#the-network-what-to-say-and-what-to-link)
says what the page does instead.

Put long reference material (a reading of the enforcement on a node, a second mode's clean
up) in a collapsible block. The existing pages use `<details><summary>...</summary>`, which
renders on GitHub and on the site; the site also supports `???` blocks (pymdownx.details),
which render on the site only. Never hide a limit that changes the headline claim.

## Compose each stage

Each step is one small unit, in this order:

1. **An action lead**: what happens, such as "Give the pod a role" or "Claim one".
2. **A short explanation**: usually two or three sentences on the input, the component that
   acts on it, and why.
3. **A focused diagram** when the stage has a new participant, boundary or flow. Hand it to
   the `aws-diagrams` skill. One job per figure, three to six nodes, short labels. Put an
   italic caption line (`*Figure N: ...*`) above the image and alt text that describes the
   whole figure in full sentences. Use a Mermaid block for timing or message order, as the
   warm pool page does.
4. **The real code or configuration, verbatim.** Copy the excerpt from the file in the
   folder, keep real field names and values, and say when it is trimmed ("Here is the part
   of `sandbox-template.yaml` that matters"). Never show a fragment as a complete file.
   The sample's pods set no CPU or memory requests or limits unless the sample cannot run
   without them; when they do, the page says why, and the requests and limits do not need
   to match ("Sizing and start-up" in the `nitro-sandbox-pods` skill).
5. **The command, then the observed result** in a `text` block, from a real run. Say
   "Abridged" or "your text will differ" when it is. Follow it with a sentence on what to
   look at in the output. Until you have run it, the block holds only
   `TODO: output from the fresh run`, never output you wrote yourself.

## The network: what to say, and what to link

**A new sample ships no network policy and has no network policy section.** One sample,
`examples/isolation/network-policy`, is about network policy: it shows a whole policy, each
of its rules, where it is enforced and its limits. Every other sample is about its own
subject, and sends a reader there for the mechanism. The maintainers set this on
2026-10-26. Why: one page that shows every rule of one policy teaches it better than a
section repeated in every sample.

So the page does these three things instead.

**1. Link the dedicated sample, once, where a reader would want the mechanism.** One
sentence in the overview or in "Good to know", not a section:

```markdown
To restrict where this pod can connect, see the
[network policy](../../isolation/network-policy/README.md) sample.
```

Adjust the relative path to your page's depth, and let `mkdocs build --strict` confirm it.

**2. Say only what your sample actually limits.** This is the part that goes wrong. With no
policy, a sandbox that has a network reaches what any pod on the cluster reaches, including
the internet. So the page must not say or imply otherwise:

- Do not write that the workload "cannot reach", "is cut off from", "is restricted to" or
  "only talks to" anything, unless something in this sample makes that true.
- A bullet such as "**the sandbox reaches only the API it needs**" is a claim about a
  policy. Without one, write what is actually true: what the sample has the workload
  connect to, and that nothing in the sample stops it reaching more.
- An `isolated-sandbox` pod's boundary is the VM, not the network. "Its own kernel, so a
  container escape does not reach the host" is a claim the sample proves; "it cannot call
  out" is not.
- Check the figures and their alt text too. A refused-destination arrow in red draws a
  boundary the sample does not have, and the `aws-diagrams` skill reserves that colour for
  exactly that meaning.

**3. Where the real boundary is an IAM role, scope it and show it.** When the sample gives
the pod AWS permissions, this is usually the limit that is actually enforced: the pod's EKS
Pod Identity role is what code in the sandbox can use in the reader's account. Give it only
what the sample needs, show the policy document on the page, and name what it permits. That
is a limit you can claim, because the sample creates it.

A sample that calls no AWS API has no role, and must not grow one to have a boundary to
show. Say on the page that it creates no Pod Identity association, and claim no limit from
one. The limits such a sample can claim are the ones it really has: the VM boundary of the
sandbox runtime class, a sandbox booted with no network, and whatever Kubernetes RBAC it
creates.

**A sandbox that has no network at all is a different thing, and worth showing.** A pod
booted with `sandbox.amazonaws.com/network-isolated: "true"` has no interface to restrict:
only `lo` has an address, there is no route, and a lookup fails, as the hello sandbox page
shows. That is a property of the sandbox the sample asked for, not a claim about a policy,
so show it with real output and say so plainly. If the workload connects nowhere, prefer
this to leaving it on the network with nothing said.

**What not to do.** Do not add a policy to a new sample "to be safe": it makes the page
about network policy, and the dedicated sample covers it better. Do not delete or rewrite a
merged sample's policy or its "How the network policy works" section either. Those pages
predate 2026-10-26, were proved with the policies they show, and are correct as they stand;
this rule is for new samples only. If you think one of them is wrong, raise it with the
maintainers rather than editing it.

**One platform fact this makes load-bearing.** A `SandboxTemplate` left at the default
`networkPolicyManagement: Managed` gets a controller-created `NetworkPolicy` that, with no
rules of your own, allows the public internet. So a new sample's template has a policy
object attached to it that restricts nothing. Do not point at it as though it limited
anything, and do not set `Unmanaged` unless the sample ships a policy, which a new one does
not. The `nitro-sandbox-pods` skill has the detail.

## Clean up

- Start by setting the variables again, for a reader in a new shell.
- Delete in reverse order of creation, starting with anything that would recreate pods
  (a warm pool, a Deployment).
- Remove every AWS resource the sample created: IAM roles and policies, Pod Identity
  associations (only this sample's), ECR repositories, local images.
- A clean-up script deletes only what carries the sample's `ManagedBy` tag or namespace
  label, checks the label before deleting anything inside the namespace, and exits
  non-zero when it skipped something or could not check it ("Shared accounts, clusters and
  machines" in `AGENTS.md`).
- Say what stays and why: any cluster-wide setting the reader turned on as a step, and
  shared installs such as agent-sandbox or a CSI driver, with the command to remove them.
- Link the hello sandbox clean up for removing the namespace and the cluster.

## Nav and roadmap

- Add the page to `nav` in `mkdocs.yml`, under its section heading and in roadmap order.
  Add the section heading if this is its first sample. `mkdocs build --strict` does not
  fail on a page missing from `nav`; the page just has no menu entry.
- In `docs/ROADMAP.md`, link the entry to `../examples/<section>/<sample>/README.md` and
  add `(available now)` after the link.
- Add it to the root `README.md` list for its section, in roadmap order. Add the section
  heading if this is its first sample.
- Run `./scripts/check-sample-index.sh`. It fails when any sample is missing from one of
  the three, or a conflict marker is left in a tracked file.
- When `main` has moved, merge it in and resolve the index files by keeping both sides
  ("Keep a pull request current with `main`" in `AGENTS.md`).

## Wording

- **pod** for the running unit you pool, claim, adopt, exec into or delete: "a warm pod",
  "each session gets its own pod". **sandbox** for the agent-sandbox resources (`Sandbox`,
  `SandboxClaim`, `SandboxWarmPool`: "claim a warm sandbox") and for the isolation
  boundary: "EC2 boots the pod's sandbox". Never **VM** or **microVM** for the claimed
  thing; **VM** only to explain how the boundary works: "the pod's containers run in a
  lightweight VM".
- **network policy**, never "fence".
- **hardware-level isolation**, never "strongest".
- No testing, tooling or how-it-was-built talk on a page: no test scripts, check counts,
  reviews or history. The word "agent" is fine; these samples are about AI agents.
- No em dashes. Use a colon, a comma or two sentences.
- Do not state a minimum CPU or memory request on slides or in videos. A page shows the
  sample's actual requests, or that it sets none.
- Name the runtime class and annotation exactly: `runtimeClassName: isolated-sandbox`,
  `sandbox.amazonaws.com/network-isolated: "true"`.

## Verification

- **Run it live, fresh, end to end**, on a cluster that has finished Getting started, in a
  new namespace or project. A resumed run cannot prove what a fresh one does.
- **Take every output block from that run.** Do not edit output beyond trimming it, and
  replace values from your own account or environment with placeholders. Replace every
  `TODO: output from the fresh run` marker, and search the page for any you missed.
- **Check each claim on the live cluster**: read the running pod's runtime class, kernel,
  environment variable names and connections, not only the manifest.
- **Keep local values in a gitignored env file** (`.env`, from `.env.example`). Read
  secrets from a file or standard input, never from a command line.
- **Tag every AWS resource the sample creates `ManagedBy=<sample>`**, label its namespace,
  and give every name to the sample. Pin the kube context for the run, and keep logs and
  state copies in the repository's `tmp/`. "Shared accounts, clusters and machines" in
  `AGENTS.md` has the rules and why.
- **Use ClusterIP and `kubectl port-forward`.** No Ingress, LoadBalancer or NodePort.
- **Run the clean up** and confirm nothing the sample created is left.

## Before the pull request

The description's checklist is the spec issue's own acceptance criteria, followed by the
repository's quality bar from the template:

```bash
cp .github/pull_request_template.md tmp/pr-body.md
gh issue view <issue> --repo aws-samples/sample-eks-nitro-sandbox --json body --jq .body \
  | tr -d '\r' | awk '/^## Acceptance criteria/{f=1; next} /^## /{f=0} f && /^- \[ \]/'
# paste those lines under "From the issue" in tmp/pr-body.md, then fill in the rest
gh pr create --draft --body-file tmp/pr-body.md
```

Copy the criteria word for word: no dropping, merging or rewording. Tick each one only
when it is met, and point to the evidence after it (the page section, the log under
`tmp/`, the commit). If one is not met, leave it unticked and say why under it. Keep the
template's "Quality bar" list whole, even where an issue box says the same thing, and
tick those boxes the same way. Keep the template's last line.

Open the pull request as a draft if the fresh run is still to do. Mark it ready when every
box from the issue and the quality bar is ticked, or a maintainer has agreed to the ones
that are not, and every box below is true. The boxes below are your own check; they are
not copied into the description.

- [ ] The spec issue exists, and the description starts with `Closes #<issue>` and carries
      every box from the issue's acceptance criteria and the template's quality bar.
- [ ] The page opens with the prerequisites link and the `git clone` and `cd` block.
- [ ] Each stage pairs an explanation, the real config verbatim and output from a fresh run.
- [ ] Each figure has a `.drawio` source, a `.png`, a caption and full alt text.
- [ ] The page ships no network policy and has no network policy section, and links the
      `network-policy` sample once where a reader would want the mechanism.
- [ ] No sentence, bullet, figure or alt text on the page says or implies the workload
      cannot reach the network, or that its reach is restricted, unless this sample is what
      restricts it. For a network-isolated sandbox: the page shows it has only loopback,
      with output from the run.
- [ ] If the sample gives the pod AWS permissions, its Pod Identity role grants only what
      the sample needs and the page shows the policy document. If it gives none, the page
      says the sample creates no Pod Identity association, and claims no limit from one.
- [ ] No Ingress, LoadBalancer or NodePort anywhere in the folder.
- [ ] No values from your own account or environment (account IDs, keys, tokens, names of
      your clusters or hosts, user names, internal URLs) in any tracked file, including
      output blocks and diagrams. The shared defaults on the home page are fine.
- [ ] The page proves the pod ran in a sandbox: its own kernel build, boot and virtio
      disks, each with what an ordinary pod shows instead.
- [ ] The clean up removes everything the sample created, and only that.
- [ ] The setup script changes nothing cluster-wide, and an overridable name such as
      `NAMESPACE` reaches every object it applies.
- [ ] A controller, CSI driver or add-on the sample needs is checked for, reused as it is
      when present, and a reader step when absent. The scripts never upgrade or reconfigure it.
- [ ] The clean up ran after the last run the page uses, and the description lists anything
      it could not remove.
- [ ] No local files (logs, state copies, helpers) in the sample folder; they are in the
      repository's `tmp/`.
- [ ] `nav` entry added, roadmap and root README updated, and
      `./scripts/check-sample-index.sh` passes.
- [ ] `mkdocs build --strict` passes, and `./scripts/check-agent-files.sh` passes.
- [ ] The branch has the latest `main` merged in, with no rebase or force-push, and the
      checks pass on its current head.
- [ ] Wording rules above hold, including no em dash (U+2014) characters and no "fence"
      or "strongest" on the page.
- [ ] A second reviewer has looked at any check, credential path or security claim.
