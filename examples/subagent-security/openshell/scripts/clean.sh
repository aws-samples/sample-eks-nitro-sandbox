#!/usr/bin/env bash
# clean.sh -- remove what this sample created, and only that.
#
# Usage:
#   ./scripts/clean.sh                      # the cluster objects and the namespace
#   ./scripts/clean.sh --delete-aws         # also the bucket, the IAM role and the images
#
# It reads the same run record setup.sh wrote, so there is nothing to set again.
#
# It does not stop at the first failure. A lookup that fails means "could not determine",
# which is a failure and never "already gone": anything it could not delete or confirm is
# named at the end and makes it exit non-zero. It touches a resource only when that
# resource is provably this sample's, and leaves anything else alone. What counts as proof
# differs by resource, and every delete below is one of these four:
#
#   * this sample's ManagedBy tag or its managed-by label: the namespace, the two
#     cluster-scoped admission objects, the sample's own StorageClass (only once no claim
#     names it), the IAM role, the bucket and the ECR repositories;
#   * sitting inside a namespace that carries that label: everything the namespace delete
#     takes with it, including both sandbox pods and the workspace claims;
#   * the chart's two cluster-scoped RBAC objects, which never carry this sample's label
#     because the chart creates them: Helm's annotations naming this release and this
#     namespace, and the name the chart derives, both required;
#   * the EKS Pod Identity association, which carries no label this script can read: its
#     cluster, namespace and service account, and a roleArn equal to the one in the run
#     record. A different role on that triple means something else wrote it, and it is
#     left alone.
#
# One thing it removes without an ownership test: the local CLI configuration directories
# under this repository's tmp/, which this sample's own scripts created at a path only they
# use, and which hold the operator's gateway client certificate and key.
#
# It never removes a shared install or a cluster-wide setting. This sample has two of
# those, the RuntimeClass approval label and the agent-sandbox controller, and both are
# left in place with the command to undo them printed at the end.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="subagent-security-openshell"
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"

delete_aws=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws) delete_aws=true ;;
    --help|-h) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1/11 the run record, the context and the account
# ---------------------------------------------------------------------------

# Unlike the other samples' clean ups, this one refuses to run without the record. It
# deletes cluster-scoped objects by name and an EKS Pod Identity association, and a
# default-guessed name for either could name another demo's object.
[[ -f "$STATE_FILE" ]] ||
  die "there is no run record at $STATE_FILE, so this script cannot tell which objects are this sample's. It deletes cluster-scoped objects by exact name, so it will not guess them. If setup.sh ran and the record is gone, remove the objects by hand."
set -a; . "$STATE_FILE"; set +a
if [[ -f "$SAMPLE_DIR/.env" ]]; then set -a; . "$SAMPLE_DIR/.env"; set +a; fi

NAMESPACE="${NAMESPACE:-}"
RELEASE="${RELEASE:-}"
ADAPTER="${ADAPTER:-}"
AWS_REGION="${AWS_REGION:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
ROLE_ARN="${ROLE_ARN:-}"
ROLE_NAME="${ROLE_NAME:-}"
RUNTIME_CLASS="isolated-sandbox"
APPROVAL_LABEL="openshell.ai/sandbox-attachable"
SERVICE_ACCOUNT="analyst"

[[ -n "$NAMESPACE" ]] || die "the run record names no NAMESPACE; nothing was deleted"
[[ -n "$RELEASE" ]] || die "the run record names no RELEASE, so the gateway's Helm release cannot be identified; nothing was deleted"

# Without a Region, a regional lookup runs in whichever Region the environment happens to
# name, and comes back with the service's own not-found exception. This script would then
# report resources as "already gone" and exit 0 while they are still there.
[[ -n "$AWS_REGION" ]] ||
  die "AWS_REGION is not set, so a lookup could run in the wrong Region and report a resource that still exists as already gone. Set it in .env, or run ./scripts/setup.sh first so the run record has it."
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

for c in aws jq kubectl helm; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

# Every kubectl call names the context rather than selecting it, so a `kubectl config
# use-context` in another session on this shared machine cannot redirect the deletes.
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

