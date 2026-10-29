"""Seccomp filters the application compiles, for bubblewrap to load.

This is the part of the boundary bubblewrap does not supply. `bwrap` has no syscall
allowlist of its own: `--add-seccomp-fd` takes a compiled BPF program on a file
descriptor and loads it into the child, and the caller is the one that decides what is in
it. So the policy below is this sample's, not bubblewrap's, and the page says so.

libseccomp does the compiling, through ctypes. Two things matter for reading the result
as evidence:

  * The syscall numbers the filter is built from and the numbers the probe calls come
    from the same resolver, `seccomp_syscall_resolve_name`, so the filter and the probe
    cannot disagree about which syscall a name means. A hard-coded number would be right
    on one architecture and silently wrong on another, and the probe would then look
    allowed because it had called something else.
  * A rule that cannot be compiled raises. A filter that quietly came out empty would
    make every "denied" check into a pass for the wrong reason.
"""
import ctypes
import errno
import tempfile
from contextlib import contextmanager

# The baseline every tool process gets. Each of these is a way for a process to reach
# outside its own execution: reading or writing another process's memory, attaching a
# debugger, changing the mount table, joining another namespace, loading a BPF program,
# or handling its own page faults in user space.
#
# This list is a sample's starting point and not a certified allowlist. It is a denylist,
# so a syscall nobody thought of is permitted; a production filter is usually built the
# other way round, by denying everything and naming what the workload needs.
BASELINE = ("ptrace", "process_vm_readv", "process_vm_writev", "bpf", "keyctl",
            "kexec_load", "mount", "umount2", "pivot_root", "setns", "userfaultfd")

SCMP_ACT_ALLOW = 0x7FFF0000


def _library():
    library = ctypes.CDLL("libseccomp.so.2")
    library.seccomp_init.argtypes = [ctypes.c_uint32]
    library.seccomp_init.restype = ctypes.c_void_p
    library.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
    library.seccomp_syscall_resolve_name.restype = ctypes.c_int
    library.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int,
                                         ctypes.c_uint]
    library.seccomp_rule_add.restype = ctypes.c_int
    library.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.seccomp_export_bpf.restype = ctypes.c_int
    library.seccomp_release.argtypes = [ctypes.c_void_p]
    return library


def syscall_number(name: str) -> int:
    """Resolve a syscall name for this architecture, the way the filter resolves it."""
    number = _library().seccomp_syscall_resolve_name(name.encode())
    if number < 0:
        raise RuntimeError(f"libseccomp does not know the syscall {name} on this "
                           "architecture")
    return number


@contextmanager
def compiled_filter(names=BASELINE):
    """Yield an open file descriptor holding a BPF filter that returns EPERM for names.

    The default action is allow, and each named syscall gets an errno return of EPERM.
    The caller passes the descriptor to bwrap with --add-seccomp-fd and keeps it open for
    the length of the call.
    """
    library = _library()
    context = library.seccomp_init(SCMP_ACT_ALLOW)
    if not context:
        raise RuntimeError("seccomp_init failed")
    try:
        for name in names:
            number = library.seccomp_syscall_resolve_name(name.encode())
            if number < 0:
                raise RuntimeError(f"libseccomp does not know the syscall {name}")
            # SCMP_ACT_ERRNO(EPERM): the child's call returns -EPERM instead of being
            # killed, which is what lets the tool process report the refusal as data.
            if library.seccomp_rule_add(context, 0x50000 | errno.EPERM, number, 0) != 0:
                raise RuntimeError(f"cannot compile a seccomp rule for {name}")
        with tempfile.TemporaryFile() as handle:
            if library.seccomp_export_bpf(context, handle.fileno()) != 0:
                raise RuntimeError("cannot export the compiled seccomp filter")
            handle.seek(0)
            yield handle
    finally:
        library.seccomp_release(context)
