#!/usr/bin/env bash
# Install the coder blueprint: Coder Community Edition, Keycloak and PostgreSQL on EKS Auto
# Mode, reached over HTTPS through a CloudFront distribution whose VPC origin is an internal
# Application Load Balancer.
#
#   cp .env.example .env    # optional: change the defaults
#   ./scripts/setup.sh
#
# Order matters for security. Coder lets anyone who reaches it create the first owner while
# it has no user, and Coder will not start until it can read Keycloak's discovery document
# through the distribution. So Keycloak is exposed first, alone, while its realm has no users;
# Coder is routed only after its owner exists and its password login is off; and the Keycloak
# users are created last, after the run has shown anonymous requests refused.
#
# Every check runs before anything is created. A resource that exists and is not the
# blueprint's stops the run, and so does an existing install (the Helm release): there is no
# upgrade path, run ./scripts/cleanup.sh first.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

KC_DISCOVERY_PATH=/auth/realms/coder/.well-known/openid-configuration
CODER_ADMIN_USERNAME="admin"
CODER_ADMIN_EMAIL=admin@example.com


require_commands aws kubectl helm jq openssl curl sed
show_context
mkdir -p "$LOCAL_DIR" || die "could not create $(rel "$LOCAL_DIR")"
chmod 700 "$LOCAL_DIR" || die "could not set mode 700 on $(rel "$LOCAL_DIR")"

step "1/13 Checks, namespaces, secrets, PostgreSQL and the Keycloak Service"
# Every check comes first, so a failed one leaves nothing behind.
check_cluster
state_set VPC_ID "$VPC_ID"
kc_cluster get runtimeclass isolated-sandbox >/dev/null \
  || die "runtimeclass isolated-sandbox not found; finish Getting started on this cluster first"

# CloudFront VPC origins need an internet gateway on the VPC (it is not used for routing).
igw="$(aws_r ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)" || die "could not list the internet gateways of $VPC_ID"
[[ "$igw" == igw-* ]] || die "VPC $VPC_ID has no internet gateway, which CloudFront VPC origins require"

# The ALB goes in the cluster's private subnets (no route to an internet gateway). Each must
# carry kubernetes.io/role/internal-elb. The tag is read VPC-wide by every load balancer
# controller, so it is your change to make, not this script's.
subnets="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.subnetIds' --output json)" \
  || die "could not read the cluster's subnets"
rts="$(aws_r ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json)" \
  || die "could not read the route tables of $VPC_ID"
# shellcheck disable=SC2046  # one argument per subnet id
subs="$(aws_r ec2 describe-subnets --subnet-ids $(jq -r '.[]' <<<"$subnets") --output json)" \
  || die "could not describe the cluster's subnets"
