#!/usr/bin/env python3
"""runtime_verify.py: download and verify the inputs that packages/sources.lock pins.

  runtime_verify.py fetch <lock> <dir>   download every file block into <dir>, then check
  runtime_verify.py check <lock> <dir>   check the files that are already in <dir>
  runtime_verify.py field <lock> <id> <key>   print one value of one block
  runtime_verify.py installed <lock> <root>   each install= file under <root> has its sha256

<lock> "-" means ${CB_SOURCES_LOCK:-packages/sources.lock}. The checks, all fail closed:
  - the public key file (beside the lock) has public_key_sha256;
  - the downloaded SHA256SUM has manifest_sha256 and a good ECDSA P-384 signature
    (openssl dgst -sha384 -verify), and its line for the archive equals sha256=;
  - each downloaded file has its sha256= and sha512=; a sidecar file names the same sha256=;
  - each archive member is one regular file at member=, with its sha256= (and, for a signed
    archive, the same value in the signed SHA256SUM).
Layout of <dir>: <file>, <id>.SHA256SUM, <id>.SHA256SUM.sig, <id>.sidecar, members/<id>.
Exit 0 all good; 1 a value does not match; 2 a download or a read failed.
Each refusal prints one line: ERROR: E_<TAG>: <text>.
"""
import hashlib
import os
import re
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True

KINDS = {
    "git-tag": ("commit", "tag_object"),
    "signed-archive": ("file", "sha256", "sha512", "manifest", "manifest_sha256", "signature",
                       "public_key", "public_key_sha256"),
    "sidecar-file": ("file", "sha256", "sha512", "sidecar"),
    "archive-member": ("archive", "member", "sha256"),
}
REQUIRED = ("id", "kind", "ref", "source", "status")
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX128 = re.compile(r"[0-9a-f]{128}")
URL = re.compile(r"(https|file)://[^\s'\"]+")


class Refused(Exception):
    def __init__(self, tag, text, code=1):
        super().__init__(f"ERROR: {tag}: {text}")
        self.code = code


def need(cond, tag, text, code=1):
    if not cond:
        raise Refused(tag, text, code)


