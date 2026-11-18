#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077
readonly OWNER_KEY="app.kubernetes.io/managed-by"
readonly OWNER="openclaw-enterprise-blueprint"
readonly OCE_OWNER="openclaw-enterprise"
readonly OCE_SOURCE_PIN="86c8c12310f691bb21651118ffffd6bfd460e9ff"
readonly AGW_NAMESPACE="openclaw-enterprise-agw"
readonly AGW_SERVICE_ACCOUNT="agentgateway"
readonly STORAGE_CLASS="openclaw-enterprise-gp3"
readonly VPC_CNI_KEY="enable-network-policy-controller"
usage() {
  cat >&2 <<'EOF'
Usage:
  cleanup.sh --kubeconfig FILE --kube-context CONTEXT \
    --state-dir DIR --receipt DIR \
    [--namespace NAMESPACE] [--release RELEASE] \
    [--tenant-namespace NAMESPACE ...] \
    [--aws-region REGION --aws-account-id ACCOUNT_ID \
     --eks-cluster-name CLUSTER_NAME \
     --pod-identity-association-id ASSOCIATION_ID \
     --iam-role-name ROLE_NAME --iam-inline-policy-name POLICY_NAME]
Paths and context must be explicit. Evidence must prove a successful exact
install on the selected cluster. AWS arguments are all-or-nothing. Tenant
namespaces and external databases are preserved.
EOF
}
die() {
  printf 'cleanup: %s\n' "$*" >&2
  exit 1
}
require_value() {
  [[ -n "${2:-}" && "$2" != --* ]] || die "$1 requires an explicit value."
}
valid_dns_label() {
  local LC_ALL=C value=$1
  [[ ${#value} -le 63 &&
    "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}
file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null ||
    die "could not inspect permissions for $1."
}
private_file() {
  local label=$1 path=$2 mode
  [[ -f "$path" && ! -L "$path" && -O "$path" && -r "$path" ]] ||
    die "$label must be an owned readable regular file, not a symbolic link."
  mode=$(file_mode "$path")
  [[ "$mode" == 400 || "$mode" == 600 || "$mode" == 700 ]] ||
    die "$label must have mode 0400, 0600, or 0700."
}
private_directory() {
  [[ -d "$2" && ! -L "$2" && -O "$2" ]] ||
    die "$1 must be an owned directory, not a symbolic link."
  [[ "$(file_mode "$2")" == 700 ]] || die "$1 must have mode 0700."
}
kubeconfig="" kube_context="" state_dir="" receipt=""
system_namespace="openclaw-system" release="oce"
declare -a tenant_namespaces=()
aws_region="" aws_account_id="" eks_cluster_name=""
association_id="" role_name="" policy_name=""
while (($#)); do
  option=$1
  case "$option" in
    --tenant-namespace)
      require_value "$option" "${2:-}"
      tenant_namespaces+=("$2")
      shift 2
      ;;
    --kubeconfig|--kube-context|--state-dir|--receipt|--namespace|--release|\
    --aws-region|--aws-account-id|--eks-cluster-name|\
    --pod-identity-association-id|--iam-role-name|--iam-inline-policy-name)
      require_value "$option" "${2:-}"
      value=$2
      case "$option" in
        --kubeconfig) kubeconfig=$value ;;
        --kube-context) kube_context=$value ;;
        --state-dir) state_dir=$value ;;
        --receipt) receipt=$value ;;
        --namespace) system_namespace=$value ;;
        --release) release=$value ;;
        --aws-region) aws_region=$value ;;
        --aws-account-id) aws_account_id=$value ;;
        --eks-cluster-name) eks_cluster_name=$value ;;
        --pod-identity-association-id) association_id=$value ;;
        --iam-role-name) role_name=$value ;;
        --iam-inline-policy-name) policy_name=$value ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $option" ;;
  esac
done
[[ -n "$kubeconfig" ]] || die "--kubeconfig is required."
[[ -n "$kube_context" && "$kube_context" != *$'\n'* ]] ||
  die "--kube-context is required and must fit on one line."