private="$(jq -c --argjson rts "$rts" '[.Subnets[] as $s
  | ([$rts.RouteTables[] | select(any(.Associations[]?; .SubnetId == $s.SubnetId))][0]
     // [$rts.RouteTables[] | select(any(.Associations[]?; .Main == true))][0]) as $rt
  | select(any($rt.Routes[]?; (.GatewayId // "") | startswith("igw-")) | not)
  | {id: $s.SubnetId, az: $s.AvailabilityZone,
     tagged: any($s.Tags[]?; .Key == "kubernetes.io/role/internal-elb" and (.Value == "1" or .Value == ""))}]' <<<"$subs")" \
  || die "could not classify the cluster's subnets"
[[ "$(jq length <<<"$private")" -gt 0 ]] || die "cluster $CLUSTER_NAME has no private subnets; the internal ALB needs them"
untagged="$(jq -r '[.[] | select(.tagged | not) | .id] | join(" ")' <<<"$private")"
[[ -z "$untagged" ]] || die "these private subnets lack the tag EKS Auto Mode needs to place an internal load balancer: $untagged
       Every load balancer controller in the VPC reads it, so add it yourself, then run ./scripts/setup.sh again:
         aws ec2 create-tags --region $AWS_REGION --resources $untagged --tags Key=kubernetes.io/role/internal-elb,Value=1"
[[ "$(jq '[.[].az] | unique | length' <<<"$private")" -ge 2 ]] \
  || die "the private subnets are in one Availability Zone; an Application Load Balancer needs two"
SUBNET_IDS_CSV="$(jq -r '[.[].id] | join(", ")' <<<"$private")"
echo "private subnets for the ALB, each tagged kubernetes.io/role/internal-elb: $SUBNET_IDS_CSV"

# An existing install is not upgraded.
if hm_err="$(hm status "$RELEASE" -n "$NAMESPACE" 2>&1 >/dev/null)"; then
  die "Helm release $RELEASE already exists in $NAMESPACE. There is no upgrade path: run ./scripts/cleanup.sh first."
fi
grep -q 'release: not found' <<<"$hm_err" || die "could not check for Helm release $RELEASE in $NAMESPACE: $hm_err"

for ns in "$NAMESPACE" "$WORKSPACE_NAMESPACE"; do
  rc=0; ns_is_ours "$ns" || rc=$?
  case $rc in
    1) die "namespace $ns exists and is not labelled $LABEL_KEY=$SAMPLE; it belongs to something else. Set NAMESPACE or WORKSPACE_NAMESPACE in .env to a free name." ;;
    2) die "could not read namespace $ns; stopping rather than guess" ;;
  esac
done

for kind in ingressclassparams ingressclass; do
  rc=0; resource_exists kc_cluster "$kind/$INGRESS_CLASS" || rc=$?
  [[ $rc -eq 2 ]] && die "could not read $kind/$INGRESS_CLASS"
  if [[ $rc -eq 0 ]]; then
    mark="$(label_of kc_cluster "$kind" "$INGRESS_CLASS")" || die "could not read the labels of $kind/$INGRESS_CLASS"
    [[ "$mark" == "$SAMPLE" ]] || die "$kind/$INGRESS_CLASS exists without $LABEL_KEY=$SAMPLE; it is not the blueprint's"
  fi
done
sel="$(kc_cluster get ingressclassparams "$INGRESS_CLASS" --ignore-not-found \
  -o 'jsonpath={.spec.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name}')" || die "could not read ingressclassparams/$INGRESS_CLASS"
[[ -z "$sel" || "$sel" == "$NAMESPACE" ]] \
  || die "ingressclassparams/$INGRESS_CLASS is the blueprint's but serves namespace $sel, not $NAMESPACE. Run ./scripts/cleanup.sh for that install first."

ALB_SG_ID="$(find_alb_sg)" || die "could not look up security group $ALB_SG_NAME"
if [[ -n "$ALB_SG_ID" ]]; then
  rc=0; sg_is_ours "$ALB_SG_ID" || rc=$?
  [[ $rc -eq 0 ]] || die "security group $ALB_SG_NAME ($ALB_SG_ID) exists without $TAG_KEY=$TAG_VAL (or its tags could not be read); it is not the blueprint's"
fi
vo="$(find_vpc_origin)" || die "could not list CloudFront VPC origins"
if [[ -n "$vo" ]]; then
  read -r VPC_ORIGIN_ID vo_arn vo_endpoint <<<"$vo"
  rc=0; cf_is_ours "$vo_arn" || rc=$?
  [[ $rc -eq 0 ]] || die "VPC origin $VPC_ORIGIN_NAME ($VPC_ORIGIN_ID) exists without $TAG_KEY=$TAG_VAL (or its tags could not be read)"
fi
rc=0; role_is_ours || rc=$?
case $rc in
  1) die "IAM role $ROLE_NAME exists without $TAG_KEY=$TAG_VAL; it is not the blueprint's" ;;
  2) die "could not read IAM role $ROLE_NAME" ;;
