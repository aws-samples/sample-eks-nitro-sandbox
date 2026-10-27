#!/usr/bin/env bash
# Helpers the four scripts in this folder share: the env file, the run record, the kube
# context, ECR credentials, and the build-push-sign step the provider's side repeats for
# each release. Sourced, never run on its own.

SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_DIR="$(cd "$SAMPLE_DIR/../_shared" && pwd)"
REPO_ROOT="$(cd "$SAMPLE_DIR/../../.." && pwd)"
# Every local file this sample writes lives here, under the repository's gitignored tmp/:
# the run record, the generated policies, the rendered pods and the logs. Nothing is
# written into the sample folder, which is published.
TMP_DIR="$REPO_ROOT/tmp/signer-policy"
STATE_FILE="$TMP_DIR/state.env"

# The ownership mark on every AWS resource this sample creates, and the label on its
# namespace. It names the sample, so a resource carries it whichever run created it.
MANAGED_BY="eks-nitro-sandbox-signer-policy-sample"
NAMESPACE="${NAMESPACE:-signer-policy-sample}"
SERVICE_ACCOUNT="signer-policy-pod"
POD_NAME="${POD_NAME:-signer-policy-demo}"
PINNED_POD_NAME="${PINNED_POD_NAME:-signer-policy-pinned}"
CONTAINER_NAME="app"
ECR_REPOSITORY="${ECR_REPOSITORY:-nitro-sample-signer-policy}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-nitro-sample-signer-policy-verify}"
SIGNER_POLICY_NAME="signer-policy-verify"
SIGNING_PLATFORM_ID="Notation-OCI-SHA384-ECDSA"
SIGNER_PLUGIN_ID="com.amazonaws.signer.notation.plugin"
# The generator profile the Confidential samples share, and the command it is invoked as.
# The Amazon EKS User Guide names the generator eks-nitro-sandbox-genpolicy; override
# GENPOLICY if your copy is named differently.
PROFILE="$SHARED_DIR/confidential-profile.yaml"
GENPOLICY="${GENPOLICY:-eks-nitro-sandbox-genpolicy}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

# The guest's own wording when its Cedar policy refuses an operation, as a fixed string.
# It must stay this specific. An earlier version matched "denied|not permitted|policy",
# and this sample's own image reference contains the word "policy"
# (nitro-sample-signer-policy), so any pull failure, throttle or expired credential whose
# message quoted the image name was read as a policy refusal, which is the one thing the
# refusal arm exists to tell apart.
POLICY_DENIAL='policy denied Agent::Action::'

require_commands() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
}

# The context is named on every kubectl call and never switched with use-context, so a run
# on a shared machine cannot be redirected by another session. Set KUBE_CONTEXT to your
# cluster's context (kubectl config get-contexts); leave it empty to use the current one.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}

load_env() {
  [[ -f "$SAMPLE_DIR/.env" ]] ||
    die "no .env in $SAMPLE_DIR. Copy .env.example to .env and fill it in."
  set -a
  # shellcheck disable=SC1091
  . "$SAMPLE_DIR/.env"
  set +a
  : "${CLUSTER_NAME:?set CLUSTER_NAME in .env}"
  : "${AWS_REGION:?set AWS_REGION in .env}"
  : "${SIGNING_PROFILE:?set SIGNING_PROFILE in .env}"
  : "${RELEASE_ONE:?set RELEASE_ONE in .env}"
  : "${RELEASE_TWO:?set RELEASE_TWO in .env}"
  [[ "$RELEASE_ONE" != "$RELEASE_TWO" ]] ||
    die "RELEASE_ONE and RELEASE_TWO are both '$RELEASE_ONE'. The sample needs two different releases, because the second one is the image the first one's policy has never seen."
  export AWS_DEFAULT_REGION="$AWS_REGION"
}

# The run record. Each script appends what it learned, so the next one reads it rather
# than looking anything up again.
state_put() {  # state_put KEY VALUE
  mkdir -p "$TMP_DIR"
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.next" 2>/dev/null || true
  printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE.next"
  mv "$STATE_FILE.next" "$STATE_FILE"
}
load_state() {
  [[ -f "$STATE_FILE" ]] || die "no run record at $STATE_FILE; run ./scripts/setup.sh first"
  set -a
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  set +a
}

# A lookup that fails means "could not determine", which is a failure and never "absent".
# Callers pass the exception name that genuinely means absent; anything else stops the run.
lookup() {  # lookup <not-found-exception> <aws args...>
  local absent="$1"; shift
  local out rc
  out="$(aws "$@" 2>"$TMP_DIR/aws.err")" && { printf '%s' "$out"; return 0; }
  rc=$?
  if grep -q "$absent" "$TMP_DIR/aws.err"; then return 2; fi
  echo "the AWS call 'aws $*' failed:" >&2
  cat "$TMP_DIR/aws.err" >&2
  return "$rc"
}
stop_if_undetermined() {  # stop_if_undetermined <rc> <what>
  [[ "$1" == 0 || "$1" == 2 ]] ||
    die "could not determine the state of $2 (the AWS call failed; check the Region and permissions). Created and changed nothing."
}
require_managed_by() {  # require_managed_by <what> <tag-value>
  [[ "$2" == "$MANAGED_BY" ]] ||
    die "$1 already exists but is not this sample's (ManagedBy='${2:-unset}', expected '$MANAGED_BY'). Refusing to touch it. Use a different name in .env, or delete it yourself."
}

