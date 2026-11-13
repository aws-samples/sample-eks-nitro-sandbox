#!/usr/bin/env python3
"""Download and verify the Nitro Sandbox runtime release, the guest image pair and Firecracker
against packages/sources.lock. Called by packages/fetch-runtime-artifacts.sh; sources.lock is the
trust root, and every check fails closed (exit 1, a FATAL line naming what is wrong).

  runtime_verify.py check <lock-file> <work-dir>
      the small public files only, with no large download: for each signed-archive block, the
      committed public key's SHA-256, the manifest's SHA-256, its signature (openssl dgst -sha384
      -verify), and that it lists the archive and every pinned member with the pinned hash; for
      each sidecar-file block, the published sidecar's value against the pin.
  runtime_verify.py fetch <lock-file> <dest-dir>
      everything `check` does, then each archive and file itself: its SHA-256 against the pin;
      every member of each archive checked before anything is read out of it (a signed archive
      must be flat, regular files only; a sidecar-verified archive may hold folders but no
      absolute path, no '..' component, no link or device; no name twice); each pinned member
      read out and checked against its pin. Every file a block installs on the node ends up as
      <dest-dir>/node-files/<block id>, written under a .part name and renamed only once its hash
      passes; the signed manifest and its signature are kept in <dest-dir>/signed-manifest/.
      <dest-dir>/node-files and <dest-dir>/downloads are made fresh on every run. Prints
      <dest-dir>/node-files as its last line.

Downloads use curl (-fsSL, retries), so a reader's proxy settings apply. Needs openssl for the
signature and Python 3.9 or later (the workstation's python3 can be older than the build host's).
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile

HEX64 = re.compile(r"^[0-9a-f]{64}$")
FLAT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
URL = re.compile(r"^(https|file)://[^\s]+$")
KINDS = ("signed-archive", "sidecar-file", "archive-member")


class Refused(Exception):
    pass


def die(msg):
    print(f"FATAL: runtime-verify: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(msg, flush=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def lock_blocks(path):
    """sources.lock as {id: {key: first-line value}}, the rule scripts/lib/common.sh's lock_field uses."""
    blocks, cur = {}, None
    with open(path) as f:
        for line in f.read().splitlines():
            if not line.strip():
                cur = None
                continue
            if line.startswith("#") or line.startswith(" ") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            if key == "id":
                if val in blocks:
                    raise Refused(f"sources.lock has two blocks with id={val}")
                cur = blocks.setdefault(val, {"id": val})
            elif cur is not None:
                cur.setdefault(key, val)
    return blocks


def need(b, key, rx=None):
    v = b.get(key)
    if not v:
        raise Refused(f"sources.lock block {b['id']} has no {key}=")
    if rx is not None and not rx.match(v):
        raise Refused(f"sources.lock block {b['id']} {key}= is not well formed: {v!r}")
    return v


def plan(lock_path):
    """The blocks this helper verifies, each checked for the fields it needs."""
    blocks = lock_blocks(lock_path)
    sel = {i: b for i, b in blocks.items() if b.get("kind") in KINDS}
    if not any(b["kind"] == "signed-archive" for b in sel.values()):
        raise Refused("sources.lock has no signed-archive block (the runtime release)")
    for b in sel.values():
        need(b, "sha256", HEX64)
        if b["kind"] == "archive-member":
            parent = sel.get(need(b, "archive"))
            if parent is None or parent["kind"] == "archive-member":
                raise Refused(f"sources.lock block {b['id']} names archive={b['archive']}, which is not a signed-archive or sidecar-file block")
            need(b, "member")
            if parent["kind"] == "signed-archive":
                need(b, "member", FLAT)
        else:
            need(b, "source", URL)
            need(b, "file", FLAT)
        if b["kind"] == "signed-archive":
            for k in ("manifest", "signature"):
                need(b, k, URL)
            need(b, "manifest_sha256", HEX64)
            need(b, "public_key", FLAT)
            need(b, "public_key_sha256", HEX64)
        if b["kind"] == "sidecar-file":
            need(b, "sidecar", URL)
        inst = b.get("install", "none")
        if inst != "none":
            parts = inst.split()
            if len(parts) != 2 or not parts[0].startswith("/") or not re.match(r"^0[0-7]{3}$", parts[1]):
                raise Refused(f"sources.lock block {b['id']} install= is not '<absolute path> <octal mode>': {inst!r}")
    return sel


