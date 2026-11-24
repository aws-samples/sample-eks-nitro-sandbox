#!/usr/bin/env python3
"""Small stand-ins for every input that packages/sources.lock pins, for the offline tests only.
Ported from examples/setup/ubuntu-ami/scripts/testlib/fixture_inputs.py. They are served from local
files through file:// URLs, so the real packages/lib/runtime_verify.py and real curl and openssl
run with no network reached:

  * a runtime release: a flat gzip tar with a shim stand-in and a logger stand-in, a SHA256SUM
    manifest that lists the archive and both members, and its signature, made with a P-384 test
    key pair (openssl) whose public half is written beside the lock file, as the real key is
    beside sources.lock;
  * a guest image pair, each file with its .sha256 sidecar;
  * a Firecracker release tarball with its .sha256.txt sidecar;
  * a lock file in the real sources.lock shape (a git-tag block, sha512= lines, verify= lines
    with continuation lines) that pins each of them.

    fixture_inputs.py <fixture-dir> <lock-file> [<case>]

<case> (default good) changes one thing, so the check the case is about is the one that answers:

  good                accepted
  checksum-changed    the archive served is not the one the signed SHA256SUM lists
  lock-pin-changed    the lock pins another SHA-256 for the archive than the signed SHA256SUM lists
  signature-changed   SHA256SUM.sig has one byte changed
  bad-sig             SHA256SUM is signed with another key
  manifest-changed    SHA256SUM changed after it was signed (its pin follows the change)
  manifest-pin        the lock pins another SHA-256 for SHA256SUM
  wrong-key           the lock pins another SHA-256 for the public key
  shim-tampered       the archive's shim is not the pinned member
  file-mismatch       the guest EIF is not its pin (its sidecar agrees with the pin)
  sidecar-mismatch    the guest EIF sidecar disagrees with the pin
  download-fails      the archive URL does not exist
  manifest-bad-line   the signed SHA256SUM (signature and pin both good) has a line that is not a checksum line
  member-missing      the archive has no logger member, while the signed SHA256SUM and the lock list it

Never point a real run at this lock: the files it pins are not the sample's inputs.
"""
import hashlib
import io
import os
import subprocess
import sys
import tarfile

CASES = ("good", "checksum-changed", "lock-pin-changed", "signature-changed", "bad-sig", "manifest-changed",
         "manifest-pin", "wrong-key", "shim-tampered", "file-mismatch", "sidecar-mismatch", "download-fails",
         "manifest-bad-line", "member-missing")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def sha512(b):
    return hashlib.sha512(b).hexdigest()


