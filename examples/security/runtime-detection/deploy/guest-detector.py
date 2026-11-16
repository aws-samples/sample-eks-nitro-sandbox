"""In-guest runtime detector for a Nitro sandbox, built on the Linux audit subsystem.

The sandbox's guest kernel has no BTF, tracepoints or kprobes, so eBPF detectors such as
Falco (modern_ebpf) and Tetragon cannot load there. It does have the audit subsystem, which
this detector drives over netlink: it registers itself as the guest's audit daemon, adds
syscall rules for exec, open and connect, and prints one JSON alert to stdout for each event
that matches one of the rules below. It also prints a heartbeat every HEARTBEAT_SECONDS, so
a detector that was killed or stalled can be noticed by its silence.

It needs the guest's PID namespace (hostPID: true, which in a sandbox is the guest's, not the
node's) and CAP_AUDIT_CONTROL. Standard library only.
"""
import json
import os
import re
import socket
import struct
import sys
import time

AUDIT_SET, AUDIT_ADD_RULE, AUDIT_DEL_RULE, AUDIT_LIST_RULES = 1001, 1011, 1012, 1013
AUDIT_SYSCALL, AUDIT_PATH, AUDIT_SOCKADDR, AUDIT_CWD, AUDIT_EXECVE, AUDIT_EOE = (
    1300, 1302, 1306, 1307, 1309, 1320)
NLMSG_ERROR, NLMSG_DONE = 2, 3
AUDIT_FILTER_TASK, AUDIT_FILTER_EXIT, AUDIT_FILTER_EXCLUDE, AUDIT_FILTER_PREPEND = 0x01, 0x04, 0x05, 0x10
AUDIT_NEVER, AUDIT_ALWAYS = 0, 2
AUDIT_PID, AUDIT_ARCH, AUDIT_MSGTYPE, AUDIT_FILTERKEY = 0, 11, 12, 210
AUDIT_EQUAL, AUDIT_NOT_EQUAL, AUDIT_LESS_THAN = 0x40000000, 0x30000000, 0x10000000
AUDIT_ARCH_X86_64 = 0xC000003E
# x86_64 syscall numbers: the rules below audit only these.
# shortcut: openat2 is left out, because its flags sit behind a pointer (struct open_how);
# add it with the AUDIT_OPENAT2 record (type 1337) if a workload uses it.
SYSCALLS = {"execve": 59, "execveat": 322, "open": 2, "openat": 257, "creat": 85,
            "connect": 42}
KEY = "runtime-detection"
HEARTBEAT_SECONDS = int(os.environ.get("HEARTBEAT_SECONDS", "60"))

SHELLS = {"sh", "bash", "dash", "zsh", "ash", "ksh"}
SENSITIVE_FILES = {"/etc/shadow", "/etc/sudoers", "/etc/pam.conf"}
O_WRONLY, O_RDWR, O_CREAT, O_TRUNC = 0o1, 0o2, 0o100, 0o1000


def emit(record):
    print(json.dumps(record, sort_keys=True), flush=True)


def nl_send(sock, msg_type, payload, seq, flags=0x1 | 0x4):  # NLM_F_REQUEST | NLM_F_ACK
    sock.send(struct.pack("=IHHII", 16 + len(payload), msg_type, flags, seq, 0) + payload)


def nl_ack(sock, allowed=()):
    """Read the kernel's ack for the last request; raise on an error not in `allowed`."""
    while True:
        data = sock.recv(65536)
        _, msg_type, _, _, _ = struct.unpack("=IHHII", data[:16])
        if msg_type == NLMSG_ERROR:
            err = -struct.unpack("=i", data[16:20])[0]
            if err and err not in allowed:
                raise OSError(err, os.strerror(err))
            return


def list_rules(sock):
    """Return the raw audit_rule_data of every rule loaded in the guest."""
    nl_send(sock, AUDIT_LIST_RULES, b"", 3, flags=0x1)  # the reply ends in NLMSG_DONE
    rules = []
    while True:
        data, off = sock.recv(65536), 0
        while off < len(data):
            length, msg_type = struct.unpack("=IH", data[off:off + 6])
            if msg_type == NLMSG_DONE:
                return rules
            if msg_type == NLMSG_ERROR:
                raise OSError("could not list the audit rules")
            if msg_type == AUDIT_LIST_RULES:  # skip audit records that arrive meanwhile
                rules.append(data[off + 16:off + length])
            off += (length + 3) & ~3


