#!/usr/bin/env bash
# Offline test of the signer-policy blueprint's local clean up: the registry credentials
# examples/confidential/signer-policy/scripts/clean.sh removes, and the page's block that
# removes the release images and the rest of tmp/signer-policy. No cluster, no AWS account,
# no Docker daemon and no network: aws, kubectl, docker and the other remote tools are stubs
# that answer only the calls a case lists, and fail any other call.
#
#   ./scripts/test-signer-policy-clean.sh [--sut DIR] [--baseline DIR] [--only CASE,...] [--list]
#
#   --sut DIR       the tree to test (default: this checkout). It must hold
#                   examples/confidential/signer-policy/{scripts/clean.sh,scripts/lib.sh,README.md}.
#   --baseline DIR  an older tree with the same files. Cases whose remote behaviour must not
#                   change are run against it too, on an identical fixture, and the exit
#                   status, output and remote calls must match; the page's other fenced
#                   blocks must match it byte for byte. Without it those comparisons are
#                   reported as not checked.
#   --only LIST     run only the named cases.
#
# Nothing here runs the checkout's own clean.sh or reads its tmp/signer-policy. Every case
# copies the scripts into a fresh fixture under this checkout's gitignored tmp/, fills it
# with inert marker files, runs it with env -i and a PATH of stubs and wrappers, and
# compares metadata of this whole checkout (except this run's own fixture tree and output
# files) before and after, without opening any file in it.
#
# Exit: 0 every case passed, 1 a case failed, 2 a case could not be checked.
set -uo pipefail

here="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
checkout="$(cd -P -- "$here/.." && pwd -P)"
sut="$checkout" baseline="" only="" list=false
while (( $# )); do
  case "$1" in
    --sut) sut="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    --only) only=",$2,"; shift 2 ;;
    --list) list=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
rel=examples/confidential/signer-policy
for d in "$sut" ${baseline:+"$baseline"}; do
  for f in scripts/clean.sh scripts/lib.sh README.md; do
    [[ -f "$d/$rel/$f" ]] || { echo "could not check: no $d/$rel/$f" >&2; exit 2; }
  done
done
sut="$(cd -P -- "$sut" && pwd -P)"
[[ -z "$baseline" ]] || baseline="$(cd -P -- "$baseline" && pwd -P)"
[[ "$(id -u)" != 0 ]] || { echo "could not check: run as a non-root user (permission cases)" >&2; exit 2; }

real() { command -v "$1" || { echo "could not check: $1 is not installed" >&2; exit 2; }; }
BASH_BIN="$(real bash)" RM_BIN="$(real rm)" REALPATH_BIN="$(real realpath)"
ZSH_BIN="$(command -v zsh || true)"
mkdir -p "$checkout/tmp"
base="$(mktemp -d "$checkout/tmp/test-signer-policy-clean.XXXXXX")" ||
  { echo "could not check: no scratch directory" >&2; exit 2; }
trap 'chmod -R u+rwx "$base" 2>/dev/null; "$RM_BIN" -rf -- "$base"' EXIT

