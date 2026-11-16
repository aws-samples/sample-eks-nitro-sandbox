"""Static contracts for the CodeBuild and ECR source-build path."""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys
from typing import Any

import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
BUILD = SAMPLE / "build"
TEMPLATE = BUILD / "template.yaml"
SCRIPT = BUILD / "build-images.sh"
SCAN_CHECK = BUILD / "check-image-scan.py"
INSPECTOR_SCAN_CHECK = BUILD / "check-inspector-scan.py"
OCE_LOCK_CHECK = BUILD / "check-oce-lock.py"
CONTROLLER_DOCKERFILE = BUILD / "controller-runtime.Dockerfile"
OWNERSHIP_HELPER = SAMPLE / "ownership-helper"
OWNERSHIP_HELPER_DOCKERFILE = OWNERSHIP_HELPER / "Dockerfile"


class _CloudFormationLoader(yaml.SafeLoader):
    pass


def _construct_tagged(
    loader: _CloudFormationLoader, tag_suffix: str, node: yaml.Node
) -> Any:
    del tag_suffix
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


_CloudFormationLoader.add_multi_constructor("!", _construct_tagged)


def _template() -> dict[str, Any]:
    return yaml.load(
        TEMPLATE.read_text(encoding="utf-8"), Loader=_CloudFormationLoader
    )


def _resources(resource_type: str) -> list[dict[str, Any]]:
    return [
        resource
        for resource in _template()["Resources"].values()
        if resource["Type"] == resource_type
    ]


def _buildspec() -> str:
    project = _resources("AWS::CodeBuild::Project")
    assert len(project) == 1
    return project[0]["Properties"]["Source"]["BuildSpec"]


def test_template_creates_four_immutable_scan_on_push_repositories() -> None:
    repositories = _resources("AWS::ECR::Repository")

    assert len(repositories) == 4
    assert {
        repository["Properties"]["RepositoryName"] for repository in repositories
    } == {
        "${RepositoryPrefix}/adapter",
        "${RepositoryPrefix}/controller",
        "${RepositoryPrefix}/ownership-helper",
        "${RepositoryPrefix}/runtime",
    }
    for repository in repositories:
        properties = repository["Properties"]
        assert properties["ImageTagMutability"] == "IMMUTABLE"
        assert properties["ImageScanningConfiguration"] == {"ScanOnPush": True}
        assert properties["EncryptionConfiguration"] == {
            "EncryptionType": "KMS",
            "KmsKey": "ImageEncryptionKey.Arn",
        }


def test_codebuild_has_no_local_source_and_exports_digest_outputs() -> None:
    project = _resources("AWS::CodeBuild::Project")[0]["Properties"]
    buildspec = project["Source"]["BuildSpec"]

    assert project["Source"]["Type"] == "NO_SOURCE"
    assert project["Artifacts"]["Type"] == "NO_ARTIFACTS"
    assert project["Environment"]["PrivilegedMode"] is True
    assert project["Environment"]["ImagePullCredentialsType"] == "CODEBUILD"
    assert set(
        yaml.safe_load(buildspec)["env"]["exported-variables"]
    ) == {
        "ADAPTER_IMAGE",
        "CONTROLLER_IMAGE",
        "OWNERSHIP_INIT_IMAGE",
        "RUNTIME_IMAGE",
        "SAMPLE_SOURCE_REVISION",
        "OCE_SOURCE_REVISION",
    }
    assert "git -C \"$SAMPLE_SOURCE_DIR\" fetch --depth 1 origin" in buildspec
    assert (
        'test "$(git -C "$SAMPLE_SOURCE_DIR" rev-parse FETCH_HEAD)" '
        '= "$SAMPLE_GIT_REVISION"' in buildspec
    )
    assert "build/build-images.sh" in buildspec


def test_source_revisions_are_full_commit_shas() -> None:
    parameters = _template()["Parameters"]

    for name in ("SampleGitRevision", "OceGitRevision"):
        assert parameters[name]["AllowedPattern"] == "^[0-9a-f]{40}$"
    assert parameters["OceGitRevision"]["Default"] == (
        "86c8c12310f691bb21651118ffffd6bfd460e9ff"
    )


def test_privileged_build_sources_are_restricted_to_canonical_repositories() -> None:
    parameters = _template()["Parameters"]

    assert parameters["SampleRepositoryUrl"]["AllowedValues"] == [
        "https://github.com/aws-samples/sample-eks-nitro-sandbox.git"
    ]
    assert parameters["OceRepositoryUrl"]["AllowedValues"] == [
        "https://github.com/openclaw/openclaw-enterprise.git"
    ]


