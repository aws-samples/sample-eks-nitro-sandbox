#!/usr/bin/env bash
# run-lib.sh -- what setup.sh, run.sh, clean.sh and deadline.sh share: the run record, the
# lock that lets only one of them act at a time, the exact AWS error check, and the identity
# every one of them must still be acting as. Source it; do not run it.
#
# The caller sets REPO_ROOT and SAMPLE first, from its own location. TMP_DIR, STATE_FILE and
# LOCK_DIR come from here, and nothing in the run record can change any of them.

TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
# The run record: one JSON object of strings, written whole to a new file that then replaces
# the old one, so a reader sees the record before a write or after it and never half of one.
# It is parsed, never sourced, so nothing in it can run as code.
STATE_FILE="$TMP_DIR/state.json"
# Outside TMP_DIR, so the clean up that removes the run directory does not remove the lock
# another script is waiting on.
LOCK_DIR="$REPO_ROOT/tmp/$SAMPLE.lock"

# Every key the run record may hold. A record with any other key is not this sample's run
# record and is refused whole: no path, tool setting or script variable is ever set from it.
STATE_KEYS=" SAMPLE RUN_ID NAMESPACE BUCKET ROLE_NAME CLUSTER_NAME AWS_REGION KUBE_CONTEXT ACCOUNT_ID
  CALLER_ROLE_ARN CLUSTER_ARN CLUSTER_ENDPOINT SUPPLIER_API_REPOSITORY ANALYST_REPOSITORY COST_SNAPSHOT
  COST_SNAPSHOT_SHA256 BEDROCK_MODEL_ID COST_EXTRA_S3_REQUESTS SUPPLIER_API_IMAGE_BYTES ANALYST_IMAGE_BYTES
  COST_WORST_USD RUN_STARTED_AT CLEANUP_AT_EPOCH DEADLINE_PID NAMESPACE_CREATED NAMESPACE_UID
  SUPPLIER_API_IMAGE SUPPLIER_API_DIGEST SUPPLIER_API_REPOSITORY_CREATED SUPPLIER_API_LOCAL_IMAGE_ID
  BUCKET_CREATED ROLE_CREATED ROLE_ARN ROLE_ID POD_IDENTITY_ASSOCIATION POD_IDENTITY_ASSOCIATION_CREATED
  ANALYST_IMAGE ANALYST_REPOSITORY_CREATED ANALYST_LOCAL_IMAGE_ID ANALYST_LOCAL_IMAGE_REF NODE_NAME
  NODE_UID NODE_PROVIDER_ID NODE_CREATED_AT NODE_POOL NODECLAIM_NAME NODECLAIM_UID NODECLAIM_CREATED_AT
  NODECLAIM_POOL NODE_AT_START NOMINATED_NODECLAIMS MODEL_TURN_AT CLEAN_RUNS_DONE "
STATE_KEYS="${STATE_KEYS//$'\n'/ }"

state_put() { # <KEY> <value>
  [[ "$STATE_KEYS" == *" $1 "* ]] || die "'$1' is not a run-record key"
  local next
  next="$(mktemp "$STATE_FILE.XXXXXX")" || die "could not write $1 to the run record"
  if ! { if [[ -s "$STATE_FILE" ]]; then jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE_FILE"
         else jq -n --arg k "$1" --arg v "$2" '{($k): $v}'; fi; } > "$next" ||
     ! mv -f "$next" "$STATE_FILE"; then
    rm -f "$next"
    die "could not write $1 to the run record $STATE_FILE"
  fi
}

# Sets one shell variable per key of the run record, after checking the whole record: a
# regular file, one JSON object, every value a string, every key one of STATE_KEYS, and
# every key the caller names present. Anything else fails and sets nothing.
state_load() { # [<required key>...]
  local key value keys
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  keys="$(jq -er 'if type == "object" and all(.[]; type == "string" and (contains("\u0000") | not))
    then keys | join(" ") else error("not a run record") end' "$STATE_FILE" 2>/dev/null)" || return 1
  for key in $keys; do [[ "$STATE_KEYS" == *" $key "* ]] || return 1; done
  for key in "$@"; do [[ " $keys " == *" $key "* ]] || return 1; done
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    printf -v "$key" '%s' "$value"
  done < <(jq -j 'to_entries[] | "\(.key)\u0000\(.value)\u0000"' "$STATE_FILE")
}