def parse_lock(path):
    """Blocks of key=value lines. An indented line continues the value before it."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError as e:
        raise Refused("E_LOCK_READ", f"{path}: {e.strerror}", 2)
    blocks, cur, last = [], {}, None
    for n, line in enumerate(lines, 1):
        if line.startswith("#"):
            continue
        if not line.strip():
            if cur:
                blocks.append(cur)
            cur, last = {}, None
            continue
        if line[0] in " \t":
            need(last is not None, "E_LOCK_FORMAT", f"line {n}: a continuation with no key")
            cur[last] += " " + line.strip()
            continue
        m = re.fullmatch(r"([a-z_0-9]+)=(.*)", line)
        need(m is not None, "E_LOCK_FORMAT", f"line {n}: not key=value")
        k, v = m.group(1), m.group(2)
        need(k not in cur, "E_LOCK_DUPLICATE_KEY", f"line {n}: {k} twice in one block")
        cur[k], last = v, k
    if cur:
        blocks.append(cur)
    ids = {}
    for b in blocks:
        for k in REQUIRED:
            need(b.get(k), "E_LOCK_FORMAT", f"a block has no {k}")
        need(b["kind"] in KINDS, "E_LOCK_KIND", f"{b['id']}: unknown kind {b['kind']}")
        for k in KINDS[b["kind"]]:
            need(b.get(k), "E_LOCK_FORMAT", f"{b['id']}: {k} is missing")
        need(b["id"] not in ids, "E_LOCK_DUPLICATE_ID", f"{b['id']} twice")
        for k in ("sha256", "manifest_sha256", "public_key_sha256"):
            if k in b:
                need(HEX64.fullmatch(b[k]) is not None, "E_LOCK_FORMAT", f"{b['id']}: {k} is not 64 hex")
        if "sha512" in b:
            need(HEX128.fullmatch(b["sha512"]) is not None, "E_LOCK_FORMAT", f"{b['id']}: sha512 is not 128 hex")
        if "file" in b:
            need(re.fullmatch(r"[A-Za-z0-9._-]+", b["file"]) is not None, "E_LOCK_FORMAT", f"{b['id']}: bad file name")
        ids[b["id"]] = b
    for b in blocks:
        if b["kind"] == "archive-member":
            need(b["archive"] in ids and ids[b["archive"]]["kind"] in ("signed-archive", "sidecar-file"),
                 "E_LOCK_FORMAT", f"{b['id']}: archive {b['archive']} is not a file block")
    return ids


def digest(path, algo):
    h = hashlib.new(algo)
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError as e:
        raise Refused("E_READ", f"{path}: {e.strerror}", 2)
    return h.hexdigest()


def download(url, out):
    need(URL.fullmatch(url) is not None, "E_LOCK_FORMAT", f"not an https or file URL: {url}")
    tmp = out + ".part"
    r = subprocess.run(["curl", "-fsSL", "--proto", "=https,file", "--max-time", "1800",
                        "-o", tmp, url], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    need(r.returncode == 0, "E_DOWNLOAD", f"{url} (curl exit {r.returncode})", 2)
    os.replace(tmp, out)


def fetch(lock, d):
    os.makedirs(d, mode=0o700, exist_ok=True)
    for b in lock.values():
        if b["kind"] == "signed-archive":
            download(b["manifest"], os.path.join(d, b["id"] + ".SHA256SUM"))
            download(b["signature"], os.path.join(d, b["id"] + ".SHA256SUM.sig"))
        elif b["kind"] == "sidecar-file":
            download(b["sidecar"], os.path.join(d, b["id"] + ".sidecar"))
        else:
            continue
        download(b["source"], os.path.join(d, b["file"]))


def manifest_lines(path):
    """sha256sum format: '<hex>  <name>'. A name listed twice is refused."""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise Refused("E_READ", f"{path}: {e.strerror}", 2)
    for line in text.splitlines():
        if not line.strip():
            continue
        m = re.fullmatch(r"([0-9a-f]{64}) [ *](?:\./)?([^/\s]+)", line.strip())
        need(m is not None, "E_MANIFEST_FORMAT", f"{os.path.basename(path)}: a line is not '<sha256>  <name>'")
        need(m.group(2) not in out, "E_MANIFEST_FORMAT", f"{m.group(2)} listed twice")
        out[m.group(2)] = m.group(1)
    return out


def check_file(b, d):
    p = os.path.join(d, b["file"])
    need(os.path.isfile(p) and not os.path.islink(p), "E_READ", f"{b['id']}: {b['file']} is missing", 2)
    got = digest(p, "sha256")
    need(got == b["sha256"], "E_FILE_SHA256", f"{b['id']}: {b['file']} has sha256 {got}, the lock has {b['sha256']}")
    got = digest(p, "sha512")
    need(got == b["sha512"], "E_FILE_SHA512", f"{b['id']}: {b['file']} sha512 does not match the lock")
    return p


def check_signed(b, d, lock_dir):
    key = os.path.join(lock_dir, b["public_key"])
    need(os.path.isfile(key), "E_READ", f"{b['id']}: public key {b['public_key']} is missing", 2)
    need(digest(key, "sha256") == b["public_key_sha256"], "E_KEY_SHA256", f"{b['id']}: the public key is not the pinned key")
    man = os.path.join(d, b["id"] + ".SHA256SUM")
    sig = man + ".sig"
    need(os.path.isfile(man) and os.path.isfile(sig), "E_READ", f"{b['id']}: SHA256SUM or its signature is missing", 2)
    r = subprocess.run(["openssl", "dgst", "-sha384", "-verify", key, "-signature", sig, man],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    need(r.returncode == 0 and r.stdout.strip() == b"Verified OK", "E_SIGNATURE",
         f"{b['id']}: SHA256SUM has no good signature from {b['public_key']}")
    need(digest(man, "sha256") == b["manifest_sha256"], "E_MANIFEST_SHA256",
         f"{b['id']}: the signed SHA256SUM is not the pinned one")
    lines = manifest_lines(man)
    need(lines.get(b["file"]) == b["sha256"], "E_ARCHIVE_SHA256",
         f"{b['id']}: the signed SHA256SUM does not list {b['file']} with the pinned sha256")
    check_file(b, d)
    return lines


def check_sidecar(b, d):
    sc = os.path.join(d, b["id"] + ".sidecar")
    try:
        with open(sc, encoding="utf-8") as f:
            words = f.read().split()
    except OSError as e:
        raise Refused("E_READ", f"{b['id']}: sidecar: {e.strerror}", 2)
    need(len(words) >= 1 and words[0] == b["sha256"], "E_SIDECAR", f"{b['id']}: the sidecar names another sha256")
    check_file(b, d)


def check_member(b, archive_path, d, signed_lines):
    out_dir = os.path.join(d, "members")
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    try:
        with tarfile.open(archive_path, "r:*") as t:
            found = [m for m in t.getmembers() if m.name.lstrip("./") == b["member"]]
            need(len(found) == 1 and found[0].isreg(), "E_MEMBER", f"{b['id']}: {b['member']} is not one regular file")
            src = t.extractfile(found[0])
            out = os.path.join(out_dir, b["id"])
            with open(out, "wb") as f:
                f.write(src.read())
    except (OSError, tarfile.TarError) as e:
        raise Refused("E_READ", f"{b['id']}: {e}", 2)
    got = digest(out, "sha256")
    need(got == b["sha256"], "E_MEMBER_SHA256", f"{b['id']}: {b['member']} has sha256 {got}, the lock has {b['sha256']}")
    if signed_lines is not None:
        need(signed_lines.get(os.path.basename(b["member"])) == b["sha256"], "E_MEMBER_SHA256",
             f"{b['id']}: the signed SHA256SUM lists another sha256 for {b['member']}")


def check(lock, lock_dir, d):
    signed = {}
    for b in lock.values():
        if b["kind"] == "signed-archive":
            signed[b["id"]] = check_signed(b, d, lock_dir)
        elif b["kind"] == "sidecar-file":
            check_sidecar(b, d)
        else:
            continue
        print(f"runtime-verify {b['id']} {b['ref']} sha256={b['sha256']} ok")
    for b in lock.values():
        if b["kind"] == "archive-member":
            a = lock[b["archive"]]
            check_member(b, os.path.join(d, a["file"]), d, signed.get(a["id"]))
            print(f"runtime-verify {b['id']} {b['ref']} sha256={b['sha256']} ok")
    print("runtime-verify all inputs verified")


def installed(lock, root):
    """Every block with install=<path> <mode>: <root><path> is a regular file with that mode
    and the pinned sha256. Used on the written root volume before the AMI is registered."""
    n = 0
    for b in lock.values():
        spec = b.get("install", "none")
        if spec == "none":
            continue
        m = re.fullmatch(r"(/usr/[A-Za-z0-9._/-]+) (0[0-7]{3})", spec)
        need(m is not None and "/../" not in m.group(1) + "/", "E_LOCK_FORMAT", f"{b['id']}: bad install= {spec!r}")
        p = root.rstrip("/") + m.group(1)
        need(os.path.isfile(p) and not os.path.islink(p), "E_INSTALLED", f"{b['id']}: {m.group(1)} is not on the image")
        mode = oct(os.stat(p).st_mode & 0o7777)[2:].rjust(4, "0")
        need(mode == m.group(2), "E_INSTALLED", f"{b['id']}: {m.group(1)} has mode {mode}, not {m.group(2)}")
        got = digest(p, "sha256")
        need(got == b["sha256"], "E_INSTALLED_SHA256", f"{b['id']}: {m.group(1)} has sha256 {got}, the lock has {b['sha256']}")
        print(f"runtime-verify installed {m.group(1)} mode={mode} sha256={got} ok")
        n += 1
    need(n > 0, "E_INSTALLED", "the lock names no installed file")


def main(argv):
    if len(argv) < 3 or argv[0] not in ("fetch", "check", "field", "installed"):
        print(__doc__, file=sys.stderr)
        return 2
    path = argv[1]
    if path == "-":
        path = os.environ.get("CB_SOURCES_LOCK") or os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources.lock")
    try:
        lock = parse_lock(path)
        if argv[0] == "field":
            need(len(argv) == 4 and argv[2] in lock and argv[3] in lock[argv[2]], "E_LOCK_FIELD",
                 f"no {argv[3] if len(argv) == 4 else '?'} in block {argv[2]}")
            print(lock[argv[2]][argv[3]])
            return 0
        need(len(argv) == 3, "E_ARGS", "fetch, check and installed take <lock> <dir>")
        if argv[0] == "installed":
            installed(lock, argv[2])
            return 0
        if argv[0] == "fetch":
            fetch(lock, argv[2])
        check(lock, os.path.dirname(os.path.abspath(path)), argv[2])
    except Refused as e:
        print(str(e), file=sys.stderr)
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
