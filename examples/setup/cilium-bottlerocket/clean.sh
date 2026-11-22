#!/usr/bin/env bash
# Delete what one run of this sample created, and nothing else.
#
#   ./clean.sh --dry-run [--run-id <id>]    list the resources of the run; no AWS resource or
#                                           Kubernetes object changes
#   ./clean.sh [--keep-ami] [--run-id <id>] delete them, after you type the cluster name
#
# The run ID defaults to the last run of setup.sh. The script holds the run lock of setup.sh,
# so it never runs beside setup.sh or test.sh of the same run. It finds each resource by its
# tags (ManagedBy=cilium-bottlerocket-sample and RunId=<id>) and by the IDs in the state file,
# so it also cleans a run that stopped part way. Before each delete it reads the tags of that
# resource again. Order (issue #281): (1) workloads, node groups, Cilium ENIs; (2) builder
# instances, their volumes, the builder security group, instance profile and role; (3) launch
# templates; (4) the AMI and its snapshots, unless --keep-ami; (5) the Pod Identity association
# and the cluster stacks (VPC, NAT gateway, Elastic IP address, roles); a cluster delete that EKS
# refuses with 409 "update in progress" runs again, up to 4 tries (CLEAN RETRY). Then it reads every
# resource class and every ID of the state file again, and writes its verdict to
# evidence/clean/verdict.txt. It exits non-zero when a resource remains or a lookup fails.
# shellcheck source=../../../scripts/lib/require-bash.sh
. "$(dirname "$0")/../../../scripts/lib/require-bash.sh"
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"

dry_run=0 keep_ami=0 keep_cluster=0
while (($#)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --keep-ami) keep_ami=1 ;;
    # The run to delete is never taken from current-run when --run-id is given without a value.
    --run-id) [[ -n "${2:-}" && "${2:-}" != -* ]] || die E_USAGE "--run-id needs a run ID"; RUN_ID="$2"; shift ;;
    *) die E_USAGE "usage: ./clean.sh [--dry-run] [--keep-ami] [--run-id <id>]" ;;
  esac
  shift
done
# The same tools and versions as setup.sh (eksctl deletes the stacks it made).
require_tool_versions
require_region
require_caller_account
require_run_id
check_run_record
lock_run
OUT="$EVIDENCE_DIR/clean"
private_dirs "$OUT" || die E_RUN_DIR "could not create $OUT"
: >"$OUT/failures.txt"
reused="$(state_get AMI_REUSED)"

# The VPC of the run, also when the state file is short: from the cluster, else by tags.
state="$(cluster_state)" || exit 1
if [[ "$state" != NONE ]]; then
  require_sample_cluster
  vpc="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.vpcId --output text)" \
    || die E_CLUSTER_READ "could not read the VPC of $CLUSTER_NAME"
else
  vpc="$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:$OWNER_TAG_KEY,Values=$OWNER_TAG_VALUE" \
    "Name=tag:$RUN_TAG_KEY,Values=$RUN_ID" --query 'Vpcs[].VpcId' --output text)" || die E_VPC_READ "could not look up the VPC of run $RUN_ID"
fi
[[ -z "$vpc" || "$vpc" =~ ^vpc-[0-9a-f]+$ ]] || die E_VPC_READ "run $RUN_ID has more than one VPC or a malformed one: '$vpc'"
[[ -z "$vpc" ]] || state_set VPC_ID "$vpc"

