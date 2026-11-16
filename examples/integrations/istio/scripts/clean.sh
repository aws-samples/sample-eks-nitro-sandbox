#!/usr/bin/env bash
# Remove what setup.sh and the page's steps created: the blueprint's namespace and
# everything in it, including the PeerAuthentication and AuthorizationPolicy.
#
#   ./scripts/clean.sh
#
# It checks the namespace's label first and removes nothing that is not the
# blueprint's. It never touches Istio: the install is shared, and the page says how
# to remove it. Exits non-zero when it could not finish.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl
show_context

mark=""; rc=0
mark="$(namespace_mark)" || rc=$?
case "$rc" in
  2) echo "namespace $NAMESPACE is already gone; nothing to remove"; exit 0 ;;
  0) [[ "$mark" == "$MARK_VALUE" ]] \
       || die "namespace $NAMESPACE is not this blueprint's (no $MARK_KEY=$MARK_VALUE label); leaving it alone" ;;
  *) die "could not read namespace $NAMESPACE, so it is not known whether it is this blueprint's; nothing was removed" ;;
esac

kc delete namespace "$NAMESPACE" --wait=true --timeout=300s

rc=0
namespace_mark >/dev/null || rc=$?
case "$rc" in
  2) ;;
  0) die "namespace $NAMESPACE still exists after the delete; check it with: kubectl get namespace $NAMESPACE" ;;
  *) die "could not determine whether namespace $NAMESPACE was removed; check it with: kubectl get namespace $NAMESPACE" ;;
esac
echo "removed namespace $NAMESPACE"
echo "Istio in $ISTIO_NAMESPACE was left as it is. To remove it, see Clean up on the page."
