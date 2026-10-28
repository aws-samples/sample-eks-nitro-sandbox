"""The trusted controller: it owns AWS and the supplier key, and bubblewrap owns the tools.

It runs inside the Nitro sandbox, as the pod's only long-lived process. Two boundaries
matter and the page keeps them apart:

  * The Nitro sandbox is the hardware-level isolation around this whole pod. Everything
    below, including the supplier key and the AWS credentials, is inside it.
  * bubblewrap is the boundary inside the pod, between this controller and the reader,
    evaluator and writer it launches. Those are processes started with an argument list
    this controller assembles, not pods, and not three independent model sessions.

What this controller does, in order: read back the bubblewrap pin and the guest setting
the boundary needs, read the case and the three proposals from Amazon S3 with the pod's
EKS Pod Identity role, show what that role is refused, start the tool processes under
`bwrap` and record what each one is allowed and refused, ask Amazon Bedrock to explain
the verified comparison, check the answer against that comparison, and save the accepted
recommendation back to S3.

Every refusal is recorded beside a control where the same call succeeds, because a
refusal on its own does not say what refused it. The controls here are deliberate:

  * For a read, the controller opens the very same path, as the very same UID, in the
    same run. So the child's ENOENT is not the file's mode and not a missing file.
  * For the read-only input, the controller also shows the child's /input/case.json is
    its own file by inode, and that it can write that file itself without changing it. So
    the child's EROFS is the read-only bind mount and nothing else.
  * For the network, the controller opens a TCP connection to the exact address and port
    the child is refused.
  * For a nested user namespace, the same probe runs in a child started without
    --disable-userns, where it has to succeed.
  * For each seccomp filter, the same syscall runs with the baseline filter alone, where
    it has to succeed.

The run fails on the first check that does not hold, and a tool process that crashed or
could not start raises rather than reporting a refusal.
"""
import errno
import hashlib
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlsplit

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# Path-style addressing, so every S3 request goes to the Region's own endpoint rather
# than to <bucket>.s3.<Region>.amazonaws.com.
S3_CONFIG = Config(s3={"addressing_style": "path"})

sys.path.insert(0, "/opt/analyst")
sys.path.insert(0, "/opt/bubblewrap")

from business import (CASE, FIXTURES, availability_from_reply, compare,  # noqa: E402
                     load_json, proposal_matches_case, render_report,
                     report_choice_matches, report_cites_sources)
from analyst_agent import ModelTurn  # noqa: E402
from filters import BASELINE, compiled_filter, syscall_number  # noqa: E402
from sandbox import (CHILD_ENVIRONMENT, HOSTNAME, NAMESPACES,  # noqa: E402
                     command, pin, run)

ROOT = Path("/var/lib/analyst")
ROLES = ("reader", "evaluator", "writer")

SUPPLIER_KEY_FILE = "/opt/supplier-key/api-key"
CA = "/opt/supplier-ca/ca.crt"
USERNS_LIMIT = Path("/proc/sys/user/max_user_namespaces")

API = os.environ["SUPPLIER_API_URL"]
BUCKET = os.environ["ANALYST_BUCKET"]
REGION = os.environ["AWS_REGION"]
ROLE_NAME = os.environ["ANALYST_ROLE_NAME"]

# Variables that would mean a model API key had been put in the sandbox. Bedrock is
# reached with Pod Identity credentials, so none of these should exist.
MODEL_KEY_VARS = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "BEDROCK_API_KEY",
                  "AWS_BEARER_TOKEN_BEDROCK")

# What a tool process's environment has to be, exactly. The five names the launcher sets
# with --setenv, and PWD, which bwrap sets from --chdir.
EXPECTED_CHILD_ENV = sorted({name for name, _ in CHILD_ENVIRONMENT} | {"PWD"})

# The syscalls the two stacked filters block, one each. Harmless on purpose: the page is
# showing that an application-supplied filter reaches the child and that two of them
# stack, not that these particular calls are dangerous.
STACKED = ("getppid", "uname")

# The five capability sets /proc/<pid>/status reports. "No capabilities at all" means all
# five are empty, so the check names all five rather than inferring the rest from CapBnd:
# the bounding set limits what this process and its descendants can gain from file
# privilege during an exec, and says nothing about what the process holds now.
CAPABILITY_SETS = ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb")


