"""The trusted controller: it owns AWS, and nono owns the tool roles.

It runs inside the Nitro sandbox, as the pod's only long-lived process. Two boundaries
matter and the page keeps them apart:

  * The Nitro sandbox is the hardware-level isolation around this whole pod. Everything
    below, including the supplier key and nono's proxy, is inside it.
  * nono is the boundary inside the pod, between this controller and the reader, evaluator
    and writer it launches. Those are processes under a per-role profile, not pods, and
    not three independent model sessions.

What this controller does, in order: read the case and the three proposals from Amazon S3
with the pod's EKS Pod Identity role, show what that role is refused, run the tool roles
under nono and record what each is allowed and refused, ask Amazon Bedrock to explain the
verified comparison, check the answer against that comparison, and save the accepted
recommendation back to S3.

Every check is recorded with the result it asked for, and the run fails on the first one
that does not hold. A check is proved both ways wherever the sample can produce both
inputs: the reader reads its own case and is refused a sibling's file, the evaluator is
refused a socket while the reader gets one, the approved hostname answers while a second
name for the same server is refused, and so on. Where the refusal is the supplier API's
own doing rather than nono's, a trusted request on the same path with the same key shows
the server would have accepted it.
"""
import errno
import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlsplit

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# Path-style addressing, so every S3 request goes to the Region's own endpoint rather than
# to <bucket>.s3.<Region>.amazonaws.com. The egress network policy names hosts, and a
# bucket-specific name would be a different host for every reader's bucket.
S3_CONFIG = Config(s3={"addressing_style": "path"})

sys.path.insert(0, "/opt/analyst")
sys.path.insert(0, "/opt/nono")

from business import (CASE, FIXTURES, availability_from_reply, load_json,  # noqa: E402
                      proposal_matches_case, compare, render_report,
                      report_choice_matches, report_cites_sources)
from analyst_agent import ModelTurn  # noqa: E402
from policies import (CA, CODE, ROLES, SECRET, check_committed,  # noqa: E402
                      committed_for, dump, profile)
from worker import MARKER  # noqa: E402

ROOT = Path("/var/lib/analyst")
COMMITTED_PROFILES = Path("/opt/nono/policies")

API = os.environ["SUPPLIER_API_URL"]
ALIAS_API = os.environ["SUPPLIER_API_ALIAS_URL"]
BUCKET = os.environ["ANALYST_BUCKET"]
REGION = os.environ["AWS_REGION"]
ROLE_NAME = os.environ["ANALYST_ROLE_NAME"]

# Variables that would mean a model API key had been put in the sandbox. Bedrock is
# reached with Pod Identity credentials, so none of these should exist.
MODEL_KEY_VARS = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "BEDROCK_API_KEY",
                  "AWS_BEARER_TOKEN_BEDROCK")

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def refused(result) -> bool:
    """True when a role reported a refusal, rather than a failure or a success."""
    return result.get("denied_errno") in (errno.EACCES, errno.EPERM)


