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
# resource carries this sample's ManagedBy tag or its managed-by label, or sits inside a
# namespace carrying that label, and leaves anything else alone.
#
# It never removes a shared install or a cluster-wide setting. This sample has two of
# those, the RuntimeClass approval label and the agent-sandbox controller, and both are
# left in place with the command to undo them printed at the end.
set -uo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
SAMPLE="openshell"
TMP_DIR="$REPO_ROOT/tmp/$SAMPLE"
STATE_FILE="$TMP_DIR/state.env"

delete_aws=false
for arg in "$@"; do
  case "$arg" in
    --delete-aws) delete_aws=true ;;
    --help|-h) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

failed=0
note_fail() { echo "INCOMPLETE: $*" >&2; failed=1; }
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1/10 the run record, the context and the account
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

say "1/10 the run record, the context and the account"

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
# 2/10 whose namespace it is
# ---------------------------------------------------------------------------

say "2/10 whose namespace $NAMESPACE is"

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
# 3/10 the sandboxes, the gateway and the namespace
# ---------------------------------------------------------------------------

say "3/10 the sandboxes, the OpenShell gateway and the namespace"

if [[ "$ns_state" != owned ]]; then
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
  if helm status "$RELEASE" -n "$NAMESPACE" ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} \
      >/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NAMESPACE" \
      ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} --wait --timeout 5m >/dev/null ||
      note_fail "could not uninstall the Helm release $RELEASE from $NAMESPACE"
    echo "  uninstalled the Helm release $RELEASE."
  else
    echo "  no Helm release $RELEASE in $NAMESPACE; already gone."
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
# 4/10 the cluster-scoped admission adapter
# ---------------------------------------------------------------------------

say "4/10 the admission adapter"

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
# 5/10 the chart's cluster-scoped RBAC
# ---------------------------------------------------------------------------

say "5/10 the ClusterRole and ClusterRoleBinding the chart created"

# helm uninstall normally takes these with it. They are checked anyway because a failed
# uninstall leaves them, and a cluster-scoped object left behind would be adopted by the
# next install of the same release name.
#
# They are identified by Helm's own annotations, which name both the release and its
# namespace, so another OpenShell gateway's RBAC in another namespace cannot match.
for kind in clusterrolebinding clusterrole; do
  if ! got="$(kc get "$kind" -o json 2>/dev/null)"; then
    note_fail "could not list the cluster $kind objects, so it is unknown whether the chart's are still there"
    continue
  fi
  names="$(jq -r --arg r "$RELEASE" --arg ns "$NAMESPACE" '
    .items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == $r)
    | select(.metadata.annotations["meta.helm.sh/release-namespace"] == $ns)
    | .metadata.name' <<<"$got")"
  if [[ -z "$names" ]]; then
    echo "  no $kind is annotated for the release $RELEASE in $NAMESPACE."
    continue
  fi
  while read -r name; do
    [[ -n "$name" ]] || continue
    kc delete "$kind" "$name" --ignore-not-found --wait=true --timeout=2m >/dev/null ||
      note_fail "could not delete the $kind $name"
    echo "  deleted the $kind $name."
  done <<<"$names"
done

# ---------------------------------------------------------------------------
# 6/10 the EKS Pod Identity association
# ---------------------------------------------------------------------------

say "6/10 the EKS Pod Identity association"

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
# 7-9/10 the AWS resources
# ---------------------------------------------------------------------------

say "7-9/10 the IAM role, the bucket and the images"

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

  for repo in "${ANALYST_REPOSITORY:-}" "${SUPPLIER_API_REPOSITORY:-}"; do
    [[ -n "$repo" ]] || continue
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
# 10/10 the local CLI config and state
# ---------------------------------------------------------------------------

say "10/10 the local CLI configuration and state"

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
       kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT }delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.6/sandbox-with-extensions.yaml

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
