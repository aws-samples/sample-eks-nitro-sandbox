#!/usr/bin/env python3
"""Check the sample's AppArmor profile text (a file path argument, default
manifests/ubuntu-ami-sample-profile next to this script's folder) for the rules the scoped-profile
pod needs. Comments are stripped and spacing is normalized before matching, and each rule is
matched as a whole line.

  * one `profile ubuntu-ami-sample-profile ... {` block;
  * the signal rules containerd's own default container profile carries
    (containerd contrib/apparmor/template.go): `signal (receive) peer=unconfined,`,
    `signal (receive) peer=runc,` and `signal (send,receive) peer=<the profile's own name>,`.
    Without `peer=runc` AppArmor refuses runc's stop signals, and kubelet can never stop a pod
    under the profile;
  * `audit deny /etc/shadow* w,`, the refusal test.sh shows;
  * every `deny` rule is an `audit deny` rule, so each refusal logs a kernel DENIED line
    (a plain `deny` is silent).

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


def problems(text):
    r = rules(text)
    bad = []
    if sum(1 for l in r if re.fullmatch(rf"profile {re.escape(NAME)}( flags=\([^)]*\))? \{{", l)) != 1:
        bad.append(f"no single `profile {NAME} ... {{` block")
    for want in ("signal (receive) peer=unconfined,", "signal (receive) peer=runc,",
                 f"signal (send,receive) peer={NAME},"):
        if want not in r:
            bad.append(f"missing `{want}` (as in containerd's default container profile)")
    if "audit deny /etc/shadow* w," not in r:
        bad.append("missing `audit deny /etc/shadow* w,`")
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
    print(f"APPARMOR PROFILE OK: {path}: signal rules for unconfined, runc and itself; every deny is audit deny")


if __name__ == "__main__":
    main()
