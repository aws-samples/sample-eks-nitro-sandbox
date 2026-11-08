#!/usr/bin/env python3
"""Run complete Box setup and cleanup with stateful local CLI substitutes."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[4]
# Select the operator-installed interpreter before individual cases replace PATH.
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("Bash is required to run the Strands Box lifecycle tests")
BASH = str(Path(BASH).resolve(strict=True))
SECTION = ROOT / "examples/subagent-security"

# Unknown calls fail. Every AWS, kubectl, and Docker invocation uses this local process.
STUB = r"""import json
import os
from pathlib import Path
import re
import sys

tool, args = sys.argv[1], sys.argv[2:]
directory = Path(os.environ["BOX_SETUP_CASE"])
state_file = directory / "cloud.json"
state = json.loads(state_file.read_text())
scenario = os.environ["BOX_SETUP_SCENARIO"]
with (directory / "commands.jsonl").open("a") as stream:
    stream.write(json.dumps([tool, *args]) + "\n")

def save():
    temporary = directory / f"cloud.{os.getpid()}.json"
    temporary.write_text(json.dumps(state))
    temporary.replace(state_file)

def output(value):
    save()
    print(value if isinstance(value, str) else json.dumps(value))
    sys.exit(0)

def option(name):
    return args[args.index(name) + 1]

def error(code, operation):
    save()
    print(f"aws: [ERROR]: An error occurred ({code}) when calling the {operation} operation: synthetic", file=sys.stderr)
    sys.exit(254)

if tool == "docker":
    if "push" in args:
        state["images"].append(args[-1].split(".amazonaws.com/")[-1].rsplit(":", 1)[0])
    if "inspect" in args:
        output("Name: default\nPlatforms: linux/amd64, linux/arm64")
    output("25.0.14")
if tool == "kubectl":
    if args[:1] == ["--context"]:
        if args[1] != "synthetic-context":
            sys.exit(92)
        args = args[2:]
    if args[:2] == ["config", "current-context"]:
        output("synthetic-context")
    if args[:2] == ["config", "view"]:
        output("https://synthetic-cluster.example")
    if args[:2] == ["get", "runtimeclass"]:
        output("runtimeclass.node.k8s.io/isolated-sandbox")
    if args[:2] == ["get", "namespace"]:
        if not state["namespace_owner"]:
            output("")
        form = option("-o")
        if form == "json":
            output({"metadata": {"labels": {"app.kubernetes.io/managed-by": state["namespace_owner"]}}})
        if form == "name":
            output("namespace/synthetic-namespace")
        output(state["namespace_owner"])
    if args[:1] == ["apply"]:
        text = Path(option("-f")).read_text()
        if re.search(r"^kind: Namespace$", text, re.M):
            state["namespace_owner"] = re.search(r"app.kubernetes.io/managed-by: (\S+)", text).group(1)
        output("applied")
    if args[:1] == ["delete"]:
        if args[1] == "namespace":
            state["namespace_owner"] = None
        output("deleted")
    if args[:1] in (["wait"], ["rollout"]):
        output("ready")
    print("Unexpected kubectl call", args, file=sys.stderr)
    sys.exit(99)
command = " ".join(args[:2])
if command == "sts get-caller-identity":
    output("111111111111")
if command == "bedrock get-inference-profile":
    region = os.environ["AWS_REGION"]
    output({"inferenceProfileArn": f"arn:aws:bedrock:{region}:111111111111:inference-profile/synthetic",
            "models": [{"modelArn": f"arn:aws:bedrock:{region}::foundation-model/synthetic"}]})
if command == "eks describe-cluster":
    output({"cluster": {"endpoint": "https://synthetic-cluster.example", "computeConfig": {"enabled": True}}})
if command == "eks list-pod-identity-associations":
    output({"associations": [{"associationId": "synthetic-id"}] if state["association"] else []})
if command == "eks describe-pod-identity-association":
    if "--query" in args:
        output(state["role_arn"])
    output({"association": {"roleArn": state["role_arn"], "tags": {"ManagedBy": state["owner"]}}})
