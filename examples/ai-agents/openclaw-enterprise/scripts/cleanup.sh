#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

command -v python3 >/dev/null 2>&1 || {
  printf 'cleanup: python3 is required.\n' >&2
  exit 1
}

exec python3 -I - "$@" <<'PY'
import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from pathlib import Path

OWNER_KEY = "app.kubernetes.io/managed-by"
OWNER = "openclaw-enterprise-blueprint"
OCE_OWNER = "openclaw-enterprise"
SOURCE_PIN = "86c8c12310f691bb21651118ffffd6bfd460e9ff"
AGW_NAMESPACE = "openclaw-enterprise-agw"
AGW_SERVICE_ACCOUNT = "agentgateway"
STORAGE_CLASS = "openclaw-enterprise-gp3"
FREEZE_PREFIX = "openclaw-enterprise-cleanup-freeze-"
FREEZE_KEY = "cleanup.openclaw.aws/"
INVOCATION_TAG = "OpenClawSetupInvocation"
AWS_ABSENT = ("NoSuchEntity", "ResourceNotFoundException")


class CleanupError(Exception):
    pass


def fail(message):
    raise CleanupError(message)


def parse_args():
    parser = argparse.ArgumentParser()
    for flag in ("kubeconfig", "kube-context", "state-dir", "receipt"):
        parser.add_argument(f"--{flag}", required=True)
    parser.add_argument("--namespace", default="openclaw-system")
    parser.add_argument("--release", default="oce")
    parser.add_argument("--tenant-namespace", action="append", default=[])
    for flag in (
        "storage-class-receipt", "agentgateway-pod-identity-receipt",
        "aws-region", "aws-account-id", "eks-cluster-name",
        "pod-identity-association-id", "iam-role-name", "iam-inline-policy-name",
    ):
        parser.add_argument(f"--{flag}")
    args = parser.parse_args()
    for name in ("kubeconfig", "state_dir", "receipt"):
        if not Path(getattr(args, name)).is_absolute():
            fail(f"--{name.replace('_', '-')} must be an absolute path.")
    dns = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?")
    names = [args.namespace, args.release, *args.tenant_namespace]
    if any(len(name) > 63 or not dns.fullmatch(name) for name in names):
        fail("namespace and release names must be Kubernetes DNS labels.")
    if len(set(args.tenant_namespace)) != len(args.tenant_namespace):
        fail("a tenant namespace was supplied more than once.")
    reserved = {args.namespace, "openclaw-enterprise-adapter", AGW_NAMESPACE}
    if reserved & set(args.tenant_namespace):
        fail("a reserved namespace was supplied as a tenant namespace.")
    aws_fields = (
        "aws_region", "aws_account_id", "eks_cluster_name",
        "pod_identity_association_id", "iam_role_name", "iam_inline_policy_name",
    )
    aws_values = [getattr(args, name) for name in aws_fields]
    if any(aws_values) and not all(aws_values):
        fail("AgentGateway cleanup requires every AWS identifier.")
    if bool(args.agentgateway_pod_identity_receipt) != all(aws_values):
        fail("AgentGateway cleanup requires its lifecycle receipt and every AWS identifier.")
    if args.aws_account_id and not re.fullmatch(r"\d{12}", args.aws_account_id):
        fail("--aws-account-id must be a 12-digit AWS account ID.")
    if args.pod_identity_association_id and not re.fullmatch(
            r"a-[a-z0-9]{17}", args.pod_identity_association_id):
        fail("--pod-identity-association-id is not valid.")
    return args


