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
# and the cluster stacks (VPC, NAT gateway, Elastic IP address, roles). Then it reads every
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
eks_tags_ours() { # eks_tags_ours <describe-args...>: 0 ours, 1 not, 2 unknown
  local tags; tags="$(aws eks "$@" --region "$AWS_REGION" --output json)" || return 2
  python3 -c 'import json,sys; d=json.load(sys.stdin); v=list(d.values())[0]; print(json.dumps(v.get("tags", {})))' <<<"$tags" | tags_match
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
  for pair in instance:BUILDER_INSTANCE_ID volume:BUILDER_VOLUME_IDS security-group:BUILDER_SG_ID \
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
  # A node group that is not the run's, that cannot be read, or whose delete did not finish
  # keeps the cluster: eksctl delete cluster would delete it with the cluster.
  for group in sandbox system; do
    t=0; eks_tags_ours describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$group" || t=$?
    case "$t" in
      0) eksctl delete nodegroup --region "$AWS_REGION" --cluster "$CLUSTER_NAME" --name "$group" --disable-eviction --wait \
           || { keep_cluster=1; fail "eksctl delete nodegroup $group did not finish, so the cluster is kept"; } ;;
      1) keep_cluster=1; fail "node group $group is not tagged for run $RUN_ID; skipped, so the cluster is kept" ;;
      *) if ! aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$group" \
           >/dev/null 2>"$OUT/ng-$group.err" && ! grep -q ResourceNotFoundException "$OUT/ng-$group.err"; then
           keep_cluster=1; fail "could not read node group $group, so the cluster is kept"
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
if ((sg_left)); then
  keep_cluster=1
  fail "the cluster and its VPC are kept, because $left_why"
elif [[ "$state" != NONE ]]; then
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
    eksctl delete cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --disable-nodegroup-eviction --wait \
      || fail "eksctl delete cluster $CLUSTER_NAME"
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
  elif ! grep -q NoSuchEntity <<<"$out"; then
    printf '%s\n' "$out" >"$OUT/oprole-read.err"
    fail "could not read role $OPERATOR_ROLE_NAME" "$out"
  fi
fi
finish_clean
