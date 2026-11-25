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
SOURCE_PIN = "86c8c12310f691bb21651118ffffd6bfd460e9ff"  # pragma: allowlist secret -- public source revision
AGW_NAMESPACE = "openclaw-enterprise-agw"
AGW_SERVICE_ACCOUNT = "agentgateway"
STORAGE_CLASS = "openclaw-enterprise-gp3"
FREEZE_PREFIX = "openclaw-enterprise-cleanup-freeze-"
FREEZE_KEY = "cleanup.openclaw.aws/"
SETUP_KEY = "openclaw-enterprise.aws.dev/setup-token"
POD_SETUP_KEY = "openclaw.enterprise/setup-invocation"
INVOCATION_TAG = "OpenClawSetupInvocation"
AWS_ABSENT = ("NoSuchEntity", "ResourceNotFoundException")
TENANT_WORKLOADS = (
    "pods,deployments.apps,statefulsets.apps,daemonsets.apps,"
    "jobs.batch,cronjobs.batch,replicasets.apps"
)
AGW_RESOURCES = (
    ("namespace", "_", AGW_NAMESPACE, "Namespace"),
    ("serviceaccount", AGW_NAMESPACE, "agentgateway", "ServiceAccount"),
    ("issuer.cert-manager.io", AGW_NAMESPACE, "agentgateway-selfsigned", "Issuer"),
    ("certificate.cert-manager.io", AGW_NAMESPACE, "agentgateway-root", "Certificate"),
    ("issuer.cert-manager.io", AGW_NAMESPACE, "agentgateway-ca", "Issuer"),
    ("certificate.cert-manager.io", AGW_NAMESPACE, "agentgateway-serving", "Certificate"),
    ("secret", AGW_NAMESPACE, "agw-client-key", "Secret"),
    ("secret", AGW_NAMESPACE, "agw-session-key", "Secret"),
    ("configmap", AGW_NAMESPACE, "agentgateway-config", "ConfigMap"),
    ("deployment.apps", AGW_NAMESPACE, "agentgateway", "Deployment"),
    (
        "poddisruptionbudget.policy",
        AGW_NAMESPACE,
        "agentgateway",
        "PodDisruptionBudget",
    ),
    ("service", AGW_NAMESPACE, "agentgateway", "Service"),
)


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
    parser.add_argument("--tenant-namespace-uid", action="append", default=[])
    parser.add_argument("--tenant-validator-key-file", action="append", default=[])
    parser.add_argument("--delete-tenant-data", action="store_true")
    for flag in (
        "storage-class-receipt", "agentgateway-receipt",
        "agentgateway-pod-identity-receipt",
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
    tenant_namespace_uids = {}
    for identity in args.tenant_namespace_uid:
        name, separator, uid = identity.partition("=")
        if (
            separator != "="
            or len(name) > 63
            or not dns.fullmatch(name)
            or not re.fullmatch(r"[A-Za-z0-9._:-]+", uid)
        ):
            fail("--tenant-namespace-uid must use NAME=UID with a valid Kubernetes UID.")
        if name in tenant_namespace_uids:
            fail("a tenant namespace UID was supplied more than once.")
        tenant_namespace_uids[name] = uid
    args.tenant_namespace_uids = tenant_namespace_uids
    validator_paths = [Path(path) for path in args.tenant_validator_key_file]
    if any(not path.is_absolute() or path.name != "validator-service-key.json"
           for path in validator_paths):
        fail(
            "--tenant-validator-key-file must be an absolute path ending in "
            "validator-service-key.json."
        )
    if len(set(validator_paths)) != len(validator_paths):
        fail("a tenant validator key file was supplied more than once.")
    reserved = {args.namespace, "openclaw-enterprise-adapter", AGW_NAMESPACE}
    if reserved & set(args.tenant_namespace):
        fail("a reserved namespace was supplied as a tenant namespace.")
    if args.delete_tenant_data and not args.tenant_namespace:
        fail("--delete-tenant-data requires at least one --tenant-namespace.")
    if args.tenant_validator_key_file and not args.delete_tenant_data:
        fail("--tenant-validator-key-file requires --delete-tenant-data.")
    aws_fields = (
        "aws_region", "aws_account_id", "eks_cluster_name",
        "pod_identity_association_id", "iam_role_name", "iam_inline_policy_name",
    )
    aws_values = [getattr(args, name) for name in aws_fields]
    if any(aws_values) and not all(aws_values):
        fail("AgentGateway cleanup requires every AWS identifier.")
    if bool(args.agentgateway_pod_identity_receipt) != all(aws_values):
        fail("AgentGateway cleanup requires its lifecycle receipt and every AWS identifier.")
    if bool(args.agentgateway_receipt) != bool(args.agentgateway_pod_identity_receipt):
        fail(
            "AgentGateway cleanup requires both its Kubernetes and Pod Identity "
            "lifecycle receipts."
        )
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


def require_helm_3():
    version = run(["helm", "version", "--short"]).strip()
    if not re.match(r"^v?3(?:[.+-]|$)", version):
        fail(f"pinned OCE revision requires Helm 3; found {version or 'unknown version'}.")


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
        self.tenant_freeze_path = Path(args.state_dir) / "cleanup-tenant-freeze.json"
        self.tenant_deletion_path = Path(args.state_dir) / "cleanup-tenant-deletion.json"
        self.freeze_started = False
        self.tenant_freeze_started = False
        self.admission_controls_dismantled = False
        self.endpoint = self.attempt = self.cluster_arn = ""
        self.install_uids = {}
        self.storage = self.pod = self.gateway = None
        self.local_credentials = []

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

    def credential_error(self, path, reason):
        fail(
            f"local credential remains at {path}: {reason} Revoke it if the OCE "
            "API is still available, then delete that exact file and every "
            "backup or snapshot that contains it."
        )

    def validate_local_credentials(self):
        paths = [
            Path(self.a.state_dir) / "initial-admin-service-key.json",
            Path(self.a.state_dir) / "initial-admin-password",
            *(Path(path) for path in self.a.tenant_validator_key_file),
        ]
        for path in paths:
            try:
                path.lstat()
            except FileNotFoundError:
                continue
            except OSError as error:
                self.credential_error(path, f"could not inspect it ({error}).")
            try:
                private_path(path.parent, "credential parent directory", True)
                checked = private_path(path, "local credential")
                info = checked.stat()
                if checked.resolve() != checked or info.st_nlink != 1:
                    self.credential_error(
                        path,
                        "it must be a canonical private file with one hard link.",
                    )
            except CleanupError as error:
                self.credential_error(path, str(error))
            self.local_credentials.append((path, info.st_dev, info.st_ino))

    def remove_local_credentials(self):
        for path, device, inode in self.local_credentials:
            try:
                checked = private_path(path, "local credential")
                info = checked.stat()
                if (info.st_dev, info.st_ino, info.st_nlink) != (device, inode, 1):
                    self.credential_error(path, "its identity changed after preflight.")
                checked.unlink()
                checked.lstat()
            except FileNotFoundError:
                print(f"Removed local credential: {path}")
            except CleanupError:
                raise
            except OSError as error:
                self.credential_error(path, f"could not remove it ({error}).")

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
            self.a.agentgateway_receipt, "AgentGateway Kubernetes lifecycle receipt"
        )
        expected = [
            {"resource": resource, "namespace": namespace, "name": name}
            for resource, namespace, name, _ in AGW_RESOURCES
        ]
        resources = item.get("resources")
        valid_gateway = (
            item.get("version") == 1
            and item.get("clusterEndpoint") == self.endpoint
            and item.get("namespace") == AGW_NAMESPACE
            and re.fullmatch(r"[a-f0-9]{32}", item.get("setupId", ""))
            and isinstance(resources, list)
            and len(resources) == len(expected)
            and all(
                isinstance(record, dict)
                and set(record) == {"resource", "namespace", "name", "uid", "created"}
                and {
                    key: record.get(key)
                    for key in ("resource", "namespace", "name")
                } == target
                and isinstance(record.get("uid"), str)
                and bool(record["uid"])
                and isinstance(record.get("created"), bool)
                for record, target in zip(resources or [], expected)
            )
        )
        if not valid_gateway:
            fail("AgentGateway Kubernetes lifecycle receipt does not match this cleanup target.")
        self.gateway = {
            "setupId": item["setupId"],
            "resources": resources,
        }

        item = load_json(
            self.a.agentgateway_pod_identity_receipt, "AgentGateway lifecycle receipt"
        )
        target, resources = item.get("target", {}), item.get("resources", {})
        account = self.a.aws_account_id
        role_arn = f"arn:aws:iam::{account}:role/{self.a.iam_role_name}"
        cluster_arn = f"arn:aws:eks:{self.a.aws_region}:{account}:cluster/{self.a.eks_cluster_name}"
        namespace = resources.get("namespace", {})
        service_account = resources.get("serviceAccount", {})
        region_config_map = resources.get("regionConfigMap", {})
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
            has_fields(region_config_map, {
                "apiVersion": "v1", "kind": "ConfigMap",
                "name": "agentgateway-aws-region", "namespace": AGW_NAMESPACE,
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
            for name in (
                "namespace", "serviceAccount", "regionConfigMap", "iamRole",
                "inlinePolicy", "podIdentityAssociation",
            )
        )
        if not all(checks):
            fail("AgentGateway lifecycle receipt does not match this cleanup target.")
        if not provenance:
            fail("AgentGateway lifecycle receipt has invalid provenance.")
        if (
            not namespace.get("uid")
            or not service_account.get("uid")
            or not region_config_map.get("uid")
        ):
            fail("AgentGateway lifecycle receipt has an invalid Kubernetes UID.")
        gateway_namespace, gateway_service_account = (
            self.gateway["resources"][0],
            self.gateway["resources"][1],
        )
        if (
            gateway_namespace["uid"] != namespace["uid"]
            or gateway_service_account["uid"] != service_account["uid"]
            or gateway_namespace["created"]
            or gateway_service_account["created"]
        ):
            fail(
                "AgentGateway Kubernetes and Pod Identity lifecycle receipts "
                "do not agree on their shared resources."
            )
        self.pod = resources

    def validate_gateway_resource(self, target, record, item, *, late=False):
        _, namespace, name, kind = target
        metadata = item.get("metadata", {})
        token = metadata.get("annotations", {}).get(SETUP_KEY)
        valid = (
            item.get("kind") == kind
            and metadata.get("name") == name
            and metadata.get("namespace")
            == (None if namespace == "_" else namespace)
            and metadata.get("uid") == record["uid"]
            and metadata.get("labels", {}).get(OWNER_KEY) == OWNER
            and (
                token == self.gateway["setupId"]
                if record["created"]
                else token is None
            )
        )
        if not valid:
            detail = (
                " changed after AgentGateway cleanup preflight"
                if late
                else " does not match its AgentGateway lifecycle receipt"
            )
            fail(f"{kind}/{name}{detail}.")

    def gateway_plan(self):
        if not self.gateway:
            return [], False
        planned = []
        preserve_dependencies = False
        for target, record in zip(AGW_RESOURCES, self.gateway["resources"]):
            resource, namespace, name, kind = target
            item = self.get(
                f"{resource}/{name}",
                None if namespace == "_" else namespace,
            )
            if not item:
                planned.append((target, record, None))
                continue
            self.validate_gateway_resource(target, record, item)
            if not record["created"] and kind not in ("Namespace", "ServiceAccount"):
                preserve_dependencies = True
            planned.append((target, record, item))
        if self.pod and any(
            not self.pod[name]["created"]
            for name in (
                "regionConfigMap",
                "iamRole",
                "inlinePolicy",
                "podIdentityAssociation",
            )
        ):
            preserve_dependencies = True
        return planned, preserve_dependencies

    def delete_gateway_resources(self, planned):
        for target, record, planned_item in reversed(planned):
            _, _, name, kind = target
            if kind in ("Namespace", "ServiceAccount") or not record["created"]:
                continue
            live = self.get(
                f"{target[0]}/{name}",
                None if target[1] == "_" else target[1],
            )
            if not live:
                continue
            if not planned_item:
                fail(f"{kind}/{name} changed after AgentGateway cleanup preflight.")
            self.validate_gateway_resource(target, record, live, late=True)
            self.raw_delete(live)

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
                "resources": ["*/*"], "scope": "Namespaced",
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
            "Secret": f"/api/v1/namespaces/{namespace}/secrets/{name}",
            "ConfigMap": f"/api/v1/namespaces/{namespace}/configmaps/{name}",
            "Service": f"/api/v1/namespaces/{namespace}/services/{name}",
            "Issuer": f"/apis/cert-manager.io/v1/namespaces/{namespace}/issuers/{name}",
            "Certificate": (
                f"/apis/cert-manager.io/v1/namespaces/{namespace}/certificates/{name}"
            ),
            "Deployment": f"/apis/apps/v1/namespaces/{namespace}/deployments/{name}",
            "PodDisruptionBudget": (
                f"/apis/policy/v1/namespaces/{namespace}/poddisruptionbudgets/{name}"
            ),
            "StorageClass": f"/apis/storage.k8s.io/v1/storageclasses/{name}",
            "ClusterRole": f"/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}",
            "ClusterRoleBinding": f"/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/{name}",
            "MutatingWebhookConfiguration": f"/apis/admissionregistration.k8s.io/v1/mutatingwebhookconfigurations/{name}",
            "ValidatingWebhookConfiguration": f"/apis/admissionregistration.k8s.io/v1/validatingwebhookconfigurations/{name}",
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

    def tenant_freeze_exists(self):
        try:
            self.tenant_freeze_path.lstat()
            return True
        except FileNotFoundError:
            return False

    def tenant_deletion_exists(self):
        try:
            self.tenant_deletion_path.lstat()
            return True
        except FileNotFoundError:
            return False

    def check_tenant_deletion_file(self):
        info = self.tenant_deletion_path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            fail(
                "tenant deletion state must be an owned regular file "
                "with mode 0600."
            )

    def write_tenant_deletion(self, state):
        if self.tenant_deletion_exists():
            self.check_tenant_deletion_file()
        temporary = self.tenant_deletion_path.with_name(
            f".cleanup-tenant-deletion.{os.getpid()}"
        )
        with temporary.open("x") as stream:
            json.dump(state, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.tenant_deletion_path)

    def read_tenant_deletion(self):
        if not self.tenant_deletion_exists():
            return None
        self.check_tenant_deletion_file()
        try:
            state = json.loads(self.tenant_deletion_path.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError):
            fail("tenant deletion state is invalid.")
        expected_keys = {
            "version",
            "context",
            "endpoint",
            "attempt",
            "namespaces",
            "persistentVolumes",
            "complete",
        }
        namespaces = state.get("namespaces") if isinstance(state, dict) else None
        volumes = (
            state.get("persistentVolumes") if isinstance(state, dict) else None
        )
        valid_targets = (
            isinstance(namespaces, list)
            and bool(namespaces)
            and namespaces == sorted(namespaces, key=lambda item: item.get("name", ""))
            and all(
                isinstance(item, dict)
                and set(item) == {"name", "uid"}
                and isinstance(item["name"], str)
                and bool(item["name"])
                and isinstance(item["uid"], str)
                and bool(item["uid"])
                for item in namespaces
            )
            and len({item["name"] for item in namespaces}) == len(namespaces)
        )
        valid_volumes = (
            isinstance(volumes, list)
            and volumes == sorted(volumes, key=lambda item: item.get("name", ""))
            and all(
                isinstance(item, dict)
                and set(item) == {"name", "uid"}
                and isinstance(item["name"], str)
                and bool(item["name"])
                and isinstance(item["uid"], str)
                and bool(item["uid"])
                for item in volumes
            )
            and len({item["name"] for item in volumes}) == len(volumes)
        )
        valid = (
            isinstance(state, dict)
            and set(state) == expected_keys
            and state.get("version") == 1
            and state.get("context") == self.a.kube_context
            and state.get("endpoint") == self.endpoint
            and state.get("attempt") == self.attempt
            and valid_targets
            and valid_volumes
            and isinstance(state.get("complete"), bool)
        )
        if not valid:
            fail("tenant deletion state does not match this cleanup target.")
        return state

    def check_tenant_freeze_file(self):
        info = self.tenant_freeze_path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            fail(
                "tenant admission-freeze state must be an owned regular file "
                "with mode 0600."
            )

    def tenant_freeze_identity(self, namespaces):
        identity = {
            "context": self.a.kube_context,
            "endpoint": self.endpoint,
            "attempt": self.attempt,
            "namespaces": namespaces,
        }
        suffix = digest(identity)[:16]
        return (
            f"{FREEZE_PREFIX}tenants-{suffix}",
            "OpenClaw Enterprise cleanup admission freeze is active for tenant namespaces.",
        )

    def write_tenant_freeze(self, state):
        if self.tenant_freeze_exists():
            self.check_tenant_freeze_file()
        temporary = self.tenant_freeze_path.with_name(
            f".cleanup-tenant-freeze.{os.getpid()}"
        )
        with temporary.open("x") as stream:
            json.dump(state, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.tenant_freeze_path)

    def read_tenant_freeze(self):
        if not self.tenant_freeze_exists():
            return None
        self.check_tenant_freeze_file()
        try:
            state = json.loads(self.tenant_freeze_path.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError):
            fail("tenant admission-freeze state is invalid.")
        expected_keys = {
            "version",
            "context",
            "endpoint",
            "attempt",
            "namespaces",
            "name",
            "token",
            "denialMessage",
            "policyUid",
            "bindingUid",
        }
        namespaces = state.get("namespaces") if isinstance(state, dict) else None
        valid_namespaces = (
            isinstance(namespaces, list)
            and bool(namespaces)
            and namespaces == sorted(namespaces, key=lambda item: item.get("name", ""))
            and all(
                isinstance(item, dict)
                and set(item) == {"name", "uid"}
                and isinstance(item["name"], str)
                and bool(item["name"])
                and isinstance(item["uid"], str)
                and bool(item["uid"])
                for item in namespaces
            )
            and len({item["name"] for item in namespaces}) == len(namespaces)
        )
        expected_name, expected_message = self.tenant_freeze_identity(
            namespaces if valid_namespaces else []
        )
        valid = (
            isinstance(state, dict)
            and set(state) == expected_keys
            and state.get("version") == 1
            and state.get("context") == self.a.kube_context
            and state.get("endpoint") == self.endpoint
            and state.get("attempt") == self.attempt
            and valid_namespaces
            and state.get("name") == expected_name
            and state.get("denialMessage") == expected_message
            and re.fullmatch(r"[a-f0-9]{32}", state.get("token", ""))
            and all(
                state.get(key) is None
                or isinstance(state.get(key), str) and bool(state.get(key))
                for key in ("policyUid", "bindingUid")
            )
        )
        if not valid:
            fail("tenant admission-freeze state does not match this cleanup target.")
        return state

    def tenant_freeze_annotations(self, state):
        return {
            f"{FREEZE_KEY}target-digest": digest(state["namespaces"]),
            f"{FREEZE_KEY}attempt": state["attempt"],
            f"{FREEZE_KEY}token": state["token"],
        }

    def tenant_freeze_spec(self, state, kind):
        if kind == "binding":
            return {
                "policyName": state["name"],
                "validationActions": ["Deny"],
                "matchResources": {
                    "namespaceSelector": {
                        "matchLabels": {OWNER_KEY: OCE_OWNER},
                    },
                },
            }
        return {
            "failurePolicy": "Fail",
            "matchConstraints": {
                "resourceRules": [
                    {
                        "apiGroups": ["*"],
                        "apiVersions": ["*"],
                        "operations": ["CREATE", "UPDATE"],
                        "resources": ["*/*"],
                        "scope": "Namespaced",
                    }
                ]
            },
            "validations": [
                {"expression": "false", "message": state["denialMessage"]}
            ],
        }

    def validate_tenant_freeze(self, item, state, kind):
        metadata = (item or {}).get("metadata", {})
        expected_kind = (
            "ValidatingAdmissionPolicyBinding"
            if kind == "binding"
            else "ValidatingAdmissionPolicy"
        )
        expected_uid = state[f"{kind}Uid"]
        valid = (
            (item or {}).get("kind") == expected_kind
            and metadata.get("name") == state["name"]
            and metadata.get("labels", {}).get(OWNER_KEY) == OWNER
            and all(
                metadata.get("annotations", {}).get(key) == value
                for key, value in self.tenant_freeze_annotations(state).items()
            )
            and item.get("spec") == self.tenant_freeze_spec(state, kind)
            and (expected_uid is None or metadata.get("uid") == expected_uid)
        )
        if not valid:
            fail(
                f"tenant admission-freeze {kind} identity/UID does not match "
                "private state; refusing deletion."
            )

    def recover_tenant_freeze(self):
        state = self.read_tenant_freeze()
        if not state:
            return
        resources = (
            (
                "binding",
                "validatingadmissionpolicybindings.admissionregistration.k8s.io",
            ),
            (
                "policy",
                "validatingadmissionpolicies.admissionregistration.k8s.io",
            ),
        )
        for kind, resource_type in resources:
            resource = f"{resource_type}/{state['name']}"
            item = self.get(resource)
            if not item:
                continue
            self.validate_tenant_freeze(item, state, kind)
            self.raw_delete(item)
            item = self.get(resource)
            if item:
                self.validate_tenant_freeze(item, state, kind)
                fail(f"tenant admission-freeze {kind} still exists after deletion.")
        self.tenant_freeze_path.unlink()
        self.tenant_freeze_started = False

    def verify_tenant_freeze(self, state, live_targets):
        for target in live_targets:
            probe = {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "openclaw-cleanup-freeze-probe",
                    "namespace": target["name"],
                },
            }
            result = subprocess.run(
                [*self.k, "create", "--dry-run=server", "-f", "-"],
                input=json.dumps(probe),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode == 0 or state["denialMessage"] not in result.stderr:
                fail(
                    f"tenant admission freeze could not be verified for "
                    f"namespace/{target['name']}."
                )

    def ensure_tenant_freeze(self, tenant_plans, protected_targets):
        live_targets = self.tenant_namespace_targets(tenant_plans)
        state = self.read_tenant_freeze()
        if state:
            if state["namespaces"] != protected_targets:
                fail(
                    "tenant admission-freeze state does not match the recorded "
                    "tenant deletion targets."
                )
            self.tenant_freeze_started = True
            for kind, resource_type in (
                (
                    "policy",
                    "validatingadmissionpolicies.admissionregistration.k8s.io",
                ),
                (
                    "binding",
                    "validatingadmissionpolicybindings.admissionregistration.k8s.io",
                ),
            ):
                self.validate_tenant_freeze(
                    self.get(f"{resource_type}/{state['name']}"),
                    state,
                    kind,
                )
            self.verify_tenant_freeze(state, live_targets)
            return
        if not live_targets:
            return

        name, denial_message = self.tenant_freeze_identity(protected_targets)
        state = {
            "version": 1,
            "context": self.a.kube_context,
            "endpoint": self.endpoint,
            "attempt": self.attempt,
            "namespaces": protected_targets,
            "name": name,
            "token": secrets.token_hex(16),
            "denialMessage": denial_message,
            "policyUid": None,
            "bindingUid": None,
        }
        self.write_tenant_freeze(state)
        self.tenant_freeze_started = True
        for kind in ("policy", "binding"):
            document = {
                "apiVersion": "admissionregistration.k8s.io/v1",
                "kind": (
                    "ValidatingAdmissionPolicyBinding"
                    if kind == "binding"
                    else "ValidatingAdmissionPolicy"
                ),
                "metadata": {
                    "name": state["name"],
                    "labels": {OWNER_KEY: OWNER},
                    "annotations": self.tenant_freeze_annotations(state),
                },
                "spec": self.tenant_freeze_spec(state, kind),
            }
            self.kubectl("create", "-f", "-", stdin=json.dumps(document))
            resource_type = (
                "validatingadmissionpolicybindings.admissionregistration.k8s.io"
                if kind == "binding"
                else "validatingadmissionpolicies.admissionregistration.k8s.io"
            )
            item = self.get(f"{resource_type}/{state['name']}")
            self.validate_tenant_freeze(item, state, kind)
            state[f"{kind}Uid"] = item["metadata"]["uid"]
            self.write_tenant_freeze(state)
        self.verify_tenant_freeze(state, live_targets)

    def discover_managed_tenant_namespaces(self):
        result = json.loads(
            self.kubectl(
                "get",
                "namespaces",
                "--selector",
                f"{OWNER_KEY}={OCE_OWNER}",
                "--output=json",
            )
        )
        items = result.get("items")
        if not isinstance(items, list):
            fail("managed tenant namespace discovery returned an unexpected result.")
        discovered = {}
        for item in items:
            metadata = item.get("metadata", {})
            name = metadata.get("name")
            uid = metadata.get("uid")
            if (
                item.get("kind") != "Namespace"
                or not isinstance(name, str)
                or not name
                or not isinstance(uid, str)
                or not uid
                or metadata.get("labels", {}).get(OWNER_KEY) != OCE_OWNER
                or name in discovered
            ):
                fail("managed tenant namespace discovery returned an invalid namespace.")
            discovered[name] = item
        return [discovered[name] for name in sorted(discovered)]

    def tenant_namespace_targets(self, tenant_plans):
        return [
            {
                "name": item["metadata"]["name"],
                "uid": item["metadata"]["uid"],
            }
            for item in tenant_plans
        ]

    def managed_tenant_namespaces(self):
        tenant_plans = self.discover_managed_tenant_namespaces()
        discovered = {
            item["metadata"]["name"]: item
            for item in tenant_plans
        }
        supplied = set(self.a.tenant_namespace)
        supplied_targets = [
            {
                "name": name,
                "uid": self.a.tenant_namespace_uids[name],
            }
            for name in sorted(self.a.tenant_namespace_uids)
        ]
        deletion = self.read_tenant_deletion()
        if deletion and not self.a.delete_tenant_data:
            fail(
                "tenant deletion is incomplete; rerun with "
                "--delete-tenant-data and the same --tenant-namespace values."
            )
        expected = (
            {item["name"] for item in deletion["namespaces"]}
            if deletion
            else set(discovered)
        )
        if supplied != expected:
            missing = sorted(expected - supplied)
            extra = sorted(supplied - expected)
            detail = []
            if missing:
                detail.append("not supplied: " + ", ".join(missing))
            if extra:
                detail.append("not recorded: " + ", ".join(extra))
            fail(
                "the supplied tenant namespace set does not exactly match the "
                "cleanup tenant namespace set (" + "; ".join(detail) + ")."
            )
        if deletion:
            if supplied_targets and supplied_targets != deletion["namespaces"]:
                fail(
                    "the supplied tenant namespace identities do not exactly "
                    "match the recorded tenant deletion identities."
                )
            live = self.require_tenant_namespaces_unchanged(
                deletion["namespaces"], allow_absent=True
            )
            if deletion["complete"] and live:
                fail(
                    "tenant deletion state is complete but a recorded namespace "
                    "exists; refusing to continue."
                )
            return live, deletion["namespaces"]
        if tenant_plans and not self.a.delete_tenant_data:
            fail(
                "tenant namespaces may contain user data; cleanup made no "
                "changes. Rerun with --delete-tenant-data to delete the exact "
                "listed tenant namespaces and their data."
            )
        if self.a.delete_tenant_data:
            if set(self.a.tenant_namespace_uids) != supplied:
                fail(
                    "--delete-tenant-data requires one "
                    "--tenant-namespace-uid NAME=UID for every supplied tenant "
                    "namespace on the first cleanup attempt."
                )
            live = self.require_tenant_namespaces_unchanged(supplied_targets)
            return live, supplied_targets
        return tenant_plans, self.tenant_namespace_targets(tenant_plans)

    def require_tenant_namespaces_unchanged(self, expected, allow_absent=False):
        expected_targets = (
            expected
            if not expected or "metadata" not in expected[0]
            else self.tenant_namespace_targets(expected)
        )
        expected_by_name = {item["name"]: item["uid"] for item in expected_targets}
        current = self.discover_managed_tenant_namespaces()
        current_by_name = {
            item["metadata"]["name"]: item["metadata"]["uid"]
            for item in current
        }
        if set(current_by_name) - set(expected_by_name):
            fail(
                "managed tenant namespaces changed during cleanup; "
                "refusing to continue."
            )
        live = []
        for name, expected_uid in sorted(expected_by_name.items()):
            item = self.get(f"namespace/{name}")
            if not item:
                if not allow_absent:
                    fail(
                        "managed tenant namespaces changed during cleanup; "
                        "refusing to continue."
                    )
                continue
            metadata = item.get("metadata", {})
            if (
                item.get("kind") != "Namespace"
                or metadata.get("uid") != expected_uid
                or metadata.get("labels", {}).get(OWNER_KEY) != OCE_OWNER
                or current_by_name.get(name) != expected_uid
            ):
                fail(
                    "managed tenant namespaces changed during cleanup; "
                    "refusing to continue."
                )
            live.append(item)
        return live

    def tenant_persistent_volumes(self, namespace_names):
        result = json.loads(
            self.kubectl("get", "persistentvolumes", "--output=json")
        )
        items = result.get("items")
        if not isinstance(items, list):
            fail("persistent volume discovery returned an unexpected result.")
        volumes = []
        for item in items:
            claim = item.get("spec", {}).get("claimRef", {})
            if claim.get("namespace") not in namespace_names:
                continue
            metadata = item.get("metadata", {})
            name, uid = metadata.get("name"), metadata.get("uid")
            if (
                item.get("kind") != "PersistentVolume"
                or not isinstance(name, str)
                or not name
                or not isinstance(uid, str)
                or not uid
            ):
                fail("persistent volume discovery returned an invalid volume.")
            volumes.append({"name": name, "uid": uid})
        return sorted(volumes, key=lambda item: item["name"])

    def prepare_tenant_deletion(self, protected_targets):
        state = self.read_tenant_deletion()
        if state:
            if state["namespaces"] != protected_targets:
                fail(
                    "tenant deletion state does not match the recorded "
                    "namespace identities."
                )
            return state
        names = {item["name"] for item in protected_targets}
        state = {
            "version": 1,
            "context": self.a.kube_context,
            "endpoint": self.endpoint,
            "attempt": self.attempt,
            "namespaces": protected_targets,
            "persistentVolumes": self.tenant_persistent_volumes(names),
            "complete": False,
        }
        self.write_tenant_deletion(state)
        return state

    def wait_for_tenant_data_deletion(self, state, seconds=600):
        target_names = {item["name"] for item in state["namespaces"]}
        expected_volumes = {
            item["name"]: item["uid"] for item in state["persistentVolumes"]
        }
        deadline = time.monotonic() + seconds
        while True:
            pending = []
            for target in state["namespaces"]:
                item = self.get(f"namespace/{target['name']}")
                if item:
                    if item.get("metadata", {}).get("uid") != target["uid"]:
                        fail(
                            f"namespace/{target['name']} was replaced while "
                            "tenant deletion was in progress."
                        )
                    pending.append(f"namespace/{target['name']}")
            pvcs = json.loads(
                self.kubectl(
                    "get",
                    "persistentvolumeclaims",
                    "--all-namespaces",
                    "--output=json",
                )
            )
            pvc_items = pvcs.get("items")
            if not isinstance(pvc_items, list):
                fail(
                    "persistent volume claim discovery returned an "
                    "unexpected result."
                )
            pending.extend(
                f"persistentvolumeclaim/{item.get('metadata', {}).get('name', '<unknown>')}"
                for item in pvc_items
                if item.get("metadata", {}).get("namespace") in target_names
            )
            pvs = json.loads(
                self.kubectl("get", "persistentvolumes", "--output=json")
            )
            pv_items = pvs.get("items")
            if not isinstance(pv_items, list):
                fail("persistent volume discovery returned an unexpected result.")
            for item in pv_items:
                metadata = item.get("metadata", {})
                name, uid = metadata.get("name"), metadata.get("uid")
                claim_namespace = item.get("spec", {}).get("claimRef", {}).get(
                    "namespace"
                )
                if name in expected_volumes:
                    if uid != expected_volumes[name]:
                        fail(
                            f"persistentvolume/{name} was replaced while "
                            "tenant deletion was in progress."
                        )
                    pending.append(f"persistentvolume/{name}")
                elif claim_namespace in target_names:
                    pending.append(
                        f"persistentvolume/{name or '<unknown>'}"
                    )
            if not pending:
                return
            if time.monotonic() >= deadline:
                fail(
                    "tenant data still exists after namespace deletion: "
                    + ", ".join(sorted(set(pending)))
                    + "."
                )
            time.sleep(2)

    def delete_tenant_data(self, tenant_plans, protected_targets, state):
        if state["complete"]:
            self.wait_for_tenant_data_deletion(state)
            if self.tenant_freeze_exists():
                self.recover_tenant_freeze()
            return
        tenant_plans = self.require_tenant_namespaces_unchanged(
            protected_targets, allow_absent=True
        )
        by_name = {
            item["metadata"]["name"]: item
            for item in tenant_plans
        }
        for target in protected_targets:
            item = by_name.get(target["name"])
            if not item:
                continue
            self.raw_delete(item)
            self.wait_absent(f"namespace/{target['name']}", target["uid"])
        self.wait_for_tenant_data_deletion(state)
        if self.discover_managed_tenant_namespaces():
            fail(
                "managed tenant namespaces remain after tenant deletion; "
                "refusing to continue."
            )
        state["complete"] = True
        self.write_tenant_deletion(state)
        self.recover_tenant_freeze()

    def require_tenant_quiescence(self, tenant_plans):
        for namespace in tenant_plans:
            name = namespace["metadata"]["name"]
            result = json.loads(
                self.kubectl(
                    "get",
                    TENANT_WORKLOADS,
                    "--namespace",
                    name,
                    "--ignore-not-found",
                    "--output=json",
                )
            )
            items = result.get("items")
            if not isinstance(items, list):
                fail(
                    f"workload discovery for namespace/{name} returned an "
                    "unexpected result."
                )
            if items:
                summaries = sorted(
                    f"{item.get('kind', 'Resource')}/"
                    f"{item.get('metadata', {}).get('name', '<unknown>')}"
                    for item in items
                )
                fail(
                    f"namespace/{name} still has workload resources: "
                    f"{', '.join(summaries)}. Delete or quiesce its agents "
                    "before cleanup."
                )

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
        expected_labels = planned["metadata"].get("labels", {})
        expected_annotations = planned["metadata"].get("annotations", {})

        def validate_live(item, stage):
            metadata = item.get("metadata", {})
            labels, annotations = (
                metadata.get("labels", {}),
                metadata.get("annotations", {}),
            )
            valid = (
                item.get("kind") == "Namespace"
                and metadata.get("name") == name
                and metadata.get("uid") == uid
                and labels.get(OWNER_KEY) == expected_labels.get(OWNER_KEY)
                and labels.get(POD_SETUP_KEY) == expected_labels.get(POD_SETUP_KEY)
                and annotations.get(SETUP_KEY) == expected_annotations.get(SETUP_KEY)
            )
            if not valid:
                fail(f"namespace/{name} identity changed {stage}.")

        live = self.get(f"namespace/{name}")
        if not live:
            return
        validate_live(live, "before deletion")
        self.start_freeze(live)
        live = self.get(f"namespace/{name}")
        if not live:
            fail(f"namespace/{name} identity changed while admission was frozen.")
        validate_live(live, "while admission was frozen")
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
        installation = values.get("installation")
        nested_attempt = (
            installation.get("attemptId")
            if isinstance(installation, dict)
            else None
        )
        attempts = {
            attempt
            for attempt in (nested_attempt, values.get("installationAttempt"))
            if isinstance(attempt, str) and attempt
        }
        if attempts != {self.attempt}:
            fail("live Helm release does not match the OCC receipt attempt.")
        return True

    def cluster_resources(self):
        resources = [
            "validatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-policy",
            "mutatingwebhookconfigurations.admissionregistration.k8s.io/openclaw-enterprise-nitro-adapter",
            "validatingadmissionpolicybindings.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label",
            "validatingadmissionpolicies.admissionregistration.k8s.io/protect-openclaw-enterprise-namespace-label",
        ]
        resources += [
            f"clusterrolebinding.rbac.authorization.k8s.io/{self.a.release}-{name}"
            for name in ("openclaw-worker-namespaces", "openclaw-api-namespaces")
        ]
        resources += [
            f"clusterrole.rbac.authorization.k8s.io/{self.a.release}-{name}"
            for name in (
                "openclaw-namespace-observer", "openclaw-namespace-worker",
                "openclaw-tenant-worker", "openclaw-tenant-api",
                "openclaw-tenant-configuration", "openclaw-gateway-observer",
            )
        ]
        return resources

    def validate_cluster_resource(self, resource, item):
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
            and labels.get("app.kubernetes.io/instance", self.a.release) == self.a.release
            and annotations.get("meta.helm.sh/release-name") == self.a.release
            and annotations.get("meta.helm.sh/release-namespace") == self.a.namespace
        )
        if owner != OWNER and not helm_identity:
            fail(f"{resource} does not carry an exact cleanup ownership label.")

    def verify_cluster_resources(self):
        for resource in self.cluster_resources():
            item = self.get(resource)
            if not item:
                continue
            self.validate_cluster_resource(resource, item)

    def delete_cluster_resources(self):
        for resource in self.cluster_resources():
            item = self.get(resource)
            if not item:
                continue
            self.validate_cluster_resource(resource, item)
            self.raw_delete(item)

    def pod_action(self, preserve_gateway=False):
        if not self.pod:
            return None
        association = self.pod["podIdentityAssociation"]["created"]
        preserve_sa = (
            preserve_gateway
            or not self.pod["serviceAccount"]["created"]
            or not association
        )
        preserve_namespace = preserve_sa or not self.pod["regionConfigMap"]["created"]
        return (
            "delete-namespace"
            if self.pod["namespace"]["created"] and not preserve_namespace
            else "delete-service-account" if not preserve_sa
            else "preserve"
        )

    def validate_storage(self, deleting_tenants=()):
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
        deleting = set(deleting_tenants)
        if any(
            pvc.get("spec", {}).get("storageClassName") == STORAGE_CLASS
            and pvc.get("metadata", {}).get("namespace") not in deleting
            for pvc in pvcs.get("items", [])
        ):
            fail("storage class is still referenced by a persistent volume claim.")
        return item

    def validate_pod_kubernetes_resource(self, key, item, *, late=False):
        expected = self.pod[key]
        metadata = item.get("metadata", {})
        namespace = expected.get("namespace")
        valid = (
            item.get("apiVersion") == expected.get("apiVersion")
            and item.get("kind") == expected.get("kind")
            and metadata.get("name") == expected.get("name")
            and metadata.get("namespace") == namespace
            and metadata.get("uid") == expected.get("uid")
            and metadata.get("labels", {}).get(OWNER_KEY) == OWNER
        )
        if expected["created"]:
            valid = (
                valid
                and metadata.get("labels", {}).get(POD_SETUP_KEY)
                == self.pod["iamRole"].get("invocationId")
            )
        if not valid:
            label = f"{expected.get('kind')}/{expected.get('name')}"
            detail = " changed after cleanup preflight" if late else (
                " does not match its lifecycle receipt"
            )
            fail(f"{label}{detail}.")

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

    def delete_pod_identity_association(self):
        if not self.pod or not self.pod["podIdentityAssociation"]["created"]:
            return
        expected = self.pod["podIdentityAssociation"]
        result = self.association()
        if not result:
            return
        live = result.get("association", {})
        fields = (
            "associationId", "associationArn", "clusterName", "namespace",
            "serviceAccount", "roleArn", "targetRoleArn", "externalId",
            "disableSessionTags", "policy",
        )
        if any(live.get(key) != expected.get(key) for key in fields):
            fail("Pod Identity association does not match the lifecycle receipt identity.")
        self.aws(
            "eks", "delete-pod-identity-association",
            "--cluster-name", self.a.eks_cluster_name,
            "--association-id", self.a.pod_identity_association_id,
        )
        deadline = time.monotonic() + 300
        while True:
            result = self.association()
            if not result:
                return
            live = result.get("association", {})
            if any(live.get(key) != expected.get(key) for key in fields):
                fail("Pod Identity association was replaced while deletion was in progress.")
            if time.monotonic() >= deadline:
                fail("Pod Identity association still exists after deletion.")
            time.sleep(2)

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
        if policy["created"]:
            role = self.role()
            if role:
                self.validate_role(role)
                live_policy = self.aws_json(
                    "iam", "get-role-policy",
                    "--role-name", self.a.iam_role_name,
                    "--policy-name", self.a.iam_inline_policy_name,
                    absent=AWS_ABSENT,
                )
                if live_policy:
                    if (
                        digest(live_policy.get("PolicyDocument"))
                        != policy.get("documentSha256")
                    ):
                        fail("inline policy changed after cleanup preflight.")
                    self.aws(
                        "iam", "delete-role-policy",
                        "--role-name", self.a.iam_role_name,
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
        self.validate_local_credentials()
        self.recover_freeze()
        helm = self.helm_present()
        self.verify_cluster_resources()
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
        ]
        tenant_plans, tenant_targets = self.managed_tenant_namespaces()
        gateway_resources, preserve_gateway = self.gateway_plan()
        pod_action, agw_plan = self.pod_action(preserve_gateway), None
        service_account, region_config_map = None, None
        if pod_action == "delete-namespace":
            agw_plan = self.namespace_plan(
                AGW_NAMESPACE, OWNER, self.pod["namespace"]["uid"], True
            )
        elif pod_action == "delete-service-account":
            service_account = self.get(
                f"serviceaccount/{AGW_SERVICE_ACCOUNT}", AGW_NAMESPACE
            )
            if service_account:
                self.validate_pod_kubernetes_resource(
                    "serviceAccount", service_account
                )
        if pod_action != "delete-namespace" and self.pod:
            live_region_config_map = self.get(
                "configmap/agentgateway-aws-region", AGW_NAMESPACE
            )
            if live_region_config_map:
                receipt = self.pod["regionConfigMap"]
                self.validate_pod_kubernetes_resource(
                    "regionConfigMap", live_region_config_map
                )
                if not preserve_gateway and receipt["created"]:
                    region_config_map = live_region_config_map
        deleting_namespaces = [
            plan["metadata"]["name"] for plan in plans if plan
        ]
        if agw_plan:
            deleting_namespaces.append(agw_plan["metadata"]["name"])
        deleting_namespaces.extend(
            [item["name"] for item in tenant_targets]
            if self.a.delete_tenant_data
            else []
        )
        storage = self.validate_storage(deleting_namespaces)

        if self.a.delete_tenant_data:
            # Keep the tenant freeze active until the exact namespace UIDs and
            # their recorded storage have gone. The OCE release is removed
            # first so its controllers cannot recreate a deleted tenant.
            tenant_deletion = self.prepare_tenant_deletion(tenant_targets)
            self.ensure_tenant_freeze(tenant_plans, tenant_targets)
            tenant_plans = self.require_tenant_namespaces_unchanged(
                tenant_targets, allow_absent=self.tenant_deletion_exists()
            )
            if helm:
                run([
                    *self.h, "uninstall", self.a.release,
                    "--namespace", self.a.namespace, "--wait", "--timeout", "10m",
                ])
                helm = False
            self.delete_tenant_data(
                tenant_plans,
                tenant_targets,
                tenant_deletion,
            )

        # Remove the AWS identity binding before deleting its Kubernetes
        # ServiceAccount or namespace. A failed AWS deletion therefore leaves
        # the named Kubernetes identity intact and cannot silently transfer the
        # role to a later same-name ServiceAccount.
        if preserve_gateway:
            print(
                "Preserved the complete AgentGateway dependency closure: "
                "at least one lifecycle dependency was reused."
            )
        else:
            self.delete_pod_identity_association()
            self.delete_gateway_resources(gateway_resources)
        if helm:
            run([
                *self.h, "uninstall", self.a.release,
                "--namespace", self.a.namespace, "--wait", "--timeout", "10m",
            ])
        # No tenant namespace can survive removal of the original
        # cluster-scoped admission controls.
        if self.discover_managed_tenant_namespaces():
            fail(
                "managed tenant namespaces remain before admission teardown; "
                "refusing to continue."
            )
        self.admission_controls_dismantled = True
        self.delete_cluster_resources()
        for plan in plans:
            self.delete_namespace(plan)
        if service_account:
            live_service_account = self.get(
                f"serviceaccount/{AGW_SERVICE_ACCOUNT}", AGW_NAMESPACE
            )
            if live_service_account:
                self.validate_pod_kubernetes_resource(
                    "serviceAccount", live_service_account, late=True
                )
                self.raw_delete(live_service_account)
        if region_config_map:
            live_region_config_map = self.get(
                "configmap/agentgateway-aws-region", AGW_NAMESPACE
            )
            if live_region_config_map:
                self.validate_pod_kubernetes_resource(
                    "regionConfigMap", live_region_config_map, late=True
                )
                self.raw_delete(live_region_config_map)
        self.delete_namespace(agw_plan)
        if storage:
            if not self.storage:
                print(f"Preserved storageclass/{STORAGE_CLASS}: no lifecycle receipt.", file=sys.stderr)
                fail("cleanup is incomplete; review the preserved sample-owned resources.")
            if not self.storage["created"]:
                print(f"Preserved storageclass/{STORAGE_CLASS}: setup reused it.")
            else:
                storage = self.validate_storage()
                if storage:
                    self.raw_delete(storage)
        # Delete the policy and role last. If the caller lacks an IAM cleanup
        # permission, the Pod Identity association and Kubernetes workloads
        # have already been removed and a rerun can safely resume cleanup.
        if not preserve_gateway:
            self.delete_aws()
        if self.tenant_freeze_exists():
            fail(
                "tenant admission freeze remains after tenant data deletion; "
                "refusing to report successful cleanup."
            )
        self.remove_local_credentials()
        if self.a.delete_tenant_data and not self.a.tenant_validator_key_file:
            print(
                "No tenant validator key files were supplied; revoke each 30-day key "
                "and delete its validator-service-key.json file and backup copies."
            )
        print(f"Cleanup completed for release {self.a.release} in kube context {self.a.kube_context}.")


def main():
    cleanup = None
    try:
        args = parse_args()
        require_helm_3()
        cleanup = Cleanup(args)
        cleanup.run()
    except CleanupError as error:
        recovery_error = None
        if cleanup and cleanup.freeze_started:
            try:
                cleanup.recover_freeze()
            except CleanupError as nested:
                recovery_error = nested
        if (
            cleanup
            and cleanup.tenant_freeze_started
            and not cleanup.admission_controls_dismantled
        ):
            try:
                cleanup.recover_tenant_freeze()
            except CleanupError as nested:
                recovery_error = nested if recovery_error is None else CleanupError(
                    f"{recovery_error}; {nested}"
                )
        print(f"cleanup: {error}", file=sys.stderr)
        if recovery_error:
            print(f"cleanup: failed to remove admission freeze: {recovery_error}", file=sys.stderr)
        raise SystemExit(1)


main()
PY
