# common.sh: sourced by every script in this sample, on the workstation and on the build
# host alike. Loads config.env, sets defaults, and provides logging, assertion and
# ownership-tag helpers. Sourced, never executed, and never sets `set -e`: callers choose
# their own error discipline, and some stages (bake-prep, smoke) must run to completion so
# they can report why they failed instead of stopping at the first non-zero command.

SAMPLE_DIR="${SAMPLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# The repository root is four levels up from this sample folder
# (examples/setup/ubuntu-ami). Local runtime artifacts, logs and output belong under the
# repository's gitignored tmp/, never inside the sample folder (see AGENTS.md).
REPO_ROOT="${REPO_ROOT:-$(cd "$SAMPLE_DIR/../../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$SAMPLE_DIR/logs}"
OUT_DIR="${OUT_DIR:-$SAMPLE_DIR/out}"
mkdir -p "$LOG_DIR" "$OUT_DIR"

# config.env is local and gitignored; config.env.example documents every variable with a
# placeholder. Both the workstation driver and a build-host copy of this directory look for
# it in the sample root.
for __common_cfg in "$SAMPLE_DIR/config.env" "$HOME/ubuntu-ami/config.env"; do
  [ -f "$__common_cfg" ] && { . "$__common_cfg"; break; }
done
unset __common_cfg

: "${AWS_REGION:=us-west-2}"
: "${CLUSTER_NAME:=nitro-sandboxes-demo}"
: "${RESOURCE_PREFIX:=ubuntu-ami-sample}"
: "${TAGS_OWNER_KEY:=ManagedBy}"
: "${TAGS_OWNER_VALUE:=$RESOURCE_PREFIX}"
: "${NAMESPACE:=ubuntu-ami-sample}"
: "${KERNEL_VERSION:=6.18.39}"
: "${EROFS_UTILS_VERSION:=1.8.10}"
: "${RUNTIME_ARTIFACTS_DIR:=$REPO_ROOT/tmp/issue10/runtime}"
mkdir -p "$RUNTIME_ARTIFACTS_DIR"
: "${LOCK_FILE:=$SAMPLE_DIR/packages/sources.lock}"
: "${NITRO_SANDBOX_DIR_INSTALL:=/usr/share/nitro-sandbox}"
: "${SHIM_DEBUG:=true}"

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Assert a condition and say what it means when it does not hold, so a failed build names
# the prerequisite it is missing rather than only a line number.
must() { # must <description> <command...>
  local what=$1; shift
  if "$@"; then printf 'ok: %s\n' "$what"; else printf 'FAILED: %s\n  (%s)\n' "$what" "$*" >&2; return 1; fi
}

# The ownership tag every AWS resource this sample creates must carry, in the shape the AWS
# CLI --tags argument and TagSpecifications both accept.
ownership_tag_cli() { printf 'Key=%s,Value=%s' "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE"; }

# lock_field <id> <field> : print the named field's value for the block whose id= line
# matches <id>, from LOCK_FILE. Multi-line fields (verify=) return only the first line;
# callers that need the fetch/verify note read the file directly. Returns 1 and prints
# nothing when the id or field is not found, so callers can fail closed rather than build
# with an empty pin.
lock_field() { # lock_field <id> <field>
  local id="$1" field="$2" in_block=0 val=""
  while IFS='=' read -r k v; do
    case "$k" in
      id) if [[ "$v" == "$id" ]]; then in_block=1; else in_block=0; fi ;;
      "") in_block=0 ;;
      "$field") [[ "$in_block" == 1 ]] && { val="$v"; } ;;
    esac
  done < "$LOCK_FILE"
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val"
}

# verify_sha256 <file> <expected-sha256> : fail closed on any mismatch. No override flag:
# a changed artifact aborts rather than silently entering the build.
verify_sha256() {
  local file="$1" expected="$2" actual
  [[ -s "$file" ]] || die "missing or empty file: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 mismatch for $file
  expected: $expected
  actual:   $actual
This artifact does not match packages/sources.lock. Do not use it. Either the download is
corrupt (re-fetch) or the upstream artifact changed (re-pin deliberately in
packages/sources.lock and packages/SOURCES.txt together). There is no override flag."
  fi
  log "verified sha256 $file"
}
