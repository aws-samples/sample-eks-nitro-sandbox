#!/usr/bin/env bash
# test-static.sh: static checks of the tracked sample folder, each proved both ways: the real
# folder must pass, and a planted copy (one bad line added to a copy under the work folder) must
# be refused, so a scan that matches nothing cannot pass.
#   cilium-version   one lock file holds the Cilium version (#281)
#   owner-tags       no auto-delete or Owner tag key (#281)
#   account-ids      no 12-digit account-shaped number outside scripts/testlib/ (AGENTS.md)
#   em-dash          no em dash character
#   exposure         no LoadBalancer, NodePort, Ingress, hostPort or hostNetwork (#281, AGENTS.md)
#   network-policy   the sample ships no network policy (#281, AGENTS.md)
#
#   examples/setup/cilium-bottlerocket/scripts/test-static.sh
source "$(dirname "$0")/testlib/harness.sh"
SCAN="$TESTLIB/static_scan.py"

# plant <rule>: a copy of the sample folder with one line the rule must refuse.
plant() {
  local d="$WORK/planted-$1"
  rm -rf "$d"; cp -r "$SAMPLE_DIR_REAL" "$d"
  mkdir -p "$d/deploy" "$d/scripts"
  case "$1" in
    cilium-version) printf 'helm upgrade --install cilium "$CHART" --version 1.20.4\n' >> "$d/scripts/planted.sh" ;;
    owner-tags)     printf 'tags:\n  auto-delete: "no"\n' >> "$d/deploy/planted.yaml" ;;
    account-ids)    "$REAL_PYTHON" -c 'import sys; open(sys.argv[1], "a").write("AWS_ACCOUNT_ID=" + "2" * 12 + "\n")' "$d/config.env.example" ;;
    em-dash)        "$REAL_PYTHON" -c 'import sys; open(sys.argv[1], "a").write("A line with an em dash \u2014 here.\n")' "$d/config.env.example" ;;
    exposure)       printf 'apiVersion: v1\nkind: Service\nmetadata:\n  name: planted\nspec:\n  type: LoadBalancer\n' >> "$d/deploy/planted.yaml" ;;
    network-policy) printf 'apiVersion: cilium.io/v2\nkind: CiliumNetworkPolicy\nmetadata:\n  name: planted\n' >> "$d/deploy/planted.yaml" ;;
  esac
  printf '%s\n' "$d"
}

for rule in cilium-version owner-tags account-ids em-dash exposure network-policy; do
  run_real "$WORK/$rule-real.log" python3 "$SCAN" "$rule" "$SAMPLE_DIR_REAL"
  check "ACCEPT the tracked sample folder: $rule finds nothing" 0 "$RC" "$WORK/$rule-real.log"
  d="$(plant "$rule")"
  run_real "$WORK/$rule-planted.log" python3 "$SCAN" "$rule" "$d"
  check "REJECT a copy with one planted line: $rule finds it" 1 "$RC" "$WORK/$rule-planted.log" "^(scripts/planted\.sh|deploy/planted\.yaml|config\.env\.example):[0-9]+: $rule: "
done
# A comment that names a forbidden value is not a finding (anchored, comments stripped).
d="$WORK/planted-comment"; rm -rf "$d"; cp -r "$SAMPLE_DIR_REAL" "$d"; mkdir -p "$d/deploy"
printf '# type: LoadBalancer is never used here\napiVersion: v1\nkind: Service\nmetadata:\n  name: c\nspec:\n  type: ClusterIP\n' > "$d/deploy/comment.yaml"
run_real "$WORK/comment.log" python3 "$SCAN" exposure "$d"
check "ACCEPT a ClusterIP Service whose comment names LoadBalancer" 0 "$RC" "$WORK/comment.log"

