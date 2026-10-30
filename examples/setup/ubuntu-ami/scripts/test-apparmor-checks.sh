#!/usr/bin/env bash
# test-apparmor-checks.sh: proves test.sh's AppArmor checks (criterion 8) and its no-network
# checks (7/7) both ways, in the REAL test.sh, with a stub `kubectl` and `aws` first on PATH (no
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
#   the sandbox pod runs Unconfined.
#   7/7 the sandbox has no network: the pod carries sandbox.amazonaws.com/network-isolated="true"
#       (read from the API); test.sh's own in-guest network read (run here for real, on a fake
#       guest tree) shows only loopback with an address, no route, and every interface but lo
#       down (dummy0 down passes; dummy0 up, an extra address, a route, an unreadable file or an
#       incomplete read fail); test.sh's own connect probe (run here for real, with only
#       connect() faked) fails from the sandbox with ENETUNREACH (Network is unreachable), never
#       passing on a connect, a timeout, ECONNREFUSED, EHOSTUNREACH, an exec error or empty
#       output; and the same connect from the ordinary pod succeeds (the control).
#   8a/8b's node evidence comes from test.sh's own node probe: the stub keeps the script
#   `kubectl debug` is given and runs its AppArmor lines for real against a fake profile list,
#   profile file and kernel journal (a fake journalctl that honours -k and --since), so a wrong
#   filter, profile name, time bound or signal operation in the probe turns the suite red.
#   2b: test.sh acts only on a run whose record matches (names, cluster, Region), and refuses
#   while another process holds the run's lock.
#   static: the profile is one closed block holding the signal rules containerd's default profile
#   has (unconfined, runc, crun, itself) and audit-deny rules only.
#
#   scripts/test-apparmor-checks.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$(cd "$HERE/.." && pwd)"
REPO_ROOT_REAL="$(cd "$SAMPLE/../../.." && pwd)"
mkdir -p "$REPO_ROOT_REAL/tmp"
WORK="$(mktemp -d "$REPO_ROOT_REAL/tmp/test-apparmor-checks.XXXXXX")"
HOLDER=""   # section 2b's background lock holder, killed by its pid
trap '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; rm -rf "$WORK"' EXIT
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
printf 'aws %s\n' "$*" >> "$STUB_LOG"
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
        if p == "{.metadata.annotations.sandbox\\.amazonaws\\.com/network-isolated}": out(E("STUB_SBX_ANNOT", "true"))
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
if line == "get service kubernetes -n default -o jsonpath={.spec.clusterIP}":
    out(E("STUB_API_IP", "172.20.0.1"))
