#!/usr/bin/env python3
"""Cross-check the run's own record against the supplier API's separately read log.

The analyst's evidence says what each tool role was allowed and refused. This reads the
supplier API's request log out of its own pod and checks the two agree:

  * every request the run expected to succeed arrived upstream exactly once, with the
    same method and path;
  * every request the run expected to be refused never arrived at all.

An empty upstream log would satisfy the second on its own, so this also requires that the
run contained both a successful draft submission and a refused operation. It exits
non-zero when the two records disagree.
"""
import json
import sys
from pathlib import Path


def validate(evidence: dict, upstream: list) -> int:
    checks = evidence.get("checks", [])
    if not checks or any(c.get("passed") is not True for c in checks):
        raise AssertionError("the run's own checks are missing or did not all pass")
    if evidence.get("comparison", {}).get("recommended_supplier") != "northstar":
        raise AssertionError("the comparison did not name the expected supplier")

    calls = [c for c in evidence.get("calls", []) if "request_id" in c]
    if not any(c.get("expected_status") == 201 for c in calls):
        raise AssertionError("no successful draft submission in the run")
    if not any(c.get("expected_status") == 403 for c in calls):
        raise AssertionError("no refused supplier operation in the run")

    for call in calls:
        arrived = [e for e in upstream if e.get("request_id") == call["request_id"]]
        expected = call.get("expected_status")
        if expected in (200, 201):
            if len(arrived) != 1:
                raise AssertionError(
                    f"an allowed request arrived {len(arrived)} times upstream, not once: "
                    f"{call['request_id']}")
            if (arrived[0].get("method") != call["method"]
                    or arrived[0].get("path") != call["path"]):
                raise AssertionError(
                    f"an allowed request arrived upstream as a different operation: "
                    f"{call['request_id']}")
        elif arrived:
            raise AssertionError(
                f"a refused request reached the supplier API: {call['request_id']}")
    return len(calls)


def main(evidence_path, upstream_path):
    evidence = json.loads(Path(evidence_path).read_text())
    upstream = [json.loads(line) for line in
                Path(upstream_path).read_text().splitlines() if line.strip()]
    correlated = validate(evidence, upstream)
    allowed = sum(1 for c in evidence["calls"]
                  if c.get("expected_status") in (200, 201))
    refused = sum(1 for c in evidence["calls"] if c.get("expected_status") == 403)
    print(f"  {len(evidence['checks'])} checks passed in the sandbox")
    print(f"  {correlated} requests correlated with the supplier API's own log "
          f"({allowed} allowed arrived once each, {refused} refused never arrived)")
    print(f"  model usage: {evidence['model_usage'].get('totalTokens')} tokens "
          f"on {evidence['model_id']}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <evidence.json> <supplier-api-requests.jsonl>",
              file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
