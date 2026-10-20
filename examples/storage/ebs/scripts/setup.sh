#!/usr/bin/env bash
# Set up the EBS sample: CHOOSE a StorageClass, then create the pod and its claim bound
# through the class that was chosen.
#
#   ./scripts/setup.sh
#
# A StorageClass is a cluster-wide object, so this sample chooses one and never changes one:
#
#   1. The cluster's default class, when it fits. "Fits" means provisioner
#      ebs.csi.eks.amazonaws.com, type gp3 (or unset, which is gp3), and encrypted "true".
#      If exactly one default class fits, setup uses it and creates nothing.
#   2. Otherwise, the sample's own class (nitro-sandbox-ebs). setup creates it from
#      deploy/storage-class.yaml with `kubectl create`, only when it is absent. If a class
#      with that name already exists, setup reuses it only when it carries the sample's mark
#      and uses the Auto Mode provisioner, and stops otherwise. The class is non-default and
#      carries the sample's mark, so the clean up deletes only a class this sample created.
#   3. STORAGE_CLASS, when set, names a class explicitly and overrides the choice; setup
#      checks that class's provisioner.
#
# setup never runs `kubectl apply` over an existing StorageClass: on a cluster whose class
# was created with `kubectl apply`, applying a manifest that omits the default-class
# annotation strips it from the live class and changes how every other claim is
# provisioned. It only ever `kubectl create`s the sample's own class when absent.
#
# It then creates the namespace (if absent), applies the PVC and pod from
# deploy/pod-ebs.yaml rendered with the chosen class, and waits for the volume to attach and
# the guest to boot. Idempotent: re-running it reuses the namespace, the class and the claim.
#
# Overridable (defaults match the page):
#   NAMESPACE      the namespace to run in                       (default nitro-ebs-sample)
#   STORAGE_CLASS  force a specific class, overriding the choice (default: empty, choose)
#   KUBECTL        the kubectl command, e.g.                     (default "kubectl")
#                  KUBECTL="kubectl --context my-cluster"
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-nitro-ebs-sample}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
KUBECTL="${KUBECTL:-kubectl}"

# The provisioner of the Auto Mode EBS CSI driver. A class that names a different
# provisioner (for example the in-tree kubernetes.io/aws-ebs) would provision something this
# sample then describes wrongly, so a class that does not use this one never fits and is
# never chosen.
WANT_PROVISIONER="ebs.csi.eks.amazonaws.com"
# The sample's own class, and the mark it carries. The mark is both the StorageClass label
# and the namespace label, so the clean up can tell an object this sample created from one
# that already existed under the same name.
SAMPLE_CLASS="nitro-sandbox-ebs"
SAMPLE_LABEL_KEY="app.kubernetes.io/part-of"
SAMPLE_LABEL_VALUE="nitro-sandbox-ebs"
# The same key with its dots backslash-escaped, for use inside a jsonpath expression (an
# unescaped dot there is a field separator, so the key would be read as nested fields).
SAMPLE_LABEL_JSONPATH='app\.kubernetes\.io/part-of'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

# kget_field <kind> <name> <jsonpath> : print the field's value on stdout and return 0,
# print nothing and return 0 when the object or field is absent, return non-zero only on a
# real read failure. Used for every StorageClass read so a transient error (throttle, RBAC,
# apiserver restart) is never mistaken for a value or for "absent". The caller reads the
# value from KGET_FIELD and the status from the function (NOT a command substitution, which
# runs in a subshell and drops a failure flag, and which under `set -e` would abort this
# script before the caller could handle it). stderr is captured separately, never folded in
# with 2>&1: kubectl writes deprecation and kubeconfig warnings there even on success.
KGET_FIELD=""
KGET_ERR=""
kget_field() {
  local kind="$1" name="$2" path="$3" errf
  errf="$(mktemp)"
  if KGET_FIELD="$($KUBECTL get "$kind" "$name" --ignore-not-found -o "jsonpath=$path" 2>"$errf")"; then
    KGET_ERR=""; rm -f "$errf"; return 0
  fi
  KGET_ERR="$(sed 's/^/  /' "$errf")"; rm -f "$errf"; KGET_FIELD=""; return 1
}

# sc_fits <class> : decide whether the named StorageClass fits (Auto Mode provisioner, type
# gp3 or unset, encrypted "true"). Three outcomes, kept apart so a transient read failure is
# never mistaken for a genuine mismatch (which would silently fall through to creating the
# sample's class instead of failing closed):
#   0 = fits; 1 = a field was read successfully and does not match; 2 = a read itself failed.
# The caller treats 2 as fatal. SC_FITS_WHY carries a human reason for 1 or 2.
SC_FITS_WHY=""
sc_fits() {
  local sc="$1"
  if ! kget_field storageclass "$sc" '{.provisioner}'; then
    SC_FITS_WHY="could not read provisioner of $sc: $KGET_ERR"; return 2
  fi
  if [[ "$KGET_FIELD" != "$WANT_PROVISIONER" ]]; then
    SC_FITS_WHY="provisioner is '${KGET_FIELD:-<unset>}', not $WANT_PROVISIONER"; return 1
  fi
  if ! kget_field storageclass "$sc" '{.parameters.type}'; then
    SC_FITS_WHY="could not read parameters.type of $sc: $KGET_ERR"; return 2
  fi
  if [[ "$KGET_FIELD" != "gp3" && -n "$KGET_FIELD" ]]; then
    SC_FITS_WHY="type is '$KGET_FIELD', not gp3 (or unset)"; return 1
  fi
  if ! kget_field storageclass "$sc" '{.parameters.encrypted}'; then
    SC_FITS_WHY="could not read parameters.encrypted of $sc: $KGET_ERR"; return 2
  fi
  if [[ "$KGET_FIELD" != "true" ]]; then
    SC_FITS_WHY="encrypted is '${KGET_FIELD:-<unset>}', not true"; return 1
  fi
  SC_FITS_WHY=""; return 0
}

