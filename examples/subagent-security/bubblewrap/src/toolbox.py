"""The tool process bubblewrap starts: the shared worker, plus this sample's probes.

Every Subagent security sample runs the same program for the reader, the evaluator and
the writer, `analyst/src/worker.py`, so that the work the three roles do is identical
across the samples and only the layer around them differs. A sample that needs extra
probes passes them in rather than editing that file, which is what happens here:

    worker.main(extra=PROBES)

The shared worker reports a denied open or socket as structured data and lets everything
else raise, but the errnos it recognises are EACCES and EPERM. The refusals bubblewrap
produces are different ones, and the difference is the point:

  * ENOENT, not EACCES, for a path nobody mounted. The child's filesystem is built up
    from the mounts the launcher names, so a path outside that list does not exist for
    the child at all. A permission error would mean the path was there and the mode said
    no, which is a claim about file permissions rather than about the mount namespace.
  * EROFS, not EACCES, for a write to the read-only input. The file's mode lets this user
    write it, and the controller does so in the same run; what refuses the child is the
    read-only bind mount.
  * ENETUNREACH for a connection, because the private network namespace has no route,
    not because something filtered the destination.

So the probes below report the errno of the one operation they perform, and the
controller checks for the exact errno it asked for. Anything that is not an OSError from
that operation still raises, leaves no result line, and fails the run: a probe that
crashed must never read as a refusal.
"""
import ctypes
import errno
import os
import socket
from pathlib import Path

import worker

CLONE_NEWUSER = 0x10000000
NAMESPACE_KINDS = ("user", "pid", "net", "ipc", "uts", "mnt", "cgroup")

# /proc/self/status lines worth reporting. All five capability sets are reported, because
# they say different things and "no capabilities" is a statement about all of them: CapEff
# is what the process can use now; CapPrm what it may move into CapEff; CapInh is eligible
# to contribute across an exec when the executable's own file capabilities permit it;
# CapAmb is the set preserved across an ordinary, unprivileged exec; and CapBnd limits what
# this process and its descendants can gain from file privilege during an exec. CapBnd is
# not a statement about the current sets: an empty bounding set beside a non-empty
# permitted set is a coherent state, so the controller checks each set rather than reading
# one off another.
# Seccomp_filters is the number of filters loaded, which is how stacking is visible
# directly rather than inferred from a refusal.
STATUS_FIELDS = ("Uid", "Gid", "CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb",
                 "NoNewPrivs", "Seccomp", "Seccomp_filters")


def failure(error: OSError) -> dict:
    return {"errno": error.errno,
            "error": errno.errorcode.get(error.errno, "UNKNOWN")}


def read_status(path="/proc/self/status") -> dict:
    fields = dict(line.split(":", 1) for line in Path(path).read_text().splitlines()
                  if ":" in line)
    return {name: fields[name].strip() for name in STATUS_FIELDS if name in fields}


def probe_inspect(args):
    """Report who this process is, what it may do, and what it can see of the network.

    Nothing here is a refusal: it is the reading the controller compares against its own,
    so that "the child is not the controller" is measured rather than assumed.
    """
    return {
        "uid": os.getuid(), "gid": os.getgid(), "pid": os.getpid(),
        "hostname": socket.gethostname(),
        "status": read_status(),
        "uid_map": Path("/proc/self/uid_map").read_text().split(),
        "gid_map": Path("/proc/self/gid_map").read_text().split(),
        "namespaces": {kind: os.readlink(f"/proc/self/ns/{kind}")
                       for kind in NAMESPACE_KINDS},
        "interfaces": sorted(name for _, name in socket.if_nameindex()),
        "environment": sorted(os.environ),
        "mounts": sorted({line.split()[1] for line
                          in Path("/proc/self/mounts").read_text().splitlines()}),
    }


def probe_status(args):
    """Report /proc/self/status and nothing else.

    `inspect` above would do, except that it calls socket.gethostname(), which is uname();
    one of the two filters the page stacks blocks uname, so under those filters `inspect`
    reports a refusal instead of a reading. This probe makes no syscall either filter
    names, so it is the one that can count the filters that are loaded.
    """
    return {"status": read_status()}


def probe_read_file(args):
    """Open one path for reading. Both directions of the read boundary go through here.

    Only the open is inside the try, and that is deliberate. Every refusal this probe is
    named for happens at the open: ENOENT for a path the mount list does not contain,
    EACCES for one the mode refuses. Anything that goes wrong *after* a successful open is
    not a refusal, it is a fault, and it has to raise so that the run fails instead of
    recording it as the boundary working. An earlier version had the read and the stat()
    inside the try as well, so a file that opened and then failed to read came back as
    though the read had been refused.

    The device and inode are reported on success, from the open descriptor rather than by
    re-resolving the path, so that the controller can show the file the child read through
    /input is its own file and not a copy that happens to match. Both numbers, because an
    inode number is unique only within one filesystem. That identity is what makes the
    read-only refusal attributable to the bind mount: the same file, the same UID,
    writable on one side of the mount and EROFS on the other.
    """
    try:
        handle = Path(args[0]).open("rb")
    except OSError as error:
        return failure(error)
    with handle:
        text = handle.read().decode()
        identity = os.fstat(handle.fileno())
    return {"text": text, "device": identity.st_dev, "inode": identity.st_ino}


def probe_write_file(args):
    """Write one path. Both directions of the write boundary go through here.

    As above, only the open is inside the try: EROFS on a read-only bind mount and EACCES
    on a mode that refuses both happen there. A write that fails after the file is open is
    a fault and raises.
    """
    path, text = Path(args[0]), args[1]
    try:
        handle = path.open("w")
    except OSError as error:
        return failure(error)
    with handle:
        handle.write(text)
    return {"written": str(path)}


def probe_connect(args):
    """Open a TCP connection to an address the controller has already reached itself."""
    host, port = args[0], int(args[1])
    try:
        with socket.create_connection((host, port), timeout=5):
            return {"connected": True}
    except OSError as error:
        return failure(error)


def probe_unshare(args):
    """Try to create a further user namespace.

    Called twice by the controller: once in a child started without
    --disable-userns, where it has to succeed, and once in a child started with it,
    where it has to fail. Without the first call, a kernel that refused user namespaces
    outright would look exactly like bubblewrap's switch working.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.unshare(CLONE_NEWUSER) != 0:
        return failure(OSError(ctypes.get_errno(), "unshare(CLONE_NEWUSER)"))
    return {"created": True}


def probe_syscall(args):
    """Make one syscall by number, so a seccomp filter's effect is observable.

    The number comes from the controller, which resolved it with the same libseccomp
    function that compiled the filter. A number hard-coded here could name one syscall on
    the architecture the filter was built for and another one at runtime, and the call
    would then look permitted because it was not the call the filter names.

    syscall() is variadic, so the argument types are set explicitly: passing a Python int
    for a long parameter is the kind of mismatch that silently calls the wrong number.
    """
    number = int(args[0])
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    buffer = ctypes.create_string_buffer(4096)
    ctypes.set_errno(0)
    if libc.syscall(ctypes.c_long(number), buffer) == -1:
        return failure(OSError(ctypes.get_errno(), f"syscall {number}"))
    return {"called": number}


PROBES = {
    "inspect": probe_inspect,
    "status": probe_status,
    "read-file": probe_read_file,
    "write-file": probe_write_file,
    "connect-to": probe_connect,
    "unshare": probe_unshare,
    "syscall": probe_syscall,
}


if __name__ == "__main__":
    worker.main(extra=PROBES)
