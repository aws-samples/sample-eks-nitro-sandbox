"""The bwrap launcher: the trusted controller assembles every argument here.

bubblewrap has no configuration file and no profile format. The boundary around a tool
process *is* the argument list `bwrap` is started with, so this module is the whole of
this sample's confinement policy, and the page shows the list it produces.

Two properties of that list are deliberate and worth keeping if you copy this:

  * Nothing in it comes from a model, from a supplier document or from a tool's own
    output. `command()` takes a workspace directory and a fixed set of switches; the
    caller may append `extra` arguments, and the only caller is the controller.
  * The mounts are named one at a time. There is no "bind everything and then exclude":
    the child's filesystem starts empty and holds exactly what is listed below, which is
    why a path nobody mounted comes back as ENOENT rather than as a permission error.

`--unshare-all` is not used, because it is the best-effort form: it skips a namespace the
kernel will not give it and carries on. Each namespace this sample claims is named
individually, so a kernel that refuses one fails the call instead of quietly running
without it.
"""
import json
import os
import subprocess
import tempfile
from pathlib import Path

from filters import compiled_filter
from worker import MARKER

# The shared analyst's code and fixtures, and this sample's own tool entry point. Both
# are bound read-only, so a tool process cannot change the code the next one will run.
ANALYST_CODE = Path("/opt/analyst")
LAYER_CODE = Path("/opt/bubblewrap")
TOOL = LAYER_CODE / "toolbox.py"

# Claimed one at a time, for the reason in the module docstring. "user" has to be in the
# list: every other namespace here is created by an unprivileged process only because it
# gets a user namespace first.
NAMESPACES = ("user", "pid", "net", "ipc", "uts")

HOSTNAME = "bubblewrap-analyst"
CHILD_HOME = "/home/analyst"
CHILD_PATH = "/usr/local/bin:/usr/bin:/bin"
TMPFS_BYTES = 16 * 1024 * 1024

# The child's whole environment. --clearenv drops everything the controller holds,
# including the AWS credential variables and the Region, and these five are put back by
# name. None of them is a credential, so none of them is a value that must not appear on
# a command line.
CHILD_ENVIRONMENT = (
    ("PATH", CHILD_PATH),
    ("HOME", CHILD_HOME),
    ("LANG", "C.UTF-8"),
    ("PYTHONPATH", f"{ANALYST_CODE}:{LAYER_CODE}"),
    ("PYTHONDONTWRITEBYTECODE", "1"),
)


def command(workspace, *, extra=(), disable_userns=True):
    """The argument list for one tool process, bar the file descriptors and the action.

    workspace is the role's own directory: its `in` becomes /input read-only and its
    `out` becomes /output read-write. disable_userns is a parameter because the page
    needs the control case: the same call with the two --*-userns switches left out, to
    show that what refuses a nested user namespace is those switches and not the kernel.
    """
    workspace = Path(workspace)
    arguments = ["bwrap", *(f"--unshare-{name}" for name in NAMESPACES)]
    if disable_userns:
        # --disable-userns sets the child's own user-namespace limit to zero, so the tool
        # cannot build a further namespace to work from. --assert-userns-disabled makes
        # bwrap fail rather than continue if it could not do that.
        arguments += ["--disable-userns", "--assert-userns-disabled"]
    arguments += [
        "--uid", "1000", "--gid", "1000",
        # Drops the capability bounding set, not only the effective set, so no exec in
        # the child can gain one back. bwrap also sets no_new_privs.
        "--cap-drop", "ALL",
        "--new-session", "--die-with-parent", "--hostname", HOSTNAME,
        "--clearenv",
    ]
    for name, value in CHILD_ENVIRONMENT:
        arguments += ["--setenv", name, value]
    arguments += [
        # The interpreter and its libraries, read-only. /usr/local is inside /usr, which
        # is where the base image keeps python3.
        "--ro-bind", "/usr", "/usr",
        "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
        "--ro-bind", str(ANALYST_CODE), str(ANALYST_CODE),
        "--ro-bind", str(LAYER_CODE), str(LAYER_CODE),
        # A procfs for this child's own PID namespace, and a minimal /dev. The private
        # procfs is why the child cannot read another process's /proc entries.
        "--proc", "/proc", "--dev", "/dev",
        "--dir", CHILD_HOME,
        # --perms and --size apply to the operation that follows them.
        "--perms", "0700", "--size", str(TMPFS_BYTES), "--tmpfs", "/tmp",
        "--ro-bind", str(workspace / "in"), "/input",
        "--bind", str(workspace / "out"), "/output",
        "--chdir", "/output",
    ]
    return arguments + list(extra)


def run(workspace, action, *arguments, extra=(), fds=(), disable_userns=True,
        timeout=60):
    """Start one tool process and return its one structured result.

    Three things have to hold before the result is handed back, and each of them is here
    so that a broken call can never read as a successful refusal:

      * bwrap exits zero. A failure to set up the boundary, or a child that crashed,
        does not get to look like a denial.
      * The child printed exactly one result line. The shared worker prints one and only
        one, so zero lines or two mean something else wrote to stdout.
      * bwrap's own JSON status carries exactly one child exit record and it is zero.
        That comes from bwrap rather than from the child's own output. Exactly one, not
        "one of them was zero": a status holding both a zero and a non-zero exit is not a
        successful call, and reading it with any() would have called it one.
    """
    with tempfile.TemporaryFile() as status, compiled_filter() as baseline:
        args = command(workspace, extra=extra, disable_userns=disable_userns)
        # The baseline filter is loaded for every tool process. --add-seccomp-fd may be
        # given more than once and the filters stack, which is what the page's two extra
        # filters show.
        args += ["--add-seccomp-fd", str(baseline.fileno()),
                 "--json-status-fd", str(status.fileno()),
                 "--", "python3", str(TOOL), action, *map(str, arguments)]
        completed = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout,
            pass_fds=(*fds, status.fileno(), baseline.fileno()),
            # bwrap itself is started with almost nothing, so a variable the controller
            # holds cannot reach the child by being forgotten in --clearenv.
            env={"PATH": os.environ["PATH"]})
        status.seek(0)
        records = [json.loads(line) for line in status if line.strip()]
    if completed.returncode != 0:
        raise RuntimeError(
            f"bwrap {action} exited {completed.returncode}, so no boundary was "
            f"established and nothing it printed is evidence: "
            f"{completed.stderr[-1600:]}")
    results = [line.removeprefix(MARKER) for line in completed.stdout.splitlines()
               if line.startswith(MARKER)]
    if len(results) != 1:
        raise RuntimeError(f"bwrap {action} printed {len(results)} result lines, "
                           f"expected 1: {completed.stdout[-1600:]}")
    exits = [record["exit-code"] for record in records if "exit-code" in record]
    if exits != [0]:
        raise RuntimeError(f"bwrap reported {exits or 'no'} child exit code(s) for "
                           f"{action}, expected exactly one and zero: {records}")
    return {"result": json.loads(results[0]), "status": records}


def pin() -> dict:
    """The bubblewrap version and source commit baked into the image by the Dockerfile."""
    version = subprocess.run(["bwrap", "--version"], capture_output=True, text=True,
                             check=True).stdout.strip()
    pinned, commit = Path("/usr/local/share/bubblewrap-pin").read_text().split()
    return {"reported": version, "pinned_version": pinned, "source_commit": commit}
