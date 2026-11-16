# Logs a sandbox does not send to the node

Before you start, review the [prerequisites and shared setup](../../README.md#prerequisites)
on the home page, and run the [hello sandbox](../../getting-started/hello-sandbox/README.md)
blueprint first so you have a cluster with the runtime classes. This blueprint gives one pod
AWS permissions through EKS Pod Identity, as
[Getting started > Coding agent](../../getting-started/coding-agent/README.md) does, and uses
the side-by-side control of [Isolation > Sandbox limits](../../isolation/sandbox-limits/README.md).
The commands below use files from this repository, so clone it if you have not already, and
run them from this blueprint's folder:

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/observability/logging
```

You need `kubectl` and the AWS CLI, as for every blueprint. Beyond the cluster, a run costs a
small amount of CloudWatch Logs ingestion and storage.

A sandboxed pod's stdout and stderr leave the sandbox on their own. The Amazon EKS User
Guide (*Observability*) says container logs stream over the vsock channel to the parent
instance, so `kubectl logs` and the Amazon CloudWatch Observability agent work unchanged.
Three other places an app commonly logs to do not take that path:

- **Files the app writes.** An `emptyDir` and the container's writable layer live on the
  sandbox's own scratch disk (*Storage with Nitro Sandboxes*), so a node agent that tails pod
  volumes finds nothing there.
- **syslog.** An app that writes to `/dev/log`, often a `hostPath` mount of the node's
  socket, writes to a socket inside the sandbox instead.
- **The kernel log.** A segfault or a kernel warning is printed by the sandbox's own kernel,
  not by the node's, so it never reaches the node's journal.

This blueprint runs the same app twice, side by side, differing only in
`runtimeClassName: isolated-sandbox`, and shows each of the three reaching the node from the
ordinary pod and missing from the sandboxed one. It then adds a Fluent Bit sidecar to the
sandboxed pod. The sidecar shares the sandbox with the app, so it can read all three, and it
ships them one of two ways: to its own stdout, which the node agent already collects, or
straight to CloudWatch Logs.

- **stdout and stderr work unchanged.** Both pods' lines are in `kubectl logs` and in
  CloudWatch Logs through the node agent.
- **Files, syslog and the kernel log stay in the sandbox.** The ordinary pod's lines reach
  the node's pod folder and journal; the sandboxed pod's do not.
- **A sidecar in the same pod ships them.** It reads the files and the syslog socket from
  shared `emptyDir` volumes, and the kernel log with `CAP_SYSLOG`.
- **Output 1, stdout, needs nothing new.** No role and no network: it works in a sandbox
  booted with `sandbox.amazonaws.com/network-isolated: "true"` too.
- **Output 2, CloudWatch Logs directly, needs a role and a network.** The pod's Pod Identity
  role may create and write to one log group, and nothing else.

*Figure 1: Where each log goes. The ordinary pod's files, syslog and kernel log land on the
node; the sandboxed pod's stay in its VM, and the log sidecar there ships them.*

![An EKS Auto Mode node holds two pods. At the top, app-standard, an ordinary pod and the control, sends file, syslog and kernel log lines along a green arrow to the node journal and pod folders, and stdout and stderr along a grey arrow to the container logs that kubectl logs reads. Below, a Nitro sandbox pod frame labelled runtimeClassName isolated-sandbox holds a lightweight VM with its own kernel. In the VM the app passes its logs over shared volumes to a Fluent Bit log sidecar. A red arrow from the sandbox pod to the node journal says file, syslog and kernel log never arrive. A grey arrow carries stdout, from the app and from output 1 of the sidecar, out of the VM to the container logs, and a node agent ships the container logs to CloudWatch Logs outside the node. A second arrow, output 2, goes from the sidecar straight to CloudWatch Logs with the Pod Identity role.](images/logging-paths.png)

## Versions

| Component | Pin | Latest (2026-11-16) |
|---|---|---|
| Fluent Bit image ([`aws-for-fluent-bit`](https://gallery.ecr.aws/aws-observability/aws-for-fluent-bit)) | `public.ecr.aws/aws-observability/aws-for-fluent-bit:3.5.8` (Fluent Bit v5.1.5) | 3.5.8 |
| App image ([`python`](https://gallery.ecr.aws/docker/library/python)) | `public.ecr.aws/docker/library/python:3.12-slim` | 3.12-slim |
| Node agent ([Amazon CloudWatch Observability EKS add-on](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html)) | `v7.0.1-eksbuild.1` | v7.0.1-eksbuild.1 |
| Node debug image ([`amazonlinux`](https://gallery.ecr.aws/amazonlinux/amazonlinux)) | `public.ecr.aws/amazonlinux/amazonlinux:2023` | 2023 |

## Files

| File | What it is |
|---|---|
| [`deploy/namespace.yaml`](deploy/namespace.yaml) | The `sandbox-logging` namespace this blueprint owns |
| [`deploy/app.yaml`](deploy/app.yaml) | The app every pod runs, and the kernel-log helper, as a ConfigMap |
| [`deploy/app-standard.yaml`](deploy/app-standard.yaml) | The ordinary pod: the control |
| [`deploy/app-sandboxed.yaml`](deploy/app-sandboxed.yaml) | The same pod with `runtimeClassName: isolated-sandbox` |
| [`deploy/fluent-bit.yaml`](deploy/fluent-bit.yaml) | The log sidecar's configuration: three inputs, and the two outputs |
| [`deploy/app-sidecar-stdout.yaml`](deploy/app-sidecar-stdout.yaml) | The sandboxed pod with the sidecar, output 1: stdout |
| [`deploy/service-account.yaml`](deploy/service-account.yaml) | The ServiceAccount the Pod Identity association maps to the role |
| [`deploy/app-sidecar-cloudwatch.yaml`](deploy/app-sidecar-cloudwatch.yaml) | The sandboxed pod with the sidecar, output 2: CloudWatch Logs directly |
| [`deploy/app-sidecar-isolated.yaml`](deploy/app-sidecar-isolated.yaml) | The sidecar pod in a sandbox with no network, both outputs on |
| [`deploy/app-sandboxed-log-raised.yaml`](deploy/app-sandboxed-log-raised.yaml) | The sandboxed pod with its container-log rate raised by annotation |
| [`iam/pod-identity-trust.json`](iam/pod-identity-trust.json) | The trust policy both roles use: EKS Pod Identity |
| [`iam/cloudwatch-logs-policy.json`](iam/cloudwatch-logs-policy.json) | The sidecar role's permissions: one log group |
| [`scripts/compare.sh`](scripts/compare.sh) | Checks where each of the five sources ended up, for both pods, and prints a table |
| [`scripts/show-network.py`](scripts/show-network.py) | Prints a pod's interfaces, routes and whether the CloudWatch Logs endpoint resolves |
| [`scripts/log-burst.py`](scripts/log-burst.py) | Writes a burst of numbered lines to the container's stdout |
| [`scripts/run-log-burst.sh`](scripts/run-log-burst.sh) | Sends the same burst from two pods and times when `kubectl logs` has every line |

Set the names the commands use. They are the shared defaults on the home page plus this
blueprint's own:

```bash
export CLUSTER_NAME=sandbox-demo AWS_REGION=us-west-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LOG_GROUP=/eks-nitro-sandbox/logging
```

The run shown on this page used a shared cluster, so it named what it created with a
suffix: the namespace `sandbox-logging-i244`, the log group
`/eks-nitro-sandbox/logging-i244` and the roles `cwagent-i244` and `logging-sidecar-i244`.
Your output prints the names above instead. Node names, pod UIDs and addresses differ too.

**Step 1: Install the node agent, once per cluster.** The Amazon CloudWatch Observability
EKS add-on runs Fluent Bit on every node and ships each container's stdout and stderr to the
log group `/aws/containerinsights/$CLUSTER_NAME/application`. It is a per-cluster
prerequisite that other workloads may use too, so check for it first:

```bash
aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name amazon-cloudwatch-observability \
  --query 'addon.[addonVersion,status]' --output text
```

If that prints a version and `ACTIVE`, use the add-on as it is and go to step 2. If it says
the add-on is not found, install it with a Pod Identity role for its `cloudwatch-agent`
ServiceAccount, with the managed policy the add-on recommends:

```bash
aws iam create-role --role-name cwagent --tags Key=ManagedBy,Value=logging \
  --assume-role-policy-document file://iam/pod-identity-trust.json
aws iam attach-role-policy --role-name cwagent \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name amazon-cloudwatch-observability \
  --addon-version v7.0.1-eksbuild.1 --tags ManagedBy=logging \
  --pod-identity-associations serviceAccount=cloudwatch-agent,roleArn=arn:aws:iam::${ACCOUNT_ID}:role/cwagent
aws eks wait addon-active --cluster-name $CLUSTER_NAME --addon-name amazon-cloudwatch-observability
kubectl get daemonset -n amazon-cloudwatch fluent-bit cloudwatch-agent
```

These two blocks are from a separate run, after the same install on the same cluster: the
check above, and the add-on's two DaemonSets.

```text
v7.0.1-eksbuild.1	ACTIVE
NAME               DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
fluent-bit         3         3         3       3            3           kubernetes.io/os=linux   22m
cloudwatch-agent   3         3         3       3            3           kubernetes.io/os=linux   22m
```

The `fluent-bit` DaemonSet is the node agent the rest of this page relies on: one pod on
every node, sandbox-capable nodes included, reading the container logs the kubelet writes.

**Step 2: Deploy the two app pods.** The app in [`deploy/app.yaml`](deploy/app.yaml) writes
one line each tick to stdout, to stderr, to `/var/log/app/app.log` on an `emptyDir`, and to
the syslog socket `/dev/log`, and starts a child process that reads address 0, so the kernel
prints a segfault line too. Each line carries the pod name and a sequence number. Both pods
mount the node's `/dev/log` with a `hostPath`, as apps that log with syslog are often given
it.

`kubectl create` refuses a `sandbox-logging` namespace that already exists, so a namespace
this blueprint did not make is never relabeled as its own:

```bash
kubectl create -f deploy/namespace.yaml &&
kubectl apply -f deploy/app.yaml -f deploy/app-standard.yaml -f deploy/app-sandboxed.yaml &&
kubectl -n sandbox-logging wait pod/app-standard pod/app-sandboxed --for=condition=Ready --timeout=300s
```

```text
namespace/sandbox-logging-i244 created
configmap/logging-app created
pod/app-standard created
pod/app-sandboxed created
pod/app-standard condition met
pod/app-sandboxed condition met
```

The run also labeled its namespace for the shared cluster it ran on; that line is left out.

The two pods are the same but for one line:

```yaml
# app-standard.yaml                         # app-sandboxed.yaml
metadata:                                   metadata:
  name: app-standard                          name: app-sandboxed
spec:                                       spec:
                                              runtimeClassName: isolated-sandbox   # <-- only this
  containers:                                 containers:
    - name: app                                 - name: app
      command: ["python3", "-u",                  command: ["python3", "-u",
                "/app/app.py"]                              "/app/app.py"]
  volumes:                                    volumes:
    - name: app-logs                            - name: app-logs
      emptyDir: {}                                emptyDir: {}
    - name: dev-log                             - name: dev-log
      hostPath:                                   hostPath:
        path: /dev/log                              path: /dev/log
        type: Socket                                type: Socket
```

The block is trimmed to the fields that matter; the security context, the mounts and the
`POD_NAME` variable are the same in both files. The pods set no CPU or memory requests.

**Step 3: Confirm the sandboxed pod is in a sandbox.** Its own kernel build, a boot as old as
the pod, and virtio disks, next to what the ordinary pod shows:

```bash
for p in app-standard app-sandboxed; do
  echo "# $p"
  kubectl -n sandbox-logging exec $p -- sh -c 'uname -rv; cut -d" " -f1 /proc/uptime; ls /sys/block | tr "\n" " "; echo'
done
```

```text
# app-standard
6.18.62 #2 SMP PREEMPT_DYNAMIC Thu Nov 12 22:49:16 UTC 2026
2754.51
dm-0 nvme0n1 nvme1n1 zram0
# app-sandboxed
6.18.62 #1 SMP PREEMPT_DYNAMIC Thu Nov 12 22:44:15 UTC 2026
13.45
dm-0 vda vdb vdc
```

The run printed a space at the end of each disk list; the block trims it.

The kernel version string is the same, `6.18.62`, but the build is not (`#1` and its date
against the node's `#2`). The sandboxed pod's uptime, 13 seconds, is its own boot; the
ordinary pod reports the node's 46 minutes. The sandboxed pod sees virtio disks (`vda`,
`vdb`, `vdc`) where the ordinary pod sees the instance's `nvme` devices.