# CHOSEN_CLASS is set by the choice below; every claim is rendered with it.
CHOSEN_CLASS=""
CREATED_CLASS=no

# use_sample_class: create the sample's own non-default class from the manifest when it is
# absent (with `kubectl create`, never `kubectl apply`), or reuse it when it already exists
# and is this sample's (carries the mark) with the Auto Mode provisioner; stop otherwise.
# Sets CHOSEN_CLASS and CREATED_CLASS. Used both when the chooser falls through to the
# sample's class and when STORAGE_CLASS names the sample's class explicitly.
use_sample_class() {
  if ! kget_field storageclass "$SAMPLE_CLASS" '{.provisioner}'; then
    die "could not read StorageClass '$SAMPLE_CLASS' (the read failed). kubectl said:
$KGET_ERR
Re-run once the cluster reads cleanly."
  fi
  if [[ -z "$KGET_FIELD" ]]; then
    # Absent: create it from the manifest with `kubectl create` (never apply, which would
    # strip the default annotation from an existing same-named class created with apply).
    $KUBECTL create -f "$SAMPLE_DIR/deploy/storage-class.yaml"
    CREATED_CLASS=yes
    CHOSEN_CLASS="$SAMPLE_CLASS"
    echo "  created the sample's own non-default StorageClass '$SAMPLE_CLASS'."
    return 0
  fi
  # Exists: reuse only if it is ours (the mark) and uses the Auto Mode provisioner.
  local existing_prov="$KGET_FIELD" existing_mark
  if ! kget_field storageclass "$SAMPLE_CLASS" "{.metadata.labels.$SAMPLE_LABEL_JSONPATH}"; then
    die "could not read the labels of StorageClass '$SAMPLE_CLASS' (the read failed). kubectl said:
$KGET_ERR
Re-run once the cluster reads cleanly."
  fi
  existing_mark="$KGET_FIELD"
  if [[ "$existing_mark" != "$SAMPLE_LABEL_VALUE" ]]; then
    die "a StorageClass named '$SAMPLE_CLASS' already exists but is not marked
$SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE, so this sample did not create it. Refusing to use or
change a class another workload may own. Rename the sample's class (edit
deploy/storage-class.yaml and set STORAGE_CLASS), or remove the conflicting class if it is
yours."
  fi
  if [[ "$existing_prov" != "$WANT_PROVISIONER" ]]; then
    die "the sample's StorageClass '$SAMPLE_CLASS' exists with provisioner
'$existing_prov', not '$WANT_PROVISIONER'. StorageClass parameters are immutable, so it
cannot be patched into shape. Delete it and re-run:
  $KUBECTL delete storageclass $SAMPLE_CLASS"
  fi
  CHOSEN_CLASS="$SAMPLE_CLASS"
  echo "  reusing the sample's own StorageClass '$SAMPLE_CLASS' (marked, Auto Mode provisioner)."
}

echo "Step 1/3: choose the StorageClass"

if [[ "$STORAGE_CLASS" == "$SAMPLE_CLASS" ]]; then
  # STORAGE_CLASS explicitly names the sample's own class: create or reuse it, exactly as
  # the chooser would when it falls through. This is the branch that proves the sample's
  # class live.
  echo "  STORAGE_CLASS names the sample's own class '$SAMPLE_CLASS'."
  use_sample_class
elif [[ -n "$STORAGE_CLASS" ]]; then
  # (3) STORAGE_CLASS forces some OTHER class. Confirm it exists with the Auto Mode
  # provisioner and stop otherwise; never create a class this sample does not own.
  if ! kget_field storageclass "$STORAGE_CLASS" '{.provisioner}'; then
    die "could not read StorageClass '$STORAGE_CLASS' (the read failed, not a report that it
is missing). kubectl said:
$KGET_ERR
Re-run once the cluster reads cleanly."
  fi
  if [[ -z "$KGET_FIELD" ]]; then
    die "STORAGE_CLASS='$STORAGE_CLASS' does not exist on this cluster. Create it yourself,
set STORAGE_CLASS='$SAMPLE_CLASS' to have setup create the sample's own class, or unset
STORAGE_CLASS to let setup choose (the cluster default when it fits, otherwise the sample's
own '$SAMPLE_CLASS')."
  fi
  if [[ "$KGET_FIELD" != "$WANT_PROVISIONER" ]]; then
    die "STORAGE_CLASS='$STORAGE_CLASS' uses provisioner '$KGET_FIELD', not
