"""Check independent analyst role filesystems with the pinned Box executable."""
import argparse
import hashlib
import json
import strict_json
import os
from pathlib import Path
import platform
import sys

from box_roles import ROLES, execute, prepare
from worker_adapter import access_refused


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(box, shared_analyst, output):
    if os.getuid() == 0:
        raise RuntimeError("Run Box as a non-root operator")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    shared_analyst = Path(shared_analyst).resolve(strict=True)
    sys.path.insert(0, str(shared_analyst))
    from business import compare, load_json
    fixture_dir = shared_analyst / "fixtures" if (shared_analyst / "fixtures").is_dir() else shared_analyst.parent / "fixtures"
    case, availability = load_json(fixture_dir / "case.json"), load_json(fixture_dir / "availability.json")
    expected = compare(case, availability)
    receipt = {"stage": "filesystem", "box_sha256": digest(box),
               "architecture": platform.machine(), "kernel": platform.release(),
               "python": sys.version, "uid": os.getuid(),
               "scope": "Native Python filesystem operations; no supplier network, credentials, or cloud validation",
               "source_sha256": {str(p): digest(p) for p in sorted(Path(__file__).parent.glob("*.py"))},
               "checks": [], "roles": {}}

    def check(name, passed):
        receipt["checks"].append({"name": name, "passed": bool(passed)})
        print(("PASS " if passed else "FAIL ") + name, flush=True)
        if not passed:
            raise AssertionError(name)

    try:
        for role in ROLES:
            work = output / role
            (work / "in").mkdir(parents=True)
            (work / "out").mkdir()
            (work / "in/facts.json").write_text(json.dumps({"case": case, "availability": availability}))
            (work / "in/identity.json").write_text(json.dumps({"role": role}))
            (work / "out/existing.json").write_text(json.dumps({"owner": role}))
        for index, role in enumerate(ROLES):
            work = output / role
            sibling = output / ROLES[(index + 1) % len(ROLES)]
            broker = output / "broker" / role
            config = prepare(role, work, broker, shared_analyst, sys.executable,
                             Path(__file__).with_name("worker_adapter.py"))
            policy = broker / "policy.dw"
            protected = [work / "in/identity.json", sibling / "in/identity.json",
                         sibling / "out/existing.json", config, policy]
            before = {str(p): digest(p) for p in protected}
            # The same operator can read and rewrite every existing target before confinement.
            for target in protected:
                original = target.read_bytes()
                target.write_bytes(original)
            check(role + ": unconfined reads and writes succeed",
                  all(digest(p) == value for p, value in before.items()))
            plan = [
                {"name": "own_input_read", "action": "read", "args": [str(work / "in/identity.json")]},
                {"name": "own_output_write", "action": "write", "args": [str(work / "out/result.json"), str(work / "in/identity.json")]},
                {"name": "own_output_read", "action": "read", "args": [str(work / "out/result.json")]},
                {"name": "comparison", "action": "evaluate", "args": [str(work / "in/facts.json")]},
                {"name": "sibling_input_read", "action": "read", "args": [str(sibling / "in/identity.json")]},
                {"name": "sibling_output_write", "action": "write", "args": [str(sibling / "out/existing.json"), str(work / "in/identity.json")]},
                {"name": "input_write", "action": "write", "args": [str(work / "in/identity.json"), str(work / "in/facts.json")]},
                {"name": "configuration_write", "action": "write", "args": [str(config), str(work / "in/identity.json")]},
                {"name": "policy_write", "action": "write", "args": [str(policy), str(work / "in/identity.json")]},
                {"name": "state_write", "action": "write", "args": [str(broker / "state/worker-wrote.json"), str(work / "in/identity.json")]},
            ]
            (work / "in/probes.json").write_text(json.dumps(plan))
            results = execute(box, config)
            names = [entry["name"] for entry in results]
            check(role + ": every probe produced one result", names == [entry["name"] for entry in plan])
            values = {entry["name"]: entry["result"] for entry in results}
            receipt["roles"][role] = {"config": str(config), "config_sha256": digest(config), "policy_sha256": digest(policy),
                                      "box_dir": str(broker / "state"), "results": results}
            for name in ("own_input_read", "own_output_read"):
                check(role + ": " + name, values[name] == {"role": role})
            check(role + ": own_output_write", values["own_output_write"] == {"written": str(work / "out/result.json")})
            check(role + ": output file confirmed by controller",
                  strict_json.loads((work / "out/result.json").read_text()) == {"role": role})
            check(role + ": shared supplier comparison", values["comparison"] == expected)
            for name in ("sibling_input_read", "sibling_output_write", "input_write",
                         "configuration_write", "policy_write", "state_write"):
                check(role + ": " + name + " refused", access_refused(values[name]))
            check(role + ": protected files unchanged", all(digest(p) == value for p, value in before.items()))
            check(role + ": Box state exists", (broker / "state/private").is_dir())
            check(role + ": worker did not change Box state", not (broker / "state/worker-wrote.json").exists())
            state_control = broker / "state/worker-wrote.json"
            state_control.write_text(json.dumps({"controller": True}))
            check(role + ": controller can write Box state", strict_json.loads(state_control.read_text()) == {"controller": True})
        check("each role has a distinct Box identity", len({row["box_dir"] for row in receipt["roles"].values()}) == len(ROLES))
        receipt["passed"] = True
    except Exception as error:
        receipt["passed"] = False
        receipt["error"] = str(error)
        raise
    finally:
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("Receipt: " + str(output / "receipt.json"), flush=True)
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--box-binary", type=Path, required=True)
    parser.add_argument("--shared-analyst", type=Path, default=Path("/opt/analyst"))
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    run(args.box_binary, args.shared_analyst, args.output_dir)
