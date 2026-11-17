#!/usr/bin/env bash
# setup.sh -- everything the procurement analyst needs on your cluster, with its tool
# processes confined by bubblewrap inside one Nitro sandbox.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./scripts/setup.sh
#
# What it does, in order:
#   1. checks the tools, the kube context, the isolated-sandbox RuntimeClass and that the
#      Bedrock model is reachable, then checks the most one run can cost against the cost
#      snapshot (scripts/cost_snapshot.py), before it creates anything;
#   2. creates the namespace when it is absent, and the analyst ServiceAccount;
#   3. generates the supplier API key and a sample certificate authority;
#   4. builds and pushes the supplier API image;
#   5. creates the S3 bucket and seeds the case, the three proposals and another case's
#      object;
#   6. creates the IAM role and the EKS Pod Identity association;
#   7. builds and pushes the analyst image with bubblewrap in it, starts the sandboxed
#      analyst pod, records its node, starts the supplier API as an ordinary pod on that
#      same node, and starts one real tool process in the analyst pod to show the guest
#      allows the boundary before you run a case.
#
# If it stops after creating anything, it runs ./scripts/clean.sh --delete-aws
# --delete-node itself. If it succeeds, a background process runs that same clean up at
# the run's deadline (scripts/deadline.sh) unless you have already removed the run.
#
# This sample ships no network policy, so it does not restrict the analyst pod's egress
# and does not touch the cluster-wide network policy setting. bubblewrap confines the
# tool processes the controller starts, inside the pod; see
# examples/isolation/network-policy for restricting a sandbox's egress on the node.
#
# It never changes a cluster-wide setting and never reuses a resource that is not this
# sample's: it stops instead, and says what it found.
#
# Set in .env: CLUSTER_NAME, KUBE_CONTEXT and COST_SNAPSHOT are required; AWS_REGION,
# NAMESPACE, BEDROCK_MODEL_ID, BUCKET, ROLE_NAME and COST_EXTRA_S3_REQUESTS have defaults.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECTION_DIR="$(cd "$SAMPLE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SECTION_DIR/../.." && pwd)"

SAMPLE="bubblewrap"
# The run record and every scratch file go under the repository's tmp/, which git
# ignores, and never in the sample folder: they hold this account's ARNs and this run's
# key material.
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-subagent-security-bubblewrap}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}"
COST_SNAPSHOT="${COST_SNAPSHOT:-}"
# A finite number of tries for every AWS CLI request, which the cost check counts on.
export AWS_MAX_ATTEMPTS=3 AWS_RETRY_MODE=standard

# The analyst image's build inputs, beside its Dockerfile. A digest of them is its tag.
ANALYST_IMAGE_INPUTS=(bubblewrap/src/controller.py bubblewrap/src/sandbox.py
  bubblewrap/src/filters.py bubblewrap/src/toolbox.py bubblewrap/src/preflight.py
  bubblewrap/src/run_envelope.json analyst/requirements.txt analyst/src/business.py
  analyst/src/worker.py analyst/src/analyst_agent.py analyst/fixtures/case.json
  analyst/fixtures/availability.json analyst/fixtures/proposals/northstar.json
  analyst/fixtures/proposals/harbor.json analyst/fixtures/proposals/cedar.json)

# shellcheck source=../../analyst/scripts/analyst-lib.sh
. "$SECTION_DIR/analyst/scripts/analyst-lib.sh"

# No run without a cost bound: COST_SNAPSHOT names the folder scripts/cost_snapshot.py
# collect wrote, and the check below rebuilds every price and offering from its raw reads.
[[ -n "$COST_SNAPSHOT" && -d "$COST_SNAPSHOT" && "$COST_SNAPSHOT" =~ ^[A-Za-z0-9_./-]+$ ]] ||
  die "COST_SNAPSHOT is not set in .env, names no folder, or has a character other than letters, digits and _./- in its path. Collect one with python3 scripts/cost_snapshot.py collect, as it describes, and set COST_SNAPSHOT to its folder; created nothing."
[[ -n "$KUBE_CONTEXT" ]] ||
  die "KUBE_CONTEXT is not set in .env. The cost check binds its snapshot to that context's cluster endpoint, so this sample does not run against whichever context is current; created nothing."

