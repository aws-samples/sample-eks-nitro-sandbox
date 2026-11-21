"""Shared parts of this sample's stub commands (fake_aws.py, fake_eksctl.py, fake_kubectl.py,
fake_helm.py, fake_packer.py), for the offline tests only.

Every stub reads and changes one world state file and appends to one call log, so a test can
check what the real script read back and in which order it called each tool:

  FAKE_STATE  path of the JSON world state (required; a stub refuses to run without it)
  FAKE_LOG    path of the call log, one JSON object per line:
              {"seq": n, "tool": "aws", "call": "ec2 delete-volume", "argv": [...]}
  FAKE_FAIL   optional rules "tool|call|substring|ErrorCode[|N[|K]]" joined by ";": a call of
              that tool whose call name equals <call> and whose joined argv contains <substring>
              (empty matches all) fails with <ErrorCode>; with N, only the first N such calls
              fail (a transient error); with K, the first K such calls pass before any fails
              (N may be empty). The stub then exits 254 (aws) or 1 (the others).

A stub never contacts AWS or a cluster, and never reads a credential.
"""
import fcntl
import json
import os
import sys
from contextlib import contextmanager

STATE_PATH = os.environ.get("FAKE_STATE", "")
LOG_PATH = os.environ.get("FAKE_LOG", "")


def require_state(tool):
    if not STATE_PATH or not os.path.isfile(STATE_PATH):
        sys.stderr.write(f"FAKE {tool}: FAKE_STATE is not set to a state file; this stub is for the "
                         "offline tests only and does nothing against AWS or a cluster\n")
        sys.exit(99)


@contextmanager
def world():
    """Load the state under an exclusive lock, yield it, save it on a normal exit."""
    lock = open(STATE_PATH + ".lock", "a+")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        with open(STATE_PATH) as f:
            state = json.load(f)
        holder = {"save": True}
        yield state, holder
        if holder["save"]:
            tmp = STATE_PATH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(state, f, indent=1, sort_keys=True)
            os.replace(tmp, STATE_PATH)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def log_call(tool, call, argv, extra=None):
    if not LOG_PATH:
        return
    lock = open(LOG_PATH + ".lock", "a+")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        seq = 0
        if os.path.exists(LOG_PATH):
            with open(LOG_PATH) as f:
                seq = sum(1 for _ in f)
        entry = {"seq": seq + 1, "tool": tool, "call": call, "argv": list(argv)}
        if extra:
            entry.update(extra)
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def injected_failure(tool, call, argv):
    """The error code of the first FAKE_FAIL rule that matches this call, or None."""
    joined = " ".join(argv)
    rules = [r for r in os.environ.get("FAKE_FAIL", "").split(";") if r.strip()]
    for n, rule in enumerate(rules):
        parts = (rule.split("|") + ["", "", "", "", ""])[:6]
        r_tool, r_call, r_sub, r_code, r_times, r_after = (p.strip() if i < 2 else p for i, p in enumerate(parts))
        if r_tool != tool or r_call != call or r_sub not in joined:
            continue
        if r_after:
            # The sixth field: let the first <after> matching calls through, then fail (for a read
            # that must pass the first time and fail a later time, such as a second inventory).
            cpath = STATE_PATH + ".failcounts"
            lock = open(cpath + ".lock", "a+")
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                counts = json.load(open(cpath)) if os.path.exists(cpath) else {}
                counts[f"seen{n}"] = counts.get(f"seen{n}", 0) + 1
                json.dump(counts, open(cpath, "w"))
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            if counts[f"seen{n}"] <= int(r_after):
                continue
        if r_times:
            cpath = STATE_PATH + ".failcounts"
            lock = open(cpath + ".lock", "a+")
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                counts = json.load(open(cpath)) if os.path.exists(cpath) else {}
                counts[str(n)] = counts.get(str(n), 0) + 1
                json.dump(counts, open(cpath, "w"))
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            if counts[str(n)] > int(r_times):
                continue
        return r_code or "AccessDenied"
    return None


def happened(call):
    """True when the call log already holds a call "<tool> <call>" (for example "eksctl delete
    nodegroup"): a world object with "ChangeAfterCall" shows its "RecheckTags" from then on, so a
    test can change a resource's owner between discovery and the delete."""
    if not call or not LOG_PATH or not os.path.exists(LOG_PATH):
        return False
    with open(LOG_PATH) as f:
        for line in f:
            e = json.loads(line)
            if f"{e['tool']} {e['call']}" == call:
                return True
    return False


def tagmap(tags):
    if isinstance(tags, dict):
        return dict(tags)
    return {t["Key"]: t["Value"] for t in tags or []}


def taglist(m):
    return [{"Key": k, "Value": v} for k, v in m.items()]
