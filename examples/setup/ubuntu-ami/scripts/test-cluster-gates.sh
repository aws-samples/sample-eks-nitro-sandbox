#!/usr/bin/env bash
# test-cluster-gates.sh: proves the cluster-side gates both ways, in the REAL scripts, with stub
# `aws` and `kubectl` first on PATH (no AWS account, no cluster):
#   scripts/00c-check-cluster.sh     the reader's vpc-cni add-on (ACTIVE, network policy on) and
#                                    the shared isolated-sandbox RuntimeClass (read only)
#   scripts/join-nodegroup.sh        the launch template user data: --node-labels with all three
#                                    labels and --register-with-taints with the taint
#   scripts/wait-node-ready.sh       the node is Ready AND advertises nitro-sandbox capacity > 0
#
#   scripts/test-cluster-gates.sh
#
# Each stub answers only the calls the script under test makes for that check, with the case the
# test sets; any other call fails loudly (exit 97), so an untested call cannot pass silently.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR_REAL="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE_DIR_REAL/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-cluster-gates.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample
unset NODEGROUP_NAME KUBECTL

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | tail -n 6; fail=$((fail+1)); fi
}

STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/aws" <<'SH'
#!/bin/bash
case "$1 $2" in
  "eks describe-addon")
    case "${STUB_ADDON:-on}" in
      on)       printf '%s\n' '["ACTIVE", "v1.0.0-eksbuild.1", "{\"enableNetworkPolicy\":\"true\"}"]' ;;
      yaml-on)  printf '%s\n' '["ACTIVE", "v1.0.0-eksbuild.1", "enableNetworkPolicy: \"true\"\n"]' ;;
      off)      printf '%s\n' '["ACTIVE", "v1.0.0-eksbuild.1", "{\"enableNetworkPolicy\":\"false\"}"]' ;;
      none)     printf '%s\n' '["ACTIVE", "v1.0.0-eksbuild.1", null]' ;;
      degraded) printf '%s\n' '["DEGRADED", "v1.0.0-eksbuild.1", "{\"enableNetworkPolicy\":\"true\"}"]' ;;
      absent)   echo "An error occurred (ResourceNotFoundException) when calling the DescribeAddon operation: No addon: vpc-cni found in cluster: example-cluster" >&2; exit 254 ;;
      denied)   echo "An error occurred (AccessDeniedException) when calling the DescribeAddon operation: not authorized" >&2; exit 254 ;;
    esac ;;
  "eks describe-cluster")
    printf 'https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com\tQ0EtREFUQS1GSVhUVVJF\t10.100.0.0/16\n' ;;
  *) echo "STUB aws: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/kubectl" <<'SH'
#!/bin/bash
args="$*"
case "$args" in
  "get runtimeclass isolated-sandbox -o json")
    case "${STUB_RC:-one}" in
      one)     echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true"}}}' ;;
      two)     echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true","sandbox.preview/nitro":"true"}}}' ;;
      foreign) echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true","example.com/other-pool":"true"}}}' ;;
      handler) echo '{"handler":"some-other-handler","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true"}}}' ;;
      absent)  echo 'Error from server (NotFound): runtimeclasses.node.k8s.io "isolated-sandbox" not found' >&2; exit 1 ;;
    esac ;;
  "get nodes -l eks.amazonaws.com/nodegroup="*" -o jsonpath={.items[0].metadata.name}") printf '%s' "${STUB_NODE:-}" ;;
  "get node "*" -o jsonpath={.status.conditions[?(@.type==\"Ready\")].status}") printf '%s' "${STUB_READY:-}" ;;
  "get node "*" -o jsonpath={.status.allocatable.eks\\.amazonaws\\.com/nitro-sandbox}") printf '%s' "${STUB_CAP:-}" ;;
  *) echo "STUB kubectl: unexpected call: $args" >&2; exit 97 ;;
esac
SH
chmod +x "$STUB/aws" "$STUB/kubectl"
export PATH="$STUB:$PATH"

