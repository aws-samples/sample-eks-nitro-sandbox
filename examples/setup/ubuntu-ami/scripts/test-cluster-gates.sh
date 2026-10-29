#!/usr/bin/env bash
# test-cluster-gates.sh: proves the cluster-side gates both ways, in the REAL scripts, with stub
# `aws` and `kubectl` first on PATH (no AWS account, no cluster):
#   scripts/lib/common.sh            require_kube_context: KUBE_CONTEXT required, its server must be
#                                    CLUSTER_NAME's endpoint; every kubectl call names it (H6)
#   scripts/00c-check-cluster.sh     the reader's vpc-cni add-on (ACTIVE, network policy on), the
#                                    shared isolated-sandbox RuntimeClass (read only), and the
#                                    cluster DNS pods the network policy allows
#   scripts/join-nodegroup.sh        the launch template user data: comments stripped, ONE active
#                                    bootstrap.sh command whose --kubelet-extra-args carry all three
#                                    labels and the taint (M3)
#   scripts/wait-node-ready.sh       the node is Ready AND advertises nitro-sandbox capacity > 0;
#                                    a failed read is "could not determine" (M4)
#   scripts/ensure-namespace.sh      created with both labels when absent, refused when foreign or
#                                    when the read fails (M4)
#   scripts/wait-pods-ready.sh       bounded wait for the validation pods (test.sh)
#   scripts/check-network-policy.py  the live policy allows only kube-system/k8s-app=kube-dns:53 (M2)
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
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample \
       NAMESPACE=ubuntu-ami-sample RUN_ID=testrun1
unset NODEGROUP_NAME KUBECTL
NG=ubuntu-ami-sample-testrun1-ng

pass=0; fail=0; skip=0
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
    [ "${STUB_CLUSTER:-}" = denied ] && { echo "An error occurred (AccessDeniedException) when calling the DescribeCluster operation: not authorized" >&2; exit 254; }
    printf '%s\n' '{"cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com", "certificateAuthority": {"data": "Q0EtREFUQS1GSVhUVVJF"}, "kubernetesNetworkConfig": {"serviceIpv4Cidr": "10.100.0.0/16"}}}' ;;
  *) echo "STUB aws: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/kubectl" <<'SH'
