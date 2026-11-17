"""Offline structural checks on the deploy manifests, asserting issue #9 invariants.

No cluster or credentials: these parse the YAML and assert the shape the sample
promises. They are the static half of validation; the live run is the other
half (see the README).
"""

from __future__ import annotations

import copy
import pathlib
import posixpath
import re
import shlex

import pytest

from launcher import config

yaml = pytest.importorskip("yaml")

SAMPLE = pathlib.Path(__file__).resolve().parent.parent
DEPLOY = SAMPLE / "deploy"


def _load(name: str) -> list[dict]:
    docs = list(yaml.safe_load_all((DEPLOY / name).read_text()))
    return [d for d in docs if d]


def _by_kind(docs: list[dict], kind: str) -> list[dict]:
    return [d for d in docs if d.get("kind") == kind]


# --- AC #7: no Ingress, LoadBalancer or NodePort ------------------------------
def test_no_ingress_loadbalancer_or_nodeport():
    for path in DEPLOY.glob("*.yaml"):
        for doc in [d for d in yaml.safe_load_all(path.read_text()) if d]:
            assert doc.get("kind") != "Ingress", f"{path.name} has an Ingress"
            if doc.get("kind") == "Service":
                svc_type = doc["spec"].get("type", "ClusterIP")
                assert svc_type == "ClusterIP", f"{path.name} Service is {svc_type}"
                for port in doc["spec"].get("ports", []):
                    assert "nodePort" not in port, f"{path.name} Service sets a nodePort"


# --- AC #7: sandbox egress is exactly DNS + the two OpenAI hosts, and no ingress
def test_egress_allows_only_dns_and_the_two_openai_hosts():
    policy = _by_kind(_load("egress-policy.yaml"), "ApplicationNetworkPolicy")[0]
    spec = policy["spec"]
    assert set(spec["policyTypes"]) == {"Ingress", "Egress"}  # default-deny both ways

    hosts: set[str] = set()
    dns_ports: set[int] = set()
    for rule in spec["egress"]:
        for to in rule["to"]:
            hosts.update(to.get("domainNames", []))
            if "ipBlock" in to:  # the CoreDNS rule
                dns_ports.update(p["port"] for p in rule["ports"])
    assert hosts == {"api.openai.com", "codex-cloud-environments.chatgpt.com"}
    assert dns_ports == {53}


def test_sandbox_denies_all_ingress():
    # The launcher delivers the session through the claim env, not the network,
    # so the sandbox needs no ingress at all.
    policy = _by_kind(_load("egress-policy.yaml"), "ApplicationNetworkPolicy")[0]
    assert policy["spec"]["ingress"] == []


# --- CKV2_K8S_6: the ingress policy selects the launcher's own pods ----------
def _selects(selector: dict, labels: dict) -> bool:
    """A label selector with matchLabels only (what these files use) selects labels."""
    assert set(selector) <= {"matchLabels"}, "only matchLabels selectors are handled here"
    match = selector.get("matchLabels") or {}
    return bool(match) and all(labels.get(k) == v for k, v in match.items())


def _ingress_policy_covers_launcher(policy: dict, deployment: dict, service: dict) -> bool:
    """The CKV2_K8S_6 suppression's premise: the policy selects every launcher pod,
    and the Service's selector reaches only pods the policy selects."""
    pod_labels = deployment["spec"]["template"]["metadata"]["labels"]
    return (
        _selects(policy["spec"]["podSelector"], pod_labels)
        and _selects(deployment["spec"]["selector"], pod_labels)
        and all(pod_labels.get(k) == v for k, v in service["spec"]["selector"].items())
        and _selects(policy["spec"]["podSelector"], service["spec"]["selector"])
    )


def _launcher_objects() -> tuple[dict, dict, dict]:
    policy = _by_kind(_load("launcher-ingress.yaml"), "ApplicationNetworkPolicy")[0]
    docs = _load("launcher.yaml")
    return policy, _by_kind(docs, "Deployment")[0], _by_kind(docs, "Service")[0]


def test_launcher_ingress_policy_selects_the_launcher_pods_and_service():
    assert _ingress_policy_covers_launcher(*_launcher_objects())


@pytest.mark.parametrize("mutate", ["pod label", "policy selector", "service selector"])
def test_launcher_ingress_relation_check_rejects_a_mismatch(mutate):
    # The check above must fail on a mutated copy, or it proves nothing.
    policy, deployment, service = copy.deepcopy(_launcher_objects())
    if mutate == "pod label":
        deployment["spec"]["template"]["metadata"]["labels"]["app"] = "renamed-launcher"
    elif mutate == "policy selector":
        policy["spec"]["podSelector"]["matchLabels"]["app"] = "renamed-launcher"
    else:
        service["spec"]["selector"]["app"] = "renamed-launcher"
    assert not _ingress_policy_covers_launcher(policy, deployment, service)


