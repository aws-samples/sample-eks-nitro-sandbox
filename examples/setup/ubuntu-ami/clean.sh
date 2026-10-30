#!/usr/bin/env bash
# clean.sh: remove what ONE run of this sample created. Every AWS resource the sample creates
# carries two tags, ManagedBy=<RESOURCE_PREFIX> and RunId=<RUN_ID>; this script lists, and
# deletes, only resources that carry BOTH for the run named, and re-reads both tags of each
# resource immediately before deleting it. A lookup that fails is "could not determine", never
# "gone", and leaves the clean up incomplete (exit 1).
#
#   ./clean.sh --dry-run                       # list this run's resources; change nothing
#   ./clean.sh                                 # remove this run's Kubernetes workload only
#   ./clean.sh --delete-aws-resources          # also remove this run's AWS resources
#   ./clean.sh --delete-aws-resources --keep-ami
#                                              # the same, but keep the run's AMI and its
#                                              #   snapshot (issue #11 builds on that AMI)
#   ./clean.sh --run-id <id> ...               # a run other than the last one setup.sh started
#   ./clean.sh --list-runs                     # every marked resource, grouped by RunId; read
#                                              #   only, needs no run id (for a lost run id)
#   ./clean.sh --run-id <id> --lost-run ...    # a run this checkout has no folder for (found
#                                              #   with --list-runs): no run lock can be taken
#
# The run is the one recorded in the run state ($OUT_DIR/run-state.env, the repository's
# gitignored tmp/issue10/run/out/run-state.env by default), or the one --run-id names. With
# neither, nothing is deleted: only --list-runs works, and it changes nothing. A run this
# checkout has a folder for is locked first (the same lock setup.sh and test.sh take, in this
# checkout only), and its record must name this CLUSTER_NAME and AWS_REGION; --list-runs takes no
# lock. A run with no folder here has no lock to take: --dry-run still lists it, and any clean up
# that changes something needs --lost-run, the reader's word that nothing else acts on the run.
#
# kubectl runs only with --context "$KUBE_CONTEXT", checked against CLUSTER_NAME's API endpoint
# before the namespace is touched. IAM roles and the instance profile are found by their per-run
# names through IAM (the Resource Groups Tagging API does not list IAM roles). The access entry
# EKS creates for the node role (it has no tags, and EKS keeps it after the role is deleted) is
# found by that role's ARN, and deleted only while the role still carries both tags.
#
# Never removed, because they are not the sample's: the vpc-cni add-on and the isolated-sandbox
# RuntimeClass (shared installs the reader set up; the README says how to remove the add-on).
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SAMPLE_DIR/scripts/lib/common.sh"

DRY_RUN=0; DELETE_AWS=0; KEEP_AMI=0; LIST_RUNS=0; LOST_RUN=0; RUN_ID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --delete-aws-resources) DELETE_AWS=1 ;;
    --keep-ami) KEEP_AMI=1 ;;
    --list-runs) LIST_RUNS=1 ;;
    --lost-run) LOST_RUN=1 ;;
    --run-id) [ $# -ge 2 ] || die "--run-id needs a value"; RUN_ID="$2"; RUN_ID_ARG="$2"; shift ;;
    --run-id=*) RUN_ID="${1#--run-id=}"; RUN_ID_ARG="$RUN_ID" ;;
    *) die "unknown argument: $1 (supported: --dry-run, --delete-aws-resources, --keep-ami, --run-id <id>, --lost-run, --list-runs)" ;;
  esac
  shift