# One setup, run or clean up at a time. A script started by the one holding the lock (the
# clean up a failed setup or run starts) inherits its token and goes ahead; anyone else waits
# up to <seconds>, then refuses. A lock whose holder has exited is taken over. setup.sh
# starts deadline.sh without the token, so the deadline waits for the lock like anyone else.
LOCK_HELD=false
lock_take() { # [<seconds to wait>]
  local end=$((SECONDS + ${1:-0})) tries=$(( ${1:-0} / 5 )) owner aside
  if [[ -n "${BUBBLEWRAP_LOCK_TOKEN:-}" && -f "$LOCK_DIR/token" &&
        "$(cat "$LOCK_DIR/token" 2>/dev/null)" == "$BUBBLEWRAP_LOCK_TOKEN" ]]; then
    return 0
  fi
  mkdir -p "$REPO_ROOT/tmp"
  until mkdir -m 700 "$LOCK_DIR" 2>/dev/null; do
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null &&
       mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
      # Only the dead holder's lock is removed; one a new holder made meanwhile goes back.
      aside="$LOCK_DIR.stale.$$"
      if [[ "$(cat "$aside/pid" 2>/dev/null)" == "$owner" ]]; then rm -rf "$aside"
      else mv "$aside" "$LOCK_DIR" 2>/dev/null || rm -rf "$aside"; fi
      continue
    fi
    (( SECONDS < end && tries-- > 0 )) || return 1
    sleep 5
  done
  BUBBLEWRAP_LOCK_TOKEN="$$.$RANDOM.$(date -u +%s)"
  export BUBBLEWRAP_LOCK_TOKEN
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  printf '%s\n' "$BUBBLEWRAP_LOCK_TOKEN" > "$LOCK_DIR/token"
  LOCK_HELD=true
}
lock_release() {
  [[ "$LOCK_HELD" == true ]] || return 0
  rm -rf "$LOCK_DIR"
  LOCK_HELD=false
}

# Absence, proved by the service's own error and nothing else: exit 254 (the AWS CLI's
# "the service returned an error"), nothing on standard output, and one line on standard
# error that is exactly "An error occurred (<code>) when calling the <Operation> operation".
# Any other failure, including an AccessDenied whose message happens to name the code, is
# "could not determine". clean-node.sh reads a terminate dry run the same way.
#   lookup <error code> <service> <cli operation> [args...]
#     prints stdout and returns 0 when the call succeeds; 1 only for that exact error;
#     2 when it could not be determined, having printed the AWS error
lookup() {
  local code="$1" op out err rc=0
  shift
  op="$(awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2) }' <<<"$2")"
  out="$(mktemp "${TMPDIR:-/tmp}/analyst-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/analyst-err.XXXXXX")" || { rm -f "$out"; return 2; }
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$out"; rm -f "$out" "$err"; return 0; fi
  if [[ "$rc" == 254 && ! -s "$out" && "$(grep -c . "$err")" == 1 ]] &&
     grep -Eq "^An error occurred \\($code\\) when calling the $op operation(: .*)?\$" "$err"; then
    rm -f "$out" "$err"
    return 1
  fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with exactly $code from $op, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

# The identity a script must be acting through, checked against what .env (or, for the
# clean up, the run record) says it must be, never against itself: EXPECTED_ACCOUNT_ID and
# EXPECTED_ROLE_ARN (arn:<partition>:iam::<account>:role/<name>, with no path). STS must
# answer with exactly that account and an assumed-role session of exactly that role; only
# the session name may differ. The cluster's ARN must be the one AWS_REGION, the account and
# CLUSTER_NAME name, and the kube context must point at its endpoint. STS is read first, so
# no other read is made as anyone else. Prints the identity as one line of JSON, or fails.
identity_now() {
  local who cluster server part account role session prefix
  [[ "${EXPECTED_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ &&
     "${EXPECTED_ROLE_ARN:-}" =~ ^arn:(aws|aws-cn|aws-us-gov):iam::([0-9]{12}):role/([A-Za-z0-9+=,.@_-]{1,64})$ ]] ||
    return 1
  part="${BASH_REMATCH[1]}" account="${BASH_REMATCH[2]}" role="${BASH_REMATCH[3]}"
  [[ "$account" == "$EXPECTED_ACCOUNT_ID" ]] || return 1
  who="$(aws sts get-caller-identity --output json 2>/dev/null)" || return 1
  account="$(jq -r '.Account // ""' <<<"$who")" session="$(jq -r '.Arn // ""' <<<"$who")"
  prefix="arn:$part:sts::$EXPECTED_ACCOUNT_ID:assumed-role/$role/"
  [[ "$account" == "$EXPECTED_ACCOUNT_ID" && "$session" == "$prefix"?* ]] || return 1
  session="${session#"$prefix"}"
  [[ "$session" =~ ^[A-Za-z0-9+=,.@_-]+$ ]] || return 1
  cluster="$(aws eks describe-cluster --name "$CLUSTER_NAME" --output json 2>/dev/null)" || return 1
  server="$(kubectl config view --minify --context "$KUBE_CONTEXT" \
    -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)" || return 1
  server="${server%/}"
  jq -cn --arg a "$account" --arg r "$EXPECTED_ROLE_ARN" \
    --arg want "arn:$part:eks:$AWS_REGION:$account:cluster/$CLUSTER_NAME" \
    --arg c "$(jq -r '.cluster.arn' <<<"$cluster")" --arg e "$(jq -r '.cluster.endpoint' <<<"$cluster")" \
    --arg s "${server%:443}" --arg g "$AWS_REGION" --arg k "$KUBE_CONTEXT" \
    'if $c == $want and ($e | startswith("https://")) and $e == $s
     then {account: $a, role: $r, cluster_arn: $c, endpoint: $e, region: $g, context: $k}
     else empty end'
}

# Seconds since the epoch for a UTC time such as 2026-11-17T08:00:00Z (GNU or BSD date).
epoch_of() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# Whether the credentials this script runs with are still valid at <epoch>: the clean up the
# deadline starts runs with them. Long-term keys have no expiry. Only the expiry is read: the
# AWS CLI's export goes straight to jq, which prints nothing else, and nothing is stored.
credentials_last_until() { # <epoch>
  local expiry until
  expiry="$(aws configure export-credentials --format process 2>/dev/null |
    jq -r '.Expiration // "none"')" || return 1
  [[ "$expiry" == none ]] && return 0
  until="$(epoch_of "$(sed -E 's/(\.[0-9]+)?(\+00:00|Z)$/Z/' <<<"$expiry")")" || return 1
  [[ "$until" =~ ^[0-9]+$ ]] && (( until >= $1 ))
}

