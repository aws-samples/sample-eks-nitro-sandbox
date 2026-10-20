---
name: sample-page
description: Build a sample in this repository and write its page (the sample folder's README.md) so it matches the existing samples - folder layout, stages that pair a short explanation with a diagram, the real code and the observed result, the network policy section, clean up, the nav entry and the roadmap update. Use after the sample's spec issue exists, when implementing a sample, writing or revising a sample page, or checking one before a pull request.
---

# Build a sample and write its page

A sample is a page a reader follows on their own account, and a page someone presents
live. Each stage shows what the reader configures, where it takes effect, and how to
recognise the result, with output from a real run.

Paths below are relative to the repository root. Before you start:

1. **The spec issue exists and is agreed.** If it does not, use the `sample-spec` skill
   first. The pull request will say `Closes #<issue>`.
2. **Read the closest samples** and reuse their patterns:
   - `examples/getting-started/hello-sandbox/README.md`: the one-line opt-in and the proof
     that the pod runs in a VM.
   - `examples/getting-started/coding-agent/README.md`: Pod Identity, a Secret read from a
     file, and an egress network policy with hostnames.
   - `examples/getting-started/warm-pool/README.md`: agent-sandbox `SandboxTemplate`,
     `SandboxWarmPool` and `SandboxClaim`.
   - `examples/managed-agents/claude-managed-agents/README.md`: the full layout (`deploy/`,
     `scripts/`, `src/`), a versions table, "How the network policy works", an optional
     mode, "Good to know" and a thorough clean up.
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
   what runs in the sandbox, what stays an ordinary pod, what each part can reach. Then the
   overview figure.
4. **Versions** table when anything is pinned, and a **files** table linking each file.
5. **Steps.** `**Step N: <Action>.**` leads each one, as on the existing pages.
6. **How the network policy works**, when the sandbox has a network: the complete policy
   YAML, a table that explains each part, where it is enforced, and its limits.
7. **Optional variants** as `## Optional: <variant>` sections.
8. **Good to know**: the limits that change what a reader can rely on, kept visible.
9. **Clean up.**

Put long reference material (a reading of the enforcement on a node, a second mode's clean
up) in a collapsible block. The existing pages use `<details><summary>...</summary>`, which
renders on GitHub and on the site; the site also supports `???` blocks (pymdownx.details),
which render on the site only. Never hide a limit that changes the headline claim.

## Compose each stage

Each step is one small unit, in this order:

1. **An action lead**: what happens, such as "Apply the network policy" or "Claim one".
2. **A short explanation**: usually two or three sentences on the input, the component that
   acts on it, and why.
3. **A focused diagram** when the stage has a new participant, boundary or flow. Hand it to
   the `aws-diagrams` skill. One job per figure, three to six nodes, short labels. Put an
   italic caption line (`*Figure N: ...*`) above the image and alt text that describes the
   whole figure in full sentences. Use a Mermaid block for timing or message order, as the
   warm pool page does.
4. **The real code or configuration, verbatim.** Copy the excerpt from the file in the
   folder, keep real field names and values, and say when it is trimmed ("Here is the part
   of `sandbox-template.yaml` that matters"). Never show a fragment as a complete policy.
5. **The command, then the observed result** in a `text` block, from a real run. Say
   "Abridged" or "your text will differ" when it is. Follow it with a sentence on what to
   look at in the output. Until you have run it, the block holds only
   `TODO: output from the fresh run`, never output you wrote yourself.

## The network policy section

Every sample whose sandbox has a network ships an egress policy and explains it in a "How
the network policy works" section:

- the complete policy YAML, without its header comment. When a script fills values in at
  apply time (the CoreDNS address, a list of AWS address ranges), show the file as it is,
  placeholders included, and say which script fills each one and from where;
- a table with one row per part (`podSelector`, `policyTypes`, each rule) and what it does;
- that enforcement is turned on once per cluster with the `amazon-vpc-cni` ConfigMap, and
  how the page waits for the `PolicyEndpoint`;
- that it is enforced on the node, outside the guest;
- its limits: a `domainNames` rule allows addresses, so other names on the same addresses
  are reachable, and a pod can always reach its own node;
- `networkPolicyManagement: Unmanaged` on any `SandboxTemplate`, and why.

Show it working: one allowed connection that connects and one refused that does not. When
the pod refuses exec, as a `confidential-sandbox` pod does under a policy that denies it,
put the probes in the container's own command and read the results from its logs. If the
sample cannot show a connection either way, say on the page what it shows instead and why.

A sandbox booted with `sandbox.amazonaws.com/network-isolated: "true"` has no network to
restrict, so it needs no policy. Show that instead: only `lo` has an address, there is no
route, and a lookup fails, as the hello sandbox page does.

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
- Say what stays and why: cluster-wide settings such as network policy enforcement, and
  shared installs such as agent-sandbox, with the command to remove them.
- Link the hello sandbox clean up for removing the namespace and the cluster.

## Nav and roadmap

- Add the page to `nav` in `mkdocs.yml`, under its section heading and in roadmap order.
  Add the section heading if this is its first sample. `mkdocs build --strict` does not
  fail on a page missing from `nav`; the page just has no menu entry.
- In `docs/ROADMAP.md`, link the entry and mark it available.
- Add it to the root `README.md` list for its section.

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
  sample's actual requests.
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
- [ ] For a sandbox with a network: "How the network policy works" shows the complete
      policy, and the page shows one allowed and one refused connection. For a
      network-isolated sandbox: the page shows it has only loopback.
- [ ] Every `SandboxTemplate` with its own policy sets `networkPolicyManagement: Unmanaged`.
- [ ] No Ingress, LoadBalancer or NodePort anywhere in the folder.
- [ ] No values from your own account or environment (account IDs, keys, tokens, names of
      your clusters or hosts, user names, internal URLs) in any tracked file, including
      output blocks and diagrams. The shared defaults on the home page are fine.
- [ ] The page proves the pod ran in a sandbox: its own kernel build, boot and virtio
      disks, each with what an ordinary pod shows instead.
- [ ] The clean up removes everything the sample created, and only that.
- [ ] The setup script changes nothing cluster-wide, and an overridable name such as
      `NAMESPACE` reaches every object it applies.
- [ ] The clean up ran after the last run the page uses, and the description lists anything
      it could not remove.
- [ ] No local files (logs, state copies, helpers) in the sample folder; they are in the
      repository's `tmp/`.
- [ ] `nav` entry added, roadmap and root README updated.
- [ ] `mkdocs build --strict` passes, and `./scripts/check-agent-files.sh` passes.
- [ ] Wording rules above hold, including no em dash (U+2014) characters and no "fence"
      or "strongest" on the page.
- [ ] A second reviewer has looked at any check, credential path or security claim.
