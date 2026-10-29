"""Does this guest let bubblewrap build the boundary at all? Run by scripts/setup.sh.

bubblewrap needs two things from the Nitro guest that are not there by default, and both
are pod settings rather than node settings: a non-zero `user.max_user_namespaces`, which
the pod's init container writes, and a container privileged enough for `bwrap` to mount a
private procfs. Without the first, `bwrap` fails with ENOSPC; without the second it gets
as far as the procfs mount and fails with EPERM.

Those failures are clear once you know what they mean and baffling otherwise, so setup
starts one real tool process through the real launcher and says what it found. It uses
`sandbox.run`, the same function the controller uses, rather than a copy of the argument
list: a copy would stop matching the launcher at its next edit and keep passing.
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, "/opt/analyst")
sys.path.insert(0, "/opt/bubblewrap")

from sandbox import pin, run  # noqa: E402

LIMIT = Path("/proc/sys/user/max_user_namespaces")


def main():
    limit = int(LIMIT.read_text())
    if limit <= 0:
        raise SystemExit(
            f"{LIMIT} is {limit} in this guest, so an unprivileged process cannot "
            "create a user namespace and bubblewrap cannot start. The analyst pod's "
            "enable-guest-userns init container is what sets it; check that it ran.")
    with tempfile.TemporaryDirectory(dir="/var/lib/analyst",
                                     prefix="preflight-") as workspace:
        for name in ("in", "out"):
            (Path(workspace) / name).mkdir()
        child = run(workspace, "inspect")["result"]
    print(json.dumps({"bubblewrap": pin(), "max_user_namespaces": limit,
                      "child_uid": child["uid"], "child_gid": child["gid"],
                      "child_cap_eff": child["status"]["CapEff"],
                      "child_no_new_privs": child["status"]["NoNewPrivs"],
                      "child_interfaces": child["interfaces"]}, indent=2))


if __name__ == "__main__":
    main()
