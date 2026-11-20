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
namespaces are deleted only after every descendant passes an ownership check.
External databases are preserved.
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
for name in intent.json dispatch.json helm-result.json resources.json; do
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
namespace_inventory_dir=$(mktemp -d)
aws_error=""
cleanup_temporary_files() {
  rm -f -- "${cluster_config:-}" "${aws_error:-}"
  [[ -z "${namespace_inventory_dir:-}" ]] ||
    rm -rf -- "$namespace_inventory_dir"
}
trap cleanup_temporary_files EXIT
chmod 600 "$cluster_config"
chmod 700 "$namespace_inventory_dir"
"${KC[@]}" config view --raw --minify --context "$kube_context" --output=json \
  >"$cluster_config" || die "could not read the selected kube context."
evidence=$(
  python3 -c '
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
print("{}\t{}".format(marker["cluster_arn"], intent["attempt"]))
' "$state_dir/install.complete" "$receipt" "$cluster_config" \
    "$OCE_SOURCE_PIN" "$kube_context" "$system_namespace" "$release"
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
    rolebinding.rbac.authorization.k8s.io)
      printf '/apis/rbac.authorization.k8s.io/v1/namespaces/%s/rolebindings/%s' \
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

declare -a delete_targets=() verify_targets=()
declare -a release_guards=() orphan_release_resources=()
declare -a namespace_inventory_types=()
namespace_inventory_types_loaded=false