**Step 4: stdout and stderr reach the node from both pods.** `kubectl logs` reads the
kubelet's copy of each container's output:

```bash
kubectl -n sandbox-logging logs app-standard --tail=2
kubectl -n sandbox-logging logs app-sandboxed --tail=2
```

```text
stderr app-standard seq=15
stdout app-standard seq=15
stdout app-sandboxed seq=11
stderr app-sandboxed seq=11
```

The node agent ships the same lines to CloudWatch Logs. Ask for the latest stderr line of
each pod, with the stream the line was recorded on:

```bash
for p in app-standard app-sandboxed; do
  aws logs filter-log-events --log-group-name /aws/containerinsights/$CLUSTER_NAME/application \
    --filter-pattern "\"stderr $p seq=\"" --start-time $(( ($(date +%s) - 120) * 1000 )) \
    --query 'events[-1].message' --output json | python3 -c \
    'import json,sys; d=json.loads(json.load(sys.stdin)); print(d["kubernetes"]["pod_name"], d["stream"], d["log"])'
done
```

```text
app-standard stderr stderr app-standard seq=20
app-sandboxed stdout stderr app-sandboxed seq=17
```

Both pods' stderr lines are in CloudWatch Logs. Look at the second column: the ordinary pod's
stderr line is recorded on the `stderr` stream, and the sandboxed pod's on `stdout`. On this
run the sandbox delivered its two streams as one, which matters if you filter or alert on
the stream; [Good to know](#good-to-know) has more.

**Step 5: Files, syslog and the kernel log reach the node only from the ordinary pod.**
[`scripts/compare.sh`](scripts/compare.sh) counts each pod's lines where a node agent would
find them: the pod's `emptyDir` folder under `/var/lib/kubelet/pods/<pod uid>/volumes/`, and
the node's journal since the pod started, for the syslog line and the segfault. It runs those
checks in a node debug pod (`kubectl debug node/... --profile=sysadmin`) on each pod's node,
and deletes each debug pod by name when it is done:

```bash
scripts/compare.sh
```

```text
Reached the node since each pod started (lines counted):
pod            runtimeClass      stdout   stderr   file     syslog   kernel
app-standard   (none)            yes (22) yes (22) yes (22) yes (22) yes (22)
app-sandboxed  isolated-sandbox  yes (19) yes (16) no       no       no
```

The run printed spaces at the end of the header line; the block trims them.

stdout and stderr reach the node from both pods. The other three reach it from the ordinary
pod only, one line per tick each:

- **Files.** The node has a folder for the sandboxed pod's `emptyDir`, and it stays empty: the
  volume the app writes to is mounted from the sandbox's own scratch disk. Listed from a node
  debug pod on each pod's node (the path is shortened):

  ```text
  # app-standard
  total 4
  -rw-r--r--. 1 10001 10001 1766 Nov 16 19:19 app.log
  file app-standard seq=71
  # app-sandboxed
  total 0
  tail: cannot open '.../volumes/kubernetes.io~empty-dir/app-logs/app.log' for reading: No such file or directory
  ```

- **syslog.** The sandbox admits the pod with the `hostPath` of `/dev/log`, and the app's
  writes succeed, but they never reach the node's journal. Inside the sandbox `/dev/log` is a
  socket on a `tmpfs` of the guest's own, and the app logged no send failure:

  ```bash
  kubectl -n sandbox-logging exec app-sandboxed -- sh -c 'grep " /dev/log " /proc/mounts; ls -l /dev/log'
  kubectl -n sandbox-logging logs app-sandboxed | grep -c 'syslog to /dev/log failed'
  ```

  ```text
  tmpfs /dev/log tmpfs rw,seclabel,size=29660k,nr_inodes=819200,mode=755 0 0
  srw-rw-rw-. 1 root root 0 Nov 16 19:08 /dev/log
  0
  ```

  The `0` is the number of failed sends. So the writes are accepted and lost, which is
  harder to notice than a mount that fails.
- **The kernel log.** The ordinary pod's segfault is printed by the node's kernel into the
  node's journal. The sandboxed pod's is printed by the guest's kernel, which the node never
  sees. The Cedar policy schema has one exception, `WatchOomEvents`, which streams container
  OOM kill events from the guest to the node (Amazon EKS User Guide, *Cedar policy schema
  reference*); the rest of the kernel log stays in the guest.

**Step 6: Add the log sidecar, output 1: stdout.** The sidecar has to run in the same pod as
the app, because each pod gets a sandbox of its own: a container in another pod reads another
kernel and another disk. [`deploy/app-sidecar-stdout.yaml`](deploy/app-sidecar-stdout.yaml) is
`app-sandboxed` with three changes: the app sends syslog to a socket on a shared `emptyDir`
instead of the node's `/dev/log`, and two containers join it.

- **`kernel-log`** copies the guest kernel log to a file on a shared `emptyDir`. It reads it
  with `syslog(2)`, which needs `CAP_SYSLOG`, so it runs as UID 0 with every other capability
  dropped. `/dev/kmsg`, which Fluent Bit's own `kmsg` input reads, is not usable from a
  container in the sandbox: [Good to know](#good-to-know) has what was tried.
- **`fluent-bit`** tails the app's files and the kernel log file, owns the syslog socket, and
  writes every record to its own stdout as one JSON line.

Here is the part of `app-sidecar-stdout.yaml` that matters:

```yaml
spec:
  runtimeClassName: isolated-sandbox
  containers:
    - name: app
      env:
        - name: SYSLOG_SOCKET
          value: /run/syslog/log
    - name: kernel-log
      image: public.ecr.aws/docker/library/python:3.12-slim
      command: ["python3", "-u", "/app/kernel-log.py"]
      securityContext:
        runAsUser: 0
        runAsNonRoot: false
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["SYSLOG"]
        readOnlyRootFilesystem: true
    - name: fluent-bit
      image: public.ecr.aws/aws-observability/aws-for-fluent-bit:3.5.8
      command: ["/fluent-bit/bin/fluent-bit", "-c", "/fluent-bit/config/stdout.conf"]
  volumes:
    - name: app-logs
      emptyDir: {}
    - name: kernel-logs
      emptyDir: {}
    - name: syslog
      emptyDir: {}
```

And the sidecar's inputs and output 1, from [`deploy/fluent-bit.yaml`](deploy/fluent-bit.yaml)
(the `[SERVICE]` block and the filters that add `pod` and `source` to each record are left
out):

```ini
[INPUT]
    Name           tail
    Tag            file
    Path           /var/log/app/*.log
    Read_from_Head true

[INPUT]
    Name      syslog
    Tag       syslog
    Mode      unix_udp
    Path      /run/syslog/log
    Unix_Perm 0666
    Parser    syslog-rfc3164-local

[INPUT]
    Name           tail
    Tag            kernel
    Path           /var/log/kernel/kernel.log
    Read_from_Head true

[OUTPUT]
    Name   stdout
    Match  *
    Format json_lines
```

Deploy it, then read one record of each source from the sidecar's stdout:

```bash
kubectl apply -f deploy/fluent-bit.yaml -f deploy/app-sidecar-stdout.yaml &&
kubectl -n sandbox-logging wait pod/app-sidecar-stdout --for=condition=Ready --timeout=300s
sleep 60
for s in file syslog kernel; do
  kubectl -n sandbox-logging logs app-sidecar-stdout -c fluent-bit | grep "\"source\":\"$s\"" | grep -E 'seq=|segfault' | tail -1
done
```

```text
configmap/logging-fluent-bit created
pod/app-sidecar-stdout created
pod/app-sidecar-stdout condition met
{"date":1794856394.276984,"log":"file app-sidecar-stdout seq=8","pod":"app-sidecar-stdout","source":"file"}
{"date":1794856394.0,"pri":"14","time":"Nov 16 19:13:14","ident":"logging-app","pid":"1","message":"syslog app-sidecar-stdout seq=8","pod":"app-sidecar-stdout","source":"syslog"}
{"date":1794856394.298677,"log":"<6>[   73.026629] app-sidecar-std[1758]: segfault at 0 ip 00007fe8fb17a858 sp 00007ffc68a8b2d8 error 4 in libc.so.6[175858,7fe8fb02d000+163000] likely on CPU 0 (core 0, socket 0)","pod":"app-sidecar-stdout","source":"kernel"}
```

All three sources are now on the sidecar's stdout. The kernel line's `[   73.026629]` is
seconds since the guest booted, and `app-sidecar-std` is the crashing child, which names
itself after the pod (the kernel keeps 15 characters).

The node agent ships the sidecar's stdout like any container's, so the kernel line is in
CloudWatch Logs too, with no role and no new connection from the pod:

```bash
aws logs filter-log-events --log-group-name /aws/containerinsights/$CLUSTER_NAME/application \
  --log-stream-name-prefix "$(kubectl -n sandbox-logging get pod app-sidecar-stdout -o jsonpath='{.spec.nodeName}')-application.var.log.containers.app-sidecar-stdout_sandbox-logging_fluent-bit" \
  --filter-pattern '"segfault at 0"' --start-time $(( ($(date +%s) - 120) * 1000 )) \
  --query 'events[-1].message' --output json | python3 -c \
  'import json,sys; d=json.loads(json.load(sys.stdin)); print(d["kubernetes"]["container_name"], d["log"])'
```

```text
fluent-bit {"date":1794856384.252135,"log":"<6>[   62.976364] app-sidecar-std[1756]: segfault at 0 ip 00007fe8fb17a858 sp 00007ffc68a8b2d8 error 4 in libc.so.6[175858,7fe8fb02d000+163000] likely on CPU 0 (core 0, socket 0)","pod":"app-sidecar-stdout","source":"kernel"}
```

**Step 7: Output 2: CloudWatch Logs directly, with Pod Identity.**
[`deploy/app-sidecar-cloudwatch.yaml`](deploy/app-sidecar-cloudwatch.yaml) is
`app-sidecar-stdout` with Fluent Bit's `cloudwatch.conf` instead of `stdout.conf`, and the
`logging-sidecar` ServiceAccount. Its output sends each source to its own log stream in one log
group:

```ini
[OUTPUT]
    Name              cloudwatch_logs
    Match             *
    region            ${AWS_REGION}
    log_group_name    ${LOG_GROUP}
    log_stream_prefix ${POD_NAME}.
    auto_create_group true
```

The ServiceAccount's EKS Pod Identity role trusts EKS Pod Identity
([`iam/pod-identity-trust.json`](iam/pod-identity-trust.json), the same trust policy as the
coding agent's) and may do three things to one log group. Here is
[`iam/cloudwatch-logs-policy.json`](iam/cloudwatch-logs-policy.json) in full:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OneLogGroupOnly",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:<AWS_REGION>:<ACCOUNT_ID>:log-group:<LOG_GROUP>",
        "arn:aws:logs:<AWS_REGION>:<ACCOUNT_ID>:log-group:<LOG_GROUP>:log-stream:*"
      ]
    }
  ]
}
```

It cannot read logs, or touch any other log group. That role is the limit this blueprint
enforces on the pod. Nothing in the blueprint limits where the pod can connect: to restrict
that, see the [network policy](../../isolation/network-policy/README.md) blueprint.

Create the role, the association and the pod. The pod starts after a short wait, because a
pod created in the seconds after its association can start without credentials:

```bash
sed -e "s/<AWS_REGION>/$AWS_REGION/g; s/<ACCOUNT_ID>/$ACCOUNT_ID/g; s#<LOG_GROUP>#$LOG_GROUP#g" \
  iam/cloudwatch-logs-policy.json > /tmp/cloudwatch-logs-policy.json