if command == "eks create-pod-identity-association":
    state["association"] = True
    output("synthetic-id")
if command == "eks delete-pod-identity-association":
    state["association"] = False
    output({})
if command == "ecr describe-repositories":
    name = option("--repository-names")
    if name not in state["repositories"]:
        error("RepositoryNotFoundException", "DescribeRepositories")
    output({"repositories": [{"repositoryArn": "arn:aws:ecr:us-west-2:111111111111:repository/" + name}]})
if command == "ecr create-repository":
    name = option("--repository-name")
    state["repositories"][name] = option("--tags").split("Value=", 1)[1]
    output({})
if command == "ecr list-tags-for-resource":
    name = option("--resource-arn").split(":repository/", 1)[1]
    output({"tags": [{"Key": "ManagedBy", "Value": state["repositories"][name]}]})
if command == "ecr describe-images":
    if option("--repository-name") not in state["images"]:
        error("ImageNotFoundException", "DescribeImages")
    if "--query" in args:
        output("sha256:" + "a" * 64)
    output({"imageDetails": [{"imageDigest": "sha256:" + "a" * 64}]})
if command == "ecr get-login-password":
    output("synthetic-registry-input")
if command == "ecr delete-repository":
    del state["repositories"][option("--repository-name")]
    output({})
if command == "s3api get-bucket-tagging":
    if not state["bucket"]:
        error("NoSuchBucket", "GetBucketTagging")
    if not state["bucket_tagged"]:
        error("NoSuchTagSet", "GetBucketTagging")
    output({"TagSet": [{"Key": "ManagedBy", "Value": state["owner"]}]})
if command == "s3api head-bucket":
    sys.exit(0 if state["bucket"] else 254)
if command == "s3api create-bucket":
    if scenario == "create-fails":
        error("AccessDenied", "CreateBucket")
    region = os.environ["AWS_REGION"]
    if region == "us-east-1" and "--create-bucket-configuration" in args:
        error("InvalidLocationConstraint", "CreateBucket")
    if region != "us-east-1" and ("--create-bucket-configuration" not in args or
            option("--create-bucket-configuration") != "LocationConstraint=" + region):
        error("IllegalLocationConstraintException", "CreateBucket")
    state["bucket"] = True
    output({})
if command == "s3api put-bucket-tagging":
    record = directory / "repository/tmp/strands-box/state.env"
    state["record_at_tagging"] = record.read_text()
    if scenario in ("tagging-fails", "rollback-fails"):
        error("AccessDenied", "PutBucketTagging")
    state["bucket_tagged"] = True
    state["owner"] = re.search(r"Value=([^}]+)", option("--tagging")).group(1)
    output({})
if command == "s3api delete-bucket":
    if scenario == "rollback-fails":
        error("AccessDenied", "DeleteBucket")
    state["bucket"] = False
    output({})
if command in ("s3api put-public-access-block", "s3api put-bucket-encryption", "s3api put-object", "s3 rm"):
    output({})
if command == "iam get-role":
    if not state["role"]:
        error("NoSuchEntity", "GetRole")
    output({"Role": {"Arn": state["role_arn"], "Tags": [{"Key": "ManagedBy", "Value": state["owner"]}]}})
if command == "iam create-role":
    state["role"] = True
    state["role_arn"] = "arn:aws:iam::111111111111:role/" + option("--role-name")
    output(state["role_arn"])
if command == "iam list-role-policies":
    output({"PolicyNames": ["analyst"]})
if command == "iam list-attached-role-policies":
    output({"AttachedPolicies": []})
if command in ("iam put-role-policy", "iam update-assume-role-policy", "iam delete-role-policy"):
    output({})
if command == "iam delete-role":
    state["role"] = False
    output({})
