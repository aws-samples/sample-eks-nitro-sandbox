#!/usr/bin/env python3
"""Cross-check role results and Box decisions against the synthetic HTTP supplier log.

The supplier log records arrival, method, and path. Worker results record response
status. Neither record alone establishes a Box policy decision.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

# Use the producer's result contracts without writing into the source folder.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from worker_adapter import access_refused, native_refused, http_result
import strict_json

POLICY = "strands.box.policy."
DRAFT = "/cases/rfp-001/recommendations"
SUPPLIERS = "/cases/rfp-001/suppliers"
# Every HTTP scenario has a fixed operation, role, and identity binding.
REQUIRED = {
    "reader-get": ("GET", SUPPLIERS, 200),
    "reader-post": ("POST", DRAFT, 403),
    "reader-patch": ("PATCH", "/suppliers/northstar", 403),
    "reader-order": ("POST", "/purchase-orders", 403),
    "reader-other-case": ("GET", "/cases/rfp-other/suppliers", 403),
    "evaluator-get": ("GET", SUPPLIERS, 403),
    "writer-get": ("GET", SUPPLIERS, 200),
    "writer-patch": ("PATCH", "/suppliers/northstar", 403),
    "writer-order": ("POST", "/purchase-orders", 403),
    "writer-other-case": ("GET", "/cases/rfp-other/suppliers", 403),
    **{"writer-draft-" + str(i): ("POST", DRAFT, 201 if i < 4 else 403) for i in range(1, 5)},
    "fresh-writer-draft": ("POST", DRAFT, 201),
    "control-draft": ("POST", DRAFT, 201),
    "control-patch": ("PATCH", "/suppliers/northstar", 200),
    "control-order": ("POST", "/purchase-orders", 200),
    "control-other-case": ("GET", "/cases/rfp-other/suppliers", 200),
    "control-alias": ("GET", SUPPLIERS, 200),
    **{label + "-" + target: ("GET", SUPPLIERS, 403)
       for label in ("reader", "evaluator", "writer", "fresh-writer")
       for target in ("alias", "unknown")},
}


ROLES = ("reader", "evaluator", "writer")
LABELS = (*ROLES, "fresh-writer")
FILESYSTEM_GATES = (
    "unconfined reads and writes succeed", "every probe produced one result",
    "own_input_read", "own_output_read", "own_output_write",
    "output file confirmed by controller", "shared supplier comparison",
    "sibling_input_read refused", "sibling_output_write refused", "input_write refused",
    "configuration_write refused", "policy_write refused", "state_write refused",
    "protected files unchanged", "Box state exists", "worker did not change Box state",
    "controller can write Box state",
)
WORKFLOW_GATES = {
    "standalone native filesystem checks passed", "each role has a distinct Box identity",
    "controller can reach direct_supplier_connection",
    "reader reads its staged case", "supplier availability belongs to the assigned case",
    "offline evaluator agrees with controller arithmetic", "eligible supplier is northstar",
    "writer output matches verified comparison",
    "reader, evaluator, writer and fresh writer have distinct Box identities",
    *(role + ": " + name for role in ROLES for name in FILESYSTEM_GATES),
}
CLOUD_GATES = {
    "AWS uses the Pod Identity container provider", "AWS caller is the sample role",
    "controller has no model API key", "controller can open protected credential files", "S3 case matches shared fixtures",
    *("S3 proposal matches case: " + supplier for supplier in ("northstar", "harbor", "cedar")),
    "IAM refuses put_object proposals/rfp-001/case.json",
    "IAM refuses delete_object proposals/rfp-001/case.json",
    "IAM refuses get_object proposals/rfp-other/case.json",
    "controller can reach direct_pod_identity_connection", "model called the evidence tool",
    "Bedrock returned nonzero token usage", "model choice matches verified comparison",
    "model cites all shared proposal sources", "choice gate rejects an ineligible supplier",
    "citation gate rejects a missing source", "S3 round trip: recommendation.md",
    "S3 round trip: comparison.json",
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def passed_checks(rows, required):
    require(isinstance(rows, list) and bool(rows), "the check receipts are missing")
    require(all(isinstance(row, dict) and isinstance(row.get("name"), str)
                and bool(row["name"]) and row.get("passed") is True for row in rows),
            "a check receipt is invalid or failed")
    names = [row["name"] for row in rows]
    require(len(set(names)) == len(names), "the check receipts contain duplicate names")
    require(required <= set(names), "required check receipts are missing: "
            + ", ".join(sorted(required - set(names))))
    return set(names)


def workflow_checks(evidence):
    required = WORKFLOW_GATES | (CLOUD_GATES if evidence["mode"] == "cloud" else set())
    passed_checks(evidence.get("checks"), required)
    if evidence["mode"] == "cloud":
        require(re.fullmatch(r"arn:[a-z0-9-]+:sts::[0-9]{12}:assumed-role/[^/]+/[^/]+",
                             evidence.get("aws_arn") or "") is not None,
                "cloud evidence has no assumed-role caller identity")
        require(evidence.get("report_prefix") == "reports/rfp-001/" + evidence["run_id"],
                "cloud evidence has no report prefix for this run")


def supporting_receipts(evidence, folder):
    """Require native filesystem and committed Box-identity receipts, not only summaries."""
    filesystem = strict_json.loads((folder / "filesystem-checks.json").read_text())
    require(filesystem.get("stage") == "filesystem" and filesystem.get("passed") is True,
            "the native filesystem receipt is missing its successful stage")
    for key in ("box_sha256", "architecture", "kernel"):
        require(filesystem.get(key) == evidence.get(key) and bool(evidence.get(key)),
                "the native filesystem receipt uses a different " + key)
    require(type(filesystem.get("uid")) is int and filesystem["uid"] > 0,
            "the native filesystem receipt has no non-root execution identity")
    required = {role + ": " + name for role in ROLES for name in FILESYSTEM_GATES}
    required.add("each role has a distinct Box identity")
    passed_checks(filesystem.get("checks"), required)
    expected_checks = {row["name"]: row for row in evidence["checks"]}
    require(all(expected_checks.get(row["name"]) == row for row in filesystem["checks"]),
            "native filesystem checks differ from the controller evidence")
    roles = filesystem.get("roles", {})
    require(set(roles) == set(ROLES), "the native filesystem receipt is missing a role")
    denied = {"sibling_input_read", "sibling_output_write", "input_write",
              "configuration_write", "policy_write", "state_write"}
    expected_names = denied | {"own_input_read", "own_output_read", "own_output_write", "comparison"}
    state_dirs = set()
    for role, receipt in roles.items():
        require(isinstance(receipt.get("box_dir"), str) and bool(receipt["box_dir"]),
                "a filesystem role has no Box state directory")
        state_dirs.add(receipt["box_dir"])
        for key in ("config_sha256", "policy_sha256"):
            require(re.fullmatch(r"[0-9a-f]{64}", receipt.get(key, "")) is not None,
                    "a filesystem role has no " + key)
        rows = receipt.get("results", [])
        values = {row["name"]: row["result"] for row in rows}
        require(len(values) == len(rows) and set(values) == expected_names,
                "a native filesystem probe is missing or duplicated")
        require(values["own_input_read"] == values["own_output_read"] == {"role": role},
                "the native filesystem read controls failed")
        written = values["own_output_write"].get("written", "")
        require(set(values["own_output_write"]) == {"written"}
                and isinstance(written, str) and written.endswith("/" + role + "/out/result.json"),
                "the native filesystem output-write control failed")
        require(values["comparison"] == evidence["comparison"],
                "the native filesystem comparison differs from the workflow")
        require(all(access_refused(values[name]) for name in denied),
                "a protected native filesystem operation was not refused")
    require(len(state_dirs) == len(ROLES), "filesystem roles share a Box state directory")
    for label in LABELS:
        identity = strict_json.loads((folder / "broker" / label / "box-identity.json").read_text())
        require(re.fullmatch(r"[0-9a-f]{64}", identity.get("committed_record_sha256", "")) is not None,
                "a Box identity receipt has no committed record hash")
        calls = [call for call in evidence["calls"]
                 if call.get("call_id", "").startswith(evidence["run_id"] + "-" + label + "-")]
        require(bool(calls), "a Box identity has no matching role calls")
        for key in ("box_id", "box_run_id"):
            require(isinstance(identity.get(key), str) and bool(identity[key])
                    and all(call.get(key) == identity[key] for call in calls),
                    "a role call differs from its committed Box identity receipt")
        for key in ("config_sha256", "policy_sha256"):
            hashes = {call.get(key) for call in calls}
            require(len(hashes) == 1 and re.fullmatch(r"[0-9a-f]{64}", next(iter(hashes)) or "") is not None,
                    "a role's calls do not use one configuration and policy")
    if evidence["mode"] == "cloud":
        deployment = strict_json.loads((folder / "deployment.json").read_text())
        role = deployment.get("target_environment", {}).get("ANALYST_ROLE_NAME")
        require(isinstance(role, str) and bool(role)
                and evidence["aws_arn"].split(":assumed-role/", 1)[1].split("/", 1)[0] == role,
                "the AWS caller differs from the deployed analyst role")


def exact_decision(call, supplier_host):
    events = call.get("box_decisions", [])
    expected = call["expected_status"]
    host, port = call.get("host"), call.get("port")
    require(isinstance(host, str) and bool(host) and type(port) is int and 0 < port < 65536,
            "the role call has no valid target host and port")
    connection_denied = call["role"] == "evaluator" or host != supplier_host
    actions = ["net:connect"] if connection_denied else ["net:connect", "http:request"]
    require([event.get(POLICY + "action") for event in events] == actions,
            "the role probe is missing its exact connection or HTTP decisions")
    require(not connection_denied or expected == 403, "an unapproved connection was expected to succeed")
    identities = set()
    for event in events:
        action = event[POLICY + "action"]
        denied = connection_denied or (action == "http:request" and expected == 403)
        resource = host + ":" + str(port) + (call["path"] if action == "http:request" else "")
        fields = {POLICY + "principal": "agent:self", POLICY + "action": action,
                  POLICY + "verdict": "deny" if denied else "permit",
                  POLICY + "resource": resource, "server.address": host, "server.port": port}
        if action == "http:request":
            fields["http.request.method"] = call["method"]
        elif not denied:
            fields[POLICY + "rule"] = "supplier_connect"
        require(all(event.get(key) == value for key, value in fields.items()),
                "the Box decision does not match the operation and expected verdict")
        require(type(call.get("started_ns")) is int and type(call.get("ended_ns")) is int
                and type(event.get("timestamp_ns")) is int
                and call["started_ns"] <= event["timestamp_ns"] <= call["ended_ns"],
                "the Box decision is outside the recorded sequential operation")
        for field in ("strands.box.request.id", "box_run_id", "box_id"):
            require(isinstance(event.get(field), str) and bool(event[field]),
                    "the Box decision is missing " + field)
        require(event["box_run_id"] == call.get("box_run_id") and event["box_id"] == call.get("box_id"),
                "the Box decision belongs to a different role call identity")
        identities.add((event["box_run_id"], event["box_id"], event["strands.box.request.id"]))
    require(len(identities) == 1, "the connection and HTTP decisions have different request identities")
    for field in ("config_sha256", "policy_sha256"):
        require(re.fullmatch(r"[0-9a-f]{64}", call.get(field, "")) is not None,
                "the role call is missing " + field)
    return events[-1]


def native_checks(evidence):
    rows = [call for call in evidence["calls"] if "call_id" in call]
    calls = {call["call_id"]: call for call in rows}
    require(len(calls) == len(rows), "the role calls contain duplicate identifiers")
    prefix = evidence["run_id"] + "-"
    for label in ("reader", "evaluator", "writer", "fresh-writer"):
        role = "writer" if label == "fresh-writer" else label
        def result(name, action):
            call = calls.get(prefix + label + "-" + name, {})
            require(call.get("role") == role and call.get("action") == action,
                    "a required native role probe is missing: " + label + "-" + name)
            return call, call.get("result", {})
        _, environment = result("credential_names", "credential-names")
        require(environment.get("aws_credential_names") == [] and environment.get("model_key_names") == [],
                "a role environment contains credential names")
        files = ["pod_identity_token"] if evidence["mode"] == "cloud" else []
        for name in files:
            _, record = result(name, "readable")
            require(access_refused(record), "a role read a protected credential file")
        targets = ["direct_supplier_connection"]
        if evidence["mode"] == "cloud":
            targets.append("direct_pod_identity_connection")
        for name in targets:
            call, record = result(name, "connect")
            target = call.get("native_target", {})
            require(target.get("controller_connected") is True and bool(target.get("host"))
                    and type(target.get("port")) is int and 0 < target["port"] < 65536,
                    "the native denial has no reachable trusted control")
            require(native_refused(record),
                    "the role's direct connection was not refused")


def validate(evidence, upstream, *, require_cloud=False):
    require(evidence.get("completed") is True, "the controller did not complete")
    run_id = evidence.get("run_id", "")
    require(re.fullmatch(r"[0-9a-f]{32}", run_id) is not None, "the run identifier is missing or invalid")
    mode = evidence.get("mode")
    require(mode in ("local", "cloud"), "the evidence has no recognized execution mode")
    require(not require_cloud or mode == "cloud", "run.sh requires cloud-mode evidence")
    if mode == "cloud":
        require(isinstance(evidence.get("model_usage"), dict)
                and evidence["model_usage"].get("totalTokens", 0) > 0,
                "cloud evidence has no model token usage")
    workflow_checks(evidence)
    require(evidence.get("case_id") == "rfp-001"
            and evidence.get("comparison", {}).get("recommended_supplier") == "northstar",
            "the shared procurement comparison is missing or unexpected")
    origins = {}
    for key in ("supplier_origin", "supplier_alias_origin"):
        origin = evidence.get(key, {})
        require(origin.get("scheme") == "http" and isinstance(origin.get("host"), str)
                and bool(origin["host"]) and type(origin.get("port")) is int and 0 < origin["port"] < 65536,
                "the evidence has no valid synthetic HTTP " + key)
        origins[key] = origin
    primary, alias = origins["supplier_origin"], origins["supplier_alias_origin"]
    require(primary["host"] != alias["host"] and primary["port"] == alias["port"],
            "the alternate supplier hostname is not a distinct name for the tested port")
    native_checks(evidence)
    calls = [call for call in evidence.get("calls", []) if "request_id" in call]
    by_id = {call["request_id"]: call for call in calls}
    require(len(by_id) == len(calls), "the controller recorded duplicate request identifiers")
    require(set(by_id) == {run_id + "-" + name for name in REQUIRED},
            "the HTTP scenario identifiers are missing, changed, or unexpected")
    require(all(call.get("action") != "api" or "request_id" in call for call in evidence["calls"]),
            "an API call has no scenario request identifier")
    for name, operation in REQUIRED.items():
        call = by_id.get(run_id + "-" + name, {})
        require(tuple(call.get(key) for key in ("method", "path", "expected_status")) == operation,
                "required supplier probe is missing or changed: " + name)
        require(call.get("control") is True if name.startswith("control-") else not call.get("control"),
                "trusted-control classification is incorrect: " + name)
        host = alias["host"] if name.endswith("-alias") else "not-approved.invalid" if name.endswith("-unknown") else primary["host"]
        require(call.get("host") == host and type(call.get("port")) is int and call["port"] == primary["port"],
                "the required probe has a different target host or port: " + name)
        if name.startswith("control-"):
            require(call.get("call_id") == run_id + "-" + name,
                    "the trusted control has a different call identifier: " + name)
        else:
            label = "fresh-writer" if name.startswith("fresh-writer-") else name.split("-", 1)[0]
            role = "writer" if label == "fresh-writer" else label
            require(call.get("role") == role and call.get("action") == "api",
                    "the required probe belongs to a different role: " + name)
            require(call.get("call_id") == run_id + "-" + label + "-" + name,
                    "the required probe has a different role call identifier: " + name)
    require(all(not str(row.get("request_id", "")).startswith(run_id + "-")
                or row["request_id"] in by_id for row in upstream),
            "a supplier request for this run has no controller call record")
    seen = set()
    for call in calls:
        identifier = call["request_id"]
        expected = call["expected_status"]
        require(type(expected) is int and expected in (200, 201, 403)
                and type(call.get("actual_status")) is int and call["actual_status"] == expected,
                "the actual response does not match the expected result: " + identifier)
        arrived = [row for row in upstream if row.get("request_id") == identifier]
        http_result(call.get("result"), expected, identifier, call["method"], call["path"])
        if not call.get("control"):
            require(call.get("role") in ("reader", "evaluator", "writer"), "the role is missing")
            decision = exact_decision(call, primary["host"])
            identity = (decision["box_run_id"], decision["strands.box.request.id"])
            require(identity not in seen, "a Box decision was reused by another probe")
            seen.add(identity)
        if expected == 403:
            require(not call.get("control") and not arrived,
                    "a denied operation reached the supplier: " + identifier)
        else:
            require(len(arrived) == 1,
                    "an allowed operation did not reach the supplier exactly once: " + identifier)
            require(arrived[0].get("method") == call["method"] and arrived[0].get("path") == call["path"],
                    "the supplier operation differs from the controller call: " + identifier)

    role_controls = [by_id[run_id + "-" + name]["box_decisions"][-1]
                     for name in ("reader-get", "evaluator-get", "writer-get", "fresh-writer-draft")]
    require(len({event["box_run_id"] for event in role_controls}) == 4
            and len({event["box_id"] for event in role_controls}) == 4,
            "the reader, evaluator, writer, and fresh writer did not use distinct Boxes")
    attempts = [by_id[run_id + "-writer-draft-" + str(i)] for i in range(1, 5)]
    fresh = by_id[run_id + "-fresh-writer-draft"]
    events = [call["box_decisions"][-1] for call in attempts]
    require(len({event["box_run_id"] for event in events}) == 1
            and len({event["box_id"] for event in events}) == 1,
            "the four draft attempts did not use the same Box run")
    require(all(left["ended_ns"] <= right["started_ns"] for left, right in zip(attempts, attempts[1:]))
            and attempts[-1]["ended_ns"] - attempts[0]["started_ns"] < 600 * 1_000_000_000,
            "the quota probes were not sequential within ten minutes")
    require([event.get(POLICY + "rule") for event in events]
            == ["supplier_draft"] * 3 + ["draft_response_budget"],
            "the fourth refusal was not the temporal response-budget rule")
    fresh_event = fresh["box_decisions"][-1]
    require(fresh_event["box_run_id"] != events[0]["box_run_id"]
            and fresh_event["box_id"] != events[0]["box_id"]
            and fresh_event.get(POLICY + "rule") == "supplier_draft",
            "the fresh-writer control did not use a distinct permitted Box")
    return len(calls)


def json_lines(path):
    return [strict_json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-cloud", action="store_true")
    parser.add_argument("evidence", type=Path)
    parser.add_argument("supplier", type=Path)
    args = parser.parse_args()
    try:
        evidence = strict_json.loads(args.evidence.read_text())
        for name in ("checks", "calls"):
            require(strict_json.loads(args.evidence.with_name(name + ".json").read_text()) == evidence.get(name),
                    name + ".json differs from the evidence")
        count = validate(evidence, json_lines(args.supplier),
                         require_cloud=args.require_cloud)
        supporting_receipts(evidence, args.evidence.parent)
        from decision_records import decisions
        actual = []
        canonical = lambda rows: Counter(json.dumps(row, sort_keys=True) for row in rows)
        for label in LABELS:
            broker = args.evidence.parent / "broker" / label
            identity = strict_json.loads((broker / "box-identity.json").read_text())
            recorded = decisions(broker / "box-records.jsonl")
            require(all(row.get("box_id") == identity["box_id"]
                        and row.get("box_run_id") == identity["box_run_id"] for row in recorded),
                    label + " raw Box decision log differs from its committed identity")
            role_actual = [row for row in recorded if row.get(POLICY + "action") in ("http:request", "net:connect")]
            role_expected = [row for call in evidence["calls"]
                             if call.get("call_id", "").startswith(evidence["run_id"] + "-" + label + "-")
                             for row in call.get("box_decisions", [])]
            require(canonical(role_actual) == canonical(role_expected),
                    label + " raw Box decision log differs from its role's selected decisions")
            actual.extend(role_actual)
        expected = [row for call in evidence["calls"] for row in call.get("box_decisions", [])]
        require(canonical(actual) == canonical(expected),
                "the raw Box decision logs differ from the controller's selected decisions")
    except (AssertionError, AttributeError, IndexError, KeyError, TypeError, ValueError, OSError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    print(str(count) + " supplier requests correlated across controller, Box, and supplier records")
    print("Execution mode: " + evidence["mode"] + "; this correlation does not establish Nitro isolation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