load_namespace_inventory_types() {
  local discovered resource_type
  [[ "$namespace_inventory_types_loaded" == false ]] || return 0
  discovered=$(
    "${K[@]}" api-resources --namespaced=true --verbs=list --output=name
  ) || die "could not discover namespaced resource types; refusing namespace deletion."
  while IFS= read -r resource_type; do
    [[ -n "$resource_type" ]] || continue
    [[ "$resource_type" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
      die "Kubernetes discovery returned an invalid resource type."
    case "$resource_type" in
      events|events.events.k8s.io)
        # Events are high-churn, server-generated diagnostic history. They do
        # not hold durable desired state and do not inherit workload ownership.
        continue
        ;;
    esac
    namespace_inventory_types+=("$resource_type")
  done < <(printf '%s\n' "$discovered")
  ((${#namespace_inventory_types[@]} > 0)) ||
    die "Kubernetes discovery returned no inspectable namespaced resource types."
  namespace_inventory_types_loaded=true
}

verify_namespace_descendants() {
  local namespace=$1 allowed_owners=${2:-$OWNER} resource_type ownership_failures
  load_namespace_inventory_types
  for resource_type in "${namespace_inventory_types[@]}"; do
    "${K[@]}" get "$resource_type" --namespace "$namespace" --output=json \
      >"$namespace_inventory_dir/$resource_type.json" ||
      die "could not inventory $resource_type in namespace/$namespace; refusing namespace deletion."
  done
  ownership_failures=$(
    python3 -I -c '
import json
import sys
from pathlib import Path

(
    namespace,
    owner_key,
    allowed_owners_csv,
    release,
    system_namespace,
    inventory_dir,
    *resource_types,
) = sys.argv[1:]
allowed_owners = set(allowed_owners_csv.split(","))
if not allowed_owners or "" in allowed_owners:
    raise SystemExit("cleanup: allowed namespace owners are malformed.")

def fail(message):
    sys.stderr.write(f"cleanup: {message}\n")
    raise SystemExit(1)

def string_map(value, resource_type, name):
    value = value or {}
    if (
        not isinstance(value, dict)
        or any(not isinstance(key, str) or not isinstance(item, str)
               for key, item in value.items())
    ):
        fail(f"{resource_type}/{name} has malformed ownership metadata.")
    return value

nodes = []
by_uid = {}
by_type_name = {}
for resource_type in resource_types:
    path = Path(inventory_dir, f"{resource_type}.json")
    try:
        with path.open(encoding="utf-8") as source:
            resource_list = json.load(source)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{resource_type} inventory is not valid JSON: {error}.")
    if (
        not isinstance(resource_list, dict)
        or not isinstance(resource_list.get("items"), list)
    ):
        fail(f"{resource_type} inventory is not a Kubernetes List.")
    for item in resource_list["items"]:
        if not isinstance(item, dict) or not isinstance(item.get("metadata"), dict):
            fail(f"{resource_type} inventory contains malformed object metadata.")
        metadata = item["metadata"]
        name = metadata.get("name")
        uid = metadata.get("uid")
        if (
            not isinstance(name, str)
            or not name
            or metadata.get("namespace") != namespace
            or not isinstance(uid, str)
            or not uid
        ):
            fail(f"{resource_type} inventory contains an incomplete object identity.")
        labels = string_map(metadata.get("labels"), resource_type, name)
        annotations = string_map(
            metadata.get("annotations"), resource_type, name
        )
        owner_references = metadata.get("ownerReferences") or []
        if not isinstance(owner_references, list):
            fail(f"{resource_type}/{name} has malformed owner references.")
        node = {
            "type": resource_type,
            "name": name,
            "uid": uid,
            "item": item,
            "labels": labels,
            "annotations": annotations,
            "ownerReferences": owner_references,
        }
        if uid in by_uid or (resource_type, name) in by_type_name:
            fail(f"{resource_type}/{name} has a duplicate inventory identity.")
        nodes.append(node)
        by_uid[uid] = node
        by_type_name[(resource_type, name)] = node

def directly_owned(node):
    labels = node["labels"]
    annotations = node["annotations"]
    return (
        labels.get(owner_key) in allowed_owners
        or (
            labels.get(owner_key) == "Helm"
            and annotations.get("meta.helm.sh/release-name") == release
            and annotations.get("meta.helm.sh/release-namespace") == namespace
        )
    )

def expected_tenant_role_binding(node):
    expected = {
        "openclaw-enterprise-worker": (
            f"{release}-openclaw-tenant-worker",
            "openclaw-enterprise-worker",
        ),
        "openclaw-enterprise-api-secrets": (
            f"{release}-openclaw-tenant-api",
            "openclaw-enterprise-api",
        ),
        "openclaw-enterprise-api-configuration": (
            f"{release}-openclaw-tenant-configuration",
            "openclaw-enterprise-api",
        ),
    }
    if node["type"] != "rolebindings.rbac.authorization.k8s.io":
        return False
    desired = expected.get(node["name"])
    if desired is None or node["labels"] or node["ownerReferences"]:
        return False
    role_name, service_account_name = desired
    return (
        node["annotations"] == {
            "kubectl.kubernetes.io/last-applied-configuration":
                node["annotations"].get(
                    "kubectl.kubernetes.io/last-applied-configuration"
                )
        }
        or not node["annotations"]
    ) and node["item"].get("roleRef") == {
        "apiGroup": "rbac.authorization.k8s.io",
        "kind": "ClusterRole",
        "name": role_name,
    } and node["item"].get("subjects") == [{
        "kind": "ServiceAccount",
        "name": service_account_name,
        "namespace": system_namespace,
    }]

def default_service_account(node):
    # The namespace controller creates this exact account. Custom labels,
    # annotations, image-pull settings, or token-mount settings make it untrusted.
    if (
        node["type"] != "serviceaccounts"
        or node["name"] != "default"
        or node["labels"]
        or node["annotations"]
        or node["ownerReferences"]
    ):
        return False
    item = node["item"]
    if "automountServiceAccountToken" in item or item.get("imagePullSecrets"):
        return False
    secrets = item.get("secrets") or []
    return (
        isinstance(secrets, list)
        and all(
            isinstance(secret, dict)
            and isinstance(secret.get("name"), str)
            and secret["name"].startswith("default-token-")
            for secret in secrets
        )
    )

def root_ca_configmap(node):
    # RootCAConfigMapPublisher creates this exact CA-only ConfigMap.
    if node["type"] != "configmaps" or node["name"] != "kube-root-ca.crt":
        return False
    labels = node["labels"]
    annotations = node["annotations"]
    data = node["item"].get("data")
    return (
        set(labels) <= {"kubernetes.io/metadata.name"}
        and labels.get("kubernetes.io/metadata.name", namespace) == namespace
        and set(annotations) == {"kubernetes.io/description"}
        and annotations["kubernetes.io/description"].startswith(
            "Contains a CA bundle"
        )
        and isinstance(data, dict)
        and set(data) == {"ca.crt"}
        and isinstance(data["ca.crt"], str)
        and bool(data["ca.crt"])
        and not node["ownerReferences"]
    )

trusted = {node["uid"] for node in nodes if directly_owned(node)}
trusted.update(
    node["uid"]
    for node in nodes
    if (
        default_service_account(node)
        or root_ca_configmap(node)
        or expected_tenant_role_binding(node)
    )
)

def controller_owned(node):
    for reference in node["ownerReferences"]:
        if not isinstance(reference, dict):
            fail("{}/{} has a malformed owner reference.".format(
                node["type"], node["name"]
            ))
        if reference.get("controller") is True and reference.get("uid") in trusted:
            return True
    return False

def generated_endpoint(node):
    # The endpoint controller mirrors a sample-owned Service without copying
    # its ownership label onto the legacy Endpoints object.
    if node["type"] != "endpoints":
        return False
    labels = node["labels"]
    annotations = node["annotations"]
    return (
        ("services", node["name"]) in {
            (item["type"], item["name"])
            for item in nodes
            if item["uid"] in trusted
        }
        and labels.get("endpoints.kubernetes.io/managed-by")
        in {"endpoint-controller", "endpoints-controller"}
        and set(labels)
        <= {
            "endpoints.kubernetes.io/managed-by",
            "service.kubernetes.io/headless",
        }
        and set(annotations)
        <= {"endpoints.kubernetes.io/last-change-trigger-time"}
        and not node["ownerReferences"]
    )

def generated_certificate_secret(node):
    # cert-manager materializes a TLS Secret for a trusted Certificate. Extra
    # non-cert-manager metadata or unexpected data keys make the Secret untrusted.
    if node["type"] != "secrets" or node["item"].get("type") != "kubernetes.io/tls":
        return False
    certificate_name = node["annotations"].get("cert-manager.io/certificate-name")
    labels = node["labels"]
    data = node["item"].get("data")
    return (
        isinstance(certificate_name, str)
        and ("certificates.cert-manager.io", certificate_name)
        in {
            (item["type"], item["name"])
            for item in nodes
            if item["uid"] in trusted
        }
        and set(labels) <= {"controller.cert-manager.io/fao"}
        and labels.get("controller.cert-manager.io/fao", "true") == "true"
        and node["annotations"]
        and all(key.startswith("cert-manager.io/") for key in node["annotations"])
        and isinstance(data, dict)
        and {"tls.crt", "tls.key"} <= set(data)
        and set(data) <= {"ca.crt", "tls.crt", "tls.key"}
        and all(isinstance(value, str) and value for value in data.values())
        and not node["ownerReferences"]
    )

def generated_controller_lease(node):
    # client-go leader election stores the active sample Pod identity in a
    # Lease. An unrelated holder or any custom metadata is not exempt.
    if node["type"] != "leases.coordination.k8s.io":
        return False
    spec = node["item"].get("spec")
    holder = spec.get("holderIdentity") if isinstance(spec, dict) else None
    pod_names = {
        item["name"]
        for item in nodes
        if item["type"] == "pods" and item["uid"] in trusted
    }
    return (
        isinstance(holder, str)
        and any(holder == name or holder.startswith(f"{name}_") for name in pod_names)
        and not node["labels"]
        and not node["annotations"]
        and not node["ownerReferences"]
    )

while True:
    added = {
        node["uid"]
        for node in nodes
        if node["uid"] not in trusted
        and (
            controller_owned(node)
            or generated_endpoint(node)
            or generated_certificate_secret(node)
            or generated_controller_lease(node)
        )
    }
    if not added:
        break
    trusted.update(added)

print("\n".join(
    "{}/{}".format(node["type"], node["name"])
    for node in nodes
    if node["uid"] not in trusted
))
' "$namespace" "$OWNER_KEY" "$allowed_owners" "$release" "$system_namespace" \
      "$namespace_inventory_dir" \
      "${namespace_inventory_types[@]}"
  ) || die "could not validate descendant ownership in namespace/$namespace."
  [[ -z "$ownership_failures" ]] ||
    die "namespace/$namespace contains descendants without exact sample ownership metadata: $ownership_failures"
}

record_owned() {
  local resource=$1 namespace=$2 expected_owner=$3 expected_uid=${4:-} record
  record=$(resource_record "$resource" "$namespace")
  [[ -n "$record" ]] || return 0
  parse_record "$record"
  [[ -z "$expected_uid" || "$R_UID" == "$expected_uid" ]] ||
    die "$resource${namespace:+ in $namespace} does not match the UID recorded in the installation receipt."
  [[ "$R_NAME" == "${resource##*/}" && "$R_OWNER" == "$expected_owner" ]] ||
    die "$resource${namespace:+ in $namespace} does not carry the exact $OWNER_KEY=$expected_owner ownership label."
  delete_targets+=(
    "$(api_path "$resource" "$namespace")|$R_UID|$R_VERSION|$resource|$namespace"
  )
  verify_targets+=("$resource|$namespace|$R_UID")
}

record_exact() {
  local resource=$1 namespace=$2 record
  record=$(resource_record "$resource" "$namespace")
  [[ -n "$record" ]] || return 0
  parse_record "$record"
  [[ "$R_NAME" == "${resource##*/}" ]] ||
    die "$resource in $namespace does not have the expected identity."
  delete_targets+=(
    "$(api_path "$resource" "$namespace")|$R_UID|$R_VERSION|$resource|$namespace"
  )
  verify_targets+=("$resource|$namespace|$R_UID")
}

readonly -a system_resources=(
  secret/oce-validation-only-postgres deployment.apps/oce-validation-only-postgres
  service/oce-validation-only-postgres
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
  configmap/agentgateway-ca
)
readonly -a tenant_role_bindings=(
  rolebinding.rbac.authorization.k8s.io/openclaw-enterprise-worker
  rolebinding.rbac.authorization.k8s.io/openclaw-enterprise-api-secrets
  rolebinding.rbac.authorization.k8s.io/openclaw-enterprise-api-configuration
)
readonly -a release_resources=(
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-namespace-observer"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-namespace-worker"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-worker" "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-api"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-configuration" "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-gateway-observer"
  "clusterrolebinding.rbac.authorization.k8s.io/${release}-openclaw-worker-namespaces"
  "clusterrolebinding.rbac.authorization.k8s.io/${release}-openclaw-api-namespaces"
)
readonly -a receipt_bound_resources=(
  "namespace/$system_namespace"
  "namespace/openclaw-enterprise-adapter"
  "namespace/$AGW_NAMESPACE"
  "${cluster_resources[@]}"
  "${release_resources[@]}"
  "storageclass.storage.k8s.io/$STORAGE_CLASS"
)
declare -a receipt_resource_guards=()
receipt_guard_output=$(
  python3 -I -c '
from pathlib import Path
import json, re, sys

path, attempt, *expected = sys.argv[1:]

def fail(message):
    sys.stderr.write(f"cleanup: {message}\n")
    raise SystemExit(1)

try:
    if Path(path).stat().st_size > 65536:
        fail("receipt resources.json is too large.")
    receipt = json.loads(Path(path).read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"invalid receipt file resources.json: {error}.")

if (
    not isinstance(receipt, dict)
    or set(receipt) != {"version", "attempt", "resources"}
    or receipt["version"] != 1
    or receipt["attempt"] != attempt
    or not isinstance(receipt["resources"], dict)
):
    fail("receipt resources.json has an unexpected schema or attempt.")

allowed = set(expected)
for resource, uid in receipt["resources"].items():
    if resource not in allowed:
        fail(f"receipt resources.json contains unexpected resource {resource}.")
    if not isinstance(uid, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", uid):
        fail(f"receipt resources.json contains an invalid UID for {resource}.")

for resource in expected:
    uid = receipt["resources"].get(resource)
    if uid is not None:
        print(f"{resource}\t{uid}")
' "$receipt/resources.json" "$receipt_attempt" "${receipt_bound_resources[@]}"
) || die "blueprint resource receipt validation failed."
if [[ -n "$receipt_guard_output" ]]; then
  while IFS=$'\t' read -r resource uid extra; do
    [[ -n "$resource" && -n "$uid" && -z "${extra:-}" ]] ||
      die "blueprint resource receipt output was malformed."
    receipt_resource_guards+=("$resource|$uid")
  done <<<"$receipt_guard_output"
fi

receipt_uid() {
  local requested=$1 guard resource uid extra
  for guard in "${receipt_resource_guards[@]}"; do
    IFS='|' read -r resource uid extra <<<"$guard"
    [[ -z "${extra:-}" ]] || die "invalid blueprint resource receipt guard."
    if [[ "$resource" == "$requested" ]]; then
      printf '%s' "$uid"
      return 0
    fi
  done
  return 1
}

required_receipt_uid() {
  local resource=$1 uid
  uid=$(receipt_uid "$resource") ||
    die "$resource is live but has no UID in the installation receipt."
  printf '%s' "$uid"
}

system_record=$(resource_record "namespace/$system_namespace" "")
if [[ -n "$system_record" ]]; then
  parse_record "$system_record"
  expected_uid=$(required_receipt_uid "namespace/$system_namespace")
  [[ "$R_UID" == "$expected_uid" ]] ||
    die "namespace/$system_namespace does not match the UID recorded in the installation receipt."
  [[ "$R_OWNER" == "$OWNER" ]] ||
    die "namespace/$system_namespace does not carry the exact $OWNER_KEY=$OWNER ownership label."
  verify_namespace_descendants "$system_namespace"
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
  tenant_uid=$R_UID
  tenant_version=$R_VERSION
  verify_namespace_descendants "$namespace" "$OWNER,$OCE_OWNER"
  for resource in "${tenant_resources[@]}"; do
    record_owned "$resource" "$namespace" "$OWNER"
  done
  for resource in "${tenant_role_bindings[@]}"; do
    record_exact "$resource" "$namespace"
  done
  delete_targets+=(
    "$(api_path "namespace/$namespace" "")|$tenant_uid|$tenant_version|namespace/$namespace|"
  )
  verify_targets+=("namespace/$namespace||$tenant_uid")
done

for resource in "${cluster_resources[@]}"; do
  record=$(resource_record "$resource" "")
  [[ -n "$record" ]] || continue
  expected_uid=$(required_receipt_uid "$resource")
  record_owned "$resource" "" "$OWNER" "$expected_uid"
done
for namespace in openclaw-enterprise-adapter "$AGW_NAMESPACE"; do
  record=$(resource_record "namespace/$namespace" "")
  [[ -n "$record" ]] || continue
  parse_record "$record"
  expected_uid=$(required_receipt_uid "namespace/$namespace")
  [[ "$R_UID" == "$expected_uid" ]] ||
    die "namespace/$namespace does not match the UID recorded in the installation receipt."
  [[ "$R_NAME" == "$namespace" && "$R_OWNER" == "$OWNER" ]] ||
    die "namespace/$namespace does not carry the exact $OWNER_KEY=$OWNER ownership label."
  verify_namespace_descendants "$namespace"
  delete_targets+=(
    "$(api_path "namespace/$namespace" "")|$R_UID|$R_VERSION|namespace/$namespace|"
  )
  verify_targets+=("namespace/$namespace||$R_UID")
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
    expected_uid=$(required_receipt_uid "$resource")
    [[ "$R_UID" == "$expected_uid" ]] ||
      die "$resource does not match the UID recorded in the installation receipt."
    [[ "$R_OWNER" == "Helm" && "$R_INSTANCE" == "$release" ]] ||
      die "$resource does not carry the exact Helm release ownership labels."
    release_guards+=("$resource|$R_UID")
  else
    orphan_release_resources+=("$resource")
  fi
done

storage_record=$(resource_record "storageclass.storage.k8s.io/$STORAGE_CLASS" "")
storage_plan="absent"
if [[ -n "$storage_record" ]]; then
  parse_record "$storage_record"
  expected_uid=$(required_receipt_uid "storageclass.storage.k8s.io/$STORAGE_CLASS")
  [[ "$R_UID" == "$expected_uid" ]] ||
    die "storageclass.storage.k8s.io/$STORAGE_CLASS does not match the UID recorded in the installation receipt."
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