[[ -n "$state_dir" && -n "$receipt" ]] ||
  die "--state-dir and --receipt are required."
[[ "$kubeconfig" = /* && "$state_dir" = /* && "$receipt" = /* ]] ||
  die "--kubeconfig, --state-dir, and --receipt must be absolute paths."
valid_dns_label "$system_namespace" ||
  die "--namespace must be a Kubernetes DNS label."
valid_dns_label "$release" || die "--release must be a Kubernetes DNS label."
for ((i = 0; i < ${#tenant_namespaces[@]}; i++)); do
  namespace=${tenant_namespaces[$i]}
  valid_dns_label "$namespace" || die "invalid tenant namespace: $namespace"
  [[ "$namespace" != "$system_namespace" &&
    "$namespace" != openclaw-enterprise-adapter &&
    "$namespace" != "$AGW_NAMESPACE" ]] ||
    die "$namespace is not a tenant namespace."
  for ((j = 0; j < i; j++)); do
    [[ "$namespace" != "${tenant_namespaces[$j]}" ]] ||
      die "tenant namespace supplied more than once: $namespace"
  done
done
declare -a aws_values=(
  "$aws_region" "$aws_account_id" "$eks_cluster_name"
  "$association_id" "$role_name" "$policy_name"
)
aws_count=0
for value in "${aws_values[@]}"; do
  [[ -z "$value" ]] || ((aws_count += 1))
done
((aws_count == 0 || aws_count == ${#aws_values[@]})) ||
  die "AgentGateway Pod Identity and IAM cleanup requires every AWS identifier."
readonly CLEAN_AWS=$((aws_count > 0))
if ((CLEAN_AWS)); then
  [[ "$aws_account_id" =~ ^[0-9]{12}$ ]] ||
    die "--aws-account-id must be a 12-digit AWS account ID."
  [[ "$aws_region" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
    die "--aws-region is not valid."
  [[ "$eks_cluster_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] ||
    die "--eks-cluster-name is not valid."
  [[ "$association_id" =~ ^a-[a-z0-9]{17}$ ]] ||
    die "--pod-identity-association-id is not valid."
  [[ "$role_name" =~ ^[A-Za-z0-9_+=,.@-]{1,64}$ ]] ||
    die "--iam-role-name is not valid."
  [[ "$policy_name" =~ ^[A-Za-z0-9_+=,.@-]{1,128}$ ]] ||
    die "--iam-inline-policy-name is not valid."
fi
for command in kubectl helm python3 stat mktemp grep; do
  command -v "$command" >/dev/null || die "$command is required."
done
((CLEAN_AWS == 0)) || command -v aws >/dev/null || die "aws is required."
private_file "--kubeconfig" "$kubeconfig"
private_directory "--state-dir" "$state_dir"
private_directory "--receipt" "$receipt"
private_file "install completion marker" "$state_dir/install.complete"
for name in intent.json dispatch.json helm-result.json; do
  private_file "receipt/$name" "$receipt/$name"
done
canonical_state=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$state_dir")
canonical_receipt=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$receipt")
[[ "$canonical_state" == "$state_dir" ]] || die "--state-dir must be canonical."
[[ "$canonical_receipt" == "$receipt" && "$receipt" == "$state_dir/"* ]] ||
  die "--receipt must be canonical and below --state-dir."
readonly -a KC=(kubectl --kubeconfig "$kubeconfig")
readonly -a K=(
  kubectl --kubeconfig "$kubeconfig" --context "$kube_context"
  --request-timeout=20s
)
readonly -a H=(helm --kubeconfig "$kubeconfig" --kube-context "$kube_context")
context=$("${KC[@]}" config get-contexts "$kube_context" --no-headers --output=name) ||
  die "could not read kube context $kube_context."
[[ "$context" == "$kube_context" ]] ||
  die "kube context $kube_context does not exist exactly."
"${K[@]}" get --raw=/readyz >/dev/null ||
  die "could not reach kube context $kube_context."
cluster_config=$(mktemp)
aws_error=""
trap 'rm -f -- "${cluster_config:-}" "${aws_error:-}"' EXIT
chmod 600 "$cluster_config"
"${KC[@]}" config view --raw --minify --context "$kube_context" --output=json \
  >"$cluster_config" || die "could not read the selected kube context."
evidence=$(
  python3 - "$state_dir/install.complete" "$receipt" "$cluster_config" \
    "$OCE_SOURCE_PIN" "$kube_context" "$system_namespace" "$release" <<'PY'
from pathlib import Path
import hashlib, json, re, sys
marker_path, receipt_path, config_path, source, context, namespace, release = sys.argv[1:]
def fail(message):
    sys.stderr.write(f"cleanup: {message}\n")
    raise SystemExit(1)
marker = {}
for line in Path(marker_path).read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if not separator or key in marker or "\t" in value:
        fail("install completion marker is malformed.")
    marker[key] = value
if set(marker) != {"source", "cluster_arn", "context", "namespace", "release"}:
    fail("install completion marker has an unexpected schema.")
if marker["source"] != source:
    fail("completion marker has the wrong OCE source pin.")
for key, expected in {"context": context, "namespace": namespace, "release": release}.items():
    if marker[key] != expected:
        fail(f"completion marker {key} does not match.")
if not re.fullmatch(
    r"arn:[^:]+:eks:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9_-]+",
    marker["cluster_arn"],
):
    fail("completion marker contains an invalid EKS cluster ARN.")
def load(name):
    try:
        return json.loads(Path(receipt_path, name).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid receipt file {name}: {error}.")

intent = load("intent.json")
required = {
    "version", "operation", "attempt", "createdAt", "clusterSha256",
    "namespace", "release", "chartSha256", "valuesSha256",
}
if not isinstance(intent, dict) or set(intent) != required:
    fail("receipt intent.json has an unexpected schema.")
if intent["version"] != 1 or intent["operation"] != "helm-install":
    fail("receipt is not a version 1 Helm install receipt.")
if load("dispatch.json") != {"outcome": "unknown"}:
    fail("receipt dispatch state is invalid.")
if load("helm-result.json") != {"outcome": "succeeded"}:
    fail("OCC receipt does not prove a successful install.")
if intent["namespace"] != namespace or intent["release"] != release:
    fail("receipt namespace or release does not match.")
if not isinstance(intent["attempt"], str) or not intent["attempt"] or "\t" in intent["attempt"]:
    fail("receipt attempt identifier is invalid.")
for key in ("clusterSha256", "chartSha256", "valuesSha256"):
    if not isinstance(intent[key], str) or not re.fullmatch(r"[a-f0-9]{64}", intent[key]):
        fail(f"receipt {key} is invalid.")
config = json.loads(Path(config_path).read_text(encoding="utf-8"))
try:
    cluster = config["clusters"][0]["cluster"]
except (KeyError, IndexError, TypeError):
    fail("selected kube context has no cluster configuration.")
actual = hashlib.sha256(
    json.dumps(cluster, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if actual != intent["clusterSha256"]:
    fail("selected kube context does not match the OCC receipt.")
print(f"{marker['cluster_arn']}\t{intent['attempt']}")
PY
) || die "install evidence validation failed."
IFS=$'\t' read -r marker_cluster_arn receipt_attempt evidence_extra <<<"$evidence"
[[ -z "${evidence_extra:-}" && -n "$marker_cluster_arn" &&
  -n "$receipt_attempt" ]] || die "install evidence output was malformed."

if env | grep -Eq '^HELM_KUBE[^=]*=.'; then
  die "nonempty HELM_KUBE* environment overrides are not allowed."
fi
case "${HELM_DRIVER:-secret}" in
  secret|secrets) ;;
  *) die "HELM_DRIVER must be unset, secret, or secrets." ;;
esac

release_present=false
release_names=$("${H[@]}" list --namespace "$system_namespace" --all --short) ||
  die "could not list Helm releases in $system_namespace."
while IFS= read -r name; do
  [[ "$name" != "$release" ]] || release_present=true
done <<<"$release_names"

live_attempt() {
  "${H[@]}" get values "$release" --namespace "$system_namespace" \
    --all --output=json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["installation"]["attemptId"])'
}

if [[ "$release_present" == true ]]; then
  [[ "$(live_attempt)" == "$receipt_attempt" ]] ||
    die "Helm release $release does not match the OCC receipt attempt."
fi

api_path() {
  local resource=$1 namespace=$2 kind name
  kind=${resource%%/*}
  name=${resource##*/}
  case "$kind" in
    namespace) printf '/api/v1/namespaces/%s' "$name" ;;
    secret) printf '/api/v1/namespaces/%s/secrets/%s' "$namespace" "$name" ;;
    service) printf '/api/v1/namespaces/%s/services/%s' "$namespace" "$name" ;;
    configmap) printf '/api/v1/namespaces/%s/configmaps/%s' "$namespace" "$name" ;;
    persistentvolumeclaim)
      printf '/api/v1/namespaces/%s/persistentvolumeclaims/%s' "$namespace" "$name"
      ;;
    deployment.apps)
      printf '/apis/apps/v1/namespaces/%s/deployments/%s' "$namespace" "$name"
      ;;
    job.batch)
      printf '/apis/batch/v1/namespaces/%s/jobs/%s' "$namespace" "$name"
      ;;
    networkpolicy.networking.k8s.io)
      printf '/apis/networking.k8s.io/v1/namespaces/%s/networkpolicies/%s' \
        "$namespace" "$name"
      ;;
    validatingadmissionpolicies.admissionregistration.k8s.io)
      printf '/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicies/%s' "$name"
      ;;
    validatingadmissionpolicybindings.admissionregistration.k8s.io)
      printf '/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicybindings/%s' "$name"
      ;;
    mutatingwebhookconfigurations.admissionregistration.k8s.io)
      printf '/apis/admissionregistration.k8s.io/v1/mutatingwebhookconfigurations/%s' "$name"
      ;;
    validatingwebhookconfigurations.admissionregistration.k8s.io)
      printf '/apis/admissionregistration.k8s.io/v1/validatingwebhookconfigurations/%s' "$name"
      ;;
    storageclass.storage.k8s.io)
      printf '/apis/storage.k8s.io/v1/storageclasses/%s' "$name"
      ;;
    *) die "no guarded API path is defined for $resource." ;;
  esac
}

