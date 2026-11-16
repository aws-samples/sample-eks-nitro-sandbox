# Runtime security a sandbox hides from the node

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
blueprint first so you have a cluster with the runtime classes. You also need
[Helm](https://helm.sh/docs/intro/install/) 3.8 or later and Python 3 on your machine. The
commands below use files from this repository, so clone it if you have not already, and run
them from this blueprint's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/security/runtime-detection
```

Most runtime security tools for Kubernetes watch the node's kernel. Falco and Cilium Tetragon,
in their usual DaemonSet form, load eBPF programs into it, and GuardDuty Runtime Monitoring
inspects the node's processes and cgroups. A pod in a Nitro sandbox runs its containers in a
lightweight VM with its own kernel, so their system calls never reach the node's kernel, and
those tools see nothing of them. The Amazon EKS User Guide says so for GuardDuty: its agent
"cannot monitor activity inside isolated or confidential pods"
([GuardDuty integration](https://docs.aws.amazon.com/eks/latest/userguide/integration-guardduty.html),
[Observability for sandboxed pods](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-observability.html)).

This blueprint shows that gap with a control, and then closes it:

- **What goes blind.** The same pod runs twice on one node, differing only in
  `runtimeClassName: isolated-sandbox`. Both run the same four benign test events. The node's
  Falco and Tetragon report every event in the ordinary pod and none in the sandboxed pod.
- **A detector inside the guest.** A sidecar in the sandboxed pod watches the guest kernel,
  catches the same four events, and prints alerts to stdout. The node's log agent ships them to
  Amazon CloudWatch Logs like any container log.
- **What it cannot see.** The sidecar sees its own guest only: not the node, and not other pods.
- **The catch.** The detector shares the guest with the workload it watches, so a workload that
  gains root in the guest can stop it. A heartbeat check turns that silence into an alert.

*Figure 1: One node, three pods. The node's Falco and Tetragon see the ordinary pod's system
calls on the node kernel, and none of the sandboxed pod's. A detector sidecar inside a sandbox
reads the guest kernel's audit records and writes alerts to stdout, which reach CloudWatch
Logs.*

![An AWS Cloud frame holds an EKS Auto Mode node frame. Inside the node, top left, an ordinary pod named app-standard holds an app container labelled test events; a solid arrow labelled syscalls on the node kernel runs from it to a gear icon labelled Falco, Tetragon, node DaemonSet. Below it, a Nitro sandbox pod named app-sandboxed holds an app container labelled same test events; a dashed arrow labelled no syscalls reach the node runs from it to the same gear, marking a path that is not taken. On the right of the node, a second Nitro sandbox pod named app-sandboxed-detector holds an app container labelled same test events and a gear labelled detector sidecar, in the guest; an arrow labelled audit records runs from the app container to the detector. An arrow labelled alerts on stdout runs from the detector, out of the node, to Amazon CloudWatch Logs inside the AWS Cloud frame.](images/runtime-detection.png)

The files:

| File | What it is |
|---|---|
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The `runtime-detection` namespace this blueprint owns |
| [`deploy/app-standard.yaml`](deploy/app-standard.yaml) | The ordinary app pod: the control. Its pod affinity puts it on the sandboxed pod's node |
| [`deploy/app-sandboxed.yaml`](deploy/app-sandboxed.yaml) | The sandboxed app pod: identical but for `runtimeClassName: isolated-sandbox` |
| [`deploy/app-sandboxed-detector.yaml`](deploy/app-sandboxed-detector.yaml) | The sandboxed app pod with the in-guest detector as a sidecar |
| [`deploy/guest-detector.py`](deploy/guest-detector.py) | The in-guest detector: drives the guest kernel's audit subsystem, writes JSON alerts and heartbeats to stdout |
| [`deploy/falco-values.yaml`](deploy/falco-values.yaml) | Helm values for Falco as a node DaemonSet with the modern eBPF probe |
| [`deploy/tetragon-values.yaml`](deploy/tetragon-values.yaml) | Helm values for Tetragon as a node DaemonSet |
| [`deploy/tetragon-policy.yaml`](deploy/tetragon-policy.yaml) | A Tetragon policy, for this namespace only, that adds events for a read of `/etc/shadow` and for each TCP connection |
| [`scripts/trigger-events.sh`](scripts/trigger-events.sh) | Runs the four test events in one pod |
| [`scripts/run-comparison.sh`](scripts/run-comparison.sh) | Deploys the two app pods, runs the events in both, prints what Falco and Tetragon saw, and a verdict |
| [`scripts/run-detector.sh`](scripts/run-detector.sh) | Deploys the detector pod, runs the events in all three pods, prints the detector's alerts and a verdict |
| [`scripts/show-guest-view.sh`](scripts/show-guest-view.sh) | Shows that the sandboxed pods run in a sandbox, and what the detector can see |
| [`scripts/check-heartbeat.sh`](scripts/check-heartbeat.sh) | Fails when a detector has written no heartbeat to CloudWatch Logs lately |
| [`tests/test_guest_detector.py`](tests/test_guest_detector.py) | Unit tests for the detector's parsing and rules, with no cluster: `python3 tests/test_guest_detector.py` |

## The test events

[`scripts/trigger-events.sh`](scripts/trigger-events.sh) runs four commands in a pod's `app`
container with `kubectl exec`. Each is benign and touches nothing outside the pod. Each matches a
rule in Falco's default rule set, and the in-guest detector uses the same rule names.

| Test event | What it does | Falco rule |
|---|---|---|
| A shell with a terminal | `kubectl exec -it ... -- sh -c 'exit 0'` | `Terminal shell in container` |
| Read `/etc/shadow` | `cat /etc/shadow > /dev/null`, the container's own copy | `Read sensitive file untrusted` |
| Drop and run a new binary | Copy `/bin/true` to `/tmp`, run it, delete it | `Drop and execute new binary in container` |
| Contact the Kubernetes API | Open one TCP connection to the API server's service address, close it, send nothing | `Contact K8S API Server From Container` |

Tetragon has no alert rules of its own: it logs every process start, and
[`deploy/tetragon-policy.yaml`](deploy/tetragon-policy.yaml) adds a kernel probe event for a read
of `/etc/shadow` and one for each outbound TCP connection, so every test event leaves a record.

The optional [GuardDuty stage](#optional-guardduty-runtime-monitoring) adds a fifth event: a DNS
lookup of `guarddutyc2activityb.com`, the domain GuardDuty documents for testing its
`C&CActivity.B!DNS` findings. The lookup sends a DNS query and connects to nothing.

## Versions

| Component | Pin | Latest (2026-11-16) |
|---|---|---|
| [Falco Helm chart](https://github.com/falcosecurity/charts/tree/master/charts/falco) | `falcosecurity/falco` chart `9.2.2` (Falco `0.45.2`) | 9.2.2 |
| Falco rules | `falco-rules:5.0.0`, installed once by the chart's `falcoctl` (set in `falco-values.yaml`) | 5.0.0 |
| [Tetragon Helm chart](https://github.com/cilium/tetragon/tree/main/install/kubernetes/tetragon) | `cilium/tetragon` chart `1.8.0` (Tetragon `v1.8.0`) | 1.8.0 |
| App and detector image ([`python`](https://gallery.ecr.aws/docker/library/python)) | `public.ecr.aws/docker/library/python:3.12-slim` | 3.12-slim |
| GuardDuty EKS runtime monitoring add-on (`aws-guardduty-agent`), optional stage only | `v1.17.3-eksbuild.2` | v1.17.3-eksbuild.2 (the default for Kubernetes 1.36) |

The in-guest detector is a single Python file using the standard library only.

## Run it

The run on this page used the namespaces `runtime-detection-i250`, `falco-i250` and
`tetragon-i250`, set with `NAMESPACE`, `FALCO_NAMESPACE` and `TETRAGON_NAMESPACE`. The blocks
show those names where the run printed them.

**Step 1: Install Falco and Tetragon on the node.** Both are cluster-wide installs: a DaemonSet
with a pod on every node. First check whether your cluster already has them, and reuse them as
they are if it does (set `FALCO_NAMESPACE` and `TETRAGON_NAMESPACE` to where they run):

```bash
kubectl get daemonset -A -l 'app.kubernetes.io/name in (falco,tetragon)'
```

If neither is there, install both at the pinned versions:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add cilium https://helm.cilium.io
helm install falco falcosecurity/falco --version 9.2.2 \
  --namespace falco --create-namespace -f deploy/falco-values.yaml
helm install tetragon cilium/tetragon --version 1.8.0 \
  --namespace tetragon --create-namespace -f deploy/tetragon-values.yaml
```

These two blocks are from separate runs of the same commands, before the walkthrough below, and
are abridged to their first lines:

```text
NAME: falco-i250
LAST DEPLOYED: Mon Nov 16 19:27:18 2026
NAMESPACE: falco-i250
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
```

```text
NAME: tetragon-i250
LAST DEPLOYED: Mon Nov 16 19:30:37 2026
NAMESPACE: tetragon-i250
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
```

[`deploy/falco-values.yaml`](deploy/falco-values.yaml) picks the `modern_ebpf` driver, JSON
output and one fixed rules version:

```yaml
driver:
  kind: modern_ebpf
tty: true
falco:
  json_output: true
  json_include_output_property: true
falcoctl:
  artifact:
    follow:
      enabled: false
  config:
    artifact:
      install:
        refs: [falco-rules:5.0.0]
```

[`deploy/tetragon-values.yaml`](deploy/tetragon-values.yaml) exports only process starts and
kernel probe events. Both tools write their events to their own container logs.

**Step 2: Run the same events in the ordinary and the sandboxed pod.**
[`scripts/run-comparison.sh`](scripts/run-comparison.sh) creates the namespace (only when it is
absent; it refuses one it did not label), applies the Tetragon policy and the two pods, checks
they are on the same node, runs the four events in each, and reads the Falco and Tetragon pods on
that node:

```bash
scripts/run-comparison.sh
```

```text
=== app-standard: 4 Falco alerts, 12 Tetragon events ===
  falco     Terminal shell in container
  falco     Read sensitive file untrusted
  falco     Drop and execute new binary in container
  falco     Contact K8S API Server From Container
  tetragon  process_exec sh
  tetragon  process_exec cat
  tetragon  process_kprobe security_file_permission
  tetragon  process_kprobe security_file_permission
  tetragon  process_kprobe security_file_permission
  tetragon  process_kprobe security_file_permission
  tetragon  process_exec sh
  tetragon  process_exec cp
  tetragon  process_exec runtime-detection-test
  tetragon  process_exec rm
  tetragon  process_exec python3
  tetragon  process_kprobe tcp_connect

=== app-sandboxed: 0 Falco alerts, 0 Tetragon events ===

=== Verdict ===
RESULT: the node's Falco and Tetragon each saw the ordinary pod's test events and
none of the sandboxed pod's, which ran the same events on the same node.
```

The block is abridged: it starts at the results. Before them the script prints each object it
creates, the node both pods share and the four events it runs in each pod.

Here is one of Falco's alerts for the ordinary pod, from its log on that node:

```text
20:22:46.158157826: Warning Sensitive file opened for reading by non-trusted program | file=/etc/shadow gparent=systemd ggparent=<NA> gggparent=<NA> evt_type=openat user=root user_uid=0 user_loginuid=-1 process=cat proc_exepath=/usr/bin/cat parent=containerd-shim command=cat /etc/shadow terminal=0 container_id=46ed94b3e6d9 container_name=app container_image_repository=public.ecr.aws/docker/library/python container_image_tag=3.12-slim k8s_pod_name=app-standard k8s_ns_name=runtime-detection-i250
```

The same pods, the same events and the same Falco and Tetragon pods: the only difference is
`runtimeClassName`. The sandboxed pod's `cat /etc/shadow` ran on the sandbox's guest kernel,
where neither tool has a probe.

**Step 3: The sandboxed pods really run in a sandbox.**
[`scripts/show-guest-view.sh`](scripts/show-guest-view.sh) prints each app pod's kernel build,
uptime and disks. This block is from the same run, after step 4, and is abridged to the two app
pods:

```text
=== app-sandboxed: runtimeClassName 'isolated-sandbox' ===
6.18.62 #1 SMP PREEMPT_DYNAMIC Thu Nov 12 22:44:15 UTC 2026
uptime(s): 76.48
disks:     dm-0 vda vdb vdc

=== app-standard: runtimeClassName '' ===
6.18.62 #2 SMP PREEMPT_DYNAMIC Thu Nov 12 22:49:16 UTC 2026
uptime(s): 3015.78
disks:     dm-0 loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 nvme0n1 nvme1n1 zram0
```

The run printed a space at the end of each disk list; the block trims it. The sandboxed pod has
its own kernel build (`#1`), booted with the pod, and virtio disks. The ordinary pod reports the
node's build (`#2`), the node's uptime and the instance's `nvme` disks.

## Why Falco and Tetragon cannot simply run in the guest

The obvious fix is to run Falco or Tetragon inside the sandbox. On this cluster neither can start
there, because the guest kernel lacks what their eBPF probes attach to. A privileged probe pod in
`isolated-sandbox` found:

- `bpf()` works: creating a BPF map succeeds.
- No BTF: `/sys/kernel/btf/vmlinux` does not exist.
- No tracing: `tracefs` is not a known file system, and `/proc/kallsyms` has no tracepoint,
  kprobe or ftrace symbols.

Falco `0.45.2` with `engine.kind=modern_ebpf`, privileged, in a sandboxed pod:

```text
libpman: prog 'BPF_TRACE_RAW_TP' is not supported
2026-11-16T19:21:44+0000: An error occurred in an event source, forcing termination...
Error: Initialization issues during scap_init
```

Tetragon `v1.8.0`, privileged, in a sandboxed pod (abridged to its error):

```text
level=error msg="Failed to execute tetragon" error="tetragon, aborting kernel autodiscovery failed: kernel version \"6.18.62\" BTF search failed kernel is not included in supported list. ...
```

The guest kernel does have the Linux audit subsystem. That is what the in-guest detector uses.

## The fix: a detector inside the guest

[`deploy/guest-detector.py`](deploy/guest-detector.py) runs as a sidecar in
[`deploy/app-sandboxed-detector.yaml`](deploy/app-sandboxed-detector.yaml). It:

1. registers itself as the guest's audit daemon over the audit netlink socket,
2. removes two rules the guest image loads that stop syscall records from being made
   (`-a never,task`, and an exclude rule for every record type below 1400),
3. adds one rule that audits `execve`, `execveat`, `open`, `openat`, `creat` and `connect` for
   every process but itself (`openat2` is left out, because its flags sit behind a pointer the
   audit record does not carry),
4. turns each matching record into a JSON alert on stdout, using the Falco rule names above,
5. prints a heartbeat line every 60 seconds.

It needs much less than `privileged: true`. These are the parts of the pod that matter:

```yaml
spec:
  runtimeClassName: isolated-sandbox
  hostPID: true          # the sandbox's own PID namespace: the guest's, not the node's
  initContainers:
    - name: detector
      restartPolicy: Always            # a sidecar, started before the app container
      command: ["python3", "-u", "/detector/guest-detector.py"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
          add: ["AUDIT_CONTROL"]
```

`hostPID: true` in a sandbox joins the guest's PID namespace, where the audit daemon must live.

!!! warning "Never copy `hostPID: true` into an ordinary pod"
    Without `runtimeClassName: isolated-sandbox`, the same field joins the node's PID namespace,
    so the pod could see and signal every process on the node. This manifest is only safe with
    the runtime class.

`AUDIT_CONTROL` lets the detector change audit settings and rules and receive the records as the
guest's audit daemon; it reaches only this pod's guest. The run on this page had no other
capability: `AUDIT_READ`, which only gates the multicast log feed, is not needed.

**Step 4: Catch the events inside the guest.** [`scripts/run-detector.sh`](scripts/run-detector.sh)
stores the detector in a ConfigMap, starts the detector pod, and runs the four events in it and
again in `app-sandboxed` and `app-standard`:

```bash
scripts/run-detector.sh
```

```text
=== app-sandboxed-detector: the detector's output since the events started ===
{"detector": "guest-audit", "kernel": "6.18.62", "removed_guest_rules": ["never,task", "exclude msgtype<1400"], "rules": ["connect", "creat", "execve", "execveat", "open", "openat"], "status": "started"}
{"detector": "guest-audit", "heartbeat": true, "time": "2026-11-16T20:23:22Z"}
{"detector": "guest-audit", "output": "shell with a terminal tty=pts0 pid=1692 ppid=1644 uid=0 comm=sh exe=/usr/bin/dash", "rule": "Terminal shell in container", "time": "2026-11-16T20:23:23Z"}
{"detector": "guest-audit", "output": "file=/etc/shadow pid=1710 ppid=1644 uid=0 comm=cat exe=/usr/bin/cat", "rule": "Read sensitive file untrusted", "time": "2026-11-16T20:23:24Z"}
{"detector": "guest-audit", "output": "executed a file written after the container started pid=1735 ppid=1728 uid=0 comm=runtime-detecti exe=/tmp/runtime-detection-test", "rule": "Drop and execute new binary in container", "time": "2026-11-16T20:23:25Z"}
{"detector": "guest-audit", "output": "connection=10.100.0.1:443 pid=1752 ppid=1644 uid=0 comm=python3 exe=/usr/local/bin/python3.12", "rule": "Contact K8S API Server From Container", "time": "2026-11-16T20:23:27Z"}

=== Verdict ===
RESULT: the in-guest detector raised 4 alerts, one for each test event in its own pod,
and none for the same events in app-sandboxed or app-standard.
```

The block is abridged: it starts at the detector's output. Before it the script prints the objects
it creates and the twelve events it runs.

**Step 5: Find the alerts in CloudWatch Logs.** The detector writes to stdout, so its alerts are
ordinary container log lines. The run used the
[Amazon CloudWatch Observability EKS add-on](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html),
whose Fluent Bit DaemonSet ships every container's log to
`/aws/containerinsights/<cluster>/application`. It is a cluster-wide install with its own IAM
permissions; if your cluster does not have it, install it as that guide says. Query the log group
for the detector's lines:

```bash
aws logs filter-log-events --region "$AWS_REGION" \
  --log-group-name "/aws/containerinsights/$CLUSTER_NAME/application" \
  --start-time "$(( ($(date +%s) - 900) * 1000 ))" --filter-pattern '"guest-audit"' \
  --query 'events[].message' --output json |
python3 -c 'import json, sys
for m in json.load(sys.stdin):
    d = json.loads(m); k = d["kubernetes"]
    print(k["namespace_name"], k["pod_name"], k["container_name"], "|", d["log"].strip()[:200])'
```

This block is from an earlier run at 19:45 UTC, with the same pods, the same events and an earlier
version of the detector (it still audited `openat2`, so its `rules` list is one longer; the
fixes since then change how records are grouped, not what reaches stdout). The add-on was removed
from the test cluster before the walkthrough above was run. The block is abridged to that run's
lines:

```text
runtime-detection-i250 app-sandboxed-detector detector | {"detector": "guest-audit", "kernel": "6.18.62", "removed_guest_rules": ["never,task", "exclude msgtype<1400"], "rules": ["connect", "creat", "execve", "execveat", "open", "openat", "openat2"], "statu
runtime-detection-i250 app-sandboxed-detector detector | {"detector": "guest-audit", "heartbeat": true, "time": "2026-11-16T19:44:57Z"}
runtime-detection-i250 app-sandboxed-detector detector | {"detector": "guest-audit", "output": "shell with a terminal tty=pts0 pid=1696 ppid=1648 uid=0 comm=sh exe=/usr/bin/dash", "rule": "Terminal shell in container", "time": "2026-11-16T19:45:01Z"}
runtime-detection-i250 app-sandboxed-detector detector | {"detector": "guest-audit", "output": "file=/etc/shadow pid=1716 ppid=1648 uid=0 comm=cat exe=/usr/bin/cat", "rule": "Read sensitive file untrusted", "time": "2026-11-16T19:45:02Z"}
runtime-detection-i250 app-sandboxed-detector detector | {"detector": "guest-audit", "output": "executed a file written after the container started pid=1740 ppid=1733 uid=0 comm=runtime-detecti exe=/tmp/runtime-detection-test", "rule": "Drop and execute new
runtime-detection-i250 app-sandboxed-detector detector | {"detector": "guest-audit", "output": "connection=10.100.0.1:443 pid=1754 ppid=1648 uid=0 comm=python3 exe=/usr/local/bin/python3.12", "rule": "Contact K8S API Server From Container", "time": "2026-11
```

The alerts leave the sandbox the way every container log does, so the detector needs no IAM role
and no network access of its own. The per-sandbox log bandwidth limit (`2M` by default, see
[Sandbox limits](../../isolation/sandbox-limits/README.md#every-per-sandbox-limit-and-its-default))
applies to them like any log.

## The detector sees its own guest, and nothing else

Step 4 already showed one side of this: the same events in `app-sandboxed` and `app-standard`
raised nothing in the detector, because they never reach its guest kernel. The other side is what
the detector can list. [`scripts/show-guest-view.sh`](scripts/show-guest-view.sh), from the same
run, abridged to the detector container, with the guest's random D-Bus machine ID cut:

```text
=== app-sandboxed-detector, detector container ===
runtimeClassName: isolated-sandbox  hostPID: true
kernel:    6.18.62 #1 SMP PREEMPT_DYNAMIC Thu Nov 12 22:44:15 UTC 2026
uptime(s): 30.14
disks:     dm-0 vda vdb vdc
processes with a command line: 12
       1  /sbin/init
     877  /x86_64-bottlerocket-linux-gnu/sys-root/usr/lib/systemd/systemd-journald
     902  /usr/bin/whippet
     905  /x86_64-bottlerocket-linux-gnu/sys-root/usr/lib/systemd/systemd-udevd
    1364  /usr/bin/dbus-broker --log 12 --controller 11 --machine-id ...
    1494  /usr/sbin/nitro-sandbox-agent
    1516  /x86_64-bottlerocket-linux-gnu/sys-root/usr/sbin/nitro-sandbox-agent pause
    1518  /x86_64-bottlerocket-linux-gnu/sys-root/usr/sbin/nitro-sandbox-agent pause
    1556  /x86_64-bottlerocket-linux-gnu/sys-root/usr/lib/systemd/systemd-logind
    1621  python3 -u /detector/guest-detector.py
    1667  sleep infinity
    1770  python3 -
sees kubelet: no
sees containerd: no
sleep infinity processes: 1
```

With `hostPID: true` the detector sees every process in its PID namespace, and that namespace is
the guest's: its init, the sandbox agent, the detector itself and the one `sleep infinity` that is
this pod's app. There is no kubelet, no containerd and no other pod. It sees the guest's virtio
disks, not the node's.

The same holds with the most privilege a pod can ask for. Later in the same run the detector pod
was re-created with its detector's `securityContext` replaced by `privileged: true`, and the
script printed the same picture: 22 processes, all of them the guest's (the extra ten were
`udev-worker` processes still running five seconds after boot), `sees kubelet: no`,
`sees containerd: no`, one `sleep infinity`, and the disks `dm-0 vda vdb vdc`. `privileged: true` in a sandbox reaches only that pod's guest.

## The catch: the detector shares the guest it watches

A node agent watching an ordinary pod sits outside that pod: code in the pod cannot reach it. The
in-guest detector sits inside the same VM as the workload. A workload that gains root in the guest
can stop the detector, change its audit rules, or flood it. In this pod the app container already
shares the guest's PID namespace and runs as root, so it can kill the detector without any
capability. From the same run, on the same detector pod as the block above (its detector was
pid 1621):

```bash
kubectl -n "$NAMESPACE" exec app-sandboxed-detector -c app -- python3 -c '
import os, signal
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
    except OSError:
        continue
    if cmd[:3] == [b"python3", b"-u", b"/detector/guest-detector.py"]:
        print(f"app container, uid {os.getuid()}, kills the detector, pid {pid}")
        os.kill(int(pid), signal.SIGKILL)'
sleep 15
kubectl -n "$NAMESPACE" get pod app-sandboxed-detector \
  -o 'jsonpath=detector restarts: {.status.initContainerStatuses[0].restartCount}{"\n"}'
kubectl -n "$NAMESPACE" logs app-sandboxed-detector -c detector | head -1
```

```text
app container, uid 0, kills the detector, pid 1621
detector restarts: 1
{"detector": "guest-audit", "kernel": "6.18.62", "removed_guest_rules": ["own rule from an earlier start"], "rules": ["connect", "creat", "execve", "execveat", "open", "openat"], "status": "started"}
```

The kubelet restarted the sidecar, which started again and replaced its own rule from before. But
between the kill and the restart nothing was watched, and a workload with `CAP_AUDIT_CONTROL`
could remove the rule instead and leave the detector running blind. So treat in-guest alerts as evidence from inside a boundary you do not fully trust:

- **The sandbox still protects the node and the other pods.** Whatever the workload does to the
  detector, it stays inside its own VM, as the previous section shows. Losing the detector loses
  visibility into one pod, not control of the node.
- **It is weaker than a node agent on an ordinary pod.** There, the agent sits in a kernel the pod
  cannot reach. Here, it does not. The node-level controls that keep working are listed below.
- **Silence must be an alert.** A detector that is killed or stalled stops writing heartbeats.
  Alarm on their absence, not only on the alerts. A heartbeat does not prove the detector can
  still see: one whose audit rule was removed keeps writing heartbeats, which is the limit of
  any detector that shares the guest with its workload.

**Step 6: Check the heartbeat.** [`scripts/check-heartbeat.sh`](scripts/check-heartbeat.sh) looks
for the latest heartbeat line from the pod's `detector` container in CloudWatch Logs, and exits
non-zero when there is none in the last 180 seconds (`MAX_AGE`, three heartbeats):

```bash
scripts/check-heartbeat.sh app-sandboxed-detector
scripts/check-heartbeat.sh app-sandboxed    # a pod with no detector: must fail
```

These blocks are from a run after the add-on had been removed, against the heartbeats the
earlier run in step 5 had stored, so it used `MAX_AGE=7200` to reach back that far:

```text
OK: last heartbeat from runtime-detection-i250/app-sandboxed-detector was 1909s ago (limit 7200s)
```

```text
ALERT: no heartbeat from runtime-detection-i250/app-sandboxed in the last 7200s
```

For a check that runs without you, turn the same idea into a CloudWatch Logs
[metric filter](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/MonitoringLogData.html)
that counts heartbeat lines, and a CloudWatch alarm on it that treats missing data as breaching.
This blueprint does not create them.

The check reads only the detector container's lines on purpose: the app container shares the
guest and runs as root, so it could print a fake heartbeat of its own.

## What keeps working for a sandboxed pod

These controls do not depend on seeing the pod's system calls, so the sandbox does not hide the pod
from them. This blueprint did not test them; each is described by its own documentation.

- **Kubernetes audit logs**, and GuardDuty EKS Protection, which reads them: they come from the
  control plane, so a sandboxed pod's API calls are logged like any other pod's.
- **Network policy and security groups**, enforced on the parent instance, outside the guest. The
  User Guide's
  [security model](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-security-model.html)
  says a compromised guest cannot disable them. See
  [Isolation > Network policy](../../isolation/network-policy/README.md) for the mechanism.
- **VPC Flow Logs**, recorded outside the instance.
- **Amazon Inspector** image scans in Amazon ECR, which look at the image before it runs.

## Optional: GuardDuty Runtime Monitoring

GuardDuty Runtime Monitoring is billed per account, so this stage is optional: every stage above
runs without it at no extra AWS cost. The User Guide states the gap: the GuardDuty agent "cannot
monitor activity inside isolated or confidential pods", because it inspects host processes and
cgroups ([GuardDuty integration](https://docs.aws.amazon.com/eks/latest/userguide/integration-guardduty.html)).
This stage shows it with the same control as above. It needs only the two app pods from step 2,
not Falco, Tetragon or the detector.

Runtime Monitoring is an account-wide setting in a Region, so agree it with whoever owns the
account. Before you start, record how the detector is set, so you can put it back exactly:

```bash
DETECTOR_ID=$(aws guardduty list-detectors --region "$AWS_REGION" --query 'DetectorIds[0]' --output text)
aws guardduty get-detector --region "$AWS_REGION" --detector-id "$DETECTOR_ID" \
  --query "Features[?Name=='RUNTIME_MONITORING']"
```

**Step G1: Turn on Runtime Monitoring for this cluster only.** Keep automated agent management
off, so GuardDuty installs nothing on other clusters, and install the agent add-on on this cluster
yourself. With management off, the agent needs an interface VPC endpoint for
`com.amazonaws.<region>.guardduty-data` in the cluster's VPC, with private DNS and a security
group that allows TCP 443 from the VPC; create both, tagged `ManagedBy=runtime-detection`, as the
GuardDuty User Guide's *Managing the security agent manually for Amazon EKS* says.

```bash
aws guardduty update-detector --region "$AWS_REGION" --detector-id "$DETECTOR_ID" --features \
  '[{"Name":"RUNTIME_MONITORING","Status":"ENABLED","AdditionalConfiguration":[
     {"Name":"EKS_ADDON_MANAGEMENT","Status":"DISABLED"},
     {"Name":"ECS_FARGATE_AGENT_MANAGEMENT","Status":"DISABLED"},
     {"Name":"EC2_AGENT_MANAGEMENT","Status":"DISABLED"}]}]'
aws eks create-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-guardduty-agent --addon-version v1.17.3-eksbuild.2 \
  --tags ManagedBy=runtime-detection
```

On the test cluster the agent pods were running within a minute, and GuardDuty's coverage report
(`aws guardduty list-coverage`) showed the cluster `HEALTHY`, 3 nodes covered, management type
`MANUAL`.

**Step G2: Run the events and the test domain lookup in both pods.**

```bash
for p in app-standard app-sandboxed; do
  scripts/trigger-events.sh "$p"
  for i in 1 2 3; do
    kubectl -n "$NAMESPACE" exec "$p" -c app -- python3 -c 'import socket
try: socket.gethostbyname("guarddutyc2activityb.com")
except OSError: pass'
  done
done
```

**Step G3: Read the findings for this cluster.**

```bash
ids=$(aws guardduty list-findings --region "$AWS_REGION" --detector-id "$DETECTOR_ID" \
  --finding-criteria '{"Criterion":{"resource.eksClusterDetails.name":{"Equals":["'"$CLUSTER_NAME"'"]}}}' \
  --query FindingIds --output text)
aws guardduty get-findings --region "$AWS_REGION" --detector-id "$DETECTOR_ID" --finding-ids $ids \
  --query 'Findings[].[CreatedAt,Type,Resource.KubernetesDetails.KubernetesWorkloadDetails.Name,Service.RuntimeDetails.Process.Name]' \
  --output text
```

The run's findings, one line each: time, type, severity, the workload the finding names, the
process (printed by a helper in `tmp/` with the same fields):

```text
2026-11-16T21:52:49.242Z Backdoor:Runtime/C&CActivity.B!DNS sev=8.0 workload=runtime-detection-i250/app-standard process=python3 count=6
2026-11-16T21:52:49.242Z Backdoor:Runtime/C&CActivity.B!DNS sev=8.0 workload=None/None process=coredns count=2
2026-11-16T21:52:49.243Z Backdoor:Runtime/C&CActivity.B!DNS sev=8.0 workload=None/None process=systemd-resolve count=2
```

These appeared about three minutes after a second round of events, run at 21:50 UTC, 17 minutes
after the agent started. A first round, one minute after the agent started, had raised no runtime
finding by then.

- **The ordinary pod is named.** The agent saw `python3` in `app-standard` query the test domain.
- **The sandboxed pod is not.** No finding names `app-sandboxed`. Its query left the sandbox to the
  node's own DNS resolvers, `coredns` and `systemd-resolved`, which the agent sees as processes on
  the node, outside any pod; those two findings name the node instance and do not say which pod
  sent the query.
- **The other four test events raised no GuardDuty runtime finding in this run**, from either pod.

GuardDuty's DNS logs, which do not use the agent, also raised `Backdoor:EC2/C&CActivity.B!DNS` for
the domain, on the node instance both pods ran on. It names the instance, not a pod.

**Step G4: Turn it off again.** Delete the add-on, set `RUNTIME_MONITORING` back to what you
recorded (here, off), and delete the endpoint and its security group in the console or with the
AWS CLI:

```bash
aws eks delete-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --addon-name aws-guardduty-agent
aws guardduty update-detector --region "$AWS_REGION" --detector-id "$DETECTOR_ID" --features \
  '[{"Name":"RUNTIME_MONITORING","Status":"DISABLED","AdditionalConfiguration":[
     {"Name":"EKS_ADDON_MANAGEMENT","Status":"DISABLED"},
     {"Name":"ECS_FARGATE_AGENT_MANAGEMENT","Status":"DISABLED"},
     {"Name":"EC2_AGENT_MANAGEMENT","Status":"DISABLED"}]}]'
```

The add-on leaves an empty `amazon-guardduty` namespace; delete it too. Then read the detector
again and compare it with what you recorded. On the test account Runtime Monitoring was on for 28
minutes, and afterwards every detector feature read back as before, with EKS Protection left on.

## Confidential pods

In `confidential-sandbox`, the guest runs under a Cedar policy, so the detector sidecar must be
allowed by that policy (see [Policy > Cedar policy](../../policy/cedar-policy/README.md)). Its
alerts are data that leave the guest through the container log, so decide whether that is
acceptable for the workload before you add it. This blueprint did not run a confidential pod.

## Clean up

Delete this blueprint's namespace, with the pods, the ConfigMap and the Tetragon policy in it. The
script first checks that the namespace carries this blueprint's `sample: runtime-detection` label
and deletes nothing otherwise:

```bash
scripts/run-comparison.sh --cleanup
```

Falco and Tetragon are cluster-wide. If you installed them in step 1 for this blueprint and
nothing else uses them, remove them; if they were there before, leave them:

```bash
helm uninstall falco --namespace falco && kubectl delete namespace falco
helm uninstall tetragon --namespace tetragon && kubectl delete namespace tetragon
# Tetragon's operator creates two CRDs that helm uninstall leaves behind:
kubectl delete crd tracingpolicies.cilium.io tracingpoliciesnamespaced.cilium.io
```

If you installed the Amazon CloudWatch Observability add-on only for this blueprint, remove it as
its guide says. If you ran the optional GuardDuty stage, its step G4 turns it off. Deleting the
cluster removes everything; see the
[hello sandbox](../../getting-started/hello-sandbox/README.md) clean up.