# See analyst-lib.sh for why this returns 2 rather than exiting.
lookup() {
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/analyst-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/analyst-err.XXXXXX")" || return 2
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$out"; rm -f "$out" "$err"; return 0; fi
  if grep -Fq "$notfound" "$err"; then rm -f "$out" "$err"; return 1; fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with $notfound, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

say "1/11 the run record, the context and the account"

echo "  context:   ${KUBE_CONTEXT:-<whatever kubectl is set to>}"
echo "  namespace: $NAMESPACE"
echo "  region:    $AWS_REGION"

# The run record names an account in ROLE_ARN. Credentials for a different account would
# make every AWS lookup below answer about the wrong account: an untagged resource would
# read as "not this sample's" and a missing one as "already gone", and the script would
# exit 0 having deleted nothing.
[[ -n "$ROLE_ARN" ]] ||
  die "the run record names no ROLE_ARN, so the account this sample's resources are in cannot be confirmed; nothing was deleted"
record_account="$(cut -d: -f5 <<<"$ROLE_ARN")"
[[ -n "$record_account" ]] ||
  die "could not read an account id out of ROLE_ARN ($ROLE_ARN); nothing was deleted"
caller_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[[ -n "$caller_account" && "$caller_account" != "None" ]] ||
  die "could not read the AWS account these credentials belong to, so it is unknown whether they are the account this sample's resources are in; nothing was deleted"
[[ "$caller_account" == "$record_account" ]] ||
  die "these credentials are for account $caller_account and this sample's resources are in $record_account; nothing was deleted. Switch credentials and run this again."
echo "  account:   $caller_account"

# ---------------------------------------------------------------------------
# 2/11 whose namespace it is
# ---------------------------------------------------------------------------

say "2/11 whose namespace $NAMESPACE is"

# Four states, and only one of them lets anything inside the namespace be deleted.
ns_state=unknown
if ns_json="$(kc get namespace "$NAMESPACE" --ignore-not-found -o json 2>/dev/null)"; then
  if [[ -z "$ns_json" ]]; then
    ns_state=absent
  elif [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$ns_json")" == "$SAMPLE" ]]; then
    ns_state=owned
  else
    ns_state=foreign
  fi
fi
case "$ns_state" in
  absent)  echo "  namespace $NAMESPACE is already gone." ;;
  owned)   echo "  namespace $NAMESPACE carries app.kubernetes.io/managed-by=$SAMPLE." ;;
  foreign) note_fail "namespace $NAMESPACE is not this sample's (its managed-by label is not '$SAMPLE'); deleted nothing in it" ;;
  unknown) note_fail "could not determine whether namespace $NAMESPACE exists or whose it is; deleted nothing in it" ;;
esac

# ---------------------------------------------------------------------------
# 3/11 the sandboxes, the gateway and the namespace
# ---------------------------------------------------------------------------

say "3/11 the sandboxes, the OpenShell gateway and the namespace"

if [[ "$ns_state" == absent ]]; then
  # Nothing to delete and nothing skipped. A second clean up, or one after the namespace
  # has already gone, is a success: treating it as incomplete would make the script report
  # a failure for work that is done, and a reader would stop believing its exit code.
  echo "  nothing to do: the namespace and everything in it are already gone."
elif [[ "$ns_state" != owned ]]; then
  echo "  skipped: the namespace is not confirmed as this sample's."
  note_fail "the sandboxes, the gateway release and the namespace were left in place because $NAMESPACE is not confirmed as this sample's"
