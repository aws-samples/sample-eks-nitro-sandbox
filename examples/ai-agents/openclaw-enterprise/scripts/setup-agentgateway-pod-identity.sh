#!/usr/bin/env bash
set -euo pipefail

readonly OWNER_TAG_KEY="ManagedBy"
readonly OWNER_TAG_VALUE="openclaw-enterprise-blueprint"
readonly AGW_NAMESPACE="openclaw-enterprise-agw"
readonly AGW_SERVICE_ACCOUNT="agentgateway"
readonly IAM_ROLE_NAME="openclaw-enterprise-agentgateway"
readonly IAM_INLINE_POLICY_NAME="openclaw-enterprise-bedrock-invoke"
readonly BEDROCK_MODEL_ID="amazon.nova-lite-v1:0"

usage() {
  cat >&2 <<'EOF'
Usage:
  setup-agentgateway-pod-identity.sh \
    --aws-region REGION \
    --aws-account-id ACCOUNT_ID \
    --eks-cluster-name CLUSTER_NAME \
    --kube-context CONTEXT

Creates or verifies the shared AgentGateway IAM role, its regional Bedrock
foundation-model policy, and the EKS Pod Identity association. Existing
resources must exactly match this blueprint and carry its ownership tag.
EOF
}

die() {
  echo "setup-agentgateway-pod-identity: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" && "${value}" != --* ]] ||
    die "${option} requires an explicit value."
}

AWS_REGION=""
AWS_ACCOUNT_ID=""
EKS_CLUSTER_NAME=""
KUBE_CONTEXT=""

while (( $# > 0 )); do
  case "$1" in
    --aws-region)
      require_value "$1" "${2:-}"
      AWS_REGION="$2"
      shift 2
      ;;
    --aws-account-id)
      require_value "$1" "${2:-}"
      AWS_ACCOUNT_ID="$2"
      shift 2
      ;;
    --eks-cluster-name)
      require_value "$1" "${2:-}"
      EKS_CLUSTER_NAME="$2"
      shift 2
      ;;
    --kube-context)
      require_value "$1" "${2:-}"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

missing_argument=false
for option_and_value in \
  "--aws-region|${AWS_REGION}" \
  "--aws-account-id|${AWS_ACCOUNT_ID}" \
  "--eks-cluster-name|${EKS_CLUSTER_NAME}" \
  "--kube-context|${KUBE_CONTEXT}"; do
  IFS='|' read -r option value <<<"${option_and_value}"
  if [[ -z "${value}" ]]; then
    echo "setup-agentgateway-pod-identity: ${option} is required." >&2
    missing_argument=true
  fi
done
if [[ "${missing_argument}" == true ]]; then
  usage
  exit 2
fi

