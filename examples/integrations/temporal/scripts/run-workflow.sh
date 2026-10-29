#!/usr/bin/env bash
# Start one run of the lifecycle workflow, and read the cluster while it runs.
#
#   ./scripts/run-workflow.sh            # start it and return
#   ./scripts/run-workflow.sh --wait     # start it and wait for the result
#   ./scripts/run-workflow.sh --describe # what the last run with this id is doing
#
# The Temporal client runs inside the Worker pod, which already has the SDK and
# already reaches the frontend over ClusterIP. Nothing here opens a port.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

require_commands kubectl
show_context

# Only act when this sample owns the namespace. Everything in a namespace the
# sample created and labelled is the sample's, so the namespace check covers the
# Worker too.
require_our_namespace
w_rc=0; resource_exists kc "deploy/$WORKER" || w_rc=$?
case $w_rc in
  0) : ;;
  1) die "deploy/$WORKER is not in namespace $NAMESPACE; run ./scripts/setup.sh first" ;;
  2) die "could not read deploy/$WORKER in namespace $NAMESPACE; stopping rather than start a run against something I cannot verify" ;;
esac

step "start the workflow"
kc exec "deploy/$WORKER" -- python -m harness.start "$@"