esac
assoc="$(find_pod_identity)" || die "could not list the Pod Identity associations of $WORKSPACE_NAMESPACE/$WORKSPACE_SA"
if [[ -n "$assoc" ]]; then
  a="$(aws_r eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$assoc" --output json)" \
    || die "could not read Pod Identity association $assoc"
  [[ "$(jq -r ".association.tags.$TAG_KEY // empty" <<<"$a")" == "$TAG_VAL" ]] \
    || die "ServiceAccount $WORKSPACE_NAMESPACE/$WORKSPACE_SA already has Pod Identity association $assoc, not tagged $TAG_KEY=$TAG_VAL. The blueprint never changes an association it does not own."
fi

# The inference profile, and the foundation models it routes to, are what the workspace
# role may invoke. Resolved now so a wrong BEDROCK_MODEL_ID stops before anything exists.
profile="$(aws_r bedrock get-inference-profile --inference-profile-identifier "$BEDROCK_MODEL_ID" --output json)" \
  || die "could not read inference profile $BEDROCK_MODEL_ID in $AWS_REGION. Set BEDROCK_MODEL_ID to an inference profile ID."
[[ "$(jq '.models | length' <<<"$profile")" -gt 0 ]] || die "inference profile $BEDROCK_MODEL_ID lists no models"
echo "checks passed: nothing that exists is outside the blueprint, and no install is present"

# The StorageClass is chosen, never changed: the default class when it fits, otherwise the
# blueprint's own coder-gp3, created only when absent and reused only when labelled.
defaults="$(kc_cluster get storageclass -o json)" || die "could not list StorageClasses"
CHOSEN_STORAGE_CLASS="$(jq -r --arg p "$EBS_PROVISIONER" '[.items[]
  | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
  | select(.provisioner == $p and .parameters.encrypted == "true" and (.reclaimPolicy // "Delete") == "Delete")
  | .metadata.name] | if length == 1 then .[0] else "" end' <<<"$defaults")"
if [[ -n "$CHOSEN_STORAGE_CLASS" ]]; then
  echo "using the default storageclass $CHOSEN_STORAGE_CLASS ($EBS_PROVISIONER, encrypted, reclaimPolicy Delete)"
elif [[ "$(jq -r --arg n "$SAMPLE_STORAGE_CLASS" '[.items[] | select(.metadata.name == $n)] | length' <<<"$defaults")" -eq 0 ]]; then
  kc_cluster create -f "$SAMPLE_DIR/deploy/storage-class.yaml" >/dev/null || die "could not create storageclass/$SAMPLE_STORAGE_CLASS"
  CHOSEN_STORAGE_CLASS=$SAMPLE_STORAGE_CLASS
  echo "no default class fits; created storageclass/$SAMPLE_STORAGE_CLASS"
else
  [[ "$(jq -r --arg n "$SAMPLE_STORAGE_CLASS" '.items[] | select(.metadata.name == $n)
        | .metadata.labels["app.kubernetes.io/part-of"] // ""' <<<"$defaults")" == "$SAMPLE" ]] \
    || die "storageclass/$SAMPLE_STORAGE_CLASS exists without $LABEL_KEY=$SAMPLE; it is not the blueprint's"
  CHOSEN_STORAGE_CLASS=$SAMPLE_STORAGE_CLASS
  echo "reusing the blueprint's storageclass/$SAMPLE_STORAGE_CLASS"
fi

ensure_namespace "$NAMESPACE"
ensure_namespace "$WORKSPACE_NAMESPACE"

# Every password and the OIDC client secret: openssl, a mode-600 file, then a Secret built
# with --from-file. No value is ever an argument of a command.
for f in postgres-superuser-password postgres-coder-password postgres-keycloak-password oidc-client-secret; do
  gen_secret_file "$LOCAL_DIR/$f" 32
done
gen_secret_file "$LOCAL_DIR/keycloak-admin-password" 24
( umask 077
  { printf 'postgres://coder:'; cat "$LOCAL_DIR/postgres-coder-password"
    printf '@postgres.%s.svc.cluster.local:5432/coder?sslmode=disable' "$NAMESPACE"; } >"$LOCAL_DIR/coder-db-url"
) || die "could not write $(rel "$LOCAL_DIR/coder-db-url")"
secret_from_files postgres-passwords --from-file=postgres="$LOCAL_DIR/postgres-superuser-password" \
  --from-file=coder="$LOCAL_DIR/postgres-coder-password" --from-file=keycloak="$LOCAL_DIR/postgres-keycloak-password"
secret_from_files keycloak-admin --from-file=password="$LOCAL_DIR/keycloak-admin-password"
secret_from_files coder-oidc --from-file=client-secret="$LOCAL_DIR/oidc-client-secret"
secret_from_files coder-db-url --from-file=url="$LOCAL_DIR/coder-db-url"

render postgres.yaml | require_rendered postgres.yaml | kc apply -f - || die "could not apply deploy/postgres.yaml"
kc rollout status deploy/postgres --timeout=10m || die "PostgreSQL did not become ready"
# Only the Service now: the Ingress needs a backend Service before Auto Mode builds the ALB,
# and Keycloak itself needs the distribution's domain, which does not exist yet.
render keycloak.yaml | kc apply -l app.kubernetes.io/component=keycloak-service -f - \
  || die "could not apply the keycloak Service"

step "2/13 The internal ALB, closed, with only the Keycloak route"
if [[ -z "$ALB_SG_ID" ]]; then
  ALB_SG_ID="$(aws_r ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$ALB_SG_NAME" \
    --description "coder blueprint ALB: inbound only from CloudFront VPC origins" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$ALB_SG_NAME},{Key=$TAG_KEY,Value=$TAG_VAL},{Key=auto-delete,Value=no}]" \
    --query GroupId --output text)" || die "could not create security group $ALB_SG_NAME"
  echo "created security group $ALB_SG_NAME ($ALB_SG_ID) with no inbound rule"
else
  # A group left by an earlier run starts closed, like a new one.
  revoke_alb_sg_ingress "$ALB_SG_ID" || die "could not close security group $ALB_SG_ID"
  echo "reusing security group $ALB_SG_NAME ($ALB_SG_ID); it has no inbound rule"
fi
state_set ALB_SG_ID "$ALB_SG_ID"
if ! resource_exists kc_cluster "ingressclass/$INGRESS_CLASS"; then
  render ingress.yaml | require_rendered ingress.yaml \
    | kc_cluster create -l app.kubernetes.io/component=ingress-class -f - \
    || die "could not create IngressClassParams and IngressClass $INGRESS_CLASS"
else
  echo "reusing the blueprint's IngressClass $INGRESS_CLASS"
fi
render ingress.yaml | without_coder_route | require_rendered ingress.yaml \
  | kc apply -l app.kubernetes.io/component=ingress -f - || die "could not apply ingress/$INGRESS_NAME"
echo "waiting for EKS Auto Mode to create the ALB (up to 10 minutes)"
start=$SECONDS
until ALB_DNS="$(kc get ingress "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" && [[ -n "$ALB_DNS" ]]; do
  (( SECONDS - start > 600 )) && die "ingress/$INGRESS_NAME has no load balancer after 10 minutes; see: kubectl -n $NAMESPACE describe ingress $INGRESS_NAME"
  sleep 10
done
lb="$(aws_r elbv2 describe-load-balancers --output json \
  | jq -c --arg d "$ALB_DNS" '[.LoadBalancers[] | select((.DNSName|ascii_downcase) == ($d|ascii_downcase))][0] // empty')" \
  || die "could not list load balancers"
[[ -n "$lb" ]] || die "no load balancer in $AWS_REGION has the Ingress's hostname $ALB_DNS"
ALB_ARN="$(jq -r .LoadBalancerArn <<<"$lb")"
[[ "$(jq -r .Scheme <<<"$lb")" == internal ]] || die "load balancer $ALB_ARN is not internal; stopping"
aws_r elbv2 describe-tags --resource-arns "$ALB_ARN" --output json | jq -e --arg c "$CLUSTER_NAME" \
  --arg s "$NAMESPACE/$INGRESS_NAME" '.TagDescriptions[0].Tags as $t
  | any($t[]; .Key == "eks:eks-cluster-name" and .Value == $c)
    and any($t[]; .Key == "ingress.eks.amazonaws.com/stack" and .Value == $s)' >/dev/null \
  || die "load balancer $ALB_ARN is not the one Auto Mode made for ingress $NAMESPACE/$INGRESS_NAME"
state_set ALB_ARN "$ALB_ARN"
aws_r elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" || die "load balancer $ALB_ARN did not become active"
# Internal, in the private subnets chosen above, no public IP address; otherwise it is removed.
check_alb_private
# Called directly, not in $( ), so its die stops this script.
wait_target_groups 1 >/dev/null
echo "security groups on the ALB:"
audit_alb_sgs closed
echo "ALB $ALB_DNS is internal and active; nothing can reach it yet"

step "3/13 The CloudFront VPC origin and distribution"
if [[ -n "$VPC_ORIGIN_ID" ]]; then
  [[ "$vo_endpoint" == "$ALB_ARN" ]] \
    || die "VPC origin $VPC_ORIGIN_ID is the blueprint's but points at another load balancer. Run ./scripts/cleanup.sh first."
  echo "reusing VPC origin $VPC_ORIGIN_NAME ($VPC_ORIGIN_ID)"
else
  VPC_ORIGIN_ID="$(aws_r cloudfront create-vpc-origin \
    --vpc-origin-endpoint-config "Name=$VPC_ORIGIN_NAME,Arn=$ALB_ARN,HTTPPort=80,HTTPSPort=443,OriginProtocolPolicy=http-only,OriginSslProtocols={Quantity=1,Items=[TLSv1.2]}" \
    --tags "Items=[{Key=$TAG_KEY,Value=$TAG_VAL},{Key=auto-delete,Value=no}]" \
    --query VpcOrigin.Id --output text)" || die "could not create the CloudFront VPC origin"
  echo "created VPC origin $VPC_ORIGIN_NAME ($VPC_ORIGIN_ID)"
fi
state_set VPC_ORIGIN_ID "$VPC_ORIGIN_ID"
echo "waiting for the VPC origin to deploy (up to 20 minutes)"
start=$SECONDS
until [[ "$(aws_r cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" --query VpcOrigin.Status --output text)" == Deployed ]]; do
  (( SECONDS - start > 1200 )) && die "VPC origin $VPC_ORIGIN_ID is not Deployed after 20 minutes"
  sleep 20
done
# CloudFront's own group for the VPC origin's network interfaces; the ALB admits only it.
CF_SG_ID="$(aws_r ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
  "Name=group-name,Values=$CF_VPC_ORIGIN_SG_NAME" "Name=tag:aws.cloudfront.vpcorigin,Values=enabled" \
  --query 'SecurityGroups[].GroupId' --output text)" || die "could not look up $CF_VPC_ORIGIN_SG_NAME"
[[ "$CF_SG_ID" == sg-* && "$CF_SG_ID" != *[[:space:]]* ]] || die "expected one $CF_VPC_ORIGIN_SG_NAME in $VPC_ID, found '${CF_SG_ID:-none}'"
state_set CF_SG_ID "$CF_SG_ID"

found="$(find_distribution)" || die "could not list CloudFront distributions"
if [[ -n "$found" ]]; then
  read -r DISTRIBUTION_ID dist_arn <<<"$found"
  rc=0; cf_is_ours "$dist_arn" || rc=$?
  [[ $rc -eq 0 ]] || die "distribution $DISTRIBUTION_ID uses the blueprint's VPC origin but is not tagged $TAG_KEY=$TAG_VAL"
  DOMAIN="$(aws_r cloudfront get-distribution --id "$DISTRIBUTION_ID" --query Distribution.DomainName --output text)" \
    || die "could not read distribution $DISTRIBUTION_ID"
  echo "reusing distribution $DISTRIBUTION_ID: https://$DOMAIN"
else
  # Viewers: HTTPS on the default *.cloudfront.net certificate, HTTP redirected to HTTPS.
  # Nothing cached. Every viewer header (Host included), cookie and query string reaches the
  # origin. CloudFront adds `Forwarded: proto=https` to every origin request, replacing any
  # value a viewer sent, so Keycloak sees the scheme the viewer used.
  jq -n --arg ref "coder-$CLUSTER_NAME-$(date +%s)" --arg comment "coder blueprint, cluster $CLUSTER_NAME" \
    --arg alb "$ALB_DNS" --arg vo "$VPC_ORIGIN_ID" --arg cp "$CF_CACHE_POLICY" --arg orp "$CF_ORIGIN_REQUEST_POLICY" \
    --arg tk "$TAG_KEY" --arg tv "$TAG_VAL" '{
    DistributionConfig: {
      CallerReference: $ref, Comment: $comment, Enabled: true, HttpVersion: "http2",
      Origins: { Quantity: 1, Items: [ {
        Id: "coder-alb", DomainName: $alb, OriginPath: "",
        CustomHeaders: { Quantity: 1, Items: [ { HeaderName: "Forwarded", HeaderValue: "proto=https" } ] },
        VpcOriginConfig: { VpcOriginId: $vo, OriginReadTimeout: 60, OriginKeepaliveTimeout: 60 },
        ConnectionAttempts: 3, ConnectionTimeout: 10, OriginShield: { Enabled: false } } ] },
      DefaultCacheBehavior: {
        TargetOriginId: "coder-alb", ViewerProtocolPolicy: "redirect-to-https",
        AllowedMethods: { Quantity: 7, Items: ["GET","HEAD","OPTIONS","PUT","PATCH","POST","DELETE"],
                          CachedMethods: { Quantity: 2, Items: ["GET","HEAD"] } },
        Compress: false, CachePolicyId: $cp, OriginRequestPolicyId: $orp },
      ViewerCertificate: { CloudFrontDefaultCertificate: true }
    },
    Tags: { Items: [ { Key: $tk, Value: $tv }, { Key: "auto-delete", Value: "no" } ] }
  }' >"$LOCAL_DIR/distribution.json" || die "could not write $(rel "$LOCAL_DIR/distribution.json")"
  out="$(aws_r cloudfront create-distribution-with-tags \
    --distribution-config-with-tags "file://$LOCAL_DIR/distribution.json" \
    --query 'Distribution.[Id,DomainName]' --output text)" || die "could not create the CloudFront distribution"
  read -r DISTRIBUTION_ID DOMAIN <<<"$out"
  echo "created distribution $DISTRIBUTION_ID: https://$DOMAIN"
fi
[[ "$DOMAIN" == *.cloudfront.net ]] || die "unexpected distribution domain '$DOMAIN'"
state_set DISTRIBUTION_ID "$DISTRIBUTION_ID"
state_set DOMAIN "$DOMAIN"
echo "waiting for distribution $DISTRIBUTION_ID to deploy (up to 35 minutes)"
aws_r cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID" || die "distribution $DISTRIBUTION_ID did not reach Deployed"

step "4/13 Keycloak, with the realm coder and no users"
render realm.json | require_rendered realm.json >"$LOCAL_DIR/coder-realm.json"
rc=0; resource_exists kc configmap/keycloak-realm || rc=$?
[[ $rc -eq 2 ]] && die "could not read configmap/keycloak-realm"
if [[ $rc -eq 1 ]]; then
  kc create configmap keycloak-realm --from-file=coder-realm.json="$LOCAL_DIR/coder-realm.json" >/dev/null \
    || die "could not create configmap/keycloak-realm"
  kc label configmap keycloak-realm "$LABEL_KEY=$SAMPLE" >/dev/null || die "could not label configmap/keycloak-realm"
fi
render keycloak.yaml | require_rendered keycloak.yaml | kc apply -f - || die "could not apply deploy/keycloak.yaml"
kc rollout status deploy/keycloak --timeout=10m || die "Keycloak did not become ready; see: kubectl -n $NAMESPACE logs deploy/keycloak"

step "5/13 Open the ALB to CloudFront's VPC origins only"
# shellcheck disable=SC2016  # a JMESPath literal, not a shell expansion
n="$(aws_r ec2 describe-security-group-rules --filters "Name=group-id,Values=$ALB_SG_ID" \
  --query 'length(SecurityGroupRules[?IsEgress==`false`])' --output text)" || die "could not read the rules of $ALB_SG_ID"
if [[ "$n" == 0 ]]; then
  aws_r ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" --ip-permissions \
    "$(jq -nc --arg g "$CF_SG_ID" '[{IpProtocol:"tcp",FromPort:80,ToPort:80,UserIdGroupPairs:[{GroupId:$g,Description:"CloudFront VPC origins only"}]}]')" \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=$TAG_KEY,Value=$TAG_VAL},{Key=auto-delete,Value=no}]" \
    >/dev/null || die "could not add the inbound rule to $ALB_SG_ID"
fi
echo "security groups on the ALB:"
audit_alb_sgs open
# Only Keycloak is routed: a realm with no users, registration off, and an admin console
# behind a random password. Coder will not start until this answers.
wait_url "https://$DOMAIN$KC_DISCOVERY_PATH" 200 10

step "6/13 The workspace namespace: ServiceAccount, provisioner Role, IAM role, Pod Identity"
render workspace-rbac.yaml | require_rendered workspace-rbac.yaml | kc_cluster apply -f - \
  || die "could not apply deploy/workspace-rbac.yaml"
jq -n '{Version:"2012-10-17",Statement:[{Sid:"EksPodIdentity",Effect:"Allow",
  Principal:{Service:"pods.eks.amazonaws.com"},Action:["sts:AssumeRole","sts:TagSession"]}]}' \
  >"$LOCAL_DIR/workspace-trust-policy.json"
