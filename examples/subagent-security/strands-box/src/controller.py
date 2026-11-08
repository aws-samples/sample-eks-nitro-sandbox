"""Run shared procurement work with Box roles and a synthetic HTTP supplier.

--local exercises real Box processes and HTTP supplier calls using shared fixtures.
It does not invoke AWS or a model. The default mode adds Pod Identity, S3 and the
unchanged Strands model turn. Neither mode is proof of a Nitro runtime boundary.
"""
import argparse
import hashlib
import json
import strict_json
import os
from pathlib import Path
import platform
import shutil
import socket
import sys
import tempfile
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import uuid

from box_roles import ROLES, execute, prepare
from decision_records import batch_identity, decisions, match
from worker_adapter import access_refused, native_refused, http_result, supplier_reply


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Run:
    def __init__(self, args):
        if os.getuid() == 0:
            raise RuntimeError("Run the controller as a non-root user")
        self.args = args
        self.id = uuid.uuid4().hex
        self.root = args.output_root.resolve() / self.id
        self.root.mkdir(parents=True, mode=0o700)
        # Unix-domain socket paths have a platform length limit. Keep only Box
        # state here; copy each decision log into the durable run directory.
        self.state_root = Path(tempfile.mkdtemp(prefix="bx-", dir="/var/tmp"))
        self.code = args.shared_analyst.resolve(strict=True)
        sys.path.insert(0, str(self.code))
        import business
        self.business = business
        self.fixture_dir = self.code / "fixtures" if (self.code / "fixtures").is_dir() else self.code.parent / "fixtures"
        self.calls, self.checks, self.box_ids = [], [], []
        self.supplier_url = args.supplier_url.rstrip("/")
        self.supplier_alias_url = args.supplier_alias_url.rstrip("/")
        origins = []
        for url in (self.supplier_url, self.supplier_alias_url):
            parsed = urlsplit(url)
            if (parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password
                    or parsed.path or parsed.query or parsed.fragment or not parsed.port):
                raise ValueError("The synthetic supplier needs a plain HTTP origin with an explicit port")
            origins.append({"scheme": "http", "host": parsed.hostname, "port": parsed.port})
        self.supplier_origin, self.supplier_alias_origin = origins
        if self.supplier_origin == self.supplier_alias_origin:
            raise ValueError("The alias control must use a different hostname")
        self.complete = False
        self.comparison = None
        self.model_usage = None
        self.report = None
        for role in ROLES:
            for directory in ("in", "out"):
                (self.root / role / directory).mkdir(parents=True)

    def check(self, name, condition):
        self.checks.append({"name": name, "passed": bool(condition)})
        print(("PASS " if condition else "FAIL ") + name, flush=True)
        if not condition:
            raise AssertionError(name)

    def dump(self, name, value):
        (self.root / name).write_text(json.dumps(value, indent=2) + "\n")

    def request(self, name, method, path, status, *, body_file=None, action="http:request", rule=None, base_url=None):
        request_id = self.id + "-" + name
        url = (base_url or self.supplier_url) + path
        address = urlsplit(url)
        args = [url, method, request_id]
        if body_file:
            args.append(str(body_file))
        return {"name": name, "action": "api", "args": args,
                "request_id": request_id, "method": method, "path": path,
                "expected_status": status, "decision_action": action, "rule": rule,
                "host": address.hostname, "port": address.port or (443 if address.scheme == "https" else 80)}

    def batch(self, role, plan, label=None):
        label = label or role
        credential_probes = [
            {"name": "credential_names", "action": "credential-names", "args": [], "expected": "credentials_absent"},
        ]
        token_file = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")
        if not self.args.local and token_file:
            credential_probes.append({"name": "pod_identity_token", "action": "readable", "args": [str(Path(token_file).resolve())], "expected": "file_refused"})
        for name, host, port in self.native_targets:
            credential_probes.append({"name": name, "action": "connect", "args": [host, str(port)], "expected": "native_unreachable"})
        port = self.supplier_origin["port"]
        common_network = [
            self.request(label + "-alias", "GET", "/cases/rfp-001/suppliers", 403,
                         action="net:connect", base_url=self.supplier_alias_url),
            self.request(label + "-unknown", "GET", "/cases/rfp-001/suppliers", 403,
                         action="net:connect", base_url="http://not-approved.invalid:" + str(port)),
        ]
        plan = credential_probes + plan + common_network
        broker = self.root / "broker" / label
        state = self.state_root / label / "state"
        state.parent.mkdir()
        config = prepare(role, self.root / role, broker, self.code, sys.executable,
                         Path(__file__).with_name("worker_adapter.py"),
                         supplier_host=self.supplier_origin["host"],
                         supplier_port=self.supplier_origin["port"], state=state)
        (self.root / role / "in/probes.json").write_text(json.dumps(plan))
        rows = execute(self.args.box_binary, config)
        self.check(label + ": one result for every requested operation",
                   [row["name"] for row in rows] == [item["name"] for item in plan])
        source = state / "private/telemetry/records.jsonl"
        log = broker / "box-records.jsonl"
        shutil.copyfile(source, log)
        events = decisions(log)
        expected_box_id, expected_run_id = batch_identity(events, state, "analyst-" + role, broker / "policy.dw")
        self.check(label + ": all decisions belong to the configured Box and one run", True)
        self.dump(str(Path("broker") / label / "box-identity.json"),
                  {"box_id": expected_box_id, "box_run_id": expected_run_id,
                   "committed_record_sha256": sha256(state / "private/box.toml")})
        seen_decisions = []
        results = {}
        for item, row in zip(plan, rows):
            result = row["result"]
            results[item["name"]] = result
            entry = {"call_id": self.id + "-" + label + "-" + item["name"],
                     "role": role, "action": item["action"], "result": result,
                     "started_ns": row["started_ns"], "ended_ns": row["ended_ns"],
                     "config_sha256": sha256(config), "policy_sha256": sha256(broker / "policy.dw"),
                     "box_id": expected_box_id, "box_run_id": expected_run_id}
            self.calls.append(entry)
            if item.get("expected") == "credentials_absent":
                self.check(label + ": no AWS or model credential in the worker environment",
                           not result["aws_credential_names"] and not result["model_key_names"] and not result["supplier_key_present"])
            elif item.get("expected") == "file_refused":
                self.check(label + ": " + item["name"] + " is inaccessible",
                           access_refused(result))
            elif item.get("expected") == "native_unreachable":
                self.check(label + ": " + item["name"] + " is unreachable from the native worker",
                           native_refused(result))
                entry["native_target"] = {"host": item["args"][0], "port": int(item["args"][1]), "controller_connected": True}
            if item["action"] != "api":
                continue
            status = item["expected_status"]
            verdict = "deny" if status == 403 else "permit"
            entry.update({key: item[key] for key in ("request_id", "method", "path", "expected_status", "host", "port")})
            entry["actual_status"] = result.get("status")
            http_result(result, status, item["request_id"], item["method"], item["path"])
            self.check(label + ": " + item["name"] + " returns " + str(status), True)
            decision = match(events, row, item["method"], item["path"],
                             item["port"], verdict, item["decision_action"], item["rule"], item["host"],
                             box_id=expected_box_id, box_run_id=expected_run_id)
            entry["box_decisions"] = [decision]
            if item["decision_action"] == "http:request":
                connect = match(events, row, item["method"], item["path"], item["port"],
                                "permit", "net:connect", "supplier_connect", item["host"],
                                box_id=expected_box_id, box_run_id=expected_run_id)
                self.check(label + ": " + item["name"] + " shares its connection decision identifier",
                           connect["strands.box.request.id"] == decision["strands.box.request.id"])
                entry["box_decisions"].insert(0, connect)
            seen_decisions.append(decision)
            self.check(label + ": " + item["name"] + " has an exact Box decision", True)
            if status != 403:
                self.check(label + ": " + item["name"] + " has the expected supplier response", True)
        expected_http = sum(item.get("decision_action") == "http:request" for item in plan if item["action"] == "api")
        self.check(label + ": no unmatched HTTP decisions",
                   len([event for event in events if event.get("strands.box.policy.action") == "http:request"]) == expected_http)
        self.check(label + ": no unmatched connection decisions",
                   len([event for event in events if event.get("strands.box.policy.action") == "net:connect"])
                   == sum(item["action"] == "api" for item in plan))
        self.check(label + ": distinct Box request identifiers",
                   len({event["strands.box.request.id"] for event in seen_decisions}) == len(seen_decisions))
        self.box_ids.append(expected_box_id)
        self.dump("calls.json", self.calls)
        return results

    def control(self, name, method, path, expected, base_url=None):
        request_id = self.id + "-control-" + name
        data = b'{"control":true}' if method != "GET" else None
        url = (base_url or self.supplier_url) + path
        origin = urlsplit(url)
        request = urllib.request.Request(url, data=data, method=method,
                    headers={"X-Analyst-Request-ID": request_id, "Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=10) as response:
            status = response.status
            body = strict_json.load(response)
        supplier_reply(body, request_id, method, path)
        self.calls.append({"call_id": request_id, "request_id": request_id,
                           "control": True, "method": method, "path": path,
                           "host": origin.hostname, "port": origin.port,
                           "expected_status": expected, "actual_status": status,
                           "result": {"status": status, "body": body}})
        self.check("trusted control: " + name, status == expected)

    def read_case(self):
        b = self.business
        if self.args.local:
            self.check("local mode explicitly skips AWS and model calls", True)
            return b.load_json(self.fixture_dir / "case.json")
        import boto3
        from botocore.config import Config
        from botocore.exceptions import ClientError
        self.session = boto3.Session(region_name=os.environ["AWS_REGION"])
        credentials = self.session.get_credentials()
        self.check("AWS uses the Pod Identity container provider",
                   credentials is not None and credentials.method == "container-role")
        self.arn = self.session.client("sts").get_caller_identity()["Arn"]
        self.check("AWS caller is the sample role", ":assumed-role/" + os.environ["ANALYST_ROLE_NAME"] + "/" in self.arn)
        key_names = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "BEDROCK_API_KEY", "AWS_BEARER_TOKEN_BEDROCK")
        self.check("controller has no model API key", not any(os.environ.get(name) for name in key_names))
        self.s3 = self.session.client("s3", config=Config(s3={"addressing_style": "path"}))
        self.bucket = os.environ["ANALYST_BUCKET"]
        case = strict_json.loads(self.s3.get_object(Bucket=self.bucket, Key="proposals/" + b.CASE + "/case.json")["Body"].read())
        for supplier in case["suppliers"]:
            source = strict_json.loads(self.s3.get_object(Bucket=self.bucket, Key=supplier["source"])["Body"].read())
            self.check("S3 proposal matches case: " + supplier["id"], b.proposal_matches_case(source, supplier))
        self.check("S3 case matches shared fixtures", b.load_json(self.fixture_dir / "case.json") == case)
        for operation, key in (("put_object", "proposals/" + b.CASE + "/case.json"),
                               ("delete_object", "proposals/" + b.CASE + "/case.json"),
                               ("get_object", "proposals/rfp-other/case.json")):
            params = {"Bucket": self.bucket, "Key": key}
            if operation == "put_object":
                params["Body"] = json.dumps(case).encode()
            try:
                getattr(self.s3, operation)(**params)
                code = "allowed"
            except ClientError as error:
                code = error.response["Error"]["Code"]
            self.check("IAM refuses " + operation + " " + key, code == "AccessDenied")
        return case

    def filesystem(self):
        from check_filesystem import run
        receipt = run(self.args.box_binary, self.code, self.state_root / "files")
        self.dump("filesystem-checks.json", receipt)
        self.check("standalone native filesystem checks passed", receipt["passed"] is True)
        self.checks.extend(receipt["checks"])

    def roles(self, case):
        b = self.business
        for role in ROLES:
            (self.root / role / "in/case.json").write_text(json.dumps(case))
        case_path = self.root / "reader/in/case.json"
        reader = self.batch("reader", [
            {"name": "read_case", "action": "read", "args": [str(case_path)]},
            self.request("reader-get", "GET", "/cases/rfp-001/suppliers", 200, rule="supplier_read_case"),
            self.request("reader-post", "POST", "/cases/rfp-001/recommendations", 403),
            self.request("reader-patch", "PATCH", "/suppliers/northstar", 403),
            self.request("reader-order", "POST", "/purchase-orders", 403),
            self.request("reader-other-case", "GET", "/cases/rfp-other/suppliers", 403),
        ])
        self.check("reader reads its staged case", reader["read_case"] == case)
        self.check("supplier availability belongs to the assigned case",
                   reader["reader-get"]["body"].get("case_id") == b.CASE)
        availability = b.availability_from_reply(reader["reader-get"]["body"])
        facts = self.root / "evaluator/in/facts.json"
        facts.write_text(json.dumps({"case": case, "availability": availability}))
        evaluated = self.batch("evaluator", [
            {"name": "evaluate", "action": "evaluate", "args": [str(facts)]},
            self.request("evaluator-get", "GET", "/cases/rfp-001/suppliers", 403, action="net:connect"),
        ])
        comparison = evaluated["evaluate"]
        self.check("offline evaluator agrees with controller arithmetic", comparison == b.compare(case, availability))
        self.check("eligible supplier is northstar", comparison["recommended_supplier"] == "northstar")
        staged = self.root / "writer/in/comparison.json"
        staged.write_text(json.dumps(comparison))
        written = self.root / "writer/out/comparison.json"
        plan = [{"name": "write_comparison", "action": "write", "args": [str(written), str(staged)]},
                self.request("writer-get", "GET", "/cases/rfp-001/suppliers", 200, rule="supplier_read_case"),
                self.request("writer-patch", "PATCH", "/suppliers/northstar", 403),
                self.request("writer-order", "POST", "/purchase-orders", 403),
                self.request("writer-other-case", "GET", "/cases/rfp-other/suppliers", 403)]
        plan += [self.request("writer-draft-" + str(i), "POST", "/cases/rfp-001/recommendations",
                              201 if i < 4 else 403, body_file=staged,
                              rule="supplier_draft" if i < 4 else "draft_response_budget") for i in range(1, 5)]
        writer = self.batch("writer", plan)
        self.check("writer output matches verified comparison", strict_json.loads(written.read_text()) == comparison
                   and writer["write_comparison"] == {"written": str(written)})
        self.batch("writer", [self.request("fresh-writer-draft", "POST", "/cases/rfp-001/recommendations",
                                          201, body_file=staged, rule="supplier_draft")], "fresh-writer")
        self.check("reader, evaluator, writer and fresh writer have distinct Box identities",
                   len(set(self.box_ids)) == 4)
        for name, method, path, status in (("draft", "POST", "/cases/rfp-001/recommendations", 201),
                                          ("patch", "PATCH", "/suppliers/northstar", 200),
                                          ("order", "POST", "/purchase-orders", 200),
                                          ("other-case", "GET", "/cases/rfp-other/suppliers", 200)):
            self.control(name, method, path, status)
        self.control("alias", "GET", "/cases/rfp-001/suppliers", 200,
                     base_url=self.supplier_alias_url)
        return comparison

    def native_controls(self):
        address = urlsplit(self.args.supplier_url)
        self.native_targets = [("direct_supplier_connection", socket.gethostbyname(address.hostname), address.port or 443)]
        protected = []
        if self.args.local:
            self.check("local mode leaves real Pod Identity endpoint and token checks untested", True)
        else:
            token = Path(os.environ["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"])
            endpoint = urlsplit(os.environ["AWS_CONTAINER_CREDENTIALS_FULL_URI"])
            self.native_targets.append(("direct_pod_identity_connection", socket.gethostbyname(endpoint.hostname), endpoint.port or 80))
            protected.append(token)
        for path in protected:
            with path.open("rb") as stream:
                stream.read(1)
        if protected:
            self.check("controller can open protected credential files", True)
        for name, host, port in self.native_targets:
            with socket.create_connection((host, port), timeout=5):
                pass
            self.check("controller can reach " + name, True)

    def model_and_save(self, case):
        b = self.business
        if self.args.local:
            self.report = ("# Local procurement check\n\nThe deterministic comparison recommends "
                           + self.comparison["recommended_supplier"]
                           + ". This local run did not invoke a model or read or write S3.\n")
            (self.root / "recommendation.md").write_text(self.report)
            return
        from analyst_agent import ModelTurn
        turn = ModelTurn(case, self.comparison)
        payload = turn.run()
        self.check("model called the evidence tool", turn.tool_calls > 0)
        self.check("Bedrock returned nonzero token usage", turn.usage.get("totalTokens", 0) > 0)
        self.check("model choice matches verified comparison", b.report_choice_matches(payload, self.comparison["recommended_supplier"]))
        self.check("model cites all shared proposal sources", b.report_cites_sources(payload, case))
        self.check("choice gate rejects an ineligible supplier", not b.report_choice_matches({**payload, "recommended_supplier": "harbor"}, self.comparison["recommended_supplier"]))
        missing = {**payload, "analysis_markdown": payload["analysis_markdown"].replace(case["suppliers"][1]["source"], "a proposal")}
        self.check("citation gate rejects a missing source", not b.report_cites_sources(missing, case))
        self.model_usage = turn.usage
        self.report = b.render_report(payload, case)
        prefix = "reports/" + b.CASE + "/" + self.id
        for name, body in (("recommendation.md", self.report), ("comparison.json", json.dumps(self.comparison, indent=2))):
            self.s3.put_object(Bucket=self.bucket, Key=prefix + "/" + name, Body=body.encode())
            actual = self.s3.get_object(Bucket=self.bucket, Key=prefix + "/" + name)["Body"].read().decode()
            self.check("S3 round trip: " + name, actual == body)
            (self.root / name).write_text(body)
        self.report_prefix = prefix

    def finish(self):
        self.dump("checks.json", self.checks)
        self.dump("calls.json", self.calls)
        evidence = {"run_id": self.id, "mode": "local" if self.args.local else "cloud",
                    "completed": self.complete, "case_id": self.business.CASE,
                    "architecture": platform.machine(), "kernel": platform.release(),
                    "box_sha256": sha256(self.args.box_binary), "state_root": str(self.state_root),
                    "source_sha256": {p.name: sha256(p) for p in sorted(Path(__file__).parent.glob("*.py"))},
                    "comparison": self.comparison, "model_usage": self.model_usage,
                    "aws_arn": getattr(self, "arn", None), "report_prefix": getattr(self, "report_prefix", None),
                    "credential_owner": "trusted controller for AWS; synthetic supplier has no credentials",
                    "supplier_origin": self.supplier_origin, "supplier_alias_origin": self.supplier_alias_origin,
                    "checks": self.checks, "calls": self.calls,
                    "qualification": "This run does not establish Nitro isolation or concurrency semantics.",
                    "untested": ["AWS model, S3, and Pod Identity"] if self.args.local else []}
        text = json.dumps(evidence, indent=2)
        (self.root / "evidence.json").write_text(text + "\n")

    def run(self):
        try:
            case = self.read_case()
            self.filesystem()
            self.native_controls()
            self.comparison = self.roles(case)
            self.model_and_save(case)
            self.complete = True
        finally:
            self.finish()
        (self.args.output_root / ("latest-local" if self.args.local else "latest")).write_text(self.id)
        print(("BOX_LOCAL_COMPLETE=" if self.args.local else "ANALYST_COMPLETE=") + self.id, flush=True)
        print(str(len(self.checks)) + " checks passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--box-binary", type=Path, default=Path(os.environ.get("BOX_BINARY", "/usr/local/bin/strands-box")))
    parser.add_argument("--shared-analyst", type=Path, default=Path("/opt/analyst"))
    parser.add_argument("--output-root", type=Path, default=Path("/var/lib/analyst"))
    parser.add_argument("--supplier-url", default=os.environ.get("SUPPLIER_API_URL"))
    parser.add_argument("--supplier-alias-url", default=os.environ.get("SUPPLIER_ALIAS_URL"))
    args = parser.parse_args()
    if not args.supplier_url or not args.supplier_alias_url:
        parser.error("Both supplier and alias HTTP origins are required")
    Run(args).run()


if __name__ == "__main__":
    main()
