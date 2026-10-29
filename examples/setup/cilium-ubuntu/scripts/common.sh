#!/usr/bin/env bash
# Shared by setup.sh, test.sh and clean.sh. Source it after setting SAMPLE_DIR; it is sourced,
# never run.
#
# It loads config.env.example (tracked defaults) then config.local.env (gitignored; real values
# live there and win), points
# kubectl, helm and eksctl at this sample's own kubeconfig, pins the tool versions, and
# provides the assertion tally and the AWS/cluster guards the three scripts share.
#
# This sample creates a dedicated, disposable cluster, so unlike the cluster-reusing samples
# it keeps its OWN kubeconfig and never touches ~/.kube/config: a run here cannot move another
# kubectl session on the workstation onto this cluster. All of this run's local state (the
# kubeconfig, the rendered eksctl YAML, the launch-template JSON) is written under the
# repository's gitignored tmp/ at RUN_DIR, never beneath the sample folder: anything in a
# sample folder is one `git add` from being published (see AGENTS.md, "Keep local files in
# the repository's tmp/").

[[ -f "$SAMPLE_DIR/config.env.example" ]] || { echo "ERROR: $SAMPLE_DIR/config.env.example is missing" >&2; exit 1; }
# config.env.example is tracked and holds the placeholders and shared defaults; config.local.env
# (gitignored) holds the real values and wins. Sourcing the example first means Region, instance
# types and OWNER_TAG always have a value, so a config.local.env that only sets the account and
# the two AMI ids still runs. The account and AMI guards below reject the placeholders, so an
# unfilled config.local.env stops with a clear message rather than acting on a blank value.
# shellcheck source=/dev/null
source "$SAMPLE_DIR/config.env.example"
if [[ -f "$SAMPLE_DIR/config.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$SAMPLE_DIR/config.local.env"
fi
export AWS_ACCOUNT_ID AWS_REGION CLUSTER_NAME AVAILABILITY_ZONES SANDBOX_AMI_ID SYSTEM_AMI_ID \
  SANDBOX_AMI_MANAGED_BY_VALUE SANDBOX_INSTANCE_TYPE SYSTEM_INSTANCE_TYPE OWNER_TAG

# Versions this sample is pinned to. The README's Versions table must match these.
#
# Cilium is pinned exactly. eksctl has no per-release list of Kubernetes versions: since
# eksctl 0.202.0 it accepts whatever versions the EKS DescribeClusterVersions API reports, so
# 0.230.0 is the floor because it is the release this sample's issue was first validated with,
# not because it is the first that knows EKS 1.36.
CILIUM_VERSION=1.20.2
CILIUM_CHART=oci://quay.io/cilium/charts/cilium
EKSCTL_MIN_VERSION=0.230.0
KUBERNETES_VERSION=1.36

# What the sandbox node runs, from the GA node-build bundle nitro-sandbox-ga-20261028 that the
# ../ubuntu-ami (#10) AMI is built from. This sample builds none of it; test.sh asserts the two
# kernel releases on the live node and pod.
#   host kernel   kernel.org linux 6.18.56 plus AWS's public commit amazonlinux/linux 1e66c960,
#                 local version -nitro-ga (what the sandbox node's `uname -r` shows)
#   guest kernel  inside the bundle's guest image latest.eif (what the sandbox pod's `uname -r` shows)
HOST_KERNEL_RELEASE=6.18.56-nitro-ga
GUEST_KERNEL_RELEASE=6.18.54
# The runtime binaries and guest image come in one archive the operator supplies to the #10
# build, which checks this SHA-256 before it installs anything. It has no public download, so
# this sample never fetches, verifies, embeds or commits it; the values are recorded here so
# the README and the AMI you consume can be compared against one place.
RUNTIME_ARCHIVE=nitro-sandbox-binaries-2026-10-28.zip
RUNTIME_ARCHIVE_SHA256=6830dc8d0acb356b06753fed609ebb9f03a182e340eaa27cd9ed171f7667ba40
export HOST_KERNEL_RELEASE GUEST_KERNEL_RELEASE RUNTIME_ARCHIVE RUNTIME_ARCHIVE_SHA256

# The sample's namespace and the label that marks it the sample's. A script reuses or deletes
# the namespace, or anything in it, only when the label is present; otherwise it stops.
NAMESPACE=cilium-ubuntu-demo
NS_LABEL_KEY="app.kubernetes.io/part-of"
NS_LABEL_VAL="setup-cilium-ubuntu"

# The AWS tag every resource this sample creates carries. clean.sh refuses a cluster without
# it; setup.sh's tag sweep (step 8) adds it to resources AWS creates implicitly.
DEMO_TAG_KEY="Demo"
DEMO_TAG_VAL="setup-cilium-ubuntu"

PY="$SAMPLE_DIR/scripts/cilium_ubuntu.py"

# The repository root, so this run's local state lands in the repo's gitignored tmp/ rather
# than beneath the sample folder. Prefer git; fall back to walking up from SAMPLE_DIR to the
# directory that holds AGENTS.md or .git, so the scripts work in a checkout with no git too.
# Never a hardcoded absolute path: the repository can be cloned anywhere.
repo_root() {
  local root dir
  if root="$(git -C "$SAMPLE_DIR" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$root" ]]; then
    printf '%s\n' "$root"; return 0
  fi
  dir="$SAMPLE_DIR"
  while [[ "$dir" != "/" ]]; do
    if [[ -e "$dir/AGENTS.md" || -e "$dir/.git" ]]; then printf '%s\n' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  die "could not find the repository root (no git, no AGENTS.md or .git above $SAMPLE_DIR)"
}
REPO_ROOT="$(repo_root)"

