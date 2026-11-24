#!/usr/bin/env python3
"""register-variant.py: add the aws-k8s-1.36-nitro-sandbox variant to a Bottlerocket clone.

  register-variant.py apply --clone C --overlay V --lock L --slots N
  register-variant.py check-lock <Cargo.lock before> <Cargo.lock after>

apply, in this order, and it stops at the first refusal:
  1. The clone is at the tag and commit of the bottlerocket-source block in L, and is clean.
  2. The stock variants/aws-k8s-1.36/Cargo.toml with the four edits below must equal the
     tracked V/variants/aws-k8s-1.36-nitro-sandbox/Cargo.toml, byte for byte. The edits are the
     name, the nitro-sandbox package, os-image-size-gib and the mempool kernel parameter.
  3. The external-files SHA-512 values of V/packages/nitro-sandbox/Cargo.toml equal L.
  4. It writes the variant (with the stock amispec.toml link) and the package, with
     pcie_slots = N in nitro-sandbox.toml.
  5. It applies each registration below; each one must match exactly the given number of times.
The settings-defaults and settings-plugins packages of aws-k8s-1.36 also serve the new variant,
as they serve aws-k8s-1.36-fips, so the variant needs no settings-defaults crate of its own.
check-lock: the after file must hold the before file's packages unchanged, plus exactly the
two new path crates. Exit 0 accepted; 1 refused; 2 a read failed. Refusals: ERROR: E_<TAG>: ...
"""
import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True

BASE = "aws-k8s-1.36"
NEW = "aws-k8s-1.36-nitro-sandbox"
PKG = "nitro-sandbox"
VARIANT_CRATE = "aws-k8s-1_36-nitro-sandbox"


class Refused(Exception):
    def __init__(self, tag, text, code=1):
        super().__init__(f"ERROR: {tag}: {text}")
        self.code = code


def need(cond, tag, text, code=1):
    if not cond:
        raise Refused(tag, text, code)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise Refused("E_READ", f"{path}: {e.strerror}", 2)


def write(path, text):
    with open(path, "x", encoding="utf-8") as f:
        f.write(text)


def replace(text, old, new, count, where):
    n = text.count(old)
    need(n == count, "E_EDIT", f"{where}: expected {count} match(es) of {old.splitlines()[0]!r}, found {n}")
    return text.replace(old, new)


def variant_edits(os_gib):
    """The four edits from the stock variant. Each must match exactly once."""
    return [
        (f'# This is the {BASE} variant.', f'# This is the {NEW} variant.'),
        ('name = "aws-k8s-1_36"\n', f'name = "{VARIANT_CRATE}"\n'),
        ("external-kmod-development = false\n\n",
         "external-kmod-development = false\n\n"
         "# Twoliter gives ROOT-A 460 MiB for each GiB of this value: 4 gives 1,840 MiB. A measured build\n"
         "# used 479,363,072 bytes of ROOT-A (about 25 percent of 1,840 MiB).\n"
         "[package.metadata.build-variant.image-layout]\n"
         f"os-image-size-gib = {os_gib}\n\n"),
        ('    "thar-be-image-verifiers",\n]\n',
         '    "thar-be-image-verifiers",\n# nitro sandbox\n    "nitro-sandbox",\n]\n'),
        ('    "quiet",\n]\n', '    "quiet",\n    "nitro_enclaves.mempool=95%-1G",\n]\n'),
        ('settings-migrations = { path = "../../packages/settings-migrations" }\n',
         'settings-migrations = { path = "../../packages/settings-migrations" }\n'
         'nitro-sandbox = { path = "../../packages/nitro-sandbox" }\n'),
    ]