# --- the PATH every run gets ------------------------------------------------------------
proto="$base/proto"
mkdir -p "$proto"
for t in bash env timeout mkdir mv touch ls sleep date id sort wc tr ln \
         chmod stat find mkfifo uname basename; do
  p="$(command -v "$t" 2>/dev/null)" && [[ "$p" == /* ]] && ln -s "$p" "$proto/$t"
done
# Readers: each logs a call whose arguments name a credential directory, then runs the
# real tool. clean.sh's remote steps use grep, cat and jq on other files.
for t in cat head tail grep sed jq cp base64 od xxd dd sha256sum md5sum less more strings \
         awk python3 perl tee; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  # shellcheck disable=SC2016 # the wrapper's own $@ and $a, expanded when it runs
  printf '#!%s\nfor a in "$@"; do case "$a" in *genpolicy-home*|*docker-config*)\n  printf "%%s %%s\\n" "${0##*/}" "$*" >> "$SPCT_CTL/read.log";; esac; done\nexec %q "$@"\n' \
    "$BASH_BIN" "$p" > "$proto/$t"
done
# rm: logs its working directory and arguments, fails or lies on request for a named
# operand, and runs the real rm only on operands inside the case's own directory.
cat > "$proto/rm" <<EOF
#!$BASH_BIN
ctl="\${SPCT_CTL:?}"
printf '%s|%s\n' "\$(pwd -P)" "\$*" >> "\$ctl/rm.log"
for a in "\$@"; do
  [[ "\$a" == */* || ! -e "\$ctl/rm-fail-\$a" ]] || { echo "rm: cannot remove '\$a': test failure" >&2; exit 1; }
  [[ "\$a" == */* || ! -e "\$ctl/rm-lie-\$a" ]] || exit 0
  [[ "\$a" == */* || ! -e "\$ctl/rm-failafter-\$a" ]] || { $RM_BIN -rf -- "\$a"; echo "rm: test failure after removing '\$a'" >&2; exit 1; }
done
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  p="\$a"; [[ "\$p" == /* ]] || p="\$(pwd -P)/\$p"
  p="\$($REALPATH_BIN -m -s -- "\$p")"
  [[ "\$p" == "\$SPCT_CASE"/* ]] || { printf '%s\n' "\$p" >> "\$ctl/rm-outside.log"; exit 97; }
done
exec $RM_BIN "\$@"
EOF
# dirname: fails its Nth call when asked to, so the anchor's own failure can be reached.
cat > "$proto/dirname" <<EOF
#!$BASH_BIN
n=\$(( \$(cat "\$SPCT_CTL/dirname.count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$SPCT_CTL/dirname.count"
[[ "\$(cat "\$SPCT_CTL/dirname.fail" 2>/dev/null)" != "\$n" ]] || exit 1
exec $(command -v dirname) "\$@"
EOF
# The remote tools. A rule is tool|nth|glob|status|stdout|stderr: nth is * or the number of
# the identical call it answers. A call no rule answers is logged as unlisted and fails 99.
cat > "$proto/_stub" <<EOF
#!$BASH_BIN
tool="\${0##*/}" ctl="\${SPCT_CTL:?}"
argv="\$tool \$*" args="\$*"
n=\$(( \$(grep -cxF -- "\$argv" "\$ctl/calls.log" 2>/dev/null || true) + 1 ))
printf '%s\n' "\$argv" >> "\$ctl/calls.log"
while IFS='|' read -r t nth pat code out err; do
  [[ "\$t" == "\$tool" && ( "\$nth" == '*' || "\$nth" == "\$n" ) ]] || continue
  # shellcheck disable=SC2053
  [[ "\$args" == \$pat ]] || continue
  [[ -z "\$out" ]] || printf '%b' "\$out"
  [[ -z "\$err" ]] || printf '%b' "\$err" >&2
  exit "\$code"
done < "\$ctl/rules"
printf '%s\n' "\$argv" >> "\$ctl/unlisted.log"
echo "stub: unlisted call: \$argv" >&2
exit 99
EOF
# docker for the page block: an image store of full tags, one per line.
cat > "$proto/docker" <<EOF
#!$BASH_BIN
ctl="\${SPCT_CTL:?}"
printf 'docker %s\n' "\$*" >> "\$ctl/calls.log"
fail="\$(cat "\$ctl/docker.fail" 2>/dev/null)"
if [[ "\$1 \$2 \$3" == "image ls --quiet" && \$# == 4 ]]; then
  [[ "\$fail" != ls ]] || { echo "Cannot connect to the Docker daemon (test)" >&2; exit 1; }
  [[ "\$4" != *: && "\$4" != */:* ]] || { echo "invalid reference format" >&2; exit 1; }
  if grep -qxF -- "\$4" "\$ctl/images"; then echo sha256-fixture; fi
  exit 0
elif [[ "\$1 \$2" == "image rm" && \$# == 3 ]]; then
  [[ "\$fail" != rm ]] || { echo "conflict: image is in use (test)" >&2; exit 1; }
  grep -qxF -- "\$3" "\$ctl/images" || { echo "No such image: \$3" >&2; exit 1; }
  grep -vxF -- "\$3" "\$ctl/images" > "\$ctl/images.next"; mv "\$ctl/images.next" "\$ctl/images"
  echo "Untagged: \$3"; exit 0
fi
printf '%s\n' "docker \$*" >> "\$ctl/unlisted.log"; echo "stub: unlisted call: docker \$*" >&2; exit 99
EOF
# Only the files written here, never the real tools the links above point to.
find "$proto" -maxdepth 1 -type f -exec chmod +x {} +
for t in "$proto"/*; do
  [[ -L "$t" ]] || "$BASH_BIN" -n "$t" || { echo "could not check: generated $t does not parse" >&2; exit 2; }
done
for t in aws kubectl notation finch podman nerdctl crane oras helm eksctl curl wget ssh nc; do
  ln -s _stub "$proto/$t"
done

# --- the real checkout's guard: metadata only, never file contents -----------------------
guard() {
  local ex=(-path "$base" -prune) f
  for f in "${own_output[@]}"; do ex+=(-o -path "$f" -prune); done
  find "$checkout" \( "${ex[@]}" \) -o -printf '%y %m %s %T@ %p -> %l\n' 2>&1 | LC_ALL=C sort
}
# Everything in the checkout is guarded except this run's own fixture tree and the files this
# run's stdout and stderr are written to, when those are inside it.
own_output=()
for fd in 1 2; do
  p="$(readlink -f "/proc/$$/fd/$fd" 2>/dev/null)" && [[ -f "$p" ]] && own_output+=("$p")
done
# A file the guard must see change, for the guard's own control case (G1).
guard_control="$base.guard-control"
: > "$guard_control"
trap 'chmod -R u+rwx "$base" 2>/dev/null; "$RM_BIN" -rf -- "$base" "$guard_control"' EXIT

# --- fixture --------------------------------------------------------------------------
# A fresh case: C is its directory, R the fixture checkout, S the blueprint folder, T the run
# directory and O a tree outside the checkout that links point into.
put() { mkdir -p "$(dirname -- "$1")" && printf '%s\n' "${2:-inert fixture marker}" > "$1"; }
mkrepo() {  # mkrepo <dir>: a checkout with the scripts under test, .env and _shared
  mkdir -p "$1/$rel/scripts" "$1/examples/confidential/_shared"
  cp "$sutdir/$rel/scripts/clean.sh" "$sutdir/$rel/scripts/lib.sh" "$1/$rel/scripts/"
  cp "$sutdir/$rel/README.md" "$1/$rel/"
  chmod +x "$1/$rel/scripts/clean.sh"
  printf '%s\n' CLUSTER_NAME=fixture-cluster AWS_REGION=us-west-2 \
    SIGNING_PROFILE=nitro_sample_trusted_release RELEASE_ONE=1.0.0 RELEASE_TWO=1.1.0 > "$1/$rel/.env"
}
state() {  # state <file> [KEY=VALUE...]: a run record in lib.sh's own format
  local kv
  : > "$1"
  for kv in ACCOUNT_ID=fixture-account AWS_REGION=us-west-2 CLUSTER_NAME=fixture-cluster \
            NAMESPACE=signer-policy-sample REGISTRY=registry.example.invalid \
            SIGNING_PROFILE=nitro_sample_trusted_release SIGNING_PROFILE_ARN=fixture-profile-arn \
            ECR_REPOSITORY=nitro-sample-signer-policy RELEASE_ONE=1.0.0 IAM_ROLE_ARN=fixture-role-arn \
            "${@:2}"; do
    printf '%s=%q\n' "${kv%%=*}" "${kv#*=}" >> "$1"
  done
}
creds() {  # creds <run dir> [gh|dc|both|none]
  case "${2:-both}" in both|gh) put "$1/genpolicy-home/.docker/config.json" ;; esac
  case "${2:-both}" in both|dc) put "$1/docker-config/config.json" ;; esac
}
new_case() {  # new_case <name> <sut dir>
  name="$1" sutdir="$2"
  C="$base/cases/$name.$RANDOM$RANDOM"
  R="$C/repo" S="$C/repo/$rel" T="$C/repo/tmp/signer-policy" O="$C/outside" CTL="$C/ctl"
  mkdir -p "$C/home" "$CTL" "$O" "$C/bin"
  : > "$C/out"; : > "$C/err"
  fp_norm=./.none
  : > "$CTL/calls.log"; : > "$CTL/rules"
  mkrepo "$R"
  creds "$T" both
  state "$T/state.env"
  put "$T/rendered-pod.json"; put "$T/policy.signer.yaml"; put "$T/genpolicy.signer.log"
  put "$T/genpolicy-home-old/.docker/config.json"; put "$T/docker-config.bak"
  put "$T/sub/genpolicy-home/config.json"; put "$R/tmp/signer-policy-old/genpolicy-home/x"
  put "$R/tmp/other-sample/docker-config/config.json"; put "$S/docker-config/x"
  put "$O/target/.docker/config.json"; put "$O/file-target"
  args=() xenv=() drop=() cwd="$S" invoke=./scripts/clean.sh pshell=bash between=""
  fails=() errors=()
}
rules() { printf '%s\n' "$@" >> "$CTL/rules"; }
H_RULES=(
  'aws|*|sts get-caller-identity *|0|fixture-account\n|'
  'kubectl|*|get namespace signer-policy-sample --ignore-not-found -o jsonpath=*|0|signer-policy-sample|'
  'kubectl|1|get namespace signer-policy-sample --ignore-not-found -o name|0|namespace/signer-policy-sample\n|'
  'kubectl|2|get namespace signer-policy-sample --ignore-not-found -o name|0||'
  'kubectl|*|delete pod *|0||'
  'kubectl|*|delete namespace signer-policy-sample *|0||'
  'aws|*|eks list-pod-identity-associations *|0|a-fixture\n|'
  'aws|*|eks describe-pod-identity-association *|0|fixture-role-arn\n|'
  'aws|*|eks delete-pod-identity-association *|0||'
)
TAG_JSON='{"Key":"ManagedBy","Value":"eks-nitro-sandbox-signer-policy-sample"}'
# With no run record the role ARN is built from the account, so the fixture's bound role
# would not match; these cases have no association instead.
NOASSOC=('aws|*|eks list-pod-identity-associations *|0|None\n|')
D_RULES=(
  'aws|*|sts get-caller-identity *|0|fixture-account\n|'
  'kubectl|*|get namespace *|0||'
  'aws|*|eks list-pod-identity-associations *|0|None\n|'
  'aws|*|iam get-role *|0|fixture-role-arn\n|'
  "aws|*|iam list-role-tags *|0|{\"Tags\":[$TAG_JSON]}\n|"
  'aws|*|iam list-role-policies *|0|signer-policy-verify\n|'
  'aws|*|iam delete-role-policy *|0||'
  'aws|*|iam delete-role *|0||'
  'aws|*|ecr describe-repositories *|0|fixture-repo-arn\n|'
  "aws|*|ecr list-tags-for-resource *|0|{\"tags\":[$TAG_JSON]}\n|"
  'aws|*|ecr delete-repository *|0||'
  'aws|1|signer get-signing-profile *|0|Active\n|'
  'aws|2|signer get-signing-profile *|0|Canceled\n|'
  'aws|*|signer list-tags-for-resource *|0|{"tags":{"ManagedBy":"eks-nitro-sandbox-signer-policy-sample"}}\n|'
  'aws|*|signer cancel-signing-profile *|0||'
)
NF_RULES=(
  'aws|*|iam get-role *|254||An error occurred (NoSuchEntity) when calling the GetRole operation\n'
  'aws|*|ecr describe-repositories *|254||An error occurred (RepositoryNotFoundException)\n'
  'aws|*|signer get-signing-profile *|254||An error occurred (ResourceNotFoundException)\n'
)

# Run the scripts under test once, in the case as it stands.
run() {
  local bin="$C/bin" t
  if [[ ! -e "$bin/bash" ]]; then
    mkdir -p "$bin"
    for t in "$proto"/*; do
      [[ " ${drop[*]} " == *" ${t##*/} "* ]] || ln -s "$t" "$bin/${t##*/}"
    done
  fi
  : > "$CTL/rm.log"
  pre_fp="$(fp)" pre_guard="$(guard)"
  ( cd "$cwd" && timeout 20 env -i HOME="$C/home" PATH="$bin" PWD="$cwd" LANG=C LC_ALL=C TZ=UTC \
      SPCT_CTL="$CTL" SPCT_CASE="$C" "${xenv[@]}" "$invoke" "${args[@]}" ) > "$C/out" 2> "$C/err"
  rc=$?
  [[ -z "$between" ]] || "$between"
  post_fp="$(fp)" post_guard="$(guard)"
  [[ "$pre_guard" == "$post_guard" ]] || errors+=("REAL-CHECKOUT-CHANGED")
  [[ ! -s "$CTL/unlisted.log" ]] || errors+=("UNLISTED-STUB-CALL:$(head -1 "$CTL/unlisted.log")")
  ! grep -q 'command not found' "$C/err" || errors+=("COMMAND-NOT-FOUND")
  [[ "$rc" != 124 ]] || fails+=("READ-BLOCKED")
  [[ ! -s "$CTL/read.log" ]] || fails+=("READ-ATTEMPT:$(head -1 "$CTL/read.log")")
  [[ ! -s "$CTL/rm-outside.log" ]] || fails+=("RM-OUTSIDE")
  ! grep -q 'Permission denied' "$C/err" || [[ "$name" == F5* ]] || fails+=("READ-REFUSED")
}
# Metadata and content of the whole case, except the two credential directories (never
# hashed), aws.err (rewritten by every --delete-aws-resources lookup) and the harness's own
# files. A directory's own mtime is left out, so a removal shows only as the entry going.
fp() {
  local trel="./${T#"$C"/}"
  ( cd "$C" && find . \( -path ./ctl -o -path ./bin -o -path ./home -o -path ./out -o -path ./err \
      -o -path "$trel/genpolicy-home" -o -path "$trel/docker-config" -o -path "$trel/aws.err" \) -prune -o \
      \( -type d \( -path "$trel" -o -path "$fp_norm" \) -printf 'd %m %p (entries checked one by one)\n' \) -o \
      \( -type d -printf 'd %m %s %T@ %p\n' \) -o \( -printf '%y %m %s %T@ %p -> %l\n' \) \
      \( -type f -exec sha256sum {} + -o -true \) ) 2>&1 | LC_ALL=C sort
}

# --- assertions -------------------------------------------------------------------------
want_rc() { [[ "$rc" == "$1" ]] || fails+=("EXIT:$rc!=$1"); }
gone() { local l; for l in "$@"; do [[ ! -e "$T/$l" && ! -L "$T/$l" ]] || fails+=("CRED-PRESENT:$l"); done; }
there() { local l; for l in "$@"; do [[ -e "$T/$l" || -L "$T/$l" ]] || fails+=("CRED-MISSING:$l"); done; }
same_tree() { [[ "$pre_fp" == "$post_fp" ]] || fails+=("RETAINED-CHANGED:$(diff <(echo "$pre_fp") <(echo "$post_fp") | grep -m1 '^[<>]')"); }
no_remote() { ! grep -qE '^(aws|kubectl) ' "$CTL/calls.log" || fails+=("REMOTE-CALLED:$(grep -m1 -E '^(aws|kubectl) ' "$CTL/calls.log")"); }
no_rm() { [[ ! -s "$CTL/rm.log" ]] || fails+=("RM-CALLED"); }
in_err() { grep -qF -- "$1" "$C/err" || fails+=("MISSING-ERR:$1"); }
not_out() { ! grep -qF -- "$1" "$C/out" "$C/err" || fails+=("UNEXPECTED:$1"); }
remote_has() { grep -qE -- "$1" "$CTL/calls.log" || fails+=("REMOTE-MISSING:$1"); }
remote_lacks() { ! grep -qE -- "$1" "$CTL/calls.log" || fails+=("REMOTE-UNEXPECTED:$1"); }
# The two removals, in order, from the physical run directory, and nothing else.
rm_exact() {
  local t; t="$(cd -P -- "$T" && pwd -P)"
  [[ "$(cat "$CTL/rm.log")" == "$t|-rf -- genpolicy-home"$'\n'"$t|-rf -- docker-config" ]] ||
    fails+=("RM-ARGV:$(tr '\n' ';' < "$CTL/rm.log")")
}
silent_local() { ! grep -qE 'INCOMPLETE: (could not|.*registry credential)|registry credentials' "$C/err" || fails+=("LOCAL-NOISE"); }
local_fail_footer() {
  in_err "Clean up INCOMPLETE: the registry credentials may still be on this machine (see above)"
  not_out "Clean up complete."
}

# Run the same case on the baseline and compare status, output and remote calls.
same_as_baseline() {
  [[ -n "$baseline" ]] || { notchecked+=("$name:baseline"); return; }
  local mine_out mine_err mine_calls mine_rc="$rc" keep_f=("${fails[@]}") keep_e=("${errors[@]}") cmp=()
  mine_out="$(sed "s|$C|<C>|g" "$C/out")" mine_err="$(sed "s|$C|<C>|g" "$C/err")"
  mine_calls="$(cat "$CTL/calls.log")"
  "setup_$name" "$baseline"
  run
  [[ "$rc" == "$mine_rc" ]] || cmp+=("BASELINE-EXIT:$mine_rc!=$rc")
  [[ "$mine_out" == "$(sed "s|$C|<C>|g" "$C/out")" ]] || cmp+=("BASELINE-STDOUT")
  [[ "$mine_err" == "$(sed "s|$C|<C>|g" "$C/err")" ]] || cmp+=("BASELINE-STDERR")
  [[ "$mine_calls" == "$(cat "$CTL/calls.log")" ]] || cmp+=("BASELINE-CALLS")
  fails=("${keep_f[@]}" "${cmp[@]}") errors=("${keep_e[@]}" "${errors[@]}")
}

notchecked=() n_fail=0 n_err=0 n_pass=0
report() {
  local line
  if (( ${#errors[@]} )); then line="ERROR $name ${errors[*]}"; n_err=$((n_err + 1))
  elif (( ${#fails[@]} )); then line="FAIL $name ${fails[*]}"; n_fail=$((n_fail + 1))
  else line="PASS $name"; n_pass=$((n_pass + 1)); fi
  echo "$line"
}
CASES=()
case_() { CASES+=("$1"); }

# --- clean.sh cases ---------------------------------------------------------------------
# Each case is setup_<name> (the fixture, so the baseline gets the same one) and
# check_<name> (the run and the assertions).

case_ A1; setup_A1() { new_case A1 "$1"; rules "${H_RULES[@]}"; }
check_A1() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; silent_local
  in_out "Clean up complete."; same_as_baseline; }
in_out() { grep -qxF -- "$1" "$C/out" || fails+=("MISSING-OUT:$1"); }
case_ A2; setup_A2() { new_case A2 "$1"; rules "${H_RULES[@]}"; "$RM_BIN" -rf "$T/genpolicy-home" "$T/docker-config"; }
check_A2() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; same_as_baseline; }
case_ A3; setup_A3() { new_case A3 "$1"; rules "${H_RULES[@]}"; "$RM_BIN" -rf "$T/docker-config"; }
check_A3() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ A4; setup_A4() { new_case A4 "$1"; rules "${H_RULES[@]}"; "$RM_BIN" -rf "$T/genpolicy-home"; }
check_A4() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ A5a; setup_A5a() { new_case A5a "$1"; rules "${NOASSOC[@]}" "${H_RULES[@]}"; "$RM_BIN" -rf "$T"; }
check_A5a() { run; want_rc 0; [[ ! -e "$T" ]] || fails+=("RUN-DIR-CREATED"); same_tree; no_rm; same_as_baseline; }
case_ A5b; setup_A5b() { new_case A5b "$1"; rules "${NOASSOC[@]}" "${H_RULES[@]}"; "$RM_BIN" -rf "$R/tmp"; }
check_A5b() { run; want_rc 0; [[ ! -e "$R/tmp" ]] || fails+=("TMP-CREATED"); same_tree; no_rm; same_as_baseline; }
case_ HD; setup_HD() { new_case HD "$1"; rules "${D_RULES[@]}"; args=(--delete-aws-resources); }
check_HD() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; silent_local
  in_out "Clean up complete."; same_as_baseline; }
case_ A6; setup_A6() { new_case A6 "$1"; rules "${NF_RULES[@]}" "${D_RULES[@]}"; args=(--delete-aws-resources); }
check_A6() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; same_as_baseline; }
case_ A7; setup_A7() { new_case A7 "$1"; rules "${D_RULES[@]}"; args=(--delete-aws-resources); "$RM_BIN" -rf "$T"; }
check_A7() { run; [[ "$rc" != 0 ]] || fails+=("EXIT:0"); [[ ! -e "$T" ]] || fails+=("RUN-DIR-CREATED"); no_rm; same_as_baseline; }

case_ E1; setup_E1() { new_case E1 "$1"; state "$T/state.env"; sed -i '/^ACCOUNT_ID=/d' "$T/state.env"
  rules 'aws|*|sts get-caller-identity *|255||Unable to locate credentials\n' "${H_RULES[@]}"; }
check_E1() { run; want_rc 255; gone genpolicy-home docker-config; remote_lacks '^kubectl '; not_out "Clean up complete."; same_as_baseline; }
case_ E2; setup_E2() { new_case E2 "$1"; rules 'kubectl|*|get namespace * -o jsonpath=*|1||' "${H_RULES[@]}"; }
check_E2() { run; want_rc 1; gone genpolicy-home docker-config; in_err "could not determine whether namespace"; same_as_baseline; }
case_ E3; setup_E3() { new_case E3 "$1"; rules 'kubectl|*|delete pod *|42||' "${H_RULES[@]}"; }
check_E3() { run; want_rc 42; gone genpolicy-home docker-config; not_out "Clean up complete."; same_as_baseline; }
case_ E4; setup_E4() { new_case E4 "$1"; rules 'aws|*|iam delete-role --role-name *|254||' "${D_RULES[@]}"; args=(--delete-aws-resources); }
check_E4() { run; want_rc 254; gone genpolicy-home docker-config; remote_lacks '^aws (ecr|signer) '; not_out "Clean up complete."; same_as_baseline; }
case_ E5; setup_E5() { new_case E5 "$1"; rules 'aws|*|signer cancel-signing-profile *|253||' "${D_RULES[@]}"; args=(--delete-aws-resources); }
check_E5() { run; want_rc 253; gone genpolicy-home docker-config; not_out "Clean up complete."; same_as_baseline; }
case_ E6; setup_E6() { new_case E6 "$1"; rules 'aws|*|iam get-role *|254||An error occurred (AccessDenied)\n' "${D_RULES[@]}"; args=(--delete-aws-resources); }
check_E6() { run; want_rc 1; gone genpolicy-home docker-config; remote_has '^aws signer cancel-signing-profile '; same_as_baseline; }
case_ E7; setup_E7() { new_case E7 "$1"; rules 'aws|*|eks list-pod-identity-associations *|255||' "${H_RULES[@]}"; }
check_E7() { run; want_rc 1; gone genpolicy-home docker-config; in_err "could not determine whether a Pod Identity association"; same_as_baseline; }

case_ U1; setup_U1() { new_case U1 "$1"; rules "${H_RULES[@]}"; args=(--bogus); }
check_U1() { run; want_rc 2; gone genpolicy-home docker-config; no_remote; rm_exact
  [[ "$(cat "$C/err")" == "unknown argument: --bogus" ]] || fails+=("USAGE-STDERR"); [[ ! -s "$C/out" ]] || fails+=("USAGE-STDOUT"); }
case_ U1F; setup_U1F() { new_case U1F "$1"; rules "${H_RULES[@]}"; args=(--bogus); touch "$CTL/rm-fail-genpolicy-home"; }
check_U1F() { run; want_rc 2; there genpolicy-home; gone docker-config; no_remote; rm_exact
  in_err "unknown argument: --bogus"; in_err "INCOMPLETE: could not remove $(cd -P "$T" && pwd -P)/genpolicy-home"; local_fail_footer; }
# A valid first argument followed by another one is still invalid usage.
case_ U5; setup_U5() { new_case U5 "$1"; rules "${D_RULES[@]}"; args=(--delete-aws-resources --bogus); }
check_U5() { run; want_rc 2; gone genpolicy-home docker-config; no_remote; rm_exact; not_out "Clean up complete."
  [[ "$(cat "$C/err")" == "unknown argument: --bogus" ]] || fails+=("USAGE-STDERR"); [[ ! -s "$C/out" ]] || fails+=("USAGE-STDOUT"); }
case_ U5a; setup_U5a() { new_case U5a "$1"; rules "${H_RULES[@]}"; args=("" --bogus); "$RM_BIN" -rf "$T/genpolicy-home" "$T/docker-config"; }
check_U5a() { run; want_rc 2; gone genpolicy-home docker-config; no_remote; rm_exact; in_err "unknown argument: --bogus"; }
case_ U5F; setup_U5F() { new_case U5F "$1"; rules "${D_RULES[@]}"; args=(--delete-aws-resources x); touch "$CTL/rm-fail-docker-config"; }
check_U5F() { run; want_rc 2; gone genpolicy-home; there docker-config; no_remote; rm_exact
  in_err "unknown argument: x"; in_err "/docker-config (a registry credential)"; local_fail_footer; }
check_U2() { run; want_rc 1; gone genpolicy-home docker-config; in_err "no .env"; no_remote; same_as_baseline; }
# The guard's own control: a guarded file changes during a run, and the run must be
# reported as could-not-check. Here that is the expected result, so it passes.
case_ G1; setup_G1() { new_case G1 "$1"; rules "${H_RULES[@]}"; between=touch_guard_control; }
touch_guard_control() { sleep 0.01; printf 'changed\n' >> "$guard_control"; }
check_G1() { run
  if [[ " ${errors[*]} " == *" REAL-CHECKOUT-CHANGED "* ]]; then errors=(); else fails+=("GUARD-BLIND"); fi; }
case_ U2; setup_U2() { new_case U2 "$1"; rules "${H_RULES[@]}"; "$RM_BIN" -f "$S/.env"; }
for t in aws kubectl jq; do
  case_ "U3$t"; eval "setup_U3$t() { new_case U3$t \"\$1\"; rules \"\${H_RULES[@]}\"; drop=($t); }"
  eval "check_U3$t() { run; want_rc 1; gone genpolicy-home docker-config; in_err '$t is required'; no_remote; same_as_baseline; }"
done
case_ U4; setup_U4() { new_case U4 "$1"; rules "${H_RULES[@]}"; sed -i 's/^CLUSTER_NAME=.*/CLUSTER_NAME=/' "$S/.env"; }
check_U4() { run; [[ "$rc" != 0 ]] || fails+=("EXIT:0"); gone genpolicy-home docker-config; no_remote; same_as_baseline; }

# Local removal failures: the other name is still tried, nothing remote runs, exit 1.
case_ F1; setup_F1() { new_case F1 "$1"; rules "${H_RULES[@]}"; touch "$CTL/rm-fail-genpolicy-home"; }
check_F1() { run; want_rc 1; there genpolicy-home; gone docker-config; no_remote; rm_exact; local_fail_footer
  in_err "INCOMPLETE: could not remove $(cd -P "$T" && pwd -P)/genpolicy-home (a registry credential)"; }
case_ F2; setup_F2() { new_case F2 "$1"; rules "${H_RULES[@]}"; touch "$CTL/rm-fail-docker-config"; }
check_F2() { run; want_rc 1; gone genpolicy-home; there docker-config; no_remote; rm_exact; local_fail_footer
  in_err "INCOMPLETE: could not remove $(cd -P "$T" && pwd -P)/docker-config (a registry credential)"; }
case_ F4; setup_F4() { new_case F4 "$1"; rules "${H_RULES[@]}"; touch "$CTL/rm-fail-genpolicy-home" "$CTL/rm-fail-docker-config"; }
check_F4() { run; want_rc 1; there genpolicy-home docker-config; no_remote; rm_exact; local_fail_footer
  in_err "/genpolicy-home (a registry credential)"; in_err "/docker-config (a registry credential)"; }
case_ F5; setup_F5() { new_case F5 "$1"; rules "${H_RULES[@]}"; chmod 500 "$T/genpolicy-home/.docker"; }
check_F5() { run; chmod 700 "$T/genpolicy-home/.docker" 2>/dev/null; want_rc 1; there genpolicy-home; gone docker-config; no_remote; local_fail_footer; }
case_ F6; setup_F6() { new_case F6 "$1"; rules "${H_RULES[@]}"; touch "$CTL/rm-lie-docker-config"; }
check_F6() { run; want_rc 1; gone genpolicy-home; there docker-config; no_remote; local_fail_footer
  in_err "/docker-config (a registry credential)"; }
# rm reports a failure although the name is gone: the status alone must still count.
case_ F7; setup_F7() { new_case F7 "$1"; rules "${H_RULES[@]}"; touch "$CTL/rm-failafter-genpolicy-home"; }
check_F7() { run; want_rc 1; gone genpolicy-home docker-config; no_remote; rm_exact; local_fail_footer
  in_err "/genpolicy-home (a registry credential)"; }
case_ X1; setup_X1() { new_case X1 "$1"; rules "${H_RULES[@]}"; echo 3 > "$CTL/dirname.fail"; }
check_X1() { run; want_rc 1; there genpolicy-home docker-config; no_remote; no_rm; local_fail_footer
  in_err "could not find this checkout's own directory"; }
case_ X1U; setup_X1U() { new_case X1U "$1"; rules "${H_RULES[@]}"; echo 3 > "$CTL/dirname.fail"; args=(--bogus); }
check_X1U() { run; want_rc 2; there genpolicy-home docker-config; no_remote; no_rm; in_err "could not find this checkout's own directory"; }

# Parents that are not plain directories: nothing removed, nothing remote, exit 1.
parent_case() {  # parent_case <name> <path under R> <kind>
  case_ "$1"
  eval "setup_$1() { new_case $1 \"\$1\"; rules \"\${H_RULES[@]}\"; make_parent '$2' '$3'; }"
  eval "check_$1() { run; chmod -R u+rwx \"\$R/tmp\" 2>/dev/null; want_rc 1; no_remote; no_rm; same_tree; local_fail_footer; }"
}
make_parent() {
  local p="$R/$1"
  case "$2" in
    link) mkdir -p "$O/ptarget"; cp -a "$p/." "$O/ptarget/"; "$RM_BIN" -rf "$p"; ln -s "$O/ptarget" "$p" ;;
    link-empty) mkdir -p "$O/empty"; "$RM_BIN" -rf "$p"; ln -s "$O/empty" "$p" ;;
    dangling) "$RM_BIN" -rf "$p"; ln -s "$O/nowhere" "$p" ;;
    file) "$RM_BIN" -rf "$p"; put "$p" ;;
    fifo) "$RM_BIN" -rf "$p"; mkfifo "$p" ;;
    socket) "$RM_BIN" -rf "$p"; mksock "$p" ;;
    unenterable) chmod 000 "$p" ;;
  esac
}
# A Unix-domain socket entry, bound and closed at once: nothing listens on it. Bound by its
# relative name, because a socket path is limited to about 100 bytes.
mksock() {
  ( cd "$(dirname -- "$1")" && python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "${1##*/}" ) ||
    errors+=("NO-SOCKET")
}
for k in link link-empty dangling file fifo socket unenterable; do
  parent_case "L_sp_$k" tmp/signer-policy "$k"
  parent_case "L_tmp_$k" tmp "$k"