echo "== 1/3 cluster prerequisites: scripts/00c-check-cluster.sh =============================="
cc() { env STUB_ADDON="$2" STUB_RC="$3" bash "$HERE/00c-check-cluster.sh" > "$WORK/cc-$1.log" 2>&1; }
rc=0; cc ok on one || rc=$?
check "ACCEPT vpc-cni ACTIVE with enableNetworkPolicy=true and a RuntimeClass selecting eks.amazonaws.com/nitro-sandbox=true" 0 "$rc" "$WORK/cc-ok.log" 'CLUSTER PREREQUISITES OK'
rc=0; cc yaml yaml-on two || rc=$?
check "ACCEPT network policy given as YAML, and a RuntimeClass selecting both labels the node registers with" 0 "$rc" "$WORK/cc-yaml.log" 'CLUSTER PREREQUISITES OK'
rc=0; cc absent absent one || rc=$?
check "REJECT a cluster with no vpc-cni add-on, printing the create-addon command" 1 "$rc" "$WORK/cc-absent.log" 'aws eks create-addon .*--addon-name vpc-cni'
grep -q -- '--resolve-conflicts NONE' "$WORK/cc-absent.log"; check "the suggested create-addon command never overwrites an existing amazon-vpc-cni ConfigMap (--resolve-conflicts NONE)" 0 $? "$WORK/cc-absent.log"
grep -q 'enableNetworkPolicy' "$WORK/cc-absent.log"; check "the suggested create-addon command turns network policy on" 0 $? "$WORK/cc-absent.log"
rc=0; cc off off one || rc=$?
check "REJECT a vpc-cni add-on with network policy off, printing the update-addon command" 1 "$rc" "$WORK/cc-off.log" 'network policy off.*|update-addon'
rc=0; cc none none one || rc=$?
check "REJECT a vpc-cni add-on with no configuration values (network policy defaults off)" 1 "$rc" "$WORK/cc-none.log" 'update-addon'
rc=0; cc degraded degraded one || rc=$?
check "REJECT a vpc-cni add-on that is not ACTIVE" 1 "$rc" "$WORK/cc-degraded.log" 'is DEGRADED, not ACTIVE'
rc=0; cc denied denied one || rc=$?
check "REJECT (could not determine) when the add-on lookup fails for another reason" 1 "$rc" "$WORK/cc-denied.log" 'could not determine'
rc=0; cc rc-absent on absent || rc=$?
check "REJECT a cluster with no isolated-sandbox RuntimeClass (Getting started first; never created here)" 1 "$rc" "$WORK/cc-rc-absent.log" 'no isolated-sandbox RuntimeClass'
rc=0; cc rc-foreign on foreign || rc=$?
check "REJECT a RuntimeClass that selects a label the sample's node does not carry (a spec question)" 1 "$rc" "$WORK/cc-rc-foreign.log" 'selects example.com/other-pool=true'
rc=0; cc rc-handler on handler || rc=$?
check "REJECT a RuntimeClass whose handler is not isolated-sandbox" 1 "$rc" "$WORK/cc-rc-handler.log" "handler 'some-other-handler'"

echo
echo "== 2/3 node labels and taint in the user data: scripts/join-nodegroup.sh ==============="
rc=0; bash "$HERE/join-nodegroup.sh" --render-user-data > "$WORK/ud-default.sh" 2> "$WORK/ud-default.err" || rc=$?
check "the user data renders (default node group name)" 0 "$rc" "$WORK/ud-default.err"
for want in '^#!/bin/bash$' "--node-labels=[^' ]*eks\.amazonaws\.com/nodegroup=ubuntu-ami-sample-ng" "--node-labels=[^' ]*eks\.amazonaws\.com/nitro-sandbox=true" \
            "--node-labels=[^' ]*sandbox\.preview/nitro=true" '--register-with-taints=sandbox\.preview/ubuntu-ami=true:NoSchedule' \
            "--apiserver-endpoint 'https://EXAMPLE0123" "--dns-cluster-ip '10\.100\.0\.10'"; do
  grep -qE -- "$want" "$WORK/ud-default.sh"; check "the rendered user data carries /$want/" 0 $? "$WORK/ud-default.sh"
