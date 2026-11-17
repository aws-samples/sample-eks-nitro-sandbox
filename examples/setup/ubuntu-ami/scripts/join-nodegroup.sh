#!/usr/bin/env bash
# join-nodegroup.sh: create this run's dedicated, tainted EKS managed node group on the verified
# AMI via a launch template, joining the EXISTING cluster named by CLUSTER_NAME. Never touches
# another node group; the taint keeps ordinary workloads off this node.
#
#   RUN_ID=<id> AMI_ID=<verified-ami-id> NODE_ROLE_ARN=<arn> scripts/join-nodegroup.sh
#   RUN_ID=<id> scripts/join-nodegroup.sh --render-user-data          # print the user data it would use
#   RUN_ID=<id> scripts/join-nodegroup.sh --check-user-data FILE      # only run the user-data check
#   RUN_ID=<id> scripts/join-nodegroup.sh --check-launch-template FILE # only run the launch-data check
#
# Names are per run: launch template <RESOURCE_PREFIX>-<RUN_ID>-lt, node group
# <RESOURCE_PREFIX>-<RUN_ID>-ng. The launch template, the node group, and (through the launch
# template's TagSpecifications) every node instance and volume carry ManagedBy and RunId.
#
# With a custom AMI in the launch template, EKS does not merge its own user data, and it applies
# the node group's API labels and taints asynchronously after the node registers. So the node's
# labels and taint are set by kubelet itself, deterministically, through Canonical's
# /etc/eks/bootstrap.sh --kubelet-extra-args:
#   --node-labels=eks.amazonaws.com/nodegroup=<NODEGROUP_NAME>   (what deploy/pod-*.yaml select)
#                 eks.amazonaws.com/nitro-sandbox=true          (what the shared isolated-sandbox
#                 sandbox.preview/nitro=true                     RuntimeClass selects; NODE_LABELS)
#   --register-with-taints=sandbox.preview/ubuntu-ami=true:NoSchedule
# The same taint is also set on the node group through the API. The bootstrap also gets the
# cluster's API endpoint, CA and DNS address (Canonical's AMI takes these as arguments).
#
# Two checks run before anything is created, and fail closed:
#   * the user data (check_user_data): comments and blank lines are stripped first; no line may
#     use a shell control operator or redirection (; & | && || ( ) < >) or a command substitution;
#     the active script must be `set -euo pipefail` at most, then exactly ONE
#     /etc/eks/bootstrap.sh command for this cluster and nothing after it. That command takes
#     --apiserver-endpoint, --b64-cluster-ca, --dns-cluster-ip and --kubelet-extra-args, each
#     exactly once and each followed by a value that is not an option, and nothing else, then the
#     cluster name as its last argument (Canonical's usage: bootstrap.sh [options]
#     <cluster-name>). The labels and taint are read from THAT command's --kubelet-extra-args,
#     never from anywhere else in the file;
#   * the launch template data (scripts/lib/launch_spec.py): IMDSv2 required with hop limit 1,
#     enclaves on, ManagedBy and RunId on the instance and volume TagSpecifications.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id