# Nothing from here down to the run record below creates anything, which is the point of
# the order. The record is the only place the names of what a run created are written down
# (bucket, role, repositories, namespace), and it used to be truncated before any of this:
# a missing credential or an unreachable model would then have cost you the only record of
# what an earlier run had left behind.
analyst_preflight

# These names carry the account id, so they are computed after the preflight read it and
# are overridable in .env for a second run beside the first.
BUCKET="${BUCKET:-subagent-analyst-$SAMPLE-$ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-subagent-analyst-$SAMPLE}"
SUPPLIER_API_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE-supplier-api"
ANALYST_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE"

# The most one run can cost, checked before the first write to AWS or the cluster. Both
# images are built here first, on this machine only, so the check has their real sizes,
# and their ids are what the push later has to match. Silent when it passes; its terms go
# in the run record below.
cost_build_log="$(mktemp "${TMPDIR:-/tmp}/bubblewrap-build.XXXXXX")" ||
  die "could not make a scratch file for the image builds; created nothing"
measure_image() { # <repository> <dockerfile> <inputs...>; sets MEASURED_ID MEASURED_BYTES
  analyst_image_ref "$@"
  analyst_image_build "$2" >"$cost_build_log" 2>&1 ||
    { cat "$cost_build_log" >&2; die "the image $ANALYST_IMAGE did not build; created nothing"; }
  MEASURED_ID="" MEASURED_BYTES=""
  read -r MEASURED_ID MEASURED_BYTES < <(docker image inspect --format '{{.Id}} {{.Size}}' \
    "$ANALYST_IMAGE") || true
  [[ -n "$MEASURED_ID" && "$MEASURED_BYTES" =~ ^[0-9]+$ ]] ||
    die "could not read the id and size of $ANALYST_IMAGE; created nothing"
}
measure_image "$SUPPLIER_API_REPOSITORY" analyst/supplier-api/Dockerfile \
  "${ANALYST_SUPPLIER_API_INPUTS[@]}"
SUPPLIER_API_EXPECTED_ID="$MEASURED_ID" SUPPLIER_API_IMAGE_BYTES="$MEASURED_BYTES"
measure_image "$ANALYST_REPOSITORY" bubblewrap/Dockerfile "${ANALYST_IMAGE_INPUTS[@]}"
ANALYST_EXPECTED_ID="$MEASURED_ID" ANALYST_IMAGE_BYTES="$MEASURED_BYTES"
rm -f "$cost_build_log"
cost_gate() { # the same check run.sh repeats before the model turn
  python3 "$SAMPLE_DIR/scripts/cost_gate.py" --snapshot "$COST_SNAPSHOT" \
    --manifest "$SAMPLE_DIR/deploy/analyst-pod.yaml" \
    --envelope "$SAMPLE_DIR/src/run_envelope.json" --region "$AWS_REGION" \
    --account "$ACCOUNT_ID" --cluster-name "$CLUSTER_NAME" --kube-context "$KUBE_CONTEXT" \
    --extra-s3 "${COST_EXTRA_S3_REQUESTS:-}" \
    --model-id "$BEDROCK_MODEL_ID" --image "supplier-api=$SUPPLIER_API_IMAGE_BYTES" \
    --image "analyst=$ANALYST_IMAGE_BYTES" \
    --seed-object "$SECTION_DIR/analyst/fixtures/case.json" \
    --seed-object "$SECTION_DIR/analyst/fixtures/proposals/northstar.json" \
    --seed-object "$SECTION_DIR/analyst/fixtures/proposals/harbor.json" \
    --seed-object "$SECTION_DIR/analyst/fixtures/proposals/cedar.json"
}
cost_terms="$(cost_gate)" ||
  die "the cost check refused this run, for the reason above; created nothing in AWS or the cluster"
COST_SNAPSHOT_SHA256="$(jq -r '.snapshot_sha256' <<<"$cost_terms")"

