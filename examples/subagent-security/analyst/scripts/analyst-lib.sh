#!/usr/bin/env bash
# analyst-lib.sh -- the half of a Subagent security sample's setup that every one of them
# shares: the namespace, the ServiceAccount, the synthetic supplier API with its key and
# TLS material, the S3 bucket with the seeded proposals, the IAM role and the EKS Pod
# Identity association.
#
# Source it, do not run it. A sample's own setup script sets the variables below, sources
# this file, and calls the analyst_* functions in order; everything specific to the
# confinement layer (its image, its pod, its profiles) stays in the sample.
#
# The caller must set, before sourcing:
#   SAMPLE          the sample's name, which is also its ManagedBy tag value
#   SAMPLE_DIR      the sample's folder (…/examples/subagent-security/<sample>)
#   SECTION_DIR     …/examples/subagent-security
#   TMP_DIR         the run's scratch folder under the repository's tmp/
#   STATE_FILE      the run record, inside TMP_DIR
#   NAMESPACE CLUSTER_NAME AWS_REGION BUCKET ROLE_NAME BEDROCK_MODEL_ID
#   KUBE_CONTEXT    optional; when set, every kubectl call is pinned to it
#
# Nothing here changes a cluster-wide setting or a shared install, and nothing here
# deletes anything: a sample's clean up does that.

ANALYST_SA="analyst"
ANALYST_CASE="rfp-001"
ANALYST_PROPOSALS=(northstar harbor cedar)

# ---------------------------------------------------------------------------
# Output and refusal
# ---------------------------------------------------------------------------

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

state_put() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

# Every kubectl call goes through kc, so one KUBE_CONTEXT pins the whole run and a context
# another session changes cannot redirect it.
kc() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"
  else kubectl "$@"; fi
}

# A lookup that cannot run is "could not determine", which is a failure, never "absent".
# Absence is proved by the service's own not-found exception and nothing else; any other
# error has to stop the script before it can create a duplicate of something already
# there.
#   lookup <not-found-exception> <aws args...>
#     prints stdout and returns 0 when the resource is there
#     returns 1 only when the named exception came back
#     returns 2 when it could not be determined, having printed the AWS error
#
# It returns 2 rather than exiting, because callers run it inside a command substitution:
# an exit there would leave the subshell only, and the caller would read the non-zero
# status as "absent" and go on to create the resource.
lookup() {
  local notfound="$1"; shift
  local out err rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/analyst-out.XXXXXX")" || return 2
  err="$(mktemp "${TMPDIR:-/tmp}/analyst-err.XXXXXX")" || return 2
  aws "$@" >"$out" 2>"$err" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$out"; rm -f "$out" "$err"; return 0; fi
  if grep -Fq "$notfound" "$err"; then rm -f "$out" "$err"; return 1; fi
  echo "ERROR: 'aws $*' failed (exit $rc) and not with $notfound, so it is unknown whether the resource exists:" >&2
  sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"
  return 2
}

stop_if_undetermined() { # <lookup-rc> <description>
  [[ "$1" != 2 ]] ||
    die "could not determine whether $2 exists (the AWS error is above), so this run created and changed nothing. Re-run once the call succeeds."
}

require_managed_by() { # <description> <actual-tag-value>
  [[ "$2" == "$SAMPLE" ]] ||
    die "$1 already exists and is not this sample's (ManagedBy='$2', expected '$SAMPLE'); created and changed nothing. Delete it, or set a new name in .env."
}

