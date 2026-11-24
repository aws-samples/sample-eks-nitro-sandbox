"""Static contracts for the CodeBuild and ECR source-build path."""

from __future__ import annotations

import hashlib
import json
import os
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
ENHANCED_SCAN_CHECK = BUILD / "check-enhanced-scanning.py"
OCE_LOCK_CHECK = BUILD / "check-oce-lock.py"
OCE_SECURITY_PATCHER = BUILD / "apply-oce-security-patches.py"
OPENSSL_BACKPORT_PATCH = BUILD / "patches" / "openssl-cve-2026-95692.patch"
OPENSSL_88823_BACKPORT_PATCH = (
    BUILD / "patches" / "openssl-cve-2026-88823.patch"
)
OPENSSL_88823_TEST_PATCH = (
    BUILD / "patches" / "openssl-cve-2026-88823-test.patch"
)
OPENSSL_88823_SOURCE_ASSETS = BUILD / "openssl"
OPENSSL_88823_UPSTREAM_COMMIT = (
    "159e1de0c448d7b9f09ad768c8e141def4aa1eb4"  # pragma: allowlist secret -- public source revision
)
OPENSSL_88823_UPSTREAM_REFERENCE = (
    "https://github.com/openssl/openssl/commit/"
    f"{OPENSSL_88823_UPSTREAM_COMMIT}"
)
OPENSSL_107496_BACKPORT_PATCH = (
    BUILD / "patches" / "openssl-cve-2026-107496.patch"
)
OPENSSL_107496_UPSTREAM_COMMIT = (
    "a0051cfe699bf5a047bc1c4faef65f80f7987366"  # pragma: allowlist secret -- public source revision
)
OPENSSL_107496_UPSTREAM_REFERENCE = (
    "https://github.com/openssl/openssl/commit/"
    f"{OPENSSL_107496_UPSTREAM_COMMIT}"
)
OPENCLAW_DEPENDENCY_PATCH = (
    BUILD / "patches" / "openclaw-security-overrides.patch"
)
CURL_BACKPORT_PATCH = (
    BUILD / "patches" / "curl-cve-2026-86414-trixie.patch"
)
ADAPTER_DOCKERFILE = SAMPLE / "adapter" / "Dockerfile"
CONTROLLER_DOCKERFILE = BUILD / "controller-runtime.Dockerfile"
OWNERSHIP_HELPER = SAMPLE / "ownership-helper"
OWNERSHIP_HELPER_DOCKERFILE = OWNERSHIP_HELPER / "Dockerfile"
STACK_MANAGER = SAMPLE / "scripts" / "manage-image-build-stack.sh"
BUILDER_REPOSITORY_MANAGER = SAMPLE / "scripts" / "manage-builder-repository.sh"
REPOSITORY_ROOT = SAMPLE.parents[2]
WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "openclaw-enterprise.yml"
CI_REQUIREMENTS = SAMPLE / "tests" / "requirements-ci.txt"


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
    loader = _CloudFormationLoader(TEMPLATE.read_text(encoding="utf-8"))
    try:
        template = loader.get_single_data()
    finally:
        loader.dispose()
    if not isinstance(template, dict):
        raise TypeError("CloudFormation template must contain a mapping")
    return template


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


def test_image_build_has_disk_for_the_pinned_oce_runtime() -> None:
    project = _resources("AWS::CodeBuild::Project")
    assert len(project) == 1
    assert project[0]["Properties"]["Environment"]["ComputeType"] == (
        "BUILD_GENERAL1_XLARGE"
    )


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


def test_sample_workflow_pins_runner_toolchains_and_hashed_dependencies() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    requirements = CI_REQUIREMENTS.read_text(encoding="utf-8")

    assert "runs-on: ubuntu-24.04" in workflow
    assert "python-version: '3.12.16'" in workflow
    assert "go-version: '1.25.14'" in workflow
    assert "node-version: '24.22.1'" in workflow
    assert "--require-hashes" in workflow
    assert "tests/requirements-ci.txt" in workflow
    assert "- 'README.md'" in workflow
    assert "examples/README.md" not in workflow
    for dependency in (
        "cfn-lint==1.47.1",
        "mkdocs==1.6.1",
        "mkdocs-material==9.7.7",
        "pymdown-extensions==12.1",
        "pytest==9.0.3",
        "pyyaml==6.0.3",
        "ruff==0.17.6",
    ):
        assert dependency in requirements
    assert " --hash=sha256:" in requirements
    assert not re.search(
        r"(?m)^\s*(?:-e|--editable|-f|--find-links|https?://)", requirements
    )


def test_ecr_repositories_are_empty_on_stack_delete() -> None:
    repositories = _resources("AWS::ECR::Repository")

    assert {
        repository["Properties"]["RepositoryName"]: repository["Properties"].get(
            "EmptyOnDelete"
        )
        for repository in repositories
    } == {
        "${RepositoryPrefix}/adapter": True,
        "${RepositoryPrefix}/controller": True,
        "${RepositoryPrefix}/ownership-helper": True,
        "${RepositoryPrefix}/runtime": True,
    }


def test_readme_requires_nodejs_22_or_later_for_live_validation() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    prerequisites = readme.split("## Prerequisites", 1)[1].split("## Overview", 1)[0]

    assert re.search(r"\bDocker\b", prerequisites)
    assert re.search(
        r"\bNode(?:\.js)?\s+(?:v?22\+|v?22\s+or\s+(?:later|newer))",
        prerequisites,
        re.IGNORECASE,
    ), "README prerequisites must require Node.js 22 or later"


def test_readme_builds_a_pinned_scanned_builder_and_resolves_the_principal() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    build_step = readme.split("**Step 2: Build and scan the images**", 1)[1].split(
        "**Step 3:", 1
    )[0]
    stack_manager = STACK_MANAGER.read_text(encoding="utf-8")
    builder_dockerfile = (BUILD / "codebuild-builder.Dockerfile").read_text(
        encoding="utf-8"
    )

    assert re.search(
        r"^FROM public\.ecr\.aws/docker/library/alpine:"
        r"[^@\s]+@sha256:[0-9a-f]{64}$",
        builder_dockerfile,
        re.MULTILINE,
    )
    assert "apk upgrade --no-cache" in builder_dockerfile
    assert "apk add --no-cache" in builder_dockerfile
    for required_package in (
        "aws-cli",
        "bash",
        "coreutils",
        "docker",
        "docker-cli-buildx",
        "git",
        "nodejs",
        "python3",
    ):
        assert required_package in builder_dockerfile
    assert "ENV DOCKER_HOST=unix:///var/run/docker.sock" in builder_dockerfile
    assert "dockerd --version" in builder_dockerfile
    assert "docker buildx version" in builder_dockerfile
    assert "docker build \\" in build_step
    assert "--platform linux/amd64" in build_step
    assert "--pull" in build_step
    assert 'build/codebuild-builder.Dockerfile"' in build_step
    assert 'manage-builder-repository.sh" create' in build_step
    assert "BUILDER_REPOSITORY_RECEIPT" in build_step
    assert '--builder-repository "$BUILDER_REPOSITORY"' in build_step
    assert '--builder-digest "$BUILDER_DIGEST"' in build_step
    assert '--trusted-build-invoker-arn "$TRUSTED_BUILD_INVOKER_ARN"' in build_step
    assert '"BuilderImageRepositoryName=$builder_repository"' in stack_manager
    assert '"BuilderImageDigest=$builder_digest"' in stack_manager
    assert "verify_builder_scan" in stack_manager
    builder_scan = stack_manager.split("verify_builder_scan() {", 1)[1].split(
        "\n}\n\nfor command", 1
    )[0]
    builder_findings = builder_scan.split("aws inspector2 list-findings", 1)[1].split(
        "--output json", 1
    )[0]
    assert "--no-paginate" not in builder_findings
    assert "--max-results" not in builder_findings
    assert '"TrustedBuildInvokerArn=$trusted_invoker_arn"' in stack_manager
    assert "aws iam get-role" in readme


def test_readme_resolves_private_eks_api_addresses_from_control_plane_enis() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    install_step = readme.split("**Step 6: Install the pinned OCE revision**", 1)[
        1
    ].split("**Step 7:", 1)[0]

    assert "cluster.resourcesVpcConfig.clusterSecurityGroupId" in install_step
    assert '"Name=description,Values=Amazon EKS $EKS_CLUSTER_NAME"' in install_step
    assert "'Name=requester-managed,Values=true'" in install_step
    assert "'Name=status,Values=in-use'" in install_step
    assert "socket.getaddrinfo" not in install_step
    assert '"${cluster_api_cidr_args[@]}"' in install_step


def test_readme_deletes_only_the_builder_repository_owned_by_this_run() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    cleanup = readme.split("## Clean up", 1)[1]

    assert 'manage-builder-repository.sh" delete' in cleanup
    assert "BUILDER_REPOSITORY_RECEIPT" in cleanup
    manager = BUILDER_REPOSITORY_MANAGER.read_text(encoding="utf-8")
    assert "aws ecr list-tags-for-resource" in manager
    assert "OpenClawValidationRun" in manager
    assert "aws ecr delete-repository" in manager


def test_readme_disables_xtrace_before_loading_temporary_credentials() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    build_step = readme.split("**Step 2: Build and scan the images**", 1)[1].split(
        "**Step 3:", 1
    )[0]

    assert build_step.index("set +x") < build_step.index('credentials="$(')


def test_codebuild_has_no_local_source_and_exports_digest_outputs() -> None:
    project = _resources("AWS::CodeBuild::Project")[0]["Properties"]
    buildspec = project["Source"]["BuildSpec"]

    assert project["Source"]["Type"] == "NO_SOURCE"
    assert project["Artifacts"]["Type"] == "NO_ARTIFACTS"
    assert project["Environment"]["PrivilegedMode"] is True
    assert project["Environment"]["ImagePullCredentialsType"] == "SERVICE_ROLE"
    assert set(yaml.safe_load(buildspec)["env"]["exported-variables"]) == {
        "ADAPTER_IMAGE",
        "CONTROLLER_IMAGE",
        "OWNERSHIP_INIT_IMAGE",
        "RUNTIME_IMAGE",
        "SAMPLE_SOURCE_REVISION",
        "OCE_SOURCE_REVISION",
    }
    assert 'git -C "$SAMPLE_SOURCE_DIR" fetch --depth 1 origin' in buildspec
    assert (
        'test "$(git -C "$SAMPLE_SOURCE_DIR" rev-parse FETCH_HEAD)" '
        '= "$SAMPLE_GIT_REVISION"' in buildspec
    )
    assert (
        'test "$(git -C "$SAMPLE_SOURCE_DIR" remote get-url origin)" '
        '= "$SAMPLE_REPOSITORY_URL"' in buildspec
    )
    assert "build/build-images.sh" in buildspec