def blocks_syscall_records(body):
    """The guest image ships rules that keep syscall records from ever being made:
    `-a never,task` (no audit context for any new task) and an exclude rule for every
    message type below 1400. These two are what this detector removes."""
    flags, action, count = struct.unpack("=III", body[:12])
    fields = struct.unpack("=64I", body[268:524])[:count]
    values = struct.unpack("=64I", body[524:780])[:count]
    ops = struct.unpack("=64I", body[780:1036])[:count]
    if flags == AUDIT_FILTER_TASK and action == AUDIT_NEVER and count == 0:
        return True
    # The exclude filter drops a matching record whatever the rule's action.
    return (flags == AUDIT_FILTER_EXCLUDE
            and list(zip(fields, ops, values)) == [(AUDIT_MSGTYPE, AUDIT_LESS_THAN, 1400)])


def is_own_rule(body):
    """This detector's rule: its key is the rule's whole string buffer."""
    return body[1036:1040] == struct.pack("=I", len(KEY)) and body[1040:] == KEY.encode()


def rule(syscalls, self_pid):
    mask = [0] * 64
    for nr in syscalls:
        mask[nr // 32] |= 1 << (nr % 32)
    fields = [(AUDIT_ARCH, AUDIT_EQUAL, AUDIT_ARCH_X86_64),
              (AUDIT_PID, AUDIT_NOT_EQUAL, self_pid),
              (AUDIT_FILTERKEY, AUDIT_EQUAL, len(KEY))]
    pad = [0] * (64 - len(fields))
    # Prepended, so it is matched before the guest image's own `-a never,exit`.
    return struct.pack(
        "=III64I64I64I64II", AUDIT_FILTER_EXIT | AUDIT_FILTER_PREPEND, AUDIT_ALWAYS, len(fields), *mask,
        *([f[0] for f in fields] + pad), *([f[2] for f in fields] + pad),
        *([f[1] for f in fields] + pad), len(KEY)) + KEY.encode()


FIELD = re.compile(r'(\w+)=("[^"]*"|\S+)')


# Fields audit writes as a string chosen by the process: quoted when plain, hex otherwise.
STRING_FIELDS = {"comm", "exe", "name", "cwd"}


def decode(key, value):
    if value.startswith('"'):
        return value[1:-1]
    if key in STRING_FIELDS and re.fullmatch(r"(?:[0-9A-F]{2})+", value):
        try:
            return bytes.fromhex(value).decode("utf-8", "replace")
        except ValueError:
            pass
    return value


def parse(text):
    """Split one record into its serial and its fields."""
    head, _, body = text.partition("): ")
    serial = head.rsplit(":", 1)[-1]
    return serial, {k: decode(k, v) for k, v in FIELD.findall(body)}


def sockaddr(hexstr):
    raw = bytes.fromhex(hexstr)
    if len(raw) >= 8 and struct.unpack("<H", raw[:2])[0] == socket.AF_INET:
        return socket.inet_ntoa(raw[4:8]), struct.unpack(">H", raw[2:4])[0]
    return None


def classify(event, api_server, written):
    """Return (rule, output) alerts for one complete audit event. `written` holds the paths
    this pod's processes have opened for writing, so a later exec of one can be flagged."""
    sc = event.get(AUDIT_SYSCALL, [{}])[0]
    # A connect with a timeout is non-blocking, so it returns EINPROGRESS (-115) and then connects.
    if sc.get("key") != KEY or (sc.get("success") != "yes" and sc.get("exit") != "-115"):
        return []
    nr, exe = int(sc.get("syscall", -1)), sc.get("exe", "")
    cwd = event.get(AUDIT_CWD, [{}])[0].get("cwd", "/")
    paths = [p for p in event.get(AUDIT_PATH, []) if p.get("name") and p.get("nametype") != "PARENT"]
    names = [os.path.normpath(os.path.join(cwd, p["name"])) for p in paths]
    who = f"pid={sc.get('pid')} ppid={sc.get('ppid')} uid={sc.get('uid')} comm={sc.get('comm')} exe={exe}"
    alerts = []
    if nr in (SYSCALLS["execve"], SYSCALLS["execveat"]):
        if os.path.basename(exe) in SHELLS and sc.get("tty", "(none)") != "(none)":
            alerts.append(("Terminal shell in container", f"shell with a terminal tty={sc['tty']} {who}"))
        if exe in written:
            alerts.append(("Drop and execute new binary in container",
                           f"executed a file written after the container started {who}"))
    if nr in (SYSCALLS["open"], SYSCALLS["openat"], SYSCALLS["creat"]):
        flags = int(sc.get("a1" if nr == SYSCALLS["open"] else "a2", "0"), 16)
        writing = nr == SYSCALLS["creat"] or flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)
        for name in names:
            if writing:
                written.add(name)
                if len(written) > 4096:  # shortcut: bounded memory; drops an arbitrary path past 4096
                    written.pop()
            elif name in SENSITIVE_FILES:
                alerts.append(("Read sensitive file untrusted", f"file={name} {who}"))
    if nr == SYSCALLS["connect"] and AUDIT_SOCKADDR in event:
        dest = sockaddr(event[AUDIT_SOCKADDR][0].get("saddr", ""))
        if dest and dest == api_server:
            alerts.append(("Contact K8S API Server From Container",
                           f"connection={dest[0]}:{dest[1]} {who}"))
    return alerts


