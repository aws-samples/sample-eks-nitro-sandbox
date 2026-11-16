# Write a burst of numbered lines to the container's own stdout (PID 1's fd 1, the
# stream the kubelet collects), as fast as the stream takes them, and print how
# long the writes took. Run it with kubectl exec -i ... -- python3 - < this file.
#
# BURST_MB  megabytes to write (default 5); each line is 1000 bytes.
# BURST_ID  a tag on every line, so the lines are easy to count in kubectl logs.
import os, time

mb = float(os.environ.get("BURST_MB", "5"))
tag = os.environ.get("BURST_ID", "burst")
lines = int(mb * 1_000_000 / 1000)
pad = "x" * (1000 - len(f"{tag} {0:08d} ") - 1)
start = time.monotonic()
with open("/proc/1/fd/1", "w", buffering=1 << 16) as out:
    for i in range(lines):
        out.write(f"{tag} {i:08d} {pad}\n")
took = time.monotonic() - start
print(f"wrote {lines} lines ({lines * 1000 / 1e6:.1f} MB) in {took:.1f}s "
      f"= {lines * 1000 * 8 / took / 1e6:.1f} Mbit/s")