#!/bin/bash
# Every call must name the test's context first (H6): a call without it fails loudly.
[ "${1:-}" = --context ] && [ "${2:-}" = "$STUB_CTX" ] || { echo "STUB kubectl: call without --context $STUB_CTX: $*" >&2; exit 97; }
shift 2
printf '%s\n' "$*" >> "$STUB_KUBECTL_LOG"
args="$*"
forbidden() { echo "Error from server (Forbidden): $1 is forbidden: User \"test\" cannot get resource" >&2; exit 1; }
case "$args" in
  "config view --minify -o jsonpath={.clusters[0].cluster.server}")
    case "${STUB_SERVER:-match}" in
      match)    printf '%s' 'https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com' ;;
      slash)    printf '%s' 'https://example0123.GR7.us-west-2.eks.amazonaws.com:443/' ;;
      other)    printf '%s' 'https://EXAMPLE9999.yl4.us-west-2.eks.amazonaws.com' ;;
      empty)    printf '' ;;
      missing)  echo "error: context \"$STUB_CTX\" does not exist" >&2; exit 1 ;;
    esac ;;
  "get runtimeclass isolated-sandbox -o json")
    case "${STUB_RC:-one}" in
      one)     echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true"}}}' ;;
      two)     echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true","sandbox.preview/nitro":"true"}}}' ;;
      foreign) echo '{"handler":"isolated-sandbox","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true","example.com/other-pool":"true"}}}' ;;
      handler) echo '{"handler":"some-other-handler","scheduling":{"nodeSelector":{"eks.amazonaws.com/nitro-sandbox":"true"}}}' ;;
      absent)  echo 'Error from server (NotFound): runtimeclasses.node.k8s.io "isolated-sandbox" not found' >&2; exit 1 ;;
    esac ;;
  "get pods -n kube-system -l k8s-app=kube-dns -o json")
    case "${STUB_DNS:-two}" in
      two)    echo '{"items": [{"metadata": {"name": "coredns-a"}}, {"metadata": {"name": "coredns-b"}}]}' ;;
      none)   echo '{"items": []}' ;;
      denied) forbidden pods ;;
    esac ;;
  "get nodes -l eks.amazonaws.com/nodegroup="*" -o jsonpath={.items[0].metadata.name}")
    [ "${STUB_NODE_ERR:-}" = list ] && forbidden nodes; printf '%s' "${STUB_NODE:-}" ;;
  "get node "*" -o jsonpath={.status.conditions[?(@.type==\"Ready\")].status}")
    [ "${STUB_NODE_ERR:-}" = ready ] && forbidden nodes; printf '%s' "${STUB_READY:-}" ;;
  "get node "*" -o jsonpath={.status.allocatable.eks\\.amazonaws\\.com/nitro-sandbox}")
    [ "${STUB_NODE_ERR:-}" = cap ] && forbidden nodes; printf '%s' "${STUB_CAP:-}" ;;
  "get namespace "*" -o json")
    case "${STUB_NS:-absent}" in
      absent) echo 'Error from server (NotFound): namespaces "ubuntu-ami-sample" not found' >&2; exit 1 ;;
      own)    echo '{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}' ;;
      otherrun) echo '{"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun2"}}}' ;;
      foreign) echo '{"metadata": {"labels": {"team": "someone-else"}}}' ;;
      denied) forbidden namespaces ;;
    esac ;;
  "create -f "*) cat "$3" > "$STUB_CREATED"; echo "namespace/created" ;;
  "get pod "*" -n "*" -o json")
    case "${STUB_PODS:-ready}" in
      ready)   echo '{"status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}' ;;
      pending) echo '{"status": {"phase": "Pending", "conditions": [{"type": "Ready", "status": "False"}], "containerStatuses": [{"state": {"waiting": {"reason": "ContainerCreating"}}}]}}' ;;
      absent)  echo 'Error from server (NotFound): pods "x" not found' >&2; exit 1 ;;
      denied)  forbidden pods ;;
      notjson) echo '<html>502 Bad Gateway</html>' ;;
      nostatus) echo '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "x"}}' ;;
    esac ;;
  *) echo "STUB kubectl: unexpected call: $args" >&2; exit 97 ;;
esac
SH
chmod +x "$STUB/aws" "$STUB/kubectl"
export PATH="$STUB:$PATH" STUB_CREATED="$WORK/created.yaml" KUBE_CONTEXT=example-context STUB_CTX=example-context \
       STUB_KUBECTL_LOG="$WORK/kubectl-calls.log"

echo "== 0/6 the kube context is the cluster the AWS calls use: require_kube_context (H6) ====="
# Run through the real ensure-namespace.sh, the first script that changes the cluster; each
# refusal must also leave the namespace uncreated.
kx() { : > "$STUB_CREATED"; env "$@" bash "$HERE/ensure-namespace.sh" > "$WORK/kx-$CASE.log" 2>&1; }
CASE=match; rc=0; kx STUB_SERVER=match || rc=$?
check "ACCEPT a context whose server is the cluster's API endpoint" 0 "$rc" "$WORK/kx-match.log" 'kube context example-context is cluster example-cluster'
CASE=slash; rc=0; kx STUB_SERVER=slash || rc=$?
check "ACCEPT the same server written with other case, :443 and a trailing slash" 0 "$rc" "$WORK/kx-slash.log" 'is cluster example-cluster'
while IFS='|' read -r CASE envs rx why; do
  [ -n "$CASE" ] || continue
  rc=0; kx $envs || rc=$?
  check "$why" 1 "$rc" "$WORK/kx-$CASE.log" "$rx"
  [ ! -s "$STUB_CREATED" ]; check "  ... and nothing was created" 0 $? "$WORK/kx-$CASE.log"
