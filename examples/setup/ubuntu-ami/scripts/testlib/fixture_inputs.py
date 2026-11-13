#!/usr/bin/env python3
"""Small stand-ins for every input the sample downloads and verifies, for the clusterless tests
only, served from local files through file:// URLs so the real scripts and real curl run with no
network reached:

  * a runtime release: a flat gzip tar holding a shim stand-in, a SHA256SUM manifest listing the
    archive and the shim, and its signature, made with a P-384 test key pair (openssl), whose
    public half is written beside the lock file, as the real key is beside sources.lock;
  * a guest image pair, each file with its .sha256 sidecar;
  * a Firecracker release tarball (release-fx/firecracker-fx, release-fx/jailer-fx) with its
    .sha256.txt sidecar;
  * a kernel tarball, a host-kernel patch whose first line names its commit, an erofs-utils
    tarball;
plus a lock file in the real sources.lock shape pinning each of them.

    fixture_inputs.py <fixture-dir> <lock-file> [<case>]

<case> (default good) changes one thing, so the check the case is about is the one that answers;
the names are the ones packages/test-inputs.sh uses. Never point a real run at this lock: the
files it pins are not the sample's inputs.
"""
import hashlib
import io
import os
import subprocess
import sys
import tarfile

COMMIT = "0123456789abcdef0123456789abcdef01234567"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def tgz(members):
    """members: list of (name, bytes) for regular files, or (name, None, tarfile type, linkname)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.PAX_FORMAT) as t:
        for m in members:
            name, data = m[0], m[1]
            ti = tarfile.TarInfo(name)
            ti.mtime = 0
            if data is None:
                ti.type, ti.linkname = m[2], m[3]
                t.addfile(ti)
            else:
                ti.size, ti.mode = len(data), 0o755
                t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(fx, lock, case="good"):
    os.makedirs(fx, exist_ok=True)
    lock_dir = os.path.dirname(os.path.abspath(lock))
    url = lambda name: "file://" + os.path.join(os.path.abspath(fx), name)
    write = lambda name, data: open(os.path.join(fx, name), "wb").write(data)

    # --- keys: the signing key, and a second one for the bad-signature case ---------------------
    key, pub = os.path.join(fx, "test-signing.key"), os.path.join(lock_dir, "fixture-runtime-v1.pub")
    openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", key)
    openssl("ec", "-in", key, "-pubout", "-out", pub)
    other = os.path.join(fx, "other-signing.key")
    openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", other)

    # --- the runtime release ---------------------------------------------------------------------
    shim = b"fixture shim\n"
    pinned_shim = shim
    members = [("fx-shim", shim), ("fx-agent", b"fixture agent, not installed\n")]
    if case == "shim-tampered":        # the archive carries another shim than the signed pin
        members[0] = ("fx-shim", b"tampered shim\n")
    if case == "member-path":
        members.append(("sub/evil", b"x\n"))
    if case == "member-dup":
        members.append(("fx-agent", b"second copy\n"))
    if case == "member-link":
        members.append(("fx-link", None, tarfile.SYMTYPE, "/usr/bin/true"))
    archive = tgz(members) if case != "not-a-tar" else b"this is not a gzip tar\n"
    write("runtime.tar.gz", archive)
    if case == "archive-swapped":      # the file served is not the archive the manifest signs
        write("runtime.tar.gz", tgz([("fx-shim", shim), ("fx-agent", b"another build\n")]))
    lines = [f"{sha(archive)}  runtime.tar.gz", f"{sha(pinned_shim)}  fx-shim"]
    if case == "manifest-no-shim":
        lines = lines[:1]
    if case == "manifest-bad-line":
        lines.append("not a manifest line")
    manifest = ("\n".join(lines) + "\n").encode()
    write("SHA256SUM", manifest)
    openssl("dgst", "-sha384", "-sign", other if case == "bad-sig" else key,
            "-out", os.path.join(fx, "SHA256SUM.sig"), os.path.join(fx, "SHA256SUM"))
    if case == "manifest-changed":     # changed after it was signed (its pin follows the change)
        manifest += f"{sha(b'extra')}  extra-line\n".encode()
        write("SHA256SUM", manifest)

    # --- the guest image pair --------------------------------------------------------------------
    eif, disk = b"fixture guest boot image\n", b"fixture guest disk\n"
    write("guest.eif", eif if case != "file-mismatch" else b"another guest image\n")
    write("guest.eif.sha256", f"{sha(eif)} guest.eif\n".encode() if case not in ("sidecar-mismatch", "sidecar-garbled")
          else (f"{sha(b'other')} guest.eif\n" if case == "sidecar-mismatch" else "<html>not found</html>\n").encode())
    write("guest-disk.img", disk)
    write("guest-disk.img.sha256", f"{sha(disk)} guest-disk.img\n".encode())

    # --- the Firecracker release -----------------------------------------------------------------
    fc, jl = b"fixture firecracker\n", b"fixture jailer\n"
    fcm = [("release-fx/firecracker-fx", fc), ("release-fx/jailer-fx", jl), ("release-fx/LICENSE", b"license\n")]
    if case == "fc-traversal":
        fcm.append(("release-fx/../../escaped", b"outside\n"))
    if case == "fc-absolute":
        fcm.append(("/etc/escaped", b"outside\n"))
    if case == "fc-link":
        fcm.append(("release-fx/link", None, tarfile.LNKTYPE, "release-fx/jailer-fx"))
    if case == "fc-missing-member":
        fcm = [m for m in fcm if m[0] != "release-fx/jailer-fx"]
    if case == "fc-jailer-tampered":
        fcm = [(n, b"tampered jailer\n" if n.endswith("jailer-fx") else d) for n, d in fcm]
    fct = tgz(fcm)
    write("firecracker-fx.tgz", fct)
    write("firecracker-fx.tgz.sha256.txt", f"{sha(fct)}  firecracker-fx.tgz\n".encode())

    # --- the kernel-build inputs -----------------------------------------------------------------
    files = {"linux-fixture.tar.xz": b"kernel fixture\n", "erofs-utils-fixture.tar.gz": b"erofs fixture\n",
             f"{COMMIT}.patch": f"From {COMMIT} Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n".encode()}
    for n, b in files.items():
        write(n, b)

    def src(name):
        return url("absent-" + name) if case == "check-only" else url(name)

    blocks = [
        dict(id="runtime-release", kind="signed-archive", ref="fixture", arch="x86_64", file="runtime.tar.gz",
             source=src("runtime.tar.gz") if case != "download-fails" else url("missing.tar.gz"),
             sha256=sha(archive), manifest=url("SHA256SUM"),
             manifest_sha256=sha(manifest) if case != "manifest-pin" else sha(b"other manifest"),
             signature=url("SHA256SUM.sig"), public_key=os.path.basename(pub),
             public_key_sha256=sha(open(pub, "rb").read()) if case != "wrong-key" else sha(b"another key"),
             status="available"),
        dict(id="runtime-shim", kind="archive-member", archive="runtime-release", ref="fixture", file="fx-shim",
             member="fx-shim", source="member of runtime-release", sha256=sha(pinned_shim),
             install="/usr/sbin/containerd-shim-nitro-sandbox-v2 0755", status="available"),
        dict(id="guest-image-eif", kind="sidecar-file", ref="fixture/amd64", file="guest.eif", source=src("guest.eif"),
             sidecar=url("guest.eif.sha256"), sha256=sha(eif), guest_kernel="6.18.56",
             install="/var/lib/nitro-sandbox-images/latest.eif 0644", status="available"),
        dict(id="guest-image-disk", kind="sidecar-file", ref="fixture/amd64", file="guest-disk.img",
             source=src("guest-disk.img"), sidecar=url("guest-disk.img.sha256"), sha256=sha(disk),
             install="/var/lib/nitro-sandbox-images/latest-disk.img 0644", status="available"),
        dict(id="firecracker-release", kind="sidecar-file", ref="vfixture", file="firecracker-fx.tgz",
             source=src("firecracker-fx.tgz"), sidecar=url("firecracker-fx.tgz.sha256.txt"), sha256=sha(fct),
             install="none", status="available"),
        dict(id="firecracker", kind="archive-member", archive="firecracker-release", ref="vfixture", file="firecracker",
             member="release-fx/firecracker-fx", source="member of firecracker-release", sha256=sha(fc),
             install="/usr/bin/firecracker 0755", status="available"),
        dict(id="jailer", kind="archive-member", archive="firecracker-release", ref="vfixture", file="jailer",
             member="release-fx/jailer-fx", source="member of firecracker-release", sha256=sha(jl),
             install="/usr/bin/jailer 0755", status="available"),
        dict(id="linux-kernel-source", kind="file", ref="fixture", source=url("linux-fixture.tar.xz"),
             sha256=sha(files["linux-fixture.tar.xz"]), status="available"),
        dict(id="host-kernel-patch", kind="file", ref=COMMIT, file=f"{COMMIT}.patch", source=url(f"{COMMIT}.patch"),
             sha256=sha(files[f"{COMMIT}.patch"]), subject="fixture", status="available"),
        dict(id="erofs-utils-source", kind="file", ref="fixture", source=url("erofs-utils-fixture.tar.gz"),
             sha256=sha(files["erofs-utils-fixture.tar.gz"]), status="available"),
    ]
    with open(lock, "w") as f:
        f.write("\n".join("".join(f"{k}={v}\n" for k, v in b.items()) for b in blocks))


if __name__ == "__main__":
    main(*sys.argv[1:4])