resource_record() {
  local resource=$1 namespace=$2
  local -a command=("${K[@]}" get "$resource")
  [[ -z "$namespace" ]] || command+=(--namespace "$namespace")
  command+=(
    --ignore-not-found
    --output=jsonpath='{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"|"}{.metadata.labels.app\.kubernetes\.io/instance}{"|"}{.metadata.uid}{"|"}{.metadata.resourceVersion}{"\n"}'
  )
  "${command[@]}" || die "could not inspect $resource${namespace:+ in $namespace}."
}

parse_record() {
  local extra
  IFS='|' read -r R_NAME R_OWNER R_INSTANCE R_UID R_VERSION extra <<<"$1"
  [[ -z "${extra:-}" && -n "$R_NAME" && -n "$R_UID" && -n "$R_VERSION" ]] ||
    die "Kubernetes returned an incomplete resource identity."
}

declare -a delete_targets=() verify_targets=() tenant_guards=()
declare -a release_guards=() orphan_release_resources=()

record_owned() {
  local resource=$1 namespace=$2 expected_owner=$3 record
  record=$(resource_record "$resource" "$namespace")
  [[ -n "$record" ]] || return 0
  parse_record "$record"
  [[ "$R_NAME" == "${resource##*/}" && "$R_OWNER" == "$expected_owner" ]] ||
    die "$resource${namespace:+ in $namespace} does not carry the exact $OWNER_KEY=$expected_owner ownership label."
  delete_targets+=(
    "$(api_path "$resource" "$namespace")|$R_UID|$R_VERSION|$resource|$namespace"
  )
  verify_targets+=("$resource|$namespace|$R_UID")
}

