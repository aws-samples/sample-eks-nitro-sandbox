#!/usr/bin/env bash
# shellcheck source=../../../../scripts/lib/require-bash.sh
. "$(dirname "$0")/../../../../scripts/lib/require-bash.sh"
set +x
set -Eeuo pipefail

umask 077

KUBE_CONTEXT=""
NAMESPACE="openclaw-system"
RELEASE_NAME="oce"
LOCAL_PORT="18080"
RELAY_PORT="18080"
API_PORT="8080"
STARTUP_TIMEOUT_SECONDS="120"
CLEANUP_TIMEOUT_SECONDS="30"
READY_FILE=""
STATE_FILE=""

RELAY_NAME=""
EGRESS_POLICY=""
API_INGRESS_POLICY=""
CREATED="false"
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
TUNNEL_READY="false"
STARTUP_DEADLINE=0
STARTUP_SECONDS_REMAINING=0

usage() {
  printf '%s\n' \
    'Usage: oce-api-tunnel.sh --kube-context NAME [options]' \
    '' \
    'Required:' \
    '  --kube-context NAME' \
    '' \
    'Optional:' \
    '  --namespace NAME       OCE namespace (default: openclaw-system)' \
    '  --release-name NAME    Helm release name (default: oce)' \
    '  --local-port PORT      Local loopback port (default: 18080)' \
    '  --startup-timeout-seconds SECONDS' \
    '                         Total relay and port-forward timeout (default: 120)' \
    '  --cleanup-timeout-seconds SECONDS' \
    '                         Temporary-resource cleanup timeout (default: 30)' \
    '  --ready-file PATH      Write only after this helper owns the local port' \
    '  --state-file PATH      Record exact temporary resources and cleanup state'
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

refresh_startup_budget() {
  STARTUP_SECONDS_REMAINING=$((STARTUP_DEADLINE - SECONDS))
  ((STARTUP_SECONDS_REMAINING > 0)) ||
    die "OCE API tunnel startup timeout elapsed"
}

write_state() {
  local cleanup_status="$1"
  [[ -n "$STATE_FILE" ]] || return 0
  jq -cn \
    --arg namespace "$NAMESPACE" \
    --arg relayPod "$RELAY_NAME" \
    --arg egressPolicy "$EGRESS_POLICY" \
    --arg apiIngressPolicy "$API_INGRESS_POLICY" \
    --arg cleanupStatus "$cleanup_status" \
    '{
      namespace: $namespace,
      relayPod: $relayPod,
      egressPolicy: $egressPolicy,
      apiIngressPolicy: $apiIngressPolicy,
      cleanupStatus: $cleanupStatus
    }' >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# shellcheck disable=SC2329  # Invoked by the trap-driven cleanup path.
resources_absent() {
  local output
  output="$(
    kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
      --request-timeout="${CLEANUP_TIMEOUT_SECONDS}s" get \
      "pod/$RELAY_NAME" \
      "networkpolicy/$EGRESS_POLICY" \
      "networkpolicy/$API_INGRESS_POLICY" \
      --ignore-not-found=true -o name
  )" || return 1
  [[ -z "$output" ]]
}

# shellcheck disable=SC2329  # Invoked indirectly by the signal and exit traps.
cleanup() {
  local status=$?
  local cleanup_failed="false"
  trap - EXIT HUP INT TERM
  if [[ -n "$PORT_FORWARD_PID" ]] &&
    kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    kill -TERM "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  if [[ -n "$PORT_FORWARD_LOG" ]]; then
    rm -f -- "$PORT_FORWARD_LOG"
    PORT_FORWARD_LOG=""
  fi
  if [[ "$CREATED" == "true" ]]; then
    kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
      --request-timeout="${CLEANUP_TIMEOUT_SECONDS}s" delete \
      "pod/$RELAY_NAME" \
      "networkpolicy/$EGRESS_POLICY" \
      "networkpolicy/$API_INGRESS_POLICY" \
      --ignore-not-found=true --wait=true \
      --timeout="${CLEANUP_TIMEOUT_SECONDS}s" >/dev/null 2>&1 ||
      cleanup_failed="true"
    resources_absent || cleanup_failed="true"
  fi
  if [[ "$cleanup_failed" == "true" ]]; then
    write_state "failed" || true
    printf 'ERROR: temporary API relay cleanup could not be verified\n' >&2
    exit 70
  fi
  write_state "complete" || exit 70
  exit "$status"
}