def curl(url, out):
    part = out + ".part"
    if os.path.lexists(part):
        os.remove(part)
    r = subprocess.run(["curl", "-fsSL", "--retry", "5", "--retry-delay", "3", "-o", part, url],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if r.returncode != 0:
        if os.path.lexists(part):
            os.remove(part)
        raise Refused(f"could not download {url} (curl exit {r.returncode}): {r.stderr.strip()[:300]}")
    os.replace(part, out)
    return out


def parse_manifest(path):
    sums = {}
    with open(path) as f:
        text = f.read()
    for line in text.splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        if m is None:
            raise Refused(f"the signed manifest has a line that is not '<sha256>  <file name>': {line!r}")
        if m.group(2) in sums:
            raise Refused(f"the signed manifest lists {m.group(2)} twice")
        sums[m.group(2)] = m.group(1)
    if not sums:
        raise Refused("the signed manifest is empty")
    return sums


def check_signed(b, members, lock_dir, work):
    """Key, manifest hash, signature and the manifest's lines for the pinned files. Returns the manifest path."""
    key = os.path.join(lock_dir, b["public_key"])
    if not os.path.isfile(key):
        raise Refused(f"the public key {b['public_key']} is not beside sources.lock ({key})")
    got = sha256(key)
    if got != b["public_key_sha256"]:
        raise Refused(f"the public key {b['public_key']} has SHA-256 {got}, not the {b['public_key_sha256']} sources.lock pins")
    man = curl(b["manifest"], os.path.join(work, f"{b['id']}.SHA256SUM"))
    sig = curl(b["signature"], os.path.join(work, f"{b['id']}.SHA256SUM.sig"))
    got = sha256(man)
    if got != b["manifest_sha256"]:
        raise Refused(f"the manifest {b['manifest']} has SHA-256 {got}, not the {b['manifest_sha256']} sources.lock pins")
    r = subprocess.run(["openssl", "dgst", "-sha384", "-verify", key, "-signature", sig, man],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if r.returncode != 0 or r.stdout.strip() != "Verified OK":
        raise Refused(f"the signature over {b['manifest']} does not verify with {b['public_key']}: "
                      f"{(r.stdout.strip() or r.stderr.strip())[:200]!r} (exit {r.returncode})")
    sums = parse_manifest(man)
    for name, want in [(b["file"], b["sha256"])] + [(m["member"], m["sha256"]) for m in members]:
        if sums.get(name) != want:
            raise Refused(f"the signed manifest lists {name} as {sums.get(name, '<absent>')}, not the {want} sources.lock pins")
    log(f"ok: {b['id']} {b['ref']}: signature Verified OK with {b['public_key']}; the manifest lists "
        f"{b['file']} and {len(members)} pinned member(s) with their pinned SHA-256")
    return man, sig


def check_sidecar(b, work):
    side = curl(b["sidecar"], os.path.join(work, f"{b['id']}.sidecar"))
    with open(side) as f:
        fields = f.read().split()
    value = fields[0] if fields else ""
    if not HEX64.match(value):
        raise Refused(f"the sidecar {b['sidecar']} does not start with a SHA-256: {value[:80]!r}")
    if value != b["sha256"]:
        raise Refused(f"the sidecar {b['sidecar']} says {value}, not the {b['sha256']} sources.lock pins for {b['file']}")
    log(f"ok: {b['id']} {b['ref']}: its published sidecar matches the pin")


def safe_member(name, flat):
    if flat:
        return FLAT.match(name) is not None
    if name.startswith("/") or "\\" in name:
        return False
    parts = [p for p in name.split("/") if p not in ("", ".")]
    return bool(parts) and ".." not in parts


def read_members(archive, flat, wanted, out_dir):
    """Check every member, then write each wanted member ({member: (block id, sha256)}) out."""
    try:
        with tarfile.open(archive, "r:gz") as t:
            infos = t.getmembers()
            names = [os.path.normpath(i.name) for i in infos]
            bad = [i.name for i in infos
                   if not safe_member(i.name, flat) or not (i.isreg() or (i.isdir() and not flat))]
            if bad:
                raise Refused(f"{os.path.basename(archive)} has members that are not "
                              f"{'regular files with flat names' if flat else 'regular files or folders inside it'}: {bad[:5]}")
            dups = sorted({n for n in names if names.count(n) > 1})
            if dups:
                raise Refused(f"{os.path.basename(archive)} has more than one member named: {dups[:5]}")
            by_name = {os.path.normpath(i.name): i for i in infos}
            for member, (bid, want) in sorted(wanted.items()):
                info = by_name.get(os.path.normpath(member))
                if info is None or not info.isreg():
                    raise Refused(f"{os.path.basename(archive)} has no regular file {member} (sources.lock block {bid})")
                dest = os.path.join(out_dir, bid)
                part = dest + ".part"
                src = t.extractfile(info)
                h = hashlib.sha256()
                with open(part, "wb") as f:
                    for chunk in iter(lambda: src.read(1 << 20), b""):
                        h.update(chunk)
                        f.write(chunk)
                if h.hexdigest() != want:
                    os.remove(part)
                    raise Refused(f"{member} in {os.path.basename(archive)} has SHA-256 {h.hexdigest()}, not the {want} sources.lock pins for {bid}")
                os.replace(part, dest)
                log(f"ok: {bid}: {member} read from {os.path.basename(archive)}, SHA-256 matches its pin")
    except (tarfile.TarError, OSError, EOFError) as e:
        raise Refused(f"{os.path.basename(archive)} is not a readable gzip tar: {e}")


def main(argv):
    if len(argv) != 4 or argv[1] not in ("check", "fetch"):
        print(__doc__, file=sys.stderr)
        return 2
    mode, lock_path, dest = argv[1], os.path.abspath(argv[2]), os.path.abspath(argv[3])
    try:
        sel = plan(lock_path)
        lock_dir = os.path.dirname(lock_path)
        work = os.path.join(dest, "metadata") if mode == "check" else os.path.join(dest, "downloads")
        node = os.path.join(dest, "node-files")
        for d in ([work] if mode == "check" else [work, node]):
            if os.path.lexists(d):
                shutil.rmtree(d)
            os.makedirs(d)
        children = {}
        for b in sel.values():
            if b["kind"] == "archive-member":
                children.setdefault(b["archive"], []).append(b)
        kept = []
        for b in sel.values():
            if b["kind"] == "signed-archive":
                kept.append((b, check_signed(b, children.get(b["id"], []), lock_dir, work)))
            elif b["kind"] == "sidecar-file":
                check_sidecar(b, work)
        if mode == "check":
            log(f"runtime inputs checked against sources.lock with no large download: "
                f"{sum(1 for b in sel.values() if b['kind'] != 'archive-member')} published inputs")
            return 0
        for b in sel.values():
            if b["kind"] == "archive-member":
                continue
            path = curl(b["source"], os.path.join(work, b["file"]))
            got = sha256(path)
            if got != b["sha256"]:
                os.remove(path)
                raise Refused(f"{b['file']} from {b['source']} has SHA-256 {got}, not the {b['sha256']} sources.lock pins")
            log(f"ok: {b['id']} {b['ref']}: {b['file']} SHA-256 matches its pin")
            kids = children.get(b["id"], [])
            if kids:
                read_members(path, b["kind"] == "signed-archive",
                             {k["member"]: (k["id"], k["sha256"]) for k in kids}, node)
            if b.get("install", "none") != "none":
                os.replace(path, os.path.join(node, b["id"]))
        kd = os.path.join(dest, "signed-manifest")
        if os.path.lexists(kd):
            shutil.rmtree(kd)
        os.makedirs(kd)
        for b, (man, sig) in kept:
            shutil.copyfile(man, os.path.join(kd, f"{b['id']}.SHA256SUM"))
            shutil.copyfile(sig, os.path.join(kd, f"{b['id']}.SHA256SUM.sig"))
        want = sorted(b["id"] for b in sel.values() if b.get("install", "none") != "none")
        have = sorted(os.listdir(node))
        if have != want:
            raise Refused(f"node-files holds {have}, not the installable blocks {want}")
        log(f"runtime inputs verified against sources.lock: {len(want)} node files in {node}")
        print(node)
        return 0
    except Refused as e:
        die(str(e))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