done
[[ "$RESOURCE_PREFIX" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "RESOURCE_PREFIX '$RESOURCE_PREFIX' must be lowercase letters, digits and hyphens"
[[ "$KEEP_AMI" == 0 || "$DELETE_AWS" == 1 || "$DRY_RUN" == 1 ]] || die "--keep-ami goes with --delete-aws-resources (or --dry-run)"

incomplete=0
warn_inc() { printf 'warning: %s\n' "$*" >&2; incomplete=1; }
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT

# --list-runs: read only, and needs no run id. Lists every resource marked
# ManagedBy=<RESOURCE_PREFIX>, grouped by its RunId, so a reader who lost the run id can find what
# a run left behind and then clean it with --run-id. Nothing is deleted in this mode.
if [[ "$LIST_RUNS" == 1 ]]; then
  [[ "$DRY_RUN$DELETE_AWS$KEEP_AMI$LOST_RUN" == 0000 && -z "${RUN_ID_ARG:-}" ]] || die "--list-runs takes no other option"
  rows=""
  lr() { # lr <kind> <python expr giving [(id, tags)]> <aws args...>
    local kind="$1" expr="$2" js; shift 2
    if ! js=$(aws "$@" --region "$AWS_REGION" --output json 2>"$ERR"); then
      warn_inc "could not determine the marked $kind (lookup failed): $(head -n 2 "$ERR")"; return
    fi
    # Only resources whose tags were read and carry ManagedBy=<RESOURCE_PREFIX> and a well-formed
    # RunId are listed; the EC2 and S3 lookups also filter on ManagedBy on the server side.
    rows+="$(printf '%s' "$js" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
for rid, tags in eval(sys.argv[1], {"d": d}):
    t = tags if isinstance(tags, dict) else {x["Key"]: x["Value"] for x in tags or []}
    if t.get(sys.argv[4]) == sys.argv[5] and re.fullmatch(r"[a-z0-9]{1,20}", t.get(sys.argv[2], "")):
        print("%s\t%s\t%s" % (t[sys.argv[2]], sys.argv[3], rid))
' "$expr" "$TAGS_RUN_KEY" "$kind" "$TAGS_OWNER_KEY" "$TAGS_OWNER_VALUE")"$'\n'
  }
  MB="Name=tag:${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}"
  lr "EC2 instance" '[(x["InstanceId"], x.get("Tags", [])) for r in d["Reservations"] for x in r["Instances"] if x["State"]["Name"] != "terminated"]' ec2 describe-instances --filters "$MB"
  lr "EBS volume" '[(x["VolumeId"], x.get("Tags", [])) for x in d["Volumes"]]' ec2 describe-volumes --filters "$MB"
  lr AMI '[(x["ImageId"], x.get("Tags", [])) for x in d["Images"]]' ec2 describe-images --owners self --filters "$MB"
  lr "EBS snapshot" '[(x["SnapshotId"], x.get("Tags", [])) for x in d["Snapshots"]]' ec2 describe-snapshots --owner-ids self --filters "$MB"
  lr "security group" '[(x["GroupId"], x.get("Tags", [])) for x in d["SecurityGroups"]]' ec2 describe-security-groups --filters "$MB"
  lr "launch template" '[(x["LaunchTemplateId"], x.get("Tags", [])) for x in d["LaunchTemplates"]]' ec2 describe-launch-templates --filters "$MB"
  lr "S3 bucket" '[(m["ResourceARN"].split(":::", 1)[-1], m.get("Tags", [])) for m in d["ResourceTagMappingList"]]' \
    resourcegroupstaggingapi get-resources --resource-type-filters s3 --tag-filters "Key=${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}"
  # IAM roles and node groups by their per-run name pattern, then their own tags.
  if js=$(aws iam list-roles --output json 2>"$ERR"); then
    for r in $(printf '%s' "$js" | json_get "[x['RoleName'] for x in d['Roles'] if __import__('re').fullmatch(r'${RESOURCE_PREFIX}-[a-z0-9]{1,20}-(build|node)', x['RoleName'])]"); do
      lr "IAM role" "[(\"$r\", d[\"Tags\"])]" iam list-role-tags --role-name "$r"
    done
  else
    warn_inc "could not determine the marked IAM roles (list-roles failed): $(head -n 2 "$ERR")"
  fi
  if js=$(aws iam list-instance-profiles --output json 2>"$ERR"); then
    for r in $(printf '%s' "$js" | json_get "[x['InstanceProfileName'] for x in d['InstanceProfiles'] if __import__('re').fullmatch(r'${RESOURCE_PREFIX}-[a-z0-9]{1,20}-build', x['InstanceProfileName'])]"); do
      lr "IAM instance profile" "[(\"$r\", d[\"Tags\"])]" iam list-instance-profile-tags --instance-profile-name "$r"
    done
  else
    warn_inc "could not determine the marked instance profiles (list-instance-profiles failed): $(head -n 2 "$ERR")"
  fi
  if js=$(aws eks list-nodegroups --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --output json 2>"$ERR"); then
    for n in $(printf '%s' "$js" | json_get "[x for x in d['nodegroups'] if __import__('re').fullmatch(r'${RESOURCE_PREFIX}-[a-z0-9]{1,20}-ng', x)]"); do
      lr "EKS node group" "[(\"$n\", d[\"nodegroup\"].get(\"tags\", {}))]" eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$n"
    done
  else
    warn_inc "could not determine the marked node groups of $CLUSTER_NAME (list-nodegroups failed): $(head -n 2 "$ERR")"
  fi
  echo "== resources marked ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} in $AWS_REGION, by ${TAGS_RUN_KEY} =="
  printf '%s' "$rows" | awk -F'\t' 'NF == 3' | sort | awk -F'\t' '$1 != run { run = $1; print "run " run ":" } { print "  " $2 " " $3 }'
  [ -n "$(printf '%s' "$rows" | awk 'NF')" ] || echo "  (none)"
  echo
  echo "--list-runs: nothing was deleted. Remove a run's resources with ./clean.sh --run-id <id> --delete-aws-resources."
  [[ "$incomplete" -eq 0 ]] || { echo "Some lookups failed; the list above is incomplete." >&2; exit 1; }
  exit 0
fi
require_run_id
# The run's lock, before any of its resources is read or changed: a run setup.sh or test.sh is
# acting on in this checkout is refused, and neither can start on it here while this runs. A run
# this checkout has a record of must match it (names, cluster and Region). A run with no folder
# here (a lost run id found with --list-runs, or a run another checkout or machine started) has
# no lock this script can take: a --dry-run lists it read only, and anything else stops here,
# before any call, unless the reader passes --lost-run.
if [ -d "$RUN_STATE_DIR" ]; then
  lock_run
  if [ -f "$RUN_STATE_DIR/run-state.env" ]; then check_run_record
  else log "run $RUN_ID has a folder but no record in this checkout; acting on its tags alone"; fi
elif [[ "$DRY_RUN" == 1 ]]; then
  log "run $RUN_ID has no folder in this checkout: no run lock could be taken; --dry-run lists its resources by their tags and changes nothing"
elif [[ "$LOST_RUN" == 0 ]]; then
  die "run $RUN_ID has no folder in this checkout, so its run lock cannot be taken here, and setup.sh or test.sh may be acting on it from another checkout or machine. Nothing was changed. Make sure nothing else acts on run $RUN_ID anywhere, then re-run with --lost-run (./clean.sh --dry-run --run-id $RUN_ID shows what it would remove)."
else
  warn "--lost-run: run $RUN_ID has no folder in this checkout, so no active-run lock can be verified from another checkout or machine. You must make sure no setup.sh or test.sh is acting on run $RUN_ID anywhere; this clean up proceeds on the run's tags alone."
fi
FILTERS=("Name=tag:${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}" "Name=tag:${TAGS_RUN_KEY},Values=${RUN_ID}")
UNKNOWN="<could not determine>"

# aws_json <var> <what> <aws args...>: the call's JSON in <var>, or $UNKNOWN (and the clean up
# marked incomplete) when the call fails.
aws_json() {
  local __v="$1" what="$2" out; shift 2
  if out=$(aws "$@" --region "$AWS_REGION" --output json 2>"$ERR"); then
    printf -v "$__v" '%s' "$out"
  else
    warn_inc "could not determine $what (lookup failed, not a report that none exist): $(head -n 2 "$ERR")"
    printf -v "$__v" '%s' "$UNKNOWN"
  fi
}
# list <var> <what> <python expr producing a list> <aws args...>
list() {
  local __v="$1" what="$2" expr="$3" js; shift 3
  aws_json js "$what" "$@"
  if [ "$js" = "$UNKNOWN" ]; then printf -v "$__v" '%s' "$UNKNOWN"; return; fi
  printf -v "$__v" '%s' "$(printf '%s' "$js" | json_get "$expr")"
}
name_tag='next((t["Value"] for t in x.get("Tags", []) if t["Key"] == "Name"), "-")'
# list_volumes: this run's EBS volumes (the launch specs tag every instance's volumes), with state.
list_volumes() {
  list volumes "this run's EBS volumes" "[(x[\"VolumeId\"], x[\"State\"]) for x in d[\"Volumes\"]]" \
    ec2 describe-volumes --filters "${FILTERS[@]}"
}
list_all() {
  list instances "this run's EC2 instances" \
    "[(x[\"InstanceId\"], x[\"State\"][\"Name\"], $name_tag) for r in d[\"Reservations\"] for x in r[\"Instances\"] if x[\"State\"][\"Name\"] != \"terminated\"]" \
    ec2 describe-instances --filters "${FILTERS[@]}"
  list_volumes
  list images "this run's AMIs" "[(x[\"ImageId\"], x.get(\"Name\", \"-\")) for x in d[\"Images\"]]" \
    ec2 describe-images --owners self --filters "${FILTERS[@]}"
  list snapshots "this run's EBS snapshots" "[(x[\"SnapshotId\"], x.get(\"VolumeSize\", \"-\")) for x in d[\"Snapshots\"]]" \
    ec2 describe-snapshots --owner-ids self --filters "${FILTERS[@]}"
  list sgs "this run's security groups" "[(x[\"GroupId\"], x[\"GroupName\"]) for x in d[\"SecurityGroups\"]]" \
    ec2 describe-security-groups --filters "${FILTERS[@]}"
  list lts "this run's launch templates" "[(x[\"LaunchTemplateId\"], x[\"LaunchTemplateName\"]) for x in d[\"LaunchTemplates\"]]" \
    ec2 describe-launch-templates --filters "${FILTERS[@]}"
  list buckets "this run's S3 staging buckets" "[m[\"ResourceARN\"].split(\":::\", 1)[-1] for m in d[\"ResourceTagMappingList\"]]" \
    resourcegroupstaggingapi get-resources --resource-type-filters s3 \
    --tag-filters "Key=${TAGS_OWNER_KEY},Values=${TAGS_OWNER_VALUE}" "Key=${TAGS_RUN_KEY},Values=${RUN_ID}"
  # The bucket name setup.sh recorded for this run is checked too, in case the tagging API has
  # not caught up with it yet (bucket_state re-reads its tags before anything is deleted).
  local recorded
  recorded=$(sed -n "s/^export STAGE_BUCKET=//p" "$RUN_STATE_DIR/stage.env" 2>/dev/null | tail -n 1)
  if [[ "$recorded" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ && "$buckets" != "$UNKNOWN" ]]; then
    buckets=$(printf '%s\n%s\n' "$buckets" "$recorded" | awk 'NF' | sort -u)
  fi
  # IAM roles and the instance profile are read by their per-run names through IAM itself: the
  # Resource Groups Tagging API's GetResources does not support IAM roles.
  iam_state role_build role "$BUILD_ROLE_NAME"
  iam_state role_node role "$NODE_ROLE_NAME"
  iam_state profile_build profile "$INSTANCE_PROFILE"
  nodegroup_state ng_state
  access_entry_state ae_node
}
# access_entry_state <var>: the principal ARN of the cluster's access entry for exactly this run's
# node role (none, or one: an IAM principal has at most one entry), or $UNKNOWN. EKS creates that
# entry for the managed node group and does not delete it with the node group or the role (Amazon
# EKS User Guide, *Create access entries*), and it carries no tags, so it is found by the role's
# per-run name and shown to be this run's by the role's own tags.
access_entry_state() {
  local __v="$1" js
  aws_json js "the access entries of cluster $CLUSTER_NAME" eks list-access-entries --cluster-name "$CLUSTER_NAME"
  if [ "$js" = "$UNKNOWN" ]; then printf -v "$__v" '%s' "$UNKNOWN"; return; fi
  printf -v "$__v" '%s' "$(printf '%s' "$js" | json_get "[x for x in d['accessEntries'] if __import__('re').fullmatch(r'arn:aws[a-z-]*:iam::[0-9]{12}:role/${NODE_ROLE_NAME}', x)]")"
}
# iam_state <var> <role|profile> <name>: "absent", "owned", "not-owned", or $UNKNOWN (and the
# clean up marked incomplete) when the tags cannot be read for a reason other than NoSuchEntity.
iam_state() {
  local __v="$1" kind="$2" name="$3" st
  st=$(recheck "$kind" "$name")
  case "$st" in
    match) printf -v "$__v" '%s' owned ;;
    mismatch) printf -v "$__v" '%s' not-owned ;;
    gone) printf -v "$__v" '%s' absent ;;
    *) warn_inc "could not determine IAM $kind $name (the lookup failed, not a report that it is absent): $(head -n 2 "$ERR")"
       printf -v "$__v" '%s' "$UNKNOWN" ;;
  esac
}
# nodegroup_state <var>: "absent", "owned <status>", "not-owned", or $UNKNOWN.
nodegroup_state() {
  local __v="$1" out
  if out=$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
             --nodegroup-name "$NODEGROUP_NAME" --output json 2>"$ERR"); then
    if printf '%s' "$out" | json_pick 'd["nodegroup"].get("tags", {})' | tags_match; then
      printf -v "$__v" 'owned %s' "$(printf '%s' "$out" | json_get 'd["nodegroup"].get("status", "?")')"
    else
      printf -v "$__v" '%s' "not-owned"
    fi
  elif aws_err_is "$ERR" ResourceNotFoundException; then
    printf -v "$__v" '%s' "absent"
  else
    warn_inc "could not determine node group $NODEGROUP_NAME: $(head -n 2 "$ERR")"
    printf -v "$__v" '%s' "$UNKNOWN"
  fi
}
# recheck <kind> <id>: read the resource's tags again, by id, right before a delete. Prints
# match | mismatch | gone | error.
recheck() {
  local kind="$1" id="$2" args expr nf out
  case "$kind" in
    instance) args=(ec2 describe-instances --instance-ids "$id"); expr='d["Reservations"][0]["Instances"][0].get("Tags", [])'; nf=InvalidInstanceID.NotFound ;;
    volume)   args=(ec2 describe-volumes --volume-ids "$id"); expr='d["Volumes"][0].get("Tags", [])'; nf=InvalidVolume.NotFound ;;
    image)    args=(ec2 describe-images --image-ids "$id"); expr='d["Images"][0].get("Tags", [])'; nf=InvalidAMIID.NotFound ;;
    snapshot) args=(ec2 describe-snapshots --snapshot-ids "$id"); expr='d["Snapshots"][0].get("Tags", [])'; nf=InvalidSnapshot.NotFound ;;
    sg)       args=(ec2 describe-security-groups --group-ids "$id"); expr='d["SecurityGroups"][0].get("Tags", [])'; nf=InvalidGroup.NotFound ;;
    lt)       args=(ec2 describe-launch-templates --launch-template-ids "$id"); expr='d["LaunchTemplates"][0].get("Tags", [])'; nf=InvalidLaunchTemplateId.NotFound ;;
    role)     args=(iam list-role-tags --role-name "$id"); expr='d["Tags"]'; nf=NoSuchEntity ;;
    profile)  args=(iam list-instance-profile-tags --instance-profile-name "$id"); expr='d["Tags"]'; nf=NoSuchEntity ;;
    *) echo error; return ;;
  esac
  if out=$(aws "${args[@]}" --region "$AWS_REGION" --output json 2>"$ERR"); then
    if printf '%s' "$out" | json_pick "$expr" 2>/dev/null | tags_match; then echo match; else echo mismatch; fi
  elif aws_err_is "$ERR" "$nf"; then
    echo gone
  else
    echo error
  fi
}
# owned_then <kind> <id> <description> <command...>: run the delete only when the re-check says
# the resource still carries both tags.
owned_then() {
  local kind="$1" id="$2" what="$3" st; shift 3
  st=$(recheck "$kind" "$id")
  case "$st" in
    match) "$@" >/dev/null 2>"$ERR" || warn_inc "could not delete $what: $(head -n 2 "$ERR")" ;;
    gone)
      # In the IAM chain (OWNED_GONE_FAILS=1) a role or profile that was listed a moment ago and
      # is gone now was changed by someone else: the clean up says so and is incomplete (RR2-001).
      if [ "${OWNED_GONE_FAILS:-0}" = 1 ]; then warn_inc "$what disappeared after it was listed, before this clean up changed it; stopped"
      else echo "$what is already gone."; fi ;;
    mismatch) warn_inc "$what no longer carries ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; refusing to delete it" ;;
    *) warn_inc "could not re-read the tags of $what before deleting it; left in place" ;;
  esac
  [ "$st" = match ]
}