aws iam create-role --role-name logging-sidecar --tags Key=ManagedBy,Value=logging \
  --assume-role-policy-document file://iam/pod-identity-trust.json
aws iam put-role-policy --role-name logging-sidecar --policy-name cloudwatch-logs-one-group \
  --policy-document file:///tmp/cloudwatch-logs-policy.json
kubectl apply -f deploy/service-account.yaml
aws eks create-pod-identity-association --cluster-name $CLUSTER_NAME \
  --namespace sandbox-logging --service-account logging-sidecar --tags ManagedBy=logging \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/logging-sidecar \
  --query 'association.[namespace,serviceAccount]' --output text
sleep 20
sed -e "s/<AWS_REGION>/$AWS_REGION/; s#<LOG_GROUP>#$LOG_GROUP#" deploy/app-sidecar-cloudwatch.yaml \
  | kubectl apply -f -
kubectl -n sandbox-logging wait pod/app-sidecar-cloudwatch --for=condition=Ready --timeout=300s
```

```text
serviceaccount/logging-sidecar created
sandbox-logging-i244	logging-sidecar
pod/app-sidecar-cloudwatch created
pod/app-sidecar-cloudwatch condition met
```

The block starts at the ServiceAccount: on the run shown, the role already existed.

A minute later the log group has one stream per source. Read the latest record of each:

```bash
aws logs describe-log-streams --log-group-name $LOG_GROUP --log-stream-name-prefix app-sidecar-cloudwatch \
  --query 'logStreams[].logStreamName' --output text
