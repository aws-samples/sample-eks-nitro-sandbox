"""Contracts for run-owned image-build stack lifecycle management."""

from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import textwrap
import time

import yaml

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = SAMPLE / "scripts" / "manage-image-build-stack.sh"
TEMPLATE = SAMPLE / "build" / "template.yaml"
README = SAMPLE / "README.md"
RUN_ID = "a" * 24
STACK_NAME = f"openclaw-enterprise-images-{RUN_ID}"
STACK_ARN = (
    "arn:aws:cloudformation:us-west-2:123456789012:"
    f"stack/{STACK_NAME}/00000000-0000-0000-0000-000000000000"
)
OCE_REVISION = "86c8c12310f691bb21651118ffffd6bfd460e9ff"
BUILDER_DIGEST = (
    "sha256:4b98f5054863c6f18a3049d5ccebbfc6d34b6b5cf37152fb8bb50af81c390660"
)


class _CloudFormationLoader(yaml.SafeLoader):
    pass


def _construct_tagged(
    loader: _CloudFormationLoader, tag_suffix: str, node: yaml.Node
) -> object:
    del tag_suffix
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


_CloudFormationLoader.add_multi_constructor("!", _construct_tagged)


def _template() -> dict[str, object]:
    return yaml.load(TEMPLATE.read_text(encoding="utf-8"), Loader=_CloudFormationLoader)