# fail <what> [output]: clean_failed, also kept in failures.txt.
fail() { printf '%s\n' "$1" >>"$OUT/failures.txt"; clean_failed "$@"; }
# inventory <file>: every resource of the run, one JSON line each (cilium_bottlerocket.py owned).
inventory() { python3 "$PY" owned >"$1" 2>"$1.err"; }
# ids <file> <class> [field=value]: the IDs of one class in an inventory file, ours only.
ids() {
  python3 -c 'import json, sys
cls, want = sys.argv[2], dict(a.split("=", 1) for a in sys.argv[3:])
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["class"] == cls and r["ours"] and all(str(r.get(k)) == v for k, v in want.items()):
        print(r["id"])' "$@"
}
# state_ids <KEY>...: the IDs that the state file names (comma or space separated).
state_ids() { local k; for k in "$@"; do state_get "$k" | tr -s ', ' '\n'; done | sed '/^$/d'; }
# candidates <file> <class> <KEY>...: inventory IDs plus state-named IDs, each once.
candidates() { { ids "$1" "$2"; state_ids "${@:3}"; } | awk '!seen[$0]++'; }
# delete_if_ours <kind> <id> <command...>: read the tags again, then delete. Each read error is
# kept in its own file.
delete_if_ours() {
  local kind="$1" ident="$2" rc=0 out err="$OUT/recheck-$1-$2.err"
  shift 2
  python3 "$PY" recheck "$kind" "$ident" >/dev/null 2>"$err" || rc=$?
  # Returns 0 when it deleted, 3 when the resource was already gone, 1 otherwise.
  case "$rc" in
    0) if out="$("$@" 2>&1)"; then echo "deleted $kind $ident"; else fail "delete $kind $ident" "$out"; return 1; fi ;;
    3) echo "$kind $ident: already gone"; return 3 ;;
    1) fail "$kind $ident is not tagged for run $RUN_ID; skipped" "$(cat "$err")"; return 1 ;;
    *) fail "could not read $kind $ident before the delete" "$(cat "$err")"; return 1 ;;
  esac
}
eks_tags_ours() { # eks_tags_ours <describe-args...>: 0 ours, 1 not, 2 unknown; the read stays in eks-read.json
  local tags; tags="$(aws eks "$@" --region "$AWS_REGION" --output json)" && printf '%s\n' "$tags" >"$OUT/eks-read.json" || return 2
  python3 -c 'import json,sys; d=json.load(sys.stdin); v=list(d.values())[0]; print(json.dumps(v.get("tags", {})))' <<<"$tags" | tags_match
}
# record_node_role: add the exact nodeRole ARN of the node group read last (proved the run's) to
# NODE_ROLE_ARNS in the state file, before the node group goes. A later clean.sh reads it too.
NODE_ROLE_RX="^arn:aws[a-z-]*:iam::$AWS_ACCOUNT_ID:role/[A-Za-z0-9+=.@_/-]+$"
record_node_role() {
  local arn old
  arn="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["nodegroup"]["nodeRole"])' "$OUT/eks-read.json")" \
    && [[ "$arn" =~ $NODE_ROLE_RX ]] && old="$(state_get NODE_ROLE_ARNS)" || return 1
  [[ ",$old," == *",$arn,"* ]] || state_set NODE_ROLE_ARNS "${old:+$old,}$arn"
}
# finish_clean: read everything back, write the verdict, exit 0 only when nothing remains.
finish_clean() {
  local rc=0 line cls kind key ident r
  step "read back"
  r=0; [[ "$(cluster_state)" == NONE ]] || r=1
  ((r == 0)) || fail "cluster $CLUSTER_NAME still exists"
  inventory "$OUT/after.jsonl" || rc=$?
  if ((rc != 0)); then
    fail "could not list the resources of run $RUN_ID after the deletes" "$(cat "$OUT/after.jsonl.err")"
  else
    while read -r line; do
      cls="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["class"])' "$line")"
      if ((keep_ami)) && [[ "$cls" == ami || "$cls" == ami-snapshot ]]; then echo "kept: $line"; else fail "still there: $line"; fi
    done <"$OUT/after.jsonl"
  fi
  # Each ID the state file names: gone, or reported (also when it lost its tags).
  for pair in instance:BUILDER_INSTANCE_ID volume:BUILDER_VOLUME_IDS security-group:BUILDER_SG_ID network-interface:BUILDER_ENI_IDS \
    launch-template:SYSTEM_LAUNCH_TEMPLATE_ID launch-template:SANDBOX_LAUNCH_TEMPLATE_ID \
    iam-role:BUILDER_ROLE_NAME instance-profile:BUILDER_PROFILE_NAME iam-role:OPERATOR_ROLE_NAME \
    image:SANDBOX_AMI_ID snapshot:SANDBOX_AMI_SNAPSHOT_IDS; do
    kind="${pair%%:*}" key="${pair#*:}"
    if [[ "$kind" == image || "$kind" == snapshot ]] && { ((keep_ami)) || [[ "$reused" == yes ]]; }; then continue; fi
    for ident in $(state_ids "$key"); do
      r=0; python3 "$PY" recheck "$kind" "$ident" >/dev/null 2>"$OUT/readback-$kind-$ident.err" || r=$?
      case "$r" in
        3) ;;
        0) fail "still there ($key): $kind $ident" ;;
        1) fail "left over without the tags of run $RUN_ID ($key): $kind $ident" ;;
        *) fail "could not read $kind $ident ($key) after the deletes" "$(cat "$OUT/readback-$kind-$ident.err")" ;;
      esac
    done
  done
  rc=0; clean_summary "run $RUN_ID of the Cilium on Bottlerocket sample ($CLUSTER_NAME)" || rc=$?
  printf 'run=%s time=%s keep_ami=%s keep_cluster=%s failures=%s verdict=%s\n' "$RUN_ID" "$(date -u +%FT%TZ)" \
    "$keep_ami" "$keep_cluster" "$CLEAN_FAIL" "$( ((rc == 0)) && echo clean || echo incomplete)" >"$OUT/verdict.txt"
  exit "$rc"
}

