#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly NAMESPACE="openclaw-enterprise-agw"
readonly OWNER_LABEL="app.kubernetes.io/managed-by"
readonly OWNER="openclaw-enterprise-blueprint"
readonly PART_LABEL="app.kubernetes.io/part-of"
readonly KEYSET_ANNOTATION="openclaw-enterprise.aws.dev/keyset-id"
readonly SETUP_ANNOTATION="openclaw-enterprise.aws.dev/setup-token"
readonly DER_PREFIX="302e020100300506032b657004220420"
readonly STATE_FILES=(
  tenant-a-agentgateway.key tenant-b-agentgateway.key
  tenant-a-sha256 tenant-b-sha256 agentgateway-session.key
)

usage() {
  cat >&2 <<'EOF'
Usage: setup-agentgateway.sh --kubeconfig FILE --kube-context CONTEXT \
  --state-dir DIRECTORY --receipt FILE [--rotate-keys] \
  [--rollout-timeout DURATION]
EOF
}

die() { echo "setup-agentgateway: $*" >&2; exit 1; }
need() {
  [[ -n "${2:-}" && "${2:-}" != --* ]] || die "$1 requires a value."
}

KUBECONFIG_INPUT="" KUBE_CONTEXT="" STATE_DIR_INPUT="" RECEIPT_INPUT=""
ROTATE=false
ROLLOUT_TIMEOUT="5m"
while (( $# )); do
  case "$1" in
    --kubeconfig) need "$1" "${2:-}"; KUBECONFIG_INPUT="$2"; shift 2 ;;
    --kube-context) need "$1" "${2:-}"; KUBE_CONTEXT="$2"; shift 2 ;;
    --state-dir) need "$1" "${2:-}"; STATE_DIR_INPUT="$2"; shift 2 ;;
    --receipt) need "$1" "${2:-}"; RECEIPT_INPUT="$2"; shift 2 ;;
    --rotate-keys) ROTATE=true; shift ;;
    --rollout-timeout) need "$1" "${2:-}"; ROLLOUT_TIMEOUT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
for value in KUBECONFIG_INPUT KUBE_CONTEXT STATE_DIR_INPUT RECEIPT_INPUT; do
  [[ -n "${!value}" ]] || { usage; die "--${value%_INPUT} is required."; }