# All of this run's local state lives here, under the repo's gitignored tmp/: the kubeconfig,
# the rendered eksctl YAML and the launch-template JSON. setup.sh creates it; test.sh and
# clean.sh only read what is in it. Exported so scripts/cilium_ubuntu.py writes the same place.
export RUN_DIR="$REPO_ROOT/tmp/issue11/run"

# This sample's own kubeconfig, under RUN_DIR (never ~/.kube/config and never the sample
# folder). setup.sh creates the directory and writes it; test.sh and clean.sh only read it,
# so a dry run leaves the working tree as it found it.
export KUBECONFIG="$RUN_DIR/kubeconfig"

# ---------------------------------------------------------------------------
# Output and guards
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _green() { printf '\033[32m%s\033[0m' "$*"; }
  _red()   { printf '\033[31m%s\033[0m' "$*"; }
  _amber() { printf '\033[33m%s\033[0m' "$*"; }
else
  _green() { printf '%s' "$*"; }
  _red()   { printf '%s' "$*"; }
  _amber() { printf '%s' "$*"; }
fi

# Public colour helpers, named like the public die/warn/step below. setup.sh wraps its
# headline lines in green(...); the tally functions use the _-prefixed forms directly.
green() { _green "$*"; }
red()   { _red "$*"; }
amber() { _amber "$*"; }

die()  { printf '%s %s\n' "$(_red 'ERROR:')" "$*" >&2; exit 1; }
warn() { printf '%s %s\n' "$(_amber 'WARN:')" "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but was not found on PATH"
  done
}

# version_at_least <have> <want>: dotted numeric comparison.
version_at_least() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