# --- blocker 1: the launcher has a deny-by-default ingress policy -------------
def test_launcher_ingress_is_deny_by_default():
    policy = _by_kind(_load("launcher-ingress.yaml"), "ApplicationNetworkPolicy")[0]
    spec = policy["spec"]
    assert spec["podSelector"]["matchLabels"] == {"app": "openai-launcher"}
    assert spec["policyTypes"] == ["Ingress"]
    assert spec["ingress"] == []  # no in-cluster pod may reach the launcher


# --- AC #4/#5: the sandbox runs isolated and holds no key in its template -----
def test_sandbox_is_isolated_and_template_sets_no_key():
    template = _by_kind(_load("sandbox-template.yaml"), "SandboxTemplate")[0]
    pod = template["spec"]["podTemplate"]["spec"]
    assert pod["runtimeClassName"] == "isolated-sandbox"
    assert pod["automountServiceAccountToken"] is False
    container = pod["containers"][0]
    # The template declares NO env: a warm pod holds no key, and a claimed pod
    # gets its key from the claim env (set by the launcher), not the template.
    assert not container.get("env"), "the sandbox template must declare no env"
    sc = container["securityContext"]
    assert sc["readOnlyRootFilesystem"] is True
    assert sc["allowPrivilegeEscalation"] is False
    assert sc["capabilities"]["drop"] == ["ALL"]


def test_warm_pool_references_the_template():
    docs = _load("sandbox-template.yaml")
    pool = _by_kind(docs, "SandboxWarmPool")[0]
    template = _by_kind(docs, "SandboxTemplate")[0]
    assert pool["spec"]["sandboxTemplateRef"]["name"] == template["metadata"]["name"]
    assert pool["spec"]["replicas"] >= 1


def _launcher_pod() -> dict:
    return _by_kind(_load("launcher.yaml"), "Deployment")[0]["spec"]["template"]["spec"]


def _volume(pod: dict, mount_path: str) -> tuple[dict, dict]:
    """The container's volumeMount at mount_path and the pod volume it names."""
    container = pod["containers"][0]
    (mount,) = [m for m in container.get("volumeMounts", []) if m["mountPath"] == mount_path]
    (volume,) = [v for v in pod["volumes"] if v["name"] == mount["name"]]
    return mount, volume


# --- AC #5 + blocker 1: launcher holds the env key AND an intake auth token ---
# Both as files from their Secrets (CKV_K8S_35), never as environment variables.
def test_launcher_holds_env_key_and_auth_token_as_files_from_secrets():
    pod = _launcher_pod()
    env = {e["name"]: e for e in pod["containers"][0].get("env", [])}
    for name in ("OPENAI_EXECUTOR_API_KEY", "LAUNCHER_AUTH_TOKEN", "OPENAI_API_KEY"):
        assert name not in env, f"{name} must not be an environment variable"
    assert not any("secretKeyRef" in e.get("valueFrom", {}) for e in env.values())
    mount, volume = _volume(pod, config.LAUNCHER_CREDENTIALS_DIR)
    assert mount["readOnly"] is True
    files = {
        (source["secret"]["name"], item["key"], item["path"])
        for source in volume["projected"]["sources"]
        for item in source["secret"]["items"]
    }
    assert files == {
        ("openai-env-key", "OPENAI_EXECUTOR_API_KEY", "OPENAI_EXECUTOR_API_KEY"),
        ("launcher-auth", "LAUNCHER_AUTH_TOKEN", "LAUNCHER_AUTH_TOKEN"),
    }


# --- CKV_K8S_38: the ServiceAccount token is mounted by hand, for one hour ----
def test_launcher_mounts_its_service_account_token_explicitly():
    pod = _launcher_pod()
    assert pod["automountServiceAccountToken"] is False
    mount, volume = _volume(pod, "/var/run/secrets/kubernetes.io/serviceaccount")
    assert mount["readOnly"] is True
    sources = volume["projected"]["sources"]
    (token,) = [s["serviceAccountToken"] for s in sources if "serviceAccountToken" in s]
    assert token == {"path": "token", "expirationSeconds": 3600}
    (ca,) = [s["configMap"] for s in sources if "configMap" in s]
    assert ca == {"name": "kube-root-ca.crt", "items": [{"key": "ca.crt", "path": "ca.crt"}]}
    (ns,) = [s["downwardAPI"] for s in sources if "downwardAPI" in s]
    assert ns == {"items": [{"path": "namespace", "fieldRef": {"fieldPath": "metadata.namespace"}}]}