REGISTRATIONS = [
    ("Cargo.toml", f'    "variants/{BASE}",\n', f'    "variants/{BASE}",\n    "variants/{NEW}",\n', 1),
    ("Cargo.toml", '    "packages/settings-plugins",\n',
     f'    "packages/settings-plugins",\n    "packages/{PKG}",\n', 1),
    ("packages/settings-defaults/settings-defaults.spec",
     f"           %{{_cross_os}}variant({BASE}-fips)\n           %{{nil}}}})\n"
     f"Provides: %{{_cross_os}}settings-defaults(any)\n"
     f"Provides: %{{_cross_os}}settings-defaults({BASE})\n"
     f"Provides: %{{_cross_os}}settings-defaults({BASE}-fips)\n",
     f"           %{{_cross_os}}variant({BASE}-fips) or\n"
     f"           %{{_cross_os}}variant({NEW})\n           %{{nil}}}})\n"
     f"Provides: %{{_cross_os}}settings-defaults(any)\n"
     f"Provides: %{{_cross_os}}settings-defaults({BASE})\n"
     f"Provides: %{{_cross_os}}settings-defaults({BASE}-fips)\n"
     f"Provides: %{{_cross_os}}settings-defaults({NEW})\n", 1),
    ("packages/settings-plugins/settings-plugins.spec",
     f"Provides: %{{_cross_os}}settings-plugin({BASE}-fips)\n",
     f"Provides: %{{_cross_os}}settings-plugin({BASE}-fips)\n"
     f"Provides: %{{_cross_os}}settings-plugin({NEW})\n", 1),
    ("README.md", f"* `{BASE}`\n", f"* `{BASE}`\n* `{NEW}`\n", 1),
]


def lock_blocks(path):
    blocks = {}
    for block in [b for b in read(path).split("\n\n") if b.strip()]:
        lines = block.strip().splitlines()
        if lines[0].strip() != "[[package]]":
            continue
        name = next((ln for ln in lines if ln.startswith("name = ")), None)
        need(name is not None, "E_LOCK_FILE", f"{path}: a package block has no name", 2)
        blocks[name[7:].strip('"')] = "\n".join(lines)
    return blocks


