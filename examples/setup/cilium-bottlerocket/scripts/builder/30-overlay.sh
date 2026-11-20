#!/usr/bin/env bash
# 30-overlay.sh (stage overlay, on the builder): add the variant and the nitro-sandbox package
# to the clone (variant/register-variant.py), put the verified inputs in the package folder,
# and refresh the root Cargo.lock for the two new path crates only.
# Input: CB_SANDBOX_SLOTS (the one density value; it becomes pcie_slots).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
[[ "${CB_SANDBOX_SLOTS:-}" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$CB_SANDBOX_SLOTS" -le 250 ] \
  || die "E_INPUT_SANDBOX_SLOTS: CB_SANDBOX_SLOTS must be an integer from 1 to 250"
[ -d "$CLONE/.git" ] || die "E_CLONE: no clone; fetch-verify did not pass"
python3 -I "$OVERLAY/packages/lib/runtime_verify.py" check "$LOCK" "$INPUTS" >/dev/null \
  || die "E_INPUTS: the inputs changed after fetch-verify"

cp "$CLONE/Cargo.lock" "$WORK/Cargo.lock.before"
python3 -I "$OVERLAY/variant/register-variant.py" apply --clone "$CLONE" --overlay "$OVERLAY/variant" \
  --lock "$LOCK" --slots "$CB_SANDBOX_SLOTS" || die "E_OVERLAY: register-variant.py refused (see the line above)"

# The four external files, as hard links of the verified files (buildsys checks each SHA-512).
pkg="$CLONE/packages/nitro-sandbox"
for id in runtime-release firecracker-release guest-image-eif guest-image-disk; do
  f=$(lock_field "$id" file)
  ln "$INPUTS/$f" "$pkg/$f" || die "E_OVERLAY: could not link $f into the package"
done

( cd "$CLONE" && cargo update --workspace --offline --quiet ) || die "E_CARGO_LOCK: cargo update --workspace failed"
python3 -I "$OVERLAY/variant/register-variant.py" check-lock "$WORK/Cargo.lock.before" "$CLONE/Cargo.lock" \
  || die "E_CARGO_LOCK: Cargo.lock changed more than the two new crates"

changed=$(git -C "$CLONE" status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')
want="Cargo.lock Cargo.toml README.md packages/nitro-sandbox/ packages/settings-defaults/settings-defaults.spec packages/settings-plugins/settings-plugins.spec variants/aws-k8s-1.36-nitro-sandbox/ "
[ "$changed" = "$want" ] || die "E_OVERLAY: the clone changed in other paths: $changed"
grep -E '^pcie_slots += ' "$pkg/nitro-sandbox.toml" | sed 's/^/builder: nitro-sandbox.toml /'
log "overlay ok"