# --- CKV_K8S_8: a liveness probe that a hand-off cannot fail -----------------
def test_launcher_liveness_probe_is_the_intake_get_with_a_minute_of_grace():
    container = _launcher_pod()["containers"][0]
    probe = container["livenessProbe"]
    # GET / is the unauthenticated handler (launch.py, do_GET), answered on its
    # own thread; tests/test_launcher.py shows it answers during a hand-off.
    assert probe["httpGet"] == {"path": "/", "port": "intake"}
    assert {p["name"] for p in container["ports"]} == {"intake"}
    assert probe["timeoutSeconds"] >= 5
    assert probe["periodSeconds"] * probe["failureThreshold"] >= 60


# --- CKV_K8S_14: one image, at a fixed tag, in both roles ---------------------
def test_both_roles_use_the_same_image_at_a_fixed_tag():
    launcher = _launcher_pod()["containers"][0]
    template = _by_kind(_load("sandbox-template.yaml"), "SandboxTemplate")[0]
    executor = template["spec"]["podTemplate"]["spec"]["containers"][0]
    assert launcher["image"] == executor["image"]
    repository, _, tag = launcher["image"].rpartition(":")
    assert repository.endswith("/openai-sandbox-executor")
    assert tag and tag != "latest"
    assert launcher["imagePullPolicy"] == executor["imagePullPolicy"] == "IfNotPresent"


# --- CKV_K8S_40: both roles run as the image's own high UID ------------------
def test_both_roles_run_as_the_images_high_uid():
    dockerfile = (SAMPLE / "Dockerfile").read_text()
    (useradd,) = re.findall(r"^RUN useradd --uid (\d+) ", dockerfile, re.MULTILINE)
    (user,) = re.findall(r"^USER (\S+)$", dockerfile, re.MULTILINE)
    uid = int(useradd)
    assert uid >= 10000
    assert user == str(uid)
    assert _launcher_pod()["securityContext"]["runAsUser"] == uid
    template = _by_kind(_load("sandbox-template.yaml"), "SandboxTemplate")[0]
    sc = template["spec"]["podTemplate"]["spec"]["securityContext"]
    assert sc["runAsUser"] == sc["runAsGroup"] == sc["fsGroup"] == uid


# --- b6daf49: the launcher pod is not consolidated mid-hand-off ---------------
def test_launcher_do_not_disrupt_is_on_the_pod_template():
    # On the pod template, where Karpenter reads it; not on the Deployment's metadata.
    deploy = _by_kind(_load("launcher.yaml"), "Deployment")[0]
    annotations = deploy["spec"]["template"]["metadata"]["annotations"]
    assert annotations["karpenter.sh/do-not-disrupt"] == "true"


def test_launcher_service_is_clusterip():
    svc = _by_kind(_load("launcher.yaml"), "Service")[0]
    assert svc["spec"].get("type", "ClusterIP") == "ClusterIP"


# --- RBAC: the launcher may manage claims but not exec into pods --------------
def test_launcher_rbac_cannot_touch_pods():
    role = _by_kind(_load("rbac.yaml"), "Role")[0]
    resources = {r for rule in role["rules"] for r in rule["resources"]}
    assert "sandboxclaims" in resources
    assert "pods" not in resources
    assert "pods/exec" not in resources


# --- blocker 7: scripts are not referenced at an in-image path ----------------
def test_dockerfile_and_docs_do_not_claim_scripts_live_in_the_image():
    dockerfile = (SAMPLE / "Dockerfile").read_text()
    # The image copies only the launcher package, not scripts/.
    assert "COPY scripts" not in dockerfile
    # check-egress.py must not tell the operator to run it from an in-image path.
    check = (SAMPLE / "scripts" / "check-egress.py").read_text()
    assert "/app/scripts/check-egress.py" not in check


# --- the credential boundary the manifests and the image carry ----------------
# guard.py does not re-derive the launcher's projected volume at runtime, and it
# checks a sandbox's credentials path with one lstat. Both rest on the
# predicates below: each holds for the shipped files and fails for each
# mutation, and each mutation names exactly the predicates it must fail.
CREDENTIALS = config.LAUNCHER_CREDENTIALS_DIR
# The image's /var/run is a link to /run, so the path has two names.
_PROTECTED = (CREDENTIALS, "/run/secrets/openai-managed-agents")
_CONTAINER_CLASSES = ("containers", "initContainers", "ephemeralContainers")
_CREDENTIAL_ITEMS = {
    ("openai-env-key", "OPENAI_EXECUTOR_API_KEY"),
    ("launcher-auth", "LAUNCHER_AUTH_TOKEN"),
}
_CREDENTIAL_MOUNT = {"name": "launcher-credentials", "mountPath": CREDENTIALS, "readOnly": True}


