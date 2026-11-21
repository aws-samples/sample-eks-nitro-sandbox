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

# The one Cilium lock file: exactly one anchored CILIUM_VERSION line, and it is 1.20.5 (#281).
lock="$SAMPLE_DIR_REAL/cilium.lock"
if need_file "$lock" "the Cilium lock file holds 1.20.5"; then
  n="$(grep -cE '^CILIUM_VERSION=' "$lock")"; v="$(sed -n 's/^CILIUM_VERSION=//p' "$lock")"
  [[ "$n" == 1 && "$v" == 1.20.5 ]]
  check "ACCEPT cilium.lock: exactly one CILIUM_VERSION line, 1.20.5" 0 $? "$lock"
fi
finish
