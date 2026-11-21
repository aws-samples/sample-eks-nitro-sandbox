#!/usr/bin/env bash
# 10-build-ami-packer.sh: the sandbox AMI build (setup.sh stage "ami").
#
#   scripts/10-build-ami-packer.sh check-tools   verify and install Packer and its Amazon plugin
#                                                (setup.sh stage "preflight"; no AWS call)
#   scripts/10-build-ami-packer.sh build         build, check and record the AMI
#
# build: checks its inputs before any AWS call; makes the builder security group (no inbound
# rule, egress TCP 443 only), the builder role (AmazonSSMManagedInstanceCore only) and its
# instance profile; runs one `packer build` of packer/; deletes the security group, the
# instance profile and the role; reads back that the builder instance, its volumes, the
# security group, the instance profile and the role are gone; then reads the AMI from the
# Packer manifest and checks the image and its two snapshots. After a failed build, the same run
# builds again only when one read of each builder part, AMI and snapshot shows it absent
# (E_RESUME otherwise); the last attempt's files and state keys go to packer.attempt<N>.
# Exit 0 done; 1 refused or failed (the state file names what exists; run ./clean.sh); 2 could
# not determine. Each refusal prints one line: ERROR: E_<TAG>: <text>.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"
export SAMPLE_DIR
# shellcheck source=/dev/null
. "$SAMPLE_DIR/scripts/common.sh"
umask 077
[ $# = 1 ] || die E_ARGS "usage: scripts/10-build-ami-packer.sh check-tools|build"
case "$1" in check-tools|build) CMD="$1" ;; *) die E_ARGS "usage: scripts/10-build-ami-packer.sh check-tools|build" ;; esac
TOOLS_LOCK="${CB_PACKER_TOOLS_LOCK:-$SAMPLE_DIR/packer/tools.lock}"
PM=(python3 -I "$SAMPLE_DIR/scripts/lib/packer_manifest.py")
# could_not <E_TAG> <text>: a check that could not run; exit 2.
could_not() { printf 'ERROR: %s: %s\n' "$1" "$2" >&2; exit 2; }

