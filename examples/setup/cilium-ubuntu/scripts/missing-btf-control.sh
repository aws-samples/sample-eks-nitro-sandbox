#!/usr/bin/env bash
# The missing-BTF failing control, as a reader step for stage 5: it shows the real BTF gate,
# scripts/cilium_ubuntu.py check-btf, refusing a node whose kernel has no BTF, then accepting
# the same node as it really is. Read-only against the cluster.
#
#   ./scripts/missing-btf-control.sh
#
# No Ubuntu EKS AMI without CONFIG_DEBUG_INFO_BTF is available to launch a node from, so the
# reject runs against the real sandbox node through a stub kubectl. The stub is written at run
# time under the repository's gitignored tmp/ (never in the sample folder) and answers exactly
# one call, check-btf's BTF read, with MISSING; every other call, the agent-pod lookup
# included, goes to the real kubectl. The script prints the stub's sha256, what kubectl resolves
# to, and how many calls the stub answered and passed on. Then it runs the same check-btf with
# no stub. It removes the stub folder at the end, however it ends, and says so.
#
# Exit codes: 0 the stub-driven run was refused (rc=1, the no-BTF message, the stub answering
# the BTF read), the real run accepted (rc=0), and the stub folder is removed; 1 either half
# came out otherwise; 2 it could not run (no kubeconfig, no single sandbox node, or a stub
# folder outside the repository's tmp/); 3 the control passed but its stub folder could not be
# removed (the message gives the folder; any other exit code is kept, with the same message);
# 130 or 143 interrupted, after the cleanup. BTF_STUB_PARENT names the folder the stub folder is
# made in (default: RUN_DIR, the repository's tmp/issue11/run); anything outside the
# repository's tmp/ is refused.
set -uo pipefail
SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$SAMPLE_DIR/scripts/common.sh"

cannot() { printf '%s %s\n' "$(_red 'COULD NOT RUN:')" "$*" >&2; exit 2; }
ts() { date -u +%FT%TZ; }
sha256_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# The exact BTF read check-btf makes (cilium_ubuntu.py, cmd_check_btf), the one call the stub answers.
BTF_READ='test -s /sys/kernel/btf/vmlinux && echo PRESENT || echo MISSING'

for cmd in kubectl python3; do
  command -v "$cmd" >/dev/null 2>&1 || cannot "$cmd is required but was not found on PATH"
done
[[ -s "$KUBECONFIG" ]] || cannot "$KUBECONFIG is missing; run ./setup.sh first"
real_kubectl="$(command -v kubectl)"
sandbox_node="$(kubectl get nodes -l eks.amazonaws.com/nodegroup=sandbox -o 'jsonpath={.items[*].metadata.name}' 2>&1)" \
  || cannot "could not read the sandbox node: $sandbox_node"
[[ -n "$sandbox_node" && "$sandbox_node" != *" "* ]] || cannot "expected exactly one sandbox node, found '$sandbox_node'"

