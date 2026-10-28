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
# A claim that is ABSENT and a read that FAILED are three different answers from two, and
# they are kept apart at every hop below. A clean up that runs after a setup that stopped
# before GitLab was applied has no claim at all, and that is nothing to confirm, not a
# failure; a read that came back empty for any other reason is a failure.
ebs_volume=""
pvc_present=""
pv_name=""
if ! pvc_present="$("${KCTL[@]}" get pvc gitlab-data -n "$NAMESPACE" -o name --ignore-not-found 2>/dev/null)"; then
  problem "could not read claim gitlab-data in '$NAMESPACE', so its EBS volume cannot be identified or confirmed removed. That is a failed read, not a report that the claim is absent."
elif [[ -z "$pvc_present" ]]; then
  echo "  there is no gitlab-data claim in '$NAMESPACE', so no EBS volume was ever provisioned for it."
elif ! pv_name="$("${KCTL[@]}" get pvc gitlab-data -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"; then
  problem "could not read the bound volume of claim gitlab-data in '$NAMESPACE', so its EBS volume cannot be identified or confirmed removed."
elif [[ -z "$pv_name" ]]; then
  # The claim exists but records no bound volume. That is NOT the same as "no volume was
  # provisioned": provisioning and binding are asynchronous, so the CSI driver can already
  # have created an EBS volume that the claim has not yet recorded. This branch used to print
  # "there is no EBS volume to confirm" and let the clean up finish, which would have reported
  # success while leaving a volume nobody could name. It is a failure to identify, so it is a
  # problem.
  problem "claim gitlab-data in '$NAMESPACE' records no bound volume, so its EBS volume cannot be identified. That is not a report that none was provisioned: binding is asynchronous, so a volume may already exist. Look for one and delete it if it is not wanted: aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$NAMESPACE"
elif ! ebs_volume="$("${KCTL[@]}" get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)"; then
  problem "could not read PersistentVolume $pv_name, so the EBS volume behind claim gitlab-data cannot be confirmed removed."
elif [[ -z "$ebs_volume" ]]; then
  problem "claim gitlab-data is bound to $pv_name, but that volume has no CSI volume handle, so the EBS volume behind it cannot be confirmed removed. A volume provisioned by something other than a CSI driver does this."
else
  reclaim="$("${KCTL[@]}" get pv "$pv_name" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)"
  echo "  claim gitlab-data is EBS volume $ebs_volume, reclaim policy ${reclaim:-could not be read}."
  # Retain means the volume outlives the claim on purpose, and the check below would then
  # report a volume that is working as configured. Say so rather than fail it.
  if [[ "$reclaim" == Retain ]]; then
    problem "PersistentVolume $pv_name has reclaim policy Retain, so EBS volume $ebs_volume is kept when the claim goes. Delete it yourself if you do not need it: aws ec2 delete-volume --volume-id $ebs_volume"
    ebs_volume=""
  fi
fi

# ---------------------------------------------------------------------------
say "3/6 the runner manager"
# ---------------------------------------------------------------------------
# First, so the runner stops taking jobs and creating job pods while the rest is removed.
#
# The success line is inside the successful branch. It used to come after the `||`, so a
# delete that failed was reported as a problem and then immediately followed by "the runner
# manager is gone": the namespace delete below may well remove it, but it has not happened
# yet, and a clean up must not say a thing is gone that it did not see go.
if "${KCTL[@]}" delete deployment gitlab-runner -n "$NAMESPACE" --ignore-not-found --wait; then
  echo "  the runner manager is gone, so no new job pod will be created."
else
  problem "could not delete Deployment gitlab-runner in '$NAMESPACE', so it may still be creating job pods while the rest of this clean up runs."
fi

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
  # There is deliberately no separate "aws is not on PATH" branch. An AWS CLI that is not
  # there makes the call below exit non-zero with a message that is not InvalidVolume.NotFound,
  # which is the same answer as any other failed lookup: could not determine, never gone. A
  # branch of its own could not be produced on an EKS cluster anyway, because the kubeconfig's
  # own credential plugin is `aws`: with it off PATH, kubectl cannot authenticate and this
  # script stops at its first call.
  #
  # The Region comes from the cluster's own nodes rather than from .env, so it cannot disagree
  # with the cluster the rest of this script ran against.
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
        # -F, so the dot is a dot and not "any character".
        if grep -qF 'InvalidVolume.NotFound' <<<"$out"; then gone=yes; break; fi
        # Any other failure is a failed lookup, not a deleted volume. That covers an AWS CLI
        # that is missing, one that cannot authenticate, and a call that is denied.
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

echo
if (( ${#problems[@]} > 0 )); then
  printf 'clean up INCOMPLETE: %d thing(s) could not be removed or confirmed.\n' "${#problems[@]}" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  exit 1
fi
cat <<EOF
clean up complete. Removed: namespace $NAMESPACE and whatever was in it, which for a full run
of this sample is GitLab, its claim and its EBS volume, the runner manager with its
ServiceAccount, Role and RoleBinding, the root-password and runner-config Secrets, and any
job pod; plus the ordinary comparison pod, by its exact name.

Nothing is left behind: this sample installs nothing shared, changes no cluster-wide setting,
and creates no IAM role, Pod Identity association or ECR repository. To remove the sandbox
runtime class and the cluster itself, see the Hello sandbox clean up.
EOF