# ---- tools: Packer and the Amazon plugin, verified against HashiCorp's signed checksums ------
lock_value() { # lock_value <key>: the one value of <key> in the tools lock
  local n
  n=$(grep -c "^$1=" "$TOOLS_LOCK" || true)
  [ "$n" = 1 ] || die E_TOOLS_LOCK "$1 must appear exactly once in $TOOLS_LOCK"
  sed -n "s/^$1=//p" "$TOOLS_LOCK"
}
fetch() { # fetch <url> <file>
  curl -fsSL --proto '=https,file' --max-time 900 -o "$2.part" "$1" 2>/dev/null || could_not E_TOOLS_DOWNLOAD "could not download $1"
  mv -f "$2.part" "$2"
}
# verify_signed <sums> <sig> <keyring> <gnupghome> <fingerprint>: one GOODSIG, one VALIDSIG whose
# primary key fingerprint (its last field) is the pinned one, and no bad status line.
verify_signed() {
  local status prim
  status=$(GNUPGHOME="$4" gpg --batch --no-default-keyring --keyring "$3" --status-fd 1 --verify "$2" "$1" 2>/dev/null) \
    || die E_TOOLS_SIGNATURE "$(basename "$1") has no good signature from the HashiCorp key"
  ! printf '%s\n' "$status" | grep -Eq '^\[GNUPG:\] (BADSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|ERRSIG|NO_PUBKEY) ' \
    || die E_TOOLS_SIGNATURE "$(basename "$1"): gpg reports a bad, expired or revoked signature"
  [ "$(printf '%s\n' "$status" | grep -c '^\[GNUPG:\] GOODSIG ')" = 1 ] \
    && [ "$(printf '%s\n' "$status" | grep -c '^\[GNUPG:\] VALIDSIG ')" = 1 ] \
    || die E_TOOLS_SIGNATURE "$(basename "$1"): not exactly one good signature"
  prim=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $NF}')
  [ "$prim" = "$5" ] || die E_TOOLS_SIGNER "$(basename "$1") is signed by key $prim, not the pinned $5"
}
# fetch_zip <product> <version> <lock-digest> <dir> <keyring> <gnupghome> <fpr>: prints the zip path.
fetch_zip() {
  local prod="$1" ver="$2" want="$3" d="$4" zip sums line got base
  base=$(lock_value HASHICORP_RELEASES_URL)
  zip="${prod}_${ver}_${PLATFORM}.zip"; sums="${prod}_${ver}_SHA256SUMS"
  fetch "$base/$prod/$ver/$sums" "$d/$sums"
  fetch "$base/$prod/$ver/$sums.sig" "$d/$sums.sig"
  verify_signed "$d/$sums" "$d/$sums.sig" "$5" "$6" "$7"
  [ "$(awk -v f="$zip" '$2 == f' "$d/$sums" | wc -l)" = 1 ] || die E_TOOLS_DIGEST "the signed $sums does not list $zip exactly once"
  line=$(awk -v f="$zip" '$2 == f {print $1}' "$d/$sums")
  [ "$line" = "$want" ] || die E_TOOLS_DIGEST "the signed $sums gives $zip another digest than $TOOLS_LOCK"
  if [ ! -f "$d/$zip" ] || [ "$(sha256sum "$d/$zip" | awk '{print $1}')" != "$want" ]; then
    fetch "$base/$prod/$ver/$zip" "$d/$zip"
  fi
  got=$(sha256sum "$d/$zip" | awk '{print $1}')
  [ "$got" = "$want" ] || die E_TOOLS_DIGEST "$zip has sha256 $got, not the signed and pinned $want"
  printf '%s\n' "$d/$zip"
}
# tools_install <dest>: Packer in <dest>/bin and the plugin in <dest>/plugins. Sets PACKER_BIN.
tools_install() {
  local dest="$1" cache="$CB_RUN_DIR/tools" pver aver api fpr os arch key gh pzip azip pname inst
  pver=$(lock_value PACKER_VERSION); aver=$(lock_value AMAZON_PLUGIN_VERSION)
  api=$(lock_value AMAZON_PLUGIN_API); fpr=$(lock_value HASHICORP_KEY_FPR)
  [[ "$pver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$aver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$api" =~ ^x[0-9]+\.[0-9]+$ && "$fpr" =~ ^[0-9A-F]{40}$ ]] \
    || die E_TOOLS_LOCK "a value in $TOOLS_LOCK has the wrong form"
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) die E_TOOLS_PLATFORM "$(uname -s) is not supported" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) die E_TOOLS_PLATFORM "$(uname -m) is not supported" ;; esac
  PLATFORM="${os}_$arch"; key=$(printf '%s' "$PLATFORM" | tr '[:lower:]' '[:upper:]')
  for x in curl gpg unzip sha256sum; do command -v "$x" >/dev/null || die E_TOOLS_PREREQ "$x is not installed"; done
  install -d -m 0700 "$cache" "$cache/downloads"
  gh=$(mktemp -d "$cache/gnupg.XXXXXX") || die E_TOOLS_KEY "could not make a key folder in $cache"
  chmod 0700 "$gh"
  # shellcheck disable=SC2064  # the folder name is fixed now
  trap "rm -rf -- '$gh'" EXIT
  fetch "$(lock_value HASHICORP_KEY_URL)" "$gh/hashicorp.asc"
  GNUPGHOME="$gh" gpg --batch --yes --dearmor -o "$gh/hashicorp.gpg" "$gh/hashicorp.asc" 2>/dev/null \
    || die E_TOOLS_KEY "the HashiCorp key file is not a key"
  pzip=$(fetch_zip packer "$pver" "$(lock_value "PACKER_ZIP_SHA256_$key")" "$cache/downloads" "$gh/hashicorp.gpg" "$gh" "$fpr") || exit $?
  azip=$(fetch_zip packer-plugin-amazon "$aver" "$(lock_value "AMAZON_PLUGIN_ZIP_SHA256_$key")" "$cache/downloads" "$gh/hashicorp.gpg" "$gh" "$fpr") || exit $?
  rm -rf -- "$gh"
  install -d -m 0700 "$dest" "$dest/bin" "$dest/plugins" "$dest/config" "$dest/cache"
  unzip -q -o "$pzip" packer -d "$dest/bin" || die E_TOOLS_UNZIP "$(basename "$pzip") has no packer binary"
  PACKER_BIN="$dest/bin/packer"
  export PACKER_PLUGIN_PATH="$dest/plugins" PACKER_CONFIG_DIR="$dest/config" PACKER_CACHE_DIR="$dest/cache" CHECKPOINT_DISABLE=1
  [ "$("$PACKER_BIN" version | head -n 1)" = "Packer v$pver" ] || die E_TOOLS_VERSION "packer does not report v$pver"
  pname="packer-plugin-amazon_v${aver}_${api}_${PLATFORM}"
  rm -rf -- "$dest/plugin-unzip"; install -d -m 0700 "$dest/plugin-unzip"
  unzip -q -o "$azip" "$pname" -d "$dest/plugin-unzip" || die E_TOOLS_PLUGIN "$(basename "$azip") has no $pname"
  "$PACKER_BIN" plugins install --path "$dest/plugin-unzip/$pname" github.com/hashicorp/amazon >/dev/null \
    || die E_TOOLS_PLUGIN "packer plugins install failed"
  rm -rf -- "$dest/plugin-unzip"
  inst=$(find "$dest/plugins" -type f -name 'packer-plugin-amazon_*' ! -name '*_SHA256SUM')
  [ "$inst" = "$dest/plugins/github.com/hashicorp/amazon/$pname" ] || die E_TOOLS_PLUGIN "not exactly one plugin binary named $pname"
  [ "$(cat "${inst}_SHA256SUM")" = "$(sha256sum "$inst" | awk '{print $1}')" ] || die E_TOOLS_PLUGIN "the plugin's _SHA256SUM does not match it"
  printf 'packer-tools packer=v%s plugin=%s platform=%s signer=%s\n' "$pver" "$aver" "$PLATFORM" "$fpr"
}