def _components(path: str) -> tuple[str, ...]:
    return pathlib.PurePosixPath("/" + posixpath.normpath(path).lstrip("/")).parts


def _overlaps_protected(path: str) -> bool:
    """Equal to, above or below either name of the credentials path, by whole components."""
    parts = _components(path)
    for protected in map(_components, _PROTECTED):
        common = min(len(parts), len(protected))
        if parts[:common] == protected[:common]:
            return True
    return False


def _mounts(pod: dict):
    """Every volumeMount in every container class, with its container class."""
    for cls in _CONTAINER_CLASSES:
        for container in pod.get(cls) or []:
            for mount in container.get("volumeMounts") or []:
                yield cls, mount


def _one_container(pod: dict) -> bool:
    return len(pod.get("containers") or []) == 1 and not pod.get("initContainers") \
        and not pod.get("ephemeralContainers")


def _launcher_env_is_exact(pod: dict) -> bool:
    container = pod["containers"][0]
    env = container.get("env") or []
    return (
        sorted(e["name"] for e in env) == ["SANDBOX_NAMESPACE", "SANDBOX_WARMPOOL"]
        and "envFrom" not in container
        and not any("secretKeyRef" in (e.get("valueFrom") or {}) for e in env)
    )


def _launcher_credential_mount_is_exact(pod: dict) -> bool:
    at_path = [m for m in pod["containers"][0].get("volumeMounts") or []
               if _components(m["mountPath"]) == _components(CREDENTIALS)]
    return at_path == [_CREDENTIAL_MOUNT]


def _launcher_credential_volume_mounted_once(pod: dict) -> bool:
    return sum(m["name"] == "launcher-credentials" for _, m in _mounts(pod)) == 1


def _launcher_projection_is_exact(pod: dict) -> bool:
    volumes = [v for v in pod.get("volumes") or [] if v["name"] == "launcher-credentials"]
    if len(volumes) != 1 or set(volumes[0]) != {"name", "projected"}:
        return False
    projected = volumes[0]["projected"]
    sources = projected.get("sources") or []
    if set(projected) != {"sources"} or len(sources) != 2:
        return False
    seen = set()
    for source in sources:
        secret = source.get("secret")
        if set(source) != {"secret"} or not set(secret) <= {"name", "items", "optional"}:
            return False
        # optional: false is what the default already is; true would let the pod start without it.
        if secret.get("optional", False) is not False:
            return False
        items = secret.get("items") or []
        if len(items) != 1 or set(items[0]) != {"key", "path"}:
            return False
        key, path = items[0]["key"], items[0]["path"]
        if key != path or "/" in path:
            return False
        seen.add((secret.get("name"), key))
    return seen == _CREDENTIAL_ITEMS


def _launcher_nothing_else_overlaps(pod: dict) -> bool:
    # The first container mount at the path is the credential mount, whose own
    # shape "credential-mount" checks; every other mount must stay clear of it.
    others = list(_mounts(pod))
    for index, (cls, mount) in enumerate(others):
        if cls == "containers" and _components(mount["mountPath"]) == _components(CREDENTIALS):
            del others[index]
            break
    return not any(_overlaps_protected(m["mountPath"]) for _, m in others)


_LAUNCHER_PREDICATES = {
    "no-runtime-class": lambda pod: "runtimeClassName" not in pod,
    "one-container": _one_container,
    "env": _launcher_env_is_exact,
    "credential-mount": _launcher_credential_mount_is_exact,
    "mounted-once": _launcher_credential_volume_mounted_once,
    "projection": _launcher_projection_is_exact,
    "overlap": _launcher_nothing_else_overlaps,
    "service-account": lambda pod: pod.get("automountServiceAccountToken") is False,
}


def _sandbox_spec() -> dict:
    return _by_kind(_load("sandbox-template.yaml"), "SandboxTemplate")[0]["spec"]


def _sandbox_security_is_exact(spec: dict) -> bool:
    pod = spec["podTemplate"]["spec"]
    pod_sc, container_sc = pod.get("securityContext") or {}, pod["containers"][0].get("securityContext") or {}
    return (
        container_sc.get("readOnlyRootFilesystem") is True
        and pod_sc.get("runAsNonRoot") is True
        and pod_sc.get("runAsUser") == pod_sc.get("runAsGroup") == 10001
    )


def _sandbox_unchanged(spec: dict) -> bool:
    pod = spec["podTemplate"]["spec"]
    container = pod["containers"][0]
    return (
        pod.get("runtimeClassName") == "isolated-sandbox"
        and container.get("ports") == [{"name": "ready", "containerPort": 8080}]
        and container.get("readinessProbe", {}).get("tcpSocket") == {"port": "ready"}
        and spec.get("networkPolicyManagement") == "Unmanaged"
    )


_SANDBOX_PREDICATES = {
    "no-env": lambda spec: not any(
        c.get("env") or "envFrom" in c for c in spec["podTemplate"]["spec"]["containers"]),
    "injection": lambda spec: spec.get("envVarsInjectionPolicy") == "Allowed",
    "claim-templates": lambda spec: spec.get("volumeClaimTemplatesPolicy", "Disallowed") == "Disallowed"
    and not spec.get("volumeClaimTemplates"),
    "one-container": lambda spec: _one_container(spec["podTemplate"]["spec"]),
    "service-account": lambda spec: spec["podTemplate"]["spec"].get("automountServiceAccountToken") is False,
    "volumes": lambda spec: spec["podTemplate"]["spec"].get("volumes") == [
        {"name": "workspace", "emptyDir": {}}, {"name": "tmp", "emptyDir": {}}],
    "mounts": lambda spec: spec["podTemplate"]["spec"]["containers"][0].get("volumeMounts") == [
        {"name": "workspace", "mountPath": "/workspace"}, {"name": "tmp", "mountPath": "/tmp"}],
    "overlap": lambda spec: not any(
        _overlaps_protected(m["mountPath"]) for _, m in _mounts(spec["podTemplate"]["spec"])),
    "security": _sandbox_security_is_exact,
    "unchanged": _sandbox_unchanged,
}


def _failing(predicates: dict, obj: dict) -> set[str]:
    return {name for name, holds in predicates.items() if not holds(obj)}


@pytest.mark.parametrize("path", [
    CREDENTIALS, "/run/secrets/openai-managed-agents",   # either name, equal
    f"{CREDENTIALS}/extra", "/run/secrets/openai-managed-agents/x",   # below
    "/var/run/secrets", "/var/run", "/run", "/var", "/",   # above
    f"{CREDENTIALS}/", "//var/run/secrets/./openai-managed-agents", "/var/run/x/../secrets",   # spelled otherwise
])
def test_overlap_is_equal_ancestor_or_descendant(path):
    assert _overlaps_protected(path)


@pytest.mark.parametrize("path", [
    "/var/run/secrets/kubernetes.io/serviceaccount",   # the sibling the launcher mounts
    f"{CREDENTIALS}-extra", "/run/secrets/openai-managed-agents-extra",   # a longer name, not below it
    "/workspace", "/tmp", "/var/runner", "/var/run/secret",
])
def test_overlap_is_by_whole_components(path):
    assert not _overlaps_protected(path)


def test_the_shipped_launcher_meets_every_credential_predicate():
    assert _failing(_LAUNCHER_PREDICATES, _launcher_pod()) == set()


def test_the_shipped_sandbox_meets_every_credential_predicate():
    assert _failing(_SANDBOX_PREDICATES, _sandbox_spec()) == set()


def _source(pod, index):
    return [v for v in pod["volumes"] if v["name"] == "launcher-credentials"][0]["projected"]["sources"][index]


def _add_mount(pod, path, cls="containers", volume="scratch"):
    pod.setdefault("volumes", []).append({"name": "scratch", "emptyDir": {}})
    if cls == "containers":
        pod["containers"][0]["volumeMounts"].append({"name": volume, "mountPath": path})
    else:
        pod.setdefault(cls, []).append(
            {"name": "extra", "image": "x", "volumeMounts": [{"name": volume, "mountPath": path}]})


def _cred_mount(pod):
    return [m for m in pod["containers"][0]["volumeMounts"] if m["name"] == "launcher-credentials"][0]