def trusted_request(path, method, request_id, key=None, base_url=API):
    """Call the supplier API from the controller, outside the nono role boundary.

    This is the control that makes a refusal attributable. The controller may read the
    real key file, so a request it makes carries the real credential: when the same
    method and path succeeds here and is refused inside a role, the refusal is nono's and
    not the server's.
    """
    if key is None:
        key = Path(SECRET).read_text().strip()
    data = None if method == "GET" else b'{"control":true}'
    req = urllib.request.Request(
        base_url + path, data=data,
        headers={"X-Api-Key": key, "X-Analyst-Request-ID": request_id,
                 **({"Content-Type": "application/json"} if data else {})},
        method=method)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=CA)))
    try:
        with opener.open(req, timeout=10) as response:
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
        for role in ("reader", "evaluator", "writer"):
            for directory in ("in", "out"):
                (self.root / role / directory).mkdir(parents=True)
        # The profiles and nono's audit data live here, outside every role's write grant.
        (self.root / "broker").mkdir(mode=0o700)

    # -- recording ---------------------------------------------------------

    def check(self, name, condition):
        passed = bool(condition)
        self.checks.append({"name": name, "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} {name}", flush=True)
        if not passed:
            raise AssertionError(name)

    # -- launching a tool role --------------------------------------------

    def call(self, role, action, *args):
        """Run one action in one role, under that role's nono profile."""
        call_id = f"{self.id}-{len(self.calls):02d}"
        broker = self.root / "broker" / call_id
        broker.mkdir(parents=True, mode=0o700)
        policy_path = broker / "profile.json"
        policy_path.write_text(json.dumps(profile(role, self.root / role, API)))
        # A small environment, built here rather than inherited: the controller's own AWS
        # variables are not passed in. HOME points into the broker directory so nono's
        # own state for this call stays outside every role's write grant.
        env = {"PATH": os.environ["PATH"], "HOME": str(broker), "LANG": "C.UTF-8",
               "PYTHONPATH": CODE, "PYTHONDONTWRITEBYTECODE": "1",
               "NONO_NO_SAVE_PROMPT": "1", "NONO_NO_MIGRATE": "1"}
        command = ["python3", "/opt/nono/ptyrun.py",
                   "nono", "-s", "run", "--no-rollback", "--profile", str(policy_path),
                   "--", "python3", f"{CODE}/worker.py", action, *map(str, args)]
        completed = subprocess.run(command, env=env, cwd=self.root / role,
                                   capture_output=True, text=True, timeout=120)
        output = ANSI.sub("", completed.stdout).replace("\r", "")
        results = [line.removeprefix(MARKER) for line in output.splitlines()
                   if line.startswith(MARKER)]
        # Only the tool's own structured result counts. A nono startup failure, a timeout
        # or a crash leaves no result line and fails the run; it is never a denial.
        if completed.returncode != 0 or len(results) != 1:
            raise AssertionError(
                f"{role}/{action} did not produce one result (exit {completed.returncode}): "
                f"{output[-1800:]}{completed.stderr[-600:]}")
        result = json.loads(results[0])
        sessions = sorted((broker / ".local/state/nono/audit").glob("*/session.json"))
        if len(sessions) != 1:
            raise AssertionError(f"expected one nono audit session for {call_id}, "
                                 f"found {len(sessions)}")
        audit = load_json(sessions[0])
        entry = {"call_id": call_id, "role": role, "action": action, "result": result,
                 "session_id": sessions[0].parent.name,
                 "network_events": audit.get("network_events", [])}
        self.calls.append(entry)
        (self.root / "calls.json").write_text(json.dumps(self.calls, indent=2))
        return result, entry

    def api(self, role, method, path, expected, body_file=None, bypass_proxy=False):
        """Send one supplier request from a role and check the outcome and the audit."""
        request_id = f"{self.id}-{len(self.calls):02d}"
        option = ["bypass-proxy"] if bypass_proxy else ([str(body_file)] if body_file else [])
        base_url = API
        if bypass_proxy:
            # Address the server directly, by its own IP, so the probe is "can the role
            # leave the process at all" and not "can it resolve a name". The connection
            # is confirmed reachable from the controller first.
            address = urlsplit(API)
            ip = socket.gethostbyname(address.hostname)
            with socket.create_connection((ip, address.port), timeout=10):
                pass
            base_url = f"https://{ip}:{address.port}"
        result, entry = self.call(role, "api", base_url + path, method, request_id, *option)
        entry.update({"request_id": request_id, "method": method, "path": path,
                      "expected_status": expected})
        if bypass_proxy:
            self.check(f"{role}: a direct connection to the supplier API is refused",
                       refused(result))
            return result
        self.check(f"{role}: {method} {path} returns {expected}",
                   result.get("status") == expected)
        matching = [e for e in entry["network_events"]
                    if e.get("method") == method and e.get("path") == path]
        self.check(f"the nono audit records {method} {path}", bool(matching))
        decision = "deny" if expected == 403 else "allow"
        self.check(f"the nono audit decision is {decision}",
                   any(e.get("decision") == decision for e in matching))
        return result

    def control(self, method, path, base_url=API, label=None):
        """Show the supplier API accepts an operation a role was refused."""
        request_id = f"{self.id}-control-{len(self.calls)}"
        status = trusted_request(path, method, request_id, base_url=base_url)["status"]
        self.check(label or f"the supplier API accepts {method} {path} with the real key, "
                            "outside the role boundary", status == 200)
        self.calls.append({"request_id": request_id, "control": True, "method": method,
                           "path": path, "expected_status": 200})

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

    def profiles_are_the_committed_ones(self):
        """What the page shows is what this run enforces.

        Two checks. The committed profiles are what the generator produces, and the
        profile this run hands each role is the committed one with this namespace and
        this run id substituted in. A third runs the same check on an altered copy,
        because a check run only on the good input cannot be told apart from one that
        accepts anything.
        """
        self.check("the profiles in policies/ are what the generator produces",
                   check_committed(COMMITTED_PROFILES) == [])

        namespace = urlsplit(API).hostname.split(".")[1]
        for role in ROLES:
            generated = profile(role, self.root / role, API)
            self.check(f"the {role} profile this run uses is the committed one",
                       generated == committed_for(COMMITTED_PROFILES, role,
                                                  namespace, self.id))

        altered = self.root / "altered-profiles"
        dump(altered)
        broken = json.loads((altered / "evaluator.json").read_text())
        broken["network"] = {"block": False}
        (altered / "evaluator.json").write_text(json.dumps(broken, indent=2) + "\n")
        self.check("the same check reports an altered profile",
                   check_committed(altered) == ["evaluator"])

    def file_boundary(self, case):
        case_path = self.root / "reader/in/case.json"
        case_path.write_text(json.dumps(case))
        read, _ = self.call("reader", "read", case_path)
        self.check("the reader reads its assigned proposal", read == case)

        result, _ = self.call("reader", "write", case_path, case_path)
        self.check("the reader cannot overwrite its read-only input", refused(result))

        sibling = self.root / "writer/in/private.json"
        sibling.write_text('{"private":"writer-only","canary":"not for the reader"}')
        result, _ = self.call("reader", "read", sibling)
        self.check("the reader cannot read the writer's private file", refused(result))

        for label, path in (("the supplier key file", SECRET),
                            ("the Pod Identity token file",
                             os.environ["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"])):
            result, _ = self.call("reader", "read", path)
            self.check(f"the reader cannot open {label}", refused(result))

        # The writer writes its own output: the accept case for the write grant.
        destination = self.root / "writer/out/echo.json"
        result, _ = self.call("writer", "write", destination, sibling)
        self.check("the writer writes its own output directory",
                   result.get("written") == str(destination) and destination.exists())

    def credential_boundary(self):
        real = Path(SECRET).read_text().strip()
        result, _ = self.call("reader", "credential-env")
        self.check("the reader holds a supplier credential", result["api_key_present"])
        self.check("the reader's credential is not the real supplier key",
                   result["api_key_sha256"] != hashlib.sha256(real.encode()).hexdigest())
        # nono sets AWS_CA_BUNDLE so an AWS SDK inside a role would trust its proxy's
        # certificate. That is not a credential, so the check names the variables that
        # would authenticate and reports the rest rather than claiming there are none.
        self.check("the reader has no AWS credential variable; its AWS environment is "
                   f"{result['aws_names']}", result["aws_credential_names"] == [])
        self.check("the reader has no model API key", result["model_key_names"] == [])
        self.placeholder_length = result["api_key_length"]
        self.real_length = len(real)

        result, _ = self.call("reader", "connect", "169.254.170.23", "80")
        self.check("the reader cannot reach the Pod Identity endpoint directly",
                   refused(result))

        self.check("the supplier API refuses an invalid key with 401",
                   trusted_request(f"/cases/{CASE}/suppliers", "GET",
                                   self.id + "-badkey", key="not-the-key")["status"] == 401)

    def network_boundary(self):
        result, _ = self.call("reader", "socket")
        self.check("the online reader creates an Internet socket",
                   result.get("socket_created") is True)
        result, _ = self.call("evaluator", "socket")
        self.check("the offline evaluator cannot create an Internet socket", refused(result))

        # The reply is an envelope naming the case; the comparison takes the inner map.
        # availability_from_reply raises if that map is missing, because passing the
        # envelope in whole would mark every supplier unavailable and name no winner.
        availability = availability_from_reply(
            self.api("reader", "GET", f"/cases/{CASE}/suppliers", 200)["body"])
        self.api("reader", "GET", f"/cases/{CASE}/suppliers", None, bypass_proxy=True)

        # A second DNS name for the very same server. The refusal is the hostname
        # decision, not a broken route: the control below reaches it with the same key.
        request_id = self.id + "-alias"
        result, entry = self.call("reader", "api",
                                  ALIAS_API + f"/cases/{CASE}/suppliers", "GET", request_id)
        entry.update({"request_id": request_id, "method": "GET",
                      "path": f"/cases/{CASE}/suppliers", "expected_status": 403})
        self.check("a second DNS name for the same server is refused",
                   result.get("status") == 403)
        alias_host = urlsplit(ALIAS_API).hostname
        self.check("the nono audit records the refused host",
                   any(e.get("decision") == "deny" and e.get("target") == alias_host
                       for e in entry["network_events"]))
        self.control("GET", f"/cases/{CASE}/suppliers", base_url=ALIAS_API,
                     label="the same server answers on that second name, with the same key, "
                           "outside the role boundary")

        # The reader may read; only the writer may submit a draft.
        self.api("reader", "POST", f"/cases/{CASE}/recommendations", 403)
        for method, path in (("PATCH", "/suppliers/northstar"),
                             ("POST", "/purchase-orders"),
                             ("GET", "/cases/rfp-other/suppliers")):
            self.api("writer", method, path, 403)
            self.control(method, path)
        return availability

    def do_the_work(self, case, availability):
        facts = self.root / "evaluator/in/facts.json"
        facts.write_text(json.dumps({"case": case, "availability": availability}))
        comparison, _ = self.call("evaluator", "evaluate", facts)
        self.check("the offline comparison names the one supplier that meets every "
                   "requirement", comparison["recommended_supplier"] == "northstar")
        self.check("the controller's own comparison agrees with the evaluator's",
                   compare(case, availability) == comparison)

        staged = self.root / "writer/in/comparison.json"
        staged.write_text(json.dumps(comparison))
        written = self.root / "writer/out/comparison.json"
        result, _ = self.call("writer", "write", written, staged)
        self.check("the writer saves the comparison in its own output directory",
                   result.get("written") == str(written))
        self.api("writer", "POST", f"/cases/{CASE}/recommendations", 201, body_file=staged)
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
        named_only_in_prose = {**payload, "recommended_supplier": "",
                               "analysis_markdown": payload["analysis_markdown"]}
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
            "credential_provider": "container-role", "model_id": os.environ["BEDROCK_MODEL_ID"],
            "model_usage": self.usage, "report_prefix": prefix,
            "supplier_credential": {"real_key_length": self.real_length,
                                    "role_placeholder_length": self.placeholder_length},
            "comparison": comparison, "report_choice": payload["recommended_supplier"],
            "checks": self.checks, "calls": self.calls,
        }
        serialised = json.dumps(evidence, indent=2)
        self.check("no supplier key appears in the evidence or the report",
                   Path(SECRET).read_text().strip() not in serialised + report)
        (self.root / "evidence.json").write_text(serialised)
        (ROOT / "latest").write_text(self.id)
        print(f"\nANALYST_COMPLETE={self.id}", flush=True)
        print(f"{len(self.checks)} checks passed", flush=True)

    def execute(self):
        session = self.aws_identity()
        s3 = session.client("s3", config=S3_CONFIG)
        case = self.read_the_case(s3)
        self.s3_refusals(s3, case)
        self.profiles_are_the_committed_ones()
        self.file_boundary(case)
        self.credential_boundary()
        availability = self.network_boundary()
        comparison = self.do_the_work(case, availability)
        payload = self.model_turn(case, comparison)
        self.save(s3, case, comparison, payload)


if __name__ == "__main__":
    run = Run()
    try:
        run.execute()
    finally:
        (run.root / "checks.json").write_text(json.dumps(run.checks, indent=2))