if [ "$CMD" = check-tools ]; then
  tools_install "$CB_RUN_DIR/tools/packer"
  exit 0
fi

# ---- build: inputs first, before any AWS call ------------------------------------------------
[[ "${SANDBOX_SLOTS:-}" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$SANDBOX_SLOTS" -le 250 ] \
  || die E_INPUT_SANDBOX_SLOTS "SANDBOX_SLOTS must be an integer from 1 to 250, got '${SANDBOX_SLOTS:-}'"
[[ "${BUILD_INSTANCE_TYPE:-}" =~ ^[a-z][a-z0-9-]*\.[0-9a-z]+$ ]] || die E_INPUT "BUILD_INSTANCE_TYPE '${BUILD_INSTANCE_TYPE:-}' is not an instance type"
[[ "${BUILD_WORK_VOLUME_GIB:-}" =~ ^[0-9]+$ ]] && [ "$BUILD_WORK_VOLUME_GIB" -ge 100 ] && [ "$BUILD_WORK_VOLUME_GIB" -le 400 ] \
  || die E_INPUT "BUILD_WORK_VOLUME_GIB must be an integer from 100 to 400"
[[ "${AMI_WAIT_SECONDS:-}" =~ ^[0-9]+$ ]] && [ "$AMI_WAIT_SECONDS" -ge 600 ] && [ "$AMI_WAIT_SECONDS" -le 7200 ] \
  || die E_INPUT "AMI_WAIT_SECONDS must be an integer from 600 to 7200"
[ -z "${PACKER_LOG+x}" ] && [ -z "${PACKER_LOG_PATH+x}" ] || die E_PACKER_LOG "PACKER_LOG or PACKER_LOG_PATH is set; unset both"
require_run_id
check_run_record
# The run lock. setup.sh holds it on fd 9 and this script inherits that fd: lock the same open
# file again (which succeeds only for the holder). Run alone, take the lock as setup.sh does.
lrc=0
python3 -c 'import errno, fcntl, os, sys
try:
    st = os.fstat(9)
except OSError:
    sys.exit(5)
lk = os.stat(sys.argv[1])
if (st.st_dev, st.st_ino) != (lk.st_dev, lk.st_ino):
    sys.exit(6)
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as e:
    sys.exit(3 if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES) else 4)' "$RUN_STATE_DIR/run.lock" || lrc=$?
case "$lrc" in
  0) ;;
  5) lock_run ;;
  3) die E_RUN_LOCK "run $RUN_ID is in use: another process holds $RUN_STATE_DIR/run.lock" ;;
  *) die E_RUN_LOCK "could not lock $RUN_STATE_DIR/run.lock (fd 9 is another file, or flock failed)" ;;
esac
for v in BUILDER_NAME BUILDER_ROLE_NAME BUILDER_PROFILE_NAME BUILDER_SG_NAME AMI_NAME; do
  [ -n "${!v:-}" ] || die E_INPUT "$v is not set by derive_names"
done
VPC_ID=$(state_need VPC_ID); BUILD_SUBNET_ID=$(state_need BUILD_SUBNET_ID)
[[ "$VPC_ID" =~ ^vpc-[0-9a-f]{8,17}$ && "$BUILD_SUBNET_ID" =~ ^subnet-[0-9a-f]{8,17}$ ]] || die E_INPUT "VPC_ID or BUILD_SUBNET_ID is malformed"
OS_GIB=$(sed -n 's/^os-image-size-gib = \([0-9][0-9]*\)$/\1/p' "$SAMPLE_DIR/variant/variants/$SANDBOX_VARIANT/Cargo.toml")
[[ "$OS_GIB" =~ ^[0-9]+$ ]] && [ "$OS_GIB" -ge 2 ] || die E_INPUT "the variant Cargo.toml must set os-image-size-gib once"
DATA_GIB=$(( (OS_GIB + 1 > 22 ? OS_GIB + 1 : 22) - OS_GIB ))   # pubsys, split partition plan
PK="$RUN_STATE_DIR/packer"
EV="$EVIDENCE_DIR/ami-build.txt"
# The run tags, and the run tags with the builder's Name tag. The system node has the same run
# tags, so a by-tag read of the builder's instance or volumes also names the builder.
TAG_FILTERS=("Name=tag:$OWNER_TAG_KEY,Values=$OWNER_TAG_VALUE" "Name=tag:$RUN_TAG_KEY,Values=$RUN_ID")
BUILDER_FILTERS=("${TAG_FILTERS[@]}" "Name=tag:Name,Values=$BUILDER_NAME")