# Registry credentials, written into a throwaway HOME for the generator and a throwaway
# DOCKER_CONFIG for docker. The password never reaches a command line: a command line is
# readable from /proc by any local user on this machine, and this is a live registry
# credential.
#
# Both get the authorization token itself rather than a credential helper. Pointing docker
# at the "ecr-login" helper would be tidier, because nothing in the file would expire, but
# it needs docker-credential-ecr-login installed: without it docker fails the push with
# "no basic auth credentials", and the sample would need a prerequisite that earns a
# reader nothing. The token lasts about 12 hours, which outlives a run, and both files are
# written under the repository's gitignored tmp/ with mode 600.
write_registry_credentials() {  # write_registry_credentials <registry>
  local registry="$1" token
  GENPOLICY_HOME="$TMP_DIR/genpolicy-home"
  DOCKER_CFG_DIR="$TMP_DIR/docker-config"
  rm -rf "$GENPOLICY_HOME" "$DOCKER_CFG_DIR"
  mkdir -p "$GENPOLICY_HOME/.docker" "$DOCKER_CFG_DIR"
  # Checked before it is encoded. Inside a pipeline a failed command substitution does not
  # stop the script, so without this the pipeline would encode a bare "AWS:" and write a
  # well-formed config holding no password; the generator would then fail later with an
  # opaque authentication error.
  token="$(aws ecr get-login-password --region "$AWS_REGION")" ||
    die "could not get an ECR authorization token"
  [[ -n "$token" ]] || die "the ECR authorization token came back empty"
  # The umask is set in the subshell that writes, so the file is never briefly
  # world-readable the way it would be if it were created first and chmod-ed after.
  ( umask 077
    printf 'AWS:%s' "$token" | base64 | tr -d '\r\n' \
      | jq -Rn --arg registry "$registry" '{auths: {($registry): {auth: input}}}' \
      > "$GENPOLICY_HOME/.docker/config.json" )
  unset token
  # "QVdTOg" is base64 for "AWS:", so a token-less "AWS:" encodes to exactly that and
  # nothing more. Anything longer carries a password.
  jq -e --arg registry "$registry" '
    .auths[$registry].auth
    | type == "string" and . != "QVdTOg==" and length > 8
  ' "$GENPOLICY_HOME/.docker/config.json" >/dev/null ||
    die "could not write the registry credentials the policy generator needs"
  # docker reads the same credentials from its own config, so the push needs no helper.
  ( umask 077; cp "$GENPOLICY_HOME/.docker/config.json" "$DOCKER_CFG_DIR/config.json" )
  export DOCKER_CONFIG="$DOCKER_CFG_DIR"
}

# The provider's side, once per release: build the image, push it under the release's own
# tag, and sign it with the sample's AWS Signer profile. Prints the digest it pushed.
build_push_sign() {  # build_push_sign <release> <registry> <signing-profile-arn>
  local release="$1" registry="$2" profile_arn="$3" uri digest
  uri="$registry/$ECR_REPOSITORY:$release"
  # The repository has IMMUTABLE tags, so a tag that is already there cannot be
  # overwritten. Stop rather than push into a release the reader may be relying on.
  if aws ecr describe-images --repository-name "$ECR_REPOSITORY" \
       --image-ids "imageTag=$release" --region "$AWS_REGION" >/dev/null 2>&1; then
    die "the tag $release already exists in $ECR_REPOSITORY, and the repository has IMMUTABLE tags. Set a release name it does not hold in .env, or remove the repository with ./scripts/clean.sh --delete-aws-resources."
  fi
  # Both are checked explicitly rather than left to set -e: this function runs inside a
  # command substitution, and a failure here would otherwise surface further down as an
  # unrelated "could not read back the digest", which hides what actually went wrong.
  DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build --platform linux/amd64 \
    --build-arg "RELEASE=$release" --tag "$uri" "$SAMPLE_DIR" >&2 ||
    die "docker build failed for release $release"
  docker push "$uri" >&2 ||
    die "docker push failed for $uri. If it reported \"no basic auth credentials\", the authorization token this script wrote has expired or the account does not have access to the repository; run this again."
  digest="$(aws ecr describe-images --repository-name "$ECR_REPOSITORY" \
    --image-ids "imageTag=$release" --region "$AWS_REGION" \
    --query 'imageDetails[0].imageDigest' --output text)"
  [[ "$digest" == sha256:* ]] || die "could not read back the digest of $uri"
  # Notation signs the digest, not the tag. The signature is stored in the registry
  # beside the image, which is where the guest's agent reads it from.
  notation sign "$registry/$ECR_REPOSITORY@$digest" \
    --plugin "$SIGNER_PLUGIN_ID" --id "$profile_arn" \
    --plugin-config "aws-region=$AWS_REGION" >&2
  notation ls "$registry/$ECR_REPOSITORY@$digest" 2>/dev/null \
    | grep -q 'application/vnd.cncf.notary.signature' ||
    die "notation sign reported success but no signature is attached to $digest"
  printf '%s' "$digest"
}

