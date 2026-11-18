#!/usr/bin/env bash
# Remove everything the coder blueprint created, and only that.
#
#   ./scripts/cleanup.sh
#
# This DELETES DATA: every workspace and its EBS home volume, PostgreSQL's volume with the
# Coder and Keycloak databases, the CloudFront distribution and VPC origin, the internal ALB
# and its security group, the workspace IAM role and its Pod Identity association, the
# IngressClass, the blueprint's own StorageClass when setup created it, and both namespaces.
#
# The order is the reverse of setup: the workspaces first, then Coder, then the ALB is
# closed to CloudFront before the distribution, the VPC origin and the ALB are deleted, and
# the namespaces go last. Each AWS resource is deleted only when it carries ManagedBy=coder,
# and each Kubernetes object only when it, or its namespace, carries
# app.kubernetes.io/part-of=coder. A lookup that fails is "could not determine", never
# "gone". Anything skipped or unconfirmed is listed, and the script exits non-zero.
#
# Two groups stay, because the blueprint does not own them: EKS Auto Mode's shared backend
# group k8s-traffic-<cluster>-* and CloudFront's CloudFront-VPCOrigins-Service-SG. The files
# in tmp/coder (passwords, users.txt) stay too; delete them yourself.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# One failed delete must not stop the ones after it; the exit code is decided at the end.
set +e

require_commands aws kubectl helm jq
show_context
mkdir -p "$LOCAL_DIR" || die "could not create $(rel "$LOCAL_DIR")"
chmod 700 "$LOCAL_DIR" || die "could not set mode 700 on $(rel "$LOCAL_DIR")"
failures=0
fail() { echo "  INCOMPLETE: $*" >&2; failures=$((failures + 1)); }

step "1/12 Checks"
check_cluster   # stops on a kube context that is not this cluster
state_load
ns_ok=0 ws_ok=0
for ns in "$NAMESPACE" "$WORKSPACE_NAMESPACE"; do
  ns_is_ours "$ns"
  case $? in
    0) [[ "$ns" == "$NAMESPACE" ]] && ns_ok=1 || ws_ok=1; echo "namespace $ns is the blueprint's" ;;
    1) fail "namespace $ns is not labelled $LABEL_KEY=$SAMPLE; leaving it and everything in it" ;;
    2) fail "could not determine whether namespace $ns exists or is the blueprint's" ;;
    3) echo "namespace $ns does not exist" ;;
  esac
done
# Every PersistentVolume claimed from the two namespaces, recorded now: once a claim is
# deleted there is nothing left to follow to its volume.
pvs_json="$(kc_cluster get pv -o json)" || { pvs_json='{"items":[]}'; fail "could not list PersistentVolumes, so the EBS volumes cannot be confirmed deleted"; }
pvs_in() { jq -r --arg n "$1" '.items[] | select(.spec.claimRef.namespace == $n) | .metadata.name' <<<"$pvs_json"; }

step "2/12 Workspaces and their EBS home volumes"
if [[ $ws_ok -eq 1 ]]; then
  # Coder's template labels each workspace's Deployment and claim with its workspace ID.
  kcw delete deployment,pvc -l com.coder.workspace.id --wait=true --timeout=5m \
    || fail "could not delete the workspace Deployments and claims in $WORKSPACE_NAMESPACE"
  wait_pvs_gone "$(pvs_in "$WORKSPACE_NAMESPACE")" || fail "a workspace EBS volume is not confirmed deleted"
fi

step "3/12 Coder (Helm release $RELEASE)"
if [[ $ns_ok -eq 1 ]]; then
  if hm_err="$(hm status "$RELEASE" -n "$NAMESPACE" 2>&1 >/dev/null)"; then
    hm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 5m || fail "could not uninstall Helm release $RELEASE"
  elif grep -q 'release: not found' <<<"$hm_err"; then
    echo "Helm release $RELEASE is not installed"
  else
    fail "could not determine whether Helm release $RELEASE exists: $hm_err"
  fi
fi

