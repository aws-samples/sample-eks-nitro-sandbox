"""Offline structural checks on the deploy manifests, asserting issue #9 invariants.

No cluster or credentials: these parse the YAML and assert the shape the sample
promises. They are the static half of validation; the live run is the other
half (see the README).
"""

from __future__ import annotations

import pathlib

import pytest

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


# --- AC #5 + blocker 1: launcher holds the env key AND an intake auth token ---
def test_launcher_holds_env_key_and_auth_token_from_secrets():
    deploy = _by_kind(_load("launcher.yaml"), "Deployment")[0]
    container = deploy["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e for e in container["env"]}
    assert "secretKeyRef" in env["OPENAI_EXECUTOR_API_KEY"]["valueFrom"]
    assert "secretKeyRef" in env["LAUNCHER_AUTH_TOKEN"]["valueFrom"]
    # The launcher never holds the application key.
    assert "OPENAI_API_KEY" not in env


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