def tgz(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.PAX_FORMAT) as t:
        for name, data in members:
            ti = tarfile.TarInfo(name)
            ti.mtime, ti.size, ti.mode = 0, len(data), 0o755
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(fx, lock, case="good"):
    if case not in CASES:
        sys.exit(f"fixture_inputs.py: unknown case {case}")
    os.makedirs(fx, exist_ok=True)
    lock_dir = os.path.dirname(os.path.abspath(lock))
    url = lambda name: "file://" + os.path.join(os.path.abspath(fx), name)  # noqa: E731

    def write(name, data):
        with open(os.path.join(fx, name), "wb") as f:
            f.write(data)

    key, pub = os.path.join(fx, "test-signing.key"), os.path.join(lock_dir, "fixture-runtime-v1.pub")
    openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", key)
    openssl("ec", "-in", key, "-pubout", "-out", pub)
    other = os.path.join(fx, "other-signing.key")
    openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", other)

    # --- the runtime release ------------------------------------------------------------------
    shim = b'#!/bin/sh\necho "containerd-shim-nitro-sandbox-v2 fixture stand-in"\n'
    logger = b"#!/bin/sh\nexit 0\n"
    members = [("containerd-shim-nitro-sandbox-v2", shim if case != "shim-tampered" else b"tampered shim\n"),
               ("nitro-sandbox-shim-logger-wrapper", logger)]
    if case == "member-missing":
        members = members[:1]
    # shim-tampered: the archive (and the manifest line for it) carry another shim, while the
    # manifest line and the lock pin for the shim member stay the good shim's.
    archive = tgz(members)
    write("nitro-sandboxes-runtime.tar.gz", archive)
    if case == "checksum-changed":
        write("nitro-sandboxes-runtime.tar.gz", tgz(members + [("extra", b"another build\n")]))
    lines = [f"{sha(archive)}  nitro-sandboxes-runtime.tar.gz",
             f"{sha(shim)}  containerd-shim-nitro-sandbox-v2", f"{sha(logger)}  nitro-sandbox-shim-logger-wrapper"]
    if case == "manifest-bad-line":
        lines.append("this is not a checksum line")
    manifest = ("\n".join(lines) + "\n").encode()
    write("SHA256SUM", manifest)
    openssl("dgst", "-sha384", "-sign", other if case == "bad-sig" else key,
            "-out", os.path.join(fx, "SHA256SUM.sig"), os.path.join(fx, "SHA256SUM"))
    if case == "signature-changed":
        sig = bytearray(open(os.path.join(fx, "SHA256SUM.sig"), "rb").read())
        sig[len(sig) // 2] ^= 0x01
        write("SHA256SUM.sig", bytes(sig))
    if case == "manifest-changed":
        manifest += f"{sha(b'extra')}  extra-line\n".encode()
        write("SHA256SUM", manifest)

    # --- the guest image pair -----------------------------------------------------------------
    eif, disk = b"fixture guest boot image\n", b"fixture guest disk\n"
    write("nitro-sandbox-guest.eif", eif if case != "file-mismatch" else b"another guest image\n")
    side = f"{sha(eif)}  nitro-sandbox-guest.eif\n" if case != "sidecar-mismatch" else f"{sha(b'other')}  nitro-sandbox-guest.eif\n"
    write("nitro-sandbox-guest.eif.sha256", side.encode())
    write("nitro-sandbox-guest-disk.img", disk)
    write("nitro-sandbox-guest-disk.img.sha256", f"{sha(disk)}  nitro-sandbox-guest-disk.img\n".encode())

    # --- Firecracker --------------------------------------------------------------------------
    fc, jl = b"fixture firecracker\n", b"fixture jailer\n"
    fct = tgz([("release-vfx-x86_64/firecracker-vfx-x86_64", fc), ("release-vfx-x86_64/jailer-vfx-x86_64", jl)])
    write("firecracker-vfx-x86_64.tgz", fct)
    write("firecracker-vfx-x86_64.tgz.sha256.txt", f"{sha(fct)}  firecracker-vfx-x86_64.tgz\n".encode())

    pub_bytes = open(pub, "rb").read()
    archive_pin = sha(archive) if case != "lock-pin-changed" else sha(b"another archive")
    blocks = [
        dict(id="bottlerocket-source", kind="git-tag", ref="vfixture", source="file:///nonexistent/bottlerocket.git",
             commit="0" * 40, tag_object="1" * 40, base_variant="aws-k8s-1.36",
             verify="the clone is checked on the builder,\n  not by runtime_verify.py", status="available"),
        dict(id="runtime-release", kind="signed-archive", ref="fixture", arch="x86_64",
             file="nitro-sandboxes-runtime.tar.gz",
             source=url("nitro-sandboxes-runtime.tar.gz") if case != "download-fails" else url("missing.tar.gz"),
             sha256=archive_pin, sha512=sha512(archive), manifest=url("SHA256SUM"),
             manifest_sha256=sha(manifest) if case != "manifest-pin" else sha(b"other manifest"),
             signature=url("SHA256SUM.sig"), public_key=os.path.basename(pub),
             public_key_sha256=sha(pub_bytes) if case != "wrong-key" else sha(b"another key"),
             install="none", verify="a fixture,\n  signed with a test key", status="available"),
        dict(id="runtime-shim", kind="archive-member", archive="runtime-release", ref="fixture",
             member="containerd-shim-nitro-sandbox-v2", source="member of runtime-release", sha256=sha(shim),
             install="/usr/bin/containerd-shim-nitro-sandbox-v2 0755", status="available"),
        dict(id="runtime-shim-logger", kind="archive-member", archive="runtime-release", ref="fixture",
             member="nitro-sandbox-shim-logger-wrapper", source="member of runtime-release", sha256=sha(logger),
             install="/usr/bin/nitro-sandbox-shim-logger-wrapper 0755", status="available"),
        dict(id="guest-image-eif", kind="sidecar-file", ref="fixture/amd64", arch="amd64", file="nitro-sandbox-guest.eif",
             source=url("nitro-sandbox-guest.eif"), sidecar=url("nitro-sandbox-guest.eif.sha256"), sha256=sha(eif),
             sha512=sha512(eif), install="/usr/share/nitro-sandbox/latest.eif 0644", status="available"),
        dict(id="guest-image-disk", kind="sidecar-file", ref="fixture/amd64", arch="amd64",
             file="nitro-sandbox-guest-disk.img", source=url("nitro-sandbox-guest-disk.img"),
             sidecar=url("nitro-sandbox-guest-disk.img.sha256"), sha256=sha(disk), sha512=sha512(disk),
             install="/usr/share/nitro-sandbox/latest-disk.img 0644", status="available"),
        dict(id="firecracker-release", kind="sidecar-file", ref="vfixture", file="firecracker-vfx-x86_64.tgz",
             source=url("firecracker-vfx-x86_64.tgz"), sidecar=url("firecracker-vfx-x86_64.tgz.sha256.txt"),
             sha256=sha(fct), sha512=sha512(fct), install="none", status="available"),
        dict(id="firecracker", kind="archive-member", archive="firecracker-release", ref="vfixture",
             member="release-vfx-x86_64/firecracker-vfx-x86_64", source="member of firecracker-release", sha256=sha(fc),
             install="/usr/bin/firecracker 0755", status="available"),
        dict(id="jailer", kind="archive-member", archive="firecracker-release", ref="vfixture",
             member="release-vfx-x86_64/jailer-vfx-x86_64", source="member of firecracker-release", sha256=sha(jl),
             install="/usr/bin/jailer 0755", status="available"),
    ]
    with open(lock, "w") as f:
        f.write("# fixture lock for the offline tests; not the sample's inputs\n\n")
        f.write("\n".join("".join(f"{k}={v}\n" for k, v in b.items()) for b in blocks))


if __name__ == "__main__":
    main(*sys.argv[1:4])