print("Unexpected AWS call", args, file=sys.stderr)
sys.exit(99)
"""


class SetupLifecycle(unittest.TestCase):
    def new_case(self, scenario, region="us-west-2"):
        scratch = ROOT / "tmp/strands-box-setup-checks"
        scratch.mkdir(parents=True, exist_ok=True)
        directory = Path(tempfile.mkdtemp(dir=scratch))
        section = directory / "repository/examples/subagent-security"
        section.mkdir(parents=True)
        selected = {"strands-box": ("scripts", "src", "policies", "deploy", "supplier", "Dockerfile", "versions.json"),
                    "analyst": ("scripts", "src", "fixtures", "deploy", "iam", "supplier-api", "requirements.txt")}
        for sample, names in selected.items():
            for name in names:
                source = SECTION / sample / name
                target = section / sample / name
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
                else:
                    shutil.copyfile(source, target)
        shutil.copyfile(SECTION / ".dockerignore", section / ".dockerignore")
        tools = directory / "stub-bin"
        tools.mkdir()
        program = tools / "stub.py"
        program.write_text(STUB)
        for name in ("aws", "kubectl", "docker"):
            command = tools / name
            command.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " +
                               shlex.quote(str(program)) + " " + name + ' "$@"\n')
            command.chmod(0o755)
        cloud = {"namespace_owner": None, "repositories": {}, "images": [],
                 "bucket": scenario == "existing-untagged", "bucket_tagged": False,
                 "role": False, "role_arn": None, "association": False, "owner": None}
        (directory / "cloud.json").write_text(json.dumps(cloud))
        environment = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
        for key in ("BUCKET", "ROLE_NAME", "KUBE_SERVER", "ACCOUNT_ID", "SAMPLE", "TMP_DIR", "STATE_FILE"):
            environment.pop(key, None)
        environment.update(PATH=str(tools) + os.pathsep + os.environ["PATH"], PYTHONDONTWRITEBYTECODE="1",
                           BOX_SETUP_CASE=str(directory), BOX_SETUP_SCENARIO=scenario, AWS_REGION=region,
                           CLUSTER_NAME="synthetic-cluster", KUBE_CONTEXT="synthetic-context",
                           NAMESPACE="synthetic-namespace", DEPLOYMENT_MODE="nitro")
        return directory, section / "strands-box", environment

    def invoke(self, case, script, *args):
        directory, sample, environment = case
        result = subprocess.run([BASH, str(sample / "scripts" / script), *args], cwd=sample,
                                env=environment, capture_output=True, text=True, timeout=90)
        (directory / (script + ".log")).write_text(result.stdout + result.stderr)
        return result

    @staticmethod
    def calls(case, service, operation):
        rows = [json.loads(line) for line in (case[0] / "commands.jsonl").read_text().splitlines()]
        return [row for row in rows if row[:3] == ["aws", service, operation]]

    @staticmethod
    def record(case):
        return case[0] / "repository/tmp/strands-box/state.env"

    @staticmethod
    def cloud(case):
        return json.loads((case[0] / "cloud.json").read_text())

    def test_setup_and_cleanup_ignore_bash_in_case_path(self):
        case = self.new_case("baseline")
        fake_bash = case[0] / "stub-bin/bash"
        fake_bash.write_text("#!/bin/sh\necho unexpected-case-bash >&2\nexit 97\n")
        fake_bash.chmod(0o755)
        setup = self.invoke(case, "setup.sh")
        self.assertEqual(setup.returncode, 0, setup.stdout + setup.stderr)
        self.assertIn("SETUP_COMPLETE=true", self.record(case).read_text())
        cleanup = self.invoke(case, "clean.sh", "--delete-aws")
        self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
        self.assertNotIn("unexpected-case-bash", setup.stderr + cleanup.stderr)
        self.assertFalse(self.record(case).exists())

    def test_setup_supports_bash_installed_under_a_path_with_spaces(self):
        scratch = ROOT / "tmp/strands-box-setup-checks"
        scratch.mkdir(parents=True, exist_ok=True)
        directory = Path(tempfile.mkdtemp(dir=scratch)) / "operator tools"
        directory.mkdir()
        interpreter = directory / "bash"
        shutil.copy2(BASH, interpreter)
        with patch(__name__ + ".BASH", str(interpreter)):
            case = self.new_case("baseline")
            setup = self.invoke(case, "setup.sh")
            self.assertEqual(setup.returncode, 0, setup.stdout + setup.stderr)
            cleanup = self.invoke(case, "clean.sh", "--delete-aws")
            self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
            self.assertFalse(self.record(case).exists())

    def test_full_setup_and_cleanup_handle_both_bucket_region_forms(self):
        for region in ("us-east-1", "us-west-2"):
            with self.subTest(region=region):
                case = self.new_case("baseline", region)
                setup = self.invoke(case, "setup.sh")
                self.assertEqual(setup.returncode, 0, setup.stdout + setup.stderr)
                self.assertIn("SETUP_COMPLETE=true", self.record(case).read_text())
                self.assertIn("BUCKET_CREATED=true", self.cloud(case)["record_at_tagging"])
                calls = self.calls(case, "s3api", "create-bucket")
                self.assertEqual(len(calls), 1)
                if region == "us-east-1":
                    self.assertNotIn("--create-bucket-configuration", calls[0])
                else:
                    self.assertIn("LocationConstraint=" + region, calls[0])
                cleanup = self.invoke(case, "clean.sh", "--delete-aws")
                self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
                remaining = self.cloud(case)
                self.assertFalse(any(remaining[key] for key in ("namespace_owner", "repositories", "bucket", "role", "association")))
                self.assertFalse(self.record(case).exists())

    def test_tagging_failure_records_creation_and_rolls_back_only_empty_bucket(self):
        for scenario, expected_status in (("tagging-fails", "deleted"), ("rollback-fails", "failed")):
            with self.subTest(scenario=scenario):
                case = self.new_case(scenario)
                setup = self.invoke(case, "setup.sh")
                self.assertNotEqual(setup.returncode, 0)
                self.assertIn("creation receipt", setup.stderr)
                self.assertIn("BUCKET_CREATED=true", self.cloud(case)["record_at_tagging"])
                record = self.record(case).read_text()
                self.assertIn("BUCKET_CREATED=true", record)
                self.assertIn("BUCKET_TAGGED=false", record)
                self.assertIn("BUCKET_ROLLBACK_STATUS=" + expected_status, record)
                self.assertEqual(len(self.calls(case, "s3api", "delete-bucket")), 1)
                self.assertEqual(self.calls(case, "s3", "rm"), [])
                self.assertEqual(self.cloud(case)["bucket"], scenario == "rollback-fails")
                cleanup = self.invoke(case, "clean.sh", "--delete-aws")
                if scenario == "rollback-fails":
                    self.assertNotEqual(cleanup.returncode, 0)
                    self.assertTrue(self.record(case).exists())
                    self.assertIn("BUCKET_CREATED=true", self.record(case).read_text())
                    self.assertEqual(len(self.calls(case, "s3api", "delete-bucket")), 1)
                    self.assertEqual(self.calls(case, "s3", "rm"), [])
                else:
                    self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)

    def test_failed_creation_never_claims_creation_or_attempts_rollback(self):
        case = self.new_case("create-fails")
        setup = self.invoke(case, "setup.sh")
        self.assertNotEqual(setup.returncode, 0)
        self.assertNotIn("BUCKET_CREATED=true", self.record(case).read_text())
        self.assertEqual(self.calls(case, "s3api", "put-bucket-tagging"), [])
        self.assertEqual(self.calls(case, "s3api", "delete-bucket"), [])
        self.assertFalse(self.cloud(case)["bucket"])

    def test_existing_untagged_bucket_is_never_adopted_emptied_or_deleted(self):
        case = self.new_case("existing-untagged")
        setup = self.invoke(case, "setup.sh")
        self.assertNotEqual(setup.returncode, 0)
        self.assertEqual(self.calls(case, "s3api", "create-bucket"), [])
        self.assertEqual(self.calls(case, "s3api", "put-bucket-tagging"), [])
        cleanup = self.invoke(case, "clean.sh", "--delete-aws")
        self.assertNotEqual(cleanup.returncode, 0)
        self.assertTrue(self.cloud(case)["bucket"])
        self.assertTrue(self.record(case).exists())
        self.assertEqual(self.calls(case, "s3", "rm"), [])
        self.assertEqual(self.calls(case, "s3api", "delete-bucket"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
