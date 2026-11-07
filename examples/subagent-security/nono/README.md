# A procurement analyst whose tools are confined by nono

A procurement analyst compares three supplier proposals and writes a recommendation that
cites all three. It does that work through three tool processes, each started by a trusted
controller under its own [nono](https://github.com/nolabs-ai/nono) profile, inside one
Nitro sandbox. The reader can open its assigned proposal and not a sibling's private file.
The evaluator has no network at all. The writer may submit a draft to the supplier and may
not place an order. None of them ever holds the real supplier API key.

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page and the [Subagent security section page](../README.md), which describes the
analyst, the case and the files this blueprint shares with the other two. Run these blueprints
first, which this one builds on and which it does not re-explain:

- [Getting started > Hello sandbox](../../getting-started/hello-sandbox/README.md): the
  one-line opt-in, and how a pod shows that it ran in a sandbox.
- [Getting started > Coding agent](../../getting-started/coding-agent/README.md): Amazon
  Bedrock through EKS Pod Identity.
- [AI agents > Claude Managed Agents](../../managed-agents/claude-managed-agents/README.md):
  a sandboxed pod with `automountServiceAccountToken: false`, and credentials shown by
  variable name and never by value.

The commands below use files from this repository, so clone it if you have not already, and
run them from this blueprint's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/subagent-security/nono
```

For this blueprint you also need [`aws`](https://aws.amazon.com/cli/),
[`kubectl`](https://kubernetes.io/docs/reference/kubectl/),
[`docker`](https://docs.docker.com/get-started/get-docker/),
[`jq`](https://jqlang.org/), `openssl` and `python3` on your machine, and an Amazon Bedrock
inference profile your account can invoke. The scripts build and push two small images to
Amazon ECR. A run costs one Bedrock turn, a few small Amazon S3 objects, and one sandboxed
pod plus one small ordinary pod kept running until you clean up.

Every output block on this page is from one real run of this blueprint, run id
`13cc944b3984459e865976b73d319659`. Values from the account and cluster it ran on are
replaced by the same placeholders the commands use, because this repository is public:
`<ACCOUNT_ID>`, `<CLUSTER_NAME>` and `<NODE_NAME>`. The Region is left as
`us-west-2`, the default this repository's blueprints share. Run ids, pod names, kernel
builds, uptimes, device lists, token counts and the model's own prose are exactly as the
run printed them. Where a block shows a file from this folder rather than a run's output,
it says so.

## Overview

**Two boundaries, doing different jobs.** `runtimeClassName: isolated-sandbox` is the one
line that puts the whole pod in a Nitro sandbox: a hardware-isolated lightweight VM with its
own kernel, which its containers run in, and which is what separates this
workload from the node and from every other pod on it. nono is the boundary *inside* that
pod, between the trusted controller and the three tool processes it starts. Everything nono
governs, including the supplier key and nono's own proxy, sits inside the sandbox.

- **The tool roles are processes, not pods and not model sessions.** The controller starts
  the reader, evaluator or writer for one action, hands it the facts it needs as a file, and
  reads one structured result. They share no writable directory.
- **Each role gets its own profile.** nono reads a JSON profile per role: the paths it may
  read, the one directory it may write, the environment variables it keeps, and either no
  network at all or one allowed host with an HTTP method and path policy.
- **The real supplier key stays with nono's proxy.** A role is given a placeholder in
  `SUPPLIER_API_KEY` and sends it in the ordinary API header; the proxy substitutes the real
  key for a request that its policy allows. The role cannot open the key file.
- **AWS stays with the trusted controller.** It reads the proposals from Amazon S3, calls
  Amazon Bedrock and saves the report with the pod's EKS Pod Identity credentials. nono does
  not sign those calls, and the tool roles have no AWS role: they are refused the Pod
  Identity token file and the Pod Identity endpoint.
- **The useful result is still checked.** A deterministic comparison picks the supplier, the
  model explains it, and two gates check the model's own choice and its citations before the
  recommendation is accepted.

*Figure 1: The two boundaries around the analyst. The Nitro sandbox holds the whole pod,
including nono's proxy and the supplier key; inside it, each tool role runs under its own
nono profile, and only the trusted controller holds AWS credentials.*

![An AWS Cloud frame holds an Amazon EKS cluster frame. Inside the cluster, a red Nitro sandbox frame labelled runtimeClassName colon isolated-sandbox contains an Analyst pod box. In that box a trusted controller sits on the left, described as owning AWS and the profiles, with three arrows running right, labelled starts each role under its profile, to three container icons: a Reader with one proposal and GET only, an Evaluator with no network, and a Writer with a draft POST allowed. The Reader and the Writer each have an arrow to a red nono proxy that holds the supplier key, which is still inside the Analyst pod and so still inside the sandbox. One arrow leaves the proxy, labelled approved host and operation, and reaches a Supplier API icon in a separate Supplier API pod box outside the sandbox frame, marked an ordinary pod and ClusterIP only. A red dashed arrow runs from the Writer to that same Supplier API, labelled direct connection refused, which is the probe in which a role's own connection to that address was refused. Two more arrows leave the trusted controller on its left side, pass below every frame and reach Amazon Bedrock, for the model turn, and Amazon S3, holding the proposals and reports; they are labelled EKS Pod Identity, and no arrow to either service starts at a tool role.](images/subagent-security-nono.png)

## Versions

This folder was built against these releases. Pin each to its latest when you build.

| Component | Version |
|---|---|
| [nono](https://github.com/nolabs-ai/nono/releases) | 0.80.0, pinned in the `Dockerfile` by release tag and by the SHA-256 of the release archive |
| [`strands-agents`](https://pypi.org/project/strands-agents/) | 1.62.0 |
| [`boto3`](https://pypi.org/project/boto3/) | 1.43.118 |
| [`pydantic`](https://pypi.org/project/pydantic/) | 2.14.1 |
| [Python](https://www.python.org/downloads/) base image | 3.13 (`public.ecr.aws/docker/library/python:3.13-slim`) |
| [busybox](https://hub.docker.com/_/busybox), for the comparison pod | 1.37.0 |

The Python packages are locked with hashes in
[`../analyst/requirements.txt`](../analyst/requirements.txt) and installed with
`pip --require-hashes`, so a dependency that resolved to another version fails the build
rather than reaching the sandbox.

## Files

Everything under [`../analyst/`](../analyst/) is shared with the other Subagent security
blueprints and listed on the [section page](../README.md#the-shared-files). This blueprint adds:

| File | What it is |
|---|---|
| [`Dockerfile`](Dockerfile) | The shared analyst plus the pinned nono binary |
| [`src/controller.py`](src/controller.py) | The trusted controller: it owns AWS and launches each tool role under nono |
| [`src/policies.py`](src/policies.py) | The profile generator, one function for all three roles |
| [`src/ptyrun.py`](src/ptyrun.py) | Gives nono a controlling terminal, so the controller can run it unattended |
| [`policies/reader.json`](policies/reader.json) | The reader's generated profile, as this page shows it |
| [`policies/evaluator.json`](policies/evaluator.json) | The evaluator's generated profile: no network |
| [`policies/writer.json`](policies/writer.json) | The writer's generated profile: one more allowed operation |
| [`deploy/analyst-pod.yaml`](deploy/analyst-pod.yaml) | The sandboxed pod |
| [`deploy/ordinary-pod.yaml`](deploy/ordinary-pod.yaml) | An ordinary pod on the same node, for the comparison in step 10 |
| [`scripts/setup.sh`](scripts/setup.sh) | Builds the images and creates everything the blueprint needs |
| [`scripts/run.sh`](scripts/run.sh) | Runs one procurement case and copies its result out |
| [`scripts/profiles.sh`](scripts/profiles.sh) | Regenerates `policies/` from `src/policies.py` |
| [`scripts/correlate.py`](scripts/correlate.py) | Checks the run's record against the supplier API's own request log |
| [`scripts/clean.sh`](scripts/clean.sh) | Removes what this blueprint created, and says what stays |
| [`.env.example`](.env.example) | The local values the blueprint needs; copy to `.env`, which git ignores |

## What this blueprint does and does not bound

This matters before the steps, because the blueprint is about confinement and it would be easy
to read more into it than it shows.

**What nono bounds, and the run demonstrates:** the three tool processes the controller
starts. For each of them, which files it can open and write, whether it can create a socket
at all, which host it can reach through nono's proxy, which HTTP method and path pairs that
proxy will forward, and which credential it holds.

**What nothing in this blueprint bounds:** the analyst pod's own egress. This blueprint ships no
network policy, so the pod — and the trusted controller inside it, which is not under any
nono profile — reaches whatever the cluster and the VPC allow. The refusals on this page are
nono refusing a *tool process*; none of them is the pod being unable to reach something.
To restrict a sandbox's egress on the node, see
[Isolation > Network policy](../../isolation/network-policy/README.md), which is the blueprint
for that mechanism.

The two are worth keeping apart. A tool process refused a host by nono is refused inside the
pod, by the process's own restrictions; the controller beside it can still reach that host,
which is exactly how this page's negative controls work.

## Steps

**Step 1: Set your local values.** Copy the example file and fill in your cluster's name
and Region. `.env` is gitignored, so nothing from your own account or cluster ends up in a
tracked file.

```bash
cp .env.example .env && $EDITOR .env
```

This is [`.env.example`](.env.example) as it is in the folder, not a run's output:

```bash
# Copy this file to .env and fill it in. .env is gitignored: nothing from your own
# account or cluster belongs in a tracked file.
#
#   cp .env.example .env && $EDITOR .env

# Your cluster's name, and the Region it is in.
CLUSTER_NAME=
AWS_REGION=us-west-2

# The kube context to pin every kubectl call to. Leave it empty to use the current
# context. Set it on a shared machine, where another session can change the current one
# in the middle of a run.
KUBE_CONTEXT=

# The namespace this sample creates and owns. Change it to run this sample twice, or
# beside another demo; it reaches every object the scripts apply.
NAMESPACE=subagent-security-nono

# The Amazon Bedrock inference profile the analyst's model turn uses. The run on the page
# used this one.
BEDROCK_MODEL_ID=global.anthropic.claude-sonnet-4-5-20250929-v1:0

# Optional. Left empty, setup.sh names the bucket and the role for this sample and your
# account id. Set them to run a second copy beside the first.
# BUCKET=
# ROLE_NAME=
```

**Step 2: Build the images and create everything the blueprint needs.** One script, seven
stages. It checks the cluster before it creates anything, builds and pushes the supplier API
image and the analyst image, seeds the proposals into a new S3 bucket, creates the IAM role
and its Pod Identity association, and only then starts the sandboxed pod. It creates nothing
outside this blueprint's own namespace and changes no cluster-wide setting.

```bash
./scripts/setup.sh
```

Abridged: the two image builds' own output is cut, and your names will differ.

```text
==> 1/7 tools, cluster and cluster-wide settings
  account:  <ACCOUNT_ID>
  region:   us-west-2
  context:  <CLUSTER_NAME>
  model:    global.anthropic.claude-sonnet-4-5-20250929-v1:0

==> 2/7 namespace subagent-security-nono and the analyst ServiceAccount
namespace/subagent-security-nono created
serviceaccount/analyst created

==> 3/7 the supplier API key and its sample certificate authority
secret/supplier-key created
  created the supplier-key Secret
secret/supplier-tls created
configmap/supplier-ca created
  created a 30-day sample certificate authority and the supplier-tls Secret

==> 4/7 the synthetic supplier API
  created the ECR repository pod-isolation/subagent-analyst-nono-supplier-api
  built and pushed pod-isolation/subagent-analyst-nono-supplier-api:6477c8d7c039259448ff
service/supplier-api created
service/supplier-api-alias created
deployment.apps/supplier-api created
Waiting for deployment "supplier-api" rollout to finish: 0 of 1 updated replicas are available...
deployment "supplier-api" successfully rolled out

==> 5/7 the S3 bucket and the proposals
  created the bucket subagent-analyst-nono-<ACCOUNT_ID>
  seeded the case, 3 proposals and one other case's object

==> 6/7 the IAM role and its EKS Pod Identity association
  created the IAM role subagent-analyst-nono
  created the Pod Identity association a-8tfukbezevcahflrb

==> 7/7 the nono analyst image and its sandboxed pod
the committed profiles match the generator for: reader, evaluator, writer
  created the ECR repository pod-isolation/subagent-analyst-nono
  built and pushed pod-isolation/subagent-analyst-nono:a1c6658d01e83a67a6cb
pod/analyst created
pod/analyst condition met

==> ready
  namespace:  subagent-security-nono
  bucket:     subagent-analyst-nono-<ACCOUNT_ID>
  role:       subagent-analyst-nono
  model:      global.anthropic.claude-sonnet-4-5-20250929-v1:0
  run record: /path/to/sample-eks-nitro-sandbox/tmp/nono/state.env

Run one procurement case:
  ./scripts/run.sh
```

The run record under the repository's `tmp/` is what `run.sh` and `clean.sh` read, so
neither needs anything set again.

**Step 3: Run one procurement case.** The controller runs in the sandbox and prints every
check as it reaches it. Each run gets a fresh id and its own directories inside the pod, so
one run cannot read or resume another's.

```bash
./scripts/run.sh
```

Every line the run printed, in order. The run id, the token count and the model's prose
will differ.

```text
==> running one procurement case in the sandbox
PASS the AWS SDK uses the Pod Identity container credential provider
PASS the caller is this sample's Pod Identity role
PASS no model API key is in the sandbox: ANTHROPIC_API_KEY, OPENAI_API_KEY, BEDROCK_API_KEY, AWS_BEARER_TOKEN_BEDROCK are all absent
PASS the S3 proposal matches the case entry for northstar
PASS the S3 proposal matches the case entry for harbor
PASS the S3 proposal matches the case entry for cedar
PASS the image's fixtures match the objects in S3
PASS IAM returns AccessDenied for overwriting a source proposal
PASS IAM returns AccessDenied for deleting a source proposal
PASS IAM returns AccessDenied for reading another case's object
PASS the profiles in policies/ are what the generator produces
PASS the reader profile this run uses is the committed one
PASS the evaluator profile this run uses is the committed one
PASS the writer profile this run uses is the committed one
PASS the same check reports an altered profile
PASS the reader reads its assigned proposal
PASS the reader cannot overwrite its read-only input
PASS the reader cannot read the writer's private file
PASS the reader cannot open the supplier key file
PASS the reader cannot open the Pod Identity token file
PASS the writer writes its own output directory
PASS the reader holds a supplier credential
PASS the reader's credential is not the real supplier key
PASS the reader has no AWS credential variable; its AWS environment is ['AWS_CA_BUNDLE']
PASS the reader has no model API key
PASS the reader cannot reach the Pod Identity endpoint directly
PASS the supplier API refuses an invalid key with 401
PASS the online reader creates an Internet socket
PASS the offline evaluator cannot create an Internet socket
PASS reader: GET /cases/rfp-001/suppliers returns 200
PASS the nono audit records GET /cases/rfp-001/suppliers
PASS the nono audit decision is allow
PASS reader: a direct connection to the supplier API is refused
PASS a second DNS name for the same server is refused
PASS the nono audit records the refused host
PASS the same server answers on that second name, with the same key, outside the role boundary
PASS reader: POST /cases/rfp-001/recommendations returns 403
PASS the nono audit records POST /cases/rfp-001/recommendations
PASS the nono audit decision is deny
PASS writer: PATCH /suppliers/northstar returns 403
PASS the nono audit records PATCH /suppliers/northstar
PASS the nono audit decision is deny
PASS the supplier API accepts PATCH /suppliers/northstar with the real key, outside the role boundary
PASS writer: POST /purchase-orders returns 403
PASS the nono audit records POST /purchase-orders
PASS the nono audit decision is deny
PASS the supplier API accepts POST /purchase-orders with the real key, outside the role boundary
PASS writer: GET /cases/rfp-other/suppliers returns 403
PASS the nono audit records GET /cases/rfp-other/suppliers
PASS the nono audit decision is deny
PASS the supplier API accepts GET /cases/rfp-other/suppliers with the real key, outside the role boundary
PASS the offline comparison names the one supplier that meets every requirement
PASS the controller's own comparison agrees with the evaluator's
PASS the writer saves the comparison in its own output directory
PASS writer: POST /cases/rfp-001/recommendations returns 201
PASS the nono audit records POST /cases/rfp-001/recommendations
PASS the nono audit decision is allow
PASS the model called the evidence tool
PASS Bedrock returned a real turn with nonzero token usage
PASS the model's own choice matches the verified comparison
PASS the model's analysis cites all three proposals
PASS the choice gate rejects an answer naming an ineligible supplier
PASS the choice gate rejects an answer that names the supplier only in its prose
PASS the citation gate rejects an answer missing one source key
PASS the report object round-trips through S3: recommendation.md
PASS the report object round-trips through S3: comparison.json
PASS the evidence and the report were scanned for the supplier key before being written, and the run was stopped if it appeared

ANALYST_COMPLETE=13cc944b3984459e865976b73d319659
67 checks passed
  66 checks passed in the sandbox
  12 requests correlated with the supplier API's own log (6 allowed arrived once each, 5 refused never arrived)
  model usage: 2563 tokens on global.anthropic.claude-sonnet-4-5-20250929-v1:0

==> done
  run id:         13cc944b3984459e865976b73d319659
  recommendation: /path/to/sample-eks-nitro-sandbox/tmp/nono/runs/13cc944b3984459e865976b73d319659/recommendation.md
  evidence:       /path/to/sample-eks-nitro-sandbox/tmp/nono/runs/13cc944b3984459e865976b73d319659/evidence.json
  S3 report:      s3://subagent-analyst-nono-<ACCOUNT_ID>/reports/rfp-001/13cc944b3984459e865976b73d319659/
```

The last three lines are the cross-check in [`scripts/correlate.py`](scripts/correlate.py),
which reads the supplier API's own request log out of its pod and compares it with the
run's record: each allowed request arrived upstream exactly once, and no refused request
arrived at all. An empty upstream log would satisfy the second on its own, so it also
requires the run to have contained both a successful draft submission and a refused
operation.

**Step 4: Read the recommendation.** The analyst's output is a Markdown report naming one
supplier and citing all three proposals, saved to Amazon S3 and copied out to the
repository's `tmp/`.

```bash
cat ../../../tmp/nono/runs/<RUN_ID>/recommendation.md
```

```markdown
# Procurement recommendation

**Case:** rfp-001, equipping a new customer service office with 100 workstations

**Recommended supplier:** Northstar Office Systems (`northstar`)

## Procurement Analysis: 100 Workstation Office Equipment

**Requirements:**
- Budget: $125,000 maximum
- Delivery: 30 days maximum
- Warranty: 24 months minimum

**Supplier Comparison:**

### ✅ Northstar Office Systems (*proposals/rfp-001/northstar.json*)
- **Price:** $120,000 (within budget)
- **Delivery:** 28 days (meets requirement)
- **Warranty:** 36 months (exceeds requirement)
- **Status:** ELIGIBLE

### ❌ Harbor Supply Partners (*proposals/rfp-001/harbor.json*)
- **Price:** $105,000 (within budget)
- **Delivery:** 45 days (exceeds 30-day limit)
- **Warranty:** 24 months (meets requirement)
- **Status:** INELIGIBLE - Late delivery

### ❌ Cedar Workplace Group (*proposals/rfp-001/cedar.json*)
- **Price:** $130,000 (exceeds budget by $5,000)
- **Delivery:** 21 days (meets requirement)
- **Warranty:** 36 months (exceeds requirement)
- **Status:** INELIGIBLE - Over budget

**Recommendation:** Northstar Office Systems is the only eligible supplier, meeting all requirements with competitive pricing at $120,000, timely 28-day delivery, and superior 36-month warranty coverage.
```





Everything from the second heading down is the model's own prose, and it cites all three
proposal keys. The two lines above it are rendered by the blueprint from the checked
`recommended_supplier` field.

The heading is rendered from the model's checked `recommended_supplier` field, not from its
prose, so the headline and the gate always read the same value. Harbor is the cheapest bid
and loses on delivery; Cedar is the fastest and is over budget.

**Step 5: Look at the file boundary.** The reader's profile grants the shared analyst code
and its own `in` directory read-only, its own `out` directory read and write, and nothing
else. Here is that part of [`policies/reader.json`](policies/reader.json), which
[`src/policies.py`](src/policies.py) generates:

```json
  "workdir": { "access": "none" },
  "filesystem": {
    "read": [
      "/opt/analyst",
      "/var/lib/analyst/<RUN>/reader/in"
    ],
    "allow": [
      "/var/lib/analyst/<RUN>/reader/out"
    ]
  },
```

`<RUN>` is this run's id in the live profile; the committed file keeps the placeholder so
the page and the generator cannot drift. The run checks that too: "the reader profile this
run uses is the committed one" compares the profile it handed the role against the
committed file with this run's id substituted in.

The run exercises the boundary in both directions. These lines are from the step 3 output:

```text
PASS the reader reads its assigned proposal
PASS the reader cannot overwrite its read-only input
PASS the reader cannot read the writer's private file
PASS the reader cannot open the supplier key file
PASS the reader cannot open the Pod Identity token file
PASS the writer writes its own output directory
```

The first and last lines are the accept cases: without them a profile that denied
everything would read the same as one that confines correctly.

Two things make the refusals attributable rather than incidental. The supplier key file is
mode 0440 and group-owned by the group the pod runs as, so the controller — running as
that same uid 1000 — reads it in this very run, which is how the run compares the role's
placeholder against the real key. And the worker reports only `EACCES` or `EPERM` as a
refusal; any other failure leaves no result line and fails the run.

What this shows is a refusal **at the uid the tool roles run as**, which is the same uid
the controller runs as. It is not a claim about root: this pod sets `runAsNonRoot: true`
and never runs a role as root, so the page has no evidence either way about what root
inside the sandbox could open, and does not claim any.

**Step 6: Give the evaluator no network.** The evaluator receives its facts as a file and
needs nothing from the network, so its profile blocks it outright. Here is
[`policies/evaluator.json`](policies/evaluator.json) in full:

```json
{
  "meta": {
    "name": "analyst-evaluator",
    "version": "1.0.0"
  },
  "workdir": {
    "access": "none"
  },
  "filesystem": {
    "read": [
      "/opt/analyst",
      "/var/lib/analyst/<RUN>/evaluator/in"
    ],
    "allow": [
      "/var/lib/analyst/<RUN>/evaluator/out"
    ]
  },
  "environment": {
    "allow_vars": [
      "PATH",
      "HOME",
      "LANG",
      "LC_ALL",
      "PYTHONPATH",
      "PYTHONDONTWRITEBYTECODE",
      "ANALYST_DIGEST_KEY"
    ]
  },
  "network": {
    "block": true
  }
}
```

`network.block` refuses the socket itself, not just a destination, and the online reader
under its own profile gets one:

```text
PASS the online reader creates an Internet socket
PASS the offline evaluator cannot create an Internet socket
```

The probe is `socket(AF_INET, SOCK_STREAM)` with no connect, so the two lines differ only
by which profile the process was started under. The evaluator still does the real work:
further down the same run, "the offline comparison names the one supplier that meets every
requirement" and "the controller's own comparison agrees with the evaluator's" are that
same offline process producing the result the recommendation is checked against.

**Step 7: Allow one host, and a short list of operations.** Permission to reach the supplier
is not permission to perform every supplier operation. The writer's profile names one host,
then defaults to deny and lists the exact method and path pairs allowed.

*Figure 2: What nono confines, at the level it confines it. The profile attaches to the
tool process the controller starts, not to the pod, and the proxy decides one operation at
a time: on the one approved host, the writer's draft submission is allowed and a purchase
order is refused.*

![A focused view of one tool role under nono. An Amazon EKS cluster frame holds a red Nitro sandbox frame labelled runtimeClassName colon isolated-sandbox, and inside that an Analyst pod box whose sub line reads that nono confines the processes it starts, not the pod. In the pod, a red nono profile icon sits above a writer tool process icon and is joined to it by a plain line labelled confines this process, so the control attaches to that one process rather than to the pod or to the sandbox. Along the bottom row of the pod, a Trusted controller icon described as owning AWS and having no profile has an arrow labelled 1. starts the writer to the writer tool process, described as one role, one action; the writer has an arrow labelled 2. request with a placeholder to a red nono proxy icon described as holding the supplier key. Two arrows leave the proxy for a Supplier API icon in a separate Supplier API pod box outside the sandbox, marked an ordinary pod reached by ClusterIP: a green one labelled 3. allowed colon GET suppliers, POST draft, and a red dashed one labelled refused at the proxy colon POST slash purchase-orders. Both name the same host, so the difference between them is the operation and not the destination. No frame encloses the pod's network and no arrow shows a route out of the pod being refused, because nothing in this blueprint restricts the pod's egress.](images/subagent-security-nono-tool-boundary.png)

Here is that part of [`policies/writer.json`](policies/writer.json):

```json
        "endpoint_policy": {
          "default": {
            "decision": "deny"
          },
          "allow": [
            {
              "method": "GET",
              "path": "/cases/rfp-001/suppliers"
            },
            {
              "method": "POST",
              "path": "/cases/rfp-001/recommendations"
            }
          ]
        }
```

The host the proxy will forward to is one entry, `allow_domain`, naming the approved
Service name and its port:

```json
    "allow_domain": [
      "supplier-api.<NAMESPACE>.svc.cluster.local:8443"
    ],
```

The reader's profile is the same with the `POST` left out, which is what makes the draft
submission the writer's job alone.

Two negative controls make the refusals attributable. The first is a second DNS name for the
very same server: `supplier-api-alias` selects the same pod as `supplier-api`, so the two
names reach one backend and a refusal on the alias is the profile's decision about the host
and not a broken route — the run proves the route by reaching that same name from the
controller, which is under no profile. The second is the supplier API itself, which accepts
an authenticated purchase order or supplier-record change: the controller sends the same
method and path with the real key, from outside the role boundary, and the server takes it.
Without these, a refusal could be the server's own doing or an unreachable address.

```text
PASS reader: GET /cases/rfp-001/suppliers returns 200
PASS the nono audit records GET /cases/rfp-001/suppliers
PASS the nono audit decision is allow
PASS reader: a direct connection to the supplier API is refused
PASS a second DNS name for the same server is refused
PASS the nono audit records the refused host
PASS the same server answers on that second name, with the same key, outside the role boundary
PASS reader: POST /cases/rfp-001/recommendations returns 403
PASS the nono audit records POST /cases/rfp-001/recommendations
PASS the nono audit decision is deny
PASS writer: PATCH /suppliers/northstar returns 403
PASS the nono audit records PATCH /suppliers/northstar
PASS the nono audit decision is deny
PASS the supplier API accepts PATCH /suppliers/northstar with the real key, outside the role boundary
PASS writer: POST /purchase-orders returns 403
PASS the nono audit records POST /purchase-orders
PASS the nono audit decision is deny
PASS the supplier API accepts POST /purchase-orders with the real key, outside the role boundary
PASS writer: GET /cases/rfp-other/suppliers returns 403
PASS the nono audit records GET /cases/rfp-other/suppliers
PASS the nono audit decision is deny
PASS the supplier API accepts GET /cases/rfp-other/suppliers with the real key, outside the role boundary
PASS writer: POST /cases/rfp-001/recommendations returns 201
PASS the nono audit records POST /cases/rfp-001/recommendations
PASS the nono audit decision is allow
```

Each refusal is read twice over: the role's own result, and nono's audit record for that
call naming the same method, path and decision. The `201` on the last three lines is the
writer's draft submission, the operation the reader is refused two blocks up, which is what
makes the difference between the two profiles visible rather than asserted.

**Step 8: Keep the real key with the proxy.** The profile tells nono where the real
credential is, which environment variable to put a placeholder in, and which header to
substitute it into:

```json
    "custom_credentials": {
      "supplier": {
        "upstream": "https://supplier-api.<NAMESPACE>.svc.cluster.local:8443",
        "credential_key": "file:///opt/supplier-key/api-key",
        "env_var": "SUPPLIER_API_KEY",
        "inject_header": "X-Api-Key",
        "credential_format": "{}",
        "tls_ca": "/opt/supplier-ca/ca.crt",
```

`credential_key` is where the proxy reads the real key, and it is a path no role's
`filesystem.read` list contains. `env_var` is the variable the role is handed a placeholder
in, and `inject_header` is the header the proxy substitutes the real key into.

The tool's own code is ordinary, and reads only the variable:

```python
headers = {"X-Api-Key": os.environ.get("SUPPLIER_API_KEY", ""),
           "X-Analyst-Request-ID": request_id}
```

The run shows the role holds a credential, that it is not the real one, and that it cannot
open the key file. Nothing prints a value: the comparison is by length and by digest.

```text
PASS the reader holds a supplier credential
PASS the reader's credential is not the real supplier key
PASS the reader has no AWS credential variable; its AWS environment is ['AWS_CA_BUNDLE']
PASS the reader has no model API key
PASS the reader cannot open the supplier key file
PASS the supplier API refuses an invalid key with 401
PASS the evidence and the report were scanned for the supplier key before being written, and the run was stopped if it appeared
```

Nothing here prints or stores either value. The comparison that decides "not the real
supplier key" is between salted digests taken under a per-run key the controller generates.
Three choices are deliberate:

- **The digest is salted and deliberately slow** — PBKDF2-HMAC-SHA256 under the per-run
  key, 200,000 iterations — rather than a bare or single-pass hash, because a fast digest
  of credential material can be checked cheaply against a list of candidates.
- **The digest is not kept.** It does its job in that one comparison and is then dropped
  from the run's record, so `calls.json` and `evidence.json` carry no commitment to either
  credential. The outcome is in the checks list by name, which is what you see above.
- **No measurement of either credential is recorded.** Not a length, not a present flag,
  not a digest. These files leave the pod and get read by people, and each comparison's
  outcome is already in the checks list above by name, so writing its inputs down adds
  nothing. What persists from that call is the three lists of variable *names*. The `401` is the upstream control: the supplier
API really does check the header, so the `200` the reader gets through the proxy is the
proxy having substituted a valid key and not the server waving anything through.

`AWS_CA_BUNDLE` is reported rather than hidden. nono sets it so that an AWS SDK inside a
role would trust the proxy's certificate; it is not a credential, which is why the check
names the variables that would authenticate and prints the rest instead of claiming the
role's AWS environment is empty.

**Step 9: Check what the tool roles cannot reach in AWS.** The controller holds the pod's
Pod Identity credentials; the roles get an environment the controller builds rather than
inherits, and are refused both the projected token file and the Pod Identity endpoint. IAM,
not nono, decides what the controller itself may do with Amazon S3.

```text
PASS the AWS SDK uses the Pod Identity container credential provider
PASS the caller is this sample's Pod Identity role
PASS the reader cannot open the Pod Identity token file
PASS the reader cannot reach the Pod Identity endpoint directly
PASS IAM returns AccessDenied for overwriting a source proposal
PASS IAM returns AccessDenied for deleting a source proposal
PASS IAM returns AccessDenied for reading another case's object
PASS the S3 proposal matches the case entry for northstar
PASS the S3 proposal matches the case entry for harbor
PASS the S3 proposal matches the case entry for cedar
PASS the image's fixtures match the objects in S3
```

The three `AccessDenied` lines are IAM's doing, not nono's: the role's policy grants
`s3:GetObject` on this case's proposals and reports and `s3:PutObject` on the reports prefix
only, so overwriting a source, deleting one, and reading another case's object are each
outside it. The other case's object is really there — `setup.sh` seeds it — so the denial
names an object that exists and is readable with other credentials, rather than being a
missing key.

No model API key is placed in the sandbox. The controller checks that by variable name,
printing the names it looked for rather than any value.

**Step 10: Show that the pod ran in a sandbox.** Read the analyst pod's runtime class, then
its own account of the machine it is running on.

The pod's age is read too, because the uptime below only means anything beside it.

```bash
export NAMESPACE=subagent-security-nono
kubectl get pod analyst -n $NAMESPACE -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl get pod analyst -n $NAMESPACE --no-headers | awk '{print "pod age: "$5}'
kubectl exec analyst -n $NAMESPACE -- sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo; cat /sys/class/dmi/id/product_name'
```

```text
isolated-sandbox
pod age: 41s
6.18.54 #1 SMP PREEMPT_DYNAMIC Thu Oct 22 17:38:11 UTC 2026
40.08
dm-0 vda vdb vdc
m8i.enclave
```

Now the same readings from an ordinary pod on the same node. Pinning the node is the point:
a reading from a pod on another instance would compare nothing.

```bash
NODE=$(kubectl get pod analyst -n $NAMESPACE -o jsonpath='{.spec.nodeName}')
[ -n "$NODE" ] || echo "the analyst pod is not running; run ./scripts/setup.sh first"
sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<MANAGED_BY>|nono|g" -e "s|<NODE_NAME>|$NODE|g" \
  deploy/ordinary-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/ordinary-comparison -n $NAMESPACE --timeout=2m
kubectl exec ordinary-comparison -n $NAMESPACE -- sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo; cat /sys/class/dmi/id/product_name'
```

```text
6.18.54 #2 SMP PREEMPT_DYNAMIC Thu Oct 22 00:16:59 UTC 2026
49659.02
dm-0 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 nvme0n1 nvme1n1 zram0
m8i.xlarge
```

Three readings differ, and each says something:

| Reading | Sandboxed analyst | Ordinary pod on the same node |
|---|---|---|
| `uname -rv` | `6.18.54 #1`, built Oct 22 17:38 | `6.18.54 #2`, built Oct 22 00:16 |
| `/proc/uptime` | `40.08`, against a pod age of 41s | `49659.02`, about 13.8 hours — the node's |
| `/sys/block` | `vda vdb vdc`, virtio | `nvme0n1 nvme1n1`, the instance's own |
| `product_name` | `m8i.enclave` | `m8i.xlarge` |

The analyst pod runs its **own kernel build**, and the uptime is the giveaway: 40 seconds
against a pod 41s old, because the sandbox booted when the pod did, while the ordinary pod
reports the node's thirteen-hour uptime. It sees virtio disks where the ordinary pod sees the
instance's `nvme` devices, and it names the enclave rather than the instance type.

Note that the kernel **version** is the same in both here — `6.18.54`. It is the build
number and the boot that differ, so compare `uname -rv` and not `uname -r`. And the runtime
class on the pod shows what was *asked for*, not what ran, so it supports the claim without
proving it; the readings inside the guest are what prove it.

Everything in step 5 to step 9 happened inside that boundary. nono's profiles, its proxy
and the supplier key are all in this pod, so they are what the sandbox contains, not what
protects the pod from the node.

Remove the comparison pod when you are done with it, by its exact name:

```bash
kubectl delete pod ordinary-comparison -n $NAMESPACE
```

## What nono's network confinement is, and is not

Everything the run shows about the network is nono deciding what a *tool process* may do.
It is worth being precise about how far that reaches, because a reader may be looking for a
pattern to copy.

- **It is enforced inside the pod, on the process.** nono's restrictions are applied to the
  tool process it starts. `network.block` makes `socket()` itself fail for the evaluator;
  for the online roles, the request goes through nono's proxy, which decides on the host and
  then on the method and path. The run shows a role refused a direct connection to the
  supplier API's own address, so that probe did not get out of the process by dialling the
  IP. What the run shows is that one refusal, for a role at uid 1000 making an IPv4 TCP
  connection to the resolved Service address. It is not a demonstration that the proxy
  cannot be routed around by any process or any other means.
- **It does not bound the pod.** The analyst pod has no network policy in this blueprint, so the
  pod's egress is whatever the cluster and VPC allow. The trusted controller runs under no
  nono profile and reaches Amazon Bedrock, Amazon S3 and the supplier API directly. A reader
  who wants the pod's egress restricted on the node wants
  [Isolation > Network policy](../../isolation/network-policy/README.md).
- **An allowed host is not an allowed operation.** That is the point of the endpoint policy:
  the writer reaches the one supplier host and is still refused a purchase order.
- **An allowed host is not a stop on getting data out.** A role that may reach a host may
  send it anything the method and path policy permits. nono bounds where a tool connects and
  with which credential; it is not a data-loss control.
- **The controller is trusted, and is not confined.** It holds the supplier key and the AWS
  credentials by design. nono is placed around what it launches, not around it.

## Good to know

- **nono confines the tool processes, not the application that starts them.** The controller
  is trusted code inside the sandbox: it reads the supplier key, holds the AWS credentials
  and writes the profiles. The boundary this page shows is around what it launches. A defect
  in the controller is not something nono is placed to catch.
- **The profiles are written where no role can write.** The controller generates each
  profile into a directory outside every role's write grant, so a role cannot widen its own
  profile, and nothing the model produces reaches the profile generator.
- **A refusal has to be told apart from a failure.** The worker reports a denied open or
  socket as structured data and lets everything else raise. A nono start-up failure, a
  timeout or a DNS error leaves no result line and fails the run, so a broken step can never
  read as a successful denial.
- **The negative controls are what make the refusals mean something.** The supplier API
  accepts an authenticated purchase order, and the alias Service reaches the same pod the
  approved one does. Without those, a refusal could be the server's doing or a broken route.
- **The pod is hardened, and nono still works under it.** The pod runs as uid 1000 with
  `runAsNonRoot`, `seccompProfile: RuntimeDefault`, every capability dropped,
  `allowPrivilegeEscalation: false`, a read-only root filesystem and
  `automountServiceAccountToken: false`. nono's controls are Landlock and seccomp, which
  need no privilege, and Landlock requires `no_new_privs` for an unprivileged process
  anyway, so `allowPrivilegeEscalation: false` is a precondition of this confinement rather
  than a cost of it. A blueprint about isolation should not have to give any of this up to
  demonstrate itself, and this one does not: the run whose output is on this page passed
  every file and network refusal with all of the above set.
- **The gates are task-specific correctness checks, not a defence against prompt injection.**
  They check that the model's explicit choice matches a comparison computed without it and
  that it cited the originals. They say nothing about whether the prose is otherwise sound.
- **The sandbox is sized by its requests.** This pod sets CPU and memory requests, which
  most blueprints here do not, because it has to hold a Python interpreter, the Strands Agents
  and AWS SDK packages, nono's proxy and three short-lived tool processes at once. Its limits
  are higher than its requests on purpose: the requests size the sandbox, and the two need
  not match (Amazon EKS User Guide, *Isolated and confidential pods limitations*).
- **Everything about the supplier is synthetic.** The proposals are invented, the supplier
  API holds no real records, and a purchase order against it orders nothing. The proposals
  hold no customer data.
- **The blueprint certificate authority is generated at setup and lasts 30 days.** It is created
  on your machine, kept in a Kubernetes Secret and a ConfigMap, and never committed. Run the
  clean up and `setup.sh` again to replace expired material.

## Clean up

`clean.sh` reads the same run record `setup.sh` wrote, so there is nothing to set again.

```bash
cd sample-eks-nitro-sandbox/examples/subagent-security/nono
./scripts/clean.sh --delete-aws
```

```text
==> 1/4 the namespace's own objects
pod "analyst" deleted from subagent-security-nono namespace
deployment.apps "supplier-api" deleted from subagent-security-nono namespace
namespace "subagent-security-nono" deleted

==> 2/4 the EKS Pod Identity association
  deleted the association a-8tfukbezevcahflrb.

==> 3/4 the AWS resources
  deleted the bucket subagent-analyst-nono-<ACCOUNT_ID>.
  deleted the IAM role subagent-analyst-nono.
  deleted the ECR repository pod-isolation/subagent-analyst-nono.
  deleted the ECR repository pod-isolation/subagent-analyst-nono-supplier-api.

==> 4/4 the local run files
  removed /path/to/sample-eks-nitro-sandbox/tmp/nono.

==> what stays
  This sample changed no cluster-wide setting and installed nothing shared, so there is
  nothing of that kind to undo.

  The isolated-sandbox RuntimeClass and the cluster itself are not this sample's. The
  hello sandbox sample's clean up covers removing the cluster.

Clean up complete.
```

`--delete-aws` also removes the run record under the repository's `tmp/`, which is where
`run.sh` copied the recommendation, so copy anything you want to keep out of there first.

It deletes in reverse order of creation, starting with the sandboxed pod, which is what
holds sandbox capacity other workloads on the cluster share. It touches a namespace only
when that namespace carries this blueprint's `app.kubernetes.io/managed-by` label, and an AWS
resource only when it carries `ManagedBy=nono`. A lookup that fails counts as "could not
determine" rather than "already gone", so anything it could not delete or confirm is named
at the end and makes it exit non-zero.

Without `--delete-aws` it removes the cluster objects and the Pod Identity association and
keeps the S3 bucket, the IAM role and the images, so a second run skips the build.

This blueprint changes no cluster-wide setting and installs nothing shared, so the clean up has
nothing of that kind to undo. The `isolated-sandbox` RuntimeClass and the cluster are not
this blueprint's; the
[hello sandbox clean up](../../getting-started/hello-sandbox/README.md#clean-up) covers
removing the cluster itself.
