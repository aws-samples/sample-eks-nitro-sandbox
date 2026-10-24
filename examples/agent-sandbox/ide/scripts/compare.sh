#!/usr/bin/env bash
# Read the three sandbox signals from the editor's pod, and the same three from an
# ordinary pod on the same node, side by side.
#
#   ./scripts/compare.sh
#
# Creates one ordinary (non-sandboxed) pod on the node the editor is on, reads
# `uname -rv`, `cat /proc/uptime` and `ls /sys/block` in each, then deletes that
# pod by its exact name. It touches nothing else.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl sed
show_context
require_our_namespace

resource_exists kc "pod/$SANDBOX" \
  || die "pod/$SANDBOX is not there (or could not be read); run ./scripts/setup.sh first"

node="$(kc get pod "$SANDBOX" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" \
  || die "could not read the node the editor's pod is on"
[[ -n "$node" ]] || die "the editor's pod has no node yet; wait for it to be scheduled"

cleanup_ordinary() {
  # By exact name, never a label selector.
  kc delete pod "$ORDINARY_POD" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
}
trap cleanup_ordinary EXIT

step "an ordinary pod on the same node ($node)"
sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s/__NODE_NAME__/$node/g" \
  "$SAMPLE_DIR/deploy/pod-ordinary.yaml" | kc apply -f -
kc wait --for=condition=Ready "pod/$ORDINARY_POD" --timeout=5m \
  || die "the ordinary pod never became Ready; check 'kubectl -n $NAMESPACE describe pod $ORDINARY_POD'"

for probe in 'uname -rv' 'cat /proc/uptime' 'ls /sys/block' 'cat /sys/class/dmi/id/product_name'; do
  step "$probe"
  echo "--- sandboxed pod/$SANDBOX ---"
  kc exec "$SANDBOX" -- sh -c "$probe" 2>&1 | sed 's/^/  /'
  echo "--- ordinary pod/$ORDINARY_POD ---"
  kc exec "$ORDINARY_POD" -- sh -c "$probe" 2>&1 | sed 's/^/  /'
done

step "when each pod started, to compare with its uptime"
kc get pod "$SANDBOX" "$ORDINARY_POD" -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp,RUNTIMECLASS:.spec.runtimeClassName'

step "where the workspace comes from, inside the guest"
kc exec "$SANDBOX" -- sh -c "df -h $WORKSPACE /; awk '\$2==\"$WORKSPACE\"{print \$1, \$3}' /proc/mounts" 2>&1 | sed 's/^/  /'

echo
echo "deleting pod/$ORDINARY_POD (by name)"
