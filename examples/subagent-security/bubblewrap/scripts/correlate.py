#!/usr/bin/env python3
"""Check the run's own record of its supplier calls against the server's request log.

    correlate.py <evidence.json> <supplier-api-requests.jsonl>

The run's evidence is the analyst pod's account of itself. This reads the supplier API's
own log, out of the supplier API pod, and compares the two. In this sample no tool
process makes a supplier call at all, because bubblewrap gives it no network, so what
the comparison establishes is the other half of that claim: the only requests the server
saw for this run are the ones the trusted controller says it made.

Three things are required, and the third is what stops an empty log from passing:

  * every authenticated request the controller recorded arrived exactly once;
  * no other request carrying this run's id arrived at all, so nothing in the pod reached
    the server besides the controller;
  * the run really contained both a successful read and an accepted draft submission.

The supplier API logs a request only after it has accepted the key, so the deliberately
invalid-key call is expected to be absent, and this requires it to be.
"""
import json
import sys
from collections import Counter


def main(evidence_path, log_path):
    evidence = json.loads(open(evidence_path).read())
    run_id = evidence["run_id"]
    recorded = evidence["supplier_requests"]

    arrived = Counter()
    seen = {}
    with open(log_path) as stream:
        for line in stream:
            if not line.strip():
                continue
            entry = json.loads(line)
            # run_id + "-" rather than run_id, so the boundary is the separator the
            # controller actually puts between the run id and the suffix, and a different
            # run whose id merely starts with this one's cannot be counted in.
            if entry["request_id"].startswith(run_id + "-"):
                arrived[entry["request_id"]] += 1
                seen[entry["request_id"]] = (entry["method"], entry["path"])

    problems = []
    expected = [r for r in recorded if r["authenticated"]]
    # Each expected request is checked against the count for its own id, so two recorded
    # requests sharing an id would both be satisfied by one upstream arrival. The
    # controller gives every call a distinct suffix, so this is not reachable through it,
    # but the correlation is the independent half of the evidence and it should not depend
    # on the thing it is checking to be well formed.
    duplicates = sorted(id for id, n in Counter(
        r["request_id"] for r in recorded).items() if n > 1)
    if duplicates:
        problems.append("the run recorded the same request id more than once "
                        f"({duplicates}), so one upstream arrival could satisfy two of "
                        "them")
    for request in expected:
        count = arrived[request["request_id"]]
        if count != 1:
            problems.append(f"{request['method']} {request['path']} arrived {count} "
                            "times upstream, expected exactly 1")
        elif seen[request["request_id"]] != (request["method"], request["path"]):
            problems.append(
                f"{request['request_id']} arrived as {seen[request['request_id']]}, "
                f"not as ({request['method']}, {request['path']})")
    for request in recorded:
        if not request["authenticated"] and arrived[request["request_id"]]:
            problems.append(f"the invalid-key call {request['request_id']} was logged "
                            "upstream, so the server accepted its key")

    unexpected = set(arrived) - {r["request_id"] for r in expected}
    if unexpected:
        problems.append("requests carrying this run's id arrived upstream that the "
                        f"controller did not make: {sorted(unexpected)}")

    reads = [r for r in expected if r["method"] == "GET" and r["status"] == 200]
    drafts = [r for r in expected if r["method"] == "POST" and r["status"] == 201]
    if not reads or not drafts:
        problems.append("the run did not contain both a successful read and an accepted "
                        "draft submission, so an empty upstream log would satisfy the "
                        "checks above")

    if problems:
        for problem in problems:
            print(f"MISMATCH {problem}", file=sys.stderr)
        raise SystemExit(1)
    print(f"  {len(expected)} authenticated requests correlated with the supplier API's "
          f"own log, each arriving once, and no other request from this run")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