done

# What sits at the fixed names: removed as the entry itself, nothing outside touched.
child_case() {  # child_case <name> <leaf> <kind>
  case_ "$1"
  eval "setup_$1() { new_case $1 \"\$1\"; rules \"\${H_RULES[@]}\"; make_child '$2' '$3'; }"
  eval "check_$1() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }"
}
make_child() {
  local p="$T/$1"
  "$RM_BIN" -rf "$p"
  case "$2" in
    dir-link) ln -s "$O/target" "$p" ;;
    dangling) ln -s "$O/nowhere" "$p" ;;
    file) put "$p" ;;
    fifo) mkfifo "$p" ;;
    socket) mksock "$p" ;;
    inner-link) mkdir -p "$p"; ln -s "$O/target" "$p/.docker"; ln -s "$O/file-target" "$p/config.json" ;;
  esac
}
for k in dir-link dangling file fifo socket inner-link; do
  child_case "C_gh_$k" genpolicy-home "$k"
  child_case "C_dc_$k" docker-config "$k"
done

# Where it is run from, and through which path.
case_ R1; setup_R1() { new_case R1 "$1"; rules "${H_RULES[@]}"; cwd=/; invoke="$S/scripts/clean.sh"; }
check_R1() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ R1b; setup_R1b() { new_case R1b "$1"; rules "${H_RULES[@]}"; cwd="$O/cwd"; invoke="$S/scripts/clean.sh"
  creds "$O/cwd" both; creds "$O/cwd/tmp/signer-policy" both; mkdir -p "$O/cwd/scripts"; }
