#!/usr/bin/env python3
"""Print the AMI id a packer manifest.json (env AMI_MANIFEST) holds for the Region AMI_REGION.

Packer records each build's artifact_id as "<region>:<ami-id>", comma separated when the image
was copied to several Regions. The last build wins. Exits 1, printing nothing, when the manifest
cannot be read, has no build, or names no AMI for AMI_REGION, so a stale manifest from another
Region is never taken.
"""
import json
import os
import sys

path = os.environ.get("AMI_MANIFEST", "")
region = os.environ.get("AMI_REGION", "")
if not path or not region:
    sys.exit(1)
try:
    with open(path) as f:
        manifest = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
builds = manifest.get("builds") or []
if not builds:
    sys.exit(1)
for entry in str(builds[-1].get("artifact_id", "")).split(","):
    r, _, ami = entry.partition(":")
    if r == region and ami:
        print(ami)
        sys.exit(0)
sys.exit(1)