else
  # The sandboxes go first and by name, not with a label selector. Each one holds a Nitro
  # sandbox pod, which is capacity other demos on this cluster share, and the agent-sandbox
  # controller is what removes the pods when its Sandbox object goes.
  #
  # Inside this sample's own namespace the namespace label is the ownership check, so there
  # is no second per-object check here: every Sandbox in this namespace was created by this
  # sample's gateway.
  if sandboxes="$(kc get sandboxes.agents.x-k8s.io -n "$NAMESPACE" \
      --ignore-not-found -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"; then
    if [[ -z "$sandboxes" ]]; then
      echo "  no Sandbox objects left in $NAMESPACE."
    else
      while read -r sandbox; do
        [[ -n "$sandbox" ]] || continue
        kc delete sandboxes.agents.x-k8s.io "$sandbox" -n "$NAMESPACE" \
          --ignore-not-found --wait=true --timeout=5m >/dev/null ||
          note_fail "could not delete the Sandbox $sandbox in $NAMESPACE"
        echo "  deleted the Sandbox $sandbox."
      done <<<"$sandboxes"
    fi
  else
    note_fail "could not list the Sandbox objects in $NAMESPACE, so the sandbox pods they own may still be running"
  fi

  # helm uninstall rather than deleting the objects: the release's own record goes with it,
  # so a later install of the same name does not meet a release Helm thinks it owns.
  # `helm status` exits non-zero both for a release that is absent and for a Helm, context
  # or API error, so its exit code alone cannot tell those apart, and treating them alike
  # would report a release that is still installed as already gone. `helm list` answers the
  # question directly: a listing this sample can parse means the lookup worked, and the
  # release is present or absent within it.
  # --filter and --max 0 together are what make this answer about this release. `helm
  # status` exits non-zero both for an absent release and for a Helm, context or API
  # error, so its exit code alone cannot tell those apart and a still-installed gateway
  # would read as already gone. A bare `helm list` would not do either: it returns at most
  # 256 releases by default, so on a busy namespace the one being looked for can simply be
  # missing from the page and read as absent. --filter is a regular expression, anchored
  # here, and --max 0 removes the limit.
  releases=""
  if releases="$(helm list -n "$NAMESPACE" \
      ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} \
      --filter "^${RELEASE}\$" --max 0 -o json 2>/dev/null)" &&
     present="$(jq -r --arg r "$RELEASE" '[.[] | select(.name == $r)] | length' \
       <<<"$releases" 2>/dev/null)" && [[ -n "$present" ]]; then
    if [[ "$present" == 0 ]]; then
      echo "  no Helm release $RELEASE in $NAMESPACE; already gone."
    elif helm uninstall "$RELEASE" -n "$NAMESPACE" \
        ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} --wait --timeout 5m >/dev/null; then
      echo "  uninstalled the Helm release $RELEASE."
    else
      # Not an "uninstalled" line: an uninstall that failed left the release in place.
      note_fail "could not uninstall the Helm release $RELEASE from $NAMESPACE"
    fi
  else
    note_fail "could not list the Helm releases in $NAMESPACE, so it is unknown whether the gateway release $RELEASE is still installed; left it alone"
  fi

  # The namespace takes the rest with it: the supervisor pods, the model bridge, the
  # supplier API, the workspace claims, the Services, the ServiceAccount and every Secret
  # this run created, including the gateway's key-encryption key and the supplier key.
  kc delete namespace "$NAMESPACE" --wait=true --timeout=10m >/dev/null ||
    note_fail "could not delete namespace $NAMESPACE"
  if still="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then
    if [[ -z "$still" ]]; then
      echo "  deleted namespace $NAMESPACE and everything in it."
    else
      note_fail "namespace $NAMESPACE is still present after the delete"
    fi
  else
    note_fail "could not confirm namespace $NAMESPACE was deleted"
  fi
fi

# ---------------------------------------------------------------------------
# 4/11 the claims' volumes and the sample's own StorageClass
# ---------------------------------------------------------------------------

say "4/11 the volumes and the sample's own StorageClass"

# The namespace delete took the claims, and the CSI driver deletes each claim's
# PersistentVolume, and its EBS volume, after it. The class goes only after that, only
# when it carries this sample's mark, and only when no claim anywhere still names it: a
# second copy of this sample under another NAMESPACE uses the same class.
SAMPLE_STORAGE_CLASS="$SAMPLE-gp3"
if [[ "$failed" != 0 ]]; then
  note_fail "left the volumes and storageclass/$SAMPLE_STORAGE_CLASS unchecked, because something above is unconfirmed and a claim of this sample's may still name the class"
