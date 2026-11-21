#!/usr/bin/env python3
"""The closed-world gate of the offline tests.

    closed_world.py gate <sample-dir> <coverage.jsonl> <report.md>
        fails (exit 1) when a tag of the generated inventory has no passing accept case or no
        passing reject case, when an untagged refusal exists, when a covered tag is not in the
        inventory, or when an entry point that a case names no longer exists
    closed_world.py mutants <sample-dir> <coverage.jsonl> <report.md> [<jobs>]
        for each tag with a passing reject case: a parse-valid mutant of the sample with that tag's
        sites neutralised (inventory.py --mutate), then the suites that hold the tag's reject cases
        run against it; the mutant is killed when one of those reject cases fails. Exit 1 when a
        mutant survives or is not parse-valid.

Both write a Markdown report. The mutants live under <repo>/tmp/cb-mutants/ and are removed after
the run unless CB_TESTS_KEEP=1.
"""
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import inventory as inv  # noqa: E402


def load_cov(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def entry_exists(root, entry):
    if not entry:
        return True
    path, _, name = entry.partition(":")
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        return False
    if not name:
        return True
    text = open(full, encoding="utf-8").read()
    if path.endswith(".py"):
        pats = [rf"add_parser\(\s*[\"']{re.escape(name)}[\"']", rf"\badd\(\s*[\"']{re.escape(name)}[\"']",
                rf"^def (cmd_)?{re.escape(name.replace('-', '_'))}\b",
                rf"[\"']{re.escape(name)}[\"']\s*:"]
    else:
        # A function, or a case pattern on its own line or after `case ... in` on one line, alone or
        # as one of several alternatives (`check-tools|build)`).
        pats = [rf"^\s*{re.escape(name)}\s*\(\)",
                rf"(^\s*|\bin\s+)\"?([\w-]+\|)*{re.escape(name)}(\|[\w-]+)*\"?\)"]
    return any(re.search(p, text, re.M) for p in pats)


def exemptions():
    """testlib/exemptions.txt: '<E_TAG>|<case kind that is exempt: accept, reject or both>|<reason>'.
    The reason says why the input cannot be produced offline, even with a stub command."""
    out = {}
    path = os.path.join(HERE, "exemptions.txt")
    if os.path.exists(path):
        for line in open(path):
            if line.strip() and not line.startswith("#"):
                tag, kind, reason = line.rstrip("\n").split("|", 2)
                out[tag] = (kind, reason)
    return out


def gate(root, cov_path, report):
    data = inv.inventory(root)
    cov = load_cov(cov_path)
    tags = data["tags"]
    exempt = exemptions()
    passed = {}
    for c in cov:
        if c.get("status") == "pass":
            passed.setdefault(c["tag"], {}).setdefault(c["kind"], []).append(c)
    rows, gaps = [], 0
    for tag, sites in tags.items():
        acc = passed.get(tag, {}).get("accept", [])
        rej = passed.get(tag, {}).get("reject", [])
        kind = exempt.get(tag, ("", ""))[0]
        ok = (bool(acc) or kind in ("accept", "both")) and (bool(rej) or kind in ("reject", "both"))
        gaps += 0 if ok else 1
        where = ", ".join(sorted({f"{s['file']}:{s['line']}" for s in sites}))[:200]
        state = "GAP" if not ok else (f"exempt ({kind}): {exempt[tag][1]}" if kind and not (acc and rej) else "ok")
        rows.append(f"| `{tag}` | {where} | {len(acc)} | {len(rej)} | {state} |")
    stale = sorted({c["tag"] for c in cov if c["tag"] not in tags})
    missing_entries = sorted({c["entry"] for c in cov if c.get("entry") and not entry_exists(root, c["entry"])})
    # An exemption line is wrong when its tag is not in the inventory, or when a passing case
    # already covers a side it exempts (the exemption is no longer needed).
    bad_exempt = []
    for tag, (kind, _) in sorted(exempt.items()):
        if tag not in tags:
            bad_exempt.append(f"`{tag}` ({kind}): not in the inventory")
            continue
        sides = ("accept", "reject") if kind == "both" else (kind,)
        covered = [s for s in sides if passed.get(tag, {}).get(s)]
        if kind not in ("accept", "reject", "both"):
            bad_exempt.append(f"`{tag}` ({kind}): the side must be accept, reject or both")
        elif covered:
            bad_exempt.append(f"`{tag}` ({kind}): a passing case covers {', '.join(covered)}; remove the exemption")
    lines = [f"# Closed-world gate", "",
             f"Inventory: {len(tags)} tags, {sum(len(v) for v in tags.values())} sites, {len(data['untagged'])} untagged sites.",
             f"Coverage: {len(cov)} records. Tags without both cases: {gaps}. Covered tags not in the inventory: {len(stale)}. "
             f"Missing entry points: {len(missing_entries)}. Exemptions: {len(exempt)}, wrong: {len(bad_exempt)}.", "",
             "| Tag | Sites | Accept cases | Reject cases | State |", "|---|---|---|---|---|", *rows, ""]
    if bad_exempt:
        lines += ["## Exemption lines that are wrong", ""] + [f"- {e}" for e in bad_exempt] + [""]
    if data["untagged"]:
        lines += ["## Untagged refusal sites", ""] + [f"- {s['file']}:{s['line']} ({s['form']})" for s in data["untagged"]] + [""]
    if stale:
        lines += ["## Covered tags not in the inventory", ""] + [f"- `{t}`" for t in stale] + [""]
    if missing_entries:
        lines += ["## Entry points that no longer exist", ""] + [f"- `{e}`" for e in missing_entries] + [""]
    open(report, "w").write("\n".join(lines))
    bad = gaps + len(data["untagged"]) + len(stale) + len(missing_entries) + len(bad_exempt)
    print(f"closed-world gate: {len(tags)} tags, {gaps} without both cases, {len(data['untagged'])} untagged, "
          f"{len(stale)} stale, {len(missing_entries)} missing entry points, {len(exempt)} exemptions "
          f"({len(bad_exempt)} wrong) -> {'PASS' if bad == 0 else 'FAIL'}")
    return 0 if bad == 0 else 1


def run_mutant(root, repo, tag, suites, keep):
    # setup.sh, test.sh and clean.sh source ../../../scripts/lib/require-bash.sh, so the mutant
    # sample sits three levels below a folder that holds a copy of it.
    mroot = os.path.join(repo, "tmp", "cb-mutants", tag)
    msample = os.path.join(mroot, "examples", "setup", "cilium-bottlerocket")
    if os.path.exists(mroot):
        shutil.rmtree(mroot)
    os.makedirs(os.path.join(mroot, "scripts", "lib"))
    shutil.copy(os.path.join(repo, "scripts", "lib", "require-bash.sh"), os.path.join(mroot, "scripts", "lib"))
    r = subprocess.run([sys.executable, os.path.join(HERE, "inventory.py"), root, "--mutate", tag, msample],
                       capture_output=True, text=True)
    if r.returncode == 3:
        shutil.rmtree(mroot, ignore_errors=True)
        return tag, "implicit", "the shared Unknown handler of main_wrapper; not mutated per subcommand"
    if r.returncode != 0:
        return tag, "not-parse-valid", r.stdout + r.stderr
    cov = os.path.join(mroot, "coverage.jsonl")
    if os.path.exists(cov):
        os.remove(cov)
    env = dict(os.environ, CB_TESTS_SAMPLE_DIR=msample, CB_TESTS_COVERAGE=cov)
    log = []
    timed_out = []
    for s in sorted(suites):
        try:
            p = subprocess.run(["bash", os.path.join(HERE, "..", f"{s}.sh")], env=env, capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, timeout=int(os.environ.get("CB_TESTS_MUTANT_TIMEOUT", "2400")))
            log.append(f"{s}: exit {p.returncode}")
        except subprocess.TimeoutExpired:
            # A suite that does not finish proves nothing about the mutant: report it, never count it.
            timed_out.append(s)
            log.append(f"{s}: timed out")
    killed = any(c["tag"] == tag and c["kind"] == "reject" and c["status"] == "fail" for c in load_cov(cov))
    if timed_out and not killed:
        if not keep:
            shutil.rmtree(mroot, ignore_errors=True)
        return tag, "TIMEOUT", "; ".join(log) + "\n" + r.stdout
    if not keep:
        shutil.rmtree(mroot, ignore_errors=True)
    return tag, "killed" if killed else "SURVIVED", "; ".join(log) + "\n" + r.stdout


def mutants(root, cov_path, report, jobs=6):
    repo = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    data = inv.inventory(root)
    cov = load_cov(cov_path)
    suites = {}
    for c in cov:
        if c["kind"] == "reject" and c["status"] == "pass" and c["tag"] in data["tags"]:
            suites.setdefault(c["tag"], set()).add(c["suite"])
    keep = os.environ.get("CB_TESTS_KEEP") == "1"
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(jobs)) as ex:
        futs = [ex.submit(run_mutant, root, repo, t, s, keep) for t, s in sorted(suites.items())]
        for f in concurrent.futures.as_completed(futs):
            results.append(f.result())
    results.sort()
    no_case = sorted(set(data["tags"]) - set(suites))
    survived = [r for r in results if r[1] not in ("killed", "implicit")]
    lines = ["# Mutants", "", f"Tags with a reject case: {len(suites)}. Killed: {len(results) - len(survived)}. "
             f"Survived or not parse-valid: {len(survived)}. Tags with no reject case (no mutant run): {len(no_case)}.", "",
             "| Tag | Result | Suites |", "|---|---|---|"]
    lines += [f"| `{t}` | {res} | {detail.splitlines()[0][:150]} |" for t, res, detail in results]
    if no_case:
        lines += ["", "## Tags with no reject case", ""] + [f"- `{t}`" for t in no_case]
    open(report, "w").write("\n".join(lines) + "\n")
    print(f"mutants: {len(results)} run, {len(results) - len(survived)} killed, {len(survived)} survived or not parse-valid")
    return 0 if not survived else 1


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "gate":
        sys.exit(gate(*sys.argv[2:5]))
    if cmd == "mutants":
        sys.exit(mutants(*sys.argv[2:6]))
    sys.exit(f"usage: {__doc__}")