done <<'CASES'
other|STUB_SERVER=other|points at https://EXAMPLE9999.* but cluster example-cluster's API endpoint is https://EXAMPLE0123|REJECT a context that points at another cluster
missing|STUB_SERVER=missing|could not read kube context 'example-context'|REJECT a context the kubeconfig does not have (unreadable)
empty|STUB_SERVER=empty|names no cluster server|REJECT a context with no cluster server
unset|KUBE_CONTEXT=|KUBE_CONTEXT is not set.*never falls back to the current context|REJECT no KUBE_CONTEXT (no fallback to the current context)
nocluster|STUB_CLUSTER=denied|could not read the API endpoint of cluster example-cluster|REJECT when the cluster's endpoint cannot be read
CASES
# The rule in the code: every kubectl call goes through kc (--context), and nothing changes the
# kubeconfig's current context. Comments are stripped before matching.
cat > "$WORK/kc_static.py" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
files = [os.path.join(root, f) for f in ("setup.sh", "test.sh", "clean.sh")] + sorted(glob.glob(os.path.join(root, "scripts", "*.sh"))) \
    + sorted(glob.glob(os.path.join(root, "scripts", "lib", "*.sh")))
def keep_lines(m):  # replace a quoted span, keeping its line breaks so line numbers stay right
    return '""' + "\n" * m.group(0).count("\n")
bad = []
for f in files:
    if os.path.basename(f).startswith("test-"):
        continue
    raw = open(f).read().split("\n")
    # full-line comments, then double-quoted text (it may span lines), then trailing comments,
    # then single-quoted text: what is left is code, so a message that names kubectl is not a call
    text = "\n".join("" if l.lstrip().startswith("#") else l for l in raw)
    text = re.sub(r'"(?:\\.|[^"\\])*"', keep_lines, text, flags=re.S)
    text = "\n".join(re.sub(r"(^|\s)#.*$", r"\1", l) for l in text.split("\n"))
    text = re.sub(r"'[^']*'", keep_lines, text, flags=re.S)
    for n, (code, line) in enumerate(zip(text.split("\n"), raw), 1):
        if re.search(r"use-context", code):
            bad.append(f"{f}:{n}: use-context")
        if re.search(r"(^|[\s;|&(])\$?\{?KUBECTL\b", code):
            bad.append(f"{f}:{n}: KUBECTL variable")
        if re.search(r"(^|[\s;|&(])kubectl\s", code) and "command -v kubectl" not in code and "kubectl --context \"$KUBE_CONTEXT\"" not in line:
            bad.append(f"{f}:{n}: bare kubectl")
for b in bad:
    print("FAIL: " + b)
print("ALL KUBECTL CALLS NAME THE CONTEXT" if not bad else "REFUSED")
sys.exit(1 if bad else 0)
PY
rc=0; python3 "$WORK/kc_static.py" "$SAMPLE_DIR_REAL" > "$WORK/kc-static.log" 2>&1 || rc=$?
check "ACCEPT the sample: every kubectl call goes through kc, and nothing runs config use-context" 0 "$rc" "$WORK/kc-static.log" 'ALL KUBECTL CALLS NAME THE CONTEXT'
for v in bare var usectx; do
  mkdir -p "$WORK/static-$v/scripts/lib"; : > "$WORK/static-$v/setup.sh"; : > "$WORK/static-$v/test.sh"
  # a comment that names kubectl must not count; the line after it is the case
  case "$v" in
    bare)   printf '# kubectl get pods is shown on the page\nkubectl get pods -n x\n' > "$WORK/static-$v/clean.sh" ;;
    var)    printf 'x=$($KUBECTL get ns)\n' > "$WORK/static-$v/clean.sh" ;;
    usectx) printf 'kc config use-context other\n' > "$WORK/static-$v/clean.sh" ;;
  esac
  rc=0; python3 "$WORK/kc_static.py" "$WORK/static-$v" > "$WORK/kc-static-$v.log" 2>&1 || rc=$?
  check "REJECT a script with $v (a bare kubectl call / a \$KUBECTL call / config use-context)" 1 "$rc" "$WORK/kc-static-$v.log" 'clean.sh:[12]: '
