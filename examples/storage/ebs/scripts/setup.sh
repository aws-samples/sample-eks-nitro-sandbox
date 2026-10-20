#!/usr/bin/env bash
# Set up the EBS sample: check the StorageClass the reader applied, then create the pod
# and its claim.
#
#   ./scripts/setup.sh
#
# This script never creates, changes or deletes a StorageClass. A StorageClass is a
# cluster-wide object, so the reader applies deploy/storage-class.yaml once per cluster
# (the page's Step 1); this script only confirms it is there with the Auto Mode EBS
# provisioner, and stops with the apply command when it is not. It then applies the PVC
# and the pod from deploy/pod-ebs.yaml and waits for the volume to attach and the guest to
# boot. Idempotent: re-running it reuses the namespace, the class and the claim.
#
# Overridable (defaults match the page):
#   NAMESPACE      the namespace to run in            (default nitro-ebs-sample)
#   STORAGE_CLASS  the StorageClass to bind against   (default auto-ebs-sc)
#   KUBECTL        the kubectl command, e.g.          (default "kubectl")
#                  KUBECTL="kubectl --context my-cluster"
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-nitro-ebs-sample}"
STORAGE_CLASS="${STORAGE_CLASS:-auto-ebs-sc}"
KUBECTL="${KUBECTL:-kubectl}"

# The provisioner that marks the Auto Mode EBS CSI driver. The whole point of the check
# below is that a class named auto-ebs-sc created by someone else can name a different
# provisioner (for example the in-tree kubernetes.io/aws-ebs), which would provision
# something this sample then describes wrongly.
WANT_PROVISIONER="ebs.csi.eks.amazonaws.com"
# A label that marks the namespace as this sample's, so the clean up can tell a namespace
# it created from one that was already there and belongs to another demo.
SAMPLE_LABEL="app.kubernetes.io/part-of=nitro-sandbox-ebs"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'$KUBECTL' is not on PATH"

apply_hint="Apply the StorageClass once per cluster, then re-run this script:
  $KUBECTL apply -f $SAMPLE_DIR/deploy/storage-class.yaml"

echo "Step 1/3: confirm the '$STORAGE_CLASS' StorageClass exists with the Auto Mode EBS provisioner"
# Does the class exist at all? Distinguish three outcomes structurally rather than by
# reading human-readable stderr: `get --ignore-not-found -o name` prints the object's name
# when it exists, prints nothing and exits 0 when it is NotFound, and exits non-zero only on
# a real read failure (throttle, apiserver restart, RBAC denial). So: non-zero means the
# read failed (fail closed), empty output means absent, non-empty means it exists.
sc_get_err="$(mktemp)"
# Guard the assignment with `if`: under `set -e` a bare `sc_name="$(... )"` whose command
# substitution exits non-zero aborts the script at this line, so the fail-closed handling
# below would never run on exactly the read failure it exists to catch.
if sc_name="$($KUBECTL get storageclass "$STORAGE_CLASS" --ignore-not-found -o name 2>"$sc_get_err")"; then
  sc_get_rc=0
else
  sc_get_rc=$?
fi
sc_msg="$(sed 's/^/  /' "$sc_get_err")"; rm -f "$sc_get_err"
if [[ $sc_get_rc -ne 0 ]]; then
  # Fail closed: do not fall through and provision against a class whose state is unknown.
  die "could not read StorageClass '$STORAGE_CLASS' (the read itself failed, which is not
a report that it is missing). kubectl said:
$sc_msg
Re-run once the cluster reads cleanly."
fi

if [[ -z "$sc_name" ]]; then
  die "StorageClass '$STORAGE_CLASS' does not exist on this cluster.
$apply_hint"
fi

# The class exists. Read its provisioner, keeping the three outcomes apart again: a
# value, an absent field, and a failed read. Command substitution runs in a subshell and
# swallows the exit status, so capture stderr and the status explicitly. stderr is kept
# separate (not folded in with 2>&1): kubectl writes deprecation and kubeconfig warnings
# to stderr even on a successful read, and folding them in would leave the comparison
# looking at "Warning: ...ebs.csi.eks.amazonaws.com" instead of the value.
prov_err="$(mktemp)"
if ! got_provisioner="$($KUBECTL get storageclass "$STORAGE_CLASS" \
      -o jsonpath='{.provisioner}' 2>"$prov_err")"; then
  prov_msg="$(sed 's/^/  /' "$prov_err")"; rm -f "$prov_err"
  die "could not read the provisioner of StorageClass '$STORAGE_CLASS' (the read failed,
which is not a report of its value). kubectl said:
$prov_msg
Re-run once the cluster reads cleanly."
fi
rm -f "$prov_err"

if [[ "$got_provisioner" != "$WANT_PROVISIONER" ]]; then
  die "StorageClass '$STORAGE_CLASS' uses provisioner '${got_provisioner:-<unset>}', not
'$WANT_PROVISIONER'. This sample needs the Auto Mode EBS CSI driver. Either apply this
sample's class under a name that is free, or point STORAGE_CLASS at a class that uses the
Auto Mode provisioner.
$apply_hint"
fi
echo "  '$STORAGE_CLASS' exists with provisioner '$got_provisioner'. Leaving it as-is."

echo "Step 2/3: create the namespace (only if absent) and apply the PVC and pod"
# Create the namespace only when it is absent, and label it as this sample's. Applying a
# manifest over an existing namespace would count as reusing it and could put this
# sample's label on a namespace another demo owns, so create it with the CLI rather than
# a manifest that hard-codes a name.
if $KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "  namespace '$NAMESPACE' already exists; reusing it without relabelling it."
else
  $KUBECTL create namespace "$NAMESPACE"
  $KUBECTL label namespace "$NAMESPACE" "$SAMPLE_LABEL" --overwrite
  echo "  created namespace '$NAMESPACE' and labelled it '$SAMPLE_LABEL'."
fi

# Render the pod manifest with the chosen StorageClass name so an overridden name reaches
# the claim, and never apply a manifest that hard-codes the default. The manifest sets no
# namespace, so -n carries it.
sed "s|storageClassName: auto-ebs-sc|storageClassName: $STORAGE_CLASS|g" \
  "$SAMPLE_DIR/deploy/pod-ebs.yaml" | $KUBECTL apply -n "$NAMESPACE" -f -

echo "Step 3/3: wait for the volume to attach and the guest to boot"
# WaitForFirstConsumer means the EBS volume is provisioned and attached during this wait.
$KUBECTL wait -n "$NAMESPACE" --for=condition=Ready pod/ebs-sandbox --timeout=5m \
  || die "pod/ebs-sandbox never became Ready. Check:
  $KUBECTL describe pod ebs-sandbox -n $NAMESPACE
  $KUBECTL get pvc ebs-sandbox-data -n $NAMESPACE"

echo
echo "ebs-sandbox is Ready with its EBS volume mounted at /data."
$KUBECTL get pvc ebs-sandbox-data -n "$NAMESPACE"
echo
echo "Assert it with:  NAMESPACE=$NAMESPACE ./scripts/test.sh"
echo "Tear down:       NAMESPACE=$NAMESPACE ./scripts/clean.sh"