rc=0; inventory "$OUT/before.jsonl" || rc=$?
((rc == 0)) || { echo "ERROR: E_CLEAN_INVENTORY: could not list the resources of run $RUN_ID" >&2; exit 2; }
if ((dry_run)); then
  step "dry run: the resources of run $RUN_ID that ./clean.sh would delete"
  python3 -c 'import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["ours"]:
        print("  %-28s %s" % (r["class"], r["id"]))' "$OUT/before.jsonl"
  ((keep_ami)) && echo "With --keep-ami, the AMI and its snapshots stay."
  echo "No AWS resource or Kubernetes object was changed. Run ./clean.sh without --dry-run to delete these."
  exit 0
fi
if [[ "${CLEAN_CONFIRM:-}" != "$CLUSTER_NAME" ]]; then
  read -r -p "This deletes run $RUN_ID, cluster $CLUSTER_NAME and its VPC. Type the cluster name to confirm: " answer || answer=""
  [[ "$answer" == "$CLUSTER_NAME" ]] || die E_NOT_CONFIRMED "not confirmed; nothing was deleted"
fi
# The deletes use a list read after the confirm. If that read fails, nothing is deleted.
rc=0; inventory "$OUT/confirmed.jsonl" || rc=$?
((rc == 0)) || { echo "ERROR: E_CLEAN_INVENTORY: could not list the resources of run $RUN_ID after the confirm; nothing was deleted" >&2; exit 2; }

step "1/5 workloads, node groups and the ENIs that Cilium created"
if [[ "$state" != NONE ]]; then
  [[ -f "$KUBECONFIG" ]] || aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --kubeconfig "$KUBECONFIG" --alias "$KUBE_CONTEXT" >/dev/null
  ns_rc=0; namespace_is_ours || ns_rc=$?
  case "$ns_rc" in
    0) if kc delete namespace "$NAMESPACE" --wait=true --timeout=5m >/dev/null; then echo "deleted namespace $NAMESPACE"
       else fail "delete namespace $NAMESPACE"; fi ;;
    3) echo "namespace $NAMESPACE: already gone" ;;
    1) fail "namespace $NAMESPACE is not this sample's; skipped" ;;
    *) fail "could not read namespace $NAMESPACE" ;;
  esac
  rcl="$(kc get runtimeclass isolated-sandbox --ignore-not-found -o "jsonpath={.metadata.labels.${NS_LABEL_KEY//./\\.}}")" \
    || fail "could not read the RuntimeClass isolated-sandbox"
  if [[ "$rcl" == "$NS_LABEL_VAL" ]]; then
    if kc delete runtimeclass isolated-sandbox >/dev/null; then echo "deleted RuntimeClass isolated-sandbox"
    else fail "delete RuntimeClass isolated-sandbox"; fi
  fi
  # A node group that is not the run's, that cannot be read, whose node role cannot be recorded,
  # or whose delete did not finish keeps the cluster: eksctl delete cluster would delete it with the cluster.
  for group in sandbox system; do
    t=0; eks_tags_ours describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$group" || t=$?
    ((t != 0)) || record_node_role || t=3
    case "$t" in
      0) eksctl delete nodegroup --region "$AWS_REGION" --cluster "$CLUSTER_NAME" --name "$group" --disable-eviction --wait \
           || { keep_cluster=1; fail "eksctl delete nodegroup $group did not finish, so the cluster is kept"; } ;;
      1) keep_cluster=1; fail "node group $group is not tagged for run $RUN_ID; skipped, so the cluster is kept" ;;
      3) keep_cluster=1; fail "could not record the node role of node group $group in NODE_ROLE_ARNS; it and the cluster are kept" ;;
      *) if ! aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$group" \
           >/dev/null 2>"$OUT/ng-$group.err" && ! aws_error_is ResourceNotFoundException "$(cat "$OUT/ng-$group.err")"; then
           keep_cluster=1; fail "could not read node group $group, so the cluster is kept" "$(cat "$OUT/ng-$group.err")"
         fi ;;
    esac
  done