done
echo

echo "== 1/6 cluster prerequisites: scripts/00c-check-cluster.sh =============================="
cc() { env STUB_ADDON="$2" STUB_RC="$3" STUB_DNS="${4:-two}" bash "$HERE/00c-check-cluster.sh" > "$WORK/cc-$1.log" 2>&1; }
rc=0; cc ok on one || rc=$?
check "ACCEPT vpc-cni ACTIVE with network policy on, a RuntimeClass selecting eks.amazonaws.com/nitro-sandbox=true, and cluster DNS pods" 0 "$rc" "$WORK/cc-ok.log" 'CLUSTER PREREQUISITES OK.*2 cluster DNS pod'
rc=0; cc yaml yaml-on two || rc=$?
check "ACCEPT network policy given as YAML, and a RuntimeClass selecting both labels the node registers with" 0 "$rc" "$WORK/cc-yaml.log" 'CLUSTER PREREQUISITES OK'
rc=0; cc absent absent one || rc=$?
check "REJECT a cluster with no vpc-cni add-on, printing the create-addon command" 1 "$rc" "$WORK/cc-absent.log" 'aws eks create-addon .*--addon-name vpc-cni'
grep -q -- '--resolve-conflicts NONE' "$WORK/cc-absent.log"; check "the suggested create-addon command never overwrites an existing amazon-vpc-cni ConfigMap (--resolve-conflicts NONE)" 0 $? "$WORK/cc-absent.log"
grep -q 'enableNetworkPolicy' "$WORK/cc-absent.log"; check "the suggested create-addon command turns network policy on" 0 $? "$WORK/cc-absent.log"
grep -q 'Every NetworkPolicy object already on' "$WORK/cc-absent.log"; check "  ... and warns (L3) that every existing NetworkPolicy on the cluster starts being enforced" 0 $? "$WORK/cc-absent.log"
rc=0; cc off off one || rc=$?
check "REJECT a vpc-cni add-on with network policy off, printing the update-addon command" 1 "$rc" "$WORK/cc-off.log" 'network policy off.*|update-addon'
grep -q 'test the change on a cluster that is' "$WORK/cc-off.log"; check "  ... with the same cluster-wide warning (L3)" 0 $? "$WORK/cc-off.log"
! grep -q 'WARNING: turning network policy' "$WORK/cc-ok.log"; check "  ... which an already-enforcing cluster is not shown" 0 $? "$WORK/cc-ok.log"
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
rc=0; cc dns-none on one none || rc=$?
check "REJECT a cluster whose DNS pods do not carry k8s-app=kube-dns (the policy would block DNS)" 1 "$rc" "$WORK/cc-dns-none.log" 'no pod in kube-system carries k8s-app=kube-dns'
rc=0; cc dns-denied on one denied || rc=$?
check "REJECT (could not determine) when the DNS pods cannot be listed" 1 "$rc" "$WORK/cc-dns-denied.log" 'could not list the cluster DNS pods'

echo
echo "== 2/6 node labels and taint in the user data: scripts/join-nodegroup.sh (M3) =========="
rc=0; bash "$HERE/join-nodegroup.sh" --render-user-data > "$WORK/ud-default.sh" 2> "$WORK/ud-default.err" || rc=$?
check "the user data renders (per-run node group name)" 0 "$rc" "$WORK/ud-default.err"
for want in '^#!/bin/bash$' "--node-labels=[^' ]*eks\.amazonaws\.com/nodegroup=$NG" "--node-labels=[^' ]*eks\.amazonaws\.com/nitro-sandbox=true" \
            "--node-labels=[^' ]*sandbox\.preview/nitro=true" '--register-with-taints=sandbox\.preview/ubuntu-ami=true:NoSchedule' \
            "--apiserver-endpoint 'https://EXAMPLE0123" "--dns-cluster-ip '10\.100\.0\.10'"; do
  grep -qE -- "$want" "$WORK/ud-default.sh"; check "the rendered user data carries /$want/" 0 $? "$WORK/ud-default.sh"