done
[[ "$KUBECONFIG_INPUT" = /* && "$STATE_DIR_INPUT" = /* &&
  "$RECEIPT_INPUT" = /* ]] || die "file and directory paths must be absolute."
[[ "$KUBECONFIG_INPUT$KUBE_CONTEXT$STATE_DIR_INPUT$RECEIPT_INPUT" != *$'\n'* &&
  "$STATE_DIR_INPUT$RECEIPT_INPUT" != *"|"* ]] || die "arguments contain unsafe characters."
[[ "$ROLLOUT_TIMEOUT" =~ ^[1-9][0-9]*(s|m|h)$ ]] ||
  die "--rollout-timeout must be a positive number followed by s, m, or h."
for tool in awk basename chmod cmp cp dirname envsubst grep id jq kubectl mkdir \
  mktemp mv od openssl python3 rm stat tr wc yq; do
  command -v "$tool" >/dev/null || die "required command is unavailable: $tool"
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CHECKOUT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
MANIFEST="$SCRIPT_DIR/../deploy/agentgateway.yaml"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "AgentGateway manifest is unsafe."

private_acl_check() {
  python3 -I - "$1" <<'PY'
import re
import subprocess
import sys

if sys.platform != "darwin":
    raise SystemExit(0)
result = subprocess.run(
    ["/bin/ls", "-lde", "--", sys.argv[1]],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
if result.returncode != 0:
    raise SystemExit("could not inspect access-control entries")
if any(re.match(rb"^[ \t]+\d+:", line) for line in result.stdout.splitlines()[1:]):
    raise SystemExit("private path has access-control entries")
PY
}
file_mode() {
  local value
  private_acl_check "$1" || die "private path must not have access-control entries: $1"
  if value="$(stat -c '%a' "$1" 2>/dev/null)" &&
    [[ "$value" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$value"
  elif value="$(stat -f '%Lp' "$1" 2>/dev/null)" &&
    [[ "$value" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$value"
  else
    die "could not inspect permissions for $1."
  fi
}
private_file_write() {
  if [[ "$3" == replace ]]; then
    private_acl_check "$1" || return 1
  fi
  python3 -I - "$1" "$2" "$3" <<'PY'
import os, stat, sys
path, value, operation = sys.argv[1:]
flags = os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
if operation == "create":
    flags |= os.O_CREAT | os.O_EXCL
fd = os.open(path, flags, 0o600)
try:
    current = os.fstat(fd)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) != 0o600
    ):
        raise SystemExit("private file is unsafe")
    os.ftruncate(fd, 0)
    os.write(fd, value.encode("ascii"))
    os.fsync(fd)
finally:
    os.close(fd)
PY
  local write_status=$?
  (( write_status == 0 )) || return "$write_status"
  private_acl_check "$1"
}
private_file_check() {
  private_acl_check "$1" || return 1
  python3 -I - "$1" <<'PY'
import os, stat, sys
fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    current = os.fstat(fd)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) != 0o600
    ):
        raise SystemExit("private file is unsafe")
finally:
    os.close(fd)
PY
}
if [[ ! -e "$STATE_DIR_INPUT" ]]; then mkdir -m 700 -- "$STATE_DIR_INPUT"; fi
[[ -d "$STATE_DIR_INPUT" && ! -L "$STATE_DIR_INPUT" && -O "$STATE_DIR_INPUT" ]] ||
  die "state directory must be an owned, non-symlink directory."
STATE_DIR="$(cd -- "$STATE_DIR_INPUT" && pwd -P)"
[[ "$(file_mode "$STATE_DIR")" == 700 ]] ||
  die "state directory must have mode 0700."
case "$STATE_DIR" in "$CHECKOUT"|"$CHECKOUT"/*) die "state directory must be outside the checkout." ;; esac
RECEIPT="$(cd -- "$(dirname -- "$RECEIPT_INPUT")" && pwd -P)/$(basename -- "$RECEIPT_INPUT")"
[[ "$RECEIPT" == "$RECEIPT_INPUT" && "$RECEIPT" == "$STATE_DIR/"* ]] ||
  die "receipt must be canonical and below the state directory."

LOCK="$STATE_DIR/.setup-agentgateway.lock"
LOCK_DIR="$LOCK.active"
LOCK_ACQUIRED=false
release_lock() {
  [[ "$LOCK_ACQUIRED" == true ]] || return 0
  rm -f -- "$LOCK_DIR/pid"
  rmdir -- "$LOCK_DIR" ||
    echo "setup-agentgateway: could not remove setup lock directory." >&2
  private_file_write "$LOCK" "" replace ||
    echo "setup-agentgateway: could not clear setup lock marker." >&2
  LOCK_ACQUIRED=false
}
[[ ! -L "$LOCK" ]] || die "setup lock must not be a symlink."
if [[ ! -e "$LOCK" ]]; then
  private_file_write "$LOCK" "" create || die "could not create setup lock marker."
else
  private_file_check "$LOCK" || die "setup lock marker is unsafe."
fi
if ! mkdir -m 700 -- "$LOCK_DIR" 2>/dev/null; then
  [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" && -O "$LOCK_DIR" &&
    "$(file_mode "$LOCK_DIR")" == 700 ]] || die "setup lock is unsafe."
  [[ -f "$LOCK_DIR/pid" && ! -L "$LOCK_DIR/pid" ]] ||
    die "setup lock is incomplete; verify no setup is running, then remove the lock directory manually."
  private_file_check "$LOCK_DIR/pid" ||
    die "setup lock PID file is unsafe; verify no setup is running, then remove the lock directory manually."
  lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [[ "$lock_pid" =~ ^[0-9]+$ ]] ||
    die "setup lock is malformed; verify no setup is running, then remove the lock directory manually."
  if kill -0 "$lock_pid" 2>/dev/null; then
    die "another setup is running"
  fi
  die "setup lock is stale; reconcile recovery state, then remove the lock directory manually."
fi
LOCK_ACQUIRED=true
trap release_lock EXIT
private_file_write "$LOCK_DIR/pid" "$$"$'\n' create ||
  die "could not record setup lock owner."
private_file_write "$LOCK" "$$"$'\n' replace ||
  die "could not update setup lock marker."

JOURNAL="$STATE_DIR/.setup-agentgateway.journal"
RECOVERY=false PRESERVE=false CLEANING=false RECEIPT_PRESENT=false
MODE="" PHASE="" SETUP_ID="" RECOVERY_ATTEMPT=false RECOVERED_COMMIT=false
if [[ -e "$JOURNAL" ]]; then
  [[ -d "$JOURNAL" && ! -L "$JOURNAL" && -O "$JOURNAL" &&
    "$(file_mode "$JOURNAL")" == 700 ]] || die "mutation journal is unsafe."
  if [[ -s "$JOURNAL/journal-mode" && -s "$JOURNAL/journal-phase" ]]; then
    RECOVERY=true
  else
    rm -rf -- "$JOURNAL"
  fi
fi
[[ -d "$JOURNAL" ]] || mkdir -m 700 -- "$JOURNAL"

KUBECTL=()
durable() {
  python3 -I - "$@" <<'PY'
import os, sys
files, directories = [], set()
for path in sys.argv[1:]:
    if os.path.isdir(path):
        for root, dirs, names in os.walk(path):
            files.extend(os.path.join(root, name) for name in names)
            directories.add(root)
            directories.update(os.path.join(root, name) for name in dirs)
        continue
    files.append(path)
    directories.add(os.path.dirname(path))
for path in files:
    fd = os.open(path, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)
for path in sorted(directories, key=lambda p: p.count(os.sep), reverse=True):
    fd = os.open(path, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)
PY
}
snapshot_kubeconfig() {
  local bootstrap="$JOURNAL/bootstrap" staged="$JOURNAL/.kubeconfig"
  private_acl_check "$KUBECONFIG_INPUT" ||
    die "kubeconfig must not have access-control entries."
  python3 -I - "$KUBECONFIG_INPUT" "$bootstrap" <<'PY'
import os, stat, sys
src, dst = sys.argv[1:]
if os.path.realpath(src) != src: raise SystemExit("kubeconfig must be canonical")
fd = os.open(src, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
s = os.fstat(fd)
if not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid() or stat.S_IMODE(s.st_mode) & 0o077:
    raise SystemExit("kubeconfig must be a private owned file")
with os.fdopen(fd, "rb") as i, open(dst, "xb") as o: o.write(i.read())
os.chmod(dst, 0o600)
PY
  local found
  found="$(kubectl --kubeconfig "$bootstrap" config get-contexts "$KUBE_CONTEXT" \
    --no-headers --output=name)" || die "could not read kube context."
  [[ "$found" == "$KUBE_CONTEXT" ]] || die "kube context does not exist exactly."
  kubectl --kubeconfig "$bootstrap" config view --raw --flatten --minify \
    --context "$KUBE_CONTEXT" >"$staged" || die "could not snapshot kube context."
  [[ -s "$staged" ]] || die "kubeconfig snapshot is empty."
  chmod 600 "$staged"; mv -f -- "$staged" "$JOURNAL/kubeconfig"; rm -f -- "$bootstrap"
}
use_snapshot() {
  [[ -f "$JOURNAL/kubeconfig" && ! -L "$JOURNAL/kubeconfig" &&
    "$(file_mode "$JOURNAL/kubeconfig")" == 600 ]] || die "saved kubeconfig is unsafe."
  KUBECTL=(kubectl --kubeconfig "$JOURNAL/kubeconfig" --context "$KUBE_CONTEXT" --request-timeout=20s)
  "${KUBECTL[@]}" get --raw=/readyz >/dev/null || die "could not reach kube context."
}
if [[ "$RECOVERY" == false ]]; then snapshot_kubeconfig; fi
use_snapshot
ENDPOINT="$("${KUBECTL[@]}" config view --raw --minify --context "$KUBE_CONTEXT" \
  --output=json | jq -er '.clusters | select(length == 1) | .[0].cluster.server')" ||
  die "selected Kubernetes target has no unique endpoint."

write_value() {
  local target="$1" value="$2" staged
  staged="$(mktemp "$JOURNAL/.value.XXXXXX")"
  printf '%s\n' "$value" >"$staged"; chmod 600 "$staged"; mv -f -- "$staged" "$target"
}
begin_journal() {
  MODE="$1"; PHASE=active
  write_value "$JOURNAL/journal-mode" "$MODE"
  write_value "$JOURNAL/journal-phase" "$PHASE"
  durable "$JOURNAL"
}
commit_journal() {
  PHASE=committed; write_value "$JOURNAL/journal-phase" committed
  durable "$JOURNAL/journal-phase"
}

RECEIPT_DATA="$JOURNAL/no-receipt.json"
load_receipt() {
  if [[ ! -e "$RECEIPT" ]]; then
    printf '{}\n' >"$RECEIPT_DATA"
    return
  fi
  [[ -f "$RECEIPT" && ! -L "$RECEIPT" && -O "$RECEIPT" ]] ||
    die "lifecycle receipt is unsafe."
  SETUP_ID="$(jq -er --arg endpoint "$ENDPOINT" --arg ns "$NAMESPACE" '
    select(.version == 1 and .clusterEndpoint == $endpoint and .namespace == $ns
    and (.setupId | test("^[0-9a-f]{32}$"))
    and (.resources | type == "array" and length == 12)
    and all(.resources[]; (.uid | type == "string" and length > 0)
      and (.created | type == "boolean"))) | .setupId
  ' "$RECEIPT")" || die "lifecycle receipt is invalid or for another target."
  RECEIPT_PRESENT=true
  RECEIPT_DATA="$RECEIPT"
}
load_receipt

read_seed() {
  private_acl_check "$1" || return 1
  python3 -I - "$1" <<'PY'
import os, re, stat, sys
fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    current = os.fstat(fd)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) not in (0o400, 0o600)
        or current.st_size != 64
    ):
        raise SystemExit("seed metadata is unsafe")
    value = os.read(fd, 65)
    if len(value) != 64 or not re.fullmatch(b"[0-9a-f]{64}", value):
        raise SystemExit("seed content is invalid")
finally:
    os.close(fd)
sys.stdout.write(value.decode("ascii"))
PY
}
generate_ed25519_seed() {
  local output_file="$1" der seed staged output_dir
  output_dir="$(dirname -- "$output_file")"
  der="$(mktemp "$output_dir/.ed25519.XXXXXX")"
  openssl genpkey -algorithm ED25519 -outform DER -out "$der" >/dev/null 2>&1 ||
    die "could not generate an Ed25519 key."
  seed="$(od -An -v -t x1 "$der" | tr -d ' \n')"; rm -f -- "$der"
  [[ "$seed" == "$DER_PREFIX"* && "${#seed}" == 96 ]] || die "unexpected Ed25519 encoding."
  seed="${seed#"$DER_PREFIX"}"
  staged="$(mktemp "$output_dir/.seed.XXXXXX")"
  printf '%s' "$seed" >"$staged"; chmod 600 "$staged"; mv -f -- "$staged" "$output_file"
}
sha256_seed() { read_seed "$1" | openssl dgst -sha256 -r | awk '{print $1}'; }
prepare_state() {
  local file hash checksum
  for file in tenant-a-agentgateway.key tenant-b-agentgateway.key agentgateway-session.key; do
    [[ ! -L "$STATE_DIR/$file" ]] || die "invalid state file: $file"
    if [[ -e "$STATE_DIR/$file" ]]; then
      read_seed "$STATE_DIR/$file" >/dev/null || die "invalid state file: $file"
    else generate_ed25519_seed "$STATE_DIR/$file"
    fi
  done
  for file in tenant-a tenant-b; do
    hash="$(sha256_seed "$STATE_DIR/${file}-agentgateway.key")"
    checksum="$STATE_DIR/${file}-sha256"
    [[ ! -L "$checksum" ]] || die "invalid state file: ${file}-sha256"
    if [[ -e "$checksum" ]]; then
      private_file_check "$checksum" || die "invalid state file: ${file}-sha256"
      [[ "$(cat "$checksum")" == "$hash" ]] || die "hash state is inconsistent."
    else
      private_file_write "$checksum" "$hash" create ||
        die "could not create hash state: ${file}-sha256"
    fi
  done
}
stage_keys() {
  local destination="$1"
  mkdir -m 700 -- "$destination"
  generate_ed25519_seed "$destination/tenant-a-agentgateway.key"
  generate_ed25519_seed "$destination/tenant-b-agentgateway.key"
  generate_ed25519_seed "$destination/agentgateway-session.key"
  sha256_seed "$destination/tenant-a-agentgateway.key" >"$destination/tenant-a-sha256"
  sha256_seed "$destination/tenant-b-agentgateway.key" >"$destination/tenant-b-sha256"
  chmod 600 "$destination"/*
}

build_expected() {
  local source="$1" destination="$2"
  local rendered="$destination/rendered.yaml" objects="$destination/objects.jsonl" raw="$destination/raw.json"
  local a b session keyset a_seed b_seed session_seed
  mkdir -m 700 -- "$destination"
  a_seed="$(read_seed "$source/tenant-a-agentgateway.key")" ||
    die "tenant A AgentGateway seed is unsafe."
  b_seed="$(read_seed "$source/tenant-b-agentgateway.key")" ||
    die "tenant B AgentGateway seed is unsafe."
  session_seed="$(read_seed "$source/agentgateway-session.key")" ||
    die "AgentGateway session seed is unsafe."
  a="$(printf '%s' "$a_seed" | openssl dgst -sha256 -r | awk '{print $1}')"
  b="$(printf '%s' "$b_seed" | openssl dgst -sha256 -r | awk '{print $1}')"
  session="$(printf '%s' "$session_seed" | openssl dgst -sha256 -r | awk '{print $1}')"
  keyset="$(printf '%s%s%s' "$a" "$b" "$session" | openssl dgst -sha256 -r | awk '{print $1}')"
  private_file_write "$destination/agentgateway-session.key" "$session_seed" create ||
    die "could not stage AgentGateway session seed."
  unset a_seed b_seed session_seed
  # shellcheck disable=SC2016
  AGW_TENANT_A_KEY_SHA256="$a" AGW_TENANT_B_KEY_SHA256="$b" envsubst \
    '${AGW_TENANT_A_KEY_SHA256} ${AGW_TENANT_B_KEY_SHA256}' <"$MANIFEST" >"$rendered"
  if ! python3 -I - "$rendered" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
variables = re.findall(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*", text)
if variables != ["${AWS_REGION}"]:
    raise SystemExit(
        "rendered manifest must retain exactly one ${AWS_REGION} placeholder"
    )
PY
  then
    die "rendered manifest contains an unexpected variable."
  fi
  yq -o=json -I=0 '.' "$rendered" >"$objects"
  python3 -I - "$objects" "$destination" "$NAMESPACE" <<'PY'
import json, pathlib, sys
source, output, namespace = sys.argv[1:]
docs = [json.loads(line) for line in open(source)]
targets = [
 ("Namespace",namespace,"namespace"), ("ServiceAccount","agentgateway","serviceaccount"),
 ("Issuer","agentgateway-selfsigned","issuer-selfsigned"),
 ("Certificate","agentgateway-root","certificate-root"), ("Issuer","agentgateway-ca","issuer-ca"),
 ("Certificate","agentgateway-serving","certificate-serving"),
 ("ConfigMap","agentgateway-config","configmap"), ("Deployment","agentgateway","raw"),
 ("PodDisruptionBudget","agentgateway","pdb"), ("Service","agentgateway","service")]
for kind, name, filename in targets:
    found = [item for item in docs if isinstance(item, dict) and item.get("kind") == kind
             and item.get("metadata", {}).get("name") == name]
    if len(found) != 1: raise SystemExit(f"manifest must contain one {kind}/{name}")
    pathlib.Path(output, filename + ".json").write_text(json.dumps(found[0], separators=(",", ":")))
PY
  jq --arg key "$KEYSET_ANNOTATION" --arg value "$keyset" \
    '.spec.template.metadata.annotations = ((.spec.template.metadata.annotations // {}) + {($key):$value})' \
    "$raw" >"$destination/deployment.json"
  "${KUBECTL[@]}" --namespace "$NAMESPACE" create secret generic agw-client-key \
    --from-file=tenant-a-sha256="$source/tenant-a-sha256" \
    --from-file=tenant-b-sha256="$source/tenant-b-sha256" \
    --dry-run=client --output=json >"$raw"
  jq --arg owner_label "$OWNER_LABEL" --arg owner "$OWNER" --arg part_label "$PART_LABEL" \
    '.metadata.labels = {($owner_label): $owner, ($part_label): $owner}' \
    "$raw" >"${destination}/secret-client.json"
  "${KUBECTL[@]}" --namespace "$NAMESPACE" create secret generic agw-session-key \
    --from-file=key="$destination/agentgateway-session.key" \
    --dry-run=client --output=json >"$raw"
  jq --arg owner_label "$OWNER_LABEL" --arg owner "$OWNER" --arg part_label "$PART_LABEL" \
    '.metadata.labels = {($owner_label): $owner, ($part_label): $owner}' \
    "$raw" >"${destination}/secret-session.json"
  cat >"${destination}/plan" <<EOF
namespace|_|${NAMESPACE}|Namespace|${destination}/namespace.json
serviceaccount|${NAMESPACE}|agentgateway|ServiceAccount|${destination}/serviceaccount.json
issuer.cert-manager.io|${NAMESPACE}|agentgateway-selfsigned|Issuer|${destination}/issuer-selfsigned.json
certificate.cert-manager.io|${NAMESPACE}|agentgateway-root|Certificate|${destination}/certificate-root.json
issuer.cert-manager.io|${NAMESPACE}|agentgateway-ca|Issuer|${destination}/issuer-ca.json
certificate.cert-manager.io|${NAMESPACE}|agentgateway-serving|Certificate|${destination}/certificate-serving.json
secret|${NAMESPACE}|agw-client-key|Secret|${destination}/secret-client.json
secret|${NAMESPACE}|agw-session-key|Secret|${destination}/secret-session.json
configmap|${NAMESPACE}|agentgateway-config|ConfigMap|${destination}/configmap.json
deployment.apps|${NAMESPACE}|agentgateway|Deployment|${destination}/deployment.json
poddisruptionbudget.policy|${NAMESPACE}|agentgateway|PodDisruptionBudget|${destination}/pdb.json
service|${NAMESPACE}|agentgateway|Service|${destination}/service.json
EOF
}

get_object() {
  local resource="$1" namespace="$2" name="$3" output="$4"
  local -a command=("${KUBECTL[@]}" get "$resource" "$name")
  [[ "$namespace" == _ ]] || command+=(--namespace "$namespace")
  "${command[@]}" --ignore-not-found --output=json >"$output"
}
INSPECT_STATE="" OBJECT_UID="" OBJECT_TOKEN=""
inspect() {
  local actual="$1" old="$2" new="${3:-$2}" resource="${4:-}" namespace="${5:-}" name="${6:-}"
  local check="${7:-any}" row
  row="$(jq -r --slurpfile old "$old" --slurpfile new "$new" --slurpfile receipt "$RECEIPT_DATA" \
    --arg ownerKey "$OWNER_LABEL" --arg owner "$OWNER" --arg tokenKey "$SETUP_ANNOTATION" \
    --arg resource "$resource" --arg namespace "$namespace" --arg name "$name" \
    --arg setup "$SETUP_ID" --arg check "$check" '
    def drop($p;$v): if getpath($p)==$v then delpaths([$p]) else . end;
    def norm:
      del(.metadata.creationTimestamp,.metadata.deletionGracePeriodSeconds,.metadata.deletionTimestamp,
        .metadata.finalizers,.metadata.generation,.metadata.managedFields,.metadata.resourceVersion,
        .metadata.selfLink,.metadata.uid,.status)
      | .metadata.annotations |= ((.//{})|del(."deployment.kubernetes.io/revision",
          ."kubectl.kubernetes.io/last-applied-configuration",."openclaw-enterprise.aws.dev/setup-token"))
      | if .metadata.annotations=={} then del(.metadata.annotations) else . end
      | if .kind=="Namespace" then drop(["metadata","labels","kubernetes.io/metadata.name"];.metadata.name)
          | drop(["spec","finalizers"];["kubernetes"]) else . end
      | if .kind=="ServiceAccount" then del(.secrets) else . end
      | if .kind=="Certificate" then drop(["spec","issuerRef","group"];"cert-manager.io")
          | drop(["spec","duration"];"2160h0m0s") | drop(["spec","renewBefore"];"720h0m0s")
          | drop(["spec","isCA"];false) | drop(["spec","privateKey"];{"rotationPolicy":"Always"}) else . end
      | if .kind=="Deployment" then drop(["spec","progressDeadlineSeconds"];600)
          | drop(["spec","revisionHistoryLimit"];10) | drop(["spec","paused"];false)
          | drop(["spec","template","metadata","creationTimestamp"];null)
          | drop(["spec","template","spec","dnsPolicy"];"ClusterFirst")
          | drop(["spec","template","spec","restartPolicy"];"Always")
          | drop(["spec","template","spec","schedulerName"];"default-scheduler")
          | drop(["spec","template","spec","terminationGracePeriodSeconds"];30)
          | if .spec.template.spec.serviceAccount==.spec.template.spec.serviceAccountName
            then del(.spec.template.spec.serviceAccount) else . end
          | .spec.template.spec.volumes |= map(if .configMap.defaultMode==420 then del(.configMap.defaultMode) else . end)
          | .spec.template.spec.containers |= map(drop(["terminationMessagePath"];"/dev/termination-log")
              | drop(["terminationMessagePolicy"];"File")
              | (.startupProbe,.readinessProbe,.livenessProbe) |=
                (drop(["timeoutSeconds"];1)|drop(["successThreshold"];1))) else . end
      | if .kind=="PodDisruptionBudget" then drop(["spec","unhealthyPodEvictionPolicy"];"IfHealthyBudget") else . end
      | if .kind=="Service" then del(.spec.clusterIP,.spec.clusterIPs,.spec.healthCheckNodePort,.spec.ipFamilies)
          | drop(["spec","allocateLoadBalancerNodePorts"];true)
          | drop(["spec","internalTrafficPolicy"];"Cluster") | drop(["spec","ipFamilyPolicy"];"SingleStack")
          | drop(["spec","publishNotReadyAddresses"];false) | drop(["spec","sessionAffinity"];"None") else . end;
    (.metadata.uid//"") as $uid | (.metadata.annotations[$tokenKey]//"") as $token |
    ($receipt[0].resources//[]|map(select(.resource==$resource and .namespace==$namespace and .name==$name))) as $records |
    if .metadata.labels[$ownerKey]!=$owner then "owner"
    elif (.metadata.deletionTimestamp//null)!=null or norm!=($old[0]|norm) and norm!=($new[0]|norm) then "material"
    elif $uid=="" then "uid"
    elif $check=="receipt" and (($records|length)!=1 or $records[0].uid!=$uid
      or (if $records[0].created then $token!=$setup else $token!="" end)) then "provenance"
    elif $check=="absent" and $token!="" then "provenance"
    elif norm==($old[0]|norm) then ["old",$uid,$token]|join("\u001f")
    else ["new",$uid,$token]|join("\u001f") end
  ' "$actual")" || return 1
  IFS=$'\x1f' read -r INSPECT_STATE OBJECT_UID OBJECT_TOKEN <<<"$row"
  [[ "$INSPECT_STATE" == old || "$INSPECT_STATE" == new ]]
}
preflight() {
  local expected="$1" require_present="$2" output="$3"
  local resource namespace name kind file actual check=absent
  [[ "$RECEIPT_PRESENT" == true ]] && check=receipt
  : >"$output"
  if [[ "$require_present" == false && "$RECEIPT_PRESENT" == false ]]; then
    actual="$JOURNAL/read-Namespace-${NAMESPACE}.json"
    get_object namespace _ "$NAMESPACE" "$actual" || die "could not read Namespace/$NAMESPACE."
    if [[ ! -s "$actual" ]]; then
      awk '{print $0 "|absent|"}' "$expected/plan" >"$output"
      return
    fi
  fi
  while IFS='|' read -r resource namespace name kind file; do
    actual="$JOURNAL/read-${kind}-${name}.json"
    get_object "$resource" "$namespace" "$name" "$actual" || die "could not read $kind/$name."
    if [[ ! -s "$actual" ]]; then
      [[ "$RECEIPT_PRESENT" == false && "$require_present" == false ]] ||
        die "$kind/$name is missing."
      printf '%s|absent|\n' "$resource|$namespace|$name|$kind|$file" >>"$output"
      continue
    fi
    inspect "$actual" "$file" "$file" "$resource" "$namespace" "$name" "$check" || case "$INSPECT_STATE" in
      owner) die "$kind/$name exists without exact blueprint ownership." ;;
      material) die "$kind/$name exists with different material configuration." ;;
      uid) die "$kind/$name has no stable UID." ;;
      *) die "$kind/$name does not match lifecycle provenance." ;;
    esac
    printf '%s|present|%s\n' "$resource|$namespace|$name|$kind|$file" "$OBJECT_UID" >>"$output"
  done <"$expected/plan"
}

set_outcome() {
  local resource="$1" namespace="$2" name="$3" state="$4" live_uid="$5" created="$6" staged
  staged="$(mktemp "$JOURNAL/.outcomes.XXXXXX")"
  awk -F '|' -v OFS='|' -v r="$resource" -v n="$namespace" -v x="$name" \
    -v s="$state" -v u="$live_uid" -v c="$created" \
    '{if($1==r && $2==n && $3==x){$6=s;$7=u;$8=c} print}' \
    "$JOURNAL/setup-outcomes" >"$staged"
  chmod 600 "$staged"; mv -f -- "$staged" "$JOURNAL/setup-outcomes"
}
recover_setup() {
  local resource namespace name kind file state _old_uid created actual
  SETUP_ID="$(cat "$JOURNAL/setup-id")"
  while IFS='|' read -r resource namespace name kind file state _old_uid created; do
    [[ "$state" == pending ]] || continue
    actual="$JOURNAL/recover-${kind}-${name}.json"
    get_object "$resource" "$namespace" "$name" "$actual" || die "could not read $kind/$name."
    [[ -s "$actual" ]] || continue
    inspect "$actual" "$file" || die "cannot recover $kind/$name safely."
    if [[ "$OBJECT_TOKEN" == "$SETUP_ID" ]]; then created=true
    elif [[ -z "$OBJECT_TOKEN" ]]; then created=false
    else die "$kind/$name belongs to another setup invocation."; fi
    set_outcome "$resource" "$namespace" "$name" complete "$OBJECT_UID" "$created"
  done <"$JOURNAL/setup-outcomes"
}
create_pending() {
  local resource namespace name kind file state _old_uid created marked actual status
  while IFS='|' read -r resource namespace name kind file state _old_uid created; do
    [[ "$state" == pending ]] || continue
    marked="$JOURNAL/create-${kind}-${name}.json"
    jq --arg key "$SETUP_ANNOTATION" --arg value "$SETUP_ID" \
      '.metadata.annotations = ((.metadata.annotations // {}) + {($key):$value})' "$file" >"$marked"
    status=0
    "${KUBECTL[@]}" create --filename "$marked" --output=json \
      >"$JOURNAL/create-response.json" 2>"$JOURNAL/create-error" || status=$?
    actual="$JOURNAL/created-${kind}-${name}.json"
    get_object "$resource" "$namespace" "$name" "$actual" ||
      die "create outcome for $kind/$name could not be read."
    [[ -s "$actual" ]] || die "create did not leave a recoverable $kind/$name."
    inspect "$actual" "$file" || die "$kind/$name appeared with different ownership or content."
    if [[ "$OBJECT_TOKEN" == "$SETUP_ID" ]]; then created=true
    elif (( status != 0 )) && [[ -z "$OBJECT_TOKEN" ]]; then created=false
    else die "$kind/$name create identity is ambiguous."; fi
    set_outcome "$resource" "$namespace" "$name" complete "$OBJECT_UID" "$created"
  done <"$JOURNAL/setup-outcomes"
}
write_receipt() {
  local staged
  staged="$(mktemp "$STATE_DIR/.receipt.XXXXXX")"
  jq -Rn --arg endpoint "$ENDPOINT" --arg ns "$NAMESPACE" --arg setup "$SETUP_ID" '
    [inputs | split("|") | {resource:.[0],namespace:.[1],name:.[2],
      uid:.[6],created:(.[7]=="true")}] |
    {version:1,clusterEndpoint:$endpoint,namespace:$ns,setupId:$setup,resources:.}
  ' <"$JOURNAL/setup-outcomes" >"$staged"
  chmod 600 "$staged"; mv -f -- "$staged" "$RECEIPT"; durable "$RECEIPT"
  RECEIPT_PRESENT=true; RECEIPT_DATA="$RECEIPT"
}

api_path() {
  case "$1" in
    namespace) printf '/api/v1/namespaces/%s' "$3" ;;
    serviceaccount|secret|configmap|service) printf '/api/v1/namespaces/%s/%ss/%s' "$2" "$1" "$3" ;;
    issuer.cert-manager.io) printf '/apis/cert-manager.io/v1/namespaces/%s/issuers/%s' "$2" "$3" ;;
    certificate.cert-manager.io) printf '/apis/cert-manager.io/v1/namespaces/%s/certificates/%s' "$2" "$3" ;;
    deployment.apps) printf '/apis/apps/v1/namespaces/%s/deployments/%s' "$2" "$3" ;;
    poddisruptionbudget.policy) printf '/apis/policy/v1/namespaces/%s/poddisruptionbudgets/%s' "$2" "$3" ;;
  esac
}
delete_uid() {
  local resource="$1" namespace="$2" name="$3" expected_uid="$4" current="$JOURNAL/delete-current.json"
  get_object "$resource" "$namespace" "$name" "$current" || return 1
  [[ ! -s "$current" ]] && return 0
  [[ "$(jq -r '.metadata.uid//""' "$current")" == "$expected_uid" ]] || return 1
  printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s"}}' "$expected_uid" |
    "${KUBECTL[@]}" delete --raw="$(api_path "$resource" "$namespace" "$name")" -f - >/dev/null
}
setup_clean() {
  local resource namespace name kind file state live_uid created actual
  while IFS='|' read -r resource namespace name kind file state live_uid created; do
    actual="$JOURNAL/clean-${kind}-${name}.json"
    get_object "$resource" "$namespace" "$name" "$actual" || return 1
    if [[ "$state" == pending || "$created" == true ]]; then
      [[ ! -s "$actual" ]] || return 1
    else
      [[ -s "$actual" ]] || return 1
      inspect "$actual" "$file" "$file" "$resource" "$namespace" "$name" absent || return 1
      [[ "$OBJECT_UID" == "$live_uid" ]] || return 1
    fi
  done <"$JOURNAL/setup-outcomes"
}
rollback_setup() {
  local resource namespace name kind file state live_uid created
  while IFS='|' read -r resource namespace name kind file state live_uid created; do
    if [[ "$state" == complete && "$created" == true ]]; then
      delete_uid "$resource" "$namespace" "$name" "$live_uid" ||
        echo "setup-agentgateway: rollback failed for $resource/$name." >&2
    fi
  done < <(awk '{line[NR]=$0} END{for(i=NR;i;i--)print line[i]}' "$JOURNAL/setup-outcomes")
  setup_clean
}

mutable_plan() {
  local old="$1" new="$2"
  cat <<EOF
configmap|${NAMESPACE}|agentgateway-config|${old}/configmap.json|${new}/configmap.json
secret|${NAMESPACE}|agw-client-key|${old}/secret-client.json|${new}/secret-client.json
secret|${NAMESPACE}|agw-session-key|${old}/secret-session.json|${new}/secret-session.json
deployment.apps|${NAMESPACE}|agentgateway|${old}/deployment.json|${new}/deployment.json
EOF
}
ROTATION_STATE=""
rotation_state() {
  local resource="$1" namespace="$2" name="$3" old="$4" new="$5" output="$6"
  get_object "$resource" "$namespace" "$name" "$output" || return 1
  [[ -s "$output" ]] || return 1
  inspect "$output" "$old" "$new" "$resource" "$namespace" "$name" receipt || return 1
  ROTATION_STATE="$INSPECT_STATE"
}
replacement() {
  local desired="$1" current="$2" output="$3"
  jq --arg key "$SETUP_ANNOTATION" --slurpfile current "$current" '
    ($current[0].metadata.resourceVersion//"") as $rv |
    ($current[0].metadata.annotations[$key]//"") as $token |
    if $rv=="" then error("missing resourceVersion") else . end |
    .metadata.resourceVersion=$rv |
    if $token=="" then . else .metadata.annotations =
      ((.metadata.annotations // {}) + {($key):$token}) end
  ' "$desired" >"$output"
}
replace_one() {
  local resource="$1" namespace="$2" name="$3" old="$4" new="$5"
  local current="$JOURNAL/rotate-current-$name.json" desired="$JOURNAL/rotate-$name.json" state
  rotation_state "$resource" "$namespace" "$name" "$old" "$new" "$current" ||
    die "$resource/$name changed after rotation preflight."
  state="$ROTATION_STATE"
  [[ "$state" == old ]] || die "$resource/$name is already rotated."
  replacement "$new" "$current" "$desired" || die "could not prepare $resource/$name."
  "${KUBECTL[@]}" replace --filename "$desired" --output=json >"$JOURNAL/replace-response.json" ||
    true
  rotation_state "$resource" "$namespace" "$name" "$old" "$new" "$current" ||
    die "could not read $resource/$name after rotation."
  state="$ROTATION_STATE"
  [[ "$state" == new ]] || die "$resource/$name is not safely rotated."
}
install_state() {
  local source="$1" file staged
  for file in "${STATE_FILES[@]}"; do
    staged="$(mktemp "$STATE_DIR/.$file.XXXXXX")"
    cp -- "$source/$file" "$staged"; chmod 600 "$staged"; mv -f -- "$staged" "$STATE_DIR/$file"
  done
  durable "$STATE_DIR/tenant-a-agentgateway.key" "$STATE_DIR/tenant-b-agentgateway.key" \
    "$STATE_DIR/tenant-a-sha256" "$STATE_DIR/tenant-b-sha256" \
    "$STATE_DIR/agentgateway-session.key"
}
rollback_rotation() {
  local resource namespace name old new current state replacement_file changed=false failed=false
  local states="$JOURNAL/rollback-states"
  : >"$states"
  while IFS='|' read -r resource namespace name old new; do
    current="$JOURNAL/rollback-current-$name.json"
    if ! rotation_state "$resource" "$namespace" "$name" "$old" "$new" "$current"; then
      echo "setup-agentgateway: skipped restore after $resource/$name changed." >&2
      return 1
    fi
    state="$ROTATION_STATE"
    printf '%s|%s|%s|%s|%s|%s\n' "$resource" "$namespace" "$name" "$old" "$new" "$state" >>"$states"
  done < <(mutable_plan "$JOURNAL/current" "$JOURNAL/new")
  while IFS='|' read -r resource namespace name old new state; do
    [[ "$state" == new ]] || continue
    changed=true; current="$JOURNAL/rollback-current-$name.json"
    replacement_file="$JOURNAL/restore-$name.json"
    replacement "$old" "$current" "$replacement_file" || { failed=true; continue; }
    "${KUBECTL[@]}" replace --filename "$replacement_file" --output=json \
      >"$JOURNAL/restore-response.json" || {
        echo "setup-agentgateway: restore failed for $resource/$name." >&2
        failed=true; continue
      }
    state=""
    if rotation_state "$resource" "$namespace" "$name" "$old" "$new" "$current"; then
      state="$ROTATION_STATE"
    fi
    if [[ "$state" != old ]]; then
      echo "setup-agentgateway: restore failed for $resource/$name." >&2; failed=true
    fi
  done <"$states"
  [[ "$failed" == false ]] || return 1
  if [[ "$changed" == true ]]; then
    "${KUBECTL[@]}" --namespace "$NAMESPACE" rollout status deployment/agentgateway \
      --timeout="$ROLLOUT_TIMEOUT" >/dev/null || {
        echo "setup-agentgateway: restored AgentGateway rollout did not complete." >&2; return 1
      }
  fi
  install_state "$JOURNAL/state-backup" || return 1
}

cleanup() {
  local status=$? clean=false
  [[ "$CLEANING" == false ]] || exit "$status"
  CLEANING=true; trap - EXIT INT TERM HUP; set +e
  if (( status != 0 )) && [[ "$RECOVERY_ATTEMPT" == false ]]; then
    if [[ "$MODE" == setup && "$PHASE" == active ]]; then
      rollback_setup && clean=true
    elif [[ "$MODE" == rotation && "$PHASE" == active ]]; then
      if rollback_rotation; then clean=true
      else
        echo "setup-agentgateway: rotation rollback was incomplete." >&2
      fi
    fi
  fi
  if (( status == 0 )) || [[ "$clean" == true ]]; then PRESERVE=false; fi
  if (( status != 0 )) && [[ "$clean" == false && -n "$MODE" ]]; then
    PRESERVE=true
    echo "setup-agentgateway: rollback could not prove consistency; preserved recovery material at $JOURNAL." >&2
  fi
  [[ "$PRESERVE" == true ]] || rm -rf -- "$JOURNAL"
  release_lock
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

reset_after_recovery() {
  rm -rf -- "$JOURNAL"; mkdir -m 700 -- "$JOURNAL"
  RECOVERY=false MODE="" PHASE="" PRESERVE=false RECEIPT_PRESENT=false
  snapshot_kubeconfig; use_snapshot
  ENDPOINT="$("${KUBECTL[@]}" config view --raw --minify --context "$KUBE_CONTEXT" \
    --output=json | jq -er '.clusters | select(length == 1) | .[0].cluster.server')"
  load_receipt
}
if [[ "$RECOVERY" == true ]]; then
  MODE="$(cat "$JOURNAL/journal-mode")"; PHASE="$(cat "$JOURNAL/journal-phase")"
  [[ "$MODE" == setup || "$MODE" == rotation ]] || die "unknown journal mode."
  [[ "$PHASE" == active || "$PHASE" == committed ]] || die "unknown journal phase."
  PRESERVE=true
  if [[ "$MODE" == rotation ]]; then
    RECOVERY_ATTEMPT=true
    if [[ "$PHASE" == committed ]]; then
      for file in "${STATE_FILES[@]}"; do
        cmp -s "$STATE_DIR/$file" "$JOURNAL/new-state/$file" ||
          die "committed rotation has incomplete local state."
      done
      preflight "$JOURNAL/new" true "$JOURNAL/committed-presence"
      RECOVERED_COMMIT=true
    else
      rollback_rotation || die "could not recover the active rotation journal."
    fi
    RECOVERY_ATTEMPT=false
    if [[ "$RECOVERED_COMMIT" == true ]]; then
      PRESERVE=false
      echo "AgentGateway resources: validated; completed rotation recovered"
      echo "Deployment/agentgateway: available"
      exit 0
    fi
    reset_after_recovery
  fi
fi

prepare_state
if [[ "$RECOVERY" == true ]]; then
  [[ "$MODE" == setup ]] || die "unexpected recovery state."
  if [[ "$PHASE" == committed ]]; then
    preflight "$JOURNAL/current" true "$JOURNAL/committed-presence"
    PRESERVE=false
    echo "AgentGateway resources: validated; completed setup recovered"
    echo "Deployment/agentgateway: available"
    exit 0
  fi
  recover_setup
else
  build_expected "$STATE_DIR" "$JOURNAL/current"
fi

if [[ "$ROTATE" == true ]]; then
  [[ "$RECEIPT_PRESENT" == true ]] || die "--rotate-keys requires a lifecycle receipt."
  preflight "$JOURNAL/current" true "$JOURNAL/presence"
  mkdir -m 700 -- "$JOURNAL/state-backup"
  for file in "${STATE_FILES[@]}"; do cp -- "$STATE_DIR/$file" "$JOURNAL/state-backup/$file"; done
  chmod 600 "$JOURNAL/state-backup"/*
  stage_keys "$JOURNAL/new-state"; build_expected "$JOURNAL/new-state" "$JOURNAL/new"
  begin_journal rotation; PRESERVE=true
  while IFS='|' read -r resource namespace name old new; do
    replace_one "$resource" "$namespace" "$name" "$old" "$new"
  done < <(mutable_plan "$JOURNAL/current" "$JOURNAL/new")
  "${KUBECTL[@]}" --namespace "$NAMESPACE" rollout status deployment/agentgateway \
    --timeout="$ROLLOUT_TIMEOUT" >/dev/null ||
    die "AgentGateway rollout did not complete after key rotation."
  install_state "$JOURNAL/new-state"
  rotation_state deployment.apps "$NAMESPACE" agentgateway \
    "$JOURNAL/current/deployment.json" "$JOURNAL/new/deployment.json" \
    "$JOURNAL/post-rollout-deployment.json" ||
    die "could not verify deployment.apps/agentgateway after rollout."
  [[ "$ROTATION_STATE" == new ]] || die "deployment.apps/agentgateway reverted after rollout."
  commit_journal
  PRESERVE=false
  echo "AgentGateway resources: validated; key-bearing resources rotated"
else
  if [[ "$RECOVERY" == false ]]; then
    preflight "$JOURNAL/current" false "$JOURNAL/presence"
    SETUP_ID="$(openssl rand -hex 16)"
    write_value "$JOURNAL/setup-id" "$SETUP_ID"
    awk -F '|' -v OFS='|' '{print $1,$2,$3,$4,$5,
      ($6=="absent"?"pending":"complete"),($6=="absent"?"":$7),"false"}' \
      "$JOURNAL/presence" >"$JOURNAL/setup-outcomes"
    chmod 600 "$JOURNAL/setup-outcomes"
    begin_journal setup; PRESERVE=true
  fi
  create_pending
  "${KUBECTL[@]}" --namespace "$NAMESPACE" rollout status deployment/agentgateway \
    --timeout="$ROLLOUT_TIMEOUT" >/dev/null || die "AgentGateway rollout did not complete."
  write_receipt
  commit_journal
  PRESERVE=false
  echo "AgentGateway resources: created or verified"
fi
echo "Deployment/agentgateway: available"