def test_codebuild_starts_docker_before_building_images() -> None:
    commands = yaml.safe_load(_buildspec())["phases"]["build"]["commands"]

    start_index = commands.index(
        "dockerd --host=unix:///var/run/docker.sock "
        "--storage-driver=vfs "
        ">/tmp/dockerd.log 2>&1 &"
    )
    ready_index = next(
        index
        for index, command in enumerate(commands)
        if "docker info --format" in command
        and "cat /tmp/dockerd.log >&2; exit 1" in command
    )
    build_index = commands.index(
        "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/"
        "build/build-images.sh"
    )

    assert start_index < ready_index < build_index


def test_stack_inputs_are_exact_revisions_and_a_controller_digest() -> None:
    parameters = _template()["Parameters"]
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")

    for name in ("SampleGitRevision", "OceGitRevision"):
        assert parameters[name]["AllowedPattern"] == "^[0-9a-f]{40}$"
    oce_revision = parameters["OceGitRevision"]["Default"]
    assert re.fullmatch(r"[0-9a-f]{40}", oce_revision)
    assert oce_revision in readme
    controller_digest = parameters["ControllerRuntimeBaseImageDigest"]
    assert controller_digest["AllowedPattern"] == "^sha256:[0-9a-f]{64}$"
    assert re.fullmatch(
        r"sha256:[0-9a-f]{64}",
        controller_digest["Default"],
    )


def test_node_build_and_runtime_bases_come_from_the_pinned_oce_source() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    assert "read_oce_dockerfile_arg()" in script
    assert "require_matching_oce_node_bases()" in script
    assert "read_oce_dockerfile_arg NODE_BASE_IMAGE" in script
    assert "read_oce_dockerfile_arg NODE_RUNTIME_BASE_IMAGE" in script
    assert "@sha256:[0-9a-f]{64}$" in script
    assert "-trixie@sha256:" in script
    assert "-trixie-slim@sha256:" in script
    assert "bookworm" not in script


def test_node_base_guard_accepts_only_matching_trixie_images() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    function_match = re.search(
        r"(?ms)^require_matching_oce_node_bases\(\) \{\n.*?^\}\n",
        script,
    )
    assert function_match is not None
    function_source = function_match.group(0)
    digest = "a" * 64
    valid_build = f"docker.io/library/node:24.22.1-trixie@sha256:{digest}"
    valid_runtime = f"docker.io/library/node:24.22.1-trixie-slim@sha256:{digest}"

    def run_guard(
        build_image: str, runtime_image: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                "-c",
                (
                    "set -euo pipefail\n"
                    "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n"
                    f"{function_source}\n"
                    'require_matching_oce_node_bases "$1" "$2"\n'
                ),
                "guard",
                build_image,
                runtime_image,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    assert run_guard(valid_build, valid_runtime).returncode == 0
    assert (
        run_guard(
            valid_build,
            f"docker.io/library/node:24.23.0-trixie-slim@sha256:{digest}",
        ).returncode
        != 0
    )
    assert (
        run_guard(valid_build.replace("@sha256:", ":"), valid_runtime).returncode != 0
    )
    assert run_guard(valid_build, valid_runtime.replace("-slim", "")).returncode != 0


def test_buildspec_defensively_rebinds_environment_input_overrides() -> None:
    project = _resources("AWS::CodeBuild::Project")[0]["Properties"]
    buildspec = project["Source"]["BuildSpec"]

    assert "EnvironmentVariables" not in project["Environment"]
    assert "SampleRepositoryUrl" not in _template()["Parameters"]
    assert "OceRepositoryUrl" not in _template()["Parameters"]
    for binding in (
        "export AWS_ACCOUNT_ID='${AWS::AccountId}'; readonly AWS_ACCOUNT_ID",
        "export AWS_DEFAULT_REGION='${AWS::Region}'; readonly AWS_DEFAULT_REGION",
        (
            "export SAMPLE_REPOSITORY_URL="
            "'https://github.com/aws-samples/sample-eks-nitro-sandbox.git'; "
            "readonly SAMPLE_REPOSITORY_URL"
        ),
        (
            "export SAMPLE_GIT_REVISION='${SampleGitRevision}'; "
            "readonly SAMPLE_GIT_REVISION"
        ),
        "export OCE_GIT_REVISION='${OceGitRevision}'; readonly OCE_GIT_REVISION",
        (
            "export CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST="
            "'${ControllerRuntimeBaseImageDigest}'; "
            "readonly CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST"
        ),
        (
            "export ADAPTER_REPOSITORY='${AdapterRepository}'; "
            "readonly ADAPTER_REPOSITORY"
        ),
        (
            "export CONTROLLER_REPOSITORY='${ControllerRepository}'; "
            "readonly CONTROLLER_REPOSITORY"
        ),
        (
            "export OWNERSHIP_HELPER_REPOSITORY='${OwnershipHelperRepository}'; "
            "readonly OWNERSHIP_HELPER_REPOSITORY"
        ),
        (
            "export RUNTIME_REPOSITORY='${RuntimeRepository}'; "
            "readonly RUNTIME_REPOSITORY"
        ),
        ("export TARGET_PLATFORM='${TargetPlatform}'; readonly TARGET_PLATFORM"),
    ):
        assert binding in buildspec


def test_buildspec_replaces_and_locks_environment_overrides_after_start() -> None:
    commands = yaml.safe_load(_buildspec())["phases"]["build"]["commands"]
    bindings = [command for command in commands if "; readonly " in command]
    replacements = {
        "${AWS::AccountId}": "123456789012",
        "${AWS::Region}": "us-west-2",
        "${SampleGitRevision}": "a" * 40,
        "${OceGitRevision}": "b" * 40,
        "${ControllerRuntimeBaseImageDigest}": f"sha256:{'c' * 64}",
        "${AdapterRepository}": "openclaw-enterprise/adapter",
        "${ControllerRepository}": "openclaw-enterprise/controller",
        "${OwnershipHelperRepository}": "openclaw-enterprise/ownership-helper",
        "${RuntimeRepository}": "openclaw-enterprise/runtime",
        "${TargetPlatform}": "linux/amd64",
    }
    expected = {
        "AWS_ACCOUNT_ID": "123456789012",
        "AWS_DEFAULT_REGION": "us-west-2",
        "SAMPLE_REPOSITORY_URL": (
            "https://github.com/aws-samples/sample-eks-nitro-sandbox.git"
        ),
        "SAMPLE_GIT_REVISION": "a" * 40,
        "OCE_GIT_REVISION": "b" * 40,
        "CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST": f"sha256:{'c' * 64}",
        "ADAPTER_REPOSITORY": "openclaw-enterprise/adapter",
        "CONTROLLER_REPOSITORY": "openclaw-enterprise/controller",
        "OWNERSHIP_HELPER_REPOSITORY": "openclaw-enterprise/ownership-helper",
        "RUNTIME_REPOSITORY": "openclaw-enterprise/runtime",
        "TARGET_PLATFORM": "linux/amd64",
        "SAMPLE_SOURCE_DIR": "/codebuild/output/src/sample-source",
        "BUILD_OUTPUT_ENV": "/codebuild/output/src/image-build.env",
    }
    resolved = []
    for command in bindings:
        for placeholder, value in replacements.items():
            command = command.replace(placeholder, value)
        resolved.append(command)
    assertions = [
        f'test "${{{name}}}" = {json.dumps(value)}' for name, value in expected.items()
    ]
    assertions.extend(
        f"declare -p {name} | grep -Eq '^declare -[^ ]*r[^ ]*x|^declare -[^ ]*x[^ ]*r'"
        for name in expected
    )
    assertions.append(
        'bash -c \'test "$SAMPLE_GIT_REVISION" = '
        f'"{"a" * 40}" && test "$CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST" = '
        f'"sha256:{"c" * 64}"\''
    )
    environment = os.environ.copy()
    environment["CODEBUILD_SRC_DIR"] = "/codebuild/output/src"
    environment.update({name: "attacker-controlled" for name in expected})

    result = subprocess.run(
        ["bash", "-c", "\n".join([*resolved, *assertions])],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr


def test_repository_encryption_key_rotates() -> None:
    key = _template()["Resources"]["ImageEncryptionKey"]

    assert key["Type"] == "AWS::KMS::Key"
    assert key["Properties"]["EnableKeyRotation"] is True


def test_build_log_groups_use_a_rotating_customer_managed_key() -> None:
    template = _template()
    key = template["Resources"]["BuildEncryptionKey"]
    log_groups = _resources("AWS::Logs::LogGroup")

    assert key["Type"] == "AWS::KMS::Key"
    assert key["Properties"]["EnableKeyRotation"] is True
    assert {log_group["Properties"]["LogGroupName"] for log_group in log_groups} == {
        "/aws/codebuild/openclaw-enterprise-images-${ValidationRunId}",
        "/aws/vendedlogs/states/openclaw-enterprise-image-build-${ValidationRunId}",
    }
    for log_group in log_groups:
        assert log_group["Properties"]["KmsKeyId"] == "BuildEncryptionKey.Arn"
        assert log_group["Properties"]["RetentionInDays"] == 365


def test_codebuild_role_is_scoped_to_builder_logs_scans_and_release_repositories() -> (
    None
):
    role = next(
        resource
        for resource in _resources("AWS::IAM::Role")
        if resource["Properties"]["AssumeRolePolicyDocument"]["Statement"][0][
            "Principal"
        ]
        == {"Service": "codebuild.amazonaws.com"}
    )
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
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:GetRegistryScanningConfiguration",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "inspector2:BatchGetAccountStatus",
        "inspector2:ListCoverage",
        "inspector2:ListFindings",
    }
    logs_statement = next(
        statement for statement in statements if statement["Sid"] == "WriteBuildLogs"
    )
    assert set(logs_statement["Resource"]) == {
        (
            "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:"
            "log-group:/aws/codebuild/openclaw-enterprise-images-${ValidationRunId}"
        ),
        (
            "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:"
            "log-group:/aws/codebuild/openclaw-enterprise-images-${ValidationRunId}:*"
        ),
    }
    push_statement = next(
        statement
        for statement in statements
        if statement["Sid"] == "PushAndVerifyImages"
    )
    assert set(push_statement["Resource"]) == {
        "AdapterRepository.Arn",
        "ControllerRepository.Arn",
        "OwnershipHelperRepository.Arn",
        "RuntimeRepository.Arn",
    }
    builder_statement = next(
        statement
        for statement in statements
        if statement["Sid"] == "PullPinnedBuilderImage"
    )
    assert set(builder_statement["Action"]) == {
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
    }
    assert builder_statement["Resource"] == (
        "arn:${AWS::Partition}:ecr:${AWS::Region}:${AWS::AccountId}:"
        "repository/${BuilderImageRepositoryName}"
    )
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


def test_privileged_builder_image_is_account_local_and_digest_pinned() -> None:
    template = _template()
    project = _resources("AWS::CodeBuild::Project")[0]["Properties"]

    assert template["Parameters"]["BuilderImageDigest"]["AllowedPattern"] == (
        "^sha256:[0-9a-f]{64}$"
    )
    assert "Default" not in template["Parameters"]["BuilderImageDigest"]
    assert project["Environment"]["Image"] == (
        "${AWS::AccountId}.dkr.ecr.${AWS::Region}.${AWS::URLSuffix}/"
        "${BuilderImageRepositoryName}@${BuilderImageDigest}"
    )
    assert project["Environment"]["ImagePullCredentialsType"] == "SERVICE_ROLE"
    assert "aws/codebuild/standard:" not in TEMPLATE.read_text(encoding="utf-8")


def test_only_fixed_workflow_role_can_start_the_privileged_build() -> None:
    template = _template()
    assert "Rules" not in template
    roles = _resources("AWS::IAM::Role")
    workflow_role = next(
        role
        for role in roles
        if role["Properties"]["AssumeRolePolicyDocument"]["Statement"][0]["Principal"]
        == {"Service": "states.amazonaws.com"}
    )
    workflow_statements = workflow_role["Properties"]["Policies"][0]["PolicyDocument"][
        "Statement"
    ]
    run_statement = next(
        statement
        for statement in workflow_statements
        if statement["Sid"] == "RunFixedBuild"
    )

    assert run_statement["Effect"] == "Allow"
    assert set(run_statement["Action"]) == {
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "codebuild:StopBuild",
    }
    assert run_statement["Resource"] == "ImageBuildProject.Arn"

    other_codebuild_allows = []
    for role in roles:
        if role is workflow_role:
            continue
        for policy in role["Properties"].get("Policies", []):
            for statement in policy["PolicyDocument"]["Statement"]:
                actions = statement["Action"]
                if isinstance(actions, str):
                    actions = [actions]
                if statement["Effect"] == "Allow" and "codebuild:StartBuild" in actions:
                    other_codebuild_allows.append(statement)
    assert other_codebuild_allows == []

    invocation_role = template["Resources"]["ImageBuildInvocationRole"]
    assert "MaxSessionDuration" not in invocation_role["Properties"]
    invocation_trust = invocation_role["Properties"]["AssumeRolePolicyDocument"][
        "Statement"
    ][0]
    assert invocation_trust["Principal"] == {"AWS": "TrustedBuildInvokerArn"}
    assert invocation_trust["Condition"] == {
        "StringEquals": {
            "aws:PrincipalAccount": "AWS::AccountId",
        }
    }
    invocation_statements = invocation_role["Properties"]["Policies"][0][
        "PolicyDocument"
    ]["Statement"]
    deny = next(
        statement
        for statement in invocation_statements
        if statement["Sid"] == "DenyDirectCodeBuildExecution"
    )
    assert deny["Effect"] == "Deny"
    assert set(deny["Action"]) == {
        "codebuild:RetryBuild",
        "codebuild:StartBuild",
        "codebuild:StartBuildBatch",
    }
    assert deny["Resource"] == "ImageBuildProject.Arn"
    allows = {
        statement["Sid"]: statement
        for statement in invocation_statements
        if statement["Effect"] == "Allow"
    }
    assert allows["StartFixedBuildWorkflow"] == {
        "Sid": "StartFixedBuildWorkflow",
        "Effect": "Allow",
        "Action": "states:StartExecution",
        "Resource": "ImageBuildStateMachine",
    }
    assert allows["ReadFixedBuildWorkflowResult"] == {
        "Sid": "ReadFixedBuildWorkflowResult",
        "Effect": "Allow",
        "Action": "states:DescribeExecution",
        "Resource": (
            "arn:${AWS::Partition}:states:${AWS::Region}:${AWS::AccountId}:"
            "execution:openclaw-enterprise-image-build-${ValidationRunId}:*"
        ),
    }
    assert allows["ReadFixedCodeBuildResult"] == {
        "Sid": "ReadFixedCodeBuildResult",
        "Effect": "Allow",
        "Action": "codebuild:BatchGetBuilds",
        "Resource": "ImageBuildProject.Arn",
    }


def test_fixed_workflow_cannot_forward_adversarial_start_build_overrides() -> None:
    template = _template()
    state_machine = template["Resources"]["ImageBuildStateMachine"]["Properties"]
    definition = state_machine["Definition"]
    task = definition["States"]["RunTrustedImageBuild"]

    assert task["Resource"] == (
        "arn:${AWS::Partition}:states:::codebuild:startBuild.sync"
    )
    assert task["Parameters"] == {"ProjectName": "ImageBuildProject"}
    serialized = json.dumps(definition)
    for override in (
        "BuildspecOverride",
        "EnvironmentVariablesOverride",
        "ImageOverride",
        "PrivilegedModeOverride",
        "SourceLocationOverride",
        "SourceTypeOverride",
    ):
        assert override not in serialized
    for bootstrap_variable in (
        "BASH_ENV",
        "ENV",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0",
        "GIT_CONFIG_VALUE_0",
    ):
        assert bootstrap_variable not in serialized


def test_fixed_workflow_logs_all_events_and_publishes_xray_traces() -> None:
    template = _template()
    state_machine = template["Resources"]["ImageBuildStateMachine"]["Properties"]
    workflow_role = template["Resources"]["ImageBuildWorkflowRole"]
    statements = workflow_role["Properties"]["Policies"][0]["PolicyDocument"][
        "Statement"
    ]

    assert state_machine["LoggingConfiguration"] == {
        "Destinations": [
            {
                "CloudWatchLogsLogGroup": {
                    "LogGroupArn": "ImageBuildStateMachineLogGroup.Arn"
                }
            }
        ],
        "IncludeExecutionData": False,
        "Level": "ALL",
    }
    assert state_machine["TracingConfiguration"] == {"Enabled": True}

    logging = next(
        statement
        for statement in statements
        if statement["Sid"] == "DeliverWorkflowLogs"
    )
    assert set(logging["Action"]) == {
        "logs:CreateLogDelivery",
        "logs:CreateLogStream",
        "logs:DeleteLogDelivery",
        "logs:DescribeLogGroups",
        "logs:DescribeResourcePolicies",
        "logs:GetLogDelivery",
        "logs:ListLogDeliveries",
        "logs:PutLogEvents",
        "logs:PutResourcePolicy",
        "logs:UpdateLogDelivery",
    }
    assert logging["Resource"] == "*"

    tracing = next(
        statement
        for statement in statements
        if statement["Sid"] == "PublishWorkflowTraces"
    )
    assert set(tracing["Action"]) == {
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets",
        "xray:PutTelemetryRecords",
        "xray:PutTraceSegments",
    }
    assert tracing["Resource"] == "*"


def test_readme_states_direct_start_build_is_a_fail_closed_deployment_contract() -> (
    None
):
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")

    assert "no project setting or resource policy" in readme
    assert "`codebuild:StartBuild`" in readme
    assert "`codebuild:StartBuildBatch`" in readme
    assert "`codebuild:RetryBuild`" in readme
    assert re.search(r"permissions boundary\s+or SCP", readme)
    assert "exempt only `ImageBuildWorkflowRole`" in readme


def test_readme_scopes_build_credentials_to_a_subshell() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    build_step = readme.split("**Step 2: Build and scan the images**", 1)[1].split(
        "**Step 3:", 1
    )[0]

    assert (
        '(\nset -euo pipefail\nset +x\nsource_aws_profile="$AWS_PROFILE"' in build_step
    )
    assert "assume_build_invocation_role() {" in build_step
    assert 'aws --profile "$source_aws_profile" sts assume-role' in build_step
    assert "--duration-seconds 3600" in build_step
    assert "--output json" in build_step
    assert 'else error("STS returned incomplete credentials")' in build_step
    assert "IFS=$'\\t' read -r access_key secret_key session_token" in build_step
    assert 'export AWS_ACCESS_KEY_ID="$access_key"' in build_step
    assert 'export AWS_SECRET_ACCESS_KEY="$secret_key"' in build_step
    assert 'export AWS_SESSION_TOKEN="$session_token"' in build_step
    assert "set -euo pipefail" in build_step
    assert "execution_deadline=$(($(date +%s) + 11100))" in build_step
    assert "current_epoch - credentials_refreshed_at >= 2700" in build_step
    assert "current_epoch >= execution_deadline" in build_step
    assert "Unexpected Step Functions status" in build_step
    assert (
        "trap 'unset credentials AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY "
        "AWS_SESSION_TOKEN' EXIT" in build_step
    )
    assert '>"$image_outputs"\nchmod 600 "$image_outputs"\n)' in build_step
    assert ") \n\nexport ADAPTER_IMAGE" not in build_step
    assert (
        "export ADAPTER_IMAGE=\"$(\n  jq -er '.ADAPTER_IMAGE' "
        '"$PRIVATE_STATE_DIR/image-build-outputs.json"' in build_step
    )


def test_readme_role_refresh_rejects_incomplete_sts_credentials(
    tmp_path: pathlib.Path,
) -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    build_step = readme.split("**Step 2: Build and scan the images**", 1)[1].split(
        "**Step 3:", 1
    )[0]
    function_start = build_step.index("assume_build_invocation_role() {")
    function_lines = build_step[function_start:].splitlines()
    function_end = function_lines.index("}")
    function_source = "\n".join(function_lines[: function_end + 1])

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_aws = bin_dir / "aws"
    fake_aws.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *" --output json "* ]]