# The only grant: invoke the configured inference profile and the foundation models it routes to.
jq '{Version:"2012-10-17",Statement:[{Sid:"InvokeConfiguredModel",Effect:"Allow",
  Action:["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  Resource:([.inferenceProfileArn] + [.models[].modelArn])}]}' <<<"$profile" \
  >"$LOCAL_DIR/workspace-bedrock-policy.json" || die "could not write the role policy"
rc=0; role_is_ours || rc=$?
if [[ $rc -eq 3 ]]; then
  aws_r iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$LOCAL_DIR/workspace-trust-policy.json" \
    --tags "Key=$TAG_KEY,Value=$TAG_VAL" Key=auto-delete,Value=no >/dev/null || die "could not create IAM role $ROLE_NAME"
  echo "created IAM role $ROLE_NAME"
elif [[ $rc -eq 0 ]]; then
  aws_r iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$LOCAL_DIR/workspace-trust-policy.json" || die "could not update the trust policy of $ROLE_NAME"
  echo "reusing the blueprint's IAM role $ROLE_NAME"
else
  die "IAM role $ROLE_NAME changed since the checks; stopping"
fi
aws_r iam put-role-policy --role-name "$ROLE_NAME" --policy-name bedrock-invoke \
  --policy-document "file://$LOCAL_DIR/workspace-bedrock-policy.json" || die "could not put the policy on $ROLE_NAME"
role_arn="$(aws_r iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)" || die "could not read $ROLE_NAME"
echo "policy bedrock-invoke ($(rel "$LOCAL_DIR/workspace-bedrock-policy.json")):"
cat "$LOCAL_DIR/workspace-bedrock-policy.json"
if [[ -z "$assoc" ]]; then
  assoc="$(aws_r eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$WORKSPACE_NAMESPACE" --service-account "$WORKSPACE_SA" --role-arn "$role_arn" \
    --tags "$TAG_KEY=$TAG_VAL,auto-delete=no" --query association.associationId --output text)" \
    || die "could not create the Pod Identity association"
  echo "created Pod Identity association $assoc: $WORKSPACE_NAMESPACE/$WORKSPACE_SA -> $ROLE_NAME"
