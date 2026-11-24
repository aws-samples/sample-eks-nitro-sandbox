#!/usr/bin/env bash
# test-testlib.sh: proves the offline test harness itself, both ways, before any other suite
# relies on it:
#   * the isolated PATH holds no real aws, eksctl, kubectl, helm or packer, and no credentials;
#   * each stub answers the calls it models and refuses (exit 97) a call it does not model;
#   * the stubs refuse what the sample must never do: kubectl config use-context, a delete by
#     label selector, a kubeconfig outside CB_RUN_DIR, an unpinned Helm chart;
#   * FAKE_FAIL fails only the call it names;
#   * the eksctl stub refuses to delete a cluster whose VPC still holds a builder (#281 M9);
#   * the fixture inputs and the fixture Packer release build for every case.
#
#   examples/setup/cilium-bottlerocket/scripts/test-testlib.sh
source "$(dirname "$0")/testlib/harness.sh"

echo "== 1/5 the isolated environment =================================================="
world_reset
for t in aws eksctl kubectl helm packer; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$t:$p" in
    packer:) rc=0 ;;
    packer:*) rc=1 ;;
    *:"$WORK/bin/$t") rc=0 ;;
    *) rc=1 ;;
  esac
  printf '%s -> %s\n' "$t" "${p:-absent}" > "$WORK/which.log"
  check "ACCEPT only the stub (or nothing, for packer) as $t on the isolated PATH" 0 "$rc" "$WORK/which.log"
done
env > "$WORK/env.log"
rc=0; grep -Eq '^(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_PROFILE)=' "$WORK/env.log" && rc=1
check "ACCEPT an environment with no AWS credential or profile variable" 0 "$rc" "$WORK/which.log"
[[ "$HOME" == "$WORK/home" && "${AWS_SHARED_CREDENTIALS_FILE:-}" == /dev/null ]]
check "ACCEPT HOME and the credentials file pointed away from the operator's own" 0 $? "$WORK/which.log"
# The cloud guard (cloud hold, 01:45Z): a case PATH on which a cloud tool is not the stub stops the run.
( cloud_guard "$PATH" ) > "$WORK/guard-ok.log" 2>&1
check "ACCEPT (cloud guard) the isolated PATH: aws, eksctl, kubectl and helm are stubs, packer, ada and isengardcli absent" 0 $? "$WORK/guard-ok.log"
for t in aws ada isengardcli packer; do
  mkdir -p "$WORK/realcloud"; rm -f "$WORK/realcloud/"*; ln -s "$WORK/sysbin/cat" "$WORK/realcloud/$t"
  ( run_real "$WORK/guard-$t-case.log" env "PATH=$WORK/realcloud:$PATH" true ) > "$WORK/guard-$t.log" 2>&1
  rc=$?
  [[ "$rc" == 2 ]] && grep -q "$t resolves to $WORK/realcloud/$t" "$WORK/guard-$t.log" && [[ ! -e "$WORK/guard-$t-case.log" ]]
  check "REJECT (cloud guard) a case whose env PATH puts a real-looking $t first: stopped before the case runs" 0 $? "$WORK/guard-$t.log"
  rm -f "$WORK/CLOUD_GUARD_TRIPPED"   # the trip was this self-test's own; a real trip fails finish
done

