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
#      Bedrock model is reachable, collects the cost reads itself (scripts/cost_snapshot.py)
#      and checks the most one run can cost, before it creates anything;
#   2. creates the namespace when it is absent, and the analyst ServiceAccount;
#   3. generates the supplier API key and a sample certificate authority;
#   4. builds and pushes the supplier API image;
#   5. creates a new S3 bucket and seeds the case, the three proposals and another case's
#      object;
#   6. creates the IAM role and the EKS Pod Identity association;
#   7. builds and pushes the analyst image with bubblewrap in it, starts the sandboxed
#      analyst pod, records its node, starts the supplier API as a pod on that same node,
#      and starts one real tool process in the analyst pod to show the guest allows the
#      boundary before you run a case.
#
# Both pods stop themselves at the run's clean-up deadline, and the images and objects
# expire a day later, whether or not anything on this machine is still running. If setup
# stops after creating anything it runs ./scripts/clean.sh --delete-aws --delete-node
# itself, and at the deadline scripts/deadline.sh runs that same clean up.
#
# This sample ships no network policy, so it does not restrict the analyst pod's egress
# and does not touch the cluster-wide network policy setting. bubblewrap confines the
# tool processes the controller starts, inside the pod; see
# examples/isolation/network-policy for restricting a sandbox's egress on the node.
#
# It never changes a cluster-wide setting and never reuses a resource that is not this
# sample's: it stops instead, and says what it found.
#
# Set in .env: CLUSTER_NAME and KUBE_CONTEXT are required; AWS_REGION, NAMESPACE,
# BEDROCK_MODEL_ID, BUCKET, ROLE_NAME and COST_EXTRA_S3_REQUESTS have defaults.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECTION_DIR="$(cd "$SAMPLE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SECTION_DIR/../.." && pwd)"

SAMPLE="bubblewrap"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-subagent-security-bubblewrap}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}"
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
# The run record, the lock and the identity check; its state_put replaces the shared one.
# shellcheck source=run-lib.sh
. "$SAMPLE_DIR/scripts/run-lib.sh"

[[ "$KUBE_CONTEXT" =~ ^[A-Za-z0-9_.:@/-]+$ ]] ||
  die "KUBE_CONTEXT is not set in .env, or has a character other than letters, digits and _.:@/-. The cost check binds its reads to that context's cluster endpoint, so this sample does not run against whichever context is current; created nothing."

# One setup, run or clean up of this sample at a time.
lock_take 0 ||
  die "another setup, run or clean up of this sample holds $LOCK_DIR (process $(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)); created nothing. Wait for it to finish."
wrote=false
on_setup_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" != 0 && "$wrote" != true ]]; then
    # Nothing was created yet: the run directory holds only this run's reads.
    rm -rf "$TMP_DIR"
  elif [[ "$status" != 0 ]]; then
    echo "setup stopped (exit $status); removing what this run created so nothing it started keeps billing" >&2
    { kc describe pods -n "$NAMESPACE"; kc logs analyst -n "$NAMESPACE" -c enable-guest-userns; } \
      > "$REPO_ROOT/tmp/$SAMPLE-setup-failure.log" 2>&1 || true
    "$SAMPLE_DIR/scripts/clean.sh" --delete-aws --delete-node ||
      echo "the clean up after the failed setup is incomplete (see above); run ./scripts/clean.sh --delete-aws --delete-node again" >&2
  fi
  lock_release
  exit "$status"
}
trap on_setup_exit EXIT

# One run at a time, and the run directory is what says so: mkdir fails if anything at all
# is already at that path, in one syscall. An earlier run's directory is the only place its
# resources are named, so this refuses rather than replacing it.
mkdir -p "$REPO_ROOT/tmp"
if ! mkdir -m 700 "$TMP_DIR"; then
  wrote=true  # not ours to remove
  trap - EXIT; lock_release
  die "could not create $TMP_DIR, and mkdir's own reason is above. If something is already there, an earlier run's resources may still be named only in it: finish that run with ./scripts/clean.sh --delete-aws, or, to keep its AWS resources, move $TMP_DIR aside rather than deleting it. Created nothing."
fi

