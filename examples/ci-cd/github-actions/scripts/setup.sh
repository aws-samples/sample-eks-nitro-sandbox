#!/usr/bin/env bash
# setup.sh -- install this sample's runner scale set and its egress policy.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./scripts/setup.sh
#
# What it does, in order:
#   1. checks the tools, the kube context and the isolated-sandbox RuntimeClass;
#   2. checks network policy enforcement is on, and stops with the command if not;
#   3. checks the ARC controller is installed at the pinned version, and stops
#      with the command if not. The controller and its CRDs are shared by
#      everything on the cluster that uses ARC, so this sample never installs,
#      upgrades or reconfigures them;
#   4. creates the runners namespace, if absent, and labels it as this sample's;
#   5. creates the GitHub credential Secret from your credential file, so the
#      credential is never on a command line;
#   6. applies the runner pods' egress policy, with your CoreDNS address filled
#      in, and waits for its PolicyEndpoint;
#   7. installs the runner scale set and waits for its listener to be Ready.
#
# Overridable (defaults match the page, and come from .env):
#   CLUSTER_NAME, GITHUB_CONFIG_URL, ARC_VERSION, ARC_SYSTEMS_NAMESPACE,
#   ARC_RUNNERS_NAMESPACE, RUNNER_SCALE_SET_NAME, GITHUB_SECRET_NAME
set -euo pipefail

SAMPLE=github-actions
SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SAMPLE_DIR/.env"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[[ -f "$ENV_FILE" ]] || die "copy .env.example to .env and fill it in first."
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
: "${GITHUB_CONFIG_URL:?set GITHUB_CONFIG_URL in .env}"
ARC_VERSION="${ARC_VERSION:-0.15.1}"
ARC_SYSTEMS_NAMESPACE="${ARC_SYSTEMS_NAMESPACE:-arc-systems}"
ARC_RUNNERS_NAMESPACE="${ARC_RUNNERS_NAMESPACE:-arc-runners}"
RUNNER_SCALE_SET_NAME="${RUNNER_SCALE_SET_NAME:-github-actions-nitro}"
GITHUB_SECRET_NAME="${GITHUB_SECRET_NAME:-github-credential}"
# The name in deploy/egress-policy.yaml. Not overridable: the file sets it.
POLICY_NAME=github-actions-runner-egress

SCALESET_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
CONTROLLER_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"

# Pin the context, so a context another session changes cannot redirect the run.
KCTL=(kubectl --context "$CLUSTER_NAME")
HELM=(helm --kube-context "$CLUSTER_NAME")

# The mark that says an object is this sample's.
LABEL_KEY="ManagedBy"
LABEL_VALUE="$SAMPLE"

# ---------------------------------------------------------------------------
say "1/7 tools, context and RuntimeClass"
# ---------------------------------------------------------------------------
for cmd in kubectl helm jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not on PATH."
done
"${KCTL[@]}" version -o json >/dev/null 2>&1 \
  || die "cannot reach the cluster with context '$CLUSTER_NAME'. Check CLUSTER_NAME in .env and 'kubectl config get-contexts'."
"${KCTL[@]}" get runtimeclass isolated-sandbox >/dev/null 2>&1 \
  || die "the isolated-sandbox RuntimeClass is not on this cluster. Work through Getting started > Hello sandbox first."
echo "  context '$CLUSTER_NAME', isolated-sandbox present."

# ---------------------------------------------------------------------------
say "2/7 network policy enforcement"
# ---------------------------------------------------------------------------
# A cluster-wide setting. This sample never changes it: without it the egress
# policy below is accepted and not enforced, which would look like it worked.
npol="$("${KCTL[@]}" get configmap -n kube-system amazon-vpc-cni \
  -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null || true)"
[[ "$npol" == "true" ]] \
  || die "network policy enforcement is off, so the runner pods' egress policy would not be enforced. Turn it on once per cluster:
  kubectl apply -f ../../getting-started/coding-agent/enable-network-policy.yaml"
echo "  enforcement is on."

