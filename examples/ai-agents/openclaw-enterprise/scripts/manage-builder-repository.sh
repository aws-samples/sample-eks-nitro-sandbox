#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly MANAGED_BY="openclaw-enterprise-sample"

usage() {
  cat >&2 <<'EOF'
Usage:
  manage-builder-repository.sh create --receipt FILE --region REGION
  manage-builder-repository.sh delete --receipt FILE

Create assigns a random run identity to a new private ECR repository and
records its exact ARN in a private receipt. Delete verifies the caller, Region,
repository ARN, and ownership tags before removing that repository.
EOF
}

die() {
  printf 'builder-repository: %s\n' "$*" >&2
  exit 1
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

valid_region() {
  [[ "$1" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]]
}

write_receipt() {
  local destination=$1 payload=$2 temporary
  temporary=$(mktemp "$(dirname -- "$destination")/.builder-repository.XXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' "$payload" >"$temporary"
  mv -f -- "$temporary" "$destination"
}

create_receipt() {
  local destination=$1 payload=$2 temporary
  temporary=$(mktemp "$(dirname -- "$destination")/.builder-repository.XXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' "$payload" >"$temporary"
  if ! ln "$temporary" "$destination"; then
    rm -f -- "$temporary"
    die "refusing to replace an existing receipt: $destination"
  fi
  rm -f -- "$temporary"
}

repository_does_not_exist() {
  grep -Fq "RepositoryNotFoundException" "$1"
}

for command in aws jq openssl stat mktemp ln; do
  command -v "$command" >/dev/null || die "$command is required."
done

(($# > 0)) || {
  usage
  exit 1
}
action=$1
shift

receipt="" region=""
while (($#)); do
  option=$1
  case "$option" in
    --receipt|--region)
      require_value "$option" "${2:-}"
      value=$2
      case "$option" in
        --receipt) receipt=$value ;;
        --region) region=$value ;;
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

if [[ "$action" == create ]]; then
  [[ ! -e "$receipt" && ! -L "$receipt" ]] ||
    die "refusing to replace an existing receipt: $receipt"
  [[ -n "$region" ]] || die "create requires --region."
  valid_region "$region" || die "--region is not valid."

  account_id=$(
    aws sts get-caller-identity --query Account --output text
  )
  [[ "$account_id" =~ ^[0-9]{12}$ ]] ||
    die "could not resolve the caller AWS account."
  run_id=$(openssl rand -hex 12)
  [[ "$run_id" =~ ^[a-f0-9]{24}$ ]] ||
    die "could not generate a valid run identifier."
  repository_name="openclaw-enterprise/codebuild-builder-$run_id"

  error_file=$(mktemp)
  trap 'rm -f -- "${error_file:-}"' EXIT
  if aws ecr describe-repositories \
    --region "$region" \
    --repository-names "$repository_name" >/dev/null 2>"$error_file"; then
    die "refusing to adopt existing repository $repository_name."
  fi
  repository_does_not_exist "$error_file" ||
    die "could not prove that repository $repository_name is unused."

  planned_receipt=$(
    jq -n \
      --arg accountId "$account_id" \
      --arg region "$region" \
      --arg runId "$run_id" \
      --arg repositoryName "$repository_name" \
      '{
        version: 1,
        operation: "builder-repository",
        status: "create-planned",
        accountId: $accountId,
        region: $region,
        runId: $runId,
        repositoryName: $repositoryName,
        repositoryArn: null
      }'
  )
  create_receipt "$receipt" "$planned_receipt"

  if ! aws ecr create-repository \
    --region "$region" \
    --repository-name "$repository_name" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --tags \
      "Key=ManagedBy,Value=$MANAGED_BY" \
      "Key=OpenClawValidationRun,Value=$run_id" >/dev/null; then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "repository creation did not complete; use this receipt to reconcile it."
  fi

  if ! repository_json=$(
    aws ecr describe-repositories \
      --region "$region" \
      --repository-names "$repository_name"
  ); then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "created repository identity could not be verified."
  fi
  repository_arn=$(
    printf '%s' "$repository_json" |
      jq -er '.repositories | if length == 1 then .[0].repositoryArn else error("count") end'
  ) || {
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "Amazon ECR did not return one repository ARN."
  }
  if ! printf '%s' "$repository_json" |
    jq -e \
      --arg accountId "$account_id" \
      --arg region "$region" \
      --arg repositoryName "$repository_name" '
        .repositories | length == 1
        and .[0].repositoryName == $repositoryName
        and .[0].registryId == $accountId
        and .[0].repositoryArn
          == ("arn:aws:ecr:" + $region + ":" + $accountId + ":repository/" + $repositoryName)
      ' >/dev/null; then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "created repository did not return the expected identity."
  fi
  if ! tag_json=$(
    aws ecr list-tags-for-resource \
      --region "$region" \
      --resource-arn "$repository_arn"
  ) || ! printf '%s' "$tag_json" |
    jq -e \
      --arg managedBy "$MANAGED_BY" \
      --arg runId "$run_id" '
        any(.tags[]?; .Key == "ManagedBy" and .Value == $managedBy)
        and any(.tags[]?; .Key == "OpenClawValidationRun" and .Value == $runId)
      ' >/dev/null; then
    failed_receipt=$(jq '.status = "create-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$failed_receipt"
    die "created repository did not return the expected ownership tags."
  fi

  completed_receipt=$(
    jq \
      --arg repositoryArn "$repository_arn" \
      '.status = "created" | .repositoryArn = $repositoryArn' \
      "$receipt"
  )
  write_receipt "$receipt" "$completed_receipt"
  printf 'Created run-owned builder repository. Receipt: %s\n' "$receipt"
elif [[ "$action" == delete ]]; then
  [[ -z "$region" ]] || die "delete accepts only --receipt."
  private_receipt "$receipt"
  receipt_json=$(jq -e '.' "$receipt") ||
    die "receipt is not valid JSON."
  printf '%s' "$receipt_json" |
    jq -e '
      keys | sort == [
        "accountId",
        "operation",
        "region",
        "repositoryArn",
        "repositoryName",
        "runId",
        "status",
        "version"
      ]
    ' >/dev/null ||
    die "receipt has an unexpected schema."
  printf '%s' "$receipt_json" |
    jq -e '
      .version == 1
      and .operation == "builder-repository"
      and (
        .status == "create-planned"
        or .status == "create-unconfirmed"
        or .status == "created"
        or .status == "delete-planned"
        or .status == "delete-unconfirmed"
        or .status == "deleted"
      )
      and (.accountId | test("^[0-9]{12}$"))
      and (.region | test("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$"))
      and (.runId | test("^[a-f0-9]{24}$"))
      and .repositoryName == ("openclaw-enterprise/codebuild-builder-" + .runId)
      and (
        .repositoryArn == null
        or (
          .repositoryArn |
          test("^arn:[^:]+:ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9._/-]+$")
        )
      )
    ' >/dev/null ||
    die "receipt identity evidence is invalid."

  account_id=$(printf '%s' "$receipt_json" | jq -r '.accountId')
  region=$(printf '%s' "$receipt_json" | jq -r '.region')
  run_id=$(printf '%s' "$receipt_json" | jq -r '.runId')
  repository_name=$(printf '%s' "$receipt_json" | jq -r '.repositoryName')
  repository_arn=$(printf '%s' "$receipt_json" | jq -r '.repositoryArn')
  receipt_status=$(printf '%s' "$receipt_json" | jq -r '.status')
  actual_account_id=$(
    aws sts get-caller-identity --query Account --output text
  )
  [[ "$actual_account_id" == "$account_id" ]] ||
    die "caller AWS account does not match the receipt."

  if [[ "$receipt_status" == deleted ]]; then
    printf 'Builder repository is already recorded as deleted. Receipt: %s\n' "$receipt"
    exit 0
  fi

  error_file=$(mktemp)
  trap 'rm -f -- "${error_file:-}"' EXIT
  if ! repository_json=$(
    aws ecr describe-repositories \
      --region "$region" \
      --repository-names "$repository_name" 2>"$error_file"
  ); then
    if repository_does_not_exist "$error_file"; then
      deleted_receipt=$(jq '.status = "deleted"' "$receipt")
      write_receipt "$receipt" "$deleted_receipt"
      printf 'Builder repository is absent and recorded as deleted. Receipt: %s\n' "$receipt"
      exit 0
    fi
    die "could not determine whether the recorded repository exists."
  fi

  actual_repository_arn=$(
    printf '%s' "$repository_json" |
      jq -er '.repositories | if length == 1 then .[0].repositoryArn else error("count") end'
  ) || die "Amazon ECR did not return one repository ARN."
  if [[ "$repository_arn" != null &&
    "$actual_repository_arn" != "$repository_arn" ]]; then
    die "refusing to delete a repository whose ARN differs from the receipt."
  fi
  printf '%s' "$repository_json" |
    jq -e \
      --arg accountId "$account_id" \
      --arg region "$region" \
      --arg repositoryName "$repository_name" \
      --arg repositoryArn "$actual_repository_arn" '
        .repositories | length == 1
        and .[0].repositoryName == $repositoryName
        and .[0].registryId == $accountId
        and .[0].repositoryArn == $repositoryArn
        and .[0].repositoryArn
          == ("arn:aws:ecr:" + $region + ":" + $accountId + ":repository/" + $repositoryName)
      ' >/dev/null ||
    die "refusing to delete a repository without exact identity evidence."
  tag_json=$(
    aws ecr list-tags-for-resource \
      --region "$region" \
      --resource-arn "$actual_repository_arn"
  ) || die "could not verify repository ownership tags."
  printf '%s' "$tag_json" |
    jq -e \
      --arg managedBy "$MANAGED_BY" \
      --arg runId "$run_id" '
        any(.tags[]?; .Key == "ManagedBy" and .Value == $managedBy)
        and any(.tags[]?; .Key == "OpenClawValidationRun" and .Value == $runId)
      ' >/dev/null ||
    die "refusing to delete a repository without exact ownership tags."

  delete_planned_receipt=$(
    jq \
      --arg repositoryArn "$actual_repository_arn" \
      '.status = "delete-planned" | .repositoryArn = $repositoryArn' \
      "$receipt"
  )
  write_receipt "$receipt" "$delete_planned_receipt"
  if ! aws ecr delete-repository \
    --region "$region" \
    --repository-name "$repository_name" \
    --force >/dev/null; then
    delete_unconfirmed_receipt=$(jq '.status = "delete-unconfirmed"' "$receipt")
    write_receipt "$receipt" "$delete_unconfirmed_receipt"
    die "repository deletion could not be confirmed; rerun delete with this receipt."
  fi
  deleted_receipt=$(jq '.status = "deleted"' "$receipt")
  write_receipt "$receipt" "$deleted_receipt"
  printf 'Deleted run-owned builder repository. Receipt: %s\n' "$receipt"
else
  usage
  die "action must be create or delete."
fi