[[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] ||
  die "--aws-account-id must be a 12-digit AWS account ID."
[[ "${AWS_REGION}" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] ||
  die "--aws-region is not a valid AWS Region name."
[[ "${EKS_CLUSTER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] ||
  die "--eks-cluster-name is not a valid EKS cluster name."

for command in aws kubectl jq mktemp grep; do
  command -v "${command}" >/dev/null 2>&1 ||
    die "${command} is required."
done

context_name="$(
  kubectl config get-contexts "${KUBE_CONTEXT}" --no-headers --output=name
)" || die "could not read kube context ${KUBE_CONTEXT}."
[[ "${context_name}" == "${KUBE_CONTEXT}" ]] ||
  die "kube context ${KUBE_CONTEXT} does not exist exactly."
readonly -a KUBECTL=(kubectl --context "${KUBE_CONTEXT}")
"${KUBECTL[@]}" get --raw=/readyz >/dev/null ||
  die "could not reach kube context ${KUBE_CONTEXT}."

owned_kubernetes_resource_exists() {
  local resource="$1"
  local namespace="$2"
  local expected_name="${resource##*/}"
  local -a command=(
    "${KUBECTL[@]}"
    get
    "${resource}"
  )
  if [[ -n "${namespace}" ]]; then
    command+=(--namespace "${namespace}")
  fi
  command+=(
    --ignore-not-found
    --output=jsonpath='{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}'
  )

  local record
  if ! record="$("${command[@]}")"; then
    die "could not verify Kubernetes resource ${resource}."
  fi
  [[ "${record}" == "${expected_name}|${OWNER_TAG_VALUE}" ]]
}

owned_kubernetes_resource_exists "namespace/${AGW_NAMESPACE}" "" ||
  die "AgentGateway namespace is absent or not owned by ${OWNER_TAG_VALUE}."
owned_kubernetes_resource_exists \
  "serviceaccount/${AGW_SERVICE_ACCOUNT}" "${AGW_NAMESPACE}" ||
  die "AgentGateway service account is not owned by ${OWNER_TAG_VALUE}."

readonly -a AWS=(
  aws
  --no-cli-pager
  --region "${AWS_REGION}"
)

aws_text() {
  local description="$1"
  shift
  local output
  if ! output="$("${AWS[@]}" "$@" --output text)"; then
    die "could not verify ${description}."
  fi
  printf '%s' "${output}"
}

caller_account="$(
  aws_text "AWS account" sts get-caller-identity --query Account
)"
[[ "${caller_account}" == "${AWS_ACCOUNT_ID}" ]] ||
  die "AWS CLI is authenticated to account ${caller_account}, not ${AWS_ACCOUNT_ID}."

cluster_record="$(
  aws_text "EKS cluster ${EKS_CLUSTER_NAME}" \
    eks describe-cluster \
    --name "${EKS_CLUSTER_NAME}" \
    --query 'cluster.[name,arn,endpoint]'
)"
IFS=$'\t' read -r \
  returned_cluster_name cluster_arn cluster_endpoint cluster_extra \
  <<<"${cluster_record}"
[[ -z "${cluster_extra:-}" &&
  "${returned_cluster_name}" == "${EKS_CLUSTER_NAME}" ]] ||
  die "EKS returned an unexpected cluster identity."

IFS=':' read -r \
  arn_literal aws_partition arn_service arn_region arn_account arn_resource arn_extra \
  <<<"${cluster_arn}"
[[ "${arn_literal}" == "arn" &&
  -n "${aws_partition}" &&
  "${arn_service}" == "eks" &&
  "${arn_region}" == "${AWS_REGION}" &&
  "${arn_account}" == "${AWS_ACCOUNT_ID}" &&
  "${arn_resource}" == "cluster/${EKS_CLUSTER_NAME}" &&
  -z "${arn_extra:-}" ]] ||
  die "EKS cluster ARN does not match the explicit region, account, and cluster name."
readonly aws_partition
readonly cluster_arn
readonly cluster_endpoint
readonly expected_role_arn="arn:${aws_partition}:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

context_endpoint="$(
  kubectl config view \
    --minify \
    --context "${KUBE_CONTEXT}" \
    --output=jsonpath='{.clusters[0].cluster.server}'
)" || die "could not resolve the API endpoint for kube context ${KUBE_CONTEXT}."
[[ "${context_endpoint}" == "${cluster_endpoint}" ]] ||
  die "kube context ${KUBE_CONTEXT} does not target the explicit EKS cluster."

work_dir="$(mktemp -d)"
created_role=false
created_inline_policy=false
association_creation_attempted=false
created_association_id=""

