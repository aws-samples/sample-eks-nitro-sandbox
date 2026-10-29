#!/usr/bin/env python3
"""Small stand-ins for every input setup.sh's local preflight verifies, for the clusterless
tests only: a two-payload runtime zip with its SHA256SUMS, a kernel tarball, a host-kernel patch
whose first line names its commit, and an erofs-utils tarball, plus a lock file in the real
sources.lock shape pinning each of them. setup.sh verifies them exactly as it verifies the real
ones (packages/fetch-*.sh), so a test can run the real setup.sh without the 150 MB archive.

    fixture_inputs.py <runtime-dir> <lock-file>

Never point a real run at this lock: the files it pins are not the sample's inputs.
"""
import hashlib
import sys
import warnings
import zipfile


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main(fx, lock):
    pay = {"fx-shim": b"fixture shim\n", "fx-image": b"fixture image\n"}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(f"{fx}/fixture.zip", "w") as z:
            z.writestr("SHA256SUMS", "".join(f"{sha(b)}  {n}\n" for n, b in sorted(pay.items())))
            for n, b in pay.items():
                z.writestr(n, b)
    commit = "0123456789abcdef0123456789abcdef01234567"
    files = {"linux-fixture.tar.xz": b"kernel fixture\n", "erofs-utils-fixture.tar.gz": b"erofs fixture\n",
             f"{commit}.patch": f"From {commit} Mon Sep 17 00:00:00 2001\nSubject: [PATCH] fixture\n".encode()}
    for n, b in files.items():
        with open(f"{fx}/{n}", "wb") as f:
            f.write(b)
    with open(f"{fx}/fixture.zip", "rb") as f:
        zip_sha = sha(f.read())
    blocks = [
        dict(id="runtime-archive", kind="file", ref="fixture", file="fixture.zip", source="operator-supplied fixture",
             sha256=zip_sha, status="operator-supplied"),
        *[dict(id=f"runtime-payload-{n}", kind="runtime-payload", archive="runtime-archive", ref="fixture", file=n,
               source="member of runtime-archive", sha256=sha(b), install="none", status="operator-supplied")
          for n, b in pay.items()],
        dict(id="linux-kernel-source", kind="file", ref="fixture", source="https://example.invalid/linux-fixture.tar.xz",
             sha256=sha(files["linux-fixture.tar.xz"]), status="available"),
        dict(id="host-kernel-patch", kind="file", ref=commit, file=f"{commit}.patch",
             source=f"https://example.invalid/{commit}.patch", sha256=sha(files[f"{commit}.patch"]), subject="fixture",
             status="available"),
        dict(id="erofs-utils-source", kind="file", ref="fixture", source="https://example.invalid/erofs-utils-fixture.tar.gz",
             sha256=sha(files["erofs-utils-fixture.tar.gz"]), status="available"),
    ]
    with open(lock, "w") as f:
        f.write("\n".join("".join(f"{k}={v}\n" for k, v in b.items()) for b in blocks))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