def _fake_tools(tmp_path: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    aws_log = tmp_path / "aws.log"
    aws = bin_dir / "aws"
    aws.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            printf '%s\\n' "$*" >>"$FAKE_AWS_LOG"
            if [[ "$1 $2" == "sts get-caller-identity" ]]; then
              printf '%s\\n' "${FAKE_ACCOUNT_ID:-123456789012}"
              exit 0
            fi
            if [[ "$1 $2" == "cloudformation deploy" ]]; then
              if [[ -n "${FAKE_DEPLOY_DELAY:-}" ]]; then
                sleep "$FAKE_DEPLOY_DELAY"
              fi
              : >"$FAKE_AWS_STATE"
              exit 0
            fi
            if [[ "$1 $2" == "cloudformation describe-stacks" ]]; then
              if [[ "${FAKE_FIRST_DESCRIBE_PER_PARENT:-0}" == 1 ]]; then
                parent_marker="${FAKE_AWS_STATE}.describe.$PPID"
                if [[ ! -e "$parent_marker" ]]; then
                  : >"$parent_marker"
                  printf 'Stack with id openclaw-enterprise-images-aaaaaaaaaaaaaaaaaaaaaaaa does not exist\\n' >&2
                  exit 255
                fi
              fi
              if [[ "${FAKE_DESCRIBE_AFTER_DEPLOY_FAIL:-0}" == 1 && -e "$FAKE_AWS_STATE" ]]; then
                printf 'transient describe failure\\n' >&2
                exit 9
              fi
              if [[ "${FAKE_STACK_EXISTS:-0}" == 1 || -e "$FAKE_AWS_STATE" ]]; then
                run_id=aaaaaaaaaaaaaaaaaaaaaaaa
                stack_name="openclaw-enterprise-images-$run_id"
                stack_id="arn:aws:cloudformation:us-west-2:123456789012:stack/$stack_name/00000000-0000-0000-0000-000000000000"
                managed_by="${FAKE_MANAGED_BY:-openclaw-enterprise-sample}"
                if [[ "${FAKE_NO_OUTPUTS:-0}" == 1 ]]; then
                  outputs_json='[]'
                else
                  printf -v outputs_json \
                    '[{"OutputKey":"ValidationRunId","OutputValue":"%s"}]' \
                    "$run_id"
                fi
                printf \
                  '{"Stacks":[{"StackName":"%s","StackId":"%s","Tags":[{"Key":"ManagedBy","Value":"%s"},{"Key":"OpenClawValidationRun","Value":"%s"}],"Parameters":[{"ParameterKey":"ValidationRunId","ParameterValue":"%s"}],"Outputs":%s}]}\\n' \
                  "$stack_name" "$stack_id" "$managed_by" "$run_id" "$run_id" \
                  "$outputs_json"
                exit 0
              fi
              printf 'Stack with id openclaw-enterprise-images-aaaaaaaaaaaaaaaaaaaaaaaa does not exist\\n' >&2
              exit 255
            fi
            if [[ "$1 $2" == "cloudformation delete-stack" ]]; then
              if [[ "${FAKE_DELETE_FAIL:-0}" == 1 ]]; then
                printf 'transient delete failure\\n' >&2
                exit 9
              fi
              rm -f -- "$FAKE_AWS_STATE"
              : >"${FAKE_AWS_STATE}.deleted"
              exit 0
            fi
            if [[ "$1 $2" == "cloudformation wait" ]]; then
              if [[ "${FAKE_WAIT_FAIL:-0}" == 1 ]]; then
                printf 'transient wait failure\\n' >&2
                exit 9
              fi
              exit 0
            fi
            printf 'unexpected aws call: %s\\n' "$*" >&2
            exit 2
            """
        ),
        encoding="utf-8",
    )
    aws.chmod(0o700)
    openssl = bin_dir / "openssl"
    openssl.write_text(
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'aaaaaaaaaaaaaaaaaaaaaaaa\\n'\n",
        encoding="utf-8",
    )
    openssl.chmod(0o700)
    return bin_dir, aws_log


def _environment(
    tmp_path: pathlib.Path, bin_dir: pathlib.Path, aws_log: pathlib.Path
) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{bin_dir}:{environment['PATH']}",
            "FAKE_AWS_LOG": str(aws_log),
            "FAKE_AWS_STATE": str(tmp_path / "aws-state"),
        }
    )
    return environment


def _create_command(receipt: pathlib.Path) -> list[str]:
    return [
        "bash",
        str(SCRIPT),
        "create",
        "--receipt",
        str(receipt),
        "--region",
        "us-west-2",
        "--sample-revision",
        "b" * 40,
        "--builder-repository",
        "openclaw-enterprise/codebuild-builder",
        "--builder-digest",
        BUILDER_DIGEST,
        "--trusted-build-invoker-arn",
        "arn:aws:iam::123456789012:role/validation",
    ]


def _write_receipt(receipt: pathlib.Path, status: str, stack_id: str | None) -> None:
    receipt.write_text(
        json.dumps(
            {
                "version": 1,
                "operation": "image-build-stack",
                "status": status,
                "accountId": "123456789012",
                "region": "us-west-2",
                "runId": RUN_ID,
                "stackName": STACK_NAME,
                "stackId": stack_id,
                "repositoryPrefix": f"openclaw-enterprise/{RUN_ID}",
                "sampleRevision": "b" * 40,
                "oceRevision": OCE_REVISION,
            }
        ),
        encoding="utf-8",
    )
    receipt.chmod(0o600)


def _wait_for_receipt_status(
    receipt: pathlib.Path, expected_status: str
) -> None:
    for _ in range(100):
        try:
            if json.loads(receipt.read_text(encoding="utf-8"))["status"] == expected_status:
                return
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.01)
    raise AssertionError(f"receipt did not reach {expected_status}")


def _wait_for_log_text(log_file: pathlib.Path, expected_text: str) -> None:
    for _ in range(100):
        try:
            if expected_text in log_file.read_text(encoding="utf-8"):
                return
        except FileNotFoundError:
            pass
        time.sleep(0.01)
    raise AssertionError(f"log did not contain {expected_text}")


def test_template_scopes_named_resources_to_a_validation_run() -> None:
    template = _template()
    parameters = template["Parameters"]
    resources = template["Resources"]

    assert parameters["ValidationRunId"]["AllowedPattern"] == "^[a-f0-9]{24}$"
    assert resources["ImageBuildProject"]["Properties"]["Name"] == (
        "openclaw-enterprise-images-${ValidationRunId}"
    )
    assert resources["ImageBuildStateMachine"]["Properties"]["StateMachineName"] == (
        "openclaw-enterprise-image-build-${ValidationRunId}"
    )
    for logical_id in ("ImageBuildLogGroup", "ImageBuildStateMachineLogGroup"):
        assert (
            "${ValidationRunId}" in resources[logical_id]["Properties"]["LogGroupName"]
        )
    assert template["Outputs"]["ValidationRunId"]["Value"] == "ValidationRunId"
    assert parameters["BuilderImageDigest"]["AllowedValues"] == [BUILDER_DIGEST]
    assert (
        "MaxSessionDuration"
        not in resources["ImageBuildInvocationRole"]["Properties"]
    )


def test_readme_uses_receipted_stack_lifecycle_only() -> None:
    readme = README.read_text(encoding="utf-8")

    assert 'manage-image-build-stack.sh" create' in readme
    assert 'manage-image-build-stack.sh" delete' in readme
    assert "IMAGE_BUILD_STACK_RECEIPT" in readme
    assert "IMAGE_BUILD_STACK_ID" in readme
    assert "aws cloudformation delete-stack" not in readme


def test_create_and_delete_use_the_same_verified_stack_arn(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)

    created = subprocess.run(
        _create_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert created.returncode == 0, created.stderr
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "created"
    assert payload["runId"] == "a" * 24
    assert payload["stackName"] == f"openclaw-enterprise-images-{'a' * 24}"
    assert payload["repositoryPrefix"] == f"openclaw-enterprise/{'a' * 24}"
    assert payload["stackId"].startswith("arn:aws:cloudformation:us-west-2:")
    assert receipt.stat().st_mode & 0o777 == 0o600

    deleted = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert deleted.returncode == 0, deleted.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "deleted"
    calls = aws_log.read_text(encoding="utf-8")
    assert f"delete-stack --region us-west-2 --stack-name {payload['stackId']}" in calls
    assert (
        f"wait stack-delete-complete --region us-west-2 --stack-name {payload['stackId']}"
        in calls
    )


def test_create_refuses_to_adopt_an_existing_stack(tmp_path: pathlib.Path) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_STACK_EXISTS"] = "1"

    result = subprocess.run(
        _create_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode != 0
    assert "refusing to adopt existing stack" in result.stderr
    assert not receipt.exists()
    assert "cloudformation deploy" not in aws_log.read_text(encoding="utf-8")


def test_concurrent_create_cannot_overwrite_the_receipt(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_DEPLOY_DELAY"] = "0.2"

    first = subprocess.Popen(
        _create_command(receipt),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    _wait_for_receipt_status(receipt, "create-planned")
    second = subprocess.Popen(
        _create_command(receipt),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    processes = [first, second]
    results = [process.communicate() + (process.returncode,) for process in processes]

    assert sorted(result[2] for result in results) == [0, 1]
    failed = next(result for result in results if result[2] != 0)
    assert "another operation is using this receipt" in failed[1]
    assert (
        aws_log.read_text(encoding="utf-8").count("cloudformation deploy") == 1
    )
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "created"
    assert receipt.stat().st_mode & 0o777 == 0o600
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_delete_cannot_race_an_in_progress_create(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_DEPLOY_DELAY"] = "0.3"

    create = subprocess.Popen(
        _create_command(receipt),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    _wait_for_receipt_status(receipt, "create-planned")

    deleted = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    _, stderr = create.communicate()

    assert create.returncode == 0, stderr
    assert deleted.returncode != 0
    assert "another operation is using this receipt" in deleted.stderr
    assert "cloudformation delete-stack" not in aws_log.read_text(encoding="utf-8")
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "created"
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_create_refuses_an_unverified_stale_operation_lock(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    operation_lock = pathlib.Path(f"{receipt}.lock")
    operation_lock.mkdir()
    (operation_lock / "pid").write_text("2147483647\n", encoding="utf-8")
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)

    created = subprocess.run(
        _create_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert created.returncode != 0
    assert "a stale lock must be reviewed" in created.stderr
    assert not receipt.exists()
    assert operation_lock.exists()


def test_create_refuses_an_empty_stale_operation_lock(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    operation_lock = pathlib.Path(f"{receipt}.lock")
    operation_lock.mkdir()
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)

    created = subprocess.run(
        _create_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert created.returncode != 0
    assert "a stale lock must be reviewed" in created.stderr
    assert not receipt.exists()
    assert operation_lock.exists()


def test_early_failure_does_not_delete_an_inherited_error_file(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    inherited_error_file = tmp_path / "owned-by-caller"
    inherited_error_file.write_text("keep\n", encoding="utf-8")
    environment["error_file"] = str(inherited_error_file)

    result = subprocess.run(
        ["bash", str(SCRIPT), "create", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode != 0
    assert "create requires every documented argument" in result.stderr
    assert inherited_error_file.read_text(encoding="utf-8") == "keep\n"
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_signal_during_create_retains_lock_for_manual_reconciliation(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    operation_lock = pathlib.Path(f"{receipt}.lock")
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_DEPLOY_DELAY"] = "0.5"

    create = subprocess.Popen(
        _create_command(receipt),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    _wait_for_receipt_status(receipt, "create-planned")
    _wait_for_log_text(aws_log, "cloudformation deploy")
    create.send_signal(signal.SIGTERM)
    _, stderr = create.communicate(timeout=5)

    assert create.returncode == 143, stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == (
        "create-planned"
    )
    assert operation_lock.is_dir()
    assert (operation_lock / "pid").read_text(encoding="utf-8").strip().isdigit()


def test_delete_refuses_a_stack_with_wrong_ownership_tag(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    created = subprocess.run(
        _create_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert created.returncode == 0, created.stderr
    environment["FAKE_MANAGED_BY"] = "someone-else"

    result = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode != 0
    assert "refusing to delete" in result.stderr
    assert not pathlib.Path(f"{environment['FAKE_AWS_STATE']}.deleted").exists()
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_delete_recovers_create_planned_receipt_when_stack_exists(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    _write_receipt(receipt, "create-planned", None)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_STACK_EXISTS"] = "1"

    result = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "deleted"
    assert payload["stackId"] == STACK_ARN
    calls = aws_log.read_text(encoding="utf-8")
    assert f"describe-stacks --region us-west-2 --stack-name {STACK_NAME}" in calls
    assert f"delete-stack --region us-west-2 --stack-name {STACK_ARN}" in calls


def test_delete_recovers_in_progress_stack_before_outputs_exist(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    _write_receipt(receipt, "create-unconfirmed", None)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_STACK_EXISTS"] = "1"
    environment["FAKE_NO_OUTPUTS"] = "1"

    result = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "deleted"
    assert payload["stackId"] == STACK_ARN
    assert f"delete-stack --region us-west-2 --stack-name {STACK_ARN}" in (
        aws_log.read_text(encoding="utf-8")
    )


def test_delete_marks_create_planned_receipt_deleted_when_stack_is_absent(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    _write_receipt(receipt, "create-planned", None)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)

    result = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "deleted"
    assert payload["stackId"] is None
    assert "cloudformation delete-stack" not in aws_log.read_text(encoding="utf-8")


def test_create_records_unconfirmed_when_post_deploy_verification_fails(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_DESCRIBE_AFTER_DEPLOY_FAIL"] = "1"

    created = subprocess.run(
        _create_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert created.returncode != 0
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == (
        "create-unconfirmed"
    )
    operation_lock = pathlib.Path(f"{receipt}.lock")
    assert operation_lock.is_dir()
    (operation_lock / "pid").unlink()
    operation_lock.rmdir()

    environment["FAKE_DESCRIBE_AFTER_DEPLOY_FAIL"] = "0"
    deleted = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert deleted.returncode == 0, deleted.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "deleted"


def test_delete_records_unconfirmed_and_can_resume_after_delete_failure(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    _write_receipt(receipt, "created", STACK_ARN)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_STACK_EXISTS"] = "1"
    environment["FAKE_DELETE_FAIL"] = "1"

    failed = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert failed.returncode != 0
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == (
        "delete-unconfirmed"
    )
    operation_lock = pathlib.Path(f"{receipt}.lock")
    assert operation_lock.is_dir()
    (operation_lock / "pid").unlink()
    operation_lock.rmdir()

    environment["FAKE_DELETE_FAIL"] = "0"
    resumed = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert resumed.returncode == 0, resumed.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "deleted"


def test_delete_records_absent_stack_as_deleted_after_wait_failure(
    tmp_path: pathlib.Path,
) -> None:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    receipt = private_dir / "image-build-stack.json"
    _write_receipt(receipt, "created", STACK_ARN)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    pathlib.Path(environment["FAKE_AWS_STATE"]).touch()
    environment["FAKE_WAIT_FAIL"] = "1"

    failed = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert failed.returncode != 0
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == (
        "delete-unconfirmed"
    )
    operation_lock = pathlib.Path(f"{receipt}.lock")
    assert operation_lock.is_dir()
    (operation_lock / "pid").unlink()
    operation_lock.rmdir()

    environment["FAKE_WAIT_FAIL"] = "0"
    resumed = subprocess.run(
        ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)],
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert resumed.returncode == 0, resumed.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "deleted"
    assert "cloudformation delete-stack" in aws_log.read_text(encoding="utf-8")