rollback() {
  local exit_code="$?"
  local rollback_association_id="${created_association_id}"

  if (( exit_code != 0 )); then
    set +e
    echo "setup-agentgateway-pod-identity: setup failed; rolling back resources created by this invocation." >&2

    if [[ "${association_creation_attempted}" == true &&
      ! "${rollback_association_id}" =~ ^a-[a-z0-9]{17}$ ]]; then
      association_ids="$(
        "${AWS[@]}" eks list-pod-identity-associations \
          --cluster-name "${EKS_CLUSTER_NAME}" \
          --namespace "${AGW_NAMESPACE}" \
          --service-account "${AGW_SERVICE_ACCOUNT}" \
          --query 'associations[].associationId' \
          --output text 2>/dev/null
      )"
      read -r -a rollback_association_ids <<<"${association_ids//$'\t'/ }"
      if (( ${#rollback_association_ids[@]} == 1 )) &&
        [[ "${rollback_association_ids[0]}" =~ ^a-[a-z0-9]{17}$ ]]; then
        candidate_id="${rollback_association_ids[0]}"
        candidate_record="$(
          "${AWS[@]}" eks describe-pod-identity-association \
            --cluster-name "${EKS_CLUSTER_NAME}" \
            --association-id "${candidate_id}" \
            --query 'association.[roleArn,tags.ManagedBy,ownerArn]' \
            --output text 2>/dev/null
        )"
        IFS=$'\t' read -r candidate_role candidate_owner candidate_owner_arn candidate_extra \
          <<<"${candidate_record}"
        if [[ -z "${candidate_extra:-}" &&
          "${candidate_role}" == "${expected_role_arn}" &&
          "${candidate_owner}" == "${OWNER_TAG_VALUE}" &&
          "${candidate_owner_arn}" == "None" ]]; then
          rollback_association_id="${candidate_id}"
        fi
      fi
    fi

    if [[ "${rollback_association_id}" =~ ^a-[a-z0-9]{17}$ ]]; then
      "${AWS[@]}" eks delete-pod-identity-association \
        --cluster-name "${EKS_CLUSTER_NAME}" \
        --association-id "${rollback_association_id}" >/dev/null ||
        echo "setup-agentgateway-pod-identity: rollback could not delete Pod Identity association ${rollback_association_id}." >&2
    fi
    if [[ "${created_inline_policy}" == true ]]; then
      "${AWS[@]}" iam delete-role-policy \
        --role-name "${IAM_ROLE_NAME}" \
        --policy-name "${IAM_INLINE_POLICY_NAME}" >/dev/null ||
        echo "setup-agentgateway-pod-identity: rollback could not delete IAM inline policy ${IAM_INLINE_POLICY_NAME}." >&2
    fi
    if [[ "${created_role}" == true ]]; then
      "${AWS[@]}" iam delete-role \
        --role-name "${IAM_ROLE_NAME}" >/dev/null ||
        echo "setup-agentgateway-pod-identity: rollback could not delete IAM role ${IAM_ROLE_NAME}." >&2
    fi
  fi

  rm -rf -- "${work_dir}"
  exit "${exit_code}"
}
trap rollback EXIT
readonly trust_policy_file="${work_dir}/pod-identity-trust.json"
readonly bedrock_policy_file="${work_dir}/bedrock-invoke.json"
readonly role_error_file="${work_dir}/get-role.err"
readonly role_trust_file="${work_dir}/current-role-trust.json"
readonly role_policy_file="${work_dir}/current-role-policy.json"

jq -n \
  --arg account "${AWS_ACCOUNT_ID}" \
  --arg cluster_arn "${cluster_arn}" \
  --arg namespace "${AGW_NAMESPACE}" \
  --arg service_account "${AGW_SERVICE_ACCOUNT}" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "AllowAgentGatewayPodIdentity",
      Effect: "Allow",
      Principal: {Service: "pods.eks.amazonaws.com"},
      Action: ["sts:AssumeRole", "sts:TagSession"],
      Condition: {
        StringEquals: {
          "aws:SourceAccount": $account,
          "aws:RequestTag/kubernetes-namespace": $namespace,
          "aws:RequestTag/kubernetes-service-account": $service_account
        },
        ArnEquals: {"aws:SourceArn": $cluster_arn}
      }
    }]
  }' >"${trust_policy_file}"

jq -n \
  --arg region "${AWS_REGION}" \
  --arg model_arn "arn:${aws_partition}:bedrock:${AWS_REGION}::foundation-model/${BEDROCK_MODEL_ID}" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "InvokeCentralBedrockModel",
      Effect: "Allow",
      Action: [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      Resource: $model_arn,
      Condition: {
        StringEquals: {"aws:RequestedRegion": $region}
      }
    }]
  }' >"${bedrock_policy_file}"

json_documents_match() {
  local expected_file="$1"
  local actual_file="$2"
  [[ "$(jq -S -c . "${expected_file}")" == "$(jq -S -c . "${actual_file}")" ]]
}

