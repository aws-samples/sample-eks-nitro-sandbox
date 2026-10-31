#!/usr/bin/env python3
"""walkthrough.py -- one procurement case through OpenShell inside a Nitro sandbox, with
every claim this sample's page makes read from the live cluster.

Run it after scripts/setup.sh, which writes the run record this reads.

A refusal is only evidence when three things hold: the operation really is refused, the
same operation really is possible for a process outside the confinement, and the layer
that refused it has its own record of refusing. Every check below is one of those, read
from the running pods and the running sandbox rather than from a manifest, and the run
stops at the first claim that does not hold.

Each run is fresh: a new run id, a new sandbox, and the template recreated. It never
resumes an earlier run's sandbox, because a resumed run can skip the very step whose
output the page shows.

What it leaves behind, under <repo>/tmp/subagent-security-openshell/runs/<run id>/:

    checks.json                   every check and whether it passed
    calls.json                    every probe this run made and what came back
    placement.json                the two pods, their nodes, the guest kernel and the
                                  node's own kernel
    initial.json                  the two policies and the provider profile, as this run
    draft-enabled.json            applied them, with the reader's namespace substituted
    supplier-profile.json
    recommendation.md             the analyst's own output, copied out of the workspace
    evidence.json
    supplier-api-requests.jsonl   the supplier API's own log, read from its pod
    bridge.log                    the model bridge's own log
    supervisor.log                OpenShell's supervisor log for this sandbox
    control.json                  the trusted control's statuses, from outside the sandbox

Nothing here deletes anything the sample did not create, nothing here changes a
cluster-wide setting or a shared install, and no credential is ever put on a command line:
the supplier key reaches the CLI in a subprocess environment and the trusted control reads
it from its own pod's file. scripts/clean.sh removes what setup.sh created.
"""
import base64
import errno
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

SAMPLE = "subagent-security-openshell"

SCRIPT = Path(__file__).resolve()
SAMPLE_DIR = SCRIPT.parents[1]
SECTION_DIR = SCRIPT.parents[2]
REPO_ROOT = SCRIPT.parents[4]
TMP_DIR = REPO_ROOT / "tmp" / SAMPLE
STATE_FILE = TMP_DIR / "state.env"

# The run record keys this script cannot work without. KUBE_CONTEXT is deliberately not
# here: an empty value is legitimate and means "whatever context kubectl is set to", and
# the page tells the reader to set it.
REQUIRED_STATE = ("SAMPLE", "NAMESPACE", "RELEASE", "TEMPLATE", "CLI", "ANALYST_IMAGE",
                  "BUCKET", "AWS_REGION", "BEDROCK_MODEL_ID", "UPSTREAM_REF",
                  "UPSTREAM_REVISION")

# The one marker every probe prints, from the shared worker.
MARKER = "ANALYST_RESULT="
# The trusted control's own marker, so a stray line on its stdout cannot be read as its
# result.
CONTROL_MARKER = "CONTROL_RESULT="

PROBE_PROGRAM = "/opt/openshell/analyst_probes.py"
CASE = "rfp-001"
CANARY_CONTENT = "synthetic-private-canary"

# Seconds. The sandbox create is the long one: the workload pod needs a sandbox node, and
# Karpenter provisions one when none is free.
PORT_FORWARD_TIMEOUT = 20
CLI_TIMEOUT = 120
PROBE_TIMEOUT = 180
ANALYZE_TIMEOUT = 300
SANDBOX_CREATE_TIMEOUT = 900

# The identity the policy's process.run_as_user names and the image's own user.
EXPECTED_UID = 1000
EXPECTED_GID = 1000

# What the trusted control outside the sandbox must get back from the supplier API: every
# operation OpenShell refused the analyst, plus one wrong key the API itself refuses.
CONTROL_EXPECTED_STATUSES = [200, 200, 200, 200, 200, 401]

# A Nitro sandbox guest sees virtio disks and device-mapper nodes. An ordinary pod on the
# same instance sees the instance's NVMe devices, so an nvme entry means this did not run
# in a guest.
GUEST_DEVICE = re.compile(r"^vd[a-z]+[0-9]*$|^dm-[0-9]+$")
GUEST_DISK = re.compile(r"^vd[a-z]+$")

# The interpreter src/policies.py names in the policy's `binaries` rule. The supervisor
# writes it into its own denial records, which is what lets the log check below tie a
# refusal to the executable the policy matched.
PYTHON_BINARY = "/usr/local/bin/python3.13"

# OpenShell's own reason for refusing a connection at the transport layer, as its
# supervisor writes it. A DNS-level refusal of the same name carries a different reason,
# so matching this one keeps the two apart.
ALIAS_DENIAL_REASON = "transparent_tcp_policy_denied"


class Problem(RuntimeError):
    """A claim this run makes that did not hold, or that could not be determined.

    The two are one type on purpose. A lookup that fails means "could not determine", which
    is a failure of this run and never a pass.
    """


def tail(text, lines=20):
    """The last few lines of a command's output, for an error message."""
    kept = [line for line in (text or "").splitlines() if line.strip()][-lines:]
    return "\n".join("  " + line for line in kept) or "  (no output)"


def load_state(path):
    """Parse the KEY=value run record setup.sh writes.

    Parsed here rather than sourced, because this script is Python and sourcing would mean
    running the file as shell. setup.sh appends, so a key can appear more than once; the
    last one wins, which is what sourcing the file would do too.
    """
    if not path.exists():
        raise Problem(
            f"there is no run record at {path}. Run ./scripts/setup.sh first: it creates "
            "everything this walkthrough needs and writes the record this reads.")
    state = {}
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise Problem(
                f"{path} line {number} is not a KEY=value line: {raw!r}. The record is "
                "written by ./scripts/setup.sh; re-run it rather than editing the file.")
        key, value = line.split("=", 1)
        state[key.strip()] = value.strip()
    missing = [key for key in REQUIRED_STATE if not state.get(key)]
    if missing:
        raise Problem(
            f"the run record at {path} is missing {', '.join(missing)}, so setup.sh did "
            "not finish. Re-run ./scripts/setup.sh.")
    if state["SAMPLE"] != SAMPLE:
        raise Problem(
            f"the run record at {path} is for the sample {state['SAMPLE']!r}, not "
            f"{SAMPLE!r}; this walkthrough would act on another sample's resources.")
    return state


def shared_keyed_digest():
    """The digest function the analyst itself uses, imported rather than reimplemented.

    The whole point of the comparison is that the operator and the restricted process
    compute the same thing. A second copy of the algorithm here could drift from the one in
    the sandbox, and the run would then be comparing two different digests and finding them
    different, which is exactly the result the check treats as a pass.
    """
    shared = SECTION_DIR / "analyst" / "src"
    if str(shared) not in sys.path:
        sys.path.insert(0, str(shared))
    try:
        import worker
    except ImportError as error:
        raise Problem(
            f"could not import the shared analyst worker from {shared} ({error}), so the "
            "credential digest cannot be computed the same way the sandbox computes it.")
    return worker.keyed_digest


def free_port():
    """A port the kernel reports free right now.

    There is a window between closing this socket and kubectl binding the port, and nothing
    here can close it: kubectl does the bind. If something else takes the port in between,
    the wait below times out and the run fails, which is the honest outcome.
    """
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def credential_volume_mounts(pod, container_name):
    """The secret and projected volumes one container of a pod mounts, by volume name.

    Container-scoped, and that is the whole point. The workload pod does carry one Secret
    volume, openshell-sandbox-bootstrap, which an init container mounts to stage OpenShell's
    runtime and its boundary material. A pod-scoped check would find that Secret volume and
    report the credential boundary as broken when it is not, and a pod-scoped check written
    the other way round would be asserting something this sample cannot claim. What the page
    claims is narrower and is what is checked: the container the analyst runs in mounts
    none of them.

    A mount naming a volume the pod does not define is "could not determine", not "not a
    secret", so it raises.
    """
    volumes = {volume["name"]: volume for volume in pod["spec"].get("volumes", [])}
    container = _container(pod, container_name)
    found = []
    for mount in container.get("volumeMounts", []):
        volume = volumes.get(mount["name"])
        if volume is None:
            raise Problem(
                f"the {container_name} container mounts a volume {mount['name']!r} that the "
                f"pod {pod['metadata']['name']} does not define, so it cannot be told "
                "whether that volume carries credential material")
        if "secret" in volume or "projected" in volume:
            found.append(mount["name"])
    return sorted(found)


