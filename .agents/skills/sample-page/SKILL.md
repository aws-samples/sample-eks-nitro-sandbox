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
   - `examples/ai-agents/claude-managed-agents/README.md`: the full layout (`deploy/`,
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

   Then anything extra this sample needs, and what a run costs beyond the cluster.
3. **Overview.** Two or three short paragraphs and a few bullets, each led by a bold claim:
   what runs in the sandbox, what stays an ordinary pod, what each part can reach. Then the
   overview figure.
4. **Versions** table when anything is pinned, and a **files** table linking each file.
5. **Steps.** `**Step N: <Action>.**` leads each one, as on the existing pages.
6. **How the network policy works**: the complete policy YAML, a table that explains each
   part, where it is enforced, and its limits.
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
   look at in the output.

## The network policy section

Every sample whose sandbox has a network ships an egress policy and explains it:

- the complete policy YAML, without its header comment;
- a table with one row per part (`podSelector`, `policyTypes`, each rule) and what it does;
- that enforcement is turned on once per cluster with the `amazon-vpc-cni` ConfigMap, and
  how the page waits for the `PolicyEndpoint`;
- that it is enforced on the node, outside the guest;
- its limits: a `domainNames` rule allows addresses, so other names on the same addresses
  are reachable, and a pod can always reach its own node;
- `networkPolicyManagement: Unmanaged` on any `SandboxTemplate`, and why.

Show it working: one allowed connection that connects and one refused that does not.

## Clean up

- Start by setting the variables again, for a reader in a new shell.
- Delete in reverse order of creation, starting with anything that would recreate pods
  (a warm pool, a Deployment).
- Remove every AWS resource the sample created: IAM roles and policies, Pod Identity
  associations (only this sample's), ECR repositories, local images.
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

- **pod** for the thing you create, pool, claim, adopt or delete: "a warm pod", "each
  session gets its own pod". **VM** or **sandbox** only for the isolation boundary: "the
  pod's containers run in a lightweight VM", "EC2 boots the pod's sandbox".
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
  replace account values with placeholders.
- **Check each claim on the live cluster**: read the running pod's runtime class, kernel,
  environment variable names and connections, not only the manifest.
- **Keep local values in a gitignored env file** (`.env`, from `.env.example`). Read
  secrets from a file or standard input, never from a command line.
- **Tag every AWS resource you create while verifying with `auto-delete=no`**, so an
  account clean-up job does not remove it in the middle of a run.
- **Use ClusterIP and `kubectl port-forward`.** No Ingress, LoadBalancer or NodePort.
- **Run the clean up** and confirm nothing the sample created is left.

## Before the pull request

- [ ] The spec issue exists, and the description starts with `Closes #<issue>`.
- [ ] The page opens with the prerequisites link and the `git clone` and `cd` block.
- [ ] Each stage pairs an explanation, the real config verbatim and output from a fresh run.
- [ ] Each figure has a `.drawio` source, a `.png`, a caption and full alt text.
- [ ] "How the network policy works" shows the complete policy; the page shows one allowed
      and one refused connection.
- [ ] Every `SandboxTemplate` with its own policy sets `networkPolicyManagement: Unmanaged`.
- [ ] No Ingress, LoadBalancer or NodePort anywhere in the folder.
- [ ] No account IDs, keys, cluster names, hostnames, user names or internal URLs in any
      tracked file, including output blocks and diagrams.
- [ ] The clean up removes everything the sample created.
- [ ] `nav` entry added, roadmap and root README updated.
- [ ] `mkdocs build --strict` passes, and `./scripts/check-agent-files.sh` passes.
- [ ] Wording rules above hold, including no em dash (U+2014) characters and no "fence"
      or "strongest" on the page.
- [ ] A second reviewer has looked at any check, credential path or security claim.