echo "== run $RUN_ID: resources tagged ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID} in $AWS_REGION =="
list_all

# --keep-ami: the run's AMIs and the snapshots behind them stay, and are reported as kept. When
# the AMIs, or the snapshots behind any one of them, cannot be read, no snapshot is deleted at
# all (kept_unknown=1) and the clean up is incomplete: a snapshot that might back a kept AMI is
# never put up for deletion.
kept_images=""; kept_snaps=""; kept_unknown=0
if [[ "$KEEP_AMI" == 1 && "$images" == "$UNKNOWN" ]]; then
  kept_unknown=1
elif [[ "$KEEP_AMI" == 1 && -n "$images" ]]; then
  kept_images="$images"
  for img in $(printf '%s\n' "$images" | awk '{print $1}'); do
    aws_json idesc "the snapshots behind AMI $img" ec2 describe-images --image-ids "$img"
    if [ "$idesc" = "$UNKNOWN" ]; then kept_unknown=1; continue; fi
    isnaps="$(printf '%s' "$idesc" | json_get '[b["Ebs"]["SnapshotId"] for x in d["Images"] for b in x.get("BlockDeviceMappings", []) if "Ebs" in b and b["Ebs"].get("SnapshotId")]')"
    if [ -z "$isnaps" ]; then warn_inc "could not determine the snapshots behind kept AMI $img (it lists none)"; kept_unknown=1; continue; fi
    kept_snaps+="$isnaps"$'\n'
  done