done
rc=0; RUN_ID=custom2 bash "$HERE/join-nodegroup.sh" --render-user-data > "$WORK/ud-custom.sh" 2>&1 || rc=$?
check "another run id reaches the nodegroup label (the name is derived, never the default)" 0 "$rc" "$WORK/ud-custom.sh" 'eks\.amazonaws\.com/nodegroup=ubuntu-ami-sample-custom2-ng[,]'
! grep -q "nodegroup=$NG" "$WORK/ud-custom.sh"; check "  ... and leaves no other run's node group name behind" 0 $? "$WORK/ud-custom.sh"
cu() { bash "$HERE/join-nodegroup.sh" --check-user-data "$WORK/ud-$1.sh" > "$WORK/cu-$1.log" 2>&1; }
rc=0; cu default || rc=$?
check "ACCEPT the rendered user data (check_user_data)" 0 "$rc" "$WORK/cu-default.log" 'USER DATA OK'
sed "s#eks\.amazonaws\.com/nodegroup=$NG,##" "$WORK/ud-default.sh" > "$WORK/ud-no-ng.sh"
sed 's#,eks\.amazonaws\.com/nitro-sandbox=true##' "$WORK/ud-default.sh" > "$WORK/ud-no-nitro.sh"
sed 's#,sandbox\.preview/nitro=true##' "$WORK/ud-default.sh" > "$WORK/ud-no-preview.sh"
sed 's# --register-with-taints=[^'"'"']*##' "$WORK/ud-default.sh" > "$WORK/ud-no-taint.sh"
sed '1d' "$WORK/ud-default.sh" > "$WORK/ud-no-shebang.sh"
# The reviewer's fixture: a shebang, one COMMENT holding every required string, and exit 0.
printf '#!/bin/bash\n# /etc/eks/bootstrap.sh example-cluster --kubelet-extra-args --node-labels=eks.amazonaws.com/nodegroup=%s,eks.amazonaws.com/nitro-sandbox=true,sandbox.preview/nitro=true --register-with-taints=sandbox.preview/ubuntu-ami=true:NoSchedule\nexit 0\n' "$NG" > "$WORK/ud-comment-only.sh"
# exit before the (otherwise correct) bootstrap
{ head -n 1 "$WORK/ud-default.sh"; echo 'exit 0'; tail -n +2 "$WORK/ud-default.sh"; } > "$WORK/ud-exit-first.sh"
# the bootstrap twice
{ cat "$WORK/ud-default.sh"; tail -n +3 "$WORK/ud-default.sh"; } > "$WORK/ud-twice.sh"
# labels and taint only in a trailing comment on the bootstrap command's last line, after the cluster name
sed '/^  --kubelet-extra-args /{N;s#^  --kubelet-extra-args '"'"'\(.*\)'"'"' \\\n\(.*\)$#  --kubelet-extra-args '"'"'--v=2'"'"' \\\n\2 \# \1#;}' \
  "$WORK/ud-default.sh" > "$WORK/ud-trailing-comment.sh"
# the right command commented out, a different one active
sed 's#^/etc/eks/bootstrap.sh#true \#/etc/eks/bootstrap.sh#' "$WORK/ud-default.sh" > "$WORK/ud-commented-cmd.sh"
# another cluster
sed "s#^  'example-cluster'\$#  'some-other-cluster'#" "$WORK/ud-default.sh" > "$WORK/ud-other-cluster.sh"
while IFS='|' read -r name rx why; do
  [ -n "$name" ] || continue
  cmp -s "$WORK/ud-default.sh" "$WORK/ud-$name.sh" && { echo "  FAIL  the $name mutation did not change the user data"; fail=$((fail+1)); continue; }
  rc=0; cu "$name" || rc=$?
  check "$why" 1 "$rc" "$WORK/cu-$name.log" "$rx"