fi
inventory "$OUT/after-1.jsonl" || { fail "could not list the resources after step 1; no further delete" "$(cat "$OUT/after-1.jsonl.err")"; finish_clean; }
for eni in $(ids "$OUT/after-1.jsonl" cilium-eni status=available); do
  delete_if_ours network-interface "$eni" aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni"
done

step "2/5 builder instances, their volumes, the builder security group, instance profile and role"
builders="$(candidates "$OUT/after-1.jsonl" builder-instance BUILDER_INSTANCE_ID)"
# Wait only for the instances that this run terminated now: one that is already gone never
# reaches "terminated" in a waiter (EC2 stops listing it about an hour after it ends).
builder_list=()
for i in $builders; do
  r=0; delete_if_ours instance "$i" aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$i" || r=$?
  ((r != 0)) || builder_list+=("$i")
done
((${#builder_list[@]} == 0)) || aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "${builder_list[@]}" \
  || fail "builder instances did not reach terminated: ${builder_list[*]}"
inventory "$OUT/after-2a.jsonl" || { fail "could not list the resources after the builder instances; no further delete" "$(cat "$OUT/after-2a.jsonl.err")"; finish_clean; }
for v in $(candidates "$OUT/after-2a.jsonl" builder-volume BUILDER_VOLUME_IDS); do
  delete_if_ours volume "$v" aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$v"
done
# A builder ENI that is left after its instance went (detached, available), found by its tags or
# by BUILDER_ENI_IDS: deleted like an available Cilium ENI, after its tags are read again.
for eni in $(ids "$OUT/after-2a.jsonl" builder-eni status=available); do
  delete_if_ours network-interface "$eni" aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni"
done
for sg in $(candidates "$OUT/after-2a.jsonl" builder-security-group BUILDER_SG_ID); do
  delete_if_ours security-group "$sg" aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg"
done
# delete_profile, delete_role and delete_stack run through delete_if_ours "$@".
# shellcheck disable=SC2329
delete_profile() { # delete_profile <profile> <role>
  aws iam remove-role-from-instance-profile --instance-profile-name "$1" --role-name "$2" 2>/dev/null
  aws iam delete-instance-profile --instance-profile-name "$1"
}
# shellcheck disable=SC2329
delete_role() { # delete_role <role>: detach managed policies, delete inline ones, then the role
  local p
  for p in $(aws iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$1" --policy-arn "$p" || return 1
  done
  for p in $(aws iam list-role-policies --role-name "$1" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$1" --policy-name "$p" || return 1
  done
  aws iam delete-role --role-name "$1"
}
delete_if_ours instance-profile "$BUILDER_PROFILE_NAME" delete_profile "$BUILDER_PROFILE_NAME" "$BUILDER_ROLE_NAME"
delete_if_ours iam-role "$BUILDER_ROLE_NAME" delete_role "$BUILDER_ROLE_NAME"
# The cluster VPC cannot go while a builder part is there: read each one again first.
sg_left=0 left_why=""
for sg in $(state_ids BUILDER_SG_ID); do
  r=0; python3 "$PY" recheck security-group "$sg" >/dev/null 2>"$OUT/sg-left-$sg.err" || r=$?
  ((r == 3)) || { sg_left=1 left_why="a builder security group remains"; fail "builder security group $sg is still there (or could not be read); the cluster is kept"; }
done
# Each builder ENI that the inventory found (by tags, by BUILDER_ENI_IDS of this or an earlier
# build attempt, or on a builder), whatever its tags, and each one the state file names.
for eni in $({ python3 -c 'import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["class"] == "builder-eni":
        print(r["id"])' "$OUT/after-2a.jsonl"; state_ids BUILDER_ENI_IDS; } | awk '!seen[$0]++'); do
  r=0; python3 "$PY" recheck network-interface "$eni" >/dev/null 2>"$OUT/eni-left-$eni.err" || r=$?
  ((r == 3)) || { sg_left=1 left_why="a builder ENI remains"; fail "builder ENI $eni is still there (or could not be read); the cluster is kept" "$(cat "$OUT/eni-left-$eni.err")"; }
done
if ((sg_left == 0)) && [[ -n "$(state_get BUILDER_INSTANCE_ID)" ]]; then
  r=0; python3 "$PY" builder-gone >"$OUT/builder-gone.txt" 2>&1 || r=$?
  ((r == 0)) || { sg_left=1 left_why="a builder part remains"; fail "builder-gone: a builder part remains or could not be read; the cluster is kept" "$(cat "$OUT/builder-gone.txt")"; }
fi

step "3/5 launch templates"
for lt in $(candidates "$OUT/after-2a.jsonl" launch-template SYSTEM_LAUNCH_TEMPLATE_ID SANDBOX_LAUNCH_TEMPLATE_ID); do
  delete_if_ours launch-template "$lt" aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-id "$lt"
done

step "4/5 the AMI and its snapshots"
if ((keep_ami)); then
  echo "--keep-ami: the AMI and its snapshots stay: $(ids "$OUT/after-2a.jsonl" ami | tr '\n' ' ')$(ids "$OUT/after-2a.jsonl" ami-snapshot | tr '\n' ' ')"
else
  ami_keys=SANDBOX_AMI_ID snap_keys=SANDBOX_AMI_SNAPSHOT_IDS
  # A reused AMI belongs to the run that built it: only its own run deletes it.
  [[ "$reused" != yes ]] || ami_keys="" snap_keys=""
  for ami in $(candidates "$OUT/after-2a.jsonl" ami $ami_keys); do
    delete_if_ours image "$ami" aws ec2 deregister-image --region "$AWS_REGION" --image-id "$ami"
  done
  for snap in $(candidates "$OUT/after-2a.jsonl" ami-snapshot $snap_keys); do
    delete_if_ours snapshot "$snap" aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap"
  done
fi

step "5/5 the Pod Identity association and the cluster stacks"
# delete_stack <name>: delete one CloudFormation stack and wait until it is gone.
# shellcheck disable=SC2329
delete_stack() {
  aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$1" \
    && aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$1"
}
# The cluster delete is tried again only while EKS refuses DeleteCluster with HTTP 409
# "currently has an update in progress". In a live run (#281), after the last node group and the
# Pod Identity association went, EKS refused it from 39 s to at least 2 min 54 s after the
# association delete, list-updates showed no update, and a delete 13 min 27 s after it passed.
# A refused try takes about 4 min (CloudFormation tries DeleteCluster for about 2 min 15 s), so
# 4 tries with 120 s between them reach about 16 min after the first try; no retry starts when it
# would start more than 25 min after the first try. Each wait is 12 x CB_SLEEP_SECONDS (10 s).
CLUSTER_DELETE_TRIES=4 CLUSTER_DELETE_BUDGET=1500
# cluster_delete_refusal <try>: "<event ID> <reason>" of the ControlPlane DELETE_FAILED event of the
# last delete of the cluster stack, or nothing. Non-zero when the events cannot be read.
cluster_delete_refusal() {
  local f="$OUT/cluster-stack-events-$1.json"
  aws cloudformation describe-stack-events --region "$AWS_REGION" --stack-name "eksctl-$CLUSTER_NAME-cluster" \
    --output json >"$f" 2>"$f.err" || return 2
  python3 -c 'import json, sys
events = sorted(json.load(open(sys.argv[1]))["StackEvents"], key=lambda e: e.get("Timestamp", ""), reverse=True)
for e in events:
    if e.get("ResourceType") == "AWS::CloudFormation::Stack" and e.get("ResourceStatus") == "DELETE_IN_PROGRESS":
        break
    if e.get("LogicalResourceId") == "ControlPlane" and e.get("ResourceStatus") == "DELETE_FAILED":
        print(e.get("EventId", ""), " ".join(str(e.get("ResourceStatusReason", "")).split()))
        break' "$f" 2>>"$f.err"
}
# delete_cluster: eksctl delete cluster, again after each new 409 "update in progress" refusal,
# within the bounds above. Any other failure, or events that cannot be read, is not retried.
delete_cluster() {
  local try start=$SECONDS wait=$((12 * ${CB_SLEEP_SECONDS:-10})) refusal="" last="" r
  for ((try = 1; try <= CLUSTER_DELETE_TRIES; try++)); do
    if ((try > 1)); then
      printf 'CLEAN RETRY E_CLUSTER_DELETE_BUSY: eksctl delete cluster, try %d of %d in %d s; EKS answered: %s\n' \
        "$try" "$CLUSTER_DELETE_TRIES" "$wait" "${refusal#* }"
      sleep "$wait"
    fi
    eksctl delete cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --disable-nodegroup-eviction --wait && return 0
    r=0; refusal="$(cluster_delete_refusal "$try")" || r=$?
    if ((r != 0)); then
      fail "eksctl delete cluster $CLUSTER_NAME" "could not read the events of stack eksctl-$CLUSTER_NAME-cluster: $(tail -n 1 "$OUT/cluster-stack-events-$try.json.err")"
      return 1
    fi
    if [[ "$refusal" != *"currently has an update in progress"* || "$refusal" != *"Status Code: 409"* \
      || ( -n "$last" && "${refusal%% *}" == "$last" ) ]]; then
      fail "eksctl delete cluster $CLUSTER_NAME" "${refusal#* }"
      return 1
    fi
    last="${refusal%% *}"
    if ((try == CLUSTER_DELETE_TRIES || SECONDS - start + wait > CLUSTER_DELETE_BUDGET)); then
      fail "eksctl delete cluster $CLUSTER_NAME" "${refusal#* }"
      printf 'ERROR: E_CLUSTER_DELETE_BUSY: EKS still refused DeleteCluster with 409 "update in progress" after %d tries in %d s; run ./clean.sh again later\n' "$try" "$((SECONDS - start))" >&2
      return 1
    fi
  done
}
# cascade_children: eksctl delete cluster deletes every node group, Fargate profile and eksctl stack
# of the cluster, the IAM OIDC provider of its issuer (the sample makes none), and the load balancers
# of its LoadBalancer Services, Ingresses and Gateways; EKS deletes the add-ons, Pod Identity
# associations, access entries and identity provider configs with it. Each must be this run's and
# readable, else it prints why and returns 1, and the cluster is kept. EKS makes three access entry
# kinds with no tag: the creator's (STANDARD), the run's when its principal is the role of the caller
# read at the start; one per managed node group (EC2_LINUX), the run's only when its principal
# is an exact ARN in NODE_ROLE_ARNS (record_node_role), whether that role is live or gone; and the
# entry of the EKS service-linked role (STANDARD), passed only by its exact ARN.
cascade_children() {
  local bad=0 kind name t list role="" creator="" p ty names n r roles rec=0
  foreign() { bad=1; fail "$1 is not this run's; eksctl delete cluster would delete it with the cluster, so the cluster is kept"; }
  unread() { bad=1; fail "could not read $1; the cluster is kept" "${2:-}"; }
  child() { case "$1" in 0) ;; 1) foreign "$2" ;; *) unread "$2" ;; esac; } # child <eks_tags_ours result> <what>
  eks_list() { # eks_list <list call> <query>: the names, one per line; non-zero when the read fails
    aws eks "$1" --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --query "$2" --output text 2>"$OUT/cascade-$1.err" \
      | tr '\t' '\n' | sed '/^None$/d; /^$/d'
    return "${PIPESTATUS[0]}"
  }
  for kind in nodegroup:list-nodegroups:nodegroups addon:list-addons:addons \
    fargate-profile:list-fargate-profiles:fargateProfileNames \
    pod-identity-association:list-pod-identity-associations:associations[].associationId; do
    IFS=: read -r name t list <<<"$kind"
    [[ "$list" == *"[]."* ]] || list="${list}[]"
    if ! names="$(eks_list "$t" "$list")"; then unread "the ${name}s of the cluster" "$(cat "$OUT/cascade-$t.err")"; continue; fi
    for n in $names; do
      r=0
      case "$name" in
        nodegroup) eks_tags_ours describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$n" || r=$? ;;
        addon) eks_tags_ours describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$n" || r=$? ;;
        fargate-profile) eks_tags_ours describe-fargate-profile --cluster-name "$CLUSTER_NAME" --fargate-profile-name "$n" || r=$? ;;
        *) eks_tags_ours describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$n" || r=$? ;;
      esac
      child "$r" "$name $n"
    done
  done
  if ! names="$(eks_list list-identity-provider-configs 'identityProviderConfigs[].name')"; then
    unread "the identity provider configs of the cluster" "$(cat "$OUT/cascade-list-identity-provider-configs.err")"
  else
    for n in $names; do
      r=0
      t="$(aws eks describe-identity-provider-config --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
        --identity-provider-config "type=oidc,name=$n" --query identityProviderConfig.oidc.tags --output json)" || r=2
      ((r != 0)) || tags_match <<<"$t" || r=$?
      child "$r" "identity provider config $n"
    done
  fi
  # An IAM OIDC provider whose URL is the cluster issuer (compared without case) is not this run's.
  if ! t="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --query cluster.identity.oidc.issuer \
    --output text 2>"$OUT/cascade-oidc.err")" || ! aws iam list-open-id-connect-providers --output json \
    >"$OUT/cascade-oidc.json" 2>>"$OUT/cascade-oidc.err" || ! names="$(python3 -c 'import json, re, sys