else
  [[ "$(jq -r .association.roleArn <<<"$a")" == "$role_arn" ]] \
    || die "Pod Identity association $assoc is the blueprint's but names another role. Run ./scripts/cleanup.sh first."
  echo "reusing the blueprint's Pod Identity association $assoc"
fi

step "7/13 Install Coder (OIDC on, password login on, not routed)"
DISABLE_PASSWORD_AUTH=false render coder-values.yaml | require_rendered coder-values.yaml >"$LOCAL_DIR/coder-values.yaml"
hm install "$RELEASE" "$CODER_CHART" --version "$CODER_VERSION" -n "$NAMESPACE" \
  -f "$LOCAL_DIR/coder-values.yaml" --wait --timeout 10m || die "helm install of Coder failed"

step "8/13 Create the Coder owner from inside the cluster"
# Nothing routes to Coder yet. Inside the coderd pod, over 127.0.0.1: a bootstrap first user
# signs in with a password read from standard input, creates admin as an OIDC user with the
# owner role, and a 10-minute admin token deletes the bootstrap user, then itself. The first
# Keycloak sign-in as admin@example.com links to that account.
gen_secret_file "$LOCAL_DIR/coder-bootstrap-password" 24
# shellcheck disable=SC2016  # expanded by the pod's shell, on purpose
in_coder '
  set -eu
  CODER_FIRST_USER_PASSWORD=
  IFS= read -r CODER_FIRST_USER_PASSWORD || [ -n "$CODER_FIRST_USER_PASSWORD" ]
  export CODER_FIRST_USER_PASSWORD
  CODER_CONFIG_DIR="$(mktemp -d)"; export CODER_CONFIG_DIR
  trap "rm -rf \"\$CODER_CONFIG_DIR\"" EXIT
  /opt/coder login http://127.0.0.1:8080 --first-user-username bootstrap \
    --first-user-email bootstrap@example.com --first-user-full-name "Setup bootstrap" --first-user-trial=false
  unset CODER_FIRST_USER_PASSWORD
  /opt/coder users create --username "$1" --email "$2" --full-name "Coder admin" --login-type oidc
  /opt/coder users edit-roles "$1" --roles owner --yes
  CODER_SESSION_TOKEN="$(/opt/coder tokens create --user "$1" --name setup-cleanup --lifetime 10m)"
  export CODER_SESSION_TOKEN
  /opt/coder users delete bootstrap
  /opt/coder users show "$1"
  /opt/coder tokens remove setup-cleanup --delete
