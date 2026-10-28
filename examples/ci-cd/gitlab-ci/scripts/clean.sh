#!/usr/bin/env bash
# clean.sh -- remove everything this sample created, and confirm it is gone.
#
# Usage:
#   ./scripts/clean.sh
#
# What it does, in order:
#   1. checks the context and that the namespace is this sample's, and refuses to touch one
#      that is not;
#   2. notes the EBS volume behind GitLab's claim, so its removal can be confirmed later;
#   3. deletes the runner manager first, so no new job pod is created while the rest goes;
#   4. deletes the ordinary comparison pod by its exact name;
#   5. deletes the namespace, which takes GitLab, the runner, both Secrets, the claim and any
#      job pod with it;
#   6. confirms the namespace is gone, that no job pod is left and that the EBS volume was
#      deleted. Anything it could not confirm is reported, and the script exits non-zero.
#
# What it does NOT remove: nothing, because this sample installs nothing shared and creates
# no cluster-wide object, no IAM role and no Pod Identity association. The EBS volume is the
# only thing it puts in the account, and it belongs to GitLab's claim.
set -uo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

ORDINARY_POD=gitlab-ci-ordinary
JOB_POD_SELECTOR="app=gitlab-ci-job"

# Collected rather than fatal, so one thing that cannot be removed does not stop the rest.
problems=()
problem() { printf '  ! %s\n' "$*"; problems+=("$*"); }

# ---------------------------------------------------------------------------
say "1/6 context and namespace"
# ---------------------------------------------------------------------------
need_tools kubectl
"${KCTL[@]}" version -o json >/dev/null 2>&1 \
  || die "cannot reach the cluster with context '$KUBE_CONTEXT'."
require_namespace
echo "  context '$KUBE_CONTEXT', namespace '$NAMESPACE' is labelled $LABEL_KEY=$LABEL_VALUE."

# ---------------------------------------------------------------------------
say "2/6 the EBS volume behind GitLab's claim"
# ---------------------------------------------------------------------------
# Read now, while the claim still exists: after the namespace goes there is nothing left to
# read the volume's id from, and "no claim" would then look like "no volume".
ebs_volume=""
pv_name=""
if ! pv_name="$("${KCTL[@]}" get pvc gitlab-data -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"; then
  problem "could not read claim gitlab-data in '$NAMESPACE', so its EBS volume cannot be identified or confirmed removed."
elif [[ -z "$pv_name" ]]; then
  echo "  claim gitlab-data is not bound to a volume, so there is no EBS volume to confirm."
else
  ebs_volume="$("${KCTL[@]}" get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)"
  if [[ -z "$ebs_volume" ]]; then
    problem "claim gitlab-data is bound to $pv_name but no CSI volume handle could be read from it, so its EBS volume cannot be confirmed removed."
  else
    echo "  claim gitlab-data is EBS volume $ebs_volume, reclaim policy $("${KCTL[@]}" get pv "$pv_name" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)."
  fi
fi

# ---------------------------------------------------------------------------
say "3/6 the runner manager"
# ---------------------------------------------------------------------------
# First, so the runner stops taking jobs and creating job pods while the rest is removed.
"${KCTL[@]}" delete deployment gitlab-runner -n "$NAMESPACE" --ignore-not-found --wait \
  || problem "could not delete Deployment gitlab-runner in '$NAMESPACE'."
echo "  the runner manager is gone, so no new job pod will be created."

# ---------------------------------------------------------------------------
say "4/6 the ordinary comparison pod"
# ---------------------------------------------------------------------------
# By its exact name. Never by a label selector: one meant for this sample's helper pod has
# matched another demo's pod on a shared cluster.
"${KCTL[@]}" delete pod "$ORDINARY_POD" -n "$NAMESPACE" --ignore-not-found --wait=false \
  || problem "could not delete pod/$ORDINARY_POD in '$NAMESPACE'."

