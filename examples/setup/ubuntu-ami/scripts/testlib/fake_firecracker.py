#!/usr/bin/env python3
"""fake_firecracker.py: a stand-in for /usr/bin/firecracker v1.18.0, for scripts/test-smoke.sh.

It serves the Firecracker HTTP API on the Unix socket named by --api-sock (every other flag is
ignored) and answers 204 to a valid PUT. It checks each PUT body against the top level of the
v1.18.0 request schema of that endpoint, as upstream does (serde deny_unknown_fields): an unknown
field, a missing required field, a top-level value of the wrong type, a body that is not JSON or an
unknown endpoint is answered 400 with {"fault_message": ...}. It does not check inside list or
object values: upstream also refuses a malformed element, such as cpu_ids [true] or numa_nodes [{}]
in /enclave, which this stand-in answers 204. Its fidelity covers the request shapes 40-smoke.sh
sends, none of which holds a list or object value. After a 2xx InstanceStart it binds the /vsock
uds_path and answers "CONNECT 1024\\n" with "OK 1073741824\\n", the handshake the guest agent gives.

Python 3.9 compatible, standard library only, no subprocess. Environment:
  FAKE_FC_ROOTS=<dir>[:<dir>]  the only folders the fake looks at or binds in: a path a request
                             names (a kernel, a drive, the vsock socket) outside them is answered
                             400, and with none given every such path is
  FAKE_FC_LOG=<file>         append one JSON line per request: method, path, body, status
  FAKE_FC_STARTED=<file>     append one JSON line at start: pid and argv
  FAKE_FC_FAIL_PATH=<path>   answer 400 to a PUT on that path
  FAKE_FC_EXIT_AFTER_START=1 exit with status 1 right after answering InstanceStart
  FAKE_FC_HANDSHAKE=garbled  reply "garbled\\n" instead of OK
  FAKE_FC_HANDSHAKE=silent   accept the vsock connection and close it without a reply
  FAKE_FC_HANDSHAKE=none     never bind the vsock socket (the agent is unreachable)
  FAKE_FC_MAX_SECS=<n>       exit with status 3 after n seconds (default 300), so a fake a
                             broken test leaves behind does not run on
--schema prints the embedded request schemas as JSON and exits.
"""
import http.server
import json
import os
import signal
import socket
import socketserver
import sys
import threading

# The request schemas, embedded from the release's own spec, firecracker_spec-v1.18.0.yaml in
# release-v1.18.0-x86_64 (Firecracker v1.18.0), section "definitions". Every property each
# definition lists, with its type ($ref fields as the referenced definition's type), and its
# "required" list. Nothing else is accepted at the top level of a body; the elements of a list
# value and the fields of an object value are not checked (see the module docstring).
SCHEMAS = {
    "BootSource": {
        "required": ["kernel_image_path"],
        "fields": {"boot_args": "str", "initrd_path": "str", "kernel_image_path": "str"},
    },
    "Drive": {
        "required": ["drive_id", "is_root_device"],
        "fields": {
            "drive_id": "str", "partuuid": "str", "is_root_device": "bool", "cache_type": "str",
            "is_read_only": "bool", "discard": "bool", "path_on_host": "str",
            "rate_limiter": "obj", "io_engine": "str", "blk_size": "int", "topology": "obj",
            "socket": "str", "dmb_size_mib": "int",
        },
    },
    "EnclaveConfig": {
        "required": [],
        "fields": {
            "cpu_ids": "list", "debug_mode": "bool", "direct_mode": "bool",
            "cpu_overcommit": "bool", "cpu_accounting": "bool", "hotplug_mode": "bool",
            "numa_nodes": "list",
        },
    },
    "InstanceActionInfo": {
        "required": ["action_type"],
        "fields": {"action_type": "str"},
    },
    "MachineConfiguration": {
        "required": ["mem_size_mib", "vcpu_count"],
        "fields": {
            "cpu_template": "str", "smt": "bool", "mem_size_mib": "int",
            "track_dirty_pages": "bool", "vcpu_count": "int", "huge_pages": "str",
        },
    },
    "NetworkInterface": {
        "required": ["host_dev_name", "iface_id"],
        "fields": {
            "guest_mac": "str", "host_dev_name": "str", "iface_id": "str", "mtu": "int",
            "rx_rate_limiter": "obj", "tx_rate_limiter": "obj", "dmb_size_mib": "int",
        },
    },
    "Vsock": {
        "required": ["guest_cid", "uds_path"],
        "fields": {"guest_cid": "int", "uds_path": "str", "vsock_id": "str", "dmb_size_mib": "int"},
    },
}
# The enum and minimum constraints the same spec gives those fields.
ENUMS = {
    ("Drive", "cache_type"): ["Unsafe", "Writeback"],
    ("Drive", "io_engine"): ["Sync", "Async"],
    ("InstanceActionInfo", "action_type"): ["FlushMetrics", "InstanceStart", "SendCtrlAltDel"],
    ("MachineConfiguration", "huge_pages"): ["None", "Transparent", "2M"],
    ("MachineConfiguration", "cpu_template"): ["C3", "T2", "T2S", "T2CL", "T2A", "V1N1", "None"],
}
MINIMUMS = {("MachineConfiguration", "vcpu_count"): 1, ("Vsock", "guest_cid"): 3}
# The PUT endpoints 40-smoke.sh uses, and the definition each one's body is.
ENDPOINTS = {
    "/machine-config": "MachineConfiguration",
    "/boot-source": "BootSource",
    "/vsock": "Vsock",
    "/enclave": "EnclaveConfig",
    "/actions": "InstanceActionInfo",
}
ID_ENDPOINTS = {"/drives/": ("Drive", "drive_id"), "/network-interfaces/": ("NetworkInterface", "iface_id")}