role_exists=false
inline_policy_exists=false
if role_record="$(
  "${AWS[@]}" iam get-role \
    --role-name "${IAM_ROLE_NAME}" \
    --query "Role.[RoleName,Arn,Tags[?Key=='${OWNER_TAG_KEY}'].Value | [0],PermissionsBoundary.PermissionsBoundaryArn]" \
    --output text \
    2>"${role_error_file}"
)"; then
  role_exists=true
  IFS=$'\t' read -r \
    returned_role_name returned_role_arn role_owner permissions_boundary role_extra \
    <<<"${role_record}"
  [[ -z "${role_extra:-}" &&
    "${returned_role_name}" == "${IAM_ROLE_NAME}" &&
    "${returned_role_arn}" == "${expected_role_arn}" ]] ||
    die "IAM role identity does not match the explicit account and role name."
  [[ "${role_owner}" == "${OWNER_TAG_VALUE}" ]] ||
    die "IAM role ${IAM_ROLE_NAME} is not tagged ${OWNER_TAG_KEY}=${OWNER_TAG_VALUE}."
  [[ "${permissions_boundary}" == "None" ]] ||
    die "IAM role ${IAM_ROLE_NAME} has an unexpected permissions boundary."

  "${AWS[@]}" iam get-role \
    --role-name "${IAM_ROLE_NAME}" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json >"${role_trust_file}" ||
    die "could not verify the IAM role trust policy."
  json_documents_match "${trust_policy_file}" "${role_trust_file}" ||
    die "IAM role ${IAM_ROLE_NAME} has an unexpected trust policy."

  inline_policies="$(
    aws_text "IAM inline policies" \
      iam list-role-policies \
      --role-name "${IAM_ROLE_NAME}" \
      --query 'PolicyNames[]'
  )"
  if [[ -z "${inline_policies}" || "${inline_policies}" == "None" ]]; then
    inline_policy_exists=false
  elif [[ "${inline_policies}" == "${IAM_INLINE_POLICY_NAME}" ]]; then
    inline_policy_exists=true
    "${AWS[@]}" iam get-role-policy \
      --role-name "${IAM_ROLE_NAME}" \
      --policy-name "${IAM_INLINE_POLICY_NAME}" \
      --query 'PolicyDocument' \
      --output json >"${role_policy_file}" ||
      die "could not verify IAM inline policy ${IAM_INLINE_POLICY_NAME}."
    json_documents_match "${bedrock_policy_file}" "${role_policy_file}" ||
      die "IAM inline policy ${IAM_INLINE_POLICY_NAME} does not grant the exact regional foundation-model access."
  else
    die "IAM role ${IAM_ROLE_NAME} has an unexpected inline policy set."
  fi

  attached_policy_count="$(
    aws_text "attached IAM policies" \
      iam list-attached-role-policies \
      --role-name "${IAM_ROLE_NAME}" \
      --query 'length(AttachedPolicies)'
  )"
  [[ "${attached_policy_count}" == "0" ]] ||
    die "IAM role ${IAM_ROLE_NAME} has attached managed policies."

  instance_profile_count="$(
    aws_text "IAM instance profiles" \
      iam list-instance-profiles-for-role \
      --role-name "${IAM_ROLE_NAME}" \
      --query 'length(InstanceProfiles)'
  )"
  [[ "${instance_profile_count}" == "0" ]] ||
    die "IAM role ${IAM_ROLE_NAME} belongs to an instance profile."
elif grep -q 'NoSuchEntity' "${role_error_file}"; then
  role_exists=false
else
  cat "${role_error_file}" >&2
  die "could not determine whether IAM role ${IAM_ROLE_NAME} exists."
fi