# ---------------------------------------------------------------------------
say "5/6 the namespace"
# ---------------------------------------------------------------------------
# The namespace carries this sample's label, checked above, so everything inside it is this
# sample's: GitLab, the runner's ServiceAccount, Role and RoleBinding, both Secrets, the
# claim, and any job pod still running.
echo "  deleting namespace '$NAMESPACE'. The volume is detached as GitLab's pod goes, so"
echo "  this takes a minute or two."
"${KCTL[@]}" delete namespace "$NAMESPACE" --wait --timeout=600s \
  || problem "could not delete namespace '$NAMESPACE'. Anything still in it is still there."

# ---------------------------------------------------------------------------
say "6/6 confirming"
# ---------------------------------------------------------------------------
ns_left=""
if ! ns_left="$("${KCTL[@]}" get namespace "$NAMESPACE" -o name --ignore-not-found 2>/dev/null)"; then
  problem "could not read namespace '$NAMESPACE' to confirm it is gone. A failed read is not a report that it was removed."
elif [[ -n "$ns_left" ]]; then
  problem "namespace '$NAMESPACE' still exists."
else
  echo "  namespace '$NAMESPACE' is gone."
fi

# A job pod of this sample's cannot outlive its namespace, so this looks across the cluster:
# the point is to catch one the runner had created somewhere else, which would mean
# `namespace` in config.toml did not match the namespace this script was given.
jobs_left=""
if ! jobs_left="$("${KCTL[@]}" get pod -A -l "$JOB_POD_SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)"; then
  problem "could not list pods labelled $JOB_POD_SELECTOR, so it cannot be confirmed that no job pod is left."
elif [[ -n "$(printf '%s' "$jobs_left" | tr -d '[:space:]')" ]]; then
  problem "job pods labelled $JOB_POD_SELECTOR are still running: $(tr '\n' ' ' <<<"$jobs_left")"
else
  echo "  no pod labelled $JOB_POD_SELECTOR is left anywhere on the cluster."
fi

if [[ -n "$ebs_volume" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    problem "the AWS CLI is not on PATH, so it cannot be confirmed that EBS volume $ebs_volume was deleted. Check it yourself: aws ec2 describe-volumes --volume-ids $ebs_volume"
  else
    # The Region comes from the cluster's own nodes rather than from .env, so it cannot
    # disagree with the cluster the rest of this script ran against.
    region="$("${KCTL[@]}" get node -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null)"
    if [[ -z "$region" ]]; then
      problem "could not read the cluster's Region from its nodes, so EBS volume $ebs_volume cannot be confirmed deleted."
    else
      echo "  waiting for EBS volume $ebs_volume to go, in $region."
      gone=no
      for _ in $(seq 1 30); do
        out="$(aws ec2 describe-volumes --region "$region" --volume-ids "$ebs_volume" 2>&1)"
        rc=$?
        if (( rc != 0 )); then
          if grep -q 'InvalidVolume.NotFound' <<<"$out"; then gone=yes; break; fi
          # Any other failure is a failed lookup, not a deleted volume.
          problem "could not look up EBS volume $ebs_volume in $region: $(head -n 1 <<<"$out")"
          gone=unknown
          break
        fi
        sleep 10
      done
      case "$gone" in
        yes)     echo "  EBS volume $ebs_volume is gone." ;;
        unknown) ;;  # already reported
        *)       problem "EBS volume $ebs_volume still exists in $region five minutes after its claim was deleted. Delete it yourself if you do not need it: aws ec2 delete-volume --region $region --volume-id $ebs_volume" ;;
      esac
    fi
  fi
fi

echo
if (( ${#problems[@]} > 0 )); then
  printf 'clean up INCOMPLETE: %d thing(s) could not be removed or confirmed.\n' "${#problems[@]}" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  exit 1
fi
cat <<EOF
clean up complete. Removed: namespace $NAMESPACE and everything in it (GitLab, its claim and
its volume, the runner manager and its RBAC, both Secrets, every job pod), and the ordinary
comparison pod.

Nothing is left behind: this sample installs nothing shared, changes no cluster-wide setting,
and creates no IAM role, Pod Identity association or ECR repository. To remove the sandbox
runtime class and the cluster itself, see the Hello sandbox clean up.
EOF