TYPES = {
    "str": lambda v: isinstance(v, str),
    "bool": lambda v: isinstance(v, bool),
    "int": lambda v: isinstance(v, int) and not isinstance(v, bool) and v >= 0,
    "list": lambda v: isinstance(v, list),
    "obj": lambda v: isinstance(v, dict),
}
DESERIALIZE = "An error occurred when deserializing the json body of a request: "
HANDSHAKE_REPLY = b"OK 1073741824\n"


def check_body(defn, body):
    """None when body is a valid <defn>, else the fault message upstream would give."""
    schema = SCHEMAS[defn]
    if not isinstance(body, dict):
        return DESERIALIZE + "invalid type: %s, expected struct %s." % (type(body).__name__, defn)
    for key in body:
        if key not in schema["fields"]:
            return DESERIALIZE + "unknown field `%s`, expected one of %s." % (
                key, ", ".join("`%s`" % f for f in schema["fields"]))
    for key in schema["required"]:
        if key not in body:
            return DESERIALIZE + "missing field `%s`." % key
    for key, value in body.items():
        kind = schema["fields"][key]
        if not TYPES[kind](value):
            return DESERIALIZE + "invalid type for `%s`: %r, expected %s." % (key, value, kind)
        allowed = ENUMS.get((defn, key))
        if allowed is not None and value not in allowed:
            return DESERIALIZE + "unknown variant `%s`, expected one of %s." % (
                value, ", ".join("`%s`" % a for a in allowed))
        low = MINIMUMS.get((defn, key))
        if low is not None and value < low:
            return DESERIALIZE + "`%s` is %d, the minimum is %d." % (key, value, low)
    return None


class State:
    def __init__(self):
        self.config = {}
        self.started = False
        self.vsock = None
        self.lock = threading.Lock()


STATE = State()


def confined(p):
    """The real path of <p> when it lies inside one of the FAKE_FC_ROOTS folders, else None. A path in
    a request is the client's choice, so the fake looks only inside the fixture folders the test
    names (the real path, links resolved, below a root's real path), never anywhere a request says."""
    full = os.path.realpath(p)
    for root in os.environ.get("FAKE_FC_ROOTS", "").split(":"):
        if root and full.startswith(os.path.realpath(root) + os.sep):
            return full
    return None


def outside(key, value):
    return "%s %r is outside the folders this fake may look at (FAKE_FC_ROOTS)" % (key, value)


def record(entry):
    path = os.environ.get("FAKE_FC_LOG")
    if path:
        with open(path, "a") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")


def vsock_serve(listener, mode):
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        with conn:
            conn.settimeout(2)
            line = b""
            try:
                while not line.endswith(b"\n") and len(line) < 64:
                    chunk = conn.recv(64 - len(line))
                    if not chunk:
                        break
                    line += chunk
                if line == b"CONNECT 1024\n" and mode != "silent":
                    conn.sendall(b"garbled\n" if mode == "garbled" else HANDSHAKE_REPLY)
            except OSError:
                pass


def start_vsock():
    mode = os.environ.get("FAKE_FC_HANDSHAKE", "")
    if mode == "none" or STATE.config.get("/vsock") is None:
        return
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(confined(STATE.config["/vsock"]["uds_path"]))
    listener.listen(8)
    STATE.vsock = listener
    threading.Thread(target=vsock_serve, args=(listener, mode), daemon=True).start()