done
rc=0; NODEGROUP_NAME=custom-ng-1 bash "$HERE/join-nodegroup.sh" --render-user-data > "$WORK/ud-custom.sh" 2>&1 || rc=$?
check "a custom NODEGROUP_NAME reaches the nodegroup label" 0 "$rc" "$WORK/ud-custom.sh" 'eks\.amazonaws\.com/nodegroup=custom-ng-1[,]'
! grep -q 'nodegroup=ubuntu-ami-sample-ng' "$WORK/ud-custom.sh"; check "a custom NODEGROUP_NAME leaves no default node group name behind" 0 $? "$WORK/ud-custom.sh"
cu() { bash "$HERE/join-nodegroup.sh" --check-user-data "$WORK/ud-$1.sh" > "$WORK/cu-$1.log" 2>&1; }
rc=0; cu default || rc=$?
check "ACCEPT the rendered user data (check_user_data)" 0 "$rc" "$WORK/cu-default.log" 'USER DATA OK'
sed 's#eks\.amazonaws\.com/nodegroup=ubuntu-ami-sample-ng,##' "$WORK/ud-default.sh" > "$WORK/ud-no-ng.sh"
sed 's#,eks\.amazonaws\.com/nitro-sandbox=true##' "$WORK/ud-default.sh" > "$WORK/ud-no-nitro.sh"
sed 's#,sandbox\.preview/nitro=true##' "$WORK/ud-default.sh" > "$WORK/ud-no-preview.sh"
sed 's# --register-with-taints=[^'"'"']*##' "$WORK/ud-default.sh" > "$WORK/ud-no-taint.sh"
sed '1d' "$WORK/ud-default.sh" > "$WORK/ud-no-shebang.sh"
while IFS='|' read -r name rx why; do
  [ -n "$name" ] || continue
  cmp -s "$WORK/ud-default.sh" "$WORK/ud-$name.sh" && { echo "  FAIL  the $name mutation did not change the user data"; fail=$((fail+1)); continue; }
  rc=0; cu "$name" || rc=$?
  check "$why" 1 "$rc" "$WORK/cu-$name.log" "$rx"
done <<'CASES'
no-ng|lacks eks\.amazonaws\.com/nodegroup=ubuntu-ami-sample-ng|REJECT user data missing the eks.amazonaws.com/nodegroup label
no-nitro|lacks eks\.amazonaws\.com/nitro-sandbox=true|REJECT user data missing eks.amazonaws.com/nitro-sandbox=true
no-preview|lacks sandbox\.preview/nitro=true|REJECT user data missing sandbox.preview/nitro=true
no-taint|register-with-taints lacks sandbox\.preview/ubuntu-ami=true:NoSchedule|REJECT user data missing the --register-with-taints taint
no-shebang|does not start with #!/bin/bash|REJECT user data cloud-init would not run (no #! line)
CASES

echo
echo "== 3/3 node Ready with nitro-sandbox capacity: scripts/wait-node-ready.sh ================"
wn() { env STUB_NODE="$2" STUB_READY="$3" STUB_CAP="$4" NODE_READY_TIMEOUT=2 NODE_POLL_SECONDS=1 bash "$HERE/wait-node-ready.sh" > "$WORK/wn-$1.log" 2>&1; }
rc=0; wn ok node-a True 20 || rc=$?
check "ACCEPT a Ready node advertising eks.amazonaws.com/nitro-sandbox=20" 0 "$rc" "$WORK/wn-ok.log" 'advertises allocatable eks.amazonaws.com/nitro-sandbox=20'
rc=0; wn zero node-a True 0 || rc=$?
check "REJECT (timeout) a Ready node advertising nitro-sandbox=0" 1 "$rc" "$WORK/wn-zero.log" "Ready but advertises allocatable eks.amazonaws.com/nitro-sandbox='0'"
rc=0; wn none node-a True "" || rc=$?
check "REJECT (timeout) a Ready node advertising no nitro-sandbox resource" 1 "$rc" "$WORK/wn-none.log" "nitro-sandbox='<none>'"
rc=0; wn notready node-a False 20 || rc=$?
check "REJECT (timeout) a node that is not Ready, whatever its capacity" 1 "$rc" "$WORK/wn-notready.log" 'is not Ready'
rc=0; wn nonode "" "" "" || rc=$?
check "REJECT (timeout) when no node of the node group registers" 1 "$rc" "$WORK/wn-nonode.log" 'no node labelled eks.amazonaws.com/nodegroup=ubuntu-ami-sample-ng'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "cluster prerequisites, node labels and taint, and node capacity proven both ways in the real scripts."
