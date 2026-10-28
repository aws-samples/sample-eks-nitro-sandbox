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
#      Bedrock model is reachable;
#   2. creates the namespace when it is absent, and the analyst ServiceAccount;
#   3. generates the supplier API key and a sample certificate authority;
#   4. builds and pushes the supplier API image and starts it as an ordinary pod;
#   5. creates the S3 bucket and seeds the case, the three proposals and another case's
#      object;
#   6. creates the IAM role and the EKS Pod Identity association;
#   7. builds and pushes the analyst image with bubblewrap in it, starts the sandboxed
#      analyst pod, and starts one real tool process in it to show the guest allows the
#      boundary before you run a case.
#
# This sample ships no network policy, so it does not restrict the analyst pod's egress
# and does not touch the cluster-wide network policy setting. bubblewrap confines the
# tool processes the controller starts, inside the pod; see
# examples/isolation/network-policy for restricting a sandbox's egress on the node.
#
# It never changes a cluster-wide setting and never reuses a resource that is not this
# sample's: it stops instead, and says what it found.
#
# Overridable in .env (the defaults match the page):
#   CLUSTER_NAME AWS_REGION KUBE_CONTEXT NAMESPACE BEDROCK_MODEL_ID BUCKET ROLE_NAME
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
    --help|-h) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-subagent-security-bubblewrap}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}"

# shellcheck source=../../analyst/scripts/analyst-lib.sh
. "$SECTION_DIR/analyst/scripts/analyst-lib.sh"

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
  die "could not create $TMP_DIR, and mkdir's own reason is above. If something is already there, an earlier run's resources may still be named only in it: finish that run with ./scripts/clean.sh --delete-aws, or, to keep its AWS resources, move $TMP_DIR aside rather than deleting it, because it is the only place their names are written down and it also holds that run's supplier API key and sample certificate authority. Created nothing in the cluster or the account."

: > "$STATE_FILE"
state_put SAMPLE "$SAMPLE"
state_put NAMESPACE "$NAMESPACE"
state_put BUCKET "$BUCKET"
state_put ROLE_NAME "$ROLE_NAME"
state_put CLUSTER_NAME "$CLUSTER_NAME"
state_put AWS_REGION "$AWS_REGION"
state_put KUBE_CONTEXT "$KUBE_CONTEXT"
state_put SUPPLIER_API_REPOSITORY "$SUPPLIER_API_REPOSITORY"
state_put ANALYST_REPOSITORY "$ANALYST_REPOSITORY"

analyst_namespace
analyst_supplier_secrets
analyst_supplier_api
analyst_bucket
analyst_role

# ---------------------------------------------------------------------------
# 7/7 the analyst image, its sandboxed pod, and one real tool process in it
# ---------------------------------------------------------------------------

say "7/7 the bubblewrap analyst image and its sandboxed pod"

analyst_image "$ANALYST_REPOSITORY" bubblewrap/Dockerfile \
  bubblewrap/src/controller.py bubblewrap/src/sandbox.py bubblewrap/src/filters.py \
  bubblewrap/src/toolbox.py bubblewrap/src/preflight.py \
  analyst/requirements.txt analyst/src/business.py analyst/src/worker.py \
  analyst/src/analyst_agent.py analyst/fixtures/case.json analyst/fixtures/availability.json \
  analyst/fixtures/proposals/northstar.json analyst/fixtures/proposals/harbor.json \
  analyst/fixtures/proposals/cedar.json
ANALYST_POD_IMAGE="$ANALYST_IMAGE"
state_put ANALYST_IMAGE "$ANALYST_POD_IMAGE"

analyst_render "$SAMPLE_DIR/deploy/analyst-pod.yaml" "$TMP_DIR/analyst-pod.yaml" \
  "s|<ANALYST_IMAGE>|$ANALYST_POD_IMAGE|g" \
  "s|<AWS_REGION>|$AWS_REGION|g" \
  "s|<BUCKET>|$BUCKET|g" \
  "s|<ROLE_NAME>|$ROLE_NAME|g" \
  "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g"

# Replace this sample's own pod rather than adopting it, so an image, identity or
# environment change can never be hidden by a pod that was already running. The pod is
# in this sample's own namespace, which the steps above confirmed carries its label.
kc delete pod analyst -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=3m
kc apply -f "$TMP_DIR/analyst-pod.yaml"
kc wait --for=condition=Ready pod/analyst -n "$NAMESPACE" --timeout=10m ||
  die "the analyst pod did not become ready; 'kubectl describe pod analyst -n $NAMESPACE' says why"

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
for attempt in 1 2; do
  if preflight_output="$(kc exec analyst -n "$NAMESPACE" -- \
       python3 /opt/bubblewrap/preflight.py 2>&1)"; then
    printf '%s\n' "$preflight_output"
    preflight_failure=""
    break
  fi
  preflight_failure="$preflight_output"
  [[ "$attempt" == 1 ]] && sleep 10
done
[[ -z "$preflight_failure" ]] ||
  die "bubblewrap could not start a tool process in the guest, twice, ten seconds apart, and what it said is below. If that names a namespace or a procfs mount, the pod's enable-guest-userns init container and its privileged working container are what make those possible: 'kubectl logs analyst -c enable-guest-userns -n $NAMESPACE' and 'kubectl describe pod analyst -n $NAMESPACE' say what happened. If it is a connection error instead, the exec did not reach the pod and re-running this script is the thing to try.
$preflight_failure"

say "ready"
cat <<EOF
  namespace:  $NAMESPACE
  bucket:     $BUCKET
  role:       $ROLE_NAME
  model:      $BEDROCK_MODEL_ID
  run record: $STATE_FILE

Run one procurement case:
  ./scripts/run.sh
EOF