def no_capabilities(fields) -> bool:
    """True when every capability set in a /proc/<pid>/status reading is empty.

    A named function rather than a condition written inline, so that it can be run
    against readings it must accept and readings it must reject without copying it. The
    controller's own reading inside the privileged container is the rejecting case: its
    CapBnd is the whole set while its CapEff and CapPrm are empty, which is exactly the
    state an inline "CapEff and CapBnd are zero" check used to accept as "no capabilities
    at all".
    """
    return all(int(fields[name], 16) == 0 for name in CAPABILITY_SETS)


def files_holding(root: Path, secret: str) -> list:
    """Every file under root whose bytes contain secret, as paths relative to root.

    A named function returning the findings rather than a check that raises, so that it
    can be run against a tree that must come back empty and a tree that must not.

    The caller passes the whole of the run's own directory. That is broader than the two
    documents that leave the pod, and deliberately: the run also stages facts between
    roles, records every call it made, and keeps each role's output, and all of it sits
    under that one directory. Scanning the directory rather than a list of names cannot
    be left stale by a later stage writing one more file.

    Decoded with errors="replace" so that a file that is not text is still scanned rather
    than skipped: a credential in a file this function could not decode would otherwise
    be the one it missed.
    """
    return sorted(str(path.relative_to(root)) for path in root.rglob("*")
                  if path.is_file()
                  and secret in path.read_bytes().decode("utf-8", "replace"))


def same_file(reported, actual) -> bool:
    """True when a child's (device, inode) reading names the file the controller holds.

    Both numbers, because an inode number is unique only within one filesystem: two equal
    inode numbers on different devices are different files, and comparing the inode alone
    would have accepted that pair. A named function for the same reason as the one above,
    so the comparison can be run against a reading it must accept and one it must reject.
    The rejecting reading is a device-only difference, which no two files in this sample
    can produce, so it is a case the sample cannot otherwise reach.

    `actual` is an os.stat_result the controller took from a descriptor it had open, not a
    descriptor it still holds: it records the identity and compares it later.
    """
    return (reported["device"], reported["inode"]) == (actual.st_dev, actual.st_ino)

# A nested user namespace can be refused in more than one way, and which one depends on
# how the kernel reports an exhausted limit. --disable-userns works by setting the
# child's own limit to zero, so ENOSPC is the usual answer; the run records the one it
# got in the check's name rather than leaving it to the reader to guess.
USERNS_DENIALS = (errno.ENOSPC, errno.EPERM, errno.EUSERS)


def status_fields(path="/proc/self/status") -> dict:
    fields = dict(line.split(":", 1) for line in Path(path).read_text().splitlines()
                  if ":" in line)
    return {name: value.strip() for name, value in fields.items()}


def trusted_request(path, method, request_id, key=None, body=None):
    """Call the supplier API from the controller, outside the tool boundary.

    The controller may read the real key file, so a request it makes carries the real
    credential. No tool process makes a supplier request in this sample: bubblewrap gives
    them no network, so the controller performs every supplier call itself.
    """
    if key is None:
        key = Path(SUPPLIER_KEY_FILE).read_text().strip()
    data = None if body is None else json.dumps(body).encode()
    headers = {"X-Api-Key": key, "X-Analyst-Request-ID": request_id}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(API + path, data=data, headers=headers,
                                     method=method)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=CA)))
    try:
        with opener.open(request, timeout=10) as response:
            return {"status": response.status, "body": json.load(response)}
    except urllib.error.HTTPError as error:
        return {"status": error.code}


