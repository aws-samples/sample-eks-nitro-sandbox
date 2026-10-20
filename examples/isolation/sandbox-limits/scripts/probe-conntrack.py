#!/usr/bin/env python3
# Per-pod outbound connection-limit probe.
#
# It opens as many concurrent outbound TCP connections to a fixed sink IP:port
# as it can, holding each one open, and reports the plateau: the count at which
# new connections start failing while the established ones keep working. That is
# the documented failure shape of the per-pod outbound connection limit. Once
# the sandbox holds its cap of outbound flows, the next connection-initiating
# packet is dropped, so connect() hangs and times out rather than being refused
# at once. The distinction is the discriminator: a refused connection is
# instant, a dropped packet blocks for the connect timeout.
#
# It connects to a raw IP passed in TARGET_IP and performs no name lookup, so it
# cannot reach the sibling DNS query-rate limit. The only thing it exercises is
# outbound flows.
#
# It is run from the operator side with `kubectl exec -i <pod> -- python3 -`, so
# there is nothing to build or copy into the pod.
#
# Reading the counter, not just the symptom: the guest kernel tracks each
# outbound flow in its own connection-tracking table, so
# /proc/sys/net/netfilter/nf_conntrack_count rises with the established
# connections and plateaus at the cap. The probe samples it the moment the first
# new connection is dropped, so the plateau can be read as a table at its limit,
# not as one failed connection that any network fault could produce.
#
# Design notes that keep the measurement honest:
#   * Connects are sequential and blocking, one at a time, so the sink's accept
#     queue never fills faster than the sink drains it; the ordinary control
#     driving this same probe against the same sink certifies the sink is not
#     the bottleneck.
#   * Every held socket stays open for the life of the probe process, so each
#     pins exactly one established flow. When the process exits the sockets close
#     and the entries drain, so back-to-back runs do not accumulate.
#   * It raises its own open-file limit first, so file-descriptor exhaustion can
#     never be mistaken for the connection limit.
#   * A run of consecutive failures declares the plateau, so one transient error
#     mid-run does not end the probe early.
#
# The machine-readable summary is the last line:
#   RESULT established=<int> first_fail_at=<int|-1> errno=<NAME> ct_at_plateau=<int> ct_final=<int>
import os, socket, sys, errno, time

TARGET_IP = os.environ["TARGET_IP"]
TARGET_PORT = int(os.environ.get("TARGET_PORT", "9000"))
MAX_CONN = int(os.environ.get("MAX_CONN", "6000"))
CONNECT_TIMEOUT = float(os.environ.get("CONNECT_TIMEOUT", "2"))
FAIL_STREAK = int(os.environ.get("FAIL_STREAK", "5"))  # consecutive fails => plateau

# Raise the open-file soft limit to the hard limit so fd exhaustion (a default
# soft limit of 1024 in some images) can never be mistaken for the connection
# limit.
try:
    import resource
    hard = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
    resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
except Exception:
    pass


def ct_count():
    try:
        with open("/proc/sys/net/netfilter/nf_conntrack_count") as f:
            return int(f.read().strip())
    except Exception:
        return -1


held = []
first_fail_at = None
first_fail_errno = None
ct_at_plateau = -1
streak = 0
# Candidate metrics for the current consecutive-failure streak. They are only
# promoted to the reported plateau once FAIL_STREAK consecutive failures confirm
# a sustained plateau, and are discarded the moment a connection succeeds again,
# so a lone transient drop mid-run never poisons the plateau evidence.
cand_at = None
cand_errno = None
cand_ct = -1
t0 = time.time()
for i in range(MAX_CONN):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(CONNECT_TIMEOUT)
    try:
        s.connect((TARGET_IP, TARGET_PORT))
        held.append(s)
        streak = 0  # a success ends any nascent streak: a transient is not the cap
    except (socket.timeout, OSError) as e:
        en = errno.ETIMEDOUT if isinstance(e, socket.timeout) else getattr(e, "errno", None)
        if streak == 0:  # start of a new streak: snapshot the candidate plateau
            cand_at = len(held)
            cand_errno = en
            cand_ct = ct_count()
        streak += 1
        s.close()
        if streak >= FAIL_STREAK:  # sustained: this is the plateau
            first_fail_at = cand_at
            first_fail_errno = cand_errno
            ct_at_plateau = cand_ct
            break
    if i % 500 == 0:
        sys.stderr.write(
            f"  ..attempt {i} established={len(held)} ct_count={ct_count()} t={time.time()-t0:.1f}s\n"
        )
        sys.stderr.flush()

established = len(held)
elapsed = time.time() - t0
if first_fail_at is None:
    ename = "NONE"  # no sustained plateau: the offered budget was reached
elif first_fail_errno in errno.errorcode:
    ename = errno.errorcode[first_fail_errno]
else:
    ename = "UNKNOWN"  # a drop occurred but carried no errno: still a real drop
ffa = first_fail_at if first_fail_at is not None else -1
print(
    f"probe target={TARGET_IP}:{TARGET_PORT} max_attempt={MAX_CONN} "
    f"connect_timeout={CONNECT_TIMEOUT}s (raw IP, no DNS)"
)
print(
    f"established={established} first_fail_at={ffa} errno={ename} "
    f"ct_at_plateau={ct_at_plateau} ct_final={ct_count()} elapsed={elapsed:.1f}s"
)
print(
    f"RESULT established={established} first_fail_at={ffa} errno={ename} "
    f"ct_at_plateau={ct_at_plateau} ct_final={ct_count()}"
)