echo "== 2/5 fake_aws.py ================================================================"
run_real "$WORK/a1.log" aws sts get-caller-identity --query Account --output text
check "ACCEPT sts get-caller-identity answers the fixture account" 0 "$RC" "$WORK/a1.log" '^111122223333$'
run_real "$WORK/a2.log" aws ec2 describe-something-new --region us-west-2
check "REJECT a call the fake does not model (exit 97)" 97 "$RC" "$WORK/a2.log" 'unexpected call'
world_py 's["ec2"]["volumes"].append({"VolumeId": "vol-0fa1", "State": "available", "Tags": [{"Key": "ManagedBy", "Value": "cilium-bottlerocket-sample"}], "RecheckTags": [{"Key": "ManagedBy", "Value": "someone-else"}]})'
run_real "$WORK/a3.log" aws ec2 describe-volumes --filters Name=tag:ManagedBy,Values=cilium-bottlerocket-sample --query 'Volumes[].VolumeId' --output text
check "ACCEPT a tag filter lookup that finds the volume" 0 "$RC" "$WORK/a3.log" '^vol-0fa1$'
run_real "$WORK/a4.log" aws ec2 describe-volumes --volume-ids vol-0fa1 --query 'Volumes[0].Tags[?Key==`ManagedBy`].Value' --output text
check "ACCEPT a by-ID re-read that sees the changed owner (RecheckTags)" 0 "$RC" "$WORK/a4.log" '^someone-else$'
FAKE_FAIL='aws|ec2 describe-volumes|vol-0fa1|RequestLimitExceeded' run_real "$WORK/a5.log" aws ec2 describe-volumes --volume-ids vol-0fa1
check "REJECT the one call that FAKE_FAIL names" 254 "$RC" "$WORK/a5.log" 'RequestLimitExceeded'
# The sixth field K lets the first K matching calls pass (a read that fails only the second time).
rm -f "$FAKE_STATE.failcounts"
export FAKE_FAIL='aws|ec2 describe-vpcs||RequestLimitExceeded||1'
run_real "$WORK/a5k1.log" aws ec2 describe-vpcs; rc1=$RC
run_real "$WORK/a5k2.log" aws ec2 describe-vpcs; rc2=$RC
unset FAKE_FAIL; rm -f "$FAKE_STATE.failcounts"
[[ "$rc1" == 0 && "$rc2" == 254 ]] && grep -q RequestLimitExceeded "$WORK/a5k2.log"
check "ACCEPT FAKE_FAIL with K=1: the first matching call passes, the second fails" 0 $? "$WORK/a5k2.log"
FAKE_FAIL='aws|ec2 describe-volumes|vol-0fa1|RequestLimitExceeded' run_real "$WORK/a6.log" aws ec2 describe-vpcs
check "ACCEPT another call while that rule is set" 0 "$RC" "$WORK/a6.log"
run_real "$WORK/a7.log" aws --version
check "ACCEPT aws --version as an AWS CLI v2" 0 "$RC" "$WORK/a7.log" '^aws-cli/2\.'

echo "== 3/5 fake_kubectl.py and fake_helm.py ============================================"
export KUBECONFIG="$CB_RUN_DIR/runs/x/kubeconfig"
run_real "$WORK/k1.log" kubectl get nodes -o json
check "ACCEPT a kubectl call with the sample's own kubeconfig" 0 "$RC" "$WORK/k1.log" '"items"'
run_real "$WORK/k2.log" kubectl config use-context other
check "REJECT kubectl config use-context" 97 "$RC" "$WORK/k2.log" 'must not change a context'
run_real "$WORK/k3.log" kubectl delete pod -l app=x -n demo
check "REJECT a delete by label selector" 97 "$RC" "$WORK/k3.log" 'selector'
KUBECONFIG="$WORK/home/.kube/config" run_real "$WORK/k4.log" kubectl get nodes
check "REJECT a kubeconfig outside CB_RUN_DIR" 97 "$RC" "$WORK/k4.log" 'not under CB_RUN_DIR'
run_real "$WORK/h1.log" helm upgrade --install cilium oci://example.invalid/cilium -n kube-system
check "REJECT an unpinned Helm chart (no --version)" 97 "$RC" "$WORK/h1.log" 'unpinned'
run_real "$WORK/h2.log" helm version --short
check "ACCEPT helm version as v3.19.0" 0 "$RC" "$WORK/h2.log" '^v3\.19\.0'
unset KUBECONFIG

echo "== 4/5 fake_eksctl.py: a VPC that still holds a builder ============================"
printf 'apiVersion: eksctl.io/v1alpha5\nkind: ClusterConfig\nmetadata:\n  name: cb-offline-test\n  region: us-west-2\n  version: "1.36"\n  tags:\n    ManagedBy: cilium-bottlerocket-sample\n    RunId: r1\n' > "$WORK/cluster.yaml"
run_real "$WORK/e1.log" eksctl create cluster -f "$WORK/cluster.yaml" --without-nodegroup
check "ACCEPT eksctl create cluster from a rendered config" 0 "$RC" "$WORK/e1.log"
vpc="$(world_get 's["eks"]["clusters"]["cb-offline-test"]["resourcesVpcConfig"]["vpcId"]')"
world_py "s['ec2']['instances'].append({'InstanceId': 'i-0fb1', 'VpcId': '$vpc', 'State': {'Name': 'running'}, 'Tags': []})"
run_real "$WORK/e2.log" eksctl delete cluster --name cb-offline-test --wait
check "REJECT eksctl delete cluster while a builder is still in the VPC" 1 "$RC" "$WORK/e2.log" 'DELETE_FAILED'
world_py 's["ec2"]["instances"][0]["State"] = {"Name": "terminated"}'
run_real "$WORK/e3.log" eksctl delete cluster --name cb-offline-test --wait
check "ACCEPT eksctl delete cluster once the builder is terminated" 0 "$RC" "$WORK/e3.log"
[[ "$(world_get 'len([v for v in s["ec2"]["vpcs"]])')" == 0 ]]
check "  ... and the VPC, subnets, NAT gateway and address are gone" 0 $? "$WORK/e3.log"

