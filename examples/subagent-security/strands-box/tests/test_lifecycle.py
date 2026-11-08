#!/usr/bin/env python3
"""Check Box setup and cleanup locally with isolated command stubs; no AWS calls."""
import copy
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
# Select the operator-installed interpreter before individual cases replace PATH.
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("Bash is required to run the Strands Box lifecycle tests")
BASH = str(Path(BASH).resolve(strict=True))
SAMPLE = ROOT / "examples/subagent-security/strands-box"
COMMON = SAMPLE / "scripts/common.sh"
IMAGE = SAMPLE / "scripts/image.sh"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VERIFY = load("box_verify_pod", SAMPLE / "scripts/verify_pod.py")


class Lifecycle(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / "tmp/strands-box-lifecycle-checks"
        scratch.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(dir=scratch))

    def shell(self, body, *, image=False, extra=None):
        # Source the real functions, then replace every external cloud/container tool.
        program = 'set -euo pipefail\nsource "$1"\n'
        if image:
            program += 'source "$2"\n'
        program += 'aws() { echo "Unexpected AWS call" >&2; return 99; }\n'
        program += 'kubectl() { echo "Unexpected Kubernetes call" >&2; return 99; }\n'
        program += 'docker() { echo "Unexpected Docker call" >&2; return 99; }\n'
        program += body
        env = dict(os.environ, CHECK_DIR=str(self.directory), PYTHONDONTWRITEBYTECODE="1")
        if extra:
            env.update(extra)
        return subprocess.run([BASH, "-c", program, "check", str(COMMON), str(IMAGE)],
                              text=True, capture_output=True, env=env, cwd=ROOT)

    def test_shell_ignores_bash_in_case_path(self):
        fake_bash = self.directory / "bash"
        fake_bash.write_text("#!/bin/sh\necho unexpected-case-bash >&2\nexit 97\n")
        fake_bash.chmod(0o755)
        result = self.shell("printf selected-interpreter", extra={
            "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
        })
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "selected-interpreter")
        self.assertNotIn("unexpected-case-bash", result.stderr)

    def test_auto_mode_does_not_require_a_daemonset(self):
        result = self.shell("box_cluster_prerequisites '{}'".format(
            json.dumps({"cluster": {"computeConfig": {"enabled": True}}})))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ready_agent_is_reused(self):
        reply = json.dumps({"status": {"desiredNumberScheduled": 2, "numberReady": 2}})
        result = self.shell("kc() { echo \"$REPLY\"; }\nbox_cluster_prerequisites '{\"cluster\":{}}'",
                            extra={"REPLY": reply})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_failed_or_unready_agent_is_refused(self):
        for reply in ("failure", "", json.dumps({"status": {"desiredNumberScheduled": 2, "numberReady": 1}}),
                      json.dumps({"status": {"desiredNumberScheduled": 0, "numberReady": 0}})):
            with self.subTest(reply=reply):
                stub = 'return 1' if reply == "failure" else 'echo "$REPLY"'
                result = self.shell("kc() { " + stub + "; }\nbox_cluster_prerequisites '{\"cluster\":{}}'",
                                    extra={"REPLY": reply})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Pod Identity", result.stderr)

    def test_docker_readiness_checks_have_both_outcomes(self):
        for failed in ("none", "buildx", "info", "arm64"):
            with self.subTest(failed=failed):
                platform = "linux/amd64" if failed == "arm64" else "linux/arm64"
                body = ('TMP_DIR="$CHECK_DIR"\n'
                        'docker() { [[ "$1" != "' + failed + '" ]] || return 1\n'
                        '  [[ " $* " != *" inspect "* ]] || echo "Platforms: ' + platform + '"; }\n'
                        'box_require_tools')
                result = self.shell(body)
                if failed == "none":
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Docker", result.stderr)

    def test_namespace_lookup_does_not_adopt_foreign_or_failed_reads(self):
        cases = [("", True, "absent"),
                 ('{"metadata":{"labels":{"app.kubernetes.io/managed-by":"strands-box"}}}', True, "owned"),
                 ('{"metadata":{"labels":{"app.kubernetes.io/managed-by":"other"}}}', False, None),
                 ("failure", False, None)]
        for value, accepted, expected in cases:
            with self.subTest(value=value):
                stub = 'return 1' if value == "failure" else 'echo "$REPLY"'
                result = self.shell(f'NAMESPACE=check\nkc() {{ {stub}; }}\nbox_namespace_state',
                                    extra={"REPLY": value})
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if expected:
                    self.assertEqual(result.stdout.strip(), expected)

    def test_setup_and_cleanup_require_exact_absence_errors(self):
        clean = (SAMPLE / "scripts/clean.sh").read_text()
        cleanup_lookup = clean[clean.index("box_cleanup_lookup() {"):clean.index("confirm_absent() {")]
        exact = "An error occurred (NoSuchBucket) when calling the GetBucketTagging operation: absent"
        cases = [("", exact, 1), ("", "\naws: [ERROR]: " + exact + "\n", 1),
                 ("", "aws: [ERROR]: AccessDenied\n" + exact, 2),
                 ("", "WARNING: " + exact, 2),
                 ("", exact.replace("GetBucketTagging", "DeleteBucket"), 2),
                 ("partial", exact, 2), ("", "AccessDenied", 2)]
        for function in ("lookup", "box_cleanup_lookup"):
            for stdout, stderr, expected in cases:
                with self.subTest(function=function, stdout=stdout, stderr=stderr):
                    body = cleanup_lookup if function == "box_cleanup_lookup" else ""
                    body += 'TMP_DIR="$CHECK_DIR"; mkdir -p "$TMP_DIR/lookups"\n'
                    body += 'aws() { printf "%s" "$STDOUT"; printf "%s" "$STDERR" >&2; return 254; }\n'
                    body += f'rc=0; {function} NoSuchBucket s3api get-bucket-tagging --bucket example || rc=$?\n'
                    body += 'printf "STATUS=%s\\n" "$rc"\n'
                    result = self.shell(body, extra={"STDOUT": stdout, "STDERR": stderr})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"STATUS={expected}", result.stdout)
            body = cleanup_lookup if function == "box_cleanup_lookup" else ""
            body += 'TMP_DIR="$CHECK_DIR"; mkdir -p "$TMP_DIR/lookups"\n'
            body += 'aws() { printf "{}"; }\n'
            body += f'{function} NoSuchBucket s3api get-bucket-tagging --bucket example\n'
            result = self.shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "{}")

    def test_saved_target_account_and_context_are_required(self):
        body = 'KUBE_CONTEXT=check; KUBE_SERVER=https://cluster.example; ACCOUNT_ID=123456789012\n'
        body += 'kc() { echo "$SERVER"; }; aws() { echo "$ACCOUNT"; }\nbox_check_target'
        for server, account, accepted in (("https://cluster.example", "123456789012", True),
                                          ("https://different.example", "123456789012", False),
                                          ("https://cluster.example", "999999999999", False)):
            with self.subTest(server=server, account=account):
                result = self.shell(body, extra={"SERVER": server, "ACCOUNT": account})
                self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_image_hash_tracks_source_and_dockerignore_but_not_bytecode(self):
        section = self.directory / "section"
        (section / "src/__pycache__").mkdir(parents=True)
        (section / ".dockerignore").write_text("**/__pycache__/\n**/*.pyc\n")
        (section / "src/main.py").write_text("print(1)\n")
        body = 'SECTION_DIR="$CHECK_DIR/section"\nbox_image_tag linux/arm64 src'
        before = self.shell(body, image=True)
        self.assertEqual(before.returncode, 0, before.stderr)
        (section / "src/__pycache__/main.pyc").write_bytes(b"compiled output")
        (section / "src/other.pyc").write_bytes(b"compiled output")
        self.assertEqual(self.shell(body, image=True).stdout, before.stdout)
        (section / "src/main.py").write_text("print(2)\n")
        source = self.shell(body, image=True).stdout
        self.assertNotEqual(source, before.stdout)
        (section / ".dockerignore").write_text("**/__pycache__/\n**/*.pyc\nextra-pattern\n")
        self.assertNotEqual(self.shell(body, image=True).stdout, source)

    def test_existing_image_uses_a_verified_digest(self):
        digest = "sha256:" + "a" * 64
        body = r'''ACCOUNT_ID=123456789012; AWS_REGION=us-west-2; TMP_DIR="$CHECK_DIR"
lookup() { case "$1" in RepositoryNotFoundException) printf '%s\n' '{"repositories":[{"repositoryArn":"example"}]}' ;; ImageNotFoundException) printf '{}' ;; *) return 99 ;; esac; }
aws() { case "$1 $2" in "ecr list-tags-for-resource") printf '%s\n' '{"tags":[{"Key":"ManagedBy","Value":"strands-box"}]}' ;; "ecr describe-images") printf '%s\n' "$DIGEST" ;; *) return 99 ;; esac; }
box_build_image example linux/arm64 unused input-tag
printf 'RESULT=%s\n' "$ANALYST_IMAGE"
'''
        for value, accepted in ((digest, True), ("None", False), ("sha256:short", False)):
            with self.subTest(digest=value):
                result = self.shell(body, image=True, extra={"DIGEST": value})
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if accepted:
                    self.assertIn("RESULT=123456789012.dkr.ecr.us-west-2.amazonaws.com/example@" + digest,
                                  result.stdout)

    def test_image_reuse_requires_repository_ownership(self):
        body = r'''ACCOUNT_ID=123456789012; AWS_REGION=us-west-2; TMP_DIR="$CHECK_DIR"
lookup() { printf '%s\n' '{"repositories":[{"repositoryArn":"example"}]}'; }
aws() { printf '%s\n' '{"tags":[{"Key":"ManagedBy","Value":"other"}]}'; }
box_build_image example linux/arm64 unused input-tag
'''
        result = self.shell(body, image=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not this sample", result.stderr)


class SupplierManifest(unittest.TestCase):
    def test_http_fixture_and_namespace_rendering(self):
        render = load("box_supplier_render", SAMPLE / "scripts/render_supplier.py").render
        template = (SAMPLE / "deploy/supplier-api.yaml").read_text()
        for mode in ("nitro", "eks"):
            with self.subTest(mode=mode):
                rendered = render(template, mode, "example@sha256:" + "a" * 64, "custom-case", "strands-box-" + "a" * 20)
                self.assertEqual(rendered.count("namespace: custom-case"), 3)
                self.assertEqual(rendered.count("type: ClusterIP"), 2)
                self.assertEqual(rendered.count("port: 8080, targetPort: 8080"), 2)
                self.assertIn("kubernetes.io/arch: arm64", rendered)
                self.assertNotIn("<", rendered)
                self.assertNotIn("secret:", rendered)
                self.assertNotIn("runtimeClassName", rendered)
        for mode, image, namespace in (("invalid", "example:tag", "custom-case"),
                                        ("nitro", "bad image", "custom-case"),
                                        ("nitro", "example:tag", "bad/namespace")):
            with self.subTest(mode=mode, image=image, namespace=namespace), self.assertRaises(ValueError):
                render(template, mode, image, namespace, "strands-box-" + "a" * 20)


class PodProfile(unittest.TestCase):
    def test_nitro_init_uses_readonly_root(self):
        template = (SAMPLE / "deploy/analyst-pod.yaml").read_text()
        init = template.split("  initContainers:\n", 1)[1].split("  containers:\n", 1)[0]
        self.assertIn("        readOnlyRootFilesystem: true\n", init)
        # Use an observed-object-shaped fixture, then mutate the required property.
        expected = {"AWS_REGION": "us-west-2", "AWS_DEFAULT_REGION": "us-west-2",
                    "ANALYST_BUCKET": "example", "ANALYST_ROLE_NAME": "example",
                    "BEDROCK_MODEL_ID": "example", "EXPERIMENTAL_LINUX_SUPPORT": "TRUE",
                    "SUPPLIER_API_URL": "http://supplier-api.example.svc.cluster.local:8080",
                    "SUPPLIER_ALIAS_URL": "http://supplier-api-alias.example.svc.cluster.local:8080"}
        pod = {"metadata": {"name": "analyst", "namespace": "example"}, "spec": {
            "runtimeClassName": "isolated-sandbox", "nodeSelector": {"kubernetes.io/arch": "arm64"},
            "nodeName": "example", "serviceAccountName": "analyst", "automountServiceAccountToken": False,
            "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
            "containers": [{"name": "analyst", "image": "example@sha256:" + "a" * 64,
                            "env": [{"name": key, "value": value} for key, value in expected.items()],
                            "securityContext": {"runAsNonRoot": True, "privileged": True,
                                                "readOnlyRootFilesystem": True}}],
            "initContainers": [{"name": "prepare-guest-user-namespaces", "image": "example@sha256:" + "a" * 64,
                                "command": ["sh", "-c", "printf '1024\n' > /proc/sys/user/max_user_namespaces"],
                                "securityContext": {"privileged": True, "runAsUser": 0,
                                                    "runAsNonRoot": False, "readOnlyRootFilesystem": True}}]}}
        kwargs = dict(mode="nitro", image="example@sha256:" + "a" * 64, namespace="example", region="us-west-2",
                      bucket="example", role="example", model="example")
        self.assertEqual(VERIFY.verify(pod, **kwargs)["runtime_class"], "isolated-sandbox")
        for mutation in ("credential_environment", "secret_volume"):
            mutated = copy.deepcopy(pod)
            if mutation == "credential_environment":
                mutated["spec"]["containers"][0]["env"].append({"name": "SUPPLIER_API_KEY", "value": "fixture"})
            else:
                mutated["spec"]["volumes"] = [{"name": "unexpected", "secret": {"secretName": "fixture"}}]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                VERIFY.verify(mutated, **kwargs)
        for value in (False, None):
            mutated = copy.deepcopy(pod)
            if value is None:
                del mutated["spec"]["initContainers"][0]["securityContext"]["readOnlyRootFilesystem"]
            else:
                mutated["spec"]["initContainers"][0]["securityContext"]["readOnlyRootFilesystem"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                VERIFY.verify(mutated, **kwargs)


class ResourceOwnership(unittest.TestCase):
    setUp = Lifecycle.setUp
    shell = Lifecycle.shell
    TARGET = {"ACCOUNT_ID": "111111111111", "AWS_REGION": "us-west-2",
              "KUBE_SERVER": "https://cluster-a.example", "NAMESPACE": "namespace-a",
              "CLUSTER_NAME": "cluster-a", "KUBE_CONTEXT": "context-a"}

    def owner(self, **changes):
        result = self.shell("box_resource_owner", extra={**self.TARGET, **changes})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def write_state(self, **changes):
        owner = self.owner()
        state = {**self.TARGET, "SAMPLE": owner, "DEPLOYMENT_MODE": "nitro",
                 "BUCKET": "custom-bucket-a", "ROLE_NAME": "custom-role-a",
                 "ANALYST_REPOSITORY": "pod-isolation/subagent-analyst-" + owner,
                 "SUPPLIER_API_REPOSITORY": "pod-isolation/subagent-analyst-" + owner + "-supplier-api",
                 **changes}
        # All fixture values are fixed strings without shell metacharacters or whitespace.
        (self.directory / "state.env").write_text("\n".join(f"{key}={value}" for key, value in state.items()) + "\n")
        return state

    def test_builder_must_offer_linux_arm64(self):
        cases = [("Platforms: linux/arm64", True),
                 ("Platforms: linux/amd64, linux/amd64/v2, linux/arm64, linux/riscv64", True),
                 ("Platforms: linux/amd64, linux/arm64/v8", True),
                 ("Platforms: linux/amd64, linux/amd64/v2, linux/386", False),
                 ("Platforms: linux/arm64x, linux/arm/v7", False),
                 ("Driver: docker", False),
                 ("failure", False)]
        for reply, accepted in cases:
            with self.subTest(reply=reply):
                stub = 'return 1' if reply == "failure" else 'printf "Name: default\\n%s\\n" "$REPLY"'
                body = ('TMP_DIR="$CHECK_DIR"\n'
                        'docker() { [[ "$1 $3 $4" == "--config buildx inspect" ]] || return 98; '
                        + stub + '; }\nbox_require_arm64_builder')
                result = self.shell(body, extra={"REPLY": reply})
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if not accepted:
                    self.assertIn("cannot build linux/arm64", result.stderr)
                    self.assertIn("docs.docker.com/build/building/multi-platform", result.stderr)

    def test_env_settings_reach_run_and_cleanup_but_not_the_target(self):
        sample = self.directory / "sample"
        sample.mkdir()
        settings = {"AWS_PROFILE": "chosen-in-env", "NAMESPACE": "from-env",
                    "CLUSTER_NAME": "from-env", "DEPLOYMENT_MODE": "nitro"}
        (sample / ".env").write_text("".join(f"{key}={value}\n" for key, value in settings.items()))
        self.write_state()
        body = ('SAMPLE_DIR="$CHECK_DIR/sample"; STATE_FILE="$CHECK_DIR/state.env"; TMP_DIR="$CHECK_DIR"\n'
                'box_load_env; box_load_state\n'
                'printf "%s|%s|%s\\n" "${AWS_PROFILE:-}" "$NAMESPACE" "$CLUSTER_NAME"')
        result = self.shell(body, extra={"AWS_PROFILE": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "chosen-in-env|namespace-a|cluster-a")
        # Without a .env, nothing is added and the record still loads.
        (sample / ".env").unlink()
        result = self.shell(body, extra={"AWS_PROFILE": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "|namespace-a|cluster-a")
        # A .env that names another mode is refused, not silently overridden.
        (sample / ".env").write_text("DEPLOYMENT_MODE=eks\n")
        result = self.shell(body)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEPLOYMENT_MODE differs", result.stderr)
        for script in ("run.sh", "clean.sh"):
            with self.subTest(script=script):
                text = (SAMPLE / "scripts" / script).read_text()
                self.assertIn("box_load_env\nbox_load_state\n", text)

    def test_owner_is_stable_and_changes_for_every_resource_scope(self):
        owner = self.owner()
        self.assertRegex(owner, r"^strands-box-[a-f0-9]{20}$")
        self.assertEqual(owner, self.owner())
        variants = ({"ACCOUNT_ID": "222222222222"}, {"AWS_REGION": "us-east-2"},
                    {"KUBE_SERVER": "https://cluster-b.example"}, {"NAMESPACE": "namespace-b"})
        changed = [self.owner(**variant) for variant in variants]
        self.assertEqual(len(set([owner, *changed])), 5)
        self.assertEqual(owner, self.owner(KUBE_CONTEXT="another-alias"))
        for key in ("ACCOUNT_ID", "AWS_REGION", "KUBE_SERVER", "NAMESPACE"):
            with self.subTest(missing=key):
                result = self.shell("box_resource_owner", extra={**self.TARGET, key: ""})
                self.assertNotEqual(result.returncode, 0)
        result = self.shell('SAMPLE="$(box_resource_owner)"; printf "%s\\n%s\\n" "$TMP_DIR" "$STATE_FILE"',
                            extra=self.TARGET)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(ROOT / "tmp/strands-box"),
                                                      str(ROOT / "tmp/strands-box/state.env")])

    def test_default_resource_names_are_scoped_and_fit_service_limits(self):
        setup = (SAMPLE / "scripts/setup.sh").read_text()
        assignments = "\n".join(line for line in setup.splitlines() if line.startswith(
            ("BUCKET=", "ROLE_NAME=", "ANALYST_REPOSITORY=", "SUPPLIER_API_REPOSITORY=")))
        results = []
        for namespace in ("namespace-a", "namespace-b"):
            body = ('unset BUCKET ROLE_NAME\nSAMPLE="$(box_resource_owner)"\n' + assignments +
                    '\nprintf "%s\\n" "$BUCKET" "$ROLE_NAME" "$ANALYST_REPOSITORY" "$SUPPLIER_API_REPOSITORY"')
            result = self.shell(body, extra={**self.TARGET, "NAMESPACE": namespace})
            self.assertEqual(result.returncode, 0, result.stderr)
            names = result.stdout.splitlines()
            self.assertEqual(len(names), 4)
            self.assertLessEqual(len(names[0]), 63)
            self.assertLessEqual(len(names[1]), 64)
            self.assertRegex(names[0], r"^[a-z0-9][a-z0-9-]+[a-z0-9]$")
            self.assertTrue(all(len(name) <= 256 for name in names[2:]))
            results.append(names)
        self.assertTrue(all(a != b for a, b in zip(*results)))

    def test_matching_saved_owner_loads(self):
        state = self.write_state()
        body = ('STATE_FILE="$CHECK_DIR/state.env"; TMP_DIR="$CHECK_DIR"\n'
                'box_load_state\nprintf "%s\\n" "$SAMPLE" "$ANALYST_REPOSITORY"')
        result = self.shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [state["SAMPLE"], state["ANALYST_REPOSITORY"]])

    def test_mismatched_state_refuses_cleanup_before_any_cloud_call(self):
        clean = (SAMPLE / "scripts/clean.sh").read_text()
        source_line = 'source "$(dirname "$0")/common.sh"\n'
        self.assertEqual(clean.count(source_line), 1)
        # The harness has already sourced the real common.sh; execute the full cleanup body.
        clean = clean.replace(source_line, "", 1)
        variants = ({"SAMPLE": "strands-box"}, {"SAMPLE": "strands-box-" + "f" * 20},
                    {"NAMESPACE": "namespace-b"}, {"KUBE_SERVER": "https://cluster-b.example"},
                    {"ACCOUNT_ID": "222222222222"}, {"AWS_REGION": "us-east-2"},
                    {"ANALYST_REPOSITORY": "pod-isolation/another-deployment"},
                    {"SUPPLIER_API_REPOSITORY": "pod-isolation/another-supplier"})
        body = ('STATE_FILE="$CHECK_DIR/state.env"; TMP_DIR="$CHECK_DIR"\n'
                'aws() { printf "aws %s\\n" "$*" >> "$CHECK_DIR/cloud-calls"; return 99; }\n'
                'kc() { printf "kubectl %s\\n" "$*" >> "$CHECK_DIR/cloud-calls"; return 99; }\n'
                'set -- --delete-aws\n' + clean)
        for variant in variants:
            with self.subTest(variant=variant):
                self.write_state(**variant)
                result = self.shell(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("match this deployment target", result.stderr)
                self.assertFalse((self.directory / "cloud-calls").exists())

    def test_custom_bucket_and_role_reuse_requires_this_deployment_owner(self):
        owner = self.owner()
        stub = r"""
TMP_DIR="$CHECK_DIR"; STATE_FILE="$CHECK_DIR/state.env"; mkdir -p "$TMP_DIR/lookups"
SAMPLE="$(box_resource_owner)"
BUCKET=custom-bucket; ROLE_NAME=custom-role
MODEL_RESOURCES='["arn:aws:bedrock:us-west-2:111111111111:inference-profile/example"]'
: > "$CHECK_DIR/resource-calls"
aws() {
  printf '%s\n' "$*" >> "$CHECK_DIR/resource-calls"
  case "$1 $2" in
    's3api get-bucket-tagging') printf '{"TagSet":[{"Key":"ManagedBy","Value":"%s"}]}\n' "$OWNER_TAG" ;;
    'iam get-role') printf '{"Role":{"Arn":"arn:aws:iam::111111111111:role/custom-role","Tags":[{"Key":"ManagedBy","Value":"%s"}]}}\n' "$OWNER_TAG" ;;
    'iam list-role-policies') printf '{"PolicyNames":[]}\n' ;;
    'iam list-attached-role-policies') printf '{"AttachedPolicies":[]}\n' ;;
    'eks list-pod-identity-associations') printf '{"associations":[]}\n' ;;
    'eks create-pod-identity-association') printf 'association-example\n' ;;
    's3api put-public-access-block'|'s3api put-bucket-encryption'|'s3api put-object'|'iam update-assume-role-policy'|'iam put-role-policy') return 0 ;;
    *) printf 'Unexpected command refused\n' >&2; return 99 ;;
  esac
}
"""
        for function in ("box_bucket", "analyst_role"):
            for tag in (owner, "strands-box", "strands-box-" + "f" * 20):
                with self.subTest(function=function, owner=tag):
                    result = self.shell(stub + "\n" + function, extra={**self.TARGET, "OWNER_TAG": tag})
                    calls = (self.directory / "resource-calls").read_text().splitlines()
                    mutations = [call for call in calls if call.split()[1].startswith(("put-", "update-", "create-"))]
                    if tag == owner:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertTrue(mutations)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("not this sample", result.stderr)
                        self.assertEqual(mutations, [])

    def test_supplier_labels_require_and_receive_the_scoped_owner(self):
        render = load("box_supplier_owner", SAMPLE / "scripts/render_supplier.py").render
        template = (SAMPLE / "deploy/supplier-api.yaml").read_text()
        for invalid in ("strands-box", "", "other-" + "a" * 20, "strands-box-" + "A" * 20):
            with self.subTest(owner=invalid), self.assertRaises(ValueError):
                render(template, "nitro", "example:tag", "namespace-a", invalid)
        body = ('SAMPLE="$(box_resource_owner)"\nDEPLOYMENT_MODE=nitro\n'
                'ANALYST_IMAGE=example:tag\nbox_render_supplier "$CHECK_DIR/supplier.yaml"')
        result = self.shell(body, image=True, extra=self.TARGET)
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = (self.directory / "supplier.yaml").read_text()
        self.assertEqual(rendered.count("app.kubernetes.io/managed-by: " + self.owner()), 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