if a[:1] == ["exec"]:
    pod, cmd = a[1], " ".join(a[a.index("--") + 1:])
    rest = a[a.index("--") + 1:]
    def exec_error():
        sys.stderr.write("error: unable to upgrade connection: container not found\n"); sys.exit(1)
    # test.sh's own connect probe (python3 -c <code> <ip>) is RUN here, for real, with only the
    # socket's connect() faked by sitecustomize.py (FAKE_CONNECT: an errno name, timeout or
    # connected), so the case decides what the network answers and test.sh's code decides the rest.
    if rest[:2] == ["python3", "-c"] and len(rest) == 4 and "socket" in rest[2]:
        mode = E("STUB_SBX_CONNECT", "ENETUNREACH") if pod == "isolated-sandbox-pod" else E("STUB_ORD_CONNECT", "connected")
        if mode == "exec-error": exec_error()
        if mode == "empty": out("")
        if rest[3] != E("STUB_API_IP", "172.20.0.1"):
            sys.exit(f"STUB kubectl: the connect probe is aimed at {rest[3]}, not the API Service's ClusterIP")
        import subprocess
        r = subprocess.run([sys.executable, "-c", rest[2], rest[3]], capture_output=True, text=True,
                           env=dict(os.environ, PYTHONPATH=E("STUB_FAKESOCK"), FAKE_CONNECT=mode))
        sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
    # test.sh's own in-guest network read (sh -c <script>) is RUN here, for real, against a fake
    # /proc/net and /sys/class/net built from the case: its paths point into that tree, and the
    # tree's prefix is taken off its output again, so test.sh's code decides everything else.
    if pod == "isolated-sandbox-pod" and rest[:2] == ["sh", "-c"] and "NET-READ-END" in rest[2]:
        mode = E("STUB_SBX_NET_EXEC", "ok")
        if mode == "error": exec_error()
        import subprocess
        root = os.path.join(E("STUB_STATE"), "guest")
        net, sysnet = os.path.join(root, "proc", "net"), os.path.join(root, "sys", "class", "net")
        os.makedirs(net); os.makedirs(sysnet)
        nofile, unreadable = E("STUB_SBX_NOFILE", "").split(), E("STUB_SBX_UNREADABLE", "").split()
        def put(name, text):
            p = os.path.join(net, name)
            if name in unreadable: os.makedirs(p)   # [ -r ] passes, cat fails
            elif name not in nofile: open(p, "w").write(text)
        addrs = E("STUB_SBX_ADDR4", "127.0.0.1").split()
        lo = ["  +-- 127.0.0.0/8 2 0 2", "     +-- 127.0.0.0/31 1 0 0", "        |-- 127.0.0.0", "           /8 host LOCAL"] \
            + (["        |-- 127.0.0.1", "           /32 host LOCAL"] if "127.0.0.1" in addrs else []) \
            + ["     |-- 127.255.255.255", "        /32 link BROADCAST"]
        other = [l for x in addrs if x != "127.0.0.1" for l in (f"  +-- {x}/32 1 0 0", f"     |-- {x}", "        /32 host LOCAL")]
        put("fib_trie", "\n".join(["Main:"] + lo + other + ["Local:"] + lo + other) + "\n")
        put("route", "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT" + " " * 59 + "\n"
            + "".join(r.replace(" ", "\t") + "\n" for r in E("STUB_SBX_ROUTE", "").split("+") if r))
        v6 = E("STUB_SBX_V6", "00000000000000000000000000000001 01 80 10 80       lo")
        if v6 != "absent":   # one line per '+'-separated entry
            put("if_inet6", "".join(r + "\n" for r in v6.split("+") if r))
        if "sysnet" in nofile: os.rmdir(sysnet)
        for entry in ([] if "sysnet" in nofile else E("STUB_SBX_IFS", "dummy0:down lo:unknown").split()):
            name, state = entry.split(":")
            os.makedirs(os.path.join(sysnet, name))
            if state != "-": open(os.path.join(sysnet, name, "operstate"), "w").write(state + "\n")
        script = rest[2].replace("/proc/net/", net + "/").replace("/sys/class/net", sysnet)
        if script.count(root) < 5:
            sys.exit("STUB kubectl: the network read does not name the files this stub models")
        r = subprocess.run(["sh", "-c", script], capture_output=True, text=True)
        text = r.stdout.replace(root, "")
        if mode == "noend": text = text.replace("NET-READ-END\n", "")
        if mode == "extra": text = text.replace("NET-READ-END\n", "something else\nNET-READ-END\n")
        sys.stdout.write(text); sys.exit(r.returncode)
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
if a[:1] == ["debug"]:
    # test.sh's node probe: kubectl debug node/<node> ... -- chroot /host sh -c <PROBE>. The probe
    # script is kept, and its AppArmor lines are run for real when its log is read (below).
    if a[1] != f"node/{NODE}" or a[a.index("--") + 1:a.index("--") + 5] != ["chroot", "/host", "sh", "-c"]:
        sys.exit(f"STUB kubectl: the node probe is not 'debug node/{NODE} ... -- chroot /host sh -c <script>': {a}")
    with open(os.path.join(E("STUB_STATE"), "probe.sh"), "w") as f:
        f.write(a[a.index("--") + 5])
    sys.stderr.write(f"Creating debugging pod {DBG} with container debugger on node {NODE}.\n"); sys.exit(0)
if a[:1] == ["wait"]:
    out(f"pod/{DBG} condition met\n")