# The run record is the only place the names of what an earlier run created are written
# down, so this refuses to overwrite one that names something different rather than
# replacing it. The case that matters is a reader who changes a name in .env to run a
# second copy: without this, the first copy's names would be gone and its clean up would
# have nothing to go on. Names that match are this run's own, so replacing the record
# loses nothing.
#
# It is also why the record is touched here and not earlier: everything above creates
# nothing, so a run that stops above this line leaves both the account and the record
# exactly as it found them.
# One run at a time, and the run directory is what says so. Creating it is the check:
# mkdir fails if anything is already at that path, whatever kind of thing it is, in one
# syscall that cannot be interleaved with anything else. So there is nothing to parse, no
# key to compare and no path type to enumerate.
#
# This is the sixth shape this check has had and the five before it each failed somewhere.
# Comparing the record's names missed the Region, the cluster, the context and the account,
# and treated an absent key like an empty value. Deleting the check was worse. Testing
# [[ ! -e ]] before truncating passed a dangling symbolic link, and the truncate then
# created the link's target. Creating the record under noclobber passed a FIFO, where the
# open would block instead, and a character device. mkdir rejects all of those.
#
# Why it refuses rather than replacing, which is the reasoning I had wrong twice: the
# record is the only place the names of what a run created are written down, and clean.sh's
# ownership checks do not make losing it safe. Every copy of this sample marks its
# resources ManagedBy=bubblewrap and labels its namespace the same way, so those checks
# stop a foreign resource and not another copy's. The path .env.example invites, changing
# BUCKET and ROLE_NAME to run a second copy, would therefore have left the first copy's
# resources with nothing pointing at them, and a later clean up could report "already gone"
# for names that were never created and exit zero.
#
# Everything above this line reads, so a run that stops above it has created no run
# directory and nothing at all in the cluster or the account. mkdir's own error is left on
# standard error rather than suppressed: it is the difference between "an earlier run is
# here" and a permission, quota or read-only filesystem problem, and the message below
# would otherwise diagnose the second as the first.
mkdir -p "$REPO_ROOT/tmp"
mkdir -m 700 "$TMP_DIR" ||
  die "could not create $TMP_DIR, and mkdir's own reason is above. If something is already there, an earlier run's resources may still be named only in it: finish that run with ./scripts/clean.sh --delete-aws, or, to keep its AWS resources, move $TMP_DIR aside rather than deleting it, because it is the only place their names are written down and it also holds that run's supplier API key and sample certificate authority. It may have created the gitignored $REPO_ROOT/tmp directory, but no run directory, no state file, and nothing in the cluster or the account."

: > "$STATE_FILE"
state_put SAMPLE "$SAMPLE"
state_put NAMESPACE "$NAMESPACE"
state_put BUCKET "$BUCKET"
state_put ROLE_NAME "$ROLE_NAME"
state_put CLUSTER_NAME "$CLUSTER_NAME"
state_put AWS_REGION "$AWS_REGION"
state_put ACCOUNT_ID "$ACCOUNT_ID"
state_put KUBE_CONTEXT "$KUBE_CONTEXT"
state_put SUPPLIER_API_REPOSITORY "$SUPPLIER_API_REPOSITORY"
state_put ANALYST_REPOSITORY "$ANALYST_REPOSITORY"
state_put COST_SNAPSHOT "$COST_SNAPSHOT"
state_put BEDROCK_MODEL_ID "$BEDROCK_MODEL_ID"
state_put COST_SNAPSHOT_SHA256 "$COST_SNAPSHOT_SHA256"
state_put COST_EXTRA_S3_REQUESTS "${COST_EXTRA_S3_REQUESTS:-}"
state_put SUPPLIER_API_IMAGE_BYTES "$SUPPLIER_API_IMAGE_BYTES"
state_put ANALYST_IMAGE_BYTES "$ANALYST_IMAGE_BYTES"
state_put COST_WORST_USD "$(jq -r '.worst_case_usd' <<<"$cost_terms")"
printf '%s\n' "$cost_terms" > "$TMP_DIR/cost-gate.json"

