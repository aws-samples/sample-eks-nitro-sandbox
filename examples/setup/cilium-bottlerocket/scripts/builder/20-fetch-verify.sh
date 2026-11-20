#!/usr/bin/env bash
# 20-fetch-verify.sh (stage fetch-verify, on the builder): clone Bottlerocket at the pinned
# tag and commit, then download and verify every runtime input (packages/sources.lock).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
mountpoint -q "$WORK" || die "E_WORK_VOLUME: $WORK is not mounted; host-setup did not pass"

ref=$(lock_field bottlerocket-source ref); url=$(lock_field bottlerocket-source source)
commit=$(lock_field bottlerocket-source commit); tag_object=$(lock_field bottlerocket-source tag_object)
[ ! -e "$CLONE" ] || die "E_CLONE: $CLONE already exists"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$url" "$CLONE" || die "E_CLONE: git clone of $ref failed"
[ "$(git -C "$CLONE" rev-parse HEAD)" = "$commit" ] || die "E_CLONE_COMMIT: $ref is not at the pinned commit $commit"
[ "$(git -C "$CLONE" rev-parse "refs/tags/$ref")" = "$tag_object" ] || die "E_CLONE_TAG: tag $ref is not the pinned tag object"
log "bottlerocket $ref commit=$commit tag_object=$tag_object"

# Twoliter's version and digest in the clone must be the pinned ones.
for k in TWOLITER_VERSION TWOLITER_SHA256_X86_64; do
  want=$(tool_lock "$k")
  [ "$(grep -c "^$k = \"$want\"$" "$CLONE/Makefile.toml")" = 1 ] || die "E_TWOLITER: Makefile.toml does not set $k = $want"
done

python3 -I "$OVERLAY/packages/lib/runtime_verify.py" fetch "$LOCK" "$INPUTS" || die "E_INPUTS: an input did not verify (see the line above)"
log "fetch-verify ok"