# Nothing from here to the first write below creates anything in AWS or the cluster.
analyst_preflight
IDENTITY="$(identity_now)" ||
  die "could not read the account, role, cluster and kube context this run would act through; created nothing"
[[ -n "$IDENTITY" ]] ||
  die "the kube context $KUBE_CONTEXT does not point at the endpoint of cluster $CLUSTER_NAME, or the identity could not be read; created nothing"

# These names carry the account id, so they are computed after the preflight read it and
# are overridable in .env for a second run beside the first.
BUCKET="${BUCKET:-subagent-analyst-$SAMPLE-$ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME:-subagent-analyst-$SAMPLE}"
SUPPLIER_API_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE-supplier-api"
ANALYST_REPOSITORY="pod-isolation/subagent-analyst-$SAMPLE"

# Both images are built here first, on this machine only, so the cost check has their
# real sizes, and their ids are what the push later has to match.
cost_build_log="$TMP_DIR/image-build.log"
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

# The cost reads, collected now by this run itself, into its own private directory, so no
# folder made beforehand, by hand or otherwise, can stand in for them. Then the most one run
# can cost, rebuilt from those reads and bound to the identity read above. Silent when it
# passes; its terms go in the run record below.
COST_SNAPSHOT="$TMP_DIR/cost"
python3 "$SAMPLE_DIR/scripts/cost_snapshot.py" collect --out "$COST_SNAPSHOT" \
  --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --kube-context "$KUBE_CONTEXT" \
  --model-id "$BEDROCK_MODEL_ID" >/dev/null ||
  die "could not collect the cost reads, for the reason above; created nothing in AWS or the cluster"
cost_terms="$(python3 "$SAMPLE_DIR/scripts/cost_gate.py" --snapshot "$COST_SNAPSHOT" \
  --identity "$IDENTITY" --manifest "$SAMPLE_DIR/deploy/analyst-pod.yaml" \
  --envelope "$SAMPLE_DIR/src/run_envelope.json" --region "$AWS_REGION" \
  --account "$ACCOUNT_ID" --cluster-name "$CLUSTER_NAME" --kube-context "$KUBE_CONTEXT" \
  --extra-s3 "${COST_EXTRA_S3_REQUESTS:-}" \
  --model-id "$BEDROCK_MODEL_ID" --image "supplier-api=$SUPPLIER_API_IMAGE_BYTES" \
  --image "analyst=$ANALYST_IMAGE_BYTES" \
  --seed-object "$SECTION_DIR/analyst/fixtures/case.json" \
  --seed-object "$SECTION_DIR/analyst/fixtures/proposals/northstar.json" \
  --seed-object "$SECTION_DIR/analyst/fixtures/proposals/harbor.json" \
  --seed-object "$SECTION_DIR/analyst/fixtures/proposals/cedar.json")" ||
  die "the cost check refused this run, for the reason above; created nothing in AWS or the cluster"

started_epoch="$(date -u +%s)"
cleanup_at=$((started_epoch + $(jq -r '.timeline_s.cleanup_start' <<<"$cost_terms")))
clean_end=$((cleanup_at + $(jq -r '.timeline_s.clean_path' <<<"$cost_terms")))
[[ "$cleanup_at" -gt "$started_epoch" && "$clean_end" -gt "$cleanup_at" ]] ||
  die "the cost check gave no clean-up deadline; created nothing"
# The deadline's clean up runs with these same credentials, so they must outlive it.
credentials_last_until "$clean_end" ||
  die "the AWS credentials this shell uses expire before $(date -u -d "@$clean_end" +%H:%MZ 2>/dev/null || date -u -r "$clean_end" +%H:%MZ), when this run's clean up could still be running (or their expiry could not be read); created nothing. Sign in again with a longer session and re-run."