iss = sys.argv[1]
re.fullmatch(r"https://[^\s/]+/\S+", iss) or sys.exit("malformed cluster issuer: %r" % iss)
for x in json.load(open(sys.argv[2]))["OpenIDConnectProviderList"]:
    m = re.fullmatch(r"arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/(\S+)", x["Arn"]) or sys.exit("malformed provider: %r" % x)
    m.group(1).lower() == iss[8:].lower() and print(x["Arn"])' "$t" "$OUT/cascade-oidc.json" 2>>"$OUT/cascade-oidc.err")"; then
    unread "the IAM OIDC providers and the cluster issuer" "$(cat "$OUT/cascade-oidc.err")"
  else
    for n in $names; do foreign "IAM OIDC provider $n (the cluster issuer)"; done
  fi
  # The access entries. The caller is an assumed role (arn:aws:sts::<account>:assumed-role/<role>/
  # <session>), whose access entry names the role, or an IAM role or user named as it is.
  if [[ "${CALLER_ARN:-}" =~ ^arn:aws:sts::$AWS_ACCOUNT_ID:assumed-role/([^/]+)/ ]]; then role="${BASH_REMATCH[1]}"
  elif [[ "${CALLER_ARN:-}" =~ ^arn:aws:iam::$AWS_ACCOUNT_ID:(role|user)/ ]]; then creator="$CALLER_ARN"; fi
  # The node role record: rec 0 read, 1 none, 2 unreadable or an element that is not a role ARN.
  roles="$(state_get NODE_ROLE_ARNS)" || rec=2
  ((rec)) || [[ -n "$roles" ]] || rec=1
  ((rec)) || while read -r n; do [[ "$n" =~ $NODE_ROLE_RX ]] || rec=2; done < <(tr ',' '\n' <<<"$roles")
  if ! names="$(eks_list list-access-entries 'accessEntries[]')"; then
    unread "the access entries of the cluster" "$(cat "$OUT/cascade-list-access-entries.err")"
  else
    for p in $names; do
      r=0; eks_tags_ours describe-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$p" || r=$?
      ((r == 0)) && continue
      ((r == 1)) || { unread "access entry $p"; continue; }
      ty="$(aws eks describe-access-entry --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --principal-arn "$p" \
        --query accessEntry.type --output text 2>/dev/null)" || { unread "access entry $p"; continue; }
      n=""; [[ "$p" =~ ^arn:aws:iam::$AWS_ACCOUNT_ID:role/(.+/)?([^/]+)$ ]] && n="${BASH_REMATCH[2]}"
      if [[ "$ty" == EC2_LINUX ]]; then   # a node role entry: see the comment of cascade_children
        case "$rec" in
          0) [[ ",$roles," == *",$p,"* ]] || foreign "access entry $p (type EC2_LINUX, not in the node role record NODE_ROLE_ARNS)" ;;
          1) foreign "access entry $p (type EC2_LINUX; the run has no node role record NODE_ROLE_ARNS)" ;;
          *) unread "the node role record NODE_ROLE_ARNS in $RUN_STATE_FILE, for access entry $p" ;;
        esac
        continue
      fi
      if [[ "$ty" == STANDARD && ( ( -n "$role" && "$n" == "$role" ) || ( -n "$creator" && "$p" == "$creator" ) ) ]]; then
        continue   # the creator entry, for the caller of this clean up
      fi
      # The entry of the EKS service-linked role, by its exact ARN: EKS creates it with the cluster,
      # no caller can create an access entry that names a service-linked role (Amazon EKS User Guide,
      # "Create access entries", https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html),
      # and EKS deletes it with the cluster.
      if [[ "$ty" == STANDARD && "$p" == "arn:aws:iam::$AWS_ACCOUNT_ID:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS" ]]; then
        continue
      fi
      foreign "access entry $p (type $ty)"
    done
  fi
  # The eksctl stacks of the cluster (inventory after step 2) that are not the run's.
  for n in $(python3 -c 'import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["class"] == "cfn-stack" and not r["ours"]:
        print(r["id"])' "$OUT/after-2a.jsonl"); do
    foreign "stack $n"
  done
  # Kubernetes objects whose AWS load balancers eksctl deletes. The sample makes none.
  if ! kc get services -A -o json >"$OUT/cascade-services.json" 2>"$OUT/cascade-services.err" \
    || ! t="$(python3 -c 'import json, sys
for s in json.load(open(sys.argv[1]))["items"]:
    if (s.get("spec") or {}).get("type") == "LoadBalancer":
        print(s["metadata"].get("namespace", "") + "/" + s["metadata"]["name"])' "$OUT/cascade-services.json" 2>>"$OUT/cascade-services.err")"; then
    unread "the Services of the cluster" "$(cat "$OUT/cascade-services.err")"
  else
    for n in $t; do foreign "Service $n of type LoadBalancer"; done
  fi
  for kind in ingresses.networking.k8s.io gateways.gateway.networking.k8s.io; do
    if t="$(kc get "$kind" -A -o name 2>"$OUT/cascade-$kind.err")"; then
      for n in $t; do foreign "$n"; done
    elif ! grep -qx "error: the server doesn't have a resource type \"${kind%%.*}\"" "$OUT/cascade-$kind.err"; then
      unread "the $kind of the cluster" "$(cat "$OUT/cascade-$kind.err")"
    fi
  done
  ((bad == 0))
}
if ((sg_left)); then
  keep_cluster=1
  fail "the cluster and its VPC are kept, because $left_why"