# From here on, a run that stops for any reason removes what it created, so nothing it
# started keeps running or billing: the pods first, then the node through its NodeClaim,
# waiting for the instance to be terminated, then the AWS resources. What the cluster said
# about the pods is kept for you in tmp/, outside the run directory the clean up removes.
on_setup_exit() {
  local status=$?
  [[ "$status" != 0 ]] || return 0
  trap - EXIT
  echo "setup stopped (exit $status); removing what this run created so nothing it started keeps billing" >&2
  { kc describe pods -n "$NAMESPACE"; kc logs analyst -n "$NAMESPACE" -c enable-guest-userns; } \
    > "$REPO_ROOT/tmp/$SAMPLE-setup-failure.log" 2>&1 || true
  "$SAMPLE_DIR/scripts/clean.sh" --delete-aws --delete-node ||
    echo "the clean up after the failed setup is incomplete (see above); run ./scripts/clean.sh --delete-aws --delete-node again" >&2
  exit "$status"
}
trap on_setup_exit EXIT

# When the run started, which nodes and NodeClaims the cluster already had, and when the
# run's clean up must start. The clean up deletes the node this run's pod lands on only if
# it appeared after this and is none of these, and setup refuses a run that made any other.
started_epoch="$(date -u +%s)"
state_put RUN_STARTED_AT "$(date -u -d "@$started_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  date -u -r "$started_epoch" +%Y-%m-%dT%H:%M:%SZ)"
cleanup_at=$((started_epoch + $(jq -r '.timeline_s.cleanup_start' <<<"$cost_terms")))
[[ "$cleanup_at" -gt "$started_epoch" ]] || die "the cost check gave no clean-up deadline"
state_put CLEANUP_AT_EPOCH "$cleanup_at"
if ! kc get nodes -o json | jq -c '[.items[].metadata.uid]' > "$TMP_DIR/nodes-at-start.json" ||
  [[ "$(jq -r 'type' "$TMP_DIR/nodes-at-start.json")" != array ]]; then
  die "could not list the cluster's nodes before the run; created nothing in AWS or the cluster"
fi
if ! kc get nodeclaims -o json | jq -c '[.items[].metadata.uid]' > "$TMP_DIR/nodeclaims-at-start.json" ||
  [[ "$(jq -r 'type' "$TMP_DIR/nodeclaims-at-start.json")" != array ]]; then
  die "could not list the cluster's NodeClaims before the run; created nothing in AWS or the cluster"
fi

# The deadline, enforced without you: at CLEANUP_AT_EPOCH a background process on this
# machine runs ./scripts/clean.sh --delete-aws --delete-node, unless this run's record is
# gone by then. The analyst pod also stops itself at that time (activeDeadlineSeconds).
# shortcut: the process lives on this machine, so a machine that is off at the deadline
# runs it when it wakes; an in-cluster timer would need cluster-wide permissions.
nohup "$SAMPLE_DIR/scripts/deadline.sh" "$STATE_FILE" "$cleanup_at" \
  >> "$REPO_ROOT/tmp/$SAMPLE-deadline.log" 2>&1 < /dev/null &
state_put DEADLINE_PID "$!"

export ANALYST_EXPECTED_IMAGE_ID="$SUPPLIER_API_EXPECTED_ID"
analyst_namespace
analyst_supplier_secrets
# The supplier API's image now; its pod starts on the analyst pod's node, once that is
# known (step 7), so it never makes EKS Auto Mode launch a node of its own.
say "4/7 the synthetic supplier API image"
analyst_supplier_image
analyst_bucket
analyst_role

# ---------------------------------------------------------------------------
# 7/7 the analyst image, its sandboxed pod, and one real tool process in it
# ---------------------------------------------------------------------------

say "7/7 the bubblewrap analyst image and its sandboxed pod"

export ANALYST_EXPECTED_IMAGE_ID="$ANALYST_EXPECTED_ID"
analyst_image "$ANALYST_REPOSITORY" bubblewrap/Dockerfile "${ANALYST_IMAGE_INPUTS[@]}"
unset ANALYST_EXPECTED_IMAGE_ID
ANALYST_POD_IMAGE="$ANALYST_IMAGE"
state_put ANALYST_IMAGE "$ANALYST_POD_IMAGE"
state_put ANALYST_REPOSITORY_CREATED "$IMAGE_REPOSITORY_CREATED"
state_put ANALYST_LOCAL_IMAGE_ID "$IMAGE_LOCAL_ID"