def token_audiences(pod, container_name):
    """The service-account token audiences one container reaches through a projected volume.

    Read from the pod spec rather than from inside the container, because the audience is
    what makes the token usable against the gateway and nothing else, and the audience is
    only in the spec.
    """
    volumes = {volume["name"]: volume for volume in pod["spec"].get("volumes", [])}
    container = _container(pod, container_name)
    audiences = set()
    for mount in container.get("volumeMounts", []):
        volume = volumes.get(mount["name"]) or {}
        for source in (volume.get("projected") or {}).get("sources", []):
            token = source.get("serviceAccountToken")
            if token and token.get("audience"):
                audiences.add(token["audience"])
    return audiences


def _container(pod, name):
    containers = {c["name"]: c for c in pod["spec"].get("containers", [])}
    if name not in containers:
        raise Problem(
            f"the pod {pod['metadata']['name']} has no container called {name!r} "
            f"(it has {', '.join(sorted(containers)) or 'none'}), so the claim about that "
            "container cannot be evaluated")
    return containers[name]


def restart_counts(pod):
    """Every container's restart count in one pod, by container name."""
    return {status["name"]: status.get("restartCount")
            for status in pod.get("status", {}).get("containerStatuses", [])}


def listing(payload, key, what):
    """One list out of a CLI `-o json` reply, which is sometimes bare and sometimes wrapped.

    `provider list-profiles` answers with a bare JSON list and `provider list` with an
    object holding one, so neither shape can be assumed. A reply that is neither is "could
    not determine" and raises: going on would mean treating an unreadable listing as an
    empty one, and this script creates things when a listing comes back empty.
    """
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        if isinstance(payload.get(key), list):
            return payload[key]
        lists = [value for value in payload.values() if isinstance(value, list)]
        if len(lists) == 1:
            return lists[0]
    raise Problem(
        f"could not read the {what} listing: expected a JSON list or an object holding "
        f"one under {key!r}, got {json.dumps(payload)[:400]}")


def names_in(entries, keys=("name", "id")):
    """Every name an entry in a CLI listing goes by, across the fields it might use."""
    found = set()
    for entry in entries:
        if isinstance(entry, str):
            found.add(entry)
        elif isinstance(entry, dict):
            for key in keys:
                if isinstance(entry.get(key), str):
                    found.add(entry[key])
    return found


def denied_body(result, what):
    """The JSON body of an OpenShell refusal.

    The shared worker hands back an error body as the string it read, because an error body
    is not guaranteed to be JSON at all, so it is decoded here. A 201 comes back already
    parsed, hence the dict case. A body that is not JSON fails the run with the body quoted:
    a refusal whose own record cannot be read is not evidence of anything.
    """
    body = result.get("body")
    if isinstance(body, dict):
        return body
    if not isinstance(body, str):
        raise Problem(f"{what} came back with a body that is neither JSON text nor an "
                      f"object: {json.dumps(result)[:400]}")
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise Problem(f"{what} came back {result.get('status')} with a body that is not "
                      f"JSON ({error}): {body[:400]!r}")


# The trusted control, run in the model bridge pod. That pod runs the same image as the
# analyst and the same uid 1000, and no OpenShell confinement, so it is what makes every
# refusal in the sandbox attributable to OpenShell rather than to the image, the file modes,
# the supplier API or the network.
#
# The key is read from the pod's own Secret mount inside the program. It is not in this
# text, not in the argument list and not in the environment: `kubectl exec` puts its
# arguments in the pod's process table and in the API server's audit record.
#
# A case table is substituted in as a JSON string and decoded at run time, rather than
# written into the program as a literal, so no value from the run record can change the
# shape of the program.
#
# Nothing that is not an HTTP status is caught here. A TLS failure, a DNS failure or a
# timeout raises, the exec exits non-zero and the run fails, because none of those is
# evidence about what the supplier API accepts.
FILE_CONTROL_PROGRAM = '''
import json
import os

CANARY = __CANARY__
CASE_FILE = "/opt/analyst/fixtures/case.json"

# This runs in the analyst's own container, started by kubectl exec rather than by
# OpenShell's runtime. That is the whole of the difference: the same pod, the same image,
# the same uid and the same filesystem, but not a process under OpenShell's policy. So if
# this can do what the analyst was refused, the refusal was the policy and nothing else.
uid = os.getuid()
if uid != 1000:
    raise SystemExit("the control runs as uid " + str(uid) + ", not 1000")

canary = open("/protected/canary").read().strip()
if canary != CANARY:
    raise SystemExit("the canary read back as " + repr(canary))

# O_WRONLY, deliberately no O_CREAT, and not one byte is written or truncated. The point
# is only that the open succeeds for the same uid the analyst runs as.
os.close(os.open(CASE_FILE, os.O_WRONLY))

print("CONTROL_RESULT=" + json.dumps({
    "uid": uid,
    "canary_read": True,
    "case_file_opened_for_writing": True,
    "case_file_mode": oct(os.stat(CASE_FILE).st_mode & 0o777),
}))
'''

# The network control cannot run where the file control does. OpenShell's Kubernetes
# driver gives the workload pod a NetworkPolicy with no egress rules, so a process in that
# pod which is not going through OpenShell's supervisor has no route out at all and would
# time out rather than reach the supplier API. This one therefore runs in the bridge pod,
# which is an ordinary pod with egress, and it answers the question that matters: does the
# host and operation the analyst was refused actually work, with the same real key.
#
# Nothing that is not an HTTP status is caught. A TLS failure, a DNS failure or a timeout
# raises, the exec exits non-zero and the run fails, because none of those is evidence
# about what the supplier API accepts.
NETWORK_CONTROL_PROGRAM = '''
import json
import ssl
import urllib.error
import urllib.request

CASES = json.loads(__CASES_JSON__)
WRONG_KEY = "not-the-supplier-key"

# The sample certificate authority that signed the supplier API's certificate, mounted
# into the bridge pod by deploy/bridge.yaml. It is named explicitly rather than left to
# the system bundle, because the authority is generated per run and so cannot be in the
# image. TLS verification stays on: turning it off would remove the very control that
# makes the analyst's connection refusal readable as a policy decision.
CA_BUNDLE = "/opt/supplier-ca/ca.crt"

key = open("/opt/supplier-key/api-key").read().strip()
if not key:
    raise SystemExit("the supplier key file in this pod is empty")

context = ssl.create_default_context(cafile=CA_BUNDLE)
statuses = []
for case in CASES:
    data = None
    if case["method"] != "GET":
        data = json.dumps({"draft": True}).encode()
    headers = {"X-Api-Key": WRONG_KEY if case.get("wrong_key") else key,
               "X-Analyst-Request-ID": case["request_id"]}
    if data:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(case["url"], data=data, headers=headers,
                                     method=case["method"])
    try:
        with urllib.request.urlopen(request, timeout=15, context=context) as response:
            statuses.append(response.status)
    except urllib.error.HTTPError as error:
        error.read()
        statuses.append(error.code)
print("CONTROL_RESULT=" + json.dumps(statuses))
'''