state_put SAMPLE "$SAMPLE"
state_put NAMESPACE "$NAMESPACE"
state_put BUCKET "$BUCKET"
state_put ROLE_NAME "$ROLE_NAME"
state_put CLUSTER_NAME "$CLUSTER_NAME"
state_put AWS_REGION "$AWS_REGION"
state_put KUBE_CONTEXT "$KUBE_CONTEXT"
state_put ACCOUNT_ID "$ACCOUNT_ID"
state_put CALLER_ROLE_ARN "$(jq -r '.role' <<<"$IDENTITY")"
state_put CLUSTER_ARN "$(jq -r '.cluster_arn' <<<"$IDENTITY")"
state_put CLUSTER_ENDPOINT "$(jq -r '.endpoint' <<<"$IDENTITY")"
state_put SUPPLIER_API_REPOSITORY "$SUPPLIER_API_REPOSITORY"
state_put ANALYST_REPOSITORY "$ANALYST_REPOSITORY"
state_put COST_SNAPSHOT "$COST_SNAPSHOT"
state_put COST_SNAPSHOT_SHA256 "$(jq -r '.snapshot_sha256' <<<"$cost_terms")"
state_put BEDROCK_MODEL_ID "$BEDROCK_MODEL_ID"
state_put COST_EXTRA_S3_REQUESTS "${COST_EXTRA_S3_REQUESTS:-}"
state_put SUPPLIER_API_IMAGE_BYTES "$SUPPLIER_API_IMAGE_BYTES"
state_put ANALYST_IMAGE_BYTES "$ANALYST_IMAGE_BYTES"
state_put COST_WORST_USD "$(jq -r '.worst_case_usd' <<<"$cost_terms")"
state_put RUN_STARTED_AT "$(date -u -d "@$started_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  date -u -r "$started_epoch" +%Y-%m-%dT%H:%M:%SZ)"
state_put CLEANUP_AT_EPOCH "$cleanup_at"
printf '%s\n' "$cost_terms" > "$TMP_DIR/cost-gate.json"

# Which nodes and NodeClaims the cluster already had. The clean up deletes a node or
# NodeClaim only if it is none of these, and setup refuses a run that made any other.
for kind in nodes nodeclaims; do
  if ! kc get "$kind" -o json | jq -c '[.items[].metadata.uid]' > "$TMP_DIR/$kind-at-start.json" ||
    [[ "$(jq -r 'type' "$TMP_DIR/$kind-at-start.json")" != array ]]; then
    die "could not list the cluster's $kind before the run; created nothing in AWS or the cluster"
  fi
done

# The clean up at the deadline, run by this machine. It is the second of two ways the run
# ends: both pods also stop themselves then, in the cluster, so a machine that is off or
# asleep at the deadline leaves a node with no workload, which EKS Auto Mode removes, and
# the AWS resources for the next clean up. It is started in its own session where setsid
# exists, and it answers before setup goes on, so setup knows it is running.
launcher=(nohup)
command -v setsid >/dev/null 2>&1 && launcher=(setsid nohup)
"${launcher[@]}" "$SAMPLE_DIR/scripts/deadline.sh" "$STATE_FILE" "$cleanup_at" \
  >> "$REPO_ROOT/tmp/$SAMPLE-deadline.log" 2>&1 < /dev/null &
deadline_pid=""
for _ in $(seq 20); do
  read -r deadline_pid deadline_at 2>/dev/null < "$TMP_DIR/deadline.ack" && break
  sleep 1
done
{ [[ "${deadline_at:-}" == "$cleanup_at" ]] &&
  ps -o args= -p "$deadline_pid" 2>/dev/null | grep -q 'deadline\.sh'; } ||
  die "the clean-up deadline process did not start and answer; created nothing in AWS or the cluster"
state_put DEADLINE_PID "$deadline_pid"

wrote=true
export ANALYST_EXPECTED_IMAGE_ID="$SUPPLIER_API_EXPECTED_ID"
analyst_namespace
analyst_supplier_secrets
say "4/7 the synthetic supplier API image"
analyst_supplier_image
# A new bucket for every run: one an earlier run left could hold objects, versions or
# settings this run's cost check never saw.
rc=0
lookup NoSuchBucket s3api get-bucket-tagging --bucket "$BUCKET" --output json >/dev/null || rc=$?
[[ "$rc" == 1 ]] ||
  die "the bucket $BUCKET already exists, or that could not be determined; this sample uses a new bucket for every run. Finish the run that made it with ./scripts/clean.sh --delete-aws, or set a new BUCKET in .env."
