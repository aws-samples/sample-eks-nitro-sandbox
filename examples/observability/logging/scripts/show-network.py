# Print the pod's network as the sandbox sees it: each interface and its IPv4
# address, its routes, and whether the CloudWatch Logs endpoint resolves. Run it with
# kubectl exec -i ... -- env ENDPOINT=logs.<region>.amazonaws.com python3 - < this file.
import fcntl, os, socket, struct

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for name in sorted(os.listdir("/sys/class/net")):
    try:
        req = struct.pack("256s", name.encode()[:15])
        addr = socket.inet_ntoa(fcntl.ioctl(s.fileno(), 0x8915, req)[20:24])  # SIOCGIFADDR
    except OSError:
        addr = "no IPv4 address"
    print(f"interface {name}: {addr}")
routes = open("/proc/net/route").read().splitlines()[1:]
print("routes:", len(routes))
host = os.environ.get("ENDPOINT", "logs.us-west-2.amazonaws.com")
try:
    print("resolve", host + ":", socket.getaddrinfo(host, 443)[0][4][0])
except OSError as e:
    print("resolve", host + ":", type(e).__name__, e)
