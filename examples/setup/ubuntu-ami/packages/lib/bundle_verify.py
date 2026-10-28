#!/usr/bin/env python3
"""Offline bundle verification for packages/make-bundle.sh consume (see bundle_verify_archive in
bundle-common.sh, which calls this).

  bundle_verify.py <archive.tar> <manifest.json> <extract-dir>   < expected lines

stdin: one "<id> <ref> <sha256> <member-name>" line per input packages/sources.lock says belongs
in a bundle; sources.lock is the trust root. Exit 0 only when the manifest's components are
exactly those (same versions and SHA-256s), the archive's SHA-256 is the manifest's, the
archive's members are exactly those member names, each once and each a regular file with a flat
name (checked BEFORE anything is extracted), and every extracted file hashes to its lock pin.
Exit 1 with a FATAL line otherwise; on a refusal before extraction nothing is written.
"""
import hashlib
import json
import os
import re
import sys
import tarfile

SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def die(msg):
    print(f"FATAL: bundle-verify: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    archive, manifest_path, dest = sys.argv[1:4]
    expected = {}
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        cid, ref, sha, member = line.split()
        expected[cid] = {"ref": ref, "sha256": sha, "member": member}
    if not expected:
        die("the lock file names no bundleable input")

    try:
        manifest = json.load(open(manifest_path))
        comps = manifest["components"]
        archive_sha = manifest["archive"]["sha256"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        die(f"could not parse the manifest {manifest_path}: {e}")

    # 2. The manifest must say exactly what sources.lock says.
    ids = [c.get("id") for c in comps]
    if len(ids) != len(set(ids)):
        die(f"the manifest lists a component more than once: {sorted(i for i in set(ids) if ids.count(i) > 1)}")
    if set(ids) != set(expected):
        die(f"the manifest's components {sorted(ids)} are not the lock file's bundleable inputs {sorted(expected)}")
    for c in comps:
        e = expected[c["id"]]
        if c.get("version") != e["ref"] or c.get("sha256") != e["sha256"]:
            die(f"the manifest's {c['id']} (version {c.get('version')}, sha256 {c.get('sha256')}) disagrees with "
                f"sources.lock (version {e['ref']}, sha256 {e['sha256']}); the lock file is the trust root")

    # 3. The archive is the one the manifest describes.
    got = sha256(archive)
    if got != archive_sha:
        die(f"archive SHA-256 does not match its own manifest\n  manifest says: {archive_sha}\n  archive is:    {got}\n"
            "The bundle is tampered, truncated, or does not belong with this manifest. Rejected, no override flag.")

    # 4. Members, before any byte is extracted.
    want_members = {e["member"]: cid for cid, e in expected.items()}
    try:
        with tarfile.open(archive) as t:
            members = t.getmembers()
            names = [m.name for m in members]
            bad = [m.name for m in members if not m.isreg() or not SAFE.match(m.name)]
            if bad:
                die(f"the archive has members that are not regular files with flat names: {bad}")
            dups = sorted({n for n in names if names.count(n) > 1})
            if dups:
                die(f"the archive has more than one member named: {dups}")
            if set(names) != set(want_members):
                die(f"the archive's members {sorted(names)} are not the lock file's {sorted(want_members)} "
                    f"(extra: {sorted(set(names) - set(want_members))}, missing: {sorted(set(want_members) - set(names))})")
            os.makedirs(dest, exist_ok=True)
            for m in members:
                src = t.extractfile(m)
                out = os.path.join(dest, m.name)
                with open(out, "wb") as f:
                    for chunk in iter(lambda: src.read(1 << 20), b""):
                        f.write(chunk)
    except tarfile.TarError as e:
        die(f"the archive is not a readable tar: {e}")

    # 5. Every extracted file against its lock pin.
    for member, cid in sorted(want_members.items()):
        h = sha256(os.path.join(dest, member))
        if h != expected[cid]["sha256"]:
            die(f"{member} has SHA-256 {h}, not the {expected[cid]['sha256']} sources.lock pins for {cid}")
        print(f"verified sha256 for {cid} (extracted from bundle): {h}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