analyst_bucket
# A bucket that was never versioned answers with nothing at all.
versioning="$(aws s3api get-bucket-versioning --bucket "$BUCKET" --output json)" ||
  die "could not read back versioning on $BUCKET; stopped before running the analyst."
empty='{}'
expect "versioning on $BUCKET" "$(jq -r '.Status // "never enabled"' <<<"${versioning:-$empty}")" \
  "never enabled" "running the analyst"
# Whatever happens to this machine, the objects expire a day after they were written.
expire='{"Rules":[{"ID":"bubblewrap-expire","Status":"Enabled","Filter":{},"Expiration":{"Days":1}}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "$expire" >/dev/null
expect_aws "the lifecycle rule on $BUCKET" "running the analyst" \
  '[.Rules[] | [.ID, .Status, .Expiration.Days, (.Filter == {} or .Filter == {"Prefix": ""})]]' \
  '[["bubblewrap-expire","Enabled",1,true]]' s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"
analyst_role

# ---------------------------------------------------------------------------
# 7/7 the analyst image, its sandboxed pod, and one real tool process in it
# ---------------------------------------------------------------------------

say "7/7 the bubblewrap analyst image and its sandboxed pod"

export ANALYST_EXPECTED_IMAGE_ID="$ANALYST_EXPECTED_ID"
analyst_image "$ANALYST_REPOSITORY" bubblewrap/Dockerfile "${ANALYST_IMAGE_INPUTS[@]}"
unset ANALYST_EXPECTED_IMAGE_ID
# The pod names the image by its digest, so what runs is exactly what was pushed.
ANALYST_POD_IMAGE="${ANALYST_IMAGE%:*}@$IMAGE_DIGEST"
state_put ANALYST_IMAGE "$ANALYST_POD_IMAGE"
state_put ANALYST_REPOSITORY_CREATED "$IMAGE_REPOSITORY_CREATED"
state_put ANALYST_LOCAL_IMAGE_ID "$IMAGE_LOCAL_ID"
state_put ANALYST_LOCAL_IMAGE_REF "$ANALYST_IMAGE"
# Whatever happens to this machine, both images expire a day after they were pushed.
keep='{"rules":[{"rulePriority":1,"selection":{"tagStatus":"any","countType":"sinceImagePushed","countUnit":"days","countNumber":1},"action":{"type":"expire"}}]}'
for repo in "$SUPPLIER_API_REPOSITORY" "$ANALYST_REPOSITORY"; do
  aws ecr put-lifecycle-policy --repository-name "$repo" --lifecycle-policy-text "$keep" >/dev/null
  expect_aws "the lifecycle policy on $repo" "starting the analyst pod" \
    '.lifecyclePolicyText | fromjson | [.rules[] | [.rulePriority, .selection.tagStatus,
      .selection.countType, .selection.countUnit, .selection.countNumber, .action.type]]' \
    '[[1,"any","sinceImagePushed","days",1,"expire"]]' ecr get-lifecycle-policy --repository-name "$repo"
done

pod_deadline=$((cleanup_at - $(date -u +%s)))
# Fifteen minutes at least: the readiness waits and the node record below must all finish
# before the deadline's clean up can start.
[[ "$pod_deadline" -gt 900 ]] ||
  die "only ${pod_deadline}s are left before this run's clean-up deadline, too few to start the analyst pod and record its node"
analyst_render "$SAMPLE_DIR/deploy/analyst-pod.yaml" "$TMP_DIR/analyst-pod.yaml" \
  "s|<ANALYST_IMAGE>|$ANALYST_POD_IMAGE|g" \
  "s|<AWS_REGION>|$AWS_REGION|g" \
  "s|<BUCKET>|$BUCKET|g" \
  "s|<ROLE_NAME>|$ROLE_NAME|g" \
  "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g" \
  "s|<ACTIVE_DEADLINE_SECONDS>|$pod_deadline|g"