step "4/12 The workspace Pod Identity association and IAM role"
assoc="$(find_pod_identity)" || { assoc=""; fail "could not determine the Pod Identity association of $WORKSPACE_NAMESPACE/$WORKSPACE_SA"; }
if [[ -n "$assoc" ]]; then
  if ! mark="$(aws_r eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$assoc" \
    --query "association.tags.$TAG_KEY" --output text)"; then fail "could not read Pod Identity association $assoc"
  elif [[ "$mark" != "$TAG_VAL" ]]; then fail "Pod Identity association $assoc is not tagged $TAG_KEY=$TAG_VAL; leaving it"
  elif aws_r eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$assoc" >/dev/null; then
    echo "deleted Pod Identity association $assoc"
  else fail "could not delete Pod Identity association $assoc"; fi
else
  echo "no Pod Identity association for $WORKSPACE_NAMESPACE/$WORKSPACE_SA"
fi
role_is_ours
case $? in
  0) for p in $(aws_r iam list-role-policies --role-name "$ROLE_NAME" --query PolicyNames --output text); do
       aws_r iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$p" || fail "could not delete policy $p of $ROLE_NAME"
     done
     if aws_r iam delete-role --role-name "$ROLE_NAME"; then echo "deleted IAM role $ROLE_NAME"; else fail "could not delete IAM role $ROLE_NAME"; fi ;;
  1) fail "IAM role $ROLE_NAME is not tagged $TAG_KEY=$TAG_VAL; leaving it" ;;
  2) fail "could not determine whether IAM role $ROLE_NAME exists or is the blueprint's" ;;
  3) echo "IAM role $ROLE_NAME does not exist" ;;
esac

step "5/12 Close the ALB to CloudFront"
if [[ -z "$ALB_SG_ID" ]]; then
  ALB_SG_ID="$(find_alb_sg)" || { ALB_SG_ID=""; fail "could not look up security group $ALB_SG_NAME"; }
fi
sg_rc=3
if [[ -n "$ALB_SG_ID" ]]; then
  sg_is_ours "$ALB_SG_ID"; sg_rc=$?
  case $sg_rc in
    0) if revoke_alb_sg_ingress "$ALB_SG_ID"; then echo "security group $ALB_SG_ID has no inbound rule"; else fail "could not close security group $ALB_SG_ID"; fi ;;
    1) fail "security group $ALB_SG_ID is not tagged $TAG_KEY=$TAG_VAL; leaving it" ;;
    2) fail "could not read security group $ALB_SG_ID" ;;
    3) echo "security group $ALB_SG_ID does not exist" ;;
  esac
else
  echo "no security group $ALB_SG_NAME"
fi

step "6/12 The CloudFront distribution (disable, wait, delete)"
if [[ -z "$VPC_ORIGIN_ID" ]]; then
  vo="$(find_vpc_origin)" || fail "could not list CloudFront VPC origins"
  VPC_ORIGIN_ID="${vo%% *}"
fi
if [[ -z "$DISTRIBUTION_ID" && -n "$VPC_ORIGIN_ID" ]]; then
  found="$(find_distribution)" || fail "could not list CloudFront distributions"
  DISTRIBUTION_ID="${found%% *}"
fi
if [[ -z "$DISTRIBUTION_ID" ]]; then
  echo "no distribution uses the blueprint's VPC origin"