# The stub folder: only ever under the repository's tmp/, after resolving every symlink.
tmp_root="$(cd "$REPO_ROOT/tmp" 2>/dev/null && pwd -P)" || cannot "$REPO_ROOT/tmp does not exist"
parent="${BTF_STUB_PARENT:-$RUN_DIR}"
parent_real="$(cd "$parent" 2>/dev/null && pwd -P)" || cannot "the stub's parent folder $parent does not exist"
case "$parent_real/" in
  "$tmp_root"/*) ;;
  *) cannot "refusing to write the stub to $parent (it resolves to $parent_real), which is not under $REPO_ROOT/tmp/, the repository's gitignored folder" ;;
esac
stub_dir="$(mktemp -d "$parent_real/missing-btf-stub.XXXXXX")" || cannot "could not make a stub folder in $parent_real"
# The removal is part of the result: INT and TERM are ignored while it runs (rm inherits that),
# and a folder that rm could not remove, or that is still there after it, turns a pass into exit 3.
cleanup() {
  local rc=$? rm_rc=0
  trap '' INT TERM
  trap - EXIT
  rm -rf -- "$stub_dir" || rm_rc=$?
  if ((rm_rc == 0)) && [[ ! -e "$stub_dir" && ! -L "$stub_dir" ]]; then
    echo "removed the stub folder $stub_dir"
  else
    printf '%s %s\n' "$(_red 'CLEANUP FAILED:')" "could not remove the stub folder $stub_dir (rm exit $rm_rc$([[ -e "$stub_dir" || -L "$stub_dir" ]] && echo '; it is still there')); remove it by hand: rm -rf -- $(printf '%q' "$stub_dir")" >&2
    if ((rc == 0)); then
      rc=3
      echo "missing-btf-control: exit 3: the control passed, but its stub folder is left behind" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'trap "" INT TERM; exit 130' INT  # a second signal must not cut the cleanup short
trap 'trap "" INT TERM; exit 143' TERM

{
  printf '%s\n' '#!/usr/bin/env bash' \
    "# Written by $SAMPLE_DIR/scripts/missing-btf-control.sh; removed when it ends." \
    "# Answers ONLY check-btf's BTF read with MISSING, as a node without CONFIG_DEBUG_INFO_BTF would;" \
    "# every other call goes to the real kubectl."
  printf 'real=%q\nlog=%q\nbtf_read=%q\n' "$real_kubectl" "$stub_dir/calls.log" "$BTF_READ"
  printf '%s\n' 'if [[ $# -eq 10 && "$1 $2 $3" == "-n kube-system exec" && "$5 $6 $7 $8 $9" == "-c cilium-agent -- sh -c" && "${10}" == "$btf_read" ]]; then' \
    '  echo "stubbed $*" >>"$log"' \
    '  echo MISSING' \
    '  exit 0' \
    'fi' \
    'echo "passed $*" >>"$log"' \
    'exec "$real" "$@"'
} >"$stub_dir/kubectl"
chmod 755 "$stub_dir/kubectl"
: >"$stub_dir/calls.log"

echo "== $(ts) STUB-DRIVEN: real scripts/cilium_ubuntu.py check-btf sandbox $sandbox_node, with $stub_dir first on PATH"
echo "stub sha256 $(sha256_of "$stub_dir/kubectl")"
echo "kubectl resolves to: $(PATH="$stub_dir:$PATH" command -v kubectl)"
reject_rc=0
reject_out="$(PATH="$stub_dir:$PATH" python3 "$PY" check-btf sandbox "$sandbox_node" 2>&1)" || reject_rc=$?
printf '%s\n' "$reject_out"
echo "rc=$reject_rc"
stubbed="$(grep -c '^stubbed ' "$stub_dir/calls.log")"
passed="$(grep -c '^passed ' "$stub_dir/calls.log")"
echo "the stub answered $stubbed BTF read(s) with MISSING and passed $passed other call(s) to $real_kubectl"

echo "== $(ts) real check-btf sandbox $sandbox_node, no stub (accept half, beside the reject)"
echo "kubectl resolves to: $(command -v kubectl)"
accept_rc=0
accept_out="$(python3 "$PY" check-btf sandbox "$sandbox_node" 2>&1)" || accept_rc=$?
printf '%s\n' "$accept_out"
echo "rc=$accept_rc"

bad=0
if ((reject_rc == 0)); then
  echo "FAIL: the stub-driven run was ACCEPTED: check-btf passed a node whose BTF read answered MISSING"; bad=1
elif ((reject_rc != 1)) || ! grep -qF "has no BTF at /sys/kernel/btf/vmlinux (read: 'MISSING')" <<<"$reject_out"; then
  echo "FAIL: the stub-driven run exited $reject_rc without the no-BTF message, so it was not refused for missing BTF"; bad=1
elif ((stubbed != 1)); then
  echo "FAIL: the stub answered $stubbed BTF reads, not exactly one, so the refusal is not the stub's"; bad=1
fi
if ((accept_rc != 0)) || ! grep -qxF "BTF present on node $sandbox_node (nodegroup sandbox)" <<<"$accept_out"; then
  echo "FAIL: the real run, with no stub, did not accept node $sandbox_node (rc=$accept_rc)"; bad=1
fi
if ((bad)); then
  echo "missing-btf-control: FAIL (exit 1)"
  exit 1
fi
echo "missing-btf-control: PASS: check-btf refused the node when its BTF read answered MISSING (rc=1) and accepted it as it is (rc=0)"
