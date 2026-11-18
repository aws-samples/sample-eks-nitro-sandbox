#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly OCE_SOURCE_PIN="86c8c12310f691bb21651118ffffd6bfd460e9ff"
readonly OCE_MODULE="github.com/openclaw/openclaw-enterprise"
readonly OWNER_LABEL="openclaw-enterprise-blueprint"
readonly VALIDATION_POSTGRES_TOKEN="__OCE_VALIDATION_POSTGRES_IMAGE__"
readonly VALIDATION_CLUSTER_TAG_KEY="Environment"
readonly VALIDATION_CLUSTER_TAG_VALUE="validation"
readonly MODEL_PROVIDER_PROTOCOL="openai-responses"
readonly MODEL_PROVIDER_BASE_URL="https://agentgateway.openclaw-enterprise-agw.svc.cluster.local/v1"
readonly DATABASE_CA_SECRET="oce-sample-database-ca"
readonly DATABASE_CA_KEY="ca.pem"
readonly DATABASE_CA_MOUNT_PATH="/etc/openclaw/database-ca"
readonly DATABASE_CA_PATH="$DATABASE_CA_MOUNT_PATH/$DATABASE_CA_KEY"

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
    '--validation-postgres creates a disposable, single-Pod PostgreSQL database with' \
    'emptyDir storage. The EKS cluster must have the exact tag key Environment with' \
    'value validation (value matching is case-insensitive). Production-tagged clusters' \
    'are rejected. This mode is only for installation validation, never production.' \
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
  python3 - "$flag" "$cidr" "$exact_host" <<'PY' ||
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
PY
    die "$flag is invalid."
}

require_private_file() {
  local flag=$1 path=$2 mode
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] ||
    die "$flag must be a readable regular file, not a symlink."
  if mode=$(stat -f '%Lp' "$path" 2>/dev/null); then
    :
  elif mode=$(stat -c '%a' "$path" 2>/dev/null); then
    :
  else
    die "could not inspect permissions for $flag."
  fi
  [[ "$mode" =~ ^[0-7]00$ ]] ||
    die "$flag must not be readable or writable by group or other (mode is $mode)."
}

install_postgres_url() {
  local flag=$1 source=$2 destination=$3
  python3 - "$flag" "$source" "$destination" "$DATABASE_CA_PATH" <<'PY' ||
import ipaddress
import os
from pathlib import Path
import re
import sys
from urllib.parse import parse_qsl, urlsplit

flag, source, destination, ca_path = sys.argv[1:]


def reject(reason):
    sys.stderr.write(f"install-oce: {flag} {reason}.\n")
    raise SystemExit(1)


try:
    raw = Path(source).read_bytes()
except OSError:
    reject("could not be read")
if not raw or len(raw) > 16384:
    reject("must contain one PostgreSQL URL no larger than 16 KiB")
if raw.endswith(b"\n"):
    raw = raw[:-1]
if any(byte < 0x21 or byte > 0x7E for byte in raw):
    reject("must contain one ASCII URL with no whitespace or embedded newlines")
try:
    value = raw.decode("ascii")
except UnicodeDecodeError:
    reject("must contain one ASCII URL")
if "\\" in value or re.search(r"%(?![0-9A-Fa-f]{2})", value):
    reject("contains malformed URL escaping")

try:
    parsed = urlsplit(value)
    host = parsed.hostname
    port = parsed.port
except ValueError:
    reject("contains a malformed PostgreSQL URL")
if (
    parsed.scheme not in {"postgres", "postgresql"}
    or not parsed.netloc
    or not host
    or parsed.fragment
    or parsed.path in {"", "/"}
):
    reject("must contain one PostgreSQL URL with a host and database name")
try:
    ipaddress.ip_address(host)
except ValueError:
    pass
else:
    reject("must use a DNS hostname so verify-full checks the server identity")
dns_labels = host.split(".")
if (
    len(host) > 253
    or any(
        len(label) > 63
        or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label)
        for label in dns_labels
    )
):
    reject("must use a valid DNS hostname so verify-full checks the server identity")
if port not in {None, 5432}:
    reject("must use a DNS hostname on PostgreSQL port 5432")

try:
    pairs = parse_qsl(
        parsed.query,
        keep_blank_values=True,
        strict_parsing=True,
        encoding="utf-8",
        errors="strict",
        max_num_fields=100,
    )
except (UnicodeDecodeError, ValueError):
    reject("contains malformed query parameters")
keys = [key.casefold() for key, _ in pairs]
if len(keys) != len(set(keys)):
    reject("must not contain duplicate query parameters")
parameters = {key.casefold(): value for key, value in pairs}
if "connectionstring" in parameters or "ssl" in parameters:
    reject("contains an unsupported nested or overriding TLS parameter")
if parameters.get("sslmode") != "verify-full":
    reject("must set sslmode=verify-full exactly once")
