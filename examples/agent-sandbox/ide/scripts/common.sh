#!/usr/bin/env bash
# Shared setup for the ide scripts: read .env, set names, and the guards the other
# scripts use. Sourced, not run.
#
# Every kubectl call in these scripts goes through kc(), which pins --context and
# --namespace, so a run never depends on the machine's current context (shared
# clusters change it) or default namespace.
set -euo pipefail

SAMPLE=ide
SANDBOX=ide
# volumeClaimTemplates names the claim "<template>-<sandbox>".
# shellcheck disable=SC2034  # used by the scripts that source this file
PVC="workspace-${SANDBOX}"
# shellcheck disable=SC2034
SECRET="${SANDBOX}-password"
# shellcheck disable=SC2034
POLICY="${SANDBOX}-egress"
# shellcheck disable=SC2034
ORDINARY_POD="${SANDBOX}-ordinary"
# The port code-server listens on inside the guest, and the local port the
# port-forward opens on the operator's own machine.
# shellcheck disable=SC2034
IDE_PORT=8080
# shellcheck disable=SC2034
WORKSPACE=/home/coder/project
# The pinned code-server image. Stated on the page's versions table.
# shellcheck disable=SC2034
IMAGE="ghcr.io/coder/code-server:4.143.1"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"
# examples/agent-sandbox/ide -> the repository root, three levels up.
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"

