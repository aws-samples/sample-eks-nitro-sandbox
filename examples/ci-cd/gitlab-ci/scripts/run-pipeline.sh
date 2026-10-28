#!/usr/bin/env bash
# run-pipeline.sh -- start a pipeline, record the job pods while they exist, and print what
# the two jobs reported.
#
# Usage:
#   ./scripts/run-pipeline.sh
#
# What it does, in order:
#   1. checks the context and that the namespace is this sample's;
#   2. starts a pipeline on the project's default branch, the same thing "Run pipeline" does
#      in GitLab's own UI;
#   3. watches the namespace for job pods. A job pod exists only while its job runs and is
#      deleted when the job ends, so each one's name, UID, runtime class and node are
#      recorded as it appears;
#   4. waits for the pipeline to finish and prints each job's status and log;
#   5. runs the same three readings in an ordinary pod on the node a job pod used, and
#      removes that pod by its exact name.
set -euo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

ORDINARY_POD=gitlab-ci-ordinary
JOB_POD_SELECTOR="app=gitlab-ci-job"

# ---------------------------------------------------------------------------
say "1/5 context and namespace"
# ---------------------------------------------------------------------------
need_tools kubectl base64 jq
check_cluster
require_namespace
echo "  context '$KUBE_CONTEXT', namespace '$NAMESPACE' is this sample's."

b64s() { printf '%s' "$1" | { base64 -w0 2>/dev/null || base64 | tr -d '\n'; }; }
work="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-ci-run.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM
chmod 700 "$work"

# ---------------------------------------------------------------------------
say "2/5 starting the pipeline"
# ---------------------------------------------------------------------------
cat > "$work/start.rb" <<RUBY_HEAD
require 'base64'
PROJECT_PATH = Base64.decode64('$(b64s "$PROJECT_PATH")')
RUBY_HEAD
cat >> "$work/start.rb" <<'RUBY'
user = User.find_by_username('root')
raise 'no root user on this GitLab' if user.nil?

project = Project.find_by_full_path("#{user.username}/#{PROJECT_PATH}")
raise "no project #{user.username}/#{PROJECT_PATH}. Run scripts/bootstrap-runner.sh first." if project.nil?

branch = project.default_branch || 'main'
# The same path GitLab's own "Run pipeline" button takes.
response = ::Ci::CreatePipelineService
  .new(project, user, ref: branch)
  .execute(:web)
pipeline = response.payload

if pipeline.nil? || !pipeline.persisted?
  raise "could not create a pipeline: #{response.message || pipeline&.errors&.full_messages&.join(', ')}"
end

puts "PIPELINE_ID=#{pipeline.id}"
puts "PIPELINE_SHA=#{pipeline.sha}"
pipeline.builds.order(:id).each { |b| puts "JOB=#{b.id} #{b.name}" }
RUBY

start_out="$("${KCTL[@]}" exec -i -n "$NAMESPACE" "$(gitlab_pod)" \
  -- gitlab-rails runner - < "$work/start.rb")" \
  || die "GitLab could not start a pipeline. Its output is above."
PIPELINE_ID="$(sed -n 's/^PIPELINE_ID=//p' <<<"$start_out")"
PIPELINE_SHA="$(sed -n 's/^PIPELINE_SHA=//p' <<<"$start_out")"
[[ -n "$PIPELINE_ID" ]] \
  || die "GitLab reported no pipeline id. Its output was:
$start_out"
echo "  pipeline $PIPELINE_ID on ${PIPELINE_SHA:0:8}, with these jobs:"
sed -n 's/^JOB=/    /p' <<<"$start_out"

# ---------------------------------------------------------------------------
say "3/5 and 4/5 the job pods, and the pipeline"
# ---------------------------------------------------------------------------
# A job pod lives only while its job runs, so the watch and the wait are one loop: the pods
# are recorded as they appear, and the loop ends when the pipeline reaches a final status. A
# record taken after the pipeline finished would find nothing.
cat > "$work/status.rb" <<RUBY_HEAD
PIPELINE_ID = $PIPELINE_ID
RUBY_HEAD
cat >> "$work/status.rb" <<'RUBY'
pipeline = Ci::Pipeline.find(PIPELINE_ID)
puts "PIPELINE_STATUS=#{pipeline.status}"
pipeline.builds.order(:id).each { |b| puts "JOB_STATUS=#{b.id} #{b.name} #{b.status}" }
RUBY