def test_repository_encryption_key_rotates() -> None:
    keys = _resources("AWS::KMS::Key")

    assert len(keys) == 1
    assert keys[0]["Properties"]["EnableKeyRotation"] is True


def test_codebuild_role_is_scoped_to_logs_and_the_four_repositories() -> None:
    role = _resources("AWS::IAM::Role")[0]
    statements = role["Properties"]["Policies"][0]["PolicyDocument"]["Statement"]
    actions = {
        action
        for statement in statements
        for action in (
            statement["Action"]
            if isinstance(statement["Action"], list)
            else [statement["Action"]]
        )
    }

    assert actions == {
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImageScanFindings",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "inspector2:ListCoverage",
        "inspector2:ListFindings",
    }
    logs_statement = next(
        statement for statement in statements if statement["Sid"] == "WriteBuildLogs"
    )
    assert set(logs_statement["Resource"]) == {
        (
            "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:"
            "log-group:/aws/codebuild/openclaw-enterprise-images"
        ),
        (
            "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:"
            "log-group:/aws/codebuild/openclaw-enterprise-images:*"
        ),
    }
    push_statement = next(
        statement for statement in statements if statement["Sid"] == "PushAndVerifyImages"
    )
    assert set(push_statement["Resource"]) == {
        "AdapterRepository.Arn",
        "ControllerRepository.Arn",
        "OwnershipHelperRepository.Arn",
        "RuntimeRepository.Arn",
    }
    token_statement = next(
        statement
        for statement in statements
        if statement["Sid"] == "GetEcrAuthorizationToken"
    )
    assert token_statement["Resource"] == "*"
    inspector_statement = next(
        statement
        for statement in statements
        if statement["Sid"] == "VerifyEnhancedImageScans"
    )
    assert inspector_statement["Resource"] == "*"


def test_build_script_builds_each_image_from_the_expected_source() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
    assert "require_value CODEBUILD_BUILD_ARN" in script
    assert "require_sha SAMPLE_GIT_REVISION" in script
    assert "require_sha OCE_GIT_REVISION" in script
    assert 'git -C "$OCE_SOURCE_DIR" fetch --depth 1 origin "$OCE_GIT_REVISION"' in script
    assert (
        '[[ "$OCE_SOURCE_REVISION" == "$OCE_GIT_REVISION" ]]'
        in script
    )
    assert (
        '"$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/adapter"'
        in script
    )
    assert (
        '"$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/'
        'ownership-helper"'
        in script
    )
    assert "--build-arg \"OWNERSHIP_HELPER_BUILDER_IMAGE=" in script
    assert "--target runtime" in script
    assert "require_digest_image CONTROLLER_RUNTIME_BASE_IMAGE" in script
    assert (
        '--build-arg "NODE_BUILD_BASE_IMAGE=$node_base_image"'
        in script
    )
    assert (
        '--build-arg "NODE_RUNTIME_BASE_IMAGE=$CONTROLLER_RUNTIME_BASE_IMAGE"'
        in script
    )
    assert (
        '--file "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/'
        'build/controller-runtime.Dockerfile"'
        in script
    )
    assert '--file "$OCE_SOURCE_DIR/deploy/runtime/Dockerfile"' in script
    assert "node scripts/lib/openclaw-source.mjs build-args" in script
    assert "OCE_MSAL_NODE_VERSION=\"7.2.0\"" in script
    assert "check-oce-lock.py" in script
    assert script.count("docker buildx build") == 4
    assert "docker pull" not in script
    assert "skopeo copy" not in script