readonly -a system_resources=(
  secret/oce-validation-only-postgres deployment.apps/oce-validation-only-postgres
  service/oce-validation-only-postgres networkpolicy.networking.k8s.io/oce-validation-only-postgres
  secret/oce-sample-installation-startup secret/oce-sample-database
  secret/oce-sample-database-ca secret/oce-sample-auth
  job.batch/oce-sample-bootstrap-volume-prep persistentvolumeclaim/oce-sample-bootstrap-output
)
readonly -a cluster_resources=(
  validatingadmissionpolicies.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label
  validatingadmissionpolicybindings.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label
  mutatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-adapter
  validatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-policy
)
readonly -a tenant_resources=(
  configmap/agentgateway-ca networkpolicy.networking.k8s.io/default-deny-egress
  networkpolicy.networking.k8s.io/allow-dns networkpolicy.networking.k8s.io/allow-agentgateway
)
readonly -a release_resources=(
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-namespace-observer"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-namespace-worker"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-worker" "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-api"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-configuration" "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-gateway-observer"
  "clusterrolebinding.rbac.authorization.k8s.io/${release}-openclaw-worker-namespaces"
  "clusterrolebinding.rbac.authorization.k8s.io/${release}-openclaw-api-namespaces"
)

system_record=$(resource_record "namespace/$system_namespace" "")
if [[ -n "$system_record" ]]; then
  parse_record "$system_record"
  [[ "$R_OWNER" == "$OWNER" ]] ||
    die "namespace/$system_namespace does not carry the exact $OWNER_KEY=$OWNER ownership label."
  for resource in "${system_resources[@]}"; do
    record_owned "$resource" "$system_namespace" "$OWNER"
  done
  legacy_record=$(resource_record deployment.apps/oce-api-cli-client "$system_namespace")
  if [[ -n "$legacy_record" ]]; then
    parse_record "$legacy_record"
    [[ "$R_OWNER" == "$OWNER" && "$R_INSTANCE" == "$release" ]] ||
      die "legacy API client is not owned by this sample release."
    record_owned deployment.apps/oce-api-cli-client "$system_namespace" "$OWNER"
  fi