elif [[ "$state" != NONE ]]; then
  cascade_children || keep_cluster=1
  # An association that is not the run's, or that cannot be read, keeps the cluster too.
  for assoc in $(ids "$OUT/after-2a.jsonl" pod-identity-association); do
    t=0; eks_tags_ours describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$assoc" || t=$?
    if ((t == 0)); then
      if aws eks delete-pod-identity-association --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
        --association-id "$assoc" >/dev/null; then
        echo "deleted Pod Identity association $assoc"
      else
        fail "delete Pod Identity association $assoc"
      fi
    else
      keep_cluster=1
      fail "Pod Identity association $assoc is not tagged for run $RUN_ID, or could not be read; skipped, so the cluster is kept"
    fi
  done
  if ((keep_cluster)); then
    fail "the cluster $CLUSTER_NAME and its VPC are kept, because a resource in it is not this run's or could not be read"
  else
    require_sample_cluster
    delete_cluster
  fi
else
  # The cluster is gone, but its eksctl stacks can remain (a run that stopped during eksctl
  # create cluster, or a delete that stopped). Delete each stack of this cluster that is the
  # run's, the node group and Pod Identity role stacks first and the cluster stack last.
  stacks="$(ids "$OUT/after-2a.jsonl" cfn-stack)"
  for s in $(grep -v -x "eksctl-$CLUSTER_NAME-cluster" <<<"$stacks") "eksctl-$CLUSTER_NAME-cluster"; do
    delete_if_ours stack "$s" delete_stack "$s"
  done
fi
# The operator role goes only with the cluster: while the cluster stays, its operator keeps it.
if [[ "$(cluster_state)" == NONE ]]; then
  r=0; out="$(aws iam get-role --role-name "$OPERATOR_ROLE_NAME" 2>&1)" || r=$?
  if ((r == 0)); then
    delete_if_ours iam-role "$OPERATOR_ROLE_NAME" delete_role "$OPERATOR_ROLE_NAME"
  elif ! aws_error_is NoSuchEntity "$out"; then
    printf '%s\n' "$out" >"$OUT/oprole-read.err"
    fail "could not read role $OPERATOR_ROLE_NAME" "$out"
  fi
fi
finish_clean