else
  pvs=""
  for _ in {1..30}; do
    pvs="$(kc get pv -o json 2>/dev/null | jq -r --arg ns "$NAMESPACE" \
      '.items[] | select(.spec.claimRef.namespace == $ns) | .metadata.name')" || {
      pvs=unknown; break; }
    [[ -n "$pvs" ]] || break
    sleep 10
  done
  case "$pvs" in
    "") echo "  no PersistentVolume is left for a claim in $NAMESPACE, so their EBS volumes are deleted." ;;
    unknown) note_fail "could not list the PersistentVolumes, so it is unknown whether this sample's EBS volumes are deleted" ;;
    *) note_fail "the PersistentVolumes $(paste -sd ' ' <<<"$pvs") of claims in $NAMESPACE are still there after 5 minutes" ;;
  esac

  if [[ -n "$pvs" ]]; then
    echo "  left storageclass/$SAMPLE_STORAGE_CLASS in place while those volumes are unconfirmed."
  elif ! sc_json="$(kc get storageclass "$SAMPLE_STORAGE_CLASS" --ignore-not-found -o json 2>/dev/null)"; then
    note_fail "could not determine whether storageclass/$SAMPLE_STORAGE_CLASS exists; left it alone"
  elif [[ -z "$sc_json" ]]; then
    echo "  storageclass/$SAMPLE_STORAGE_CLASS is not there: setup used another class, or it is already gone."
  elif [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$sc_json")" != "$SAMPLE" ]]; then
    note_fail "storageclass/$SAMPLE_STORAGE_CLASS does not carry app.kubernetes.io/managed-by=$SAMPLE; left it alone"
  elif ! claims="$(kc get pvc -A -o json 2>/dev/null | jq -r --arg sc "$SAMPLE_STORAGE_CLASS" \
      '.items[] | select(.spec.storageClassName == $sc) | "\(.metadata.namespace)/\(.metadata.name)"')"; then
    note_fail "could not list the claims on this cluster, so it is unknown whether one still names storageclass/$SAMPLE_STORAGE_CLASS; left it in place"
  elif [[ -n "$claims" ]]; then
    note_fail "storageclass/$SAMPLE_STORAGE_CLASS is still named by the claims $(paste -sd ' ' <<<"$claims"); left it in place"
  else
    kc delete storageclass "$SAMPLE_STORAGE_CLASS" --ignore-not-found --wait=true --timeout=2m >/dev/null ||
      note_fail "could not delete storageclass/$SAMPLE_STORAGE_CLASS"
    if ! still="$(kc get storageclass "$SAMPLE_STORAGE_CLASS" --ignore-not-found -o name 2>/dev/null)"; then
      note_fail "could not confirm storageclass/$SAMPLE_STORAGE_CLASS was deleted"
    elif [[ -n "$still" ]]; then
      note_fail "storageclass/$SAMPLE_STORAGE_CLASS is still present after the delete"
    else
      echo "  deleted storageclass/$SAMPLE_STORAGE_CLASS, which carried this sample's managed-by label."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5/11 the cluster-scoped admission adapter
# ---------------------------------------------------------------------------

say "5/11 the admission adapter"

# By exact name and only with this sample's label. A label selector is not used here on
# purpose: these are cluster-scoped objects, and a selector that matched another gateway's
# adapter would delete admission policy other people's pods depend on.
if [[ -z "$ADAPTER" ]]; then
  note_fail "the run record names no ADAPTER, so the MutatingAdmissionPolicy and its binding were left in place"
else
  for kind in mutatingadmissionpolicybinding mutatingadmissionpolicy; do
    owner=""
    if ! got="$(kc get "$kind" "$ADAPTER" --ignore-not-found -o json 2>/dev/null)"; then
      note_fail "could not determine whether the $kind $ADAPTER exists; left it alone"
      continue
    fi
    if [[ -z "$got" ]]; then
      echo "  the $kind $ADAPTER is already gone."
      continue
    fi
    owner="$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$got")"
    if [[ "$owner" != "$SAMPLE" ]]; then
      note_fail "the $kind $ADAPTER does not carry app.kubernetes.io/managed-by=$SAMPLE (found '$owner'); left it alone"
      continue
    fi
    kc delete "$kind" "$ADAPTER" --ignore-not-found --wait=true --timeout=2m >/dev/null ||
      note_fail "could not delete the $kind $ADAPTER"
    if still="$(kc get "$kind" "$ADAPTER" --ignore-not-found -o name 2>/dev/null)"; then
      if [[ -z "$still" ]]; then
        echo "  deleted the $kind $ADAPTER."
      else
        note_fail "the $kind $ADAPTER is still present after the delete"
      fi
    else
      note_fail "could not confirm the $kind $ADAPTER was deleted"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 6/11 the chart's cluster-scoped RBAC
