#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly OWNER_KEY="ManagedBy"
readonly OWNER="openclaw-enterprise-blueprint"
readonly INVOCATION_KEY="OpenClawSetupInvocation"
readonly INVOCATION_LABEL="openclaw.enterprise/setup-invocation"
readonly NAMESPACE="openclaw-enterprise-agw"
readonly SERVICE_ACCOUNT="agentgateway"
readonly REGION_CONFIG_MAP="agentgateway-aws-region"
readonly POLICY_NAME="openclaw-enterprise-bedrock-invoke"
readonly MODEL_ID="amazon.nova-lite-v1:0"

usage() {
  cat >&2 <<'EOF'
Usage: setup-agentgateway-pod-identity.sh \
  --aws-region REGION --aws-account-id ACCOUNT_ID \
  --eks-cluster-name CLUSTER_NAME --kube-context CONTEXT \
  [--iam-role-name NAME] [--receipt FILE]

Creates or verifies the AgentGateway Kubernetes identity, IAM role and policy,
and EKS Pod Identity association. Existing resources must match this sample.
A receipt enables interruption recovery and records created/reused provenance
for cleanup.
EOF
}

die() {
  echo "setup-agentgateway-pod-identity: $*" >&2
  exit 1
}

require_value() {
  [[ -n "${2:-}" && "${2:-}" != --* ]] ||
    die "$1 requires an explicit value."
}

AWS_REGION=""
AWS_ACCOUNT_ID=""
EKS_CLUSTER_NAME=""
KUBE_CONTEXT=""
ROLE_NAME="openclaw-enterprise-agentgateway"
RECEIPT_PATH=""
while (( $# )); do
  case "$1" in
    --aws-region) require_value "$1" "${2:-}"; AWS_REGION="$2"; shift 2 ;;
    --aws-account-id)
      require_value "$1" "${2:-}"; AWS_ACCOUNT_ID="$2"; shift 2
      ;;
    --eks-cluster-name)
      require_value "$1" "${2:-}"; EKS_CLUSTER_NAME="$2"; shift 2
      ;;
    --kube-context)
      require_value "$1" "${2:-}"; KUBE_CONTEXT="$2"; shift 2
      ;;
    --iam-role-name)
      require_value "$1" "${2:-}"; ROLE_NAME="$2"; shift 2
      ;;
    --receipt) require_value "$1" "${2:-}"; RECEIPT_PATH="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

missing=false
for pair in "--aws-region|${AWS_REGION}" "--aws-account-id|${AWS_ACCOUNT_ID}" \
  "--eks-cluster-name|${EKS_CLUSTER_NAME}" "--kube-context|${KUBE_CONTEXT}"; do
  IFS='|' read -r option value <<<"${pair}"
  if [[ -z "${value}" ]]; then
    echo "setup-agentgateway-pod-identity: ${option} is required." >&2
    missing=true
  fi
