#!/usr/bin/env bash
# Remove what this sample created, which is its own namespace and everything in
# it, and nothing else.
#
#   ./scripts/cleanup.sh
#
# There is deliberately no flag here that undoes the prerequisites. The Argo
# Rollouts controller and the step-plugin registration (the stepPlugins key in
# the controller's own ConfigMap, the initContainer on its Deployment, the
# cluster-scoped ClusterRole and ClusterRoleBinding, and the ECR repository the
# plugin image lives in) are things the READER sets up before the sample runs,
# exactly like the agent-sandbox controller. They are shared with every Rollout
# on the cluster, so this sample neither creates nor removes them: the page's
# "What stays" section has the commands for a reader who wants them gone.
#
# It exits non-zero when it skipped something or could not tell whether
# something was gone. A lookup that fails means "could not determine", which is
# a failure, never "gone".
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

[[ $# -eq 0 ]] || die "usage: $0   (it takes no arguments; the prerequisites are never undone here, see the page's \"What stays\")"

require_commands kubectl
show_context

# Anything this script could not remove or could not check is recorded here, and
# makes the run exit non-zero at the end. A clean up that says it is done when it
# is not is worse than one that fails.
INCOMPLETE=()
note_incomplete() { INCOMPLETE+=("$1"); echo "  INCOMPLETE: $1" >&2; }

step "1/1 the sample's namespace $NAMESPACE"
ns_rc=0
namespace_is_ours || ns_rc=$?
case $ns_rc in
  0)
    # Delete the pool FIRST so it stops booting replacements while the rest goes
    # away. Inside a namespace this sample owns, the namespace label is the mark,
    # so there is no need to check each object in it.
    echo "  deleting the warm pool first, so it stops booting replacements"
    kc delete sandboxwarmpool "$POOL" --ignore-not-found --wait=true --timeout=180s \
      || note_incomplete "could not delete sandboxwarmpool/$POOL in $NAMESPACE"
    echo "  deleting the namespace and everything in it"
    if kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=600s; then
      echo "  deleted namespace $NAMESPACE"
    else
      note_incomplete "could not delete namespace $NAMESPACE"
    fi ;;
  1) note_incomplete "namespace $NAMESPACE exists but is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL, so it is not this sample's and nothing in it was touched" ;;
  2) note_incomplete "could not read namespace $NAMESPACE, so whether it is this sample's could not be determined" ;;
  3) echo "  namespace $NAMESPACE does not exist; nothing to remove" ;;
esac

cat <<EOF

Left in place, because a reader sets these up as prerequisites and the whole
cluster shares them:
  - the Argo Rollouts install in namespace $ARGO_NAMESPACE
  - the step-plugin registration: the stepPlugins key in configmap
    $ARGO_NAMESPACE/argo-rollouts-config, the initContainer on deployment
    $ARGO_NAMESPACE/argo-rollouts, and clusterrole/clusterrolebinding
    argo-rollouts-sandbox-warmpool
  - the ECR repository $PLUGIN_REPO, which holds the plugin image
  - the agent-sandbox controller
The page's "What stays" section has the commands to remove them, and what to
check first.
EOF

echo
if ((${#INCOMPLETE[@]})); then
  printf 'the clean up did not finish: %d thing(s) were skipped or could not be checked\n' "${#INCOMPLETE[@]}" >&2
  printf '  - %s\n' "${INCOMPLETE[@]}" >&2
  exit 1
fi
echo "clean up complete: the sample's namespace and everything in it are gone."
