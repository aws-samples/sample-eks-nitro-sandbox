#!/usr/bin/env bash
# Patch the SandboxTemplate's revision marker, and NOTHING else.
#
#   ./scripts/patch-template.sh rev-2
#
# This is the deploy on its own: the template now holds the new revision, and the
# pool is untouched. Every pod already warm in the pool keeps the revision it
# booted with, so this is the step that opens the stale-adoption window rather
# than the step that closes it. ./scripts/drain-pool.sh is what closes it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

REVISION="${1:-}"
[[ -n "$REVISION" ]] || die "usage: $0 <revision>   (for example: $0 rev-2)"
# The value is passed to jq as data, not spliced into a document, but keeping it
# to a short token means the value on the template is also the value the page
# shows and the one the readings compare.
[[ "$REVISION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
  || die "revision must start alphanumeric and hold only letters, digits, dots, dashes or underscores (at most 63 characters); got '$REVISION'"

require_commands kubectl jq
show_context
require_our_namespace

before="$(template_revision)" \
  || die "could not read $REVISION_ENV on sandboxtemplate/$TEMPLATE; stopping rather than patch a template whose current value is unknown"

# A merge patch on a custom resource replaces an array wholesale rather than
# merging it by key, so the containers array is read from the live object, the
# one marker value is changed in it, and the whole array is sent back. That
# keeps every other field exactly as it is without needing to know where in the
# env list the marker sits.
#
# jq reports how many entries it changed, and a patch that matched nothing is an
# error: without that check a renamed marker would leave the template untouched
# and the script would still say it had patched it.
patch_body="$(kc get sandboxtemplate "$TEMPLATE" -o json \
  | jq -c --arg n "$REVISION_ENV" --arg v "$REVISION" '
      .spec.podTemplate.spec.containers as $c
      | [$c[].env[]? | select(.name == $n)] | length as $matched
      | if $matched == 0 then
          error("no \($n) entry in the containers of this template")
        else
          {spec: {podTemplate: {spec: {containers:
            ($c | map(.env |= map(if .name == $n then .value = $v else . end)))
          }}}}
        end')" \
  || die "could not build the patch for sandboxtemplate/$TEMPLATE (is the $REVISION_ENV marker still in the template's env list?)"

kc patch sandboxtemplate "$TEMPLATE" --type=merge -p "$patch_body" >/dev/null

after="$(template_revision)" \
  || die "the patch was applied but $REVISION_ENV could not be read back; check 'kubectl -n $NAMESPACE get sandboxtemplate $TEMPLATE -o yaml'"
[[ "$after" == "$REVISION" ]] \
  || die "the template still says $REVISION_ENV=$after after patching it to $REVISION"

echo "sandboxtemplate/$TEMPLATE: $REVISION_ENV $before -> $after"
echo
echo "The pool has NOT been rebooted. Its sandboxes still carry:"
pool_sandbox_revisions | sed 's/^/  booted at /' || echo "  (could not read the pool's sandboxes)"
pool_template_hashes | sed 's/^/  template hash /' || true
echo
echo "Claim a pod now and it adopts one of those:  ./scripts/claim.sh stale"
