#!/usr/bin/env bash
# policies.sh -- regenerate policy/ from src/policies.py.
#
# The files in policy/ are what the page shows, so they are generated rather than
# hand-edited. scripts/setup.sh runs the same generator with --check and refuses to go on
# when the committed files disagree with it, so a page can never show a policy that is
# not the one the run applied.
#
# Usage:
#   ./scripts/policies.sh
set -euo pipefail

SAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$SAMPLE_DIR/src/policies.py" "$SAMPLE_DIR/policy"