fi

for namespace in "${tenant_namespaces[@]}"; do
  record=$(resource_record "namespace/$namespace" "")
  if [[ -z "$record" ]]; then
    printf 'Tenant namespace %s is absent; nothing inside it will be touched.\n' "$namespace"
    continue
  fi
  parse_record "$record"
  [[ "$R_OWNER" == "$OCE_OWNER" ]] ||
    die "tenant namespace/$namespace is not owned by $OCE_OWNER."
  tenant_guards+=("$namespace|$R_UID")
  for resource in "${tenant_resources[@]}"; do
    record_owned "$resource" "$namespace" "$OWNER"
  done
done

for resource in "${cluster_resources[@]}"; do
  record_owned "$resource" "" "$OWNER"
done
for namespace in openclaw-enterprise-adapter "$AGW_NAMESPACE"; do
  record_owned "namespace/$namespace" "" "$OWNER"
done
if [[ -n "$system_record" ]]; then
  parse_record "$system_record"
  delete_targets+=(
    "$(api_path "namespace/$system_namespace" "")|$R_UID|$R_VERSION|namespace/$system_namespace|"
  )
  verify_targets+=("namespace/$system_namespace||$R_UID")
fi

for resource in "${release_resources[@]}"; do
  record=$(resource_record "$resource" "")
  [[ -n "$record" ]] || continue
  parse_record "$record"
  if [[ "$release_present" == true ]]; then
    release_guards+=("$resource|$R_UID")
  else
    orphan_release_resources+=("$resource")
  fi
done

vpc_json=$("${K[@]}" get configmap amazon-vpc-cni --namespace kube-system \
  --ignore-not-found --output=json) || die "could not inspect the VPC CNI ConfigMap."