fi
is_kept_snap() { printf '%s\n' "$kept_snaps" | grep -qxF -- "$1"; }
show() { echo "$1:"; if [ -z "$2" ]; then echo "  (none)"; else printf '%s\n' "$2" | sed 's/^/  /'; fi; }
show "EC2 instances" "$instances"
show "EBS volumes" "$volumes"
if [[ "$KEEP_AMI" == 1 && "$images" != "$UNKNOWN" ]]; then
  show "AMIs" "${images:+$(printf '%s\n' "$images" | sed 's/$/   left in place (kept on request)/')}"
else
  show "AMIs" "$images"
fi
snap_lines=""
if [ "$snapshots" != "$UNKNOWN" ] && [ -n "$snapshots" ]; then
  while read -r sid size; do
    [ -n "$sid" ] || continue
    if is_kept_snap "$sid"; then snap_lines+="$sid $size   left in place (kept on request)"$'\n'; else snap_lines+="$sid $size"$'\n'; fi
  done <<< "$snapshots"
  snap_lines="${snap_lines%$'\n'}"
else
  snap_lines="$snapshots"
fi
show "EBS snapshots" "$snap_lines"
show "Security groups" "$sgs"
show "Launch templates" "$lts"
show "S3 staging buckets" "$buckets"
echo "IAM (by this run's names):"
printf '  role %s: %s\n  role %s: %s\n  instance profile %s: %s\n' "$BUILD_ROLE_NAME" "$role_build" \
  "$NODE_ROLE_NAME" "$role_node" "$INSTANCE_PROFILE" "$profile_build"
echo "EKS managed node group $NODEGROUP_NAME: $ng_state"
echo "EKS access entry for role $NODE_ROLE_NAME: ${ae_node:-none}"
echo "Left in place (shared, not the sample's): the vpc-cni add-on and the isolated-sandbox RuntimeClass on cluster $CLUSTER_NAME"

