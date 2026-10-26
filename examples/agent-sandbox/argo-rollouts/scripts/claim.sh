#!/usr/bin/env bash
# Claim a warm pod and read, by value, which template revision it booted from.
#
#   ./scripts/claim.sh stale
#   ./scripts/claim.sh fresh
#
# The claim adopts a pod the pool had already booted. This prints what the
# SandboxTemplate says NOW next to what the adopted pod actually booted with, so
# the two can be compared rather than inferred:
#
#   * the template's marker, read from the API;
#   * the same marker read from inside the guest as an environment variable;
#   * the file the container wrote at boot, which records the value the pod
#     started with and cannot be changed by a later patch to the template;
#   * the agents.x-k8s.io/launch-type label, which says the pod came from the
#     pool rather than being cold-started for this claim.
#
# The agents.x-k8s.io/sandbox-template-hash label is NOT read here. The
# controller takes the pool's labels off a sandbox when a claim adopts it, so
# that witness is read from the pool before claiming; the page does that in the
# step above this one.
#
# It exits non-zero when the two disagree ONLY if STRICT=current is set; by
# default it reports what it found either way, because the page uses it to show
# both a stale adoption and a fresh one.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: $0 <claim-name>   (for example: $0 stale)"
[[ "$NAME" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || die "the claim name must be a DNS label; got '$NAME'"

require_commands kubectl
show_context
require_our_namespace

# The template's side of the comparison, read before the claim so a patch racing
# with this script cannot make the two readings come from different moments.
tmpl_rev="$(template_revision)" \
  || die "could not read $REVISION_ENV on sandboxtemplate/$TEMPLATE"

# `create`, not `apply`: a claim of this name left by an earlier run must fail
# here rather than be quietly reused. Every reading below is about the pod THIS
# claim adopted, and an old claim would answer with the pod it adopted before.
exists_rc=0
resource_exists kc "sandboxclaim/$NAME" || exists_rc=$?
case $exists_rc in
  0) die "sandboxclaim/$NAME already exists. Delete it first so this claim is a new one, whose adoption these readings describe:
  kubectl -n $NAMESPACE delete sandboxclaim $NAME" ;;
  2) die "could not read sandboxclaim/$NAME; stopping rather than create over something I cannot see" ;;
esac

claim_fresh "$NAME"
wait_claim_ready "$NAME" 120 \
  || die "sandboxclaim/$NAME never became Ready and named an adopted pod. Check 'kubectl -n $NAMESPACE describe sandboxclaim $NAME'"

pod="$(claim_pod "$NAME")" || die "sandboxclaim/$NAME is Ready but does not name an adopted pod"
env_v="$(pod_revision_env "$pod")" || env_v=""
file_v="$(pod_revision_file "$pod")" || file_v=""
launch="$(pod_launch_type "$pod")" || launch=""

echo
printf '  %-38s: %s\n' "the SandboxTemplate now says" "$REVISION_ENV=$tmpl_rev"
printf '  %-38s: %s\n' "the claim adopted pod" "$pod"
printf '  %-38s: %s\n' "that pod's $REVISION_ENV (env)" "${env_v:-<could not read>}"
printf '  %-38s: %s\n' "$REVISION_FILE (at boot)" "${file_v:-<could not read>}"
printf '  %-38s: %s\n' "agents.x-k8s.io/launch-type" "${launch:-<could not read>}"
echo

# A reading that could not be taken is never reported as agreement. Both in-guest
# readings have to be present AND equal to each other before either is compared
# with the template, so an exec that failed can not make a stale pod look fresh.
if [[ -z "$env_v" || -z "$file_v" ]]; then
  echo "could not read the revision marker from inside pod $pod, so whether it is stale could not be determined" >&2
  exit 1
fi
if [[ "$env_v" != "$file_v" ]]; then
  echo "the environment variable ($env_v) and the file written at boot ($file_v) disagree on pod $pod; that should not happen and is worth looking into" >&2
  exit 1
fi

if [[ "$env_v" == "$tmpl_rev" ]]; then
  echo "CURRENT: the adopted pod booted from the revision the template now holds ($tmpl_rev)."
  exit 0
fi

echo "STALE: the template says $tmpl_rev, and the adopted pod booted from $env_v."
echo "A claim made now still gets a pod from the old template, because patching a"
echo "SandboxTemplate does not reboot the pool. ./scripts/drain-pool.sh closes this."
if [[ "${STRICT:-}" == "current" ]]; then
  exit 1
fi
exit 0
