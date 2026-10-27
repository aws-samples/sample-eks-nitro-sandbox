# Subagent security: the same analyst, three ways to confine its tools

The samples in this section run one procurement analyst three times over. The task, the
inputs, the model path and the recommendation it has to produce are identical in all three.
What changes is the layer that confines the tool processes the analyst runs inside its
sandbox: [nono](https://github.com/nolabs-ai/nono) here,
[bubblewrap](https://github.com/containers/bubblewrap) next, and
[OpenShell](https://github.com/NVIDIA/OpenShell) in the third.

Every one of them puts the whole workload in a Nitro sandbox. So there are two boundaries
on each page, and they do different jobs:

- **The Nitro sandbox** is the hardware-level isolation around the pod. EKS runs the pod's
  containers and their own kernel in a lightweight VM inside that sandbox, which is what
  separates this workload from the node and from every other pod on it.
- **The confinement layer** is the boundary *inside* the pod, between the trusted
  application and the tool processes it starts. It is what decides which files a tool can
  open, whether it has a network at all, and which credential it holds.

This page is the part the three samples share: the analyst, the case, the files, and what
a confinement layer has to supply. Each sample's page links here instead of restating it.

## The analyst and its case

A fictional procurement case. An office needs 100 workstations, for at most $125,000,
delivered within 30 days, with at least 24 months of warranty. Three suppliers have bid,
and the analyst has to compare them and write a recommendation that cites the original
proposals.

| Supplier | Price | Delivery | Warranty | Outcome |
|---|---|---|---|---|
| Harbor Supply Partners | $105,000 | 45 days | 24 months | Cheapest, and too late |
| Cedar Workplace Group | $130,000 | 21 days | 36 months | Fastest, and over budget |
| Northstar Office Systems | $120,000 | 28 days | 36 months | Meets every requirement |

The proposals are made up, and they hold no customer data. The analyst can draft a
recommendation; it cannot change a supplier record or place an order.

**The work is split so the model does not decide the outcome.** A deterministic comparison
in [`analyst/src/business.py`](analyst/src/business.py) qualifies each supplier against the
requirements and a supplier-availability lookup, then picks the cheapest one that is left.
Qualifying before comparing price is the whole point: Harbor is the cheapest bid and loses
on delivery, so a comparison that sorted on price alone would recommend it.

A real Amazon Bedrock turn then explains that comparison. The model gets one tool, which
returns the verified facts, and it returns a structured answer with two fields: the
supplier id it selects, and its analysis in Markdown. Two gates run before the answer is
accepted, and they are deliberately separate:

- **The choice gate** reads the `recommended_supplier` field and nothing else, so a
  supplier named only in the prose, or only in a citation, cannot satisfy it.
- **The citation gate** requires every original proposal's S3 key in the analysis.

The recommendation heading is rendered from the checked field, not from the prose, so the
headline and the gate always read the same value. Each sample's page shows both gates
refusing an answer as well as accepting one.

## What runs where

```text
One Nitro sandbox pod
└── trusted controller                  AWS, through EKS Pod Identity
    ├── reader      ─┐
    ├── evaluator    ├─ tool processes under the confinement layer
    └── writer      ─┘
                                        the layer's proxy, where there is one,
                                        holds the real supplier key

An ordinary pod
└── synthetic supplier API              ClusterIP only, reached inside the cluster
```

The reader, evaluator and writer are **tool processes**, not three independent model
sessions and not three pods. The controller starts each one for a single action, hands it
the facts it needs as a file, and reads its structured result. They have no shared writable
directory, so what passes between them passes through the controller.

**The trusted controller owns AWS.** It downloads the proposals from Amazon S3, calls
Amazon Bedrock and saves the report, all with the pod's EKS Pod Identity credentials. The
confinement layer does not sign those calls, and the tool processes have no AWS role: they
are refused the Pod Identity token file and the Pod Identity endpoint, which each sample
shows. No model API key is placed in the sandbox, and each page checks that by variable
name.

**The supplier API accepts an authenticated mutation on purpose.** A purchase order or a
supplier-record change succeeds against it when the request carries the real key. That is
what makes a refusal attributable: each sample sends the same method and path from the
trusted controller, with the same key, and shows the server accepting it. Without that
control, a refusal could be the server's own doing rather than the confinement layer's.

## Which to pick

| | [nono](nono/README.md) | bubblewrap | OpenShell |
|---|---|---|---|
| What it gives you | File and network profiles, plus a credential proxy that brokers an API key and filters HTTP method and path | Namespace and mount isolation for a child process, with no network for the restricted tools | A supervisor that holds the credentials in a pod of its own, outside the sandbox |
| What you deploy | One pinned binary in your image, driven by your application | One pinned binary in your image | A control plane, with its own pods and charts |
| Where the real credential sits | Inside the sandbox, with the layer's proxy | Inside the sandbox, with the trusted controller | Outside the sandbox, with the supervisor |
| Reach for it when | Your tools need allow-listed API access and a brokered credential, and you want no separate control plane to operate | Your restricted tools need no network at all and you want the smallest possible layer | You want the credential out of the sandbox entirely, and can run the supervisor |

In all three the application still owns the orchestration, the model call, IAM, storage and
the business gates. The confinement layer bounds what the tools it starts can reach; it
does not decide whether the recommendation is right.

## The shared files

Everything under [`analyst/`](analyst/) is shared, and each sample uses it unchanged.

| File | What it is |
|---|---|
| [`analyst/src/business.py`](analyst/src/business.py) | The deterministic comparison, the choice gate and the citation gate |
| [`analyst/src/worker.py`](analyst/src/worker.py) | The tool-role worker: one process, one action, with refusals reported as data and everything else an error |
| [`analyst/src/analyst_agent.py`](analyst/src/analyst_agent.py) | The Bedrock turn through Strands Agents, its evidence tool and its structured answer |
| [`analyst/fixtures/`](analyst/fixtures/) | The case, the three proposals and the availability lookup |
| [`analyst/supplier-api/`](analyst/supplier-api/) | The synthetic supplier API and its image |
| [`analyst/deploy/`](analyst/deploy/) | The namespace, the analyst ServiceAccount, and the supplier API Deployment and Services |
| [`analyst/iam/`](analyst/iam/) | The Pod Identity role trust policy and the permissions the controller gets |
| [`analyst/scripts/analyst-lib.sh`](analyst/scripts/analyst-lib.sh) | The half of setup every sample shares, sourced by each sample's own `setup.sh` |
| [`analyst/requirements.txt`](analyst/requirements.txt) | The locked, hash-pinned Python dependencies, installed with `--require-hashes` |

**What a sample adds.** Its own `Dockerfile`, which puts its confinement layer in the image
beside the shared analyst; its own controller, which launches the tool roles through that
layer; the profiles or configuration the layer reads; its pod; and its `setup.sh`, `run.sh`
and `clean.sh`.

**What none of them adds is a network policy.** These samples are about the boundary inside
the pod, between a trusted application and the tool processes it starts. None of them
restricts its pod's egress, so on each page the confinement layer is the only boundary
shown and the pod reaches whatever the cluster and VPC allow. Each page says so, and says
precisely what its layer does and does not decide.
[Isolation > Network policy](../isolation/network-policy/README.md) is the sample for
restricting a sandbox's egress on the node.

**What a confinement layer has to supply**, for the three samples to show the same thing:

1. Start [`analyst/src/worker.py`](analyst/src/worker.py) as a separate process for one
   role and one action, with an environment the controller builds rather than inherits.
2. Grant that process its own `in` directory read-only and its own `out` directory
   read-write, and nothing else beyond the shared analyst code.
3. Refuse the network entirely for the evaluator.
4. For the online roles, allow one supplier host, and nothing else.
5. Keep the real supplier key out of the role's reach, by file and by environment.
6. Pass `ANALYST_DIGEST_KEY` into the role's environment, and allow that variable through.
   The shared worker keys its credential digest with it, so the run's own record holds no
   unsalted commitment to credential material; a role started without it raises rather
   than reporting a refusal.

A layer that cannot do one of these is worth saying so about on its page, rather than
leaving the comparison looking even.

Each sample names its own `ManagedBy` tag and its own namespace, and builds its own copy of
the supplier API image, so two of them can run side by side in one account without either
clean up removing the other's resources.

## Before you run one

Each sample's page lists what it needs, and they all share the
[prerequisites](../README.md#prerequisites) on the home page. Every sample here also builds
on three earlier ones and does not re-explain them:
[hello sandbox](../getting-started/hello-sandbox/README.md) for the one-line opt-in and how
a pod shows it ran in a sandbox, [coding agent](../getting-started/coding-agent/README.md)
for Bedrock through Pod Identity, and
[Claude Managed Agents](../managed-agents/claude-managed-agents/README.md) for
`automountServiceAccountToken: false` and credentials shown by variable name.

A run uses Amazon Bedrock tokens, stores a few small objects in Amazon S3, and keeps one
sandboxed pod and one small ordinary pod running until you clean up.

## The samples

- [Procurement analyst confined by nono](nono/README.md): reader, evaluator and writer as
  separate processes under per-role nono profiles, with nono's proxy brokering the supplier
  key and filtering the HTTP method and path.

Two more are planned, running the same analyst under bubblewrap and under OpenShell. See
the
[roadmap](https://github.com/aws-samples/sample-eks-nitro-sandbox/blob/main/docs/ROADMAP.md).