check_R1b() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ R2; setup_R2() { new_case R2 "$1"; rules "${H_RULES[@]}"; ln -s "$R" "$C/root-link"; cwd="$C/root-link/$rel"; }
check_R2() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ R3; setup_R3() { new_case R3 "$1"; rules "${H_RULES[@]}"
  mkrepo "$C/D"; "$RM_BIN" -rf "$C/D/$rel/scripts"; ln -s "$S/scripts" "$C/D/$rel/scripts"
  creds "$C/D/tmp/signer-policy" both; state "$C/D/tmp/signer-policy/state.env"; cwd="$C/D/$rel"; }
check_R3() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ R4; setup_R4() { new_case R4 "$1"; rules "${H_RULES[@]}"; mv "$R" "$C/re po"
  R="$C/re po" S="$C/re po/$rel" T="$C/re po/tmp/signer-policy" cwd="$C/re po/$rel"
  creds "$C/re/tmp/signer-policy" both; mkdir -p "$C/po"; creds "$C/po/tmp/signer-policy" both; }
check_R4() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ R5; setup_R5() { new_case R5 "$1"; rules "${H_RULES[@]}"; mkdir -p "$C/elsewhere"
  ln -s "$S/scripts/clean.sh" "$C/elsewhere/clean.sh"; cwd="$C/elsewhere"; invoke=./clean.sh; }
