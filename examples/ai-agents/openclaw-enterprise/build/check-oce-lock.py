#!/usr/bin/env python3
"""Require the exact remediated MSAL Node version in OCE's pnpm lockfile."""

from __future__ import annotations

import pathlib
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: check-oce-lock.py LOCKFILE EXPECTED_VERSION")

lockfile = pathlib.Path(sys.argv[1])
expected_version = sys.argv[2]
if not re.fullmatch(r"\d+\.\d+\.\d+", expected_version):
    raise SystemExit("OCE lock: expected version must be exact")

try:
    text = lockfile.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"OCE lock: could not read {lockfile}: {error}") from error

versions = re.findall(r"^  '@azure/msal-node@([^']+)':$", text, re.MULTILINE)
if not versions:
    raise SystemExit("OCE lock: no exact @azure/msal-node package entry found")
if set(versions) != {expected_version}:
    found = ", ".join(sorted(set(versions)))
    raise SystemExit(
        f"OCE lock: @azure/msal-node resolved to {found}; "
        f"expected only {expected_version}"
    )

print(f"OCE lock: @azure/msal-node is exact-pinned to remediated {expected_version}")
