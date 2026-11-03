#!/usr/bin/env bash
# The raw FQDN cache read (criterion 13), as a reader step after ./test.sh. Read-only: two DNS
# lookups from the sandbox pod and one read of a Cilium agent.
#
#   ./scripts/fqdn-cache-read.sh
#
# A lookup row lives in a Cilium agent's FQDN cache only for the DNS answer's TTL, so a read
# taken minutes after test.sh can hold none. So this step makes its own lookups first: from the
# sandbox pod (nitro) it looks up the allowed name and the denied name, then reads the sandbox
# node's agent at once. Both lookups must answer: the policy drops the denied name's connection,
# not its lookup. It passes only when the cache holds at least one lookup row for the sandbox
# pod's endpoint for each name, and only then prints the cache's header and that endpoint's
# lookup rows.
#
# Exit codes: 0 both names have a lookup row for the sandbox pod's endpoint. 1 the reads worked,
# but the cache holds no such row for a name (or no rows at all), or the demo namespace is not
# the sample's. 2 a read or a lookup failed or came back empty, so nothing was checked.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"

ALLOW_FQDN="checkip.amazonaws.com"  # test.sh stage 7's names
DENY_FQDN="example.net"
ts() { date -u +%FT%TZ; }
cannot() { printf '%s %s\n' "$(_red 'COULD NOT CHECK:')" "$*" >&2; echo "fqdn-cache-read: nothing was checked (exit 2)" >&2; exit 2; }
missing() { printf '%s %s\n' "$(_red 'NO EVIDENCE:')" "$*" >&2; echo "fqdn-cache-read: FAIL (exit 1)" >&2; exit 1; }
oneline() { tr '\n' ' ' <<<"$1" | head -c 300; }

command -v kubectl >/dev/null 2>&1 || cannot "kubectl is required but was not found on PATH"
[[ -s "$KUBECONFIG" ]] || cannot "$KUBECONFIG is missing; run ./setup.sh first"
ns_rc=0; namespace_is_ours || ns_rc=$?
case "$ns_rc" in
  0) ;;
  1) missing "namespace $NAMESPACE is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL; it is not this sample's" ;;
  2) cannot "could not read namespace $NAMESPACE" ;;
  *) cannot "namespace $NAMESPACE does not exist; run ./test.sh first" ;;
esac
ep="$(kubectl -n "$NAMESPACE" get ciliumendpoint nitro -o 'jsonpath={.status.id}' 2>&1)" \
  || cannot "could not read the sandbox pod's Cilium endpoint: $(oneline "$ep")"
[[ "$ep" =~ ^[0-9]+$ ]] || cannot "the sandbox pod's Cilium endpoint id read back as '$ep', not a number"
node="$(kubectl -n "$NAMESPACE" get pod nitro -o 'jsonpath={.spec.nodeName}' 2>&1)" \
  || cannot "could not read the sandbox pod's node: $(oneline "$node")"
[[ -n "$node" && "$node" != *[[:space:]]* ]] || cannot "the sandbox pod's node read back as '$node'"
agent="$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$node" \
  -o 'jsonpath={.items[*].metadata.name}' 2>&1)" || cannot "could not read the Cilium agent on node $node: $(oneline "$agent")"
[[ -n "$agent" && "$agent" != *[[:space:]]* ]] || cannot "expected exactly one Cilium agent on node $node, found '$agent'"

for name in "$ALLOW_FQDN" "$DENY_FQDN"; do
  out="$(kubectl -n "$NAMESPACE" exec nitro -- nslookup "$name" 2>&1)"; rc=$?
  # Answer records only: the Address lines after a Name line, as test.sh counts them.
  n="$(awk '/^Name:/{named=1; next} named && /^Address:/{n++} END{print n+0}' <<<"$out")"
  ((rc == 0 && n > 0)) || cannot "the lookup of $name from the sandbox pod failed (rc=$rc, $n answer record(s)): $(oneline "$out")"
  echo "== $(ts) nslookup $name from the sandbox pod: rc=0, $n answer record(s)"
done

cache="$(kubectl -n kube-system exec "$agent" -c cilium-agent -- cilium-dbg fqdn cache list 2>&1)"; rc=$?
((rc == 0)) || cannot "the cache read on $agent failed (rc=$rc): $(oneline "$cache")"
header="$(grep -m1 -E '^Endpoint +Source +FQDN +TTL +ExpirationTime +IPs' <<<"$cache")" \
  || cannot "the cache read on $agent printed no 'Endpoint Source FQDN TTL ExpirationTime IPs' header: $(oneline "$cache")"
rows="$(awk '$1 ~ /^[0-9]+$/ && NF >= 5' <<<"$cache")"
[[ -n "$rows" ]] || missing "the cache on $agent holds no rows at all, only its header: no lookup was recorded"
kept="$(awk -v ep="$ep" '$1 == ep && $2 == "lookup"' <<<"$rows")"
count() { awk -v f="$1." '$3 == f' <<<"$kept" | grep -c .; }
absent=""
for name in "$ALLOW_FQDN" "$DENY_FQDN"; do
  (($(count "$name") > 0)) || absent="${absent:+$absent and }$name."
done
if [[ -n "$absent" ]]; then
  sources="$(awk -v ep="$ep" '$1 == ep {print $2}' <<<"$rows" | sort -u | paste -sd ' ' -)"
  others="$(awk -v ep="$ep" '$1 != ep && $2 == "lookup" {print $1}' <<<"$rows" | sort -u | paste -sd ' ' -)"
  missing "endpoint $ep (the sandbox pod) has no lookup row for $absent in the cache on $agent (its rows there: ${sources:-none}; lookup rows for other endpoints: ${others:-none})"
fi
echo "== $(ts) $agent (the sandbox pod's node $node): cilium-dbg fqdn cache list, the header and endpoint $ep's lookup rows"
printf '%s\n' "$header" "$kept"
echo "fqdn-cache-read: PASS: endpoint $ep has lookup rows for $ALLOW_FQDN. ($(count "$ALLOW_FQDN")) and $DENY_FQDN. ($(count "$DENY_FQDN"))"
