#!/bin/sh
set -eu
version=2.11.0-1+oce1
case "${1:-}" in
    --packages)
        test "$#" = 2
        cd "$2"
        arch=$(dpkg --print-architecture)
        printf '%s\n' "libexpat1_${version}_${arch}.deb" |
            diff -u - runtime-packages.list
        printf '%s\n' "libexpat1-dev_${version}_${arch}.deb" |
            diff -u - build-packages.list
        checksum_files=$(mktemp)
        trap 'rm -f "$checksum_files"' EXIT HUP INT TERM
        awk '{print $2}' packages.sha256 | sed 's#^\./##' | LC_ALL=C sort >"$checksum_files"
        cat runtime-packages.list build-packages.list | LC_ALL=C sort |
            diff -u - "$checksum_files"
        find . -maxdepth 1 -type f -name '*.deb' -print | sed 's#^\./##' | LC_ALL=C sort |
            diff -u "$checksum_files" -
        sha256sum --check --strict packages.sha256
        for package in libexpat1 libexpat1-dev; do
            deb="${package}_${version}_${arch}.deb"
            test "$(dpkg-deb --field "$deb" Package)" = "$package"
            test "$(dpkg-deb --field "$deb" Version)" = "$version"
            test "$(dpkg-deb --field "$deb" Architecture)" = "$arch"
        done ;;
    --runtime)
        test "$#" = 1
        test "$(dpkg-query -W -f='${db:Status-Status}' libexpat1)" = installed
        test "$(dpkg-query -W -f='${Version}' libexpat1)" = "$version"
        if [ "$(dpkg-query -W -f='${db:Status-Status}' libexpat1-dev 2>/dev/null || true)" = installed ]; then
            test "$(dpkg-query -W -f='${Version}' libexpat1-dev)" = "$version"
        fi
        python3 - <<'PY'
import ctypes
import pyexpat
import xml.etree.ElementTree as ET

library = ctypes.CDLL("libexpat.so.1")
library.XML_ExpatVersion.restype = ctypes.c_char_p
assert library.XML_ExpatVersion() == b"expat_2.11.0"
assert pyexpat.EXPAT_VERSION == "expat_2.11.0", pyexpat.EXPAT_VERSION
assert ET.fromstring("<root><item>ok</item></root>")[0].text == "ok"
try:
    ET.fromstring("<root>")
except ET.ParseError:
    pass
else:
    raise AssertionError("invalid XML was accepted")
# Regression shape from CVE-2026-117610: initial empty non-final subparse.
parser = pyexpat.ParserCreate()
child = parser.ExternalEntityParserCreate("")
child.Parse(b"", False)
child.Parse(b"<child/>", True)
print("Expat 2.11.0 system SONAME and Python XML ABI verified")
PY
        ;;
    *) echo "Usage: verify.sh --packages DIR | --runtime" >&2; exit 2 ;;
esac