class Run:
    def __init__(self):
        self.id = uuid.uuid4().hex
        self.root = ROOT / self.id
        self.root.mkdir(parents=True, mode=0o700)
        self.calls = []
        self.checks = []
        # Every supplier call this run makes, so the server's own request log can be
        # checked against it afterwards by scripts/correlate.py.
        self.supplier_requests = []
        for role in ROLES:
            for directory in ("in", "out"):
                (self.root / role / directory).mkdir(parents=True)

    # -- recording ---------------------------------------------------------

    def check(self, name, condition):
        passed = bool(condition)
        self.checks.append({"name": name, "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} {name}", flush=True)
        if not passed:
            raise AssertionError(name)

    def call(self, role, action, *args, **options):
        """Run one action in one tool process, under this sample's bwrap argument list."""
        completed = run(self.root / role, action, *args, **options)
        self.calls.append({"call_id": f"{self.id}-{len(self.calls):02d}", "role": role,
                           "action": action, "result": completed["result"],
                           "bwrap_status": completed["status"]})
        (self.root / "calls.json").write_text(json.dumps(self.calls, indent=2))
        return completed["result"]

    def refused(self, result, expected) -> bool:
        """True only for the exact errno asked for, never for any failure."""
        return result.get("errno") == expected

    def supplier(self, method, path, suffix, key=None, body=None):
        """One supplier call, from the controller, recorded for the correlation."""
        request_id = f"{self.id}-{suffix}"
        reply = trusted_request(path, method, request_id, key=key, body=body)
        self.supplier_requests.append(
            {"request_id": request_id, "method": method, "path": path,
             "status": reply["status"], "authenticated": key is None})
        return reply

    # -- the stages --------------------------------------------------------

    def aws_identity(self):
        session = boto3.Session(region_name=REGION)
        credentials = session.get_credentials()
        self.check("the AWS SDK uses the Pod Identity container credential provider",
                   credentials is not None and credentials.method == "container-role")
        identity = session.client("sts").get_caller_identity()
        self.check("the caller is this sample's Pod Identity role",
                   f":assumed-role/{ROLE_NAME}/" in identity["Arn"])
        present = [name for name in MODEL_KEY_VARS if os.environ.get(name)]
        self.check("no model API key is in the sandbox: " +
                   (", ".join(MODEL_KEY_VARS) + " are all absent" if not present
                    else f"found {present}"), not present)
        self.arn = identity["Arn"]
        return session

    def the_layer(self):
        """The pinned binary, the guest setting it needs, and who the controller is."""
        version = pin()
        self.check(f"bwrap reports the pinned version: {version['reported']}",
                   version["reported"] == f"bubblewrap {version['pinned_version']}")
        self.check("the image records the upstream source commit bwrap was built from: "
                   f"{version['source_commit']}", len(version["source_commit"]) == 40)
        self.pin = version

        # The init container raised this inside the guest. bubblewrap needs a user
        # namespace, and the guest's default is zero, so a value above zero here is the
        # init container's work and not something the sample can assume.
        limit = int(USERNS_LIMIT.read_text())
        self.check(f"the guest allows user namespaces: "
                   f"{USERNS_LIMIT} is {limit}", limit > 0)
        self.userns_limit = limit

        fields = status_fields()
        self.check("the trusted controller runs as UID/GID 1000",
                   os.getuid() == 1000 and os.getgid() == 1000)
        # The working container is privileged, which is what lets bwrap mount a private
        # procfs in the guest. It does not give this process any capability: a non-root
        # exec starts with an empty permitted set, so CapPrm and CapEff are both zero
        # while the bounding set the container was given is everything.
        #
        # The three readings after the condition are the cost of that privilege, and they
        # are reported rather than asserted. Asserting them would mean a run failing if a
        # future runtime hardened a privileged container, which is not a regression this
        # sample should refuse to run on; the page reads them as the trade bubblewrap's
        # requirements force here.
        self.check("the trusted controller has no capability it can use (CapEff "
                   f"{fields['CapEff']}, CapPrm {fields['CapPrm']}); the privileged "
                   f"container's other readings are CapBnd {fields['CapBnd']}, "
                   f"NoNewPrivs {fields['NoNewPrivs']} and Seccomp {fields['Seccomp']}",
                   int(fields["CapEff"], 16) == 0 and int(fields["CapPrm"], 16) == 0)
        # The rendered list for one role, written into the evidence so that the page can
        # show what this run actually passed rather than only the code that builds it.
        # The two file descriptors and the action are appended by sandbox.run(), and
        # their numbers change from call to call, so they are not in this list.
        self.arguments = command(self.root / "reader")

        self.controller = {
            "uid": os.getuid(), "gid": os.getgid(),
            "status": {name: fields[name] for name in
                       ("CapPrm", "CapEff", "CapBnd", "CapAmb", "NoNewPrivs", "Seccomp")
                       if name in fields},
            "hostname": socket.gethostname(),
            "namespaces": {kind: os.readlink(f"/proc/self/ns/{kind}")
                           for kind in (*NAMESPACES, "mnt", "cgroup")},
            "max_user_namespaces": limit,
        }

    def child_identity(self):
        """What bubblewrap made of the tool process, measured against the controller."""
        child = self.call("reader", "inspect")
        self.child = child
        fields = child["status"]

        self.check("the tool process runs as UID/GID 1000, mapped alone in its own user "
                   f"namespace: uid_map {' '.join(child['uid_map'])}",
                   child["uid"] == 1000 and child["gid"] == 1000)
        # All five sets, because "no capabilities at all" is a statement about all of
        # them. An empty bounding set says what the process may *acquire* across an exec
        # and nothing about what it holds now, so reading one off the other would leave
        # the page's wording broader than the check.
        self.check("the tool process has no capabilities at all: "
                   + ", ".join(f"{name} {fields[name]}" for name in CAPABILITY_SETS)
                   + " are all empty",
                   no_capabilities(fields))
        self.check("the tool process cannot gain privilege through exec: NoNewPrivs is "
                   f"{fields['NoNewPrivs']}", fields["NoNewPrivs"] == "1")
        self.check("the tool process runs under one seccomp filter, the baseline this "
                   f"application compiled: Seccomp mode {fields['Seccomp']}, "
                   f"Seccomp_filters {fields['Seccomp_filters']}",
                   fields["Seccomp"] == "2" and fields["Seccomp_filters"] == "1")

        # Every namespace the launcher claims, plus the mount namespace bwrap always
        # makes. A namespace it shared with the controller would read the same inode.
        for kind in (*NAMESPACES, "mnt"):
            self.check(f"the tool process has its own {kind} namespace",
                       child["namespaces"][kind]
                       != self.controller["namespaces"][kind])
        self.check(f"the tool process has its own hostname, {child['hostname']}",
                   child["hostname"] == HOSTNAME
                   and self.controller["hostname"] != HOSTNAME)
        # The mount list itself, because "the tool cannot read the credentials" is first
        # of all a statement about what was mounted. The ENOENT refusals in
        # file_boundary() confirm it at runtime; this is the list the launcher built.
        secret_prefixes = sorted({
            str(Path(SUPPLIER_KEY_FILE).parent),
            str(Path(os.environ["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"]).parent),
            # The whole projected-volume root, so a token path that moves inside it is
            # still covered by this check.
            "/var/run/secrets",
        })
        inside = [mount for mount in child["mounts"]
                  if any(mount == prefix or mount.startswith(prefix + "/")
                         for prefix in secret_prefixes)]
        self.check(f"the tool process's whole mount list is {child['mounts']}, and none "
                   f"of {secret_prefixes} is in it", not inside)
        self.check("the tool process's whole environment is "
                   f"{child['environment']}",
                   child["environment"] == EXPECTED_CHILD_ENV)
        # The line above already pins the environment exactly, so this one cannot fail on
        # its own. It is here because it names what matters about that list: the
        # controller's AWS credentials and Region do not reach the tool, and no model key
        # does either. --clearenv is what removes them.
        self.check("so the tool process holds no AWS variable and no model API key",
                   not [name for name in child["environment"]
                        if name.startswith("AWS_") or name.endswith("_API_KEY")])

    def read_the_case(self, s3):
        case = json.loads(s3.get_object(Bucket=BUCKET,
                                        Key=f"proposals/{CASE}/case.json")["Body"].read())
        for supplier in case["suppliers"]:
            original = json.loads(s3.get_object(Bucket=BUCKET,
                                                Key=supplier["source"])["Body"].read())
            self.check(f"the S3 proposal matches the case entry for {supplier['id']}",
                       proposal_matches_case(original, supplier))
        # The same three proposals are in the image, so a reader can tell whether the run
        # used the objects it cites or a baked-in copy.
        self.check("the image's fixtures match the objects in S3",
                   load_json(FIXTURES / "case.json") == case)
        return case

    def s3_refusals(self, s3, case):
        for name, operation, key in (
            ("overwriting a source proposal", "put_object", f"proposals/{CASE}/case.json"),
            ("deleting a source proposal", "delete_object", f"proposals/{CASE}/case.json"),
            ("reading another case's object", "get_object", "proposals/rfp-other/case.json"),
        ):
            params = {"Bucket": BUCKET, "Key": key}
            if operation == "put_object":
                params["Body"] = json.dumps(case).encode()
            try:
                getattr(s3, operation)(**params)
                code = "allowed"
            except ClientError as error:
                code = error.response["Error"]["Code"]
            self.check(f"IAM returns AccessDenied for {name}", code == "AccessDenied")

    def file_boundary(self, case):
        """The read and write boundary, each direction, each refusal with its control."""
        case_path = self.root / "reader/in/case.json"
        case_path.write_text(json.dumps(case))
        # The controller's own identity for that file, from an open descriptor, so the
        # comparison below is between two fstat readings of a file each side has open
        # rather than between two path lookups.
        with case_path.open("rb") as handle:
            identity = os.fstat(handle.fileno())

        # Accept, and real work: the shared worker reads the case it was assigned.
        self.check("the reader reads its assigned case at /input/case.json",
                   self.call("reader", "read", "/input/case.json") == case)
        # Accept for the probe the refusals below use, so the probe itself is proved both
        # ways rather than only on the inputs it has to refuse.
        opened = self.call("reader", "read-file", "/input/case.json")
        self.check("the reader's own read probe opens the same file",
                   json.loads(opened["text"]) == case)
        # Device and inode, not the inode alone: an inode number is unique only within
        # one filesystem, so two equal inode numbers on different devices are different
        # files and would have satisfied the earlier version of this check.
        self.check("and /input/case.json is the controller's own file, device "
                   f"{opened['device']} inode {opened['inode']}",
                   same_file(opened, identity))

        # The control for EROFS: the same file, the same inode, the same UID, written by
        # the controller without changing a byte of it.
        before = hashlib.sha256(case_path.read_bytes()).hexdigest()
        try:
            with case_path.open("a"):
                pass
            permitted = True
        except OSError:
            permitted = False
        self.check("the controller may write that same file at the same UID, and left it "
                   "unchanged", permitted
                   and hashlib.sha256(case_path.read_bytes()).hexdigest() == before)
        refusal = self.call("reader", "write-file", "/input/case.json", "changed")
        self.check("so the reader's write is refused by the read-only bind mount, not by "
                   f"a file mode: {refusal.get('error')}",
                   self.refused(refusal, errno.EROFS))

        # ENOENT for paths nobody mounted: a sibling role's private file, and the two
        # credential files the controller itself reads. Each with the controller opening
        # it in the same run, at the same UID.
        sibling = self.root / "writer/in/private.json"
        sibling.write_text('{"private":"writer-only","canary":"not for the reader"}')
        for label, path in (("the writer's private file", str(sibling)),
                            ("the supplier key file", SUPPLIER_KEY_FILE),
                            ("the Pod Identity token file",
                             os.environ["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"])):
            # The control. Nothing is printed or kept: the open and one byte are all that
            # is needed to show the path is there and this UID may read it.
            with open(path, "rb") as handle:
                present = len(handle.read(1)) == 1
            self.check(f"the controller opens {label} at the same UID", present)
            refusal = self.call("reader", "read-file", path)
            self.check(f"so {label} is absent from the reader's mount list, not merely "
                       f"unreadable: {refusal.get('error')}",
                       self.refused(refusal, errno.ENOENT))

        # Accept for the write grant, and the controller reading back what was written.
        written = self.call("writer", "write-file", "/output/draft.txt", "draft")
        self.check("the writer writes its own output directory",
                   written.get("written") == "/output/draft.txt")
        self.check("and the controller reads back what the writer wrote",
                   (self.root / "writer/out/draft.txt").read_text() == "draft")

    def process_boundary(self):
        """A further user namespace, and the application's own seccomp filters."""
        allowed = self.call("reader", "unshare", disable_userns=False)
        self.check("a further user namespace succeeds in a child started without "
                   "--disable-userns", allowed.get("created") is True)
        refusal = self.call("reader", "unshare")
        self.check("so --disable-userns is what refuses a further user namespace: "
                   f"{refusal.get('error')}",
                   refusal.get("errno") in USERNS_DENIALS)

        numbers = {name: syscall_number(name) for name in STACKED}
        for name, number in numbers.items():
            called = self.call("reader", "syscall", number)
            self.check(f"{name} succeeds under the baseline filter alone",
                       called.get("called") == number)

        with compiled_filter([STACKED[0]]) as first, compiled_filter([STACKED[1]]) as second:
            extra = ["--add-seccomp-fd", str(first.fileno()),
                     "--add-seccomp-fd", str(second.fileno())]
            fds = [first.fileno(), second.fileno()]
            # Each filter is read from its descriptor by bwrap, so rewind both before
            # every call that reuses them.
            for handle in (first, second):
                handle.seek(0)
            # The status probe and not inspect: inspect reads the hostname, which is
            # uname(), and uname is one of the two calls these filters block.
            stacked = self.call("reader", "status", extra=extra, fds=fds)
            self.check("three seccomp filters are loaded in the child: the baseline and "
                       f"the two this run added, Seccomp_filters "
                       f"{stacked['status']['Seccomp_filters']}",
                       stacked["status"]["Seccomp_filters"] == "3")
            for name, number in numbers.items():
                for handle in (first, second):
                    handle.seek(0)
                refusal = self.call("reader", "syscall", number, extra=extra, fds=fds)
                self.check(f"and with both added, {name} returns "
                           f"{refusal.get('error')}",
                           self.refused(refusal, errno.EPERM))

    def network_boundary(self):
        """No route for any tool process, and the same address reached by the controller.

        All three roles, not one. The launcher builds the same namespace list for each of
        them, so one reading would be a fair inference, but the page and its figure say
        "a tool process" rather than "the reader", and a claim about three processes is
        worth measuring three times rather than inferring from shared code.
        """
        address = urlsplit(API)
        ip = socket.gethostbyname(address.hostname)
        with socket.create_connection((ip, address.port), timeout=10):
            reachable = True
        self.check("the controller reaches the supplier API's own address and port",
                   reachable)
        for role in ROLES:
            child = self.child if role == "reader" else self.call(role, "inspect")
            self.check(f"the {role}'s interface list is loopback alone: "
                       f"{child['interfaces']}", child["interfaces"] == ["lo"])
            refusal = self.call(role, "connect-to", ip, address.port)
            self.check(f"so the {role} has no route to that same address: "
                       f"{refusal.get('error')}",
                       self.refused(refusal, errno.ENETUNREACH))

    def supplier_calls(self):
        """Every supplier call in this sample is the controller's own."""
        reply = self.supplier("GET", f"/cases/{CASE}/suppliers", "suppliers")
        self.check("the supplier API answers the controller's authenticated read with "
                   "200", reply["status"] == 200)
        self.check("the supplier API refuses an invalid key with 401",
                   self.supplier("GET", f"/cases/{CASE}/suppliers", "badkey",
                                 key="not-the-key")["status"] == 401)
        return availability_from_reply(reply["body"])

    def do_the_work(self, case, availability):
        facts = self.root / "evaluator/in/facts.json"
        facts.write_text(json.dumps({"case": case, "availability": availability}))
        comparison = self.call("evaluator", "evaluate", "/input/facts.json")
        self.check("the offline comparison names the one supplier that meets every "
                   "requirement", comparison["recommended_supplier"] == "northstar")
        self.check("the controller's own comparison agrees with the evaluator's",
                   compare(case, availability) == comparison)

        staged = self.root / "writer/in/comparison.json"
        staged.write_text(json.dumps(comparison))
        written = self.call("writer", "write", "/output/comparison.json",
                            "/input/comparison.json")
        self.check("the writer saves the comparison in its own output directory",
                   written.get("written") == "/output/comparison.json")
        draft = json.loads((self.root / "writer/out/comparison.json").read_text())
        self.check("the controller submits the writer's draft, which the supplier API "
                   "accepts with 201",
                   self.supplier("POST", f"/cases/{CASE}/recommendations", "draft",
                                 body=draft)["status"] == 201)
        return comparison

    def model_turn(self, case, comparison):
        turn = ModelTurn(case, comparison)
        payload = turn.run()
        self.check("the model called the evidence tool", turn.tool_calls > 0)
        self.check("Bedrock returned a real turn with nonzero token usage",
                   turn.usage.get("totalTokens", 0) > 0)
        self.check("the model's own choice matches the verified comparison",
                   report_choice_matches(payload, comparison["recommended_supplier"]))
        self.check("the model's analysis cites all three proposals",
                   report_cites_sources(payload, case))

        # The same two gates, on answers they must reject. Both run the functions the
        # run itself uses, not a copy of them.
        wrong_choice = {**payload, "recommended_supplier": "harbor"}
        self.check("the choice gate rejects an answer naming an ineligible supplier",
                   not report_choice_matches(wrong_choice,
                                             comparison["recommended_supplier"]))
        named_only_in_prose = {**payload, "recommended_supplier": ""}
        self.check("the choice gate rejects an answer that names the supplier only in "
                   "its prose",
                   not report_choice_matches(named_only_in_prose,
                                             comparison["recommended_supplier"]))
        dropped_citation = {**payload,
                            "analysis_markdown": payload["analysis_markdown"].replace(
                                case["suppliers"][1]["source"], "a supplier proposal")}
        self.check("the citation gate rejects an answer missing one source key",
                   not report_cites_sources(dropped_citation, case))

        self.usage = turn.usage
        return payload

    def save(self, s3, case, comparison, payload):
        report = render_report(payload, case)
        prefix = f"reports/{CASE}/{self.id}"
        for name, body in (("recommendation.md", report),
                           ("comparison.json", json.dumps(comparison, indent=2))):
            s3.put_object(Bucket=BUCKET, Key=f"{prefix}/{name}", Body=body.encode())
            stored = s3.get_object(Bucket=BUCKET,
                                   Key=f"{prefix}/{name}")["Body"].read().decode()
            self.check(f"the report object round-trips through S3: {name}", stored == body)
        (self.root / "recommendation.md").write_text(report)

        evidence = {
            "run_id": self.id, "case_id": CASE, "aws_arn": self.arn,
            "credential_provider": "container-role",
            "model_id": os.environ["BEDROCK_MODEL_ID"], "model_usage": self.usage,
            "bubblewrap": self.pin, "seccomp_baseline": list(BASELINE),
            "bwrap_argument_list": self.arguments,
            "controller": self.controller, "child": self.child,
            "report_prefix": prefix, "comparison": comparison,
            "report_choice": payload["recommended_supplier"],
            "supplier_requests": self.supplier_requests,
            "checks": self.checks, "calls": self.calls,
        }
        serialised = json.dumps(evidence, indent=2)
        secret = Path(SUPPLIER_KEY_FILE).read_text().strip()
        # Enforced by raising, not by recording a flag computed from the key's contents.
        # Reaching the line after the raise IS the result, so that is what gets recorded.
        #
        # This one runs before the write, so the two documents that leave the pod are
        # never written at all if the key is in them. Note what it already covers:
        # self.checks is inside evidence, and self.checks holds every check name this run
        # printed, so scanning it scans every check line that went to standard output.
        if secret in serialised + report:
            raise AssertionError(
                "the supplier key appears in the evidence or the report; nothing written")
        self.check("the evidence and the report were scanned for the supplier key before "
                   "being written, and the run was stopped if it appeared", True)
        (self.root / "evidence.json").write_text(serialised)
        (self.root / "checks.json").write_text(json.dumps(self.checks, indent=2))

        # And then the whole of the run's own directory, on disk. The scan above can only
        # see what the controller holds in memory, and the run writes more than that: the
        # facts staged for the evaluator, the comparison staged for the writer, each
        # role's output, and the record of every call. Those are the files run.sh copies
        # out of the pod beside the two above.
        holding = files_holding(self.root, secret)
        if holding:
            raise AssertionError(
                f"the supplier key appears in {holding}, under this run's directory")
        written = sum(1 for path in self.root.rglob("*") if path.is_file())
        self.check(f"and every one of the {written} files this run wrote was scanned on "
                   "disk too, including the facts staged between roles and the record of "
                   "every call", True)
        print(f"\nANALYST_COMPLETE={self.id}", flush=True)
        print(f"{len(self.checks)} checks passed", flush=True)
        print(f"  bubblewrap {self.pin['pinned_version']}, source commit "
              f"{self.pin['source_commit']}", flush=True)
        print(f"  model usage: {self.usage.get('totalTokens')} tokens on "
              f"{os.environ['BEDROCK_MODEL_ID']}", flush=True)

    def execute(self):
        # The layer first, because it is what the rest depends on: a guest that cannot
        # start a bubblewrap child should fail here rather than after a page of AWS
        # checks that would have passed anywhere.
        self.the_layer()
        self.child_identity()
        session = self.aws_identity()
        s3 = session.client("s3", config=S3_CONFIG)
        case = self.read_the_case(s3)
        self.s3_refusals(s3, case)
        self.file_boundary(case)
        self.process_boundary()
        self.network_boundary()
        availability = self.supplier_calls()
        comparison = self.do_the_work(case, availability)
        payload = self.model_turn(case, comparison)
        self.save(s3, case, comparison, payload)


if __name__ == "__main__":
    run_ = Run()
    try:
        run_.execute()
    finally:
        (run_.root / "checks.json").write_text(json.dumps(run_.checks, indent=2))
