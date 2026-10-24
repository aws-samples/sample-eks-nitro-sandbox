#!/usr/bin/env bash
# clean.sh -- remove what this sample created, and only that.
#
# Usage:
#   ./scripts/clean.sh
#
# What it removes, in reverse order of creation:
#   1. the runner scale set Helm release, first, because it is what creates
#      runner pods, then waits for any in-flight runner pod to go;
#   2. the runner pods' egress policy;
#   3. the GitHub credential Secret;
#   4. the runners namespace, once it is this sample's and empty of the
#      sample's objects.
#
# What it never removes: the ARC controller and the four ARC CRDs. They are
# shared by everything on the cluster that uses ARC, one controller watches
# every namespace, and deleting a CRD deletes every team's objects of that kind.
# This sample never installs them, so it never removes them; it prints the
# commands instead.
#
# It does not stop at the first failure. A lookup that fails means "could not
# determine", which is a failure and never "already gone": anything it could not
# delete or confirm is named at the end and makes it exit non-zero.
set -uo pipefail

SAMPLE=github-actions
SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SAMPLE_DIR/.env"

say() { printf '\n==> %s\n' "$*"; }
incomplete=0
warn() { printf 'warning: %s\n' "$*" >&2; incomplete=1; }

if [[ ! -f "$ENV_FILE" ]]; then
  printf 'error: no .env found. Clean up needs the same values setup.sh used.\n' >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

if [[ -z "${CLUSTER_NAME:-}" ]]; then
  printf 'error: set CLUSTER_NAME in .env.\n' >&2
  exit 1
fi
ARC_SYSTEMS_NAMESPACE="${ARC_SYSTEMS_NAMESPACE:-arc-systems}"
ARC_RUNNERS_NAMESPACE="${ARC_RUNNERS_NAMESPACE:-arc-runners}"
RUNNER_SCALE_SET_NAME="${RUNNER_SCALE_SET_NAME:-github-actions-nitro}"
GITHUB_SECRET_NAME="${GITHUB_SECRET_NAME:-github-credential}"
POLICY_NAME=github-actions-runner-egress

KCTL=(kubectl --context "$CLUSTER_NAME")
HELM=(helm --kube-context "$CLUSTER_NAME")

LABEL_KEY="ManagedBy"
LABEL_VALUE="$SAMPLE"

