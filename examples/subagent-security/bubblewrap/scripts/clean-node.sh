#!/usr/bin/env bash
# clean-node.sh -- clean.sh's node step: the functions that delete the run's own node, or a
# NodeClaim launched for its pods, and nothing else. clean.sh sources it; do not run it.
#
# Every read is fresh. The node the run record names is deleted only if every identity in
# the record still holds; a NodeClaim launched for the run's pods (named in their events)
# only if it appeared after the run started and is none the cluster had then. A pod other
# than a DaemonSet's or a static one on a node means someone else's work is on it, and the
# node is left alone. Deleting the NodeClaim is the EKS Auto Mode way to remove a node;
# terminating the instance directly happens only with --allow-instance-termination, after
# that fails, after the node is cordoned, and after every check again.
#
# clean.sh sets what these read: the run record's fields, allow_terminate, and kc, aws,
# gone_within, note_fail and identity_matches.
# shellcheck disable=SC2154

node_why=""
foreign_on() { # <node name>: sets node_why and fails if other workloads run on it
  local pods foreign
  if pods="$(kc get pods -A --field-selector "spec.nodeName=$1" -o json 2>/dev/null)" &&
     foreign="$(jq -er '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
       | select(((.metadata.ownerReferences // []) | map(.kind) | index("DaemonSet")) == null)
       | select((.metadata.annotations // {})["kubernetes.io/config.mirror"] == null)
       | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")' <<<"$pods")"; then :
  else node_why="could not list the pods on node $1"; return 1; fi
  [[ -z "$foreign" ]] || { node_why="other workloads run on node $1: $foreign"; return 1; }
}
node_matches() { # fresh reads of the Node, its NodeClaim and the pods on it
  local node claim want
  if node="$(kc get node "$NODE_NAME" --ignore-not-found -o json 2>/dev/null)"; then :
  else node_why="could not read node $NODE_NAME"; return 1; fi
  if [[ -n "$node" ]]; then
    want="$(jq -cn --arg a "$NODE_UID" --arg b "$NODE_PROVIDER_ID" --arg c "$NODE_CREATED_AT" \
      --arg d "$NODE_POOL" '[$a, $b, $c, $d]')"
    [[ "$(jq -c '[.metadata.uid, .spec.providerID, .metadata.creationTimestamp,
        .metadata.labels["karpenter.sh/nodepool"]]' <<<"$node" 2>/dev/null)" == "$want" ]] ||
      { node_why="node $NODE_NAME no longer matches the run record"; return 1; }
  fi
  if claim="$(kc get nodeclaim "$NODECLAIM_NAME" --ignore-not-found -o json 2>/dev/null)"; then :
  else node_why="could not read NodeClaim $NODECLAIM_NAME"; return 1; fi
  if [[ -n "$claim" ]]; then
    want="$(jq -cn --arg a "$NODECLAIM_UID" --arg b "$NODE_PROVIDER_ID" \
      --arg c "$NODECLAIM_CREATED_AT" --arg d "$NODECLAIM_POOL" '[$a, $b, $c, $d]')"
    [[ "$(jq -c '[.metadata.uid, .status.providerID, .metadata.creationTimestamp,
        .metadata.labels["karpenter.sh/nodepool"]]' <<<"$claim" 2>/dev/null)" == "$want" ]] ||
      { node_why="NodeClaim $NODECLAIM_NAME no longer matches the run record"; return 1; }
  fi
  foreign_on "$NODE_NAME"
}
instance_state() { # prints the instance's state name, or nothing if it could not be read
  aws ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null
}
instance_matches() { # the instance's own tags name this cluster, the NodeClaim and its pool
  local tags
  tags="$(aws ec2 describe-instances --instance-ids "$instance" --output json 2>/dev/null |
    jq -c '[.Reservations[0].Instances[0].Tags // [] | from_entries
      | .["eks:eks-cluster-name"], .["karpenter.sh/nodeclaim"], .["karpenter.sh/nodepool"]]')"
  [[ "$tags" == "$(jq -cn --arg a "$CLUSTER_NAME" --arg b "$NODECLAIM_NAME" \
      --arg c "$NODECLAIM_POOL" '[$a, $b, $c]')" ]] ||
    { node_why="instance $instance does not carry the tags of this cluster's NodeClaim $NODECLAIM_NAME"; return 1; }
}
wait_terminated() { # every ten seconds, for ten minutes at most
  local state end=$((SECONDS + 600)) tries=60
  while (( SECONDS < end && tries-- > 0 )) && in_budget; do
    state="$(instance_state)"
    [[ "$state" == terminated ]] && return 0
    sleep 10
  done
  node_why="instance $instance is ${state:-unreadable}, not terminated, after ten minutes"
  return 1
}
delete_run_node() {
  local field instance gone=false dry
  for field in NODE_NAME NODE_UID NODE_PROVIDER_ID NODE_CREATED_AT NODE_POOL NODE_AT_START \
      NODECLAIM_NAME NODECLAIM_UID NODECLAIM_CREATED_AT NODECLAIM_POOL RUN_STARTED_AT CLUSTER_NAME; do
    [[ -n "${!field:-}" ]] ||
      { note_fail "the run record has no $field, so node ${NODE_NAME:-?} was not deleted"; return; }
  done
  [[ "$NODE_AT_START" == false && "$NODE_POOL" == "$NODECLAIM_POOL" && "$RUN_STARTED_AT" < "$NODECLAIM_CREATED_AT" &&
     ! "$NODE_CREATED_AT" < "$NODECLAIM_CREATED_AT" ]] ||
    { note_fail "the run record does not show node $NODE_NAME appearing after the run started, so it was left in place"; return; }
  [[ "$NODE_PROVIDER_ID" =~ ^aws:///[a-z0-9-]+/(i-[0-9a-f]{8,17})$ ]] ||
    { note_fail "node $NODE_NAME's provider id is not an EC2 instance; left it in place"; return; }
  instance="${BASH_REMATCH[1]}"
  node_matches || { note_fail "$node_why; left it in place"; return; }

  kc delete nodeclaim "$NODECLAIM_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 ||
    echo "  the NodeClaim delete was not accepted; waiting to see whether the node goes anyway"
  gone_within 600 nodeclaim "$NODECLAIM_NAME" && gone_within 60 node "$NODE_NAME" && gone=true
  if [[ "$gone" == true ]] && wait_terminated; then
    echo "  deleted node $NODE_NAME through its NodeClaim; instance $instance is terminated."
    return
  fi
  [[ "$gone" == true ]] || node_why="NodeClaim $NODECLAIM_NAME or node $NODE_NAME is still there after ten minutes"
  if [[ "$allow_terminate" != true ]]; then
    note_fail "$node_why; pass --allow-instance-termination to terminate the instance directly"
    return
  fi
  dry="$(aws ec2 terminate-instances --instance-ids "$instance" --dry-run 2>&1)"
  grep -q 'DryRunOperation' <<<"$dry" ||
    { note_fail "$node_why, and terminating instance $instance directly is not permitted here; left it"; return; }
  # Nothing new may land on it from here: cordon it, only while it is still the recorded
  # node (the patch's own test of its uid and provider id), then wait and check it again.
  if kc get node "$NODE_NAME" --ignore-not-found -o name 2>/dev/null | grep -q .; then
    kc patch node "$NODE_NAME" --type=json -p "$(jq -cn --arg u "$NODE_UID" --arg p "$NODE_PROVIDER_ID" \
      '[{op: "test", path: "/metadata/uid", value: $u}, {op: "test", path: "/spec/providerID", value: $p},
        {op: "add", path: "/spec/unschedulable", value: true}]')" >/dev/null ||
      { note_fail "could not cordon node $NODE_NAME as the recorded node; left instance $instance in place"; return; }
    sleep 30
  fi
  if ! identity_matches; then
    note_fail "this shell no longer acts as the identity setup recorded; left instance $instance in place"
    return
  fi
  if ! { node_matches && instance_matches; }; then
    note_fail "$node_why; left instance $instance in place"
    return
  fi
  aws ec2 terminate-instances --instance-ids "$instance" >/dev/null 2>&1 ||
    { note_fail "could not terminate instance $instance"; return; }
  wait_terminated || { note_fail "$node_why"; return; }
  echo "  terminated instance $instance directly, after the NodeClaim delete did not finish."
}
delete_nominated_claim() { # <name>: a NodeClaim launched for this run's pods, never its record
  local claim node
  claim="$(kc get nodeclaim "$1" --ignore-not-found -o json 2>/dev/null)" ||
    { note_fail "could not read NodeClaim $1, launched for this run's pods"; return; }
  [[ -n "$claim" ]] || { echo "  NodeClaim $1, launched for this run's pods, is already gone."; return; }
  [[ -f "$TMP_DIR/nodeclaims-at-start.json" && -n "${RUN_STARTED_AT:-}" &&
     "$(jq --slurpfile s "$TMP_DIR/nodeclaims-at-start.json" '.metadata.uid as $u | $s[0] | index($u) == null' <<<"$claim")" == true &&
     "$RUN_STARTED_AT" < "$(jq -r '.metadata.creationTimestamp' <<<"$claim")" ]] ||
    { note_fail "NodeClaim $1 was nominated for this run's pods but is not shown appearing after the run started; left it"; return; }
  node="$(jq -r '.status.nodeName // ""' <<<"$claim")"
  [[ -z "$node" ]] || foreign_on "$node" || { note_fail "$node_why; left NodeClaim $1"; return; }
  if ! { kc delete nodeclaim "$1" --wait=false >/dev/null 2>&1 && gone_within 600 nodeclaim "$1"; }; then
    note_fail "NodeClaim $1, launched for this run's pods, is still there after ten minutes"
    return
  fi
  echo "  deleted NodeClaim $1, launched for this run's pods."
}
