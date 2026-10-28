#!/usr/bin/env bash
# bootstrap-runner.sh -- the project, the runner authentication token, and the runner
# manager.
#
# Usage:
#   ./scripts/bootstrap-runner.sh
#
# What it does, in order:
#   1. checks the context and that the namespace is this sample's;
#   2. creates the project on the in-cluster GitLab, if absent, and commits the pipeline
#      files to it with [ci skip] so no pipeline starts before there is a runner to take it;
#   3. mints a project runner authentication token from that GitLab, unless the runner
#      Secret is already there;
#   4. renders runner/config.toml.template with the token and stores it in a Secret;
#   5. applies the runner manager and waits until GitLab has heard from it.
#
# The token is never an argument to any command. It leaves GitLab on standard output, goes
# into a file in a private temp directory, and reaches the Secret through
# `kubectl create secret --from-file`. Everything these scripts ask GitLab to do, they send
# on standard input, so nothing they send reaches a command line either.
set -euo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

RUNNER_DESCRIPTION="nitro-sandbox-runner"

# ---------------------------------------------------------------------------
say "1/5 context and namespace"
# ---------------------------------------------------------------------------
need_tools kubectl base64 awk
check_cluster
require_namespace
echo "  context '$KUBE_CONTEXT', namespace '$NAMESPACE' is this sample's."

# ---------------------------------------------------------------------------
say "2/5 the project and the pipeline files"
# ---------------------------------------------------------------------------
# Every value and every file this sample sends to GitLab is base64-encoded into the Ruby
# that carries it. `kubectl exec` has no way to set an environment variable in the container,
# and the alternative, prefixing the command with `env NAME=value`, would put each value on
# a command line. Encoding also means no file's content has to survive shell quoting.
b64() { base64 -w0 < "$1" 2>/dev/null || base64 < "$1" | tr -d '\n'; }
b64s() { printf '%s' "$1" | { base64 -w0 2>/dev/null || base64 | tr -d '\n'; }; }

PIPELINE_FILES=(
  ".gitlab-ci.yml:$SAMPLE_DIR/pipeline/.gitlab-ci.yml"
  "ci/Dockerfile:$SAMPLE_DIR/pipeline/ci/Dockerfile"
  "ci/go.mod:$SAMPLE_DIR/pipeline/ci/go.mod"
  "ci/main.go:$SAMPLE_DIR/pipeline/ci/main.go"
)

work="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-ci-boot.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM
chmod 700 "$work"

project_ruby="$work/project.rb"
{
  printf "require 'base64'\n"
  printf "PROJECT_PATH = Base64.decode64('%s')\n" "$(b64s "$PROJECT_PATH")"
  printf 'FILES = {\n'
  for entry in "${PIPELINE_FILES[@]}"; do
    repo_path="${entry%%:*}"
    local_path="${entry#*:}"
    [[ -r "$local_path" ]] || die "cannot read $local_path."
    printf "  Base64.decode64('%s') => Base64.decode64('%s'),\n" \
      "$(b64s "$repo_path")" "$(b64 "$local_path")"
  done
  printf '}\n'
  cat <<'RUBY'

user = User.find_by_username('root')
raise 'no root user on this GitLab' if user.nil?

full = "#{user.username}/#{PROJECT_PATH}"
project = Project.find_by_full_path(full)

if project.nil?
  project = Projects::CreateService.new(
    user,
    name: PROJECT_PATH,
    path: PROJECT_PATH,
    namespace_id: user.namespace.id,
    visibility_level: Gitlab::VisibilityLevel::PRIVATE,
    initialize_with_readme: true
  ).execute
  unless project.persisted?
    raise "could not create project #{full}: #{project.errors.full_messages.join(', ')}"
  end
end

branch = project.default_branch || 'main'

actions = FILES.map do |repo_path, content|
  existing = begin
    project.repository.blob_at(branch, repo_path)&.data
  rescue StandardError
    nil
  end
  next nil if existing == content
  { action: existing.nil? ? :create : :update, file_path: repo_path, content: content }
end.compact

if actions.empty?
  commit = 'unchanged'
else
  # [ci skip] keeps this commit from starting a pipeline of its own. The pipeline is started
  # by run-pipeline.sh, once the runner is online, so the run the page shows is one a reader
  # can start themselves and watch from the beginning.
  result = Files::MultiService.new(
    project,
    user,
    commit_message: 'Add the Nitro sandbox CI pipeline [ci skip]',
    branch_name: branch,
    start_branch: branch,
    actions: actions
  ).execute
  raise "could not commit the pipeline files: #{result[:message]}" unless result[:status] == :success
  commit = project.repository.commit(branch).id
end

puts "PROJECT_ID=#{project.id}"
puts "PROJECT_FULL=#{project.full_path}"
puts "BRANCH=#{branch}"
puts "COMMIT=#{commit}"
puts "FILES_WRITTEN=#{actions.map { |a| a[:file_path] }.join(',')}"
RUBY
} > "$project_ruby"