if a[:1] == ["logs"]:
    # The host-requirement readings are canned. The AppArmor ones come from running test.sh's own
    # probe lines (every line that names apparmor) in sh, against a fake node: its profile list,
    # the profile file, and a kernel journal read through a fake journalctl, which honours -k and
    # --since @<epoch>. The journal holds the lines the probe must count and lines it must not:
    # the same denials before T0, another profile's, another path's, AUDIT and ALLOWED lines.
    import shutil, subprocess
    st = E("STUB_STATE"); node = os.path.join(st, "node"); os.makedirs(os.path.join(node, "apparmor.d"), exist_ok=True)
    open(os.path.join(node, "enabled"), "w").write("Y\n")
    loaded = E("STUB_AA_LOADED", "loaded") == "loaded"
    open(os.path.join(node, "profiles"), "w").write(
        (f"{SAMPLE_PROFILE} ({E('STUB_AA_MODE', 'enforce')})\n" if loaded else "") + "cri-containerd.apparmor.d (enforce)\nrunc (unconfined)\n")
    pfile = os.path.join(node, "apparmor.d", SAMPLE_PROFILE)
    if "STUB_AA_SHA" not in os.environ: shutil.copy(E("STUB_PROFILE_FILE"), pfile)
    elif E("STUB_AA_SHA"): open(pfile, "w").write("not this sample's profile\n")
    t0 = 1700000000   # what `date -u +%s` answered in the ordinary pod (T0)
    def deny(t, prof, what, verdict="DENIED"):
        rest = ('operation="open" class="file" name="%s" comm="sh" requested_mask="wc" denied_mask="wc"' % what
                if what.startswith("/") else 'operation="signal" class="signal" comm="runc" requested_mask="receive" denied_mask="receive" signal=term peer="runc"')
        return '%d\tkernel: audit: type=1400 audit(%d.000:1): apparmor="%s" %s profile="%s" pid=4242' % (t, t, verdict, rest, prof)
    n = lambda k, d: int(E(k, d) or 0)
    j = [deny(t0 - 10000, SAMPLE_PROFILE, "/etc/shadow"), deny(t0 - 9999, SAMPLE_PROFILE, "signal")]   # before T0
    j += [deny(t0 + 5, SAMPLE_PROFILE, "/etc/shadow")] * n("STUB_SHADOW_DENIALS", "1")
    j += [deny(t0 + 5, "profile-that-does-not-exist", "/etc/shadow")] * n("STUB_BOGUS_DENIALS", "0")
    j += [deny(t0 + 6, SAMPLE_PROFILE, "signal")] * n("STUB_SIGNAL_DENIALS", "0")
    j += [deny(t0 + 6, "profile-that-does-not-exist", "signal")] * n("STUB_BOGUS_SIGNAL_DENIALS", "0")
    j += [deny(t0 + 7, "cri-containerd.apparmor.d", "/etc/shadow"), deny(t0 + 7, SAMPLE_PROFILE, "/etc/gshadow"),
          deny(t0 + 7, SAMPLE_PROFILE, "/etc/shadow", "AUDIT"), deny(t0 + 7, SAMPLE_PROFILE, "signal", "ALLOWED"),
          deny(t0 + 7, "cri-containerd.apparmor.d", "signal")]
    open(os.path.join(node, "journal"), "w").write("\n".join(j) + "\n")
    probe = open(os.path.join(st, "probe.sh")).read()
    aa = "\n".join(l for l in probe.split("\n") if "apparmor" in l)
    aa = aa.replace("/sys/module/apparmor/parameters/enabled", os.path.join(node, "enabled")) \
           .replace("/sys/kernel/security/apparmor/profiles", os.path.join(node, "profiles")).replace("/etc/apparmor.d/", os.path.join(node, "apparmor.d") + "/")
    r = subprocess.run(["sh", "-c", aa], capture_output=True, text=True,
                       env=dict(os.environ, PATH=E("STUB_NODEBIN") + ":" + E("PATH"), STUB_JOURNAL=os.path.join(node, "journal")))
    out("\n".join([
        "KERNEL=6.18.56-nitro-ga", "btf=present", "btf_bogus=absent", "ne=present", "ne_bogus=absent",
        "vsock=present", "vsock_bogus=absent", "tun=present", "tun_bogus=absent", "cma=14456832", "cma_bogus=",
        "erofs=present", "erofs_bogus=absent", "handler=present", "handler_bogus=absent", "containerd_gate=ok",
        "containerd_version=containerd github.com/containerd/containerd/v2 2.2.1"]) + "\n" + r.stdout)
