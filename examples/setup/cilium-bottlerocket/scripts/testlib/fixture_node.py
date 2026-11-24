#!/usr/bin/env python3
"""Good captures from a sandbox node and its pods, in the shapes the checks of
scripts/lib/cb_checks.py read, for the offline tests only (scripts/test-node-checks.sh).

    fixture_node.py <dir>

Each file is what setup.sh or test.sh would capture on a healthy node of the sample. A test copies
one, changes one thing, and runs the real check on it. The values are placeholders, not output of
a real run.
"""
import base64
import json
import os
import sys


def main(d):
    os.makedirs(d, exist_ok=True)

    def w(name, text):
        with open(os.path.join(d, name), "w") as f:
            f.write(text if isinstance(text, str) else json.dumps(text, indent=1))

    # pods: the max-pods of m8i.xlarge (4 vCPUs: ENI formula 4 x (30 IPv4 - 1) + 2 = 118, ceiling
    # 110, so 110); sandbox: SANDBOX_SLOTS.
    def node(os_image, pods="110", sandbox="58"):
        return {"metadata": {"name": "ip-10-0-1-10.us-west-2.compute.internal"},
                "status": {"nodeInfo": {"osImage": os_image, "kubeletVersion": "v1.36.4-eks-fake",
                                        "architecture": "amd64", "kernelVersion": "6.18.62"},
                           "capacity": {"pods": pods, "eks.amazonaws.com/nitro-sandbox": sandbox},
                           "allocatable": {"pods": pods, "eks.amazonaws.com/nitro-sandbox": sandbox}}}
    w("node-system.json", node("Bottlerocket OS 1.70.0 (aws-k8s-1.36)", sandbox="0"))
    w("node-sandbox.json", node("Bottlerocket OS 1.70.0 (aws-k8s-1.36-nitro-sandbox)"))
    w("btf.txt", "BTF_BYTES=5662391\n")
    # check-slots: the Nitro Enclaves driver values that probe_capture reads from sysfs (the
    # fixture config has SANDBOX_SLOTS=58, so the slot pool here is 58 too).
    w("slots.txt", "pcie_slots_total=58\npcie_slots=58\nmax_pcie_devices=32\n")
    w("cmdline.txt", "BOOT_IMAGE=(hd0,gpt3)/vmlinuz root=/dev/dm-0 ro nitro_enclaves.mempool=95%-1G quiet\n")
    w("kernel-log.txt", "[    0.000000] Linux version 6.18.62\n[    0.012345] nitro_enclaves: CMA pool: 14336 MiB reserved in 7 region(s), 14848 MiB requested\n")
    w("configz.json", {"kubeletconfig": {"containerRuntimeEndpoint": "unix:///run/nitro-sandbox/cri-proxy.sock", "maxPods": 110}})
    w("ami-tags.json", {"Images": [{"ImageId": "ami-0fa00000000000101",
                                    "Tags": [{"Key": "SandboxSlots", "Value": "58"}, {"Key": "RunId", "Value": "r1"}]}]})
    user_data = ('[settings.kubernetes]\ncluster-name = "cb-offline-test"\nmax-pods = 110\n'
                 'container-runtime-endpoint = "unix:///run/nitro-sandbox/cri-proxy.sock"\n')
    w("lt-sandbox.json", {"LaunchTemplateVersions": [{"LaunchTemplateData": {
        "UserData": base64.b64encode(user_data.encode()).decode(), "EnclaveOptions": {"Enabled": True}}}]})
    w("nitro-sandbox.toml", "[nitro_sandbox]\nkernel_path = \"/usr/share/nitro-sandbox/latest.eif\"\npcie_slots      = 58\n")
    w("selinux-enforce.txt", "1\n")
    w("avc.txt", "[  12.3] audit: type=1403 audit(1.0:2): auid=4294967295 ses=4294967295 lsm=selinux res=1\n")
    w("journal.txt", "Nov 21 00:00:01 node systemd[1]: Started cri-proxy.service.\n"
                     "Nov 21 00:00:02 node containerd-shim-nitro-sandbox-v2[900]: advertising 58 nitro-sandbox slots (target=58)\n")
    w("domains.txt", "system_u:system_r:runtime_t:s0\t/usr/bin/containerd-shim-nitro-sandbox-v2 cri-proxy --socket /run/nitro-sandbox/cri-proxy.sock\n"
                     "system_u:system_r:runtime_t:s0\t/usr/bin/containerd-shim-nitro-sandbox-v2 -namespace k8s.io -id abc123\n"
                     "system_u:system_r:system_t:s0\t/usr/bin/kubelet --config /etc/kubernetes/kubelet/config\n")
    w("networkd.txt", "==links==\n1: lo: <LOOPBACK,UP>\n2: eth0: <BROADCAST,UP>\n3: eth1: <BROADCAST,UP>\n4: lxc0abc@if5: <UP>\n"
                      "==states==\n1 ADMIN_STATE=unmanaged OPER_STATE=carrier\n2 ADMIN_STATE=configured OPER_STATE=routable\n"
                      "3 ADMIN_STATE=unmanaged OPER_STATE=routable\n")
    w("dm-verity.txt", "==dm==\nroot\n==dev==\n254:0\n==cmdline==\nroot=/dev/dm-0 ro \"dm-mod.create=root,,,ro,0 1 verity 1 PARTUUID\"\n"
                       "==mount==\n22 1 254:0 / / ro,relatime shared:1 - ext4 /dev/root ro\n")
    w("isolated.txt", "==addr==\n1: lo    inet 127.0.0.1/8 scope host lo\n==route==\n==dns rc=1==\n;; connection timed out; no servers could be reached\n")
    w("enis.json", {"NetworkInterfaces": [{"NetworkInterfaceId": "eni-0fa00000000000301", "Attachment": {"DeviceIndex": 1},
                                           "PrivateIpAddresses": [{"PrivateIpAddress": "10.0.1.20", "Primary": True},
                                                                  {"PrivateIpAddress": "10.0.1.21", "Primary": False}]}]})
    w("cilium-status.txt", "KubeProxyReplacement:    True   [eth0  10.0.1.10 (Direct Routing)]\n"
                           "KubeProxyReplacement Details:\n  Status:                 True\n  Socket LB:              Enabled\n"
                           "  Socket LB Tracing:      Enabled\n  Socket LB Coverage:     Hostns-only\n"
                           "Routing:                 Network: Native   Host: BPF\n")
    w("cilium-config.txt", "IPAM                              : eni\nRoutingMode                       : native\n")
    # check-eni-stable: the host network state of the sandbox node before and after an event
    # (the same here), and the CiliumNode whose ENI record holds eth1's MAC and addresses.
    eni = ("==link==\n"
           "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\\"
           "    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00\n"
           "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP mode DEFAULT group default qlen 1000\\"
           "    link/ether 0a:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff\n"
           "3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP mode DEFAULT group default qlen 1000\\"
           "    link/ether 0a:00:00:00:00:02 brd ff:ff:ff:ff:ff:ff\n"
           "==addr==\n"
           "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n"
           "2: eth0    inet 10.0.1.10/24 brd 10.0.1.255 scope global dynamic eth0\\       valid_lft 3000sec preferred_lft 3000sec\n"
           "3: eth1    inet 10.0.1.20/24 brd 10.0.1.255 scope global eth1\\       valid_lft forever preferred_lft forever\n"
           "==route==\n"
           "default via 10.0.1.1 dev eth0 proto dhcp src 10.0.1.10 metric 1024\n"
           "default via 10.0.1.1 dev eth1 table 11\n"
           "10.0.1.0/24 dev eth1 table 11 proto kernel scope link src 10.0.1.20\n"
           "local 10.0.1.20 dev eth1 table local proto kernel scope host src 10.0.1.20\n"
           "==route6==\n"
           "fe80::/64 dev eth1 proto kernel metric 256 pref medium\n"
           "==rule==\n"
           "0:\tfrom all lookup local\n"
           "20:\tfrom 10.0.1.20 lookup 11\n"
           "32766:\tfrom all lookup main\n"
           "32767:\tfrom all lookup default\n")
    w("eni-before.txt", eni)
    w("eni-after.txt", eni)
    # check-eni-capture: capture A of a sandbox node in the host iproute2
    # format, with the two routes that Cilium 1.20 sets for ENI number 1 (table 11, the gateway
    # the first address of the ENI subnet) and one endpoint rule; networkd lists eth1 unmanaged.
    w("eni-a.txt", "==link==\n"
                   "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP mode DEFAULT group default qlen 1000\\"
                   "    link/ether 0a:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff\n"
                   "6: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP mode DEFAULT group default qlen 1000\\"
                   "    link/ether 0a:00:00:00:00:02 brd ff:ff:ff:ff:ff:ff\n"
                   "==addr==\n"
                   "2: eth0    inet 10.0.1.10/19 metric 1024 brd 10.0.31.255 scope global dynamic eth0\\       valid_lft 3000sec preferred_lft 3000sec\n"
                   "6: eth1    inet6 fe80::ff:feee:2/64 scope link proto kernel_ll \\       valid_lft forever preferred_lft forever\n"
                   "==route==\n"
                   "default via 10.0.0.1 dev eth1 table 11 proto kernel\n"
                   "10.0.0.1 dev eth1 table 11 proto kernel scope link\n"
                   "default via 10.0.0.1 dev eth0 proto dhcp src 10.0.1.10 metric 1024\n"
                   "==route6==\n"
                   "fe80::/64 dev eth1 proto kernel metric 256 pref medium\n"
                   "local fe80::ff:feee:2 dev eth1 table local proto kernel metric 0 pref medium\n"
                   "==rule==\n"
                   "9:\tfrom all fwmark 0x200/0xf00 lookup 2004\n"
                   "20:\tfrom all to 10.0.2.20 lookup main\n"
                   "111:\tfrom 10.0.2.20 lookup 11 proto kernel\n"
                   "32766:\tfrom all lookup main\n")
    w("networkd-a.txt", "==links==\n2: eth0: <UP>\n6: eth1: <UP>\n==states==\n"
                        "2 ADMIN_STATE=configured OPER_STATE=routable\n6 ADMIN_STATE=unmanaged OPER_STATE=carrier\n")
    w("ciliumnode-a.json", {"status": {"eni": {"enis": {
        "eni-0fa00000000000300": {"id": "eni-0fa00000000000300", "mac": "0a:00:00:00:00:01", "ip": "10.0.1.10",
                                  "addresses": ["10.0.1.21"], "subnet": {"cidr": "10.0.0.0/19"}},
        "eni-0fa00000000000301": {"id": "eni-0fa00000000000301", "mac": "0a:00:00:00:00:02", "ip": "10.0.2.10", "number": 1,
                                  "addresses": ["10.0.2.20"], "subnet": {"cidr": "10.0.0.0/19"}}}}}})
    # check-kubeconfig-path and check-mkfs-erofs: the stat capture of the
    # kubelet kubeconfig, and `mkfs.erofs -V` of erofs-utils 1.9.4 built with libzstd.
    w("kubeconfig.txt", "KUBECONFIG_BYTES=5321\n")
    w("mkfs-erofs.txt", "mkfs.erofs (erofs-utils) 1.9.4\navailable compressors: lz4, lz4hc, lzma, deflate, libdeflate, zstd\n")
    w("ciliumnode.json", {"metadata": {"name": "ip-10-0-1-10.us-west-2.compute.internal"},
                          "status": {"eni": {"enis": {"eni-0fa00000000000301": {
                              "id": "eni-0fa00000000000301", "mac": "0a:00:00:00:00:02", "ip": "10.0.1.20",
                              "addresses": ["10.0.1.21", "10.0.1.22"]}}}}})


if __name__ == "__main__":
    main(sys.argv[1])
