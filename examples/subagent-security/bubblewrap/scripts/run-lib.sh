#!/usr/bin/env bash
# run-lib.sh -- what setup.sh, run.sh, clean.sh and deadline.sh share: the run record, the
# lock that lets only one of them act at a time, the exact AWS error check, and the identity
# every one of them must still be acting as. Source it; do not run it.
#
# The caller sets REPO_ROOT and SAMPLE first. TMP_DIR, STATE_FILE and LOCK_DIR come from here.

TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
# The run record: one JSON object of strings, written whole to a new file that then replaces
# the old one, so a reader sees the record before a write or after it and never half of one.
# It is parsed, never sourced, so nothing in it can run as code.
STATE_FILE="$TMP_DIR/state.json"
# Outside TMP_DIR, so the clean up that removes the run directory does not remove the lock
# another script is waiting on.
LOCK_DIR="$REPO_ROOT/tmp/$SAMPLE.lock"

state_put() { # <KEY> <value>
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "'$1' is not a run-record key"
  local next
  next="$(mktemp "$STATE_FILE.XXXXXX")" || die "could not write $1 to the run record"
  if ! { if [[ -s "$STATE_FILE" ]]; then jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE_FILE"
         else jq -n --arg k "$1" --arg v "$2" '{($k): $v}'; fi; } > "$next" ||
     ! mv -f "$next" "$STATE_FILE"; then
    rm -f "$next"
    die "could not write $1 to the run record $STATE_FILE"
  fi
}

# Sets one shell variable per key of the run record. A key that could change how the shell
# or the AWS CLI behaves (PATH, AWS_PROFILE and the like) is refused rather than set.
state_load() {
  local key value
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  jq -e 'type == "object" and all(.[]; type == "string" and (contains("\u0000") | not))' \
    "$STATE_FILE" >/dev/null 2>&1 || return 1
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && ! "$key" =~ ^(PATH|HOME|IFS|ENV|SHELL|SHELLOPTS|PWD|OLDPWD|CDPATH|GLOBIGNORE|PS4|PROMPT_COMMAND|TMPDIR|KUBECONFIG|BASH.*|LD_.*|DOCKER_.*|AWS_.*)$ ||
       "$key" == AWS_REGION ]] || return 1
    printf -v "$key" '%s' "$value"
  done < <(jq -j 'to_entries[] | "\(.key)\u0000\(.value)\u0000"' "$STATE_FILE")
}

# One setup, run or clean up at a time. A script started by the one holding the lock (the
# clean up a failed setup or run starts) inherits its token and goes ahead; anyone else waits
# up to <seconds>, then refuses. A lock whose holder has exited is taken over.
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
# "could not determine".
#   lookup <error code> <service> <cli operation> [args...]
#     prints stdout and returns 0 when the resource is there; 1 only for that exact error;
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

# The account, the role, the cluster ARN, its endpoint, the Region and the kube context a
# script is acting through right now, as one line of JSON, or nothing if any of them could
# not be read. setup.sh records it; clean.sh compares it before its first delete and again
# before it terminates an instance, so a changed profile, a re-pointed context or a
# different cluster stops the clean up before it touches anything.
identity_now() {
  local who cluster server role
  who="$(aws sts get-caller-identity --output json 2>/dev/null)" || return 1
  cluster="$(aws eks describe-cluster --name "$CLUSTER_NAME" --output json 2>/dev/null)" || return 1
  server="$(kubectl config view --minify --context "$KUBE_CONTEXT" \
    -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)" || return 1
  # An assumed role's ARN names the session too, which a fresh sign-in changes; the role is
  # what grants the permissions, so the role is what is compared.
  role="$(jq -r '.Arn' <<<"$who" | sed -E 's#^arn:([^:]+):sts::([0-9]+):assumed-role/([^/]+)/.*$#arn:\1:iam::\2:role/\3#')"
  server="${server%/}"
  jq -cn --arg a "$(jq -r '.Account' <<<"$who")" --arg r "$role" \
    --arg c "$(jq -r '.cluster.arn' <<<"$cluster")" --arg e "$(jq -r '.cluster.endpoint' <<<"$cluster")" \
    --arg s "${server%:443}" --arg g "$AWS_REGION" --arg k "$KUBE_CONTEXT" \
    'if [$a, $r, $c, $e, $s] | all(. != "" and . != "null") and $e == $s
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

# The NodeClaims EKS Auto Mode launched for this run's pods, from the namespace's own events
# ("Nominated ... nodeclaim/<name>"), so one created and replaced between two lists is still
# seen. Prints the names, one per line; fails if the events could not be read.
nominated_claims() {
  kc get events -n "$NAMESPACE" -o json |
    jq -r '[.items[] | select(.involvedObject.kind == "Pod" and .reason == "Nominated")
      | .message | capture("nodeclaim/(?<n>[a-z0-9]([a-z0-9.-]*[a-z0-9])?)").n] | unique | .[]'
}