# Load .env if present, as defaults. A value already set in the environment wins
# over .env, so `NAMESPACE=other ./scripts/setup.sh` overrides the file. Keep the
# caller's environment, read .env line by line, and fill in only the names the
# caller did not set.
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      NAMESPACE)      NAMESPACE="${NAMESPACE:-$_v}" ;;
      STORAGE_CLASS)  STORAGE_CLASS="${STORAGE_CLASS:-$_v}" ;;
      AWS_REGION)     AWS_REGION="${AWS_REGION:-$_v}" ;;
      KUBE_CONTEXT)   KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      LOCAL_DIR)      LOCAL_DIR="${LOCAL_DIR:-$_v}" ;;
    esac
  done < <(grep -E '^[[:space:]]*(NAMESPACE|STORAGE_CLASS|AWS_REGION|KUBE_CONTEXT|LOCAL_DIR)[[:space:]]*=' "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

NAMESPACE="${NAMESPACE:-ide}"
# STORAGE_CLASS, when set, names a specific class for the workspace claim and
# overrides the choice; setup then only checks that class's provisioner. When it
# is unset (the default), setup CHOOSES the class: the cluster's default class if
# exactly one fits (EBS CSI, gp3, encrypted), otherwise the sample's own class.
STORAGE_CLASS="${STORAGE_CLASS:-}"
CHOSEN_STORAGE_CLASS=""
SAMPLE_STORAGE_CLASS="ide-gp3"
EBS_PROVISIONER="ebs.csi.eks.amazonaws.com"
AWS_REGION="${AWS_REGION:-us-west-2}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

# Where the password and its hash live on the operator's own machine. The
# repository's tmp/ is git-ignored, so neither file can be committed by accident.
# The plaintext never leaves this directory: it is read from the file, never
# passed on a command line.
LOCAL_DIR="${LOCAL_DIR:-$REPO_ROOT/tmp/$SAMPLE}"
# shellcheck disable=SC2034
PASSWORD_FILE="$LOCAL_DIR/password"
HASH_FILE="$LOCAL_DIR/hashed-password"

# rel <path> : the path as the reader sees it, relative to the repository root
# when it is inside it. The scripts print paths through this so their output does
# not carry the absolute path of your clone.
rel() {
  local p=$1
  case "$p" in
    "$REPO_ROOT"/*) printf '%s' "${p#"$REPO_ROOT"/}" ;;
    *)              printf '%s' "$p" ;;
  esac
}

# kc: kubectl pinned to this sample's context and namespace. Cluster-scoped reads
# that must not carry a namespace use kc_cluster.
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
  else
    kubectl --namespace "$NAMESPACE" "$@"
  fi
}
kc_cluster() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

require_commands() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Print which cluster the run is pinned to, so a shared machine's current context
# can never be mistaken for the one you meant.
show_context() {
  local ctx
  ctx="$(kc_cluster config current-context 2>/dev/null || true)"
  if [[ -n "$KUBE_CONTEXT" ]]; then
    echo "context: $KUBE_CONTEXT (pinned)   namespace: $NAMESPACE"
  else
    echo "context: ${ctx:-<none>} (current; set KUBE_CONTEXT to pin it)   namespace: $NAMESPACE"
  fi
}

# This sample's namespace is the sample's only when it carries the label the setup
# put on it. A script reuses or deletes the namespace, or anything in it, only when
# the label is present; otherwise it stops. A read that fails means "could not
# determine", which is a failure, never "gone".
NS_LABEL_KEY="app.kubernetes.io/managed-by"
NS_LABEL_VAL="$SAMPLE"

# Return codes, so callers can tell the cases apart:
#   0  the namespace exists and carries our label  (it is the sample's)
#   1  the namespace exists but does not carry our label  (someone else's)
#   2  the namespace exists but its labels could not be read  (could not tell)
#   3  the namespace does not exist
namespace_is_ours() {
  local out rc
  local key_esc="${NS_LABEL_KEY//./\\.}"   # dots in a label key must be escaped in jsonpath
  out="$(kc_cluster get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    return 2    # the read itself failed: could not determine
  fi
  if [[ "$out" == "|" || -z "$out" ]]; then
    return 3    # --ignore-not-found printed nothing: the namespace is absent
  fi
  local label="${out%%|*}"
  [[ "$label" == "$NS_LABEL_VAL" ]]
}

# resource_exists <runner> <kind/name...> : a failure-aware existence check, so a
# failed read is never mistaken for "absent" or "gone". Pass kc or kc_cluster as
# the first argument.
#   0  it exists   1  it does not exist   2  the read failed
resource_exists() {
  local runner=$1; shift
  local out rc
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}

# require_our_namespace : stop unless this sample owns the namespace, so a
# mutating script never touches a same-named object in a namespace that belongs to
# something else. A failed read stops too.
require_our_namespace() {
  local rc=0
  namespace_is_ours || rc=$?
  case $rc in
    0) return 0 ;;
    1) die "namespace $NAMESPACE is not the sample's ($NS_LABEL_KEY=$NS_LABEL_VAL); refusing to touch anything in it. Set NAMESPACE in .env to the one you ran ./scripts/setup.sh with." ;;
    2) die "could not read namespace $NAMESPACE; stopping rather than act on a namespace I cannot verify" ;;
    3) die "namespace $NAMESPACE does not exist; run ./scripts/setup.sh first" ;;
  esac
}

# sc_field <class> <jsonpath> : read one field of a StorageClass. Prints the value
# (empty when the field or the class is absent) and returns non-zero only when the
# read itself fails, so a caller can tell "absent" from "could not read".
sc_field() {
  local class=$1 path=$2 out rc=0
  out="$(kc_cluster get storageclass "$class" --ignore-not-found -o "jsonpath=$path" 2>/dev/null)" || rc=$?
  printf '%s' "$out"
  return $rc
}

# sc_fits <class> : does this class fit the sample? EBS CSI provisioner, type gp3
# (or unset, which is gp3), and encrypted "true".
#   0 it fits   1 it does not   2 a read failed
sc_fits() {
  local class=$1 prov type enc rc=0
  prov="$(sc_field "$class" '{.provisioner}')" || rc=$?
  type="$(sc_field "$class" '{.parameters.type}')" || rc=$?
  enc="$(sc_field "$class" '{.parameters.encrypted}')" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ "$prov" == "$EBS_PROVISIONER" ]] || return 1
  [[ -z "$type" || "$type" == "gp3" ]] || return 1
  [[ "$enc" == "true" ]] || return 1
  return 0
}

# choose_storage_class : decide which StorageClass the workspace claim names, and
# create the sample's own class only if needed. Sets CHOSEN_STORAGE_CLASS. A
# StorageClass is chosen, never changed: this never patches a class and never
# `kubectl apply`s one.
#
#   STORAGE_CLASS set   -> use it, after checking its provisioner is EBS CSI.
#   STORAGE_CLASS unset -> use the one default class that fits, if exactly one
#                          does; otherwise the sample's own class.
choose_storage_class() {
  if [[ -n "$STORAGE_CLASS" ]]; then
    if [[ "$STORAGE_CLASS" == "$SAMPLE_STORAGE_CLASS" ]]; then
      echo "STORAGE_CLASS names the sample's own class $SAMPLE_STORAGE_CLASS"
      ensure_sample_storage_class
      CHOSEN_STORAGE_CLASS="$SAMPLE_STORAGE_CLASS"
      return 0
    fi
    local prov rc=0
    prov="$(sc_field "$STORAGE_CLASS" '{.provisioner}')" || rc=$?
    [[ $rc -ne 0 ]] && die "could not read storageclass/$STORAGE_CLASS; stopping rather than guess (a failed read is not 'absent')"
    [[ -z "$prov" ]] && die "storageclass/$STORAGE_CLASS (from STORAGE_CLASS) not found. Set STORAGE_CLASS to a class that uses $EBS_PROVISIONER, or unset it to let setup choose."
    [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$STORAGE_CLASS (from STORAGE_CLASS) uses provisioner '$prov', not '$EBS_PROVISIONER'; its volumes are not EBS CSI volumes."
    CHOSEN_STORAGE_CLASS="$STORAGE_CLASS"
    echo "using storageclass $CHOSEN_STORAGE_CLASS (from STORAGE_CLASS), provisioner $prov"
    return 0
  fi

  local defaults rc=0
  defaults="$(kc_cluster get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && die "could not list StorageClasses; stopping rather than guess"

  local fitting=() name f
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    f=0; sc_fits "$name" || f=$?
    case $f in
      0) fitting+=("$name") ;;
      2) die "could not read the default storageclass/$name; stopping rather than guess" ;;
    esac
  done <<< "$defaults"

  if [[ ${#fitting[@]} -eq 1 ]]; then
    CHOSEN_STORAGE_CLASS="${fitting[0]}"
    echo "using the cluster default storageclass ${CHOSEN_STORAGE_CLASS} (it fits: $EBS_PROVISIONER, gp3, encrypted); creating no class"
    return 0
  fi

  if [[ ${#fitting[@]} -gt 1 ]]; then
    echo "note: ${#fitting[@]} default StorageClasses fit; not guessing which. Using the sample's own class ${SAMPLE_STORAGE_CLASS}."
  else
    echo "note: no default StorageClass fits ($EBS_PROVISIONER, gp3, encrypted). Using the sample's own class ${SAMPLE_STORAGE_CLASS}."
  fi
  ensure_sample_storage_class
  CHOSEN_STORAGE_CLASS="$SAMPLE_STORAGE_CLASS"
}

# ensure_sample_storage_class : make SAMPLE_STORAGE_CLASS available. Create it from
# the manifest with `kubectl create` only when absent; reuse an existing one only
# when it carries the sample's mark AND the right provisioner; stop otherwise.
ensure_sample_storage_class() {
  local prov rc=0
  prov="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.provisioner}')" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  if [[ -z "$prov" ]]; then
    echo "creating storageclass/$SAMPLE_STORAGE_CLASS from deploy/storage-class.yaml"
    kc_cluster create -f "$SAMPLE_DIR/deploy/storage-class.yaml" \
      || die "could not create storageclass/$SAMPLE_STORAGE_CLASS"
    return 0
  fi
  local mark mrc=0
  mark="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" || mrc=$?
  [[ $mrc -ne 0 ]] && die "could not read the labels on storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  [[ "$mark" != "$SAMPLE" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS already exists without the sample's mark ($NS_LABEL_KEY=$SAMPLE); it belongs to something else. Remove it or set STORAGE_CLASS to a class that uses $EBS_PROVISIONER."
  [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS exists with provisioner '$prov', not '$EBS_PROVISIONER'; not reusing it."
  echo "reusing storageclass/$SAMPLE_STORAGE_CLASS (carries the sample's mark, provisioner $prov)"
}

# require_hash_file : the editor's password hash must already exist on this
# machine. scripts/new-password.sh writes it. An empty file is as useless as a
# missing one, so check both.
require_hash_file() {
  [[ -f "$HASH_FILE" ]] \
    || die "no password hash at $(rel "$HASH_FILE"); run ./scripts/new-password.sh first (it generates the password and its argon2 hash on this machine)"
  [[ -s "$HASH_FILE" ]] \
    || die "the password hash at $(rel "$HASH_FILE") is empty; run ./scripts/new-password.sh again"
  grep -q '^[$]argon2' "$HASH_FILE" \
    || die "the file at $(rel "$HASH_FILE") does not hold an argon2 hash (it must start with \$argon2); run ./scripts/new-password.sh again"
}

# require_network_policy_enforcement : network policies are accepted on EKS Auto
# Mode but not enforced until the cluster's amazon-vpc-cni ConfigMap turns the
# controller on. That is a cluster-wide setting every workload shares, so this
# script never changes it: it checks and stops with the command for the reader.
# A read that fails stops the run too.
require_network_policy_enforcement() {
  local v rc=0
  v="$(kc_cluster -n kube-system get configmap amazon-vpc-cni \
    -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read the amazon-vpc-cni ConfigMap in kube-system; stopping rather than assume network policy is enforced"
  if [[ "$v" != "true" ]]; then
    die "network policy enforcement is off on this cluster (amazon-vpc-cni enable-network-policy-controller is '${v:-<unset>}'), so the egress policy would be accepted and not enforced.
       This is a cluster-wide setting every workload shares, so this script does not change it. Turn it on yourself with:
         kubectl -n kube-system patch configmap amazon-vpc-cni --type merge -p '{\"data\":{\"enable-network-policy-controller\":\"true\"}}'
       then re-run ./scripts/setup.sh."
  fi
  echo "network policy enforcement is on (amazon-vpc-cni enable-network-policy-controller=true)"
}