def main():
    api_server = (os.environ.get("KUBERNETES_SERVICE_HOST"),
                  int(os.environ.get("KUBERNETES_SERVICE_PORT", "443")))
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 9)  # NETLINK_AUDIT
    sock.bind((0, 0))
    # Become the guest's audit daemon, so audit records come to this socket, and raise the
    # queue from the guest's 64 records so a burst of opens does not stall the app.
    # struct audit_status: mask (ENABLED | PID | BACKLOG_LIMIT), enabled, failure, pid,
    # rate_limit, backlog_limit, then fields this call does not set.
    nl_send(sock, AUDIT_SET, struct.pack("=11I", 0x1 | 0x4 | 0x10, 1, 0, os.getpid(), 0, 8192,
                                         *[0] * 5), 1)
    nl_ack(sock)
    # Remove the guest image's two rules that suppress syscall records, and this
    # detector's own rule from an earlier start of the container, then add this rule.
    removed = []
    for body in list_rules(sock):
        ours = is_own_rule(body)
        if ours or blocks_syscall_records(body):
            nl_send(sock, AUDIT_DEL_RULE, body, 4)
            nl_ack(sock)
            removed.append("own rule from an earlier start" if ours else
                           "never,task" if body[:4] == struct.pack("=I", AUDIT_FILTER_TASK)
                           else "exclude msgtype<1400")
    nl_send(sock, AUDIT_ADD_RULE, rule(SYSCALLS.values(), os.getpid()), 2)
    nl_ack(sock)
    emit({"detector": "guest-audit", "status": "started", "rules": sorted(SYSCALLS),
          "removed_guest_rules": removed, "kernel": os.uname().release})
    sock.settimeout(HEARTBEAT_SECONDS)
    # Records of one syscall share a serial and end with AUDIT_EOE; records of two tasks can
    # interleave, so each event is collected under its serial until its EOE arrives.
    events, last_beat, written = {}, 0.0, set()

    def flush(event):
        for name, output in classify(event, api_server, written):
            emit({"detector": "guest-audit", "rule": name, "output": output,
                  "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})

    while True:
        if time.time() - last_beat >= HEARTBEAT_SECONDS:
            emit({"detector": "guest-audit", "heartbeat": True,
                  "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
            last_beat = time.time()
        try:
            data = sock.recv(65536)
        except socket.timeout:
            continue
        if len(data) < 16:
            continue
        _, msg_type, _, _, _ = struct.unpack("=IHHII", data[:16])
        if msg_type < AUDIT_SYSCALL or msg_type > 1399:
            continue
        try:
            serial, fields = parse(data[16:].split(b"\0", 1)[0].decode("utf-8", "replace"))
            if msg_type == AUDIT_EOE:
                flush(events.pop(serial, {}))
            else:
                events.setdefault(serial, {}).setdefault(msg_type, []).append(fields)
                if len(events) > 1024:  # shortcut: bounded memory; drops the oldest open event
                    events.pop(next(iter(events)))
        except (ValueError, struct.error) as err:  # a malformed record: skip it, keep watching
            emit({"detector": "guest-audit", "status": "skipped record", "error": str(err)})


if __name__ == "__main__":
    try:
        main()
    except OSError as err:
        emit({"detector": "guest-audit", "status": "failed", "error": str(err)})
        sys.exit(1)