def test_controller_runtime_uses_a_separate_pinned_base_and_drops_build_tools() -> None:
    dockerfile = CONTROLLER_DOCKERFILE.read_text(encoding="utf-8")

    assert "ARG NODE_BUILD_BASE_IMAGE" in dockerfile
    assert "ARG NODE_RUNTIME_BASE_IMAGE" in dockerfile
    assert "FROM ${NODE_BUILD_BASE_IMAGE} AS dependencies" in dockerfile
    assert dockerfile.count("FROM ${NODE_RUNTIME_BASE_IMAGE}") == 2
    runtime = dockerfile.split(
        "FROM ${NODE_RUNTIME_BASE_IMAGE} AS runtime", maxsplit=1
    )[1]
    assert "FROM ${NODE_BUILD_BASE_IMAGE}" not in runtime
    assert (
        "COPY --from=runtime-dependencies --chown=node:node "
        "/app/node_modules node_modules"
        in runtime
    )
    for workspace in (
        "apps/controller",
        "packages/audit",
        "packages/contracts",
        "packages/iam",
        "packages/occ",
    ):
        assert (
            "COPY --from=runtime-dependencies --chown=node:node "
            f"/app/{workspace}/node_modules {workspace}/node_modules"
            in runtime
        )
    assert "COPY --from=dependencies" not in runtime
    assert (
        "RUN --mount=type=bind,source=pnpm-lock.yaml,"
        "target=/app/pnpm-lock.yaml,readonly"
        in runtime
    )
    assert "COPY --chown=node:node pnpm-lock.yaml" not in runtime
    assert "delete packageJson.devDependencies" in runtime
    assert "delete packageJson.scripts" in runtime
    assert "delete packageJson.packageManager" in runtime
    assert "/usr/local/lib/node_modules/npm" in runtime
    assert "/usr/local/lib/node_modules/corepack" in runtime
    for package in (
        "esbuild@*",
        "@esbuild+*",
        "@esbuild-kit+*",
        "tsx@*",
        "drizzle-kit@*",
    ):
        assert package in dockerfile
    assert 'ENTRYPOINT ["node"]' in runtime
    assert 'CMD ["apps/controller/src/server.mjs"]' in runtime


def test_default_controller_runtime_base_is_digest_pinned() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assignment = re.search(
        r"CONTROLLER_RUNTIME_BASE_IMAGE=\""
        r"\$\{CONTROLLER_RUNTIME_BASE_IMAGE:-([^}]+)\}\"",
        script,
    )

    assert assignment is not None
    assert re.fullmatch(
        r"public\.ecr\.aws/docker/library/node:24-bookworm-slim@sha256:[0-9a-f]{64}",
        assignment.group(1),
    )


def test_build_outputs_are_verified_digest_references() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    assert 'digest = json.load(handle).get("containerimage.digest", "")' in script
    assert 'aws ecr describe-images \\' in script
    assert "aws ecr describe-image-scan-findings" in script
    assert 'grep -Fq "ScanNotFoundException"' in script
    assert "aws inspector2 list-coverage" in script
    assert "aws inspector2 list-findings" in script
    assert script.count("--no-paginate") == 2
    assert '"resourceId": equals(resource_id)' in script
    assert '"ecrImageHash": equals(digest)' in script
    assert '"findingStatus": equals("ACTIVE")' in script
    assert "check-image-scan.py" in script
    assert "check-inspector-scan.py" in script
    assert script.count('verify_scan "$') == 4
    for name in (
        "ADAPTER_IMAGE",
        "CONTROLLER_IMAGE",
        "OWNERSHIP_INIT_IMAGE",
        "RUNTIME_IMAGE",
    ):
        assert re.search(
            rf'{name}="\$\{{REGISTRY\}}/\$\{{[A-Z_]+REPOSITORY\}}'
            r'@\$\{[a-z_]+digest\}"',
            script,
        )
    assert "printf 'export OWNERSHIP_INIT_IMAGE=%q\\n'" in script
    assert '"ownershipHelper": {' in script
    assert '"image": os.environ["OWNERSHIP_INIT_IMAGE"]' in script


def _scan_result(payload: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(SCAN_CHECK)],
        check=False,
        input=json.dumps(payload),
        text=True,
        capture_output=True,
    )


def _scan_payload(
    status: str,
    counts: dict[str, int],
    completed_at: str | None = "2026-11-16T00:00:00Z",
) -> dict[str, object]:
    return {
        "imageScanStatus": {"status": status},
        "imageScanFindings": {
            "imageScanCompletedAt": completed_at,
            "findingSeverityCounts": counts,
        },
    }


def test_scan_gate_accepts_clean_basic_and_enhanced_results() -> None:
    for status in ("COMPLETE", "ACTIVE"):
        result = _scan_result(_scan_payload(status, {"MEDIUM": 2}))

        assert result.returncode == 0, result.stderr
        assert f"image scan: {status} with CRITICAL=0, HIGH=0" in result.stdout


def test_scan_gate_rejects_any_critical_or_high_finding() -> None:
    for counts in ({"CRITICAL": 1}, {"HIGH": 1}, {"CRITICAL": 2, "HIGH": 3}):
        result = _scan_result(_scan_payload("ACTIVE", counts))

        assert result.returncode == 1
        assert "image scan: scan found" in result.stderr