pod_deadline=$((cleanup_at - $(date -u +%s)))
# Fifteen minutes at least: the ten-minute readiness wait and the node record below must
# both finish before the deadline's clean up can start.
[[ "$pod_deadline" -gt 900 ]] ||
  die "only ${pod_deadline}s are left before this run's clean-up deadline, too few to start the analyst pod and record its node"
analyst_render "$SAMPLE_DIR/deploy/analyst-pod.yaml" "$TMP_DIR/analyst-pod.yaml" \
  "s|<ANALYST_IMAGE>|$ANALYST_POD_IMAGE|g" \
  "s|<AWS_REGION>|$AWS_REGION|g" \
  "s|<BUCKET>|$BUCKET|g" \
  "s|<ROLE_NAME>|$ROLE_NAME|g" \
  "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g" \
  "s|<ACTIVE_DEADLINE_SECONDS>|$pod_deadline|g"

# Which node the pod landed on, and whether this run is what made it, read now while it is
# certain: the clean up deletes that node (--delete-node) only if every one of these still
# matches and the node appeared after the run started.
record_node() {
  local pod node claims claim name
  pod="$(kc get pod analyst -n "$NAMESPACE" -o json)" || return 1
  name="$(jq -r '.spec.nodeName // ""' <<<"$pod")"
  [[ -n "$name" ]] || return 1
  node="$(kc get node "$name" -o json)" || return 1
  claims="$(kc get nodeclaims -o json)" || return 1
  claim="$(jq -c --arg p "$(jq -r '.spec.providerID // ""' <<<"$node")" \
    '[.items[] | select(.status.providerID == $p and $p != "")]' <<<"$claims")"
  [[ "$(jq 'length' <<<"$claim")" == 1 ]] || return 1
  NODE_NAME="$name"
  NODECLAIM_UID="$(jq -r '.[0].metadata.uid' <<<"$claim")"
  NODE_AT_START="$(jq --arg u "$(jq -r '.metadata.uid' <<<"$node")" \
    'index($u) != null' "$TMP_DIR/nodes-at-start.json")"
  state_put NODE_NAME "$name"
  state_put NODE_UID "$(jq -r '.metadata.uid' <<<"$node")"
  state_put NODE_PROVIDER_ID "$(jq -r '.spec.providerID' <<<"$node")"
  state_put NODE_CREATED_AT "$(jq -r '.metadata.creationTimestamp' <<<"$node")"
  state_put NODE_POOL "$(jq -r '.metadata.labels["karpenter.sh/nodepool"] // ""' <<<"$node")"
  state_put NODECLAIM_NAME "$(jq -r '.[0].metadata.name' <<<"$claim")"
  state_put NODECLAIM_UID "$NODECLAIM_UID"
  state_put NODECLAIM_CREATED_AT "$(jq -r '.[0].metadata.creationTimestamp' <<<"$claim")"
  state_put NODECLAIM_POOL "$(jq -r '.[0].metadata.labels["karpenter.sh/nodepool"] // ""' <<<"$claim")"
  state_put NODE_AT_START "$NODE_AT_START"
}

# Replace this sample's own pod rather than adopting it, so an image, identity or
# environment change can never be hidden by a pod that was already running. The pod is
# in this sample's own namespace, which the steps above confirmed carries its label.
kc delete pod analyst -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=3m
kc apply -f "$TMP_DIR/analyst-pod.yaml"
if ! kc wait --for=condition=Ready pod/analyst -n "$NAMESPACE" --timeout=10m; then
  # A pod that was placed but never became ready still has a node: recording it is what
  # lets the clean up below delete that node. A Pending pod has none, and records nothing.
  record_node || true
  die "the analyst pod did not become ready; $REPO_ROOT/tmp/$SAMPLE-setup-failure.log has what the cluster said about it. If it was Pending, no xlarge Nitro sandbox node could be launched for it: the pod asks for that size and never a larger one."
fi

record_node ||
  die "could not record which node and NodeClaim the analyst pod is on. A NodeClaim this run cannot name is left to EKS Auto Mode, which removes an empty node with no deadline; 'kubectl get nodeclaims' shows it until then"