# The helper pods of setup.sh and test.sh (deploy/probe/): neither mounts a service account token
# or sets CPU or memory requests or limits. The filler pod, which only sleeps and holds an IP,
# also has the hardening of the walkthrough pods: a non-root user, the default seccomp filter, no
# privilege escalation, no capability and a read-only root file system. The node probe keeps its
# host access (privileged, host PID namespace, host paths).
helper_pods() { # helper_pods <sample dir>: one line per finding; exit 1 when it finds one
  "$REAL_PYTHON" - "$1" <<'PY'
import sys
import yaml
bad = []
for name in ("filler-pod.yaml", "node-probe.yaml"):
    spec = yaml.safe_load(open(f"{sys.argv[1]}/deploy/probe/{name}"))["spec"]
    if spec.get("automountServiceAccountToken") is not False:
        bad.append(f"{name}: automountServiceAccountToken is not false")
    for c in spec["containers"]:
        if c.get("resources"):
            bad.append(f"{name}: container {c['name']} sets resources")
        if name != "filler-pod.yaml":
            continue
        sc = c.get("securityContext") or {}
        if sc.get("readOnlyRootFilesystem") is not True:
            bad.append(f"{name}: container {c['name']} has no read-only root file system")
        if sc.get("allowPrivilegeEscalation") is not False or (sc.get("capabilities") or {}).get("drop") != ["ALL"] or sc.get("privileged"):
            bad.append(f"{name}: container {c['name']} can escalate or keeps a capability")
    if name == "filler-pod.yaml":
        psc = spec.get("securityContext") or {}
        if (psc.get("seccompProfile") or {}).get("type") != "RuntimeDefault":
            bad.append(f"{name}: no RuntimeDefault seccomp profile")
        if psc.get("runAsNonRoot") is not True or spec.get("hostPID") or spec.get("hostNetwork"):
            bad.append(f"{name}: runs as root or in a host namespace")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}
helper_run() { RC=0; helper_pods "$2" >"$1" 2>&1 || RC=$?; } # helper_run <log> <sample dir>; sets RC
helper_run "$WORK/helper-pods-real.log" "$SAMPLE_DIR_REAL"
check "ACCEPT the helper pods: no service account token on either, the filler pod hardened, no requests or limits" 0 "$RC" "$WORK/helper-pods-real.log"
while IFS='#' read -r what file sedexpr pat; do
  [[ -n "$what" ]] || continue
  d="$WORK/planted-helper"; rm -rf "$d"; cp -r "$SAMPLE_DIR_REAL" "$d"; sed -i "$sedexpr" "$d/deploy/probe/$file"
  helper_run "$WORK/helper-pods-bad.log" "$d"
  check "REJECT $what" 1 "$RC" "$WORK/helper-pods-bad.log" "$pat"
done <<'CASES'
a node probe that mounts the service account token#node-probe.yaml#/automountServiceAccountToken: false/d#^node-probe\.yaml: automountServiceAccountToken is not false$
a filler pod that mounts the service account token#filler-pod.yaml#/automountServiceAccountToken: false/d#^filler-pod\.yaml: automountServiceAccountToken is not false$
a filler pod with a writable root file system#filler-pod.yaml#s/readOnlyRootFilesystem: true/readOnlyRootFilesystem: false/#^filler-pod\.yaml: container main has no read-only root file system$
a filler pod with no seccomp profile#filler-pod.yaml#/seccompProfile:/,/type: RuntimeDefault/d#^filler-pod\.yaml: no RuntimeDefault seccomp profile$
a filler pod with a memory request#filler-pod.yaml#s/^      command: \["sleep", "3600"\]$/      command: ["sleep", "3600"]\n      resources: {requests: {memory: 8Mi}}/#^filler-pod\.yaml: container main sets resources$
CASES

# The one Cilium lock file: exactly one anchored CILIUM_VERSION line, and it is 1.20.5 (#281).
lock="$SAMPLE_DIR_REAL/cilium.lock"
if need_file "$lock" "the Cilium lock file holds 1.20.5"; then
  n="$(grep -cE '^CILIUM_VERSION=' "$lock")"; v="$(sed -n 's/^CILIUM_VERSION=//p' "$lock")"
  [[ "$n" == 1 && "$v" == 1.20.5 ]]
  check "ACCEPT cilium.lock: exactly one CILIUM_VERSION line, 1.20.5" 0 $? "$lock"
fi
finish