vpc_plan=$(
  python3 -c '
import json, sys
raw, owner, key = sys.stdin.read(), sys.argv[1], sys.argv[2]
if not raw.strip():
    print("absent"); raise SystemExit
resource = json.loads(raw)
metadata, data = resource.get("metadata", {}), resource.get("data") or {}
if key not in data:
    print("field-absent"); raise SystemExit
managers = {
    entry.get("manager") for entry in metadata.get("managedFields") or []
    if f"f:{key}" in ((entry.get("fieldsV1") or {}).get("f:data") or {})
}
if managers != {owner}:
    print("preserve-unowned"); raise SystemExit
if data[key] != "true":
    print("preserve-changed"); raise SystemExit
print("remove\t{}\t{}".format(metadata["uid"], metadata["resourceVersion"]))
' "$OWNER" "$VPC_CNI_KEY" <<<"$vpc_json"
) || die "VPC CNI ConfigMap returned malformed ownership data."

storage_record=$(resource_record "storageclass.storage.k8s.io/$STORAGE_CLASS" "")
storage_plan="absent"
if [[ -n "$storage_record" ]]; then
  parse_record "$storage_record"
  if [[ "$R_OWNER" != "$OWNER" ]]; then
    storage_plan="preserve-unowned"
  else
    storage_plan="delete"
    storage_target="$(api_path "storageclass.storage.k8s.io/$STORAGE_CLASS" "")|$R_UID|$R_VERSION|storageclass.storage.k8s.io/$STORAGE_CLASS|"
    storage_verify="storageclass.storage.k8s.io/$STORAGE_CLASS||$R_UID"
  fi
fi

readonly -a A=(aws --no-cli-pager --region "${aws_region:-us-east-1}")
aws_text() {
  local output
  output=$("${A[@]}" "$@" --output text) || die "AWS verification failed: $*"
  printf '%s' "$output"
}

role_arn=""
verify_role() {
  local role_record role_owner policies managed_count profiles
  local returned_name returned_arn extra
  role_record=$(aws_text iam get-role --role-name "$role_name" \
    --query 'Role.[RoleName,Arn]')
  IFS=$'\t' read -r returned_name returned_arn extra <<<"$role_record"
  [[ -z "${extra:-}" && "$returned_name" == "$role_name" &&
    "$returned_arn" == "arn:"*":iam::$aws_account_id:role/$role_name" ]] ||
    die "IAM role does not match the explicit account and role name."
  role_arn=$returned_arn
  role_owner=$(aws_text iam get-role --role-name "$role_name" \
    --query "Role.Tags[?Key=='ManagedBy'].Value | [0]")
  [[ "$role_owner" == "$OWNER" ]] ||
    die "IAM role $role_name is not tagged ManagedBy=$OWNER."
  policies=$(aws_text iam list-role-policies --role-name "$role_name" \
    --query 'PolicyNames[]')
  [[ "$policies" == "$policy_name" ]] ||
    die "IAM role $role_name has an unexpected inline policy set."
  managed_count=$(aws_text iam list-attached-role-policies --role-name "$role_name" \
    --query 'length(AttachedPolicies)')
  profiles=$(aws_text iam list-instance-profiles-for-role --role-name "$role_name" \
    --query 'length(InstanceProfiles)')
  [[ "$managed_count" == 0 && "$profiles" == 0 ]] ||
    die "IAM role $role_name has extra attachments; refusing deletion."
}

