from __future__ import annotations

import base64
import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "install-oce.sh"
POSTGRES = ROOT / "deploy" / "oce-validation-postgres.yaml"
README = ROOT / "README.md"
PIN = "86c8c12310f691bb21651118ffffd6bfd460e9ff"  # pragma: allowlist secret -- public source revision
DIGEST = "a" * 64
VALIDATION_POSTGRES_DIGEST = (
    "86c951e05bf56c93d95d397747fb8820ac76cc3bedb78f43abd83eedbe3666ae"  # pragma: allowlist secret -- public image digest
)
DATABASE_CA_PATH = "/etc/openclaw/database-ca/ca.pem"
MODEL_PROVIDER_BASE_URL = (
    "https://agentgateway.openclaw-enterprise-agw.svc.cluster.local/v1"
)
DISABLED_DIRECT_API_CLIENT_SELECTOR = {
    "app.kubernetes.io/name": "oce-direct-pod-api-clients-disabled",
    "openclaw.dev/direct-pod-api-client": "disabled",
}
RECEIPT_RESOURCE_KEYS = {
    "namespace/openclaw-system",
    "namespace/openclaw-enterprise-adapter",
    "namespace/openclaw-enterprise-agw",
    "networkpolicy.networking.k8s.io/oce-eks-cluster-dns",
    "storageclass.storage.k8s.io/gp3",
    (
        "validatingadmissionpolicies.admissionregistration.k8s.io/"
        "protect-openclaw-enterprise-namespace-label"
    ),
    (
        "validatingadmissionpolicybindings.admissionregistration.k8s.io/"
        "protect-openclaw-enterprise-namespace-label"
    ),
    (
        "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-adapter"
    ),
    (
        "validatingwebhookconfigurations.admissionregistration.k8s.io/"
        "openclaw-enterprise-nitro-policy"
    ),
    "clusterrole.rbac.authorization.k8s.io/oce-openclaw-namespace-observer",
    "clusterrole.rbac.authorization.k8s.io/oce-openclaw-namespace-worker",
    "clusterrole.rbac.authorization.k8s.io/oce-openclaw-tenant-worker",
    "clusterrole.rbac.authorization.k8s.io/oce-openclaw-tenant-api",
    "clusterrole.rbac.authorization.k8s.io/oce-openclaw-tenant-configuration",
    "clusterrole.rbac.authorization.k8s.io/oce-openclaw-gateway-observer",
    "clusterrolebinding.rbac.authorization.k8s.io/oce-openclaw-worker-namespaces",
    "clusterrolebinding.rbac.authorization.k8s.io/oce-openclaw-api-namespaces",
}
TEST_CA = """-----BEGIN CERTIFICATE-----
VEVTVA==
-----END CERTIFICATE-----
"""


def run_script(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def test_static_install_contract_is_pinned_and_closed() -> None:
    text = SCRIPT.read_text()
    assert f'OCE_SOURCE_PIN="{PIN}"' in text
    assert 'gatewayRouting:' in text
    assert 'agentNativeAdmin:' in text
    assert text.count("enabled: false") >= 4
    assert "requireImmutableDigest: true" in text
    assert "gatewayClients:" in text
    assert "includeDefaults: false" in text
    assert "app.kubernetes.io/managed-by: $OWNER_LABEL" in text
    assert "--server-side --field-manager=" in text
    assert '"$occ_binary" installation install' in text
    persist = text[
        text.index("persist_private_file() {") : text.index(
            "sha256_file() {"
        )
    ]
    assert persist.index('sync_file_and_parent "$source"') < persist.index(
        'mv "$source" "$destination"'
    )
    assert persist.index('mv "$source" "$destination"') < persist.index(
        'sync_directory "$(dirname "$destination")"'
    )
    for explicit_flag in (
        '--release "$release"',
        '--chart "$chart_dir"',
        '--kubeconfig "$kubeconfig"',
        '--context "$kube_context"',
        '--kube-namespace "$namespace"',
        '--values "$values_yaml"',
        '--receipt "$receipt"',
    ):
        assert explicit_flag in text
    assert "git -C \"$oce_source\" status --porcelain --untracked-files=all" in text
    assert "vcs.revision=" in text
    assert "vcs.modified=false" in text
    assert "wrong AWS account" in text
    assert "require_helm_3" in text
    assert "pinned OCE revision requires Helm 3" in text
    assert "require_validation_postgres_version" in text
    assert "pinned OCE revision requires PostgreSQL 17 or later" in text
    assert "require_validation_postgres_role_contract" in text
    assert "role contract does not match pinned OCE requirements" in text
    assert "kube context endpoint does not match EKS cluster" in text
    assert "refusing to adopt existing" in text
    assert 'create \\\n        -f "$bootstrap_handoff" -o json' in text
    assert "openclaw.dev/bootstrap-handoff-receipt" in text
    assert "bootstrap_handoff_contract_matches" in text
    assert 'VALIDATION_CLUSTER_TAG_KEY="Environment"' in text
    assert 'VALIDATION_CLUSTER_TAG_VALUE="validation"' in text
    assert 'MODEL_PROVIDER_PROTOCOL="openai-responses"' in text
    assert f'MODEL_PROVIDER_BASE_URL="{MODEL_PROVIDER_BASE_URL}"' in text
    assert "api-cli-client.yaml" not in text
    assert "oce-api-cli-client" not in text
    assert "deployment/oce-api-cli-client" not in text
    assert "Direct Pod API clients" in text
    assert "sslmode=verify-full" in text
    assert 'DATABASE_CA_PATH="$DATABASE_CA_MOUNT_PATH/$DATABASE_CA_KEY"' in text
    assert "caSecretName: $DATABASE_CA_SECRET" in text
    assert "caMountPath: $DATABASE_CA_MOUNT_PATH" in text


def test_validation_postgres_is_explicitly_disposable_and_owned() -> None:
    documents = list(yaml.safe_load_all(POSTGRES.read_text()))
    assert [document["kind"] for document in documents] == [
        "Deployment",
        "Service",
    ]
    for document in documents:
        metadata = document["metadata"]
        assert metadata["name"] == "oce-validation-only-postgres"
        assert (
            metadata["labels"]["app.kubernetes.io/managed-by"]
            == "openclaw-enterprise-blueprint"
        )
        assert metadata["annotations"]["openclaw.dev/validation-only"] == "true"
    deployment = documents[0]
    pod_spec = deployment["spec"]["template"]["spec"]
    assert pod_spec["automountServiceAccountToken"] is False
    postgres = pod_spec["containers"][0]
    assert "__OCE_VALIDATION_POSTGRES_IMAGE__" == postgres["image"]
    assert {
        "name": "bootstrap",
        "mountPath": "/docker-entrypoint-initdb.d",
        "readOnly": True,
    } in postgres["volumeMounts"]
    bootstrap = next(
        volume for volume in pod_spec["volumes"] if volume["name"] == "bootstrap"
    )
    assert bootstrap["secret"]["secretName"] == "oce-validation-only-postgres"  # pragma: allowlist secret -- Kubernetes Secret name
    assert bootstrap["secret"]["items"] == [
        {"key": "init.sql", "path": "10-openclaw-roles.sql"}
    ]
    assert pod_spec["volumes"][0]["emptyDir"]["sizeLimit"] == "2Gi"
    assert "persistentVolumeClaim" not in POSTGRES.read_text()


def test_help_names_validation_database_limit() -> None:
    result = run_script("--help")
    assert result.returncode == 0
    assert PIN in result.stdout
    assert "emptyDir" in result.stdout
    assert "never production" in result.stdout
    assert "exact tag key Environment" in result.stdout
    assert "value validation (value matching is case-insensitive)" in result.stdout
    assert "--database-ca-file" in result.stdout
    assert f"sslrootcert={DATABASE_CA_PATH}" in result.stdout


def test_mutable_images_fail_before_external_commands(tmp_path: Path) -> None:
    result = run_script(
        "--aws-account-id",
        "123456789012",
        "--aws-region",
        "ap-southeast-2",
        "--eks-cluster-name",
        "test",
        "--kubeconfig",
        str(tmp_path / "config"),
        "--kube-context",
        "test",
        "--oce-source",
        str(tmp_path / "source"),
        "--build-occ",
        "--controller-image",
        "example/controller:latest",
        "--runtime-image",
        f"example/runtime@sha256:{DIGEST}",
        "--auth-base-url",
        "https://oce.example.test",
        "--agent-domain",
        "agents.example.test",
        "--admin-email",
        "admin@example.test",
        "--runtime-storage-class",
        "gp3",
        "--pod-cidr",
        "10.0.0.0/16",
        "--cluster-api-cidr",
        "10.0.0.1/32",
        "--state-dir",
        str(tmp_path / "state"),
        "--receipt",
        str(tmp_path / "state" / "receipt"),
        "--validation-postgres",
        "--validation-postgres-image",
        f"example/postgres@sha256:{DIGEST}",
    )
    assert result.returncode != 0
    assert "immutable IMAGE@sha256:DIGEST" in result.stderr


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _write_private(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o600)


def _base_args(tmp_path: Path, source: Path, kubeconfig: Path, occ: Path) -> list[str]:
    return [
        "--aws-account-id",
        "123456789012",
        "--aws-region",
        "ap-southeast-2",
        "--eks-cluster-name",
        "oce-test",
        "--kubeconfig",
        str(kubeconfig),
        "--kube-context",
        "oce-test",
        "--oce-source",
        str(source),
        "--occ-binary",
        str(occ),
        "--controller-image",
        f"example/controller@sha256:{DIGEST}",
        "--runtime-image",
        f"example/runtime@sha256:{DIGEST}",
        "--auth-base-url",
        "https://oce.example.test",
        "--agent-domain",
        "agents.example.test",
        "--admin-email",
        "admin@example.test",
        "--runtime-storage-class",
        "gp3",
        "--pod-cidr",
        "10.2.0.0/16",
        "--cluster-api-cidr",
        "10.0.0.1/32",
        "--state-dir",
        str(tmp_path / "state"),
        "--receipt",
        str(tmp_path / "state" / "receipt"),
        "--validation-postgres",
        "--validation-postgres-image",
        f"example/postgres@sha256:{DIGEST}",
    ]


def _external_args(
    tmp_path: Path,
    source: Path,
    kubeconfig: Path,
    occ: Path,
    *,
    app_url: str | None = None,
    migration_url: str | None = None,
) -> list[str]:
    default_app_url = (
        "postgresql://oce_app:app-secret@db.example.test:5432/openclaw"  # pragma: allowlist secret -- test placeholder
        f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}"
    )
    default_migration_url = (
        "postgresql://oce_migrator:migration-secret@db.example.test:5432/openclaw"  # pragma: allowlist secret -- test placeholder
        f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}"
    )
    app_url_file = tmp_path / "application-url"
    migration_url_file = tmp_path / "migration-url"
    ca_file = tmp_path / "database-ca.pem"
    _write_private(app_url_file, f"{app_url or default_app_url}\n")
    _write_private(migration_url_file, f"{migration_url or default_migration_url}\n")
    _write_private(ca_file, TEST_CA)
    args = _base_args(tmp_path, source, kubeconfig, occ)
    del args[-3:]
    return [
        *args,
        "--database-app-url-file",
        str(app_url_file),
        "--database-migration-url-file",
        str(migration_url_file),
        "--database-ca-file",
        str(ca_file),
        "--database-cidr",
        "10.0.1.20/32",
    ]


