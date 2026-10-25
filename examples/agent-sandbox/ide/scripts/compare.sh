#!/usr/bin/env bash
# Read the four sandbox signals from the editor's pod, and the same four from an
# ordinary pod on the same node, side by side.
#
#   ./scripts/compare.sh
#
# Creates one ordinary (non-sandboxed) pod on the node the editor is on, reads
# `uname -rv`, `cat /proc/uptime`, `ls /sys/block` and
# `cat /sys/class/dmi/id/product_name` in each, then deletes that pod by its exact
# name. It touches nothing else.
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
  # By exact name, never a label selector: a selector meant for one helper pod
  # can match another demo's pod on a shared cluster. A delete that fails is
  # reported, not hidden, because the pod would otherwise sit on the node until
  # its own 600-second sleep ends.
  if ! kc delete pod "$ORDINARY_POD" --ignore-not-found --wait=true --timeout=120s; then
    echo "error: could not delete pod/$ORDINARY_POD. Remove it with:" >&2
    echo "  $(kubectl_cmd) -n $NAMESPACE delete pod $ORDINARY_POD" >&2
    # The trap does not change the exit status on its own, so set it here: a
    # helper pod left running on a shared cluster is an incomplete run.
    exit 1
  fi
}
trap cleanup_ordinary EXIT

step "an ordinary pod on the same node ($node)"
sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s/__NODE_NAME__/$node/g" \
  "$SAMPLE_DIR/deploy/pod-ordinary.yaml" | kc apply -f -
kc wait --for=condition=Ready "pod/$ORDINARY_POD" --timeout=5m \
  || die "the ordinary pod never became Ready; check '$(kubectl_cmd) -n $NAMESPACE describe pod $ORDINARY_POD'"

# Each probe reports its own result, and one that fails does not end the
# comparison: with set -e and pipefail a non-zero exec would stop the script and
# lose the signals after it, so the failure is printed and the loop goes on. The
# exit status is shown, so a missing signal cannot be mistaken for a reading.
probe_in() {
  local pod=$1 probe=$2 rc=0
  echo "--- $3 pod/$pod ---"
  kc exec "$pod" -- sh -c "$probe" 2>&1 | sed 's/^/  /' || rc=$?
  [[ $rc -ne 0 ]] && echo "  (this probe exited $rc in pod/$pod; the reading above, if any, is incomplete)"
  return 0
}
for probe in 'uname -rv' 'cat /proc/uptime' 'ls /sys/block' 'cat /sys/class/dmi/id/product_name'; do
  step "$probe"
  probe_in "$SANDBOX" "$probe" sandboxed
  probe_in "$ORDINARY_POD" "$probe" ordinary
done

step "when each pod started, to compare with its uptime"
kc get pod "$SANDBOX" "$ORDINARY_POD" -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp,RUNTIMECLASS:.spec.runtimeClassName'

step "where the workspace comes from, inside the guest"
kc exec "$SANDBOX" -- sh -c "df -h $WORKSPACE /; awk '\$2==\"$WORKSPACE\"{print \$1, \$3}' /proc/mounts" 2>&1 | sed 's/^/  /'

echo
echo "done; deleting pod/$ORDINARY_POD by name"