for s in file syslog kernel; do
  aws logs filter-log-events --log-group-name $LOG_GROUP --log-stream-names app-sidecar-cloudwatch.$s \
    --filter-pattern '?seq ?segfault' --start-time $(( ($(date +%s) - 90) * 1000 )) \
    --query 'events[-1].message' --output json | python3 -c 'import json,sys; print(json.load(sys.stdin))'
done
kubectl -n sandbox-logging logs app-sidecar-cloudwatch -c fluent-bit | grep -cE '\[error\]'
```

```text
app-sidecar-cloudwatch.file	app-sidecar-cloudwatch.kernel	app-sidecar-cloudwatch.syslog
{"log":"file app-sidecar-cloudwatch seq=9","pod":"app-sidecar-cloudwatch","source":"file"}
{"pri":"14","time":"Nov 16 19:15:34","ident":"logging-app","pid":"1","message":"syslog app-sidecar-cloudwatch seq=9","pod":"app-sidecar-cloudwatch","source":"syslog"}
{"log":"<6>[   83.235362] app-sidecar-clo[1749]: segfault at 0 ip 00007f93e017a858 sp 00007ffcb71c7208 error 4 in libc.so.6[175858,7f93e002d000+163000] likely on CPU 0 (core 0, socket 0)","pod":"app-sidecar-cloudwatch","source":"kernel"}
0
```

The file, syslog and kernel records of the sandboxed pod are in the blueprint's own log
group, sent from inside the sandbox, and Fluent Bit logged no error. This output costs a role
and a connection from the pod; output 1 costs neither.

## Optional: a sandbox with no network

[`deploy/app-sidecar-isolated.yaml`](deploy/app-sidecar-isolated.yaml) is
`app-sidecar-stdout` booted with no network, and with both outputs on (`both.conf`):

```yaml
metadata:
  name: app-sidecar-isolated
  annotations:
    sandbox.amazonaws.com/network-isolated: "true"