if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "--dry-run: nothing was deleted."
  [[ "$incomplete" -eq 0 ]] || { echo "Some lookups failed; the list above is incomplete." >&2; exit 1; }
  exit 0
fi

echo
echo "== deleting the validation workload (namespace $NAMESPACE) =="
# The first change this script makes: stop here, with nothing deleted, unless KUBE_CONTEXT is set
# and is cluster CLUSTER_NAME (every kubectl call passes --context "$KUBE_CONTEXT").
require_kube_context
if ns_json=$(kc get namespace "$NAMESPACE" -o json 2>"$ERR"); then
  ns_owner=$(printf '%s' "$ns_json" | json_get 'd["metadata"].get("labels", {}).get("app.kubernetes.io/part-of", "")')
  ns_run=$(printf '%s' "$ns_json" | json_get 'd["metadata"].get("labels", {}).get("app.kubernetes.io/instance", "")')
  if [[ "$ns_owner" == "$RESOURCE_PREFIX" && "$ns_run" == "$RUN_ID" ]]; then
    # test.sh's scoped AppArmor pod first, by its exact name (test.sh deletes it too; this covers a
    # run stopped before that): a pod that cannot be stopped is reported here by name, rather
    # than only as a namespace delete that timed out.
    kc delete pod apparmor-scoped-pod -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>"$ERR" \
      || warn_inc "could not confirm pod apparmor-scoped-pod in $NAMESPACE was deleted: $(head -n 2 "$ERR")"
    kc delete namespace "$NAMESPACE" --wait=true --timeout=5m >/dev/null 2>"$ERR" \
      || warn_inc "could not confirm namespace $NAMESPACE was deleted: $(head -n 2 "$ERR")"
  else
    warn_inc "namespace $NAMESPACE is not labelled app.kubernetes.io/part-of=$RESOURCE_PREFIX and app.kubernetes.io/instance=$RUN_ID (has '${ns_owner:-none}' and '${ns_run:-none}'); refusing to delete a namespace this run may not own."
  fi
elif grep -q 'NotFound' "$ERR"; then
  echo "namespace $NAMESPACE does not exist; nothing namespaced to delete."
else
  warn_inc "could not read namespace $NAMESPACE (the read failed, not a report it is absent): $(head -n 2 "$ERR")"
fi

if [[ "$DELETE_AWS" != 1 ]]; then
  echo
  if [[ "$incomplete" -ne 0 ]]; then
    printf 'Workload clean up INCOMPLETE: see the warnings above.\n' >&2
    exit 1
  fi
  echo "Workload removed. Run $RUN_ID's AWS resources (node group, instances, AMI, launch template,"
  echo "security group, staging bucket, the node role's access entry, instance profile and roles) are left in place. Re-run with"
  echo "--delete-aws-resources to remove them, or ./clean.sh --dry-run to see what remains."
  exit 0
fi

echo "== deleting the managed node group =="
case "$ng_state" in
  absent) echo "no node group named $NODEGROUP_NAME; nothing to delete." ;;
  "$UNKNOWN") warn_inc "skipping the node group: its state could not be determined" ;;
  not-owned) warn_inc "node group $NODEGROUP_NAME does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; refusing to delete it" ;;
  owned*)
    nodegroup_state ng_now
    if [[ "$ng_now" == owned* ]]; then
      aws eks delete-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" --output json >/dev/null 2>"$ERR" \
        || warn_inc "could not issue delete-nodegroup for $NODEGROUP_NAME: $(head -n 2 "$ERR")"
      aws eks wait nodegroup-deleted --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" 2>"$ERR" \
        || warn_inc "could not confirm node group $NODEGROUP_NAME was deleted"
    else
      warn_inc "node group $NODEGROUP_NAME changed before the delete ($ng_now); left in place"
    fi ;;
esac

echo "== terminating this run's EC2 instances (build and verification hosts) =="
if [ "$instances" != "$UNKNOWN" ] && [ -n "$instances" ]; then
  terminated=()
  while read -r iid _rest; do
    [ -n "$iid" ] || continue
    owned_then instance "$iid" "instance $iid" aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$iid" --output json \
      && terminated+=("$iid")
  done <<< "$instances"
  if [ "${#terminated[@]}" -gt 0 ]; then
    aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "${terminated[@]}" 2>"$ERR" \
      || warn_inc "could not confirm termination of: ${terminated[*]}"
  fi
elif [ -z "$instances" ]; then echo "none."; fi

echo "== deleting this run's EBS volumes that are left once its instances are gone =="
# Read again now: a terminated instance's DeleteOnTermination volumes go with it, and the rest
# become available. Only an available (unattached) volume is deleted, after both tags are re-read.
list_volumes
if [ "$volumes" != "$UNKNOWN" ] && [ -n "$volumes" ]; then
  gone_vols=()
  while read -r vid vstate; do
    [ -n "$vid" ] || continue
    case "$vstate" in
      available) owned_then volume "$vid" "volume $vid" aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$vid" --output json \
                   && gone_vols+=("$vid") ;;
      deleting) gone_vols+=("$vid") ;;
      *) warn_inc "volume $vid is $vstate (still attached); left in place" ;;
    esac
  done <<< "$volumes"
  if [ "${#gone_vols[@]}" -gt 0 ]; then
    aws ec2 wait volume-deleted --region "$AWS_REGION" --volume-ids "${gone_vols[@]}" 2>"$ERR" \
      || warn_inc "could not confirm deletion of volume(s): ${gone_vols[*]}"
  fi
elif [ -z "$volumes" ]; then echo "none."; fi

echo "== deregistering this run's AMIs, then deleting its snapshots =="
if [[ "$KEEP_AMI" == 1 ]]; then
  echo "--keep-ami: AMIs left in place: $(printf '%s\n' "$images" | awk 'NF{print $1}' | tr '\n' ' ')"