if line == "get runtimeclass isolated-sandbox -o jsonpath={.metadata.name}":
    out("isolated-sandbox")
sys.exit(f"STUB kubectl: unexpected call: {line}")
PY
# sitecustomize.py for the connect probe the stub runs: fakes only socket.connect(), as
# FAKE_CONNECT says (an errno name such as ENETUNREACH, "timeout", or "connected").
mkdir -p "$STUB/fakesock"
cat > "$STUB/fakesock/sitecustomize.py" <<'PY'
import errno, os, socket
_mode = os.environ.get("FAKE_CONNECT")
if _mode:
    def _connect(self, address):
        if _mode == "connected":
            return None
        if _mode == "timeout":
            raise socket.timeout("timed out")
        code = getattr(errno, _mode)
        raise OSError(code, os.strerror(code))
    socket.socket.connect = _connect
PY
export STUB_FAKESOCK="$STUB/fakesock" PYTHONDONTWRITEBYTECODE=1
# The node's journalctl, for the AppArmor probe lines the stub runs: the kernel journal
# ($STUB_JOURNAL, "<epoch><TAB><line>") only with -k, from --since @<epoch> on; any other option,
# or a --since it cannot read, fails the way journalctl does.
mkdir -p "$STUB/nodebin"
cat > "$STUB/nodebin/journalctl" <<'PY'
#!/usr/bin/env python3
import os, re, sys
a, kernel, since = sys.argv[1:], False, None
while a:
    x = a.pop(0)
    if x in ("-k", "--dmesg"): kernel = True
    elif x == "--no-pager": pass
    elif x == "--since" and a:
        m = re.fullmatch(r"@([0-9]+)", a.pop(0))
        if not m: sys.exit("Failed to parse timestamp")
        since = int(m.group(1))
    else: sys.exit(f"journalctl: unrecognized option '{x}'")
for l in open(os.environ["STUB_JOURNAL"]).read().splitlines():
    t, text = l.split("\t", 1)
    if kernel and (since is None or int(t) >= since):
        print("Nov 14 22:13:25 node-a " + text)
PY
chmod +x "$STUB/nodebin/journalctl"
export STUB_NODEBIN="$STUB/nodebin" STUB_PROFILE_FILE="$SAMPLE/manifests/ubuntu-ami-sample-profile"
chmod +x "$STUB/aws" "$STUB/kubectl"
export PATH="$STUB:$PATH"

# t <case> [VAR=value]: the real test.sh with the stub world changed as the case says.
t() {
  local c="$1"; shift
  export STUB_LOG="$WORK/$c.calls" STUB_APPLIED="$WORK/$c.applied" STUB_STATE="$WORK/$c.state"
  : > "$STUB_LOG"; : > "$STUB_APPLIED"; rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"
  env "$@" bash "$SAMPLE/test.sh" > "$WORK/$c.log" 2>&1 < /dev/null
}
# The run's record, as setup.sh writes it: test.sh acts only on a run this checkout set up.
RUN_DIR="$ISSUE10_RUN_DIR/out/runs/testrun1"; mkdir -p "$RUN_DIR"
GOOD_RECORD=$'RUN_ID=testrun1\nRESOURCE_PREFIX=ubuntu-ami-sample\nNODEGROUP_NAME=ubuntu-ami-sample-testrun1-ng\nNAMESPACE=ubuntu-ami-sample\nCLUSTER_NAME=example-cluster\nAWS_REGION=us-west-2'
printf '%s\n' "$GOOD_RECORD" > "$RUN_DIR/run-state.env"
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
A_ANNOT='the sandbox pod carries sandbox.amazonaws.com/network-isolated="true" (read back from the API)'
A_ADDR="only loopback has an address in the sandbox"
A_ROUTE="the sandbox has no route"
A_IFDOWN="every sandbox interface other than lo is down"
A_NOCONN="the sandbox's TCP connect to the API Service fails with Network is unreachable (ENETUNREACH)"
A_CONNCTL="the same connect from the ordinary pod succeeds (control for the previous check)"

