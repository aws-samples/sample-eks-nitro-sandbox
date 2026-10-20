#!/usr/bin/env bash
# Shared setup for the pause-resume scripts: read .env, set names, and the
# guards the other scripts use. Sourced, not run.
#
# Every kubectl call in these scripts goes through kc(), which pins --context and
# --namespace, so a run never depends on the machine's current context (shared
# clusters change it) or default namespace.
set -euo pipefail

SAMPLE=pause-resume
SANDBOX=pause-resume
# shellcheck disable=SC2034  # PVC is used by the scripts that source this file.
PVC="workspace-${SANDBOX}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

# Load .env if present, as defaults. A value already set in the environment wins
# over .env, so `NAMESPACE=other ./scripts/setup.sh` overrides the file. Keep the
# caller's environment, source .env into a subshell, and fill in only the names
# the caller did not set.
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      NAMESPACE)      NAMESPACE="${NAMESPACE:-$_v}" ;;
      STORAGE_CLASS)  STORAGE_CLASS="${STORAGE_CLASS:-$_v}" ;;
      AWS_REGION)     AWS_REGION="${AWS_REGION:-$_v}" ;;
      KUBE_CONTEXT)   KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
    esac
  done < <(grep -E '^[[:space:]]*(NAMESPACE|STORAGE_CLASS|AWS_REGION|KUBE_CONTEXT)[[:space:]]*=' "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

NAMESPACE="${NAMESPACE:-pause-resume}"
# STORAGE_CLASS, when set, names a specific class for the workspace claim and
# overrides the choice; setup then only checks that class's provisioner. When it
# is unset (the default), setup CHOOSES the class: the cluster's default class if
# exactly one fits (EBS CSI, gp3, encrypted), otherwise the sample's own class.
# choose_storage_class fills CHOSEN_STORAGE_CLASS with the name the claim uses.
STORAGE_CLASS="${STORAGE_CLASS:-}"
CHOSEN_STORAGE_CLASS=""
# The sample's own class: named for the sample, not the cluster default, created
# only when no fitting default exists. Its manifest is deploy/storage-class.yaml.
SAMPLE_STORAGE_CLASS="pause-resume-gp3"
# The provisioner a class must use for the EBS CSI driver.
EBS_PROVISIONER="ebs.csi.eks.amazonaws.com"
AWS_REGION="${AWS_REGION:-us-west-2}"
# The context the run pins. Set KUBE_CONTEXT to the name of the kube context for
# the cluster you ran Getting started on. Empty means "use the current context",
# which the scripts then print so you can see which cluster they used.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

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

# This sample's namespace is the sample's only when it carries the label the
# setup put on it. A script reuses or deletes the namespace, or anything in it,
# only when the label is present; otherwise it stops. A read that fails means
# "could not determine", which is a failure, never "gone".
NS_LABEL_KEY="app.kubernetes.io/managed-by"
NS_LABEL_VAL="$SAMPLE"

# Return codes, so callers can tell the cases apart. A read that fails for any
# reason other than "not found" is NEVER read as "gone".
#   0  the namespace exists and carries our label  (it is the sample's)
#   1  the namespace exists but does not carry our label  (someone else's)
#   2  the namespace exists but its labels could not be read  (could not tell)
#   3  the namespace does not exist
namespace_is_ours() {
  local out rc
  # One authoritative read of the object. --ignore-not-found makes "absent" a
  # clean empty result with rc 0, so a real API error (rc != 0) is distinct from
  # a namespace that simply is not there.
  local key_esc="${NS_LABEL_KEY//./\\.}"   # dots in the label key must be escaped in jsonpath
  out="$(kc_cluster get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    return 2    # the read itself failed: could not determine
  fi
  if [[ "$out" == "|" || -z "$out" ]]; then
    return 3    # --ignore-not-found printed nothing: the namespace is absent
  fi
  # out is "<label-value>|<name>"; the name is non-empty, so the namespace exists.
  local label="${out%%|*}"
  [[ "$label" == "$NS_LABEL_VAL" ]]
}

# resource_exists <kind/name...> : a failure-aware existence check, so a failed
# read is never mistaken for "absent" or "gone". Uses --ignore-not-found so a
# genuinely missing object is a clean empty result (rc 0), distinct from an API
# error (rc != 0). Pass kc or kc_cluster as the first argument.
#   0  the resource exists
#   1  the resource does not exist
#   2  the read failed (could not determine)
resource_exists() {
  local runner=$1; shift
  local out rc
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}

# require_our_namespace : stop unless this sample owns the namespace, so suspend,
# resume and any other mutating script never touch a same-named object in a
# namespace that belongs to something else. A failed read stops too.
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

# sc_field <class> <jsonpath-after-metadata> : read one field of a StorageClass.
# Prints the value (empty when the field or the class is absent). Returns non-zero
# only when the read itself fails, so a caller can tell "absent" from "could not
# read". Pass the jsonpath body, e.g. '{.provisioner}'.
sc_field() {
  local class=$1 path=$2 out rc=0
  out="$(kc_cluster get storageclass "$class" --ignore-not-found -o "jsonpath=$path" 2>/dev/null)" || rc=$?
  printf '%s' "$out"
  return $rc
}

# sc_fits <class> : does this class fit the sample? EBS CSI provisioner, type gp3
# (or unset, which is gp3), and encrypted "true". Returns 0 when it fits, 1 when
# it does not, 2 when a read failed. Never treats a failed read as a fit.
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
# create the sample's own class only if needed. Sets CHOSEN_STORAGE_CLASS. Runs
# before setup creates anything. A StorageClass is chosen, never changed: this
# never patches a class and never `kubectl apply`s one (which, on a class created
# with apply, would strip its default annotation).
#
#   STORAGE_CLASS set   -> use it, after checking its provisioner is EBS CSI.
#   STORAGE_CLASS unset -> use the one default class that fits, if exactly one
#                          does; otherwise the sample's own class (create it from
#                          deploy/storage-class.yaml when absent, reuse it only
#                          when it carries the sample's mark and the right
#                          provisioner, stop otherwise).
choose_storage_class() {
  if [[ -n "$STORAGE_CLASS" ]]; then
    # Naming the sample's OWN class means "use the sample's class": ensure it
    # exists (create from the manifest when absent, reuse only when marked and
    # right-provisioned). Naming any OTHER class is a check-only override: setup
    # uses it as is and only checks its provisioner, never creating it.
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

  # Auto-choose. List the default classes (a read failure stops the run).
  local defaults rc=0
  defaults="$(kc_cluster get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && die "could not list StorageClasses; stopping rather than guess"

  # Of the default classes, keep the ones that fit.
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

  # No single fitting default: use the sample's own class.
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
# Never `kubectl apply` (which would change an existing class).
ensure_sample_storage_class() {
  local prov rc=0
  prov="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.provisioner}')" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  if [[ -z "$prov" ]]; then
    # Absent: create it from the manifest. kubectl create (not apply) fails if it
    # races into existence, which is the safe outcome.
    echo "creating storageclass/$SAMPLE_STORAGE_CLASS from deploy/storage-class.yaml"
    kc_cluster create -f "$SAMPLE_DIR/deploy/storage-class.yaml" \
      || die "could not create storageclass/$SAMPLE_STORAGE_CLASS"
    return 0
  fi
  # Present: reuse only when it is the sample's and uses the EBS CSI provisioner.
  local mark mrc=0
  mark="$(sc_field "$SAMPLE_STORAGE_CLASS" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" || mrc=$?
  [[ $mrc -ne 0 ]] && die "could not read the labels on storageclass/$SAMPLE_STORAGE_CLASS; stopping rather than guess"
  [[ "$mark" != "$SAMPLE" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS already exists without the sample's mark (app.kubernetes.io/managed-by=$SAMPLE); it belongs to something else. Remove it or set STORAGE_CLASS to a class that uses $EBS_PROVISIONER."
  [[ "$prov" != "$EBS_PROVISIONER" ]] && die "storageclass/$SAMPLE_STORAGE_CLASS exists with provisioner '$prov', not '$EBS_PROVISIONER'; not reusing it."
  echo "reusing storageclass/$SAMPLE_STORAGE_CLASS (carries the sample's mark, provisioner $prov)"
}