printf '%s' "$FAKE_STS_RESPONSE"
""",
        encoding="utf-8",
    )
    fake_aws.chmod(0o755)
    shell = f"""\
set -euo pipefail
source_aws_profile=test-profile
invocation_role_arn=arn:aws:iam::123456789012:role/test
{function_source}
assume_build_invocation_role
printf '%s\\n' "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY:$AWS_SESSION_TOKEN"
"""
    environment = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
    }

    valid = subprocess.run(
        ["bash", "-c", shell],
        check=False,
        text=True,
        capture_output=True,
        env={
            **environment,
            "FAKE_STS_RESPONSE": json.dumps(
                {
                    "Credentials": {
                        "AccessKeyId": "access",
                        "SecretAccessKey": "secret",  # pragma: allowlist secret -- test placeholder
                        "SessionToken": "token",
                    }
                }
            ),
        },
    )
    assert valid.returncode == 0, valid.stderr
    assert valid.stdout == "access:secret:token\n"

    incomplete = subprocess.run(
        ["bash", "-c", shell],
        check=False,
        text=True,
        capture_output=True,
        env={
            **environment,
            "FAKE_STS_RESPONSE": json.dumps(
                {
                    "Credentials": {
                        "AccessKeyId": "access",
                        "SessionToken": "token",
                    }
                }
            ),
        },
    )
    assert incomplete.returncode != 0
    assert "STS returned incomplete credentials" in incomplete.stderr
    assert incomplete.stdout == ""


def test_build_script_builds_each_image_from_the_expected_source() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
    assert "require_value CODEBUILD_BUILD_ARN" in script
    assert "require_sha SAMPLE_GIT_REVISION" in script
    assert "require_sha OCE_GIT_REVISION" in script
    assert "require_digest CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST" in script
    assert (
        'readonly OCE_REPOSITORY_URL="'
        'https://github.com/openclaw/openclaw-enterprise.git"' in script
    )
    assert (
        '[[ "$(git -C "$OCE_SOURCE_DIR" remote get-url origin)" '
        '== "$OCE_REPOSITORY_URL" ]]' in script
    )
    assert (
        'git -C "$OCE_SOURCE_DIR" fetch --depth 1 origin "$OCE_GIT_REVISION"' in script
    )
    assert '[[ "$OCE_SOURCE_REVISION" == "$OCE_GIT_REVISION" ]]' in script
    assert (
        '"$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/adapter"' in script
    )
    assert (
        '"$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/'
        'ownership-helper"' in script
    )
    assert '--build-arg "OWNERSHIP_HELPER_BUILDER_IMAGE=' in script
    assert "--target runtime" in script
    assert '--build-arg "NODE_BUILD_BASE_IMAGE=$OCE_NODE_BUILD_BASE_IMAGE"' in script
    assert (
        '--build-arg "NODE_RUNTIME_BASE_IMAGE=$CONTROLLER_RUNTIME_BASE_IMAGE"' in script
    )
    assert (
        '--file "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/'
        'build/controller-runtime.Dockerfile"' in script
    )
    assert '--file "$OCE_RUNTIME_DOCKERFILE"' in script
    assert '--build-arg "NODE_BASE_IMAGE=$OCE_NODE_BUILD_BASE_IMAGE"' in script
    assert (
        '--build-arg "NODE_RUNTIME_BASE_IMAGE=$OCE_NODE_RUNTIME_BASE_IMAGE"' in script
    )
    assert "node scripts/lib/openclaw-source.mjs build-args" in script
    assert 'OCE_MSAL_NODE_VERSION="7.2.0"' in script
    assert "check-oce-lock.py" in script
    assert "apply-oce-security-patches.py" in script
    assert script.index("apply-oce-security-patches.py") < script.rindex(
        "docker buildx build"
    )
    assert script.count("docker buildx build") == 4
    assert script.count("--provenance=false") == 4
    assert "docker buildx prune --all --force" in script
    assert "docker system prune --all --force --volumes" in script
    assert script.count("reclaim_build_disk") == 4
    runtime_build = script.rindex("docker buildx build")
    assert script.rindex("reclaim_build_disk", 0, runtime_build) < runtime_build
    assert (
        script.count(
            '--label "org.opencontainers.image.revision=$SAMPLE_SOURCE_REVISION"'
        )
        == 4
    )
    assert (
        script.count(
            '--label "org.openclaw.enterprise.source-revision=$OCE_SOURCE_REVISION"'
        )
        == 2
    )
    assert "docker pull" not in script
    assert "skopeo copy" not in script


def test_oce_runtime_base_metadata_preserves_both_source_revisions() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    dependency_patch_sha256 = hashlib.sha256(
        OPENCLAW_DEPENDENCY_PATCH.read_bytes()
    ).hexdigest()

    assert '"baseImage": os.environ["OCE_NODE_RUNTIME_BASE_IMAGE"]' in script
    assert '"buildBaseImage": os.environ["OCE_NODE_BUILD_BASE_IMAGE"]' in script
    assert script.count('"oceSourceRevision": os.environ["OCE_SOURCE_REVISION"]') == 2
    assert script.count('"sourceRevision": os.environ["SAMPLE_SOURCE_REVISION"]') == 4
    assert '"securityBackports": [' in script
    assert '"cve": os.environ["OPENSSL_BACKPORT_CVE"]' in script
    assert '"patchSha256": os.environ["OPENSSL_BACKPORT_PATCH_SHA256"]' in script
    assert '"upstreamCommit": os.environ["OPENSSL_BACKPORT_UPSTREAM_COMMIT"]' in script
    assert '"cve": os.environ["CURL_BACKPORT_CVE"]' in script
    assert '"patchSha256": os.environ["CURL_BACKPORT_PATCH_SHA256"]' in script
    assert '"upstreamCommit": os.environ["CURL_BACKPORT_UPSTREAM_COMMIT"]' in script
    assert '"dependencyPatches": [' in script
    assert (
        '"patchSha256": os.environ["OPENCLAW_DEPENDENCY_PATCH_SHA256"]' in script
    )
    assert (
        f'OPENCLAW_DEPENDENCY_PATCH_SHA256="{dependency_patch_sha256}"' in script
    )
    assert 'NPM_RUNTIME_VERSION="11.21.3"' in script
    assert (
        'NPM_RUNTIME_ARCHIVE_SHA256="'
        "ee5fc68e724c4bdba38db9d96d9c661d4e736e4be7001ae44d2fbbaa52159514"  # pragma: allowlist secret -- public archive checksum
        '"' in script
    )
    assert '"runtimePackages": [' in script
    assert '"version": os.environ["NPM_RUNTIME_VERSION"]' in script


def test_build_script_checks_bash_four_before_using_mapfile() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    executable_lines = [
        line
        for line in script.splitlines()[1:]
        if line.strip() and not line.lstrip().startswith("#")
    ]

    assert "mapfile -t openclaw_source_args" in script
    assert executable_lines[0] == (
        '. "$(dirname "$0")/../../../../scripts/lib/require-bash.sh"'
    )


def test_adapter_base_image_is_allowlisted_and_digest_pinned() -> None:
    dockerfile = ADAPTER_DOCKERFILE.read_text(encoding="utf-8")
    base_images = re.findall(r"^FROM\s+(\S+)", dockerfile, re.MULTILINE)

    assert len(base_images) == 1
    base_image = re.fullmatch(
        r"(?P<repository>[a-z0-9.-]+(?:/[a-z0-9._-]+)+)"
        r":(?P<tag>[A-Za-z0-9][A-Za-z0-9._-]*)"
        r"@(?P<digest>sha256:[0-9a-f]{64})",
        base_images[0],
    )
    assert base_image
    assert base_image.group("repository") == "cgr.dev/chainguard/python"


def test_controller_runtime_uses_a_separate_pinned_base_and_drops_build_tools() -> None:
    dockerfile = CONTROLLER_DOCKERFILE.read_text(encoding="utf-8")

    assert "ARG NODE_BUILD_BASE_IMAGE" in dockerfile
    assert "ARG NODE_RUNTIME_BASE_IMAGE" in dockerfile
    assert "FROM ${NODE_BUILD_BASE_IMAGE} AS dependencies" in dockerfile
    assert "FROM ${NODE_BUILD_BASE_IMAGE} AS console-build" in dockerfile
    assert "FROM ${NODE_BUILD_BASE_IMAGE} AS runtime-prepared" in dockerfile
    assert dockerfile.count("FROM ${NODE_RUNTIME_BASE_IMAGE}") == 1
    runtime = dockerfile.split(
        "FROM ${NODE_RUNTIME_BASE_IMAGE} AS runtime", maxsplit=1
    )[1]
    assert "FROM ${NODE_BUILD_BASE_IMAGE}" not in runtime
    prepared = dockerfile.split(
        "FROM ${NODE_BUILD_BASE_IMAGE} AS runtime-prepared", maxsplit=1
    )[1].split("FROM ${NODE_RUNTIME_BASE_IMAGE} AS runtime", maxsplit=1)[0]
    assert (
        "COPY --from=runtime-dependencies --chown=1000:1000 "
        "/app/node_modules node_modules" in prepared
    )
    for workspace in (
        "apps/controller",
        "packages/audit",
        "packages/contracts",
        "packages/iam",
        "packages/occ",
    ):
        assert (
            "COPY --from=runtime-dependencies --chown=1000:1000 "
            f"/app/{workspace}/node_modules {workspace}/node_modules" in prepared
        )
    assert "COPY --from=dependencies" not in runtime
    assert (
        "RUN --mount=type=bind,source=pnpm-lock.yaml,"
        "target=/app/pnpm-lock.yaml,readonly" in prepared
    )
    assert "COPY --chown=node:node pnpm-lock.yaml" not in runtime
    assert "delete packageJson.devDependencies" in prepared
    assert "delete packageJson.scripts" in prepared
    assert "delete packageJson.packageManager" in prepared
    runtime_run_lines = [
        line for line in runtime.splitlines() if line.startswith("RUN ")
    ]
    assert runtime_run_lines == [
        next(
            line
            for line in runtime.splitlines()
            if line.startswith('RUN ["/nodejs/bin/node", "-e",')
        )
    ]
    assert "RUN apt-get" not in runtime
    assert "/usr/local/lib/node_modules/npm" not in runtime
    assert "/usr/local/lib/node_modules/corepack" not in runtime
    assert "COPY --from=runtime-prepared --chown=1000:1000 /app /app" in runtime
    assert 'ENV PATH="/nodejs/bin:${PATH}"' in runtime
    assert "USER 1000:1000" in runtime
    for package in (
        "esbuild@*",
        "@esbuild+*",
        "@esbuild-kit+*",
        "tsx@*",
        "drizzle-kit@*",
    ):
        assert package in dockerfile
    assert 'ENTRYPOINT ["/nodejs/bin/node"]' in runtime
    assert 'CMD ["apps/controller/src/server.mjs"]' in runtime


def test_controller_runtime_base_has_an_allowlisted_repository_and_exact_digest() -> (
    None
):
    script = SCRIPT.read_text(encoding="utf-8")
    template = _template()
    parameter = template["Parameters"]["ControllerRuntimeBaseImageDigest"]
    digest = "sha256:6abfcb367ebc291572c774c1592a986be2ab26a2486f73093401327495a5962a"

    assert parameter["Default"] == digest
    assert parameter["AllowedValues"] == [digest]
    assert (
        'readonly CONTROLLER_RUNTIME_BASE_IMAGE_REPOSITORY="'
        'gcr.io/distroless/nodejs24-debian13"' in script
    )
    assert 'readonly CONTROLLER_RUNTIME_BASE_IMAGE_TAG="nonroot"' in script
    assert (
        f'readonly CONTROLLER_RUNTIME_BASE_IMAGE_ALLOWLIST_DIGEST="{digest}"' in script
    )
    assert (
        '"$CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST" == '
        '"$CONTROLLER_RUNTIME_BASE_IMAGE_ALLOWLIST_DIGEST"' in script
    )
    assert (
        'readonly CONTROLLER_RUNTIME_BASE_IMAGE="${CONTROLLER_RUNTIME_BASE_IMAGE_REPOSITORY}:'
        "${CONTROLLER_RUNTIME_BASE_IMAGE_TAG}@"
        '${CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST}"' in script
    )
    assert "${CONTROLLER_RUNTIME_BASE_IMAGE:-" not in script


def test_controller_runtime_verifies_final_image_security_properties() -> None:
    dockerfile = CONTROLLER_DOCKERFILE.read_text(encoding="utf-8")
    runtime = dockerfile.split(" AS runtime\n", 1)[1]

    assert runtime.count('RUN ["/nodejs/bin/node", "-e",') == 1
    assert "process.versions.node" in runtime
    assert "process.getuid() !== 1000 || process.getgid() !== 1000" in runtime
    for path in (
        "/bin/sh",
        "/bin/bash",
        "/usr/bin/apt",
        "/usr/bin/apt-get",
        "/usr/bin/dpkg",
    ):
        assert path in runtime
    assert 'ENTRYPOINT ["/nodejs/bin/node"]' in runtime
    assert 'CMD ["apps/controller/src/server.mjs"]' in runtime


def test_build_outputs_are_verified_digest_references() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    verify_scan = script.split("verify_scan() {", 1)[1].split(
        '\n}\n\nverify_scan "$ADAPTER_REPOSITORY"', 1
    )[0]

    assert 'digest = json.load(handle).get("containerimage.digest", "")' in script
    assert "aws ecr describe-images \\" in script
    assert "aws inspector2 batch-get-account-status" in script
    assert "aws ecr get-registry-scanning-configuration" in script
    assert "check-enhanced-scanning.py" in script
    assert "aws inspector2 list-coverage" in script
    assert "aws inspector2 list-findings" in script
    assert script.count("--no-paginate") == 1
    assert "--max-results 100" not in verify_scan
    assert "readonly INSPECTOR_SCAN_POLL_SECONDS=5" in script
    assert "readonly INSPECTOR_SCAN_STABLE_OBSERVATIONS=13" in script
    assert "local clean_observations=0" in verify_scan
    assert "((clean_observations += 1))" in verify_scan
    assert (
        "clean_observations >= INSPECTOR_SCAN_STABLE_OBSERVATIONS" in verify_scan
    )
    assert "clean_observations=0" in verify_scan
    assert 'sleep "$INSPECTOR_SCAN_POLL_SECONDS"' in verify_scan
    assert '"resourceId": equals(resource_id)' in script
    assert '"ecrImageHash": equals(digest)' in script
    assert '"findingStatus": equals("ACTIVE")' in script
    assert "check-inspector-scan.py" in script
    assert "describe-image-scan-findings" not in verify_scan
    assert "check-image-scan.py" not in verify_scan
    assert verify_scan.count("return 0") == 1
    assert verify_scan.index("check-inspector-scan.py") < verify_scan.index("return 0")
    assert (
        "Inspector PACKAGE scan for $repository@$digest did not complete" in verify_scan
    )
    assert len(re.findall(r"(?m)^verify_scan(?:\s|$)", script)) == 4
    assert (
        'verify_scan \\\n'
        '  "$RUNTIME_REPOSITORY" \\\n'
        '  "$runtime_digest" \\\n'
        '  "$OPENSSL_BACKPORT_PATCH" \\\n'
        '  "$OPENSSL_88823_BACKPORT_PATCH" \\\n'
        '  "$OPENSSL_107496_BACKPORT_PATCH"'
    ) in script
    assert script.index("check-enhanced-scanning.py") < script.index(
        'git init "$OCE_SOURCE_DIR"'
    )
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


def _enhanced_scan_result(
    tmp_path: pathlib.Path,
    *,
    account_status: dict[str, object],
    registry_config: dict[str, object],
) -> subprocess.CompletedProcess[str]:
    account_status_path = tmp_path / "account-status.json"
    registry_config_path = tmp_path / "registry-config.json"
    account_status_path.write_text(json.dumps(account_status), encoding="utf-8")
    registry_config_path.write_text(json.dumps(registry_config), encoding="utf-8")
    return subprocess.run(
        [
            sys.executable,
            "-I",
            str(ENHANCED_SCAN_CHECK),
            str(account_status_path),
            str(registry_config_path),
            "123456789012",
            "openclaw-enterprise/run/adapter",
            "openclaw-enterprise/run/runtime",
        ],
        check=False,
        text=True,
        capture_output=True,
    )


def _enabled_inspector_account() -> dict[str, Any]:
    return {
        "accounts": [
            {
                "accountId": "123456789012",
                "state": {"status": "ENABLED"},
                "resourceState": {"ecr": {"status": "ENABLED"}},
            }
        ],
        "failedAccounts": [],
    }


def _enhanced_registry_config(
    pattern: str = "openclaw-enterprise/*",
) -> dict[str, Any]:
    return {
        "registryId": "123456789012",
        "scanningConfiguration": {
            "scanType": "ENHANCED",
            "rules": [
                {
                    "scanFrequency": "CONTINUOUS_SCAN",
                    "repositoryFilters": [
                        {"filter": pattern, "filterType": "WILDCARD"}
                    ],
                }
            ],
        },
    }


def test_enhanced_scan_preflight_accepts_covered_release_repositories(
    tmp_path: pathlib.Path,
) -> None:
    result = _enhanced_scan_result(
        tmp_path,
        account_status=_enabled_inspector_account(),
        registry_config=_enhanced_registry_config(),
    )

    assert result.returncode == 0, result.stderr


def test_enhanced_scan_preflight_uses_ecr_substring_filter_semantics(
    tmp_path: pathlib.Path,
) -> None:
    result = _enhanced_scan_result(
        tmp_path,
        account_status=_enabled_inspector_account(),
        registry_config=_enhanced_registry_config("openclaw-enterprise/"),
    )

    assert result.returncode == 0, result.stderr


def test_enhanced_scan_preflight_rejects_disabled_ecr_scanning(
    tmp_path: pathlib.Path,
) -> None:
    account_status = _enabled_inspector_account()
    account_status["accounts"][0]["resourceState"]["ecr"]["status"] = "DISABLED"
    result = _enhanced_scan_result(
        tmp_path,
        account_status=account_status,
        registry_config=_enhanced_registry_config(),
    )

    assert result.returncode != 0
    assert "ECR scanning is not enabled" in result.stderr


def test_enhanced_scan_preflight_rejects_basic_or_uncovered_registries(
    tmp_path: pathlib.Path,
) -> None:
    basic = _enhanced_registry_config()
    basic["scanningConfiguration"]["scanType"] = "BASIC"
    basic_result = _enhanced_scan_result(
        tmp_path,
        account_status=_enabled_inspector_account(),
        registry_config=basic,
    )
    uncovered_result = _enhanced_scan_result(
        tmp_path,
        account_status=_enabled_inspector_account(),
        registry_config=_enhanced_registry_config("different-prefix/*"),
    )

    assert basic_result.returncode != 0
    assert "scan type must be ENHANCED" in basic_result.stderr
    assert uncovered_result.returncode != 0
    assert "no enabled enhanced-scanning rule covers" in uncovered_result.stderr


def test_readme_treats_enhanced_scanning_as_read_only_shared_configuration() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")

    assert "aws inspector2 batch-get-account-status" in readme
    assert "aws ecr get-registry-scanning-configuration" in readme
    assert "image-scanning-enhanced.html" in readme
    assert "aws inspector2 enable" not in readme
    assert "aws ecr put-registry-scanning-configuration" not in readme


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
    backport_patch: pathlib.Path | tuple[pathlib.Path, ...] | None = None,
) -> subprocess.CompletedProcess[str]:
    coverage_path = tmp_path / "coverage.json"
    findings_path = tmp_path / "findings.json"
    coverage_path.write_text(json.dumps(coverage), encoding="utf-8")
    findings_path.write_text(json.dumps(findings), encoding="utf-8")
    command = [
        sys.executable,
        "-I",
        str(INSPECTOR_SCAN_CHECK),
        str(coverage_path),
        str(findings_path),
        INSPECTOR_RESOURCE_ID,
        INSPECTOR_ACCOUNT,
        INSPECTOR_REPOSITORY,
        INSPECTOR_DIGEST,
    ]
    if isinstance(backport_patch, pathlib.Path):
        backport_patches = (backport_patch,)
    else:
        backport_patches = backport_patch or ()
    for patch in backport_patches:
        command.extend(["--backport-patch", str(patch)])
    return subprocess.run(
        command,
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


def _openssl_backport_finding() -> dict[str, object]:
    finding = _inspector_finding()
    finding["packageVulnerabilityDetails"] = {
        "vulnerabilityId": "CVE-2026-95692",
        "vulnerablePackages": [
            {
                "name": "openssl/openssl",
                "version": "3.5.9",
                "packageManager": "GENERIC",
                "fixedInVersion": "3.5.10",
                "filePath": (
                    "/usr/local/include/node/openssl/archs/linux-x86_64/"
                    f"{variant}/include/openssl/opensslv.h"
                ),
            }
            for variant in ("asm", "asm_avx2", "no-asm")
        ],
        "referenceUrls": [
            (
                "https://github.com/openssl/openssl/commit/"
                "257a3427aa0ef8d9dd2ef5b3e2d1c021a221b116"  # pragma: allowlist secret -- public source revision
            )
        ],
    }
    return finding


def _openssl_88823_backport_finding() -> dict[str, object]:
    finding = _inspector_finding()
    finding["packageVulnerabilityDetails"] = {
        "vulnerabilityId": "CVE-2026-88823",
        "vulnerablePackages": [
            {
                "name": "openssl",
                "version": "3.5.9",
                "release": "1~deb13u1+oce1",
                "epoch": 0,
                "arch": "AMD64",
                "packageManager": "OS",
                "fixedInVersion": "NotAvailable",
                "filePath": "/var/lib/dpkg/status",
                "remediation": (
                    "Update affected packages to fixed version (or newer)."
                ),
            },
            *[
                {
                    "name": "openssl/openssl",
                    "version": "3.5.9",
                    "epoch": 0,
                    "packageManager": "GENERIC",
                    "fixedInVersion": "3.5.10",
                    "remediation": (
                        "Update affected packages to fixed version (or newer)."
                    ),
                    "filePath": (
                        "/usr/local/include/node/openssl/archs/linux-x86_64/"
                        f"{variant}/include/openssl/opensslv.h"
                    ),
                }
                for variant in ("asm", "asm_avx2", "no-asm")
            ],
        ],
        "referenceUrls": [OPENSSL_88823_UPSTREAM_REFERENCE],
    }
    return finding


def _openssl_107496_backport_finding(
    include_os_package: bool = False,
) -> dict[str, object]:
    finding = _inspector_finding()
    packages: list[dict[str, object]] = [
        {
            "name": "openssl/openssl",
            "version": "3.5.9",
            "epoch": 0,
            "packageManager": "GENERIC",
            "fixedInVersion": "3.5.10",
            "remediation": (
                "Update affected packages to fixed version (or newer)."
            ),
            "filePath": (
                "/usr/local/include/node/openssl/archs/linux-x86_64/"
                f"{variant}/include/openssl/opensslv.h"
            ),
        }
        for variant in ("asm", "asm_avx2", "no-asm")
    ]
    if include_os_package:
        packages.insert(
            0,
            {
                "name": "openssl",
                "version": "3.5.9",
                "release": "1~deb13u1+oce2",
                "epoch": 0,
                "arch": "AMD64",
                "packageManager": "OS",
                "fixedInVersion": "NotAvailable",
                "filePath": "/var/lib/dpkg/status",
                "remediation": (
                    "Update affected packages to fixed version (or newer)."
                ),
            },
        )
    finding["packageVulnerabilityDetails"] = {
        "vulnerabilityId": "CVE-2026-107496",
        "vulnerablePackages": packages,
        "referenceUrls": [OPENSSL_107496_UPSTREAM_REFERENCE],
    }
    return finding


def _copy_inspector_finding(
    finding: dict[str, object],
) -> dict[str, object]:
    return json.loads(json.dumps(finding))


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


def test_inspector_gate_accepts_only_the_exact_reviewed_source_backport(
    tmp_path: pathlib.Path,
) -> None:
    result = _inspector_scan_result(
        tmp_path,
        _inspector_coverage(),
        {"findings": [_openssl_backport_finding()]},
        OPENSSL_BACKPORT_PATCH,
    )

    assert result.returncode == 0, result.stderr
    assert "accepted 1 reviewed HIGH source backport finding(s)" in result.stdout


def test_inspector_gate_accepts_both_exact_reviewed_source_backports(
    tmp_path: pathlib.Path,
) -> None:
    result = _inspector_scan_result(
        tmp_path,
        _inspector_coverage(),
        {
            "findings": [
                _openssl_backport_finding(),
                _openssl_88823_backport_finding(),
            ]
        },
        (OPENSSL_BACKPORT_PATCH, OPENSSL_88823_BACKPORT_PATCH),
    )

    assert result.returncode == 0, result.stderr
    assert "accepted 2 reviewed HIGH source backport finding(s)" in result.stdout


def test_inspector_gate_accepts_exact_cve_2026_107496_package_shapes(
    tmp_path: pathlib.Path,
) -> None:
    for include_os_package in (False, True):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            {
                "findings": [
                    _openssl_107496_backport_finding(include_os_package)
                ]
            },
            OPENSSL_107496_BACKPORT_PATCH,
        )

        assert result.returncode == 0, result.stderr
        assert (
            "accepted 1 reviewed HIGH source backport finding(s)"
            in result.stdout
        )


def test_inspector_cve_2026_107496_gate_rejects_package_near_match(
    tmp_path: pathlib.Path,
) -> None:
    finding = _copy_inspector_finding(_openssl_107496_backport_finding())
    finding["packageVulnerabilityDetails"]["vulnerablePackages"][0][  # type: ignore[index]
        "filePath"
    ] = "/unexpected/opensslv.h"

    result = _inspector_scan_result(
        tmp_path,
        _inspector_coverage(),
        {"findings": [finding]},
        OPENSSL_107496_BACKPORT_PATCH,
    )

    assert result.returncode == 1


def test_inspector_backport_gate_rejects_near_matches_and_other_findings(
    tmp_path: pathlib.Path,
) -> None:
    wrong_package = _openssl_backport_finding()
    wrong_package["packageVulnerabilityDetails"]["vulnerablePackages"][0][  # type: ignore[index]
        "version"
    ] = "3.5.8"
    wrong_cve = _openssl_backport_finding()
    wrong_cve["packageVulnerabilityDetails"]["vulnerabilityId"] = (  # type: ignore[index]
        "CVE-2026-00000"
    )
    for findings in (
        {"findings": [wrong_package]},
        {"findings": [wrong_cve]},
        {"findings": [_openssl_backport_finding(), _inspector_finding()]},
        {"findings": [_openssl_backport_finding()], "nextToken": "more"},
    ):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            findings,
            OPENSSL_BACKPORT_PATCH,
        )

        assert result.returncode == 1


def test_inspector_backport_gate_rejects_a_different_patch(
    tmp_path: pathlib.Path,
) -> None:
    different_patch = tmp_path / "different.patch"
    different_patch.write_text("different", encoding="utf-8")

    result = _inspector_scan_result(
        tmp_path,
        _inspector_coverage(),
        {"findings": [_openssl_backport_finding()]},
        different_patch,
    )

    assert result.returncode == 1
    assert "patch checksum" in result.stderr


def test_inspector_gate_accepts_only_exact_cve_2026_88823_backport(
    tmp_path: pathlib.Path,
) -> None:
    result = _inspector_scan_result(
        tmp_path,
        _inspector_coverage(),
        {"findings": [_openssl_88823_backport_finding()]},
        (OPENSSL_BACKPORT_PATCH, OPENSSL_88823_BACKPORT_PATCH),
    )

    assert result.returncode == 0, result.stderr
    assert "accepted 1 reviewed HIGH source backport finding(s)" in result.stdout


def test_inspector_cve_2026_88823_gate_rejects_package_near_matches(
    tmp_path: pathlib.Path,
) -> None:
    altered_tuple = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    altered_tuple["packageVulnerabilityDetails"]["vulnerablePackages"][0][  # type: ignore[index]
        "packageManager"
    ] = "GENERIC"

    missing_package = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    missing_package["packageVulnerabilityDetails"]["vulnerablePackages"].pop()  # type: ignore[index]

    extra_package = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    extra_package["packageVulnerabilityDetails"]["vulnerablePackages"].append(  # type: ignore[index]
        {
            "name": "openssl/openssl",
            "version": "3.5.9",
            "packageManager": "GENERIC",
            "fixedInVersion": "3.5.10",
            "filePath": "/unexpected/opensslv.h",
        }
    )

    altered_path = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    altered_path["packageVulnerabilityDetails"]["vulnerablePackages"][1][  # type: ignore[index]
        "filePath"
    ] = "/unexpected/opensslv.h"

    altered_version = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    altered_version["packageVulnerabilityDetails"]["vulnerablePackages"][0][  # type: ignore[index]
        "version"
    ] = "3.5.8"

    altered_fixed_version = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    altered_fixed_version["packageVulnerabilityDetails"]["vulnerablePackages"][1][  # type: ignore[index]
        "fixedInVersion"
    ] = "3.5.11"

    for case, finding in (
        ("altered package tuple", altered_tuple),
        ("missing package", missing_package),
        ("extra package", extra_package),
        ("altered path", altered_path),
        ("altered version", altered_version),
        ("altered fixed version", altered_fixed_version),
    ):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            {"findings": [finding]},
            OPENSSL_88823_BACKPORT_PATCH,
        )

        assert result.returncode == 1, (
            f"{case} was accepted\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def test_inspector_cve_2026_88823_gate_rejects_reference_near_matches(
    tmp_path: pathlib.Path,
) -> None:
    missing_reference = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    missing_reference["packageVulnerabilityDetails"]["referenceUrls"] = []  # type: ignore[index]

    altered_reference = _copy_inspector_finding(
        _openssl_88823_backport_finding()
    )
    altered_reference["packageVulnerabilityDetails"]["referenceUrls"] = [  # type: ignore[index]
        "https://github.com/openssl/openssl/commit/not-the-reviewed-commit"
    ]

    for case, finding in (
        ("missing reference", missing_reference),
        ("altered reference", altered_reference),
    ):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            {"findings": [finding]},
            OPENSSL_88823_BACKPORT_PATCH,
        )

        assert result.returncode == 1, (
            f"{case} was accepted\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def test_inspector_cve_2026_88823_gate_requires_exactly_one_reviewed_patch(
    tmp_path: pathlib.Path,
) -> None:
    altered_patch = OPENSSL_BACKPORT_PATCH
    extra_patch = tmp_path / "extra.patch"
    extra_patch.write_text("unexpected patch", encoding="utf-8")

    for case, backport_patch in (
        ("missing patch", None),
        ("altered patch", altered_patch),
        ("unknown extra patch", (OPENSSL_88823_BACKPORT_PATCH, extra_patch)),
        (
            "duplicate patch",
            (OPENSSL_88823_BACKPORT_PATCH, OPENSSL_88823_BACKPORT_PATCH),
        ),
    ):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            {"findings": [_openssl_88823_backport_finding()]},
            backport_patch,
        )

        assert result.returncode == 1, (
            f"{case} was accepted\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def test_inspector_cve_2026_88823_gate_rejects_other_severe_findings_and_pagination(
    tmp_path: pathlib.Path,
) -> None:
    critical = _copy_inspector_finding(_openssl_88823_backport_finding())
    critical["severity"] = "CRITICAL"

    for case, findings in (
        ("critical finding", {"findings": [critical]}),
        (
            "unrelated high finding",
            {
                "findings": [
                    _openssl_88823_backport_finding(),
                    _inspector_finding("HIGH"),
                ]
            },
        ),
        (
            "paginated findings",
            {
                "findings": [_openssl_88823_backport_finding()],
                "nextToken": "more",
            },
        ),
    ):
        result = _inspector_scan_result(
            tmp_path,
            _inspector_coverage(),
            findings,
            OPENSSL_88823_BACKPORT_PATCH,
        )

        assert result.returncode == 1, (
            f"{case} was accepted\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


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


def test_basic_scan_success_cannot_replace_inspector_package_evidence(
    tmp_path: pathlib.Path,
) -> None:
    basic_result = _scan_result(_scan_payload("COMPLETE", {}))
    missing_inspector_result = _inspector_scan_result(
        tmp_path,
        {"coveredResources": []},
        {"findings": []},
    )
    script = SCRIPT.read_text(encoding="utf-8")
    verify_scan = script.split("verify_scan() {", 1)[1].split(
        '\n}\n\nverify_scan "$ADAPTER_REPOSITORY"', 1
    )[0]

    assert basic_result.returncode == 0, basic_result.stderr
    assert missing_inspector_result.returncode == 10
    assert "check-image-scan.py" not in verify_scan
    assert "check-inspector-scan.py" in verify_scan


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


def _create_fake_oce_source(tmp_path: pathlib.Path) -> tuple[pathlib.Path, str]:
    oce_source = tmp_path / "oce"
    runtime_dir = oce_source / "deploy" / "runtime"
    node_dir = runtime_dir / "node"
    node_dir.mkdir(parents=True)
    (node_dir / "source.json").write_text(
        json.dumps(
            {
                "version": "24.22.1",
                "commit": "ce7aaf1cee78b8cf0ce17364260535c418d3ed26",  # pragma: allowlist secret -- public source revision
                "sourceArchiveSha256": (
                    "4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231"  # pragma: allowlist secret -- public archive checksum
                ),
                "patchSha256": (
                    "4ca82f5f04473f4a79b89e57064f71d6f01e6fcacf6794930fc128177306b5c9"  # pragma: allowlist secret -- public patch checksum
                ),
                "modules": "137",
                "napi": "10",
            }
        ),
        encoding="utf-8",
    )
    (runtime_dir / "openclaw-source.json").write_text(
        json.dumps(
            {
                "commit": "513c12703ad9a9161cc123e0b8ed4ecb811aa6b3",  # pragma: allowlist secret -- public source revision
                "sourceArchiveSha256": (
                    "dab8e21f38603bace955a157f804ddec32b0097ab52286c87b0c0886d45b7730"  # pragma: allowlist secret -- public archive checksum
                ),
                "buildTimestamp": "2026-11-04T17:24:42Z",
            }
        ),
        encoding="utf-8",
    )
    (runtime_dir / "Dockerfile").write_text(
        """ARG NODE_BASE_IMAGE=docker.io/library/node:24.22.1-bookworm@sha256:6449e19d8184d84062525b6a7524def03146c2cb04a7f08b076680d0e8e4240a