# ---- a retry after a failed build: only when each part of the last attempt is absent ---------
# One read for each part: the instance, its volumes, the security group, the instance profile,
# the role, and the AMIs and snapshots of the run by tag and by name. If one is present or a
# read fails, stop. Else rename packer/ to packer.attempt<N>, move the evidence file and the
# attempt's state keys into it, and build again. The retry deletes nothing.
resume_note=""
if [ -n "$(state_get BUILDER_SG_ID)" ] || [ -e "$PK" ]; then
  [ "$(state_get AMI_BUILD_RESULT)" != ok ] || die E_RESUME "this run already built its AMI"
  for k in BUILDER_ROLE_NAME BUILDER_PROFILE_NAME; do
    v=$(state_get "$k"); [ -z "$v" ] || [ "$v" = "${!k}" ] || die E_RESUME "the state has $k=$v, not ${!k}"
  done
  require_region
  require_caller_account >/dev/null
  RP="$PK/private"
  install -d -m 0700 "$PK" "$RP"
  absent() { # absent <kind> <name> <aws args...>: one read; the part is terminated or absent
    local kind="$1" n="$2" rc=0; shift 2
    aws "$@" --region "$AWS_REGION" --output json >"$RP/resume-$n.json" 2>"$RP/resume-$n.err" || rc=$?
    "${PM[@]}" gone "$kind" "$rc" "$RP/resume-$n.json" "$RP/resume-$n.err" >>"$RP/resume.txt" \
      || die E_RESUME "$n of the last attempt is present or could not be read; nothing was changed (run ./clean.sh --dry-run)"
  }
  bid=$(state_get BUILDER_INSTANCE_ID); sg=$(state_get BUILDER_SG_ID)
  [ -z "$bid" ] || absent instance instance ec2 describe-instances --instance-ids "$bid"
  absent instance instances-by-name ec2 describe-instances --filters "${BUILDER_FILTERS[@]}"
  for vol in $(state_get BUILDER_VOLUME_IDS | tr ',' ' '); do
    absent volume "$vol" ec2 describe-volumes --volume-ids "$vol"
  done
  absent volume volumes-by-name ec2 describe-volumes --filters "${BUILDER_FILTERS[@]}"
  [ -z "$sg" ] || absent sg sg ec2 describe-security-groups --group-ids "$sg"
  absent sg sg-by-name ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$BUILDER_SG_NAME"
  absent profile profile iam get-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME"
  absent role role iam get-role --role-name "$BUILDER_ROLE_NAME"
  absent image images-by-tag ec2 describe-images --owners self --filters "${TAG_FILTERS[@]}"
  absent image images-by-name ec2 describe-images --owners self --filters "Name=name,Values=$AMI_NAME"
  absent snapshot snapshots-by-tag ec2 describe-snapshots --owner-ids self --filters "${TAG_FILTERS[@]}"
  absent snapshot snapshots-by-name ec2 describe-snapshots --owner-ids self --filters "Name=tag:Name,Values=$AMI_NAME"
  n=1
  while [ -e "$PK.attempt$n" ]; do n=$((n + 1)); done
  OLD="$PK.attempt$n"
  mv "$PK" "$OLD" || die E_RESUME "could not rename $PK to $OLD"
  [ ! -e "$EV" ] || mv "$EV" "$OLD/ami-build.txt" || die E_RESUME "could not move $EV to $OLD"
  # The keys of the attempt go to $OLD/state-cleared.env, then out of the state file
  # (temp file, then rename, as state_set writes it).
  keys='^(BUILDER_[A-Z0-9_]+|OS_VOLUME_ID|DATA_VOLUME_ID|PACKER_MANIFEST|PACKER_RUN_UUID|SANDBOX_AMI_ID|SANDBOX_AMI_SNAPSHOT_IDS|SSM_COMMAND_[A-Z0-9_]+)='
  rc=0; grep -E "$keys" "$RUN_STATE_FILE" >"$OLD/state-cleared.env" || rc=$?
  [ "$rc" -le 1 ] || die E_STATE "could not read $RUN_STATE_FILE"
  tmp=$(mktemp "$RUN_STATE_FILE.XXXXXX") || die E_STATE "could not write $RUN_STATE_FILE"
  rc=0; grep -Ev "$keys" "$RUN_STATE_FILE" >"$tmp" || rc=$?
  { [ "$rc" -le 1 ] && chmod 600 "$tmp" && mv -f "$tmp" "$RUN_STATE_FILE"; } || { rm -f "$tmp"; die E_STATE "could not write $RUN_STATE_FILE"; }
  resume_note="resume previous=$(basename "$OLD") reads=$(wc -l <"$OLD/private/resume.txt" | tr -d ' ') all=absent cleared=$(cut -d= -f1 "$OLD/state-cleared.env" | paste -sd, -)"