TAINT_KEY=sandbox.preview/ubuntu-ami
TAINT_VALUE=true
[[ "$NODE_LABELS" =~ ^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+(,[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+)*$ ]] || die "NODE_LABELS is not a comma-separated key=value list: $NODE_LABELS"
KUBELET_LABELS="eks.amazonaws.com/nodegroup=${NODEGROUP_NAME},${NODE_LABELS}"
KUBELET_TAINT="${TAINT_KEY}=${TAINT_VALUE}:NoSchedule"

# check_user_data <file>: see the header. Prints one FAIL line per problem; non-zero on any.
check_user_data() {
  python3 - "$1" "$CLUSTER_NAME" "$KUBELET_LABELS" "$KUBELET_TAINT" <<'PY'
import re, shlex, sys
path, cluster, labels, taint = sys.argv[1:5]
text = open(path).read()
bad = []
lines = text.split("\n")
if not lines or lines[0] != "#!/bin/bash":
    bad.append("user data does not start with #!/bin/bash (cloud-init would not run it as a script)")
# Join continuation lines, then drop blank and comment-only lines (shlex also drops trailing comments).
logical, cur = [], ""
for raw in lines[1:]:
    if raw.endswith("\\"):
        cur += raw[:-1] + " "
        continue
    cur += raw
    logical.append(cur)
    cur = ""
if cur:
    logical.append(cur)
def words(line):
    # The shell's own word split: quotes and comments as the shell reads them, and each control
    # operator or redirection (; & | && || ( ) < >) outside quotes as a word of its own.
    lex = shlex.shlex(line, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    return list(lex)
active = []
for l in logical:
    try:
        argv = words(l)
    except ValueError as e:
        bad.append(f"user data line does not parse: {l.strip()!r} ({e})")
        continue
    if not argv:
        continue
    ops = [w for w in argv if re.fullmatch(r"[();<>|&]+", w)]
    if ops:
        bad.append(f"user data line uses the shell control operator {ops[0]!r}, which runs or redirects another command: {l.strip()!r}")
    if any("`" in w or "$(" in w for w in argv):
        bad.append(f"user data line has a command substitution (` or $( ): {l.strip()!r}")
    active.append(argv)
boots = [i for i, a in enumerate(active) if a[0] == "/etc/eks/bootstrap.sh"]
if len(boots) != 1:
    bad.append(f"user data has {len(boots)} active /etc/eks/bootstrap.sh commands; exactly one is required")
else:
    i = boots[0]
    # Only `set -euo pipefail` may come before bootstrap.sh.
    before = [a for a in active[:i] if a != ["set", "-euo", "pipefail"]]
    if before:
        bad.append(f"user data runs other commands before bootstrap.sh: {' '.join(before[0])!r} (only 'set -euo pipefail' may come first)")
    if active[i + 1:]:
        bad.append(f"user data runs commands after bootstrap.sh: {' '.join(active[i + 1])!r}")
    argv = active[i]
    # usage: /etc/eks/bootstrap.sh [options] <cluster-name>. Between the command and the name: the
    # four options this sample passes, each exactly once, each followed by a value that is not
    # itself an option, and nothing else.
    value_flags = ("--apiserver-endpoint", "--b64-cluster-ca", "--dns-cluster-ip", "--kubelet-extra-args")
    is_option = lambda w: re.fullmatch(r"--?[A-Za-z][A-Za-z0-9-]*", w) is not None
    given = {}
    if len(argv) < 2 or argv[-1] != cluster:
        bad.append(f"bootstrap.sh is not given the cluster name {cluster!r} as its last argument, after every option")
    else:
        mid, j = argv[1:-1], 0
        while j < len(mid):
            flag = mid[j]
            if flag not in value_flags:
                bad.append(f"bootstrap.sh is given {flag!r} where one of its options ({', '.join(value_flags)}) is expected")
                break
            if j + 1 >= len(mid):   # the cluster name taken as this option's value
                bad.append(f"bootstrap.sh is not given the cluster name {cluster!r} as its last argument, after every option")
                break
            if is_option(mid[j + 1]):
                bad.append(f"bootstrap.sh {flag} is followed by the option {mid[j + 1]!r}, not a value")
                break
            given.setdefault(flag, []).append(mid[j + 1])
            j += 2
        else:
            for flag in value_flags:
                n = len(given.get(flag, []))
                if n == 0:
                    bad.append(f"bootstrap.sh lacks {flag} <value>")
                elif n > 1:
                    bad.append(f"bootstrap.sh is given {flag} {n} times; exactly once is required")
    # The labels and the taint are read from the word after --kubelet-extra-args in this command
    # (a missing --kubelet-extra-args is reported above).
    extra = []
    if "--kubelet-extra-args" in argv and argv.index("--kubelet-extra-args") + 1 < len(argv):
        extra = shlex.split(argv[argv.index("--kubelet-extra-args") + 1])
    have_labels = ",".join(x.split("=", 1)[1] for x in extra if x.startswith("--node-labels=")).split(",")
    have_taints = ",".join(x.split("=", 1)[1] for x in extra if x.startswith("--register-with-taints=")).split(",")
    for want in labels.split(","):
        if want not in have_labels:
            bad.append(f"bootstrap.sh --kubelet-extra-args --node-labels lacks {want}")
    if taint not in have_taints:
        bad.append(f"bootstrap.sh --kubelet-extra-args --register-with-taints lacks {taint}")
for b in bad:
    print("FAIL: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

case "${1:-}" in
  --check-user-data)
    [ -s "${2:-}" ] || die "usage: join-nodegroup.sh --check-user-data <file>"
    if check_user_data "$2"; then echo "USER DATA OK: $2"; exit 0; else echo "USER DATA REFUSED: $2" >&2; exit 1; fi ;;
  --check-launch-template)
    [ -s "${2:-}" ] || die "usage: join-nodegroup.sh --check-launch-template <file>"
    launch_spec check-lt "$2"; exit $? ;;
esac

# --- Render the user data from the cluster's own endpoint, CA and service CIDR (read only) ------
cluster_json=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --output json) \
  || die "could not read cluster $CLUSTER_NAME (describe-cluster failed)"
read -r api_endpoint cluster_ca service_cidr < <(printf '%s' "$cluster_json" \
  | json_get '[(d["cluster"]["endpoint"], d["cluster"]["certificateAuthority"]["data"], d["cluster"]["kubernetesNetworkConfig"]["serviceIpv4Cidr"])]')
[[ "$api_endpoint" == https://* && -n "$cluster_ca" && -n "$service_cidr" ]] || die "could not read endpoint, CA and service CIDR of cluster $CLUSTER_NAME"
[[ "$cluster_ca" =~ ^[A-Za-z0-9+/=]+$ ]] || die "cluster CA of $CLUSTER_NAME is not base64"
# EKS puts cluster DNS at the service CIDR's network address + 10 (10.100.0.10, 172.20.0.10).
dns_ip=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]).network_address + 10)' "$service_cidr")
mkdir -p "$RUN_STATE_DIR"
USER_DATA_FILE="$RUN_STATE_DIR/nodegroup-user-data.sh"
cat > "$USER_DATA_FILE" <<UD
#!/bin/bash
set -euo pipefail
/etc/eks/bootstrap.sh \\
  --apiserver-endpoint '$api_endpoint' \\
  --b64-cluster-ca '$cluster_ca' \\
  --dns-cluster-ip '$dns_ip' \\
  --kubelet-extra-args '--node-labels=$KUBELET_LABELS --register-with-taints=$KUBELET_TAINT' \\
  '$CLUSTER_NAME'