def _fake_environment(tmp_path: Path, *, account: str = "123456789012") -> tuple[dict[str, str], Path, Path, Path]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    log = tmp_path / "calls.log"
    kube_state = tmp_path / "kube-state"
    kube_state.mkdir()
    (kube_state / "remote-key").touch()
    (kube_state / "remote-password").touch()
    source = tmp_path / "source"
    (source / "deploy" / "helm" / "openclaw-enterprise").mkdir(parents=True)
    (source / "deploy" / "helm" / "openclaw-enterprise" / "Chart.yaml").write_text(
        "apiVersion: v2\nname: openclaw-enterprise\nversion: 0.0.0\n"
    )
    (source / "cmd" / "occ").mkdir(parents=True)
    (source / "cmd" / "occ" / "main.go").write_text("package main\n")
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("test\n")
    kubeconfig.chmod(0o600)
    occ = tmp_path / "occ"
    _write_executable(
        occ,
        """#!/usr/bin/env bash
printf 'occ %s\n' "$*" >>"$TEST_LOG"
receipt=
while (($#)); do
  if [[ "$1" == --receipt ]]; then receipt=$2; shift 2; else shift; fi
done
attempt=${TEST_OCC_ATTEMPT:-attempt-test}
mkdir "$receipt"
printf \
  '{"version":1,"operation":"helm-install","attempt":"%s",'\
'"createdAt":"2026-11-20T00:00:00Z","clusterSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'\
'"namespace":"openclaw-system","release":"oce",'\
'"chartSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",'\
'"valuesSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}\n' \
  "$attempt" \
  >"$receipt/intent.json"
chmod 600 "$receipt/intent.json"
if [[ "${TEST_OCC_PRE_DISPATCH_ONLY:-}" == true ]]; then
  exit 73
fi
printf '%s\n' '{"outcome":"unknown"}' >"$receipt/dispatch.json"
printf '{"outcome":"%s"}\n' "${TEST_OCC_OUTCOME:-succeeded}" \
  >"$receipt/helm-result.json"
chmod 600 "$receipt"/*.json
printf '%s\n' deployed >"$TEST_KUBE_STATE/release-status"
printf '%s\n' "$attempt" >"$TEST_KUBE_STATE/release-attempt"
if [[ "${TEST_OCC_RESPONSE_LOSS:-}" == true ]]; then
  exit 74
fi
""",
    )

    _write_executable(
        fake_bin / "git",
        f"""#!/usr/bin/env bash
if [[ "$*" == *"rev-parse --verify HEAD"* ]]; then
  printf '%s\n' "${{TEST_GIT_HEAD:-{PIN}}}"
elif [[ "$*" == *"status --porcelain"* ]]; then
  :
else
  exit 2
fi
""",
    )
    _write_executable(
        fake_bin / "go",
        f"""#!/usr/bin/env bash
if [[ "$1" == version && "$2" == -m ]]; then
  printf '%s\\n' "$3"
  printf '\\tmod\\tgithub.com/openclaw/openclaw-enterprise\\t(devel)\\n'
  printf '\\tbuild\\tvcs.revision={PIN}\\n'
  printf '\\tbuild\\tvcs.modified=false\\n'
else
  exit 2
fi
""",
    )
    _write_executable(
        fake_bin / "aws",
        f"""#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  *"sts get-caller-identity"*) printf '%s\\n' "${{TEST_ACCOUNT:-{account}}}" ;;
  *"cluster.arn"*) printf 'arn:aws:eks:ap-southeast-2:123456789012:cluster/oce-test\\n' ;;
  *"cluster.status"*) printf 'ACTIVE\\n' ;;
  *"cluster.kubernetesNetworkConfig.serviceIpv4Cidr"*)
    printf '%s\\n' "${{TEST_SERVICE_IPV4_CIDR:-10.100.0.0/16}}" ;;
  *"eks list-tags-for-resource"*)
    printf '%s\\n' "$TEST_CLUSTER_TAGS" ;;
  *"cluster.endpoint"*) printf 'https://eks.example.test\\n' ;;
  *) exit 2 ;;
esac
""",
    )
    _write_executable(
        fake_bin / "openssl",
        """#!/usr/bin/env bash
case "$1" in
  rand)
    count=$((2 * $3))
    for ((index = 0; index < count; index++)); do printf 'b'; done
    printf '\\n'
    ;;
  x509)
    cat >/dev/null
    printf '%s\\n' 'X509v3 Basic Constraints: critical' '    CA:TRUE'
    ;;
  *) exit 2 ;;
esac
""",
    )
    _write_executable(
        fake_bin / "helm",
        """#!/usr/bin/env bash
printf 'helm %s\n' "$*" >>"$TEST_LOG"
case "$1" in
  version) printf '%s\n' "${TEST_HELM_VERSION:-v3.22.1+gtest}" ;;
  list)
    status=
    [[ ! -f "$TEST_KUBE_STATE/release-status" ]] ||
      status=$(<"$TEST_KUBE_STATE/release-status")
    selected=false
    case "$status" in
      deployed) [[ " $* " == *" --deployed "* ]] && selected=true ;;
      failed) [[ " $* " == *" --failed "* ]] && selected=true ;;
      pending-*) [[ " $* " == *" --pending "* ]] && selected=true ;;
      uninstalled) [[ " $* " == *" --uninstalled "* ]] && selected=true ;;
      superseded) [[ " $* " == *" --superseded "* ]] && selected=true ;;
      uninstalling) [[ " $* " == *" --uninstalling "* ]] && selected=true ;;
    esac
    if [[ "$selected" == true ]]; then
      printf '%s\n' oce
    fi
    ;;
  get)
    [[ "$2" == values && "$3" == oce ]] || exit 2
    attempt=${TEST_HELM_ATTEMPT:-}
    if [[ -z "$attempt" && -f "$TEST_KUBE_STATE/release-attempt" ]]; then
      attempt=$(<"$TEST_KUBE_STATE/release-attempt")
    fi
    printf '{"installationAttempt":"%s"}\n' "$attempt"
    ;;
  template) printf '%s\n' 'apiVersion: v1' 'kind: List' 'items: []' ;;
  *) exit 2 ;;
esac
""",
    )
    _write_executable(
        fake_bin / "kubectl",
        """#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$TEST_LOG"
not_found() {
  printf 'Error from server (NotFound): %s not found\\n' "$1" >&2
  exit 1
}
fail_after_delete() {
  local resource=$1
  if [[ "${TEST_FAIL_AFTER_DELETE:-}" == "$resource" &&
    ! -f "$TEST_KUBE_STATE/failed-delete-$resource" ]]; then
    : >"$TEST_KUBE_STATE/failed-delete-$resource"
    exit 42
  fi
}
require_delete_preconditions() {
  local body=$1 expected_uid=$2 expected_resource_version=$3
  if [[ "$(jq -r '.preconditions.uid' <<<"$body")" != "$expected_uid" ||
    "$(jq -r '.preconditions.resourceVersion' <<<"$body")" != \
      "$expected_resource_version" ]]; then
    printf '%s\n' \
      'Error from server (Conflict): deletion precondition failed' >&2
    exit 1
  fi
}
handoff_pod_json() {
  local receipt owner image extra_container
  receipt=${TEST_POD_RECEIPT:-}
  if [[ -z "$receipt" && -f "$TEST_KUBE_STATE/pod-receipt" ]]; then
    receipt=$(<"$TEST_KUBE_STATE/pod-receipt")
  fi
  owner=${TEST_POD_OWNER:-openclaw-enterprise-blueprint}
  image=${TEST_POD_IMAGE:-example/controller@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  extra_container=${TEST_POD_EXTRA_CONTAINER:-false}
  jq -cn \
    --arg uid "${TEST_POD_UID:-uid-bootstrap-pod}" \
    --arg resource_version "${TEST_POD_RESOURCE_VERSION:-103}" \
    --arg receipt "$receipt" \
    --arg owner "$owner" \
    --arg image "$image" \
    --arg extra_container "$extra_container" \
    '{
      metadata: {
        name: "oce-sample-bootstrap-handoff",
        namespace: "openclaw-system",
        uid: $uid,
        resourceVersion: $resource_version,
        labels: {
          "app.kubernetes.io/managed-by": $owner,
          "app.kubernetes.io/part-of": "openclaw-enterprise-blueprint",
          "app.kubernetes.io/component": "bootstrap-handoff"
        },
        annotations: {
          "openclaw.dev/bootstrap-handoff-receipt": $receipt
        }
      },
      spec: {
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
    }
    | if $extra_container == "true"
      then .spec.containers += [{
        name: "sidecar",
        image: "example/attacker:latest"
      }]
      else .
      end'
}
case "$*" in
  *"config get-contexts"*) printf 'oce-test\\n' ;;
  *"config current-context"*) printf 'oce-test\\n' ;;
  *"config view"*) printf 'https://eks.example.test' ;;
  *"get namespace kube-system"*) printf 'namespace/kube-system\\n' ;;
  *"get storageclass gp3 -o json")
    printf '%s\\n' \
      '{"metadata":{"name":"gp3","labels":{"app.kubernetes.io/managed-by":"'"${TEST_STORAGE_OWNER:-openclaw-enterprise-blueprint}"'"}},"provisioner":"'"${TEST_STORAGE_PROVISIONER:-ebs.csi.eks.amazonaws.com}"'","parameters":{"type":"'"${TEST_STORAGE_TYPE:-gp3}"'","encrypted":"'"${TEST_STORAGE_ENCRYPTED:-true}"'"},"reclaimPolicy":"'"${TEST_STORAGE_RECLAIM:-Delete}"'","volumeBindingMode":"'"${TEST_STORAGE_BINDING:-WaitForFirstConsumer}"'"}'
    ;;
  *"get namespace openclaw-system"*"jsonpath"*)
    printf 'openclaw-enterprise-blueprint' ;;
  *"get namespace openclaw-system"*) printf 'namespace/openclaw-system\\n' ;;
  *"get job/oce-sample-bootstrap-volume-prep"*) printf '1' ;;
  *"get job oce-sample-bootstrap-volume-prep -o json")
    [[ ! -f "$TEST_KUBE_STATE/job-deleted" ]] ||
      not_found job/oce-sample-bootstrap-volume-prep
    printf '%s\\n' \
      '{"metadata":{"name":"oce-sample-bootstrap-volume-prep","uid":"'"${TEST_JOB_UID:-uid-bootstrap-job}"'","resourceVersion":"'"${TEST_JOB_RESOURCE_VERSION:-101}"'","labels":{"app.kubernetes.io/managed-by":"'"${TEST_JOB_OWNER:-openclaw-enterprise-blueprint}"'"}}}'
    ;;
  *"get job oce-sample-bootstrap-volume-prep"*"-o name"*)
    [[ ! -f "$TEST_KUBE_STATE/job-deleted" ]] ||
      not_found job/oce-sample-bootstrap-volume-prep
    printf 'job.batch/oce-sample-bootstrap-volume-prep\\n' ;;
  *"get persistentvolumeclaim oce-sample-bootstrap-output -o json")
    [[ ! -f "$TEST_KUBE_STATE/pvc-deleted" ]] ||
      not_found persistentvolumeclaim/oce-sample-bootstrap-output
    printf '%s\\n' \
      '{"metadata":{"name":"oce-sample-bootstrap-output","uid":"'"${TEST_PVC_UID:-uid-bootstrap-pvc}"'","resourceVersion":"'"${TEST_PVC_RESOURCE_VERSION:-102}"'","labels":{"app.kubernetes.io/managed-by":"'"${TEST_PVC_OWNER:-openclaw-enterprise-blueprint}"'"}},"spec":{"volumeName":"'"${TEST_PV_NAME:-pvc-bootstrap-output}"'","storageClassName":"gp3"}}'
    ;;
  *"get persistentvolume/pvc-bootstrap-output -o json")
    [[ ! -f "$TEST_KUBE_STATE/pv-deleted" ]] ||
      not_found persistentvolume/pvc-bootstrap-output
    printf '%s\\n' \
      '{"metadata":{"name":"pvc-bootstrap-output","uid":"'"${TEST_PV_UID:-uid-bootstrap-pv}"'"},"spec":{"storageClassName":"'"${TEST_PV_STORAGE_CLASS:-gp3}"'","persistentVolumeReclaimPolicy":"'"${TEST_PV_RECLAIM:-Delete}"'","csi":{"driver":"'"${TEST_PV_DRIVER:-ebs.csi.eks.amazonaws.com}"'"},"claimRef":{"namespace":"openclaw-system","name":"oce-sample-bootstrap-output","uid":"'"${TEST_PV_CLAIM_UID:-${TEST_PVC_UID:-uid-bootstrap-pvc}}"'"}}}'
    ;;
  *"get pod oce-sample-bootstrap-handoff -o json")
    [[ -f "$TEST_KUBE_STATE/pod-live" ]] ||
      not_found pod/oce-sample-bootstrap-handoff
    handoff_pod_json
    ;;
  *"exec pod/oce-sample-bootstrap-handoff"*"readFileSync"*\
"initial-admin-service-key.json"*)
    [[ -f "$TEST_KUBE_STATE/remote-key" ]] ||
      not_found initial-admin-service-key.json
    printf x >>"$TEST_KUBE_STATE/key-reads"
    printf '%s' '{"data":{"key":"test-service-key"}}' ;;
  *"exec pod/oce-sample-bootstrap-handoff"*"readFileSync"*\
"initial-admin-password"*)
    if [[ "${TEST_FAIL_PASSWORD_READ_ONCE:-}" == true &&
      ! -f "$TEST_KUBE_STATE/failed-password-read" ]]; then
      : >"$TEST_KUBE_STATE/failed-password-read"
      exit 42
    fi
    [[ -f "$TEST_KUBE_STATE/remote-password" ]] ||
      not_found initial-admin-password
    printf '%s' 'test-admin-password' ;;
  *"exec pod/oce-sample-bootstrap-handoff"*"rmSync"*)
    rm -f "$TEST_KUBE_STATE/remote-key"
    if [[ "${TEST_FAIL_ERASE_AFTER_KEY_ONCE:-}" == true &&
      ! -f "$TEST_KUBE_STATE/failed-erase" ]]; then
      : >"$TEST_KUBE_STATE/failed-erase"
      exit 42
    fi
    rm -f "$TEST_KUBE_STATE/remote-password"
    ;;
  *"jsonpath={.metadata.name}"*"metadata.uid"*)
    target=
    previous=
    for argument in "$@"; do
      if [[ "$previous" == get ]]; then target=$argument; break; fi
      previous=$argument
    done
    name=${target##*/}
    owner=openclaw-enterprise-blueprint
    instance=
    if [[ "$name" == oce-openclaw-* ]]; then
      owner=Helm
      instance=oce
    fi
    printf '%s|%s|%s|uid-%s\\n' "$name" "$owner" "$instance" "$name"
    ;;
  *"get "*" -o name"*)
    printf 'resource/owned\\n' ;;
  *"jsonpath={.metadata.labels.app"*) printf 'openclaw-enterprise-blueprint' ;;
  *" exec deployment/oce-validation-only-postgres "*"SHOW server_version_num"*)
    printf '%s\n' "${TEST_POSTGRES_VERSION:-180006}" ;;
  *" exec deployment/oce-validation-only-postgres "*"FROM pg_roles"*)
    printf '%s\n' "${TEST_POSTGRES_ROLE_CONTRACT:-true}" ;;
  *"get service oce-validation-only-postgres"*"jsonpath={.spec.clusterIP}"*)
    printf '10.100.169.63' ;;
  *"jsonpath={.items[*].status.podIP}"*) printf '10.2.3.4' ;;
  *" create "*"bootstrap-handoff.yaml"*"-o json"*)
    if [[ -f "$TEST_KUBE_STATE/pod-live" ]]; then
      printf '%s\n' \
        'Error from server (AlreadyExists): pods "oce-sample-bootstrap-handoff" already exists' >&2
      exit 1
    fi
    manifest=
    previous=
    for argument in "$@"; do
      if [[ "$previous" == -f ]]; then manifest=$argument; break; fi
      previous=$argument
    done
    receipt=$(sed -n \
      's/^[[:space:]]*openclaw.dev\\/bootstrap-handoff-receipt:[[:space:]]*"\\([^"]*\\)"[[:space:]]*$/\\1/p' \
      "$manifest")
    [[ "$receipt" =~ ^[a-f0-9]{64}$ ]] || exit 2
    printf '%s' "$receipt" >"$TEST_KUBE_STATE/pod-receipt"
    : >"$TEST_KUBE_STATE/pod-live"
    handoff_pod_json
    ;;
  *" apply "*) : ;;
  *" delete --raw=/api/v1/namespaces/openclaw-system/pods/oce-sample-bootstrap-handoff -f -")
    body=$(cat)
    require_delete_preconditions "$body" \
      "${TEST_DELETE_POD_UID:-${TEST_POD_UID:-uid-bootstrap-pod}}" \
      "${TEST_DELETE_POD_RESOURCE_VERSION:-${TEST_POD_RESOURCE_VERSION:-103}}"
    rm -f "$TEST_KUBE_STATE/pod-live"
    fail_after_delete pod
    printf '%s\n' '{"kind":"Pod","metadata":{"name":"oce-sample-bootstrap-handoff"}}'
    ;;
  *" delete --raw=/apis/batch/v1/namespaces/openclaw-system/jobs/oce-sample-bootstrap-volume-prep -f -")
    body=$(cat)
    require_delete_preconditions "$body" \
      "${TEST_DELETE_JOB_UID:-${TEST_JOB_UID:-uid-bootstrap-job}}" \
      "${TEST_DELETE_JOB_RESOURCE_VERSION:-${TEST_JOB_RESOURCE_VERSION:-101}}"
    : >"$TEST_KUBE_STATE/job-deleted"
    fail_after_delete job
    printf '%s\n' '{"kind":"Job","metadata":{"name":"oce-sample-bootstrap-volume-prep"}}'
    ;;
  *" delete --raw=/api/v1/namespaces/openclaw-system/persistentvolumeclaims/oce-sample-bootstrap-output -f -")
    body=$(cat)
    require_delete_preconditions "$body" \
      "${TEST_DELETE_PVC_UID:-${TEST_PVC_UID:-uid-bootstrap-pvc}}" \
      "${TEST_DELETE_PVC_RESOURCE_VERSION:-${TEST_PVC_RESOURCE_VERSION:-102}}"
    : >"$TEST_KUBE_STATE/pvc-deleted"
    if [[ "${TEST_STORAGE_RECLAIM:-Delete}" == Delete ]]; then
      : >"$TEST_KUBE_STATE/pv-delete-requested"
    fi
    fail_after_delete pvc
    printf '%s\n' '{"kind":"PersistentVolumeClaim","metadata":{"name":"oce-sample-bootstrap-output"}}'
    ;;
  *" rollout status "*) : ;;
  *" wait --for=delete persistentvolume/pvc-bootstrap-output "*)
    [[ -f "$TEST_KUBE_STATE/pv-delete-requested" ]] || exit 42
    : >"$TEST_KUBE_STATE/pv-deleted"
    if [[ "${TEST_FAIL_PV_WAIT_ONCE:-}" == true &&
      ! -f "$TEST_KUBE_STATE/failed-pv-wait" ]]; then
      : >"$TEST_KUBE_STATE/failed-pv-wait"
      exit 42
    fi
    ;;
  *" wait "*) : ;;
  *) printf 'unexpected kubectl invocation: %s\\n' "$*" >&2; exit 2 ;;
esac
""",
    )
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["TEST_LOG"] = str(log)
    env["TEST_KUBE_STATE"] = str(kube_state)
    env["TEST_CLUSTER_TAGS"] = '{"Environment":"validation"}'
    env.pop("HELM_DRIVER", None)
    for key in list(env):
        if key.startswith("HELM_KUBE"):
            env.pop(key)
    return env, source, kubeconfig, occ