# ---------------------------------------------------------------------------

say "6/11 the ClusterRole and ClusterRoleBinding the chart created"

# helm uninstall normally takes these with it. They are checked anyway because a failed
# uninstall leaves them, and a cluster-scoped object left behind would be adopted by the
# next install of the same release name.
#
# Two conditions, and neither is sufficient alone.
#
# Helm's annotations name both the release and its namespace, which rules out another
# OpenShell gateway's RBAC in another namespace. But an annotation is ordinary mutable
# metadata, not proof of who created an object: anything at all could carry those two
# keys, and deleting on them alone would delete it. So the name has to match the one the
# chart actually derives as well, which is the release name plus a fixed suffix.
#
# If the chart ever changes that naming, this stops matching and says so rather than
# widening: an object left behind and reported is recoverable, one deleted because the
# check was loose is not.
EXPECTED_RBAC="$RELEASE-node-reader-$NAMESPACE"
for kind in clusterrolebinding clusterrole; do
  if ! got="$(kc get "$kind" -o json 2>/dev/null)"; then
    note_fail "could not list the cluster $kind objects, so it is unknown whether the chart's are still there"
    continue
  fi
  annotated="$(jq -r --arg r "$RELEASE" --arg ns "$NAMESPACE" '
    .items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == $r)
    | select(.metadata.annotations["meta.helm.sh/release-namespace"] == $ns)
    | .metadata.name' <<<"$got")"
  if [[ -z "$annotated" ]]; then
    echo "  no $kind is annotated for the release $RELEASE in $NAMESPACE."
    continue
  fi
  while read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" != "$EXPECTED_RBAC" ]]; then
      note_fail "the $kind $name carries this release's Helm annotations but is not the name the chart derives ($EXPECTED_RBAC), so it is not provably this sample's; left it alone"
      continue
    fi
    kc delete "$kind" "$name" --ignore-not-found --wait=true --timeout=2m >/dev/null ||
      note_fail "could not delete the $kind $name"
    echo "  deleted the $kind $name."
  done <<<"$annotated"
done

# ---------------------------------------------------------------------------
# 7/11 the EKS Pod Identity association
# ---------------------------------------------------------------------------

say "7/11 the EKS Pod Identity association"

if [[ -z "$CLUSTER_NAME" ]]; then
  note_fail "CLUSTER_NAME is not set, so the Pod Identity association could not be looked up or removed"
else
  assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --output json 2>/dev/null)"
  if [[ -z "$assoc" ]]; then
    note_fail "could not list the Pod Identity associations for $NAMESPACE/$SERVICE_ACCOUNT on $CLUSTER_NAME"
  elif [[ "$(jq '.associations | length' <<<"$assoc")" == 0 ]]; then
    echo "  no association for $NAMESPACE/$SERVICE_ACCOUNT; already gone."
  else
    id="$(jq -r '.associations[0].associationId' <<<"$assoc")"
    detail="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$id" --output json 2>/dev/null)"
    assoc_role=""
    [[ -z "$detail" ]] || assoc_role="$(jq -r '.association.roleArn // ""' <<<"$detail")"
    if [[ -z "$detail" ]]; then
      note_fail "could not read the Pod Identity association $id, so it was left in place"
    elif [[ "$assoc_role" != "$ROLE_ARN" ]]; then
      # The namespace and service account are this sample's, but the role is not the one
      # the run record names, so something else wrote this association.
      note_fail "the Pod Identity association $id points at $assoc_role, not this sample's $ROLE_ARN; left it alone"
    else
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --association-id "$id" >/dev/null 2>&1 ||
        note_fail "could not delete the Pod Identity association $id"
      remaining="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
        --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" --output json 2>/dev/null)"
      if [[ -z "$remaining" ]]; then
        note_fail "could not confirm the Pod Identity association was deleted"
      elif [[ "$(jq '.associations | length' <<<"$remaining")" != 0 ]]; then
        note_fail "the Pod Identity association is still present after the delete"
      else
        echo "  deleted the association $id."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 8-10/11 the AWS resources