# ---------------------------------------------------------------------------
say "3/7 the ARC controller (shared; this sample does not install it)"
# ---------------------------------------------------------------------------
# One controller watches every namespace, and its CRDs hold every team's runner
# sets. If it is already here it is used exactly as it is.
#
# Look for it the way AGENTS.md says, by its CRDs and by its Deployment in any
# namespace, not only as a Helm release in the namespace this sample expects. A
# controller installed elsewhere, or without Helm, must not be reported as
# absent: the reader would then install a second one, and two controllers would
# reconcile the same CRDs.
ctrl_deploys="$("${KCTL[@]}" get deploy -A \
  -l app.kubernetes.io/name=gha-rs-controller \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)" \
  || die "could not list ARC controller Deployments. That is a failed read, not a report that the controller is absent."
ctrl_elsewhere="$(grep -v "^$ARC_SYSTEMS_NAMESPACE/" <<<"$ctrl_deploys" | grep . || true)"
[[ -z "$ctrl_elsewhere" ]] \
  || die "an ARC controller runs in another namespace ($(tr '\n' ' ' <<<"$ctrl_elsewhere")). One controller watches every namespace, so a second would compete with it for every runner set. Set ARC_SYSTEMS_NAMESPACE in .env to that namespace, or remove that controller, then re-run."

crds_present="$("${KCTL[@]}" get crd autoscalingrunnersets.actions.github.com \
  -o name --ignore-not-found 2>/dev/null)" \
  || die "could not read the ARC CRDs. That is a failed read, not a report that they are absent."

# The statuses are named so a controller release stuck in pending or failed is
# seen rather than read as absent. Helm 3 lists only deployed and failed by
# default, and Helm 4 has dropped the `-a` shorthand, so these flags suit both.
ctrl_list="$("${HELM[@]}" list --deployed --failed --pending --uninstalling \
  -n "$ARC_SYSTEMS_NAMESPACE" -o json 2>/dev/null)" \
  || die "could not list Helm releases in '$ARC_SYSTEMS_NAMESPACE'. That is a failed read, not a report that the controller is absent."
ctrl_chart="$(jq -r \
  '[.[] | select(.chart | startswith("gha-runner-scale-set-controller-"))][0].chart // ""' \
  <<<"$ctrl_list" \
  || die "could not parse the output of 'helm list' for '$ARC_SYSTEMS_NAMESPACE'.")"
ctrl_chart="${ctrl_chart#gha-runner-scale-set-controller-}"
if [[ -z "$ctrl_chart" ]]; then
  if [[ -n "$(grep . <<<"$ctrl_deploys" || true)" ]]; then
    die "an ARC controller Deployment runs in '$ARC_SYSTEMS_NAMESPACE' but there is no controller Helm release there, so its version cannot be read. This sample needs $ARC_VERSION, because the controller refuses a scale set built by another version. Check that install by hand, then re-run."
  fi
  if [[ -n "$crds_present" ]]; then
    die "the ARC CRDs exist but no ARC controller Deployment carries the label this script looks for ($ARC_SYSTEMS_NAMESPACE or elsewhere): another ARC install, one renamed with nameOverride, or one partly removed. Installing a controller over this could adopt someone else's CRDs. Sort that out by hand (kubectl get crd | grep actions.github.com), then re-run."
  fi
  die "no ARC controller found on this cluster.
  The controller and its CRDs are shared cluster-wide, so install them yourself, once, at the version this sample pins:

  helm install arc $CONTROLLER_CHART \\
    --version $ARC_VERSION --namespace $ARC_SYSTEMS_NAMESPACE --create-namespace

  Then re-run this script."
fi
[[ "$ctrl_chart" == "$ARC_VERSION" ]] \
  || die "the ARC controller in '$ARC_SYSTEMS_NAMESPACE' is version $ctrl_chart, but this sample pins $ARC_VERSION, and the controller refuses a scale set built by a different version.
  Either set ARC_VERSION=$ctrl_chart in .env to match the controller already on the cluster, or upgrade the controller yourself. This sample does not change a shared install."