# activeDeadlineSeconds counts from the pod's own start, which comes after it was rendered.
# Once that start is known, the deadline is lowered (the only change Kubernetes allows) so
# the pod ends at CLEANUP_AT_EPOCH exactly, and read back.
pin_deadline() { # <pod>
  local started left
  started="$(kc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.startTime}')" || return 1
  started="$(epoch_of "$started")" || return 1
  left=$((cleanup_at - started))
  (( left > 0 )) || return 1
  kc patch pod "$1" -n "$NAMESPACE" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/activeDeadlineSeconds\",\"value\":$left}]" >/dev/null || return 1
  [[ "$(kc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.spec.activeDeadlineSeconds}')" == "$left" ]]
}

# Which node the pod landed on, and whether this run is what made it, read now while it is
# certain: the clean up deletes that node (--delete-node) only if every one of these still
# matches. A node or NodeClaim that was already on the cluster is not this run's.
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
  NODECLAIM_NAME="$(jq -r '.[0].metadata.name' <<<"$claim")"
  NODECLAIM_UID="$(jq -r '.[0].metadata.uid' <<<"$claim")"
  NODE_AT_START="$(jq --arg u "$(jq -r '.metadata.uid' <<<"$node")" \
    'index($u) != null' "$TMP_DIR/nodes-at-start.json")"
  # A node that is new must have a NodeClaim that is new too; anything else is a record
  # this run cannot stand behind.
  [[ "$NODE_AT_START" == true || "$(jq --arg u "$NODECLAIM_UID" 'index($u) == null' \
       "$TMP_DIR/nodeclaims-at-start.json")" == true ]] || return 1
  state_put NODE_NAME "$name"
  state_put NODE_UID "$(jq -r '.metadata.uid' <<<"$node")"
  state_put NODE_PROVIDER_ID "$(jq -r '.spec.providerID' <<<"$node")"
  state_put NODE_CREATED_AT "$(jq -r '.metadata.creationTimestamp' <<<"$node")"
  state_put NODE_POOL "$(jq -r '.metadata.labels["karpenter.sh/nodepool"] // ""' <<<"$node")"
  state_put NODECLAIM_NAME "$NODECLAIM_NAME"
  state_put NODECLAIM_UID "$NODECLAIM_UID"
  state_put NODECLAIM_CREATED_AT "$(jq -r '.[0].metadata.creationTimestamp' <<<"$claim")"
  state_put NODECLAIM_POOL "$(jq -r '.[0].metadata.labels["karpenter.sh/nodepool"] // ""' <<<"$claim")"
  state_put NODE_AT_START "$NODE_AT_START"
}

# At most one node may be this run's, and it must be the one recorded: every NodeClaim
# that appeared since the run started, and every one EKS Auto Mode nominated for this run's
# pods in the namespace's events (which also names one made and replaced between two
# lists), must be that one. Anything else is outside the run's cost bound.
only_the_recorded_claim() {
  local claims extra nominated mine=""
  [[ "$NODE_AT_START" == false ]] && mine="$NODECLAIM_UID"
  claims="$(kc get nodeclaims -o json)" || return 1
  extra="$(jq -r --slurpfile start "$TMP_DIR/nodeclaims-at-start.json" --arg mine "$mine" \
    '[.items[] | select((.metadata.uid as $u | $start[0] | index($u)) == null)
      | select(.metadata.uid != $mine) | .metadata.name] | join(" ")' <<<"$claims")" || return 1
  nominated="$(nominated_claims)" || return 1
  state_put NOMINATED_NODECLAIMS "$(tr '\n' ' ' <<<"$nominated" | sed 's/ *$//')"
  # A new node must show up in the events as the one nominated for the pod; if it does
  # not, the events cannot be read the way this check reads them, and it refuses.
  if [[ "$NODE_AT_START" == false ]]; then
    grep -qx "$NODECLAIM_NAME" <<<"$nominated" || return 1
    nominated="$(grep -vx "$NODECLAIM_NAME" <<<"$nominated" || true)"
  fi
  extra="$extra $(tr '\n' ' ' <<<"$nominated")"
  [[ -z "${extra// /}" ]] || { echo "NodeClaims that are not this run's record: $extra" >&2; return 1; }
}