# Renders a shared manifest with this run's names. Never edits a file in place, and never
# applies a manifest that hard-codes a default: a NAMESPACE a reader changed in .env has
# to reach every object the run applies.
#
# After substituting, it refuses a manifest that still holds a placeholder. A value that
# did not arrive leaves its <PLACEHOLDER> in the file, and Kubernetes would take it as a
# literal: a namespace really called "<NAMESPACE>", or a pod whose image is the string
# "<ANALYST_IMAGE>". Some of these are caught by the API server and some are not, so the
# check does not depend on which.
#
# Whole comment lines are dropped first, so a manifest that mentions something like
# "<bucket>.s3.<Region>" in its own explanation is not mistaken for one. Only whole lines:
# cutting from the first "#" anywhere on a line would also cut a "#" inside a quoted YAML
# value, and a placeholder after it would escape the guard. The pattern is the all-caps
# placeholder convention these manifests use.
analyst_render() { # <manifest> <out> [extra sed expressions...]
  local src="$1" out="$2"; shift 2
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" \
      -e "s|<MANAGED_BY>|$SAMPLE|g" \
      "${@/#/-e}" "$src" > "$out"
  # "grep || true": finding no placeholder is this guard's success case, and grep exits 1
  # when it matches nothing. Under the callers' "set -euo pipefail" an unguarded grep
  # would make the whole assignment fail and exit the script with no message at all.
  local left
  left="$(sed '/^[[:space:]]*#/d' "$out" | { grep -oE '<[A-Z_]+>' || true; } |
    sort -u | tr '\n' ' ')"
  [[ -z "$left" ]] ||
    die "$(basename "$src") still holds the placeholder(s) $left after rendering, so a value this run needed was empty. Nothing was applied from it."
}

# ---------------------------------------------------------------------------
# Preflight the three samples share
# ---------------------------------------------------------------------------