ARG NODE_RUNTIME_BASE_IMAGE=docker.io/library/node:24.22.1-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205
FROM node-build-base AS node-source
# Record every patch applied here in appliedPatches in scripts/build-runtime-assets.mjs,
# which writes provenance; runtime-assets.test.mjs compares the two.
FROM node-build-base AS curl-packages
COPY deploy/runtime/curl /tmp/curl
RUN --mount=type=secret,id=build-ca,required=false \\
    set -eu; \\
    if [ -f /run/secrets/build-ca ]; then export CURL_CA_BUNDLE=/run/secrets/build-ca; fi; \\
    sh /tmp/curl/build.sh
FROM node-runtime-base AS runtime

RUN --mount=type=bind,from=curl-packages,source=/out,target=/tmp/curl-packages \\
    apt-get update --error-on=any \\
    && candidate="$(apt-cache policy curl | sed -n 's/^  Candidate: //p')" \\
    && expected="$(cat /tmp/curl-packages/debian-version)" \\
    && { [ "$candidate" = "$expected" ] || { echo "Refresh the curl backport: Debian candidate is $candidate, source is $expected" >&2; exit 1; }; } \\
    && apt-get install -y --no-install-recommends tini git ca-certificates openssh-client libstdc++6 libgomp1 python3 procps /tmp/curl-packages/*.deb \\
    && mkdir -p /usr/share/doc/curl/oce \\
    && cp /tmp/curl-packages/*.sha256 /usr/share/doc/curl/oce/ \\
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; . /etc/os-release; \\
    test "${VERSION_CODENAME:-}" = bookworm || { echo "The Node termination repair requires a Bookworm runtime base." >&2; exit 1; };

RUN curl -O "https://github.com/cli/cli/releases/download/v2.103.2/gh_2.103.2_linux_${architecture}.tar.gz"; \\
    curl -O "https://github.com/cli/cli/releases/download/v2.103.2/gh_2.103.2_checksums.txt"; \\
    echo '414d6009dc7f9f936d70831af818d1a32aa0ff07a77646861efd207356a36b2d  gh_2.103.2_checksums.txt' | sha256sum --check --strict; \\
    grep " gh_2.103.2_linux_${architecture}.tar.gz$" gh_2.103.2_checksums.txt | sha256sum --check --strict; \\
    tar -xzf "gh_2.103.2_linux_${architecture}.tar.gz"; \\
    install -m 0755 "gh_2.103.2_linux_${architecture}/bin/gh" /usr/local/bin/gh; \\
    rm -rf /tmp/gh_2.103.2*; \\
    XDG_STATE_HOME="$gh_state" /usr/local/bin/gh --version | grep '^gh version 2.103.2 '
""",
        encoding="utf-8",
    )
    gog_release_dir = (
        oce_source
        / "apps"
        / "controller"
        / "plugins"
        / "oce-google-workspace"
        / "ai.openclaw.oce"
    )
    gog_release_dir.mkdir(parents=True)
    (gog_release_dir / "release.json").write_text(
        json.dumps(
            {
                "version": "0.46.0",
                "artifacts": {
                    "linux-amd64": {
                        "url": "https://github.com/openclaw/gogcli/releases/download/v0.46.0/gogcli_0.46.0_linux_amd64.tar.gz",
                        "archiveSha256": "d53cf89f0c2a2338211212e380b3efcacadd4e27e500cb8e7ed2cd82a739da2e",  # pragma: allowlist secret -- public checksum
                        "binarySha256": "36551bb5725a7c7f22413826109ed455ce9de9a1aecaa81e918a5d461072787a",  # pragma: allowlist secret -- public checksum
                    },
                    "linux-arm64": {
                        "url": "https://github.com/openclaw/gogcli/releases/download/v0.46.0/gogcli_0.46.0_linux_arm64.tar.gz",
                        "archiveSha256": "9ae69d117cef895aa1c50b5859d7d3def45c5580886b25dc1c7f3cfe128ed0dd",  # pragma: allowlist secret -- public checksum
                        "binarySha256": "ad84f12b8efd889f65bd7c45c4eb6152fa963f623394fdf50938b14c57b9b694",  # pragma: allowlist secret -- public checksum
                    },
                },
            }
        ),
        encoding="utf-8",
    )
    scripts_dir = oce_source / "scripts"
    scripts_dir.mkdir()
    (scripts_dir / "build-runtime-assets.mjs").write_text(
        "const appliedPatches = [\n];\n",
        encoding="utf-8",
    )
    (node_dir / "fetch.sh").write_text(
        """#!/bin/sh
set -eu
. /etc/os-release
test "$VERSION_CODENAME" = bookworm
archive_sha=$(node -p 'require("./source.json").sourceArchiveSha256')
patch_sha=$(node -p 'require("./source.json").patchSha256')
printf '%s  /build/node.tar.xz\\n%s  worker-esm-termination.patch\\n' "$archive_sha" "$patch_sha" | sha256sum --check --strict
git apply /node-repair/worker-esm-termination.patch
""",
        encoding="utf-8",
    )
    curl_dir = runtime_dir / "curl"
    curl_dir.mkdir()
    (curl_dir / "build.sh").write_text(
        """#!/bin/sh
set -eu
# TODO: Remove this backport when Bookworm publishes a CVE-2026-86414 fix.
version=7.88.1-10+deb12u15
for file in "curl_${version}.dsc" curl_7.88.1.orig.tar.gz curl_7.88.1.orig.tar.gz.asc "curl_${version}.debian.tar.xz"; do
  :
done
2744f12e3aef161c0361743fa1b318296b122e566e47f381e4a63320fbcc23f4  curl_7.88.1-10+deb12u15.dsc
cdb38b72e36bc5d33d5b8810f8018ece1baa29a8f215b4495e495ded82bbf3c7  curl_7.88.1.orig.tar.gz
7a5a55d7123149a1b357f298cf895bd0a601e3a2807005ef6c95f3752803485f  curl_7.88.1.orig.tar.gz.asc
961b78bc48492c5693e4decb352ddd176f343260a8956f48b2887874048ef23b  curl_7.88.1-10+deb12u15.debian.tar.xz
quilt pop -a
cp /tmp/curl/CVE-2026-86414.patch debian/patches/
# Debian copies the tree for each backend while applying its final two patches.
# The security fix must precede both, so it reaches OpenSSL and GnuTLS alike.
sed -i '/^90_gnutls.patch$/i CVE-2026-86414.patch' debian/patches/series
quilt push -a
curl (7.88.1-10+deb12u15+oce1) bookworm; urgency=medium
for package in curl libcurl4 libcurl3-gnutls; do
  :
done
sha256sum ../*.dsc ../*.orig.tar.gz ../*.debian.tar.xz /tmp/curl/CVE-2026-86414.patch > /out/source.sha256
""",
        encoding="utf-8",
    )
    (curl_dir / "verify.sh").write_text(
        """#!/bin/sh
set -eu
for backend in build build-gnutls; do
  (
    cd "/build/curl/source/debian/$backend/tests" &&
    make -C server -j2 all &&
    perl ./runtests.pl -a -n -v 80 83 206 217 310 311 2173
  )
done
""",
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "-q", str(oce_source)], check=True)
    subprocess.run(["git", "-C", str(oce_source), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(oce_source),
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-qm",
            "fixture",
        ],
        check=True,
    )
    revision = subprocess.run(
        ["git", "-C", str(oce_source), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return oce_source, revision


def _oce_security_patcher_args(
    oce_source: pathlib.Path,
    revision: str,
) -> list[str]:
    return [
        sys.executable,
        "-I",
        str(OCE_SECURITY_PATCHER),
        str(oce_source),
        revision,
        str(OPENSSL_BACKPORT_PATCH),
        str(OPENCLAW_DEPENDENCY_PATCH),
        str(CURL_BACKPORT_PATCH),
        str(OPENSSL_88823_SOURCE_ASSETS),
        str(OPENSSL_88823_BACKPORT_PATCH),
        str(OPENSSL_88823_TEST_PATCH),
        str(OPENSSL_107496_BACKPORT_PATCH),
    ]


def test_oce_security_patcher_applies_the_reviewed_backport(
    tmp_path: pathlib.Path,
) -> None:
    oce_source, revision = _create_fake_oce_source(tmp_path)

    result = subprocess.run(
        _oce_security_patcher_args(oce_source, revision),
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    node_dir = oce_source / "deploy" / "runtime" / "node"
    assert (node_dir / "openssl-cve-2026-95692.patch").read_bytes() == (
        OPENSSL_BACKPORT_PATCH.read_bytes()
    )
    fetch = (node_dir / "fetch.sh").read_text(encoding="utf-8")
    assert "security_patch_sha=" in fetch
    assert "sha256sum --check --strict" in fetch
    assert 'test "$VERSION_CODENAME" = trixie' in fetch
    assert 'test "$VERSION_CODENAME" = bookworm' not in fetch
    assert (
        "git apply -p1 --directory=deps/openssl/openssl "
        "/node-repair/openssl-cve-2026-95692.patch" in fetch
    )
    assert (
        "git apply -p1 --directory=deps/openssl/openssl "
        "--include=deps/openssl/openssl/crypto/ec/ec_key.c "
        "/node-repair/openssl-cve-2026-107496.patch" in fetch
    )
    runtime_dir = oce_source / "deploy" / "runtime"
    assert (
        runtime_dir / "openclaw-security-overrides.patch"
    ).read_bytes() == OPENCLAW_DEPENDENCY_PATCH.read_bytes()
    dockerfile = (runtime_dir / "Dockerfile").read_text(encoding="utf-8")
    assert (
        "git apply /tmp/openclaw-security-overrides.patch" in dockerfile
    )
    assert (
        "2b1fb478649494c0b74879bbed20c55155658575555ebe37a88050d372aef451"  # pragma: allowlist secret -- reviewed patch checksum
        in dockerfile
    )
    assert "FROM node-build-base AS npm-runtime" in dockerfile
    assert "npm-11.21.3.tgz" in dockerfile
    assert (
        "ee5fc68e724c4bdba38db9d96d9c661d4e736e4be7001ae44d2fbbaa52159514"  # pragma: allowlist secret -- public archive checksum
        in dockerfile
    )
    assert 'require("/out/node_modules/undici/package.json").version' in dockerfile
    assert "RUN rm -rf /usr/local/lib/node_modules/npm" in dockerfile
    assert "COPY --from=npm-runtime /out/ /usr/local/lib/node_modules/npm/" in (
        dockerfile
    )
    assert (
        'require("/usr/local/lib/node_modules/npm/node_modules/undici/package.json").version'
        in dockerfile
    )
    assert "node:24.22.1-bookworm@" not in dockerfile
    assert "node:24.22.1-bookworm-slim@" not in dockerfile
    assert (
        "node:24.22.1-trixie@sha256:"
        "f1e034976f948cf212ef1f659c12e5dd58ac7eab947831813e81a62401ca38be"  # pragma: allowlist secret -- public image digest
        in dockerfile
    )
    assert (
        "node:24.22.1-trixie-slim@sha256:"
        "89c5244bc22a9bc3287d89ebc7e49b9cb5bb84cd40e6175ac3421d5a9f68b95a"  # pragma: allowlist secret -- public image digest
        in dockerfile
    )
    assert 'test "${VERSION_CODENAME:-}" = trixie' in dockerfile
    assert "requires a Trixie runtime base" in dockerfile
    assert "requires a Bookworm runtime base" not in dockerfile
    assert "v2.103.2" not in dockerfile
    assert "gh_2.103.2" not in dockerfile
    assert "v2.105.0" in dockerfile
    assert "gh_2.105.0" in dockerfile
    assert (
        "4597138ea96e474c68001370c0a4955ff4834ba603c53900de6ebbef4cb0bed9"  # pragma: allowlist secret -- public checksum
        in dockerfile
    )
    gog_release = (
        oce_source
        / "apps"
        / "controller"
        / "plugins"
        / "oce-google-workspace"
        / "ai.openclaw.oce"
        / "release.json"
    ).read_text(encoding="utf-8")
    assert "0.46.0" not in gog_release
    assert '"version": "0.48.1"' in gog_release
    assert "gogcli_0.48.1_linux_amd64.tar.gz" in gog_release
    assert "gogcli_0.48.1_linux_arm64.tar.gz" in gog_release
    assert (
        "dcd956e09d1222a07c1304d836f8acd55266b2fa241ef466580ced6a02453d72"  # pragma: allowlist secret -- public checksum
        in gog_release
    )
    assert (
        "c091fa2014dc3d5608acef4d09fb3bb4a3eb71e4cff898b5eaddd9703599e45c"  # pragma: allowlist secret -- public checksum
        in gog_release
    )
    runtime_assets = (
        oce_source / "scripts" / "build-runtime-assets.mjs"
    ).read_text(encoding="utf-8")
    assert 'file: "openclaw-security-overrides.patch"' in runtime_assets
    curl_dir = runtime_dir / "curl"
    assert (
        curl_dir / "CVE-2026-86414.patch"
    ).read_bytes() == CURL_BACKPORT_PATCH.read_bytes()
    curl_build = (curl_dir / "build.sh").read_text(encoding="utf-8")
    assert "Bookworm" not in curl_build
    assert "version=8.14.1-2+deb13u7" in curl_build
    assert "curl_8.14.1.orig.tar.gz" in curl_build
    assert "curl_8.14.1.orig.tar.xz" not in curl_build
    assert "quilt pop -a" not in curl_build
    assert (
        "printf '%s\\n' CVE-2026-86414.patch >> debian/patches/series"
        in curl_build
    )
    assert "curl (8.14.1-2+deb13u7+oce1) trixie" in curl_build
    assert "for package in curl libcurl4t64 libcurl3t64-gnutls; do" in curl_build
    curl_verify = (curl_dir / "verify.sh").read_text(encoding="utf-8")
    assert "make -C certs -j2 all" in curl_verify
    assert "test -s certs/test-localhost.pem" in curl_verify
    assert curl_verify.index("make -C certs") < curl_verify.index("make -C server")


def test_reviewed_openssl_backport_is_a_valid_git_patch(
    tmp_path: pathlib.Path,
) -> None:
    result = subprocess.run(
        [
            "git",
            "apply",
            "--numstat",
            "--unsafe-paths",
            str(OPENSSL_BACKPORT_PATCH),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == (
        "14\t0\tproviders/implementations/ciphers/cipher_aes_gcm_siv.c\n"
    )


def test_cve_2026_88823_backport_matches_exact_upstream_commit_and_build_contract(
    tmp_path: pathlib.Path,
) -> None:
    patch_bytes = OPENSSL_88823_BACKPORT_PATCH.read_bytes()
    patch = patch_bytes.decode()
    script = SCRIPT.read_text(encoding="utf-8")
    build_script = (
        OPENSSL_88823_SOURCE_ASSETS / "build.sh"
    ).read_text(encoding="utf-8")
    verify_script = (
        OPENSSL_88823_SOURCE_ASSETS / "verify.sh"
    ).read_text(encoding="utf-8")
    patch_sha256 = hashlib.sha256(patch_bytes).hexdigest()

    assert patch.startswith(f"From {OPENSSL_88823_UPSTREAM_COMMIT} ")
    assert "Fixes: CVE-2026-88823" in patch
    assert OPENSSL_88823_BACKPORT_PATCH.name in script
    assert "CVE-2026-88823" in script
    assert OPENSSL_88823_UPSTREAM_COMMIT in script
    assert patch_sha256 in script
    assert "apt-get install -y --no-install-recommends quilt" in build_script
    assert build_script.index("apt-get install -y --no-install-recommends quilt") < (
        build_script.index("quilt push -a")
    )
    assert (
        """test "$(grep -c 'ADD_TEST(test_aes_gcm_siv_' """
        """test/evp_extra_test.c)" -eq 6"""
    ) in verify_script

    result = subprocess.run(
        [
            "git",
            "apply",
            "--numstat",
            "--unsafe-paths",
            str(OPENSSL_88823_BACKPORT_PATCH),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == (
        "10\t0\tproviders/implementations/ciphers/cipher_aes_gcm_siv.c\n"
        "1\t6\tproviders/implementations/ciphers/cipher_aes_gcm_siv_hw.c\n"
    )


def test_cve_2026_107496_backport_matches_exact_upstream_commit_and_build_contract(
    tmp_path: pathlib.Path,
) -> None:
    patch_bytes = OPENSSL_107496_BACKPORT_PATCH.read_bytes()
    patch = patch_bytes.decode()
    script = SCRIPT.read_text(encoding="utf-8")
    build_script = (
        OPENSSL_88823_SOURCE_ASSETS / "build.sh"
    ).read_text(encoding="utf-8")
    verify_script = (
        OPENSSL_88823_SOURCE_ASSETS / "verify.sh"
    ).read_text(encoding="utf-8")
    patch_sha256 = hashlib.sha256(patch_bytes).hexdigest()

    assert patch.startswith(f"From {OPENSSL_107496_UPSTREAM_COMMIT} ")
    assert "Fixes: CVE-2026-107496" in patch
    assert OPENSSL_107496_BACKPORT_PATCH.name in script
    assert "CVE-2026-107496" in script
    assert OPENSSL_107496_UPSTREAM_COMMIT in script
    assert patch_sha256 in script
    assert "CVE-2026-107496.patch" in build_script
    assert "keygen_invalid_order_test" in verify_script
    assert "test_ec" in verify_script

    result = subprocess.run(
        [
            "git",
            "apply",
            "--numstat",
            "--unsafe-paths",
            str(OPENSSL_107496_BACKPORT_PATCH),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == (
        "5\t0\tcrypto/ec/ec_key.c\n"
        "33\t0\ttest/ectest.c\n"
    )


def test_reviewed_openclaw_dependency_patch_is_scoped_to_the_dependency_files(
    tmp_path: pathlib.Path,
) -> None:
    result = subprocess.run(
        [
            "git",
            "apply",
            "--numstat",
            "--unsafe-paths",
            str(OPENCLAW_DEPENDENCY_PATCH),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == (
        "1\t1\tpackage.json\n"
        "17\t20\tpnpm-lock.yaml\n"
        "7\t0\tpnpm-workspace.yaml\n"
    )


def test_reviewed_curl_backport_is_scoped_to_the_proxy_fix(
    tmp_path: pathlib.Path,
) -> None:
    result = subprocess.run(
        [
            "git",
            "apply",
            "--numstat",
            "--unsafe-paths",
            str(CURL_BACKPORT_PATCH),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == (
        "2\t4\tlib/cf-h1-proxy.c\n"
        "2\t0\ttests/data/Makefile.am\n"
        "68\t0\ttests/data/test2173\n"
        "1\t1\ttests/testutil.pm\n"
    )
    patch = CURL_BACKPORT_PATCH.read_text(encoding="utf-8")
    assert "(GET|POST|PUT|DELETE|CONNECT)" in patch
    assert "+56\n+</errorcode>" in patch


def test_oce_security_patcher_fails_closed_on_source_or_revision_drift(
    tmp_path: pathlib.Path,
) -> None:
    oce_source, revision = _create_fake_oce_source(tmp_path)
    source_json = oce_source / "deploy" / "runtime" / "node" / "source.json"
    source = json.loads(source_json.read_text(encoding="utf-8"))
    source["version"] = "24.22.2"
    source_json.write_text(json.dumps(source), encoding="utf-8")

    wrong_source = subprocess.run(
        _oce_security_patcher_args(oce_source, revision),
        check=False,
        capture_output=True,
        text=True,
    )
    wrong_revision = subprocess.run(
        _oce_security_patcher_args(oce_source, "0" * 40),
        check=False,
        capture_output=True,
        text=True,
    )

    assert wrong_source.returncode == 1
    assert "source metadata changed" in wrong_source.stderr
    assert wrong_revision.returncode == 1
    assert "OCE checkout is" in wrong_revision.stderr


def test_oce_security_patcher_fails_closed_on_openclaw_source_drift(
    tmp_path: pathlib.Path,
) -> None:
    oce_source, revision = _create_fake_oce_source(tmp_path)
    source_json = oce_source / "deploy" / "runtime" / "openclaw-source.json"
    source = json.loads(source_json.read_text(encoding="utf-8"))
    source["commit"] = "0" * 40
    source_json.write_text(json.dumps(source), encoding="utf-8")

    result = subprocess.run(
        _oce_security_patcher_args(oce_source, revision),
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "pinned OpenClaw source metadata changed" in result.stderr
    assert not (
        oce_source
        / "deploy"
        / "runtime"
        / "openclaw-security-overrides.patch"
    ).exists()


def test_oce_security_patcher_fails_closed_on_runtime_dockerfile_drift(
    tmp_path: pathlib.Path,
) -> None:
    oce_source, revision = _create_fake_oce_source(tmp_path)
    dockerfile = oce_source / "deploy" / "runtime" / "Dockerfile"
    dockerfile.write_text(
        dockerfile.read_text(encoding="utf-8").replace(
            "FROM node-runtime-base AS runtime",
            "FROM node-runtime-base AS changed-runtime",
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        _oce_security_patcher_args(oce_source, revision),
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "runtime patch anchors changed" in result.stderr


def test_oce_security_patcher_fails_closed_on_curl_source_drift(
    tmp_path: pathlib.Path,
) -> None:
    oce_source, revision = _create_fake_oce_source(tmp_path)
    curl_build = oce_source / "deploy" / "runtime" / "curl" / "build.sh"
    curl_build.write_text(
        curl_build.read_text(encoding="utf-8").replace(
            "version=7.88.1-10+deb12u15",
            "version=7.88.1-10+deb12u16",
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        _oce_security_patcher_args(oce_source, revision),
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "pinned curl source build changed" in result.stderr


def test_oce_security_patcher_fails_closed_on_node_base_drift(
    tmp_path: pathlib.Path,
) -> None:
    oce_source, revision = _create_fake_oce_source(tmp_path)
    dockerfile = oce_source / "deploy" / "runtime" / "Dockerfile"
    dockerfile.write_text(
        dockerfile.read_text(encoding="utf-8").replace(
            "node:24.22.1-bookworm@",
            "node:24.22.2-bookworm@",
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        _oce_security_patcher_args(oce_source, revision),
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "pinned Node base images changed" in result.stderr


def _oce_lock_result(
    tmp_path: pathlib.Path, content: str
) -> subprocess.CompletedProcess[str]:
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