elif [ "$images" != "$UNKNOWN" ] && [ -n "$images" ]; then
  while read -r image_id _name; do
    [ -n "$image_id" ] || continue
    owned_then image "$image_id" "AMI $image_id" aws ec2 deregister-image --region "$AWS_REGION" --image-id "$image_id" --output json || true
  done <<< "$images"
elif [ -z "$images" ]; then echo "no AMIs."; fi
# Snapshots are tagged at create-image time, so this also catches a snapshot whose AMI never
# finished registering. A snapshot behind a kept AMI stays.
list snapshots "this run's EBS snapshots" "[(x[\"SnapshotId\"], x.get(\"VolumeSize\", \"-\")) for x in d[\"Snapshots\"]]" \
  ec2 describe-snapshots --owner-ids self --filters "${FILTERS[@]}"
if [[ "$kept_unknown" == 1 ]]; then
  warn_inc "--keep-ami: the snapshots behind the kept AMIs could not be determined, so no snapshot was deleted"
elif [ "$snapshots" != "$UNKNOWN" ] && [ -n "$snapshots" ]; then
  while read -r snap _size; do
    [ -n "$snap" ] || continue
    if is_kept_snap "$snap"; then echo "snapshot $snap backs a kept AMI; left in place."; continue; fi
    owned_then snapshot "$snap" "snapshot $snap" aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap" --output json || true
  done <<< "$snapshots"
elif [ -z "$snapshots" ]; then echo "no snapshots."; fi

echo "== deleting this run's launch templates =="
if [ "$lts" != "$UNKNOWN" ] && [ -n "$lts" ]; then
  while read -r lt_id _name; do
    [ -n "$lt_id" ] || continue
    owned_then lt "$lt_id" "launch template $lt_id" aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-id "$lt_id" --output json || true
  done <<< "$lts"
elif [ -z "$lts" ]; then echo "none."; fi

echo "== deleting this run's build security group =="
if [ "$sgs" != "$UNKNOWN" ] && [ -n "$sgs" ]; then
  while read -r sg_id _name; do
    [ -n "$sg_id" ] || continue
    owned_then sg "$sg_id" "security group $sg_id" aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg_id" --output json || true
  done <<< "$sgs"
elif [ -z "$sgs" ]; then echo "none."; fi

echo "== emptying and deleting this run's S3 staging buckets =="
# bucket_state <bucket>: absent | owned | not-owned, or non-zero when it cannot be determined.
# Every S3 call names the expected bucket owner (the caller's account), so a same-named bucket
# in another account is never read or emptied.
bucket_state() {
  local b="$1" t
  if ! aws s3api head-bucket --bucket "$b" --region "$AWS_REGION" --expected-bucket-owner "$ACCOUNT" --output json >/dev/null 2>"$ERR"; then
    grep -qE '\(404\)|Not Found|NoSuchBucket' "$ERR" && { echo absent; return 0; }
    return 1
  fi
  t=$(aws s3api get-bucket-tagging --bucket "$b" --region "$AWS_REGION" --expected-bucket-owner "$ACCOUNT" --output json 2>"$ERR") || return 1
  if printf '%s' "$t" | json_pick 'd["TagSet"]' | tags_match; then echo owned; else echo not-owned; fi
}
empty_bucket() { # delete every object, a page at a time, naming the expected owner on each call
  local b="$1" page keys n=0
  while :; do
    page=$(aws s3api list-objects-v2 --bucket "$b" --region "$AWS_REGION" --expected-bucket-owner "$ACCOUNT" --max-keys 1000 --output json 2>"$ERR") || return 1
    keys=$(printf '%s' "$page" | json_pick '{"Objects": [{"Key": o["Key"]} for o in d.get("Contents", [])], "Quiet": True}')
    [ "$(printf '%s' "$keys" | json_get 'len(d["Objects"])')" -gt 0 ] || return 0
    aws s3api delete-objects --bucket "$b" --region "$AWS_REGION" --expected-bucket-owner "$ACCOUNT" --delete "$keys" --output json >/dev/null 2>"$ERR" || return 1
    n=$((n + 1)); [ "$n" -lt 1000 ] || return 1
  done
}
ACCOUNT=""
if [ "$buckets" != "$UNKNOWN" ] && [ -n "$buckets" ]; then
  if ACCOUNT=$(aws sts get-caller-identity --output json 2>"$ERR" | json_get 'd["Account"]') && [[ "$ACCOUNT" =~ ^[0-9]{12}$ ]]; then
    for b in $buckets; do
      if ! st=$(bucket_state "$b"); then warn_inc "could not determine the state of bucket $b: $(head -n 2 "$ERR")"; continue; fi
      case "$st" in
        absent) echo "bucket $b is already gone." ;;
        not-owned) warn_inc "bucket $b does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; refusing to delete it" ;;
        owned)
          if empty_bucket "$b"; then
            aws s3api delete-bucket --bucket "$b" --region "$AWS_REGION" --expected-bucket-owner "$ACCOUNT" --output json 2>"$ERR" \
              || warn_inc "could not delete bucket $b: $(head -n 2 "$ERR")"
          else
            warn_inc "could not empty bucket $b: $(head -n 2 "$ERR")"
          fi ;;
      esac
    done
  else
    warn_inc "could not read the caller's account, so the staging buckets were not touched: $(head -n 2 "$ERR")"
  fi
elif [ -z "$buckets" ]; then echo "none."; fi

echo "== deleting this run's IAM instance profile and roles (by their per-run names) =="
# The instance profile first: remove the roles it holds (it is this run's profile, so they are
# this run's build role), then delete it.
case "$profile_build" in
  absent) echo "instance profile $INSTANCE_PROFILE does not exist." ;;
  "$UNKNOWN") warn_inc "skipping instance profile $INSTANCE_PROFILE: its state could not be determined" ;;
  not-owned) warn_inc "instance profile $INSTANCE_PROFILE does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; refusing to delete it" ;;
  owned)
    aws_json pdesc "the roles in instance profile $INSTANCE_PROFILE" iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
    if [ "$pdesc" != "$UNKNOWN" ]; then
      pblocked=0
      for prole in $(printf '%s' "$pdesc" | json_get '[r["RoleName"] for r in d["InstanceProfile"].get("Roles", [])]'); do
        OWNED_GONE_FAILS=1 owned_then profile "$INSTANCE_PROFILE" "instance profile $INSTANCE_PROFILE (removing role $prole)" \
          aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --role-name "$prole" --output json \
          || { pblocked=1; break; }
      done
      if [ "$pblocked" = 0 ]; then
        OWNED_GONE_FAILS=1 owned_then profile "$INSTANCE_PROFILE" "instance profile $INSTANCE_PROFILE" \
          aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --output json || true
      else
        warn_inc "instance profile $INSTANCE_PROFILE left in place: see the warnings above"
      fi
    fi ;;