UD
check_user_data "$USER_DATA_FILE" || die "the rendered user data ($USER_DATA_FILE) failed its check; see the FAIL lines above"

if [ "${1:-}" = --render-user-data ]; then
  cat "$USER_DATA_FILE"
  exit 0
fi
[ $# -eq 0 ] || die "unknown argument: $1 (supported: --render-user-data, --check-user-data <file>, --check-launch-template <file>)"

: "${AMI_ID:?set AMI_ID to the fresh-instance-verified AMI}"
: "${NODE_ROLE_ARN:?set NODE_ROLE_ARN to the EKS node IAM role (EKS worker, ECR pull, VPC CNI, SSM)}"
read -r -a NODE_SUBNET_ARR <<< "$NODE_SUBNET_IDS"
[[ "${#NODE_SUBNET_ARR[@]}" -gt 0 ]] || die "NODE_SUBNET_IDS is empty; set it in config.env"

LT_DATA="$RUN_STATE_DIR/nodegroup-launch-template.json"
launch_spec render-lt --name "$NODEGROUP_NAME" --image-id "$AMI_ID" --instance-type "${NODE_INSTANCE_TYPE:-m8i.xlarge}" \
  --user-data-file "$USER_DATA_FILE" > "$LT_DATA"
launch_spec check-lt "$LT_DATA" || die "the launch template data $LT_DATA failed its check"

log "creating launch template $LT_NAME"
lt_id=$(aws ec2 create-launch-template \
  --region "$AWS_REGION" \
  --launch-template-name "$LT_NAME" \
  --launch-template-data "file://$LT_DATA" \
  --tag-specifications "ResourceType=launch-template,Tags=[$(run_tags_cli)]" \
  --output json | json_get 'd["LaunchTemplate"]["LaunchTemplateId"]')
[[ -n "$lt_id" ]] || die "create-launch-template returned no id"
log "launch template: $lt_id"

log "creating managed node group $NODEGROUP_NAME on cluster $CLUSTER_NAME"
aws eks create-nodegroup \
  --region "$AWS_REGION" \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "${NODE_SUBNET_ARR[@]}" \
  --scaling-config "minSize=${NODE_COUNT:-1},maxSize=${NODE_COUNT:-1},desiredSize=${NODE_COUNT:-1}" \
  --launch-template "id=$lt_id" \
  --taints "key=${TAINT_KEY},value=${TAINT_VALUE},effect=NO_SCHEDULE" \
  --tags "${TAGS_OWNER_KEY}=${TAGS_OWNER_VALUE},${TAGS_RUN_KEY}=${RUN_ID}" \
  --output json >/dev/null

log "waiting for node group to become ACTIVE (this can take several minutes)"
aws eks wait nodegroup-active --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
log "node group $NODEGROUP_NAME is ACTIVE"
printf '%s\n' "$NODEGROUP_NAME"