echo "== 1/3 ACCEPT: the scoped profile on an ordinary pod, the sandbox Unconfined and with no network ="
rc=0; t good || rc=$?
check "ACCEPT the good node: the real test.sh passes every check" 0 "$rc" "$WORK/good.log" '^passed [0-9]+, failed 0$'
for a in "$A_LOADED" "$A_SHA" "$A_RUNS" "$A_ATTR" "$A_ORD" "$A_EACCES" "$A_CONTROL" "$A_DENIED" "$A_BOGUS" "$A_GONE" \
         "$A_SIGNAL" "$A_BOGUS_SIGNAL" "$A_REJ" "$A_SBX" "$A_ANNOT" "$A_ADDR" "$A_ROUTE" "$A_IFDOWN" "$A_NOCONN" "$A_CONNCTL"; do
  [ "$(line good "$a")" = PASS ]; check "  ... PASS: $a" 0 $? "$WORK/good.log"
done
grep -qx '  kubernetes Service ClusterIP (read from the API): 172.20.0.1' "$WORK/good.log" \
  && grep -qx '  sandbox TCP connect to that ClusterIP on 443: errno=ENETUNREACH (Network is unreachable)' "$WORK/good.log" \
  && grep -qx '  ordinary pod TCP connect to that ClusterIP on 443: connected' "$WORK/good.log"
check "  ... test.sh's own connect probe, run for real (only connect() faked), printed the errno for the sandbox and connected for the ordinary pod, at the ClusterIP read from the API" 0 $? "$WORK/good.log"
grep -qx '  sandbox interfaces (/sys/class/net, operstate): dummy0 down, lo unknown' "$WORK/good.log" \
  && grep -qx '  sandbox IPv4 local addresses (/proc/net/fib_trie): 127.0.0.1' "$WORK/good.log" \
  && grep -qx '  sandbox IPv6 addresses (/proc/net/if_inet6): ::1 on lo' "$WORK/good.log" \
  && grep -qx '  sandbox IPv4 routes (/proc/net/route): none (header line only)' "$WORK/good.log"
check "  ... test.sh's own network read, run for real on a guest tree like the probe's (dummy0 down, lo), printed every interface, the addresses and no route" 0 $? "$WORK/good.log"
sed -n '/^== 7\/7/,/^passed /p' "$WORK/good.log" > "$WORK/good.77"
[ "$(grep -c '172\.20\.0\.1' "$WORK/good.77")" = 1 ] && ! grep -qiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$WORK/good.77"
check "  ... and 7/7 prints the Service ClusterIP on one line only (the page shows it as a placeholder) and no MAC address" 0 $? "$WORK/good.77"
grep -qx 'get service kubernetes -n default -o jsonpath={.spec.clusterIP}' "$WORK/good.calls" \
  && ! grep -qE '^get networkpolicy|getent|/dev/tcp' "$WORK/good.calls"