# `rollout status` with a selector that matches nothing prints "No resources
# found" and exits 0 (measured on EKS 1.37), so a release whose Deployment is
# missing or renamed would otherwise be reported ready. Require the Deployment
# first.
grep -q "^$ARC_SYSTEMS_NAMESPACE/" <<<"$ctrl_deploys" \
  || die "a controller Helm release $ctrl_chart exists in '$ARC_SYSTEMS_NAMESPACE' but no Deployment there carries app.kubernetes.io/name=gha-rs-controller, so there is nothing to wait on. The release may be broken, partly removed, or installed with a nameOverride. Check it by hand, then re-run."
"${KCTL[@]}" rollout status deploy -n "$ARC_SYSTEMS_NAMESPACE" \
  -l app.kubernetes.io/name=gha-rs-controller --timeout=120s \
  || die "the ARC controller in '$ARC_SYSTEMS_NAMESPACE' is not ready."
echo "  controller $ctrl_chart is installed and ready; using it as it is."

# ---------------------------------------------------------------------------
say "4/7 the runners namespace"
# ---------------------------------------------------------------------------
if "${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" >/dev/null 2>&1; then
  owner="$("${KCTL[@]}" get namespace "$ARC_RUNNERS_NAMESPACE" \
    -o "jsonpath={.metadata.labels.$LABEL_KEY}" 2>/dev/null || true)"
  [[ "$owner" == "$LABEL_VALUE" ]] \
    || die "namespace '$ARC_RUNNERS_NAMESPACE' exists but is not labelled $LABEL_KEY=$LABEL_VALUE (found: ${owner:-none}), so it is not this sample's. Set ARC_RUNNERS_NAMESPACE in .env to a name this sample owns."
  echo "  namespace '$ARC_RUNNERS_NAMESPACE' is already this sample's; reusing it."
else
  "${KCTL[@]}" create namespace "$ARC_RUNNERS_NAMESPACE"
  "${KCTL[@]}" label namespace "$ARC_RUNNERS_NAMESPACE" "$LABEL_KEY=$LABEL_VALUE"
  echo "  created namespace '$ARC_RUNNERS_NAMESPACE' and labelled it $LABEL_KEY=$LABEL_VALUE."
fi

# ---------------------------------------------------------------------------
say "5/7 the GitHub credential Secret"
# ---------------------------------------------------------------------------
# Refuse a same-named Secret this sample did not create, so a credential
# belonging to someone else is never replaced. A read that FAILS is not a report
# that the Secret is absent: --ignore-not-found separates the two, so a
# transient error or RBAC that denies get never reaches the write below.
secret_present="$("${KCTL[@]}" get secret "$GITHUB_SECRET_NAME" \
  -n "$ARC_RUNNERS_NAMESPACE" -o name --ignore-not-found 2>/dev/null)" \
  || die "could not read Secret '$GITHUB_SECRET_NAME' in '$ARC_RUNNERS_NAMESPACE'. That is a failed read, not a report that it is absent; refusing to write over a credential whose owner is unknown."
if [[ -n "$secret_present" ]]; then
  owner="$("${KCTL[@]}" get secret "$GITHUB_SECRET_NAME" -n "$ARC_RUNNERS_NAMESPACE" \
    -o "jsonpath={.metadata.labels.$LABEL_KEY}" 2>/dev/null)" \
    || die "could not read the labels of Secret '$GITHUB_SECRET_NAME'."
  [[ "$owner" == "$LABEL_VALUE" ]] \
    || die "Secret '$GITHUB_SECRET_NAME' in '$ARC_RUNNERS_NAMESPACE' is not this sample's (labelled $LABEL_KEY=${owner:-none}). Set GITHUB_SECRET_NAME in .env to another name."
fi