for cmd in kubectl helm jq; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'error: %s is not on PATH.\n' "$cmd" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
say "the runners namespace"
# ---------------------------------------------------------------------------
# Three outcomes, not two: present and this sample's, absent, or the read
# failed. A failed read is not permission to delete anything.
ns_json="$("${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" -o json 2>/dev/null)"
ns_rc=$?
ns_state=unknown
if [[ "$ns_rc" -eq 0 && -n "$ns_json" ]]; then
  ns_owner="$(jq -r --arg k "$LABEL_KEY" '.metadata.labels[$k] // ""' <<<"$ns_json" 2>/dev/null)"
  if [[ "$ns_owner" == "$LABEL_VALUE" ]]; then
    ns_state=ours
    echo "  '$ARC_RUNNERS_NAMESPACE' is labelled $LABEL_KEY=$LABEL_VALUE; it is this sample's."
  else
    ns_state=foreign
    warn "namespace '$ARC_RUNNERS_NAMESPACE' exists but is labelled $LABEL_KEY=${ns_owner:-none}, not $LABEL_VALUE. Refusing to delete anything in a namespace this sample does not own. Clean it up by hand, or re-run with ARC_RUNNERS_NAMESPACE set to the one this sample made."
  fi
elif "${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" 2>&1 | grep -q 'NotFound'; then
  ns_state=absent
  echo "  '$ARC_RUNNERS_NAMESPACE' is already gone."
else
  warn "could not determine whether namespace '$ARC_RUNNERS_NAMESPACE' exists (the read failed, not a report that it is absent). Refusing to clean up on an unknown state."
fi

if [[ "$ns_state" == ours ]]; then
  # -----------------------------------------------------------------------
  say "1/4 the runner scale set"
  # -----------------------------------------------------------------------
  # Uninstall it first: while it exists the controller keeps making runner pods.
  ss_list="$("${HELM[@]}" list -n "$ARC_RUNNERS_NAMESPACE" -o json 2>/dev/null)"
  if [[ $? -ne 0 || -z "$ss_list" ]]; then
    warn "could not list Helm releases in '$ARC_RUNNERS_NAMESPACE'; leaving the scale set alone."
  elif ! jq -e --arg n "$RUNNER_SCALE_SET_NAME" 'any(.[]; .name == $n)' <<<"$ss_list" >/dev/null; then
    echo "  release '$RUNNER_SCALE_SET_NAME' is already gone."
  else
    # Inside this sample's own namespace the namespace label is enough, so the
    # release is uninstalled without re-asserting ownership per object.
    if "${HELM[@]}" uninstall "$RUNNER_SCALE_SET_NAME" -n "$ARC_RUNNERS_NAMESPACE" --wait --timeout 5m; then
      echo "  uninstalled '$RUNNER_SCALE_SET_NAME'."
    else
      warn "could not uninstall Helm release '$RUNNER_SCALE_SET_NAME' in '$ARC_RUNNERS_NAMESPACE'."
    fi
  fi

  echo "  waiting for any in-flight runner pod to go..."
  for _ in $(seq 1 60); do
    pods="$("${KCTL[@]}" get pods -n "$ARC_RUNNERS_NAMESPACE" \
      -l actions-ephemeral-runner=True -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
    [[ -z "$pods" ]] && break
    sleep 5
  done
  pods="$("${KCTL[@]}" get pods -n "$ARC_RUNNERS_NAMESPACE" \
    -l actions-ephemeral-runner=True -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  if [[ -n "$pods" ]]; then
    warn "runner pods are still present in '$ARC_RUNNERS_NAMESPACE': $pods"
  else
    echo "  no runner pods left."
  fi

  # -----------------------------------------------------------------------
  say "2/4 the egress policy"
  # -----------------------------------------------------------------------
  if "${KCTL[@]}" get applicationnetworkpolicy "$POLICY_NAME" -n "$ARC_RUNNERS_NAMESPACE" >/dev/null 2>&1; then
    "${KCTL[@]}" delete applicationnetworkpolicy "$POLICY_NAME" -n "$ARC_RUNNERS_NAMESPACE" \
      && echo "  deleted $POLICY_NAME." \
      || warn "could not delete ApplicationNetworkPolicy '$POLICY_NAME'."
  else
    echo "  $POLICY_NAME is already gone."
  fi

  # -----------------------------------------------------------------------
  say "3/4 the GitHub credential Secret"
  # -----------------------------------------------------------------------
  if "${KCTL[@]}" get secret "$GITHUB_SECRET_NAME" -n "$ARC_RUNNERS_NAMESPACE" >/dev/null 2>&1; then
    "${KCTL[@]}" delete secret "$GITHUB_SECRET_NAME" -n "$ARC_RUNNERS_NAMESPACE" \
      && echo "  deleted Secret $GITHUB_SECRET_NAME." \
      || warn "could not delete Secret '$GITHUB_SECRET_NAME'."
  else
    echo "  Secret $GITHUB_SECRET_NAME is already gone."
  fi

  # -----------------------------------------------------------------------
  say "4/4 the runners namespace"
  # -----------------------------------------------------------------------
  if "${KCTL[@]}" delete namespace "$ARC_RUNNERS_NAMESPACE" --wait --timeout=5m; then
    echo "  deleted namespace $ARC_RUNNERS_NAMESPACE."
  else
    warn "could not delete namespace '$ARC_RUNNERS_NAMESPACE'."
  fi
  if "${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" >/dev/null 2>&1; then
    warn "namespace '$ARC_RUNNERS_NAMESPACE' still exists after the delete."
  fi
fi

# ---------------------------------------------------------------------------
say "what stays"
# ---------------------------------------------------------------------------
cat <<EOF
  The ARC controller in '$ARC_SYSTEMS_NAMESPACE' and the four ARC CRDs stay.
  They are shared: one controller watches every namespace, and each CRD holds
  every team's objects of that kind, so deleting one would delete another team's
  runner sets. This sample did not install them, so it does not remove them.

  If you installed them only for this sample, and nothing else on the cluster
  uses ARC, remove them yourself:

    helm --kube-context $CLUSTER_NAME uninstall arc -n $ARC_SYSTEMS_NAMESPACE
    kubectl --context $CLUSTER_NAME delete namespace $ARC_SYSTEMS_NAMESPACE
    kubectl --context $CLUSTER_NAME delete crd \\
      autoscalingrunnersets.actions.github.com \\
      autoscalinglisteners.actions.github.com \\
      ephemeralrunnersets.actions.github.com \\
      ephemeralrunners.actions.github.com

  Check nothing else uses ARC first:

    kubectl --context $CLUSTER_NAME get autoscalingrunnersets -A

  Network policy enforcement is a cluster-wide setting and also stays. The
  workflow file in your test repository, and the credential you created on
  GitHub, are yours to remove: delete the workflow, and revoke the token or
  uninstall the GitHub App.
EOF

if [[ "$incomplete" -ne 0 ]]; then
  printf '\nClean up INCOMPLETE: something above could not be deleted or confirmed. See the warnings.\n' >&2
  exit 1
fi
printf '\nClean up complete.\n'
