#!/usr/bin/env bash
set -euo pipefail
set +x
IFS=$'\n\t'
umask 077

readonly OCE_SOURCE_PIN="86c8c12310f691bb21651118ffffd6bfd460e9ff" # pragma: allowlist secret -- public source revision
readonly OCE_MODULE="github.com/openclaw/openclaw-enterprise"
readonly OWNER_LABEL="openclaw-enterprise-blueprint"
readonly VALIDATION_POSTGRES_TOKEN="__OCE_VALIDATION_POSTGRES_IMAGE__"
readonly VALIDATION_POSTGRES_STORAGE_TOKEN="__OCE_VALIDATION_POSTGRES_STORAGE_CLASS__"
readonly VALIDATION_CLUSTER_TAG_KEY="Environment"
readonly VALIDATION_CLUSTER_TAG_VALUE="validation"
readonly VALIDATION_POSTGRES_MIN_SERVER_VERSION_NUM=170000
readonly MODEL_PROVIDER_PROTOCOL="openai-responses"
readonly MODEL_PROVIDER_BASE_URL="https://agentgateway.openclaw-enterprise-agw.svc.cluster.local/v1"
readonly DATABASE_CA_SECRET="oce-sample-database-ca" # pragma: allowlist secret -- Kubernetes Secret name
readonly DATABASE_CA_KEY="ca.pem"
readonly DATABASE_CA_MOUNT_PATH="/etc/openclaw/database-ca"
readonly DATABASE_CA_PATH="$DATABASE_CA_MOUNT_PATH/$DATABASE_CA_KEY"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly INPUT_VALIDATOR="$SCRIPT_DIR/install-oce-inputs.py"

usage() {
  printf '%s\n' \
    'Usage:' \
    "  install-oce.sh \\" \
    "    --aws-account-id ID --aws-region REGION --eks-cluster-name NAME \\" \
    "    --kubeconfig FILE --kube-context CONTEXT \\" \
    "    --oce-source DIR (--occ-binary FILE | --build-occ) \\" \
    "    --controller-image IMAGE@sha256:DIGEST \\" \
    "    --runtime-image IMAGE@sha256:DIGEST \\" \
    "    --auth-base-url https://HOST --agent-domain DOMAIN \\" \
    "    --admin-email EMAIL --runtime-storage-class NAME \\" \
    "    --pod-cidr CIDR --cluster-api-cidr IPV4/32 \\" \
    "    --state-dir DIR --receipt DIR \\" \
    "    [--namespace NAME] [--release NAME] [--wait-timeout DURATION] \\" \
    "    (--validation-postgres \\" \
    '       --validation-postgres-image IMAGE@sha256:DIGEST |' \
    "     --database-app-url-file FILE \\" \
    "       --database-migration-url-file FILE \\" \
    "       --database-ca-file FILE \\" \
    '       --database-cidr IPV4/32)' \
    '' \
    'Installs the exact OpenClaw Enterprise source revision' \
    '86c8c12310f691bb21651118ffffd6bfd460e9ff in a terminal-managed topology.' \
    'Direct Pod API clients, browser gateway routing, and agent native administration' \
    'are disabled.' \
    '' \
    '--validation-postgres creates a single-Pod PostgreSQL database on the encrypted' \
    'EBS-backed --runtime-storage-class. Cleanup deletes its claim and Delete-policy' \
    'volume. The EKS cluster must have the exact tag key Environment with' \
    'value validation (value matching is case-insensitive). Production-tagged clusters' \
    'are rejected. The image must run PostgreSQL 17 or later; the README pins the' \
    'OCE-qualified PostgreSQL 18.6 baseline. This mode is only for installation' \
    'validation, never production.' \
    '' \
    'External database URL files must use a DNS hostname, sslmode=verify-full, and' \
    "sslrootcert=$DATABASE_CA_PATH. --database-ca-file must contain only trusted PEM" \
    'CA certificates; the installer mounts it into every chart database client.' \
    '' \
    'Repeat --cluster-api-cidr and --database-cidr when more than one exact /32 is' \
    'needed. The receipt must be a new path below --state-dir.'
}

die() {
  printf 'install-oce: %s\n' "$1" >&2
  exit "${2:-1}"
}