def test_scan_gate_waits_for_pending_or_unfinished_enhanced_scan() -> None:
    for payload in (
        _scan_payload("PENDING", {}),
        _scan_payload("IN_PROGRESS", {}),
        _scan_payload("ACTIVE", {}, completed_at=None),
    ):
        result = _scan_result(payload)

        assert result.returncode == 10


def test_scan_gate_fails_closed_on_unknown_or_incomplete_results() -> None:
    for payload in (
        _scan_payload("FAILED", {}),
        {"imageScanStatus": {"status": "COMPLETE"}},
        {
            "imageScanStatus": {"status": "COMPLETE"},
            "imageScanFindings": {"imageScanCompletedAt": "now"},
        },
        _scan_payload("COMPLETE", {"HIGH": "0"}),  # type: ignore[dict-item]
    ):
        result = _scan_result(payload)

        assert result.returncode == 1


def _inspector_scan_result(
    tmp_path: pathlib.Path,
    coverage: object,
    findings: object,
) -> subprocess.CompletedProcess[str]:
    coverage_path = tmp_path / "coverage.json"
    findings_path = tmp_path / "findings.json"
    coverage_path.write_text(json.dumps(coverage), encoding="utf-8")
    findings_path.write_text(json.dumps(findings), encoding="utf-8")
    return subprocess.run(
        [
            sys.executable,
            "-I",
            str(INSPECTOR_SCAN_CHECK),
            str(coverage_path),
            str(findings_path),
            INSPECTOR_RESOURCE_ID,
            INSPECTOR_ACCOUNT,
            INSPECTOR_REPOSITORY,
            INSPECTOR_DIGEST,
        ],
        check=False,
        text=True,
        capture_output=True,
    )


INSPECTOR_ACCOUNT = "123456789012"
INSPECTOR_REPOSITORY = "sample/ownership-helper"
INSPECTOR_DIGEST = f"sha256:{'a' * 64}"
INSPECTOR_RESOURCE_ID = (
    f"arn:aws:ecr:us-west-2:{INSPECTOR_ACCOUNT}:"
    f"repository/{INSPECTOR_REPOSITORY}/{INSPECTOR_DIGEST}"
)


def _inspector_coverage(reason: str = "SUCCESSFUL") -> dict[str, object]:
    return {
        "coveredResources": [
            {
                "resourceType": "AWS_ECR_CONTAINER_IMAGE",
                "resourceId": INSPECTOR_RESOURCE_ID,
                "accountId": INSPECTOR_ACCOUNT,
                "scanType": "PACKAGE",
                "scanStatus": {"statusCode": "ACTIVE", "reason": reason},
                "resourceMetadata": {
                    "ecrRepository": {
                        "name": INSPECTOR_REPOSITORY,
                        "scanFrequency": "CONTINUOUS_SCAN",
                    }
                },
                "lastScannedAt": "2026-11-16T00:00:00Z",
            }
        ]
    }


def _inspector_finding(severity: str = "HIGH") -> dict[str, object]:
    return {
        "findingArn": "arn:aws:inspector2:us-west-2:123456789012:finding/example",
        "awsAccountId": INSPECTOR_ACCOUNT,
        "status": "ACTIVE",
        "severity": severity,
        "resources": [
            {
                "type": "AWS_ECR_CONTAINER_IMAGE",
                "id": INSPECTOR_RESOURCE_ID,
                "details": {
                    "awsEcrContainerImage": {
                        "repositoryName": INSPECTOR_REPOSITORY,
                        "imageHash": INSPECTOR_DIGEST,
                        "registry": INSPECTOR_ACCOUNT,
                    }
                },
            }
        ],
    }


def test_inspector_gate_accepts_successful_coverage_with_no_severe_findings(
    tmp_path: pathlib.Path,
) -> None:
    result = _inspector_scan_result(
        tmp_path,
        _inspector_coverage(),
        {"findings": []},
    )

    assert result.returncode == 0, result.stderr
    assert "ACTIVE with CRITICAL=0, HIGH=0" in result.stdout


def test_inspector_gate_rejects_critical_or_high_finding(
    tmp_path: pathlib.Path,
) -> None:
    for severity in ("CRITICAL", "HIGH"):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            {"findings": [_inspector_finding(severity)]},
        )

        assert result.returncode == 1
        assert f"scan found {severity} finding" in result.stderr


