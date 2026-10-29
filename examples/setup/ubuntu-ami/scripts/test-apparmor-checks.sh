#!/usr/bin/env bash
# test-apparmor-checks.sh: proves test.sh's AppArmor checks (criterion 8) and its network-policy
# control both ways, in the REAL test.sh, with a stub `kubectl` and `aws` first on PATH (no
# cluster, no AWS account), and the AppArmor profile's own rules in the REAL
# scripts/check-apparmor-profile.py. The stub answers every call test.sh makes with a good node;
# each case changes one answer, and must make exactly its own check fail:
#
#   8a  AppArmor on and enforcing on the host: the profile loaded in enforce mode, the node's copy
#       is this sample's file; a profile the node never loaded reads absent.
#   8b  the scoped profile works on an ordinary pod (deploy/pod-apparmor-scoped.yaml): it runs
#       under 'ubuntu-ami-sample-profile (enforce)', its /etc/shadow write fails with EACCES and
#       the kernel logs the profile's DENIED line since T0, a write elsewhere in /etc succeeds,
#       and deleted by its exact name it is gone within its grace period with no DENIED signal.
#   8c  the reject control (deploy/pod-apparmor-reject.yaml) is refused with containerd's exact
#       message for a missing profile.
#   the sandbox pod runs Unconfined; the 443 refusal from the sandbox has its control (the same
#   connect from the ordinary pod succeeds).
#   static: the profile carries the signal rules containerd's default profile has and audit-deny
#   rules only.
#
#   scripts/test-apparmor-checks.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-apparmor-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export ISSUE10_RUN_DIR="$WORK/run" AWS_REGION=us-west-2 CLUSTER_NAME=example-cluster RESOURCE_PREFIX=ubuntu-ami-sample \
       NAMESPACE=ubuntu-ami-sample RUN_ID=testrun1 KUBE_CONTEXT=example-context STUB_CTX=example-context \
       POD_READY_TIMEOUT=2 POD_POLL_SECONDS=1 SCOPED_POD_TRIES=2 SCOPED_POD_POLL_SECONDS=0 \
       REJECT_POD_TRIES=2 REJECT_POD_POLL_SECONDS=0 SCOPED_DELETE_MARGIN=5
export STUB_PROFILE_SHA="$(sha256sum "$SAMPLE/manifests/ubuntu-ami-sample-profile" | cut -d' ' -f1)"
unset NODEGROUP_NAME

pass=0; fail=0
check() { # check <description> <expected-rc> <actual-rc> <log> [<regex the log must match>]
  local ok=0
  [[ "$3" -eq "$2" ]] || ok=1
  if [[ $ok -eq 0 && -n "${5:-}" ]]; then grep -qE -- "$5" "$4" || ok=1; fi
  if [[ $ok -eq 0 ]]; then printf '  PASS  %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %s (expected rc=%s%s, got rc=%s)\n' "$1" "$2" "${5:+ and /$5/}" "$3"; sed 's/^/        | /' "$4" | grep -E 'FAIL|STUB' | tail -n 8; fail=$((fail+1)); fi
}

STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/aws" <<'SH'
#!/bin/bash
case "$1 $2" in
  "eks describe-cluster") printf '%s\n' '{"cluster": {"endpoint": "https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com"}}' ;;
  *) echo "STUB aws: unexpected call: $*" >&2; exit 97 ;;
esac
SH
cat > "$STUB/kubectl" <<'SH'
#!/bin/bash
exec python3 "$(dirname "$0")/kubectl.py" "$@"
SH
cat > "$STUB/kubectl.py" <<'PY'
# Stub kubectl for test-apparmor-checks.sh: a good node, with one answer changed per case (env).
import datetime, json, os, sys, time
E = os.environ.get
a = sys.argv[1:]
if a[:2] != ["--context", E("STUB_CTX")]:
    sys.exit(f"STUB kubectl: call without --context {E('STUB_CTX')}: {a}")
a = a[2:]
line = " ".join(a)
with open(E("STUB_LOG"), "a") as f:
    f.write(line + "\n")