verify_association() {
  local association expected partition association_arn
  partition=${role_arn#arn:}
  partition=${partition%%:*}
  association_arn="arn:$partition:eks:$aws_region:$aws_account_id:podidentityassociation/$eks_cluster_name/$association_id"
  association=$(aws_text eks describe-pod-identity-association \
    --cluster-name "$eks_cluster_name" --association-id "$association_id" \
    --query 'association.[clusterName,associationId,associationArn,namespace,serviceAccount,roleArn,tags.ManagedBy,ownerArn]')
  expected="$eks_cluster_name"$'\t'"$association_id"$'\t'"$association_arn"$'\t'"$AGW_NAMESPACE"$'\t'"$AGW_SERVICE_ACCOUNT"$'\t'"$role_arn"$'\t'"$OWNER"$'\tNone'
  [[ "$association" == "$expected" ]] ||
    die "Pod Identity association does not match the explicit cluster, service account, role, and ownership."
}

if ((CLEAN_AWS)); then
  [[ "$(aws_text sts get-caller-identity --query Account)" == "$aws_account_id" ]] ||
    die "AWS CLI is authenticated to the wrong account."
  live_cluster_arn=$(aws_text eks describe-cluster \
    --name "$eks_cluster_name" --query cluster.arn)
  [[ "$live_cluster_arn" == "$marker_cluster_arn" ]] ||
    die "EKS cluster does not match the completion marker."
  verify_role
  verify_association
fi

delete_guarded() {
  local path uid version display namespace extra options
  IFS='|' read -r path uid version display namespace extra <<<"$1"
  [[ -z "${extra:-}" ]] || die "invalid deletion target."
  options=$(python3 -c '
import json, sys
print(json.dumps({
  "apiVersion": "v1", "kind": "DeleteOptions",
  "propagationPolicy": "Foreground",
  "preconditions": {"uid": sys.argv[1], "resourceVersion": sys.argv[2]},
}, separators=(",", ":")))
' "$uid" "$version")
  printf '%s' "$options" | "${K[@]}" delete --raw="$path" -f - >/dev/null ||
    die "guarded deletion failed for $display${namespace:+ in $namespace}; it changed after preflight."
}

verify_absent() {
  local resource namespace uid extra record
  IFS='|' read -r resource namespace uid extra <<<"$1"
  [[ -z "${extra:-}" ]] || die "invalid verification target."
  for _ in {1..30}; do
    record=$(resource_record "$resource" "$namespace")
    [[ -n "$record" ]] || return 0
    parse_record "$record"
    [[ "$R_UID" == "$uid" ]] ||
      die "$resource was replaced during cleanup; the replacement was preserved."
    sleep 2
  done
  die "$resource${namespace:+ in $namespace} still exists after deletion."
}

if [[ "$release_present" == true ]]; then
  [[ "$(live_attempt)" == "$receipt_attempt" ]] ||
    die "Helm release changed after preflight."
  "${H[@]}" uninstall "$release" --namespace "$system_namespace" \
    --wait --timeout=5m >/dev/null || die "Helm uninstall failed."
  release_names=$("${H[@]}" list --namespace "$system_namespace" --all --short) ||
    die "could not verify Helm release deletion."
  while IFS= read -r name; do
    [[ "$name" != "$release" ]] ||
      die "Helm release $release still exists after uninstall."
  done <<<"$release_names"
fi

for target in "${delete_targets[@]}"; do delete_guarded "$target"; done
for target in "${verify_targets[@]}"; do verify_absent "$target"; done

for guard in "${tenant_guards[@]}"; do
  IFS='|' read -r namespace uid <<<"$guard"
  record=$(resource_record "namespace/$namespace" "")
  [[ -n "$record" ]] || die "tenant namespace/$namespace disappeared."
  parse_record "$record"
  [[ "$R_UID" == "$uid" && "$R_OWNER" == "$OCE_OWNER" ]] ||
    die "tenant namespace/$namespace changed identity or ownership."
done

for guard in "${release_guards[@]}"; do
  IFS='|' read -r resource uid <<<"$guard"
  record=$(resource_record "$resource" "")
  [[ -z "$record" ]] && continue
  parse_record "$record"
  [[ "$R_UID" == "$uid" ]] ||
    die "$resource was replaced during Helm cleanup; replacement preserved."
  die "$resource still exists after Helm uninstall."
done

incomplete=0
for resource in "${orphan_release_resources[@]}"; do
  printf 'Preserved %s: the receipt-matched Helm release was already absent, so ownership could not be proved.\n' \
    "$resource" >&2
  incomplete=1
done

IFS=$'\t' read -r vpc_action vpc_uid vpc_version <<<"$vpc_plan"
case "$vpc_action" in
  absent|field-absent|preserve-unowned) ;;
  preserve-changed)
    printf 'Preserved sample-owned VPC CNI field because its value changed.\n' >&2
    incomplete=1
    ;;
  remove)
    patch=$(python3 -c '
import json, sys
uid, version, key = sys.argv[1:]
path = "/data/" + key.replace("~", "~0").replace("/", "~1")
print(json.dumps([
  {"op": "test", "path": "/metadata/uid", "value": uid},
  {"op": "test", "path": "/metadata/resourceVersion", "value": version},
  {"op": "test", "path": path, "value": "true"},
  {"op": "remove", "path": path},
], separators=(",", ":")))
' "$vpc_uid" "$vpc_version" "$VPC_CNI_KEY")
    "${K[@]}" patch configmap amazon-vpc-cni --namespace kube-system \
      --type=json --patch="$patch" >/dev/null ||
      die "VPC CNI ConfigMap changed after preflight; it was preserved."
    vpc_json=$("${K[@]}" get configmap amazon-vpc-cni --namespace kube-system \
      --output=json) || die "could not verify the VPC CNI ConfigMap."
    python3 -c '
import json, sys
resource = json.load(sys.stdin)
if resource["metadata"]["uid"] != sys.argv[1]:
    raise SystemExit("VPC CNI ConfigMap was replaced during cleanup.")
if sys.argv[2] in (resource.get("data") or {}):
    raise SystemExit("sample-owned VPC CNI field still exists after cleanup.")
' "$vpc_uid" "$VPC_CNI_KEY" <<<"$vpc_json" ||
      die "VPC CNI cleanup verification failed."
    ;;
  *) die "invalid VPC CNI cleanup plan." ;;