def test_wrong_source_pin_fails_closed(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_GIT_HEAD"] = "0" * 40
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)
    assert result.returncode != 0
    assert "unpinned OCE source" in result.stderr


def test_helm_4_fails_before_aws_or_cluster_access(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_HELM_VERSION"] = "v4.3.0+gtest"
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "pinned OCE revision requires Helm 3; found v4.3.0+gtest" in result.stderr
    calls = (tmp_path / "calls.log").read_text()
    assert calls.splitlines() == ["helm version --short"]
    assert not (tmp_path / "state").exists()


def test_old_validation_postgres_fails_before_oce_install(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_POSTGRES_VERSION"] = "160016"
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert (
        "pinned OCE revision requires PostgreSQL 17 or later; "
        "validation database reported 160016"
    ) in result.stderr
    calls = (tmp_path / "calls.log").read_text()
    assert "SHOW server_version_num" in calls
    assert "occ installation install" not in calls
    assert not (tmp_path / "state" / "receipt").exists()


def test_invalid_validation_database_roles_fail_before_oce_install(
    tmp_path: Path,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_POSTGRES_ROLE_CONTRACT"] = "f"
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert (
        "validation PostgreSQL role contract does not match pinned OCE requirements"
        in result.stderr
    )
    calls = (tmp_path / "calls.log").read_text()
    assert "FROM pg_roles" in calls
    assert "occ installation install" not in calls
    assert not (tmp_path / "state" / "receipt").exists()


def test_wrong_aws_account_fails_closed(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_ACCOUNT"] = "999999999999"
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)
    assert result.returncode != 0
    assert "wrong AWS account" in result.stderr
    assert not (tmp_path / "state" / "receipt").exists()


@pytest.mark.parametrize(
    "bad_url, expected_error",
    [
        (
            (
                "postgresql://app:secret@db.example.test:5432/openclaw"  # pragma: allowlist secret -- test placeholder
                f"?sslmode=require&sslrootcert={DATABASE_CA_PATH}"
            ),
            "must set sslmode=verify-full exactly once",
        ),
        (
            (
                "postgresql://app:secret@db.example.test:5432/openclaw"  # pragma: allowlist secret -- test placeholder
                f"?sslmode=verify-full&sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}"
            ),
            "must not contain duplicate query parameters",
        ),
        (
            (
                "postgresql://app:secret@db.example.test:5432/openclaw"  # pragma: allowlist secret -- test placeholder
                f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}%ZZ"
            ),
            "contains malformed URL escaping",
        ),
        (
            (
                "postgresql://app:secret@not_a_dns_name:5432/openclaw"  # pragma: allowlist secret -- test placeholder
                f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}"
            ),
            "must use a valid DNS hostname",
        ),
    ],
)
def test_external_database_url_failures_are_safe(
    tmp_path: Path, bad_url: str, expected_error: str
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    result = run_script(
        *_external_args(
            tmp_path,
            source,
            kubeconfig,
            occ,
            app_url=bad_url,
        ),
        env=env,
    )
    assert result.returncode != 0
    assert expected_error in result.stderr
    assert "app:secret" not in result.stderr
    assert (tmp_path / "calls.log").read_text().splitlines() == [
        "helm version --short"
    ]


def test_external_database_uses_verified_tls_and_mounted_ca(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    result = run_script(
        *_external_args(tmp_path, source, kubeconfig, occ),
        env=env,
    )
    assert result.returncode == 0, result.stderr

    state = tmp_path / "state"
    values = (state / "values.yaml").read_text()
    assert "caSecretName: oce-sample-database-ca" in values
    assert "caKey: ca.pem" in values
    assert "caMountPath: /etc/openclaw/database-ca" in values

    ca_secret = yaml.safe_load((state / "database-ca-secret.yaml").read_text())
    assert ca_secret["metadata"]["name"] == "oce-sample-database-ca"
    assert base64.b64decode(ca_secret["data"]["ca.pem"]) == TEST_CA.encode()

    system_secrets = {
        document["metadata"]["name"]: document
        for document in yaml.safe_load_all((state / "system-secrets.yaml").read_text())
    }
    database_data = system_secrets["oce-sample-database"]["data"]
    for key in ("application-url", "migration-url"):
        decoded = base64.b64decode(database_data[key])
        assert b"sslmode=verify-full" in decoded
        assert f"sslrootcert={DATABASE_CA_PATH}".encode() in decoded
        assert not decoded.endswith(b"\n")


@pytest.mark.parametrize(
    "tags, accepted",
    [
        ('{"Environment":"VALIDATION"}', True),
        ('{"environment":"validation"}', False),
        ('{"Environment":"production"}', False),
        ('{"Environment":"validation","Stage":"PROD"}', False),
    ],
)
def test_validation_postgres_requires_exact_nonproduction_tag(
    tmp_path: Path, tags: str, accepted: bool
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_CLUSTER_TAGS"] = tags
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)
    if accepted:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0
        if "prod" in tags.casefold():
            assert "rejects production-tagged EKS clusters" in result.stderr
        else:
            assert "requires the exact EKS tag Environment=validation" in result.stderr
        assert not (tmp_path / "state" / "receipt").exists()


def test_fake_cluster_contract_dispatches_occ_with_explicit_inputs(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)
    assert result.returncode == 0, result.stderr
    assert (
        "Topology: terminal-managed; embedded Harnesses only; direct Pod API clients "
        "and browser routing disabled."
    ) in result.stdout
    state = tmp_path / "state"
    values = (state / "values.yaml").read_text()
    values_document = yaml.safe_load(values)
    installation = (state / "installation.yaml").read_text()
    installation_document = yaml.safe_load(installation)
    api_clients = values_document["api"]["clients"]
    assert api_clients == [
        {
            "namespace": "openclaw-system",
            "podLabels": DISABLED_DIRECT_API_CLIENT_SELECTOR,
        }
    ]
    assert api_clients[0]["podLabels"]
    gateway_clients = installation_document["drivers"]["compute"]["configuration"][
        "network"
    ]["gatewayClients"]
    assert gateway_clients == [
        {
            "namespace": "openclaw-system",
            "podLabels": DISABLED_DIRECT_API_CLIENT_SELECTOR,
        }
    ]
    assert installation_document["drivers"]["compute"]["configuration"]["runtime"][
        "modelProvider"
    ] == {
        "protocol": "openai-responses",
        "baseUrl": MODEL_PROVIDER_BASE_URL,
    }
    assert "gatewayRouting:\n  enabled: false" in values
    assert "agentNativeAdmin:\n  enabled: false" in values
    assert "10.100.169.63/32" in values
    assert "10.2.3.4/32" not in values
    assert (state / "cluster-dns-cidr").read_text() == "10.100.0.10/32"
    dns_policy = yaml.safe_load(
        (state / "eks-cluster-dns-network-policy.yaml").read_text()
    )
    assert dns_policy["metadata"] == {
        "name": "oce-eks-cluster-dns",
        "namespace": "openclaw-system",
        "labels": {
            "app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint",
            "app.kubernetes.io/part-of": "openclaw-enterprise-blueprint",
        },
    }
    assert dns_policy["spec"]["podSelector"]["matchLabels"] == {
        "app.kubernetes.io/name": "openclaw-enterprise",
        "app.kubernetes.io/instance": "oce",
    }
    assert dns_policy["spec"]["podSelector"]["matchExpressions"] == [
        {
            "key": "app.kubernetes.io/component",
            "operator": "In",
            "values": ["api", "worker", "initialization"],
        }
    ]
    assert dns_policy["spec"]["policyTypes"] == ["Egress"]
    assert dns_policy["spec"]["egress"] == [
        {
            "to": [{"ipBlock": {"cidr": "10.100.0.10/32"}}],
            "ports": [
                {"protocol": "UDP", "port": 53},
                {"protocol": "TCP", "port": 53},
            ],
        }
    ]
    assert "0.0.0.0/0" not in (state / "eks-cluster-dns-network-policy.yaml").read_text()
    assert "gatewayClients:" in installation
    assert "gatewayRouting:" not in installation
    assert "includeDefaults: false" in installation
    assert not (state / "api-cli-client.yaml").exists()
    assert "oce-api-cli-client" not in (state / "rendered.yaml").read_text()
    for path in (
        state / "auth-secret",
        state / "validation-postgres-password",
        state / "validation-postgres-migration-password",
        state / "validation-postgres-app-password",
        state / "database-application-url",
        state / "database-migration-url",
    ):
        assert not path.read_bytes().endswith(b"\n")
    app_url = (state / "database-application-url").read_text()
    migration_url = (state / "database-migration-url").read_text()
    assert app_url.startswith("postgresql://occ_app:")
    assert migration_url.startswith("postgresql://occ_migrator:")
    assert app_url != migration_url
    validation_secret = yaml.safe_load(
        (state / "validation-postgres-secret.yaml").read_text()
    )
    init_sql = base64.b64decode(validation_secret["data"]["init.sql"]).decode()
    assert "CREATE ROLE occ_migrator LOGIN PASSWORD " in init_sql
    assert "CREATE ROLE occ_app LOGIN PASSWORD " in init_sql
    assert "GRANT CREATE ON DATABASE openclaw TO occ_migrator;" in init_sql
    assert "CREATE SCHEMA occ AUTHORIZATION occ_migrator;" in init_sql
    assert "CREATE SCHEMA drizzle AUTHORIZATION occ_migrator;" in init_sql
    assert "REVOKE CREATE ON SCHEMA public FROM PUBLIC;" in init_sql
    system_secrets = {
        document["metadata"]["name"]: document
        for document in yaml.safe_load_all((state / "system-secrets.yaml").read_text())
    }
    assert not base64.b64decode(
        system_secrets["oce-sample-auth"]["data"]["secret"]
    ).endswith(b"\n")
    calls = (tmp_path / "calls.log").read_text()
    assert "oce-api-cli-client" not in calls
    assert "deployment/oce-api-cli-client" not in calls
    helm_list = next(
        line for line in calls.splitlines() if line.startswith("helm list ")
    )
    assert "--all" not in helm_list.split()
    for status in (
        "--deployed",
        "--failed",
        "--pending",
        "--uninstalled",
        "--superseded",
        "--uninstalling",
    ):
        assert status in helm_list.split()
    assert "eks list-tags-for-resource" in calls
    assert "FROM pg_roles" in calls
    assert "occ installation install" in calls
    for expected in (
        f"--kubeconfig {kubeconfig}",
        "--context oce-test",
        "--kube-namespace openclaw-system",
        f"--values {state / 'values.yaml'}",
        f"--receipt {state / 'receipt'}",
    ):
        assert expected in calls
    assert (state / "receipt").is_dir()
    resource_receipt = json.loads((state / "receipt" / "resources.json").read_text())
    assert resource_receipt["version"] == 1
    assert resource_receipt["attempt"] == "attempt-test"
    assert set(resource_receipt["resources"]) == RECEIPT_RESOURCE_KEYS
    assert all(
        uid.startswith("uid-") for uid in resource_receipt["resources"].values()
    )
    assert stat.S_IMODE(
        (state / "receipt" / "resources.json").stat().st_mode
    ) == 0o600
    assert json.loads((state / "initial-admin-service-key.json").read_text()) == {
        "data": {"key": "test-service-key"}
    }
    assert (state / "initial-admin-password").read_text() == "test-admin-password"
    assert stat.S_IMODE(
        (state / "initial-admin-service-key.json").stat().st_mode
    ) == 0o600
    assert stat.S_IMODE((state / "initial-admin-password").stat().st_mode) == 0o600
    handoff = yaml.safe_load((state / "bootstrap-handoff.yaml").read_text())
    handoff_spec = handoff["spec"]
    assert re.fullmatch(
        r"[a-f0-9]{64}",
        handoff["metadata"]["annotations"][
            "openclaw.dev/bootstrap-handoff-receipt"
        ],
    )
    assert handoff_spec["automountServiceAccountToken"] is False
    assert handoff_spec["containers"][0]["imagePullPolicy"] == "IfNotPresent"
    assert handoff_spec["containers"][0]["volumeMounts"] == [
        {"name": "bootstrap", "mountPath": "/bootstrap"}
    ]
    assert (
        "exec pod/oce-sample-bootstrap-handoff"
        in calls
    )
    assert " create " in calls
    assert "bootstrap-handoff.yaml -o json" in calls
    assert " apply " + str(state / "bootstrap-handoff.yaml") not in calls
    assert (
        "delete --raw=/api/v1/namespaces/openclaw-system/"
        "pods/oce-sample-bootstrap-handoff -f -"
    ) in calls
    assert (
        "delete --raw=/apis/batch/v1/namespaces/openclaw-system/"
        "jobs/oce-sample-bootstrap-volume-prep -f -"
    ) in calls
    assert (
        "delete --raw=/api/v1/namespaces/openclaw-system/"
        "persistentvolumeclaims/oce-sample-bootstrap-output -f -"
    ) in calls
    assert "wait --for=delete persistentvolume/pvc-bootstrap-output" in calls
    assert (state / "install.complete").is_file()


def test_missing_jq_fails_before_external_commands(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    fake_bin = Path(env["PATH"].split(os.pathsep)[0])
    isolated_bin = tmp_path / "isolated-bin"
    isolated_bin.mkdir()
    for command in (
        "bash",
        "dirname",
        "aws",
        "kubectl",
        "helm",
        "git",
        "go",
        "openssl",
        "base64",
        "python3",
        "install",
        "mktemp",
        "sed",
        "grep",
        "tr",
        "stat",
    ):
        candidate = fake_bin / command
        source_path = candidate if candidate.exists() else Path(
            shutil.which(command, path=env["PATH"]) or ""
        )
        assert source_path.is_file(), command
        os.symlink(source_path, isolated_bin / command)
    env["PATH"] = str(isolated_bin)

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "missing prerequisite: jq" in result.stderr
    assert not (tmp_path / "calls.log").exists()
    assert not (tmp_path / "state").exists()


@pytest.mark.parametrize(
    ("variable", "value"),
    [
        ("TEST_STORAGE_OWNER", "another-installer"),
        ("TEST_STORAGE_PROVISIONER", "kubernetes.io/aws-ebs"),
        ("TEST_STORAGE_TYPE", "gp2"),
        ("TEST_STORAGE_ENCRYPTED", "false"),
        ("TEST_STORAGE_RECLAIM", "Retain"),
        ("TEST_STORAGE_BINDING", "Immediate"),
    ],
)
def test_storage_class_contract_fails_before_cluster_mutation(
    tmp_path: Path,
    variable: str,
    value: str,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env[variable] = value

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "StorageClass gp3 must be blueprint-owned encrypted gp3" in result.stderr
    calls = (tmp_path / "calls.log").read_text()
    assert " apply " not in calls
    assert "occ installation install" not in calls


@pytest.mark.parametrize(
    "status",
    ["failed", "pending-install", "uninstalling"],
)
def test_non_deployed_helm_release_is_not_resumable(
    tmp_path: Path,
    status: str,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    (Path(env["TEST_KUBE_STATE"]) / "release-status").write_text(f"{status}\n")

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "exists but is not deployed" in result.stderr
    assert "occ installation install" not in (tmp_path / "calls.log").read_text()


@pytest.mark.parametrize(
    ("variable", "value"),
    [
        ("TEST_PV_STORAGE_CLASS", "other"),
        ("TEST_PV_RECLAIM", "Retain"),
        ("TEST_PV_DRIVER", "example.invalid/csi"),
        ("TEST_PV_CLAIM_UID", "uid-other-claim"),
    ],
)
def test_bound_pv_contract_fails_before_occ(
    tmp_path: Path,
    variable: str,
    value: str,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env[variable] = value

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "persistent volume does not match" in result.stderr
    assert "occ installation install" not in (tmp_path / "calls.log").read_text()


@pytest.mark.parametrize(
    ("variable", "value"),
    [
        ("TEST_FAIL_PASSWORD_READ_ONCE", "true"),
        ("TEST_FAIL_ERASE_AFTER_KEY_ONCE", "true"),
        ("TEST_FAIL_AFTER_DELETE", "pod"),
        ("TEST_FAIL_AFTER_DELETE", "job"),
        ("TEST_FAIL_AFTER_DELETE", "pvc"),
        ("TEST_FAIL_PV_WAIT_ONCE", "true"),
    ],
)
def test_post_occ_failures_resume_without_reinstalling(
    tmp_path: Path,
    variable: str,
    value: str,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env[variable] = value
    args = _base_args(tmp_path, source, kubeconfig, occ)

    first = run_script(*args, env=env)
    assert first.returncode != 0

    second = run_script(*args, env=env)
    assert second.returncode == 0, second.stderr

    state = tmp_path / "state"
    kube_state = Path(env["TEST_KUBE_STATE"])
    calls = (tmp_path / "calls.log").read_text()
    assert calls.count("occ installation install") == 1
    assert (state / "initial-admin-service-key.json").is_file()
    assert (state / "initial-admin-password").is_file()
    assert not (state / "bootstrap-handoff-state.json").exists()
    assert not (kube_state / "remote-key").exists()
    assert not (kube_state / "remote-password").exists()
    assert (kube_state / "job-deleted").is_file()
    assert (kube_state / "pvc-deleted").is_file()
    assert (kube_state / "pv-deleted").is_file()


def test_interrupted_remote_read_copies_no_partial_credentials(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_FAIL_PASSWORD_READ_ONCE"] = "true"  # pragma: allowlist secret -- test control name
    args = _base_args(tmp_path, source, kubeconfig, occ)

    first = run_script(*args, env=env)

    state = tmp_path / "state"
    assert first.returncode != 0
    assert not (state / "initial-admin-service-key.json").exists()
    assert not (state / "initial-admin-password").exists()
    journal = json.loads((state / "bootstrap-handoff-state.json").read_text())
    assert journal["version"] == 3
    assert journal["phase"] == "handoff-pod-ready"
    assert journal["podUid"] == "uid-bootstrap-pod"
    assert re.fullmatch(r"[a-f0-9]{64}", journal["podReceipt"])
    handoff = yaml.safe_load((state / "bootstrap-handoff.yaml").read_text())
    assert (
        handoff["metadata"]["annotations"][
            "openclaw.dev/bootstrap-handoff-receipt"
        ]
        == journal["podReceipt"]
    )
    assert journal["occAttempt"] == "attempt-test"
    assert journal["credentialKeySha256"] == ""
    assert journal["credentialPasswordSha256"] == ""

    second = run_script(*args, env=env)
    assert second.returncode == 0, second.stderr
    assert (Path(env["TEST_KUBE_STATE"]) / "key-reads").read_text() == "xx"
    assert (tmp_path / "calls.log").read_text().count(
        "bootstrap-handoff.yaml -o json"
    ) == 1


def test_existing_local_credential_must_match_cluster_copy(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    state = tmp_path / "state"
    state.mkdir(mode=0o700)
    key = state / "initial-admin-service-key.json"
    key.write_text('{"data":{"key":"unrelated-service-key"}}')
    key.chmod(0o600)

    result = run_script(
        *_base_args(tmp_path, source, kubeconfig, occ),
        env=env,
    )

    assert result.returncode != 0
    assert "does not match the deployed installation" in result.stderr
    kube_state = Path(env["TEST_KUBE_STATE"])
    assert (kube_state / "remote-key").is_file()
    assert (kube_state / "remote-password").is_file()


def test_recorded_local_credential_hashes_gate_retry(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_FAIL_ERASE_AFTER_KEY_ONCE"] = "true"
    args = _base_args(tmp_path, source, kubeconfig, occ)
    first = run_script(*args, env=env)
    assert first.returncode != 0

    state = tmp_path / "state"
    journal = json.loads((state / "bootstrap-handoff-state.json").read_text())
    assert journal["version"] == 3
    assert journal["phase"] == "credentials-local"
    assert re.fullmatch(r"[a-f0-9]{64}", journal["credentialKeySha256"])
    assert re.fullmatch(r"[a-f0-9]{64}", journal["credentialPasswordSha256"])
    password = state / "initial-admin-password"
    password.write_text("different-valid-password")
    password.chmod(0o600)

    retry = run_script(*args, env=env)

    assert retry.returncode != 0
    assert "does not match the handoff journal" in retry.stderr
    assert (Path(env["TEST_KUBE_STATE"]) / "remote-password").is_file()


def test_resume_rejects_helm_attempt_mismatching_receipt(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_FAIL_PASSWORD_READ_ONCE"] = "true"  # pragma: allowlist secret -- test-only fault injection
    args = _base_args(tmp_path, source, kubeconfig, occ)
    assert run_script(*args, env=env).returncode != 0
    env["TEST_HELM_ATTEMPT"] = "attempt-replaced"

    retry = run_script(*args, env=env)

    assert retry.returncode != 0
    assert "does not match the OCC receipt attempt" in retry.stderr
    assert (tmp_path / "calls.log").read_text().count("occ installation install") == 1


def test_undispatched_receipt_requires_a_new_receipt_directory(
    tmp_path: Path,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_OCC_PRE_DISPATCH_ONLY"] = "true"
    args = _base_args(tmp_path, source, kubeconfig, occ)
    first = run_script(*args, env=env)
    assert first.returncode != 0
    receipt = tmp_path / "state" / "receipt"
    assert (receipt / "intent.json").is_file()
    assert not (receipt / "dispatch.json").exists()

    retry = run_script(*args, env=env)

    assert retry.returncode != 0
    assert "records an undispatched intent" in retry.stderr
    assert "new --receipt directory" in retry.stderr
    assert (tmp_path / "calls.log").read_text().count(
        "occ installation install"
    ) == 1


def test_occ_receipt_must_prove_success(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_OCC_OUTCOME"] = "failed"

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "does not prove a successful install" in result.stderr
    assert not (tmp_path / "state" / "install.complete").exists()


def test_recovered_occ_receipt_is_accepted(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_OCC_OUTCOME"] = "recovered"

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode == 0, result.stderr


def test_occ_response_loss_recovers_without_reinstalling(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_OCC_RESPONSE_LOSS"] = "true"
    args = _base_args(tmp_path, source, kubeconfig, occ)

    first = run_script(*args, env=env)
    assert first.returncode != 0

    env.pop("TEST_OCC_RESPONSE_LOSS")
    second = run_script(*args, env=env)

    assert second.returncode == 0, second.stderr
    assert (tmp_path / "calls.log").read_text().count(
        "occ installation install"
    ) == 1


def test_precreated_handoff_pod_is_neither_adopted_nor_deleted(
    tmp_path: Path,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    kube_state = Path(env["TEST_KUBE_STATE"])
    (kube_state / "pod-live").touch()
    env["TEST_POD_RECEIPT"] = "b" * 64

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert (
        "refusing to adopt existing pod/oce-sample-bootstrap-handoff "
        "without a journalled UID"
    ) in result.stderr
    assert (kube_state / "pod-live").is_file()
    calls = (tmp_path / "calls.log").read_text()
    assert "bootstrap-handoff.yaml -o json" in calls
    assert "exec pod/oce-sample-bootstrap-handoff" not in calls
    assert "delete --raw=" not in calls


def test_retry_rejects_replaced_handoff_pod_uid(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_FAIL_PASSWORD_READ_ONCE"] = "true"  # pragma: allowlist secret -- test-only fault injection
    args = _base_args(tmp_path, source, kubeconfig, occ)
    first = run_script(*args, env=env)
    assert first.returncode != 0
    calls_before_retry = (tmp_path / "calls.log").read_text()
    env["TEST_POD_UID"] = "uid-replacement-pod"

    retry = run_script(*args, env=env)

    assert retry.returncode != 0
    assert (
        "refusing to recover replaced pod/oce-sample-bootstrap-handoff"
        in retry.stderr
    )
    calls = (tmp_path / "calls.log").read_text()
    assert calls.count("bootstrap-handoff.yaml -o json") == 1
    assert calls.count("exec pod/oce-sample-bootstrap-handoff") == (
        calls_before_retry.count("exec pod/oce-sample-bootstrap-handoff")
    )
    assert (Path(env["TEST_KUBE_STATE"]) / "pod-live").is_file()


@pytest.mark.parametrize(
    ("variable", "value"),
    [
        ("TEST_POD_RECEIPT", "c" * 64),
        ("TEST_POD_EXTRA_CONTAINER", "true"),
        (
            "TEST_POD_IMAGE",
            "example/other@sha256:" + "d" * 64,
        ),
    ],
)
def test_retry_rejects_tampered_handoff_pod(
    tmp_path: Path,
    variable: str,
    value: str,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_FAIL_PASSWORD_READ_ONCE"] = "true"  # pragma: allowlist secret -- test-only fault injection
    args = _base_args(tmp_path, source, kubeconfig, occ)
    first = run_script(*args, env=env)
    assert first.returncode != 0
    calls_before_retry = (tmp_path / "calls.log").read_text()
    env[variable] = value

    retry = run_script(*args, env=env)

    assert retry.returncode != 0
    assert (
        "does not match its journalled receipt and canonical specification"
        in retry.stderr
    )
    calls = (tmp_path / "calls.log").read_text()
    assert calls.count("bootstrap-handoff.yaml -o json") == 1
    assert calls.count("exec pod/oce-sample-bootstrap-handoff") == (
        calls_before_retry.count("exec pod/oce-sample-bootstrap-handoff")
    )
    assert (Path(env["TEST_KUBE_STATE"]) / "pod-live").is_file()


def test_retry_rejects_replaced_job_identity_before_delete(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_FAIL_AFTER_DELETE"] = "pod"
    args = _base_args(tmp_path, source, kubeconfig, occ)
    assert run_script(*args, env=env).returncode != 0
    env["TEST_JOB_UID"] = "uid-replacement-job"

    retry = run_script(*args, env=env)

    assert retry.returncode != 0
    assert "refusing to delete replaced job/" in retry.stderr
    assert not (Path(env["TEST_KUBE_STATE"]) / "job-deleted").exists()


def test_raw_delete_uses_resource_version_precondition(tmp_path: Path) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_DELETE_JOB_RESOURCE_VERSION"] = "resource-version-changed"

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "preconditioned deletion failed for job/" in result.stderr
    assert not (Path(env["TEST_KUBE_STATE"]) / "job-deleted").exists()


@pytest.mark.parametrize(
    "service_cidr",
    ["not-a-cidr", "fd00::/108", "10.100.0.0/30"],
)
def test_invalid_service_cidr_fails_before_cluster_mutation(
    tmp_path: Path,
    service_cidr: str,
) -> None:
    env, source, kubeconfig, occ = _fake_environment(tmp_path)
    env["TEST_SERVICE_IPV4_CIDR"] = service_cidr

    result = run_script(*_base_args(tmp_path, source, kubeconfig, occ), env=env)

    assert result.returncode != 0
    assert "EKS cluster service IPv4 CIDR" in result.stderr
    calls = (tmp_path / "calls.log").read_text()
    assert " apply " not in calls
    assert "occ installation install" not in calls


def test_readme_targets_cert_manager_at_the_explicit_context() -> None:
    readme = README.read_text(encoding="utf-8")
    cert_manager_step = readme.split(
        "Install the pinned cert-manager release", 1
    )[1].split("cert-manager is a shared cluster prerequisite", 1)[0]

    assert re.search(
        r"helm upgrade --install cert-manager\s*\\?\s*"
        r"oci://quay\.io/jetstack/charts/cert-manager\s*\\?\s*"
        r'--kube-context "\$KUBE_CONTEXT"',
        cert_manager_step,
    )


def test_readme_derives_network_inputs_and_pins_validation_postgres() -> None:
    readme = README.read_text(encoding="utf-8")
    install_step = readme.split("**Step 6: Install the pinned OCE revision**", 1)[
        1
    ].split("**Step 7:", 1)[0]

    assert re.search(
        r"OCE_VALIDATION_POSTGRES_IMAGE='[^']+@sha256:[0-9a-f]{64}'",
        install_step,
    )
    assert (
        "OCE_VALIDATION_POSTGRES_IMAGE="
        f"'public.ecr.aws/docker/library/postgres@sha256:{VALIDATION_POSTGRES_DIGEST}'"
    ) in install_step
    assert "| Validation PostgreSQL | OCE-qualified `18.6`" in readme
    assert "sample_pod_ip=" in install_step
    assert "ipaddress.ip_network" in install_step
    assert "cluster.resourcesVpcConfig.clusterSecurityGroupId" in install_step
    assert '"Name=description,Values=Amazon EKS $EKS_CLUSTER_NAME"' in install_step
    assert "'Name=requester-managed,Values=true'" in install_step
    assert "socket.getaddrinfo" not in install_step
    assert 'cluster_api_cidr_args+=(--cluster-api-cidr "$ip/32")' in install_step
    assert '"${cluster_api_cidr_args[@]}"' in install_step


def test_readme_requires_a_preexisting_validation_cluster_tag() -> None:
    readme = README.read_text(encoding="utf-8")
    install_step = readme.split("**Step 6: Install the pinned OCE revision**", 1)[
        1
    ].split("**Step 7:", 1)[0]

    assert "aws eks list-tags-for-resource" in install_step
    assert '"$cluster_environment" != validation' in install_step
    assert "aws eks tag-resource" not in readme


def test_readme_changes_to_repository_root_before_static_tests() -> None:
    readme = README.read_text(encoding="utf-8")
    validation_step = readme.split(
        "**Step 8: Validate the two-tenant boundary**", 1
    )[1].split("**Step 9:", 1)[0]

    assert 'cd "$(git -C "$SAMPLE_DIR" rev-parse --show-toplevel)"' in validation_step