while (($#)); do
  case "$1" in
    --kube-context)
      (($# >= 2)) || die "--kube-context requires a value"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --namespace)
      (($# >= 2)) || die "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --release-name)
      (($# >= 2)) || die "--release-name requires a value"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --local-port)
      (($# >= 2)) || die "--local-port requires a value"
      LOCAL_PORT="$2"
      shift 2
      ;;
    --startup-timeout-seconds)
      (($# >= 2)) || die "--startup-timeout-seconds requires a value"
      STARTUP_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --cleanup-timeout-seconds)
      (($# >= 2)) || die "--cleanup-timeout-seconds requires a value"
      CLEANUP_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --ready-file)
      (($# >= 2)) || die "--ready-file requires a value"
      READY_FILE="$2"
      shift 2
      ;;
    --state-file)
      (($# >= 2)) || die "--state-file requires a value"
      STATE_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$KUBE_CONTEXT" ]] || die "--kube-context is required"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  die "namespace must be a DNS label"
[[ "$RELEASE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  die "release name must be a DNS label"
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] ||
  die "local port must be an integer"
((LOCAL_PORT >= 1024 && LOCAL_PORT <= 65535)) ||
  die "local port must be between 1024 and 65535"
[[ "$STARTUP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] ||
  die "startup timeout must be an integer"
((STARTUP_TIMEOUT_SECONDS >= 1 && STARTUP_TIMEOUT_SECONDS <= 600)) ||
  die "startup timeout must be between 1 and 600 seconds"
[[ "$CLEANUP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] ||
  die "cleanup timeout must be an integer"
((CLEANUP_TIMEOUT_SECONDS >= 1 && CLEANUP_TIMEOUT_SECONDS <= 120)) ||
  die "cleanup timeout must be between 1 and 120 seconds"
if [[ -n "$READY_FILE" || -n "$STATE_FILE" ]]; then
  [[ -n "$READY_FILE" && -n "$STATE_FILE" ]] ||
    die "--ready-file and --state-file must be provided together"
  for control_file in "$READY_FILE" "$STATE_FILE"; do
    [[ "$control_file" == /* ]] || die "control file paths must be absolute"
    [[ ! -e "$control_file" && ! -L "$control_file" ]] ||
      die "control files must not already exist"
    control_parent="$(dirname "$control_file")"
    [[ -d "$control_parent" && ! -L "$control_parent" ]] ||
      die "control file parent must be a non-symlink directory"
    control_mode="$(stat -f '%Lp' "$control_parent" 2>/dev/null ||
      stat -c '%a' "$control_parent" 2>/dev/null)" ||
      die "could not inspect control file parent"
    [[ "$control_mode" == "700" ]] ||
      die "control file parent must have mode 0700"
  done
fi

for command in chmod dirname grep jq kubectl mktemp openssl rm sleep stat; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

STARTUP_DEADLINE=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
refresh_startup_budget
kubectl --context "$KUBE_CONTEXT" config get-contexts "$KUBE_CONTEXT" \
  --no-headers >/dev/null 2>&1 ||
  die "kube context does not exist"
refresh_startup_budget

selector="app.kubernetes.io/name=openclaw-enterprise,app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/component=api"
api_pods="$(
  kubectl --context "$KUBE_CONTEXT" \
    --request-timeout="${STARTUP_SECONDS_REMAINING}s" \
    --namespace "$NAMESPACE" get pods \
    --selector "$selector" -o json
)" || die "could not list OCE API pods"
refresh_startup_budget

api_record="$(
  jq -er '
    [
      .items[]
      | select(.status.phase == "Running")
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | select(.metadata.deletionTimestamp == null)
      | {
          name: .metadata.name,
          uid: .metadata.uid,
          ip: .status.podIP,
          image: (
            [.spec.containers[] | select(.name == "api") | .image]
            | if length == 1 then .[0] else error("expected one api container") end
          )
        }
    ]
    | if length == 1 then .[0] else error("expected exactly one ready OCE API pod") end
  ' <<<"$api_pods"
)" || die "expected exactly one ready OCE API pod"
refresh_startup_budget

API_POD="$(jq -er '.name' <<<"$api_record")"
API_POD_UID="$(jq -er '.uid' <<<"$api_record")"
API_POD_IP="$(jq -er '.ip' <<<"$api_record")"
API_IMAGE="$(jq -er '.image' <<<"$api_record")"
[[ "$API_POD" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
  die "OCE API pod name is invalid"
[[ "$API_POD_UID" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  die "OCE API pod UID is invalid"
[[ "$API_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] ||
  die "OCE API image must be pinned by SHA-256 digest"

if [[ "$API_POD_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  IFS=. read -r octet1 octet2 octet3 octet4 <<<"$API_POD_IP"
  for octet in "$octet1" "$octet2" "$octet3" "$octet4"; do
    ((10#$octet <= 255)) || die "OCE API pod IP is invalid"
  done
  API_CIDR="${API_POD_IP}/32"
elif [[ "$API_POD_IP" =~ ^[0-9A-Fa-f:]+$ && "$API_POD_IP" == *:* ]]; then
  API_CIDR="${API_POD_IP}/128"
else
  die "OCE API pod IP is invalid"
fi

nonce="$(openssl rand -hex 8)"
[[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || die "could not generate relay identity"
refresh_startup_budget
RELAY_NAME="oce-api-loopback-relay-${nonce}"
EGRESS_POLICY="${RELAY_NAME}-egress"
API_INGRESS_POLICY="${RELAY_NAME}-api-ingress"
write_state "pending"

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

manifest="$(
  jq -cn \
    --arg namespace "$NAMESPACE" \
    --arg relay "$RELAY_NAME" \
    --arg nonce "$nonce" \
    --arg apiPod "$API_POD" \
    --arg apiPodUid "$API_POD_UID" \
    --arg apiPodIp "$API_POD_IP" \
    --arg apiCidr "$API_CIDR" \
    --arg image "$API_IMAGE" \
    --arg release "$RELEASE_NAME" \
    --argjson relayPort "$RELAY_PORT" \
    --argjson apiPort "$API_PORT" '
    {
      apiVersion: "v1",
      kind: "List",
      items: [
        {
          apiVersion: "v1",
          kind: "Pod",
          metadata: {
            name: $relay,
            namespace: $namespace,
            labels: {
              "app.kubernetes.io/name": "oce-api-loopback-relay",
              "app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint",
              "openclaw.dev/api-relay-id": $nonce
            },
            annotations: {
              "openclaw.dev/api-pod": $apiPod,
              "openclaw.dev/api-pod-uid": $apiPodUid
            }
          },
          spec: {
            automountServiceAccountToken: false,
            enableServiceLinks: false,
            restartPolicy: "Never",
            terminationGracePeriodSeconds: 1,
            securityContext: {
              runAsNonRoot: true,
              runAsUser: 1000,
              runAsGroup: 1000,
              seccompProfile: {type: "RuntimeDefault"}
            },
            containers: [
              {
                name: "relay",
                image: $image,
                imagePullPolicy: "IfNotPresent",
                args: [
                  "-e",
                  "const net=require(\"node:net\"),h=process.env.OCE_API_POD_IP,p=Number(process.env.OCE_API_PORT),l=Number(process.env.RELAY_PORT);net.createServer(c=>{const u=net.connect(p,h);c.pipe(u);u.pipe(c);const x=()=>{c.destroy();u.destroy()};c.on(\"error\",x);u.on(\"error\",x)}).listen(l,\"127.0.0.1\")"
                ],
                env: [
                  {name: "OCE_API_POD_IP", value: $apiPodIp},
                  {name: "OCE_API_PORT", value: ($apiPort | tostring)},
                  {name: "RELAY_PORT", value: ($relayPort | tostring)}
                ],
                ports: [
                  {name: "loopback", containerPort: $relayPort, protocol: "TCP"}
                ],
                resources: {
                  requests: {cpu: "10m", memory: "32Mi"},
                  limits: {cpu: "100m", memory: "128Mi"}
                },
                securityContext: {
                  allowPrivilegeEscalation: false,
                  privileged: false,
                  readOnlyRootFilesystem: true,
                  capabilities: {drop: ["ALL"]}
                }
              }
            ]
          }
        },
        {
          apiVersion: "networking.k8s.io/v1",
          kind: "NetworkPolicy",
          metadata: {
            name: ($relay + "-egress"),
            namespace: $namespace,
            labels: {
              "app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint",
              "openclaw.dev/api-relay-id": $nonce
            }
          },
          spec: {
            podSelector: {
              matchLabels: {
                "app.kubernetes.io/name": "oce-api-loopback-relay",
                "openclaw.dev/api-relay-id": $nonce
              }
            },
            policyTypes: ["Ingress", "Egress"],
            ingress: [],
            egress: [
              {
                to: [{ipBlock: {cidr: $apiCidr}}],
                ports: [{protocol: "TCP", port: $apiPort}]
              }
            ]
          }
        },
        {
          apiVersion: "networking.k8s.io/v1",
          kind: "NetworkPolicy",
          metadata: {
            name: ($relay + "-api-ingress"),
            namespace: $namespace,
            labels: {
              "app.kubernetes.io/managed-by": "openclaw-enterprise-blueprint",
              "openclaw.dev/api-relay-id": $nonce
            }
          },
          spec: {
            podSelector: {
              matchLabels: {
                "app.kubernetes.io/name": "openclaw-enterprise",
                "app.kubernetes.io/instance": $release,
                "app.kubernetes.io/component": "api"
              }
            },
            policyTypes: ["Ingress"],
            ingress: [
              {
                from: [
                  {
                    podSelector: {
                      matchLabels: {
                        "app.kubernetes.io/name": "oce-api-loopback-relay",
                        "openclaw.dev/api-relay-id": $nonce
                      }
                    }
                  }
                ],
                ports: [{protocol: "TCP", port: $apiPort}]
              }
            ]
          }
        }
      ]
    }'
)" || die "could not build relay manifest"
refresh_startup_budget

CREATED="true"
printf '%s\n' "$manifest" |
  kubectl --context "$KUBE_CONTEXT" \
    --request-timeout="${STARTUP_SECONDS_REMAINING}s" \
    create -f - >/dev/null ||
  die "could not create the temporary API relay"

refresh_startup_budget
kubectl --context "$KUBE_CONTEXT" \
  --request-timeout="${STARTUP_SECONDS_REMAINING}s" \
  --namespace "$NAMESPACE" wait \
  --for=condition=Ready "pod/$RELAY_NAME" \
  --timeout="${STARTUP_SECONDS_REMAINING}s" >/dev/null ||
  die "temporary API relay did not become ready"

refresh_startup_budget

PORT_FORWARD_LOG="$(mktemp "${TMPDIR:-/tmp}/oce-api-tunnel-port-forward.XXXXXX")"
chmod 600 "$PORT_FORWARD_LOG"
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" port-forward \
  --address=127.0.0.1 "pod/$RELAY_NAME" \
  "${LOCAL_PORT}:${RELAY_PORT}" >"$PORT_FORWARD_LOG" 2>&1 &
PORT_FORWARD_PID=$!

forwarding_line="Forwarding from 127.0.0.1:${LOCAL_PORT} -> ${RELAY_PORT}"
while ((SECONDS < STARTUP_DEADLINE)); do
  kill -0 "$PORT_FORWARD_PID" 2>/dev/null ||
    die "local port-forward exited before becoming ready"
  if grep -Fqx "$forwarding_line" "$PORT_FORWARD_LOG"; then
    kill -0 "$PORT_FORWARD_PID" 2>/dev/null ||
      die "local port-forward exited while becoming ready"
    printf 'OCE API tunnel: http://127.0.0.1:%s -> %s/%s:8080\n' \
      "$LOCAL_PORT" "$NAMESPACE" "$API_POD" >&2
    printf 'The relay is temporary and will be removed when this command stops.\n' >&2
    if [[ -n "$READY_FILE" ]]; then
      (set -o noclobber; printf '%s\n' "$forwarding_line" >"$READY_FILE") ||
        die "could not publish the private tunnel readiness signal"
      chmod 600 "$READY_FILE"
    fi
    TUNNEL_READY="true"
    break
  fi
  sleep 0.1
done
[[ "$TUNNEL_READY" == "true" ]] ||
  die "local port-forward did not become ready"

set +e
while kill -0 "$PORT_FORWARD_PID" 2>/dev/null; do
  sleep 0.2
done
wait "$PORT_FORWARD_PID"
status=$?
set -e
PORT_FORWARD_PID=""
rm -f -- "$PORT_FORWARD_LOG"
PORT_FORWARD_LOG=""
exit "$status"