# Replace this sample's own pod rather than adopting it, so an image, identity or
# environment change can never be hidden by a pod that was already running.
kc delete pod analyst -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=3m
kc apply -f "$TMP_DIR/analyst-pod.yaml"
if ! kc wait --for=condition=Ready pod/analyst -n "$NAMESPACE" --timeout=10m; then
  # A pod that was placed but never became ready still has a node: recording it is what
  # lets the clean up below delete that node. A Pending pod has none; the clean up finds a
  # NodeClaim launched for it in the namespace's events.
  record_node || true
  die "the analyst pod did not become ready; $REPO_ROOT/tmp/$SAMPLE-setup-failure.log has what the cluster said about it. If it was Pending, no xlarge Nitro sandbox node could be launched for it: the pod asks for that size and never a larger one."
fi
pin_deadline analyst ||
  die "could not set the analyst pod to end at the run's clean-up deadline"
record_node ||
  die "could not record which node and NodeClaim the analyst pod is on, or the record names a node that is new with a NodeClaim that is not"
only_the_recorded_claim ||
  die "this run is outside its cost bound: a NodeClaim that is not the one the run recorded appeared, or was nominated for this run's pods, or the list or events could not be read"

# The supplier API on that same node, bound to it, so nothing provisions a node for it: the
# shared manifest's two Services, and this sample's own pod in place of its Deployment.
echo "  starting the supplier API on $NODE_NAME, the analyst pod's own node"
analyst_render "$SECTION_DIR/analyst/deploy/supplier-api.yaml" "$TMP_DIR/supplier-api-all.yaml" \
  "s|<SUPPLIER_API_IMAGE>|$SUPPLIER_API_IMAGE|g"
awk '/^---$/ { n++ } n < 2' "$TMP_DIR/supplier-api-all.yaml" > "$TMP_DIR/supplier-api-services.yaml"
[[ "$(grep -c '^kind: Service$' "$TMP_DIR/supplier-api-services.yaml")" == 2 &&
   "$(grep -c '^kind:' "$TMP_DIR/supplier-api-services.yaml")" == 2 ]] ||
  die "the shared supplier API manifest no longer starts with its two Services"
analyst_render "$SAMPLE_DIR/deploy/supplier-api-pod.yaml" "$TMP_DIR/supplier-api-pod.yaml" \
  "s|<SUPPLIER_API_IMAGE>|${SUPPLIER_API_IMAGE%:*}@$SUPPLIER_API_DIGEST|g" \
  "s|<NODE_NAME>|$NODE_NAME|g" \
  "s|<ACTIVE_DEADLINE_SECONDS>|$((cleanup_at - $(date -u +%s)))|g"
kc delete deployment,pod supplier-api -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=3m
kc apply -n "$NAMESPACE" -f "$TMP_DIR/supplier-api-services.yaml"
kc create -n "$NAMESPACE" -f "$TMP_DIR/supplier-api-pod.yaml"
kc wait --for=condition=Ready pod/supplier-api -n "$NAMESPACE" --timeout=5m ||
  die "the supplier API did not become ready"
pin_deadline supplier-api ||
  die "could not set the supplier API's pod to end at the run's clean-up deadline"
[[ "$(kc get pod supplier-api -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')" == "$NODE_NAME" ]] ||
  die "the supplier API's pod is not on node $NODE_NAME"
only_the_recorded_claim ||
  die "this run is outside its cost bound: a NodeClaim that is not the recorded one appeared while the supplier API started"

# One real tool process, through the same launcher the controller uses. bubblewrap needs
# a user namespace and a private procfs inside the guest, and neither is available there
# by default: this is where a guest that cannot provide them says so.
#
# Twice, not once, with a pause between, and only for the transport condition: `kubectl
# exec` to a brand-new node can fail before it reaches the pod at all ("error dialing
# backend: remote error: tls: internal error"), and the very next command works. A guest
# that cannot run bubblewrap is answering the question this check asks, so it is not retried.
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
  grep -qE 'error dialing backend|tls: internal error|unable to upgrade connection' \
    <<<"$preflight_output" || break
  [[ "$attempt" == 1 ]] && sleep 10
done
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
  clean up:   due at $(date -u -d "@$cleanup_at" +%H:%MZ 2>/dev/null || date -u -r "$cleanup_at" +%H:%MZ), when both pods stop and this run removes itself unless you have

Run one procurement case, once:
  ./scripts/run.sh
EOF