require_eksctl_version() {
  local have
  have="$(eksctl version 2>/dev/null | head -n1)"
  have="${have#v}"
  [[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read the eksctl version (got '$have')"
  version_at_least "$have" "$EKSCTL_MIN_VERSION" \
    || die "eksctl $have is too old; this sample needs $EKSCTL_MIN_VERSION or newer (EKS $KUBERNETES_VERSION support)"
}

# Refuse to act in any account but the configured one, so a wrong profile cannot build or
# delete a cluster in the wrong place.
require_caller_account() {
  local arn account
  [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS_ACCOUNT_ID is not set in config.local.env"
  arn="$(aws sts get-caller-identity --query Arn --output text)" || die "no AWS credentials"
  account="$(aws sts get-caller-identity --query Account --output text)"
  echo "Caller: $arn"
  [[ "$account" == "$AWS_ACCOUNT_ID" ]] \
    || die "the caller is in account $account, not AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID; refusing"
}

# cluster_state: prints the EKS cluster status, or NONE when it does not exist. Any other
# failure to read it (credentials, throttling) stops the script rather than reading as NONE,
# so a clean up can never mistake a read failure for "already gone".
cluster_state() {
  local out status=0
  out="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query cluster.status --output text 2>&1)" || status=$?
  if ((status == 0)); then
    printf '%s\n' "$out"
  elif grep -Eq '^(aws: \[ERROR\]: )?An error occurred \(ResourceNotFoundException\) when calling the DescribeCluster operation' <<<"$out"; then
    printf 'NONE\n'
  else
    die "could not read cluster $CLUSTER_NAME: $out"
  fi
}

# The cluster must carry this sample's Demo tag before anything touches it.
require_demo_cluster() {
  local tag
  tag="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query "cluster.tags.$DEMO_TAG_KEY" --output text)"
  [[ "$tag" == "$DEMO_TAG_VAL" ]] \
    || die "cluster $CLUSTER_NAME exists but is not tagged $DEMO_TAG_KEY=$DEMO_TAG_VAL; it is not this sample's"
}

# namespace_is_ours: 0 the namespace exists and carries our label (the sample's); 1 it exists
# without the label (someone else's); 2 the read failed (could not tell); 3 it does not exist.
# A read that fails is NEVER read as "gone".
namespace_is_ours() {
  local out rc key_esc="${NS_LABEL_KEY//./\\.}"
  out="$(kubectl get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.${key_esc}}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  ((rc != 0)) && return 2
  [[ "$out" == "|" || -z "$out" ]] && return 3
  [[ "${out%%|*}" == "$NS_LABEL_VAL" ]]
}

# ---------------------------------------------------------------------------
# The assertion tally (test.sh), modelled on the repo's other test.sh scripts
# ---------------------------------------------------------------------------
DEMO_PASS=0
DEMO_FAIL=0
DEMO_SKIP=0

# assert "<what it proves>" <exit-status>: one pass or one fail in the tally. Written so the
# caller reads as a plain shell test followed by $?.
assert() {
  if [[ "${2}" == 0 ]]; then
    printf '  [%s] %s\n' "$(_green PASS)" "$1"; DEMO_PASS=$((DEMO_PASS + 1))
  else
    printf '  [%s] %s\n' "$(_red FAIL)" "$1"; DEMO_FAIL=$((DEMO_FAIL + 1))
  fi
}

# skip "<why it could not run>": counted separately and named in the result line, and FATAL
# for this sample -- every check here backs a headline claim, so a check that could not run
# leaves that claim unproven and the run must not report green.
skip() {
  printf '  [%s] %s\n' "$(_red 'SKIP!')" "$1 (required evidence missing: counts as a failure)"
  DEMO_SKIP=$((DEMO_SKIP + 1))
}

# demo_summary "<what was proven>": last line of test.sh. Exits non-zero on any failure, any
# skip, and when no assertion ran at all, so "N/N passed" can never hide a skipped check.
demo_summary() {
  local subject="${1:-the sample}" total=$((DEMO_PASS + DEMO_FAIL))
  printf '\n'
  if ((total == 0)); then
    printf '%s\n' "$(_red "RESULT: no assertions ran, so ${subject} is NOT proven (${DEMO_SKIP} skipped).")"
    return 1
  fi
  if ((DEMO_FAIL == 0 && DEMO_SKIP == 0)); then
    printf '%s\n' "$(_green "RESULT: ${subject}: ${DEMO_PASS}/${total} assertions passed.")"
  elif ((DEMO_FAIL == 0)); then
    printf '%s\n' "$(_red "RESULT: ${DEMO_SKIP} required check(s) could not run, so ${subject} is NOT proven. See the SKIP lines above.")"
  else
    printf '%s\n' "$(_red "RESULT: ${DEMO_FAIL} of ${total} assertion(s) FAILED. See above.")"
    ((DEMO_SKIP > 0)) && printf '%s\n' "$(_amber "${DEMO_SKIP} check(s) skipped.")"
  fi
  ((DEMO_FAIL == 0 && DEMO_SKIP == 0))
}

# ---------------------------------------------------------------------------
# The cleanup tally (clean.sh)
# ---------------------------------------------------------------------------
CLEAN_FAIL=0

# clean_failed "<what>" "<verbatim output>": record a teardown step that did not complete.
# Prints the step and its output and bumps the failure count, but returns 0 so a clean.sh
# under set -e records the failure and still runs its remaining teardown. clean_summary owns
# the exit code.
clean_failed() {
  printf '%s %s\n' "$(_red 'CLEAN FAILED:')" "$1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /' >&2
  CLEAN_FAIL=$((CLEAN_FAIL + 1))
  return 0
}

# clean_summary "<what was removed>": last line of clean.sh. Non-zero when any teardown step
# was recorded as failed, so a clean up that could not finish never reports success.
clean_summary() {
  local subject="${1:-the sample}"
  printf '\n'
  if ((CLEAN_FAIL == 0)); then
    printf '%s\n' "$(_green "CLEAN: ${subject}: nothing left behind.")"
  else
    printf '%s\n' "$(_red "CLEAN: ${CLEAN_FAIL} teardown step(s) did not complete for ${subject}. See above.")"
  fi
  ((CLEAN_FAIL == 0))
}
