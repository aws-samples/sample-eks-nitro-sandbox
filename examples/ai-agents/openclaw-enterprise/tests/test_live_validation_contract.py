from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
import textwrap
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "validate-live.sh"
DIGEST = "a" * 64
RUNTIME_IMAGE = f"registry.example/oce-runtime@sha256:{DIGEST}"
OCE_SOURCE_REVISION = "86c8c12310f691bb21651118ffffd6bfd460e9ff"


FAKE_COMMAND = textwrap.dedent(
    f"""\
    #!/usr/bin/env python3
    import base64
    import http.server
    import json
    import os
    import re
    import signal
    import sys
    from pathlib import Path

    tool = Path(sys.argv[0]).name
    args = sys.argv[1:]
    state_dir = Path(os.environ["FAKE_STATE_DIR"])
    scenario = os.environ.get("FAKE_SCENARIO", "pass")
    log_path = state_dir / "commands.jsonl"
    with log_path.open("a") as log:
        log.write(json.dumps({{"tool": tool, "args": args}}) + "\\n")

    digest = "{DIGEST}"
    image = "registry.example/oce-runtime@sha256:" + digest

    def emit(value):
        if isinstance(value, (dict, list)):
            print(json.dumps(value))
        else:
            print(value)

    def pod(
        namespace, name, uid, app_name, oce_namespace, agent_id, replica_set,
        revision, pvc_name,
    ):
        return {{
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {{
                "name": name,
                "namespace": namespace,
                "uid": uid,
                "labels": {{
                    "app.kubernetes.io/managed-by": "openclaw-enterprise",
                    "app.kubernetes.io/name": app_name,
                    "openclaw.dev/workload-role": "gateway",
                    "openclaw.dev/namespace": oce_namespace,
                    "openclaw.dev/agent": agent_id,
                    "openclaw.dev/revision": revision,
                }},
                "annotations": {{}},
                "ownerReferences": [{{
                    "apiVersion": "apps/v1",
                    "kind": "ReplicaSet",
                    "name": replica_set,
                    "uid": "rs-uid-" + uid,
                    "controller": True,
                }}],
            }},
            "spec": {{
                "runtimeClassName": "isolated-sandbox",
                "automountServiceAccountToken": False,
                "serviceAccountName": "agent-" + namespace,
                "containers": [{{
                    "name": "gateway",
                    "image": image,
                    "securityContext": {{
                        "allowPrivilegeEscalation": False,
                        "privileged": False,
                        "readOnlyRootFilesystem": True,
                        "runAsNonRoot": True,
                        "runAsUser": 1000,
                        "runAsGroup": 1000,
                        "seccompProfile": {{"type": "RuntimeDefault"}},
                        "capabilities": {{"drop": ["ALL"]}},
                    }},
                    "env": [{{"name": "OPENAI_API_KEY", "valueFrom": {{
                        "secretKeyRef": {{"name": "gateway-key", "key": "key"}}
                    }}}}],
                    "volumeMounts": [{{
                        "name": "persistent-home",
                        "mountPath": "/home/node/.openclaw",
                    }}],
                }}],
                "volumes": [
                    {{
                        "name": "oce-token",
                        "projected": {{"sources": [{{
                            "serviceAccountToken": {{
                                "audience": "openclaw-enterprise",
                                "expirationSeconds": 900,
                                "path": "token",
                            }}
                        }}]}},
                    }},
                    {{
                        "name": "persistent-home",
                        "persistentVolumeClaim": {{"claimName": pvc_name}},
                    }},
                ],
            }},
            "status": {{
                "phase": "Running",
                "containerStatuses": [{{
                    "name": "gateway",
                    "ready": True,
                    "state": {{"running": {{"startedAt": "2026-01-01T00:00:00Z"}}}},
                    "imageID": "containerd://sha256:" + digest,
                }}],
            }},
        }}

    pod_a = pod(
        "tenant-a-k8s", "tenant-a-pod", "uid-a-old", "gateway-aaaaaaaaaaaa",
        "ns_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "agt_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "rs-a",
        "rev_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "pvc-a",
    )
    pod_a_new = pod(
        "tenant-a-k8s", "tenant-a-replacement", "uid-a-new", "gateway-aaaaaaaaaaaa",
        "ns_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "agt_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "rs-a",
        "rev_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "pvc-a",
    )
    pod_b = pod(
        "tenant-b-k8s", "tenant-b-pod", "uid-b", "gateway-bbbbbbbbbbbb",
        "ns_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "agt_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "rs-b",
        "rev_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "pvc-b",
    )

    def cross_probe(name, include_uid=True):
        phase = "Running" if scenario == "cross_tenant_pvc_mounted" else "Pending"
        statuses = [{{
            "name": "cross-tenant-pvc",
            "ready": True,
            "state": {{"running": {{}}}},
        }}] if phase == "Running" else []
        metadata = {{
            "name": name,
            "namespace": "tenant-a-k8s",
            "labels": {{"openclaw.dev/validation": "cross-tenant-pvc"}},
        }}
        if include_uid:
            metadata["uid"] = "uid-cross-pvc"
        return {{
            "metadata": metadata,
            "spec": {{
                "containers": [{{
                    "name": "cross-tenant-pvc",
                    "image": image,
                    "command": ["sh", "-c", "sleep 3600"],
                    "volumeMounts": [{{
                        "name": "cross-tenant-pvc",
                        "mountPath": "/cross-tenant",
                    }}],
                }}],
                "volumes": [{{
                    "name": "cross-tenant-pvc",
                    "persistentVolumeClaim": {{"claimName": "pvc-b"}},
                }}],
                "automountServiceAccountToken": False,
                "enableServiceLinks": False,
                "restartPolicy": "Never",
            }},
            "status": {{
                "phase": phase,
                "containerStatuses": statuses,
            }},
        }}

    def pvc(namespace, name, uid, pv_name):
        return {{
            "metadata": {{"namespace": namespace, "name": name, "uid": uid}},
            "spec": {{"storageClassName": "gp3-oce", "volumeName": pv_name}},
            "status": {{"phase": "Bound"}},
        }}

    def pv(name, uid, namespace, pvc_name, pvc_uid, volume_handle):
        return {{
            "metadata": {{"name": name, "uid": uid}},
            "spec": {{
                "storageClassName": "gp3-oce",
                "claimRef": {{
                    "namespace": namespace,
                    "name": pvc_name,
                    "uid": pvc_uid,
                }},
                "csi": {{
                    "driver": "ebs.csi.aws.com",
                    "volumeHandle": volume_handle,
                }},
            }},
        }}

    pvc_a = pvc("tenant-a-k8s", "pvc-a", "pvc-uid-a", "pv-a")
    pvc_b = pvc("tenant-b-k8s", "pvc-b", "pvc-uid-b", "pv-b")
    pv_a = pv(
        "pv-a", "pv-uid-a", "tenant-a-k8s", "pvc-a", "pvc-uid-a",
        "vol-tenant-a-secret",
    )
    pv_b = pv(
        "pv-b", "pv-uid-b", "tenant-b-k8s", "pvc-b", "pvc-uid-b",
        "vol-tenant-b-secret",
    )

    if tool == "aws":
        if args == ["--version"]:
            emit("aws-cli/2.31.0 Python/3.13.7 Darwin/25.1.0 source/arm64")
        elif args[:2] == ["sts", "get-caller-identity"]:
            emit({{"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/fake"}})
        elif args[:2] == ["eks", "describe-cluster"]:
            emit({{"cluster": {{
                "name": "explicit-cluster",
                "status": "ACTIVE",
                "arn": (
                    "arn:aws:eks:us-west-2:123456789012:cluster/wrong-cluster"
                    if scenario == "wrong_cluster_arn"
                    else "arn:aws:eks:us-west-2:123456789012:cluster/explicit-cluster"
                ),
                "endpoint": "https://eks.example.invalid",
            }}}})
        elif args[:2] == ["eks", "list-pod-identity-associations"]:
            emit({{"associations": []}})
        elif args[:2] == ["kms", "get-public-key"]:
            emit({{
                "KeyId": "arn:aws:kms:us-west-2:123456789012:key/fake-evidence-key",
                "KeyUsage": "SIGN_VERIFY",
                "SigningAlgorithms": ["RSASSA_PSS_SHA_256"],
            }})
        elif args[:2] == ["kms", "sign"]:
            emit({{
                "KeyId": "arn:aws:kms:us-west-2:123456789012:key/fake-evidence-key",
                "Signature": base64.b64encode(b"fake-kms-signature").decode(),
            }})
        elif args[:2] == ["kms", "verify"]:
            emit({{
                "KeyId": "arn:aws:kms:us-west-2:123456789012:key/fake-evidence-key",
                "SignatureValid": scenario != "kms_verify_failure",
            }})
        else:
            print("unsupported fake aws command", args, file=sys.stderr)
            sys.exit(90)
        sys.exit(0)

    if tool != "kubectl":
        sys.exit(92)

    if args[:1] != ["--context"] or args[1] != "explicit-context":
        print("missing explicit context", file=sys.stderr)
        sys.exit(93)
    args = args[2:]

    if args == ["version", "--client", "-o", "json"]:
        emit({{"clientVersion": {{
            "gitVersion": "v1.34.0",
            "platform": "darwin/arm64",
        }}}})
        sys.exit(0)
    if args[:2] == ["config", "get-contexts"]:
        emit("explicit-context")
        sys.exit(0)
    if args[:2] == ["config", "view"]:
        emit({{"clusters": [{{"cluster": {{"server": "https://eks.example.invalid"}}}}]}})
        sys.exit(0)
    if args == ["get", "--raw=/readyz"]:
        emit("ok")
        sys.exit(0)
    if args[:3] == ["get", "nodeclass", "default"]:
        emit({{"spec": {{"networkPolicy": "DefaultAllow"}}}})
        sys.exit(0)
    if args[:2] == ["get", "namespace"]:
        sys.exit(1)
    if args[:2] == ["create", "namespace"]:
        (state_dir / "network_namespace").write_text(args[2])
        sys.exit(0)
    if args[:2] == ["label", "namespace"]:
        sys.exit(0)
    if args[:2] == ["delete", "namespace"]:
        (state_dir / "network_namespace").unlink(missing_ok=True)
        sys.exit(0)

    namespace = None
    if args[:1] == ["-n"]:
        namespace = args[1]
        args = args[2:]

    if args[:2] == ["get", "persistentvolumeclaim"]:
        name = args[2]
        if namespace == "tenant-a-k8s" and name == "pvc-a":
            emit(pvc_a)
            sys.exit(0)
        if namespace == "tenant-b-k8s" and name == "pvc-b":
            emit(pvc_b)
            sys.exit(0)
        print(
            f'Error from server (NotFound): persistentvolumeclaims "{{name}}" not found',
            file=sys.stderr,
        )
        sys.exit(1)
    if args[:2] == ["get", "persistentvolume"]:
        name = args[2]
        if name == "pv-a":
            emit(pv_a)
        elif name == "pv-b":
            emit(pv_b)
        else:
            sys.exit(1)
        sys.exit(0)
    if args[:2] == ["get", "events"]:
        cross_name_file = state_dir / "cross_pvc_pod"
        if not cross_name_file.exists():
            emit({{"items": []}})
        elif scenario == "cross_tenant_pvc_mounted":
            emit({{"items": []}})
        else:
            emit({{"items": [{{
                "reason": "FailedScheduling",
                "message": 'persistentvolumeclaim "pvc-b" not found',
            }}]}})
        sys.exit(0)
    if args[:2] == ["get", "pod"] and "-o" in args:
        name = args[2]
        if name == "oce-live-validation-spoof":
            sys.exit(1)
        if name == "tenant-a-pod":
            emit(pod_a)
        elif name == "tenant-a-replacement":
            emit(pod_a_new)
        elif name == "tenant-b-pod":
            emit(pod_b)
        elif (
            (state_dir / "cross_pvc_pod").exists()
            and name == (state_dir / "cross_pvc_pod").read_text()
        ):
            emit(cross_probe(name))
        else:
            sys.exit(94)
        sys.exit(0)

    if args[:2] == ["get", "serviceaccount"]:
        emit({{
            "metadata": {{"annotations": {{}}}},
            "automountServiceAccountToken": False,
        }})
        sys.exit(0)

    if namespace == "kube-system" and args[:3] == ["get", "configmap", "amazon-vpc-cni"]:
        emit({{"data": {{
            "enable-network-policy-controller": "true",
        }}}})
        sys.exit(0)

    if namespace == "openclaw-enterprise-agw" and args[:3] == ["get", "deployment", "agentgateway"]:
        emit({{
            "metadata": {{"generation": 4}},
            "spec": {{"template": {{"spec": {{"containers": [{{
                "name": "agentgateway",
                "readinessProbe": {{"httpGet": {{
                    "path": "/healthz/ready", "port": "health"
                }}}},
            }}]}}}}}},
            "status": {{
                "observedGeneration": 4,
                "replicas": 2,
                "updatedReplicas": 2,
                "readyReplicas": 2,
                "availableReplicas": 2,
            }},
        }})
        sys.exit(0)
    if namespace == "openclaw-enterprise-agw" and args[:2] == ["get", "pods"]:
        status = {{
            "phase": "Running",
            "containerStatuses": [{{
                "name": "agentgateway",
                "ready": True,
                "state": {{"running": {{}}}},
                "imageID": "containerd://sha256:" + ("b" * 64),
            }}],
        }}
        spec = {{"containers": [{{"name": "agentgateway"}}]}}
        emit({{"items": [
            {{"metadata": {{"uid": "uid-agw-1"}}, "spec": spec, "status": status}},
            {{"metadata": {{"uid": "uid-agw-2"}}, "spec": spec, "status": status}},
        ]}})
        sys.exit(0)
    if namespace == "oce-system" and args[:2] == ["get", "pods"]:
        emit({{"items": [{{
            "metadata": {{"uid": "uid-oce-api-1"}},
            "spec": {{"containers": [{{"name": "api"}}]}},
            "status": {{
                "phase": "Running",
                "containerStatuses": [{{
                    "name": "api",
                    "ready": True,
                    "state": {{"running": {{}}}},
                    "imageID": "containerd://sha256:" + ("c" * 64),
                }}],
            }},
        }}]}})
        sys.exit(0)

    if args[:1] == ["port-forward"]:
        if (
            namespace != "oce-system"
            or args[1:3] != ["--address=127.0.0.1", "service/openclaw-enterprise-api"]
            or len(args) != 4
        ):
            print("invalid OCE API port-forward", file=sys.stderr)
            sys.exit(100)
        local_port, remote_port = args[3].split(":", 1)
        if remote_port != "8080":
            print("invalid OCE API service port", file=sys.stderr)
            sys.exit(100)
        if scenario == "port_forward_early_exit":
            sys.exit(101)

        class OCEHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/console/":
                    revision = (
                        "f" * 40
                        if scenario == "wrong_oce_revision"
                        else "{OCE_SOURCE_REVISION}"
                    )
                    response = (
                        '<!doctype html><html><head>'
                        f'<meta name="occ-build-revision" content="{{revision}}" />'
                        '</head><body></body></html>'
                    ).encode()
                    self.send_response(200)
                    self.send_header("content-type", "text/html; charset=utf-8")
                    self.send_header("content-length", str(len(response)))
                    self.end_headers()
                    self.wfile.write(response)
                    return
                key = self.headers.get("x-api-key", "")
                own_a = (
                    key == "tenant-a-secret"
                    and "/ns_aaaaaaaa-" in self.path
                    and "/agt_aaaaaaaa-" in self.path
                )
                own_b = (
                    key == "tenant-b-secret"
                    and "/ns_bbbbbbbb-" in self.path
                    and "/agt_bbbbbbbb-" in self.path
                )
                if own_a or own_b:
                    namespace_match = re.search(r"/namespaces/([^/]+)/", self.path)
                    agent_match = re.search(r"/agents/([^/]+)$", self.path)
                    if namespace_match is None or agent_match is None:
                        self.send_error(400)
                        return
                    body = {{
                        "data": {{
                            "id": agent_match.group(1),
                            "namespaceId": namespace_match.group(1),
                        }}
                    }}
                    status = 200
                else:
                    code = "WRONG_CODE" if scenario == "wrong_cross_code" else "FORBIDDEN"
                    body = {{"error": {{"code": code, "message": "denied"}}}}
                    status = 403
                response = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, _format, *_args):
                return

        server = http.server.HTTPServer(("127.0.0.1", int(local_port)), OCEHandler)
        (state_dir / "port_forward_pid").write_text(str(os.getpid()))
        (state_dir / "port_forward_started").write_text(
            f"127.0.0.1:{{local_port}}:8080"
        )
        if scenario != "port_forward_no_marker":
            print(
                f"Forwarding from 127.0.0.1:{{local_port}} -> 8080",
                file=sys.stderr,
                flush=True,
            )

        def stop_port_forward(_signum, _frame):
            (state_dir / "port_forward_stopped").write_text("SIGTERM")
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, stop_port_forward)
        try:
            server.serve_forever()
        finally:
            server.server_close()
            if not (state_dir / "port_forward_stopped").exists():
                (state_dir / "port_forward_stopped").write_text("EXIT")
        sys.exit(0)

    if args[:1] == ["exec"]:
        pod_name = args[2] if args[1] == "-i" else args[1]
        remote = args[args.index("--") + 1:]
        joined = " ".join(remote)
        if "LIVE_GUEST_EVIDENCE" in joined:
            boot_id = (
                "11111111-1111-4111-8111-111111111111"
                if namespace == "tenant-a-k8s"
                else "22222222-2222-4222-8222-222222222222"
            )
            emit("\\n".join([
                "LIVE_GUEST_EVIDENCE",
                boot_id,
                "6.1.99",
                "x86_64",
                "/dev/vda1 ext4",
                "252:0:2097152:vda",
            ]))
            sys.exit(0)
        if "OCE_NETPOL_CANARY" in joined:
            policy = state_dir / f"netpol-{{namespace}}"
            allowed = namespace.startswith("oce-live-network-") or policy.exists()
            if scenario == "network_policy_not_enforced" and namespace.startswith("tenant-"):
                allowed = True
            if allowed:
                print("NETPOL_ALLOWED", end="")
                sys.exit(0)
            sys.exit(43)
        if "NETPOL_BLOCKED" in joined:
            policy = state_dir / f"netpol-{{namespace}}"
            blocked = not policy.exists()
            if scenario == "network_policy_not_enforced" and namespace.startswith("tenant-"):
                blocked = False
            if blocked:
                print("NETPOL_BLOCKED", end="")
                sys.exit(0)
            sys.exit(42)
        if "net.createConnection" in joined:
            host = remote[-2]
            if scenario == "egress_allowed" and host == "1.1.1.1":
                sys.exit(42)
            print("EGRESS_BLOCKED", end="")
            sys.exit(0)
        if "https.request" in joined:
            emit({{"status": 200, "model": "nova-lite", "text": "OK"}})
            sys.exit(0)
        if "persistent-ok" in joined and remote[:3] == ["sh", "-eu", "-c"]:
            (state_dir / "marker").write_text("persistent-ok")
            (state_dir / "ephemeral").write_text("ephemeral-old")
            sys.exit(0)
        if remote[:2] == ["rm", "-f"]:
            for marker in ("marker", "ephemeral"):
                (state_dir / marker).unlink(missing_ok=True)
            sys.exit(0)
        if remote[:1] == ["cat"]:
            if (state_dir / "marker").exists():
                print("persistent-ok")
                sys.exit(0)
            sys.exit(1)
        if remote[:2] == ["test", "-e"]:
            if pod_name == "tenant-a-replacement":
                sys.exit(1)
            sys.exit(0 if (state_dir / "ephemeral").exists() else 1)
        if remote[:3] == ["test", "!", "-e"]:
            clean = not (state_dir / "marker").exists() and not (state_dir / "ephemeral").exists()
            sys.exit(0 if clean else 1)
        print("unsupported fake exec", remote, file=sys.stderr)
        sys.exit(95)

    if args[:2] == ["get", "networkpolicy"]:
        sys.exit(0 if (state_dir / f"netpol-{{namespace}}").exists() else 1)
    if args[:2] == ["create", "-f"]:
        manifest = sys.stdin.read()
        if "kind: Pod" in manifest:
            match = re.search(r"(?m)^  name: (oce-live-cross-pvc-[0-9]+)$", manifest)
            if (
                namespace != "tenant-a-k8s"
                or match is None
                or "claimName: pvc-b" not in manifest
            ):
                print("invalid cross-tenant PVC probe", file=sys.stderr)
                sys.exit(97)
            (state_dir / "cross_pvc_pod").write_text(match.group(1))
            emit(cross_probe(
                match.group(1),
                include_uid=scenario != "post_create_uid_failure",
            ))
        elif "kind: NetworkPolicy" in manifest:
            (state_dir / f"netpol-{{namespace}}").write_text(manifest)
        elif "kind: Deployment" in manifest and "kind: Service" in manifest:
            (state_dir / "network_canary").write_text(namespace)
        else:
            print("unsupported fake create manifest", file=sys.stderr)
            sys.exit(97)
        sys.exit(0)
    if args[:2] == ["apply", "-f"]:
        manifest = sys.stdin.read()
        if "kind: Deployment" in manifest and "kind: Service" in manifest:
            (state_dir / "network_canary").write_text(namespace)
            sys.exit(0)
        print("unsupported fake apply manifest", file=sys.stderr)
        sys.exit(98)
    if args[:2] == ["delete", "networkpolicy"]:
        (state_dir / f"netpol-{{namespace}}").unlink(missing_ok=True)
        sys.exit(0)
    if (
        args[:2] == ["get", "pods"]
        and namespace
        and namespace.startswith("oce-live-network-")
    ):
        emit("canary-pod")
        sys.exit(0)
    if args[:2] == ["get", "configmap"]:
        sys.exit(1)
    if args[:2] == ["create", "configmap"]:
        print("denied: admission caller is not an allowed controller identity for this resource", file=sys.stderr)
        sys.exit(1)
    if args[:2] == ["create", "--dry-run=server"]:
        print("denied: admission caller is not an allowed controller identity for this resource", file=sys.stderr)
        sys.exit(1)
    if args[:1] == ["debug"]:
        print(
            "denied: ephemeral containers are not permitted in OpenClaw Enterprise managed namespaces",
            file=sys.stderr,
        )
        sys.exit(1)
    if args[:2] == ["get", "replicaset"]:
        emit({{
            "metadata": {{"ownerReferences": [{{
                "kind": "Deployment",
                "name": "tenant-a-controller",
                "controller": True,
            }}]}}
        }})
        sys.exit(0)
    if args[:1] == ["delete"] and any(value.startswith("--raw=") for value in args):
        raw = next(value.removeprefix("--raw=") for value in args if value.startswith("--raw="))
        options_path = Path(args[args.index("-f") + 1])
        options = json.loads(options_path.read_text())
        supplied_uid = options.get("preconditions", {{}}).get("uid")
        match = re.fullmatch(r"/api/v1/namespaces/([^/]+)/pods/([^/]+)", raw)
        if match is None:
            print("invalid raw pod delete path", file=sys.stderr)
            sys.exit(99)
        delete_namespace, pod_name = match.groups()
        cross_file = state_dir / "cross_pvc_pod"
        if pod_name == "tenant-a-pod":
            expected_uid = "uid-a-old"
            if scenario == "uid_precondition_rejected":
                print("Conflict: pod UID precondition failed", file=sys.stderr)
                sys.exit(1)
            (state_dir / "deleted").write_text(pod_name)
            (state_dir / "deleted_uid").write_text(supplied_uid or "")
            (state_dir / "ephemeral").unlink(missing_ok=True)
        elif cross_file.exists() and pod_name == cross_file.read_text():
            expected_uid = "uid-cross-pvc"
            (state_dir / "cross_deleted_uid").write_text(supplied_uid or "")
            cross_file.unlink()
        else:
            print("unexpected pod delete target", file=sys.stderr)
            sys.exit(99)
        if delete_namespace != "tenant-a-k8s" or supplied_uid != expected_uid:
            print("Conflict: pod UID precondition failed", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    if args[:1] == ["wait"] and "--for=delete" in args:
        pod_name = next(value.removeprefix("pod/") for value in args if value.startswith("pod/"))
        cross_file = state_dir / "cross_pvc_pod"
        if cross_file.exists() and cross_file.read_text() == pod_name:
            sys.exit(1)
        sys.exit(0)
    if args[:2] == ["delete", "pod"]:
        print("direct pod deletion is not allowed by this test harness", file=sys.stderr)
        sys.exit(99)
    if args[:2] == ["get", "pods"] and namespace == "tenant-a-k8s":
        emit({{"items": [pod_a_new]}})
        sys.exit(0)
    if args[:2] == ["rollout", "status"]:
        sys.exit(0)

    print("unsupported fake kubectl command", namespace, args, file=sys.stderr)
    sys.exit(96)
    """
)