done
[[ "${missing}" == false ]] || { usage; exit 2; }
[[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] ||
  die "--aws-account-id must be a 12-digit AWS account ID."
if [[ ! "${AWS_REGION}" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] ||
  (( ${#AWS_REGION} > 32 )); then
  die "--aws-region is invalid."
fi
[[ "${EKS_CLUSTER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] ||
  die "--eks-cluster-name is invalid."
[[ "${ROLE_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] ||
  die "--iam-role-name is invalid."
[[ -z "${RECEIPT_PATH}" || "${RECEIPT_PATH}" = /* ]] ||
  die "--receipt must be an absolute path."
readonly ROLE_NAME
for command in aws kubectl jq mktemp python3 grep; do
  command -v "${command}" >/dev/null || die "${command} is required."
done

work_dir="$(mktemp -d)"
chmod 700 "${work_dir}"
lock_path=""
lock_token=""
lock_acquired=false
release_lock() {
  [[ "${lock_acquired}" == true && -d "${lock_path}" &&
    ! -L "${lock_path}" && -f "${lock_path}/token" &&
    ! -L "${lock_path}/token" ]] || return 0
  [[ "$(<"${lock_path}/token")" == "${lock_token}" ]] || return 0
  rm -f -- "${lock_path}/pid" "${lock_path}/token"
  rmdir -- "${lock_path}" 2>/dev/null || true
}
snapshot_dir=""
cleanup() {
  local status="$?"
  release_lock
  rm -rf -- "${work_dir}"
  [[ -z "${snapshot_dir}" ]] || rm -rf -- "${snapshot_dir}"
  trap - EXIT
  exit "${status}"
}
trap cleanup EXIT

# Receipts contain account and resource identities. Keep the parent and file
# private, reject symlinks, and replace files through a directory descriptor.
check_private_path() {
  python3 -I - "$1" <<'PY'
import os, stat, sys
path = sys.argv[1]
parent = os.path.dirname(path)
if not os.path.isabs(path) or not os.path.basename(path):
    raise SystemExit("invalid state path")
if os.path.realpath(parent) != os.path.abspath(parent):
    raise SystemExit("state parent contains a symlink")
info = os.lstat(parent)
if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
    raise SystemExit("state parent is not an owned directory")
if stat.S_IMODE(info.st_mode) & 0o077:
    raise SystemExit("state parent grants group or other access")
if os.path.lexists(path):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise SystemExit("state path is not an owned regular file")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise SystemExit("state file grants group or other access")
PY
}
atomic_install() {
  python3 -I - "$1" "$2" <<'PY'
import os, secrets, stat, sys
source, destination = sys.argv[1:]
parent, name = os.path.split(destination)
directory = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
temporary = f".{name}.tmp.{secrets.token_hex(8)}"
descriptor = -1
try:
    try:
        current = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
            raise SystemExit("unsafe destination")
    except FileNotFoundError:
        pass
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600,
        dir_fd=directory,
    )
    with open(source, "rb") as reader, os.fdopen(descriptor, "wb") as writer:
        descriptor = -1
        while chunk := reader.read(1024 * 1024):
            writer.write(chunk)
        writer.flush()
        os.fsync(writer.fileno())
    os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    os.fsync(directory)
finally:
    if descriptor >= 0:
        os.close(descriptor)
    try:
        os.unlink(temporary, dir_fd=directory)
    except FileNotFoundError:
        pass
    os.close(directory)
PY
}
acquire_lock() {
  local stale="${lock_path}.stale.$$"
  local holder
  lock_token="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"
  if ! mkdir -- "${lock_path}" 2>/dev/null; then
    [[ -d "${lock_path}" && ! -L "${lock_path}" &&
      -f "${lock_path}/pid" && ! -L "${lock_path}/pid" ]] ||
      die "receipt lock is unsafe: ${lock_path}"
    holder="$(<"${lock_path}/pid")"
    [[ "${holder}" =~ ^[1-9][0-9]*$ ]] ||
      die "receipt lock has an invalid owner."
    kill -0 "${holder}" 2>/dev/null &&
      die "another invocation is using ${RECEIPT_PATH}."
    mv -- "${lock_path}" "${stale}" 2>/dev/null ||
      die "another invocation acquired ${RECEIPT_PATH}."
    rm -f -- "${stale}/pid" "${stale}/token"
    rmdir -- "${stale}" || die "could not remove stale receipt lock."
    mkdir -- "${lock_path}" || die "could not acquire receipt lock."
  fi
  chmod 700 "${lock_path}"
  printf '%s\n' "$$" >"${lock_path}/pid"
  printf '%s\n' "${lock_token}" >"${lock_path}/token"
  chmod 600 "${lock_path}/pid" "${lock_path}/token"
  lock_acquired=true
}
if [[ -n "${RECEIPT_PATH}" ]]; then
  check_private_path "${RECEIPT_PATH}" || die "--receipt path is unsafe."
  lock_path="${RECEIPT_PATH}.lock"
  [[ ! -L "${lock_path}" ]] || die "receipt lock is a symbolic link."
  acquire_lock
fi

# Pin every kubectl call to one private, flattened context snapshot. This avoids
# context switching and prevents credential material leaking through a temp file.
# With a receipt, the snapshots live beside it in its checked private directory,
# not in TMPDIR, where a hard kill that skips the exit trap would leave them.
snapshot_dir="${work_dir}"
if [[ -n "${RECEIPT_PATH}" ]]; then
  snapshot_dir="$(
    mktemp -d "${RECEIPT_PATH%/*}/.setup-agentgateway-pod-identity-kubeconfig.XXXXXX"
  )" || die "could not create a private kubeconfig snapshot directory."
  chmod 700 "${snapshot_dir}"
fi
source_kubeconfig="${KUBECONFIG:-${HOME}/.kube/config}"
source_snapshot="${snapshot_dir}/source-kubeconfig"
kubeconfig_file="${snapshot_dir}/kubeconfig.json"
[[ "${source_kubeconfig}" = /* && "${source_kubeconfig}" != *:* ]] ||
  die "KUBECONFIG must name one absolute file."
python3 -I - "${source_kubeconfig}" "${source_snapshot}" <<'PY'
import os, stat, sys
source, destination = sys.argv[1:]
parent, name = os.path.split(source)
if os.path.realpath(parent) != os.path.abspath(parent):
    raise SystemExit("kubeconfig parent contains a symlink")
directory = os.open(
    parent, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
)
descriptor = os.open(
    name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=directory
)
try:
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise SystemExit("kubeconfig is not an owned regular file")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise SystemExit("kubeconfig grants group or other access")
    output = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(output, "wb") as target:
        while chunk := os.read(descriptor, 1024 * 1024):
            target.write(chunk)
finally:
    os.close(descriptor)
    os.close(directory)
PY
kubectl --kubeconfig "${source_snapshot}" config view --raw --flatten --minify \
  --context "${KUBE_CONTEXT}" --output=json >"${kubeconfig_file}" ||
  die "could not snapshot kube context ${KUBE_CONTEXT}."
chmod 600 "${kubeconfig_file}"
jq -e --arg context "${KUBE_CONTEXT}" '
  .["current-context"] == $context
  and ([.contexts[] | select(.name == $context)] | length == 1)
  and ([.contexts[] | select(.name == $context)][0].context.cluster as $name
    | [.clusters[] | select(.name == $name)] | length == 1)
' "${kubeconfig_file}" >/dev/null ||
  die "kube context snapshot is incomplete or ambiguous."
context_endpoint="$(jq -er --arg context "${KUBE_CONTEXT}" '
  [.contexts[] | select(.name == $context)][0].context.cluster as $name
  | [.clusters[] | select(.name == $name)][0].cluster.server
  | strings | select(length > 0)
' "${kubeconfig_file}")" || die "kube context has no endpoint."
readonly -a KUBECTL=(
  kubectl --kubeconfig "${kubeconfig_file}" --context "${KUBE_CONTEXT}"
)
"${KUBECTL[@]}" get --raw=/readyz >/dev/null ||
  die "kube context ${KUBE_CONTEXT} is not reachable."

# Verify explicit AWS identity and the kube endpoint before creating anything.
readonly -a AWS=(aws --no-cli-pager --region "${AWS_REGION}")
aws_json() {
  local description="$1"
  local output
  shift
  output="$("${AWS[@]}" "$@" --output json)" ||
    die "could not verify ${description}."
  jq -e . >/dev/null <<<"${output}" ||
    die "${description} returned malformed or partial JSON."
  printf '%s' "${output}"
}
caller_json="$(aws_json "AWS account" sts get-caller-identity)"
caller_account="$(jq -er '.Account | strings | select(test("^[0-9]{12}$"))' \
  <<<"${caller_json}")" || die "AWS returned an incomplete caller identity."
[[ "${caller_account}" == "${AWS_ACCOUNT_ID}" ]] ||
  die "AWS CLI uses account ${caller_account}, not ${AWS_ACCOUNT_ID}."
cluster_json="$(aws_json "EKS cluster" eks describe-cluster \
  --name "${EKS_CLUSTER_NAME}")"
cluster_record="$(jq -er \
  '.cluster | [.name, .arn, .endpoint] | map(strings) | @tsv' \
  <<<"${cluster_json}")" || die "EKS returned an incomplete cluster identity."
IFS=$'\t' read -r returned_name cluster_arn cluster_endpoint extra \
  <<<"${cluster_record}"
[[ "${returned_name}" == "${EKS_CLUSTER_NAME}" && -z "${extra:-}" ]] ||
  die "EKS returned an unexpected cluster identity."
IFS=: read -r literal partition service region account resource arn_extra \
  <<<"${cluster_arn}"
[[ "${literal}" == arn && -n "${partition}" && "${service}" == eks &&
  "${region}" == "${AWS_REGION}" && "${account}" == "${AWS_ACCOUNT_ID}" &&
  "${resource}" == "cluster/${EKS_CLUSTER_NAME}" && -z "${arn_extra:-}" ]] ||
  die "EKS cluster ARN differs from the explicit region, account, or name."
[[ "${context_endpoint}" == "${cluster_endpoint}" ]] ||
  die "kube context ${KUBE_CONTEXT} targets another EKS cluster."
role_arn="arn:${partition}:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
association_prefix="arn:${partition}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:podidentityassociation/${EKS_CLUSTER_NAME}/"

trust_file="${work_dir}/trust.json"
policy_file="${work_dir}/policy.json"
jq -n --arg account "${AWS_ACCOUNT_ID}" --arg cluster "${cluster_arn}" '
  {Version:"2012-10-17",Statement:[{
    Sid:"AllowAgentGatewayPodIdentity",Effect:"Allow",
    Principal:{Service:"pods.eks.amazonaws.com"},
    Action:["sts:AssumeRole","sts:TagSession"],
    Condition:{StringEquals:{
      "aws:SourceAccount":$account,
      "aws:RequestTag/kubernetes-namespace":"openclaw-enterprise-agw",
      "aws:RequestTag/kubernetes-service-account":"agentgateway"
    },ArnEquals:{"aws:SourceArn":$cluster}}
  }]}
' >"${trust_file}"
jq -n --arg region "${AWS_REGION}" \
  --arg model "arn:${partition}:bedrock:${AWS_REGION}::foundation-model/${MODEL_ID}" '
  {Version:"2012-10-17",Statement:[{
    Sid:"InvokeCentralBedrockModel",Effect:"Allow",
    Action:["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
    Resource:$model,Condition:{StringEquals:{"aws:RequestedRegion":$region}}
  }]}
' >"${policy_file}"
policy_sha256="$(python3 -I - "${policy_file}" <<'PY'
import hashlib, json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
print(hashlib.sha256(json.dumps(
    value, sort_keys=True, separators=(",", ":")
).encode()).hexdigest())
PY
)"

# The journal stores only provenance state. Immutable IDs belong in the final
# receipt; interrupted creates are recovered by their random invocation marker.
receipt_existing=false
journal_path=""
journal_file="${work_dir}/journal.json"
invocation_id="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"
namespace_state=unknown
service_account_state=unknown
region_config_map_state=unknown
role_state=unknown
policy_state=unknown
association_state=unknown
validate_receipt() {
  jq -e --arg context "${KUBE_CONTEXT}" --arg endpoint "${cluster_endpoint}" \
    --arg region "${AWS_REGION}" --arg account "${AWS_ACCOUNT_ID}" \
    --arg cluster "${EKS_CLUSTER_NAME}" --arg cluster_arn "${cluster_arn}" \
    --arg role_name "${ROLE_NAME}" --arg role_arn "${role_arn}" \
    --arg association_prefix "${association_prefix}" '
    def bool: type == "boolean";
    def invocation: type == "string" and test("^[a-f0-9]{32}$");
    . as $root
    | .version == 2 and .operation == "setup-agentgateway-pod-identity"
    and .target == {
      kubeContext:$context,clusterEndpoint:$endpoint,awsRegion:$region,
      awsAccountId:$account,eksClusterName:$cluster,eksClusterArn:$cluster_arn
    }
    and (.resources | keys | sort) == [
      "iamRole","inlinePolicy","namespace",
      "podIdentityAssociation","regionConfigMap","serviceAccount"
    ]
    and (.resources.namespace |
      .apiVersion == "v1" and .kind == "Namespace"
      and .name == "openclaw-enterprise-agw"
      and (.uid | strings | length > 0) and (.created | bool))
    and (.resources.serviceAccount |
      .apiVersion == "v1" and .kind == "ServiceAccount"
      and .namespace == "openclaw-enterprise-agw" and .name == "agentgateway"
      and (.uid | strings | length > 0) and (.created | bool))
    and (.resources.regionConfigMap |
      .apiVersion == "v1" and .kind == "ConfigMap"
      and .namespace == "openclaw-enterprise-agw"
      and .name == "agentgateway-aws-region"
      and (.uid | strings | length > 0) and (.created | bool))
    and (.resources.iamRole |
      .name == $role_name and .arn == $role_arn
      and (.roleId | test("^ARO[A-Z0-9]{16,}$"))
      and (.invocationId | invocation) and (.created | bool))
    and (.resources.inlinePolicy |
      .name == "openclaw-enterprise-bedrock-invoke"
      and .roleName == $role_name
      and .roleId == $root.resources.iamRole.roleId
      and (.documentSha256 | test("^[a-f0-9]{64}$"))
      and (.created | bool))
    and (.resources.podIdentityAssociation |
      .clusterName == $cluster and .namespace == "openclaw-enterprise-agw"
      and .serviceAccount == "agentgateway" and .roleArn == $role_arn
      and (.associationId | test("^a-[a-z0-9]{17}$"))
      and .associationArn == ($association_prefix + .associationId)
      and .targetRoleArn == null and .externalId == null
      and .disableSessionTags == false and .policy == null
      and (.invocationId | invocation) and (.created | bool))
    and .resources.podIdentityAssociation.invocationId
      == .resources.iamRole.invocationId
  ' "${RECEIPT_PATH}" >/dev/null
}
record_step() {
  local key="$1"
  local state="$2"
  [[ "${receipt_existing}" == false ]] || return 0
  case "${key}" in
    namespace) namespace_state="${state}" ;;
    serviceAccount) service_account_state="${state}" ;;
    regionConfigMap) region_config_map_state="${state}" ;;
    iamRole) role_state="${state}" ;;
    inlinePolicy) policy_state="${state}" ;;
    podIdentityAssociation) association_state="${state}" ;;
    *) die "internal error: unknown lifecycle step ${key}." ;;
  esac
  [[ -n "${journal_path}" ]] || return 0
  jq --arg key "${key}" --arg state "${state}" \
    '.resources[$key] = $state' "${journal_path}" >"${journal_file}"
  atomic_install "${journal_file}" "${journal_path}" ||
    die "could not persist ${key} lifecycle intent."
}
if [[ -n "${RECEIPT_PATH}" ]]; then
  journal_path="${RECEIPT_PATH}.journal"
  check_private_path "${journal_path}" || die "journal path is unsafe."
  if [[ -e "${RECEIPT_PATH}" ]]; then
    if jq -e '
      .version == 2
      and .operation == "setup-agentgateway-pod-identity"
      and (.resources | type == "object")
      and (.resources | has("regionConfigMap") | not)
    ' "${RECEIPT_PATH}" >/dev/null; then
      die "--receipt predates the region ConfigMap lifecycle contract; use its original sample revision to clean up, then create a new receipt."
    fi
    validate_receipt || die "--receipt is invalid or belongs to another target."
    invocation_id="$(jq -er '.resources.iamRole.invocationId' \
      "${RECEIPT_PATH}")" ||
      die "--receipt has no valid invocation identity."
    receipt_existing=true
  elif [[ -e "${journal_path}" ]]; then
    invocation_id="$(jq -er \
      '.invocationId | strings | select(test("^[a-f0-9]{32}$"))' \
      "${journal_path}")" || die "journal has no valid invocation identity."
    jq -e --arg context "${KUBE_CONTEXT}" --arg endpoint "${cluster_endpoint}" \
      --arg region "${AWS_REGION}" --arg account "${AWS_ACCOUNT_ID}" \
      --arg cluster "${EKS_CLUSTER_NAME}" --arg arn "${cluster_arn}" \
      --arg role_name "${ROLE_NAME}" '
      def state: . == "unknown" or . == "pending"
        or . == "created" or . == "reused";
      .version == 2 and .operation == "setup-agentgateway-pod-identity"
      and .target == {
        kubeContext:$context,clusterEndpoint:$endpoint,awsRegion:$region,
        awsAccountId:$account,eksClusterName:$cluster,eksClusterArn:$arn,
        iamRoleName:$role_name
      }
      and (.resources | keys | sort) == [
        "iamRole","inlinePolicy","namespace","podIdentityAssociation",
        "regionConfigMap","serviceAccount"
      ] and ([.resources[] | state] | all)
    ' "${journal_path}" >/dev/null ||
      die "journal is invalid or belongs to another target."
    IFS=$'\t' read -r namespace_state service_account_state \
      region_config_map_state role_state policy_state association_state <<<"$(
        jq -r '[.resources.namespace,.resources.serviceAccount,
          .resources.regionConfigMap,.resources.iamRole,
          .resources.inlinePolicy,.resources.podIdentityAssociation] | @tsv' \
          "${journal_path}"
      )"
  else
    jq -n --arg invocation "${invocation_id}" --arg context "${KUBE_CONTEXT}" \
      --arg endpoint "${cluster_endpoint}" --arg region "${AWS_REGION}" \
      --arg account "${AWS_ACCOUNT_ID}" --arg cluster "${EKS_CLUSTER_NAME}" \
      --arg arn "${cluster_arn}" --arg role_name "${ROLE_NAME}" '{
        version:2,operation:"setup-agentgateway-pod-identity",
        invocationId:$invocation,
        target:{kubeContext:$context,clusterEndpoint:$endpoint,awsRegion:$region,
          awsAccountId:$account,eksClusterName:$cluster,eksClusterArn:$arn,
          iamRoleName:$role_name},
        resources:{namespace:"unknown",serviceAccount:"unknown",
          regionConfigMap:"unknown",iamRole:"unknown",inlinePolicy:"unknown",
          podIdentityAssociation:"unknown"}
      }' >"${journal_file}"
    atomic_install "${journal_file}" "${journal_path}" ||
      die "could not create interruption journal."
  fi
fi

kube_read() {
  local resource="$1"
  local namespace="$2"
  local -a command=("${KUBECTL[@]}" get "${resource}")
  [[ -z "${namespace}" ]] || command+=(--namespace "${namespace}")
  command+=(--ignore-not-found --output=json)
  resource_document="$("${command[@]}")" ||
    die "could not read Kubernetes resource ${resource}."
  [[ -z "${resource_document}" ]] ||
    jq -e 'type == "object"' >/dev/null <<<"${resource_document}" ||
    die "${resource} returned malformed or partial JSON."
}
reconcile_step() {
  local key="$1"
  local state="$2"
  local invocation_matches="$3"
  case "${state}" in
    unknown) record_step "${key}" reused ;;
    pending)
      [[ "${invocation_matches}" == true ]] ||
        die "${key} appeared after create intent but is from another invocation."
      record_step "${key}" created
      ;;
    created)
      [[ "${invocation_matches}" == true ]] ||
        die "${key} no longer has its created invocation marker."
      ;;
    reused) ;;
    *) die "internal error: invalid lifecycle state for ${key}." ;;
  esac
}
ensure_kube() {
  local key="$1" resource="$2" namespace="$3" manifest="$4"
  local state="$5" filter="$6"
  kube_read "${resource}" "${namespace}"
  if [[ -z "${resource_document}" ]]; then
    [[ "${receipt_existing}" == false ]] ||
      die "${resource} recorded in --receipt is absent."
    [[ "${state}" != created && "${state}" != reused ]] ||
      die "${resource} recorded in the journal is absent."
    if [[ "${state}" != pending ]]; then
      record_step "${key}" pending
      state=pending
    fi
    if ! output="$("${KUBECTL[@]}" create --filename "${manifest}" 2>&1)"; then
      kube_read "${resource}" "${namespace}"
      [[ -n "${resource_document}" ]] ||
        die "could not create ${resource}: ${output}"
    fi
    kube_read "${resource}" "${namespace}"
  fi
  jq -e --arg owner "${OWNER}" --arg region "${AWS_REGION}" \
    "${filter}" >/dev/null <<<"${resource_document}" ||
    die "${resource} has a foreign or unexpected contract."
  resource_uid="$(jq -er '.metadata.uid | strings | select(length > 0)' \
    <<<"${resource_document}")" || die "${resource} has no UID."
  invocation_matches="$(jq -r --arg label_key "${INVOCATION_LABEL}" \
    --arg invocation "${invocation_id}" \
    '.metadata.labels[$label_key] == $invocation' <<<"${resource_document}")"
  reconcile_step "${key}" "${state}" "${invocation_matches}"
}

namespace_file="${work_dir}/namespace.json"
service_account_file="${work_dir}/service-account.json"
region_config_map_file="${work_dir}/region-config-map.json"
jq -n --arg owner "${OWNER}" --arg label_key "${INVOCATION_LABEL}" \
  --arg invocation "${invocation_id}" '{
  apiVersion:"v1",kind:"Namespace",metadata:{
    name:"openclaw-enterprise-agw",labels:{
      "app.kubernetes.io/name":"agentgateway",
      "app.kubernetes.io/managed-by":$owner,
      "pod-security.kubernetes.io/enforce":"restricted",
      "pod-security.kubernetes.io/audit":"restricted",
      "pod-security.kubernetes.io/warn":"restricted",($label_key):$invocation}}
}' >"${namespace_file}"
jq -n --arg owner "${OWNER}" --arg label_key "${INVOCATION_LABEL}" \
  --arg invocation "${invocation_id}" '{
  apiVersion:"v1",kind:"ServiceAccount",
  metadata:{namespace:"openclaw-enterprise-agw",name:"agentgateway",
    labels:{
      "app.kubernetes.io/managed-by":$owner,
      ($label_key):$invocation}},
  automountServiceAccountToken:false
}' >"${service_account_file}"
jq -n --arg owner "${OWNER}" --arg label_key "${INVOCATION_LABEL}" \
  --arg invocation "${invocation_id}" --arg region "${AWS_REGION}" '{
  apiVersion:"v1",kind:"ConfigMap",
  metadata:{namespace:"openclaw-enterprise-agw",
    name:"agentgateway-aws-region",
    labels:{
      "app.kubernetes.io/managed-by":$owner,
      ($label_key):$invocation}},
  immutable:true,data:{AWS_REGION:$region}
}' >"${region_config_map_file}"

# jq expressions are deliberately passed as literal function arguments.
# shellcheck disable=SC2016
ensure_kube namespace "namespace/${NAMESPACE}" "" "${namespace_file}" \
  "${namespace_state}" '
    .apiVersion == "v1" and .kind == "Namespace"
    and .metadata.name == "openclaw-enterprise-agw"
    and .metadata.labels["app.kubernetes.io/name"] == "agentgateway"
    and .metadata.labels["app.kubernetes.io/managed-by"] == $owner
    and .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted"
    and .metadata.labels["pod-security.kubernetes.io/audit"] == "restricted"
    and .metadata.labels["pod-security.kubernetes.io/warn"] == "restricted"'
namespace_uid="${resource_uid}"
# shellcheck disable=SC2016
ensure_kube serviceAccount "serviceaccount/${SERVICE_ACCOUNT}" "${NAMESPACE}" \
  "${service_account_file}" "${service_account_state}" '
    .apiVersion == "v1" and .kind == "ServiceAccount"
    and .metadata.namespace == "openclaw-enterprise-agw"
    and .metadata.name == "agentgateway"
    and .automountServiceAccountToken == false'
service_account_uid="${resource_uid}"
# shellcheck disable=SC2016
ensure_kube regionConfigMap "configmap/${REGION_CONFIG_MAP}" "${NAMESPACE}" \
  "${region_config_map_file}" "${region_config_map_state}" '
    .apiVersion == "v1" and .kind == "ConfigMap"
    and .metadata.namespace == "openclaw-enterprise-agw"
    and .metadata.name == "agentgateway-aws-region"
    and .immutable == true and (.data | keys) == ["AWS_REGION"]
    and .data.AWS_REGION == $region'
region_config_map_uid="${resource_uid}"

role_error="${work_dir}/role.err"
read_role() {
  if role_json="$("${AWS[@]}" iam get-role --role-name "${ROLE_NAME}" \
    --output json 2>"${role_error}")"; then
    jq -e . >/dev/null <<<"${role_json}" ||
      die "IAM role lookup returned malformed or partial JSON."
    role_exists=true
  elif grep -q NoSuchEntity "${role_error}"; then
    role_exists=false
    role_json=""
  else
    cat "${role_error}" >&2
    die "could not determine whether IAM role ${ROLE_NAME} exists."
  fi
}
validate_role() {
  jq -e --arg name "${ROLE_NAME}" --arg arn "${role_arn}" \
    --arg owner_key "${OWNER_KEY}" --arg owner "${OWNER}" \
    --arg invocation_key "${INVOCATION_KEY}" --slurpfile trust "${trust_file}" '
    .Role.RoleName == $name and .Role.Arn == $arn
    and (.Role.RoleId | test("^ARO[A-Z0-9]{16,}$"))
    and ([.Role.Tags[] | select(.Key == $owner_key).Value] == [$owner])
    and ([.Role.Tags[] | select(.Key == $invocation_key).Value][0]
      | test("^[a-f0-9]{32}$"))
    and .Role.PermissionsBoundary == null
    and .Role.AssumeRolePolicyDocument == $trust[0]
  ' >/dev/null <<<"${role_json}" ||
    die "IAM role ${ROLE_NAME} has a foreign or unexpected contract."
  role_id="$(jq -er '.Role.RoleId' <<<"${role_json}")"
  role_invocation="$(jq -er --arg key "${INVOCATION_KEY}" \
    '[.Role.Tags[] | select(.Key == $key).Value][0]' <<<"${role_json}")"
  policies="$(aws_json "IAM inline policies" iam list-role-policies \
    --role-name "${ROLE_NAME}")"
  jq -e --arg expected "${POLICY_NAME}" \
    '.PolicyNames | arrays | (length == 0 or sort == [$expected])' \
    >/dev/null <<<"${policies}" ||
    die "IAM role ${ROLE_NAME} has unexpected inline policies."
  attached="$(aws_json "attached IAM policies" iam list-attached-role-policies \
    --role-name "${ROLE_NAME}")"
  jq -e '.AttachedPolicies == []' >/dev/null <<<"${attached}" ||
    die "IAM role ${ROLE_NAME} has attached managed policies."
  profiles="$(aws_json "IAM instance profiles" \
    iam list-instance-profiles-for-role --role-name "${ROLE_NAME}")"
  jq -e '.InstanceProfiles == []' >/dev/null <<<"${profiles}" ||
    die "IAM role ${ROLE_NAME} belongs to an instance profile."
}
read_role
if [[ "${role_exists}" == false ]]; then
  [[ "${receipt_existing}" == false ]] || die "receipt IAM role is absent."
  [[ "${role_state}" != created && "${role_state}" != reused ]] ||
    die "journal IAM role is absent."
  [[ "${role_state}" == pending ]] || record_step iamRole pending
  if created="$("${AWS[@]}" iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${trust_file}" --tags \
    "Key=${OWNER_KEY},Value=${OWNER}" \
    "Key=${INVOCATION_KEY},Value=${invocation_id}" --output json)"; then
    jq -e --arg name "${ROLE_NAME}" --arg arn "${role_arn}" '
      .Role.RoleName == $name and .Role.Arn == $arn
      and (.Role.RoleId | test("^ARO[A-Z0-9]{16,}$"))
    ' >/dev/null <<<"${created}" ||
      die "IAM role create returned partial JSON; rerun to recover."
  fi
  read_role
  [[ "${role_exists}" == true ]] ||
    die "IAM role creation failed without a recoverable role."
fi
validate_role
[[ "${role_invocation}" == "${invocation_id}" ]] ||
  die "IAM role ${ROLE_NAME} is owned by another lifecycle invocation; use its original receipt or clean it up first."
role_matches=false
[[ "${role_invocation}" == "${invocation_id}" ]] && role_matches=true
reconcile_step iamRole "${role_state}" "${role_matches}"

policy_error="${work_dir}/policy.err"
read_policy() {
  if policy_json="$("${AWS[@]}" iam get-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "${POLICY_NAME}" --output json 2>"${policy_error}")"; then
    jq -e '.PolicyDocument | objects' >/dev/null <<<"${policy_json}" ||
      die "IAM policy lookup returned malformed or partial JSON."
    policy_exists=true
  elif grep -q NoSuchEntity "${policy_error}"; then
    policy_exists=false
    policy_json=""
  else
    cat "${policy_error}" >&2
    die "could not determine whether IAM inline policy exists."
  fi
}
read_policy
if [[ "${policy_exists}" == false ]]; then
  [[ "${receipt_existing}" == false ]] || die "receipt IAM policy is absent."
  [[ "${policy_state}" != created && "${policy_state}" != reused ]] ||
    die "journal IAM policy is absent."
  [[ "${policy_state}" == pending ]] || record_step inlinePolicy pending
  "${AWS[@]}" iam put-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "${POLICY_NAME}" --policy-document "file://${policy_file}" ||
    true
  read_policy
  [[ "${policy_exists}" == true ]] ||
    die "IAM policy creation failed without a recoverable policy."
fi
jq -e --slurpfile expected "${policy_file}" \
  '.PolicyDocument == $expected[0]' >/dev/null <<<"${policy_json}" ||
  die "IAM policy differs from the exact regional model policy."
case "${policy_state}" in
  unknown) record_step inlinePolicy reused ;;
  pending) record_step inlinePolicy created ;;
  created|reused) ;;
  *) die "internal error: invalid policy lifecycle state." ;;
esac

read_association() {
  association_list="$(aws_json "Pod Identity associations" \
    eks list-pod-identity-associations --cluster-name "${EKS_CLUSTER_NAME}" \
    --namespace "${NAMESPACE}" --service-account "${SERVICE_ACCOUNT}")"
  association_count="$(jq -er '.associations | arrays | length' \
    <<<"${association_list}")" || die "association list is incomplete."
  (( association_count <= 1 )) ||
    die "multiple Pod Identity associations exist for the service account."
  if (( association_count == 0 )); then
    association_exists=false
    return
  fi
  association_id="$(jq -er \
    '.associations[0].associationId
      | strings | select(test("^a-[a-z0-9]{17}$"))' \
    <<<"${association_list}")" || die "association identity is invalid."
  association_json="$(aws_json "Pod Identity association" \
    eks describe-pod-identity-association --cluster-name "${EKS_CLUSTER_NAME}" \
    --association-id "${association_id}")"
  association_exists=true
}
validate_association() {
  jq -e --arg cluster "${EKS_CLUSTER_NAME}" --arg id "${association_id}" \
    --arg namespace "${NAMESPACE}" --arg account "${SERVICE_ACCOUNT}" \
    --arg role "${role_arn}" --arg arn "${association_prefix}${association_id}" \
    --arg owner "${OWNER}" --arg owner_key "${OWNER_KEY}" \
    --arg invocation_key "${INVOCATION_KEY}" '
    .association.clusterName == $cluster and .association.associationId == $id
    and .association.namespace == $namespace
    and .association.serviceAccount == $account
    and .association.roleArn == $role and .association.associationArn == $arn
    and .association.tags[$owner_key] == $owner
    and (.association.tags[$invocation_key] | test("^[a-f0-9]{32}$"))
    and .association.ownerArn == null and .association.targetRoleArn == null
    and .association.externalId == null
    and .association.disableSessionTags == false and .association.policy == null
  ' >/dev/null <<<"${association_json}" ||
    die "Pod Identity association has a foreign or unexpected contract."
  association_arn="$(jq -er '.association.associationArn' \
    <<<"${association_json}")"
  association_invocation="$(jq -er --arg key "${INVOCATION_KEY}" \
    '.association.tags[$key]' <<<"${association_json}")"
}
read_association
if [[ "${association_exists}" == false ]]; then
  [[ "${receipt_existing}" == false ]] || die "receipt association is absent."
  [[ "${association_state}" != created && "${association_state}" != reused ]] ||
    die "journal association is absent."
  [[ "${association_state}" == pending ]] ||
    record_step podIdentityAssociation pending
  if created="$("${AWS[@]}" eks create-pod-identity-association \
    --cluster-name "${EKS_CLUSTER_NAME}" --namespace "${NAMESPACE}" \
    --service-account "${SERVICE_ACCOUNT}" --role-arn "${role_arn}" \
    --tags "${OWNER_KEY}=${OWNER},${INVOCATION_KEY}=${invocation_id}" \
    --output json)"; then
    jq -e --arg prefix "${association_prefix}" '
      (.association.associationId | test("^a-[a-z0-9]{17}$"))
      and (.association.associationArn | startswith($prefix))
    ' >/dev/null <<<"${created}" ||
      die "association create returned partial JSON; rerun to recover."
  fi
  read_association
  [[ "${association_exists}" == true ]] ||
    die "association creation failed without a recoverable association."
fi
validate_association
[[ "${association_invocation}" == "${invocation_id}" ]] ||
  die "Pod Identity association is owned by another lifecycle invocation; use its original receipt or clean it up first."
association_matches=false
[[ "${association_invocation}" == "${invocation_id}" ]] &&
  association_matches=true
reconcile_step podIdentityAssociation "${association_state}" \
  "${association_matches}"

if [[ "${receipt_existing}" == true ]]; then
  jq -e --arg namespace_uid "${namespace_uid}" \
    --arg account_uid "${service_account_uid}" --arg role_id "${role_id}" \
    --arg region_config_map_uid "${region_config_map_uid}" \
    --arg role_invocation "${role_invocation}" \
    --arg policy_sha256 "${policy_sha256}" \
    --arg association_id "${association_id}" \
    --arg association_arn "${association_arn}" \
    --arg association_invocation "${association_invocation}" '
    .resources.namespace.uid == $namespace_uid
    and .resources.serviceAccount.uid == $account_uid
    and .resources.regionConfigMap.uid == $region_config_map_uid
    and .resources.iamRole.roleId == $role_id
    and .resources.iamRole.invocationId == $role_invocation
    and .resources.inlinePolicy.roleId == $role_id
    and .resources.inlinePolicy.documentSha256 == $policy_sha256
    and .resources.podIdentityAssociation.associationId == $association_id
    and .resources.podIdentityAssociation.associationArn == $association_arn
    and .resources.podIdentityAssociation.invocationId == $association_invocation
  ' "${RECEIPT_PATH}" >/dev/null ||
    die "--receipt differs from the live resource identities."
elif [[ -n "${RECEIPT_PATH}" ]]; then
  namespace_created=false
  service_account_created=false
  region_config_map_created=false
  role_created=false
  policy_created=false
  association_created=false
  for name in namespace service_account region_config_map role policy association; do
    state_name="${name}_state"
    created_name="${name}_created"
    [[ "${!state_name}" == created ]] &&
      printf -v "${created_name}" true ||
      printf -v "${created_name}" false
  done
  receipt_file="${work_dir}/receipt.json"
  jq -n --arg context "${KUBE_CONTEXT}" --arg endpoint "${cluster_endpoint}" \
    --arg region "${AWS_REGION}" --arg account "${AWS_ACCOUNT_ID}" \
    --arg cluster "${EKS_CLUSTER_NAME}" --arg cluster_arn "${cluster_arn}" \
    --arg namespace_uid "${namespace_uid}" \
    --argjson namespace_created "${namespace_created}" \
    --arg account_uid "${service_account_uid}" \
    --argjson account_created "${service_account_created}" \
    --arg region_config_map_uid "${region_config_map_uid}" \
    --argjson region_config_map_created "${region_config_map_created}" \
    --arg role_name "${ROLE_NAME}" --arg role_arn "${role_arn}" \
    --arg role_id "${role_id}" \
    --arg role_invocation "${role_invocation}" \
    --argjson role_created "${role_created}" \
    --arg policy_sha256 "${policy_sha256}" \
    --argjson policy_created "${policy_created}" \
    --arg association_id "${association_id}" \
    --arg association_arn "${association_arn}" \
    --arg association_invocation "${association_invocation}" \
    --argjson association_created "${association_created}" '{
    version:2,operation:"setup-agentgateway-pod-identity",
    target:{kubeContext:$context,clusterEndpoint:$endpoint,awsRegion:$region,
      awsAccountId:$account,eksClusterName:$cluster,eksClusterArn:$cluster_arn},
    resources:{
      namespace:{apiVersion:"v1",kind:"Namespace",
        name:"openclaw-enterprise-agw",uid:$namespace_uid,
        created:$namespace_created},
      serviceAccount:{apiVersion:"v1",kind:"ServiceAccount",
        namespace:"openclaw-enterprise-agw",name:"agentgateway",
        uid:$account_uid,created:$account_created},
      regionConfigMap:{apiVersion:"v1",kind:"ConfigMap",
        namespace:"openclaw-enterprise-agw",name:"agentgateway-aws-region",
        uid:$region_config_map_uid,created:$region_config_map_created},
      iamRole:{name:$role_name,arn:$role_arn,
        roleId:$role_id,invocationId:$role_invocation,created:$role_created},
      inlinePolicy:{name:"openclaw-enterprise-bedrock-invoke",
        roleName:$role_name,roleId:$role_id,
        documentSha256:$policy_sha256,created:$policy_created},
      podIdentityAssociation:{clusterName:$cluster,associationId:$association_id,
        associationArn:$association_arn,namespace:"openclaw-enterprise-agw",
        serviceAccount:"agentgateway",roleArn:$role_arn,targetRoleArn:null,
        externalId:null,disableSessionTags:false,policy:null,
        invocationId:$association_invocation,created:$association_created}
    }
  }' >"${receipt_file}"
  atomic_install "${receipt_file}" "${RECEIPT_PATH}" ||
    die "could not persist --receipt."
fi
if [[ -n "${journal_path}" && -e "${journal_path}" ]]; then
  rm -f -- "${journal_path}" ||
    die "could not remove completed interruption journal."
fi
echo "AgentGateway Pod Identity is ready for ${NAMESPACE}/${SERVICE_ACCOUNT}."
[[ -z "${RECEIPT_PATH}" ]] || echo "Lifecycle receipt: ${RECEIPT_PATH}"