# ---------------------------------------------------------------------------

say "8-10/11 the IAM role, the bucket and the images"

if [[ "$delete_aws" != true ]]; then
  echo "  kept the IAM role, the bucket and the images; pass --delete-aws to remove them."
else
  role="$ROLE_NAME"
  if [[ -z "$role" ]]; then
    note_fail "no IAM role name in the run record or .env, so the role could not be removed"
  else
    got="$(lookup NoSuchEntity iam get-role --role-name "$role" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      tag="$(jq -r '.Role.Tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$got")"
      if [[ "$tag" != "$SAMPLE" ]]; then
        note_fail "the IAM role $role does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
      else
        inline="$(aws iam list-role-policies --role-name "$role" --output json 2>/dev/null)"
        attached="$(aws iam list-attached-role-policies --role-name "$role" --output json 2>/dev/null)"
        if [[ -z "$inline" || -z "$attached" ]]; then
          note_fail "could not list the policies on the IAM role $role; left it in place"
        elif [[ -n "$(jq -r '.PolicyNames[] | select(. != "bridge")' <<<"$inline")" ||
                "$(jq '.AttachedPolicies | length' <<<"$attached")" != 0 ]]; then
          # The tag says the role is this sample's, but it now carries a grant this sample
          # did not create. Deleting it would take someone else's change with it.
          note_fail "the IAM role $role carries a policy this sample did not create; left it in place"
        else
          if [[ "$(jq -r '.PolicyNames | index("bridge")' <<<"$inline")" != "null" ]]; then
            aws iam delete-role-policy --role-name "$role" --policy-name bridge >/dev/null 2>&1 ||
              note_fail "could not delete the inline bridge policy on $role"
          fi
          aws iam delete-role --role-name "$role" >/dev/null 2>&1 ||
            note_fail "could not delete the IAM role $role"
          lookup NoSuchEntity iam get-role --role-name "$role" --output json >/dev/null 2>&1; rc=$?
          case "$rc" in
            1) echo "  deleted the IAM role $role." ;;
            0) note_fail "the IAM role $role is still present after the delete" ;;
            *) note_fail "could not confirm the IAM role $role was deleted" ;;
          esac
        fi
      fi
    elif [[ "$rc" == 1 ]]; then
      echo "  the IAM role $role is already gone."
    else
      note_fail "could not determine whether the IAM role $role exists; left it alone"
    fi
  fi

  bucket="${BUCKET:-}"
  if [[ -z "$bucket" ]]; then
    note_fail "no bucket name in the run record or .env, so the bucket could not be removed"
  else
    tags="$(lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      tag="$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")"
      if [[ "$tag" != "$SAMPLE" ]]; then
        note_fail "the bucket $bucket does not carry ManagedBy=$SAMPLE (found '$tag'); left it alone"
      else
        aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" >/dev/null 2>&1 ||
          note_fail "could not empty the bucket $bucket"
        aws s3api delete-bucket --bucket "$bucket" >/dev/null 2>&1 ||
          note_fail "could not delete the bucket $bucket"
        lookup NoSuchBucket s3api get-bucket-tagging --bucket "$bucket" --output json \
          >/dev/null 2>&1; rc=$?
        case "$rc" in
          1) echo "  deleted the bucket $bucket, with this sample's reports in it." ;;
          0) note_fail "the bucket $bucket is still present after the delete" ;;
          *) note_fail "could not confirm the bucket $bucket was deleted" ;;
        esac
      fi
    elif [[ "$rc" == 1 ]]; then
      echo "  the bucket $bucket is already gone."
    else
      note_fail "could not determine whether the bucket $bucket exists; left it alone"
    fi
  fi

  # Named rather than iterated over values, so a record missing one of them is reported
  # instead of quietly skipped: an empty name used to `continue` and leave the repository
  # in the account with the clean up still exiting 0.
  for repo_var in ANALYST_REPOSITORY SUPPLIER_API_REPOSITORY; do
    repo="${!repo_var:-}"
    if [[ -z "$repo" ]]; then
      note_fail "the run record names no $repo_var, so that ECR repository could not be found or removed"
      continue
    fi
    got="$(lookup RepositoryNotFoundException ecr describe-repositories \
      --repository-names "$repo" --output json)"; rc=$?
    if [[ "$rc" == 0 ]]; then
      arn="$(jq -r '.repositories[0].repositoryArn' <<<"$got")"
      tags="$(aws ecr list-tags-for-resource --resource-arn "$arn" --output json 2>/dev/null)"
      if [[ -z "$tags" ]]; then
        note_fail "could not read the tags on the ECR repository $repo; left it alone"
      elif [[ "$(jq -r '.tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")" != "$SAMPLE" ]]; then
        note_fail "the ECR repository $repo does not carry ManagedBy=$SAMPLE; left it alone"
      else
        aws ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 ||
          note_fail "could not delete the ECR repository $repo"
        lookup RepositoryNotFoundException ecr describe-repositories \
          --repository-names "$repo" --output json >/dev/null 2>&1; rc=$?
        case "$rc" in
          1) echo "  deleted the ECR repository $repo." ;;
          0) note_fail "the ECR repository $repo is still present after the delete" ;;
          *) note_fail "could not confirm the ECR repository $repo was deleted" ;;
        esac
      fi
    elif [[ "$rc" == 1 ]]; then
      echo "  the ECR repository $repo is already gone."
    else
      note_fail "could not determine whether the ECR repository $repo exists; left it alone"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 11/11 the local CLI config and state