else
  cfg="$(aws_lookup NoSuchDistribution cloudfront get-distribution-config --id "$DISTRIBUTION_ID" --output json)"
  case $? in
    3) echo "distribution $DISTRIBUTION_ID does not exist" ;;
    2) fail "could not read distribution $DISTRIBUTION_ID" ;;
    0) arn="$(aws_r cloudfront get-distribution --id "$DISTRIBUTION_ID" --query Distribution.ARN --output text)"
       if ! cf_is_ours "$arn"; then
         fail "distribution $DISTRIBUTION_ID is not tagged $TAG_KEY=$TAG_VAL (or its tags could not be read); leaving it"
       else
         ok=1
         if [[ "$(jq -r .DistributionConfig.Enabled <<<"$cfg")" == true ]]; then
           jq .DistributionConfig.Enabled=false <<<"$cfg" | jq .DistributionConfig >"$LOCAL_DIR/distribution-disabled.json"
           aws_r cloudfront update-distribution --id "$DISTRIBUTION_ID" --if-match "$(jq -r .ETag <<<"$cfg")" \
             --distribution-config "file://$LOCAL_DIR/distribution-disabled.json" >/dev/null || ok=0
           [[ $ok -eq 1 ]] && echo "disabled distribution $DISTRIBUTION_ID; waiting for that to deploy (up to 35 minutes)"
         fi
         [[ $ok -eq 1 ]] && { aws_r cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID" || ok=0; }
         [[ $ok -eq 1 ]] && { etag="$(aws_r cloudfront get-distribution-config --id "$DISTRIBUTION_ID" --query ETag --output text)" || ok=0; }
         [[ $ok -eq 1 ]] && { aws_r cloudfront delete-distribution --id "$DISTRIBUTION_ID" --if-match "$etag" || ok=0; }
         if [[ $ok -eq 1 ]]; then echo "deleted distribution $DISTRIBUTION_ID"; else fail "could not disable and delete distribution $DISTRIBUTION_ID"; fi
       fi ;;
  esac
fi

step "7/12 The CloudFront VPC origin"
if [[ -z "$VPC_ORIGIN_ID" ]]; then
  echo "no VPC origin named $VPC_ORIGIN_NAME"
else
  out="$(aws_lookup EntityNotFound cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" --output json)"
  case $? in
    3) echo "VPC origin $VPC_ORIGIN_ID does not exist" ;;
    2) fail "could not read VPC origin $VPC_ORIGIN_ID" ;;
    0) if ! cf_is_ours "$(jq -r .VpcOrigin.Arn <<<"$out")"; then
         fail "VPC origin $VPC_ORIGIN_ID is not tagged $TAG_KEY=$TAG_VAL (or its tags could not be read); leaving it"
       elif ! aws_r cloudfront delete-vpc-origin --id "$VPC_ORIGIN_ID" --if-match "$(jq -r .ETag <<<"$out")" >/dev/null; then
         fail "could not delete VPC origin $VPC_ORIGIN_ID (a distribution may still use it)"
       else
         echo "deleting VPC origin $VPC_ORIGIN_ID (up to 20 minutes)"
         start=$SECONDS
         while :; do
           aws_lookup EntityNotFound cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" >/dev/null
           rc=$?
           [[ $rc -eq 3 ]] && { echo "deleted VPC origin $VPC_ORIGIN_ID"; break; }
           [[ $rc -eq 2 ]] && { fail "could not read VPC origin $VPC_ORIGIN_ID while it was deleting"; break; }
           (( SECONDS - start > 1200 )) && { fail "VPC origin $VPC_ORIGIN_ID still exists after 20 minutes"; break; }
           sleep 20
         done
       fi ;;
  esac
fi

step "8/12 The Ingress, and with it the ALB"
if [[ $ns_ok -eq 1 ]]; then
  if [[ -z "$ALB_ARN" ]]; then
    host="$(kc get ingress "$INGRESS_NAME" --ignore-not-found -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" \
      || fail "could not read ingress/$INGRESS_NAME"
    if [[ -n "$host" ]]; then
      ALB_ARN="$(aws_r elbv2 describe-load-balancers --output json | jq -r --arg d "$host" \
        '[.LoadBalancers[] | select((.DNSName|ascii_downcase) == ($d|ascii_downcase))][0].LoadBalancerArn // empty')" \
        || fail "could not look up the ALB of ingress/$INGRESS_NAME"
    fi
  fi
  # Auto Mode deletes the ALB, its listener and target groups when the Ingress goes.
  kc delete ingress "$INGRESS_NAME" --ignore-not-found --wait=true --timeout=10m || fail "could not delete ingress/$INGRESS_NAME"
fi
if [[ -n "$ALB_ARN" ]]; then
  start=$SECONDS
  while :; do
    aws_lookup LoadBalancerNotFound elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" >/dev/null
    rc=$?
    [[ $rc -eq 3 ]] && { echo "the ALB is gone"; break; }
    [[ $rc -eq 2 ]] && { fail "could not read load balancer $ALB_ARN"; break; }
    (( SECONDS - start > 600 )) && { fail "load balancer $ALB_ARN still exists 10 minutes after its Ingress was deleted"; break; }
    sleep 10
  done
fi