NS, NODE = "ubuntu-ami-sample", "node-a"
SAMPLE_PROFILE = "ubuntu-ami-sample-profile"
DBG = "node-debugger-node-a-abcde"
GONE = os.path.join(E("STUB_STATE"), "scoped-gone")
REJ_MSG = "failed to get container spec opts: failed to generate apparmor spec opts: apparmor profile not found profile-that-does-not-exist"
def out(s=""):
    sys.stdout.write(s); sys.exit(0)
def notfound(kind, name):
    sys.stderr.write(f'Error from server (NotFound): {kind} "{name}" not found\n'); sys.exit(1)
def jp():
    return next((x[len("jsonpath="):] for x in a if x.startswith("jsonpath=")), "")
if line == "config view --minify -o jsonpath={.clusters[0].cluster.server}":
    out("https://EXAMPLE0123.gr7.us-west-2.eks.amazonaws.com")
if line == f"get namespace {NS} -o json":
    out(json.dumps({"metadata": {"labels": {"app.kubernetes.io/part-of": "ubuntu-ami-sample", "app.kubernetes.io/instance": "testrun1"}}}))
if a[:2] == ["get", "pod"] and a[-2:] == ["-o", "json"]:
    out(json.dumps({"status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}))
if a[:2] == ["get", "nodes"]:
    out(NODE)
if a[:3] == ["get", "node", NODE]:
    p = jp()
    if "Ready" in p: out("True")
    if "nitro-sandbox-bogus" in p or "nitro-bogus" in p: out("")
    if "labels" in p: out("true")
    if "allocatable" in p: out("20")
if a[:1] == ["apply"]:
    with open(a[a.index("-f") + 1]) as f:
        text = f.read()
    with open(E("STUB_APPLIED"), "a") as f:
        f.write(text + "\n---\n")
    out("pod/applied\n")
if a[:3] == ["delete", "pod", "apparmor-scoped-pod"]:
    mode = E("STUB_SCOPED_DELETE", "ok")
    if mode == "stuck":
        sys.stderr.write("error: timed out waiting for the condition on pods/apparmor-scoped-pod\n"); sys.exit(1)
    if mode == "slow":
        time.sleep(3)
    open(GONE, "w").close()
    out('pod "apparmor-scoped-pod" deleted\n')
if a[:1] == ["delete"]:
    out("pod deleted\n")
if a[:2] == ["get", "pod"] and len(a) > 2:
    pod, p = a[2], jp()
    if pod == "apparmor-scoped-pod":
        if a[-2:] == ["-o", "name"]:
            if os.path.exists(GONE): notfound("pods", pod)
            out("pod/apparmor-scoped-pod\n")
        if p == "{.status.phase}": out(E("STUB_SCOPED_PHASE", "Running"))
        if p.endswith("appArmorProfile.type}"): out(E("STUB_SCOPED_TYPE", "Localhost"))
        if p.endswith("localhostProfile}"): out(E("STUB_SCOPED_PROFILE", SAMPLE_PROFILE))
        if p == "{.spec.nodeName}": out(E("STUB_SCOPED_NODE", NODE))
        if p == "{.spec.terminationGracePeriodSeconds}": out(E("STUB_GRACE", "15"))
    if pod == "isolated-sandbox-pod":
        if p.endswith("appArmorProfile.type}"): out(E("STUB_SBX_TYPE", "Unconfined"))
        if p == "{.status.phase}": out(E("STUB_SBX_PHASE", "Running"))
        if p == "{.status.startTime}":
            out((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=150)).strftime("%Y-%m-%dT%H:%M:%SZ"))
    if pod == "apparmor-reject-control":
        rej = E("STUB_REJ", "refused")
        if p == "{.spec.nodeName}": out(NODE)
        if p == "{.status.phase}": out("Running" if rej == "running" else "Pending")
        if p.endswith("waiting.reason}"):
            out({"refused": "CreateContainerError", "running": "", "other": "CreateContainerError", "unanchored": "CreateContainerError", "imagepull": "ErrImagePull"}[rej])
        if p.endswith("waiting.message}"):
            out({"refused": REJ_MSG, "running": "", "other": "failed to create containerd container: some other error",
                 "unanchored": "kubelet: " + REJ_MSG + " (retrying)", "imagepull": "pull access denied"}[rej])
    if pod == "ordinary-pod" and p == "{.status.podIP}":
        out("10.0.0.9")
if a[:1] == ["exec"]:
    pod, cmd = a[1], " ".join(a[a.index("--") + 1:])
    if cmd == "date -u +%s": out("1700000000\n")
    if cmd == "cat /proc/self/attr/current":
        out({"apparmor-scoped-pod": E("STUB_SCOPED_ATTR", f"{SAMPLE_PROFILE} (enforce)"),
             "ordinary-pod": E("STUB_ORD_ATTR", "cri-containerd.apparmor.d (enforce)"),
             "isolated-sandbox-pod": "system_u:system_r:runtime_t:s0:c0.c1023"}[pod] + "\n")
    if pod == "apparmor-scoped-pod" and "> /etc/shadow" in cmd:
        out(E("STUB_SCOPED_SHADOW", "sh: line 1: /etc/shadow: Permission denied\nWRITE-FAILED") + "\n")
    if pod == "apparmor-scoped-pod" and "write-control" in cmd:
        out(E("STUB_SCOPED_CONTROL", "WRITTEN") + "\n")
    if cmd == "uname -r": out("6.18.56-nitro-ga\n" if pod == "ordinary-pod" else "6.18.54\n")
    if "/sys/block" in cmd: out("nvme0n1 " if pod == "ordinary-pod" else "vda vdb vdc ")
    if cmd == "cat /proc/uptime": out("50000.00 1.00\n" if pod == "ordinary-pod" else "100.00 1.00\n")
    if "/sys/class/net" in cmd: out("interface eth0 0e:00:00:00:00:01 up\ninterface lo 00:00:00:00:00:00 unknown\n")
    if "getent hosts" in cmd: out("172.20.0.1\n")
    if "/dev/tcp/172.20.0.1/443" in cmd:
        out((E("STUB_ORD_443", "connected") if pod == "ordinary-pod" else "refused") + "\n")
    if "/dev/tcp/10.0.0.9/53" in cmd: out("connected\n" if pod == "ordinary-pod" else "refused\n")
if a[:1] == ["debug"]:
    sys.stderr.write(f"Creating debugging pod {DBG} with container debugger on node {NODE}.\n"); sys.exit(0)
if a[:1] == ["wait"]:
    out(f"pod/{DBG} condition met\n")
if a[:1] == ["logs"]:
    out("\n".join([
        "KERNEL=6.18.56-nitro-ga", "btf=present", "btf_bogus=absent", "ne=present", "ne_bogus=absent",
        "vsock=present", "vsock_bogus=absent", "tun=present", "tun_bogus=absent", "cma=14456832", "cma_bogus=",
        "erofs=present", "erofs_bogus=absent", "handler=present", "handler_bogus=absent", "containerd_gate=ok",
        "containerd_version=containerd github.com/containerd/containerd/v2 2.2.1", "apparmor_enabled=Y",
        f"apparmor_profile={E('STUB_AA_LOADED', 'loaded')}", "apparmor_profile_bogus=absent",
        f"apparmor_profile_mode={E('STUB_AA_MODE', 'enforce')}",
        f"apparmor_profile_sha256={E('STUB_AA_SHA', E('STUB_PROFILE_SHA'))}",
        f"apparmor_shadow_denials={E('STUB_SHADOW_DENIALS', '1')}", f"apparmor_bogus_denials={E('STUB_BOGUS_DENIALS', '0')}",
        f"apparmor_signal_denials={E('STUB_SIGNAL_DENIALS', '0')}", f"apparmor_bogus_signal_denials={E('STUB_BOGUS_SIGNAL_DENIALS', '0')}"]) + "\n")
if line == "get runtimeclass isolated-sandbox -o jsonpath={.metadata.name}":
    out("isolated-sandbox")
if line == f"get networkpolicy -n {NS} -o name":
    out("networkpolicy.networking.k8s.io/isolated-sandbox-pod-policy\n")
if line == f"get networkpolicy isolated-sandbox-pod-policy -n {NS} -o json":
    peer = {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
            "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}
    out(json.dumps({"spec": {"podSelector": {"matchLabels": {"app": "isolated-sandbox-pod"}}, "policyTypes": ["Ingress", "Egress"],
                             "ingress": [], "egress": [{"to": [peer], "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]}]}}))
sys.exit(f"STUB kubectl: unexpected call: {line}")
PY
chmod +x "$STUB/aws" "$STUB/kubectl"
export PATH="$STUB:$PATH"

# t <case> [VAR=value]: the real test.sh with the stub world changed as the case says.
t() {
  local c="$1"; shift
  export STUB_LOG="$WORK/$c.calls" STUB_APPLIED="$WORK/$c.applied" STUB_STATE="$WORK/$c.state"
  : > "$STUB_LOG"; : > "$STUB_APPLIED"; rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"
  env "$@" bash "$SAMPLE/test.sh" > "$WORK/$c.log" 2>&1 < /dev/null
}
# line <case> <assertion text, a fixed string>: PASS or FAIL, as test.sh printed it for that assertion
line() { grep -F -- "$2" "$WORK/$1.log" | grep -E '^  (PASS|FAIL)  ' | head -n 1 | awk '{print $1}'; }

A_LOADED="ACCEPT: the scoped profile ubuntu-ami-sample-profile is loaded on the node in enforce mode"
A_SHA="the profile on the node is this sample's manifests/ubuntu-ami-sample-profile"
A_RUNS="the scoped pod requests Localhost ubuntu-ami-sample-profile and runs on the sandbox node"
A_ATTR="ACCEPT: the scoped pod's process is confined by 'ubuntu-ami-sample-profile (enforce)' (attr/current)"
A_ORD="REJECT: the same label read on the ordinary pod, which requests no profile, does not name ubuntu-ami-sample-profile"
A_EACCES="ACCEPT: the scoped pod's write to /etc/shadow is refused with EACCES (Permission denied)"
A_CONTROL="REJECT: the same pod's write to a path the profile does not deny succeeds"
A_DENIED="ACCEPT: the node's kernel logged the profile's DENIED line for that write since T0"
A_BOGUS="REJECT: the same count for a profile the node never loaded is 0"
A_GONE="ACCEPT: deleted by its exact name, the scoped pod is gone within its grace period"
A_SIGNAL="ACCEPT: the node logged no DENIED signal under ubuntu-ami-sample-profile since T0"
A_BOGUS_SIGNAL="REJECT: the same signal count for a profile the node never loaded is 0"
A_REJ="REJECT: a pod naming an unloaded AppArmor profile is refused on the sandbox node: CreateContainerError"
A_SBX="the sandbox pod runs with appArmorProfile Unconfined, as the GA build notes require"
A_443="the same connect from the ordinary pod, which no policy selects, succeeds (control for the previous check)"

echo "== 1/3 ACCEPT: the scoped profile working on an ordinary pod, the sandbox Unconfined =========="
rc=0; t good || rc=$?
check "ACCEPT the good node: the real test.sh passes every check" 0 "$rc" "$WORK/good.log" '^passed [0-9]+, failed 0$'
for a in "$A_LOADED" "$A_SHA" "$A_RUNS" "$A_ATTR" "$A_ORD" "$A_EACCES" "$A_CONTROL" "$A_DENIED" "$A_BOGUS" "$A_GONE" \
         "$A_SIGNAL" "$A_BOGUS_SIGNAL" "$A_REJ" "$A_SBX" "$A_443"; do
  [ "$(line good "$a")" = PASS ]; check "  ... PASS: $a" 0 $? "$WORK/good.log"
done
grep -q 'name: apparmor-scoped-pod' "$WORK/good.applied" && grep -q 'localhostProfile: ubuntu-ami-sample-profile' "$WORK/good.applied" \
  && grep -q 'eks.amazonaws.com/nodegroup: "ubuntu-ami-sample-testrun1-ng"' "$WORK/good.applied" && ! grep -q '@NODEGROUP@' "$WORK/good.applied"
check "  ... it applied deploy/pod-apparmor-scoped.yaml rendered for this run's node group" 0 $? "$WORK/good.applied"
grep -qx 'delete pod apparmor-scoped-pod -n ubuntu-ami-sample --ignore-not-found --wait=true --timeout=20s' "$WORK/good.calls" \
  && grep -qx 'delete pod apparmor-reject-control -n ubuntu-ami-sample --ignore-not-found' "$WORK/good.calls" \
  && ! grep -qE '^delete .*(-l|--selector|--all)' "$WORK/good.calls"
check "  ... and deleted the scoped pod (waiting its 15 s grace plus 5 s) and the reject control by their exact names (no selector)" 0 $? "$WORK/good.calls"
python3 - "$WORK/good.calls" <<'PY'
import sys
c = [l.rstrip("\n") for l in open(sys.argv[1])]
first = lambda p: next(i for i, l in enumerate(c) if l.startswith(p))
assert first("exec apparmor-scoped-pod -n ubuntu-ami-sample -- sh -c { echo test > /etc/shadow; }") \
     < first("delete pod apparmor-scoped-pod") < first("debug node/node-a"), "write, then delete, then the node probe"
assert not any(l.startswith("exec isolated-sandbox-pod -n ubuntu-ami-sample -- sh -c { echo test > /etc/shadow") for l in c)
PY
check "  ... the /etc/shadow write runs in the scoped pod (not the sandbox), before its delete, and both before the node probe reads the journal" 0 $? "$WORK/good.calls"

echo "== 2/3 REJECT: each check refuses its one wrong answer ========================================="
while IFS='|' read -r c envs a; do
  [ -n "$c" ] || continue
  # VAR=value settings, separated by ';' (a value may hold spaces, never a ';')
  IFS=';' read -r -a ev <<< "$envs"
  rc=0; t "$c" "${ev[@]}" || rc=$?
  [ "$rc" = 1 ] && [ "$(line "$c" "$a")" = FAIL ] && [ "$(grep -c '^  FAIL  ' "$WORK/$c.log")" = 1 ]
  check "REJECT $c: '$a' fails, and it is the only failing check" 0 $? "$WORK/$c.log"
done <<CASES
notloaded|STUB_AA_LOADED=absent|$A_LOADED
complainmode|STUB_AA_MODE=complain|$A_LOADED
othersha|STUB_AA_SHA=0000000000000000000000000000000000000000000000000000000000000000|$A_SHA
nosha|STUB_AA_SHA=|$A_SHA
attrcomplain|STUB_SCOPED_ATTR=ubuntu-ami-sample-profile (complain)|$A_ATTR
attrdefault|STUB_SCOPED_ATTR=cri-containerd.apparmor.d (enforce)|$A_ATTR
ordprofile|STUB_ORD_ATTR=ubuntu-ami-sample-profile (enforce)|$A_ORD
ordunread|STUB_ORD_ATTR=|$A_ORD
notrunning|STUB_SCOPED_PHASE=Pending|$A_RUNS
othernode|STUB_SCOPED_NODE=node-b|$A_RUNS
otherprofile|STUB_SCOPED_PROFILE=some-other-profile|$A_RUNS
written|STUB_SCOPED_SHADOW=|$A_EACCES
readonlyfs|STUB_SCOPED_SHADOW=sh: line 1: /etc/shadow: Read-only file system WRITE-FAILED|$A_EACCES
controlrefused|STUB_SCOPED_CONTROL=sh: line 1: /etc/ubuntu-ami-sample-write-control: Read-only file system|$A_CONTROL
nodenied|STUB_SHADOW_DENIALS=0|$A_DENIED
bogusdenied|STUB_BOGUS_DENIALS=1|$A_BOGUS
stuck|STUB_SCOPED_DELETE=stuck|$A_GONE
slow|STUB_SCOPED_DELETE=slow;STUB_GRACE=1|$A_GONE
signaldenied|STUB_SIGNAL_DENIALS=46|$A_SIGNAL
bogussignal|STUB_BOGUS_SIGNAL_DENIALS=1|$A_BOGUS_SIGNAL
rejrunning|STUB_REJ=running|$A_REJ
rejother|STUB_REJ=other|$A_REJ
rejunanchored|STUB_REJ=unanchored|$A_REJ
rejimagepull|STUB_REJ=imagepull|$A_REJ
sbxlocalhost|STUB_SBX_TYPE=Localhost|$A_SBX
sbxfailed|STUB_SBX_PHASE=Failed|$A_SBX
ord443|STUB_ORD_443=refused|$A_443
CASES

echo "== 3/3 static: the profile's own rules, scripts/check-apparmor-profile.py ======================"
P="$SAMPLE/manifests/ubuntu-ami-sample-profile"
rc=0; python3 "$HERE/check-apparmor-profile.py" "$P" > "$WORK/prof-good.log" 2>&1 || rc=$?
check "ACCEPT the sample's profile: signal rules for unconfined, runc and itself; every deny is audit deny" 0 "$rc" "$WORK/prof-good.log" '^APPARMOR PROFILE OK'
# pm <id> <description> <python expression over t, the profile text> <expected FAIL regex>: a broken
# copy, refused. <id> names the case's files; the description may hold any character.
pm() {
  python3 -c 'import sys; t = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(eval(sys.argv[3]))' "$P" "$WORK/prof-$1" "$3"
  rc=0; python3 "$HERE/check-apparmor-profile.py" "$WORK/prof-$1" > "$WORK/prof-$1.log" 2>&1 || rc=$?
  cmp -s "$P" "$WORK/prof-$1" && { check "REJECT a profile with $2 (the case changed nothing: test bug)" 1 0 "$WORK/prof-$1.log"; return; }
  check "REJECT a profile with $2" 1 "$rc" "$WORK/prof-$1.log" "$4"
}
pm norunc      "no peer=runc"        't.replace("  signal (receive) peer=runc,\n", "")' '^FAIL: missing `signal \(receive\) peer=runc,`'
pm nounconf    "no peer=unconfined"  't.replace("  signal (receive) peer=unconfined,\n", "")' '^FAIL: missing `signal \(receive\) peer=unconfined,`'
pm noself      "no self signals"     't.replace("  signal (send,receive) peer=ubuntu-ami-sample-profile,\n", "")' '^FAIL: missing `signal \(send,receive\) peer=ubuntu-ami-sample-profile,`'
pm runccomment "peer=runc only in a comment" 't.replace("  signal (receive) peer=runc,\n", "  # signal (receive) peer=runc,\n")' '^FAIL: missing `signal \(receive\) peer=runc,`'
pm plainshadow "a plain deny on /etc/shadow" 't.replace("audit deny /etc/shadow* w,", "deny /etc/shadow* w,")' '^FAIL: `deny /etc/shadow\* w,` is a plain deny'
pm plainboot   "a plain deny on /boot"       't.replace("audit deny /boot/** w,", "deny /boot/** w,")' '^FAIL: `deny /boot/\*\* w,` is a plain deny'
pm noshadow    "no /etc/shadow rule"  't.replace("  audit deny /etc/shadow* w,\n", "")' '^FAIL: missing `audit deny /etc/shadow\* w,`'
pm othername   "another profile name" 't.replace("profile ubuntu-ami-sample-profile flags", "profile some-other-profile flags")' '^FAIL: no single `profile ubuntu-ami-sample-profile'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "test.sh's AppArmor checks and the 443 control proven both ways in the real script, and the profile's rules in the real checker."