done <<'CASES'
no-ng|lacks eks\.amazonaws\.com/nodegroup=ubuntu-ami-sample-testrun1-ng|REJECT user data missing the eks.amazonaws.com/nodegroup label
no-nitro|lacks eks\.amazonaws\.com/nitro-sandbox=true|REJECT user data missing eks.amazonaws.com/nitro-sandbox=true
no-preview|lacks sandbox\.preview/nitro=true|REJECT user data missing sandbox.preview/nitro=true
no-taint|register-with-taints lacks sandbox\.preview/ubuntu-ami=true:NoSchedule|REJECT user data missing the --register-with-taints taint
no-shebang|does not start with #!/bin/bash|REJECT user data cloud-init would not run (no #! line)
comment-only|has 0 active /etc/eks/bootstrap.sh commands|REJECT the reviewer's fixture: every required string only in a comment, then exit 0
exit-first|runs other commands before bootstrap.sh: 'exit 0'|REJECT user data that exits before bootstrap.sh
twice|has 2 active /etc/eks/bootstrap.sh commands|REJECT user data with two bootstrap.sh commands
trailing-comment|--node-labels lacks|REJECT labels and taint that appear only in a trailing comment
commented-cmd|has 0 active /etc/eks/bootstrap.sh commands|REJECT a commented-out bootstrap.sh behind another command
other-cluster|is not given the cluster name 'example-cluster' as its last argument|REJECT a bootstrap.sh for another cluster
CASES

echo
echo "== 3/6 node Ready with nitro-sandbox capacity: scripts/wait-node-ready.sh (M4) ========"
wn() { env STUB_NODE="$2" STUB_READY="$3" STUB_CAP="$4" STUB_NODE_ERR="${5:-}" NODE_READY_TIMEOUT=2 NODE_POLL_SECONDS=1 bash "$HERE/wait-node-ready.sh" > "$WORK/wn-$1.log" 2>&1; }
rc=0; wn ok node-a True 20 || rc=$?
check "ACCEPT a Ready node advertising eks.amazonaws.com/nitro-sandbox=20" 0 "$rc" "$WORK/wn-ok.log" 'advertises allocatable eks.amazonaws.com/nitro-sandbox=20'
rc=0; wn zero node-a True 0 || rc=$?
check "REJECT (timeout) a Ready node advertising nitro-sandbox=0" 1 "$rc" "$WORK/wn-zero.log" "Ready but advertises allocatable eks.amazonaws.com/nitro-sandbox='0'"
rc=0; wn none node-a True "" || rc=$?
check "REJECT (timeout) a Ready node advertising no nitro-sandbox resource" 1 "$rc" "$WORK/wn-none.log" "nitro-sandbox='<none>'"
rc=0; wn notready node-a False 20 || rc=$?
check "REJECT (timeout) a node that is not Ready, whatever its capacity" 1 "$rc" "$WORK/wn-notready.log" 'is not Ready'
rc=0; wn nonode "" "" "" || rc=$?
check "REJECT (timeout) when no node of the node group registers" 1 "$rc" "$WORK/wn-nonode.log" "no node labelled eks.amazonaws.com/nodegroup=$NG"
rc=0; wn listdenied "" "" "" list || rc=$?
check "REJECT (could not determine) when listing the node group's nodes is forbidden, not 'no node registered'" 1 "$rc" "$WORK/wn-listdenied.log" 'could not determine the nodes of node group'
! grep -q 'registered within' "$WORK/wn-listdenied.log"; check "  ... and it does not misreport the failure as an absent node" 0 $? "$WORK/wn-listdenied.log"
rc=0; wn capdenied node-a True 20 cap || rc=$?
check "REJECT (could not determine) when reading the node's capacity is forbidden" 1 "$rc" "$WORK/wn-capdenied.log" 'could not determine the nitro-sandbox capacity of node node-a'

