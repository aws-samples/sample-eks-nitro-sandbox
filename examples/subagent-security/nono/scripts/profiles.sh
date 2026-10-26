#!/usr/bin/env bash
# profiles.sh -- regenerate the nono profiles in policies/ from src/policies.py.
#
# Usage:
#   ./scripts/profiles.sh            # write them
#   ./scripts/profiles.sh --check    # report differences, write nothing
#
# policies/ holds the three profiles the page shows, with <NAMESPACE> and <RUN> left as
# placeholders. setup.sh refuses to build an image when they are not what the generator
# produces, and the run checks the profile it hands each role against the committed one,
# so what the page shows cannot drift from what is enforced.
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  --check) exec python3 "$SAMPLE_DIR/src/policies.py" "$SAMPLE_DIR/policies" --check ;;
  --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
  "") exec python3 "$SAMPLE_DIR/src/policies.py" "$SAMPLE_DIR/policies" ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac
