"""Offline structural checks on the deploy manifests, asserting issue #9 invariants.

No cluster or credentials: these parse the YAML and assert the shape the sample
promises. They are the static half of validation; the live run is the other
half (see the README).
"""

from __future__ import annotations

import copy
import pathlib
import re

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
