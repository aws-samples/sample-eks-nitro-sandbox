from __future__ import annotations

import base64
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
NATIVE_HISTORY_EVALUATOR = ROOT / "scripts" / "lib" / "evaluate-native-tool-history.mjs"
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
                    "env": [
                        {{"name": "OPENAI_API_KEY", "valueFrom": {{
                            "secretKeyRef": {{"name": "gateway-key", "key": "key"}}
                        }}}},
                        {{"name": "OPENCLAW_GATEWAY_PASSWORD", "valueFrom": {{
                            "secretKeyRef": {{"name": "gateway-password", "key": "gateway-password"}}
                        }}}},
                    ],
                    "volumeMounts": [
                        {{
                            "name": "runtime-state",
                            "mountPath": "/home/node",
                        }},
                        {{
                            "name": "openclaw-gateway-state",
                            "mountPath": "/home/node/.openclaw",
                        }},
                        {{
                            "name": "openclaw-configuration",
                            "mountPath": "/etc/openclaw",
                            "readOnly": True,
                        }},
                        {{
                            "name": "agentgateway-ca",
                            "mountPath": "/etc/agentgateway-ca",
                            "readOnly": True,
                        }},
                        {{
                            "name": "openclaw-service-principal",
                            "mountPath": "/var/run/secrets/openclaw/service-principal",
                            "readOnly": True,
                        }},
                    ],
                }}],
                "initContainers": [{{
                    "name": "prepare-private-state",
                    "image": image,
                    "volumeMounts": [
                        {{
                            "name": "runtime-state",
                            "mountPath": "/runtime-state",
                        }},
                        {{
                            "name": "openclaw-gateway-state",
                            "mountPath": "/gateway-state",
                        }},
                    ],
                }}],
                "volumes": [
                    {{
                        "name": "runtime-state",
                        "emptyDir": {{}},
                    }},
                    {{
                        "name": "openclaw-service-principal",
                        "projected": {{"sources": [{{
                            "serviceAccountToken": {{
                                "audience": "openclaw-enterprise",
                                "expirationSeconds": 900,
                                "path": "token",
                            }}
                        }}]}},
                    }},
                    {{
                        "name": "openclaw-gateway-state",
                        "persistentVolumeClaim": {{"claimName": pvc_name}},
                    }},
                    {{
                        "name": "openclaw-configuration",
                        "configMap": {{
                            "name": "gateway-aaaaaaaaaaaa-rev-012345abcdef",
                            "items": [{{"key": "openclaw.json", "path": "openclaw.json"}}],
                        }},
                    }},
                    {{
                        "name": "agentgateway-ca",
                        "configMap": {{
                            "name": "agentgateway-ca",
                            "items": [{{"key": "ca.crt", "path": "ca.crt"}}],
                        }},
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

    if scenario == "sidecar_aws_environment":
        pod_a["spec"]["containers"].append({{
            "name": "credential-sidecar",
            "image": image,
            "env": [{{"name": "AWS_ACCESS_KEY_ID", "value": "not-a-real-key"}}],
        }})
    elif scenario == "init_aws_environment":
        pod_a["spec"]["initContainers"].append({{
            "name": "credential-init",
            "image": image,
            "env": [{{
                "name": "AWS_WEB_IDENTITY_TOKEN_FILE",
                "value": "/var/run/unapproved/token",
            }}],
        }})
    elif scenario == "ephemeral_aws_environment":
        pod_a["spec"]["ephemeralContainers"] = [{{
            "name": "credential-debugger",
            "image": image,
            "env": [{{
                "name": "AWS_CONTAINER_CREDENTIALS_FULL_URI",
                "value": "http://127.0.0.1/credentials",
            }}],
        }}]
    elif scenario == "secret_aws_mount":
        pod_a["spec"]["volumes"].append({{
            "name": "aws-credentials",
            "secret": {{"secretName": "aws-credentials"}},
        }})
        pod_a["spec"]["containers"].append({{
            "name": "credential-sidecar",
            "image": image,
            "volumeMounts": [{{
                "name": "aws-credentials",
                "mountPath": "/home/node/.aws",
                "readOnly": True,
            }}],
        }})
    elif scenario == "sidecar_state_pvc_mount":
        pod_a["spec"]["containers"].append({{
            "name": "state-sidecar",
            "image": image,
            "volumeMounts": [{{
                "name": "openclaw-gateway-state",
                "mountPath": "/home/node/.openclaw",
            }}],
        }})
    elif scenario == "csi_credential_mount":
        pod_a["spec"]["volumes"].append({{
            "name": "credential-csi",
            "csi": {{"driver": "secrets-store.csi.k8s.io"}},
        }})
        pod_a["spec"]["containers"][0]["volumeMounts"].append({{
            "name": "credential-csi",
            "mountPath": "/mnt/identity",
            "readOnly": True,
        }})
    elif scenario == "pvc_credential_mount":
        pod_a["spec"]["volumes"].append({{
            "name": "credential-pvc",
            "persistentVolumeClaim": {{"claimName": "credential-pvc"}},
        }})
        pod_a["spec"]["containers"][0]["volumeMounts"].append({{
            "name": "credential-pvc",
            "mountPath": "/mnt/identity",
        }})
    elif scenario == "hostpath_credential_mount":
        pod_a["spec"]["volumes"].append({{
            "name": "host-credentials",
            "hostPath": {{"path": "/root/.aws", "type": "Directory"}},
        }})
        pod_a["spec"]["containers"][0]["volumeMounts"].append({{
            "name": "host-credentials",
            "mountPath": "/mnt/identity",
            "readOnly": True,
        }})

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

    def ordinary_control(name, include_uid=True):
        metadata = {{
            "name": name,
            "namespace": "openclaw-enterprise-agw",
            "labels": {{
                "app.kubernetes.io/managed-by":
                    "openclaw-enterprise-blueprint",
                "openclaw.dev/validation": "ordinary-pod-control",
            }},
        }}
        if include_uid:
            metadata["uid"] = "uid-ordinary-control"
        control = {{
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": metadata,
            "spec": {{
                "automountServiceAccountToken": False,
                "enableServiceLinks": False,
                "restartPolicy": "Never",
                "serviceAccountName": "default",
                "containers": [{{
                    "name": "ordinary-control",
                    "image": image,
                    "command": ["sh", "-c", "sleep 3600"],
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
                }}],
            }},
            "status": {{
                "phase": "Running",
                "containerStatuses": [{{
                    "name": "ordinary-control",
                    "ready": True,
                    "state": {{"running": {{}}}},
                }}],
            }},
        }}
        if scenario == "ordinary_sandboxed_control":
            control["spec"]["runtimeClassName"] = "isolated-sandbox"
        elif scenario == "ordinary_control_has_volume":
            control["spec"]["volumes"] = [{{
                "name": "unexpected",
                "emptyDir": {{}},
            }}]
        elif scenario == "ordinary_not_ready":
            control["status"] = {{
                "phase": "Pending",
                "containerStatuses": [],
            }}
        return control

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
        elif (
            (state_dir / "ordinary_control_pod").exists()
            and name == (state_dir / "ordinary_control_pod").read_text()
        ):
            emit(ordinary_control(name))
        else:
            sys.exit(94)
        sys.exit(0)

    if args[:2] == ["get", "serviceaccount"]:
        emit({{
            "metadata": {{"annotations": {{}}}},
            "automountServiceAccountToken": False,
        }})
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
            {{
                "metadata": {{"name": "agentgateway-0", "uid": "uid-agw-1"}},
                "spec": spec,
                "status": status,
            }},
            {{
                "metadata": {{"name": "agentgateway-1", "uid": "uid-agw-2"}},
                "spec": spec,
                "status": status,
            }},
        ]}})
        sys.exit(0)
    if namespace == "openclaw-enterprise-agw" and args[:1] == ["logs"]:
        if args[1] != "agentgateway-0":
            sys.exit(0)
        model_call_count = int(
            (state_dir / "model_call_count").read_text()
            if (state_dir / "model_call_count").exists()
            else "0"
        )
        for call_index in range(1, model_call_count + 1):
            trace_id = format(call_index, "032x")
            if scenario == "missing_agw_trace":
                trace_id = "f" * 32
            bedrock_model = (
                "amazon.nova-pro-v1:0"
                if scenario == "wrong_agw_model"
                else "amazon.nova-lite-v1:0"
            )
            fields = []
            if scenario != "missing_agw_request_id":
                fields.append("request.id=" + str(9000 + call_index))
            fields.extend([
                'trace.id="' + trace_id + '"',
                'gen_ai.provider.name="bedrock"',
                'agw.ai.original_model="nova-lite"',
                'gen_ai.request.model="' + bedrock_model + '"',
            ])
            print(" ".join(fields))
        sys.exit(0)
    if namespace == "oce-system" and args[:2] == ["get", "pods"]:
        emit({{"items": [{{
            "metadata": {{
                "name": "oce-api-0",
                "uid": "uid-oce-api-1",
                "labels": {{"app.kubernetes.io/component": "api"}},
            }},
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
        if "LIVE_AGENTGATEWAY_KEY_CONTRACT" in joined:
            if (
                namespace not in ("tenant-a-k8s", "tenant-b-k8s")
                or pod_name not in ("tenant-a-pod", "tenant-b-pod")
            ):
                print("invalid AgentGateway key probe target", file=sys.stderr)
                sys.exit(102)
            with (state_dir / "agentgateway_key_calls.jsonl").open("a") as calls:
                calls.write(json.dumps({{
                    "namespace": namespace,
                    "pod": pod_name,
                }}) + "\\n")
            no_key_status = 200 if scenario == "agw_missing_key_accepted" else 401
            wrong_key_status = 200 if scenario == "agw_wrong_key_accepted" else 403
            accepted_status = (
                403
                if scenario == "agw_correct_key_denied"
                or (
                    scenario == "agw_tenant_b_correct_key_denied"
                    and namespace == "tenant-b-k8s"
                )
                else 200
            )
            if scenario == "agw_key_malformed_output":
                print('{{"marker":')
                sys.exit(0)
            emit({{
                "marker": (
                    "WRONG_AGENTGATEWAY_KEY_CONTRACT"
                    if scenario == "agw_key_marker_missing"
                    else "LIVE_AGENTGATEWAY_KEY_CONTRACT"
                ),
                "noKeyStatus": no_key_status,
                "wrongKeyStatus": wrong_key_status,
                "acceptedStatus": accepted_status,
                "nonceMatch": scenario != "agw_key_nonce_mismatch",
            }})
            sys.exit(0)
        if "LIVE_NATIVE_TOOL_EXECUTION" in joined:
            if (
                namespace != "oce-system"
                or pod_name != "oce-api-0"
                or remote[:1] != ["env"]
                or (
                    "OCE_TEST_NAMESPACE_ID="
                    "ns_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                ) not in remote
                or (
                    "OCE_TEST_AGENT_ID="
                    "agt_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                ) not in remote
            ):
                print("invalid native tool execution target", file=sys.stderr)
                sys.exit(103)
            (state_dir / "native_tool_execution").write_text(
                json.dumps({{
                    "namespace": namespace,
                    "pod": pod_name,
                    "container": args[args.index("-c") + 1],
                }})
            )
            if scenario == "native_tool_malformed_output":
                print('{{"marker":')
                sys.exit(0)
            if scenario == "native_tool_wrong_name":
                print("native transcript used the wrong tool", file=sys.stderr)
                sys.exit(105)
            emit({{
                "marker": (
                    "WRONG_NATIVE_TOOL_EXECUTION"
                    if scenario == "native_tool_marker_missing"
                    else "LIVE_NATIVE_TOOL_EXECUTION"
                ),
                "outcome": (
                    "error"
                    if scenario == "native_tool_outcome_error"
                    else "ok"
                ),
                "toolCallCount": (
                    0
                    if scenario == "native_tool_missing_exec_call"
                    else 1
                ),
                "execResultCount": (
                    0
                    if scenario == "native_tool_uncorrelated_result"
                    else 2 if scenario == "native_tool_harmless_retry" else 1
                ),
                "finalReplyCount": 1,
                "exactCommand": scenario != "native_tool_wrong_command",
                "resultMarker": scenario != "native_tool_result_marker_missing",
                "finalReply": scenario != "native_tool_wrong_final_reply",
                "runIdHash": (
                    "not-a-hash"
                    if scenario == "native_tool_invalid_run_hash"
                    else "d" * 64
                ),
            }})
            sys.exit(0)
        if "LIVE_GUEST_EVIDENCE" in joined:
            is_sandbox = namespace in ("tenant-a-k8s", "tenant-b-k8s")
            if namespace == "tenant-a-k8s":
                boot_id = "11111111-1111-4111-8111-111111111111"
            elif namespace == "tenant-b-k8s":
                boot_id = "22222222-2222-4222-8222-222222222222"
            elif namespace == "openclaw-enterprise-agw":
                boot_id = (
                    "11111111-1111-4111-8111-111111111111"
                    if scenario == "ordinary_shared_boot_id"
                    else "33333333-3333-4333-8333-333333333333"
                )
                if scenario == "ordinary_invalid_boot_id":
                    boot_id = "not-a-boot-id"
            else:
                print("invalid guest evidence target", file=sys.stderr)
                sys.exit(104)
            if is_sandbox:
                root = "/dev/vda1 ext4"
                disk_rows = [
                    "BLOCK:vda",
                    "PARTITION:252:0:2097152:vda",
                    "PARTITION:252:1:2096128:vda1",
                ]
            else:
                root = "overlay overlay"
                disk_rows = [
                    "BLOCK:nvme0n1",
                    "PARTITION:259:0:2097152:nvme0n1",
                    "PARTITION:259:1:2096128:nvme0n1p1",
                ]
            if scenario == "ordinary_sandbox_disk" and not is_sandbox:
                root = "/dev/vda1 ext4"
                disk_rows = [
                    "BLOCK:vda",
                    "PARTITION:252:0:2097152:vda",
                    "PARTITION:252:1:2096128:vda1",
                ]
            if scenario == "sandbox_non_virtio_disk" and namespace == "tenant-a-k8s":
                root = "/dev/nvme0n1p1 ext4"
                disk_rows = [
                    "BLOCK:nvme0n1",
                    "PARTITION:259:0:2097152:nvme0n1",
                    "PARTITION:259:1:2096128:nvme0n1p1",
                ]
            if scenario == "sandbox_missing_partition" and namespace == "tenant-a-k8s":
                disk_rows = ["BLOCK:vda"]
            if scenario == "sandbox_whole_disk_only" and namespace == "tenant-a-k8s":
                disk_rows = [
                    "BLOCK:vda",
                    "PARTITION:252:0:2097152:vda",
                ]
            if scenario == "ordinary_whole_disk_only" and not is_sandbox:
                disk_rows = [
                    "BLOCK:nvme0n1",
                    "PARTITION:259:0:2097152:nvme0n1",
                ]
            if scenario == "sandbox_malformed_partition" and namespace == "tenant-a-k8s":
                disk_rows = ["BLOCK:vda", "PARTITION:not-valid"]
            emit("\\n".join([
                "LIVE_GUEST_EVIDENCE",
                boot_id,
                "6.1.99",
                "x86_64",
                root,
                *disk_rows,
            ]))
            sys.exit(0)
        if "/v1/chat/completions" in joined:
            model_call_count_file = state_dir / "model_call_count"
            model_call_count = int(
                model_call_count_file.read_text()
                if model_call_count_file.exists()
                else "0"
            ) + 1
            model_call_count_file.write_text(str(model_call_count))
            emit({{
                "status": 200,
                "unauthenticatedStatus": (
                    200 if scenario == "native_unauthenticated_accepted" else 401
                ),
                "model": (
                    "openclaw/unexpected"
                    if scenario == "wrong_native_model"
                    else "openclaw/default"
                ),
                "requestId": "chatcmpl_" + format(model_call_count, "032x"),
                "traceId": format(model_call_count, "032x"),
                "nonceMatch": scenario != "nonce_suffix",
            }})
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

    if args[:2] == ["create", "-f"]:
        manifest = Path(args[2]).read_text() if args[2] != "-" else sys.stdin.read()
        try:
            manifest_json = json.loads(manifest)
        except json.JSONDecodeError:
            manifest_json = None
        if isinstance(manifest_json, dict) and manifest_json.get("kind") == "Pod":
            metadata = manifest_json.get("metadata", {{}})
            name = metadata.get("name", "")
            if metadata.get("labels", {{}}).get(
                "openclaw.dev/validation"
            ) == "cross-tenant-pvc":
                expected_manifest = {{
                    "apiVersion": "v1",
                    "kind": "Pod",
                    "metadata": {{
                        "name": name,
                        "labels": {{
                            "app.kubernetes.io/managed-by":
                                "openclaw-enterprise-blueprint",
                            "openclaw.dev/validation": "cross-tenant-pvc",
                        }},
                    }},
                    "spec": {{
                        "automountServiceAccountToken": False,
                        "enableServiceLinks": False,
                        "restartPolicy": "Never",
                        "securityContext": {{
                            "runAsNonRoot": True,
                            "runAsUser": 1000,
                            "runAsGroup": 1000,
                            "seccompProfile": {{"type": "RuntimeDefault"}},
                        }},
                        "containers": [{{
                            "name": "cross-tenant-pvc",
                            "image": image,
                            "command": ["sh", "-c", "sleep 3600"],
                            "volumeMounts": [{{
                                "name": "cross-tenant-pvc",
                                "mountPath": "/cross-tenant",
                            }}],
                            "securityContext": {{
                                "allowPrivilegeEscalation": False,
                                "readOnlyRootFilesystem": True,
                                "capabilities": {{"drop": ["ALL"]}},
                            }},
                        }}],
                        "volumes": [{{
                            "name": "cross-tenant-pvc",
                            "persistentVolumeClaim": {{
                                "claimName": "pvc-b",
                            }},
                        }}],
                    }},
                }}
                if (
                    namespace != "tenant-a-k8s"
                    or re.fullmatch(
                        r"oce-live-cross-pvc-[0-9]+", name
                    ) is None
                    or manifest_json != expected_manifest
                ):
                    print("invalid cross-tenant PVC probe", file=sys.stderr)
                    sys.exit(97)
                (state_dir / "cross_pvc_pod").write_text(name)
                emit(cross_probe(
                    name,
                    include_uid=scenario != "post_create_uid_failure",
                ))
            elif metadata.get("labels", {{}}).get(
                "openclaw.dev/validation"
            ) == "ordinary-pod-control":
                expected_manifest = ordinary_control(name)
                expected_manifest.pop("status")
                expected_manifest["metadata"].pop("uid", None)
                expected_manifest["spec"].pop("runtimeClassName", None)
                expected_manifest["spec"].pop("volumes", None)
                if (
                    namespace != "openclaw-enterprise-agw"
                    or re.fullmatch(r"oce-live-ordinary-[0-9]+", name) is None
                    or manifest_json != expected_manifest
                ):
                    print("invalid ordinary control pod", file=sys.stderr)
                    sys.exit(97)
                (state_dir / "ordinary_control_manifest.json").write_text(
                    json.dumps(manifest_json, sort_keys=True)
                )
                (state_dir / "ordinary_control_pod").write_text(name)
                emit(ordinary_control(
                    name,
                    include_uid=(
                        scenario != "ordinary_post_create_uid_failure"
                    ),
                ))
            else:
                print("unsupported fake pod manifest", file=sys.stderr)
                sys.exit(97)
        else:
            print("unsupported fake create manifest", file=sys.stderr)
            sys.exit(97)
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
        ordinary_file = state_dir / "ordinary_control_pod"
        if pod_name == "tenant-a-pod":
            expected_uid = "uid-a-old"
            expected_namespace = "tenant-a-k8s"
            if scenario == "uid_precondition_rejected":
                print("Conflict: pod UID precondition failed", file=sys.stderr)
                sys.exit(1)
            (state_dir / "deleted").write_text(pod_name)
            (state_dir / "deleted_uid").write_text(supplied_uid or "")
            (state_dir / "ephemeral").unlink(missing_ok=True)
        elif cross_file.exists() and pod_name == cross_file.read_text():
            expected_uid = "uid-cross-pvc"
            expected_namespace = "tenant-a-k8s"
            (state_dir / "cross_deleted_uid").write_text(supplied_uid or "")
        elif ordinary_file.exists() and pod_name == ordinary_file.read_text():
            expected_uid = "uid-ordinary-control"
            expected_namespace = "openclaw-enterprise-agw"
            (state_dir / "ordinary_deleted_uid").write_text(supplied_uid or "")
            if scenario == "ordinary_uid_precondition_rejected":
                print("Conflict: pod UID precondition failed", file=sys.stderr)
                sys.exit(1)
        else:
            print("unexpected pod delete target", file=sys.stderr)
            sys.exit(99)
        if (
            delete_namespace != expected_namespace
            or supplied_uid != expected_uid
        ):
            print("Conflict: pod UID precondition failed", file=sys.stderr)
            sys.exit(1)
        if cross_file.exists() and pod_name == cross_file.read_text():
            cross_file.unlink()
        if ordinary_file.exists() and pod_name == ordinary_file.read_text():
            ordinary_file.unlink()
        sys.exit(0)
    if args[:1] == ["wait"] and "--for=condition=Ready" in args:
        pod_name = next(
            value.removeprefix("pod/")
            for value in args
            if value.startswith("pod/")
        )
        ordinary_file = state_dir / "ordinary_control_pod"
        if (
            not ordinary_file.exists()
            or ordinary_file.read_text() != pod_name
            or namespace != "openclaw-enterprise-agw"
        ):
            print("unexpected ready wait target", file=sys.stderr)
            sys.exit(99)
        sys.exit(1 if scenario == "ordinary_not_ready" else 0)
    if args[:1] == ["wait"] and "--for=delete" in args:
        pod_name = next(value.removeprefix("pod/") for value in args if value.startswith("pod/"))
        cross_file = state_dir / "cross_pvc_pod"
        ordinary_file = state_dir / "ordinary_control_pod"
        if cross_file.exists() and cross_file.read_text() == pod_name:
            sys.exit(1)
        if ordinary_file.exists() and ordinary_file.read_text() == pod_name:
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
    timeout = (
        180
        if scenario
        in {"wrong_agw_model", "missing_agw_trace", "missing_agw_request_id"}
        else 90
    )
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
        timeout=timeout,
    )


def _evaluate_native_history(
    messages: list[object],
) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
    payload = {
        "history": {"messages": messages},
        "nonce": "nonce-123",
        "runId": "run-123",
        "exactCommand": "printf TOOL_nonce-123",
        "toolMarker": "TOOL_nonce-123",
        "finalMarker": "DONE_nonce-123",
    }
    program = """
      import { readFileSync } from "node:fs";
      const { evaluateNativeToolHistory } = await import(process.argv[1]);
      const payload = JSON.parse(readFileSync(0, "utf8"));
      try {
        const evidence = evaluateNativeToolHistory(payload);
        process.stdout.write(JSON.stringify({ ok: true, evidence }));
      } catch (error) {
        process.stdout.write(JSON.stringify({ ok: false, error: error.message }));
        process.exitCode = 2;
      }
    """
    result = subprocess.run(
        [
            "node",
            "--input-type=module",
            "-e",
            program,
            NATIVE_HISTORY_EVALUATOR.as_uri(),
        ],
        input=json.dumps(payload),
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return result, json.loads(result.stdout)


def _valid_native_history() -> list[object]:
    run = {"runId": "run-123"}
    return [
        {
            "role": "user",
            "content": "Run the check for nonce-123",
            "__openclaw": run,
        },
        {
            "role": "assistant",
            "content": [
                {
                    "type": "toolCall",
                    "id": "call-1",
                    "name": "exec",
                    "arguments": {"command": "printf TOOL_nonce-123"},
                }
            ],
            "__openclaw": run,
        },
        {
            "role": "toolResult",
            "toolCallId": "call-1",
            "toolName": "exec",
            "isError": False,
            "content": "TOOL_nonce-123",
            "__openclaw": run,
        },
        {
            "role": "assistant",
            "content": "DONE_nonce-123",
            "__openclaw": run,
        },
    ]


def test_native_history_evaluator_accepts_harmless_retries_and_extra_messages() -> None:
    valid = _valid_native_history()
    messages = [
        {"role": "system", "content": "session metadata"},
        valid[0],
        {"role": "assistant", "content": "Working on it"},
        valid[1],
        json.loads(json.dumps(valid[1])),
        valid[2],
        json.loads(json.dumps(valid[2])),
        valid[3],
    ]

    result, output = _evaluate_native_history(messages)

    assert result.returncode == 0, result.stderr
    assert output == {
        "ok": True,
        "evidence": {
            "toolCallCount": 1,
            "execResultCount": 2,
            "finalReplyCount": 1,
        },
    }


@pytest.mark.parametrize(
    "mutate, expected_error",
    [
        (
            lambda messages: messages[1]["content"].__setitem__(0, None),
            "malformed assistant content block",
        ),
        (
            lambda messages: messages[1]["content"][0]["arguments"].__setitem__(
                "command", "printf WRONG"
            ),
            "unexpected exec tool call",
        ),
        (
            lambda messages: messages[2].__setitem__("toolCallId", "call-other"),
            "uncorrelated exec tool result",
        ),
        (
            lambda messages: messages[2].__setitem__("isError", True),
            "exec tool result did not prove success",
        ),
        (
            lambda messages: messages[2].__setitem__("isError", None),
            "exec tool result did not prove success",
        ),
        (
            lambda messages: messages[2].__setitem__(
                "content",
                {
                    "command": "printf TOOL_nonce-123",
                    "output": "TOOL_nonce-123",
                },
            ),
            "unsupported transcript content shape",
        ),
        (
            lambda messages: messages[2].__setitem__(
                "content", "prefix TOOL_nonce-123 suffix"
            ),
            "exec tool result did not prove success",
        ),
    ],
)
def test_native_history_evaluator_rejects_malformed_or_inconsistent_evidence(
    mutate, expected_error: str
) -> None:
    messages = _valid_native_history()
    mutate(messages)

    result, output = _evaluate_native_history(messages)

    assert result.returncode == 2
    assert output == {"ok": False, "error": expected_error}


def test_native_history_evaluator_rejects_multiple_distinct_tool_calls() -> None:
    messages = _valid_native_history()
    messages.insert(
        2,
        {
            "role": "assistant",
            "content": [
                {
                    "type": "toolCall",
                    "id": "call-2",
                    "name": "exec",
                    "arguments": {"command": "printf TOOL_nonce-123"},
                }
            ],
            "__openclaw": {"runId": "run-123"},
        },
    )

    result, output = _evaluate_native_history(messages)

    assert result.returncode == 2
    assert output == {"ok": False, "error": "unexpected tool-call count"}


def test_native_history_evaluator_rejects_multiple_exact_final_replies() -> None:
    messages = _valid_native_history()
    messages.append(json.loads(json.dumps(messages[-1])))

    result, output = _evaluate_native_history(messages)

    assert result.returncode == 2
    assert output == {"ok": False, "error": "unexpected final reply count"}


def test_native_history_evaluator_does_not_accept_mismatched_run_ids() -> None:
    messages = _valid_native_history()
    for message in messages[1:]:
        message["__openclaw"] = {"runId": "run-other"}

    result, output = _evaluate_native_history(messages)

    assert result.returncode == 0, result.stderr
    assert output == {"ok": True, "evidence": None}


def test_native_history_evaluator_requires_the_final_nonce() -> None:
    messages = _valid_native_history()[:-1]

    result, output = _evaluate_native_history(messages)

    assert result.returncode == 0, result.stderr
    assert output == {"ok": True, "evidence": None}


def test_fake_live_run_accepts_harmless_native_tool_retry(tmp_path: Path) -> None:
    result = _run(tmp_path, "native_tool_harmless_retry")

    assert result.returncode == 0, result.stderr
    evidence = (tmp_path / "evidence" / "live-validation-evidence.txt").read_text()
    assert "PASS\tnative-openclaw-tool-execution\t" in evidence
    assert "RESULT\tPASS" in evidence


def test_requires_every_explicit_target_and_replacement_confirmation(
    tmp_path: Path,
) -> None:
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


def test_accepts_raw_one_line_service_keys_for_secret_manager_exports(
    tmp_path: Path,
) -> None:
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


def test_fake_live_run_accepts_valid_runtime_mounts_and_sanitizes_evidence(
    tmp_path: Path,
) -> None:
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
    for call_index, alias in enumerate(
        ("tenant-a", "tenant-b", "tenant-a-replacement"), start=1
    ):
        trace_id = format(call_index, "032x")
        native_request_id = "chatcmpl_" + trace_id
        gateway_request_id = str(9000 + call_index)
        assert (
            f"EVIDENCE\tnative-model-correlation-{alias}\t"
            f"trace-id-sha256={hashlib.sha256(trace_id.encode()).hexdigest()} "
            "native-request-id-sha256="
            f"{hashlib.sha256(native_request_id.encode()).hexdigest()} "
            "gateway-request-id-sha256="
            f"{hashlib.sha256(gateway_request_id.encode()).hexdigest()} "
            "native-model=openclaw/default gateway-model=nova-lite "
            "bedrock-model=amazon.nova-lite-v1:0"
        ) in evidence
        assert trace_id not in evidence
        assert native_request_id not in evidence
    assert "EVIDENCE\ttool-version-aws\taws-cli/2.31.0" in evidence
    assert "EVIDENCE\ttool-version-kubectl\tv1.34.0 darwin/arm64" in evidence
    assert "EVIDENCE\ttool-version-node\tv" in evidence
    assert ("EVIDENCE\tnative-tool-run-id-sha256\t" + ("d" * 64)) in evidence
    assert "EVIDENCE\tordinary-control-kernel\t6.1.99 x86_64" in evidence
    assert "EVIDENCE\tguest-a-block-devices\tvda" in evidence
    assert "EVIDENCE\tguest-b-block-devices\tvda" in evidence
    assert "EVIDENCE\tordinary-control-root\toverlay overlay" in evidence
    assert "EVIDENCE\tordinary-control-block-devices\tnvme0n1" in evidence
    assert "EVIDENCE\tsignature-status\tunsigned;" in evidence
    assert "CLEANUP\tPASS\t" in evidence
    for check in (
        "runtime-isolation",
        "security-context",
        "aws-credential-absence",
        "tenant-storage-isolation",
        "cross-tenant-pvc-mount-denied",
        "guest-vm-boundary",
        "agentgateway-key-authorization",
        "native-openclaw-model-turn",
        "native-openclaw-tool-execution",
        "agentgateway-model-telemetry",
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
    assert (state_dir / "ordinary_deleted_uid").read_text() == "uid-ordinary-control"
    assert not (state_dir / "marker").exists()
    assert not (state_dir / "ephemeral").exists()
    assert not (state_dir / "cross_pvc_pod").exists()
    assert not (state_dir / "ordinary_control_pod").exists()
    ordinary_manifest = json.loads(
        (state_dir / "ordinary_control_manifest.json").read_text()
    )
    assert ordinary_manifest == {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": ordinary_manifest["metadata"]["name"],
            "namespace": "openclaw-enterprise-agw",
            "labels": {
                "app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint",
                "openclaw.dev/validation": "ordinary-pod-control",
            },
        },
        "spec": {
            "automountServiceAccountToken": False,
            "enableServiceLinks": False,
            "restartPolicy": "Never",
            "serviceAccountName": "default",
            "containers": [
                {
                    "name": "ordinary-control",
                    "image": RUNTIME_IMAGE,
                    "command": ["sh", "-c", "sleep 3600"],
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "privileged": False,
                        "readOnlyRootFilesystem": True,
                        "runAsNonRoot": True,
                        "runAsUser": 1000,
                        "runAsGroup": 1000,
                        "seccompProfile": {"type": "RuntimeDefault"},
                        "capabilities": {"drop": ["ALL"]},
                    },
                }
            ],
        },
    }
    assert ordinary_manifest["metadata"]["name"].startswith("oce-live-ordinary-")
    key_calls = [
        json.loads(line)
        for line in (state_dir / "agentgateway_key_calls.jsonl")
        .read_text()
        .splitlines()
    ]
    assert key_calls == [
        {"namespace": "tenant-a-k8s", "pod": "tenant-a-pod"},
        {"namespace": "tenant-b-k8s", "pod": "tenant-b-pod"},
    ]
    assert json.loads((state_dir / "native_tool_execution").read_text()) == {
        "namespace": "oce-system",
        "pod": "oce-api-0",
        "container": "api",
    }
    command_log = (state_dir / "commands.jsonl").read_text()
    assert "tenant-a-secret" not in command_log
    assert "tenant-b-secret" not in command_log
    assert "tenant-a-secret" not in result.stdout + result.stderr
    assert "tenant-b-secret" not in result.stdout + result.stderr
    assert '"kms"' not in command_log
    commands = [json.loads(line) for line in command_log.splitlines()]
    native_tool_commands = [
        command
        for command in commands
        if command["tool"] == "kubectl"
        and any(
            arg.startswith("OCE_NATIVE_HISTORY_EVALUATOR_B64=")
            for arg in command["args"]
        )
    ]
    assert len(native_tool_commands) == 1
    encoded_evaluator = next(
        arg.removeprefix("OCE_NATIVE_HISTORY_EVALUATOR_B64=")
        for arg in native_tool_commands[0]["args"]
        if arg.startswith("OCE_NATIVE_HISTORY_EVALUATOR_B64=")
    )
    executed_evaluator = base64.b64decode(encoded_evaluator, validate=True)
    assert executed_evaluator == NATIVE_HISTORY_EVALUATOR.read_bytes()
    assert (
        "EVIDENCE\tnative-history-evaluator-sha256\t"
        f"{hashlib.sha256(executed_evaluator).hexdigest()}"
    ) in evidence
    port_forward_commands = [
        command
        for command in commands
        if command["tool"] == "kubectl" and "port-forward" in command["args"]
    ]
    assert len(port_forward_commands) == 1
    port_forward_args = port_forward_commands[0]["args"]
    assert "--address=127.0.0.1" in port_forward_args
    assert "service/openclaw-enterprise-api" in port_forward_args
    assert not any(
        "0.0.0.0" in arg or arg == "--address=localhost" for arg in port_forward_args
    )
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


@pytest.mark.parametrize(
    ("scenario", "expected_detail"),
    [
        (
            "sidecar_aws_environment",
            'spec.containers[1] ("credential-sidecar") defines prohibited '
            'AWS credential environment "AWS_ACCESS_KEY_ID"',
        ),
        (
            "init_aws_environment",
            'spec.initContainers[1] ("credential-init") defines prohibited '
            'AWS credential environment "AWS_WEB_IDENTITY_TOKEN_FILE"',
        ),
        (
            "ephemeral_aws_environment",
            'spec.ephemeralContainers[0] ("credential-debugger") defines '
            "prohibited AWS credential environment "
            '"AWS_CONTAINER_CREDENTIALS_FULL_URI"',
        ),
        (
            "secret_aws_mount",
            'spec.containers[1] ("credential-sidecar").volumeMounts[0] mounts '
            'Secret volume "aws-credentials" at credential-like path '
            '"/home/node/.aws"',
        ),
        (
            "sidecar_state_pvc_mount",
            'spec.containers[1] ("state-sidecar").volumeMounts[0] uses '
            "unapproved PersistentVolumeClaim volume "
            '"openclaw-gateway-state" at "/home/node/.openclaw"',
        ),
        (
            "csi_credential_mount",
            'uses unapproved CSI volume "credential-csi" at "/mnt/identity"',
        ),
        (
            "pvc_credential_mount",
            'uses unapproved PersistentVolumeClaim volume "credential-pvc" '
            'at "/mnt/identity"',
        ),
        (
            "hostpath_credential_mount",
            'uses unapproved hostPath volume "host-credentials" at "/mnt/identity"',
        ),
    ],
)
def test_live_run_rejects_credentials_in_every_container_and_volume_source(
    tmp_path: Path,
    scenario: str,
    expected_detail: str,
) -> None:
    result = _run(tmp_path, scenario)

    assert result.returncode != 0
    assert "ERROR [tenant-runtime-contract]" in result.stderr
    assert expected_detail in result.stderr
    evidence = (tmp_path / "evidence" / "live-validation-evidence.txt").read_text()
    assert "FAIL\ttenant-runtime-contract\t" in evidence
    assert "RESULT\tPASS" not in evidence


def test_bash_trace_cannot_expose_service_keys(tmp_path: Path) -> None:
    result = _run(tmp_path, trace=True)

    assert result.returncode == 0, result.stderr
    combined_output = result.stdout + result.stderr
    command_log = (tmp_path / "state" / "commands.jsonl").read_text()
    evidence_files = [
        path.read_text() for path in (tmp_path / "evidence").iterdir() if path.is_file()
    ]
    for secret in ("tenant-a-secret", "tenant-b-secret"):
        assert secret not in combined_output
        assert secret not in command_log
        assert all(secret not in content for content in evidence_files)


def test_kms_signing_occurs_only_when_key_is_explicitly_supplied(
    tmp_path: Path,
) -> None:
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


@pytest.mark.parametrize(
    ("scenario", "expected_error"),
    [
        (
            "sandbox_whole_disk_only",
            "sandbox guest did not expose a virtio block device and partition",
        ),
        (
            "ordinary_whole_disk_only",
            "ordinary control pod did not expose the expected NVMe disk contrast",
        ),
    ],
)
def test_whole_disk_rows_do_not_count_as_partition_evidence(
    tmp_path: Path, scenario: str, expected_error: str
) -> None:
    result = _run(tmp_path, scenario)

    assert result.returncode != 0
    assert f"ERROR [guest-vm-evidence]: {expected_error}" in result.stderr
    evidence = (tmp_path / "evidence" / "live-validation-evidence.txt").read_text()
    assert "FAIL\tguest-vm-evidence\t" in evidence
    assert "RESULT\tPASS" not in evidence


@pytest.mark.parametrize(
    "scenario, failed_check",
    [
        ("wrong_cluster_arn", "eks-cluster"),
        ("port_forward_early_exit", "oce-api-port-forward"),
        ("port_forward_no_marker", "oce-api-port-forward"),
        ("wrong_oce_revision", "oce-deployed-source-revision"),
        ("wrong_cross_code", "oce-tenant-api-isolation"),
        ("cross_tenant_pvc_mounted", "tenant-storage-isolation"),
        ("post_create_uid_failure", "tenant-storage-isolation"),
        ("uid_precondition_rejected", "controller-driven-persistence"),
        ("nonce_suffix", "native-openclaw-model-turn"),
        ("wrong_native_model", "native-openclaw-model-turn"),
        ("wrong_agw_model", "agentgateway-model-telemetry"),
        ("missing_agw_trace", "agentgateway-model-telemetry"),
        ("missing_agw_request_id", "agentgateway-model-telemetry"),
        ("kms_verify_failure", "evidence-signing"),
        ("ordinary_post_create_uid_failure", "guest-vm-evidence"),
        ("ordinary_sandboxed_control", "guest-vm-evidence"),
        ("ordinary_control_has_volume", "guest-vm-evidence"),
        ("ordinary_not_ready", "guest-vm-evidence"),
        ("ordinary_shared_boot_id", "guest-vm-evidence"),
        ("ordinary_invalid_boot_id", "guest-vm-evidence"),
        ("ordinary_sandbox_disk", "guest-vm-evidence"),
        ("sandbox_non_virtio_disk", "guest-vm-evidence"),
        ("sandbox_missing_partition", "guest-vm-evidence"),
        ("sandbox_malformed_partition", "guest-vm-evidence"),
        ("ordinary_uid_precondition_rejected", "temporary-artifact-cleanup"),
        ("native_unauthenticated_accepted", "native-openclaw-model-turn"),
        ("agw_missing_key_accepted", "agentgateway-key-authorization"),
        ("agw_wrong_key_accepted", "agentgateway-key-authorization"),
        ("agw_correct_key_denied", "agentgateway-key-authorization"),
        ("agw_tenant_b_correct_key_denied", "agentgateway-key-authorization"),
        ("agw_key_marker_missing", "agentgateway-key-authorization"),
        ("agw_key_nonce_mismatch", "agentgateway-key-authorization"),
        ("agw_key_malformed_output", "agentgateway-key-authorization"),
        ("native_tool_marker_missing", "native-openclaw-tool-execution"),
        ("native_tool_malformed_output", "native-openclaw-tool-execution"),
        ("native_tool_outcome_error", "native-openclaw-tool-execution"),
        ("native_tool_missing_exec_call", "native-openclaw-tool-execution"),
        ("native_tool_wrong_name", "native-openclaw-tool-execution"),
        ("native_tool_wrong_command", "native-openclaw-tool-execution"),
        ("native_tool_uncorrelated_result", "native-openclaw-tool-execution"),
        ("native_tool_result_marker_missing", "native-openclaw-tool-execution"),
        ("native_tool_wrong_final_reply", "native-openclaw-tool-execution"),
        ("native_tool_invalid_run_hash", "native-openclaw-tool-execution"),
    ],
)
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
    if scenario.startswith("ordinary_"):
        assert (
            tmp_path / "state" / "ordinary_deleted_uid"
        ).read_text() == "uid-ordinary-control"
    if scenario.startswith("agw_"):
        key_calls = [
            json.loads(line)
            for line in (tmp_path / "state" / "agentgateway_key_calls.jsonl")
            .read_text()
            .splitlines()
        ]
        assert key_calls[0] == {
            "namespace": "tenant-a-k8s",
            "pod": "tenant-a-pod",
        }
        if scenario == "agw_tenant_b_correct_key_denied":
            assert key_calls == [
                {"namespace": "tenant-a-k8s", "pod": "tenant-a-pod"},
                {"namespace": "tenant-b-k8s", "pod": "tenant-b-pod"},
            ]
        else:
            assert len(key_calls) == 1
    if scenario.startswith("native_tool_"):
        assert json.loads(
            (tmp_path / "state" / "native_tool_execution").read_text()
        ) == {
            "namespace": "oce-system",
            "pod": "oce-api-0",
            "container": "api",
        }
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
    command_log = (tmp_path / "state" / "commands.jsonl").read_text()
    combined_output = result.stdout + result.stderr + evidence
    for secret in ("tenant-a-secret", "tenant-b-secret"):
        assert secret not in command_log
        assert secret not in combined_output


def test_script_contains_destructive_and_api_contract_guards() -> None:
    source = SCRIPT.read_text()
    evaluator_source = NATIVE_HISTORY_EVALUATOR.read_text(encoding="utf-8")

    assert source.startswith("#!/usr/bin/env bash\nset +x\n")
    assert 'NATIVE_MODEL_ID="openclaw/default"' in source
    assert 'process.env.OPENCLAW_GATEWAY_PASSWORD || ""' in source
    assert 'hostname: "127.0.0.1"' in source
    assert 'path: "/v1/chat/completions"' in source
    assert "OPENCLAW_LIVE_" in source
    assert 'value.normalize("NFKC").trim()' in source
    assert "normalize(text) !== normalize(nonce)" in source
    assert "!text.includes(nonce)" not in source
    assert "model: parsed.model" in source
    assert "requestId: parsed.id" in source
    assert "nonceMatch: true" in source
    assert "headers.traceparent = traceparent" in source
    assert 'AGW_MODEL_ID="nova-lite"' in source
    assert 'BEDROCK_MODEL_ID="amazon.nova-lite-v1:0"' in source
    assert '"trace.id"' in source
    assert r"request\.id" in source
    assert '"gen_ai.provider.name", "bedrock"' in source
    assert '"agw.ai.original_model", gatewayModel' in source
    assert '"gen_ai.request.model", bedrockModel' in source
    assert "unauthenticatedStatus" in source
    assert "rejectUnauthorized: false" not in source
    assert source.count("--dry-run=server") >= 3
    assert "admission caller is not an allowed controller identity" in source
    assert "ephemeral containers are not permitted" in source
    assert 'EXPECTED_OCE_SOURCE_REVISION="' + OCE_SOURCE_REVISION + '"' in source
    assert 'exec 3<"$file"' in source
    assert "credential file must be owned by the effective user" in source
    assert "credential file must have exactly one hard link" in source
    assert "read -r -d '' credential_blob <&3" in source
    assert "jq -er '.data.key' \"$file\"" not in source
    assert 'cat "$file"' not in source
    assert '"kind":"DeleteOptions","preconditions":{"uid":"%s"}' in source
    assert '--raw="/api/v1/namespaces/${namespace}/pods/${pod}"' in source
    assert 'delete pod "$TENANT_A_POD"' not in source
    assert "cross-tenant-pvc-mount-denied" in source
    assert 'ORDINARY_CONTROL_POD="oce-live-ordinary-$$"' in source
    assert "cleanup_ordinary_control_pod" in source
    assert '"openclaw.dev/validation": "ordinary-pod-control"' in source
    assert "(.spec.runtimeClassName == null)" in source
    assert "(.spec.volumes // [] | length == 0)" in source
    assert '.spec.serviceAccountName == "default"' in source
    assert "$ORDINARY_CONTROL_POD_UID" in source
    assert "sandbox guest did not expose a virtio block device and partition" in source
    assert "ordinary control pod unexpectedly exposed sandbox virtio disks" in source
    assert (
        "ordinary control pod did not expose the expected NVMe disk contrast" in source
    )
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
    assert 'path: "/v1/responses"' in source
    assert "if (token !== null) headers.authorization = `Bearer ${token}`;" in source
    assert 'marker: "LIVE_AGENTGATEWAY_KEY_CONTRACT"' in source
    assert ".noKeyStatus == 401 or .noKeyStatus == 403" in source
    assert ".wrongKeyStatus == 401 or .wrongKeyStatus == 403" in source
    assert ".acceptedStatus == 200" in source
    assert ".nonceMatch == true" in source
    assert "verify_agentgateway_key_contract" in source
    assert "const { GatewayClient } = await import(" in source
    assert "evaluateNativeToolHistory" in source
    assert "OCE_NATIVE_HISTORY_EVALUATOR_B64" in source
    assert "const exactCommand = `printf ${toolMarker}`;" in source
    assert "outcome?.runId !== sent.runId" in source
    assert 'block.name !== "exec"' in evaluator_source
    assert "block?.arguments?.command !== exactCommand" in evaluator_source
    assert 'message.toolName !== "exec"' in evaluator_source
    assert "!toolCallIds.has(message.toolCallId)" in evaluator_source
    assert "message.isError !== false" in evaluator_source
    assert (
        "normalize(contentText(message.content)) !== normalize(toolMarker)"
        in evaluator_source
    )
    assert (
        "normalize(assistantReplyText(message.content)) ==="
        in evaluator_source
    )
    assert 'marker: "LIVE_NATIVE_TOOL_EXECUTION"' in source
    assert ".toolCallCount == 1" in source
    assert ".execResultCount >= 1" in source
    assert ".finalReplyCount == 1" in source
    assert ".exactCommand == true" in source
    assert ".resultMarker == true" in source
    assert ".finalReply == true" in source
    assert "stop_oce_api_port_forward >/dev/null 2>&1" in source
    assert 'if wait "$pid" 2>/dev/null; then' in source
    assert "stop_oce_api_port_forward || die" in source
    assert 'delete namespace "$TENANT_A_NAMESPACE"' not in source
    assert 'delete namespace "$TENANT_B_NAMESPACE"' not in source
    assert "delete deployment" not in source
    assert 'rm -f -- "$PERSISTENT_MARKER" "$EPHEMERAL_MARKER"' in source
    assert 'if [[ -n "$KMS_SIGNING_KEY_ID" ]]; then' in source
    assert "unsigned; no KMS key explicitly supplied" in source