echo
echo "== 4/6 the sample's namespace: scripts/ensure-namespace.sh (M4) ======================="
en() { : > "$STUB_CREATED"; env STUB_NS="$2" bash "$HERE/ensure-namespace.sh" > "$WORK/en-$1.log" 2>&1; }
rc=0; en absent absent || rc=$?
check "ACCEPT an absent namespace: created in one call" 0 "$rc" "$WORK/en-absent.log" 'created namespace ubuntu-ami-sample'
grep -q 'app.kubernetes.io/part-of: ubuntu-ami-sample' "$STUB_CREATED" && grep -q 'app.kubernetes.io/instance: testrun1' "$STUB_CREATED"
check "  ... and created already carrying both labels" 0 $? "$STUB_CREATED"
rc=0; en own own || rc=$?
check "ACCEPT this run's own namespace (reused)" 0 "$rc" "$WORK/en-own.log" "reusing this run's namespace"
rc=0; en otherrun otherrun || rc=$?
check "REJECT a namespace labelled for another run" 1 "$rc" "$WORK/en-otherrun.log" "instance='testrun2'"
rc=0; en foreign foreign || rc=$?
check "REJECT a namespace another workload owns" 1 "$rc" "$WORK/en-foreign.log" 'exists but is not this run'
rc=0; en denied denied || rc=$?
check "REJECT (could not determine) when the namespace read is forbidden, never taking it as absent" 1 "$rc" "$WORK/en-denied.log" 'could not determine whether namespace'
[ ! -s "$STUB_CREATED" ]; check "  ... and nothing was created" 0 $? "$WORK/en-denied.log"

echo
echo "== 5/6 bounded pod readiness wait: scripts/wait-pods-ready.sh (test.sh) =============="
wp() { env STUB_PODS="$2" POD_READY_TIMEOUT=2 POD_POLL_SECONDS=1 bash "$HERE/wait-pods-ready.sh" ordinary-pod isolated-sandbox-pod > "$WORK/wp-$1.log" 2>&1; }
rc=0; wp ready ready || rc=$?
check "ACCEPT pods that are Ready" 0 "$rc" "$WORK/wp-ready.log" 'pods Ready in ubuntu-ami-sample'
rc=0; wp pending pending || rc=$?
check "REJECT (timeout) pods still ContainerCreating, naming each and its reason" 1 "$rc" "$WORK/wp-pending.log" 'isolated-sandbox-pod \(phase Pending, waiting reason ContainerCreating\)'
rc=0; wp absent absent || rc=$?
check "REJECT (timeout) pods that were never created" 1 "$rc" "$WORK/wp-absent.log" 'not created yet'
rc=0; wp denied denied || rc=$?
check "REJECT (could not determine) at once when a pod read is forbidden" 1 "$rc" "$WORK/wp-denied.log" 'could not determine the state of pod ordinary-pod'
# An answer the parser cannot read must stop on the first read, not wait out the timeout.
for c in notjson nostatus; do
  : > "$STUB_KUBECTL_LOG"; rc=0; wp "$c" "$c" || rc=$?
  check "REJECT (could not determine) at once when the pod answer is $c" 1 "$rc" "$WORK/wp-$c.log" 'could not determine the state of pod ordinary-pod in ubuntu-ami-sample \(unreadable pod JSON\)'
  [ "$(grep -c '^get pod ' "$STUB_KUBECTL_LOG")" = 1 ]; check "  ... after one pod read, without waiting" 0 $? "$STUB_KUBECTL_LOG"
done