' coder-bootstrap "$CODER_ADMIN_USERNAME" "$CODER_ADMIN_EMAIL" <"$LOCAL_DIR/coder-bootstrap-password" \
  || die "could not create the Coder owner"
rm -f "$LOCAL_DIR/coder-bootstrap-password"
first="$(in_coder 'wget -q -O - http://127.0.0.1:8080/api/v2/users/first' </dev/null)" \
  || die "could not read /api/v2/users/first"
echo "GET /api/v2/users/first: $first"

step "9/13 Turn Coder password login off"
DISABLE_PASSWORD_AUTH=true render coder-values.yaml | require_rendered coder-values.yaml >"$LOCAL_DIR/coder-values.yaml"
hm upgrade "$RELEASE" "$CODER_CHART" --version "$CODER_VERSION" -n "$NAMESPACE" \
  -f "$LOCAL_DIR/coder-values.yaml" --wait --timeout 10m || die "helm upgrade of Coder failed"
kc rollout status deploy/coder --timeout=5m || die "Coder did not roll out"
methods="$(in_coder 'wget -q -O - http://127.0.0.1:8080/api/v2/users/authmethods' </dev/null)" \
  || die "could not read /api/v2/users/authmethods"
jq -e '.password.enabled == false and .oidc.enabled == true' <<<"$methods" >/dev/null \
  || die "Coder sign-in methods are not OIDC only: $methods"