_LAUNCHER_MUTATIONS = {
    "runtime-class": (lambda p: p.__setitem__("runtimeClassName", "isolated-sandbox"), {"no-runtime-class"}),
    "sidecar": (lambda p: p["containers"].append({"name": "sidecar", "image": "x"}), {"one-container"}),
    "init-container-mounting-the-credentials": (
        lambda p: _add_mount(p, CREDENTIALS, "initContainers", "launcher-credentials"),
        {"one-container", "mounted-once", "overlap"}),
    "ephemeral-container-at-the-alias": (
        lambda p: _add_mount(p, "/run/secrets", "ephemeralContainers"), {"one-container", "overlap"}),
    "init-container-above-the-path": (
        lambda p: _add_mount(p, "/var/run", "initContainers"), {"one-container", "overlap"}),
    "env-application-key": (
        lambda p: p["containers"][0]["env"].append({"name": "OPENAI_API_KEY", "value": "x"}), {"env"}),
    "env-empty-environment-key": (
        lambda p: p["containers"][0]["env"].append({"name": "OPENAI_EXECUTOR_API_KEY", "value": ""}), {"env"}),
    "env-from-a-secret": (
        lambda p: p["containers"][0]["env"][1].update(
            {"value": None, "valueFrom": {"secretKeyRef": {"name": "launcher-auth", "key": "x"}}}), {"env"}),
    "env-from": (lambda p: p["containers"][0].__setitem__("envFrom", [{"secretRef": {"name": "openai-env-key"}}]),
                 {"env"}),
    "read-only-false": (lambda p: _cred_mount(p).__setitem__("readOnly", False), {"credential-mount"}),
    "read-only-missing": (lambda p: _cred_mount(p).pop("readOnly"), {"credential-mount"}),
    "sub-path": (lambda p: _cred_mount(p).__setitem__("subPath", "OPENAI_EXECUTOR_API_KEY"), {"credential-mount"}),
    "sub-path-expr": (lambda p: _cred_mount(p).__setitem__("subPathExpr", "$(POD)"), {"credential-mount"}),
    "wrong-volume": (lambda p: _cred_mount(p).__setitem__("name", "kube-api-access"),
                     {"credential-mount", "mounted-once"}),
    "second-mount-of-the-volume": (
        lambda p: p["containers"][0]["volumeMounts"].append(
            {"name": "launcher-credentials", "mountPath": "/etc/credentials", "readOnly": True}),
        {"mounted-once"}),
    "second-mount-at-the-path": (lambda p: _add_mount(p, CREDENTIALS), {"credential-mount", "overlap"}),
    "below-the-path": (lambda p: _add_mount(p, f"{CREDENTIALS}/extra"), {"overlap"}),
    "above-the-path": (lambda p: _add_mount(p, "/var/run/secrets"), {"overlap"}),
    "at-the-alias": (lambda p: _add_mount(p, "/run/secrets/openai-managed-agents"), {"overlap"}),
    "at-var-run": (lambda p: _add_mount(p, "/var/run"), {"overlap"}),
    "beside-the-path": (lambda p: _add_mount(p, f"{CREDENTIALS}-extra"), set()),
    "volume-is-an-empty-dir": (
        lambda p: [v for v in p["volumes"] if v["name"] == "launcher-credentials"][0].update(
            {"projected": None, "emptyDir": {}}), {"projection"}),
    "third-source": (
        lambda p: [v for v in p["volumes"] if v["name"] == "launcher-credentials"][0]["projected"]["sources"].append(
            {"secret": {"name": "openai-app-key", "items": [{"key": "OPENAI_API_KEY", "path": "OPENAI_API_KEY"}]}}),
        {"projection"}),
    "second-item": (lambda p: _source(p, 0)["secret"]["items"].append({"key": "OPENAI_API_KEY", "path": "OPENAI_API_KEY"}),
                    {"projection"}),
    "source-removed": (
        lambda p: [v for v in p["volumes"] if v["name"] == "launcher-credentials"][0]["projected"]["sources"].pop(),
        {"projection"}),
    "item-removed": (lambda p: _source(p, 0)["secret"]["items"].clear(), {"projection"}),
    "items-missing": (lambda p: _source(p, 0)["secret"].pop("items"), {"projection"}),
    "optional-true": (lambda p: _source(p, 0)["secret"].__setitem__("optional", True), {"projection"}),
    "optional-false": (lambda p: _source(p, 0)["secret"].__setitem__("optional", False), set()),
    "wrong-secret": (lambda p: _source(p, 0)["secret"].__setitem__("name", "openai-app-key"), {"projection"}),
    "wrong-key": (lambda p: _source(p, 0)["secret"]["items"][0].__setitem__("key", "OPENAI_API_KEY"), {"projection"}),
    "wrong-path": (lambda p: _source(p, 0)["secret"]["items"][0].__setitem__("path", "OPENAI_API_KEY"), {"projection"}),
    "keys-swapped": (lambda p: (_source(p, 0)["secret"]["items"][0].update(
        {"key": "LAUNCHER_AUTH_TOKEN", "path": "LAUNCHER_AUTH_TOKEN"}), _source(p, 1)["secret"]["items"][0].update(
        {"key": "OPENAI_EXECUTOR_API_KEY", "path": "OPENAI_EXECUTOR_API_KEY"})), {"projection"}),
    "secret-names-swapped": (lambda p: (_source(p, 0)["secret"].__setitem__("name", "launcher-auth"),
                                        _source(p, 1)["secret"].__setitem__("name", "openai-env-key")),
                             {"projection"}),
    "nested-path": (lambda p: _source(p, 0)["secret"]["items"][0].update(
        {"key": "sub/OPENAI_EXECUTOR_API_KEY", "path": "sub/OPENAI_EXECUTOR_API_KEY"}), {"projection"}),
    "config-map-source": (lambda p: _source(p, 0).update({"configMap": {"name": "x"}}), {"projection"}),
    "downward-api-source": (
        lambda p: [v for v in p["volumes"] if v["name"] == "launcher-credentials"][0]["projected"]["sources"].__setitem__(
            1, {"downwardAPI": {"items": [{"path": "LAUNCHER_AUTH_TOKEN", "fieldRef": {"fieldPath": "metadata.name"}}]}}),
        {"projection"}),
    "token-automounted": (lambda p: p.__setitem__("automountServiceAccountToken", True), {"service-account"}),
}