echo
echo "== 6/6 the sandbox's egress policy: scripts/check-network-policy.py (M2) ================"
GOOD_NP='{"spec": {"podSelector": {"matchLabels": {"app": "isolated-sandbox-pod"}}, "policyTypes": ["Ingress", "Egress"], "ingress": [],
 "egress": [{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
             "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]}]}}'
np() { printf '%s' "$2" | python3 "$HERE/check-network-policy.py" > "$WORK/np-$1.log" 2>&1; }
mut() { printf '%s' "$GOOD_NP" | python3 -c "import json,sys; d=json.load(sys.stdin); r=d['spec']['egress'][0]; $1; print(json.dumps(d))"; }
rc=0; np good "$GOOD_NP" || rc=$?
check "ACCEPT egress only to kube-system pods labelled k8s-app=kube-dns on UDP and TCP 53" 0 "$rc" "$WORK/np-good.log" 'NETWORK POLICY OK'
if python3 -c 'import yaml' 2>/dev/null; then
  rc=0; python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$SAMPLE_DIR_REAL/deploy/network-policy.yaml" \
    | python3 "$HERE/check-network-policy.py" > "$WORK/np-deploy.log" 2>&1 || rc=$?
  check "ACCEPT the shipped deploy/network-policy.yaml itself" 0 "$rc" "$WORK/np-deploy.log" 'NETWORK POLICY OK'
else
  echo "  SKIP  the shipped deploy/network-policy.yaml (PyYAML not installed; the README sync check below still runs)"; skip=$((skip+1))
fi
while IFS='|' read -r name code rx why; do
  [ -n "$name" ] || continue
  rc=0; np "$name" "$(mut "$code")" || rc=$?
  check "$why" 1 "$rc" "$WORK/np-$name.log" "$rx"
done <<'CASES'
any-namespace|r["to"] = [{"namespaceSelector": {}}]|does not name both a namespace and a pod selector|REJECT the R1-A policy: namespaceSelector {} (port 53 to any pod)
two-peers|r["to"] = [{"namespaceSelector": r["to"][0]["namespaceSelector"]}, {"podSelector": r["to"][0]["podSelector"]}]|does not name both|REJECT namespace and pod selectors in separate peers (an OR, not an AND)
wrong-pod|r["to"][0]["podSelector"] = {"matchLabels": {"app": "decoy"}}|podSelector is|REJECT a pod selector other than k8s-app=kube-dns
port-443|r["ports"].append({"protocol": "TCP", "port": 443})|only UDP and TCP port 53 are allowed|REJECT an extra port
udp-only|r["ports"] = [{"protocol": "UDP", "port": 53}]|must be exactly UDP 53 and TCP 53|REJECT UDP 53 alone (TCP 53 missing)
tcp-only|r["ports"] = [{"protocol": "TCP", "port": 53}]|must be exactly UDP 53 and TCP 53|REJECT TCP 53 alone (UDP 53 missing)
dup-udp|r["ports"].append({"protocol": "UDP", "port": 53})|must be exactly UDP 53 and TCP 53|REJECT a duplicate UDP 53
no-ports|r.pop("ports")|allows every port|REJECT a rule with no ports
ipblock|r["to"].append({"ipBlock": {"cidr": "0.0.0.0/0"}})|is an ipBlock|REJECT an ipBlock peer
all-dest|r.pop("to")|allows every destination|REJECT a rule with no 'to'
ingress|d["spec"]["ingress"] = [{}]|ingress is not empty|REJECT any allowed ingress
CASES
# The README shows the policy whole: its yaml block must be the shipped file, comments stripped.
python3 - "$SAMPLE_DIR_REAL/README.md" "$SAMPLE_DIR_REAL/deploy/network-policy.yaml" <<'PY' > "$WORK/np-readme.log" 2>&1; check "the README shows deploy/network-policy.yaml whole (same lines, comments stripped)" 0 $? "$WORK/np-readme.log"
import re, sys
readme, policy = open(sys.argv[1]).read(), open(sys.argv[2]).read()
sec = readme.split("### The validation sandbox's network policy", 1)[1]
block = re.search(r"```yaml\n(.*?)```", sec, re.S).group(1)
want = "\n".join(l for l in policy.splitlines() if not l.lstrip().startswith("#")).strip()
sys.exit(0 if block.strip() == want else print("README block differs from the deploy file") or 1)
PY

echo
printf 'passed %d, failed %d, skipped %d\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]] || exit 1
echo "cluster prerequisites, user data, node capacity, namespace, pod readiness and the egress policy proven both ways in the real scripts."