echo "sign-in methods: $(jq -c '{password: .password.enabled, oidc: .oidc.enabled}' <<<"$methods")"

step "10/13 Route / to Coder"
render ingress.yaml | require_rendered ingress.yaml | kc apply -l app.kubernetes.io/component=ingress -f - \
  || die "could not add the Coder route to ingress/$INGRESS_NAME"
# Called directly, not in $( ), so its die stops this script.
wait_target_groups 2 >/dev/null
wait_url "https://$DOMAIN/healthz" 200 10

step "11/13 Anonymous requests through https://$DOMAIN, before any Keycloak user exists"
# Each line prints what curl received, and the run stops if it is not a refusal.
probe() { # <label> <want> <curl args...>
  local label=$1 want=$2 got
  shift 2
  got="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$@")" || die "$label: request failed"
  printf '%-44s %s\n' "$label" "$got"
  [[ "$got" =~ $want ]] || die "$label: expected $want"
}
probe "GET http://$DOMAIN/" "^301 https://$DOMAIN/\$" "http://$DOMAIN/"
probe "GET /api/v2/users/me" "^401 " "https://$DOMAIN/api/v2/users/me"
# A well-formed first-user request, so Coder answers about the user count, not the body.
probe "POST /api/v2/users/first" "^409 " -X POST -H 'Content-Type: application/json' \
  --data-binary @- "https://$DOMAIN/api/v2/users/first" \
  <<<'{"email":"probe@example.com","username":"probe","password":"refused-probe-1"}'