def test_inspector_gate_retries_pending_or_missing_coverage(
    tmp_path: pathlib.Path,
) -> None:
    for coverage in (
        {"coveredResources": []},
        _inspector_coverage("PENDING_INITIAL_SCAN"),
        _inspector_coverage("SCAN_IN_PROGRESS"),
    ):
        result = _inspector_scan_result(tmp_path, coverage, {"findings": []})

        assert result.returncode == 10


def test_inspector_gate_fails_closed_on_mismatched_or_failed_responses(
    tmp_path: pathlib.Path,
) -> None:
    wrong_resource = _inspector_coverage()
    wrong_resource["coveredResources"][0]["resourceId"] = (  # type: ignore[index]
        f"arn:aws:ecr:us-west-2:{INSPECTOR_ACCOUNT}:"
        f"repository/{INSPECTOR_REPOSITORY}/sha256:{'b' * 64}"
    )
    for coverage, findings in (
        (_inspector_coverage("UNSUPPORTED_OS"), {"findings": []}),
        (wrong_resource, {"findings": []}),
        (_inspector_coverage(), {}),
        (_inspector_coverage(), {"findings": [{"severity": "MEDIUM"}]}),
    ):
        result = _inspector_scan_result(tmp_path, coverage, findings)

        assert result.returncode == 1


def _oce_lock_result(tmp_path: pathlib.Path, content: str) -> subprocess.CompletedProcess[str]:
    lockfile = tmp_path / "pnpm-lock.yaml"
    lockfile.write_text(content, encoding="utf-8")
    return subprocess.run(
        [sys.executable, "-I", str(OCE_LOCK_CHECK), str(lockfile), "7.2.0"],
        check=False,
        text=True,
        capture_output=True,
    )


def test_oce_lock_gate_accepts_only_the_exact_remediated_version(
    tmp_path: pathlib.Path,
) -> None:
    result = _oce_lock_result(
        tmp_path,
        "packages:\n  '@azure/msal-node@7.2.0':\n"
        "snapshots:\n  '@azure/msal-node@7.2.0':\n",
    )

    assert result.returncode == 0, result.stderr
    assert "exact-pinned to remediated 7.2.0" in result.stdout


def test_oce_lock_gate_rejects_vulnerable_mixed_and_missing_entries(
    tmp_path: pathlib.Path,
) -> None:
    for content in (
        "packages:\n  '@azure/msal-node@6.0.1':\n",
        (
            "packages:\n  '@azure/msal-node@7.2.0':\n"
            "snapshots:\n  '@azure/msal-node@6.0.1':\n"
        ),
        "packages: {}\n",
    ):
        result = _oce_lock_result(tmp_path, content)

        assert result.returncode == 1
        assert "OCE lock:" in result.stderr


def test_ownership_helper_builds_a_compiled_binary() -> None:
    dockerfile = OWNERSHIP_HELPER_DOCKERFILE.read_text(encoding="utf-8")
    script = SCRIPT.read_text(encoding="utf-8")

    dockerfile_builder = re.search(
        r"^ARG OWNERSHIP_HELPER_BUILDER_IMAGE="
        r"(?P<image>[^@\s]+@sha256:[0-9a-f]{64})$",
        dockerfile,
        re.MULTILINE,
    )
    script_builder = re.search(
        r'^OWNERSHIP_HELPER_BUILDER_IMAGE="'
        r'(?P<image>[^@\s]+@sha256:[0-9a-f]{64})"$',
        script,
        re.MULTILINE,
    )
    assert dockerfile_builder
    assert script_builder
    assert dockerfile_builder.group("image") == script_builder.group("image")
    assert "RUN go test ./..." in dockerfile
    assert "go build -buildvcs=false -trimpath" in dockerfile
    assert any(
        path.suffix in {".c", ".cc", ".cpp", ".go", ".rs"}
        for path in OWNERSHIP_HELPER.rglob("*")
        if path.is_file()
    )


def test_ownership_helper_final_image_contains_only_the_compiled_helper() -> None:
    dockerfile = OWNERSHIP_HELPER_DOCKERFILE.read_text(encoding="utf-8")
    stages = re.split(r"(?=^FROM\s)", dockerfile, flags=re.MULTILINE)
    final_stage = stages[-1]

    assert final_stage.startswith("FROM scratch")
    copy_destinations = re.findall(
        r"^COPY(?:\s+--from=\S+)?\s+\S+\s+(?P<destination>\S+)$",
        final_stage,
        re.MULTILINE,
    )
    assert copy_destinations == ["/ownership-helper"]
    assert "/bin/sh" not in final_stage
    assert "/bin/chown" not in final_stage
    assert "/bin/chmod" not in final_stage