: > "$work/pods.tsv"
pipeline_status=""
echo "  watching for job pods. Each one is created when its job starts and deleted when it"
echo "  ends, so this is the only moment they can be read."
printf '\n  %-46s %-38s %-18s %s\n' POD UID "RUNTIME CLASS" NODE

# Up to 40 minutes: a sandboxed job pod has a node to be provisioned, a VM to boot and its
# images to pull before the script runs.
deadline=$(( $(date +%s) + 2400 ))
last_status_check=0
while :; do
  # Record any job pod that is there now and has not been seen before. kubectl goes straight
  # into jq, and only the fields below are kept.
  pods_json="$("${KCTL[@]}" get pod -n "$NAMESPACE" -l "$JOB_POD_SELECTOR" -o json 2>/dev/null)" \
    || die "could not list the job pods in '$NAMESPACE'. That is a failed read, not a report that there are none."
  while IFS=$'\t' read -r name uid rclass node phase; do
    [[ -n "$name" ]] || continue
    if ! cut -f1 "$work/pods.tsv" | grep -qxF "$name"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$uid" "$rclass" "$node" "$phase" >> "$work/pods.tsv"
      printf '  %-46s %-38s %-18s %s\n' "$name" "$uid" "${rclass:-<none>}" "${node:-<unscheduled>}"
    fi
  done < <(jq -r '(.items // [])[] | [.metadata.name, .metadata.uid, (.spec.runtimeClassName // ""), (.spec.nodeName // ""), .status.phase] | @tsv' <<<"$pods_json")

  now=$(date +%s)
  (( now < deadline )) || die "the pipeline had not finished after 40 minutes. Its jobs and the runner manager's log say where it is:
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE logs deploy/gitlab-runner --tail=80
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE get pods -l $JOB_POD_SELECTOR"

  # GitLab's Rails console takes about half a minute to start, so the pipeline's status is
  # read every 30 seconds while the pods are polled every 2.
  if (( now - last_status_check >= 30 )); then
    last_status_check=$now
    status_out="$("${KCTL[@]}" exec -i -n "$NAMESPACE" "$(gitlab_pod)" \
      -- gitlab-rails runner - < "$work/status.rb" 2>/dev/null || true)"
    pipeline_status="$(sed -n 's/^PIPELINE_STATUS=//p' <<<"$status_out")"
    case "$pipeline_status" in
      success|failed|canceled|skipped) break ;;
      "") ;;  # a read that did not come back; try again rather than treat it as finished
      *) echo "  pipeline $PIPELINE_ID: $pipeline_status" ;;
    esac
  fi
  sleep 2
done

echo
echo "  pipeline $PIPELINE_ID finished: $pipeline_status"
sed -n 's/^JOB_STATUS=/    job /p' <<<"$status_out"

pod_count="$(wc -l < "$work/pods.tsv" | tr -d ' ')"
echo
echo "  job pods seen: $pod_count"
# Every job pod must have been a sandbox. A pod with no runtime class would mean the runner
# ignored runtime_class_name, which is the whole of what this sample configures, and the job
# would have run as an ordinary pod on the node.
unsandboxed="$(awk -F'\t' '$3 != "isolated-sandbox" { print $1 " (runtime class: " ($3 == "" ? "<none>" : $3) ")" }' "$work/pods.tsv")"
[[ -z "$unsandboxed" ]] \
  || die "a job pod did not carry runtimeClassName isolated-sandbox, so that job did not run in a sandbox:
$unsandboxed
  Check that runner/config.toml.template's runtime_class_name reached the Secret, and that the runner manager was restarted after it changed."
uid_count="$(cut -f2 "$work/pods.tsv" | sort -u | grep -c .)"
echo "  distinct pod UIDs: $uid_count (one per job, so no job reused another's pod)"
awk -F'\t' '{ printf "    %s  uid %s  on %s\n", $1, $2, $4 }' "$work/pods.tsv"

