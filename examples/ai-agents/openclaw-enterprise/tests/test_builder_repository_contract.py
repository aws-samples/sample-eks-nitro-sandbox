"""Contracts for the run-owned builder repository lifecycle."""

from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import textwrap
import time

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = SAMPLE / "scripts" / "manage-builder-repository.sh"
README = SAMPLE / "README.md"
RUN_ID = "a" * 24
REPOSITORY_NAME = f"openclaw-enterprise/codebuild-builder-{RUN_ID}"
REPOSITORY_ARN = (
    "arn:aws:ecr:us-west-2:123456789012:repository/" + REPOSITORY_NAME
)


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
            if [[ "$1 $2" == "ecr describe-repositories" ]]; then
              if [[ "${FAKE_FIRST_DESCRIBE_PER_PARENT:-0}" == 1 ]]; then
                parent_marker="${FAKE_AWS_STATE}.describe.$PPID"
                if [[ ! -e "$parent_marker" ]]; then
                  : >"$parent_marker"
                  printf 'RepositoryNotFoundException\\n' >&2
                  exit 254
                fi
              fi
              if [[ "${FAKE_REPOSITORY_EXISTS:-0}" == 1 || -e "$FAKE_AWS_STATE" ]]; then
                cat <<JSON
            {"repositories":[{"repositoryArn":"arn:aws:ecr:us-west-2:123456789012:repository/openclaw-enterprise/codebuild-builder-aaaaaaaaaaaaaaaaaaaaaaaa","registryId":"123456789012","repositoryName":"openclaw-enterprise/codebuild-builder-aaaaaaaaaaaaaaaaaaaaaaaa"}]}
            JSON
                exit 0
              fi
              printf 'RepositoryNotFoundException\\n' >&2
              exit 254
            fi
            if [[ "$1 $2" == "ecr create-repository" ]]; then
              if [[ -n "${FAKE_CREATE_DELAY:-}" ]]; then
                sleep "$FAKE_CREATE_DELAY"
              fi
              if [[ "${FAKE_CREATE_FAIL:-0}" == 1 ]]; then
                printf 'create failed\\n' >&2
                exit 9
              fi
              : >"$FAKE_AWS_STATE"
              exit 0
            fi
            if [[ "$1 $2" == "ecr list-tags-for-resource" ]]; then
              managed_by="${FAKE_MANAGED_BY:-openclaw-enterprise-sample}"
              cat <<JSON
            {"tags":[{"Key":"ManagedBy","Value":"$managed_by"},{"Key":"OpenClawValidationRun","Value":"aaaaaaaaaaaaaaaaaaaaaaaa"}]}
            JSON
              exit 0
            fi
            if [[ "$1 $2" == "ecr delete-repository" ]]; then
              if [[ "${FAKE_DELETE_FAIL:-0}" == 1 ]]; then
                printf 'delete failed\\n' >&2
                exit 9
              fi
              rm -f -- "$FAKE_AWS_STATE"
              : >"${FAKE_AWS_STATE}.deleted"
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
    ]


def _delete_command(receipt: pathlib.Path) -> list[str]:
    return ["bash", str(SCRIPT), "delete", "--receipt", str(receipt)]


def _write_receipt(
    receipt: pathlib.Path, status: str, repository_arn: str | None
) -> None:
    receipt.write_text(
        json.dumps(
            {
                "version": 1,
                "operation": "builder-repository",
                "status": status,
                "accountId": "123456789012",
                "region": "us-west-2",
                "runId": RUN_ID,
                "repositoryName": REPOSITORY_NAME,
                "repositoryArn": repository_arn,
            }
        ),
        encoding="utf-8",
    )
    receipt.chmod(0o600)


def _private_receipt(tmp_path: pathlib.Path) -> pathlib.Path:
    private_dir = tmp_path / "private"
    private_dir.mkdir(mode=0o700)
    return private_dir / "builder-repository.json"


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


def test_script_is_executable_and_documented() -> None:
    assert os.access(SCRIPT, os.X_OK)
    readme = README.read_text(encoding="utf-8")
    assert 'manage-builder-repository.sh" create' in readme
    assert 'manage-builder-repository.sh" delete' in readme
    assert "BUILDER_REPOSITORY_RECEIPT" in readme