def git(clone, *args):
    r = subprocess.run(["git", "-C", clone] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    need(r.returncode == 0, "E_GIT", f"git {' '.join(args)} failed", 2)
    return r.stdout.strip()


def source_block(lock_path):
    text = read(lock_path)
    for block in text.split("\n\n"):
        kv = dict(ln.split("=", 1) for ln in block.splitlines() if re.match(r"^[a-z_0-9]+=", ln))
        if kv.get("id") == "bottlerocket-source":
            for k in ("ref", "commit", "tag_object", "base_variant"):
                need(re.fullmatch(r"[0-9A-Za-z._-]+", kv.get(k, "")) is not None, "E_LOCK_FILE", f"bottlerocket-source has no {k}")
            return kv
    raise Refused("E_LOCK_FILE", "no bottlerocket-source block")


def external_files(cargo_text):
    out = {}
    for block in cargo_text.split("[[package.metadata.build-package.external-files]]")[1:]:
        p = re.search(r'^path = "([^"]+)"$', block, re.M)
        s = re.search(r'^sha512 = "([0-9a-f]{128})"(?:  # pragma: allowlist secret)?$', block, re.M)
        need(p is not None and s is not None, "E_PACKAGE_FILES", "an external-files entry has no path or sha512")
        out[p.group(1)] = s.group(1)
    return out


def lock_sha512(lock_path):
    out = {}
    for block in read(lock_path).split("\n\n"):
        kv = dict(ln.split("=", 1) for ln in block.splitlines() if re.match(r"^[a-z_0-9]+=", ln))
        if "file" in kv and "sha512" in kv:
            out[kv["file"]] = kv["sha512"]
    return out


def cmd_apply(a):
    need(re.fullmatch(r"[1-9][0-9]{0,2}", a.slots or "") is not None and 1 <= int(a.slots) <= 250,
         "E_INPUT_SANDBOX_SLOTS", f"--slots must be an integer from 1 to 250, got {a.slots!r}")
    src = source_block(a.lock)
    need(src["base_variant"] == BASE, "E_LOCK_FILE", f"base_variant is {src['base_variant']}, not {BASE}")
    c = a.clone
    need(git(c, "rev-parse", "HEAD") == src["commit"], "E_CLONE_COMMIT", f"the clone is not at {src['commit']}")
    need(git(c, "rev-parse", f"refs/tags/{src['ref']}") == src["tag_object"], "E_CLONE_TAG",
         f"tag {src['ref']} is not the pinned tag object")
    need(git(c, "status", "--porcelain") == "", "E_CLONE_DIRTY", "the clone has changes before the overlay")

    tracked_path = os.path.join(a.overlay, "variants", NEW, "Cargo.toml")
    tracked = read(tracked_path)
    sizes = re.findall(r"^os-image-size-gib = ([0-9]+)$", tracked, re.M)
    need(len(sizes) == 1, "E_VARIANT_DIFF", "the tracked variant must set os-image-size-gib exactly once")
    stock_path = os.path.join(c, "variants", BASE, "Cargo.toml")
    made = read(stock_path)
    for old, new in variant_edits(sizes[0]):
        made = replace(made, old, new, 1, stock_path)
    need(made == tracked, "E_VARIANT_DIFF",
         f"the stock {BASE} Cargo.toml with the four edits is not the tracked {NEW} Cargo.toml")

    pkg_src = os.path.join(a.overlay, "packages", PKG)
    ext = external_files(read(os.path.join(pkg_src, "Cargo.toml")))
    pinned = lock_sha512(a.lock)
    need(len(ext) == 4 and all(pinned.get(k) == v for k, v in ext.items()), "E_PACKAGE_FILES",
         "the package external-files SHA-512 values are not those of sources.lock")

    vdir = os.path.join(c, "variants", NEW)
    pdir = os.path.join(c, "packages", PKG)
    need(not os.path.lexists(vdir) and not os.path.lexists(pdir), "E_CLONE_DIRTY", "the variant or the package exists")
    os.mkdir(vdir)
    write(os.path.join(vdir, "Cargo.toml"), tracked)
    os.symlink(os.readlink(os.path.join(c, "variants", BASE, "amispec.toml")), os.path.join(vdir, "amispec.toml"))
    os.mkdir(pdir)
    for name in sorted(os.listdir(pkg_src)):
        s = os.path.join(pkg_src, name)
        need(os.path.isfile(s) and not os.path.islink(s), "E_PACKAGE_FILES", f"{name} is not a regular file")
        if name == "nitro-sandbox.toml":
            t = replace(read(s), "pcie_slots      = @SANDBOX_SLOTS@\n", f"pcie_slots      = {a.slots}\n", 1, name)
            need("@" not in t, "E_PACKAGE_FILES", f"{name} still has a template value")
            write(os.path.join(pdir, name), t)
        else:
            shutil.copyfile(s, os.path.join(pdir, name))

    for rel, old, new, count in REGISTRATIONS:
        p = os.path.join(c, rel)
        text = replace(read(p), old, new, count, rel)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)

    diff = difflib.unified_diff(read(stock_path).splitlines(True), tracked.splitlines(True),
                                f"variants/{BASE}/Cargo.toml", f"variants/{NEW}/Cargo.toml")
    sys.stdout.write("".join(diff))
    print(f"register-variant variant={NEW} slots={a.slots} os_image_gib={sizes[0]} registrations={len(REGISTRATIONS)} ok")


def other_blocks(path):
    """The header and any block that is not a [[package]] (for example the lockfile version)."""
    return [b.strip() for b in read(path).split("\n\n") if b.strip() and not b.strip().startswith("[[package]]")]


def cmd_check_lock(a):
    need(other_blocks(a.before) == other_blocks(a.after), "E_LOCK_CHANGED", "the Cargo.lock header or version changed")
    before, after = lock_blocks(a.before), lock_blocks(a.after)
    for name, block in before.items():
        need(after.get(name) == block, "E_LOCK_CHANGED", f"Cargo.lock changed the package {name}")
    added = sorted(set(after) - set(before))
    need(added == sorted([VARIANT_CRATE, PKG]), "E_LOCK_CHANGED", f"Cargo.lock added {added}")
    need(not re.search(r"^source = ", after[VARIANT_CRATE] + after[PKG], re.M), "E_LOCK_CHANGED",
         "a new crate has a registry source")
    print(f"register-variant cargo-lock added={','.join(added)} ok")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("apply")
    for k in ("--clone", "--overlay", "--lock", "--slots"):
        p.add_argument(k, required=True)
    p = sp.add_parser("check-lock")
    p.add_argument("before")
    p.add_argument("after")
    a = ap.parse_args()
    try:
        {"apply": cmd_apply, "check-lock": cmd_check_lock}[a.cmd](a)
    except Refused as e:
        print(str(e), file=sys.stderr)
        return e.code
    except OSError as e:
        print(f"ERROR: E_READ: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