check "  ... it read the ClusterIP from the API and made no network policy, DNS or /dev/tcp call" 0 $? "$WORK/good.calls"
# More guests that have no network and must be accepted: no IPv6 at all (no if_inet6), an empty
# if_inet6 (what a container started with --network none shows), and only lo (no dummy0).
for c in v6absent:STUB_SBX_V6=absent v6empty:STUB_SBX_V6= loonly:STUB_SBX_IFS=lo:unknown; do
  rc=0; t "${c%%:*}" "${c#*:}" || rc=$?
  check "ACCEPT ${c%%:*} (${c#*:}): every check passes" 0 "$rc" "$WORK/${c%%:*}.log" '^passed [0-9]+, failed 0$'
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
annotfalse|STUB_SBX_ANNOT=false|$A_ANNOT
annotabsent|STUB_SBX_ANNOT=|$A_ANNOT
addr4extra|STUB_SBX_ADDR4=127.0.0.1 192.0.2.10|$A_ADDR
addr4none|STUB_SBX_ADDR4=|$A_ADDR
addr6extra|STUB_SBX_V6=00000000000000000000000000000001 01 80 10 80       lo+fe80000000000000021122fffe334455 02 40 20 80   dummy0|$A_ADDR
addr6garbled|STUB_SBX_V6=not an if_inet6 line|$A_ADDR
fibmissing|STUB_SBX_NOFILE=fib_trie|$A_ADDR
fibunreadable|STUB_SBX_UNREADABLE=fib_trie|$A_ADDR
v6unreadable|STUB_SBX_UNREADABLE=if_inet6|$A_ADDR
route|STUB_SBX_ROUTE=eth0 00000000 0100000A 0003 0 0 0 00000000 0 0 0|$A_ROUTE
routemissing|STUB_SBX_NOFILE=route|$A_ROUTE
routeunreadable|STUB_SBX_UNREADABLE=route|$A_ROUTE
dummy0up|STUB_SBX_IFS=dummy0:up lo:unknown|$A_IFDOWN
eth0up|STUB_SBX_IFS=eth0:up dummy0:down lo:unknown|$A_IFDOWN
dummy0unknown|STUB_SBX_IFS=dummy0:unknown lo:unknown|$A_IFDOWN
nooperstate|STUB_SBX_IFS=dummy0:- lo:unknown|$A_IFDOWN
nolo|STUB_SBX_IFS=dummy0:down|$A_IFDOWN
sysnetmissing|STUB_SBX_NOFILE=sysnet|$A_IFDOWN
sbxconnected|STUB_SBX_CONNECT=connected|$A_NOCONN
sbxtimeout|STUB_SBX_CONNECT=timeout|$A_NOCONN
sbxrefused|STUB_SBX_CONNECT=ECONNREFUSED|$A_NOCONN
sbxhostunreach|STUB_SBX_CONNECT=EHOSTUNREACH|$A_NOCONN
sbxexecerr|STUB_SBX_CONNECT=exec-error|$A_NOCONN
sbxempty|STUB_SBX_CONNECT=empty|$A_NOCONN
ordrefused|STUB_ORD_CONNECT=ECONNREFUSED|$A_CONNCTL
ordtimeout|STUB_ORD_CONNECT=timeout|$A_CONNCTL
ordexecerr|STUB_ORD_CONNECT=exec-error|$A_CONNCTL
CASES
# No ClusterIP from the API: neither connect can be aimed, so both fail, and nothing else does.
rc=0; t noip STUB_API_IP= || rc=$?
[ "$rc" = 1 ] && [ "$(line noip "$A_NOCONN")" = FAIL ] && [ "$(line noip "$A_CONNCTL")" = FAIL ] && [ "$(grep -c '^  FAIL  ' "$WORK/noip.log")" = 2 ] \
  && grep -qx '  sandbox TCP connect to that ClusterIP on 443: <no ClusterIP>' "$WORK/noip.log"
check "REJECT noip: with no ClusterIP read from the API, both connect checks fail, and they are the only failing checks" 0 $? "$WORK/noip.log"
# A network read that did not run to its end proves nothing: the exec fails, the end marker is
# missing, or a line the read never prints appears. Then the address, route and interface checks
# all fail, and nothing else does.
for c in netexecerr:error netnoend:noend netextra:extra; do
  rc=0; t "${c%%:*}" "STUB_SBX_NET_EXEC=${c#*:}" || rc=$?
  [ "$rc" = 1 ] && [ "$(line "${c%%:*}" "$A_ADDR")" = FAIL ] && [ "$(line "${c%%:*}" "$A_ROUTE")" = FAIL ] \
    && [ "$(line "${c%%:*}" "$A_IFDOWN")" = FAIL ] && [ "$(grep -c '^  FAIL  ' "$WORK/${c%%:*}.log")" = 3 ] \
    && grep -q "the sandbox's network read did not complete" "$WORK/${c%%:*}.log"
  check "REJECT ${c%%:*} (STUB_SBX_NET_EXEC=${c#*:}): the address, route and interface checks fail, and they are the only failing checks" 0 $? "$WORK/${c%%:*}.log"
done

echo "== 2b/3 the run's record and lock: test.sh reads only its own run, and not while another process acts on it =="
# Each refusal comes before any kubectl or aws call (the stubs log every call they get).
refused() { # refused <case> <description> <log regex> [VAR=value...]
  local c="$1" why="$2" rx="$3"; shift 3
  rc=0; t "$c" "$@" || rc=$?
  check "$why" 1 "$rc" "$WORK/$c.log" "$rx"
  [ ! -s "$WORK/$c.calls" ]; check "  ... before any kubectl or aws call" 0 $? "$WORK/$c.calls"
}
refused othercluster "REJECT test.sh with CLUSTER_NAME other than the run's record (the late R3 finding)" \
  'has CLUSTER_NAME=example-cluster, but this run has CLUSTER_NAME=other-cluster' CLUSTER_NAME=other-cluster