# The NodeClaims EKS Auto Mode launched for this run's pods, from the namespace's own events,
# so one created and replaced between two lists is still seen. Every Nominated event must be
# exactly "Pod should schedule on: <kind>/<name>[, <kind>/<name>]" with kind nodeclaim or
# node; one in any other shape fails the read rather than being skipped. Prints the
# NodeClaim names, one per line.
nominated_claims() {
  kc get events -n "$NAMESPACE" -o json | jq -r '
    "[a-z0-9]([a-z0-9.-]*[a-z0-9])?" as $n
    | [.items[] | select(.involvedObject.kind == "Pod" and .reason == "Nominated") | .message] as $all
    | [$all[] | select(test("^Pod should schedule on: (nodeclaim|node)/\($n)(, (nodeclaim|node)/\($n))*$"))] as $ok
    | if ($ok | length) != ($all | length) then error("a Nominated event this check cannot read")
      else [$ok[] | scan("nodeclaim/(\($n))") | .[0]] | unique | .[] end'
}

# Cordons a node, in one patch that applies only while it still has the given uid and provider
# id, so a node replaced under the same name is never touched. A cordon stops the scheduler
# placing anything new on it; pods bound by nodeName, as this run's are, still start there.
fence_node() { # <node> <uid> <provider id>
  kc patch node "$1" --type=json -p "$(jq -cn --arg u "$2" --arg p "$3" \
    '[{op: "test", path: "/metadata/uid", value: $u}, {op: "test", path: "/spec/providerID", value: $p},
      {op: "add", path: "/spec/unschedulable", value: true}]')" >/dev/null
}

# The pods on a node that are neither a DaemonSet's, a static pod nor in <namespace> (this
# run's own, when given), and still running or about to; prints them, fails if unreadable.
foreign_pods() { # <node> [<namespace>]
  kc get pods -A --field-selector "spec.nodeName=$1" -o json | jq -er --arg ns "${2:-}" '
    [.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
     | select(.metadata.namespace != $ns)
     | select(((.metadata.ownerReferences // []) | map(.kind) | index("DaemonSet")) == null)
     | select((.metadata.annotations // {})["kubernetes.io/config.mirror"] == null)
     | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")'
}