```

```bash
sed -e "s/<AWS_REGION>/$AWS_REGION/; s#<LOG_GROUP>#$LOG_GROUP#" deploy/app-sidecar-isolated.yaml \
  | kubectl apply -f -
kubectl -n sandbox-logging wait pod/app-sidecar-isolated --for=condition=Ready --timeout=300s
sleep 60
for p in app-sidecar-isolated app-sidecar-stdout; do
  echo "# $p"
  kubectl -n sandbox-logging exec -i $p -c app -- env ENDPOINT=logs.$AWS_REGION.amazonaws.com \
    python3 - < scripts/show-network.py
done
```

```text
# app-sidecar-isolated
interface dummy0: no IPv4 address
interface lo: 127.0.0.1
routes: 0
resolve logs.us-west-2.amazonaws.com: gaierror [Errno -3] Temporary failure in name resolution
# app-sidecar-stdout
interface dummy0: 169.254.169.254
interface eth0: 192.168.110.146
interface lo: 127.0.0.1
routes: 3
resolve logs.us-west-2.amazonaws.com: 44.234.123.69
```

The block leaves out the `pod/... created` and `condition met` lines.

The isolated pod has only loopback with an address, no route, and no DNS. The pod with a
network has `eth0` and three routes, and resolves the endpoint. So output 2 cannot connect,
and output 1 still delivers, because container stdout leaves the sandbox over its internal
channel to the node, not over the network:

```bash
kubectl -n sandbox-logging logs app-sidecar-isolated -c fluent-bit | grep -E '\[(error|warn)\]' | grep -v imds | head -4
for s in file syslog kernel; do
  kubectl -n sandbox-logging logs app-sidecar-isolated -c fluent-bit | grep "\"source\":\"$s\"" | grep -E 'seq=|segfault' | tail -1