check_R5() { run; [[ "$rc" != 0 ]] || fails+=("EXIT:0"); there genpolicy-home docker-config; same_tree; no_remote; no_rm; }

# Names a run can set, from the caller's environment, .env or state.env.
SUBST=(TMP_DIR REPO_ROOT SAMPLE_DIR STATE_FILE GENPOLICY_HOME DOCKER_CFG_DIR DOCKER_CONFIG
       cred_root cred_root_rc root)
subst_values() {  # subst_values: decoy trees and the assignments that point at them
  local v
  for v in "${SUBST[@]}"; do creds "$O/s-$v" both; creds "$O/s-$v/tmp/signer-policy" both; done
  sv=(); for v in "${SUBST[@]}"; do sv+=("$v=$O/s-$v"); done
  sv=("${sv[@]/#cred_root_rc=*/cred_root_rc=0}")
}
case_ S1; setup_S1() { new_case S1 "$1"; rules "${H_RULES[@]}"; subst_values
  mkdir -p "$O/cdp/tmp/signer-policy" "$O/cdp/signer-policy"; creds "$O/cdp/signer-policy" both
  xenv=("${sv[@]}" CDPATH="$O/cdp" IFS=/); }
check_S1() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ S2; setup_S2() { new_case S2 "$1"; rules "${H_RULES[@]}"; subst_values
  mkdir -p "$O/cdp/tmp/signer-policy" "$O/cdp/signer-policy"; creds "$O/cdp/signer-policy" both
  printf '%s\n' "${sv[@]}" "CDPATH=$O/cdp" "IFS=/" >> "$S/.env"; }