analyst_preflight() {
  say "1/7 tools, cluster and cluster-wide settings"
  local c
  for c in aws jq kubectl docker openssl python3; do
    command -v "$c" >/dev/null 2>&1 || die "$c is required"
  done
  [[ -n "$AWS_REGION" ]] || die "AWS_REGION is not set; copy .env.example to .env and fill it in"
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  [[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is not set; copy .env.example to .env and fill it in"

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" ||
    die "could not read the AWS account; check your credentials"
  echo "  account:  $ACCOUNT_ID"
  echo "  region:   $AWS_REGION"
  echo "  context:  $(kc config current-context)"

  kc get runtimeclass isolated-sandbox -o name >/dev/null 2>&1 ||
    die "the isolated-sandbox runtime class is not on this cluster; run the Getting started samples first"

  # Resolve the model now, so a Bedrock profile the account cannot see fails before
  # anything is created.
  local info
  info="$(aws bedrock get-inference-profile --inference-profile-identifier "$BEDROCK_MODEL_ID" \
    --output json 2>/dev/null)" ||
    die "could not read the Bedrock inference profile '$BEDROCK_MODEL_ID' in $AWS_REGION. Check BEDROCK_MODEL_ID in .env and that the account has access to it."
  MODEL_RESOURCES="$(jq -c '[.inferenceProfileArn] + [.models[].modelArn]' <<<"$info")"
  echo "  model:    $BEDROCK_MODEL_ID"
}

# ---------------------------------------------------------------------------
# The namespace and the ServiceAccount
# ---------------------------------------------------------------------------

analyst_namespace() {
  say "2/7 namespace $NAMESPACE and the analyst ServiceAccount"
  analyst_render "$SECTION_DIR/analyst/deploy/namespace.yaml" "$TMP_DIR/namespace.yaml"
  analyst_render "$SECTION_DIR/analyst/deploy/service-account.yaml" "$TMP_DIR/service-account.yaml"

  # Create the namespace only when absent, and reuse it only when it already carries this
  # sample's label. Applying over a namespace another demo owns would put the mark on it,
  # and this sample's clean up would then delete it.
  local exists label
  if exists="$(kc get namespace "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)" &&
     label="$(kc get namespace "$NAMESPACE" --ignore-not-found \
       -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"; then
    :
  else
    die "could not determine whether namespace $NAMESPACE exists (the kubectl lookup failed; check the context and your permissions); created nothing in the cluster"
  fi
  if [[ -z "$exists" ]]; then
    kc apply -f "$TMP_DIR/namespace.yaml"
    state_put NAMESPACE_CREATED true
  elif [[ "$label" != "$SAMPLE" ]]; then
    die "namespace $NAMESPACE already exists and is not this sample's (managed-by='$label'); created nothing in it. Delete it, or set a new NAMESPACE in .env."
  else
    echo "  reusing namespace $NAMESPACE (it carries this sample's managed-by label)"
    state_put NAMESPACE_CREATED false
  fi
  kc apply -f "$TMP_DIR/service-account.yaml"
}

# ---------------------------------------------------------------------------
# The supplier API: its key, its TLS material, its image and its pod
# ---------------------------------------------------------------------------

# The key and the certificate are generated here and never typed on a command line:
# kubectl reads each from a file, and the files stay under the repository's tmp/.
analyst_supplier_secrets() {
  say "3/7 the supplier API key and its sample certificate authority"
  local secrets_dir="$TMP_DIR/supplier"
  mkdir -p "$secrets_dir"
  chmod 700 "$secrets_dir"

  if kc get secret supplier-key -n "$NAMESPACE" -o name >/dev/null 2>&1; then
    echo "  reusing the supplier-key Secret already in this sample's namespace"
  else
    openssl rand -base64 32 | tr -d '\n' > "$secrets_dir/api-key"
    chmod 600 "$secrets_dir/api-key"
    kc create secret generic supplier-key -n "$NAMESPACE" \
      --from-file=api-key="$secrets_dir/api-key"
    # A client-side apply would copy the key into the last-applied-configuration
    # annotation, which kubectl describe prints. create does not, and this confirms it.
    [[ -z "$(kc get secret supplier-key -n "$NAMESPACE" \
      -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}')" ]] ||
      die "the supplier-key Secret carries a last-applied-configuration annotation, which would hold the key in clear text"
    echo "  created the supplier-key Secret"
  fi

  # The Secret and the CA ConfigMap are one unit: the proxy trusts the CA that signed the
  # server certificate, so half a pair is not usable. Refuse rather than guess.
  local tls ca
  tls="$(kc get secret supplier-tls -n "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"
  ca="$(kc get configmap supplier-ca -n "$NAMESPACE" --ignore-not-found -o name 2>/dev/null)"
  if [[ -n "$tls" && -n "$ca" ]]; then
    echo "  reusing the supplier-tls Secret and the supplier-ca ConfigMap"
    return
  fi
  [[ -z "$tls" && -z "$ca" ]] ||
    die "this namespace has only one of the supplier-tls Secret and the supplier-ca ConfigMap, so the certificate and the authority that signed it do not make a pair. Run ./scripts/clean.sh and then this script again."

  # A sample certificate authority, for a server reached only inside the cluster. Both
  # Service names are in the certificate, so the hostname refusal on the page comes from
  # the confinement profile and not from a TLS error.
  #
  # keyUsage on the authority is not optional here: Python's default TLS context enables
  # OpenSSL's strict X.509 checks, which reject a CA certificate that does not carry
  # keyCertSign. Without it the trusted control fails with "CA cert does not include key
  # usage extension" and a refusal the page attributes to nono would really be a TLS error.
  local alt="DNS:supplier-api.$NAMESPACE.svc.cluster.local,DNS:supplier-api-alias.$NAMESPACE.svc.cluster.local"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=subagent-security-sample-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -keyout "$secrets_dir/ca.key" -out "$secrets_dir/ca.crt" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=supplier-api" \
    -keyout "$secrets_dir/tls.key" -out "$secrets_dir/server.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=%s\n' \
    "$alt" > "$secrets_dir/server.ext"
  openssl x509 -req -in "$secrets_dir/server.csr" -CA "$secrets_dir/ca.crt" \
    -CAkey "$secrets_dir/ca.key" -CAcreateserial -days 30 \
    -extfile "$secrets_dir/server.ext" -out "$secrets_dir/tls.crt" 2>/dev/null
  chmod 600 "$secrets_dir"/*.key
  kc create secret tls supplier-tls -n "$NAMESPACE" \
    --cert="$secrets_dir/tls.crt" --key="$secrets_dir/tls.key"
  kc create configmap supplier-ca -n "$NAMESPACE" --from-file=ca.crt="$secrets_dir/ca.crt"
  echo "  created a 30-day sample certificate authority and the supplier-tls Secret"
}

# Builds and pushes one image, reusing the pushed tag when the inputs have not changed.
#   analyst_image <ecr-repository> <dockerfile, relative to SECTION_DIR> <input paths...>
# Prints nothing; sets ANALYST_IMAGE.
analyst_image() {
  local repo="$1" dockerfile="$2"; shift 2
  local tag registry existing rc
  # The tag is a digest of the build inputs, so a changed file always means a new tag and
  # a pod can never run yesterday's code under today's name.
  tag="$( (cd "$SECTION_DIR" && cat "$dockerfile" "$@" | sha256sum) | cut -c1-20)"
  registry="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
  ANALYST_IMAGE="$registry/$repo:$tag"

  # "|| rc=$?" and not "; rc=$?": a failing assignment is not a tested context, so under
  # set -e the shell would exit before rc could be read, and a not-found lookup would
  # stop the run instead of meaning "create it".
  rc=0
  existing="$(lookup RepositoryNotFoundException ecr describe-repositories \
    --repository-names "$repo" --output json)" || rc=$?
  stop_if_undetermined "$rc" "the ECR repository $repo"
  if [[ "$rc" == 0 ]]; then
    local arn tags
    arn="$(jq -r '.repositories[0].repositoryArn' <<<"$existing")"
    tags="$(aws ecr list-tags-for-resource --resource-arn "$arn" --output json)" ||
      die "could not read the tags on the ECR repository $repo, so it is unknown whether it is this sample's"
    require_managed_by "the ECR repository $repo" \
      "$(jq -r '.tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$tags")"
  else
    aws ecr create-repository --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true \
      --tags "Key=ManagedBy,Value=$SAMPLE" >/dev/null
    echo "  created the ECR repository $repo"
  fi

  if aws ecr describe-images --repository-name "$repo" --image-ids "imageTag=$tag" \
      >/dev/null 2>&1; then
    echo "  reusing $repo:$tag (the build inputs have not changed)"
    return
  fi
  local docker_config
  docker_config="$(mktemp -d "${TMPDIR:-/tmp}/analyst-docker.XXXXXX")"
  # The registry password goes in on standard input, never on a command line.
  aws ecr get-login-password --region "$AWS_REGION" |
    docker --config "$docker_config" login --username AWS --password-stdin "$registry" \
      >/dev/null ||
    die "could not sign in to $registry"
  ( cd "$SECTION_DIR" &&
    docker build --platform linux/amd64 -f "$dockerfile" -t "$ANALYST_IMAGE" . ) ||
    die "the image build failed"
  docker --config "$docker_config" push "$ANALYST_IMAGE" >/dev/null ||
    die "could not push $ANALYST_IMAGE"
  rm -rf "$docker_config"
  echo "  built and pushed $repo:$tag"
}

analyst_supplier_api() {
  say "4/7 the synthetic supplier API"
  analyst_image "$SUPPLIER_API_REPOSITORY" analyst/supplier-api/Dockerfile \
    analyst/supplier-api/supplier_api.py analyst/src/business.py \
    analyst/fixtures/case.json analyst/fixtures/availability.json
  analyst_render "$SECTION_DIR/analyst/deploy/supplier-api.yaml" "$TMP_DIR/supplier-api.yaml" \
    "s|<SUPPLIER_API_IMAGE>|$ANALYST_IMAGE|g"
  kc apply -n "$NAMESPACE" -f "$TMP_DIR/supplier-api.yaml"
  kc rollout status deployment/supplier-api -n "$NAMESPACE" --timeout=5m ||
    die "the supplier API did not become ready"
}

# ---------------------------------------------------------------------------
# S3: the bucket and the seeded proposals
# ---------------------------------------------------------------------------

analyst_bucket() {
  say "5/7 the S3 bucket and the proposals"
  local rc=0
  lookup NoSuchBucket s3api get-bucket-tagging --bucket "$BUCKET" --output json \
    >"$TMP_DIR/bucket-tags.json" 2>/dev/null || rc=$?
  if [[ "$rc" == 0 ]]; then
    require_managed_by "the bucket $BUCKET" \
      "$(jq -r '.TagSet[]? | select(.Key=="ManagedBy") | .Value' "$TMP_DIR/bucket-tags.json")"
    echo "  reusing the bucket $BUCKET"
  else
    # get-bucket-tagging answers NoSuchTagSet for a bucket that exists with no tags, and
    # NoSuchBucket only when there is none, so an untagged bucket must not be adopted.
    if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
      die "the bucket $BUCKET already exists and carries no ManagedBy=$SAMPLE tag; created and changed nothing. Delete it, or set a new BUCKET in .env."
    fi
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null ||
      die "could not create the bucket $BUCKET"
    aws s3api put-bucket-tagging --bucket "$BUCKET" \
      --tagging "TagSet=[{Key=ManagedBy,Value=$SAMPLE}]"
    state_put BUCKET_CREATED true
    echo "  created the bucket $BUCKET"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  local f
  aws s3api put-object --bucket "$BUCKET" --key "proposals/$ANALYST_CASE/case.json" \
    --body "$SECTION_DIR/analyst/fixtures/case.json" >/dev/null
  for f in "${ANALYST_PROPOSALS[@]}"; do
    aws s3api put-object --bucket "$BUCKET" --key "proposals/$ANALYST_CASE/$f.json" \
      --body "$SECTION_DIR/analyst/fixtures/proposals/$f.json" >/dev/null
  done
  # Another case's object, so the page's denied read names a real object that is readable
  # with other credentials. Without it, AccessDenied could just be a missing key.
  printf '{"case_id":"rfp-other","note":"another case, outside the analyst role grant"}\n' \
    > "$TMP_DIR/rfp-other-case.json"
  aws s3api put-object --bucket "$BUCKET" --key "proposals/rfp-other/case.json" \
    --body "$TMP_DIR/rfp-other-case.json" >/dev/null
  echo "  seeded the case, ${#ANALYST_PROPOSALS[@]} proposals and one other case's object"
}

# ---------------------------------------------------------------------------
# The IAM role and the Pod Identity association
# ---------------------------------------------------------------------------

analyst_role() {
  say "6/7 the IAM role and its EKS Pod Identity association"
  jq --arg ns "$NAMESPACE" 'del(._comment)
      | .Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] = $ns' \
    "$SECTION_DIR/analyst/iam/role-trust-policy.json" > "$TMP_DIR/role-trust-policy.json"
  jq --arg bucket "$BUCKET" --argjson models "$MODEL_RESOURCES" 'del(._comment)
      | .Statement |= map(
          if .Sid == "InvokeTheConfiguredModel" then .Resource = $models
          else .Resource = (.Resource | if type == "array" then map(gsub("<BUCKET>"; $bucket))
                                        else gsub("<BUCKET>"; $bucket) end) end)' \
    "$SECTION_DIR/analyst/iam/permissions-policy.json" > "$TMP_DIR/permissions-policy.json"

  local existing rc=0
  existing="$(lookup NoSuchEntity iam get-role --role-name "$ROLE_NAME" --output json)" || rc=$?
  stop_if_undetermined "$rc" "the IAM role $ROLE_NAME"
  if [[ "$rc" == 0 ]]; then
    require_managed_by "the IAM role $ROLE_NAME" \
      "$(jq -r '.Role.Tags[]? | select(.Key=="ManagedBy") | .Value' <<<"$existing")"

    # The tag says the role is this sample's; it does not say the role still carries only
    # what this sample grants. An interrupted run, a hand edit or another version of the
    # sample could have left a second inline policy or an attached managed policy, and
    # putting the analyst policy back would not remove it. The page then shows
    # AccessDenied as evidence of least privilege while the role in fact holds more, so
    # refuse rather than reuse. The clean up makes the same check before it deletes.
    local inline attached extra
    inline="$(aws iam list-role-policies --role-name "$ROLE_NAME" --output json)" ||
      die "could not list the inline policies on the IAM role $ROLE_NAME, so it is unknown whether it carries only this sample's; changed nothing."
    attached="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json)" ||
      die "could not list the attached policies on the IAM role $ROLE_NAME, so it is unknown whether it carries only this sample's; changed nothing."
    extra="$(jq -r '.PolicyNames[] | select(. != "analyst")' <<<"$inline" | tr '\n' ' ')"
    [[ -z "$extra" ]] ||
      die "the IAM role $ROLE_NAME carries inline policies this sample did not create ($extra), so reusing it would leave the controller with more than this sample grants; changed nothing. Delete the role, or set a new ROLE_NAME in .env."
    [[ "$(jq '.AttachedPolicies | length' <<<"$attached")" == 0 ]] ||
      die "the IAM role $ROLE_NAME has managed policies attached ($(jq -r '[.AttachedPolicies[].PolicyName] | join(", ")' <<<"$attached")), so reusing it would leave the controller with more than this sample grants; changed nothing. Delete the role, or set a new ROLE_NAME in .env."

    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
      --policy-document "file://$TMP_DIR/role-trust-policy.json"
    ROLE_ARN="$(jq -r '.Role.Arn' <<<"$existing")"
    echo "  reusing the IAM role $ROLE_NAME (it carries only this sample's analyst policy)"
  else
    ROLE_ARN="$(aws iam create-role --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$TMP_DIR/role-trust-policy.json" \
      --tags "Key=ManagedBy,Value=$SAMPLE" --query Role.Arn --output text)" ||
      die "could not create the IAM role $ROLE_NAME"
    state_put ROLE_CREATED true
    echo "  created the IAM role $ROLE_NAME"
  fi
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name analyst \
    --policy-document "file://$TMP_DIR/permissions-policy.json"
  state_put ROLE_ARN "$ROLE_ARN"

  # An association is identified by cluster, namespace and service account, not by a name.
  local assoc assoc_role
  assoc="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" --service-account "$ANALYST_SA" --output json)" ||
    die "could not list the Pod Identity associations for $NAMESPACE/$ANALYST_SA on $CLUSTER_NAME"
  if [[ "$(jq '.associations | length' <<<"$assoc")" != 0 ]]; then
    local id
    id="$(jq -r '.associations[0].associationId' <<<"$assoc")"
    assoc_role="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$id" --query association.roleArn --output text)" ||
      die "could not read the existing Pod Identity association $id"
    [[ "$assoc_role" == "$ROLE_ARN" ]] ||
      die "the Pod Identity association for $NAMESPACE/$ANALYST_SA points at $assoc_role, not $ROLE_ARN; changed nothing. Remove it, or set a new NAMESPACE in .env."
    echo "  reusing the Pod Identity association $id"
  else
    local id
    id="$(aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --namespace "$NAMESPACE" --service-account "$ANALYST_SA" --role-arn "$ROLE_ARN" \
      --tags "ManagedBy=$SAMPLE" --query association.associationId --output text)" ||
      die "could not create the Pod Identity association"
    state_put POD_IDENTITY_ASSOCIATION "$id"
    echo "  created the Pod Identity association $id"
  fi
}