class Walkthrough:
    """One run: a fresh sandbox, every check, and the evidence files it writes as it goes."""

    def __init__(self, state):
        self.state = state
        self.namespace = state["NAMESPACE"]
        self.context = state.get("KUBE_CONTEXT", "")
        self.release = state["RELEASE"]
        self.template = state["TEMPLATE"]
        self.cli_path = state["CLI"]
        self.region = state["AWS_REGION"]

        self.run_id = uuid.uuid4().hex
        self.sandbox = "analyst-" + self.run_id[:10]
        self.run_dir = TMP_DIR / "runs" / self.run_id
        self.run_dir.mkdir(parents=True, exist_ok=True)

        self.supplier_url = f"https://supplier-api.{self.namespace}.svc.cluster.local:8443"
        self.alias_host = f"supplier-api-alias.{self.namespace}.svc.cluster.local"
        self.alias_url = f"https://{self.alias_host}:8443"
        self.bridge_url = f"https://analyst-bridge.{self.namespace}.svc.cluster.local:8443"

        self.checks = []
        self.calls = []
        # Every request id this run expects to be refused. The correlation at the end
        # requires that none of them reached the supplier API or the bridge, so a refusal
        # the client reported is also a request that never arrived.
        self.denied_request_ids = []

        self.config_dir = None
        self.cli_env = None
        self.port_forward = None
        self.port_forward_log = TMP_DIR / "port-forward.log"
        self.workload = None
        self.supervisor = None
        self.sandbox_uid = None
        self.identity = {}
        self.s3_key = ""
        self.real_key = ""

    # -----------------------------------------------------------------------
    # Running things
    # -----------------------------------------------------------------------

    def _run(self, argv, timeout, env=None, stdin=None):
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                                  env=env, input=stdin)
        except subprocess.TimeoutExpired:
            raise Problem(
                f"'{argv[0]} {' '.join(argv[1:4])}...' did not finish within {timeout}s, so "
                "it is unknown whether it did anything")
        except FileNotFoundError:
            raise Problem(f"{argv[0]} is not on PATH")

    def kubectl(self, *args, timeout=CLI_TIMEOUT, check=True, stdin=None):
        """Every kubectl call this script makes, pinned to one context and one namespace.

        The context is named on the command rather than selected, so a `kubectl config
        use-context` in another session on this shared machine cannot redirect the run.
        """
        argv = ["kubectl"]
        if self.context:
            argv += ["--context", self.context]
        argv += ["-n", self.namespace, *args]
        completed = self._run(argv, timeout, stdin=stdin)
        if check and completed.returncode != 0:
            raise Problem(f"'kubectl {' '.join(args)}' failed (exit "
                          f"{completed.returncode}):\n{tail(completed.stderr)}")
        return completed

    def kubectl_json(self, *args, timeout=CLI_TIMEOUT):
        completed = self.kubectl(*args, "-o", "json", timeout=timeout)
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise Problem(f"'kubectl {' '.join(args)}' did not return JSON ({error})")

    def aws(self, *args, timeout=CLI_TIMEOUT):
        """An AWS call with the operator's own credentials, in the run record's Region.

        The Region is pinned here rather than left to the environment: a call that ran in
        another Region would come back with that Region's answer, and a bucket this sample
        created would look absent.
        """
        env = dict(os.environ, AWS_REGION=self.region, AWS_DEFAULT_REGION=self.region)
        completed = self._run(["aws", *args], timeout, env=env)
        if completed.returncode != 0:
            raise Problem(f"'aws {' '.join(args)}' failed (exit {completed.returncode}):\n"
                          f"{tail(completed.stderr)}")
        return completed

    def cli(self, *args, timeout=CLI_TIMEOUT, check=True, gateway=True, extra_env=None):
        """One OpenShell CLI call against this run's own gateway connection.

        extra_env is how a credential reaches the CLI: in the subprocess environment, never
        on the command line, which other processes on the host can read.
        """
        argv = [self.cli_path]
        if gateway:
            argv += ["-g", "analyst"]
        argv += list(args)
        env = dict(self.cli_env, **(extra_env or {}))
        completed = self._run(argv, timeout, env=env)
        if check and completed.returncode != 0:
            raise Problem(f"'openshell {' '.join(args)}' failed (exit "
                          f"{completed.returncode}):\n{tail(completed.stdout)}\n"
                          f"{tail(completed.stderr)}")
        return completed

    def cli_json(self, *args, timeout=CLI_TIMEOUT):
        completed = self.cli(*args, "-o", "json", timeout=timeout)
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise Problem(f"'openshell {' '.join(args)}' did not return JSON ({error}):\n"
                          f"{tail(completed.stdout)}")

    # -----------------------------------------------------------------------
    # Checks and probes
    # -----------------------------------------------------------------------

    def check(self, condition, name):
        """Record one claim, print it, and stop the run if it did not hold.

        It raises rather than counting failures, so the last line printed is always the
        claim that broke, and nothing after a broken claim is published as though the run
        had got that far.
        """
        passed = bool(condition)
        try:
            self.checks.append({"name": name, "passed": passed})
            print(("PASS " if passed else "FAIL ") + name, flush=True)
        finally:
            self.save_checks()
        if not passed:
            raise Problem(f"the claim that did not hold: {name}")
        return True

    def save_checks(self):
        (self.run_dir / "checks.json").write_text(json.dumps(self.checks, indent=2) + "\n")

    def save_calls(self):
        (self.run_dir / "calls.json").write_text(json.dumps(self.calls, indent=2) + "\n")

    def probe(self, action, *args, timeout=PROBE_TIMEOUT):
        """Run one probe in the sandbox and return the single result it printed.

        The shared worker's contract is that a refusal is a result line and everything else
        is a non-zero exit with no result line. So a non-zero exit, no line, or more than
        one line all fail the run: a startup failure, a timeout or a crash must never be
        able to read as a refusal.
        """
        completed = self.cli("sandbox", "exec", "--name", self.sandbox, "--no-tty", "--",
                             "python3", PROBE_PROGRAM, action, *args,
                             timeout=timeout, check=False)
        if completed.returncode != 0:
            raise Problem(
                f"the probe '{action} {' '.join(args)}' exited {completed.returncode}, so it "
                "did not run to the point of reporting anything. A failure to start is not "
                f"a refusal.\n{tail(completed.stdout)}\n{tail(completed.stderr)}")
        lines = [line for line in completed.stdout.splitlines() if line.startswith(MARKER)]
        if len(lines) != 1:
            raise Problem(
                f"the probe '{action} {' '.join(args)}' printed {len(lines)} "
                f"{MARKER} lines, not exactly one, so there is no single result to "
                f"read:\n{tail(completed.stdout)}")
        try:
            result = json.loads(lines[0][len(MARKER):])
        except json.JSONDecodeError as error:
            raise Problem(f"the probe '{action}' printed a result line that is not JSON "
                          f"({error}): {lines[0][:400]!r}")
        self.calls.append({"index": len(self.calls), "action": action, "args": list(args),
                           "result": result})
        self.save_calls()
        return result

    def run_control(self, kubectl_args, action, what):
        """Run one trusted control and return the single result it printed.

        Same contract as probe(): a non-zero exit, no result line, or more than one all
        fail the run. A control that did not run cannot stand as evidence that the thing
        it was meant to show is possible, which is exactly the direction that would make
        a refusal look attributable when it is not.
        """
        completed = self.kubectl(*kubectl_args, timeout=PROBE_TIMEOUT, check=False)
        if completed.returncode != 0:
            raise Problem(
                f"{what}: the control exited {completed.returncode}, so it never reported "
                f"anything.\n{tail(completed.stdout)}\n{tail(completed.stderr)}")
        lines = [line for line in completed.stdout.splitlines()
                 if line.startswith(CONTROL_MARKER)]
        if len(lines) != 1:
            raise Problem(
                f"{what}: the control printed {len(lines)} {CONTROL_MARKER} lines, not "
                f"exactly one:\n{tail(completed.stdout)}")
        result = json.loads(lines[0][len(CONTROL_MARKER):])
        self.calls.append({"index": len(self.calls), "action": action,
                           "args": [], "result": result})
        self.save_calls()
        return result

    # -----------------------------------------------------------------------
    # The gateway connection
    # -----------------------------------------------------------------------

    def open_gateway(self):
        """Assemble the operator's mTLS bundle, forward the gateway port, and register it.

        The gateway is a ClusterIP Service reached only through a port-forward bound to
        127.0.0.1, so nothing in this sample puts an endpoint on the reader's account. The
        client certificate is this gateway's whole access control, which is why it is
        written into a private directory of its own and never into the sample folder.
        """
        self.config_dir = Path(tempfile.mkdtemp(prefix="cli-run.", dir=str(TMP_DIR)))
        os.chmod(self.config_dir, 0o700)
        mtls = self.config_dir / "openshell" / "gateways" / "analyst" / "mtls"
        mtls.mkdir(parents=True)
        secret = f"{self.release}-client-tls"
        data = self.secret_data(secret, ("ca.crt", "tls.crt", "tls.key"))
        for name, value in data.items():
            path = mtls / name
            path.write_bytes(value)
            os.chmod(path, 0o600)
        print(f"  gateway client certificate: {mtls}")

        port = free_port()
        log = TMP_DIR / "port-forward.log"
        argv = ["kubectl"]
        if self.context:
            argv += ["--context", self.context]
        argv += ["-n", self.namespace, "port-forward", "--address=127.0.0.1",
                 f"service/{self.release}", f"{port}:8080"]
        self.port_forward_log = log
        with log.open("w") as stream:
            self.port_forward = subprocess.Popen(argv, stdout=stream, stderr=stream)
        self.wait_for_port(port)
        print(f"  gateway: 127.0.0.1:{port} -> service/{self.release}:8080")

        self.cli_env = dict(
            os.environ,
            XDG_CONFIG_HOME=str(self.config_dir),
            XDG_STATE_HOME=str(self.config_dir / "state"),
            XDG_DATA_HOME=str(self.config_dir / "data"),
            # No telemetry from a sample's own run.
            OPENSHELL_TELEMETRY_ENABLED="false")

        # `gateway add` is tolerated failing: this run's config directory is new, so it
        # normally succeeds, but a re-registration of the same name is not an error worth
        # stopping for. If the gateway really is not usable, the first call that needs it
        # fails with the CLI's own message.
        added = self.cli("gateway", "add", f"https://127.0.0.1:{port}", "--local",
                         "--name", "analyst", gateway=False, check=False)
        if added.returncode != 0:
            print("  gateway add reported it was already registered")

    def wait_for_port(self, port):
        deadline = time.monotonic() + PORT_FORWARD_TIMEOUT
        while time.monotonic() < deadline:
            if self.port_forward.poll() is not None:
                raise Problem(
                    "the gateway port-forward exited before it was listening; its output is "
                    f"in {self.port_forward_log}:\n"
                    f"{tail(self.port_forward_log.read_text())}")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=1):
                    return
            except OSError:
                time.sleep(0.2)
        raise Problem(
            f"the gateway port-forward did not accept a connection on 127.0.0.1:{port} "
            f"within {PORT_FORWARD_TIMEOUT}s; its output is in {self.port_forward_log}")

    def close_gateway(self):
        if self.port_forward is None or self.port_forward.poll() is not None:
            return
        self.port_forward.terminate()
        try:
            self.port_forward.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.port_forward.kill()

    def secret_data(self, name, keys):
        """Decoded values out of one Secret, by key.

        A missing key is a failure rather than an empty value: half an mTLS bundle would
        fail later as a TLS error, and a TLS error must never be mistaken here for anything
        else.
        """
        payload = self.kubectl_json("get", "secret", name)
        data = payload.get("data") or {}
        out = {}
        for key in keys:
            if key not in data:
                raise Problem(f"the Secret {name} in {self.namespace} has no {key!r} key, "
                              "so this run cannot connect to the gateway")
            out[key] = base64.b64decode(data[key])
        return out

    # -----------------------------------------------------------------------
    # The policies this run applies, and the provider
    # -----------------------------------------------------------------------

    def render_policies(self):
        """Copy the committed policies into the run directory with this namespace in them.

        The committed files carry <NAMESPACE> so the page can show them exactly as they are
        in the repository. Rendering into the run directory rather than editing them in
        place keeps the files the page shows and the files this run applied both on disk,
        and a placeholder left behind means a value did not arrive, which fails here rather
        than reaching OpenShell as a literal host name.
        """
        for name in ("initial", "draft-enabled", "supplier-profile"):
            source = SAMPLE_DIR / "policy" / f"{name}.json"
            text = source.read_text().replace("<NAMESPACE>", self.namespace)
            left = sorted(set(re.findall(r"<[A-Z_]+>", text)))
            if left:
                raise Problem(f"{source} still holds {', '.join(left)} after rendering, so "
                              "a value this run needed was empty; applied nothing")
            target = self.run_dir / f"{name}.json"
            target.write_text(text)
        print(f"  policies rendered for {self.namespace} into {self.run_dir}")

    def read_supplier_key(self):
        """The real supplier key, for the digest comparison and for the provider.

        It is read into this process and handed on only in a subprocess environment or read
        from a file inside a pod. It is never printed, never written into the run directory
        and never put on a command line.
        """
        self.real_key = self.secret_data("supplier-key", ("api-key",))["api-key"] \
            .decode().strip()
        if not self.real_key:
            raise Problem("the supplier-key Secret holds an empty api-key value")

    def ensure_provider(self):
        """The provider profile and the provider, created only when they are not there.

        The profile says how to authenticate and deliberately nothing about where; the
        endpoints in the worker policy are what grant the network, and they opt into this
        credential. src/policies.py explains why both lists in the profile are empty.
        """
        profiles = listing(self.cli_json("provider", "list-profiles"), "profiles",
                           "provider profile")
        if "procurement-supplier" in names_in(profiles):
            print("  provider profile procurement-supplier is already registered")
        else:
            self.cli("provider", "profile", "import", "-f",
                     str(self.run_dir / "supplier-profile.json"))
            print("  imported the provider profile procurement-supplier")

        providers = listing(self.cli_json("provider", "list"), "providers", "provider")
        if "supplier" in names_in(providers):
            print("  provider supplier is already configured")
            return
        # The key goes in through the environment the CLI reads, named by --credential. A
        # credential on a command line is visible to every other process on the host and
        # lands in shell history.
        self.cli("provider", "create", "--name", "supplier",
                 "--type", "procurement-supplier", "--credential", "SUPPLIER_API_KEY",
                 extra_env={"SUPPLIER_API_KEY": self.real_key})
        print("  created the provider supplier from the key in this run's Secret")

    # -----------------------------------------------------------------------
    # The sandbox
    # -----------------------------------------------------------------------

    def recreate_template(self):
        """Drop the previous run's sandbox and template, then make the template again.

        A fresh run starts with none of this run's own objects present. Leaving the previous
        sandbox would hold sandbox capacity other demos on this cluster share, and reusing a
        template built from an older image would run yesterday's analyst under today's name.

        The previous sandbox is named in the run record, which this script appends to once
        it has created one. A delete that fails is reported and not fatal: the sandbox may
        already be gone, and the refusal to adopt below is what actually protects this run.
        """
        previous = self.state.get("LAST_SANDBOX", "")
        if previous:
            gone = self.cli("sandbox", "delete", "--name", previous, check=False)
            if gone.returncode == 0:
                print(f"  deleted the previous run's sandbox {previous}")
            else:
                print(f"  the previous run's sandbox {previous} was not deleted by the "
                      "gateway; it may already be gone")

        templates = listing(self.cli_json("sandbox", "template", "list"), "templates",
                            "sandbox template")
        if self.template in names_in(templates):
            self.cli("sandbox", "template", "delete", self.template)
            print(f"  deleted the existing template {self.template}")

        # Two values here are load-bearing and neither is cosmetic. The node selector keeps
        # the x86_64 analyst image off this cluster's Graviton sandbox nodes. The 1Gi memory
        # request is what sizes the sandbox VM: a default-sized guest is about 130 MiB and
        # the kernel OOM-kills the analyst's Python process with no log output at all, which
        # looks like a refusal and is not one.
        driver_config = json.dumps(
            {"kubernetes": {"pod": {"node_selector": {"kubernetes.io/arch": "amd64"}}}})
        self.cli("sandbox", "template", "create", self.template,
                 "--image", self.state["ANALYST_IMAGE"],
                 "--cpu", "1", "--memory", "1Gi",
                 "--driver-config-json", driver_config)
        print(f"  created the template {self.template} on {self.state['ANALYST_IMAGE']}")

    def create_sandbox(self):
        """Create this run's sandbox, refusing to adopt one that is already there.

        The Sandbox object the agent-sandbox controller creates for a gateway sandbox is
        named default--<sandbox>. If one of that name exists, something else made it, and
        running the walkthrough against it would publish checks about a sandbox this run did
        not create and whose policy it does not know.
        """
        name = f"sandboxes.agents.x-k8s.io/default--{self.sandbox}"
        existing = self.kubectl("get", name, "--ignore-not-found", "-o", "name",
                                check=False)
        if existing.returncode != 0:
            raise Problem(
                f"could not determine whether a Sandbox called default--{self.sandbox} "
                f"already exists in {self.namespace}, so this run created nothing:\n"
                f"{tail(existing.stderr)}")
        if existing.stdout.strip():
            raise Problem(
                f"a Sandbox called default--{self.sandbox} is already in {self.namespace}. "
                "This run will not adopt a sandbox it did not create; delete it, or run "
                "again for a new run id.")

        print(f"  creating the sandbox {self.sandbox}; this takes a few minutes when a "
              "sandbox node has to be provisioned")
        self.cli("sandbox", "create", "--name", self.sandbox,
                 "--template", self.template,
                 "--policy", str(self.run_dir / "initial.json"),
                 "--provider", "supplier", "--no-auto-providers", "--detach",
                 "--", "sleep", "infinity",
                 timeout=SANDBOX_CREATE_TIMEOUT)
        # Written to the run record so the next run deletes this sandbox before it starts.
        with STATE_FILE.open("a") as stream:
            stream.write(f"LAST_SANDBOX={self.sandbox}\n")
        print(f"  created the sandbox {self.sandbox}")

    def find_pods(self):
        """The two pods of this sandbox, found by ownership rather than by name.

        A gateway sandbox is a workload pod inside a Nitro sandbox and a supervisor pod
        outside it. Both are selected by the Sandbox object's own uid, so a pod from another
        sandbox or another demo in this namespace cannot be picked up, and then told apart
        by the boundary-role label OpenShell puts on each. Exactly one of each is required:
        two would mean this is reading a different sandbox's pods as well.
        """
        sandbox = self.kubectl_json("get", "sandboxes.agents.x-k8s.io",
                                    f"default--{self.sandbox}")
        self.sandbox_uid = sandbox["metadata"]["uid"]
        pods = self.kubectl_json("get", "pods")
        owned = [pod for pod in pods.get("items", [])
                 if any(reference.get("uid") == self.sandbox_uid
                        for reference in pod["metadata"].get("ownerReferences", []))]
        by_role = {}
        for pod in owned:
            role = pod["metadata"].get("labels", {}).get("openshell.ai/boundary-role")
            by_role.setdefault(role, []).append(pod)
        for role in ("workload", "supervisor"):
            found = by_role.get(role, [])
            if len(found) != 1:
                raise Problem(
                    f"the sandbox default--{self.sandbox} owns {len(found)} pods labelled "
                    f"openshell.ai/boundary-role={role}, not exactly one, so this run "
                    "cannot say which pod is which side of the boundary")
        self.workload = by_role["workload"][0]
        self.supervisor = by_role["supervisor"][0]
        print(f"  workload pod:   {self.workload['metadata']['name']} on "
              f"{self.workload['spec'].get('nodeName')}")
        print(f"  supervisor pod: {self.supervisor['metadata']['name']} on "
              f"{self.supervisor['spec'].get('nodeName')}")

        # Karpenter may consolidate nodes at any time, and moving a live sandbox mid-run
        # would end it. This annotation is a scheduling hint and nothing else: it is not an
        # isolation mechanism and the page claims nothing from it.
        for pod in (self.workload, self.supervisor):
            self.kubectl("annotate", "pod", pod["metadata"]["name"],
                         "karpenter.sh/do-not-disrupt=true", "--overwrite")

    # -----------------------------------------------------------------------
    # The checks
    # -----------------------------------------------------------------------

    def check_the_split(self):
        """One sandbox pod and one ordinary pod, from the live specs."""
        self.check(self.workload["spec"].get("runtimeClassName") == "isolated-sandbox",
                   "the analyst's workload pod runs with runtimeClassName isolated-sandbox")
        self.check(self.supervisor["spec"].get("runtimeClassName") is None,
                   "the supervisor pod has no runtimeClassName, so it is an ordinary pod "
                   "outside the sandbox")

    def check_the_credential_boundary(self):
        """Which side of the boundary holds a credential, read from the two pod specs.

        This is the claim the page rests on most, so it is read per container rather than
        per pod. credential_volume_mounts says why that distinction is not a detail.
        """
        mounted = credential_volume_mounts(self.workload, "agent")
        self.check(mounted == [],
                   "the analyst's own container mounts no Secret or projected volume "
                   f"(found {mounted or 'none'})")
        self.check(self.workload["spec"].get("automountServiceAccountToken") is False,
                   "the workload pod sets automountServiceAccountToken: false")

        supervisor_mounts = credential_volume_mounts(self.supervisor, "supervisor")
        audiences = token_audiences(self.supervisor, "supervisor")
        self.check(bool(supervisor_mounts) and "openshell-gateway" in audiences,
                   "the supervisor container holds the service-account token for the "
                   "openshell-gateway audience, on the other side of the boundary "
                   f"(audiences: {', '.join(sorted(audiences)) or 'none'})")

    def check_identity(self):
        """The restricted process's own identity, and that it carries no AWS credential.

        Each field comes from a different mechanism and the page has to say which, so they
        are read together and credited separately: uid and gid are OpenShell's policy
        (process.run_as_user and run_as_group); CapEff and NoNewPrivs come from the pod spec
        OpenShell's Kubernetes driver generates, not from this sample's policy.

        The run id is the digest salt, not a secret. It is passed as an argument so the
        operator can compare the analyst's credential with the real one without either
        value being printed.
        """
        identity = self.probe("identity", self.run_id)
        self.identity = identity
        self.check(identity.get("uid") == EXPECTED_UID
                   and identity.get("gid") == EXPECTED_GID,
                   f"the analyst runs as uid {EXPECTED_UID} and gid {EXPECTED_GID}, the "
                   "identity the policy names")
        self.check(identity.get("no_new_privs") == "1",
                   "NoNewPrivs is set on the analyst process, from the generated pod spec")
        cap_eff = identity.get("cap_eff")
        try:
            effective = int(cap_eff, 16)
        except (TypeError, ValueError):
            raise Problem(f"the analyst process reported CapEff as {cap_eff!r}, which is "
                          "not a hexadecimal capability mask, so the claim that it holds "
                          "no capability cannot be evaluated")
        self.check(effective == 0,
                   f"the analyst process holds no effective capability (CapEff {cap_eff})")

        self.check(identity.get("aws_names") == []
                   and identity.get("aws_credential_names") == []
                   and identity.get("model_key_names") == [],
                   "the analyst has no AWS variable, no AWS credential variable and no "
                   "other model key in its environment")

    def check_the_placeholder(self):
        """The analyst holds a placeholder, and it is not the real key.

        The digest is computed here over the real key with the same salted, deliberately
        slow function the analyst used, so the two are comparable. Equal digests would mean
        the analyst is holding the real credential, which is the failure this check exists
        to catch, so they fail the run rather than being reported.

        What this does not establish, and what no wording here should imply: that the real
        key was absent from the sandbox at every earlier moment, or that it is absent from
        some channel this run does not read. It compares the value the analyst holds when
        probed. The container-scoped mount check is the other half of the evidence.
        """
        identity = self.identity
        self.check(identity.get("api_key_present") is True
                   and identity.get("api_key_is_placeholder") is True,
                   "the analyst holds a credential and it is an openshell: placeholder")
        keyed_digest = shared_keyed_digest()
        real = keyed_digest(self.run_id, self.real_key)
        reported = identity.get("api_key_digest")
        # The digest has to be a digest before it can be compared. Without this, a probe
        # that did not report the field at all would leave `None != real`, which is true,
        # and the comparison would pass having measured nothing.
        # The digest itself is deliberately not printed, and not put in the check's name
        # either. It is a salted, slow commitment to credential material, which the shared
        # worker goes to some trouble to make expensive to test against a candidate list,
        # and none of that is a reason to publish it: a reader learns nothing from the
        # value, and this line ends up in a page's output block. CodeQL flagged an earlier
        # version of this line as clear-text logging of sensitive data, and it was right.
        # The run's own calls.json under tmp/ keeps both digests as evidence.
        self.check(isinstance(reported, str) and len(reported) == 64
                   and all(c in "0123456789abcdef" for c in reported),
                   "the analyst reported a credential digest to compare, of the expected "
                   "length and alphabet")
        # Deliberately narrow wording. This compares the value the analyst holds now
        # against the real key; it does not establish that the real key was never present
        # at any earlier moment, nor that it is absent from some channel this run does not
        # read. The mounts check above is the other half of the evidence.
        self.check(reported != real,
                   "the credential the analyst holds is not the real supplier key, by "
                   "salted digest of each")

    def check_the_sandbox(self):
        """That this really ran in a Nitro sandbox guest, and where.

        The guest's block devices are the reading that cannot be faked by a pod spec: a
        guest sees virtio disks, while an ordinary pod on the same instance sees the
        instance's NVMe devices.
        """
        identity = self.identity
        devices = identity.get("block_devices")
        if not isinstance(devices, list) or not devices:
            raise Problem("the analyst reported no block devices, so it cannot be said "
                          "whether this ran in a sandbox guest")
        self.check(any(GUEST_DISK.match(device) for device in devices)
                   and all(GUEST_DEVICE.match(device) for device in devices)
                   and not any(device.startswith("nvme") for device in devices),
                   "the analyst sees only a sandbox guest's virtio and device-mapper disks "
                   f"and no instance NVMe device ({', '.join(devices)})")

        node = self.workload["spec"].get("nodeName")
        if not node:
            raise Problem("the workload pod names no node, so the guest kernel cannot be "
                          "compared with the node's own")
        node_kernel = self.kubectl(
            "get", "node", node, "-o",
            "jsonpath={.status.nodeInfo.kernelVersion}").stdout.strip()
        if not node_kernel:
            raise Problem(f"could not read the kernel version of the node {node}, so the "
                          "guest kernel cannot be compared with the node's own")
        (self.run_dir / "placement.json").write_text(json.dumps({
            "run_id": self.run_id,
            "sandbox": self.sandbox,
            "sandbox_uid": self.sandbox_uid,
            "upstream_ref": self.state["UPSTREAM_REF"],
            "upstream_revision": self.state["UPSTREAM_REVISION"],
            "workload": {"pod": self.workload["metadata"]["name"],
                         "uid": self.workload["metadata"]["uid"],
                         "node": node,
                         "runtime_class": self.workload["spec"].get("runtimeClassName")},
            "supervisor": {"pod": self.supervisor["metadata"]["name"],
                           "uid": self.supervisor["metadata"]["uid"],
                           "node": self.supervisor["spec"].get("nodeName"),
                           "runtime_class":
                               self.supervisor["spec"].get("runtimeClassName")},
            "guest": {"kernel": identity.get("kernel"),
                      "kernel_version": identity.get("kernel_version"),
                      "uptime_seconds": identity.get("uptime_seconds"),
                      "block_devices": devices},
            "node_kernel_version": node_kernel,
        }, indent=2) + "\n")
        print(f"  guest kernel {identity.get('kernel')} on a node running {node_kernel}")

    def check_the_filesystem(self):
        """The filesystem policy, both ways: one path it must open and ones it must not."""
        granted = self.probe("open-probe", "/opt/analyst/fixtures/case.json", "read")
        self.check(granted.get("allowed") is True,
                   "the analyst can read the case file inside its granted path")

        # That file is mode 666 in the image, and the trusted control below opens it for
        # writing as the same uid. So a refused write here is OpenShell's filesystem policy
        # and not a Unix permission.
        refused = self.probe("open-probe", "/opt/analyst/fixtures/case.json", "write")
        self.check(refused.get("denied_errno") == errno.EACCES,
                   "the analyst is refused EACCES opening the same case file for writing, "
                   "in a read-only grant")

        canary = self.probe("open-probe", "/protected/canary", "read")
        self.check(canary.get("denied_errno") == errno.EACCES,
                   "the analyst is refused EACCES reading the canary outside every grant")

        workspace = self.probe("open-probe", "/sandbox/probe.txt", "create")
        self.check(workspace.get("allowed") is True,
                   "the analyst can create a file in its writable workspace")

        # ENOENT is what this run observed: OpenShell stages its boundary material at pod
        # start and it is gone before the analyst runs. EACCES and EPERM are accepted as
        # well because either would also mean the analyst cannot have it, but absence and
        # refusal are different claims and the page says which one the run saw.
        boundary = self.probe("open-probe",
                              "/.openshell/state/bootstrap/boundary.json", "read")
        self.check(boundary.get("denied_errno") in (errno.ENOENT, errno.EACCES, errno.EPERM),
                   "the analyst cannot open OpenShell's staged boundary material "
                   f"(errno {boundary.get('denied_errno')} "
                   f"{boundary.get('errno_name') or 'unnamed'})")

        token = self.probe("open-probe",
                           "/var/run/secrets/kubernetes.io/serviceaccount/token", "read")
        self.check(token.get("denied_errno") in (errno.ENOENT, errno.EACCES, errno.EPERM),
                   "the analyst cannot open a Kubernetes service-account token "
                   f"(errno {token.get('denied_errno')})")

    def check_the_process(self):
        """A refused transition to root.

        This one comes from a fixed seccomp filter inside OpenShell's own in-pod runtime,
        which is not policy-configurable, so the page must not credit this sample's policy
        with it.
        """
        result = self.probe("setuid-root")
        self.check(result.get("denied_errno") == errno.EPERM,
                   "the analyst is refused EPERM becoming root, by OpenShell's own seccomp "
                   "filter")

    def check_the_trusted_control(self):
        """The same operations, outside OpenShell's confinement, in the model bridge pod.

        This is what makes every refusal above attributable. The bridge pod runs the same
        image as the analyst and the same uid 1000 with no OpenShell confinement, so each
        operation OpenShell refused is shown here to be one the image, the file modes, the
        supplier API and the network all allow.

        The program asserts its own identity, the canary and the writable open and exits
        non-zero if any of them does not hold; its statuses are compared here. The exec's
        exit status is checked through check() rather than raised on directly, so a failure
        prints as a FAIL line beside the claims it belongs with.
        """
        cases = []
        for number, (method, host, path) in enumerate([
                ("GET", self.supplier_url, f"/cases/{CASE}/suppliers"),
                # The alias host OpenShell refused the analyst, answering 200 here: same
                # backend, same key, a different name.
                ("GET", self.alias_url, f"/cases/{CASE}/suppliers"),
                ("POST", self.supplier_url, "/purchase-orders"),
                ("PATCH", self.supplier_url, "/suppliers/northstar"),
                ("GET", self.supplier_url, "/cases/rfp-other/suppliers"),
        ]):
            cases.append({"method": method, "url": host + path,
                          "request_id": f"{self.run_id}-control-{number}"})
        # One request with a key that is not the supplier's, so the 200s above are shown to
        # be authenticated rather than a server that accepts anything.
        cases.append({"method": "GET",
                      "url": self.supplier_url + f"/cases/{CASE}/suppliers",
                      "request_id": f"{self.run_id}-control-5", "wrong_key": True})

        # The file control runs in the analyst's own container, through kubectl exec
        # rather than through OpenShell. Same pod, same image, same uid, same filesystem,
        # and the only difference is that this process was not started under OpenShell's
        # policy, so what it can do is what the policy is refusing the analyst.
        file_program = FILE_CONTROL_PROGRAM.replace("__CANARY__", repr(CANARY_CONTENT))
        file_result = self.run_control(
            ["exec", self.workload["metadata"]["name"], "-c", "agent", "--",
              "python3", "-c", file_program],
            "file-control",
            "outside OpenShell, in the analyst's own container at the same uid 1000, the "
            "canary reads and the case file opens for writing")
        self.check(file_result.get("uid") == EXPECTED_UID
                   and file_result.get("canary_read") is True
                   and file_result.get("case_file_opened_for_writing") is True,
                   "the trusted control in the analyst's own container reads the canary "
                   "and opens the case file for writing, so both refusals above are "
                   f"OpenShell's policy (case file mode {file_result.get('case_file_mode')})")

        # The network control has to run somewhere with egress; see the comment on
        # NETWORK_CONTROL_PROGRAM for why that cannot be the workload pod.
        network_program = (NETWORK_CONTROL_PROGRAM
                           .replace("__CASES_JSON__", repr(json.dumps(cases))))
        statuses = self.run_control(
            ["exec", "deployment/analyst-bridge", "--", "python3", "-c",
             network_program],
            "network-control",
            "the trusted network control ran in the bridge pod")
        (self.run_dir / "control.json").write_text(json.dumps(
            {"file_control": file_result, "cases": cases, "statuses": statuses,
             "expected": CONTROL_EXPECTED_STATUSES}, indent=2) + "\n")
        self.check(statuses == CONTROL_EXPECTED_STATUSES,
                   "outside OpenShell the supplier API answers every operation the analyst "
                   f"was refused, and refuses a wrong key: {statuses}")

    def count_alias_denials(self, save=False):
        """How many transport-layer refusals of the alias host the supervisor has recorded.

        Every part of the predicate earns its place. "DENIED" and the hostname alone would
        match a DNS-level refusal of the same name, so the line also has to carry the port,
        the executable the policy names and OpenShell's own reason for refusing a
        connection at the transport layer. None of that makes the line unique to one
        attempt, though, which is why the caller compares the count before and after its
        own probe rather than asking whether any such line exists.
        """
        log = self.kubectl("logs", self.supervisor["metadata"]["name"], "-c", "supervisor",
                           check=False)
        if log.returncode != 0:
            raise Problem("could not read the supervisor's log, so the refusal has no "
                          f"record from the layer that made it:\n{tail(log.stderr)}")
        if save:
            (self.run_dir / "supervisor.log").write_text(log.stdout)
        return sum(1 for line in log.stdout.splitlines()
                   if "DENIED" in line
                   and f"{self.alias_host}:8443" in line
                   and PYTHON_BINARY in line
                   and ALIAS_DENIAL_REASON in line)

    def check_the_destination(self):
        """A host the policy does not name, refused at connect, with the layer's own record.

        A timeout, a TLS error or a 401 cannot pass as a denial here: the shared worker
        raises on all three and only an EACCES at connect comes back as denied_errno. The
        trusted control above already had this same host answer 200, so the refusal is the
        destination rule and not the host being unreachable.
        """
        # The log is counted before the probe runs, not only after. Matching on the host,
        # the port, the executable and the reason makes the line specific to this kind of
        # refusal, but every one of those is fixed for the life of the sandbox, so a line
        # left by an earlier attempt would match just as well. What distinguishes this
        # attempt is that the count goes up across it.
        before = self.count_alias_denials()

        request_id = f"{self.run_id}-alias"
        self.denied_request_ids.append(request_id)
        result = self.probe("api", f"{self.alias_url}/cases/{CASE}/suppliers", "GET",
                            request_id)
        self.check(result.get("denied_errno") == errno.EACCES,
                   "the analyst is refused EACCES connecting to the alias host the policy "
                   "does not name")

        # The client's own errno is not the only evidence this run accepts: the layer that
        # refused has to have said so too, and it has to have said so just now.
        after = self.count_alias_denials(save=True)
        self.check(after > before,
                   "OpenShell's supervisor logged this refusal itself, naming the alias "
                   f"host, port 8443, {PYTHON_BINARY} and reason {ALIAS_DENIAL_REASON}")

    def check_the_operations(self):
        """Four operations on a host the policy does allow, each refused by rule.

        The destination is the same one the availability read is allowed on, so what is
        being shown here is the operation rules and not the host.
        """
        operations = [("POST", "/purchase-orders"),
                      ("PATCH", "/suppliers/northstar"),
                      ("GET", "/cases/rfp-other/suppliers"),
                      ("POST", f"/cases/{CASE}/recommendations")]
        for number, (method, path) in enumerate(operations):
            request_id = f"{self.run_id}-denied-{number}"
            self.denied_request_ids.append(request_id)
            result = self.probe("api", self.supplier_url + path, method, request_id)
            body = denied_body(result, f"{method} {path}")
            self.check(result.get("status") == 403
                       and body.get("error") == "policy_denied"
                       and body.get("layer") == "l7"
                       and body.get("rule") == f"{method} {path}",
                       f"OpenShell refuses {method} {path} with a 403 policy_denied naming "
                       "that rule")

    def check_the_allowed_read(self):
        result = self.probe("api", f"{self.supplier_url}/cases/{CASE}/suppliers", "GET",
                            f"{self.run_id}-allowed")
        self.check(result.get("status") == 200,
                   "the one supplier operation the policy allows returns 200")

    def check_the_work(self):
        """The analyst's actual work: the comparison, the model call and the saved report.

        bridge_credential_provider is the one field here that is about the boundary rather
        than the work. container-role is how EKS Pod Identity reaches boto3, so it says the
        Bedrock call was made with the bridge's own credentials, outside the sandbox, and
        the analyst had none.
        """
        model = self.state["BEDROCK_MODEL_ID"]
        result = self.probe("analyze", self.supplier_url, self.bridge_url, self.run_id,
                            model, timeout=ANALYZE_TIMEOUT)
        self.check(result.get("recommended_supplier") == "northstar",
                   "the analyst recommends the supplier the deterministic comparison names")
        self.check(result.get("cites_all_sources") is True,
                   "the model's analysis cites every original proposal")
        self.check(result.get("model") == model,
                   f"the completion came from the configured model {model}")
        self.check((result.get("usage") or {}).get("total_tokens", 0) > 0,
                   "the completion reports a non-zero token usage, so a real model turn "
                   "happened")
        self.check(result.get("bridge_credential_provider") == "container-role",
                   "the Bedrock call used the bridge's EKS Pod Identity credentials, which "
                   "is the only AWS identity in this sample")

    def check_the_policy_update(self):
        """One rule added to a live sandbox, with nothing about the request changing.

        The same submission is refused, then allowed, then the operations the update did not
        name are still refused. The two pod uids and the restart counts are read before and
        after, so the page can say the policy changed under a running analyst rather than
        the sandbox having been replaced underneath it.

        The counts are only recorded at this point and not asserted: the assertion is at the
        end, against what they are after the update.
        """
        before = {}
        for role, pod in (("workload", self.workload), ("supervisor", self.supervisor)):
            before[role] = {"uid": pod["metadata"]["uid"], "restarts": restart_counts(pod)}
        print(f"  before the update: {json.dumps(before)}")

        denied_id = f"{self.run_id}-draft-denied"
        self.denied_request_ids.append(denied_id)
        refused = self.probe("submit", self.supplier_url, denied_id)
        body = denied_body(refused, "the draft submission before the update")
        self.check(refused.get("status") == 403
                   and body.get("error") == "policy_denied"
                   and body.get("rule") == f"POST /cases/{CASE}/recommendations",
                   "before the update, the analyst's own draft submission is refused by "
                   "rule")

        # `policy set` replaces the sandbox's policy rather than patching it, which is why
        # draft-enabled.json is a whole policy and not a fragment. --wait, so the next probe
        # cannot race the update.
        self.cli("policy", "set", self.sandbox,
                 "--policy", str(self.run_dir / "draft-enabled.json"), "--wait")
        print("  applied the one-rule policy update to the running sandbox")

        allowed_id = f"{self.run_id}-draft"
        allowed = self.probe("submit", self.supplier_url, allowed_id)
        saved = allowed.get("body")
        self.check(allowed.get("status") == 201 and isinstance(saved, dict)
                   and saved.get("saved") is True
                   and saved.get("request_id") == allowed_id,
                   "after the update, the identical draft submission is accepted with 201")

        still_id = f"{self.run_id}-still-denied"
        self.denied_request_ids.append(still_id)
        still = self.probe("api", self.supplier_url + "/purchase-orders", "POST", still_id)
        still_body = denied_body(still, "the purchase order after the update")
        self.check(still.get("status") == 403
                   and still_body.get("error") == "policy_denied"
                   and still_body.get("rule") == "POST /purchase-orders",
                   "after the update, the purchase order is still refused: the update added "
                   "one rule and nothing else")

        after = {}
        for role, name in (("workload", self.workload["metadata"]["name"]),
                           ("supervisor", self.supervisor["metadata"]["name"])):
            pod = self.kubectl_json("get", "pod", name)
            after[role] = {"uid": pod["metadata"]["uid"], "restarts": restart_counts(pod)}
        self.check(after["workload"]["uid"] == before["workload"]["uid"]
                   and after["supervisor"]["uid"] == before["supervisor"]["uid"],
                   "both pods are the same objects they were before the update, by uid")
        counts = [count for role in after for count in after[role]["restarts"].values()]
        self.check(bool(counts) and all(count == 0 for count in counts),
                   f"no container in either pod has restarted ({json.dumps(after)})")

    def check_the_correlation(self):
        """The two servers' own logs against this run's record of what it was allowed.

        Read from the supplier API's pod and the bridge's stdout rather than from the
        analyst's evidence, so an allowed request can be shown to have arrived and a refused
        one never to have arrived at all. A log with no entries would satisfy the second half
        on its own, so the allowed ids have to be present as well, and that is what makes an
        empty log a failure here.
        """
        api_pods = self.kubectl_json("get", "pods", "-l", "app=supplier-api")
        names = [pod["metadata"]["name"] for pod in api_pods.get("items", [])]
        if len(names) != 1:
            raise Problem(f"found {len(names)} pods labelled app=supplier-api in "
                          f"{self.namespace}, not exactly one, so it cannot be said which "
                          "log is the supplier API's")
        api_log = self.kubectl("exec", names[0], "--",
                               "cat", "/var/lib/supplier/requests.jsonl", check=False)
        if api_log.returncode != 0:
            raise Problem("could not read the supplier API's own request log, so this run "
                          f"cannot be correlated with it:\n{tail(api_log.stderr)}")
        (self.run_dir / "supplier-api-requests.jsonl").write_text(api_log.stdout)

        bridge_log = self.kubectl("logs", "deployment/analyst-bridge", check=False)
        if bridge_log.returncode != 0:
            raise Problem("could not read the model bridge's log, so this run cannot be "
                          f"correlated with it:\n{tail(bridge_log.stderr)}")
        (self.run_dir / "bridge.log").write_text(bridge_log.stdout)

        entries = []
        for line in api_log.stdout.splitlines():
            if line.strip():
                entries.append(json.loads(line))
        # The bridge prints one JSON object per authenticated attempt, and one plain line
        # when it starts, so only the objects are read and anything else is left alone.
        for line in bridge_log.stdout.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue

        self.check(bool(entries),
                   "the supplier API and the bridge have request logs to correlate against")

        for request_id in (f"{self.run_id}-allowed", f"{self.run_id}-draft"):
            # The supplier API logs a request only after its key check, so an entry with no
            # authenticated field is an authenticated one; the bridge records the flag.
            matched = [entry for entry in entries
                       if entry.get("request_id") == request_id
                       and entry.get("authenticated", True) is True]
            self.check(len(matched) == 1,
                       f"the allowed request {request_id} arrived upstream exactly once, "
                       "authenticated")

        # Exact equality on the request id, never a substring: "<run>-draft" is a prefix of
        # "<run>-draft-denied", and a substring test would find the refused one in the
        # allowed one and pass.
        refused = set(self.denied_request_ids)
        leaked = sorted({entry.get("request_id") for entry in entries
                         if entry.get("request_id") in refused})
        self.check(not leaked,
                   f"none of this run's {len(self.denied_request_ids)} refused requests "
                   f"reached the supplier API or the bridge ({', '.join(leaked) or 'none'})")

    def copy_out_and_upload(self):
        """The analyst's output out of the workspace, and the report into S3.

        The upload is made with the operator's own credentials from this workstation. No pod
        in this sample has any S3 permission: the bridge's role grants Bedrock on one
        inference profile and nothing else, and the analyst has no role at all.
        """
        for name in ("recommendation.md", "evidence.json"):
            completed = self.cli("sandbox", "exec", "--name", self.sandbox, "--no-tty",
                                 "--", "cat", f"/sandbox/output/{name}", check=False)
            if completed.returncode != 0:
                raise Problem(f"could not copy {name} out of the sandbox workspace:\n"
                              f"{tail(completed.stderr)}")
            (self.run_dir / name).write_text(completed.stdout)
        # A copy that silently produced nothing must not be uploaded as the run's report.
        report = self.run_dir / "recommendation.md"
        if not report.read_text().strip():
            raise Problem(f"{report} came back empty, so the recommendation was not copied "
                          "out of the workspace")
        try:
            json.loads((self.run_dir / "evidence.json").read_text())
        except json.JSONDecodeError as error:
            raise Problem(f"the evidence copied out of the workspace is not JSON ({error})")

        self.s3_key = f"reports/{CASE}/{self.run_id}/recommendation.md"
        self.aws("s3api", "put-object", "--bucket", self.state["BUCKET"],
                 "--key", self.s3_key, "--body", str(report))
        print(f"  uploaded s3://{self.state['BUCKET']}/{self.s3_key}")

    # -----------------------------------------------------------------------
    # The run
    # -----------------------------------------------------------------------

    def run(self):
        print(f"\n==> run {self.run_id} in {self.run_dir}")
        self.render_policies()
        self.read_supplier_key()
        try:
            print("\n==> connecting to the OpenShell gateway")
            self.open_gateway()
            self.ensure_provider()

            print("\n==> the sandbox")
            self.recreate_template()
            self.create_sandbox()
            self.find_pods()

            print("\n==> what the sandbox is, and what the analyst holds")
            self.check_the_split()
            self.check_the_credential_boundary()
            self.check_identity()
            self.check_the_placeholder()
            self.check_the_sandbox()

            print("\n==> what the analyst may touch")
            self.check_the_filesystem()
            self.check_the_process()

            print("\n==> the same operations outside OpenShell's confinement")
            self.check_the_trusted_control()

            print("\n==> what the analyst may reach")
            self.check_the_destination()
            self.check_the_operations()
            self.check_the_allowed_read()

            print("\n==> the work, and one rule added while it runs")
            self.check_the_work()
            self.check_the_policy_update()

            print("\n==> the servers' own records")
            self.check_the_correlation()
            self.copy_out_and_upload()
        finally:
            self.save_checks()
            self.save_calls()
            self.close_gateway()

        print("\n==> done")
        print(f"  checks:         {len(self.checks)}, all passed")
        print(f"  run id:         {self.run_id}")
        print(f"  run directory:  {self.run_dir}")
        print(f"  S3 report:      s3://{self.state['BUCKET']}/{self.s3_key}")
        print(f"  the sandbox {self.sandbox} is still running; ./scripts/clean.sh removes "
              "it with the rest")


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv:
        print(f"unknown argument: {argv[0]}", file=sys.stderr)
        return 2
    try:
        walkthrough = Walkthrough(load_state(STATE_FILE))
        walkthrough.run()
    except Problem as problem:
        print(f"\nERROR: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