# ---------------------------------------------------------------------------

say "11/11 the local CLI configuration and state"

# These hold the operator's gateway client certificate and key, which are this gateway's
# whole access control, so they go even when something above was left behind. The run
# evidence stays: it is what the page's output blocks are copied from.
removed_config=false
for dir in "$TMP_DIR"/cli-run.*; do
  [[ -d "$dir" ]] || continue
  rm -rf "$dir" || note_fail "could not remove the CLI configuration directory $dir"
  removed_config=true
done
if [[ "$removed_config" == true ]]; then
  echo "  removed this sample's CLI configuration and state directories."
else
  echo "  no CLI configuration directory to remove."
fi
echo "  kept $TMP_DIR/runs, which holds each run's checks, calls and output."

# ---------------------------------------------------------------------------
# What stays
# ---------------------------------------------------------------------------

say "what stays, and how to undo it"
cat <<EOF
  Two things this sample needs are shared with anything else on this cluster, so this
  script never removes them. Remove either one only if you know nothing else uses it.

  1. The $APPROVAL_LABEL=true label on the $RUNTIME_CLASS RuntimeClass.
     Every OpenShell gateway on this cluster reads the same label, and without it none of
     them may attach that RuntimeClass to a sandbox. Removing it would break another
     gateway's sandboxes, not just this sample's.
EOF
if [[ "${RUNTIME_CLASS_LABELLED:-false}" == true ]]; then
  cat <<EOF
     This run's setup added it, so it was not there before. If no other OpenShell gateway
     needs it:
       kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT }label runtimeclass $RUNTIME_CLASS $APPROVAL_LABEL-
EOF
else
  cat <<EOF
     It was already on the RuntimeClass before this run, so it is not this sample's to
     remove.
EOF
fi
cat <<EOF

  2. The agent-sandbox controller, which OpenShell's Kubernetes driver creates Sandbox
     objects for. setup.sh reused the install already on this cluster and changed nothing
     about it. If nothing else uses it:
       kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT }delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.10/sandbox-with-extensions.yaml

  The $RUNTIME_CLASS RuntimeClass itself and the cluster are not this sample's either. The
  Getting started > Hello sandbox sample's clean up covers removing the cluster.

  Local files left under $TMP_DIR: the run record, the downloaded OpenShell CLI and chart,
  the supplier key and the sample certificate authorities this run generated, and the run
  evidence. Nothing there is published; the repository ignores tmp/.
EOF

echo
if [[ "$failed" == 0 ]]; then
  if [[ "$delete_aws" == true ]]; then
    echo "Clean up complete."
  else
    echo "Clean up complete for the cluster objects. The IAM role, the bucket and the images are still there; pass --delete-aws to remove them."
  fi
else
  echo "Clean up finished with items left behind (see the INCOMPLETE lines above)." >&2
fi
exit "$failed"