echo "  asking GitLab to create the project and commit the pipeline. Its Rails console"
echo "  takes about half a minute to start, and this waits for it."
project_out="$("${KCTL[@]}" exec -i -n "$NAMESPACE" "$(gitlab_pod)" \
  -- gitlab-rails runner - < "$project_ruby")" \
  || die "GitLab could not create the project or commit the pipeline files. Its output is above."

PROJECT_ID="$(sed -n 's/^PROJECT_ID=//p' <<<"$project_out")"
PROJECT_FULL="$(sed -n 's/^PROJECT_FULL=//p' <<<"$project_out")"
BRANCH="$(sed -n 's/^BRANCH=//p' <<<"$project_out")"
COMMIT="$(sed -n 's/^COMMIT=//p' <<<"$project_out")"
FILES_WRITTEN="$(sed -n 's/^FILES_WRITTEN=//p' <<<"$project_out")"
[[ -n "$PROJECT_ID" && -n "$BRANCH" ]] \
  || die "GitLab did not report a project id and a branch. Its output was:
$project_out"
echo "  project $PROJECT_FULL (id $PROJECT_ID), branch $BRANCH"
if [[ "$COMMIT" == unchanged ]]; then
  echo "  the pipeline files were already committed, unchanged."
else
  echo "  committed $FILES_WRITTEN at ${COMMIT:0:8}, with [ci skip] so no pipeline starts yet."
fi

# ---------------------------------------------------------------------------
say "3/5 the runner authentication token"
# ---------------------------------------------------------------------------
# A runner authentication token cannot be read back out of GitLab after it is created, so
# the Secret holding it is what decides whether to mint one: if the Secret is there, this
# sample already has a runner and its token, and nothing is minted.
secret_present="$("${KCTL[@]}" get secret "$RUNNER_SECRET" -n "$NAMESPACE" -o name --ignore-not-found 2>/dev/null)" \
  || die "could not read Secret '$RUNNER_SECRET' in '$NAMESPACE'. That is a failed read, not a report that it is absent."

if [[ -n "$secret_present" ]]; then
  echo "  Secret '$RUNNER_SECRET' is already there, so this sample already has a runner and"
  echo "  its token. Nothing minted. To start over, run scripts/clean.sh first."
else
  cat > "$work/runner.rb" <<RUBY_HEAD
require 'base64'
PROJECT_ID = $PROJECT_ID
RUNNER_DESCRIPTION = Base64.decode64('$(b64s "$RUNNER_DESCRIPTION")')
RUBY_HEAD
  cat >> "$work/runner.rb" <<'RUBY'

user = User.find_by_username('root')
raise 'no root user on this GitLab' if user.nil?

project = Project.find(PROJECT_ID)

# A runner of this sample's own description, on this sample's own project, in the GitLab this
# sample installed. Removing one left over from an earlier run keeps this GitLab's runner
# list honest: its token is in no Secret any more, so it can never come back online.
project.runners.where(description: RUNNER_DESCRIPTION).each(&:destroy!)

result = ::Ci::Runners::CreateRunnerService.new(
  user: user,
  type: :project_type,
  scope: project,
  params: {
    description: RUNNER_DESCRIPTION,
    # The pipeline's jobs carry no tags, so the runner has to accept untagged jobs.
    run_untagged: true,
    tag_list: ['nitro-sandbox']
  }
).execute

raise "could not create the runner: #{result.message}" unless result.success?

created = result.payload[:runner]
# Marked, so the value is lifted out of whatever else the Rails console prints, and so
# nothing else in this output can be mistaken for it.
puts "RUNNER_ID=#{created.id}"
puts "RUNNER_TOKEN=#{created.token}"
RUBY

  echo "  asking GitLab for a project runner authentication token."
  runner_out="$("${KCTL[@]}" exec -i -n "$NAMESPACE" "$(gitlab_pod)" \
    -- gitlab-rails runner - < "$work/runner.rb")" \
    || die "GitLab could not create the runner. Its output is above."

  RUNNER_ID="$(sed -n 's/^RUNNER_ID=//p' <<<"$runner_out")"
  ( umask 077; sed -n 's/^RUNNER_TOKEN=//p' <<<"$runner_out" | tr -d '\r\n' > "$work/token" )
  [[ -s "$work/token" ]] \
    || die "GitLab reported no runner authentication token. Its output was:
$(sed 's/^RUNNER_TOKEN=.*/RUNNER_TOKEN=<not shown>/' <<<"$runner_out")"
  # The prefix is all this prints. glrt- is what a runner created in GitLab 16.0 or later
  # gets; the deprecated registration tokens it replaced had no prefix.
  prefix="$(cut -c1-5 < "$work/token")"
  [[ "$prefix" == "glrt-" ]] \
    || die "the token GitLab returned does not start with glrt-, so it is not a runner authentication token. Its first five characters were '$prefix'."
  echo "  runner id $RUNNER_ID, token prefix '$prefix' (the value is not printed)."

  # ---------------------------------------------------------------------------
  say "4/5 the Secret holding config.toml"
  # ---------------------------------------------------------------------------
  # The token is substituted by awk reading the token FILE, not by `sed -e "s|...|$token|"`:
  # sed's replacement text would be an argument, which is the one place the token must never
  # be. The rendered file then reaches the Secret with --from-file.
  ( umask 077
    sed -e "s|<GITLAB_URL>|$GITLAB_URL|g" -e "s|<NAMESPACE>|$NAMESPACE|g" \
        "$SAMPLE_DIR/runner/config.toml.template" > "$work/config.toml.pre"
    awk 'FNR==NR { tok=$0; next } { sub(/<RUNNER_TOKEN>/, tok); print }' \
        "$work/token" "$work/config.toml.pre" > "$work/config.toml" )
  ! grep -q '<RUNNER_TOKEN>' "$work/config.toml" \
    || die "the token was not substituted into config.toml."
  grep -q '^  token = "glrt-' "$work/config.toml" \
    || die "config.toml does not carry a glrt- token after rendering."
  grep -q '^    runtime_class_name = "isolated-sandbox"$' "$work/config.toml" \
    || die "the rendered config.toml does not set runtime_class_name = \"isolated-sandbox\", so the job pods would not be sandboxes."

  # `create`, not `apply`: a client-side apply copies the whole object, token included, into
  # a kubectl.kubernetes.io/last-applied-configuration annotation, and
  # `kubectl describe secret` prints annotations even though it hides data.
  "${KCTL[@]}" create secret generic "$RUNNER_SECRET" -n "$NAMESPACE" \
    --from-file=config.toml="$work/config.toml" >/dev/null \
    || die "could not create Secret '$RUNNER_SECRET'."
  "${KCTL[@]}" label secret "$RUNNER_SECRET" -n "$NAMESPACE" "$LABEL_KEY=$LABEL_VALUE" >/dev/null
  echo "  Secret '$RUNNER_SECRET' holds the rendered config.toml, with the token in it."
fi

# ---------------------------------------------------------------------------
say "5/5 the runner manager"
# ---------------------------------------------------------------------------
sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<RUNNER_SECRET>|$RUNNER_SECRET|g" \
  "$SAMPLE_DIR/deploy/runner.yaml" | "${KCTL[@]}" apply -f - \
  || die "could not apply deploy/runner.yaml."
"${KCTL[@]}" rollout status deploy/gitlab-runner -n "$NAMESPACE" --timeout=300s \
  || die "the runner manager did not become Ready. Its log says why:
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE logs deploy/gitlab-runner --tail=50"

# A Ready pod is not an online runner: the manager's container is Ready as soon as it starts,
# and it is GitLab that decides whether the token it presents is valid. contacted_at is
# GitLab's own record of having heard from it, so that is what is waited on. Without this, a
# token GitLab rejects would show up only as a first job that sat pending forever.
echo "  waiting for GitLab to hear from the runner."
cat > "$work/online.rb" <<RUBY_HEAD
require 'base64'
PROJECT_ID = $PROJECT_ID
RUNNER_DESCRIPTION = Base64.decode64('$(b64s "$RUNNER_DESCRIPTION")')
RUBY_HEAD
cat >> "$work/online.rb" <<'RUBY'
project = Project.find(PROJECT_ID)
runner = project.runners.where(description: RUNNER_DESCRIPTION).order(:id).last
if runner.nil?
  puts 'STATUS=no-runner'
else
  puts "STATUS=#{runner.contacted_at.nil? ? 'never-contacted' : 'online'}"
  puts "RUNNER_ID=#{runner.id}"
  puts "CONTACTED_AT=#{runner.contacted_at}"
end
RUBY
status=""
online_out=""
for _ in $(seq 1 10); do
  online_out="$("${KCTL[@]}" exec -i -n "$NAMESPACE" "$(gitlab_pod)" \
    -- gitlab-rails runner - < "$work/online.rb" 2>/dev/null || true)"
  status="$(sed -n 's/^STATUS=//p' <<<"$online_out")"
  [[ "$status" == online ]] && break
  sleep 10
done
[[ "$status" == online ]] \
  || die "GitLab has not heard from the runner (status: ${status:-could not read}). The manager pod is Ready, so it started; GitLab rejecting its token is the usual cause, and the manager logs that as a 403. Its log says which:
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE logs deploy/gitlab-runner --tail=50
  If the token is wrong, run scripts/clean.sh and start again: a runner authentication token cannot be read back out of GitLab, so there is nothing to repair in place."
echo "  the runner is online, last seen $(sed -n 's/^CONTACTED_AT=//p' <<<"$online_out")."

rm -rf "$work"
trap - EXIT INT TERM

say "the runner is ready"
cat <<EOF
  Project:      $PROJECT_FULL (id $PROJECT_ID), branch $BRANCH
  Runner:       '$RUNNER_DESCRIPTION', a project runner on that project
  Token:        in Secret '$RUNNER_SECRET', prefix glrt-, never printed
  Job pods:     runtimeClassName isolated-sandbox, privileged, in namespace $NAMESPACE

Next, start a pipeline and watch its two jobs land in two sandboxes:

  ./scripts/run-pipeline.sh
EOF
