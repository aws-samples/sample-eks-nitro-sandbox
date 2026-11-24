# harness.sh: sourced by every scripts/test-*.sh of this sample, never run.
#
# It gives each suite:
#   * a work folder under the repository's gitignored tmp/ (removed on exit unless CB_TESTS_KEEP=1);
#   * an isolated PATH: the stub commands first ($WORK/bin), then links to only the system tools
#     the scripts need ($WORK/sysbin). The host's real aws, kubectl, eksctl, helm and packer are
#     not on it, so a call that a stub does not answer fails instead of reaching AWS;
#   * no credentials: every AWS credential and profile variable is unset, the CLI config and
#     credentials files are /dev/null, the instance metadata lookup is off, and HOME is a fresh
#     folder, so a call that escapes a stub cannot authenticate;
#   * the test hooks of the scripts (CB_RUN_DIR, CB_LOCAL_CONFIG,
#     CB_SLEEP_SECONDS) and the stub variables (FAKE_STATE, FAKE_LOG);
#   * the tally: check, check_cmd, not_run, and finish (the RESULT line and the exit code).
#
# A suite sources it as its first command:   source "$(dirname "$0")/testlib/harness.sh"

set -uo pipefail
TESTLIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The sample tree under test: the real folder, or a mutant copy under tmp/ (CB_TESTS_SAMPLE_DIR,
# set by run-all.sh --mutants). The stubs and fixtures always come from this testlib/.
SAMPLE_DIR_REAL="$(cd "${CB_TESTS_SAMPLE_DIR:-$TESTLIB/../..}" && pwd)"
REPO_ROOT_REAL="$(git -C "$TESTLIB" rev-parse --show-toplevel 2>/dev/null || (cd "$TESTLIB/../../../../.." && pwd))"
SUITE="$(basename "$0" .sh)"

[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "ERROR: $SUITE needs bash 4 or later" >&2; exit 2; }
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/cb-tests.$SUITE.XXXXXX")"
if [[ "${CB_TESTS_KEEP:-}" == 1 ]]; then
  echo "work folder kept: $WORK"
else
  trap 'rm -rf "$WORK"' EXIT
fi

# The Python that runs the stubs, resolved before PATH is narrowed. It needs jmespath and PyYAML
# (requirements-test.txt). A missing package stops the suite as "could not check" (exit 2).
REAL_PYTHON="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" \
  || { echo "ERROR: $SUITE needs python3" >&2; exit 2; }
PY_USERBASE="$("$REAL_PYTHON" -c 'import site; print(site.getuserbase())')"
export PYTHONUSERBASE="$PY_USERBASE"
"$REAL_PYTHON" -c 'import jmespath, yaml, cryptography' 2>/dev/null || {
  echo "ERROR: $SUITE needs the Python packages in $TESTLIB/requirements-test.txt:" >&2
  echo "  python3 -m venv tmp/cb-tests-venv && tmp/cb-tests-venv/bin/pip install -r $TESTLIB/requirements-test.txt" >&2
  echo "  then put tmp/cb-tests-venv/bin first on PATH" >&2
  exit 2
}
# A real containerd 2.x for the drop-in test only; no sample script reads it.
: "${CB_CONTAINERD:=$(command -v containerd 2>/dev/null || true)}"
export CB_CONTAINERD

mkdir -p "$WORK/bin" "$WORK/sysbin" "$WORK/home" "$WORK/run"
for __t in bash sh env cat cp mv rm mkdir rmdir ln ls chmod touch date sleep head tail tr cut sort uniq \
  wc grep sed awk find xargs mktemp realpath readlink dirname basename printf echo test tee timeout kill \
  sha256sum sha512sum base64 openssl gpg gpg-agent gpgconf gpgv unzip zip curl git jq diff cmp stat id \
  uname tar gzip xz lz4 seq true false comm paste od install flock nproc hostname whoami expr fold \
  numfmt nl rev split ps pgrep pkill truncate dd sync column getent setsid; do
  __p="$(command -v "$__t" 2>/dev/null || true)"
  [[ -n "$__p" && "$__p" == /* ]] && ln -sf "$__p" "$WORK/sysbin/$__t"
done
ln -sf "$REAL_PYTHON" "$WORK/sysbin/python3"
unset __t __p

# stub_install <name> <script under testlib/>: $WORK/bin/<name> runs that stub.
stub_install() {
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$REAL_PYTHON" "$TESTLIB/$2" > "$WORK/bin/$1"
  chmod 0755 "$WORK/bin/$1"
}
# stub_remove <name>: the command is then missing from PATH (a "tool missing" case).
stub_remove() { rm -f "$WORK/bin/$1" "$WORK/sysbin/$1"; }
stub_install aws fake_aws.py
stub_install eksctl fake_eksctl.py
stub_install kubectl fake_kubectl.py
stub_install helm fake_helm.py

# No credentials reach a sample script. The names below are the variables the AWS SDKs and CLI
# read; the files are /dev/null; HOME is the suite's own folder.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE \
  AWS_DEFAULT_PROFILE AWS_CREDENTIAL_EXPIRATION AWS_ROLE_ARN AWS_ROLE_SESSION_NAME \
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE AWS_CREDENTIAL_PROCESS \
  AWS_ACCOUNT_ID AWS_DEFAULT_REGION KUBECONFIG
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER="" AWS_REGION=us-west-2
export HOME="$WORK/home"
export PATH="$WORK/bin:$WORK/sysbin"
export FAKE_STATE="$WORK/state.json" FAKE_LOG="$WORK/calls.jsonl" FAKE_TESTLIB="$TESTLIB"
export CB_RUN_DIR="$WORK/run" CB_LOCAL_CONFIG="$WORK/config.local.env" CB_SLEEP_SECONDS=0
unset FAKE_FAIL CLEAN_CONFIRM RUN_ID

# ---- world state ---------------------------------------------------------------------------
# world_reset [<fixture json under testlib/>]: a fresh state (default world-empty.json), an empty
# call log and the base local config.
world_reset() {
  cp "$TESTLIB/${1:-world-empty.json}" "$FAKE_STATE"
  rm -f "$FAKE_LOG" "$FAKE_STATE.failcounts"
  : > "$FAKE_LOG"
  cp "$TESTLIB/fixture-config.env" "$CB_LOCAL_CONFIG"
  unset FAKE_FAIL
}
# world_py '<python>': run Python on the state as `s` (a dict), then save it.
world_py() {
  "$REAL_PYTHON" - "$FAKE_STATE" "$1" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
s = json.load(open(path))
exec(code, {"s": s, "json": json})
json.dump(s, open(path, "w"), indent=1, sort_keys=True)
PY
}
# world_get '<python expression on s>': print the value.
world_get() {
  "$REAL_PYTHON" -c 'import json,sys; s=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print(v if isinstance(v,str) else json.dumps(v))' \
    "$FAKE_STATE" "$1"
}
# write_state <file> KEY=VALUE ...: a state file with one line per argument (mode 600).
write_state() {
  local f="$1"; shift
  printf '%s\n' "$@" > "$f" && chmod 600 "$f"
}
# config_set KEY=VALUE ...: change or add lines in the local config file.
config_set() {
  local kv k
  for kv in "$@"; do
    k="${kv%%=*}"
    sed -i "/^${k}=/d" "$CB_LOCAL_CONFIG"
    printf '%s\n' "$kv" >> "$CB_LOCAL_CONFIG"
  done
}

# ---- the call log --------------------------------------------------------------------------
# calls [<tool>] [<call>] [<argv substring>]: one line per matching call, "<seq> <tool> <call> <argv>".
calls() {
  "$REAL_PYTHON" - "$FAKE_LOG" "${1:-}" "${2:-}" "${3:-}" <<'PY'
import json, sys
log, tool, call, sub = sys.argv[1:5]
for line in open(log):
    e = json.loads(line)
    argv = " ".join(e.get("argv", []))
    if (not tool or e["tool"] == tool) and (not call or e["call"] == call) and sub in argv:
        print(e["seq"], e["tool"], e["call"], argv)
PY
}
# first_seq / last_seq <tool> <call> [<substring>]: the sequence number, or empty.
first_seq() { calls "$@" | head -n1 | cut -d' ' -f1; }
last_seq() { calls "$@" | tail -n1 | cut -d' ' -f1; }
count_calls() { calls "$@" | wc -l | tr -d ' '; }

# ---- running a real script -----------------------------------------------------------------
# cloud_guard <PATH value>: each cloud tool on that PATH is this suite's stub ($WORK/bin) or absent.
# Otherwise the suite stops (exit 2) before the case runs, and finish fails too (the marker file),
# so no case can reach a real aws, eksctl, kubectl, helm, packer, ada or isengardcli.
CLOUD_TOOLS=(aws eksctl kubectl helm packer ada isengardcli)
cloud_guard() {
  local t p
  for t in "${CLOUD_TOOLS[@]}"; do
    p="$(PATH="$1" command -v "$t" 2>/dev/null || true)"
    if [[ -n "$p" && "$p" != "$WORK/bin/$t" ]]; then
      echo "ERROR: $SUITE: $t resolves to $p, not the stub in $WORK/bin; stopping before the case runs" | tee -a "$WORK/CLOUD_GUARD_TRIPPED" >&2
      exit 2
    fi
  done
}
cloud_guard "$PATH"
# run_real <log> <command...>: run it with a 300 s limit, stdin closed; sets RC. The cloud guard
# runs first, on this PATH and on any PATH=... that an `env` command line sets.
run_real() {
  local log="$1" a; shift
  cloud_guard "$PATH"
  if [[ "${1:-}" == env ]]; then
    for a in "$@"; do [[ "$a" != PATH=* ]] || cloud_guard "${a#PATH=}"; done
  fi
  RC=0
  timeout 300 "$@" > "$log" 2>&1 < /dev/null || RC=$?
}

# ---- coverage for the closed-world gate --------------------------------------
# Each check appends {"suite", "case", "kind", "tag", "entry", "status"} to CB_TESTS_COVERAGE.
# A check that expects a non-zero exit and whose regex names ^ERROR: E_<TAG>: is a reject case for
# that tag; `cover accept E_<TAG> ...` right after a check records it as an accept case for those tags.
# `entry <file>[:<function or subcommand>]` names what the following checks run.
: "${CB_TESTS_COVERAGE:=$WORK/coverage.jsonl}"
export CB_TESTS_COVERAGE
ENTRY=""; LAST_DESC=""; LAST_STATUS=""
entry() { ENTRY="$1"; }
_cov() { # _cov <kind> <tag> <status> <case>
  "$REAL_PYTHON" -c 'import json, sys; print(json.dumps(dict(zip(["suite", "kind", "tag", "status", "case", "entry"], sys.argv[1:]))))' \
    "$SUITE" "$1" "$2" "$3" "$4" "$ENTRY" >> "$CB_TESTS_COVERAGE"
}
cover() { # cover accept|reject E_<TAG> ...: the last check is also a case of that kind for these tags
  local kind="$1" t; shift
  for t in "$@"; do _cov "$kind" "$t" "$LAST_STATUS" "$LAST_DESC"; done
}
# file_tags <file under the sample> [<tag to leave out> ...]: the tags the generated inventory
# finds in that file. Use it after an accept case whose run passes every guard of the file.
file_tags() {
  "$REAL_PYTHON" - "$SAMPLE_DIR_REAL" "$@" <<'PY'
import os, sys
sys.path.insert(0, os.environ["FAKE_TESTLIB"])
import inventory
root, rel, skip = sys.argv[1], sys.argv[2], set(sys.argv[3:])
tags = inventory.inventory(root)["tags"]
print(" ".join(t for t, sites in tags.items() if t not in skip and any(s["file"] == rel for s in sites)))
PY
}

# ---- the tally -----------------------------------------------------------------------------
PASS=0; FAIL=0; NOTRUN=0
# check <description> <expected rc> <actual rc> <log> [<regex the log must match>]
check() {
  local ok=0 tag=""
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then
    printf '  PASS  %s (rc=%s)\n' "$1" "$3"; PASS=$((PASS + 1)); LAST_STATUS=pass
  else
    printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"
    [[ -f "$4" ]] && sed 's/^/        | /' "$4" | tail -n 8
    FAIL=$((FAIL + 1)); LAST_STATUS=fail
  fi
  LAST_DESC="$1"
  if [[ "$2" != 0 && "${5:-}" =~ ERROR:\ (E_[A-Z0-9_]+): ]]; then
    tag="${BASH_REMATCH[1]}"
    _cov reject "$tag" "$LAST_STATUS" "$1"
  fi
}
# check_cmd <description> <command...>: PASS when the command exits 0.
check_cmd() {
  local d="$1"; shift
  if "$@" > "$WORK/check_cmd.log" 2>&1; then
    printf '  PASS  %s\n' "$d"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$d"; sed 's/^/        | /' "$WORK/check_cmd.log" | tail -n 8; FAIL=$((FAIL + 1))
  fi
}
# not_run <description> <why>: the case could not run; it counts against the suite.
not_run() { printf '  NOT RUN  %s: %s\n' "$1" "$2"; NOTRUN=$((NOTRUN + 1)); }
# need_file <path> <description>: 0 when the file exists; otherwise one NOT RUN line.
need_file() {
  [[ -e "$1" ]] && return 0
  not_run "$2" "${1#"$SAMPLE_DIR_REAL"/} does not exist yet"
  return 1
}
# finish: the RESULT line; exit 0 only with no failure and nothing not run.
finish() {
  if [[ -s "$WORK/CLOUD_GUARD_TRIPPED" ]]; then
    cat "$WORK/CLOUD_GUARD_TRIPPED" >&2
    printf '\nRESULT: %s: stopped by the cloud guard (a real cloud tool on a case PATH)\n' "$SUITE"
    exit 2
  fi
  printf '\nRESULT: %s: %d passed, %d failed, %d not run\n' "$SUITE" "$PASS" "$FAIL" "$NOTRUN"
  ((FAIL == 0 && NOTRUN == 0))
  exit $?
}