refused otherregion "REJECT test.sh with AWS_REGION other than the run's record" \
  'has AWS_REGION=us-west-2, but this run has AWS_REGION=us-east-1' AWS_REGION=us-east-1
printf '%s\n' "$GOOD_RECORD" | grep -v '^CLUSTER_NAME=' > "$RUN_DIR/run-state.env"
refused oldrecord "REJECT a record with no CLUSTER_NAME line (one written before the cluster was recorded)" \
  'has no CLUSTER_NAME line, but this run has CLUSTER_NAME=example-cluster'
rm -f "$RUN_DIR/run-state.env"
refused norecord "REJECT a run this checkout has no record of" 'run testrun1 has no record at .*/runs/testrun1/run-state.env'
printf '%s\n' "$GOOD_RECORD" > "$RUN_DIR/run-state.env"
# A second holder: a background process takes the run's lock with the real lock_run, as setup.sh
# or clean.sh would, and sleeps; the test kills it by its own pid.
rm -f "$WORK/holder.ready"
RUN_ID=testrun1 bash -c '. "$1/lib/common.sh" && derive_run_names && lock_run && echo held > "$2" && exec sleep 300' \
  _ "$HERE" "$WORK/holder.ready" > "$WORK/holder.log" 2>&1 < /dev/null &
HOLDER=$!
for _ in $(seq 1 100); do [ -s "$WORK/holder.ready" ] && break; sleep 0.1; done
[ -s "$WORK/holder.ready" ] && kill -0 "$HOLDER" 2>/dev/null
check "a background process (pid $HOLDER) holds run testrun1's lock, taken with the real lock_run" 0 $? "$WORK/holder.log"
refused locked "REJECT test.sh while another process holds the run's lock (R3-FR high)" \
  'run testrun1 is in use: another process holds its lock .*/runs/testrun1/run.lock'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
rc=0; t unlocked || rc=$?
check "ACCEPT the same test.sh once the holder is gone: the lock is free and every check passes" 0 "$rc" "$WORK/unlocked.log" '^passed [0-9]+, failed 0$'

echo "== 3/3 static: the profile's own rules, scripts/check-apparmor-profile.py ======================"
P="$SAMPLE/manifests/ubuntu-ami-sample-profile"
rc=0; python3 "$HERE/check-apparmor-profile.py" "$P" > "$WORK/prof-good.log" 2>&1 || rc=$?
check "ACCEPT the sample's profile: one closed profile block with signal rules for unconfined, runc, crun and itself; every deny is audit deny" 0 "$rc" "$WORK/prof-good.log" '^APPARMOR PROFILE OK'
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
# The reviewers' structural cases (R3-FR and its late result), each accepted before F1: every
# rule moved out of the profile into the top level after an empty profile; the profile's closing
# brace removed; the rules in a decoy second profile; and the crun signal rule removed.
HDR='profile ubuntu-ami-sample-profile flags=(attach_disconnected,mediate_deleted) {\n'
pm outside     "every rule outside the profile, after an empty closed profile" \
  "t.replace('$HDR', '$HDR  file,\n}\n', 1).rstrip().rstrip('}') + '\n'" '^FAIL: missing `signal \(receive\) peer=runc,` in profile ubuntu-ami-sample-profile'
pm unclosed    "the profile's closing brace removed" 't.rstrip().rstrip("}") + "\n"' '^FAIL: the `profile ubuntu-ami-sample-profile` block is never closed \(unbalanced braces\)$'
pm decoy       "the rules in a decoy second profile, the named one holding only file," \
  "t.replace('$HDR', '$HDR  file,\n}\nprofile decoy {\n', 1)" '^FAIL: missing `audit deny /etc/shadow\* w,` in profile ubuntu-ami-sample-profile$'
pm nocrun      "no peer=crun" 't.replace("  signal (receive) peer=crun,\n", "")' '^FAIL: missing `signal \(receive\) peer=crun,` in profile ubuntu-ami-sample-profile'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "test.sh's AppArmor checks and its no-network checks proven both ways in the real script, and the profile's rules in the real checker."