@pytest.mark.parametrize("mutation", list(_LAUNCHER_MUTATIONS))
def test_each_launcher_mutation_fails_exactly_its_own_predicates(mutation):
    mutate, expected = _LAUNCHER_MUTATIONS[mutation]
    pod = copy.deepcopy(_launcher_pod())
    mutate(pod)
    assert _failing(_LAUNCHER_PREDICATES, pod) == expected


def _sandbox_pod(spec):
    return spec["podTemplate"]["spec"]


def _sandbox_add_container(spec, cls, path=None):
    container = {"name": "extra", "image": "x"}
    if path:
        container["volumeMounts"] = [{"name": "tmp", "mountPath": path}]
    _sandbox_pod(spec).setdefault(cls, []).append(container)


_SANDBOX_MUTATIONS = {
    "env-application-key": (
        lambda s: _sandbox_pod(s)["containers"][0].__setitem__("env", [{"name": "OPENAI_API_KEY", "value": "x"}]),
        {"no-env"}),
    "env-empty-codex-key": (
        lambda s: _sandbox_pod(s)["containers"][0].__setitem__("env", [{"name": "CODEX_API_KEY", "value": ""}]),
        {"no-env"}),
    "env-from": (lambda s: _sandbox_pod(s)["containers"][0].__setitem__(
        "envFrom", [{"secretRef": {"name": "openai-env-key"}}]), {"no-env"}),
    "injection-overrides": (lambda s: s.__setitem__("envVarsInjectionPolicy", "Overrides"), {"injection"}),
    "claim-templates-allowed": (lambda s: s.__setitem__("volumeClaimTemplatesPolicy", "Allowed"), {"claim-templates"}),
    "claim-templates-disallowed": (lambda s: s.__setitem__("volumeClaimTemplatesPolicy", "Disallowed"), set()),
    "claim-template-entry": (lambda s: s.__setitem__("volumeClaimTemplates", [{"metadata": {"name": "w"}}]),
                             {"claim-templates"}),
    "sidecar-at-the-path": (lambda s: _sandbox_add_container(s, "containers", CREDENTIALS),
                            {"one-container", "overlap"}),
    "init-container": (lambda s: _sandbox_add_container(s, "initContainers"), {"one-container"}),
    "ephemeral-container-at-the-alias": (
        lambda s: _sandbox_add_container(s, "ephemeralContainers", "/run/secrets/openai-managed-agents"),
        {"one-container", "overlap"}),
    "mount-at-the-path": (lambda s: _sandbox_pod(s)["containers"][0]["volumeMounts"].append(
        {"name": "tmp", "mountPath": CREDENTIALS}), {"mounts", "overlap"}),
    "mount-above-the-path": (lambda s: _sandbox_pod(s)["containers"][0]["volumeMounts"].append(
        {"name": "tmp", "mountPath": "/var/run/secrets"}), {"mounts", "overlap"}),
    "mount-below-the-alias": (lambda s: _sandbox_pod(s)["containers"][0]["volumeMounts"].append(
        {"name": "tmp", "mountPath": "/run/secrets/openai-managed-agents/x"}), {"mounts", "overlap"}),
    "projected-volume-unmounted": (lambda s: _sandbox_pod(s)["volumes"].append(
        {"name": "creds", "projected": {"sources": []}}), {"volumes"}),
    "token-automounted": (lambda s: _sandbox_pod(s).__setitem__("automountServiceAccountToken", True),
                          {"service-account"}),
    "writable-root": (lambda s: _sandbox_pod(s)["containers"][0]["securityContext"].__setitem__(
        "readOnlyRootFilesystem", False), {"security"}),
    "root-user": (lambda s: _sandbox_pod(s)["securityContext"].__setitem__("runAsUser", 0), {"security"}),
    "run-as-non-root-off": (lambda s: _sandbox_pod(s)["securityContext"].__setitem__("runAsNonRoot", False),
                            {"security"}),
    "no-runtime-class": (lambda s: _sandbox_pod(s).pop("runtimeClassName"), {"unchanged"}),
    "second-port": (lambda s: _sandbox_pod(s)["containers"][0]["ports"].append(
        {"name": "intake", "containerPort": 9000}), {"unchanged"}),
    "managed-network-policy": (lambda s: s.__setitem__("networkPolicyManagement", "Managed"), {"unchanged"}),
}