def _make_fake_commands(tmp_path: Path) -> tuple[Path, Path]:
    fake_bin = tmp_path / "bin"
    state_dir = tmp_path / "state"
    fake_bin.mkdir()
    state_dir.mkdir()
    for name in ("aws", "kubectl"):
        command = fake_bin / name
        command.write_text(FAKE_COMMAND)
        command.chmod(0o755)
    return fake_bin, state_dir


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _arguments(tmp_path: Path) -> list[str]:
    credential_a = tmp_path / "tenant-a.key"
    credential_b = tmp_path / "tenant-b.key"
    credential_a.write_text(json.dumps({"data": {"key": "tenant-a-secret"}}))
    credential_b.write_text(json.dumps({"data": {"key": "tenant-b-secret"}}))
    credential_a.chmod(0o600)
    credential_b.chmod(0o600)
    return [
        "--account-id",
        "123456789012",
        "--region",
        "us-west-2",
        "--cluster",
        "explicit-cluster",
        "--kube-context",
        "explicit-context",
        "--tenant-a-namespace",
        "tenant-a-k8s",
        "--tenant-a-pod",
        "tenant-a-pod",
        "--tenant-a-container",
        "gateway",
        "--tenant-b-namespace",
        "tenant-b-k8s",
        "--tenant-b-pod",
        "tenant-b-pod",
        "--tenant-b-container",
        "gateway",
        "--runtime-image",
        RUNTIME_IMAGE,
        "--oce-api-local-port",
        str(_free_loopback_port()),
        "--oce-system-namespace",
        "oce-system",
        "--oce-source-revision",
        OCE_SOURCE_REVISION,
        "--tenant-a-oce-namespace",
        "ns_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "--tenant-a-agent-id",
        "agt_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "--tenant-a-credential-file",
        str(credential_a),
        "--tenant-b-oce-namespace",
        "ns_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "--tenant-b-agent-id",
        "agt_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "--tenant-b-credential-file",
        str(credential_b),
        "--evidence-dir",
        str(tmp_path / "evidence"),
        "--confirm-pod-replacement",
        "--timeout-seconds",
        "10",
    ]