# At most one node may be this run's, and it must be the one recorded: every NodeClaim that
# appeared since the run started must be that one. A run that made any other, whoever's it
# turns out to be, is outside its cost bound and stops here.
only_the_recorded_claim() {
  local claims extra
  claims="$(kc get nodeclaims -o json)" || return 1
  extra="$(jq -r --slurpfile start "$TMP_DIR/nodeclaims-at-start.json" --arg mine "$(
      [[ "$NODE_AT_START" == false ]] && printf '%s' "$NODECLAIM_UID")" \
    '[.items[] | select((.metadata.uid as $u | $start[0] | index($u)) == null)
      | select(.metadata.uid != $mine) | .metadata.name] | join(" ")' <<<"$claims")" || return 1
  [[ -z "$extra" ]] || { echo "NodeClaims that are not this run's record appeared during the run: $extra" >&2; return 1; }
}
only_the_recorded_claim ||
  die "this run is outside its cost bound: the cluster has a NodeClaim that appeared after the run started and is not the one the run recorded (or the list could not be read)"

# The supplier API runs on that same node, bound to it, so nothing provisions a node for it.
echo "  starting the supplier API on $NODE_NAME, the analyst pod's own node"
analyst_supplier_deploy "$NODE_NAME"
only_the_recorded_claim ||
  die "this run is outside its cost bound: a NodeClaim that is not the recorded one appeared while the supplier API started"

# One real tool process, through the same launcher the controller uses. bubblewrap needs
# a user namespace and a private procfs inside the guest, and neither is available there
# by default: this is where a guest that cannot provide them says so, instead of the
# first run failing in a way that reads like a bug in the sample.
#
# Twice, not once, with a pause between. The pod is seconds old here and often on a node
# that is too, and `kubectl exec` to a brand-new node can fail before it reaches the pod
# at all: one run of this script died on "error dialing backend: remote error: tls:
# internal error", and the very next command into that same pod worked. Treating that as
# a guest that cannot run bubblewrap sends a reader to the init container's logs over
# something they need only retry, so the second attempt is what decides and the message
# below names both possibilities rather than only the one this check exists for.
preflight_failure=""
preflight_attempts=0
for attempt in 1 2; do
  preflight_attempts="$attempt"
  if preflight_output="$(kc exec analyst -n "$NAMESPACE" -- \
       python3 /opt/bubblewrap/preflight.py 2>&1)"; then
    printf '%s\n' "$preflight_output"
    preflight_failure=""
    break
  fi
  preflight_failure="$preflight_output"
  # Only the transport condition is retried. A guest that cannot run bubblewrap is
  # answering the question this check asks, and asking it twice does not make the answer
  # truer: retrying every failure would let a real one fail once, succeed once and be
  # discarded, with only the success printed.
  grep -qE 'error dialing backend|tls: internal error|unable to upgrade connection' \
    <<<"$preflight_output" || break
  [[ "$attempt" == 1 ]] && sleep 10
done
# Said as it happened: a guest failure is not retried, so reporting "twice" for it would
# be false, which is what round 17 found.
if [[ "$preflight_attempts" == 1 ]]; then preflight_tried="once"
else preflight_tried="twice, ten seconds apart"; fi
[[ -z "$preflight_failure" ]] ||
  die "bubblewrap could not start a tool process in the guest, $preflight_tried, and what it said is below. If that names a namespace or a procfs mount, the pod's enable-guest-userns init container and its privileged working container are what make those possible: $REPO_ROOT/tmp/$SAMPLE-setup-failure.log has that container's log and what the cluster said about the pod. If it is a connection error instead, the exec did not reach the pod, and a new run, once this one's clean up below has finished, is the thing to try.
$preflight_failure"

say "ready"
cat <<EOF
  namespace:  $NAMESPACE
  bucket:     $BUCKET
  role:       $ROLE_NAME
  model:      $BEDROCK_MODEL_ID
  run record: $STATE_FILE
  clean up:   due at $(date -u -d "@$cleanup_at" +%H:%MZ 2>/dev/null || date -u -r "$cleanup_at" +%H:%MZ), when this run removes itself unless you have

Run one procurement case:
  ./scripts/run.sh
EOF