def decide(path, body):
    """(status, fault message or None, action after answering) for one parsed PUT."""
    if path in ENDPOINTS:
        defn, want_id = ENDPOINTS[path], None
    else:
        for prefix, (defn, id_field) in ID_ENDPOINTS.items():
            if path.startswith(prefix) and len(path) > len(prefix) and "/" not in path[len(prefix):]:
                want_id = (id_field, path[len(prefix):])
                break
        else:
            return 400, "Invalid request method and/or path: PUT %s." % path, None
    fault = check_body(defn, body)
    if fault:
        return 400, fault, None
    if want_id and body[want_id[0]] != want_id[1]:
        return 400, "The id from the path does not match the id from the body!", None
    if path == "/actions":
        if body["action_type"] != "InstanceStart":
            return 204, None, None
        if STATE.started:
            return 400, "The requested operation is not supported after starting the microVM.", None
        if "/boot-source" not in STATE.config:
            return 400, "Cannot start microvm without kernel configuration.", None
        return 204, None, "start"
    if STATE.started:
        return 400, "The requested operation is not supported after starting the microVM.", None
    if defn == "BootSource":
        for key in ("kernel_image_path", "initrd_path"):
            if key in body:
                full = confined(body[key])
                if full is None:
                    return 400, outside(key, body[key]), None
                if not os.path.isfile(full):
                    return 400, "The %s file cannot be opened: No such file or directory (os error 2)" % key, None
    if defn == "Drive" and "socket" not in body:
        if "path_on_host" not in body:
            return 400, "Unable to create the block device: cannot open the backing file None", None
        full = confined(body["path_on_host"])
        if full is None:
            return 400, outside("path_on_host", body["path_on_host"]), None
        if not os.path.exists(full):
            return 400, "Unable to create the block device: cannot open the backing file %r" % body["path_on_host"], None
    if defn == "Vsock" and confined(body["uds_path"]) is None:
        return 400, outside("uds_path", body["uds_path"]), None
    STATE.config[path] = body
    return 204, None, None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 10

    def log_message(self, *args):  # the default one indexes client_address, empty on AF_UNIX
        pass

    def answer(self, entry, status, fault):
        entry["status"] = status
        record(entry)
        self.send_response(status)
        if fault is None:
            self.end_headers()
            return
        data = json.dumps({"fault_message": fault}).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode(errors="replace")
        entry = {"method": self.command, "path": self.path, "body": None}
        try:
            entry["body"] = json.loads(raw)
            parsed = True
        except ValueError as e:
            entry["raw"] = raw
            parsed, err = False, e
        with STATE.lock:
            if self.command != "PUT":
                return self.answer(entry, 400, "Invalid request method and/or path: %s %s." % (self.command, self.path))
            if os.environ.get("FAKE_FC_FAIL_PATH") == self.path:
                return self.answer(entry, 400, "fault injected by FAKE_FC_FAIL_PATH for %s" % self.path)
            if not parsed:
                return self.answer(entry, 400, DESERIALIZE + str(err))
            status, fault, action = decide(self.path, entry["body"])
            if action == "start":
                STATE.started = True
                if os.environ.get("FAKE_FC_EXIT_AFTER_START") != "1":
                    start_vsock()
            self.answer(entry, status, fault)
            if action == "start" and os.environ.get("FAKE_FC_EXIT_AFTER_START") == "1":
                self.wfile.flush()
                os._exit(1)

    do_PUT = do_GET = do_PATCH = do_POST = do_DELETE = handle_any


class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = False


def on_sigterm(signum, frame):
    raise SystemExit(0)


def main(argv):
    if "--schema" in argv:
        print(json.dumps({"definitions": SCHEMAS, "endpoints": ENDPOINTS,
                          "enums": {"%s.%s" % k: v for k, v in ENUMS.items()}}, sort_keys=True))
        return 0
    if "--api-sock" not in argv or argv.index("--api-sock") + 1 >= len(argv):
        print("fake firecracker: --api-sock PATH is required", file=sys.stderr)
        return 1
    api_sock = argv[argv.index("--api-sock") + 1]
    started = os.environ.get("FAKE_FC_STARTED")
    if started:
        with open(started, "a") as f:
            f.write(json.dumps({"pid": os.getpid(), "argv": argv}) + "\n")
    if os.path.exists(api_sock):
        print("fake firecracker: Failed to open the API socket at %s: Address in use" % api_sock, file=sys.stderr)
        return 1
    signal.signal(signal.SIGTERM, on_sigterm)
    max_secs = float(os.environ.get("FAKE_FC_MAX_SECS", "300"))
    timer = threading.Timer(max_secs, os._exit, args=(3,))
    timer.daemon = True
    timer.start()
    server = UnixHTTPServer(api_sock, Handler)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        if STATE.vsock is not None:
            STATE.vsock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
