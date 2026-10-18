#!/usr/bin/env python3
# Per-sandbox DNS query-rate probe.
#
# It offers a fixed rate of DNS A queries to the pod's own resolver for a fixed
# window and reports how many were answered. Below the per-sandbox limit every
# query is answered; above it, a fraction of queries silently go unanswered, so a
# caller sees intermittent resolution timeouts rather than a hard failure. That is
# the shape this sample shows.
#
# It is run from the operator side with `kubectl exec -i <pod> -- python3 - < this`
# so it needs no image build and nothing copied into the pod: a stock python image
# is all it needs.
#
# Design notes that keep the measurement honest:
#   * One connected UDP socket. A sender loop paces sends to the offered rate and a
#     receiver thread counts DISTINCT answered transaction IDs. Decoupling send
#     from receive means a dropped query never stalls the offered rate (a per-query
#     blocking recv would collapse the offered rate to about 1/timeout and never
#     exceed the limit, hiding the very symptom this shows).
#   * Transaction IDs are sequential (i & 0xFFFF), so distinct sends never collide
#     in the answered set: no undercount masquerading as drops.
#   * It queries a name that resolves, so a NOERROR answer comes back. The limit
#     sits on the sandbox network path in front of whatever resolver
#     /etc/resolv.conf names, so it meters every query that leaves the guest
#     regardless of resolver-side caching.
#
# The machine-readable summary is the LAST line, so a caller can read a numeric
# result rather than parse prose:
#   RESULT offered=<int> answered=<int> elapsed=<float> rate=<float>
import os, re, socket, struct, threading, time

OFFERED_QPS = int(os.environ.get("OFFERED_QPS", "400"))
WINDOW = float(os.environ.get("WINDOW", "5"))
DRAIN = float(os.environ.get("DRAIN", "1"))
QNAME = os.environ.get("QNAME", "kubernetes.default.svc.cluster.local")


def nameserver():
    with open("/etc/resolv.conf") as f:
        for line in f:
            m = re.match(r"\s*nameserver\s+(\S+)", line)
            if m:
                return m.group(1)
    raise SystemExit("no nameserver in /etc/resolv.conf")


def query(txid, qname):
    header = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)  # RD set, 1 question
    labels = b"".join(struct.pack("B", len(p)) + p.encode() for p in qname.split("."))
    return header + labels + b"\x00" + struct.pack(">HH", 1, 1)  # QTYPE A, QCLASS IN


ns = nameserver()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.connect((ns, 53))

answered = set()
stop = threading.Event()


def receiver():
    sock.settimeout(0.5)
    while not stop.is_set():
        try:
            data = sock.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) >= 2:
            answered.add(struct.unpack(">H", data[:2])[0])


rx = threading.Thread(target=receiver, daemon=True)
rx.start()

start = time.time()
interval = 1.0 / OFFERED_QPS
sent = 0
next_send = start
while time.time() - start < WINDOW:
    try:
        sock.send(query(sent & 0xFFFF, QNAME))
        sent += 1
    except OSError:
        pass
    next_send += interval
    delay = next_send - time.time()
    if delay > 0:
        time.sleep(delay)

# Let late answers arrive before we stop counting.
time.sleep(DRAIN)
stop.set()
rx.join(timeout=1)

elapsed = time.time() - start
n = len(answered)
# Report answered throughput against the OFFERING WINDOW, not total elapsed: the
# drain only exists to collect in-flight answers so the count is complete, and
# folding it into the denominator would dilute every rate and under-report the
# answered throughput.
rate = n / WINDOW
print(f"offered~{OFFERED_QPS}qps window={WINDOW}s drain={DRAIN}s nameserver={ns} qname={QNAME}")
print(f"sent={sent} answered={n} elapsed={elapsed:.2f}s answered_rate={rate:.1f}qps (over the {WINDOW}s offer window)")
print(f"RESULT offered={sent} answered={n} elapsed={elapsed:.2f} rate={rate:.1f}")