# Both credential branches below, the GitHub App one and the token one, build
# the Secret with kubectl --from-file, so no credential is ever an argument, and
# xtrace is off around each so `bash -x` cannot print one. The sample's label
# goes on in the same write, with `kubectl label --local`, so the Secret is
# never briefly unlabelled.
#
# `create` when the Secret was absent, so one that appeared since the check is
# not taken over; `replace` only for this sample's own Secret. A client-side
# apply is never used: it copies the whole Secret, credential included, into its
# kubectl.kubernetes.io/last-applied-configuration annotation, and
# `kubectl describe secret` prints annotations even though it hides data.
secret_write() {
  if [[ -z "$secret_present" ]]; then
    "${KCTL[@]}" label --local -f - "$LABEL_KEY=$LABEL_VALUE" -o yaml \
      | "${KCTL[@]}" create -f -
  else
    # `replace`, not `apply --server-side`: a full PUT of an object whose
    # ownership was just checked. A server-side apply takes ownership only of
    # the keys it sends and leaves keys written by another field manager, so
    # after a `create` above, moving from a token to a GitHub App would leave
    # the old github_token in the Secret beside the App keys while the reader
    # believed it had been replaced.
    "${KCTL[@]}" label --local -f - "$LABEL_KEY=$LABEL_VALUE" -o yaml \
      | "${KCTL[@]}" replace -f -
  fi
}

# Neither `create` nor `replace` adds that annotation, and a `replace` that
# omits it removes one already there, so with the writes above this is belt and
# braces. It stays because the annotation is the one place a credential could
# sit in plain view of `kubectl describe secret`, and because it catches a
# Secret left annotated by an older version of this script or by someone's own
# `kubectl apply`. Measured on EKS 1.37: after a client-side apply the
# annotation held the token, and a later server-side apply replaced it with the
# new token. Remove it, then confirm it is gone rather than assume.
strip_last_applied() {
  # Tracing off, like the two credential branches: this function used to read
  # the annotation's VALUE into a variable, which is the whole Secret with the
  # credential in it, so `bash -x setup.sh` would have printed it. It now asks
  # jq only whether the key is there and keeps nothing but that answer.
  local xt=0; case "$-" in *x*) xt=1; set +x;; esac
  "${KCTL[@]}" annotate secret "$GITHUB_SECRET_NAME" -n "$ARC_RUNNERS_NAMESPACE" \
    kubectl.kubernetes.io/last-applied-configuration- >/dev/null 2>&1 || true
  local present rc=0
  present="$("${KCTL[@]}" get secret "$GITHUB_SECRET_NAME" -n "$ARC_RUNNERS_NAMESPACE" \
    -o json 2>/dev/null \
    | jq -r '(.metadata.annotations // {}) | has("kubectl.kubernetes.io/last-applied-configuration")')" \
    || rc=$?
  [[ "$xt" == 1 ]] && set -x
  [[ "$rc" -eq 0 && -n "$present" ]] \
    || die "could not confirm whether Secret '$GITHUB_SECRET_NAME' carries a last-applied-configuration annotation. That is a failed read, not a report that it is absent."
  [[ "$present" == false ]] \
    || die "Secret '$GITHUB_SECRET_NAME' still carries a kubectl.kubernetes.io/last-applied-configuration annotation, which would hold a copy of your credential in clear view of 'kubectl describe secret'. Remove it by hand:
  kubectl --context $CLUSTER_NAME -n $ARC_RUNNERS_NAMESPACE annotate secret $GITHUB_SECRET_NAME kubectl.kubernetes.io/last-applied-configuration-"
}

make_secret_from_app() {
  local xt=0; case "$-" in *x*) xt=1; set +x;; esac
  local rc=0
  "${KCTL[@]}" create secret generic "$GITHUB_SECRET_NAME" \
    --namespace "$ARC_RUNNERS_NAMESPACE" \
    --from-literal=github_app_id="$GITHUB_APP_ID" \
    --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
    --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_FILE" \
    --dry-run=client -o yaml | secret_write || rc=$?
  [[ "$xt" == 1 ]] && set -x
  return "$rc"
}