check_S2() { run; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ S3; setup_S3() { new_case S3 "$1"; rules "${H_RULES[@]}"; subst_values
  mkdir -p "$O/cdp/tmp/signer-policy" "$O/cdp/signer-policy"; creds "$O/cdp/signer-policy" both
  printf '%s\n' "${sv[@]}" "CDPATH=$O/cdp" "IFS=/" >> "$T/state.env"; }
check_S3() { run; gone genpolicy-home docker-config; same_tree; rm_exact; }

# Never reading the credentials: FIFOs block a reader until the timeout, mode 000 files
# refuse one, and the reader wrappers log one.
case_ N1; setup_N1() { new_case N1 "$1"; rules "${H_RULES[@]}"; "$RM_BIN" -f "$T/genpolicy-home/.docker/config.json" "$T/docker-config/config.json"
  mkfifo "$T/genpolicy-home/.docker/config.json" "$T/docker-config/config.json"; }
check_N1() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
case_ N2; setup_N2() { new_case N2 "$1"; rules "${H_RULES[@]}"; chmod 000 "$T/genpolicy-home/.docker/config.json" "$T/docker-config/config.json"; }
check_N2() { run; want_rc 0; gone genpolicy-home docker-config; same_tree; rm_exact; }
# The source itself: outside comments, the two names appear only in the removal, its check
# and its message, and nothing else in clean.sh opens, sources or copies them.
case_ N3; setup_N3() { new_case N3 "$1"; }
check_N3() {
  local src bad
  src="$(sed -e 's/^[[:space:]]*#.*$//' "$S/scripts/clean.sh")"
  # shellcheck disable=SC2016 # the patterns match clean.sh's literal $ text
  bad="$(grep -nE 'genpolicy-home|docker-config|GENPOLICY_HOME|DOCKER_CFG_DIR|DOCKER_CONFIG' <<<"$src" | grep -vE \
    -e '^[0-9]+:  rm -rf -- (genpolicy-home|docker-config) \|\| (gh|dc)_rc=\$\?$' \
    -e '^[0-9]+:  if \[\[ "\$(gh|dc)_rc" != 0 \|\| -e (genpolicy-home|docker-config) \|\| -L (genpolicy-home|docker-config) \]\]; then$' \
    -e '^[0-9]+:    echo "  INCOMPLETE: could not remove \$root/tmp/signer-policy/(genpolicy-home|docker-config) \(a registry credential\)" >&2$')"
  [[ -z "$bad" ]] || fails+=("SOURCE-NAMES:${bad%%$'\n'*}")
  [[ "$(grep -cE '^  rm -rf -- (genpolicy-home|docker-config) ' <<<"$src")" == 2 ]] || fails+=("SOURCE-RM-COUNT")
  ! grep -qE '(<|cat|source|\.)[[:space:]]+[^|]*(genpolicy-home|docker-config)' <<<"$src" || fails+=("SOURCE-READ")
}

# Repeat runs, and the run after a failed one.
case_ K1; setup_K1() { new_case K1 "$1"; rules "${H_RULES[@]}"; }
check_K1() { run; local first; first="$(cat "$C/out")"; "$RM_BIN" -f "$CTL/calls.log"; : > "$CTL/calls.log"
  run; want_rc 0; gone genpolicy-home docker-config; [[ "$first" == "$(cat "$C/out")" ]] || fails+=("REPEAT-STDOUT"); rm_exact; }
case_ K2; setup_K2() { new_case K2 "$1"; rules 'kubectl|1|get namespace * -o jsonpath=*|1||' "${H_RULES[@]}"; }
check_K2() { run; want_rc 1; gone genpolicy-home docker-config; creds "$T" gh
  run; want_rc 0; gone genpolicy-home docker-config; }
case_ K3; setup_K3() { new_case K3 "$1"; rules "${NF_RULES[@]}" "${D_RULES[@]}"; args=(--delete-aws-resources); }
check_K3() { run; want_rc 0; : > "$CTL/calls.log"; run; want_rc 0; gone genpolicy-home docker-config; }

# --- the page block ---------------------------------------------------------------------
# The one fenced block in Clean up that removes the release images; run under bash and zsh.
page_block() { awk '/^## Clean up/{c=1} c && /^```bash$/{b=1; s=""; next} b && /^```$/{b=0; if (s ~ /docker image rm/) {printf "%s", s; exit}; next} b{s = s $0 "\n"}' "$1"; }
blocks_of() {  # every fenced block, opening fence line included, NUL-separated
  local line in=false acc=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == '```'* ]]; then
      if $in; then printf '%s\0' "$acc"; acc="" in=false; else acc="$line"$'\n' in=true; fi
    elif $in; then acc+="$line"$'\n'; fi
  done < "$1"
}
P_TAG1=registry.example.invalid/nitro-sample-signer-policy:1.0.0
P_TAG2=registry.example.invalid/nitro-sample-signer-policy:1.1.0
pcase() {  # pcase <name> <setup words>: one setup, then a run under each shell
  local sh
  for sh in bash zsh; do
    case_ "P_${1}_$sh"
    eval "setup_P_${1}_$sh() { new_case P_${1}_$sh \"\$1\"; page_setup $2; pshell=$sh; }"
    eval "check_P_${1}_$sh() { prun && page_check_$1; }"
  done
}
page_setup() {
  fp_norm="./${R#"$C"/}/tmp"
  "$RM_BIN" -rf "$T/genpolicy-home" "$T/docker-config"
  printf '%s\n' "$P_TAG1" "$P_TAG2" registry.example.invalid/nitro-sample-signer-policy:other > "$CTL/images"
  state "$T/state.env" RELEASE_TWO=1.1.0
  local w
  for w in "$@"; do
    case "$w" in
      one) state "$T/state.env" ;;
      absent) printf '%s\n' registry.example.invalid/nitro-sample-signer-policy:other > "$CTL/images" ;;
      nostate) "$RM_BIN" -f "$T/state.env" ;;
      statelink) mv "$T/state.env" "$O/state.env"; ln -s "$O/state.env" "$T/state.env" ;;
      norelease) state "$T/state.env"; sed -i '/^RELEASE_ONE=/d' "$T/state.env" ;;
      rmfail) echo rm > "$CTL/docker.fail" ;;
      lsfail) echo ls > "$CTL/docker.fail" ;;
      hostile) printf '%s\n' "run=$O/target" "root=$O" > "$T/state.env.extra"; cat "$T/state.env.extra" >> "$T/state.env" ;;
      ambient) xenv=(RELEASE_TWO=1.1.0 REGISTRY=wrong.invalid) ;;
      tmplink) make_parent tmp link ;;
      splink) make_parent tmp/signer-policy link ;;
      nodir) "$RM_BIN" -rf "$T" ;;
      wrongcwd) mkdir -p "$O/a/b/c" "$O/tmp/signer-policy"
        state "$O/tmp/signer-policy/state.env" RELEASE_TWO=1.1.0; cwd="$O/a/b/c" ;;
    esac
  done
}
prun() {
  local block shbin
  block="$(page_block "$S/README.md")"
  [[ -n "$block" ]] || { fails+=("PAGE-BLOCK-MISSING"); return 1; }
  if [[ "$pshell" == zsh ]]; then
    [[ -n "$ZSH_BIN" ]] || { errors+=("NO-ZSH"); return 1; }
    shbin="$ZSH_BIN"; "$ZSH_BIN" -n <<<"$block" || { errors+=("ZSH-SYNTAX"); return 1; }
  else shbin="$BASH_BIN"; "$BASH_BIN" -n <<<"$block" || { errors+=("BASH-SYNTAX"); return 1; }; fi
  printf '%s\nprintf "SHELL-SURVIVED rc=%%s\\n" "$?"\n' "$block" > "$C/block.sh"
  local bin="$C/bin" t
  mkdir -p "$bin"; for t in "$proto"/*; do ln -s "$t" "$bin/${t##*/}"; done
  : > "$CTL/rm.log"; pre_fp="$(fp)" pre_guard="$(guard)"
  local f=(-f); [[ "$pshell" == bash ]] && f=(--norc --noprofile)
  ( cd "$cwd" && timeout 20 env -i HOME="$C/home" PATH="$bin" PWD="$cwd" LANG=C LC_ALL=C TZ=UTC \
      SPCT_CTL="$CTL" SPCT_CASE="$C" "${xenv[@]}" "$shbin" "${f[@]}" "$C/block.sh" ) > "$C/out" 2> "$C/err"
  rc=$?
  post_fp="$(fp)" post_guard="$(guard)"
  [[ "$pre_guard" == "$post_guard" ]] || errors+=("REAL-CHECKOUT-CHANGED")
  [[ ! -s "$CTL/unlisted.log" ]] || errors+=("UNLISTED-STUB-CALL:$(head -1 "$CTL/unlisted.log")")
  ! grep -q 'command not found' "$C/err" || errors+=("COMMAND-NOT-FOUND")
  [[ ! -s "$CTL/rm-outside.log" ]] || fails+=("RM-OUTSIDE")
  block_rc="$(sed -n 's/^SHELL-SURVIVED rc=//p' "$C/out")"
  [[ -n "$block_rc" ]] || fails+=("SHELL-EXITED")
}
images_left() { [[ "$(cat "$CTL/images")" == "$(printf '%s\n' "$@")" ]] || fails+=("IMAGES:$(tr '\n' ';' < "$CTL/images")"); }
dir_kept() { [[ -d "$T" && ! -L "$T" ]] || fails+=("RUN-DIR-GONE"); same_tree; }
dir_gone() {
  [[ ! -e "$T" && ! -L "$T" ]] || fails+=("RUN-DIR-KEPT")
  local t; t="$(cd -P -- "$R/tmp" && pwd -P)"
  [[ "$(cat "$CTL/rm.log")" == "$t|-rf -- signer-policy" ]] || fails+=("RM-ARGV:$(tr '\n' ';' < "$CTL/rm.log")")
  [[ -f "$R/tmp/signer-policy-old/genpolicy-home/x" && -f "$R/tmp/other-sample/docker-config/config.json" ]] || fails+=("DECOY-REMOVED")
}
block_ok() { [[ "$block_rc" == 0 ]] || fails+=("BLOCK-EXIT:$block_rc!=0"); }
block_failed() { [[ -n "$block_rc" && "$block_rc" != 0 ]] || fails+=("BLOCK-EXIT:$block_rc"); }
no_docker() { ! grep -q '^docker ' "$CTL/calls.log" || fails+=("DOCKER-CALLED"); }
pcase two ""; page_check_two() { block_ok; images_left registry.example.invalid/nitro-sample-signer-policy:other; dir_gone; }
pcase one "one"; page_check_one() { block_ok; images_left "$P_TAG2" registry.example.invalid/nitro-sample-signer-policy:other; dir_gone; }
pcase ambient "one ambient"; page_check_ambient() { block_ok; images_left "$P_TAG2" registry.example.invalid/nitro-sample-signer-policy:other; dir_gone; }
pcase absent "absent"; page_check_absent() { block_ok; grep -qF "$P_TAG1 is already gone" "$C/out" || fails+=("NO-ABSENT-NOTE"); dir_gone; }
pcase hostile "hostile"; page_check_hostile() { block_ok; dir_gone; [[ -f "$O/target/.docker/config.json" ]] || fails+=("OUTSIDE-REMOVED"); }
pcase nostate "nostate"; page_check_nostate() { block_failed; dir_kept; no_docker; }
pcase statelink "statelink"; page_check_statelink() { block_failed; dir_kept; no_docker; }
pcase norelease "norelease"; page_check_norelease() { block_failed; dir_kept; no_docker; }
pcase rmfail "rmfail"; page_check_rmfail() { block_failed; dir_kept; }
pcase lsfail "lsfail"; page_check_lsfail() { block_failed; dir_kept; }
pcase tmplink "tmplink"; page_check_tmplink() { block_failed; same_tree; no_docker; [[ ! -s "$CTL/rm.log" ]] || fails+=("RM-CALLED"); }
pcase splink "splink"; page_check_splink() { block_failed; same_tree; no_docker; [[ ! -s "$CTL/rm.log" ]] || fails+=("RM-CALLED"); }
pcase nodir "nodir"; page_check_nodir() { block_failed; no_docker; [[ ! -s "$CTL/rm.log" ]] || fails+=("RM-CALLED"); }
pcase wrongcwd "wrongcwd"; page_check_wrongcwd() { block_failed; dir_kept; no_docker; [[ -f "$O/tmp/signer-policy/state.env" ]] || fails+=("WRONG-ROOT-CHANGED"); }
# Every other fenced block on the page is unchanged, and the block is one subshell.
case_ P_static; setup_P_static() { new_case P_static "$1"; }
check_P_static() {
  local block; block="$(page_block "$S/README.md")"
  [[ -n "$block" ]] || { fails+=("PAGE-BLOCK-MISSING"); return; }
  [[ "${block:0:2}" == "( " && "$block" == *" )" ]] || fails+=("BLOCK-NOT-ONE-SUBSHELL")
  ! grep -qE 'prune|--force|(^|[[:space:]])-f[[:space:]]|\*' <<<"$(grep -v '^#' <<<"$block" | grep -F docker)" || fails+=("BLOCK-BROAD-DOCKER")
  [[ -n "$baseline" ]] || { notchecked+=("$name:baseline"); return; }
  local mine=() theirs=() kept=() b dropped=0
  mapfile -d '' mine < <(blocks_of "$S/README.md")
  mapfile -d '' theirs < <(blocks_of "$baseline/$rel/README.md")
  for b in "${mine[@]}"; do
    if [[ "$b" == '```bash'$'\n'"$block"$'\n' ]]; then dropped=$((dropped + 1)); else kept+=("$b"); fi
  done
  [[ "$dropped" == 1 ]] || fails+=("PAGE-BLOCK-COUNT:$dropped")
  [[ "${#kept[@]}" == "${#theirs[@]}" ]] || fails+=("OTHER-FENCES-COUNT:${#kept[@]}!=${#theirs[@]}")
  local i
  for i in "${!theirs[@]}"; do
    [[ "${kept[i]:-}" == "${theirs[i]}" ]] || { fails+=("OTHER-FENCE-CHANGED:$i"); break; }
  done
}

# --- run --------------------------------------------------------------------------------
if $list; then printf '%s\n' "${CASES[@]}"; exit 0; fi
g0="$(guard)"
for c in "${CASES[@]}"; do
  [[ -z "$only" || "$only" == *",$c,"* ]] || continue
  "setup_$c" "$sut"
  "check_$c"
  report
done
[[ "$(grep -vF "$guard_control" <<<"$g0")" == "$(guard | grep -vF "$guard_control")" ]] ||
  { echo "ERROR the real checkout changed during the run" >&2; n_err=$((n_err + 1)); }
(( ${#notchecked[@]} == 0 )) || echo "NOT CHECKED (no --baseline): ${notchecked[*]}"
echo "passed $n_pass, failed $n_fail, could not check $n_err"
(( n_err == 0 && ${#notchecked[@]} == 0 )) || exit 2
(( n_fail == 0 )) || exit 1