esac
# role_owned_before <role> <changes made> <the next change>: both tags of the role read again
# right before one change to it. 0 when it still carries both. Otherwise its clean up stops here,
# with every policy still on it left there, and is incomplete: re-tagged, gone since it was
# listed (someone else changed it), or unreadable.
role_owned_before() {
  local role="$1" n="$2" next="$3"
  case "$(recheck role "$role")" in
    match) return 0 ;;
    gone) warn_inc "role $role disappeared after it was listed, before $next, after $n policy change(s) by this clean up; stopped" ;;
    mismatch)
      if [ "$n" = 0 ]; then warn_inc "role $role no longer carries ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; left in place, no policy detached"
      else warn_inc "role $role no longer carries ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID} before $next; left in place after $n policy change(s), nothing more changed"; fi ;;
    *) warn_inc "could not re-read the tags of role $role before $next; left in place" ;;
  esac
  return 1
}
# delete_role <name> <state>: detach and delete its policies, then the role. Every lookup it
# depends on is checked: a failed one leaves the role in place and the clean up incomplete.
delete_role() {
  local role="$1" st="$2" blocked=0 n=0 profs att inl p
  case "$st" in
    absent) echo "role $role does not exist."; return ;;
    "$UNKNOWN") warn_inc "skipping role $role: its state could not be determined"; return ;;
    not-owned) warn_inc "role $role does not carry ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; refusing to delete it"; return ;;
  esac
  aws_json profs "the instance profiles that hold $role" iam list-instance-profiles-for-role --role-name "$role"
  [ "$profs" != "$UNKNOWN" ] || { warn_inc "role $role left in place: see the warning above"; return; }
  p=$(printf '%s' "$profs" | json_get '[x["InstanceProfileName"] for x in d["InstanceProfiles"]]' | tr '\n' ' ')
  [ -z "${p// /}" ] || { warn_inc "role $role is still in instance profile(s) ${p% }; left in place"; return; }
  aws_json att "the attached policies of $role" iam list-attached-role-policies --role-name "$role"
  [ "$att" != "$UNKNOWN" ] || { warn_inc "role $role left in place: see the warning above"; return; }
  aws_json inl "the inline policies of $role" iam list-role-policies --role-name "$role"
  [ "$inl" != "$UNKNOWN" ] || { warn_inc "role $role left in place: see the warning above"; return; }
  # Both tags again right before EVERY change to this role (each detach, each inline-policy
  # delete, and the delete itself through owned_then): a role re-tagged at any point keeps every
  # policy it still has.
  for p in $(printf '%s' "$att" | json_get '[x["PolicyArn"] for x in d["AttachedPolicies"]]'); do
    role_owned_before "$role" "$n" "detaching $p" || return
    if aws iam detach-role-policy --role-name "$role" --policy-arn "$p" --output json >/dev/null 2>"$ERR"; then n=$((n + 1))
    else warn_inc "could not detach $p from $role: $(head -n 2 "$ERR")"; blocked=1; fi
  done
  for p in $(printf '%s' "$inl" | json_get 'd["PolicyNames"]'); do
    role_owned_before "$role" "$n" "deleting inline policy $p" || return
    if aws iam delete-role-policy --role-name "$role" --policy-name "$p" --output json >/dev/null 2>"$ERR"; then n=$((n + 1))
    else warn_inc "could not delete inline policy $p from $role: $(head -n 2 "$ERR")"; blocked=1; fi
  done
  [ "$blocked" = 0 ] || { warn_inc "role $role left in place: see the warnings above"; return; }
  OWNED_GONE_FAILS=1 owned_then role "$role" "IAM role $role" aws iam delete-role --role-name "$role" --output json || true
}
delete_role "$BUILD_ROLE_NAME" "$role_build"
# The node role's access entry: after the node group is gone (its nodes authenticate with it) and
# before the role, whose tags, read again right before the delete, are what show the entry is this
# run's. An entry whose role is already gone cannot be shown to be this run's, so it is left, with
# the command that removes it, and the clean up is incomplete.
echo "== deleting the EKS access entry for this run's node role =="
# delete_access_entry: non-zero when an entry may still be there, including when the role's tags,
# read right before the delete, said gone, another owner or could not be read: the node role is
# then kept for the rest of this clean up (a later read that matches again is not trusted), so a
# re-run can still show the entry is this run's and delete it.
delete_access_entry() {
  local arn ng_now
  case "$ae_node" in
    "") echo "none."; return 0 ;;
    "$UNKNOWN") warn_inc "skipping the access entry for role $NODE_ROLE_NAME: the cluster's access entries could not be read"; return 1 ;;
  esac
  case "$role_node" in
    absent)
      for arn in $ae_node; do
        warn_inc "access entry $arn names role $NODE_ROLE_NAME, which no longer exists, so it cannot be shown to be this run's; left in place. If it is, remove it with: aws eks delete-access-entry --region $AWS_REGION --cluster-name $CLUSTER_NAME --principal-arn $arn"
      done
      return 0 ;;
    owned) ;;
    *) warn_inc "access entry for role $NODE_ROLE_NAME left in place: the role is $role_node"; return 0 ;;
  esac
  nodegroup_state ng_now
  [ "$ng_now" = absent ] || { warn_inc "access entry for role $NODE_ROLE_NAME left in place: node group $NODEGROUP_NAME is not gone ($ng_now)"; return 1; }
  for arn in $ae_node; do
    case "$(recheck role "$NODE_ROLE_NAME")" in
      match) aws eks delete-access-entry --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --principal-arn "$arn" --output json >/dev/null 2>"$ERR" \
               || { warn_inc "could not delete access entry $arn: $(head -n 2 "$ERR")"; return 1; } ;;
      # Not shown to be this run's role: the entry stays, and so does the role.
      gone) warn_inc "role $NODE_ROLE_NAME disappeared after it was listed; access entry $arn left in place"; return 1 ;;
      mismatch) warn_inc "role $NODE_ROLE_NAME no longer carries ${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE} and ${TAGS_RUN_KEY}=${RUN_ID}; access entry $arn left in place"; return 1 ;;
      *) warn_inc "could not re-read the tags of role $NODE_ROLE_NAME; access entry $arn left in place"; return 1 ;;
    esac
  done
}
# access_entry_gone: before the node role is deleted, the cluster's access entries are read
# again; the role goes only when no entry for it is listed (a delete that succeeded but left the
# entry, or a first listing that missed it, keeps the role). 0 when the role may go.
access_entry_gone() {
  local ae_now
  [ "$role_node" = owned ] || return 0   # delete_role reports an absent, foreign or unknown role
  access_entry_state ae_now
  case "$ae_now" in
    "") return 0 ;;
    "$UNKNOWN") return 1 ;;   # access_entry_state already said it could not determine
    *) warn_inc "the access entry for role $NODE_ROLE_NAME is still listed after its delete ($ae_now)"; return 1 ;;
  esac
}
if delete_access_entry && access_entry_gone; then
  delete_role "$NODE_ROLE_NAME" "$role_node"