make_secret_from_pat() {
  # --from-file takes the file's bytes verbatim, and a trailing newline makes
  # the token invalid, so copy it through a private temp file that holds the
  # token and nothing else. The trap removes that copy even on an interrupt.
  local xt=0; case "$-" in *x*) xt=1; set +x;; esac
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/arc-token.XXXXXX")" || { [[ "$xt" == 1 ]] && set -x; return 1; }
  # INT and TERM traps are global, and $tmp is local, so clear them before every
  # return: left set, a later interrupt would run `rm -f "$tmp"` with $tmp
  # unbound and fail under `set -u` instead of stopping cleanly.
  trap 'rm -f "$tmp"' INT TERM
  chmod 600 "$tmp"
  if ! tr -d '\r\n' < "$GITHUB_PAT_FILE" > "$tmp" || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"; trap - INT TERM
    [[ "$xt" == 1 ]] && set -x
    echo "GITHUB_PAT_FILE=$GITHUB_PAT_FILE is empty, or could not be read." >&2
    return 1
  fi
  "${KCTL[@]}" create secret generic "$GITHUB_SECRET_NAME" \
    --namespace "$ARC_RUNNERS_NAMESPACE" \
    --from-file=github_token="$tmp" \
    --dry-run=client -o yaml | secret_write || rc=$?
  rm -f "$tmp"
  [[ -e "$tmp" ]] && { echo "could not remove $tmp; delete it by hand." >&2; rc=1; }
  trap - INT TERM
  [[ "$xt" == 1 ]] && set -x
  return "$rc"
}