methods="$(curl -sS "https://$DOMAIN/api/v2/users/authmethods")" || die "could not read the sign-in methods"
printf '%-44s %s\n' "GET /api/v2/users/authmethods" "$(jq -c '{password: .password.enabled, oidc: .oidc.enabled}' <<<"$methods")"
jq -e '.password.enabled == false and .oidc.enabled == true' <<<"$methods" >/dev/null || die "Coder offers more than Keycloak sign-in"
probe "GET /auth/admin/" "^30[0-9] https://$DOMAIN/auth/" "https://$DOMAIN/auth/admin/"

step "12/13 Create the Keycloak users (admin and $DEVELOPER_COUNT developers)"
# kcadm.sh runs inside the Keycloak pod. It signs in with the admin password from the pod's
# own environment (KC_CLI_PASSWORD) and reads each user's JSON, password included, from
# standard input.
# shellcheck disable=SC2016  # expanded by the pod's shell, on purpose
kcadm='set -eu
  export KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD"
  cfg="$(mktemp)"; trap "rm -f \"$cfg\"" EXIT
  /opt/keycloak/bin/kcadm.sh config credentials --config "$cfg" --server http://127.0.0.1:8080/auth \
    --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME"
  /opt/keycloak/bin/kcadm.sh create users --config "$cfg" -r coder -f -'
( umask 077; : >"$USERS_FILE" ) || die "could not write $(rel "$USERS_FILE")"
users=("$CODER_ADMIN_USERNAME")
for (( i = 1; i <= DEVELOPER_COUNT; i++ )); do users+=("dev$i"); done
for u in "${users[@]}"; do
  pw="$LOCAL_DIR/keycloak-user-$u-password"
  rm -f "$pw"; gen_secret_file "$pw" 16
  { printf '{"username":"%s","email":"%s@example.com","emailVerified":true,"enabled":true,' "$u" "$u"
    printf '"firstName":"%s","lastName":"User","credentials":[{"type":"password","temporary":false,"value":"' "$u"
    cat "$pw"; printf '"}]}\n'; } | kc exec -i deploy/keycloak -c keycloak -- sh -c "$kcadm" \
    || die "could not create Keycloak user $u"
  { printf '%s %s@example.com ' "$u" "$u"; cat "$pw"; printf '\n'; } >>"$USERS_FILE"
  rm -f "$pw"
  echo "created Keycloak user $u ($u@example.com)"
done

step "13/13 Template variables and next steps"
cat >"$LOCAL_DIR/template-variables.yaml" <<EOF
namespace: $WORKSPACE_NAMESPACE
service_account: $WORKSPACE_SA
storage_class: $CHOSEN_STORAGE_CLASS
bedrock_model: $BEDROCK_MODEL_ID
aws_region: $AWS_REGION
coder_internal_url: http://$RELEASE.$NAMESPACE.svc.cluster.local
EOF
echo "Coder:          https://$DOMAIN"
echo "Keycloak admin: https://$DOMAIN/auth/admin/  (user admin, password in $(rel "$LOCAL_DIR/keycloak-admin-password"))"
echo "Users:          $(rel "$USERS_FILE")  (mode 600: user, email, password)"
echo
echo "Publish the template as the Coder admin (sign in through Keycloak as admin in the browser):"
echo "  coder login https://$DOMAIN"
echo "  coder templates push claude-code-nitro --directory $(rel "$SAMPLE_DIR/templates/claude-code-nitro") \\"
echo "    --variables-file $(rel "$LOCAL_DIR/template-variables.yaml") --yes"
echo "Tear it down:   ./scripts/cleanup.sh"