echo "== 5/5 fixtures ===================================================================="
for c in good checksum-changed lock-pin-changed signature-changed bad-sig manifest-changed manifest-pin wrong-key \
  shim-tampered file-mismatch sidecar-mismatch download-fails manifest-bad-line member-missing; do
  mkdir -p "$WORK/fx/$c"
  run_real "$WORK/fx-$c.log" python3 "$TESTLIB/fixture_inputs.py" "$WORK/fx/$c/files" "$WORK/fx/$c/sources.lock" "$c"
  check "ACCEPT the runtime fixture case $c builds" 0 "$RC" "$WORK/fx-$c.log"
done
for c in good bad-sig zip-swapped lock-digest wrong-version wrong-fingerprint; do
  run_real "$WORK/pr-$c.log" python3 "$TESTLIB/fixture_packer_release.py" "$WORK/pr/$c" "$WORK/pr/$c.tools.lock" "$c"
  check "ACCEPT the Packer release fixture case $c builds" 0 "$RC" "$WORK/pr-$c.log"
done
# gpg --import exits 2 on a host whose gpg has no gpg-agent, even when the key was imported, so
# the check uses the agent-free path: dearmor the key into a keyring file, verify against it.
mkdir -m 700 "$WORK/gnupg-check"
gpg --homedir "$WORK/gnupg-check" --batch --yes -o "$WORK/gnupg-check/fixture-key.gpg" --dearmor \
  "$WORK/pr/good/hashicorp-test-key.asc" > "$WORK/gpg-import.log" 2>&1
check "ACCEPT the fixture public key as a keyring file, with no gpg-agent" 0 $? "$WORK/gpg-import.log"
for c in good bad-sig; do
  rc=0
  gpg --homedir "$WORK/gnupg-check" --batch --no-default-keyring --keyring "$WORK/gnupg-check/fixture-key.gpg" \
    --status-fd 1 --verify "$WORK/pr/$c/releases/packer/1.16.2/packer_1.16.2_SHA256SUMS.sig" \
    "$WORK/pr/$c/releases/packer/1.16.2/packer_1.16.2_SHA256SUMS" > "$WORK/gpg-$c.log" 2>&1 || rc=$?
  echo "rc=$rc" >> "$WORK/gpg-$c.log"
done
fpr_good="$(sed -n 's/^HASHICORP_KEY_FPR=//p' "$WORK/pr/good.tools.lock")"
check "ACCEPT the good fixture SHA256SUMS: VALIDSIG by the fingerprint the fixture lock pins" 0 0 "$WORK/gpg-good.log" \
  "^\[GNUPG:\] VALIDSIG $fpr_good "
grep -q '^\[GNUPG:\] VALIDSIG' "$WORK/gpg-bad-sig.log"; rc=$?
check "REJECT the bad-sig fixture SHA256SUMS: no VALIDSIG with the pinned key alone" 1 "$rc" "$WORK/gpg-bad-sig.log" \
  '^\[GNUPG:\] (ERRSIG|NO_PUBKEY|BADSIG)'
mkdir -p "$WORK/unz"
(cd "$WORK/unz" && unzip -q "$WORK/pr/good/releases/packer/1.16.2/packer_1.16.2_linux_amd64.zip")
"$WORK/unz/packer" version > "$WORK/pv.log" 2>&1
check "ACCEPT the packer in the good fixture zip as Packer v1.16.2" 0 $? "$WORK/pv.log" '^Packer v1\.16\.2$'
finish