done
aws logs describe-log-streams --log-group-name $LOG_GROUP --log-stream-name-prefix app-sidecar-isolated \
  --query 'length(logStreams)' --output text
```

```text
[2026/11/16 19:16:04.399] [error] [aws_client] connection initialization error
[2026/11/16 19:16:04.505] [error] [aws_client] connection initialization error
[2026/11/16 19:16:04.506] [error] [output:cloudwatch_logs:cloudwatch_logs.1] Failed to create log stream
[2026/11/16 19:16:04.506] [error] [output:cloudwatch_logs:cloudwatch_logs.1] Failed to send events
{"date":1794856637.424312,"log":"file app-sidecar-isolated seq=9","pod":"app-sidecar-isolated","source":"file"}
{"date":1794856637.0,"pri":"14","time":"Nov 16 19:17:17","ident":"logging-app","pid":"1","message":"syslog app-sidecar-isolated seq=9","pod":"app-sidecar-isolated","source":"syslog"}
{"date":1794856637.459778,"log":"<6>[   83.172616] app-sidecar-iso[1767]: segfault at 0 ip 00007f9b2c582858 sp 00007ffe3e2ea3b8 error 4 in libc.so.6[175858,7f9b2c435000+163000] likely on CPU 0 (core 0, socket 0)","pod":"app-sidecar-isolated","source":"kernel"}
0
```

The CloudWatch Logs output fails to connect, and the log group has no stream from this pod
(`0`). The stdout output has all three sources, and the node agent ships them as in step 6:

```text
fluent-bit {"date":1794856738.0,"pri":"14","time":"Nov 16 19:18:58","ident":"logging-app","pid":"1","message":"syslog app-sidecar-isolated seq=19","pod":"app-sidecar-isolated","source":"syslog"}
```

That line comes from the step 6 CloudWatch command with `app-sidecar-isolated` in place of
`app-sidecar-stdout` and the filter `'"syslog app-sidecar-isolated"'` over the last five
minutes.

## The container-log rate limit

The sandbox caps how fast container logs stream out of it. The Amazon EKS User Guide
(*Resource isolation and throttling*) documents the annotation
`sandbox.amazonaws.com/log-bandwidth`, "Container log streaming throughput", with a default
of `2M`: 2 Mbit/s, equivalent to 250 KBps. The annotation is read once, when the pod is
created. Output 1 shares this limit with the app's own stdout, because both are container
logs of the same pod.

[`scripts/run-log-burst.sh`](scripts/run-log-burst.sh) writes the same 4 MB burst to a pod's
stdout and times how long `kubectl logs` takes to show every line. It runs on the ordinary
pod, the sandboxed pod, and
[`deploy/app-sandboxed-log-raised.yaml`](deploy/app-sandboxed-log-raised.yaml), which is
`app-sandboxed` with the limit raised to 20M:

```yaml
metadata:
  name: app-sandboxed-log-raised
  annotations:
    sandbox.amazonaws.com/log-bandwidth: "20M"   # <-- the only change from app-sandboxed