association_exists=false
association_ids="$(
  aws_text "AgentGateway Pod Identity associations" \
    eks list-pod-identity-associations \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --namespace "${AGW_NAMESPACE}" \
    --service-account "${AGW_SERVICE_ACCOUNT}" \
    --query 'associations[].associationId'
)"
if [[ -n "${association_ids}" && "${association_ids}" != "None" ]]; then
  read -r -a association_id_list <<<"${association_ids//$'\t'/ }"
  (( ${#association_id_list[@]} == 1 )) ||
    die "more than one AgentGateway Pod Identity association exists."
  association_id="${association_id_list[0]}"
  [[ "${association_id}" =~ ^a-[a-z0-9]{17}$ ]] ||
    die "EKS returned an invalid Pod Identity association ID."
  association_record="$(
    aws_text "EKS Pod Identity association ${association_id}" \
      eks describe-pod-identity-association \
      --cluster-name "${EKS_CLUSTER_NAME}" \
      --association-id "${association_id}" \
      --query 'association.[clusterName,associationId,namespace,serviceAccount,roleArn,associationArn,tags.ManagedBy,ownerArn]'
  )"
  IFS=$'\t' read -r \
    association_cluster returned_association_id association_namespace \
    association_service_account association_role_arn association_arn \
    association_owner association_owner_arn association_extra \
    <<<"${association_record}"
  expected_association_arn="arn:${aws_partition}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:podidentityassociation/${EKS_CLUSTER_NAME}/${association_id}"
  [[ -z "${association_extra:-}" &&
    "${association_cluster}" == "${EKS_CLUSTER_NAME}" &&
    "${returned_association_id}" == "${association_id}" &&
    "${association_namespace}" == "${AGW_NAMESPACE}" &&
    "${association_service_account}" == "${AGW_SERVICE_ACCOUNT}" &&
    "${association_role_arn}" == "${expected_role_arn}" &&
    "${association_arn}" == "${expected_association_arn}" ]] ||
    die "Pod Identity association does not match the explicit cluster, namespace, service account, and role."
  [[ "${association_owner}" == "${OWNER_TAG_VALUE}" ]] ||
    die "Pod Identity association is not tagged ${OWNER_TAG_KEY}=${OWNER_TAG_VALUE}."
  [[ "${association_owner_arn}" == "None" ]] ||
    die "Pod Identity association is owned by an EKS add-on."
  [[ "${role_exists}" == true ]] ||
    die "Pod Identity association exists but its expected IAM role does not."
  association_exists=true
fi

if [[ "${role_exists}" == false ]]; then
  created_role=true
  created_role_arn="$(
    "${AWS[@]}" iam create-role \
      --role-name "${IAM_ROLE_NAME}" \
      --assume-role-policy-document "file://${trust_policy_file}" \
      --tags "Key=${OWNER_TAG_KEY},Value=${OWNER_TAG_VALUE}" \
      --query 'Role.Arn' \
      --output text
  )" || die "could not create IAM role ${IAM_ROLE_NAME}."
  [[ "${created_role_arn}" == "${expected_role_arn}" ]] ||
    die "created IAM role ARN does not match the explicit account and role name."
fi

if [[ "${inline_policy_exists}" == false ]]; then
  created_inline_policy=true
  "${AWS[@]}" iam put-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name "${IAM_INLINE_POLICY_NAME}" \
    --policy-document "file://${bedrock_policy_file}" ||
    die "could not create IAM inline policy ${IAM_INLINE_POLICY_NAME}."
fi

if [[ "${association_exists}" == false ]]; then
  association_creation_attempted=true
  association_id="$(
    "${AWS[@]}" eks create-pod-identity-association \
      --cluster-name "${EKS_CLUSTER_NAME}" \
      --namespace "${AGW_NAMESPACE}" \
      --service-account "${AGW_SERVICE_ACCOUNT}" \
      --role-arn "${expected_role_arn}" \
      --tags "${OWNER_TAG_KEY}=${OWNER_TAG_VALUE}" \
      --query 'association.associationId' \
      --output text
  )" || die "could not create the AgentGateway Pod Identity association."
  [[ "${association_id}" =~ ^a-[a-z0-9]{17}$ ]] ||
    die "EKS returned an invalid Pod Identity association ID after creation."
  created_association_id="${association_id}"
fi

echo "AgentGateway Pod Identity is ready."
echo "IAM role: ${IAM_ROLE_NAME}"
echo "IAM inline policy: ${IAM_INLINE_POLICY_NAME}"
echo "EKS association: ${association_id}"
echo "Bedrock model: ${BEDROCK_MODEL_ID} in ${AWS_REGION}"