def private_path(path, label, directory=False):
    try:
        info = Path(path).lstat()
    except OSError:
        fail(f"{label} does not exist.")
    wanted = stat.S_ISDIR if directory else stat.S_ISREG
    mode = stat.S_IMODE(info.st_mode)
    if not wanted(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        kind = "directory" if directory else "regular file"
        fail(f"{label} must be an owned {kind}, not a symbolic link.")
    if mode not in ({0o700} if directory else {0o400, 0o600}):
        fail(f"{label} must have mode {'0700' if directory else '0400 or 0600'}.")
    return Path(path)


def load_json(path, label):
    path = private_path(path, label)
    try:
        return json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid: {error}.")


def run(command, *, stdin=None, absent=()):
    try:
        result = subprocess.run(
            command, input=stdin, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        fail(f"{command[0]} is required.")
    if result.returncode:
        if absent and any(marker in result.stderr for marker in absent):
            return None
        detail = result.stderr.strip() or result.stdout.strip() or "command failed"
        fail(f"{command[0]} failed: {detail}")
    return result.stdout


def digest(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def has_fields(value, expected):
    return isinstance(value, dict) and all(value.get(key) == item for key, item in expected.items())


class Cleanup:
    def __init__(self, args):
        self.a = args
        self.k = ["kubectl", "--kubeconfig", args.kubeconfig, "--context",
                  args.kube_context, "--request-timeout=20s"]
        self.h = ["helm", "--kubeconfig", args.kubeconfig, "--kube-context", args.kube_context]
        self.freeze_path = Path(args.state_dir) / "cleanup-freeze.json"
        self.freeze_started = False
        self.endpoint = self.attempt = self.cluster_arn = ""
        self.install_uids = {}
        self.storage = self.pod = None

    def kubectl(self, *args, stdin=None):
        return run([*self.k, *args], stdin=stdin)

    def get(self, resource, namespace=None):
        command = ["get", resource]
        if namespace:
            command += ["--namespace", namespace]
        output = self.kubectl(*command, "--ignore-not-found", "--output=json")
        return json.loads(output) if output.strip() else None

    def aws(self, *args, absent=()):
        return run(["aws", *args, "--region", self.a.aws_region, "--output", "json"],
                   absent=absent)

    def aws_json(self, *args, absent=()):
        output = self.aws(*args, absent=absent)
        return None if output is None else json.loads(output)

    def validate_paths(self):
        private_path(self.a.kubeconfig, "--kubeconfig")
        state = private_path(self.a.state_dir, "--state-dir", True).resolve()
        receipt = private_path(self.a.receipt, "--receipt", True).resolve()
        if state != Path(self.a.state_dir) or receipt != Path(self.a.receipt):
            fail("--state-dir and --receipt must be canonical.")
        if receipt.parent != state:
            fail("--receipt must be directly below --state-dir.")

    def validate_install_receipt(self):
        marker = {}
        marker_path = private_path(
            Path(self.a.state_dir) / "install.complete", "install completion marker"
        )
        for line in marker_path.read_text().splitlines():
            key, separator, value = line.partition("=")
            if not separator or key in marker:
                fail("install completion marker is malformed.")
            marker[key] = value
        if set(marker) != {"source", "cluster_arn", "context", "namespace", "release"}:
            fail("install completion marker has an unexpected schema.")
        expected = {
            "source": SOURCE_PIN, "context": self.a.kube_context,
            "namespace": self.a.namespace, "release": self.a.release,
        }
        for key, value in expected.items():
            if marker[key] != value:
                fail(f"completion marker {key} does not match.")

        config = json.loads(self.kubectl(
            "config", "view", "--minify", "--flatten", "--output=json"
        ))
        cluster = config.get("clusters", [{}])[0].get("cluster")
        if config.get("current-context") != self.a.kube_context or not isinstance(cluster, dict):
            fail("selected kube context does not match --kube-context.")
        self.endpoint = cluster.get("server", "")
        if not self.endpoint:
            fail("selected kube context has no cluster endpoint.")
        self.kubectl("get", "--raw=/readyz")

        receipt = Path(self.a.receipt)
        intent = load_json(receipt / "intent.json", "receipt/intent.json")
        dispatch = load_json(receipt / "dispatch.json", "receipt/dispatch.json")
        result = load_json(receipt / "helm-result.json", "receipt/helm-result.json")
        resources = load_json(receipt / "resources.json", "receipt/resources.json")
        valid_intent = (
            intent.get("version") == 1 and intent.get("operation") == "helm-install"
            and intent.get("namespace") == self.a.namespace
            and intent.get("release") == self.a.release
            and isinstance(intent.get("attempt"), str) and intent["attempt"]
        )
        if not valid_intent:
            fail("receipt intent.json has an unexpected schema or target.")
        if dispatch != {"outcome": "unknown"}:
            fail("receipt dispatch state is invalid.")
        if result not in ({"outcome": "succeeded"}, {"outcome": "recovered"}):
            fail("OCC receipt does not prove a successful install.")
        if digest(cluster) != intent.get("clusterSha256"):
            fail("selected kube context does not match the OCC receipt.")
        if (
            resources.get("version") != 1
            or resources.get("attempt") != intent["attempt"]
            or not isinstance(resources.get("resources"), dict)
        ):
            fail("receipt resources.json has an unexpected schema or attempt.")
        self.attempt = intent["attempt"]
        self.cluster_arn = marker["cluster_arn"]
        self.install_uids = resources["resources"]

    def validate_lifecycle_receipts(self):
        if self.a.storage_class_receipt:
            item = load_json(self.a.storage_class_receipt, "storage lifecycle receipt")
            resource = item.get("resource", {})
            valid = (
                item.get("version") == 1
                and item.get("operation") == "setup-storage-class"
                and item.get("kubeContext") == self.a.kube_context
                and item.get("clusterEndpoint") == self.endpoint
                and resource.get("apiVersion") == "storage.k8s.io/v1"
                and resource.get("kind") == "StorageClass"
                and resource.get("name") == STORAGE_CLASS
                and isinstance(resource.get("created"), bool)
                and bool(resource.get("uid"))
            )
            if not valid:
                fail("storage lifecycle receipt does not match this cleanup target.")
            self.storage = resource
        if not self.a.agentgateway_pod_identity_receipt:
            return

        item = load_json(
            self.a.agentgateway_pod_identity_receipt, "AgentGateway lifecycle receipt"
        )
        target, resources = item.get("target", {}), item.get("resources", {})
        account = self.a.aws_account_id
        role_arn = f"arn:aws:iam::{account}:role/{self.a.iam_role_name}"
        cluster_arn = f"arn:aws:eks:{self.a.aws_region}:{account}:cluster/{self.a.eks_cluster_name}"
        namespace, service_account = resources.get("namespace", {}), resources.get("serviceAccount", {})
        role, policy = resources.get("iamRole", {}), resources.get("inlinePolicy", {})
        association = resources.get("podIdentityAssociation", {})
        checks = (
            item.get("version") == 2,
            item.get("operation") == "setup-agentgateway-pod-identity",
            target == {
                "kubeContext": self.a.kube_context, "clusterEndpoint": self.endpoint,
                "awsRegion": self.a.aws_region, "awsAccountId": account,
                "eksClusterName": self.a.eks_cluster_name, "eksClusterArn": cluster_arn,
            },
            cluster_arn == self.cluster_arn,
            has_fields(namespace, {"apiVersion": "v1", "kind": "Namespace",
                                   "name": AGW_NAMESPACE}),
            has_fields(service_account, {
                "apiVersion": "v1", "kind": "ServiceAccount",
                "name": AGW_SERVICE_ACCOUNT, "namespace": AGW_NAMESPACE,
            }),
            has_fields(role, {"name": self.a.iam_role_name, "arn": role_arn}),
            has_fields(policy, {"name": self.a.iam_inline_policy_name,
                                "roleName": self.a.iam_role_name, "roleId": role.get("roleId")}),
            has_fields(association, {
                "associationId": self.a.pod_identity_association_id,
                "clusterName": self.a.eks_cluster_name, "namespace": AGW_NAMESPACE,
                "serviceAccount": AGW_SERVICE_ACCOUNT, "roleArn": role_arn,
                "targetRoleArn": None, "externalId": None,
                "disableSessionTags": False, "policy": None,
            }),
        )
        provenance = all(
            isinstance(resources.get(name, {}).get("created"), bool)
            for name in ("namespace", "serviceAccount", "iamRole", "inlinePolicy", "podIdentityAssociation")
        )
        if not all(checks):
            fail("AgentGateway lifecycle receipt does not match this cleanup target.")
        if not provenance:
            fail("AgentGateway lifecycle receipt has invalid provenance.")
        if not namespace.get("uid") or not service_account.get("uid"):
            fail("AgentGateway lifecycle receipt has an invalid Kubernetes UID.")
        self.pod = resources

    def freeze_exists(self):
        try:
            self.freeze_path.lstat()
            return True
        except FileNotFoundError:
            return False

    def check_freeze_file(self):
        info = self.freeze_path.lstat()
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600):
            fail("admission-freeze state must be an owned regular file with mode 0600.")

    def freeze_identity(self, namespace, uid):
        identity = "\0".join((
            self.a.kube_context, self.endpoint, self.attempt, namespace, uid))
        return (
            FREEZE_PREFIX + hashlib.sha256(identity.encode()).hexdigest()[:16],
            f"OpenClaw Enterprise cleanup admission freeze is active for namespace/{namespace}.",
        )

    def write_freeze(self, state):
        if self.freeze_exists():
            self.check_freeze_file()
        temporary = self.freeze_path.with_name(f".cleanup-freeze.{os.getpid()}")
        with temporary.open("x") as stream:
            json.dump(state, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.freeze_path)

    def read_freeze(self):
        if not self.freeze_exists():
            return None
        self.check_freeze_file()
        try:
            state = json.loads(self.freeze_path.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError):
            fail("admission-freeze state is invalid.")
        expected_keys = {
            "version", "context", "endpoint", "attempt", "namespace",
            "namespaceUid", "name", "token", "denialMessage",
            "policyUid", "bindingUid",
        }
        if not isinstance(state, dict):
            fail("admission-freeze state does not match this cleanup target.")
        expected_name, expected_message = self.freeze_identity(
            state.get("namespace", ""), state.get("namespaceUid", ""))
        valid = (
            set(state) == expected_keys
            and state.get("version") == 1
            and state.get("context") == self.a.kube_context
            and state.get("endpoint") == self.endpoint
            and state.get("attempt") == self.attempt
            and re.fullmatch(r"[a-f0-9]{32}", state.get("token", ""))
            and state.get("name") == expected_name
            and state.get("denialMessage") == expected_message
            and bool(state.get("namespace")) and bool(state.get("namespaceUid"))
            and all(
                state.get(key) is None
                or isinstance(state.get(key), str) and bool(state.get(key))
                for key in ("policyUid", "bindingUid")
            )
        )
        if not valid:
            fail("admission-freeze state does not match this cleanup target.")
        return state

    def freeze_annotations(self, state):
        return {
            f"{FREEZE_KEY}target-namespace": state["namespace"],
            f"{FREEZE_KEY}target-namespace-uid": state["namespaceUid"],
            f"{FREEZE_KEY}attempt": state["attempt"],
            f"{FREEZE_KEY}token": state["token"],
        }

    def freeze_spec(self, state, kind):
        if kind == "binding":
            return {"policyName": state["name"], "validationActions": ["Deny"]}
        return {
            "failurePolicy": "Fail",
            "matchConstraints": {"resourceRules": [{
                "apiGroups": ["*"], "apiVersions": ["*"],
                "operations": ["CREATE", "UPDATE"],
                "resources": ["*", "*/*"], "scope": "Namespaced",
            }]},
            "matchConditions": [{
                "name": "target-namespace",
                "expression": f"request.namespace == {json.dumps(state['namespace'])}",
            }],
            "validations": [{"expression": "false", "message": state["denialMessage"]}],
        }

    def validate_freeze(self, item, state, kind):
        metadata = (item or {}).get("metadata", {})
        expected_kind = "ValidatingAdmissionPolicyBinding" if kind == "binding" else "ValidatingAdmissionPolicy"
        expected_uid = state[f"{kind}Uid"]
        valid = (
            (item or {}).get("kind") == expected_kind
            and metadata.get("name") == state["name"]
            and metadata.get("labels", {}).get(OWNER_KEY) == OWNER
            and all(
                metadata.get("annotations", {}).get(key) == value
                for key, value in self.freeze_annotations(state).items()
            )
            and item.get("spec") == self.freeze_spec(state, kind)
            and (expected_uid is None or metadata.get("uid") == expected_uid)
        )
        if not valid:
            fail(f"admission-freeze {kind} identity/UID does not match private state; refusing deletion.")

    def raw_delete(self, item):
        metadata, kind = item["metadata"], item["kind"]
        name, namespace = metadata["name"], metadata.get("namespace")
        paths = {
            "Namespace": f"/api/v1/namespaces/{name}",
            "ServiceAccount": f"/api/v1/namespaces/{namespace}/serviceaccounts/{name}",
            "StorageClass": f"/apis/storage.k8s.io/v1/storageclasses/{name}",
            "ValidatingAdmissionPolicy": f"/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicies/{name}",
            "ValidatingAdmissionPolicyBinding": f"/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicybindings/{name}",
        }
        options = {
            "apiVersion": "v1", "kind": "DeleteOptions",
            "preconditions": {
                "uid": metadata["uid"], "resourceVersion": metadata["resourceVersion"],
            },
        }
        self.kubectl("delete", "--raw", paths[kind], "-f", "-", stdin=json.dumps(options))

    def recover_freeze(self):
        state = self.read_freeze()
        if not state:
            return
        resources = (
            ("binding", "validatingadmissionpolicybindings.admissionregistration.k8s.io"),
            ("policy", "validatingadmissionpolicies.admissionregistration.k8s.io"),
        )
        for kind, resource_type in resources:
            resource = f"{resource_type}/{state['name']}"
            item = self.get(resource)
            if not item:
                continue
            self.validate_freeze(item, state, kind)
            try:
                self.raw_delete(item)
            except CleanupError:
                item = self.get(resource)
                if not item:
                    continue
                self.validate_freeze(item, state, kind)
                self.raw_delete(item)
            item = self.get(resource)
            if item:
                self.validate_freeze(item, state, kind)
                fail(f"admission-freeze {kind} still exists after deletion.")
        self.freeze_path.unlink()
        self.freeze_started = False

    def start_freeze(self, namespace):
        metadata = namespace["metadata"]
        name, denial_message = self.freeze_identity(metadata["name"], metadata["uid"])
        state = {
            "version": 1, "context": self.a.kube_context, "endpoint": self.endpoint,
            "attempt": self.attempt, "namespace": metadata["name"],
            "namespaceUid": metadata["uid"], "name": name,
            "token": secrets.token_hex(16), "denialMessage": denial_message,
            "policyUid": None, "bindingUid": None,
        }
        self.write_freeze(state)
        self.freeze_started = True
        for kind in ("policy", "binding"):
            document = {
                "apiVersion": "admissionregistration.k8s.io/v1",
                "kind": "ValidatingAdmissionPolicyBinding" if kind == "binding" else "ValidatingAdmissionPolicy",
                "metadata": {
                    "name": state["name"], "labels": {OWNER_KEY: OWNER},
                    "annotations": self.freeze_annotations(state),
                },
                "spec": self.freeze_spec(state, kind),
            }
            self.kubectl("create", "-f", "-", stdin=json.dumps(document))
            resource_type = (
                "validatingadmissionpolicybindings.admissionregistration.k8s.io"
                if kind == "binding"
                else "validatingadmissionpolicies.admissionregistration.k8s.io"
            )
            item = self.get(f"{resource_type}/{state['name']}")
            self.validate_freeze(item, state, kind)
            state[f"{kind}Uid"] = item["metadata"]["uid"]
            self.write_freeze(state)
        probe = {
            "apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": "openclaw-cleanup-freeze-probe", "namespace": metadata["name"]},
        }
        result = subprocess.run(
            [*self.k, "create", "--dry-run=server", "-f", "-"],
            input=json.dumps(probe), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        if result.returncode == 0 or state["denialMessage"] not in result.stderr:
            fail("namespace admission freeze could not be verified.")

    def namespace_plan(self, name, owner, receipt_uid=None, receipt_required=False):
        item = self.get(f"namespace/{name}")
        if not item:
            return None
        metadata = item["metadata"]
        if metadata.get("labels", {}).get(OWNER_KEY) != owner:
            fail(f"namespace/{name} does not carry the exact {OWNER_KEY}={owner} ownership label.")
        if receipt_required and not receipt_uid:
            fail(f"namespace/{name} is live but has no UID in its lifecycle receipt.")
        if receipt_uid and metadata.get("uid") != receipt_uid:
            fail(f"namespace/{name} does not match its lifecycle receipt UID.")
        return item

    def wait_absent(self, resource, uid, seconds=600):
        deadline = time.monotonic() + seconds
        while True:
            item = self.get(resource)
            if not item:
                return
            if item["metadata"].get("uid") != uid:
                fail(f"{resource} was replaced while deletion was in progress.")
            if time.monotonic() >= deadline:
                fail(f"{resource} still exists after deletion.")
            time.sleep(2)

    def delete_namespace(self, planned):
        if not planned:
            return
        name, uid = planned["metadata"]["name"], planned["metadata"]["uid"]
        live = self.get(f"namespace/{name}")
        if not live:
            return
        if live["metadata"]["uid"] != uid:
            fail(f"namespace/{name} UID changed before deletion.")
        self.start_freeze(live)
        live = self.get(f"namespace/{name}")
        if not live or live["metadata"]["uid"] != uid:
            fail(f"namespace/{name} identity changed while admission was frozen.")
        self.raw_delete(live)
        self.wait_absent(f"namespace/{name}", uid)
        self.recover_freeze()

    def helm_present(self):
        releases = json.loads(run([
            *self.h, "list", "--namespace", self.a.namespace, "--all",
            "--filter", f"^{self.a.release}$", "--output=json",
        ]))
        if not releases:
            return False
        if len(releases) != 1 or releases[0].get("name") != self.a.release:
            fail("Helm release lookup returned an unexpected result.")
        values = json.loads(run([
            *self.h, "get", "values", self.a.release,
            "--namespace", self.a.namespace, "--output=json",
        ]))
        if values.get("installationAttempt") != self.attempt:
            fail("live Helm release does not match the OCC receipt attempt.")
        return True

    def verify_cluster_resources(self, helm_present):
        resources = [
            "validatingadmissionpolicies.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label",
            "validatingadmissionpolicybindings.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label",
            "mutatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-adapter",
            "validatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-policy",
        ]
        resources += [
            f"clusterrole.rbac.authorization.k8s.io/{self.a.release}-{name}"
            for name in (
                "openclaw-namespace-observer", "openclaw-namespace-worker",
                "openclaw-tenant-worker", "openclaw-tenant-api",
                "openclaw-tenant-configuration", "openclaw-gateway-observer",
            )
        ]
        resources += [
            f"clusterrolebinding.rbac.authorization.k8s.io/{self.a.release}-{name}"
            for name in ("openclaw-worker-namespaces", "openclaw-api-namespaces")
        ]
        for resource in resources:
            item = self.get(resource)
            if not item:
                continue
            expected_uid = self.install_uids.get(resource)
            if not expected_uid:
                fail(f"{resource} is live but has no UID in the installation receipt.")
            metadata = item["metadata"]
            if metadata.get("uid") != expected_uid:
                fail(f"{resource} does not match the UID recorded in the installation receipt.")
            labels, annotations = metadata.get("labels", {}), metadata.get("annotations", {})
            owner = labels.get(OWNER_KEY)
            helm_identity = (
                owner == "Helm"
                and labels.get("app.kubernetes.io/instance") == self.a.release
                and annotations.get("meta.helm.sh/release-name") == self.a.release
                and annotations.get("meta.helm.sh/release-namespace") == self.a.namespace
            )
            if owner != OWNER and not helm_identity:
                fail(f"{resource} does not carry an exact cleanup ownership label.")
            if not helm_present:
                fail(f"{resource} is live but the receipt-matched Helm release is absent.")

    def pod_action(self):
        if not self.pod:
            return None
        association = self.pod["podIdentityAssociation"]["created"]
        preserve_sa = not self.pod["serviceAccount"]["created"] or not association
        return (
            "delete-namespace" if self.pod["namespace"]["created"] and not preserve_sa
            else "delete-service-account" if not preserve_sa
            else "preserve"
        )

    def validate_storage(self):
        item = self.get(f"storageclass.storage.k8s.io/{STORAGE_CLASS}")
        if not item or not self.storage or not self.storage["created"]:
            return item
        metadata = item["metadata"]
        if (
            metadata.get("uid") != self.storage["uid"]
            or metadata.get("labels", {}).get(OWNER_KEY) != OWNER
        ):
            fail("storage class identity does not match its lifecycle receipt.")
        pvcs = json.loads(self.kubectl(
            "get", "persistentvolumeclaims", "--all-namespaces", "--output=json"
        ))
        if any(
            item.get("spec", {}).get("storageClassName") == STORAGE_CLASS
            for item in pvcs.get("items", [])
        ):
            fail("storage class is still referenced by a persistent volume claim.")
        return item

    def role(self):
        return self.aws_json(
            "iam", "get-role", "--role-name", self.a.iam_role_name,
            absent=AWS_ABSENT,
        )

    def validate_role(self, result):
        expected, live = self.pod["iamRole"], result.get("Role", {})
        identity = (
            live.get("RoleName") == expected.get("name")
            and live.get("Arn") == expected.get("arn")
            and live.get("RoleId") == expected.get("roleId")
        )
        tags = {item["Key"]: item["Value"] for item in live.get("Tags", [])}
        if expected["created"]:
            identity = identity and tags.get(INVOCATION_TAG) == expected.get("invocationId")
        if not identity:
            fail("IAM role does not match the lifecycle receipt identity.")

    def association(self):
        return self.aws_json(
            "eks", "describe-pod-identity-association",
            "--cluster-name", self.a.eks_cluster_name,
            "--association-id", self.a.pod_identity_association_id,
            absent=AWS_ABSENT,
        )

    def validate_aws(self):
        if not self.pod:
            return
        if self.aws_json("sts", "get-caller-identity").get("Account") != self.a.aws_account_id:
            fail("AWS CLI is authenticated to the wrong account.")
        cluster = self.aws_json("eks", "describe-cluster", "--name", self.a.eks_cluster_name)
        if cluster.get("cluster", {}).get("arn") != self.cluster_arn:
            fail("EKS cluster does not match the completion marker.")
        expected = self.pod["podIdentityAssociation"]
        if expected["created"]:
            result = self.association()
            if result:
                live = result.get("association", {})
                fields = (
                    "associationId", "associationArn", "clusterName", "namespace",
                    "serviceAccount", "roleArn", "targetRoleArn", "externalId",
                    "disableSessionTags", "policy",
                )
                if any(live.get(key) != expected.get(key) for key in fields):
                    fail("Pod Identity association does not match the lifecycle receipt identity.")
        role = self.role()
        policy = self.pod["inlinePolicy"]
        if role and (policy["created"] or self.pod["iamRole"]["created"]):
            self.validate_role(role)
        if role and policy["created"]:
            live = self.aws_json(
                "iam", "get-role-policy", "--role-name", self.a.iam_role_name,
                "--policy-name", self.a.iam_inline_policy_name, absent=AWS_ABSENT,
            )
            if live and digest(live.get("PolicyDocument")) != policy.get("documentSha256"):
                fail("inline policy does not match the lifecycle receipt identity.")

    def delete_aws(self):
        if not self.pod:
            return
        association = self.pod["podIdentityAssociation"]
        policy, role_receipt = self.pod["inlinePolicy"], self.pod["iamRole"]
        preserve_role = not role_receipt["created"] or not policy["created"] or not association["created"]
        if association["created"] and self.association():
            self.aws(
                "eks", "delete-pod-identity-association",
                "--cluster-name", self.a.eks_cluster_name,
                "--association-id", self.a.pod_identity_association_id,
            )
        if policy["created"]:
            role = self.role()
            if role:
                self.validate_role(role)
                self.aws(
                    "iam", "delete-role-policy", "--role-name", self.a.iam_role_name,
                    "--policy-name", self.a.iam_inline_policy_name,
                )
        if preserve_role:
            print(f"Preserved iam-role/{self.a.iam_role_name}: required by a reused resource.")
            return
        role = self.role()
        if not role:
            return
        self.validate_role(role)
        if self.aws_json(
            "iam", "list-role-policies", "--role-name", self.a.iam_role_name
        ).get("PolicyNames", []):
            fail("IAM role still has inline policies; refusing deletion.")
        if self.aws_json(
            "iam", "list-attached-role-policies", "--role-name", self.a.iam_role_name
        ).get("AttachedPolicies", []):
            fail("IAM role still has managed policies; refusing deletion.")
        if self.aws_json(
            "iam", "list-instance-profiles-for-role", "--role-name", self.a.iam_role_name
        ).get("InstanceProfiles", []):
            fail("IAM role still has instance profiles; refusing deletion.")
        self.aws("iam", "delete-role", "--role-name", self.a.iam_role_name)

    def run(self):
        self.validate_paths()
        self.validate_install_receipt()
        self.validate_lifecycle_receipts()
        self.recover_freeze()
        helm = self.helm_present()
        self.verify_cluster_resources(helm)
        self.validate_aws()

        plans = [
            self.namespace_plan(
                self.a.namespace, OWNER,
                self.install_uids.get(f"namespace/{self.a.namespace}"), True,
            ),
            self.namespace_plan(
                "openclaw-enterprise-adapter", OWNER,
                self.install_uids.get("namespace/openclaw-enterprise-adapter"), True,
            ),
            *[
                self.namespace_plan(namespace, OCE_OWNER)
                for namespace in self.a.tenant_namespace
            ],
        ]
        pod_action, agw_plan, service_account = self.pod_action(), None, None
        if pod_action == "delete-namespace":
            agw_plan = self.namespace_plan(
                AGW_NAMESPACE, OWNER, self.pod["namespace"]["uid"], True
            )
        elif pod_action == "delete-service-account":
            service_account = self.get(
                f"serviceaccount/{AGW_SERVICE_ACCOUNT}", AGW_NAMESPACE
            )
            if service_account:
                receipt, metadata = self.pod["serviceAccount"], service_account["metadata"]
                if (
                    metadata.get("uid") != receipt["uid"]
                    or metadata.get("labels", {}).get(OWNER_KEY) != OWNER
                ):
                    fail("AgentGateway service account does not match its lifecycle receipt.")
        storage = self.validate_storage()

        if helm:
            run([
                *self.h, "uninstall", self.a.release,
                "--namespace", self.a.namespace, "--wait", "--timeout", "10m",
            ])
        for plan in plans:
            self.delete_namespace(plan)
        self.delete_aws()
        if service_account:
            self.raw_delete(service_account)
        self.delete_namespace(agw_plan)
        if storage:
            if not self.storage:
                print(f"Preserved storageclass/{STORAGE_CLASS}: no lifecycle receipt.", file=sys.stderr)
                fail("cleanup is incomplete; review the preserved sample-owned resources.")
            if not self.storage["created"]:
                print(f"Preserved storageclass/{STORAGE_CLASS}: setup reused it.")
            else:
                self.raw_delete(storage)
        print(f"Cleanup completed for release {self.a.release} in kube context {self.a.kube_context}.")


def main():
    cleanup = None
    try:
        cleanup = Cleanup(parse_args())
        cleanup.run()
    except CleanupError as error:
        recovery_error = None
        if cleanup and cleanup.freeze_started:
            try:
                cleanup.recover_freeze()
            except CleanupError as nested:
                recovery_error = nested
        print(f"cleanup: {error}", file=sys.stderr)
        if recovery_error:
            print(f"cleanup: failed to remove admission freeze: {recovery_error}", file=sys.stderr)
        raise SystemExit(1)


main()
PY