# Decode a policy envelope into the readable Cedar document, so the page and the reader
# can see what the guest will enforce. The annotation itself is gzipped base64.
decode_policy() {  # decode_policy <b64-file> <out-yaml>
  local raw="$1.raw" json="$1.json"
  base64 --decode "$1" > "$raw"
  if gzip -t "$raw" >/dev/null 2>&1; then gzip -dc "$raw" > "$json"; else cp "$raw" "$json"; fi
  jq -e '(.version | type) == "number" and (.admission_policy | type) == "string"' "$json" >/dev/null ||
    die "the generated policy envelope has an unexpected schema ($json)"
  jq -r '
    def yaml_block($key):
      .[$key] as $value
      | if ($value | endswith("\n")) then
          "\($key): |+\n" + ($value | rtrimstr("\n") | split("\n") | map("  " + .) | join("\n"))
        else
          "\($key): |-\n" + ($value | split("\n") | map("  " + .) | join("\n"))
        end;
    "version: \(.version)", yaml_block("admission_policy"), yaml_block("runtime_policy")
  ' "$json" > "$2"
}

# Create the namespace only when it is absent, and reuse it only when it already carries
# this sample's label. Applying over a namespace another demo owns would add the mark and
# then let a later delete act in a namespace this sample does not own.
ensure_namespace() {
  local rendered="$TMP_DIR/rendered-namespace.json" label exists lrc erc
  kubectl create --dry-run=client --validate=false -o json -f "$SAMPLE_DIR/deploy/namespace.yaml" \
    | jq --arg n "$NAMESPACE" '.metadata.name = $n' > "$rendered"
  if label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"; then lrc=0; else lrc=$?; fi
  if exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"; then erc=0; else erc=$?; fi
  [[ "$lrc" == 0 && "$erc" == 0 ]] ||
    die "could not determine whether namespace $NAMESPACE exists (the kubectl lookup failed; check the context and permissions). Created nothing."
  if [[ -z "$exists" ]]; then
    kc apply -f "$rendered"
  elif [[ "$label" != "signer-policy-sample" ]]; then
    die "namespace $NAMESPACE already exists and is not this sample's (managed-by='${label:-unset}'). Created nothing. Delete it, or re-run with NAMESPACE set to a name no other workload uses."
  else
    echo "  reusing namespace $NAMESPACE (it carries this sample's label)"
  fi
}

# Wait for a pod to be Ready, or collect why it was not. Prints the guest's reason on
# failure. Used by both arms: one expects Ready, the other expects a refusal.
wait_for_pod() {  # wait_for_pod <name> <seconds>; 0 = Ready, 1 = not Ready
  local name="$1" deadline=$(( SECONDS + $2 )) json
  while (( SECONDS < deadline )); do
    json="$(kc get pod "$name" -n "$NAMESPACE" -o json 2>/dev/null || true)"
    if [[ -n "$json" ]]; then
      [[ "$(jq -r '[.status.conditions[]? | select(.type=="Ready") | .status] | first // "False"' <<<"$json")" != "True" ]] || return 0
      POD_MESSAGE="$(jq -r '
        [ .status.containerStatuses[]? | .state.waiting.message?, .state.terminated.message?,
          .lastState.waiting.message?, .lastState.terminated.message? ]
        + [ .status.conditions[]? | select(.type=="PodScheduled") | .message? ]
        | map(select(. != null and . != "")) | unique | join("\n")' <<<"$json")"
      # A policy refusal is reported by the guest and does not change once it has
      # happened, so there is no point waiting out the rest of the timeout. Any other
      # failure is left to the timeout, because only this one is known to be final.
      if grep -qF "$POLICY_DENIAL" <<<"$POD_MESSAGE"; then return 1; fi
    fi
    sleep 5
  done
  return 1
}

# Replace account numbers and Pod Identity session names before anything from the cluster
# is printed or saved. A Pod Identity session name is built from the cluster and pod
# names, so a raw guest message can carry both the account and the cluster.
redact() {
  sed -e 's/[0-9]\{12\}/<ACCOUNT_ID>/g' -e 's|\(assumed-role/[^/]*/\)[^ "\\]*|\1<session>|g'
}