if parameters.get("sslrootcert") != ca_path:
    reject(f"must set sslrootcert={ca_path} exactly once")

flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    descriptor = os.open(destination, flags, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(raw)
    os.chmod(destination, 0o600)
except OSError:
    reject("could not be copied into the protected state directory")
PY
    die "$flag is invalid."
}

install_ca_bundle() {
  local flag=$1 source=$2 destination=$3
  python3 - "$flag" "$source" "$destination" <<'PY' ||
import os
from pathlib import Path
import re
import subprocess
import sys

flag, source, destination = sys.argv[1:]


def reject(reason):
    sys.stderr.write(f"install-oce: {flag} {reason}.\n")
    raise SystemExit(1)


try:
    raw = Path(source).read_bytes()
except OSError:
    reject("could not be read")
if not raw or len(raw) > 1024 * 1024:
    reject("must contain a nonempty PEM CA bundle no larger than 1 MiB")
try:
    value = raw.decode("ascii")
except UnicodeDecodeError:
    reject("must contain ASCII PEM certificates")
pattern = re.compile(
    r"-----BEGIN CERTIFICATE-----\r?\n"
    r"[A-Za-z0-9+/=\r\n]+"
    r"-----END CERTIFICATE-----"
)
certificates = pattern.findall(value)
if not certificates or pattern.sub("", value).strip():
    reject("must contain only PEM certificates, with no private keys or other text")
for index, certificate in enumerate(certificates, start=1):
    result = subprocess.run(
        ["openssl", "x509", "-noout", "-text"],
        input=certificate,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        reject(f"contains an invalid X.509 certificate at position {index}")
    if not re.search(r"\bCA\s*:\s*TRUE\b", result.stdout, re.IGNORECASE):
        reject(f"certificate {index} is not a CA certificate")

flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    descriptor = os.open(destination, flags, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(raw)
    os.chmod(destination, 0o600)
except OSError:
    reject("could not be copied into the protected state directory")
PY
    die "$flag is invalid."
}

require_validation_cluster_tags() {
  local tags_json=$1
  python3 - "$tags_json" "$VALIDATION_CLUSTER_TAG_KEY" \
    "$VALIDATION_CLUSTER_TAG_VALUE" <<'PY' ||
import json
import sys

raw, required_key, required_value = sys.argv[1:]
try:
    tags = json.loads(raw)
except json.JSONDecodeError:
    tags = None
if not isinstance(tags, dict) or not all(
    isinstance(key, str) and isinstance(value, str)
    for key, value in tags.items()
):
    sys.stderr.write("install-oce: EKS returned malformed cluster tags.\n")
    raise SystemExit(1)

production = []
for key, value in tags.items():
    if key.casefold() in {"environment", "stage"} and value.casefold() in {
        "prod",
        "production",
    }:
        production.append(f"{key}={value}")
if production:
    sys.stderr.write(
        "install-oce: --validation-postgres rejects production-tagged EKS "
        f"clusters ({', '.join(production)}).\n"
    )
    raise SystemExit(1)

actual_value = tags.get(required_key)
if not isinstance(actual_value, str) or actual_value.casefold() != required_value:
    sys.stderr.write(
        "install-oce: --validation-postgres requires the exact EKS tag "
        f"{required_key}={required_value} (value is case-insensitive).\n"
    )
    raise SystemExit(1)
PY
    die "EKS cluster is not explicitly tagged for validation."
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
  grep -Eq '(\(NotFound\)| not found|NotFound)' <<<"$1"
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

for prerequisite in aws kubectl helm git go openssl base64 python3 install mktemp sed grep tr stat; do
  require_command "$prerequisite"
done

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
state_dir=$(python3 - "$state_dir" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)
receipt=$(python3 - "$receipt" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)
[[ "$receipt" == "$state_dir/"* ]] ||
  die "--receipt must be below --state-dir."

database_app_url_value="$state_dir/database-application-url"
database_migration_url_value="$state_dir/database-migration-url"
database_ca_value="$state_dir/database-ca.pem"
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
    trap 'rm -f "${occ_tmp:-}"' EXIT
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
current_context=$(kubectl --kubeconfig "$kubeconfig" config current-context)
[[ "$current_context" == "$kube_context" ]] ||
  die "wrong active kube context: expected $kube_context, found $current_context."
context_endpoint=$(kubectl --kubeconfig "$kubeconfig" config view --raw --minify \
  --context "$kube_context" -o 'jsonpath={.clusters[0].cluster.server}')
[[ "$context_endpoint" == "$cluster_endpoint" ]] ||
  die "kube context endpoint does not match EKS cluster $eks_cluster_name."

KUBE=(kubectl --kubeconfig "$kubeconfig" --context "$kube_context" --request-timeout=20s)
"${KUBE[@]}" get namespace kube-system -o name >/dev/null ||
  die "cannot reach kube-system through the selected context."
"${KUBE[@]}" get storageclass "$runtime_storage_class" -o name >/dev/null ||
  die "required StorageClass $runtime_storage_class does not exist."

release_names=$(helm list --kubeconfig "$kubeconfig" --kube-context "$kube_context" \
  --namespace "$namespace" --all --short)
marker="$state_dir/install.complete"
if grep -Fqx "$release" <<<"$release_names"; then
  [[ -f "$marker" && ! -L "$marker" && -d "$receipt" ]] ||
    die "Helm release $release exists without this installer's completion evidence."
  if ! grep -Fqx "source=$OCE_SOURCE_PIN" "$marker" ||
    ! grep -Fqx "cluster_arn=$cluster_arn" "$marker" ||
    ! grep -Fqx "context=$kube_context" "$marker" ||
    ! grep -Fqx "namespace=$namespace" "$marker" ||
    ! grep -Fqx "release=$release" "$marker"; then
    die "existing release $release does not match this install request."
  fi
  printf 'OpenClaw Enterprise release %s is already installed with matching evidence.\n' "$release"
  exit 0
fi
[[ ! -e "$marker" && ! -e "$receipt" ]] ||
  die "release is absent but receipt or completion evidence exists; inspect the prior OCC attempt."

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

auth_secret_value="$state_dir/auth-secret"
if [[ ! -e "$auth_secret_value" ]]; then
  auth_secret=$(openssl rand -hex 32)
  write_private_text "$auth_secret_value" "$auth_secret"
fi
normalize_hex_secret "generated auth secret" "$auth_secret_value" 64

validation_manifest="$state_dir/oce-validation-postgres.yaml"
if [[ "$validation_postgres" == true ]]; then
  printf 'WARNING: using disposable validation-only PostgreSQL with emptyDir storage.\n' >&2
  validation_password="$state_dir/validation-postgres-password"
  if [[ ! -e "$validation_password" ]]; then
    generated_password=$(openssl rand -hex 24)
    write_private_text "$validation_password" "$generated_password"
  fi
  normalize_hex_secret \
    "generated validation PostgreSQL password" "$validation_password" 48
  password=$(<"$validation_password")
  write_private_text "$database_app_url_value" \
    "postgresql://oce_validation:${password}@oce-validation-only-postgres:5432/openclaw?sslmode=disable"
  write_private_text "$database_migration_url_value" \
    "postgresql://oce_validation:${password}@oce-validation-only-postgres:5432/openclaw?sslmode=disable"

  validation_secret="$state_dir/validation-postgres-secret.yaml"
  validation_password_b64=$(base64_one_line "$validation_password")
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
  password: $validation_password_b64"
  apply_owned_resource secret oce-validation-only-postgres "$validation_secret"

  script_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  validation_template="$script_root/deploy/oce-validation-postgres.yaml"
  [[ -f "$validation_template" ]] ||
    die "missing validation PostgreSQL manifest $validation_template."
  sed "s|$VALIDATION_POSTGRES_TOKEN|$validation_postgres_image|g" \
    "$validation_template" >"$validation_manifest"
  chmod 600 "$validation_manifest"
  grep -Fq "$VALIDATION_POSTGRES_TOKEN" "$validation_manifest" &&
    die "validation PostgreSQL image placeholder was not replaced."
  resource_is_owned deployment oce-validation-only-postgres || true
  resource_is_owned service oce-validation-only-postgres || true
  resource_is_owned networkpolicy oce-validation-only-postgres || true
  "${KUBE[@]}" --namespace "$namespace" apply \
    --server-side --field-manager="$OWNER_LABEL" -f "$validation_manifest" >/dev/null
  "${KUBE[@]}" --namespace "$namespace" rollout status \
    deployment/oce-validation-only-postgres --timeout=120s
  database_pod_ips=$("${KUBE[@]}" --namespace "$namespace" get pods \
    -l 'app.kubernetes.io/name=oce-validation-only-postgres,app.kubernetes.io/instance=validation-only' \
    -o 'jsonpath={.items[*].status.podIP}')
  [[ "$database_pod_ips" != *" "* && -n "$database_pod_ips" ]] ||
    die "validation PostgreSQL must have exactly one Pod IP."
  require_ipv4_cidr "validation PostgreSQL Pod IP" "$database_pod_ips/32" true
  database_cidrs=("$database_pod_ips/32")
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

write_private "$marker" printf '%s\n' \
  "source=$OCE_SOURCE_PIN" \
  "cluster_arn=$cluster_arn" \
  "context=$kube_context" \
  "namespace=$namespace" \
  "release=$release"

printf 'Installed OpenClaw Enterprise release %s in namespace %s.\n' "$release" "$namespace"
printf 'Receipt: %s\n' "$receipt"
printf 'Topology: terminal-managed; embedded Harnesses only; direct Pod API clients and browser routing disabled.\n'
