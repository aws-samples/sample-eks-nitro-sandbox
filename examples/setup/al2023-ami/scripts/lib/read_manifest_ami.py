#!/usr/bin/env python3
"""Print the AMI id from a packer manifest.json (env AMI_MANIFEST).

Packer records the build's artifact_id as "<region>:<ami-id>"; the last build wins. Prints
nothing (exit 0) when the manifest has no build, so the caller falls back to the build log.
"""
import json
import os
import sys

path = os.environ.get("AMI_MANIFEST", "")
if not path:
    sys.exit(0)
try:
    with open(path) as f:
        manifest = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
builds = manifest.get("builds") or []
if not builds:
    sys.exit(0)
artifact_id = builds[-1].get("artifact_id", "")
ami = artifact_id.split(":")[-1] if ":" in artifact_id else artifact_id
if ami:
    print(ami)