esac

if [[ "$storage_plan" == delete ]]; then
  pvc_json=$("${K[@]}" get persistentvolumeclaims --all-namespaces --output=json) ||
    die "could not inspect remaining PVC references to $STORAGE_CLASS."
  pvc_references=$(
    python3 -c '
import json, sys
name = sys.argv[1]
for item in json.load(sys.stdin).get("items") or []:
    if (item.get("spec") or {}).get("storageClassName") == name:
        metadata = item.get("metadata") or {}
        print("{}/{}".format(
            metadata.get("namespace", "?"), metadata.get("name", "?")
        ))
' "$STORAGE_CLASS" <<<"$pvc_json"
  ) || die "PVC inventory returned malformed JSON."
  [[ -z "$pvc_references" ]] || storage_plan="preserve-referenced"
fi

case "$storage_plan" in
  absent|preserve-unowned) ;;
  preserve-referenced)
    printf 'Preserved sample-owned StorageClass %s; remaining PVC references:\n%s\n' \
      "$STORAGE_CLASS" "$pvc_references" >&2
    incomplete=1
    ;;
  delete)
    delete_guarded "$storage_target"
    verify_absent "$storage_verify"
    ;;
  *) die "invalid StorageClass cleanup plan." ;;
esac

if ((CLEAN_AWS)); then
  verify_role
  verify_association
  "${A[@]}" eks delete-pod-identity-association \
    --cluster-name "$eks_cluster_name" --association-id "$association_id" >/dev/null
  aws_error=$(mktemp)
  chmod 600 "$aws_error"
  association_deleted=false
  for _ in {1..30}; do
    if "${A[@]}" eks describe-pod-identity-association \
      --cluster-name "$eks_cluster_name" --association-id "$association_id" \
      >/dev/null 2>"$aws_error"; then
      sleep 2
    elif grep -q ResourceNotFoundException "$aws_error"; then
      association_deleted=true
      break
    else
      cat "$aws_error" >&2
      die "could not verify Pod Identity association deletion."
    fi
  done
  [[ "$association_deleted" == true ]] ||
    die "Pod Identity association deletion timed out."
  verify_role
  "${A[@]}" iam delete-role-policy --role-name "$role_name" \
    --policy-name "$policy_name"
  "${A[@]}" iam delete-role --role-name "$role_name"
fi

((incomplete == 0)) ||
  die "cleanup is incomplete; review the preserved sample-owned resources."
printf 'Cleanup completed for release %s in kube context %s.\n' \
  "$release" "$kube_context"