def test_create_and_delete_use_one_verified_run_owned_repository(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
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
    assert payload == {
        "version": 1,
        "operation": "builder-repository",
        "status": "created",
        "accountId": "123456789012",
        "region": "us-west-2",
        "runId": RUN_ID,
        "repositoryName": REPOSITORY_NAME,
        "repositoryArn": REPOSITORY_ARN,
    }
    assert receipt.stat().st_mode & 0o777 == 0o600

    deleted = subprocess.run(
        _delete_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert deleted.returncode == 0, deleted.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "deleted"
    calls = aws_log.read_text(encoding="utf-8")
    assert f"delete-repository --region us-west-2 --repository-name {REPOSITORY_NAME}" in calls
    assert "--force" in calls


def test_concurrent_create_cannot_overwrite_the_receipt(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_CREATE_DELAY"] = "0.2"

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
    assert aws_log.read_text(encoding="utf-8").count("ecr create-repository") == 1
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "created"
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_delete_cannot_race_an_in_progress_create(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_CREATE_DELAY"] = "0.3"

    create = subprocess.Popen(
        _create_command(receipt),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    _wait_for_receipt_status(receipt, "create-planned")

    deleted = subprocess.run(
        _delete_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    _, stderr = create.communicate()

    assert create.returncode == 0, stderr
    assert deleted.returncode != 0
    assert "another operation is using this receipt" in deleted.stderr
    assert "ecr delete-repository" not in aws_log.read_text(encoding="utf-8")
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "created"
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_create_refuses_an_unverified_stale_operation_lock(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
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
    receipt = _private_receipt(tmp_path)
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
    receipt = _private_receipt(tmp_path)
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
    assert "create requires --region" in result.stderr
    assert inherited_error_file.read_text(encoding="utf-8") == "keep\n"
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_signal_during_create_retains_lock_for_manual_reconciliation(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    operation_lock = pathlib.Path(f"{receipt}.lock")
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_CREATE_DELAY"] = "0.5"

    create = subprocess.Popen(
        _create_command(receipt),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    _wait_for_receipt_status(receipt, "create-planned")
    _wait_for_log_text(aws_log, "ecr create-repository")
    create.send_signal(signal.SIGTERM)
    _, stderr = create.communicate(timeout=5)

    assert create.returncode == 143, stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == (
        "create-planned"
    )
    assert operation_lock.is_dir()
    assert (operation_lock / "pid").read_text(encoding="utf-8").strip().isdigit()


def test_delete_refuses_repository_with_wrong_ownership_tag(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    _write_receipt(receipt, "created", REPOSITORY_ARN)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_REPOSITORY_EXISTS"] = "1"
    environment["FAKE_MANAGED_BY"] = "someone-else"

    result = subprocess.run(
        _delete_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode != 0
    assert "refusing to delete" in result.stderr
    assert "ecr delete-repository" not in aws_log.read_text(encoding="utf-8")
    assert not pathlib.Path(f"{receipt}.lock").exists()


def test_delete_reconciles_planned_receipt_when_repository_is_absent(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    _write_receipt(receipt, "create-planned", None)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)

    result = subprocess.run(
        _delete_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "deleted"
    assert payload["repositoryArn"] is None
    assert "ecr delete-repository" not in aws_log.read_text(encoding="utf-8")


def test_delete_reconciles_unconfirmed_create_when_repository_exists(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    _write_receipt(receipt, "create-unconfirmed", None)
    bin_dir, aws_log = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, aws_log)
    environment["FAKE_REPOSITORY_EXISTS"] = "1"

    result = subprocess.run(
        _delete_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    assert payload["status"] == "deleted"
    assert payload["repositoryArn"] == REPOSITORY_ARN


def test_delete_records_uncertain_result_and_can_resume(
    tmp_path: pathlib.Path,
) -> None:
    receipt = _private_receipt(tmp_path)
    _write_receipt(receipt, "created", REPOSITORY_ARN)
    bin_dir, _ = _fake_tools(tmp_path)
    environment = _environment(tmp_path, bin_dir, tmp_path / "aws.log")
    environment["FAKE_REPOSITORY_EXISTS"] = "1"
    environment["FAKE_DELETE_FAIL"] = "1"

    failed = subprocess.run(
        _delete_command(receipt),
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
        _delete_command(receipt),
        check=False,
        text=True,
        capture_output=True,
        env=environment,
    )
    assert resumed.returncode == 0, resumed.stderr
    assert json.loads(receipt.read_text(encoding="utf-8"))["status"] == "deleted"