def _run(
    tmp_path: Path,
    scenario: str = "pass",
    kms_key_id: str | None = None,
    trace: bool = False,
) -> subprocess.CompletedProcess[str]:
    fake_bin, state_dir = _make_fake_commands(tmp_path)
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["FAKE_STATE_DIR"] = str(state_dir)
    env["FAKE_SCENARIO"] = scenario
    arguments = _arguments(tmp_path)
    if kms_key_id is not None:
        arguments.extend(["--kms-signing-key-id", kms_key_id])
    command = ["bash", "-x", str(SCRIPT)] if trace else [str(SCRIPT)]
    return subprocess.run(
        [*command, *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        timeout=90,
    )


def test_requires_every_explicit_target_and_replacement_confirmation(tmp_path: Path) -> None:
    result = subprocess.run(
        [str(SCRIPT), "--region", "us-west-2"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )

    assert result.returncode != 0
    assert "missing required option" in result.stderr
    assert not (tmp_path / "evidence").exists()


def test_requires_an_explicit_unprivileged_loopback_port(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)
    port_index = arguments.index("--oce-api-local-port")
    del arguments[port_index : port_index + 2]

    result = subprocess.run(
        [str(SCRIPT), *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )

    assert result.returncode != 0
    assert "missing required option" in result.stderr
    assert not (tmp_path / "evidence").exists()


def test_accepts_raw_one_line_service_keys_for_secret_manager_exports(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)
    for tenant in ("a", "b"):
        credential = tmp_path / f"tenant-{tenant}.key"
        credential.write_text(f"tenant-{tenant}-secret")
        credential.chmod(0o600)

    fake_bin, state_dir = _make_fake_commands(tmp_path)
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["FAKE_STATE_DIR"] = str(state_dir)
    result = subprocess.run(
        [str(SCRIPT), *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        timeout=90,
    )

    assert result.returncode == 0, result.stderr


def test_fake_live_run_passes_and_writes_only_sanitized_evidence(tmp_path: Path) -> None:
    result = _run(tmp_path)

    assert result.returncode == 0, result.stderr
    evidence = (tmp_path / "evidence" / "live-validation-evidence.txt").read_text()
    assert "RESULT\tPASS" in evidence
    assert f"EVIDENCE\toce-source-revision\t{OCE_SOURCE_REVISION}" in evidence
    assert f"EVIDENCE\toce-deployed-source-revision\t{OCE_SOURCE_REVISION}" in evidence
    assert (
        f"EVIDENCE\tvalidator-sha256\t{hashlib.sha256(SCRIPT.read_bytes()).hexdigest()}"
        in evidence
    )
    git_revision = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--verify", "HEAD^{commit}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    assert f"EVIDENCE\tgit-revision\t{git_revision}" in evidence
    cluster_arn = "arn:aws:eks:us-west-2:123456789012:cluster/explicit-cluster"
    assert (
        f"EVIDENCE\tcluster-arn-sha256\t"
        f"{hashlib.sha256(cluster_arn.encode()).hexdigest()}"
    ) in evidence
    assert (
        "EVIDENCE\tworkload-image-tenant-a\t"
        f"uid=uid-a-old container=gateway digest=sha256:{DIGEST}"
    ) in evidence
    assert (
        "EVIDENCE\tworkload-image-tenant-a-replacement\t"
        f"uid=uid-a-new container=gateway digest=sha256:{DIGEST}"
    ) in evidence
    assert (
        "EVIDENCE\tworkload-image-tenant-b\t"
        f"uid=uid-b container=gateway digest=sha256:{DIGEST}"
    ) in evidence
    assert (
        "EVIDENCE\tworkload-image-agentgateway-1\t"
        "uid=uid-agw-1 container=agentgateway digest=sha256:" + ("b" * 64)
    ) in evidence
    assert (
        "EVIDENCE\tworkload-image-oce-system-1\t"
        "uid=uid-oce-api-1 container=api digest=sha256:" + ("c" * 64)
    ) in evidence
    assert "EVIDENCE\ttool-version-aws\taws-cli/2.31.0" in evidence
    assert "EVIDENCE\ttool-version-kubectl\tv1.34.0 darwin/arm64" in evidence
    assert "EVIDENCE\ttool-version-node\tv" in evidence
    assert "EVIDENCE\tsignature-status\tunsigned;" in evidence
    assert "CLEANUP\tPASS\t" in evidence
    for check in (
        "runtime-isolation",
        "security-context",
        "tenant-storage-isolation",
        "cross-tenant-pvc-mount-denied",
        "guest-vm-boundary",
        "auto-mode-network-policy-configuration",
        "auto-mode-network-policy-enforcement",
        "egress-tenant-a-public-ip",
        "egress-tenant-b-imds",
        "agentgateway-responses-api",
        "control-plane-evidence",
        "oce-api-loopback-port-forward",
        "oce-deployed-source-revision",
        "oce-same-tenant-api",
        "oce-cross-tenant-api",
        "reserved-configmap-spoof",
        "managed-pod-spoof",
        "ephemeral-debug",
        "controller-driven-persistence",
        "temporary-artifact-cleanup",
    ):
        assert f"PASS\t{check}\t" in evidence

    sensitive_values = (
        "123456789012",
        "explicit-cluster",
        "explicit-context",
        "tenant-a-k8s",
        "tenant-a-pod",
        "tenant-b-k8s",
        "tenant-b-pod",
        "ns_aaaaaaaa",
        "agt_aaaaaaaa",
        "tenant-a-secret",
        "tenant-b-secret",
        "vol-tenant-a-secret",
        "vol-tenant-b-secret",
        RUNTIME_IMAGE,
    )
    assert not any(value in evidence for value in sensitive_values)

    state_dir = tmp_path / "state"
    assert (state_dir / "deleted").read_text() == "tenant-a-pod"
    assert (state_dir / "deleted_uid").read_text() == "uid-a-old"
    assert (state_dir / "cross_deleted_uid").read_text() == "uid-cross-pvc"
    assert not (state_dir / "marker").exists()
    assert not (state_dir / "ephemeral").exists()
    assert not (state_dir / "cross_pvc_pod").exists()
    command_log = (state_dir / "commands.jsonl").read_text()
    assert "tenant-a-secret" not in command_log
    assert "tenant-b-secret" not in command_log
    assert '"kms"' not in command_log
    commands = [json.loads(line) for line in command_log.splitlines()]
    port_forward_commands = [
        command
        for command in commands
        if command["tool"] == "kubectl" and "port-forward" in command["args"]
    ]
    assert len(port_forward_commands) == 1
    port_forward_args = port_forward_commands[0]["args"]
    assert "--address=127.0.0.1" in port_forward_args
    assert "service/openclaw-enterprise-api" in port_forward_args
    assert not any("0.0.0.0" in arg or arg == "--address=localhost" for arg in port_forward_args)
    assert not any(
        "deployment/oce-api-cli-client" in arg
        for command in commands
        for arg in command["args"]
    )
    assert (state_dir / "port_forward_stopped").read_text() == "SIGTERM"
    port_forward_pid = int((state_dir / "port_forward_pid").read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(port_forward_pid, 0)

    evidence_path = tmp_path / "evidence" / "live-validation-evidence.txt"
    manifest_path = tmp_path / "evidence" / "live-validation-manifest.sha256"
    expected_manifest = (
        f"{hashlib.sha256(evidence_path.read_bytes()).hexdigest()}  "
        "live-validation-evidence.txt\n"
    )
    assert manifest_path.read_text() == expected_manifest
    assert not (tmp_path / "evidence" / "live-validation-evidence.sig.b64").exists()
    assert not list((tmp_path / "evidence").glob(".live-validation-*"))


def test_bash_trace_cannot_expose_service_keys(tmp_path: Path) -> None:
    result = _run(tmp_path, trace=True)

    assert result.returncode == 0, result.stderr
    combined_output = result.stdout + result.stderr
    command_log = (tmp_path / "state" / "commands.jsonl").read_text()
    evidence_files = [
        path.read_text()
        for path in (tmp_path / "evidence").iterdir()
        if path.is_file()
    ]
    for secret in ("tenant-a-secret", "tenant-b-secret"):
        assert secret not in combined_output
        assert secret not in command_log
        assert all(secret not in content for content in evidence_files)


def test_kms_signing_occurs_only_when_key_is_explicitly_supplied(tmp_path: Path) -> None:
    result = _run(tmp_path, kms_key_id="alias/evidence-test")

    assert result.returncode == 0, result.stderr
    evidence_path = tmp_path / "evidence" / "live-validation-evidence.txt"
    signature_path = tmp_path / "evidence" / "live-validation-evidence.sig.b64"
    manifest_path = tmp_path / "evidence" / "live-validation-manifest.sha256"
    evidence = evidence_path.read_text()
    assert "EVIDENCE\tsignature-status\tsigned-with-kms " in evidence
    assert "alias/evidence-test" not in evidence
    assert "fake-evidence-key" not in evidence
    assert signature_path.read_text().strip() == "ZmFrZS1rbXMtc2lnbmF0dXJl"
    assert manifest_path.read_text() == (
        f"{hashlib.sha256(evidence_path.read_bytes()).hexdigest()}  "
        "live-validation-evidence.txt\n"
        f"{hashlib.sha256(signature_path.read_bytes()).hexdigest()}  "
        "live-validation-evidence.sig.b64\n"
    )
    command_log = (tmp_path / "state" / "commands.jsonl").read_text()
    assert '"get-public-key"' in command_log
    assert '"sign"' in command_log
    assert '"verify"' in command_log


def test_rejects_service_key_with_multiple_hard_links(tmp_path: Path) -> None:
    arguments = _arguments(tmp_path)
    os.link(tmp_path / "tenant-a.key", tmp_path / "tenant-a-hard-link.key")
    fake_bin, state_dir = _make_fake_commands(tmp_path)
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["FAKE_STATE_DIR"] = str(state_dir)

    result = subprocess.run(
        [str(SCRIPT), *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )

    assert result.returncode != 0
    assert "credential file must have exactly one hard link" in result.stderr
    assert not (tmp_path / "evidence").exists()
    assert not (state_dir / "commands.jsonl").exists()


@pytest.mark.parametrize("scenario, failed_check", [
    ("wrong_cluster_arn", "eks-cluster"),
    ("egress_allowed", "tenant-egress-deny"),
    ("network_policy_not_enforced", "auto-mode-network-policy-enforcement"),
    ("port_forward_early_exit", "oce-api-port-forward"),
    ("port_forward_no_marker", "oce-api-port-forward"),
    ("wrong_oce_revision", "oce-deployed-source-revision"),
    ("wrong_cross_code", "oce-tenant-api-isolation"),
    ("cross_tenant_pvc_mounted", "tenant-storage-isolation"),
    ("post_create_uid_failure", "tenant-storage-isolation"),
    ("uid_precondition_rejected", "controller-driven-persistence"),
    ("kms_verify_failure", "evidence-signing"),
])
def test_live_run_fails_closed_on_security_contract_mismatch(
    tmp_path: Path, scenario: str, failed_check: str
) -> None:
    kms_key_id = "alias/evidence-test" if scenario == "kms_verify_failure" else None
    result = _run(tmp_path, scenario, kms_key_id)

    assert result.returncode != 0
    evidence = (tmp_path / "evidence" / "live-validation-evidence.txt").read_text()
    assert f"FAIL\t{failed_check}\t" in evidence
    assert "RESULT\tPASS" not in evidence
    if scenario in ("cross_tenant_pvc_mounted", "post_create_uid_failure"):
        assert (tmp_path / "state" / "cross_deleted_uid").read_text() == "uid-cross-pvc"
    if scenario in (
        "wrong_cross_code",
        "wrong_oce_revision",
        "port_forward_no_marker",
    ):
        state_dir = tmp_path / "state"
        assert (state_dir / "port_forward_stopped").read_text() == "SIGTERM"
        port_forward_pid = int((state_dir / "port_forward_pid").read_text())
        with pytest.raises(ProcessLookupError):
            os.kill(port_forward_pid, 0)
    if scenario == "kms_verify_failure":
        assert not (tmp_path / "evidence" / "live-validation-evidence.sig.b64").exists()
    evidence_dir = tmp_path / "evidence"
    if evidence_dir.exists():
        assert not list(evidence_dir.glob(".live-validation-*"))


def test_script_contains_destructive_and_api_contract_guards() -> None:
    source = SCRIPT.read_text()

    assert source.startswith("#!/usr/bin/env bash\nset +x\n")
    assert 'MODEL_ALIAS="nova-lite"' in source
    assert 'EXPECTED_MODEL_TEXT="OK"' in source
    assert 'caPath !== "/etc/agentgateway-ca/ca.crt"' in source
    assert "fs.readFileSync(caPath)" in source
    assert "rejectUnauthorized: true" in source
    assert "rejectUnauthorized: false" not in source
    assert '"169.254.170.23" "80" "identity-endpoint"' in source
    assert '"169.254.169.254" "80" "imds"' in source
    assert source.count("--dry-run=server") >= 3
    assert "admission caller is not an allowed controller identity" in source
    assert "ephemeral containers are not permitted" in source
    assert 'EXPECTED_OCE_SOURCE_REVISION="' + OCE_SOURCE_REVISION + '"' in source
    assert 'exec 3<"$file"' in source
    assert "credential file must be owned by the effective user" in source
    assert "credential file must have exactly one hard link" in source
    assert "read -r -d '' credential_blob <&3" in source
    assert 'jq -er \'.data.key\' "$file"' not in source
    assert 'cat "$file"' not in source
    assert '"kind":"DeleteOptions","preconditions":{"uid":"%s"}' in source
    assert '--raw="/api/v1/namespaces/${namespace}/pods/${pod}"' in source
    assert 'delete pod "$TENANT_A_POD"' not in source
    assert "cross-tenant-pvc-mount-denied" in source
    assert "volume-handle-sha256-tenant-a" in source
    assert "oce-deployed-source-revision" in source
    assert 'target.pathname !== "/console/"' in source
    assert 'name="occ-build-revision"' in source
    assert "--oce-api-local-port" in source
    assert "--oce-api-url" not in source
    assert "port-forward" in source
    assert "--address=127.0.0.1" in source
    assert "service/openclaw-enterprise-api" in source
    assert 'OCE_API_URL="http://127.0.0.1:${OCE_API_LOCAL_PORT}"' in source
    assert 'target.hostname !== "127.0.0.1"' in source
    assert "deployment/oce-api-cli-client" not in source
    assert "--arg credential" not in source
    assert "export TENANT_A_CREDENTIAL" not in source
    assert "export TENANT_B_CREDENTIAL" not in source
    assert """printf '%s\\0%s' "$request_url" "$credential" |""" in source
    assert 'const separator = input.indexOf("\\0");' in source
    assert 'stop_oce_api_port_forward >/dev/null 2>&1' in source
    assert 'if wait "$pid" 2>/dev/null; then' in source
    assert 'stop_oce_api_port_forward || die' in source
    assert 'delete namespace "$NETWORK_VALIDATION_NAMESPACE"' in source
    assert 'delete namespace "$TENANT_A_NAMESPACE"' not in source
    assert 'delete namespace "$TENANT_B_NAMESPACE"' not in source
    assert "delete deployment" not in source
    assert 'rm -f -- "$PERSISTENT_MARKER" "$EPHEMERAL_MARKER"' in source
    assert 'if [[ -n "$KMS_SIGNING_KEY_ID" ]]; then' in source
    assert "unsigned; no KMS key explicitly supplied" in source
