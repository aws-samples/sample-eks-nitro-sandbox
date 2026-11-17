#!/usr/bin/env bash
# Run the local preview without AWS. Receipts remain under the repository's tmp/.
# Usage: ./scripts/run-local.sh [--image EXISTING_LOCAL_IMAGE]
# Without --image, build the current Dockerfile for Linux ARM64 first.
set -euo pipefail
umask 077
SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECTION_DIR="$(cd "$SAMPLE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SECTION_DIR/../.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
image=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --image) [[ "$#" -ge 2 && -n "$2" ]] || die "--image requires an existing local image"; image="$2"; shift 2 ;;
    --help|-h) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for tool in docker python3; do command -v "$tool" >/dev/null || die "$tool is required"; done
run_id="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
out="$REPO_ROOT/tmp/strands-box-local/$run_id"
mkdir -p "$out"
container_id=""
cleanup() {
  local status=$? owner
  trap - EXIT
  if [[ -n "$container_id" ]]; then
    if owner="$(docker inspect --format '{{ index .Config.Labels "strands-box.local-run" }}' "$container_id")"; then
      if [[ "$owner" == "$run_id" ]]; then
        if docker rm --force "$container_id" >/dev/null; then
          printf 'removed\n' > "$out/container-cleanup.txt"
        else
          printf 'removal failed\n' > "$out/container-cleanup.txt"
          echo "INCOMPLETE: could not remove this run's container $container_id" >&2
          status=1
        fi
      else
        printf 'ownership mismatch; retained\n' > "$out/container-cleanup.txt"
        echo "INCOMPLETE: container ownership differs; left $container_id alone" >&2
        status=1
      fi
    else
      printf 'ownership lookup failed; retained\n' > "$out/container-cleanup.txt"
      echo "INCOMPLETE: could not confirm container ownership; left $container_id alone" >&2
      status=1
    fi
  fi
  echo "Local receipts: $out"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -z "$image" ]]; then
  image="strands-box-local:$run_id"
  docker build --platform linux/arm64 -f "$SAMPLE_DIR/Dockerfile" -t "$image" "$SECTION_DIR" \
    > "$out/build.log" 2>&1 || die "the local image build failed; inspect $out/build.log"
fi
info="$(docker image inspect --format '{{.Id}} {{.Os}} {{.Architecture}}' "$image")" ||
  die "could not inspect the local image $image"
read -r image_id image_os image_arch <<<"$info"
[[ "$image_os" == linux && "$image_arch" == arm64 && "$image_id" == sha256:* ]] ||
  die "the local image must be Linux ARM64"
python3 - "$out/image.json" "$image" "$image_id" <<'IMAGE'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"image_reference": sys.argv[2], "image_id": sys.argv[3],
    "os": "linux", "architecture": "arm64", "network": "none", "uid": 1000,
    "privileged": True}, indent=2) + "\n")
IMAGE
container_id="$(docker create --name "strands-box-local-$run_id" \
  --label "strands-box.local-run=$run_id" --label app.kubernetes.io/managed-by=strands-box-local \
  --network none --platform linux/arm64 --privileged --user 1000:1000 \
  --mount "type=bind,source=$REPO_ROOT,target=/work,readonly" \
  --env "BOX_LOCAL_RUN_ID=$run_id" --env "BOX_LOCAL_IMAGE_ID=$image_id" \
  "$image_id" python3 -B /work/examples/subagent-security/strands-box/scripts/local_driver.py)" ||
  die "could not create the local container"
printf '%s\n' "$container_id" > "$out/container-id.txt"
status=0
docker start --attach "$container_id" > "$out/container.log" 2>&1 || status=$?
mkdir -p "$out/receipts"
docker cp "$container_id:/var/lib/analyst/local-export/." "$out/receipts" ||
  die "could not collect local receipts; inspect $out/container.log"
[[ "$status" == 0 ]] || die "the local controller failed; inspect $out/receipts/local-report.json"
python3 - "$out/receipts/local-report.json" "$image_id" "$SAMPLE_DIR/src" <<'REPORT'
import json
import sys
from pathlib import Path
import re
sys.path.insert(0, sys.argv[3])
import strict_json
folder = Path(sys.argv[1]).parent
report = strict_json.loads(Path(sys.argv[1]).read_text())
if report.get("completed") is not True or report.get("image_id") != sys.argv[2] or report.get("uid") != 1000:
    sys.exit("The local report is incomplete or describes a different image or user")
evidence = strict_json.loads((folder / "evidence.json").read_text())
transcript = (folder / "controller.log").read_text()
markers = re.findall(r"^BOX_LOCAL_COMPLETE=([0-9a-f]{32})$", transcript, re.M)
if (evidence.get("mode") != "local" or markers != [evidence.get("run_id")]
        or re.search(r"^ANALYST_COMPLETE=", transcript, re.M)):
    sys.exit("The receipts do not describe exactly one completed local run")
REPORT
python3 "$SAMPLE_DIR/scripts/correlate.py" "$out/receipts/evidence.json" \
  "$out/receipts/supplier-api-requests.jsonl" \
  | tee "$out/correlation.log"
echo "Local checks passed. Nitro, model, S3, and Pod Identity behavior remain untested by this command."
