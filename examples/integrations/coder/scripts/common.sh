#!/usr/bin/env bash
# The names below are read by setup.sh and cleanup.sh, which source this file.
# shellcheck disable=SC2034
#
# Shared names and helpers for the coder blueprint's setup.sh and cleanup.sh.
# Sourced, not run.
#
# Every kubectl and helm call goes through kc, kc_cluster or hm, which pin the kube
# context, so a run never depends on the machine's current context. Every AWS call goes
# through aws_r, which pins the Region and uses your own credential chain.
set -euo pipefail
# The scripts read generated passwords into shell variables; tracing (bash -x) would print
# them, so it is off for everything after this line, however the script was started.
set +x

SAMPLE=coder
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"
# examples/integrations/coder -> the repository root, three levels up.
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"

# Read .env as defaults. A value already in the environment wins over the file, so
# `NAMESPACE=other ./scripts/setup.sh` overrides it. Only the names below are read.
ENV_KEYS='NAMESPACE|WORKSPACE_NAMESPACE|KUBE_CONTEXT|CLUSTER_NAME|AWS_REGION|BEDROCK_MODEL_ID|DEVELOPER_COUNT|LOCAL_DIR'
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    [[ -z "${!_k:-}" ]] && printf -v "$_k" '%s' "$_v"
  done < <(grep -E "^[[:space:]]*($ENV_KEYS)[[:space:]]*=" "$SAMPLE_DIR/.env" \
             | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

NAMESPACE="${NAMESPACE:-coder}"
WORKSPACE_NAMESPACE="${WORKSPACE_NAMESPACE:-coder-workspaces}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
CLUSTER_NAME="${CLUSTER_NAME:-sandbox-demo}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
DEVELOPER_COUNT="${DEVELOPER_COUNT:-2}"
LOCAL_DIR="${LOCAL_DIR:-$REPO_ROOT/tmp/$SAMPLE}"
# Absolute, so that no path the scripts make under it can be read as an option by chmod,
# mktemp, ls or find (a relative LOCAL_DIR starting with "-" would be).
[[ "$LOCAL_DIR" == /* ]] || LOCAL_DIR="$PWD/$LOCAL_DIR"

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

# These values reach sed replacements, JSON and AWS names, so check their shape once here.
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "NAMESPACE '$NAMESPACE' is not a valid namespace name"
[[ "$WORKSPACE_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "WORKSPACE_NAMESPACE '$WORKSPACE_NAMESPACE' is not a valid namespace name"
[[ "$NAMESPACE" != "$WORKSPACE_NAMESPACE" ]] || die "NAMESPACE and WORKSPACE_NAMESPACE must differ"
[[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || die "CLUSTER_NAME '$CLUSTER_NAME' is not a valid EKS cluster name"
[[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "AWS_REGION '$AWS_REGION' is not a Region name"
[[ "$BEDROCK_MODEL_ID" =~ ^[a-z0-9][a-z0-9.:-]*$ ]] || die "BEDROCK_MODEL_ID '$BEDROCK_MODEL_ID' is not an inference profile ID"
[[ "$DEVELOPER_COUNT" =~ ^[0-9]+$ && "$DEVELOPER_COUNT" -ge 1 && "$DEVELOPER_COUNT" -le 20 ]] \
  || die "DEVELOPER_COUNT '$DEVELOPER_COUNT' must be a number from 1 to 20"

# Names. Every one is the blueprint's own, and the manifests receive them through render.
TAG_KEY=ManagedBy
TAG_VAL=$SAMPLE
LABEL_KEY=app.kubernetes.io/part-of
CODER_CHART=oci://ghcr.io/coder/chart/coder
CODER_VERSION=2.38.10
RELEASE=coder
INGRESS_NAME=coder
INGRESS_CLASS=coder-alb
ALB_SG_NAME=coder-alb-origin
VPC_ORIGIN_NAME="coder-${CLUSTER_NAME}"
WORKSPACE_SA=coder-workspace
ROLE_NAME="coder-workspace-bedrock-${CLUSTER_NAME}"
ROLE_NAME="${ROLE_NAME:0:64}"
SAMPLE_STORAGE_CLASS=coder-gp3
EBS_PROVISIONER=ebs.csi.eks.amazonaws.com
# CloudFront creates this group in the VPC with the first VPC origin there. The name is
# reserved for CloudFront; the blueprint never creates or edits it.
CF_VPC_ORIGIN_SG_NAME=CloudFront-VPCOrigins-Service-SG
# Managed CloudFront policies (CloudFront Developer Guide, managed cache and origin
# request policies): CachingDisabled, and AllViewer, which forwards every viewer header
# (Host included), cookie and query string.
CF_CACHE_POLICY=4135ea2d-6df8-44a3-9df3-4b5a84be39ad
CF_ORIGIN_REQUEST_POLICY=216adef6-5c7f-47e4-b989-5492eafa07d3
STATE_FILE="$LOCAL_DIR/state.env"
USERS_FILE="$LOCAL_DIR/users.txt"

# Values the steps hand to each other, also kept in STATE_FILE for cleanup.sh.
VPC_ID="" SUBNET_IDS_CSV="" ALB_SG_ID="" ALB_ARN="" ALB_DNS="" VPC_ORIGIN_ID="" CF_SG_ID=""
DISTRIBUTION_ID="" DOMAIN="" CHOSEN_STORAGE_CLASS="" CREATED_STORAGE_CLASS=0

# rel <path> : the path relative to the repository root, so output carries no home path.
rel() { case "$1" in "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

kc_cluster() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}
kc() { kc_cluster --namespace "$NAMESPACE" "$@"; }
kcw() { kc_cluster --namespace "$WORKSPACE_NAMESPACE" "$@"; }
hm() {
  if [[ -n "$KUBE_CONTEXT" ]]; then helm --kube-context "$KUBE_CONTEXT" "$@"; else helm "$@"; fi
}
aws_r() { aws --region "$AWS_REGION" "$@"; }

# check_alb_private : the ALB must be internal, sit in exactly the private subnets setup chose
# (none with a route to an internet gateway), and hold no public IP address on any of its
# network interfaces. Silent when it holds. When it does not, or cannot be confirmed, the
# Ingress is deleted at once, so EKS Auto Mode removes the load balancer, and setup stops:
# nothing public is left in your account.
check_alb_private() {
  local lb got want rts s pub enis
  lb="$(aws_r elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --output json)" \
    || alb_not_private "could not read load balancer $ALB_ARN"
  [[ "$(jq -r '.LoadBalancers[0].Scheme' <<<"$lb")" == internal ]] || alb_not_private "it is not internal"
  got="$(jq -r '[.LoadBalancers[0].AvailabilityZones[].SubnetId] | sort | join(" ")' <<<"$lb")"
  want="$(tr ',' ' ' <<<"$SUBNET_IDS_CSV" | xargs -n1 | sort | xargs)"
  [[ -n "$got" && "$got" == "$want" ]] || alb_not_private "it is in subnets '$got', not the private subnets '$want'"
  rts="$(aws_r ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json)" \
    || alb_not_private "could not read the route tables of $VPC_ID"
  for s in $got; do
    jq -e --arg s "$s" '([.RouteTables[] | select(any(.Associations[]?; .SubnetId == $s))][0]
        // [.RouteTables[] | select(any(.Associations[]?; .Main == true))][0]) as $rt
      | $rt != null and (any($rt.Routes[]?; (.GatewayId // "") | startswith("igw-")) | not)' \
      <<<"$rts" >/dev/null || alb_not_private "subnet $s has a route to an internet gateway"
  done
  enis="$(aws_r ec2 describe-network-interfaces --filters "Name=description,Values=ELB ${ALB_ARN#*:loadbalancer/}" \
    --output json)" || alb_not_private "could not read the ALB's network interfaces"
  # No match is not proof of no public address: it is a lookup that found nothing to check.
  [[ "$(jq '.NetworkInterfaces | length' <<<"$enis")" -gt 0 ]] \
    || alb_not_private "no network interface matched it, so its addresses cannot be confirmed private"
  pub="$(jq -r '[.NetworkInterfaces[] | select(.Association.PublicIp != null) | .NetworkInterfaceId] | join(" ")' \
    <<<"$enis")" || alb_not_private "could not read the ALB's network interfaces"
  [[ -z "$pub" ]] || alb_not_private "network interfaces $pub have public IP addresses"
}
alb_not_private() {
  # This helper deletes the Ingress itself, so the guard is cleared, and a signal is ignored
  # until the delete has run: a Ctrl-C to the process group would otherwise end kubectl too.
  trap - EXIT; trap '' INT TERM HUP
  echo "error: the ALB is not private: $1" >&2
  echo "deleting ingress/$INGRESS_NAME so EKS Auto Mode removes the load balancer" >&2
  kc delete ingress "$INGRESS_NAME" --ignore-not-found >&2 || echo "error: could not delete ingress/$INGRESS_NAME; delete it now" >&2
  die "stopped. Run ./scripts/cleanup.sh, then check the scheme and subnets in deploy/ingress.yaml"
}

require_commands() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done
}

show_context() {
  local ctx
  ctx="$(kc_cluster config current-context 2>/dev/null || true)"
  echo "cluster $CLUSTER_NAME in $AWS_REGION, kube context ${KUBE_CONTEXT:-${ctx:-<none>} (current)}"
  echo "namespaces: $NAMESPACE (Coder, Keycloak, PostgreSQL) and $WORKSPACE_NAMESPACE (workspaces)"
}

# aws_lookup <not-found-code> <aws args...> : a read that tells "absent" from "could not
# read". Prints the output. Returns 0 read, 3 the resource does not exist, 2 any other
# failure (the error is printed).
aws_lookup() {
  local nf=$1 err out rc=0
  shift
  err="$(mktemp)"
  out="$(aws_r "$@" 2>"$err")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    if grep -q "$nf" "$err"; then rm -f "$err"; return 3; fi
    sed 's/^/  aws: /' "$err" >&2
    rm -f "$err"
    return 2
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# The ManagedBy tag is the blueprint's mark on AWS resources. Each *_is_ours returns
# 0 ours, 1 exists without the mark, 3 absent, 2 could not read.
tag_is_ours() { # <value read from the tag, or None>
  [[ "$1" == "$TAG_VAL" ]]
}
sg_is_ours() {
  local v rc=0
  v="$(aws_lookup InvalidGroup.NotFound ec2 describe-security-groups --group-ids "$1" \
    --query "SecurityGroups[0].Tags[?Key=='$TAG_KEY'].Value | [0]" --output text)" || rc=$?
  [[ $rc -ne 0 ]] && return $rc
  tag_is_ours "$v"
}
cf_is_ours() { # <CloudFront ARN>
  local v rc=0
  v="$(aws_lookup NoSuchResource cloudfront list-tags-for-resource --resource "$1" \
    --query "Tags.Items[?Key=='$TAG_KEY'].Value | [0]" --output text)" || rc=$?
  [[ $rc -ne 0 ]] && return $rc
  tag_is_ours "$v"
}
role_is_ours() {
  local v rc=0
  v="$(aws_lookup NoSuchEntity iam list-role-tags --role-name "$ROLE_NAME" \
    --query "Tags[?Key=='$TAG_KEY'].Value | [0]" --output text)" || rc=$?
  [[ $rc -ne 0 ]] && return $rc
  tag_is_ours "$v"
}

# ---- state file: KEY=value lines, mode 600, in the git-ignored LOCAL_DIR ----------------
state_get() { [[ -f "$STATE_FILE" ]] || return 0; sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1; }
state_set() {
  local tmp
  tmp="$(mktemp "$LOCAL_DIR/.state.XXXXXX")"
  { if [[ -f "$STATE_FILE" ]]; then grep -v "^$1=" "$STATE_FILE" || true; fi
    if [[ -n "${2:-}" ]]; then printf '%s=%s\n' "$1" "$2"; fi; } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}
state_load() {
  local k
  for k in VPC_ID ALB_SG_ID ALB_ARN VPC_ORIGIN_ID CF_SG_ID DISTRIBUTION_ID DOMAIN; do
    [[ -n "${!k}" ]] || printf -v "$k" '%s' "$(state_get "$k")"
  done
}

# ---- Kubernetes ownership --------------------------------------------------------------
# resource_exists <runner> <kind/name> : 0 exists, 1 does not, 2 the read failed.
resource_exists() {
  local runner=$1 out rc=0
  shift
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}
# label_of <runner> <kind> <name> : prints the part-of label, empty when absent.
label_of() {
  "$1" get "$2" "$3" -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null
}
# ns_is_ours <namespace> : 0 ours, 1 not labelled app.kubernetes.io/part-of=coder,
# 2 could not read, 3 absent.
ns_is_ours() {
  local rc=0 mark
  resource_exists kc_cluster "namespace/$1" || rc=$?
  [[ $rc -eq 1 ]] && return 3
  [[ $rc -eq 2 ]] && return 2
  mark="$(label_of kc_cluster namespace "$1")" || return 2
  [[ "$mark" == "$SAMPLE" ]]
}

# ---- rendering -------------------------------------------------------------------------
# render <file in deploy/> : fill the non-secret placeholders. A value that is not known
# yet leaves its placeholder, and require_rendered refuses to apply the result.
render() {
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
      -e "s|<WORKSPACE_NAMESPACE>|$WORKSPACE_NAMESPACE|g" \
      -e "s|<DOMAIN>|${DOMAIN:-<DOMAIN>}|g" \
      -e "s|<STORAGE_CLASS>|${CHOSEN_STORAGE_CLASS:-<STORAGE_CLASS>}|g" \
      -e "s|<DISABLE_PASSWORD_AUTH>|${DISABLE_PASSWORD_AUTH:-<DISABLE_PASSWORD_AUTH>}|g" \
      -e "s|<SUBNET_IDS>|${SUBNET_IDS_CSV:-<SUBNET_IDS>}|g" \
      -e "s|<SECURITY_GROUP_ID>|${ALB_SG_ID:-<SECURITY_GROUP_ID>}|g" \
      "$SAMPLE_DIR/deploy/$1"
}
# require_rendered <file> : the rendered text on stdin must hold no placeholder outside a
# comment. Prints it back, so it can sit in a pipe.
require_rendered() {
  local text
  text="$(cat)"
  if sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' <<<"$text" | grep -qE '<[A-Z_]+>'; then
    die "internal: deploy/$1 still has a placeholder after rendering"
  fi
  printf '%s\n' "$text"
}
# Ingress without the Coder route: the lines between the two coder-route markers.
without_coder_route() { sed -e '/# coder-route: begin/,/# coder-route: end/d'; }

# ---- the cluster and its VPC -----------------------------------------------------------
# check_cluster : Auto Mode with load balancing on, and the kube context points at this
# cluster. The local context named like the cluster can point at another account, so the
# API server is compared with the one EKS reports.
check_cluster() {
  local out compute elb endpoint server
  out="$(aws_r eks describe-cluster --name "$CLUSTER_NAME" --output json)" \
    || die "could not describe cluster $CLUSTER_NAME in $AWS_REGION; stopping rather than guess"
  compute="$(jq -r '.cluster.computeConfig.enabled // false' <<<"$out")"
  elb="$(jq -r '.cluster.kubernetesNetworkConfig.elasticLoadBalancing.enabled // false' <<<"$out")"
  endpoint="$(jq -r '.cluster.endpoint // empty' <<<"$out")"
  VPC_ID="$(jq -r '.cluster.resourcesVpcConfig.vpcId // empty' <<<"$out")"
  [[ "$compute" == true ]] || die "cluster $CLUSTER_NAME is not an EKS Auto Mode cluster"
  [[ "$elb" == true ]] || die "EKS Auto Mode load balancing is off on $CLUSTER_NAME; the blueprint's ALB needs it"
  [[ "$VPC_ID" == vpc-* ]] || die "could not read the VPC of cluster $CLUSTER_NAME"
  server="$(kc_cluster config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" \
    || die "could not read the kube context's API server"
  [[ -n "$server" && "${server%/}" == "${endpoint%/}" ]] \
    || die "the kube context points at ${server:-nothing}, not cluster $CLUSTER_NAME in $AWS_REGION ($endpoint). Set KUBE_CONTEXT in .env to a context for this cluster."
  echo "cluster $CLUSTER_NAME: EKS Auto Mode, load balancing on, VPC $VPC_ID; the kube context points at it"
}

# find_alb_sg : prints the id of the group named coder-alb-origin in the VPC, or nothing.
find_alb_sg() {
  local id
  id="$(aws_r ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$ALB_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)" || return 2
  [[ "$id" == None ]] || printf '%s' "$id"
}
# find_vpc_origin : prints "id arn endpoint-arn" of the VPC origin named for the blueprint.
find_vpc_origin() {
  aws_r cloudfront list-vpc-origins --output json \
    | jq -r --arg n "$VPC_ORIGIN_NAME" '(.VpcOriginList.Items // [])[] | select(.Name == $n) | "\(.Id) \(.Arn) \(.OriginEndpointArn)"'
}
# find_distribution : prints "id arn" of a distribution whose origin is VPC_ORIGIN_ID.
find_distribution() {
  aws_r cloudfront list-distributions --output json \
    | jq -r --arg vo "$VPC_ORIGIN_ID" '(.DistributionList.Items // [])[]
        | select(any(.Origins.Items[]?; .VpcOriginConfig.VpcOriginId == $vo)) | "\(.Id) \(.ARN)"'
}
# find_pod_identity : prints the association id for the workspace ServiceAccount, or nothing.
find_pod_identity() {
  local id
  id="$(aws_r eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$WORKSPACE_NAMESPACE" --service-account "$WORKSPACE_SA" \
    --query 'associations[0].associationId' --output text)" || return 2
  [[ "$id" == None ]] || printf '%s' "$id"
}

# revoke_alb_sg_ingress <sg-id> : remove every inbound rule from the blueprint's group.
revoke_alb_sg_ingress() {
  local ids
  # shellcheck disable=SC2016  # a JMESPath literal, not a shell expansion
  ids="$(aws_r ec2 describe-security-group-rules --filters "Name=group-id,Values=$1" \
    --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' --output text)" || return 1
  if [[ -n "$ids" && "$ids" != None ]]; then
    # shellcheck disable=SC2086  # one argument per rule id
    aws_r ec2 revoke-security-group-ingress --group-id "$1" --security-group-rule-ids $ids >/dev/null || return 1
  fi
}

# wait_pvs_gone <pv names, one per line> : each PersistentVolume must be deleted, which for
# a class with reclaimPolicy Delete means its EBS volume is deleted. 0 all gone, 1 not.
wait_pvs_gone() {
  local pv rc bad=0
  while IFS= read -r pv; do
    [[ -z "$pv" ]] && continue
    rc=0; resource_exists kc_cluster "pv/$pv" || rc=$?
    if [[ $rc -eq 0 ]] && ! kc_cluster wait --for=delete "pv/$pv" --timeout=5m >/dev/null; then rc=2; fi
    if [[ $rc -eq 2 ]]; then echo "  pv/$pv: still present or could not be read" >&2; bad=1; else echo "  pv/$pv: gone"; fi
  done <<<"$1"
  return $bad
}

# ---- setup helpers -------------------------------------------------------------------
# gen_secret_file <path> <bytes> : random hex from openssl, mode 600, no trailing newline
# (an env var read from a Secret would otherwise carry the newline into the password).
# An existing non-empty file is kept, so a run that stopped part way and is run again uses
# the values its Secrets already hold; it is reused only if it is a plain file (not a link,
# and no other name for the same file) holding exactly the hex this function writes, and it
# is set to mode 600. A new value goes to a new file that then replaces the name, so nothing
# is ever written through an existing file.
gen_secret_file() {
  local v tmp
  if [[ -e "$1" || -L "$1" ]]; then
    [[ -f "$1" && ! -L "$1" ]] || die "$(rel "$1") exists and is not a plain file; remove it and run setup again"
    # ls -ld prints the link count in its second field on GNU and BSD alike, and `--` keeps a
    # name that starts with "-" from being read as an option.
    [[ "$(ls -ld -- "$1" | awk 'NR == 1 { print $2 }')" == 1 ]] \
      || die "$(rel "$1") has another name (a hard link); remove it and run setup again"
    v="$(cat "$1")" || die "could not read $(rel "$1")"
    if [[ -n "$v" ]]; then
      [[ "$v" =~ ^[0-9a-f]+$ && ${#v} -eq $(( $2 * 2 )) ]] \
        || die "$(rel "$1") does not hold a value setup generated; remove it and run setup again"
      chmod 600 "$1" || die "could not set mode 600 on $(rel "$1")"
      return 0
    fi
  fi
  tmp="$(mktemp "$1.XXXXXX")" || die "could not write $(rel "$1")"
  { ( umask 077; openssl rand -hex "$2" | tr -d '\n' >"$tmp" ) && chmod 600 "$tmp" && mv -f "$tmp" "$1"; } \
    || { rm -f "$tmp"; die "could not write $(rel "$1")"; }
}

# reset_private_file <path> : an empty file only you can read, before anything secret goes in.
# A new file replaces the name, so an existing file, or another name for it, is never
# truncated or changed; a symbolic link or a directory is refused.
reset_private_file() {
  local tmp
  [[ ! -L "$1" ]] || die "$(rel "$1") is a symbolic link; remove it and run setup again"
  [[ ! -e "$1" || -f "$1" ]] || die "$(rel "$1") exists and is not a plain file; remove it and run setup again"
  tmp="$(mktemp "$1.XXXXXX")" || die "could not write $(rel "$1")"
  { chmod 600 "$tmp" && mv -f "$tmp" "$1"; } || { rm -f "$tmp"; die "could not write $(rel "$1")"; }
}

# role_holds_only_bedrock : stops unless the existing role has no managed policy attached and
# no inline policy other than bedrock-invoke. Every workspace gets whatever the role may do,
# so a marked role is reused only when that is nothing more than what setup grants.
role_holds_only_bedrock() {
  local out extra
  out="$(aws_r iam list-attached-role-policies --role-name "$ROLE_NAME" --output json)" \
    || die "could not list the managed policies attached to $ROLE_NAME"
  extra="$(jq -r '[.AttachedPolicies[].PolicyArn] | join(" ")' <<<"$out")" \
    || die "could not read the managed policies attached to $ROLE_NAME"
  [[ -z "$extra" ]] || die "IAM role $ROLE_NAME has managed policies attached ($extra); the blueprint's role holds only bedrock-invoke. Detach them, or delete the role, then run ./scripts/setup.sh again"
  out="$(aws_r iam list-role-policies --role-name "$ROLE_NAME" --output json)" \
    || die "could not list the inline policies of $ROLE_NAME"
  extra="$(jq -r '[.PolicyNames[] | select(. != "bedrock-invoke")] | join(" ")' <<<"$out")" \
    || die "could not read the inline policies of $ROLE_NAME"
  [[ -z "$extra" ]] || die "IAM role $ROLE_NAME has inline policies other than bedrock-invoke ($extra); delete them, or delete the role, then run ./scripts/setup.sh again"
}

# secret_from_files <name> <--from-file=...>... : create a Secret once, labelled.
secret_from_files() {
  local name=$1 rc=0
  shift
  resource_exists kc "secret/$name" || rc=$?
  case $rc in
    0) echo "secret/$name already exists; keeping it"; return 0 ;;
    2) die "could not read secret/$name" ;;
  esac
  kc create secret generic "$name" "$@" >/dev/null || die "could not create secret/$name"
  kc label secret "$name" "$LABEL_KEY=$SAMPLE" >/dev/null || die "could not label secret/$name"
  echo "created secret/$name from files in $(rel "$LOCAL_DIR")"
}

# ensure_namespace <name> : create it labelled, or reuse it only when it carries the label.
ensure_namespace() {
  local rc=0
  ns_is_ours "$1" || rc=$?
  case $rc in
    0) echo "namespace $1 exists and is the blueprint's; reusing it" ;;
    3) kc_cluster create namespace "$1" >/dev/null || die "could not create namespace $1"
       kc_cluster label namespace "$1" "$LABEL_KEY=$SAMPLE" >/dev/null \
         || die "created namespace $1 but could not label it $LABEL_KEY=$SAMPLE"
       echo "created namespace $1, labelled $LABEL_KEY=$SAMPLE" ;;
    *) die "namespace $1 changed since the checks; stopping" ;;
  esac
}

# wait_target_groups <n> : Auto Mode makes one target group per backend Service.
wait_target_groups() {
  local start=$SECONDS tgs
  while :; do
    tgs="$(aws_r elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" \
      --query 'TargetGroups[].TargetGroupArn' --output text)" || die "could not list the target groups of $ALB_ARN"
    [[ $(wc -w <<<"$tgs") -ge $1 ]] && break
    (( SECONDS - start > 300 )) && die "the ALB has fewer than $1 target groups after 5 minutes"
    sleep 10
  done
  printf '%s' "$tgs"
}

# The ALB, its listener, rules and target groups belong to EKS Auto Mode and carry only Auto
# Mode's own tags (eks:eks-cluster-name, ingress.eks.amazonaws.com/stack). Setup adds none:
# Auto Mode removes any tag it did not set on its next update of the Ingress, the cluster
# role is not allowed to, and that update then fails, so the / route would never be added.
# audit_alb_sgs closed|open : read from AWS what can reach the ALB. The blueprint's group
# has no inbound rule (closed) or exactly one, TCP 80 from CloudFront's VPC origin group
# (open). Any other group on the ALB (Auto Mode's shared backend group) has none.
audit_alb_sgs() {
  local sgs sg rules
  sgs="$(aws_r elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].SecurityGroups' --output text)" || die "could not read the security groups of $ALB_ARN"
  grep -qw -- "$ALB_SG_ID" <<<"$sgs" || die "the ALB is not using $ALB_SG_ID (it has: $sgs)"
  for sg in $sgs; do
    # shellcheck disable=SC2016  # a JMESPath literal, not a shell expansion
    rules="$(aws_r ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" \
      --query 'SecurityGroupRules[?IsEgress==`false`]' --output json)" || die "could not read the rules of $sg"
    if [[ "$sg" != "$ALB_SG_ID" || "$1" == closed ]]; then
      [[ "$(jq length <<<"$rules")" -eq 0 ]] || die "security group $sg on the ALB has an inbound rule; expected none"
      echo "  $sg: no inbound rule"
      continue
    fi
    jq -e --arg cf "$CF_SG_ID" 'length == 1 and (.[0] | .IpProtocol == "tcp" and .FromPort == 80
      and .ToPort == 80 and .ReferencedGroupInfo.GroupId == $cf and .CidrIpv4 == null
      and .CidrIpv6 == null and .PrefixListId == null)' <<<"$rules" >/dev/null \
      || die "security group $sg does not hold exactly one inbound rule, TCP 80 from $CF_SG_ID: $(jq -c . <<<"$rules")"
    echo "  $sg: inbound TCP 80 from $CF_SG_ID ($CF_VPC_ORIGIN_SG_NAME) only"
  done
}

# wait_url <url> <code> <minutes> : poll through CloudFront until the URL answers <code>.
wait_url() {
  local start=$SECONDS code
  while :; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
    [[ "$code" == "$2" ]] && break
    (( SECONDS - start > $3 * 60 )) && die "$1 answered '${code:-nothing}', not $2, after $3 minutes"
    sleep 15
  done
  echo "$1 answers $2"
}

# in_coder <program> [args] : run a shell program inside the coderd container. The program
# text holds no secret; anything secret arrives on standard input.
in_coder() { kc exec -i deploy/coder -c coder -- sh -c "$@"; }
