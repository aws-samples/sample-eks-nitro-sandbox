"""Static contracts for the CodeBuild and ECR source-build path."""

from __future__ import annotations

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
OCE_LOCK_CHECK = BUILD / "check-oce-lock.py"
ADAPTER_DOCKERFILE = SAMPLE / "adapter" / "Dockerfile"
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
    return yaml.load(TEMPLATE.read_text(encoding="utf-8"), Loader=_CloudFormationLoader)


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


def test_readme_mirrors_a_pinned_builder_and_resolves_the_trusted_principal() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    build_step = readme.split("**Step 2: Build and scan the images**", 1)[1].split(
        "**Step 3:", 1
    )[0]

    assert re.search(
        r"BUILDER_SOURCE_IMAGE='[^']+@sha256:[0-9a-f]{64}'", build_step
    )
    assert "docker pull --platform linux/amd64" in build_step
    assert 'BuilderImageRepositoryName="$BUILDER_REPOSITORY"' in build_step
    assert 'BuilderImageDigest="$BUILDER_DIGEST"' in build_step
    assert 'TrustedBuildInvokerArn="$TRUSTED_BUILD_INVOKER_ARN"' in build_step
    assert '"Key=OpenClawValidationRun,Value=$EKS_CLUSTER_NAME"' in build_step
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

    assert "aws ecr list-tags-for-resource" in cleanup
    assert "OpenClawValidationRun" in cleanup
    assert '[[ "$builder_repository_run" == "$EKS_CLUSTER_NAME" ]]' in cleanup
    assert "aws ecr delete-repository" in cleanup


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

    start_index = commands.index("/usr/local/bin/dockerd-entrypoint.sh true")
    ready_index = commands.index(
        "docker info --format 'daemon {{.ServerVersion}}, storage driver {{.Driver}}'"
    )
    build_index = commands.index(
        "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/"
        "build/build-images.sh"
    )

    assert start_index < ready_index < build_index


def test_stack_inputs_are_exact_revisions_and_a_controller_digest() -> None:
    parameters = _template()["Parameters"]

    for name in ("SampleGitRevision", "OceGitRevision"):
        assert parameters[name]["AllowedPattern"] == "^[0-9a-f]{40}$"
    assert parameters["OceGitRevision"]["Default"] == (
        "86c8c12310f691bb21651118ffffd6bfd460e9ff"
    )
    controller_digest = parameters["ControllerRuntimeBaseImageDigest"]
    assert controller_digest["AllowedPattern"] == "^sha256:[0-9a-f]{64}$"
    assert re.fullmatch(
        r"sha256:[0-9a-f]{64}",
        controller_digest["Default"],
    )


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
    assert {
        log_group["Properties"]["LogGroupName"] for log_group in log_groups
    } == {
        "/aws/codebuild/openclaw-enterprise-images",
        "/aws/vendedlogs/states/openclaw-enterprise-image-build",
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
            "execution:openclaw-enterprise-image-build:*"
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
        statement for statement in statements if statement["Sid"] == "DeliverWorkflowLogs"
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

    assert '(\ncredentials="$(\n  aws sts assume-role' in build_step
    assert (
        "trap 'unset credentials AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY "
        "AWS_SESSION_TOKEN' EXIT" in build_step
    )
    assert '>"$image_outputs"\nchmod 600 "$image_outputs"\n)' in build_step
    assert ") \n\nexport ADAPTER_IMAGE" not in build_step
    assert (
        'export ADAPTER_IMAGE="$(\n  jq -er \'.ADAPTER_IMAGE\' '
        '"$PRIVATE_STATE_DIR/image-build-outputs.json"' in build_step
    )


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
    assert '--build-arg "NODE_BUILD_BASE_IMAGE=$node_base_image"' in script
    assert (
        '--build-arg "NODE_RUNTIME_BASE_IMAGE=$CONTROLLER_RUNTIME_BASE_IMAGE"' in script
    )
    assert (
        '--file "$SAMPLE_SOURCE_DIR/examples/ai-agents/openclaw-enterprise/'
        'build/controller-runtime.Dockerfile"' in script
    )
    assert '--file "$OCE_SOURCE_DIR/deploy/runtime/Dockerfile"' in script
    assert "node scripts/lib/openclaw-source.mjs build-args" in script
    assert 'OCE_MSAL_NODE_VERSION="7.2.0"' in script
    assert "check-oce-lock.py" in script
    assert script.count("docker buildx build") == 4
    assert "docker pull" not in script
    assert "skopeo copy" not in script


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
    assert dockerfile.count("FROM ${NODE_RUNTIME_BASE_IMAGE}") == 2
    runtime = dockerfile.split(
        "FROM ${NODE_RUNTIME_BASE_IMAGE} AS runtime", maxsplit=1
    )[1]
    assert "FROM ${NODE_BUILD_BASE_IMAGE}" not in runtime
    assert (
        "COPY --from=runtime-dependencies --chown=node:node "
        "/app/node_modules node_modules" in runtime
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
            f"/app/{workspace}/node_modules {workspace}/node_modules" in runtime
        )
    assert "COPY --from=dependencies" not in runtime
    assert (
        "RUN --mount=type=bind,source=pnpm-lock.yaml,"
        "target=/app/pnpm-lock.yaml,readonly" in runtime
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


def test_controller_runtime_base_has_an_allowlisted_repository_and_exact_digest() -> (
    None
):
    script = SCRIPT.read_text(encoding="utf-8")
    assert (
        'readonly CONTROLLER_RUNTIME_BASE_IMAGE_REPOSITORY="'
        'public.ecr.aws/docker/library/node"' in script
    )
    assert 'readonly CONTROLLER_RUNTIME_BASE_IMAGE_TAG="24-bookworm-slim"' in script
    assert (
        'readonly CONTROLLER_RUNTIME_BASE_IMAGE="${CONTROLLER_RUNTIME_BASE_IMAGE_REPOSITORY}:'
        "${CONTROLLER_RUNTIME_BASE_IMAGE_TAG}@"
        '${CONTROLLER_RUNTIME_BASE_IMAGE_DIGEST}"' in script
    )
    assert "${CONTROLLER_RUNTIME_BASE_IMAGE:-" not in script


def test_build_outputs_are_verified_digest_references() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    assert 'digest = json.load(handle).get("containerimage.digest", "")' in script
    assert "aws ecr describe-images \\" in script
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
