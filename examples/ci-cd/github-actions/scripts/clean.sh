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
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

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
# --ignore-not-found makes absence a successful empty read, so "absent" and
# "the read failed" are told apart by the exit code rather than by matching an
# error message through a pipe.
ns_json="$("${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" \
  -o json --ignore-not-found 2>/dev/null)"
ns_rc=$?
ns_state=unknown
if [[ "$ns_rc" -ne 0 ]]; then
  warn "could not determine whether namespace '$ARC_RUNNERS_NAMESPACE' exists (the read failed, not a report that it is absent). Refusing to clean up on an unknown state."
elif [[ -z "$ns_json" ]]; then
  ns_state=absent
  echo "  '$ARC_RUNNERS_NAMESPACE' is already gone."
else
  ns_owner="$(jq -r --arg k "$LABEL_KEY" '.metadata.labels[$k] // ""' <<<"$ns_json")"
  if [[ $? -ne 0 ]]; then
    warn "could not read the labels of namespace '$ARC_RUNNERS_NAMESPACE'. Refusing to clean up on an unknown state."
  elif [[ "$ns_owner" == "$LABEL_VALUE" ]]; then
    ns_state=ours
    echo "  '$ARC_RUNNERS_NAMESPACE' is labelled $LABEL_KEY=$LABEL_VALUE; it is this sample's."
  else
    ns_state=foreign
    warn "namespace '$ARC_RUNNERS_NAMESPACE' exists but is labelled $LABEL_KEY=${ns_owner:-none}, not $LABEL_VALUE. Refusing to delete anything in a namespace this sample does not own. Clean it up by hand, or re-run with ARC_RUNNERS_NAMESPACE set to the one this sample made."
  fi
fi

if [[ "$ns_state" == ours ]]; then
  # -----------------------------------------------------------------------
  say "1/4 the runner scale set"
  # -----------------------------------------------------------------------
  # Uninstall it first: while it exists the controller keeps making runner pods.
  # Name the statuses, so a release stuck in pending or uninstalling is seen
  # rather than reported as already gone. Helm 3 lists only deployed and failed
  # by default; Helm 4 lists every status but has dropped the `-a` shorthand, so
  # these flags are what works on both.
  ss_list="$("${HELM[@]}" list --deployed --failed --pending --uninstalling \
    -n "$ARC_RUNNERS_NAMESPACE" -o json 2>/dev/null)"
  ss_rc=$?
  # jq exits 1 when the release is absent but 2 or 5 on a parse error, so tell
  # "not there" apart from "could not tell".
  ss_found=unknown
  if [[ "$ss_rc" -eq 0 && -n "$ss_list" ]]; then
    jq -e --arg n "$RUNNER_SCALE_SET_NAME" 'any(.[]; .name == $n)' <<<"$ss_list" >/dev/null
    case $? in
      0) ss_found=yes ;;
      1) ss_found=no ;;
      *) ss_found=unknown ;;
    esac
  fi
  # While the scale set exists the controller keeps making runner pods, so
  # whether it is gone decides, with the pod read below, what may be deleted
  # next. Unknown is not gone.
  ss_gone=no
  if [[ "$ss_found" == unknown ]]; then
    warn "could not list Helm releases in '$ARC_RUNNERS_NAMESPACE'; leaving the scale set alone."
  elif [[ "$ss_found" == no ]]; then
    # The release record being gone is not the same as the scale set being
    # gone: `helm uninstall --wait` purges the record and then exits non-zero
    # when, say, an AutoscalingRunnerSet finalizer is stuck, so a later run
    # would see no release and call it gone. Check the objects themselves, and
    # only when their CRDs are installed, so a cluster without ARC CRDs cannot
    # make this clean up refuse for ever.
    echo "  release '$RUNNER_SCALE_SET_NAME' is already gone."
    # Each kind is read only when its own CRD is installed. Reading all three at
    # once would fail outright if any one CRD were missing, for instance while a
    # CRD delete hangs on a finalizer, and every later run would then warn
    # "could not read" with nothing left to find.
    arc_objs=""
    arc_read_failed=no
    for k in autoscalingrunnersets ephemeralrunnersets ephemeralrunners; do
      k_crd="$("${KCTL[@]}" get crd "$k.actions.github.com" -o name --ignore-not-found 2>/dev/null)"
      if [[ $? -ne 0 ]]; then
        warn "could not read the $k.actions.github.com CRD, so whether any $k is left cannot be told."
        arc_read_failed=yes
        continue
      fi
      [[ -z "$k_crd" ]] && continue   # the CRD is absent, so no object can exist
      k_objs="$("${KCTL[@]}" get "$k" -n "$ARC_RUNNERS_NAMESPACE" \
        -o name --ignore-not-found 2>/dev/null)"
      if [[ $? -ne 0 ]]; then
        warn "could not read $k in '$ARC_RUNNERS_NAMESPACE'; that is a failed read, not a report that none are left."
        arc_read_failed=yes
        continue
      fi
      [[ -n "$k_objs" ]] && arc_objs+="$k_objs"$'\n'
    done
    # Objects first, then a failed read. The other order hid a real finding:
    # when one kind's read failed and another kind still had objects, only the
    # failed read was warned, so the reader was not told what was left or how
    # to clear a stuck finalizer until a later run. Either way `ss_gone` stays
    # no, so the gate below is unaffected.
    if [[ -n "$(grep . <<<"$arc_objs" || true)" ]]; then
      warn "the Helm release is gone but runner scale set objects remain in '$ARC_RUNNERS_NAMESPACE': $(tr '\n' ' ' <<<"$arc_objs"). They may still be terminating, so re-run first.
  If they never clear, a finalizer is stuck, which happens when the ARC controller was removed before its objects were. Check that no controller is running, because clearing a finalizer while one is alive skips ARC's own clean up and can leave the listener, and its copy of your GitHub credential, behind:
    kubectl --context $CLUSTER_NAME get deploy -A -l app.kubernetes.io/name=gha-rs-controller
  Only if that prints nothing, remove the finalizers and re-run:
    kubectl --context $CLUSTER_NAME -n $ARC_RUNNERS_NAMESPACE patch <kind>/<name> --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    elif [[ "$arc_read_failed" == yes ]]; then
      : # already warned above, per kind; ss_gone stays no
    else
      ss_gone=yes
    fi
  else
    # Inside this sample's own namespace the namespace label is enough, so the
    # release is uninstalled without re-asserting ownership per object.
    if "${HELM[@]}" uninstall "$RUNNER_SCALE_SET_NAME" -n "$ARC_RUNNERS_NAMESPACE" --wait --timeout 5m; then
      echo "  uninstalled '$RUNNER_SCALE_SET_NAME'."
      ss_gone=yes
    else
      warn "could not uninstall Helm release '$RUNNER_SCALE_SET_NAME' in '$ARC_RUNNERS_NAMESPACE'."
    fi
  fi

  # A read that fails here means "could not tell", never "gone".
  runner_pods() {
    "${KCTL[@]}" get pods -n "$ARC_RUNNERS_NAMESPACE" \
      -l actions-ephemeral-runner=True -o name --ignore-not-found 2>/dev/null
  }
  echo "  waiting for any in-flight runner pod to go..."
  for _ in $(seq 1 60); do
    pods="$(runner_pods)" || break
    [[ -z "$pods" ]] && break
    sleep 5
  done
  pods="$(runner_pods)"
  pods_rc=$?
  runners_left=unknown
  if [[ "$pods_rc" -ne 0 ]]; then
    warn "could not read the runner pods in '$ARC_RUNNERS_NAMESPACE'; that is a failed read, not a report that none are left."
  elif [[ -n "$pods" ]]; then
    runners_left=yes
    warn "runner pods are still present in '$ARC_RUNNERS_NAMESPACE': $(tr '\n' ' ' <<<"$pods")"
  else
    runners_left=no
    echo "  no runner pods left."
  fi

  # Deletes an object in this sample's own namespace. The namespace label was
  # already checked, so no per-object ownership check is needed; what this adds
  # is telling a failed read apart from an absent object.
  delete_if_present() { # <kind> <name> <label for messages>
    local kind="$1" name="$2" what="$3" present
    present="$("${KCTL[@]}" get "$kind" "$name" -n "$ARC_RUNNERS_NAMESPACE" \
      -o name --ignore-not-found 2>/dev/null)"
    if [[ $? -ne 0 ]]; then
      warn "could not read $what '$name' in '$ARC_RUNNERS_NAMESPACE'; that is a failed read, not a report that it is gone."
      return
    fi
    if [[ -z "$present" ]]; then
      echo "  $name is already gone."
      return
    fi
    if "${KCTL[@]}" delete "$kind" "$name" -n "$ARC_RUNNERS_NAMESPACE"; then
      echo "  deleted $name."
    else
      warn "could not delete $what '$name'."
    fi
  }

  # -----------------------------------------------------------------------
  say "2/4 the egress policy"
  # -----------------------------------------------------------------------
  # Only once the runner pods are confirmed gone AND the scale set is confirmed
  # gone. Removing the policy while a runner pod still ran, or while the
  # controller could still create one, would leave a job's egress unrestricted.
  safe_to_unprotect=no
  if [[ "$runners_left" == no && "$ss_gone" == yes ]]; then
    safe_to_unprotect=yes
  fi
  if [[ "$safe_to_unprotect" == yes ]]; then
    delete_if_present applicationnetworkpolicy "$POLICY_NAME" "ApplicationNetworkPolicy"
  else
    warn "not deleting the egress policy '$POLICY_NAME': runner pods may still be running in '$ARC_RUNNERS_NAMESPACE', or the runner scale set may still exist and create one, and removing the policy would leave a job's egress unrestricted. Re-run once both are gone."
  fi

  # -----------------------------------------------------------------------
  say "3/4 the GitHub credential Secret"
  # -----------------------------------------------------------------------
  delete_if_present secret "$GITHUB_SECRET_NAME" "Secret"

  # -----------------------------------------------------------------------
  say "4/4 the runners namespace"
  # -----------------------------------------------------------------------
  # Gated on the same condition as the policy. Deleting the namespace removes
  # the policy and the pods together, and a pod keeps running through its
  # termination grace period after the policy has gone, so an ungated delete
  # here would undo the gate above.
  if [[ "$safe_to_unprotect" != yes ]]; then
    warn "not deleting namespace '$ARC_RUNNERS_NAMESPACE': runner pods may still be running, or the runner scale set may still exist. Deleting it would remove the egress policy while a pod was still terminating. Re-run once both are gone."
  else
    if "${KCTL[@]}" delete namespace "$ARC_RUNNERS_NAMESPACE" --wait --timeout=5m; then
      echo "  deleted namespace $ARC_RUNNERS_NAMESPACE."
    else
      warn "could not delete namespace '$ARC_RUNNERS_NAMESPACE'."
    fi
    left="$("${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" \
      -o name --ignore-not-found 2>/dev/null)"
    if [[ $? -ne 0 ]]; then
      warn "could not confirm namespace '$ARC_RUNNERS_NAMESPACE' is gone."
    elif [[ -n "$left" ]]; then
      warn "namespace '$ARC_RUNNERS_NAMESPACE' still exists after the delete."
    fi
  fi
fi

# ---------------------------------------------------------------------------
say "the listener, and ARC's copy of the credential"
# ---------------------------------------------------------------------------
# ARC does not keep the credential only where this sample put it. For each
# scale set the controller builds a listener in ARC_SYSTEMS_NAMESPACE and a
# `<listener>-config` Secret beside it whose config.json embeds the App
# credential or the token. Both are owned by the AutoscalingRunnerSet, so
# uninstalling the release above should remove them, but "should" is not
# "did": confirm it, because what is being confirmed gone is a copy of the
# credential.
sel="actions.github.com/scale-set-name=$RUNNER_SCALE_SET_NAME,actions.github.com/scale-set-namespace=$ARC_RUNNERS_NAMESPACE"

# Is the controller namespace there at all? Absent means there is nothing left
# to find, so a per-kind read failing is expected and not worth reporting. A
# read that FAILS is neither: it must not silence the per-kind failures below.
sysns="$("${KCTL[@]}" get namespace "$ARC_SYSTEMS_NAMESPACE" \
  -o name --ignore-not-found 2>/dev/null)"
sysns_rc=$?
if [[ "$sysns_rc" -ne 0 ]]; then
  sysns_state=unknown
  warn "could not determine whether namespace '$ARC_SYSTEMS_NAMESPACE' exists, so the checks below cannot be trusted to say the listener's copy of the credential is gone."
elif [[ -z "$sysns" ]]; then
  sysns_state=absent
  echo "  namespace '$ARC_SYSTEMS_NAMESPACE' does not exist, so nothing of this scale set is left in it."
else
  sysns_state=present
fi

if [[ "$sysns_state" != absent ]]; then
  # An absent CRD means no object of that kind can exist anywhere, so it is not
  # something to report as unreadable: a reader who removed the ARC CRDs while
  # keeping the namespace would otherwise see this clean up fail on every run
  # with nothing left to find.
  crd_for_kind() { # <kind> -> prints the CRD name, or nothing for a core kind
    case "$1" in
      autoscalinglistener) echo autoscalinglisteners.actions.github.com ;;
      *) echo "" ;;
    esac
  }
  for kind in autoscalinglistener secret pod; do
    crd="$(crd_for_kind "$kind")"
    if [[ -n "$crd" ]]; then
      crd_there="$("${KCTL[@]}" get crd "$crd" -o name --ignore-not-found 2>/dev/null)"
      if [[ $? -ne 0 ]]; then
        warn "could not read the $crd CRD, so whether any $kind for this scale set is left cannot be told."
        continue
      fi
      if [[ -z "$crd_there" ]]; then
        echo "  the $crd CRD is not installed, so no $kind can exist."
        continue
      fi
    fi
    found="$("${KCTL[@]}" get "$kind" -n "$ARC_SYSTEMS_NAMESPACE" -l "$sel" \
      -o name --ignore-not-found 2>/dev/null)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      warn "could not read $kind objects for this scale set in '$ARC_SYSTEMS_NAMESPACE'; that is a failed read, not a report that none are left."
    elif [[ -n "$found" ]]; then
      warn "this scale set still has $kind objects in '$ARC_SYSTEMS_NAMESPACE': $(tr '\n' ' ' <<<"$found"). The listener's config Secret holds a copy of the GitHub credential, so remove them before you consider the credential gone from the cluster."
    else
      echo "  no $kind left for this scale set in '$ARC_SYSTEMS_NAMESPACE'."
    fi
  done

  # The label selector above is how ARC labels these objects, read from its
  # source. Do not rely on that alone for the credential copy: also look for a
  # Secret named after this scale set, which is how ARC names the listener and
  # its `<listener>-config`.
  #
  # Matched with jq's startswith, not a regex, so a release name containing a
  # dot cannot match something else. A hit whose scale-set-namespace label names
  # a DIFFERENT runners namespace belongs to another install of this sample and
  # is skipped: left in, a second install sharing the default scale set name
  # would make this clean up warn and exit non-zero for as long as it existed,
  # and would tell the reader a copy of their credential may remain when none
  # does. An unlabelled hit is still reported, which is the point of not
  # trusting labels alone.
  # kubectl goes straight into jq, so only the matching NAMES are ever held in a
  # variable. Holding the JSON itself would put the `data` of every Secret in
  # this namespace into `bash -x` output, which on a shared cluster means other
  # installs' listener credentials as well as this reader's.
  #
  # With pipefail this is non-zero if either kubectl or jq fails, and empty
  # kubectl output leaves `hits` empty with a zero status, so absent and
  # unreadable stay apart.
  hits="$("${KCTL[@]}" get secret -n "$ARC_SYSTEMS_NAMESPACE" \
    -o json --ignore-not-found 2>/dev/null \
    | jq -r --arg n "$RUNNER_SCALE_SET_NAME" --arg ns "$ARC_RUNNERS_NAMESPACE" '
      [ (.items // [])[]
        | select(.metadata.name | startswith($n + "-"))
        | select((((.metadata.labels // {})["actions.github.com/scale-set-namespace"]) // $ns) == $ns)
        | .metadata.name ] | join(" ")' 2>/dev/null)"
  byname_rc=$?
  if [[ "$byname_rc" -ne 0 ]]; then
    warn "could not read or parse the Secrets in '$ARC_SYSTEMS_NAMESPACE' to check for a listener config Secret named after this scale set; that is a failed read, not a report that none is left."
  elif [[ -n "$hits" ]]; then
    warn "Secrets named after this scale set are still in '$ARC_SYSTEMS_NAMESPACE': $hits. One of these may be the listener's config Secret, which holds a copy of the GitHub credential."
  else
    echo "  no Secret named after this scale set in '$ARC_SYSTEMS_NAMESPACE'."
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