[[ "$pipeline_status" == success ]] \
  || die "the pipeline finished as '$pipeline_status'. The job logs below in GitLab, and the runner manager's log, say why:
  kubectl --context $KUBE_CONTEXT -n $NAMESPACE logs deploy/gitlab-runner --tail=80"

# ---------------------------------------------------------------------------
say "the job logs"
# ---------------------------------------------------------------------------
cat > "$work/trace.rb" <<RUBY_HEAD
PIPELINE_ID = $PIPELINE_ID
RUBY_HEAD
cat >> "$work/trace.rb" <<'RUBY'
pipeline = Ci::Pipeline.find(PIPELINE_ID)
pipeline.builds.order(:id).each do |build|
  puts "===== job #{build.id} #{build.name} (#{build.status}) ====="
  puts(build.trace.raw || '(no log)')
end
RUBY
"${KCTL[@]}" exec -i -n "$NAMESPACE" "$(gitlab_pod)" \
  -- gitlab-rails runner - < "$work/trace.rb" \
  || die "could not read the job logs from GitLab."

# ---------------------------------------------------------------------------
say "5/5 what an ordinary pod on the same node reports"
# ---------------------------------------------------------------------------
# The comparison only means something on the node a job pod actually ran on: a reading from
# another node compares two unrelated machines.
NODE_NAME="$(awk -F'\t' '$4 != "" { print $4; exit }' "$work/pods.tsv")"
[[ -n "$NODE_NAME" ]] \
  || die "none of the job pods recorded a node, so there is no node to compare against."
echo "  the job pods ran on $NODE_NAME."

# A pod this script made for itself, at a name of its own, removed by that exact name and
# never by a selector: a selector meant for one helper pod can match another demo's.
"${KCTL[@]}" delete pod "$ORDINARY_POD" -n "$NAMESPACE" --ignore-not-found --wait >/dev/null
sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<NODE_NAME>|$NODE_NAME|g" \
  "$SAMPLE_DIR/deploy/ordinary-pod.yaml" | "${KCTL[@]}" apply -f - >/dev/null \
  || die "could not create the ordinary pod."
cleanup_ordinary() {
  "${KCTL[@]}" delete pod "$ORDINARY_POD" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap 'cleanup_ordinary; rm -rf "$work"' EXIT INT TERM
"${KCTL[@]}" wait --for=condition=Ready "pod/$ORDINARY_POD" -n "$NAMESPACE" --timeout=180s >/dev/null \
  || die "the ordinary pod did not become Ready on $NODE_NAME."

echo
echo "  --- its kernel (the node's, shared with every ordinary pod on it) ---"
"${KCTL[@]}" exec -n "$NAMESPACE" "$ORDINARY_POD" -- uname -rv
echo "  --- its uptime (the node's, not this pod's age) ---"
"${KCTL[@]}" exec -n "$NAMESPACE" "$ORDINARY_POD" -- sh -c "cut -d' ' -f1 /proc/uptime"
echo "  --- its block devices (the instance's NVMe disks) ---"
"${KCTL[@]}" exec -n "$NAMESPACE" "$ORDINARY_POD" -- ls /sys/block
echo "  --- its product name (the EC2 instance type) ---"
"${KCTL[@]}" exec -n "$NAMESPACE" "$ORDINARY_POD" -- cat /sys/class/dmi/id/product_name

"${KCTL[@]}" delete pod "$ORDINARY_POD" -n "$NAMESPACE" --ignore-not-found --wait >/dev/null
trap 'rm -rf "$work"' EXIT INT TERM
echo
echo "  removed pod/$ORDINARY_POD."

rm -rf "$work"
trap - EXIT INT TERM

say "the pipeline is done"
cat <<EOF
  Pipeline:     $PIPELINE_ID, $pipeline_status
  Job pods:     $pod_count, $uid_count distinct UIDs, every one runtimeClassName isolated-sandbox
  Node:         $NODE_NAME

The job pods are gone: the runner deletes each one when its job ends. To watch a pipeline in
GitLab itself, forward the Service and open the project:

  kubectl --context $KUBE_CONTEXT -n $NAMESPACE port-forward svc/gitlab 8080:8080

When you have finished, remove everything this sample made:

  ./scripts/clean.sh
EOF
