#!/usr/bin/env python3
"""A stand-in Bottlerocket clone for the offline tests of variant/register-variant.py only.

    fixture_br_clone.py <sample-dir> <clone-dir> <lock-out>

It writes a git repository at <clone-dir> that holds the files register-variant.py edits, in
their stock shape: variants/aws-k8s-1.36/Cargo.toml (made from the tracked variant by undoing the
script's own variant edits, so the tracked file is the stock one plus those edits), the amispec.toml
link, the workspace Cargo.toml, the settings-defaults and settings-plugins specs and README.md. It
commits them and makes an annotated tag v1.70.0. <lock-out> is the sample's packages/sources.lock
with the bottlerocket-source commit and tag object of this repository.

This proves the script's guards both ways; it does not prove that the edits match the upstream
v1.70.0 files. scripts/test-variant.sh also runs the accept case against a real clone when
CB_TESTS_BOTTLEROCKET_CLONE names one, and the builder's overlay stage proves it on the live build.
"""
import importlib.util
import os
import re
import subprocess
import sys


def load(sample):
    spec = importlib.util.spec_from_file_location("register_variant", os.path.join(sample, "variant", "register-variant.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(mod)
    return mod


def git(clone, *args):
    return subprocess.run(["git", "-C", clone, "-c", "user.name=offline-test", "-c", "user.email=offline-test@example.invalid",
                           "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                          check=True, capture_output=True, text=True).stdout.strip()


def main(sample, clone, lock_out):
    rv = load(sample)
    tracked = open(os.path.join(sample, "variant", "variants", rv.NEW, "Cargo.toml")).read()
    size = re.search(r"^os-image-size-gib = ([0-9]+)$", tracked, re.M).group(1)
    stock = tracked
    for old, new in reversed(rv.variant_edits(size)):
        assert stock.count(new) == 1, f"the tracked variant does not hold the edit {new.splitlines()[0]!r} once"
        stock = stock.replace(new, old)
    files = {
        f"variants/{rv.BASE}/Cargo.toml": stock,
        "Cargo.toml": f'[workspace]\nmembers = [\n    "variants/{rv.BASE}",\n    "packages/settings-plugins",\n]\n',
        "packages/settings-defaults/settings-defaults.spec":
            "Requires: (%{_cross_os}variant(aws-k8s-1.36) or\n"
            "           %{_cross_os}variant(aws-k8s-1.36-fips)\n           %{nil}})\n"
            "Provides: %{_cross_os}settings-defaults(any)\n"
            "Provides: %{_cross_os}settings-defaults(aws-k8s-1.36)\n"
            "Provides: %{_cross_os}settings-defaults(aws-k8s-1.36-fips)\n",
        "packages/settings-plugins/settings-plugins.spec": "Provides: %{_cross_os}settings-plugin(aws-k8s-1.36-fips)\n",
        "README.md": "Variants:\n* `aws-k8s-1.35`\n* `aws-k8s-1.36`\n",
        "variants/shared/amispec-split.toml": "# stand-in\n",
    }
    os.makedirs(clone)
    for rel, text in files.items():
        p = os.path.join(clone, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    os.symlink("../shared/amispec-split.toml", os.path.join(clone, "variants", rv.BASE, "amispec.toml"))
    git(clone, "init", "-q")
    git(clone, "add", "-A")
    git(clone, "commit", "-q", "-m", "stand-in v1.70.0")
    git(clone, "tag", "-a", "v1.70.0", "-m", "stand-in v1.70.0")
    commit = git(clone, "rev-parse", "HEAD")
    tag_object = git(clone, "rev-parse", "refs/tags/v1.70.0")
    lock = open(os.path.join(sample, "packages", "sources.lock")).read()
    lock = re.sub(r"(?m)^commit=[0-9a-f]{40}$", f"commit={commit}", lock, count=1)
    lock = re.sub(r"(?m)^tag_object=[0-9a-f]{40}$", f"tag_object={tag_object}", lock, count=1)
    with open(lock_out, "w") as f:
        f.write(lock)


if __name__ == "__main__":
    main(*sys.argv[1:4])