fi
mkdir -m 0700 "$PK" "$PK/private" "$PK/upload"
PRIV="$PK/private"
[ -z "$resume_note" ] || printf '%s\n' "$resume_note" | tee -a "$EV"

# The overlay the builder receives: this checkout's files, so a reader builds what they edited.
# One SSM document is at most 64 KB (Systems Manager quotas, "Document size"; SendCommand error
# MaxDocumentSizeExceeded). Each upload command carries at most CHUNK bytes of base64, and the
# whole archive at most MAX_UPLOAD bytes, checked here before the builder exists.
CHUNK=48000; MAX_UPLOAD=384000
[[ "${CB_UPLOAD_CHUNK:-}" =~ ^[0-9]+$ ]] && [ "$CB_UPLOAD_CHUNK" -ge 1000 ] && [ "$CB_UPLOAD_CHUNK" -le "$CHUNK" ] && CHUNK=$CB_UPLOAD_CHUNK
[[ "${CB_UPLOAD_MAX_BYTES:-}" =~ ^[0-9]+$ ]] && [ "$CB_UPLOAD_MAX_BYTES" -le "$MAX_UPLOAD" ] && MAX_UPLOAD=$CB_UPLOAD_MAX_BYTES
B64_BYTES=$(python3 -I - "$SAMPLE_DIR" "$PK" "$CHUNK" <<'PY'
# The overlay archive (owner root, no __pycache__), its SHA-256, and its base64 in chunks.
import base64, hashlib, io, os, sys, tarfile
src, pk, chunk = sys.argv[1], sys.argv[2], int(sys.argv[3])
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as t:
    for top in ("variant", "packages", "scripts/builder", "packer/tools.lock"):
        def reset(i):
            if "__pycache__" in i.name:
                return None
            i.uid = i.gid = 0
            i.uname = i.gname = "root"
            return i
        t.add(os.path.join(src, top), arcname=top, filter=reset)
data = buf.getvalue()
with open(os.path.join(pk, "overlay.tgz"), "xb") as f:
    f.write(data)
with open(os.path.join(pk, "overlay.sha256"), "x") as f:
    f.write(hashlib.sha256(data).hexdigest() + "\n")
b64 = base64.b64encode(data)
for i in range(0, len(b64), chunk):
    with open(os.path.join(pk, "upload", "chunk-%03d" % (i // chunk)), "xb") as f:
        f.write(b64[i:i + chunk])
print(len(b64))
PY
) || die E_UPLOAD "could not pack the overlay"
[ "$B64_BYTES" -le "$MAX_UPLOAD" ] \
  || die E_UPLOAD_TOO_LARGE "the overlay is $B64_BYTES bytes of base64; the limit is $MAX_UPLOAD (64 KB per SSM document, $CHUNK per command)"
printf 'overlay archive=%s base64=%s chunks=%s chunk_max=%s sha256=%s\n' "$(wc -c < "$PK/overlay.tgz" | tr -d ' ')" \
  "$B64_BYTES" "$(find "$PK/upload" -name 'chunk-*' | wc -l | tr -d ' ')" "$CHUNK" "$(cat "$PK/overlay.sha256")" | tee -a "$EV"

tools_install "$PK" | tee -a "$EV"
[ "${PIPESTATUS[0]}" = 0 ] || exit 1
PACKER_BIN="$PK/bin/packer"
export PACKER_PLUGIN_PATH="$PK/plugins" PACKER_CONFIG_DIR="$PK/config" PACKER_CACHE_DIR="$PK/cache" CHECKPOINT_DISABLE=1

# Packer's plugin socket path must stay short: a private folder under TMPDIR (at most 80 bytes).
TMPBASE="${TMPDIR:-/tmp}"
[ "${#TMPBASE}" -le 80 ] && [ -d "$TMPBASE" ] || die E_PACKER_TMPDIR "TMPDIR ($TMPBASE) must be an existing folder of at most 80 bytes"
PTMP=$(mktemp -d "$TMPBASE/cbr-packer.XXXXXX") || die E_PACKER_TMPDIR "could not make a folder in $TMPBASE"
trap 'rm -rf -- "$PTMP"' EXIT

# ---- AWS: account, Region, builder AMI, subnet ------------------------------------------------
require_region
require_caller_account >/dev/null
rd() { # rd <name> <aws args...>: one read into private/<name>.json; exit 2 when it fails
  local n="$1"; shift
  aws "$@" --region "$AWS_REGION" --output json >"$PRIV/$n.json" 2>"$PRIV/$n.err" \
    || could_not E_READ "aws $1 $2 failed: $(tail -n 1 "$PRIV/$n.err")"
}
BUILDER_AMI_ID=$(aws ssm get-parameter --region "$AWS_REGION" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
                 --query Parameter.Value --output text 2>"$PRIV/ssm-parameter.err") || could_not E_READ "could not read the AL2023 AMI parameter"
[[ "$BUILDER_AMI_ID" =~ ^ami-[0-9a-f]{8,17}$ ]] || die E_INPUT "the AL2023 AMI parameter is not an AMI ID"
state_set BUILDER_AMI_ID "$BUILDER_AMI_ID"
rd subnet ec2 describe-subnets --subnet-ids "$BUILD_SUBNET_ID"
python3 -I -c 'import json, sys
s = json.load(open(sys.argv[1]))["Subnets"]
sys.exit(0 if len(s) == 1 and s[0]["VpcId"] == sys.argv[2] and s[0]["MapPublicIpOnLaunch"] is False else 1)' \
  "$PRIV/subnet.json" "$VPC_ID" || die E_SUBNET "$BUILD_SUBNET_ID is not a private subnet of $VPC_ID"

# ---- the builder security group, role and instance profile -----------------------------------
TAGS_SPEC="Tags=[{Key=$OWNER_TAG_KEY,Value=$OWNER_TAG_VALUE},{Key=$RUN_TAG_KEY,Value=$RUN_ID},{Key=Name,Value=$BUILDER_SG_NAME}]"
SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$BUILDER_SG_NAME" --vpc-id "$VPC_ID" \
        --description "cilium-bottlerocket builder: no inbound rule, egress TCP 443" \
        --tag-specifications "ResourceType=security-group,$TAGS_SPEC" --query GroupId --output text) \
  || die E_CREATE "create-security-group failed"
[[ "$SG_ID" =~ ^sg-[0-9a-f]{8,17}$ ]] || die E_CREATE "create-security-group returned no group ID"
state_set BUILDER_SG_ID "$SG_ID"
aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null || die E_CREATE "could not remove the default egress rule"
aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS only"}]}]' >/dev/null \
  || die E_CREATE "could not add the egress rule"
rd sg-created ec2 describe-security-groups --group-ids "$SG_ID"
"${PM[@]}" sg "$PRIV/sg-created.json" --sg "$SG_ID" --vpc "$VPC_ID" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" | tee -a "$EV"
[ "${PIPESTATUS[0]}" = 0 ] || exit 1

state_set BUILDER_ROLE_NAME "$BUILDER_ROLE_NAME"
# shellcheck disable=SC2046  # tag_args prints the two Key=,Value= words
aws iam create-role --role-name "$BUILDER_ROLE_NAME" --assume-role-policy-document "file://$SAMPLE_DIR/packer/builder-trust-policy.json" \
  --description "cilium-bottlerocket builder: Systems Manager only" --tags $(tag_args) >/dev/null || die E_CREATE "create-role failed"
aws iam attach-role-policy --role-name "$BUILDER_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" || die E_CREATE "attach-role-policy failed"
state_set BUILDER_PROFILE_NAME "$BUILDER_PROFILE_NAME"
# shellcheck disable=SC2046
aws iam create-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" --tags $(tag_args) >/dev/null || die E_CREATE "create-instance-profile failed"
aws iam add-role-to-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" --role-name "$BUILDER_ROLE_NAME" \
  || die E_CREATE "add-role-to-instance-profile failed"
aws iam wait instance-profile-exists --instance-profile-name "$BUILDER_PROFILE_NAME" || could_not E_READ "the instance profile did not appear"
aws iam get-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" --output json >"$PRIV/profile.json" 2>"$PRIV/profile.err" \
  || could_not E_READ "get-instance-profile failed"
"${PM[@]}" owned profile "$PRIV/profile.json" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" --role "$BUILDER_ROLE_NAME" >/dev/null || exit $?
sleep "${CB_SLEEP_SECONDS:-15}"   # IAM is eventually consistent: give EC2 time to see the profile

# ---- one Packer build -------------------------------------------------------------------------
# The pin tags come from packages/sources.lock, the one source of the versions.
PIN_RUNTIME=$(python3 -I "$SAMPLE_DIR/packages/lib/runtime_verify.py" field - runtime-release ref) || exit 1
PIN_GUEST=$(python3 -I "$SAMPLE_DIR/packages/lib/runtime_verify.py" field - guest-image-eif ref) || exit 1
PIN_FC=$(python3 -I "$SAMPLE_DIR/packages/lib/runtime_verify.py" field - firecracker-release ref) || exit 1
python3 -I - "$PK/vars.pkrvars.json" "$AWS_REGION" "$BUILDER_AMI_ID" "$BUILD_INSTANCE_TYPE" "$BUILD_SUBNET_ID" "$SG_ID" \
  "$BUILDER_PROFILE_NAME" "$BUILD_WORK_VOLUME_GIB" "$OS_GIB" "$DATA_GIB" "$AMI_NAME" "$BUILDER_NAME" "$RUN_ID" \
  "$OWNER_TAG_VALUE" "$SANDBOX_SLOTS" "$AMI_WAIT_SECONDS" "$BOTTLEROCKET_RELEASE" "$SANDBOX_VARIANT" \
  "$PIN_RUNTIME" "$PIN_GUEST" "$PIN_FC" \
  "$SAMPLE_DIR/scripts/packer-stage.sh" "$RUN_STATE_DIR" "$PK/manifest.json" <<'PY' || die E_INPUT "could not write the Packer variables"
import json, os, sys
a = sys.argv[2:]
assert len(a) == 23
v = {
    "region": a[0], "builder_ami_id": a[1], "instance_type": a[2], "subnet_id": a[3], "security_group_id": a[4],
    "instance_profile": a[5], "builder_root_gib": 30, "work_gib": int(a[6]), "os_image_gib": int(a[7]),
    "data_image_gib": int(a[8]), "ami_name": a[9], "build_name": a[10], "run_id": a[11], "managed_by": a[12],
    "sandbox_slots": int(a[13]), "ami_wait_attempts": (int(a[14]) + 14) // 15,
    "pin_tags": {"BottlerocketRelease": a[15], "Variant": a[16], "NitroRuntime": a[17], "GuestImage": a[18],
                 "Firecracker": a[19]},
    "stage_driver": a[20], "run_state_dir": a[21], "manifest_path": a[22],
}
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(v, f, indent=1)
PY
state_set PACKER_MANIFEST "$PK/manifest.json"
env TMPDIR="$PTMP" "$PACKER_BIN" validate -var-file="$PK/vars.pkrvars.json" "$SAMPLE_DIR/packer" >/dev/null \
  || die E_PACKER_VALIDATE "packer validate refused the template"
log "packer build: amazon-ebssurrogate, communicator none, -on-error=cleanup"
set +e
env TMPDIR="$PTMP" "$PACKER_BIN" build -on-error=cleanup -var-file="$PK/vars.pkrvars.json" "$SAMPLE_DIR/packer" 2>&1 \
  | tee "$PK/packer-build.log"
packer_rc=${PIPESTATUS[0]}
set -e

# ---- the builder resources are gone, success or failure --------------------------------------
worst=0
note() { local r="$1"; [ "$r" -le "$worst" ] || worst="$r"; }
# gone <kind> <name> <aws args...>: the read shows the resource terminated or absent. A volume
# can stay "deleting" for a short time after its instance ends, so the read is repeated.
gone() {
  local kind="$1" n="$2" rc r=1; shift 2
  for _ in $(seq 1 "${CB_WAIT_TRIES:-20}"); do
    rc=0
    aws "$@" --region "$AWS_REGION" --output json >"$PRIV/gone-$n.json" 2>"$PRIV/gone-$n.err" || rc=$?
    r=0; "${PM[@]}" gone "$kind" "$rc" "$PRIV/gone-$n.json" "$PRIV/gone-$n.err" >/dev/null || r=$?
    [ "$r" = 1 ] || break
    sleep "${CB_SLEEP_SECONDS:-15}"
  done
  [ "$r" = 0 ] || "${PM[@]}" gone "$kind" "$rc" "$PRIV/gone-$n.json" "$PRIV/gone-$n.err" || true
  return "$r"
}
bid=$(state_get BUILDER_INSTANCE_ID)
if [ -n "$bid" ]; then r=0; gone instance instance ec2 describe-instances --instance-ids "$bid" || r=$?; note "$r"; fi
r=0; gone instance instances-by-tag ec2 describe-instances --filters "${BUILDER_FILTERS[@]}" || r=$?; note "$r"
for vol in $(state_get BUILDER_VOLUME_IDS | tr ',' ' '); do
  r=0; gone volume "$vol" ec2 describe-volumes --volume-ids "$vol" || r=$?; note "$r"
done
r=0; gone volume volumes-by-tag ec2 describe-volumes --filters "${BUILDER_FILTERS[@]}" || r=$?; note "$r"
# Before each delete, the resource's own tags are read again. The builder's interface can stay
# attached to the group for a short time after the instance ends (DependencyViolation), so the
# delete is tried again while the group is still there and still the run's.
for _ in $(seq 1 "${CB_WAIT_TRIES:-20}"); do
  if ! aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG_ID" --output json >"$PRIV/sg-before-delete.json" 2>/dev/null \
     || ! "${PM[@]}" owned sg "$PRIV/sg-before-delete.json" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" >/dev/null; then
    break
  fi
  aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID" 2>"$PRIV/sg-delete.err" && break
  grep -q 'DependencyViolation' "$PRIV/sg-delete.err" || { note 1; break; }
  sleep "${CB_SLEEP_SECONDS:-15}"
done
r=0; gone sg sg ec2 describe-security-groups --group-ids "$SG_ID" || r=$?; note "$r"
if aws iam get-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" --output json >"$PRIV/profile-before-delete.json" 2>/dev/null \
   && "${PM[@]}" owned profile "$PRIV/profile-before-delete.json" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" --role "$BUILDER_ROLE_NAME" >/dev/null; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" --role-name "$BUILDER_ROLE_NAME" || note 1
  aws iam delete-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" || note 1
fi
r=0; gone profile profile iam get-instance-profile --instance-profile-name "$BUILDER_PROFILE_NAME" || r=$?; note "$r"
if aws iam get-role --role-name "$BUILDER_ROLE_NAME" --output json >"$PRIV/role-before-delete.json" 2>/dev/null \
   && "${PM[@]}" owned role "$PRIV/role-before-delete.json" --run-id "$RUN_ID" --managed-by "$OWNER_TAG_VALUE" >/dev/null; then
  aws iam detach-role-policy --role-name "$BUILDER_ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" || note 1
  aws iam delete-role --role-name "$BUILDER_ROLE_NAME" || note 1
fi
r=0; gone role role iam get-role --role-name "$BUILDER_ROLE_NAME" || r=$?; note "$r"
[ "$worst" != 2 ] || could_not E_LEFTOVER "a builder resource could not be read (see above); run ./clean.sh --dry-run"
[ "$worst" = 0 ] || die E_LEFTOVER "a builder resource remains (see above); run ./clean.sh --dry-run"
record() { printf '%s\n' "$*" | tee -a "$EV"; }
record "builder-gone instance=terminated volumes=absent sg=absent profile=absent role=absent"
[ "$packer_rc" = 0 ] || die E_PACKER_BUILD "packer build exited $packer_rc; no AMI is recorded"

# ---- the AMI: from the manifest only, then its image and snapshot checks ---------------------
[ -f "$PK/packer-run-uuid" ] || die E_MANIFEST_UUID "no builder was bound (stage bind did not run); no AMI is recorded"
out=$("${PM[@]}" manifest "$PK/manifest.json" --run-id "$RUN_ID" --region "$AWS_REGION" --uuid "$(cat "$PK/packer-run-uuid")") || exit $?
AMI_ID=$(printf '%s\n' "$out" | sed -n 's/^SANDBOX_AMI_ID=//p')
state_set SANDBOX_AMI_ID "$AMI_ID"
state_set PACKER_RUN_UUID "$(printf '%s\n' "$out" | sed -n 's/^PACKER_RUN_UUID=//p')"
record "manifest builds=1 builder_type=amazon-ebssurrogate sha256=$(sha256sum "$PK/manifest.json" | awk '{print $1}')"
rd images ec2 describe-images --owners self --image-ids "$AMI_ID"
rd uefi ec2 describe-image-attribute --image-id "$AMI_ID" --attribute uefiData
"${PM[@]}" image "$PRIV/images.json" --uefi "$PRIV/uefi.json" --ami "$AMI_ID" --run-id "$RUN_ID" \
  --managed-by "$OWNER_TAG_VALUE" --slots "$SANDBOX_SLOTS" >/dev/null || exit $?
snaps=$(python3 -I -c 'import json, sys
print(" ".join(m["Ebs"]["SnapshotId"] for m in json.load(open(sys.argv[1]))["Images"][0]["BlockDeviceMappings"] if "Ebs" in m))' "$PRIV/images.json")
# shellcheck disable=SC2086
rd snapshots ec2 describe-snapshots --owner-ids self --snapshot-ids $snaps
out=$("${PM[@]}" snapshots "$PRIV/images.json" "$PRIV/snapshots.json" --ami "$AMI_ID" --run-id "$RUN_ID" \
      --managed-by "$OWNER_TAG_VALUE" --os-volume "$(state_need OS_VOLUME_ID)" --data-volume "$(state_need DATA_VOLUME_ID)" \
      --slots "$SANDBOX_SLOTS") || exit $?
state_set SANDBOX_AMI_SNAPSHOT_IDS "$(printf '%s\n' "$out" | sed -n 's/^SANDBOX_AMI_SNAPSHOT_IDS=//p')"
record "image x86_64 hvm ena=true sriov=simple imds=v2.0 root=/dev/xvda data=/dev/xvdb gp3 boot_mode=uefi-preferred uefi_data=none snapshots=2 SandboxSlots=$SANDBOX_SLOTS"
state_set AMI_BUILD_RESULT ok
log "sandbox AMI built and checked; see $EV"