```

```bash
kubectl apply -f deploy/app-sandboxed-log-raised.yaml &&
kubectl -n sandbox-logging wait pod/app-sandboxed-log-raised --for=condition=Ready --timeout=300s
scripts/run-log-burst.sh app-standard app-sandboxed app-sandboxed-log-raised
```

```text
== app-standard: 4 MB to stdout
wrote 4000 lines (4.0 MB) in 0.1s = 493.2 Mbit/s
kubectl logs shows 4000 of 4000 lines 2s after the burst started
== app-sandboxed: 4 MB to stdout
wrote 4000 lines (4.0 MB) in 0.6s = 55.9 Mbit/s
kubectl logs shows 4000 of 4000 lines 17s after the burst started
== app-sandboxed-log-raised: 4 MB to stdout
wrote 4000 lines (4.0 MB) in 0.0s = 1446.2 Mbit/s
kubectl logs shows 4000 of 4000 lines 3s after the burst started
```

The block leaves out the `pod/... created` and `condition met` lines.

The symptom is late logs, not lost ones: every line arrived from all three pods. The
sandboxed pod's burst took 17 seconds to show in full, about 1.9 Mbit/s over the 4 MB and the
time the script measures from (which includes starting `kubectl exec`), near the documented
2 Mbit/s. The ordinary pod's took 2 seconds, and with the annotation at 20M the sandboxed pod's
took 3. The time a write takes is not the symptom to watch for this size: the app's writes
returned in under a second, and the lines queued inside the sandbox. On an earlier run of a
10 MB burst, the app's writes themselves took about 24 seconds, so a larger burst can slow
the app down too.

If a sandboxed pod's logs arrive minutes behind, or a chatty app slows down only in a
sandbox, raise `sandbox.amazonaws.com/log-bandwidth` on the pod, or log less to stdout.

## Confidential mode

This blueprint uses `isolated-sandbox`, and was not run in `confidential-sandbox`. In
confidential mode the parent instance, the node, is untrusted, and two things follow for a
log sidecar:

- **The sidecar is part of the pod's policy.** Every container is admitted against the
  pod's Cedar policy, whose `CreateContainer` context carries the image, the command, the
  mounts and the capabilities (Amazon EKS User Guide, *Cedar policy schema reference*). So the
  `kernel-log` and `fluent-bit` containers, and `kernel-log`'s `CAP_SYSLOG`, must be in the
  policy you generate, as the app is.
- **Every log line that leaves the guest is data you hand out.** Output 1 goes through the
  node, which confidential mode does not trust, so the node can read every line. Output 2 goes
  to CloudWatch Logs, so whoever can read that log group can read every line. Log only what you
  would let the node or those readers see.

## Good to know

- **A sandboxed pod's stdout and stderr arrive as one stream.** On the run shown, the node
  recorded the sandboxed pod's stderr lines on the `stdout` stream (step 4), and a stdout line
  and a stderr line written together sometimes ran into one line. This is what the run
  measured, not something the User Guide states:

  ```bash
  kubectl -n sandbox-logging logs app-sandboxed | grep -vE '^(stdout|stderr) app-sandboxed seq=[0-9]+$' | head
  ```

  ```text
  stdout app-sandboxed seq=6stderr app-sandboxed seq=6

  stdout app-sandboxed seq=16stderr app-sandboxed seq=16

  stdout app-sandboxed seq=19stderr app-sandboxed seq=19

  ```

  If you need the two apart, write a level into each line, or send structured logs through
  the sidecar.
- **The kernel log needs `CAP_SYSLOG`, and `/dev/kmsg` does not work.** In a separate probe on
  the same cluster, a container in the sandbox had no `/dev/kmsg`, even with
  `privileged: true`. With a `hostPath` of `/dev/kmsg` the device appeared, and opening it
  failed with `Operation not permitted`, even privileged. Reading the kernel buffer with
  `syslog(2)` (what `dmesg` does) worked from a container running as UID 0 with only
  `CAP_SYSLOG`, and failed for a non-root container with no capabilities. So this blueprint
  copies the log with `syslog(2)` rather than using Fluent Bit's `kmsg` input. The first read
  returns the guest's boot messages too, about a thousand lines.
- **The Pod Identity credentials reach every container in the pod**, not only the sidecar:
  the association is per ServiceAccount, and the pod has one. Give the role only what the
  sidecar needs, as this one does.
- **The node cannot measure the sandbox's scratch disk.** The Amazon EKS User Guide
  (*Considerations*) says ephemeral storage usage for `emptyDir` volumes and the writable
  layer reports as zero, because the data lives inside the sandbox. A log file that grows
  forever fills the sandbox's disk without the kubelet seeing it, so rotate it, or let the
  sidecar ship it and keep it short.
- **One sidecar per sandboxed pod.** A node DaemonSet cannot read a sandbox's files, syslog or
  kernel, so the collector has to be in each pod that needs it.

## Clean up

Set the variables again, for a new shell:

```bash
export CLUSTER_NAME=sandbox-demo AWS_REGION=us-west-2
export LOG_GROUP=/eks-nitro-sandbox/logging
```

First confirm the namespace and the role are this blueprint's: each command must print
`logging`. If one prints anything else, it is not this blueprint's, so do not delete it.

```bash
kubectl get namespace sandbox-logging -o jsonpath='{.metadata.labels.sample}{"\n"}'
aws iam list-role-tags --role-name logging-sidecar --query "Tags[?Key=='ManagedBy'].Value" --output text
```

Then delete the namespace, which takes every pod, the ConfigMaps and the ServiceAccount with
it; the Pod Identity association; the role; and the log group:

```bash
kubectl delete namespace sandbox-logging
for id in $(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME \
              --namespace sandbox-logging --service-account logging-sidecar \
              --query 'associations[].associationId' --output text); do
  aws eks delete-pod-identity-association --cluster-name $CLUSTER_NAME --association-id $id
done
aws iam delete-role-policy --role-name logging-sidecar --policy-name cloudwatch-logs-one-group
aws iam delete-role --role-name logging-sidecar
aws logs delete-log-group --log-group-name $LOG_GROUP
```

The CloudWatch Observability add-on is a per-cluster install. If you installed it in step 1
and nothing else on the cluster uses it, remove it and its role (check the role's
`ManagedBy` tag the same way first):

```bash
aws eks delete-addon --cluster-name $CLUSTER_NAME --addon-name amazon-cloudwatch-observability
aws iam detach-role-policy --role-name cwagent \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam delete-role --role-name cwagent
```

The add-on wrote the log groups under `/aws/containerinsights/$CLUSTER_NAME/`. Delete those
too if they did not exist before you installed it. To remove the cluster, see the
[hello sandbox](../../getting-started/hello-sandbox/README.md) clean up.
