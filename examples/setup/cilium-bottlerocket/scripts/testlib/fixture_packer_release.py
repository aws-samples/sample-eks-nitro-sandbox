#!/usr/bin/env python3
"""A fixture HashiCorp release of Packer and the Amazon plugin, for the offline tests only.

    fixture_packer_release.py <out-dir> <tools-lock-out> [<case>]

It writes, under <out-dir>/releases/ in the releases.hashicorp.com layout:
  packer/<v>/packer_<v>_linux_amd64.zip               holds `packer`: a launcher for fake_packer.py
  packer/<v>/packer_<v>_SHA256SUMS (+ .sig)           GPG detached signature by a test key
  packer-plugin-amazon/<p>/packer-plugin-amazon_<p>_linux_amd64.zip
                                                      holds packer-plugin-amazon_v<p>_x5.0_linux_amd64
  packer-plugin-amazon/<p>/packer-plugin-amazon_<p>_SHA256SUMS (+ .sig)
and <out-dir>/hashicorp-test-key.asc, the test key's public half, and a tools lock in the
packer/tools.lock shape whose URLs are file:// and whose
HASHICORP_KEY_FPR is the test key's fingerprint. The non-Packer keys of the lock are copied from
the real packer/tools.lock when it exists, because the workstation never downloads them.

The launcher bakes in FAKE_STATE, FAKE_LOG, the stub folder and the narrowed PATH of the suite,
because scripts/10-build-ami-packer.sh runs Packer under `env -i`. It also sets the AWS CLI config and credentials
files to /dev/null, so a shell-local stage that the wrapper starts can never reach a real account.

<case> changes one thing: good, bad-sig (signed by another key), zip-swapped (the zip served is
not the one SHA256SUMS lists), lock-digest (the lock pins another zip SHA-256), wrong-version
(the zip's packer prints another version), wrong-fingerprint (the lock pins another signer).
"""
import hashlib
import io
import os
import shutil
import sys
import zipfile

PACKER_VERSION = "1.16.2"
PLUGIN_VERSION = "1.8.4"
CASES = ("good", "bad-sig", "zip-swapped", "lock-digest", "plugin-digest", "wrong-version", "wrong-fingerprint",
         "no-plugin-binary", "no-packer-binary")


def sha(b):
    return hashlib.sha256(b).hexdigest()


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from openpgp_fixture import Key  # noqa: E402


def zip_one(name, data):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o100755 << 16
        z.writestr(info, data)
    return buf.getvalue()


def launcher(testlib, python, version_note):
    env = {k: os.environ.get(k, "") for k in ("FAKE_STATE", "FAKE_LOG", "FAKE_TESTLIB")}
    path = os.environ.get("PATH", "")
    return (f"#!{python}\n"
            "# Fixture `packer` for the offline tests: runs scripts/testlib/fake_packer.py.\n"
            f"# {version_note}\n"
            "import os, runpy, sys\n"
            f"for k, v in {env!r}.items():\n"
            "    os.environ.setdefault(k, v)\n"
            f"os.environ['PATH'] = {path!r}\n"
            "os.environ['AWS_CONFIG_FILE'] = '/dev/null'\n"
            "os.environ['AWS_SHARED_CREDENTIALS_FILE'] = '/dev/null'\n"
            "os.environ['AWS_EC2_METADATA_DISABLED'] = 'true'\n"
            + (b"os.environ['FAKE_PACKER_VERSION'] = '1.16.1'\n".decode() if "wrong-version" in version_note else "") +
            f"sys.argv[0] = {os.path.join(testlib, 'fake_packer.py')!r}\n"
            f"runpy.run_path({os.path.join(testlib, 'fake_packer.py')!r}, run_name='__main__')\n").encode()