'$WANT_PROVISIONER'. This sample needs the Auto Mode EBS CSI driver. Point STORAGE_CLASS at
a class that uses it, or unset it to let setup choose."
  fi
  CHOSEN_CLASS="$STORAGE_CLASS"
  echo "  STORAGE_CLASS forced '$CHOSEN_CLASS' (provisioner '$WANT_PROVISIONER'). Using it."
else
  # (1) Prefer the cluster's default class, but only when EXACTLY ONE default class exists
  # and it fits. Listing is a read like any other: a failure to list must fail closed, not
  # look like "no default".
  dflt_err="$(mktemp)"
  if default_classes="$($KUBECTL get storageclass \
        -o 'jsonpath={range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
        2>"$dflt_err")"; then
    :
  else
    dflt_msg="$(sed 's/^/  /' "$dflt_err")"; rm -f "$dflt_err"
    die "could not list the cluster's StorageClasses to find the default (the read failed).
kubectl said:
$dflt_msg
Re-run once the cluster reads cleanly."
  fi
  rm -f "$dflt_err"
  # Drop blank lines, then count.
  mapfile -t default_list < <(printf '%s\n' "$default_classes" | sed '/^$/d')
  default_count="${#default_list[@]}"

  if [[ "$default_count" -eq 1 ]]; then
    # Exactly one default: does it fit? Evaluate sc_fits in an `if` so its non-zero return
    # (1 mismatch, 2 read-failure) does not trip `set -e` before fits_rc is captured.
    if sc_fits "${default_list[0]}"; then fits_rc=0; else fits_rc=$?; fi
    if [[ $fits_rc -eq 0 ]]; then
      CHOSEN_CLASS="${default_list[0]}"
      echo "  the cluster default StorageClass '$CHOSEN_CLASS' fits (Auto Mode provisioner, gp3, encrypted). Using it and creating nothing."
    elif [[ $fits_rc -eq 2 ]]; then
      die "could not determine whether the cluster default StorageClass '${default_list[0]}'
fits ($SC_FITS_WHY). The read failed, which is not a report that it does not fit, so refusing
to fall through to creating the sample's class. Re-run once the cluster reads cleanly."
    else
      echo "  the cluster default StorageClass '${default_list[0]}' does not fit ($SC_FITS_WHY); using the sample's own '$SAMPLE_CLASS'."
      use_sample_class
    fi
  else
    # (2) No default, or more than one: use the sample's own non-default class.
    if [[ "$default_count" -eq 0 ]]; then
      echo "  the cluster has no default StorageClass; using the sample's own '$SAMPLE_CLASS'."
    else
      echo "  the cluster has $default_count default StorageClasses, so none can be chosen unambiguously; using the sample's own '$SAMPLE_CLASS'."
    fi
    use_sample_class
  fi
fi

echo "Step 2/3: create the namespace (only if absent) and apply the PVC and pod"
# Create the namespace only when it is absent, and label it as this sample's. Applying a
# manifest over an existing namespace would count as reusing it and could put this sample's
# label on a namespace another demo owns, so create it with the CLI rather than a manifest
# that hard-codes a name.
if $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "  namespace '$NAMESPACE' already exists; reusing it without relabelling it."
else
  $KUBECTL create namespace "$NAMESPACE"
  $KUBECTL label namespace "$NAMESPACE" "$SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE" --overwrite
  echo "  created namespace '$NAMESPACE' and labelled it '$SAMPLE_LABEL_KEY=$SAMPLE_LABEL_VALUE'."
fi

# Render the pod manifest with the chosen StorageClass, so the claim binds through the class
# setup chose. The placeholder is anchored to the storageClassName line so nothing else is
# touched; the manifest sets no namespace, so -n carries it.
sed "s|storageClassName: <STORAGE_CLASS>|storageClassName: $CHOSEN_CLASS|g" \
  "$SAMPLE_DIR/deploy/pod-ebs.yaml" | $KUBECTL apply -n "$NAMESPACE" -f -

echo "Step 3/3: wait for the volume to attach and the guest to boot"
# WaitForFirstConsumer means the EBS volume is provisioned and attached during this wait.
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/ebs-sandbox --timeout=5m \
  || die "pod/ebs-sandbox never became Ready. Check:
  $KUBECTL describe pod ebs-sandbox -n $NAMESPACE
  $KUBECTL get pvc ebs-sandbox-data -n $NAMESPACE"

echo
echo "ebs-sandbox is Ready with its EBS volume mounted at /data, bound through '$CHOSEN_CLASS'."
[[ "$CREATED_CLASS" == yes ]] && echo "(This run created the sample's own StorageClass '$SAMPLE_CLASS'; the clean up deletes it.)"
$KUBECTL get pvc ebs-sandbox-data -n "$NAMESPACE"
echo
echo "Assert it with:  NAMESPACE=$NAMESPACE ./scripts/test.sh"
echo "Tear down:       NAMESPACE=$NAMESPACE ./scripts/clean.sh"
