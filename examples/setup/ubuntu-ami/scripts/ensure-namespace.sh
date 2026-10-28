#!/usr/bin/env bash
# ensure-namespace.sh: make sure this run's namespace exists and is this run's, before anything is
# applied into it. setup.sh calls it.
#
#   RUN_ID=<id> KUBE_CONTEXT=<ctx> scripts/ensure-namespace.sh
#
#   * absent (kubectl answers NotFound): created in ONE call, already carrying both labels,
#     app.kubernetes.io/part-of=<RESOURCE_PREFIX> and app.kubernetes.io/instance=<RUN_ID>, so it
#     can never exist unlabelled (clean.sh deletes a namespace only when it carries both);
#   * present with both labels: reused;
#   * present with anything else: refused (set NAMESPACE to a new name);
#   * the read fails for any other reason (wrong context, no permission, API error): refused with
#     "could not determine"; a failed read is never taken to mean "absent".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
require_run_id
require_kube_context   # KUBE_CONTEXT is set and is cluster CLUSTER_NAME, before the namespace is read or created
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "NAMESPACE '$NAMESPACE' is not a valid namespace name"

if ns_json=$(kc get namespace "$NAMESPACE" -o json 2>"$ERR"); then
  owner=$(printf '%s' "$ns_json" | json_get 'd["metadata"].get("labels", {}).get("app.kubernetes.io/part-of", "")')
  run=$(printf '%s' "$ns_json" | json_get 'd["metadata"].get("labels", {}).get("app.kubernetes.io/instance", "")')
  [[ "$owner" == "$RESOURCE_PREFIX" && "$run" == "$RUN_ID" ]] \
    || die "namespace $NAMESPACE exists but is not this run's (app.kubernetes.io/part-of='${owner:-none}', app.kubernetes.io/instance='${run:-none}'; expected $RESOURCE_PREFIX and $RUN_ID). Set NAMESPACE to a new name."
  log "reusing this run's namespace $NAMESPACE"
elif grep -q 'NotFound' "$ERR"; then
  manifest=$(mktemp)
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    app.kubernetes.io/part-of: %s\n    app.kubernetes.io/instance: %s\n' \
    "$NAMESPACE" "$RESOURCE_PREFIX" "$RUN_ID" > "$manifest"
  kc create -f "$manifest" || { rm -f "$manifest"; die "could not create namespace $NAMESPACE"; }
  rm -f "$manifest"
  log "created namespace $NAMESPACE labelled app.kubernetes.io/part-of=$RESOURCE_PREFIX app.kubernetes.io/instance=$RUN_ID"
else
  die "could not determine whether namespace $NAMESPACE exists (kubectl failed, not a report that it is absent): $(head -n 2 "$ERR")"
fi
