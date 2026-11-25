#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly MANAGED_BY="openclaw-enterprise-sample"
readonly OCE_SOURCE_PIN="86c8c12310f691bb21651118ffffd6bfd460e9ff" # pragma: allowlist secret -- public source revision
readonly INSPECTOR_SCAN_POLL_SECONDS=5
readonly INSPECTOR_SCAN_STABLE_OBSERVATIONS=13
error_file=""
scan_dir=""
operation_lock=""
lock_owned=false
lock_release_safe=true

usage() {
  cat >&2 <<'EOF'
Usage:
  manage-image-build-stack.sh create --receipt FILE --region REGION \
    --sample-revision SHA --builder-repository NAME --builder-digest SHA \
    --trusted-build-invoker-arn ARN \
    [--target-platform linux/amd64|linux/arm64]

  manage-image-build-stack.sh delete --receipt FILE

Create assigns a random run identity to a new CloudFormation stack and records
the exact stack ARN in a private receipt. Delete verifies the caller, Region,
stack ARN, and ownership tags before removing that stack. Both run only as the
principal in OPENCLAW_EXPECTED_CALLER_ARN.
EOF
}

die() {
  cleanup
  printf 'image-build-stack: %s\n' "$*" >&2
  exit 1
}

# OPENCLAW_EXPECTED_CALLER_ARN names the one AWS principal that may change this sample's AWS resources: an
# IAM user ARN, or an assumed-role ARN without its session name. Compare the caller with it before any change.
require_expected_caller() {
  local expected="${OPENCLAW_EXPECTED_CALLER_ARN:-}" identity
  [[ "$expected" =~ ^arn:aws[a-z-]*:(iam::[0-9]{12}:user/[A-Za-z0-9+=,.@_/-]+|sts::[0-9]{12}:assumed-role/[A-Za-z0-9+=,.@_-]+)$ ]] ||
    die "OPENCLAW_EXPECTED_CALLER_ARN must be an IAM user ARN or an assumed-role ARN without its session name."
  identity=$(aws sts get-caller-identity --output json) ||
    die "could not read the AWS caller identity."
  jq -e --arg expected "$expected" '
    (.Arn | type == "string")
    and (
      .Arn == $expected
      or (
        ($expected | contains(":assumed-role/"))
        and (.Arn | startswith($expected + "/"))
        and (.Arn | ltrimstr($expected + "/") | test("^[A-Za-z0-9+=,.@_-]{2,64}$"))
      )
    )
  ' <<<"$identity" >/dev/null ||
    die "the AWS caller is not OPENCLAW_EXPECTED_CALLER_ARN $expected."
}

require_value() {
  [[ -n "${2:-}" && "$2" != --* ]] ||
    die "$1 requires an explicit value."
}