if [[ -n "${GITHUB_APP_ID:-}" && -n "${GITHUB_APP_INSTALLATION_ID:-}" && -n "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
  [[ -r "$GITHUB_APP_PRIVATE_KEY_FILE" ]] \
    || die "GITHUB_APP_PRIVATE_KEY_FILE=$GITHUB_APP_PRIVATE_KEY_FILE is not readable."
  make_secret_from_app || die "could not create Secret '$GITHUB_SECRET_NAME'."
  echo "  Secret '$GITHUB_SECRET_NAME' created from the GitHub App private key file."
elif [[ -n "${GITHUB_PAT_FILE:-}" ]]; then
  [[ -r "$GITHUB_PAT_FILE" ]] || die "GITHUB_PAT_FILE=$GITHUB_PAT_FILE is not readable."
  make_secret_from_pat || die "could not create Secret '$GITHUB_SECRET_NAME'."
  echo "  Secret '$GITHUB_SECRET_NAME' created from the token file."
else
  die "no credential in .env. Set either the three GITHUB_APP_* values or GITHUB_PAT_FILE."
fi
strip_last_applied
echo "  no last-applied-configuration annotation on it."

# ---------------------------------------------------------------------------
say "6/7 the runner pods' egress policy"
# ---------------------------------------------------------------------------
coredns="$("${KCTL[@]}" get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
[[ -n "$coredns" ]] || die "could not read the CoreDNS Service address from kube-system/kube-dns."
sed "s|<COREDNS_IP>|$coredns|g" "$SAMPLE_DIR/deploy/egress-policy.yaml" \
  | "${KCTL[@]}" apply -n "$ARC_RUNNERS_NAMESPACE" -f -
echo "  applied, with CoreDNS at $coredns."

# The PolicyEndpoint is how the controller says it has handed the policy to the
# nodes. Wait for THIS policy's endpoint, matched by its owner, not for any
# endpoint in the namespace: another policy's would otherwise look like proof.
pe_for_policy() {
  "${KCTL[@]}" get policyendpoints -n "$ARC_RUNNERS_NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg p "$POLICY_NAME" \
        '[.items[] | select((.metadata.ownerReferences // []) | any(.name == $p))]
         | .[0].metadata.name // ""'
}
echo "  waiting for the PolicyEndpoint of $POLICY_NAME..."
for _ in $(seq 1 30); do
  [[ -n "$(pe_for_policy)" ]] && break
  sleep 2
done
pe="$(pe_for_policy || true)"
[[ -n "$pe" ]] \
  || die "no PolicyEndpoint owned by '$POLICY_NAME' appeared in '$ARC_RUNNERS_NAMESPACE'. Without it the policy is not on the nodes yet, so a job queued now would run unrestricted."
echo "  PolicyEndpoint: $pe"

# ---------------------------------------------------------------------------
say "7/7 the runner scale set"
# ---------------------------------------------------------------------------
# Refuse a same-named release this sample did not install.
ss_list="$("${HELM[@]}" list --deployed --failed --pending --uninstalling \
  -n "$ARC_RUNNERS_NAMESPACE" -o json 2>/dev/null)" \
  || die "could not list Helm releases in '$ARC_RUNNERS_NAMESPACE'."
# `install` when absent and `upgrade` only for this sample's own release, rather
# than `upgrade --install`: `install` fails if a release of this name appeared
# between the check below and the call, instead of taking it over.
helm_verb=install
if jq -e --arg n "$RUNNER_SCALE_SET_NAME" 'any(.[]; .name == $n)' <<<"$ss_list" >/dev/null; then
  ss_meta="$("${HELM[@]}" get metadata "$RUNNER_SCALE_SET_NAME" -n "$ARC_RUNNERS_NAMESPACE" -o json 2>/dev/null)" \
    || die "could not read the Helm metadata of release '$RUNNER_SCALE_SET_NAME'."
  rel_owner="$(jq -r --arg k "$LABEL_KEY" '.labels[$k] // ""' <<<"$ss_meta")"
  [[ "$rel_owner" == "$LABEL_VALUE" ]] \
    || die "a Helm release '$RUNNER_SCALE_SET_NAME' already exists in '$ARC_RUNNERS_NAMESPACE' and is not labelled $LABEL_KEY=$LABEL_VALUE, so it is not this sample's. Set RUNNER_SCALE_SET_NAME in .env to another name."
  helm_verb=upgrade
fi

values_rendered="$(mktemp "${TMPDIR:-/tmp}/arc-values.XXXXXX.yaml")"
trap 'rm -f "$values_rendered"' EXIT
sed -e "s|__GITHUB_CONFIG_URL__|$GITHUB_CONFIG_URL|g" \
    -e "s|__GITHUB_SECRET_NAME__|$GITHUB_SECRET_NAME|g" \
    "$SAMPLE_DIR/deploy/runner-scale-set-values.yaml" > "$values_rendered"

"${HELM[@]}" "$helm_verb" "$RUNNER_SCALE_SET_NAME" "$SCALESET_CHART" \
  --version "$ARC_VERSION" \
  --namespace "$ARC_RUNNERS_NAMESPACE" \
  --labels "$LABEL_KEY=$LABEL_VALUE" \
  -f "$values_rendered"

echo "  waiting for the listener pod in '$ARC_SYSTEMS_NAMESPACE'..."
"${KCTL[@]}" wait --for=condition=Ready pod \
  -l "actions.github.com/scale-set-name=$RUNNER_SCALE_SET_NAME,actions.github.com/scale-set-namespace=$ARC_RUNNERS_NAMESPACE" \
  -n "$ARC_SYSTEMS_NAMESPACE" --timeout=180s \
  || die "the listener pod for '$RUNNER_SCALE_SET_NAME' did not become Ready in '$ARC_SYSTEMS_NAMESPACE', so the scale set is not registered with GitHub. Check the credential, then:
  kubectl --context $CLUSTER_NAME -n $ARC_SYSTEMS_NAMESPACE logs -l actions.github.com/scale-set-name=$RUNNER_SCALE_SET_NAME"

say "setup complete"
cat <<EOF
  ARC controller:    namespace $ARC_SYSTEMS_NAMESPACE, version $ctrl_chart (shared; not installed by this sample)
  Runner scale set:  release '$RUNNER_SCALE_SET_NAME' in namespace $ARC_RUNNERS_NAMESPACE
  Registered with:   $GITHUB_CONFIG_URL
  Egress policy:     github-actions-runner-egress, PolicyEndpoint $pe

Next, copy the workflow into your test repository and trigger it:

  cp workflow/untrusted-pr-workflow.yaml <your-clone>/.github/workflows/
  (commit and push, then run it from the repository's Actions tab)

A runner pod appears only while the job runs. Watch for it with:

  kubectl --context $CLUSTER_NAME get pods -n $ARC_RUNNERS_NAMESPACE -w
EOF