else
  warn_inc "role $NODE_ROLE_NAME left in place, so that a re-run can still show its access entry is this run's and delete it"
fi

echo "== verifying absence =="
first_buckets="$buckets"
list_all
# Confirm every bucket the first listing found, as well as any the second one finds.
buckets=$(printf '%s\n%s\n' "$first_buckets" "$buckets" | awk 'NF' | sort -u)
for pair in "instances:EC2 instances" "volumes:EBS volumes" "sgs:security groups" "lts:launch templates"; do
  v="${pair%%:*}"; what="${pair#*:}"
  [ -z "${!v}" ] || [ "${!v}" = "$UNKNOWN" ] || warn_inc "this run's $what still present after cleanup: $(printf '%s' "${!v}" | tr '\n' ' ')"
done
if [[ "$KEEP_AMI" == 1 ]]; then
  [ "$images" = "$UNKNOWN" ] || [ "$(printf '%s\n' "$images" | awk 'NF{print $1}' | sort)" = "$(printf '%s\n' "$kept_images" | awk 'NF{print $1}' | sort)" ] \
    || warn_inc "the AMIs present ($images) are not the kept ones ($kept_images)"
else
  [ -z "$images" ] || [ "$images" = "$UNKNOWN" ] || warn_inc "this run's AMIs still present after cleanup: $(printf '%s' "$images" | tr '\n' ' ')"
fi
if [ -n "$snapshots" ] && [ "$snapshots" != "$UNKNOWN" ] && [[ "$kept_unknown" == 0 ]]; then
  while read -r snap _s; do
    [ -n "$snap" ] || continue
    is_kept_snap "$snap" || warn_inc "this run's snapshot $snap still present after cleanup"
  done <<< "$snapshots"
fi
[ "$ng_state" = absent ] || [ "$ng_state" = "$UNKNOWN" ] || warn_inc "node group $NODEGROUP_NAME still present after cleanup: $ng_state"
[ -z "$ae_node" ] || [ "$ae_node" = "$UNKNOWN" ] || warn_inc "the access entry for role $NODE_ROLE_NAME is still present after cleanup: $ae_node"
# The roles and the profile were re-read by name in list_all; buckets are confirmed directly (the
# tagging API can list a bucket for a while after it is deleted).
for pair in "role_build:IAM role $BUILD_ROLE_NAME" "role_node:IAM role $NODE_ROLE_NAME" "profile_build:instance profile $INSTANCE_PROFILE"; do
  v="${pair%%:*}"; what="${pair#*:}"
  case "${!v}" in
    absent|"$UNKNOWN") ;;   # UNKNOWN is reported by the loop at the end
    *) warn_inc "$what still present after cleanup (${!v})" ;;
  esac
done
if [ -n "$ACCOUNT" ]; then
  while read -r b; do
    [ -n "$b" ] && [ "$b" != "$UNKNOWN" ] || continue
    st=$(bucket_state "$b") || { warn_inc "could not confirm bucket $b is gone"; continue; }
    [ "$st" = absent ] || warn_inc "bucket $b still present after cleanup ($st)"
  done <<< "$buckets"
elif [ -n "$buckets" ]; then
  warn_inc "the staging buckets' absence could not be confirmed (no caller account)"
fi
for v in instances volumes images snapshots sgs lts buckets ng_state ae_node role_build role_node profile_build; do
  printf '%s\n' "${!v}" | grep -qxF -- "$UNKNOWN" && warn_inc "absence of this run's $v could not be confirmed"
done
if [[ "$KEEP_AMI" == 1 && -n "$kept_images" ]]; then
  echo "Left in place (kept on request): AMI(s) $(printf '%s\n' "$kept_images" | awk 'NF{print $1}' | tr '\n' ' ')and snapshot(s) $(printf '%s\n' "$kept_snaps" | awk 'NF' | tr '\n' ' ')"
fi
echo "Left in place (shared, not the sample's): the vpc-cni add-on and the isolated-sandbox RuntimeClass on cluster $CLUSTER_NAME; see the README's Clean up section for how to remove the add-on."

if [[ "$incomplete" -ne 0 ]]; then
  printf '\nClean up INCOMPLETE: see the warnings above.\n' >&2
  exit 1
fi
echo
echo "Clean up of run $RUN_ID complete: validation workload, node group, instances, EBS volumes, $([[ "$KEEP_AMI" == 1 ]] || echo 'AMIs and snapshots, ')launch template, security group, staging bucket, the node role's access entry, instance profile and roles are gone."