def main(out, lock_out, case="good"):
    if case not in CASES:
        sys.exit(f"fixture_packer_release.py: unknown case {case}")
    testlib = os.path.dirname(os.path.abspath(__file__))
    rel = os.path.join(out, "releases")
    if os.path.isdir(rel):
        shutil.rmtree(rel)
    pdir = os.path.join(rel, "packer", PACKER_VERSION)
    adir = os.path.join(rel, "packer-plugin-amazon", PLUGIN_VERSION)
    os.makedirs(pdir)
    os.makedirs(adir)
    key = Key("Fixture HashiCorp Release Key <fixture-signer@example.invalid>")
    other = Key("Another Signer <another-signer@example.invalid>")
    fpr = key.fingerprint
    with open(os.path.join(out, "hashicorp-test-key.asc"), "wb") as f:
        f.write(key.public_armored())
    with open(os.path.join(out, "another-signer-key.asc"), "wb") as f:
        f.write(other.public_armored())

    pz_name = f"packer_{PACKER_VERSION}_linux_amd64.zip"
    az_name = f"packer-plugin-amazon_{PLUGIN_VERSION}_linux_amd64.zip"
    note = "prints the version that the world state names" if case != "wrong-version" else "a wrong-version case"
    pz = zip_one("packer" if case != "no-packer-binary" else "README", launcher(testlib, sys.executable, note))
    plugin_name = f"packer-plugin-amazon_v{PLUGIN_VERSION}_x5.0_linux_amd64" if case != "no-plugin-binary" else "README"
    az = zip_one(plugin_name, b"#!/bin/sh\necho fixture plugin\n")
    sums = {pdir: (f"packer_{PACKER_VERSION}_SHA256SUMS", [(pz_name, pz)]),
            adir: (f"packer-plugin-amazon_{PLUGIN_VERSION}_SHA256SUMS", [(az_name, az)])}
    for d, (sums_name, files) in sums.items():
        for name, data in files:
            served = data if case != "zip-swapped" else zip_one("packer", b"#!/bin/sh\necho swapped\n")
            with open(os.path.join(d, name), "wb") as f:
                f.write(served)
        body = "".join(f"{sha(data)}  {name}\n" for name, data in files).encode()
        with open(os.path.join(d, sums_name), "wb") as f:
            f.write(body)
        signer = other if case == "bad-sig" else key
        with open(os.path.join(d, sums_name + ".sig"), "wb") as f:
            f.write(signer.sign_detached(body))

    keep = {}
    real = os.path.join(testlib, "..", "..", "packer", "tools.lock")
    if os.path.exists(real):
        for line in open(real):
            k, _, v = line.strip().partition("=")
            if k and not k.startswith("#") and k in ("TWOLITER_VERSION", "TWOLITER_SHA256_X86_64", "RUSTUP_VERSION",
                                                     "RUSTUP_INIT_SHA256", "RUST_TOOLCHAIN", "CARGO_MAKE_VERSION",
                                                     "CARGO_MAKE_CRATE_SHA256"):
                keep[k] = v
    other_fpr = "0" * 40
    # The fixture has a linux_amd64 build only; the other platforms keep a well-formed digest that
    # no fixture file has, so a check on another platform fails rather than passing.
    lock = {
        "PACKER_VERSION": PACKER_VERSION,
        "PACKER_ZIP_SHA256_LINUX_AMD64": sha(pz) if case != "lock-digest" else sha(b"another zip"),
        "PACKER_ZIP_SHA256_LINUX_ARM64": "0" * 64, "PACKER_ZIP_SHA256_DARWIN_AMD64": "0" * 64,
        "PACKER_ZIP_SHA256_DARWIN_ARM64": "0" * 64,
        "AMAZON_PLUGIN_VERSION": PLUGIN_VERSION,
        "AMAZON_PLUGIN_API": "x5.0",
        "AMAZON_PLUGIN_ZIP_SHA256_LINUX_AMD64": sha(az) if case != "plugin-digest" else sha(b"another plugin"),
        "AMAZON_PLUGIN_ZIP_SHA256_LINUX_ARM64": "0" * 64, "AMAZON_PLUGIN_ZIP_SHA256_DARWIN_AMD64": "0" * 64,
        "AMAZON_PLUGIN_ZIP_SHA256_DARWIN_ARM64": "0" * 64,
        "HASHICORP_RELEASES_URL": "file://" + os.path.abspath(rel),
        "HASHICORP_KEY_URL": "file://" + os.path.abspath(os.path.join(out, "hashicorp-test-key.asc")),
        "HASHICORP_KEY_FPR": fpr if case != "wrong-fingerprint" else other_fpr,
    }
    lock.update(keep)
    with open(lock_out, "w") as f:
        f.write("# fixture tools lock for the offline tests; not the sample's pins\n")
        for k, v in lock.items():
            f.write(f"{k}={v}\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