file_mode() {
  local mode
  if mode=$(stat -c '%a' "$1" 2>/dev/null) &&
    [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$mode"
  elif mode=$(stat -f '%Lp' "$1" 2>/dev/null) &&
    [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s\n' "$mode"
  else
    die "could not inspect permissions for $1."
  fi
}

private_parent() {
  local parent=$1
  [[ -d "$parent" && ! -L "$parent" && -O "$parent" ]] ||
    die "receipt parent must be an owned directory, not a symbolic link."
  [[ "$(file_mode "$parent")" == 700 ]] ||
    die "receipt parent must have mode 0700."
}

private_receipt() {
  local path=$1
  [[ -f "$path" && ! -L "$path" && -O "$path" && -r "$path" ]] ||
    die "receipt must be an owned readable regular file, not a symbolic link."
  [[ "$(file_mode "$path")" == 600 ]] ||
    die "receipt must have mode 0600."
}

cleanup() {
  [[ -z "$error_file" ]] || rm -f -- "$error_file"
  error_file=""
  if [[ -n "$scan_dir" && -d "$scan_dir" ]]; then
    rm -f -- \
      "$scan_dir/account-status.json" \
      "$scan_dir/coverage-filter.json" \
      "$scan_dir/coverage.json" \
      "$scan_dir/findings-filter.json" \
      "$scan_dir/findings.json" \
      "$scan_dir/registry-scanning.json"
    rmdir -- "$scan_dir" 2>/dev/null || true
  fi
  scan_dir=""
  if [[ "$lock_owned" == true && "$lock_release_safe" == true &&
    -n "$operation_lock" ]]; then
    rm -f -- "$operation_lock/pid"
    rmdir -- "$operation_lock" 2>/dev/null || true
    lock_owned=false
  fi
}

acquire_operation_lock() {
  local owner_file
  if ! mkdir -- "$operation_lock" 2>/dev/null; then
    die "another operation is using this receipt, or a stale lock must be reviewed: $operation_lock"
  fi
  lock_owned=true
  owner_file="$operation_lock/pid"
  printf '%s\n' "$$" >"$owner_file" ||
    die "could not record operation lock ownership."
}

valid_region() {
  [[ "$1" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]]
}

valid_revision() {
  [[ "$1" =~ ^[a-f0-9]{40}$ ]]
}

valid_digest() {
  [[ "$1" =~ ^sha256:[a-f0-9]{64}$ ]]
}

write_receipt() {
  local destination=$1 payload=$2 temporary
  temporary=$(mktemp "$(dirname -- "$destination")/.image-build-stack.XXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' "$payload" >"$temporary"
  mv -f -- "$temporary" "$destination"
}

create_receipt() {
  local destination=$1 payload=$2 temporary
  temporary=$(mktemp "$(dirname -- "$destination")/.image-build-stack.XXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' "$payload" >"$temporary"
  if ! ln "$temporary" "$destination"; then
    rm -f -- "$temporary"
    die "refusing to replace an existing receipt: $destination"
  fi
  rm -f -- "$temporary"
}

stack_does_not_exist() {
  grep -Fq "does not exist" "$1"
}

verify_builder_scan() {
  local account_id=$1 region=$2 repository=$3 digest=$4 partition=$5
  local checker_dir=$6 resource_id scan_result _
  resource_id="arn:${partition}:ecr:${region}:${account_id}:repository/${repository}/${digest}"
  scan_dir=$(mktemp -d)

  aws inspector2 batch-get-account-status \
    --region "$region" \
    --account-ids "$account_id" \
    --output json >"$scan_dir/account-status.json" ||
    die "could not verify Amazon Inspector account status for the builder image."
  aws ecr get-registry-scanning-configuration \
    --region "$region" \
    --output json >"$scan_dir/registry-scanning.json" ||
    die "could not verify ECR enhanced scanning for the builder image."
  python3 -I "$checker_dir/check-enhanced-scanning.py" \
    "$scan_dir/account-status.json" \
    "$scan_dir/registry-scanning.json" \
    "$account_id" \
    "$repository" ||
    die "the privileged builder repository is not covered by enhanced scanning."

  jq -n \
    --arg account "$account_id" \
    --arg repository "$repository" \
    --arg resource "$resource_id" '{
      accountId: [{comparison: "EQUALS", value: $account}],
      resourceId: [{comparison: "EQUALS", value: $resource}],
      resourceType: [{comparison: "EQUALS", value: "AWS_ECR_CONTAINER_IMAGE"}],
      scanType: [{comparison: "EQUALS", value: "PACKAGE"}],
      ecrRepositoryName: [{comparison: "EQUALS", value: $repository}]
    }' >"$scan_dir/coverage-filter.json"
  jq -n \
    --arg account "$account_id" \
    --arg repository "$repository" \
    --arg digest "$digest" \
    --arg resource "$resource_id" '{
      awsAccountId: [{comparison: "EQUALS", value: $account}],
      resourceType: [{comparison: "EQUALS", value: "AWS_ECR_CONTAINER_IMAGE"}],
      resourceId: [{comparison: "EQUALS", value: $resource}],
      ecrImageRegistry: [{comparison: "EQUALS", value: $account}],
      ecrImageRepositoryName: [{comparison: "EQUALS", value: $repository}],
      ecrImageHash: [{comparison: "EQUALS", value: $digest}],
      findingStatus: [{comparison: "EQUALS", value: "ACTIVE"}],
      severity: [
        {comparison: "EQUALS", value: "CRITICAL"},
        {comparison: "EQUALS", value: "HIGH"}
      ]
    }' >"$scan_dir/findings-filter.json"

  # The same gate as build/build-images.sh: Inspector can mark coverage successful before all findings are
  # queryable, so accept only INSPECTOR_SCAN_STABLE_OBSERVATIONS consecutive clean reads at five-second
  # intervals (a full minute from first to last), start over when the scan is pending, and stop at the first
  # finding. 120 reads leave room for that run after a long pending scan.
  local clean_observations=0
  for _ in {1..120}; do
    aws inspector2 list-coverage \
      --region "$region" \
      --filter-criteria "file://$scan_dir/coverage-filter.json" \
      --max-results 2 \
      --no-paginate \
      --output json >"$scan_dir/coverage.json" ||
      die "Inspector coverage lookup failed for the privileged builder image."
    aws inspector2 list-findings \
      --region "$region" \
      --filter-criteria "file://$scan_dir/findings-filter.json" \
      --output json >"$scan_dir/findings.json" ||
      die "Inspector findings lookup failed for the privileged builder image."
    if python3 -I "$checker_dir/check-inspector-scan.py" \
      "$scan_dir/coverage.json" \
      "$scan_dir/findings.json" \
      "$resource_id" \
      "$account_id" \
      "$repository" \
      "$digest"; then
      ((clean_observations += 1))
      if ((clean_observations >= INSPECTOR_SCAN_STABLE_OBSERVATIONS)); then
        return 0
      fi
    else
      scan_result=$?
      [[ "$scan_result" -eq 10 ]] ||
        die "Inspector rejected the privileged builder image."
      clean_observations=0
    fi
    sleep "$INSPECTOR_SCAN_POLL_SECONDS"
  done
  die "Inspector did not complete the privileged builder image scan."
}

for command in aws jq openssl python3 sleep stat mktemp ln mkdir rmdir; do
  command -v "$command" >/dev/null || die "$command is required."
done

(($# > 0)) || {
  usage
  exit 1
}
action=$1
shift

receipt="" region="" sample_revision="" builder_repository=""
builder_digest="" trusted_invoker_arn="" target_platform=""
while (($#)); do
  option=$1
  case "$option" in
    --receipt|--region|--sample-revision|--builder-repository|\
    --builder-digest|--trusted-build-invoker-arn|--target-platform)
      require_value "$option" "${2:-}"
      value=$2
      case "$option" in
        --receipt) receipt=$value ;;
        --region) region=$value ;;
        --sample-revision) sample_revision=$value ;;
        --builder-repository) builder_repository=$value ;;
        --builder-digest) builder_digest=$value ;;
        --trusted-build-invoker-arn) trusted_invoker_arn=$value ;;
        --target-platform) target_platform=$value ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $option"
      ;;
  esac
