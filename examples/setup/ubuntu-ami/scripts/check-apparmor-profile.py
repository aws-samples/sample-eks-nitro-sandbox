#!/usr/bin/env python3
"""Check the sample's AppArmor profile text (a file path argument, default
manifests/ubuntu-ami-sample-profile next to this script's folder) for the rules the scoped-profile
pod needs. Comments are stripped and spacing is normalized before matching, and each rule is
matched as a whole line.

  * one `profile ubuntu-ami-sample-profile ... {` block, at the top level, closed by its own
    `}`, with the braces in the whole file balanced;
  * inside that block (its own rules, not a nested block's and not another profile's), the
    signal rules containerd's own default container profile carries
    (containerd contrib/apparmor/template.go): `signal (receive) peer=unconfined,`,
    `signal (receive) peer=runc,`, `signal (receive) peer=crun,` and
    `signal (send,receive) peer=<the profile's own name>,`. Without `peer=runc` AppArmor refuses
    runc's stop signals, and kubelet can never stop a pod under the profile;
  * inside that block, `audit deny /etc/shadow* w,`, the refusal test.sh shows;
  * every `deny` rule anywhere in the file is an `audit deny` rule, so each refusal logs a
    kernel DENIED line (a plain `deny` is silent).

Exit 0 with "APPARMOR PROFILE OK", or 1 with one FAIL line per problem. scripts/test-apparmor-checks.sh
runs it on the real profile and on broken copies.
"""
import os
import re
import sys

NAME = "ubuntu-ami-sample-profile"


def rules(text):
    out = []
    for line in text.splitlines():
        line = re.sub(r"#.*$", "", line)
        line = re.sub(r"\s+", " ", line).strip()
        line = re.sub(r"\(\s*", "(", re.sub(r"\s*\)", ")", line))
        line = re.sub(r"\s*,\s*(?=[a-z])", ",", line) if line.startswith("signal") else line
        if line:
            out.append(line)
    return out


def target_block(r):
    """The target profile's own rules (the lines one level inside its braces), and problems with
    the block structure: the header count, where it sits, whether it closes, the braces."""
    header = re.compile(rf"profile {re.escape(NAME)}( flags=\([^)]*\))? \{{")
    bad, own, depth, state = [], [], 0, "before"   # before -> inside -> after
    if sum(1 for l in r if header.fullmatch(l)) != 1:
        bad.append(f"no single `profile {NAME} ... {{` block")
    for l in r:
        if header.fullmatch(l) and state == "before":
            if depth != 0:
                bad.append(f"`profile {NAME}` is nested inside another block")
            state = "inside"
        elif state == "inside" and depth == 1 and l != "}":
            own.append(l)
        depth += l.count("{") - l.count("}")
        if depth < 0:
            bad.append("a `}` closes a block that was never opened (unbalanced braces)")
            depth = 0
        if state == "inside" and depth == 0:
            state = "after"
    if state == "inside":
        bad.append(f"the `profile {NAME}` block is never closed (unbalanced braces)")
    elif depth != 0:
        bad.append("a block is never closed (unbalanced braces)")
    return own, bad


def problems(text):
    r = rules(text)
    own, bad = target_block(r)
    for want in ("signal (receive) peer=unconfined,", "signal (receive) peer=runc,", "signal (receive) peer=crun,",
                 f"signal (send,receive) peer={NAME},"):
        if want not in own:
            bad.append(f"missing `{want}` in profile {NAME} (as in containerd's default container profile)")
    if "audit deny /etc/shadow* w," not in own:
        bad.append(f"missing `audit deny /etc/shadow* w,` in profile {NAME}")
    for l in r:
        if re.match(r"^deny\b", l):
            bad.append(f"`{l}` is a plain deny, which AppArmor does not log; use `audit deny`")
    return bad


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "manifests", NAME)
    with open(path) as f:
        bad = problems(f.read())
    for b in bad:
        print("FAIL: " + b)
    if bad:
        sys.exit(1)
    print(f"APPARMOR PROFILE OK: {path}: one closed profile block holding the signal rules for unconfined, runc, crun and itself; every deny is audit deny")


if __name__ == "__main__":
    main()
