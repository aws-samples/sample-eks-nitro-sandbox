#!/usr/bin/env python3
"""Verify the observed analyst pod before running the controller."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import strict_json


def verify(pod, mode, image, *, namespace, region, bucket, role, model):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    require(mode in ("eks", "nitro"), "unknown deployment mode")
    require(bool(image), "the setup record has no analyst image")
    expected = {"AWS_REGION": region, "AWS_DEFAULT_REGION": region,
                "ANALYST_BUCKET": bucket, "ANALYST_ROLE_NAME": role, "BEDROCK_MODEL_ID": model,
                "EXPERIMENTAL_LINUX_SUPPORT": "TRUE",
                "SUPPLIER_API_URL": f"http://supplier-api.{namespace}.svc.cluster.local:8080",
                "SUPPLIER_ALIAS_URL": f"http://supplier-api-alias.{namespace}.svc.cluster.local:8080"}
    require(all(isinstance(value, str) and value for value in (namespace, region, bucket, role, model)),
            "the saved namespace, Region, bucket, role and model are required")
    metadata = pod.get("metadata", {})
    require(metadata.get("name") == "analyst" and metadata.get("namespace") == namespace,
            "the analyst pod name or namespace does not match the setup record")
    spec = pod["spec"]
    require(spec.get("serviceAccountName") == "analyst", "analyst must use the saved analyst service account")
    require(spec.get("automountServiceAccountToken") is False, "analyst must disable the default service-account token mount")
    containers = spec.get("containers", [])
    require(len(containers) == 1 and containers[0].get("name") == "analyst",
            "expected exactly one analyst container")
    app = containers[0]
    require(app.get("image") == image, "the analyst image does not match the setup record")
    require(not app.get("envFrom"), "analyst must not import an unverified environment")
    environment = app.get("env", [])
    require(isinstance(environment, list), "analyst environment is not a list")
    names = [entry.get("name") for entry in environment]
    require(all(isinstance(name, str) and name for name in names) and len(set(names)) == len(names),
            "analyst has an invalid or duplicate environment name")
    entries = {entry["name"]: entry for entry in environment}
    require(not {"SUPPLIER_CA_FILE", "SUPPLIER_KEY_FILE", "SUPPLIER_API_KEY", "SUPPLIER_TLS_DIR"}.intersection(entries),
            "the synthetic HTTP fixture must not mount supplier credentials or TLS configuration")
    require(not any("secret" in volume or volume.get("name") in ("supplier-key", "supplier-ca", "supplier-tls")
                    for volume in spec.get("volumes", [])),
            "the synthetic HTTP fixture must not mount supplier secrets")
    for name, value in expected.items():
        entry = entries.get(name, {})
        require(entry.get("value") == value and "valueFrom" not in entry,
                f"analyst environment {name} does not match the saved setup target")
    require(bool(spec.get("nodeName")), "analyst has no assigned worker node")
    require(spec.get("nodeSelector", {}).get("kubernetes.io/arch") == "arm64",
            "analyst must select an ARM64 worker")
    require(not any(spec.get(name, False) for name in ("hostNetwork", "hostPID", "hostIPC")),
            "analyst must not share host network, process, or IPC namespaces")
    require(not spec.get("ephemeralContainers"), "analyst has an unexpected ephemeral container")
    require(not any("hostPath" in volume for volume in spec.get("volumes", [])),
            "analyst must not mount a host path")
    pod_security = spec.get("securityContext", {})
    security = app.get("securityContext", {})
    effective = {**pod_security, **security}
    require(effective.get("runAsUser") == 1000 and effective.get("runAsGroup") == 1000,
            "analyst must use UID and GID 1000")
    require(effective.get("runAsNonRoot") is True, "analyst must require a non-root user")
    require(security.get("readOnlyRootFilesystem") is True, "analyst must use a read-only container root filesystem")
    require(pod_security.get("fsGroup") == 1000, "analyst volumes must use group 1000")
    runtime = spec.get("runtimeClassName")
    if mode == "eks":
        require(runtime in (None, ""), "ordinary EKS must not select a runtime class")
        require(spec.get("hostUsers") is False, "ordinary EKS requires hostUsers: false")
        require(not spec.get("initContainers"), "ordinary EKS must not run guest preparation init containers")
        require(security.get("privileged") is False, "ordinary EKS analyst must be nonprivileged")
        require(security.get("allowPrivilegeEscalation") is False,
                "ordinary EKS must disable privilege escalation")
        capabilities = security.get("capabilities", {})
        require(capabilities.get("drop") == ["ALL"] and not capabilities.get("add"),
                "ordinary EKS must drop all capabilities and add none")
        require(effective.get("seccompProfile", {}).get("type") == "Unconfined",
                "ordinary EKS requires the tested Unconfined outer seccomp profile")
        require(security.get("procMount") == "Unmasked", "ordinary EKS requires procMount: Unmasked")
    else:
        require(runtime == "isolated-sandbox", "analyst is not using the isolated-sandbox runtime")
        require(spec.get("hostUsers") is not False, "Nitro must not use hostUsers: false")
        require(security.get("privileged") is True, "the Nitro analyst requires privileged: true")
        preparations = spec.get("initContainers", [])
        require(len(preparations) == 1 and preparations[0].get("name") == "prepare-guest-user-namespaces",
                "Nitro requires exactly the declared guest preparation init container")
        preparation = preparations[0]
        require(preparation.get("image") == image, "the Nitro preparation image does not match the setup record")
        require(preparation.get("command") == ["sh", "-c", "printf '1024\n' > /proc/sys/user/max_user_namespaces"]
                and not preparation.get("args"), "the Nitro preparation command differs from the sample manifest")
        preparation_security = preparation.get("securityContext", {})
        require(set(preparation_security) == {"privileged", "runAsUser", "runAsNonRoot", "readOnlyRootFilesystem"}
                and preparation_security.get("privileged") is True
                and type(preparation_security.get("runAsUser")) is int
                and preparation_security["runAsUser"] == 0
                and preparation_security.get("readOnlyRootFilesystem") is True
                and preparation_security.get("runAsNonRoot") is False,
                "the Nitro preparation security settings differ from the sample manifest")
    return {"deployment_mode": mode, "pod_name": pod.get("metadata", {}).get("name"),
            "pod_uid": metadata.get("uid"), "namespace": namespace, "service_account": "analyst",
            "target_environment": expected, "worker_node": spec["nodeName"],
            "image": image, "runtime_class": runtime, "host_users": spec.get("hostUsers"),
            "pod_security_context": pod_security, "container_security_context": security}


if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        for name in ("mode", "image", "namespace", "region", "bucket", "role", "model"):
            parser.add_argument("--" + name, required=True)
        arguments = vars(parser.parse_args())
        print(json.dumps(verify(strict_json.load(sys.stdin), **arguments), indent=2))
    except (ValueError, KeyError, TypeError, IndexError, AttributeError) as error:
        sys.exit(f"Deployment verification failed: {error}")
