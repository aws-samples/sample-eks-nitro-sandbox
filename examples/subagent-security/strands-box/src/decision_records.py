"""Read Box decision logs and correlate a sequential probe with one exact decision."""
import hashlib
import json
import strict_json
import re


def value(item):
    if "intValue" in item:
        return int(item["intValue"])
    if "arrayValue" in item:
        return [value(entry) for entry in item["arrayValue"]["values"]]
    return next(iter(item.values()))


def decisions(path):
    records = []
    for line in path.read_text().splitlines():
        for resource in strict_json.loads(line).get("resourceLogs", []):
            owner = strict_json.unique_object((entry["key"], value(entry["value"]))
                     for entry in resource.get("resource", {}).get("attributes", []))
            for scope in resource.get("scopeLogs", []):
                if scope.get("scope", {}).get("name") != "strands-box.policy":
                    continue
                for record in scope.get("logRecords", []):
                    if record.get("eventName") != "strands.box.policy.decision":
                        continue
                    fields = strict_json.unique_object((entry["key"], value(entry["value"]))
                              for entry in record.get("attributes", []))
                    fields["timestamp_ns"] = int(record["timeUnixNano"])
                    fields["box_run_id"] = owner.get("strands.box.run.id")
                    fields["box_id"] = owner.get("strands.box.name")
                    records.append(fields)
    return records


def batch_identity(records, state, name, policy):
    """Bind a batch to the record committed by the pinned Box runtime."""
    record = (state / "private/box.toml").read_bytes()
    marker = (state / "private/configured").read_text().strip().split()
    if len(marker) != 2 or marker[1] != "sha256:" + hashlib.sha256(record).hexdigest():
        raise AssertionError("Box identity marker does not match its committed record")
    # These four values are strings emitted by Box's TOML serializer. Parse only
    # its top-level header; the sample does not interpret arbitrary TOML.
    header = record.decode().split("\n[", 1)[0]
    fields = {}
    for key in ("box_id", "box_dir", "name", "policy"):
        matches = re.findall(r"^" + key + r" = (\"[^\n]*\")$", header, re.MULTILINE)
        if len(matches) != 1:
            raise AssertionError("Missing or duplicate committed Box field: " + key)
        fields[key] = strict_json.loads(matches[0])
    if (not re.fullmatch(r"box-[0-9a-f]{16}", marker[0])
            or fields != {"box_id": marker[0], "box_dir": str(state.resolve()),
                          "name": name, "policy": str(policy.resolve())}):
        raise AssertionError("Committed Box identity does not match this batch configuration")
    run_ids = {event.get("box_run_id") for event in records}
    if len(run_ids) != 1 or not all(isinstance(item, str) and item for item in run_ids):
        raise AssertionError("Batch decisions must have one nonempty Box run identifier")
    if not records or any(event.get("box_id") != marker[0] for event in records):
        raise AssertionError("Batch decision belongs to an unexpected Box identity")
    return marker[0], next(iter(run_ids))


def match(records, row, method, path, port, verdict, action="http:request", rule=None,
          host="127.0.0.1", *, box_id, box_run_id):
    if not box_id or not box_run_id:
        raise AssertionError("Expected Box and run identifiers are required")
    expected = {"box_id": box_id, "box_run_id": box_run_id,
                "strands.box.policy.principal": "agent:self",
                "strands.box.policy.action": action,
                "strands.box.policy.verdict": verdict,
                "server.address": host, "server.port": port,
                "strands.box.policy.resource": host + ":" + str(port)
                    + (path if action == "http:request" else "")}
    if action == "http:request":
        expected["http.request.method"] = method
    if rule is not None:
        expected["strands.box.policy.rule"] = rule
    found = [record for record in records
             if row["started_ns"] <= record["timestamp_ns"] <= row["ended_ns"]
             and all(record.get(key) == wanted for key, wanted in expected.items())]
    if len(found) != 1:
        raise AssertionError("Expected one exact Box decision, found " + str(len(found)))
    result = found[0]
    if not result.get("strands.box.request.id") or not result.get("box_run_id"):
        raise AssertionError("Box decision is missing its request or run identifier")
    return result