step "9/12 The ALB security group"
if [[ $sg_rc -eq 0 ]]; then
  # The ALB's network interfaces take a few minutes to go after the ALB.
  start=$SECONDS
  until err="$(aws_r ec2 delete-security-group --group-id "$ALB_SG_ID" 2>&1 >/dev/null)"; do
    if ! grep -q DependencyViolation <<<"$err" || (( SECONDS - start > 600 )); then
      fail "could not delete security group $ALB_SG_ID: $err"; err=failed; break
    fi
    sleep 20
  done
  [[ "$err" != failed ]] && echo "deleted security group $ALB_SG_ID"
fi

step "10/12 The IngressClass and its parameters"
for kind in ingressclass ingressclassparams; do
  resource_exists kc_cluster "$kind/$INGRESS_CLASS"
  case $? in
    1) echo "$kind/$INGRESS_CLASS does not exist" ;;
    2) fail "could not read $kind/$INGRESS_CLASS" ;;
    0) if [[ "$(label_of kc_cluster "$kind" "$INGRESS_CLASS")" != "$SAMPLE" ]]; then
         fail "$kind/$INGRESS_CLASS is not labelled $LABEL_KEY=$SAMPLE; leaving it"
       elif kc_cluster delete "$kind" "$INGRESS_CLASS" --wait=true >/dev/null; then
         echo "deleted $kind/$INGRESS_CLASS"
       else fail "could not delete $kind/$INGRESS_CLASS"; fi ;;
  esac
done

step "11/12 PostgreSQL's volume, and the blueprint's StorageClass"
if [[ $ns_ok -eq 1 ]]; then
  kc delete deployment postgres --ignore-not-found --wait=true --timeout=3m >/dev/null || fail "could not delete deployment/postgres"
  kc delete pvc postgres-data --ignore-not-found --wait=true --timeout=3m >/dev/null || fail "could not delete pvc/postgres-data"
  wait_pvs_gone "$(pvs_in "$NAMESPACE")" || fail "PostgreSQL's EBS volume is not confirmed deleted"
fi
# Only the class setup created (it carries the label), and only once no claim can need it.
resource_exists kc_cluster "storageclass/$SAMPLE_STORAGE_CLASS"
case $? in
  1) echo "storageclass/$SAMPLE_STORAGE_CLASS does not exist (setup used the cluster's default class)" ;;
  2) fail "could not read storageclass/$SAMPLE_STORAGE_CLASS" ;;
  0) if [[ "$(label_of kc_cluster storageclass "$SAMPLE_STORAGE_CLASS")" != "$SAMPLE" ]]; then
       fail "storageclass/$SAMPLE_STORAGE_CLASS is not labelled $LABEL_KEY=$SAMPLE; leaving it"
     elif [[ $failures -ne 0 ]]; then
       fail "not deleting storageclass/$SAMPLE_STORAGE_CLASS while a claim may still use it"
     elif kc_cluster delete storageclass "$SAMPLE_STORAGE_CLASS" >/dev/null; then
       echo "deleted storageclass/$SAMPLE_STORAGE_CLASS"
     else fail "could not delete storageclass/$SAMPLE_STORAGE_CLASS"; fi ;;
esac

step "12/12 The namespaces"
for ns in "$WORKSPACE_NAMESPACE" "$NAMESPACE"; do
  [[ "$ns" == "$NAMESPACE" && $ns_ok -eq 0 ]] && continue
  [[ "$ns" == "$WORKSPACE_NAMESPACE" && $ws_ok -eq 0 ]] && continue
  if [[ $failures -ne 0 ]]; then
    fail "not deleting namespace $ns while something above is unconfirmed"
  elif kc_cluster delete namespace "$ns" --wait=true --timeout=5m >/dev/null; then
    echo "deleted namespace $ns"
  else fail "could not delete namespace $ns"; fi
done

echo
echo "Left in place, owned by EKS Auto Mode and CloudFront rather than the blueprint:"
aws_r ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
  "Name=group-name,Values=k8s-traffic-${CLUSTER_NAME}-*,$CF_VPC_ORIGIN_SG_NAME" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text | sed 's/^/  /' \
  || echo "  (could not list them)"
if [[ $failures -ne 0 ]]; then
  echo "clean up INCOMPLETE: $failures item(s) above were skipped or could not be confirmed. Fix them and run ./scripts/cleanup.sh again." >&2
  exit 1
fi
echo "clean up complete. The generated passwords and users.txt are still in $(rel "$LOCAL_DIR"); delete them when you are done."