done

[[ -n "$receipt" && "$receipt" = /* ]] ||
  die "--receipt must be an absolute path."
receipt_parent=$(dirname -- "$receipt")
private_parent "$receipt_parent"
operation_lock="${receipt}.lock"
acquire_operation_lock
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
require_expected_caller

if [[ "$action" == create ]]; then
  [[ ! -e "$receipt" && ! -L "$receipt" ]] ||
    die "refusing to replace an existing receipt: $receipt"
  target_platform=${target_platform:-linux/amd64}
  [[ -n "$region" && -n "$sample_revision" &&
    -n "$builder_repository" && -n "$builder_digest" &&
    -n "$trusted_invoker_arn" ]] ||
    die "create requires every documented argument."
  valid_region "$region" || die "--region is not valid."
  valid_revision "$sample_revision" ||
    die "--sample-revision must be a full lowercase Git SHA."
  valid_digest "$builder_digest" ||
    die "--builder-digest must be an exact lowercase sha256 digest."
  [[ "$builder_repository" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
    die "--builder-repository is not a valid ECR repository name."
  [[ "$trusted_invoker_arn" =~ ^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:(role|user)/[A-Za-z0-9+=,.@_/-]+$ ]] ||
    die "--trusted-build-invoker-arn is not a valid IAM principal ARN."
  [[ "$target_platform" =~ ^linux/(amd64|arm64)$ ]] ||
    die "--target-platform must be linux/amd64 or linux/arm64."

  account_id=$(
    aws sts get-caller-identity --query Account --output text
  )
  [[ "$account_id" =~ ^[0-9]{12}$ ]] ||
    die "could not resolve the caller AWS account."
  arn_account=${trusted_invoker_arn#*::}
  arn_account=${arn_account%%:*}
  [[ "$arn_account" == "$account_id" ]] ||
    die "trusted build invoker must belong to the caller AWS account."
  partition=${trusted_invoker_arn#arn:}
  partition=${partition%%:*}
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  verify_builder_scan \
    "$account_id" \
    "$region" \
    "$builder_repository" \
    "$builder_digest" \
    "$partition" \
    "$script_dir/../build"

  run_id=$(openssl rand -hex 12)
  [[ "$run_id" =~ ^[a-f0-9]{24}$ ]] ||
    die "could not generate a valid run identifier."
  stack_name="openclaw-enterprise-images-$run_id"
  repository_prefix="openclaw-enterprise/$run_id"
  error_file=$(mktemp)
  if aws cloudformation describe-stacks \
    --region "$region" \
    --stack-name "$stack_name" >/dev/null 2>"$error_file"; then
    die "refusing to adopt existing stack $stack_name."
  fi
  grep -Fq "does not exist" "$error_file" ||
    die "could not prove that stack $stack_name is unused."

  planned_receipt=$(
    jq -n \
      --arg accountId "$account_id" \
      --arg region "$region" \
      --arg runId "$run_id" \
      --arg stackName "$stack_name" \
      --arg repositoryPrefix "$repository_prefix" \
      --arg sampleRevision "$sample_revision" \
      --arg oceRevision "$OCE_SOURCE_PIN" \
      --arg targetPlatform "$target_platform" \
      '{
        version: 2,
        operation: "image-build-stack",
        status: "create-planned",
        accountId: $accountId,
        region: $region,
        runId: $runId,
        stackName: $stackName,
        stackId: null,
        repositoryPrefix: $repositoryPrefix,
        sampleRevision: $sampleRevision,
        oceRevision: $oceRevision,
        targetPlatform: $targetPlatform
      }'
  )
  create_receipt "$receipt" "$planned_receipt"

  template_file="$script_dir/../build/template.yaml"
  lock_release_safe=false
  if ! aws cloudformation deploy \
    --region "$region" \
    --stack-name "$stack_name" \
    --template-file "$template_file" \
    --capabilities CAPABILITY_IAM \
    --tags \
      "ManagedBy=$MANAGED_BY" \
      "OpenClawValidationRun=$run_id" \
    --parameter-overrides \
      "ValidationRunId=$run_id" \
      "RepositoryPrefix=$repository_prefix" \
      "SampleGitRevision=$sample_revision" \
      "OceGitRevision=$OCE_SOURCE_PIN" \
      "TargetPlatform=$target_platform" \
      "BuilderImageRepositoryName=$builder_repository" \
      "BuilderImageDigest=$builder_digest" \
      "TrustedBuildInvokerArn=$trusted_invoker_arn"; then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "stack creation did not complete; inspect the recorded stack name before taking action."
  fi

  if ! stack_json=$(
    aws cloudformation describe-stacks \
      --region "$region" \
      --stack-name "$stack_name"
  ); then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "stack creation completed but its identity could not be verified."
  fi
  if ! stack_id=$(printf '%s' "$stack_json" | jq -er '.Stacks[0].StackId'); then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "CloudFormation did not return the created stack ARN."
  fi
  [[ "$stack_id" =~ ^arn:[^:]+:cloudformation:[a-z0-9-]+:[0-9]{12}:stack/[^/]+/[A-Za-z0-9-]+$ ]] ||
    {
      failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
      write_receipt "$receipt" "$failed_receipt"
      die "CloudFormation returned an invalid stack ARN."
    }
  if ! printf '%s' "$stack_json" |
    jq -e \
      --arg accountId "$account_id" \
      --arg region "$region" \
      --arg runId "$run_id" \
      --arg stackName "$stack_name" \
      --arg targetPlatform "$target_platform" \
      --arg managedBy "$MANAGED_BY" '
        .Stacks | length == 1
        and .[0].StackName == $stackName
        and (.[0].StackId | contains(":" + $region + ":" + $accountId + ":stack/"))
        and any(.[0].Tags[]?; .Key == "ManagedBy" and .Value == $managedBy)
        and any(.[0].Tags[]?; .Key == "OpenClawValidationRun" and .Value == $runId)
        and (
          [.[0].Parameters[]? | select(.ParameterKey == "ValidationRunId")]
          == [{"ParameterKey": "ValidationRunId", "ParameterValue": $runId}]
        )
        and (
          [.[0].Parameters[]? | select(.ParameterKey == "TargetPlatform")]
          == [{"ParameterKey": "TargetPlatform", "ParameterValue": $targetPlatform}]
        )
        and (
          [.[0].Outputs[]? | select(.OutputKey == "ValidationRunId")]
          == [{"OutputKey": "ValidationRunId", "OutputValue": $runId}]
        )
      ' >/dev/null; then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "created stack did not return the expected identity and ownership evidence."
  fi

  completed_receipt=$(
    jq \
      --arg stackId "$stack_id" \
      '.status = "created" | .stackId = $stackId' \
      "$receipt"
  )
  write_receipt "$receipt" "$completed_receipt"
  lock_release_safe=true
  cleanup
  printf 'Created run-owned image build stack. Receipt: %s\n' "$receipt"
elif [[ "$action" == delete ]]; then
  [[ -z "$region$sample_revision$builder_repository$builder_digest$trusted_invoker_arn$target_platform" ]] ||
    die "delete accepts only --receipt."
  private_receipt "$receipt"
  receipt_json=$(jq -e '.' "$receipt") ||
    die "receipt is not valid JSON."
  printf '%s' "$receipt_json" |
    jq -e '
      (
        .version == 1
        and (
          keys | sort == [
            "accountId",
            "oceRevision",
            "operation",
            "region",
            "repositoryPrefix",
            "runId",
            "sampleRevision",
            "stackId",
            "stackName",
            "status",
            "version"
          ]
        )
      )
      or (
        .version == 2
        and (
          keys | sort == [
            "accountId",
            "oceRevision",
            "operation",
            "region",
            "repositoryPrefix",
            "runId",
            "sampleRevision",
            "stackId",
            "stackName",
            "status",
            "targetPlatform",
            "version"
          ]
        )
      )
    ' >/dev/null ||
    die "receipt has an unexpected schema."
  printf '%s' "$receipt_json" |
    jq -e \
      --arg oceRevision "$OCE_SOURCE_PIN" '
        (.version == 1 or .version == 2)
        and .operation == "image-build-stack"
        and (
          .status == "create-planned"
          or .status == "create-unconfirmed"
          or .status == "created"
          or .status == "delete-planned"
          or .status == "delete-unconfirmed"
          or .status == "deleted"
        )
        and .oceRevision == $oceRevision
        and (.accountId | test("^[0-9]{12}$"))
        and (.region | test("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$"))
        and (.runId | test("^[a-f0-9]{24}$"))
        and .stackName == ("openclaw-enterprise-images-" + .runId)
        and .repositoryPrefix == ("openclaw-enterprise/" + .runId)
        and (.sampleRevision | test("^[a-f0-9]{40}$"))
        and (
          (.version == 1 and (.targetPlatform == null))
          or (
            .version == 2
            and (.targetPlatform == "linux/amd64" or .targetPlatform == "linux/arm64")
          )
        )
        and (
          (
            (.status == "create-planned" or .status == "create-unconfirmed")
            and (
              .stackId == null
              or (
                .stackId |
                test("^arn:[^:]+:cloudformation:[a-z0-9-]+:[0-9]{12}:stack/[^/]+/[A-Za-z0-9-]+$")
              )
            )
          )
          or (
            (
              .status == "created"
              or .status == "delete-planned"
              or .status == "delete-unconfirmed"
              or .status == "deleted"
            )
            and (
              .stackId |
              test("^arn:[^:]+:cloudformation:[a-z0-9-]+:[0-9]{12}:stack/[^/]+/[A-Za-z0-9-]+$")
            )
          )
        )
      ' >/dev/null ||
    die "receipt identity evidence is invalid."

  account_id=$(printf '%s' "$receipt_json" | jq -r '.accountId')
  region=$(printf '%s' "$receipt_json" | jq -r '.region')
  run_id=$(printf '%s' "$receipt_json" | jq -r '.runId')
  stack_name=$(printf '%s' "$receipt_json" | jq -r '.stackName')
  stack_id=$(printf '%s' "$receipt_json" | jq -r '.stackId')
  receipt_status=$(printf '%s' "$receipt_json" | jq -r '.status')
  receipt_version=$(printf '%s' "$receipt_json" | jq -r '.version')
  receipt_target_platform=$(printf '%s' "$receipt_json" | jq -r '.targetPlatform // empty')
  actual_account_id=$(
    aws sts get-caller-identity --query Account --output text
  )
  [[ "$actual_account_id" == "$account_id" ]] ||
    die "caller AWS account does not match the receipt."

  if [[ "$receipt_status" == deleted ]]; then
    cleanup
    printf 'Image build stack is already recorded as deleted. Receipt: %s\n' "$receipt"
    exit 0
  fi

  stack_reference=$stack_name
  [[ "$stack_id" == null ]] || stack_reference=$stack_id
  error_file=$(mktemp)
  if ! stack_json=$(
    aws cloudformation describe-stacks \
      --region "$region" \
      --stack-name "$stack_reference" 2>"$error_file"
  ); then
    if stack_does_not_exist "$error_file"; then
      deleted_receipt=$(jq '.status = "deleted"' "$receipt")
      write_receipt "$receipt" "$deleted_receipt"
      cleanup
      printf 'Image build stack is absent and is now recorded as deleted. Receipt: %s\n' "$receipt"
      exit 0
    fi
    die "could not determine whether the recorded stack exists."
  fi

  actual_stack_id=$(printf '%s' "$stack_json" | jq -er '.Stacks[0].StackId') ||
    die "CloudFormation did not return the recorded stack ARN."
  [[ "$actual_stack_id" =~ ^arn:[^:]+:cloudformation:[a-z0-9-]+:[0-9]{12}:stack/[^/]+/[A-Za-z0-9-]+$ ]] ||
    die "CloudFormation returned an invalid stack ARN."
  if [[ "$stack_id" != null && "$actual_stack_id" != "$stack_id" ]]; then
    die "refusing to delete a stack whose ARN differs from the receipt."
  fi
  if ! printf '%s' "$stack_json" |
    jq -e \
      --arg stackId "$actual_stack_id" \
      --arg stackName "$stack_name" \
      --arg accountId "$account_id" \
      --arg region "$region" \
      --arg runId "$run_id" \
      --argjson receiptVersion "$receipt_version" \
      --arg targetPlatform "$receipt_target_platform" \
      --arg managedBy "$MANAGED_BY" '
        .Stacks | length == 1
        and .[0].StackId == $stackId
        and .[0].StackName == $stackName
        and (.[0].StackId | contains(":" + $region + ":" + $accountId + ":stack/"))
        and any(.[0].Tags[]?; .Key == "ManagedBy" and .Value == $managedBy)
        and any(.[0].Tags[]?; .Key == "OpenClawValidationRun" and .Value == $runId)
        and (
          [.[0].Parameters[]? | select(.ParameterKey == "ValidationRunId")]
          == [{"ParameterKey": "ValidationRunId", "ParameterValue": $runId}]
        )
        and (
          $receiptVersion == 1
          or (
            [.[0].Parameters[]? | select(.ParameterKey == "TargetPlatform")]
            == [{"ParameterKey": "TargetPlatform", "ParameterValue": $targetPlatform}]
          )
        )
        and (
          [.[0].Outputs[]? | select(.OutputKey == "ValidationRunId")] as $outputs
          | ($outputs | length) == 0
            or $outputs
              == [{"OutputKey": "ValidationRunId", "OutputValue": $runId}]
        )
      ' >/dev/null; then
    die "refusing to delete a stack without exact ownership evidence."
  fi

  delete_planned_receipt=$(
    jq \
      --arg stackId "$actual_stack_id" \
      '.status = "delete-planned" | .stackId = $stackId' \
      "$receipt"
  )
  write_receipt "$receipt" "$delete_planned_receipt"
  lock_release_safe=false
  if ! aws cloudformation delete-stack \
    --region "$region" \
    --stack-name "$actual_stack_id"; then
    delete_unconfirmed_receipt=$(jq '.status = "delete-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$delete_unconfirmed_receipt"
    die "stack deletion could not be confirmed; rerun delete with this receipt."
  fi
  if ! aws cloudformation wait stack-delete-complete \
    --region "$region" \
    --stack-name "$actual_stack_id"; then
    delete_unconfirmed_receipt=$(jq '.status = "delete-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$delete_unconfirmed_receipt"
    die "stack deletion could not be confirmed; rerun delete with this receipt."
  fi
  deleted_receipt=$(jq '.status = "deleted"' "$receipt")
  write_receipt "$receipt" "$deleted_receipt"
  lock_release_safe=true
  cleanup
  printf 'Deleted run-owned image build stack. Receipt: %s\n' "$receipt"
else
  usage
  die "action must be create or delete."
fi
