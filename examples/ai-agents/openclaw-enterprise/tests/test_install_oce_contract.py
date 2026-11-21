from __future__ import annotations

import base64
import json
import os
import re
import stat
import subprocess
from pathlib import Path

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "install-oce.sh"
POSTGRES = ROOT / "deploy" / "oce-validation-postgres.yaml"
README = ROOT / "README.md"
PIN = "86c8c12310f691bb21651118ffffd6bfd460e9ff"
DIGEST = "a" * 64
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
    "storageclass.storage.k8s.io/gp3",
    "validatingadmissionpolicies.admissionregistration.k8s.io/"
    "protect-openclaw-enterprise-namespace-label",
    "validatingadmissionpolicybindings.admissionregistration.k8s.io/"
    "protect-openclaw-enterprise-namespace-label",
    "mutatingwebhookconfigurations.admissionregistration.k8s.io/"
    "openclaw-enterprise-nitro-adapter",
    "validatingwebhookconfigurations.admissionregistration.k8s.io/"
    "openclaw-enterprise-nitro-policy",
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
    assert "kube context endpoint does not match EKS cluster" in text
    assert "refusing to adopt existing" in text
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
    assert "__OCE_VALIDATION_POSTGRES_IMAGE__" == pod_spec["containers"][0]["image"]
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
        "postgresql://oce_app:app-secret@db.example.test:5432/openclaw"
        f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}"
    )
    default_migration_url = (
        "postgresql://oce_migrator:migration-secret@db.example.test:5432/openclaw"
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
mkdir "$receipt"
printf '%s\n' \
  '{"version":1,"operation":"helm-install","attempt":"attempt-test",'\
'"createdAt":"2026-11-20T00:00:00Z","clusterSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'\
'"namespace":"openclaw-system","release":"oce",'\
'"chartSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",'\
'"valuesSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}' \
  >"$receipt/intent.json"
printf '%s\n' '{"outcome":"unknown"}' >"$receipt/dispatch.json"
printf '%s\n' '{"outcome":"succeeded"}' >"$receipt/helm-result.json"
chmod 600 "$receipt"/*.json
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
  list) : ;;
  template) printf '%s\n' 'apiVersion: v1' 'kind: List' 'items: []' ;;
  *) exit 2 ;;
esac
""",
    )
    _write_executable(
        fake_bin / "kubectl",
        """#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  *"config get-contexts"*) printf 'oce-test\\n' ;;
  *"config current-context"*) printf 'oce-test\\n' ;;
  *"config view"*) printf 'https://eks.example.test' ;;
  *"get namespace kube-system"*) printf 'namespace/kube-system\\n' ;;
  *"get storageclass gp3"*) printf 'storageclass.storage.k8s.io/gp3\\n' ;;
  *"get namespace openclaw-system"*"jsonpath"*)
    printf 'openclaw-enterprise-blueprint' ;;
  *"get namespace openclaw-system"*) printf 'namespace/openclaw-system\\n' ;;
  *"get job/oce-sample-bootstrap-volume-prep"*) printf '1' ;;
  *"get job oce-sample-bootstrap-volume-prep"*"-o name"*)
    printf 'job.batch/oce-sample-bootstrap-volume-prep\\n' ;;
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
  *"jsonpath={.items[*].status.podIP}"*) printf '10.2.3.4' ;;
  *" apply "*) : ;;
  *" rollout status "*) : ;;
  *" wait "*) : ;;
  *) printf 'unexpected kubectl invocation: %s\\n' "$*" >&2; exit 2 ;;
esac
""",
    )
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["TEST_LOG"] = str(log)
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
            "postgresql://app:secret@db.example.test:5432/openclaw"
            f"?sslmode=require&sslrootcert={DATABASE_CA_PATH}",
            "must set sslmode=verify-full exactly once",
        ),
        (
            "postgresql://app:secret@db.example.test:5432/openclaw"
            f"?sslmode=verify-full&sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}",
            "must not contain duplicate query parameters",
        ),
        (
            "postgresql://app:secret@db.example.test:5432/openclaw"
            f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}%ZZ",
            "contains malformed URL escaping",
        ),
        (
            "postgresql://app:secret@not_a_dns_name:5432/openclaw"
            f"?sslmode=verify-full&sslrootcert={DATABASE_CA_PATH}",
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
    assert "10.2.3.4/32" in values
    assert "gatewayClients:" in installation
    assert "gatewayRouting:" not in installation
    assert "includeDefaults: false" in installation
    assert not (state / "api-cli-client.yaml").exists()
    assert "oce-api-cli-client" not in (state / "rendered.yaml").read_text()
    for path in (
        state / "auth-secret",
        state / "validation-postgres-password",
        state / "database-application-url",
        state / "database-migration-url",
    ):
        assert not path.read_bytes().endswith(b"\n")
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
    assert (state / "install.complete").is_file()


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