need_value() {
  (($# >= 2)) || die "$1 requires a value."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1."
}

require_helm_3() {
  local LC_ALL=C helm_version
  helm_version=$(helm version --short 2>/dev/null) ||
    die "could not determine the Helm version."
  [[ "$helm_version" =~ ^v?3([.+-]|$) ]] ||
    die "pinned OCE revision requires Helm 3; found $helm_version."
}

require_input_validator() {
  [[ -f "$INPUT_VALIDATOR" && ! -L "$INPUT_VALIDATOR" && -r "$INPUT_VALIDATOR" ]] ||
    die "missing input validator: $INPUT_VALIDATOR."
}

is_dns_label() {
  local LC_ALL=C value=$1
  [[ ${#value} -le 63 && "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

is_dns_subdomain() {
  local LC_ALL=C value=$1
  [[ ${#value} -le 253 &&
    "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]
}

require_immutable_image() {
  local LC_ALL=C flag=$1 image=$2
  [[ "$image" =~ ^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$ ]] ||
    die "$flag must be a lowercase immutable IMAGE@sha256:DIGEST reference."
}

require_ipv4_cidr() {
  local flag=$1 cidr=$2 exact_host=${3:-false}
  python3 -c '
import ipaddress
import sys

flag, value, exact_host = sys.argv[1:]
try:
    network = ipaddress.ip_network(value, strict=False)
except ValueError:
    sys.stderr.write(f"install-oce: {flag} must be a valid IPv4 CIDR.\n")
    raise SystemExit(1)
if network.version != 4 or (exact_host == "true" and network.prefixlen != 32):
    suffix = " exact IPv4 /32" if exact_host == "true" else "n IPv4 CIDR"
    sys.stderr.write(f"install-oce: {flag} must be a{suffix}.\n")
    raise SystemExit(1)
if network.prefixlen == 0:
    sys.stderr.write(f"install-oce: {flag} must not allow all IPv4 addresses.\n")
    raise SystemExit(1)
' "$flag" "$cidr" "$exact_host" ||
    die "$flag is invalid."
}

derive_eks_cluster_dns_cidr() {
  local service_cidr=$1
  python3 -I -c '
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    sys.stderr.write(
        "install-oce: EKS cluster service IPv4 CIDR is invalid.\n"
    )
    raise SystemExit(1)
if network.version != 4 or network.num_addresses <= 10:
    sys.stderr.write(
        "install-oce: EKS cluster service IPv4 CIDR must contain the "
        "cluster DNS service address.\n"
    )
    raise SystemExit(1)
print(f"{network.network_address + 10}/32")
' "$service_cidr" ||
    die "could not derive the EKS cluster DNS service address."
}

derive_eks_cluster_api_service_cidr() {
  local service_cidr=$1
  python3 -I -c '
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    sys.stderr.write(
        "install-oce: EKS cluster service IPv4 CIDR is invalid.\n"
    )
    raise SystemExit(1)
if network.version != 4 or network.num_addresses <= 1:
    sys.stderr.write(
        "install-oce: EKS cluster service IPv4 CIDR must contain the "
        "Kubernetes API service address.\n"
    )
    raise SystemExit(1)
print(f"{network.network_address + 1}/32")
' "$service_cidr" ||
    die "could not derive the Kubernetes API service address."
}

require_private_file() {
  local flag=$1 path=$2 mode links
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] ||
    die "$flag must be a readable regular file, not a symlink."
  if mode=$(stat -c '%a' "$path" 2>/dev/null) &&
    [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    :
  elif mode=$(stat -f '%Lp' "$path" 2>/dev/null) &&
    [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    :
  else
    die "could not inspect permissions for $flag."
  fi
  [[ "$mode" =~ ^[0-7]00$ ]] ||
    die "$flag must not be readable or writable by group or other (mode is $mode)."
  [[ -O "$path" ]] ||
    die "$flag must be owned by the current user."
  # A second hard link is another name for the same secret, outside this check.
  if links=$(stat -c '%h' "$path" 2>/dev/null) && [[ "$links" =~ ^[0-9]+$ ]]; then
    :
  elif links=$(stat -f '%l' "$path" 2>/dev/null) && [[ "$links" =~ ^[0-9]+$ ]]; then
    :
  else
    die "could not inspect the link count for $flag."
  fi
  [[ "$links" == 1 ]] ||
    die "$flag must have exactly one hard link."
}

install_postgres_url() {
  local flag=$1 source=$2 destination=$3
  if ! python3 "$INPUT_VALIDATOR" postgres-url \
    "$flag" "$source" "$destination" "$DATABASE_CA_PATH"; then
    die "$flag is invalid."
  fi
}

install_ca_bundle() {
  local flag=$1 source=$2 destination=$3
  if ! python3 "$INPUT_VALIDATOR" ca-bundle \
    "$flag" "$source" "$destination"; then
    die "$flag is invalid."
  fi
}

require_validation_cluster_tags() {
  local tags_json=$1
  python3 "$INPUT_VALIDATOR" validation-cluster-tags \
    "$tags_json" "$VALIDATION_CLUSTER_TAG_KEY" "$VALIDATION_CLUSTER_TAG_VALUE" ||
    die "EKS cluster is not explicitly tagged for validation."
}

require_validation_postgres_version() {
  local target_namespace=$1 version_num
  version_num=$(
    "${KUBE[@]}" --namespace "$target_namespace" exec \
      deployment/oce-validation-only-postgres -- \
      psql -U oce_validation -d openclaw -Atc 'SHOW server_version_num'
  ) || die "could not determine validation PostgreSQL server version."
  [[ "$version_num" =~ ^[0-9]+$ ]] ||
    die "validation PostgreSQL returned an invalid server version."
  ((version_num >= VALIDATION_POSTGRES_MIN_SERVER_VERSION_NUM)) ||
    die "pinned OCE revision requires PostgreSQL 17 or later; validation database reported $version_num."
}

require_validation_postgres_role_contract() {
  local target_namespace=$1 role_contract
  role_contract=$(
    "${KUBE[@]}" --namespace "$target_namespace" exec \
      deployment/oce-validation-only-postgres -- \
      psql -U oce_validation -d openclaw -Atc "
SELECT (
  (
    SELECT count(*) = 2
      AND bool_and(NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls)
    FROM pg_roles
    WHERE rolname IN ('occ_migrator', 'occ_app')
  )
  AND has_database_privilege('occ_migrator', current_database(), 'CREATE')
  AND NOT has_database_privilege('occ_app', current_database(), 'CREATE')
  AND (
    SELECT pg_get_userbyid(nspowner) = 'occ_migrator'
    FROM pg_namespace
    WHERE nspname = 'occ'
  )
  AND (
    SELECT pg_get_userbyid(nspowner) = 'occ_migrator'
    FROM pg_namespace
    WHERE nspname = 'drizzle'
  )
  AND NOT has_schema_privilege('occ_app', 'public', 'CREATE')
)::text;"
  ) || die "could not verify validation PostgreSQL role contract."
  [[ "$role_contract" == true ]] ||
    die "validation PostgreSQL role contract does not match pinned OCE requirements."
}

base64_one_line() {
  base64 <"$1" | tr -d '\r\n'
}

write_private_text() {
  local path=$1 value=$2
  printf '%s' "$value" >"$path"
  chmod 600 "$path"
}

write_private() {
  local path=$1
  shift
  "$@" >"$path"
  chmod 600 "$path"
}

sync_file_and_parent() {
  local path=$1
  python3 -I -c '
import os
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    os.fsync(handle.fileno())
directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
' "$path" || die "could not durably persist $path."
}

sync_directory() {
  local path=$1
  python3 -I -c '
import os
import sys

directory = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
' "$path" || die "could not durably persist directory $path."
}

persist_private_file() {
  local source=$1 destination=$2
  [[ ! -e "$destination" && ! -L "$destination" ]] ||
    die "refusing to overwrite existing bootstrap credential $destination."
  chmod 600 "$source"
  sync_file_and_parent "$source"
  mv "$source" "$destination"
  sync_directory "$(dirname "$destination")"
}

sha256_file() {
  local path=$1
  python3 -I -c '
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(131072), b""):
        digest.update(chunk)
print(digest.hexdigest())
' "$path" || die "could not hash $path."
}

normalize_hex_secret() {
  local LC_ALL=C label=$1 path=$2 expected_length=$3 value
  require_private_file "$label" "$path"
  value=$(<"$path")
  [[ ${#value} -eq "$expected_length" && "$value" =~ ^[a-f0-9]+$ ]] ||
    die "$label must contain exactly $expected_length lowercase hexadecimal characters."
  write_private_text "$path" "$value"
}

verify_occ_binary() {
  local binary=$1 metadata
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] ||
    die "OCC binary must be an executable regular file, not a symlink."
  metadata=$(go version -m "$binary" 2>&1) ||
    die "could not read Go build metadata from OCC binary $binary."
  grep -Fq $'\tmod\t'"$OCE_MODULE"$'\t' <<<"$metadata" ||
    die "OCC binary was not built from $OCE_MODULE."
  grep -Fq $'\tbuild\tvcs.revision='"$OCE_SOURCE_PIN" <<<"$metadata" ||
    die "OCC binary does not match source pin $OCE_SOURCE_PIN."
  grep -Fq $'\tbuild\tvcs.modified=false' <<<"$metadata" ||
    die "OCC binary was built from modified source."
}

kubectl_error_is_not_found() {
  # Only kubectl's own NotFound line means absent: other errors can mention "not found" (for example a
  # missing admission webhook service), and those must stop the install.
  grep -Eq '^Error from server \(NotFound\): ' <<<"$1"
}

kubectl_error_is_already_exists() {
  grep -Eq '(\(AlreadyExists\)|already exists|AlreadyExists)' <<<"$1"
}

resource_is_owned() {
  local kind=$1 name=$2
  local output status owner
  set +e
  output=$("${KUBE[@]}" --namespace "$namespace" get "$kind" "$name" -o name 2>&1)
  status=$?
  set -e
  if ((status != 0)); then
    kubectl_error_is_not_found "$output" && return 1
    die "could not inspect $kind/$name: $output"
  fi
  owner=$("${KUBE[@]}" --namespace "$namespace" get "$kind" "$name" \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')
  [[ "$owner" == "$OWNER_LABEL" ]] ||
    die "refusing to adopt existing $kind/$name; expected managed-by=$OWNER_LABEL."
  return 0
}

apply_owned_resource() {
  local kind=$1 name=$2 manifest=$3
  resource_is_owned "$kind" "$name" || true
  "${KUBE[@]}" --namespace "$namespace" apply \
    --server-side --field-manager="$OWNER_LABEL" -f "$manifest" >/dev/null
}

require_kubernetes_uid() {
  local label=$1 uid=$2
  [[ "$uid" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
    die "$label reported an invalid Kubernetes UID."
}

inspect_owned_resource() {
  local kind=$1 name=$2 expected_owner=$3
  local output status owner uid resource_version
  INSPECTED_RESOURCE_PRESENT=false
  INSPECTED_RESOURCE_UID=
  INSPECTED_RESOURCE_VERSION=
  INSPECTED_RESOURCE_JSON=
  set +e
  output=$("${KUBE[@]}" --namespace "$namespace" get "$kind" "$name" -o json 2>&1)
  status=$?
  set -e
  if ((status != 0)); then
    kubectl_error_is_not_found "$output" && return 0
    die "could not inspect $kind/$name: $output"
  fi
  owner=$(jq -er '.metadata.labels["app.kubernetes.io/managed-by"]' <<<"$output") ||
    die "$kind/$name is missing its ownership label."
  [[ "$owner" == "$expected_owner" ]] ||
    die "refusing to use $kind/$name; expected managed-by=$expected_owner."
  uid=$(jq -er '.metadata.uid' <<<"$output") ||
    die "$kind/$name is missing its UID."
  require_kubernetes_uid "$kind/$name" "$uid"
  resource_version=$(jq -er \
    '.metadata.resourceVersion | select(type == "string" and length > 0)' \
    <<<"$output") ||
    die "$kind/$name is missing its resourceVersion."
  INSPECTED_RESOURCE_PRESENT=true
  INSPECTED_RESOURCE_UID=$uid
  INSPECTED_RESOURCE_VERSION=$resource_version
  INSPECTED_RESOURCE_JSON=$output
}

bootstrap_handoff_contract_matches() {
  local pod_json=$1
  [[ "$bootstrap_pod_receipt" =~ ^[a-f0-9]{64}$ ]] || return 1
  jq -e \
    --arg namespace "$namespace" \
    --arg owner "$OWNER_LABEL" \
    --arg image "$controller_image" \
    --arg receipt "$bootstrap_pod_receipt" \
    '
      def normalized_container:
        del(.terminationMessagePath, .terminationMessagePolicy)
        | if .resources == {} then del(.resources) else . end;
      .metadata.name == "oce-sample-bootstrap-handoff"
      and .metadata.namespace == $namespace
      and (.metadata.generateName // "") == ""
      and (.metadata.ownerReferences // []) == []
      and .metadata.labels["app.kubernetes.io/managed-by"] == $owner
      and .metadata.labels["app.kubernetes.io/part-of"] == $owner
      and .metadata.labels["app.kubernetes.io/component"]
        == "bootstrap-handoff"
      and (
        (.metadata.labels | keys) - [
          "app.kubernetes.io/managed-by",
          "app.kubernetes.io/part-of",
          "app.kubernetes.io/component",
          "topology.kubernetes.io/region",
          "topology.kubernetes.io/zone"
        ]
        | length == 0
      )
      and (
        (.metadata.labels | has("topology.kubernetes.io/region") | not)
        or (
          .metadata.labels["topology.kubernetes.io/region"]
          | type == "string" and length > 0
        )
      )
      and (
        (.metadata.labels | has("topology.kubernetes.io/zone") | not)
        or (
          .metadata.labels["topology.kubernetes.io/zone"]
          | type == "string" and length > 0
        )
      )
      and .metadata.annotations[
        "openclaw.dev/bootstrap-handoff-receipt"
      ] == $receipt
      and (.spec.dnsPolicy // "ClusterFirst") == "ClusterFirst"
      and (.spec.schedulerName // "default-scheduler") == "default-scheduler"
      and (.spec.serviceAccountName // "default") == "default"
      and (.spec.serviceAccount // "default") == "default"
      and (.spec.terminationGracePeriodSeconds // 30) == 30
      and (.spec.priority // 0) == 0
      and (
        (.spec.preemptionPolicy // "PreemptLowerPriority")
        == "PreemptLowerPriority"
      )
      and (
        (.spec.nodeName // "") == ""
        or (.spec.nodeName | type == "string" and length > 0)
      )
      and (
        (.spec.tolerations // [])
        | all(
          (
            .key == "node.kubernetes.io/not-ready"
            or .key == "node.kubernetes.io/unreachable"
          )
          and .operator == "Exists"
          and .effect == "NoExecute"
          and .tolerationSeconds == 300
        )
      )
      and (
        (
          .spec
          | del(
              .nodeName,
              .dnsPolicy,
              .schedulerName,
              .serviceAccountName,
              .serviceAccount,
              .terminationGracePeriodSeconds,
              .tolerations,
              .priority,
              .preemptionPolicy
            )
          | .containers |= map(normalized_container)
        ) == {
          automountServiceAccountToken: false,
          enableServiceLinks: false,
          restartPolicy: "Never",
          securityContext: {
            runAsNonRoot: true,
            runAsUser: 1000,
            runAsGroup: 1000,
            fsGroup: 1000,
            seccompProfile: {type: "RuntimeDefault"}
          },
          containers: [{
            name: "handoff",
            image: $image,
            imagePullPolicy: "IfNotPresent",
            command: ["node"],
            args: ["-e", "setInterval(() => {}, 300000)"],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: {drop: ["ALL"]}
            },
            volumeMounts: [{
              name: "bootstrap",
              mountPath: "/bootstrap"
            }]
          }],
          volumes: [{
            name: "bootstrap",
            persistentVolumeClaim: {
              claimName: "oce-sample-bootstrap-output"
            }
          }]
        }
      )
    ' <<<"$pod_json" >/dev/null
}

require_bootstrap_handoff_contract() {
  local pod_json=$1 expected_uid=$2 actual_uid
  actual_uid=$(jq -er '.metadata.uid' <<<"$pod_json") ||
    die "bootstrap handoff Pod is missing its UID."
  require_kubernetes_uid "bootstrap handoff Pod" "$actual_uid"
  [[ -z "$expected_uid" || "$actual_uid" == "$expected_uid" ]] ||
    die "refusing to recover replaced pod/oce-sample-bootstrap-handoff."
  bootstrap_handoff_contract_matches "$pod_json" ||
    die "bootstrap handoff Pod does not match its journalled receipt and canonical specification."
}

oce_initialization_job_contract_matches() {
  local job_json=$1
  jq -e \
    --arg namespace "$namespace" \
    --arg release "$release" \
    --arg attempt "$occ_attempt" \
    --arg image "$controller_image" \
    '
      .metadata.name == ($release + "-initialization")
      and .metadata.namespace == $namespace
      and (.metadata.ownerReferences // []) == []
      and .metadata.labels["app.kubernetes.io/name"]
        == "openclaw-enterprise"
      and .metadata.labels["app.kubernetes.io/instance"] == $release
      and .metadata.labels["app.kubernetes.io/component"]
        == "initialization"
      and .metadata.labels["app.kubernetes.io/managed-by"] == "Helm"
      and .metadata.annotations["openclaw.dev/installation-attempt"]
        == $attempt
      and .metadata.annotations["helm.sh/hook"] == "pre-install,pre-upgrade"
      and .metadata.annotations["helm.sh/hook-weight"] == "-10"
      and .metadata.annotations["helm.sh/hook-delete-policy"]
        == "before-hook-creation"
      and (.status.active // 0) == 0
      and (.status.failed // 0) == 0
      and (.status.succeeded // 0) == 1
      and any(
        .status.conditions[]?;
        .type == "Complete" and .status == "True"
      )
      and all(
        .status.conditions[]?;
        (.type != "Failed") or .status != "True"
      )
      and .spec.template.spec.serviceAccountName
        == "openclaw-enterprise-initialization"
      and .spec.template.spec.automountServiceAccountToken == false
      and .spec.template.spec.restartPolicy == "Never"
      and (
        .spec.template.spec.volumes
        | map(select(has("persistentVolumeClaim")))
      ) == [{
        name: "bootstrap-password-output",
        persistentVolumeClaim: {
          claimName: "oce-sample-bootstrap-output"
        }
      }]
      and (.spec.template.spec.initContainers | length) == 1
      and .spec.template.spec.initContainers[0].name == "migration"
      and .spec.template.spec.initContainers[0].image == $image
      and (.spec.template.spec.containers | length) == 1
      and .spec.template.spec.containers[0].name == "bootstrap"
      and .spec.template.spec.containers[0].image == $image
      and any(
        .spec.template.spec.containers[0].volumeMounts[]?;
        .name == "bootstrap-password-output"
      )
    ' <<<"$job_json" >/dev/null
}

delete_oce_initialization_job() {
  local job_name="${release}-initialization"
  local resource_path delete_options output status
  inspect_owned_resource job "$job_name" Helm
  if [[ "$INSPECTED_RESOURCE_PRESENT" != true ]]; then
    return 0
  fi
  oce_initialization_job_contract_matches "$INSPECTED_RESOURCE_JSON" ||
    die "refusing to delete $job_name; it does not match the completed OCE installation hook."
  if jq -e '.metadata.deletionTimestamp? | type == "string" and length > 0' \
    <<<"$INSPECTED_RESOURCE_JSON" >/dev/null; then
    "${KUBE[@]}" --namespace "$namespace" wait \
      --for=delete "job/$job_name" --timeout=120s
    return 0
  fi
  resource_path=$(kubernetes_resource_path job "$job_name")
  delete_options=$(jq -cn \
    --arg uid "$INSPECTED_RESOURCE_UID" \
    --arg resource_version "$INSPECTED_RESOURCE_VERSION" \
    '{
      apiVersion: "v1",
      kind: "DeleteOptions",
      propagationPolicy: "Foreground",
      preconditions: {
        uid: $uid,
        resourceVersion: $resource_version
      }
    }')
  set +e
  output=$("${KUBE[@]}" --namespace "$namespace" delete \
    --raw="$resource_path" -f - <<<"$delete_options" 2>&1)
  status=$?
  set -e
  if ((status != 0)); then
    kubectl_error_is_not_found "$output" && return 0
    die "preconditioned deletion failed for job/$job_name: $output"
  fi
  "${KUBE[@]}" --namespace "$namespace" wait \
    --for=delete "job/$job_name" --timeout=120s
}

kubernetes_resource_path() {
  local kind=$1 name=$2
  case "$kind" in
    pod)
      printf '/api/v1/namespaces/%s/pods/%s' "$namespace" "$name"
      ;;
    persistentvolumeclaim)
      printf '/api/v1/namespaces/%s/persistentvolumeclaims/%s' \
        "$namespace" "$name"
      ;;
    job)
      printf '/apis/batch/v1/namespaces/%s/jobs/%s' "$namespace" "$name"
      ;;
    *)
      die "raw deletion is not implemented for Kubernetes kind $kind."
      ;;
  esac
}

delete_owned_resource() {
  local kind=$1 name=$2 expected_uid=$3 timeout=$4
  local resource_path delete_options output status
  inspect_owned_resource "$kind" "$name" "$OWNER_LABEL"
  if [[ "$INSPECTED_RESOURCE_PRESENT" != true ]]; then
    return 0
  fi
  [[ -n "$expected_uid" && "$INSPECTED_RESOURCE_UID" == "$expected_uid" ]] ||
    die "refusing to delete replaced $kind/$name; UID does not match the handoff journal."
  resource_path=$(kubernetes_resource_path "$kind" "$name")
  delete_options=$(jq -cn \
    --arg uid "$INSPECTED_RESOURCE_UID" \
    --arg resource_version "$INSPECTED_RESOURCE_VERSION" \
    '{
      apiVersion: "v1",
      kind: "DeleteOptions",
      propagationPolicy: "Background",
      preconditions: {
        uid: $uid,
        resourceVersion: $resource_version
      }
    }')
  set +e
  output=$("${KUBE[@]}" --namespace "$namespace" delete \
    --raw="$resource_path" -f - <<<"$delete_options" 2>&1)
  status=$?
  set -e
  if ((status != 0)); then
    kubectl_error_is_not_found "$output" && return 0
    die "preconditioned deletion failed for $kind/$name: $output"
  fi
  "${KUBE[@]}" --namespace "$namespace" wait \
    --for=delete "$kind/$name" --timeout="$timeout"
}

require_storage_class_contract() {
  local storage_class_json
  storage_class_json=$("${KUBE[@]}" get storageclass \
    "$runtime_storage_class" -o json) ||
    die "required StorageClass $runtime_storage_class does not exist."
  jq -e \
    --arg name "$runtime_storage_class" \
    --arg owner "$OWNER_LABEL" \
    '
      .metadata.name == $name
      and .metadata.labels["app.kubernetes.io/managed-by"] == $owner
      and .provisioner == "ebs.csi.eks.amazonaws.com"
      and .parameters.type == "gp3"
      and .parameters.encrypted == "true"
      and .reclaimPolicy == "Delete"
      and .volumeBindingMode == "WaitForFirstConsumer"
    ' <<<"$storage_class_json" >/dev/null ||
    die "StorageClass $runtime_storage_class must be blueprint-owned encrypted gp3 with reclaimPolicy=Delete."
}

require_network_policy_enforcement() {
  # OCE trusts the whole pod CIDR as a gateway proxy source; only its tenant NetworkPolicies keep other Pods
  # from presenting the gateway's trusted identity header. EKS Auto Mode accepts those policies without
  # enforcing them until this cluster-wide setting is on. This script reads it and never changes it.
  local value status
  set +e
  value=$("${KUBE[@]}" --namespace kube-system get configmap amazon-vpc-cni \
    -o 'jsonpath={.data.enable-network-policy-controller}' 2>&1)
  status=$?
  set -e
  if ((status != 0)) && ! kubectl_error_is_not_found "$value"; then
    die "could not read configmap/amazon-vpc-cni in kube-system: $value"
  fi
  [[ "$status" -eq 0 && "$value" == true ]] ||
    die "network policy enforcement is off: configmap/amazon-vpc-cni in kube-system must set enable-network-policy-controller to \"true\" (README Prerequisites). This script does not change that shared setting."
}

validate_occ_receipt() {
  [[ -d "$receipt" && ! -L "$receipt" ]] ||
    die "OCC receipt must be a directory, not a symbolic link."
  require_private_file "OCC receipt intent" "$receipt/intent.json"
  require_private_file "OCC receipt dispatch state" "$receipt/dispatch.json"
  require_private_file "OCC receipt Helm result" "$receipt/helm-result.json"
  occ_receipt_attempt=$(python3 -I -c '
import json
import sys
from pathlib import Path

intent_path, dispatch_path, result_path, namespace, release = sys.argv[1:]
try:
    intent = json.loads(Path(intent_path).read_text(encoding="utf-8"))
    dispatch = json.loads(Path(dispatch_path).read_text(encoding="utf-8"))
    result = json.loads(Path(result_path).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit("invalid OCC receipt JSON")
attempt = intent.get("attempt")
valid_intent = (
    intent.get("version") == 1
    and intent.get("operation") == "helm-install"
    and intent.get("namespace") == namespace
    and intent.get("release") == release
    and isinstance(attempt, str)
    and bool(attempt)
)
if not valid_intent:
    raise SystemExit("OCC receipt intent does not match this install")
if dispatch != {"outcome": "unknown"}:
    raise SystemExit("invalid OCC dispatch state")
if result not in ({"outcome": "succeeded"}, {"outcome": "recovered"}):
    raise SystemExit("OCC receipt does not prove a successful install")
print(attempt)
' "$receipt/intent.json" "$receipt/dispatch.json" \
    "$receipt/helm-result.json" "$namespace" "$release") ||
    die "OCC receipt does not prove a successful install for this target."
  require_kubernetes_uid "OCC installation attempt" "$occ_receipt_attempt"
}

require_deployed_release_attempt() {
  local helm_values live_attempt
  helm_values=$(helm get values "$release" \
    --kubeconfig "$kubeconfig" --kube-context "$kube_context" \
    --namespace "$namespace" --output json) ||
    die "could not inspect Helm values for deployed release $release."
  live_attempt=$(jq -er \
    '[
      (.installation.attemptId? // empty),
      (.installationAttempt? // empty)
    ]
    | map(select(type == "string" and length > 0))
    | unique
    | select(length == 1)
    | .[0]' \
    <<<"$helm_values") ||
    die "deployed release $release has no OCC installation attempt."
  [[ "$live_attempt" == "$occ_receipt_attempt" ]] ||
    die "deployed release $release does not match the OCC receipt attempt."
}

write_handoff_state() {
  local phase=$1
  [[ ! -L "$handoff_state" ]] ||
    die "bootstrap handoff journal must not be a symlink."
  python3 -I -c '
import json
import os
import sys
import tempfile

(
    path,
    phase,
    source,
    cluster_arn,
    context,
    namespace,
    release,
    storage_class,
    job_uid,
    pvc_uid,
    pv_name,
    pv_uid,
    pod_uid,
    pod_receipt,
    occ_attempt,
    credential_key_sha256,
    credential_password_sha256,
) = sys.argv[1:]
parent = os.path.dirname(path)
data = {
    "version": 3,
    "phase": phase,
    "source": source,
    "clusterArn": cluster_arn,
    "context": context,
    "namespace": namespace,
    "release": release,
    "storageClass": storage_class,
    "jobUid": job_uid,
    "pvcUid": pvc_uid,
    "pvName": pv_name,
    "pvUid": pv_uid,
    "podUid": pod_uid,
    "podReceipt": pod_receipt,
    "occAttempt": occ_attempt,
    "credentialKeySha256": credential_key_sha256,
    "credentialPasswordSha256": credential_password_sha256,
}
descriptor, temporary = tempfile.mkstemp(
    dir=parent, prefix=".bootstrap-handoff.", text=True
)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
' "$handoff_state" "$phase" "$OCE_SOURCE_PIN" "$cluster_arn" \
    "$kube_context" "$namespace" "$release" "$runtime_storage_class" \
    "$bootstrap_job_uid" "$bootstrap_pvc_uid" "$bootstrap_pv" \
    "$bootstrap_pv_uid" "$bootstrap_pod_uid" "$bootstrap_pod_receipt" \
    "$occ_attempt" \
    "$credential_key_sha256" "$credential_password_sha256" ||
    die "could not persist the bootstrap handoff journal."
  handoff_phase=$phase
}

load_handoff_state() {
  require_private_file "bootstrap handoff journal" "$handoff_state"
  jq -e \
    --arg source "$OCE_SOURCE_PIN" \
    --arg cluster_arn "$cluster_arn" \
    --arg context "$kube_context" \
    --arg namespace "$namespace" \
    --arg release "$release" \
    --arg storage_class "$runtime_storage_class" \
    '
      .phase as $phase
      | .version == 3
      and .source == $source
      and .clusterArn == $cluster_arn
      and .context == $context
      and .namespace == $namespace
      and .release == $release
      and .storageClass == $storage_class
      and (.phase | type == "string")
      and (.jobUid | type == "string")
      and (.pvcUid | type == "string")
      and (.pvName | type == "string")
      and (.pvUid | type == "string")
      and (.podUid | type == "string")
      and (.podReceipt | test("^[a-f0-9]{64}$"))
      and (.occAttempt | type == "string")
      and (.credentialKeySha256 | type == "string")
      and (.credentialPasswordSha256 | type == "string")
      and (
        if (
          $phase == "credentials-local"
          or $phase == "credentials-erased"
          or $phase == "pod-deleted"
          or $phase == "job-deleted"
          or $phase == "pvc-deleted"
          or $phase == "pv-deleted"
        )
        then
          (.credentialKeySha256 | test("^[a-f0-9]{64}$"))
          and (.credentialPasswordSha256 | test("^[a-f0-9]{64}$"))
        else
          .credentialKeySha256 == ""
          and .credentialPasswordSha256 == ""
        end
      )
    ' "$handoff_state" >/dev/null ||
    die "bootstrap handoff journal does not match this install request."
  handoff_phase=$(jq -er '.phase' "$handoff_state")
  bootstrap_job_uid=$(jq -er '.jobUid' "$handoff_state")
  bootstrap_pvc_uid=$(jq -er '.pvcUid' "$handoff_state")
  bootstrap_pv=$(jq -er '.pvName' "$handoff_state")
  bootstrap_pv_uid=$(jq -er '.pvUid' "$handoff_state")
  bootstrap_pod_uid=$(jq -er '.podUid' "$handoff_state")
  bootstrap_pod_receipt=$(jq -er '.podReceipt' "$handoff_state")
  occ_attempt=$(jq -er '.occAttempt' "$handoff_state")
  credential_key_sha256=$(jq -er '.credentialKeySha256' "$handoff_state")
  credential_password_sha256=$(jq -er \
    '.credentialPasswordSha256' "$handoff_state")
  case "$handoff_phase" in
    prepared|volume-ready|installed|handoff-pod-ready|credentials-local|\
      credentials-erased|pod-deleted|job-deleted|pvc-deleted|pv-deleted) ;;
    *) die "bootstrap handoff journal has an invalid phase." ;;
  esac
}

aws_account_id=
aws_region=
eks_cluster_name=
kubeconfig=
kube_context=
oce_source=
occ_binary=
build_occ=false
controller_image=
runtime_image=
auth_base_url=
agent_domain=
admin_email=
runtime_storage_class=
pod_cidr=
state_dir=
receipt=
namespace="openclaw-system"
release="oce"
wait_timeout="5m"
validation_postgres=false
validation_postgres_image=
database_app_url_file=
database_migration_url_file=
database_ca_file=
cluster_api_cidrs=()
database_cidrs=()
handoff_phase=
bootstrap_job_uid=
bootstrap_pvc_uid=
bootstrap_pv=
bootstrap_pv_uid=
bootstrap_pod_uid=
bootstrap_pod_receipt=
occ_attempt=
credential_key_sha256=
credential_password_sha256=

while (($#)); do
  case "$1" in
    --aws-account-id) need_value "$@"; aws_account_id=$2; shift 2 ;;
    --aws-region) need_value "$@"; aws_region=$2; shift 2 ;;
    --eks-cluster-name) need_value "$@"; eks_cluster_name=$2; shift 2 ;;
    --kubeconfig) need_value "$@"; kubeconfig=$2; shift 2 ;;
    --kube-context) need_value "$@"; kube_context=$2; shift 2 ;;
    --oce-source) need_value "$@"; oce_source=$2; shift 2 ;;
    --occ-binary) need_value "$@"; occ_binary=$2; shift 2 ;;
    --build-occ) build_occ=true; shift ;;
    --controller-image) need_value "$@"; controller_image=$2; shift 2 ;;
    --runtime-image) need_value "$@"; runtime_image=$2; shift 2 ;;
    --auth-base-url) need_value "$@"; auth_base_url=$2; shift 2 ;;
    --agent-domain) need_value "$@"; agent_domain=$2; shift 2 ;;
    --admin-email) need_value "$@"; admin_email=$2; shift 2 ;;
    --runtime-storage-class) need_value "$@"; runtime_storage_class=$2; shift 2 ;;
    --pod-cidr) need_value "$@"; pod_cidr=$2; shift 2 ;;
    --cluster-api-cidr) need_value "$@"; cluster_api_cidrs+=("$2"); shift 2 ;;
    --state-dir) need_value "$@"; state_dir=$2; shift 2 ;;
    --receipt) need_value "$@"; receipt=$2; shift 2 ;;
    --namespace) need_value "$@"; namespace=$2; shift 2 ;;
    --release) need_value "$@"; release=$2; shift 2 ;;
    --wait-timeout) need_value "$@"; wait_timeout=$2; shift 2 ;;
    --validation-postgres) validation_postgres=true; shift ;;
    --validation-postgres-image)
      need_value "$@"; validation_postgres_image=$2; shift 2
      ;;
    --database-app-url-file)
      need_value "$@"; database_app_url_file=$2; shift 2
      ;;
    --database-migration-url-file)
      need_value "$@"; database_migration_url_file=$2; shift 2
      ;;
    --database-ca-file)
      need_value "$@"; database_ca_file=$2; shift 2
      ;;
    --database-cidr) need_value "$@"; database_cidrs+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unsupported argument $1." ;;
  esac
done

require_input_validator

[[ "$aws_account_id" =~ ^[0-9]{12}$ ]] ||
  die "--aws-account-id must be a 12-digit AWS account ID."
[[ "$aws_region" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
  die "--aws-region must be an AWS region name."
[[ "$eks_cluster_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] ||
  die "--eks-cluster-name is invalid."
[[ -n "$kube_context" && "$kube_context" != *$'\n'* ]] ||
  die "--kube-context is required and must fit on one line."
[[ "$auth_base_url" =~ ^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$ ]] ||
  die "--auth-base-url must be a lowercase HTTPS origin without a path."
is_dns_subdomain "$agent_domain" ||
  die "--agent-domain must be a lowercase DNS domain."
[[ "$admin_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
  die "--admin-email is invalid."
is_dns_subdomain "$runtime_storage_class" ||
  die "--runtime-storage-class must be a Kubernetes DNS subdomain."
is_dns_label "$namespace" || die "--namespace must be a Kubernetes DNS label."
is_dns_label "$release" || die "--release must be a Kubernetes DNS label."
[[ "$wait_timeout" =~ ^[1-9][0-9]*[smh]$ ]] ||
  die "--wait-timeout must be a positive duration such as 5m."
[[ -n "$state_dir" && -n "$receipt" ]] ||
  die "--state-dir and --receipt are required."
[[ "$state_dir" = /* && "$receipt" = /* ]] ||
  die "--state-dir and --receipt must be absolute paths."
require_ipv4_cidr --pod-cidr "$pod_cidr" false
((${#cluster_api_cidrs[@]} > 0)) ||
  die "at least one --cluster-api-cidr is required."
for cidr in "${cluster_api_cidrs[@]}"; do
  require_ipv4_cidr --cluster-api-cidr "$cidr" true
done
require_immutable_image --controller-image "$controller_image"
require_immutable_image --runtime-image "$runtime_image"

if [[ -n "$occ_binary" && "$build_occ" == true ]] ||
  [[ -z "$occ_binary" && "$build_occ" != true ]]; then
  die "choose exactly one of --occ-binary or --build-occ."
fi

if [[ "$validation_postgres" == true ]]; then
  [[ -z "$database_app_url_file" && -z "$database_migration_url_file" &&
    -z "$database_ca_file" && ${#database_cidrs[@]} -eq 0 ]] ||
    die "--validation-postgres cannot be combined with external database inputs."
  require_immutable_image --validation-postgres-image "$validation_postgres_image"
else
  [[ -z "$validation_postgres_image" ]] ||
    die "--validation-postgres-image requires --validation-postgres."
  [[ -n "$database_app_url_file" && -n "$database_migration_url_file" &&
    -n "$database_ca_file" &&
    ${#database_cidrs[@]} -gt 0 ]] ||
    die "external database mode requires both URL files, --database-ca-file, and at least one --database-cidr."
  require_private_file --database-app-url-file "$database_app_url_file"
  require_private_file --database-migration-url-file "$database_migration_url_file"
  require_private_file --database-ca-file "$database_ca_file"
  for cidr in "${database_cidrs[@]}"; do
    require_ipv4_cidr --database-cidr "$cidr" true
  done
fi

for prerequisite in aws kubectl helm git go openssl base64 python3 install mktemp sed grep tr stat jq; do
  require_command "$prerequisite"
done
require_helm_3

[[ -d "$oce_source" && ! -L "$oce_source" ]] ||
  die "--oce-source must be a source directory, not a symlink."
source_head=$(git -C "$oce_source" rev-parse --verify HEAD 2>/dev/null) ||
  die "--oce-source is not a Git checkout."
[[ "$source_head" == "$OCE_SOURCE_PIN" ]] ||
  die "unpinned OCE source: expected $OCE_SOURCE_PIN, found $source_head."
[[ -z "$(git -C "$oce_source" status --porcelain --untracked-files=all)" ]] ||
  die "OCE source checkout is modified; use a clean checkout of the pinned revision."
chart_dir="$oce_source/deploy/helm/openclaw-enterprise"
[[ -f "$chart_dir/Chart.yaml" && -f "$oce_source/cmd/occ/main.go" ]] ||
  die "pinned source is missing the OCC command or Helm chart."

[[ -f "$kubeconfig" && ! -L "$kubeconfig" && -r "$kubeconfig" ]] ||
  die "--kubeconfig must be a readable regular file, not a symlink."
require_private_file --kubeconfig "$kubeconfig"

[[ ! -e "$state_dir" || ( -d "$state_dir" && ! -L "$state_dir" ) ]] ||
  die "--state-dir must be a directory, not a symlink."
install -d -m 700 "$state_dir"
[[ -O "$state_dir" ]] || die "--state-dir must be owned by the current user."
chmod 700 "$state_dir"
state_dir=$(python3 -c \
  'import os,sys; print(os.path.realpath(sys.argv[1]))' "$state_dir")
receipt=$(python3 -c \
  'import os,sys; print(os.path.realpath(sys.argv[1]))' "$receipt")
[[ "$receipt" == "$state_dir/"* ]] ||
  die "--receipt must be below --state-dir."

# One install at a time per state directory: a second run would race this one's receipt, journal and cluster
# changes. A hard kill leaves the lock; remove it only after confirming no install is running.
install_lock="$state_dir/.install-oce.lock"
install_lock_acquired=false
install_lock_token=
release_install_lock() {
  [[ "$install_lock_acquired" == true ]] || return 0
  local owner_file="$install_lock/owner"
  if [[ -f "$owner_file" && ! -L "$owner_file" && "$(<"$owner_file")" == "$install_lock_token" ]]; then
    rm -f -- "$owner_file"
    rmdir -- "$install_lock" 2>/dev/null || true
  else
    printf 'install-oce: install lock ownership changed; preserving %s.\n' "$install_lock" >&2
  fi
  install_lock_acquired=false
}
[[ ! -L "$install_lock" ]] ||
  die "install lock must not be a symbolic link: $install_lock."
install_lock_token=$(openssl rand -hex 32) ||
  die "could not generate the install lock token."
mkdir -- "$install_lock" 2>/dev/null ||
  die "state directory is already in use or has a stale install lock: $install_lock."
install_lock_acquired=true
trap release_install_lock EXIT
chmod 700 "$install_lock" ||
  die "could not secure the install lock $install_lock."
printf '%s\n' "$install_lock_token" >"$install_lock/owner" ||
  die "could not record the install lock owner."
chmod 600 "$install_lock/owner" ||
  die "could not secure the install lock owner."

database_app_url_value="$state_dir/database-application-url"
database_migration_url_value="$state_dir/database-migration-url"
database_ca_value="$state_dir/database-ca.pem"
handoff_state="$state_dir/bootstrap-handoff-state.json"
if [[ "$validation_postgres" != true ]]; then
  install_postgres_url --database-app-url-file \
    "$database_app_url_file" "$database_app_url_value"
  install_postgres_url --database-migration-url-file \
    "$database_migration_url_file" "$database_migration_url_value"
  install_ca_bundle --database-ca-file "$database_ca_file" "$database_ca_value"
fi

if [[ "$build_occ" == true ]]; then
  occ_binary="$state_dir/occ-$OCE_SOURCE_PIN"
  if [[ ! -e "$occ_binary" ]]; then
    occ_tmp=$(mktemp "$state_dir/.occ.XXXXXXXX")
    trap 'rm -f "${occ_tmp:-}"; release_install_lock' EXIT
    (
      cd "$oce_source"
      CGO_ENABLED=0 go build -trimpath -buildvcs=true -o "$occ_tmp" ./cmd/occ
    )
    chmod 700 "$occ_tmp"
    mv "$occ_tmp" "$occ_binary"
    occ_tmp=
  fi
fi
verify_occ_binary "$occ_binary"

if env | grep -Eq '^HELM_KUBE[^=]*=.'; then
  die "nonempty HELM_KUBE* environment overrides are not allowed."
fi
case "${HELM_DRIVER:-secret}" in
  secret|secrets) ;;
  *) die "HELM_DRIVER must be unset, secret, or secrets." ;;
esac

actual_account=$(aws sts get-caller-identity --query Account --output text)
[[ "$actual_account" == "$aws_account_id" ]] ||
  die "wrong AWS account: expected $aws_account_id, authenticated as $actual_account."
cluster_arn=$(aws eks describe-cluster --region "$aws_region" \
  --name "$eks_cluster_name" --query cluster.arn --output text)
[[ "$cluster_arn" =~ ^arn:[^:]+:eks:${aws_region}:${aws_account_id}:cluster/${eks_cluster_name}$ ]] ||
  die "EKS ARN does not match the requested account, region, and cluster: $cluster_arn."
cluster_status=$(aws eks describe-cluster --region "$aws_region" \
  --name "$eks_cluster_name" --query cluster.status --output text)
[[ "$cluster_status" == "ACTIVE" ]] ||
  die "EKS cluster $eks_cluster_name is not ACTIVE (status: $cluster_status)."
cluster_service_ipv4_cidr=$(aws eks describe-cluster --region "$aws_region" \
  --name "$eks_cluster_name" \
  --query cluster.kubernetesNetworkConfig.serviceIpv4Cidr --output text)
cluster_dns_cidr=$(derive_eks_cluster_dns_cidr "$cluster_service_ipv4_cidr")
cluster_api_service_cidr=$(
  derive_eks_cluster_api_service_cidr "$cluster_service_ipv4_cidr"
)
cluster_api_service_cidr_present=false
for cidr in "${cluster_api_cidrs[@]}"; do
  if [[ "$cidr" == "$cluster_api_service_cidr" ]]; then
    cluster_api_service_cidr_present=true
    break
  fi
done
if [[ "$cluster_api_service_cidr_present" != true ]]; then
  cluster_api_cidrs+=("$cluster_api_service_cidr")
fi
write_private_text "$state_dir/cluster-dns-cidr" "$cluster_dns_cidr"
write_private_text \
  "$state_dir/cluster-api-service-cidr" "$cluster_api_service_cidr"
if [[ "$validation_postgres" == true ]]; then
  cluster_tags=$(aws eks list-tags-for-resource --region "$aws_region" \
    --resource-arn "$cluster_arn" --query tags --output json)
  require_validation_cluster_tags "$cluster_tags"
fi
cluster_endpoint=$(aws eks describe-cluster --region "$aws_region" \
  --name "$eks_cluster_name" --query cluster.endpoint --output text)
[[ "$cluster_endpoint" == https://* ]] ||
  die "EKS cluster returned an invalid endpoint."

context_name=$(kubectl --kubeconfig "$kubeconfig" config get-contexts \
  "$kube_context" -o name)
[[ "$context_name" == "$kube_context" ]] ||
  die "kube context $kube_context does not exist in $kubeconfig."
context_endpoint=$(kubectl --kubeconfig "$kubeconfig" config view --raw --minify \
  --context "$kube_context" -o 'jsonpath={.clusters[0].cluster.server}')
[[ "$context_endpoint" == "$cluster_endpoint" ]] ||
  die "kube context endpoint does not match EKS cluster $eks_cluster_name."
# The endpoint alone does not identify the cluster's API server; its CA must match too.
cluster_ca=$(aws eks describe-cluster --region "$aws_region" \
  --name "$eks_cluster_name" --query cluster.certificateAuthority.data --output text)
[[ "$cluster_ca" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
  die "EKS cluster returned an invalid certificate authority."
context_ca=$(kubectl --kubeconfig "$kubeconfig" config view --raw --minify --flatten \
  --context "$kube_context" -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}')
[[ "$context_ca" == "$cluster_ca" ]] ||
  die "kube context certificate authority does not match EKS cluster $eks_cluster_name."

KUBE=(kubectl --kubeconfig "$kubeconfig" --context "$kube_context" --request-timeout=20s)
HELM_RELEASE_STATES=(
  --deployed
  --failed
  --pending
  --uninstalled
  --superseded
  --uninstalling
)
"${KUBE[@]}" get namespace kube-system -o name >/dev/null ||
  die "cannot reach kube-system through the selected context."
require_storage_class_contract
require_network_policy_enforcement

release_names=$(helm list --kubeconfig "$kubeconfig" --kube-context "$kube_context" \
  --namespace "$namespace" "${HELM_RELEASE_STATES[@]}" --short)
deployed_release_names=$(helm list --kubeconfig "$kubeconfig" \
  --kube-context "$kube_context" --namespace "$namespace" --deployed --short)
marker="$state_dir/install.complete"
resume_handoff=false
if grep -Fqx "$release" <<<"$release_names"; then
  grep -Fqx "$release" <<<"$deployed_release_names" ||
    die "Helm release $release exists but is not deployed; refusing bootstrap recovery."
  if [[ -f "$marker" && ! -L "$marker" && -d "$receipt" &&
    -f "$receipt/resources.json" && ! -L "$receipt/resources.json" ]]; then
    if ! grep -Fqx "source=$OCE_SOURCE_PIN" "$marker" ||
      ! grep -Fqx "cluster_arn=$cluster_arn" "$marker" ||
      ! grep -Fqx "context=$kube_context" "$marker" ||
      ! grep -Fqx "namespace=$namespace" "$marker" ||
      ! grep -Fqx "release=$release" "$marker"; then
      die "existing release $release does not match this install request."
    fi
    validate_occ_receipt
    require_deployed_release_attempt
    printf 'OpenClaw Enterprise release %s is already installed with matching evidence.\n' "$release"
    exit 0
  fi
  [[ -d "$receipt" && ! -L "$receipt" &&
    -f "$receipt/intent.json" && ! -L "$receipt/intent.json" &&
    -f "$handoff_state" && ! -L "$handoff_state" ]] ||
    die "Helm release $release exists without resumable handoff evidence."
  load_handoff_state
  validate_occ_receipt
  require_deployed_release_attempt
  case "$handoff_phase" in
    volume-ready)
      [[ -z "$occ_attempt" || "$occ_attempt" == "$occ_receipt_attempt" ]] ||
        die "bootstrap handoff journal does not match the OCC receipt attempt."
      occ_attempt=$occ_receipt_attempt
      write_handoff_state installed
      ;;
    installed|handoff-pod-ready|credentials-local|credentials-erased|\
      pod-deleted|job-deleted|pvc-deleted|pv-deleted)
      [[ "$occ_attempt" == "$occ_receipt_attempt" ]] ||
        die "bootstrap handoff journal does not match the OCC receipt attempt."
      ;;
    *)
      die "bootstrap handoff journal does not prove OCC reached the deployed release."
      ;;
  esac
  [[ -n "$bootstrap_job_uid" && -n "$bootstrap_pvc_uid" &&
    -n "$bootstrap_pv" && -n "$bootstrap_pv_uid" ]] ||
    die "bootstrap handoff journal is missing bound resource identities."
  require_kubernetes_uid "bootstrap preparation Job" "$bootstrap_job_uid"
  require_kubernetes_uid "bootstrap output PVC" "$bootstrap_pvc_uid"
  is_dns_subdomain "$bootstrap_pv" ||
    die "bootstrap handoff journal contains an invalid persistent volume name."
  require_kubernetes_uid "bootstrap output PV" "$bootstrap_pv_uid"
  [[ -z "$bootstrap_pod_uid" ]] ||
    require_kubernetes_uid "bootstrap handoff Pod" "$bootstrap_pod_uid"
  resume_handoff=true
else
  ! grep -Fqx "$release" <<<"$deployed_release_names" ||
    die "Helm deployed-release lookup disagrees with the all-state lookup."
  [[ ! -e "$marker" ]] ||
    die "release is absent but completion evidence exists; inspect the prior OCC attempt."
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    if [[ -d "$receipt" && ! -L "$receipt" &&
      -f "$receipt/intent.json" && ! -L "$receipt/intent.json" &&
      ! -e "$receipt/dispatch.json" && ! -L "$receipt/dispatch.json" ]]; then
      die "release is unused and the OCC receipt records an undispatched intent. Preserve it and rerun with a new --receipt directory after confirming the original OCC process exited."
    fi
    die "release is absent but the OCC receipt may record a dispatched attempt. Preserve it and reconcile the original attempt with occ installation plan; do not retry."
  fi
  if [[ -e "$handoff_state" || -L "$handoff_state" ]]; then
    load_handoff_state
  else
    bootstrap_pod_receipt=$(openssl rand -hex 32)
    [[ "$bootstrap_pod_receipt" =~ ^[a-f0-9]{64}$ ]] ||
      die "could not generate a valid bootstrap handoff receipt."
    write_handoff_state prepared
  fi
fi

if [[ "$resume_handoff" != true ]]; then
namespace_manifest="$state_dir/namespace.yaml"
write_private "$namespace_manifest" printf '%s\n' \
"apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL"

set +e
namespace_get=$("${KUBE[@]}" get namespace "$namespace" -o name 2>&1)
namespace_status=$?
set -e
if ((namespace_status == 0)); then
  namespace_owner=$("${KUBE[@]}" get namespace "$namespace" \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')
  [[ "$namespace_owner" == "$OWNER_LABEL" ]] ||
    die "refusing to use existing namespace/$namespace without managed-by=$OWNER_LABEL."
elif kubectl_error_is_not_found "$namespace_get"; then
  "${KUBE[@]}" apply --server-side --field-manager="$OWNER_LABEL" \
    -f "$namespace_manifest" >/dev/null
else
  die "could not inspect namespace/$namespace: $namespace_get"
fi

cluster_dns_policy="$state_dir/eks-cluster-dns-network-policy.yaml"
write_private "$cluster_dns_policy" printf '%s\n' \
"apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: oce-eks-cluster-dns
  namespace: $namespace
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: openclaw-enterprise
      app.kubernetes.io/instance: $release
    matchExpressions:
      - key: app.kubernetes.io/component
        operator: In
        values:
          - api
          - worker
          - initialization
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: $cluster_dns_cidr
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53"
apply_owned_resource \
  networkpolicy.networking.k8s.io oce-eks-cluster-dns "$cluster_dns_policy"

auth_secret_value="$state_dir/auth-secret"
if [[ ! -e "$auth_secret_value" ]]; then
  auth_secret=$(openssl rand -hex 32)
  write_private_text "$auth_secret_value" "$auth_secret"
fi
normalize_hex_secret "generated auth secret" "$auth_secret_value" 64

validation_manifest="$state_dir/oce-validation-postgres.yaml"
if [[ "$validation_postgres" == true ]]; then
  printf 'WARNING: using single-instance, validation-only PostgreSQL on sample-managed EBS storage.\n' >&2
  validation_password="$state_dir/validation-postgres-password"
  validation_migration_password="$state_dir/validation-postgres-migration-password"
  validation_app_password="$state_dir/validation-postgres-app-password"
  if [[ ! -e "$validation_password" ]]; then
    generated_password=$(openssl rand -hex 24)
    write_private_text "$validation_password" "$generated_password"
  fi
  if [[ ! -e "$validation_migration_password" ]]; then
    generated_password=$(openssl rand -hex 24)
    write_private_text "$validation_migration_password" "$generated_password"
  fi
  if [[ ! -e "$validation_app_password" ]]; then
    generated_password=$(openssl rand -hex 24)
    write_private_text "$validation_app_password" "$generated_password"
  fi
  normalize_hex_secret \
    "generated validation PostgreSQL password" "$validation_password" 48
  normalize_hex_secret \
    "generated validation PostgreSQL migration password" \
    "$validation_migration_password" 48
  normalize_hex_secret \
    "generated validation PostgreSQL application password" \
    "$validation_app_password" 48
  migration_password=$(<"$validation_migration_password")
  app_password=$(<"$validation_app_password")
  write_private_text "$database_app_url_value" \
    "postgresql://occ_app:${app_password}@oce-validation-only-postgres:5432/openclaw?sslmode=disable" # pragma: allowlist secret -- generated validation credential
  write_private_text "$database_migration_url_value" \
    "postgresql://occ_migrator:${migration_password}@oce-validation-only-postgres:5432/openclaw?sslmode=disable" # pragma: allowlist secret -- generated validation credential

  validation_secret="$state_dir/validation-postgres-secret.yaml"
  validation_init_sql="$state_dir/validation-postgres-init.sql"
  write_private "$validation_init_sql" printf '%s\n' \
"CREATE ROLE occ_migrator LOGIN PASSWORD '$migration_password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE ROLE occ_app LOGIN PASSWORD '$app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT CREATE ON DATABASE openclaw TO occ_migrator;
CREATE SCHEMA occ AUTHORIZATION occ_migrator;
CREATE SCHEMA drizzle AUTHORIZATION occ_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
  validation_password_b64=$(base64_one_line "$validation_password")
  validation_init_sql_b64=$(base64_one_line "$validation_init_sql")
  write_private "$validation_secret" printf '%s\n' \
"apiVersion: v1
kind: Secret
metadata:
  name: oce-validation-only-postgres
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
    app.kubernetes.io/component: validation-only-database
  annotations:
    openclaw.dev/validation-only: \"true\"
type: Opaque
data:
  password: $validation_password_b64
  init.sql: $validation_init_sql_b64"
  apply_owned_resource secret oce-validation-only-postgres "$validation_secret"

  script_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  validation_template="$script_root/deploy/oce-validation-postgres.yaml"
  [[ -f "$validation_template" ]] ||
    die "missing validation PostgreSQL manifest $validation_template."
  sed \
    -e "s|$VALIDATION_POSTGRES_TOKEN|$validation_postgres_image|g" \
    -e "s|$VALIDATION_POSTGRES_STORAGE_TOKEN|$runtime_storage_class|g" \
    "$validation_template" >"$validation_manifest"
  chmod 600 "$validation_manifest"
  if grep -Fq "$VALIDATION_POSTGRES_TOKEN" "$validation_manifest" ||
    grep -Fq "$VALIDATION_POSTGRES_STORAGE_TOKEN" "$validation_manifest"; then
    die "validation PostgreSQL manifest placeholders were not replaced."
  fi
  resource_is_owned persistentvolumeclaim oce-validation-only-postgres || true
  resource_is_owned deployment oce-validation-only-postgres || true
  resource_is_owned service oce-validation-only-postgres || true
  "${KUBE[@]}" --namespace "$namespace" apply \
    --server-side --field-manager="$OWNER_LABEL" -f "$validation_manifest" >/dev/null
  "${KUBE[@]}" --namespace "$namespace" rollout status \
    deployment/oce-validation-only-postgres --timeout=120s
  require_validation_postgres_version "$namespace"
  require_validation_postgres_role_contract "$namespace"
  database_service_ip=$("${KUBE[@]}" --namespace "$namespace" get \
    service oce-validation-only-postgres -o 'jsonpath={.spec.clusterIP}')
  require_ipv4_cidr \
    "validation PostgreSQL Service IP" "$database_service_ip/32" true
  database_cidrs=("$database_service_ip/32")
fi

if [[ "$validation_postgres" != true ]]; then
  database_ca_b64=$(base64_one_line "$database_ca_value")
  database_ca_secret="$state_dir/database-ca-secret.yaml"
  write_private "$database_ca_secret" printf '%s\n' \
"apiVersion: v1
kind: Secret
metadata:
  name: $DATABASE_CA_SECRET
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
    app.kubernetes.io/component: database-ca
type: Opaque
data:
  $DATABASE_CA_KEY: $database_ca_b64"
  apply_owned_resource secret "$DATABASE_CA_SECRET" "$database_ca_secret"
fi

installation_yaml="$state_dir/installation.yaml"
{
  printf '%s\n' \
"occ:
  cluster: \"$eks_cluster_name\"
backend: []
presets:
  includeDefaults: false
drivers:
  plugin:
    - id: codex-plugin
      configuration:
        catalogSource: openai-curated
  configuration:
    id: config-kubernetes
    configuration:
      authentication:
        mode: inCluster
  iam:
    id: native-iam
    configuration: {}
  compute:
    id: compute-kubernetes
    configuration:
      authentication:
        mode: inCluster
      images:
        gateway: \"$runtime_image\"
        agent: \"$runtime_image\"
        requireImmutableDigest: true
      resources:
        gateway:
          requests: { cpu: 100m, memory: 2560Mi }
          limits: { cpu: \"4\", memory: 4Gi }
        agent:
          requests: { cpu: 100m, memory: 768Mi }
          limits: { cpu: \"4\", memory: 6Gi }
        namespace:
          quota: { pods: \"10\" }
          containerDefaults:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: \"4\", memory: 2Gi }
      network:
        dns:
          namespace: kube-system
          podLabels:
            k8s-app: kube-dns
        gatewayPort: 8080
        gatewayTrustedProxyCidrs:
          - \"$pod_cidr\"
        gatewayClients:
          - namespace: \"$namespace\"
            podLabels:
              app.kubernetes.io/name: oce-direct-pod-api-clients-disabled
              openclaw.dev/direct-pod-api-client: disabled
      servicePrincipalCredentials:
        mode: projectedServiceAccountToken
        audience: openclaw-enterprise
        expirationSeconds: 900
      runtime:
        modelProvider:
          protocol: \"$MODEL_PROVIDER_PROTOCOL\"
          baseUrl: \"$MODEL_PROVIDER_BASE_URL\"
        gatewayStorageClassName: \"$runtime_storage_class\"
        nativeOpenClawSessionCapacity: 8
        transportSecretPrefix: openclaw-agent-transport
  secret:
    id: secret-kubernetes
    configuration:
      authentication:
        mode: inCluster"
} >"$installation_yaml"
chmod 600 "$installation_yaml"

values_yaml="$state_dir/values.yaml"
{
  printf '%s\n' \
"images:
  controller: \"$controller_image\"
metrics:
  enabled: false
installation:
  name: openclaw-enterprise
  secretName: oce-sample-installation-startup
  key: installation.yaml
auth:
  baseUrl: \"$auth_base_url\"
  secretName: oce-sample-auth
  secretKey: secret
agentNativeAdmin:
  enabled: false
  sessionMode: shared-cookie
  domain: \"$agent_domain\"
agentRuntimeLogs:
  enabled: false
bootstrap:
  adminEmail: \"$admin_email\"
  password:
    claimName: oce-sample-bootstrap-output
    mountPath: /var/lib/openclaw/bootstrap
    fileName: initial-admin-password
  serviceKey:
    fileName: initial-admin-service-key.json
database:
  secretName: oce-sample-database
  appUrlKey: application-url
  migrationUrlKey: migration-url
  cidrs:"
  for cidr in "${database_cidrs[@]}"; do
    printf '    - "%s"\n' "$cidr"
  done
  if [[ "$validation_postgres" != true ]]; then
    printf '%s\n' \
"  caSecretName: $DATABASE_CA_SECRET
  caKey: $DATABASE_CA_KEY
  caMountPath: $DATABASE_CA_MOUNT_PATH"
  fi
  printf '%s\n' \
"  port: 5432
api:
  clients:
    - namespace: \"$namespace\"
      podLabels:
        app.kubernetes.io/name: oce-direct-pod-api-clients-disabled
        openclaw.dev/direct-pod-api-client: disabled
cluster:
  cidrs:"
  for cidr in "${cluster_api_cidrs[@]}"; do
    printf '    - "%s"\n' "$cidr"
  done
  printf '%s\n' \
"  port: 443
gatewayRouting:
  enabled: false
worker:
  replicaCount: 1"
} >"$values_yaml"
chmod 600 "$values_yaml"

installation_b64=$(base64_one_line "$installation_yaml")
database_app_b64=$(base64_one_line "$database_app_url_value")
database_migration_b64=$(base64_one_line "$database_migration_url_value")
auth_b64=$(base64_one_line "$auth_secret_value")
system_secrets="$state_dir/system-secrets.yaml"
write_private "$system_secrets" printf '%s\n' \
"apiVersion: v1
kind: Secret
metadata:
  name: oce-sample-installation-startup
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
type: Opaque
data:
  installation.yaml: $installation_b64
---
apiVersion: v1
kind: Secret
metadata:
  name: oce-sample-database
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
type: Opaque
data:
  application-url: $database_app_b64
  migration-url: $database_migration_b64
---
apiVersion: v1
kind: Secret
metadata:
  name: oce-sample-auth
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
type: Opaque
data:
  secret: $auth_b64"
resource_is_owned secret oce-sample-installation-startup || true
resource_is_owned secret oce-sample-database || true
resource_is_owned secret oce-sample-auth || true
"${KUBE[@]}" --namespace "$namespace" apply \
  --server-side --field-manager="$OWNER_LABEL" -f "$system_secrets" >/dev/null

bootstrap_resources="$state_dir/bootstrap-resources.yaml"
write_private "$bootstrap_resources" printf '%s\n' \
"apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: oce-sample-bootstrap-output
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
    app.kubernetes.io/component: bootstrap-output
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: \"$runtime_storage_class\"
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: oce-sample-bootstrap-volume-prep
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
    app.kubernetes.io/component: bootstrap-volume-preparation
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: $OWNER_LABEL
        app.kubernetes.io/part-of: $OWNER_LABEL
        app.kubernetes.io/component: bootstrap-volume-preparation
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      restartPolicy: Never
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: prepare
          image: \"$controller_image\"
          command: [node]
          args:
            - -e
            - |
              const fs = require('node:fs');
              const root = '/bootstrap';
              const entries = fs.readdirSync(root, {withFileTypes: true});
              if (entries.some((entry) => entry.name !== 'lost+found')) {
                throw new Error('bootstrap output volume is not fresh');
              }
              fs.chownSync(root, 1000, 1000);
              fs.chmodSync(root, 0o700);
              const stat = fs.statSync(root);
              if (stat.uid !== 1000 || stat.gid !== 1000 ||
                  (stat.mode & 0o777) !== 0o700) {
                throw new Error('bootstrap output ownership verification failed');
              }
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
              add: [CHOWN, FOWNER]
          volumeMounts:
            - name: output
              mountPath: /bootstrap
      volumes:
        - name: output
          persistentVolumeClaim:
            claimName: oce-sample-bootstrap-output"
resource_is_owned persistentvolumeclaim oce-sample-bootstrap-output || true
if resource_is_owned job oce-sample-bootstrap-volume-prep; then
  prep_status=$("${KUBE[@]}" --namespace "$namespace" get \
    job/oce-sample-bootstrap-volume-prep -o 'jsonpath={.status.succeeded}')
  [[ "$prep_status" == "1" ]] ||
    die "existing bootstrap preparation Job has not succeeded; inspect it before retrying."
fi
"${KUBE[@]}" --namespace "$namespace" apply \
  --server-side --field-manager="$OWNER_LABEL" -f "$bootstrap_resources" >/dev/null
"${KUBE[@]}" --namespace "$namespace" wait \
  --for=condition=complete job/oce-sample-bootstrap-volume-prep --timeout=120s

previous_job_uid=$bootstrap_job_uid
inspect_owned_resource job oce-sample-bootstrap-volume-prep "$OWNER_LABEL"
[[ "$INSPECTED_RESOURCE_PRESENT" == true ]] ||
  die "bootstrap preparation Job disappeared before installation."
[[ -z "$previous_job_uid" || "$previous_job_uid" == "$INSPECTED_RESOURCE_UID" ]] ||
  die "bootstrap preparation Job was replaced during a retry."
bootstrap_job_uid=$INSPECTED_RESOURCE_UID

previous_pvc_uid=$bootstrap_pvc_uid
inspect_owned_resource persistentvolumeclaim oce-sample-bootstrap-output "$OWNER_LABEL"
[[ "$INSPECTED_RESOURCE_PRESENT" == true ]] ||
  die "bootstrap output PVC disappeared before installation."
[[ -z "$previous_pvc_uid" || "$previous_pvc_uid" == "$INSPECTED_RESOURCE_UID" ]] ||
  die "bootstrap output PVC was replaced during a retry."
bootstrap_pvc_uid=$INSPECTED_RESOURCE_UID
bootstrap_pv=$(jq -er '.spec.volumeName' <<<"$INSPECTED_RESOURCE_JSON") ||
  die "could not identify the bootstrap output volume."
is_dns_subdomain "$bootstrap_pv" ||
  die "bootstrap output claim reported an invalid persistent volume name."

bootstrap_pv_json=$("${KUBE[@]}" get "persistentvolume/$bootstrap_pv" -o json) ||
  die "could not inspect bootstrap output persistentvolume/$bootstrap_pv."
current_pv_uid=$(jq -er '.metadata.uid' <<<"$bootstrap_pv_json") ||
  die "bootstrap output persistent volume is missing its UID."
require_kubernetes_uid "bootstrap output persistent volume" "$current_pv_uid"
[[ -z "$bootstrap_pv_uid" || "$bootstrap_pv_uid" == "$current_pv_uid" ]] ||
  die "bootstrap output persistent volume was replaced during a retry."
bootstrap_pv_uid=$current_pv_uid
jq -e \
  --arg name "$bootstrap_pv" \
  --arg storage_class "$runtime_storage_class" \
  --arg namespace "$namespace" \
  --arg pvc_uid "$bootstrap_pvc_uid" \
  '
    .metadata.name == $name
    and .spec.storageClassName == $storage_class
    and .spec.persistentVolumeReclaimPolicy == "Delete"
    and .spec.csi.driver == "ebs.csi.eks.amazonaws.com"
    and .spec.claimRef.namespace == $namespace
    and .spec.claimRef.name == "oce-sample-bootstrap-output"
    and .spec.claimRef.uid == $pvc_uid
  ' <<<"$bootstrap_pv_json" >/dev/null ||
  die "bootstrap output persistent volume does not match the encrypted EBS deletion contract."
write_handoff_state volume-ready

rendered="$state_dir/rendered.yaml"
helm template "$release" "$chart_dir" --namespace "$namespace" \
  --values "$values_yaml" \
  --set-string 'installation.attemptId=preflight-not-an-install-attempt' >"$rendered"
chmod 600 "$rendered"

"$occ_binary" installation install \
  --release "$release" \
  --chart "$chart_dir" \
  --kubeconfig "$kubeconfig" \
  --context "$kube_context" \
  --kube-namespace "$namespace" \
  --values "$values_yaml" \
  --receipt "$receipt" \
  --wait-timeout "$wait_timeout"
post_occ_deployed_releases=$(helm list --kubeconfig "$kubeconfig" \
  --kube-context "$kube_context" --namespace "$namespace" --deployed --short)
grep -Fqx "$release" <<<"$post_occ_deployed_releases" ||
  die "OCC returned without a deployed Helm release $release."
validate_occ_receipt
require_deployed_release_attempt
occ_attempt=$occ_receipt_attempt
write_handoff_state installed
fi

bootstrap_key="$state_dir/initial-admin-service-key.json"
bootstrap_password="$state_dir/initial-admin-password"

bootstrap_handoff="$state_dir/bootstrap-handoff.yaml"
write_private "$bootstrap_handoff" printf '%s\n' \
"apiVersion: v1
kind: Pod
metadata:
  name: oce-sample-bootstrap-handoff
  namespace: $namespace
  annotations:
    openclaw.dev/bootstrap-handoff-receipt: \"$bootstrap_pod_receipt\"
  labels:
    app.kubernetes.io/managed-by: $OWNER_LABEL
    app.kubernetes.io/part-of: $OWNER_LABEL
    app.kubernetes.io/component: bootstrap-handoff
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: handoff
      image: \"$controller_image\"
      imagePullPolicy: IfNotPresent
      command: [node]
      args: [-e, \"setInterval(() => {}, 300000)\"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: bootstrap
          mountPath: /bootstrap
  volumes:
    - name: bootstrap
      persistentVolumeClaim:
        claimName: oce-sample-bootstrap-output"

(
  bootstrap_reader_live=false
  remote_erasure_recorded=false
  bootstrap_key_tmp=
  bootstrap_password_tmp=
  bootstrap_create_error=
  cleanup_bootstrap_handoff() {
    trap - EXIT
    rm -f "${bootstrap_key_tmp:-}" "${bootstrap_password_tmp:-}" \
      "${bootstrap_create_error:-}"
    if [[ "$bootstrap_reader_live" == true &&
      "$remote_erasure_recorded" == true &&
      -n "$bootstrap_pod_uid" ]]; then
      set +e
      cleanup_pod=$("${KUBE[@]}" --namespace "$namespace" get \
        pod oce-sample-bootstrap-handoff -o json 2>/dev/null)
      cleanup_status=$?
      set -e
      if ((cleanup_status == 0)); then
        cleanup_owner=$(jq -r \
          '.metadata.labels["app.kubernetes.io/managed-by"] // ""' \
          <<<"$cleanup_pod")
        cleanup_uid=$(jq -r '.metadata.uid // ""' <<<"$cleanup_pod")
        cleanup_resource_version=$(jq -r \
          '.metadata.resourceVersion // ""' <<<"$cleanup_pod")
        if [[ "$cleanup_owner" == "$OWNER_LABEL" &&
          "$cleanup_uid" == "$bootstrap_pod_uid" &&
          -n "$cleanup_resource_version" ]] &&
          bootstrap_handoff_contract_matches "$cleanup_pod"; then
          cleanup_delete_options=$(jq -cn \
            --arg uid "$cleanup_uid" \
            --arg resource_version "$cleanup_resource_version" \
            '{
              apiVersion: "v1",
              kind: "DeleteOptions",
              propagationPolicy: "Background",
              preconditions: {
                uid: $uid,
                resourceVersion: $resource_version
              }
            }')
          "${KUBE[@]}" --namespace "$namespace" delete \
            --raw="/api/v1/namespaces/$namespace/pods/oce-sample-bootstrap-handoff" \
            -f - <<<"$cleanup_delete_options" >/dev/null 2>&1 || true
        fi
      fi
      set -e
    fi
  }
  trap cleanup_bootstrap_handoff EXIT

  bootstrap_key_local=false
  if [[ -e "$bootstrap_key" || -L "$bootstrap_key" ]]; then
    require_private_file "local bootstrap service key" "$bootstrap_key"
    jq -e '.data.key | type == "string" and length > 0' \
      "$bootstrap_key" >/dev/null ||
      die "local bootstrap service key has an invalid format."
    bootstrap_key_local=true
  fi
  bootstrap_password_local=false
  if [[ -e "$bootstrap_password" || -L "$bootstrap_password" ]]; then
    require_private_file "local bootstrap password" "$bootstrap_password"
    [[ -s "$bootstrap_password" ]] ||
      die "local bootstrap password is empty."
    bootstrap_password_local=true
  fi

  case "$handoff_phase" in
    credentials-erased|pod-deleted|job-deleted|pvc-deleted|pv-deleted)
      remote_erasure_recorded=true
      ;;
  esac
  credentials_local_recorded=false
  case "$handoff_phase" in
    credentials-local|credentials-erased|pod-deleted|job-deleted|pvc-deleted|\
      pv-deleted)
      credentials_local_recorded=true
      ;;
  esac
  if [[ "$credentials_local_recorded" == true ]]; then
    [[ "$bootstrap_key_local" == true && "$bootstrap_password_local" == true ]] ||
      die "handoff journal records local credentials, but a credential is missing."
    [[ "$(sha256_file "$bootstrap_key")" == "$credential_key_sha256" ]] ||
      die "local bootstrap service key does not match the handoff journal."
    [[ "$(sha256_file "$bootstrap_password")" == \
      "$credential_password_sha256" ]] ||
      die "local bootstrap password does not match the handoff journal."
  fi
  if [[ "$remote_erasure_recorded" == true &&
    ( "$bootstrap_key_local" != true || "$bootstrap_password_local" != true ) ]]; then
    die "handoff journal records erased cluster credentials, but a local credential is missing."
  fi

  inspect_owned_resource \
    persistentvolumeclaim oce-sample-bootstrap-output "$OWNER_LABEL"
  bootstrap_pvc_live=$INSPECTED_RESOURCE_PRESENT
  if [[ "$bootstrap_pvc_live" == true &&
    "$INSPECTED_RESOURCE_UID" != "$bootstrap_pvc_uid" ]]; then
    die "refusing to mount replaced persistentvolumeclaim/oce-sample-bootstrap-output."
  fi
  if [[ "$bootstrap_pvc_live" != true &&
    "$remote_erasure_recorded" != true ]]; then
    die "bootstrap output PVC is gone before cluster credential erasure was recorded."
  fi

  if [[ "$bootstrap_pvc_live" == true &&
    "$remote_erasure_recorded" != true ]]; then
    if [[ -z "$bootstrap_pod_uid" ]]; then
      bootstrap_create_error=$(mktemp \
        "$state_dir/bootstrap-create-error.XXXXXX")
      set +e
      bootstrap_pod_json=$("${KUBE[@]}" --namespace "$namespace" create \
        -f "$bootstrap_handoff" -o json 2>"$bootstrap_create_error")
      bootstrap_create_status=$?
      set -e
      bootstrap_create_message=$(<"$bootstrap_create_error")
      rm -f "$bootstrap_create_error"
      bootstrap_create_error=
      if ((bootstrap_create_status != 0)); then
        if kubectl_error_is_already_exists "$bootstrap_create_message"; then
          die "refusing to adopt existing pod/oce-sample-bootstrap-handoff without a journalled UID."
        fi
        die "exclusive creation failed for bootstrap handoff Pod: $bootstrap_create_message"
      fi
      require_bootstrap_handoff_contract "$bootstrap_pod_json" ""
      bootstrap_pod_uid=$(jq -er '.metadata.uid' <<<"$bootstrap_pod_json")
      if [[ "$credentials_local_recorded" == true ]]; then
        write_handoff_state credentials-local
      else
        write_handoff_state handoff-pod-ready
      fi
    fi
    inspect_owned_resource pod oce-sample-bootstrap-handoff "$OWNER_LABEL"
    [[ "$INSPECTED_RESOURCE_PRESENT" == true ]] ||
      die "journalled bootstrap handoff Pod is missing."
    require_bootstrap_handoff_contract \
      "$INSPECTED_RESOURCE_JSON" "$bootstrap_pod_uid"
    bootstrap_reader_live=true
    "${KUBE[@]}" --namespace "$namespace" wait \
      --for=condition=Ready pod/oce-sample-bootstrap-handoff --timeout=120s

    if [[ "$credentials_local_recorded" != true ]]; then
      bootstrap_key_tmp=$(mktemp "$state_dir/bootstrap-key.XXXXXX")
      write_private "$bootstrap_key_tmp" \
        "${KUBE[@]}" --namespace "$namespace" exec \
        pod/oce-sample-bootstrap-handoff -- node -e \
        'process.stdout.write(require("node:fs").readFileSync(
          "/bootstrap/initial-admin-service-key.json"))'
      jq -e '.data.key | type == "string" and length > 0' \
        "$bootstrap_key_tmp" >/dev/null ||
        die "bootstrap service key has an invalid format."

      bootstrap_password_tmp=$(mktemp "$state_dir/bootstrap-password.XXXXXX")
      write_private "$bootstrap_password_tmp" \
        "${KUBE[@]}" --namespace "$namespace" exec \
        pod/oce-sample-bootstrap-handoff -- node -e \
        'process.stdout.write(require("node:fs").readFileSync(
          "/bootstrap/initial-admin-password"))'
      [[ -s "$bootstrap_password_tmp" ]] ||
        die "bootstrap password is empty."

      if [[ "$bootstrap_key_local" == true ]]; then
        [[ "$(sha256_file "$bootstrap_key")" == \
          "$(sha256_file "$bootstrap_key_tmp")" ]] ||
          die "existing local bootstrap service key does not match the deployed installation."
        rm -f "$bootstrap_key_tmp"
        bootstrap_key_tmp=
      else
        persist_private_file "$bootstrap_key_tmp" "$bootstrap_key"
        bootstrap_key_tmp=
        bootstrap_key_local=true
      fi

      if [[ "$bootstrap_password_local" == true ]]; then
        [[ "$(sha256_file "$bootstrap_password")" == \
          "$(sha256_file "$bootstrap_password_tmp")" ]] ||
          die "existing local bootstrap password does not match the deployed installation."
        rm -f "$bootstrap_password_tmp"
        bootstrap_password_tmp=
      else
        persist_private_file "$bootstrap_password_tmp" "$bootstrap_password"
        bootstrap_password_tmp=
        bootstrap_password_local=true
      fi

      credential_key_sha256=$(sha256_file "$bootstrap_key")
      credential_password_sha256=$(sha256_file "$bootstrap_password")
      write_handoff_state credentials-local
      credentials_local_recorded=true
    fi

    [[ "$(sha256_file "$bootstrap_key")" == "$credential_key_sha256" ]] ||
      die "local bootstrap service key changed before cluster erasure."
    [[ "$(sha256_file "$bootstrap_password")" == \
      "$credential_password_sha256" ]] ||
      die "local bootstrap password changed before cluster erasure."
    "${KUBE[@]}" --namespace "$namespace" exec \
      pod/oce-sample-bootstrap-handoff -- node -e '
        const fs = require("node:fs");
        const files = [
          "/bootstrap/initial-admin-service-key.json",
          "/bootstrap/initial-admin-password",
        ];
        for (const file of files) {
          fs.rmSync(file, {force: true});
        }
        if (files.some((file) => fs.existsSync(file))) {
          throw new Error("bootstrap credential erasure verification failed");
        }
      '
    write_handoff_state credentials-erased
    remote_erasure_recorded=true
  fi

  require_private_file "local bootstrap service key" "$bootstrap_key"
  jq -e '.data.key | type == "string" and length > 0' \
    "$bootstrap_key" >/dev/null ||
    die "bootstrap service key has an invalid format."
  require_private_file "local bootstrap password" "$bootstrap_password"
  [[ -s "$bootstrap_password" ]] || die "bootstrap password is empty."

  inspect_owned_resource pod oce-sample-bootstrap-handoff "$OWNER_LABEL"
  if [[ "$INSPECTED_RESOURCE_PRESENT" == true ]]; then
    require_bootstrap_handoff_contract \
      "$INSPECTED_RESOURCE_JSON" "$bootstrap_pod_uid"
    delete_owned_resource pod oce-sample-bootstrap-handoff \
      "$bootstrap_pod_uid" 120s
  fi
  bootstrap_reader_live=false
  write_handoff_state pod-deleted

  delete_owned_resource job oce-sample-bootstrap-volume-prep \
    "$bootstrap_job_uid" 120s
  write_handoff_state job-deleted

  # OCE retains its completed pre-install hook until the next Helm operation.
  # Delete only the exact completed hook for this OCC attempt so its finished
  # Pod releases the temporary bootstrap PVC before the sample removes it.
  delete_oce_initialization_job

  delete_owned_resource persistentvolumeclaim oce-sample-bootstrap-output \
    "$bootstrap_pvc_uid" 120s
  write_handoff_state pvc-deleted

  set +e
  bootstrap_pv_json=$("${KUBE[@]}" get \
    "persistentvolume/$bootstrap_pv" -o json 2>&1)
  bootstrap_pv_status=$?
  set -e
  if ((bootstrap_pv_status == 0)); then
    current_pv_uid=$(jq -er '.metadata.uid' <<<"$bootstrap_pv_json") ||
      die "bootstrap output persistent volume is missing its UID."
    [[ "$current_pv_uid" == "$bootstrap_pv_uid" ]] ||
      die "refusing to wait for replaced persistentvolume/$bootstrap_pv."
    "${KUBE[@]}" wait --for=delete "persistentvolume/$bootstrap_pv" \
      --timeout=180s
  elif ! kubectl_error_is_not_found "$bootstrap_pv_json"; then
    die "could not inspect persistentvolume/$bootstrap_pv: $bootstrap_pv_json"
  fi
  write_handoff_state pv-deleted
  trap - EXIT
  cleanup_bootstrap_handoff
)

declare -a receipt_resource_guards=()
record_receipt_resource() {
  local resource=$1 expected_owner=$2 expected_instance=$3
  local target_namespace=${4:-}
  local expected_name=${resource##*/}
  local record name owner instance uid extra
  local -a get_command=("${KUBE[@]}")
  [[ -z "$target_namespace" ]] || get_command+=(--namespace "$target_namespace")
  get_command+=(get "$resource")
  record=$("${get_command[@]}" \
    -o 'jsonpath={.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"|"}{.metadata.labels.app\.kubernetes\.io/instance}{"|"}{.metadata.uid}{"\n"}') ||
    die "could not bind $resource to the installation receipt."
  IFS='|' read -r name owner instance uid extra <<<"$record"
  [[ -z "${extra:-}" && "$name" == "$expected_name" &&
    "$owner" == "$expected_owner" && "$instance" == "$expected_instance" &&
    "$uid" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
    die "$resource does not match the expected ownership identity; refusing to record it."
  receipt_resource_guards+=("$resource|$uid")
}

record_helm_receipt_resource() {
  local resource=$1
  local expected_name=${resource##*/}
  local record name owner helm_release helm_namespace uid extra
  record=$("${KUBE[@]}" get "$resource" \
    -o 'jsonpath={.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"|"}{.metadata.annotations.meta\.helm\.sh/release-name}{"|"}{.metadata.annotations.meta\.helm\.sh/release-namespace}{"|"}{.metadata.uid}{"\n"}') ||
    die "could not bind $resource to the installation receipt."
  IFS='|' read -r name owner helm_release helm_namespace uid extra <<<"$record"
  [[ -z "${extra:-}" && "$name" == "$expected_name" &&
    "$owner" == Helm && "$helm_release" == "$release" &&
    "$helm_namespace" == "$namespace" &&
    "$uid" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
    die "$resource does not match the expected Helm ownership identity; refusing to record it."
  receipt_resource_guards+=("$resource|$uid")
}

readonly -a adapter_resources=(
  namespace/openclaw-enterprise-adapter
  validatingadmissionpolicies.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label
  validatingadmissionpolicybindings.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label
  mutatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-adapter
  validatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-policy
)
readonly -a release_resources=(
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-namespace-observer"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-namespace-worker"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-worker"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-api"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-tenant-configuration"
  "clusterrole.rbac.authorization.k8s.io/${release}-openclaw-gateway-observer"
  "clusterrolebinding.rbac.authorization.k8s.io/${release}-openclaw-worker-namespaces"
  "clusterrolebinding.rbac.authorization.k8s.io/${release}-openclaw-api-namespaces"
)

record_receipt_resource "namespace/$namespace" "$OWNER_LABEL" ""
record_receipt_resource namespace/openclaw-enterprise-agw "$OWNER_LABEL" ""
record_receipt_resource \
  networkpolicy.networking.k8s.io/oce-eks-cluster-dns \
  "$OWNER_LABEL" "" "$namespace"
record_receipt_resource \
  "storageclass.storage.k8s.io/$runtime_storage_class" "$OWNER_LABEL" ""
for resource in "${adapter_resources[@]}"; do
  record_receipt_resource "$resource" "$OWNER_LABEL" ""
done
for resource in "${release_resources[@]}"; do
  record_helm_receipt_resource "$resource"
done

write_private "$receipt/resources.json" python3 -I -c '
from pathlib import Path
import json, re, sys

intent_path, *records = sys.argv[1:]
intent = json.loads(Path(intent_path).read_text(encoding="utf-8"))
attempt = intent.get("attempt")
if not isinstance(attempt, str) or not attempt or "\t" in attempt:
    raise SystemExit("invalid OCC attempt identifier")

resources = {}
for record in records:
    resource, separator, uid = record.partition("|")
    if (
        not separator
        or resource in resources
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,255}", resource)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", uid)
    ):
        raise SystemExit("invalid resource identity")
    resources[resource] = uid

print(json.dumps(
    {"version": 1, "attempt": attempt, "resources": resources},
    sort_keys=True,
    separators=(",", ":"),
))
' "$receipt/intent.json" "${receipt_resource_guards[@]}"

write_private "$marker" printf '%s\n' \
  "source=$OCE_SOURCE_PIN" \
  "cluster_arn=$cluster_arn" \
  "context=$kube_context" \
  "namespace=$namespace" \
  "release=$release"
sync_file_and_parent "$marker"
rm -f "$handoff_state"
sync_directory "$state_dir"

printf 'Installed OpenClaw Enterprise release %s in namespace %s.\n' "$release" "$namespace"
printf 'Receipt: %s\n' "$receipt"
printf 'Topology: terminal-managed; embedded Harnesses only; direct Pod API clients and browser routing disabled.\n'