@pytest.mark.parametrize("mutation", list(_SANDBOX_MUTATIONS))
def test_each_sandbox_mutation_fails_exactly_its_own_predicates(mutation):
    mutate, expected = _SANDBOX_MUTATIONS[mutation]
    spec = copy.deepcopy(_sandbox_spec())
    mutate(spec)
    assert _failing(_SANDBOX_PREDICATES, spec) == expected


# --- the image sets no credential or claim name and creates no credentials path
_IMAGE_REFUSED_NAMES = {
    "OPENAI_API_KEY", "OPENAI_EXECUTOR_API_KEY", "LAUNCHER_AUTH_TOKEN",
    "CODEX_API_KEY", "OPENAI_SESSION_ID", "OPENAI_ENVIRONMENT_ID", "OPENAI_REMOTE_URL",
}


def _instructions(dockerfile: str) -> list[tuple[str, str]]:
    """The Dockerfile's (instruction, arguments), comments dropped and continuation lines joined."""
    instructions, current = [], ""
    for line in dockerfile.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue  # a comment, also between continuation lines, is not part of the instruction
        if stripped.endswith("\\"):
            current += stripped[:-1] + " "
            continue
        keyword, _, arguments = (current + stripped).partition(" ")
        instructions.append((keyword.upper(), arguments.strip()))
        current = ""
    return instructions


def _declared_names(instructions: list[tuple[str, str]]) -> set[str]:
    names = set()
    for keyword, arguments in instructions:
        tokens = shlex.split(arguments)
        if keyword == "ARG" or (keyword == "ENV" and tokens and "=" in tokens[0]):
            names.update(token.split("=", 1)[0] for token in tokens)
        elif keyword == "ENV" and tokens:
            names.add(tokens[0])  # the legacy form, ENV NAME value
    return names


_IMAGE_PREDICATES = {
    "image-env": lambda text: not _declared_names(_instructions(text)) & _IMAGE_REFUSED_NAMES,
    "image-path": lambda text: not any("/run/secrets" in arguments for _, arguments in _instructions(text)),
}


def _dockerfile() -> str:
    return (SAMPLE / "Dockerfile").read_text()


def test_the_shipped_image_meets_every_credential_predicate():
    assert _failing(_IMAGE_PREDICATES, _dockerfile()) == set()
    assert {"HOME", "CODEX_HOME", "CODEX_PATH", "CODEX_VERSION"} <= _declared_names(_instructions(_dockerfile()))


_LAST_ENV = f"CODEX_PATH={config.DEFAULT_CODEX_PATH}"
_IMAGE_MUTATIONS = {
    "env-application-key": (lambda t: t + "ENV OPENAI_API_KEY=x\n", {"image-env"}),
    "env-in-the-continued-block": (
        lambda t: t.replace(_LAST_ENV, _LAST_ENV + " \\\n    CODEX_API_KEY="), {"image-env"}),
    "legacy-env": (lambda t: t + "ENV LAUNCHER_AUTH_TOKEN value\n", {"image-env"}),
    "arg-session": (lambda t: t + "ARG OPENAI_SESSION_ID\n", {"image-env"}),
    "credentials-path": (lambda t: t + "RUN mkdir -p /var/run/secrets/openai-managed-agents\n", {"image-path"}),
    "comment-only": (lambda t: t + "# ENV OPENAI_API_KEY=x /var/run/secrets/openai-managed-agents\n", set()),
    "base-url": (lambda t: t + "ENV OPENAI_BASE_URL=https://api.openai.com/v1\n", set()),
}


@pytest.mark.parametrize("mutation", list(_IMAGE_MUTATIONS))
def test_each_image_mutation_fails_exactly_its_own_predicates(mutation):
    mutate, expected = _IMAGE_MUTATIONS[mutation]
    text = mutate(_dockerfile())
    assert text != _dockerfile()
    assert _failing(_IMAGE_PREDICATES, text) == expected
