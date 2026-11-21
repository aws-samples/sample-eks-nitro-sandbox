#!/usr/bin/env python3
"""Validate and copy sensitive inputs used by install-oce.sh."""

from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import parse_qsl, urlsplit


def reject(flag: str, reason: str) -> None:
    sys.stderr.write(f"install-oce: {flag} {reason}.\n")
    raise SystemExit(1)


def write_private(destination: str, raw: bytes, flag: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(destination, flags, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(raw)
        os.chmod(destination, 0o600)
    except OSError:
        reject(flag, "could not be copied into the protected state directory")


def install_postgres_url(
    flag: str, source: str, destination: str, ca_path: str
) -> None:
    try:
        raw = Path(source).read_bytes()
    except OSError:
        reject(flag, "could not be read")
    if not raw or len(raw) > 16384:
        reject(flag, "must contain one PostgreSQL URL no larger than 16 KiB")
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    if any(byte < 0x21 or byte > 0x7E for byte in raw):
        reject(flag, "must contain one ASCII URL with no whitespace or embedded newlines")
    try:
        value = raw.decode("ascii")
    except UnicodeDecodeError:
        reject(flag, "must contain one ASCII URL")
    if "\\" in value or re.search(r"%(?![0-9A-Fa-f]{2})", value):
        reject(flag, "contains malformed URL escaping")

    try:
        parsed = urlsplit(value)
        host = parsed.hostname
        port = parsed.port
    except ValueError:
        reject(flag, "contains a malformed PostgreSQL URL")
    if (
        parsed.scheme not in {"postgres", "postgresql"}
        or not parsed.netloc
        or not host
        or parsed.fragment
        or parsed.path in {"", "/"}
    ):
        reject(flag, "must contain one PostgreSQL URL with a host and database name")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        reject(flag, "must use a DNS hostname so verify-full checks the server identity")
    dns_labels = host.split(".")
    if (
        len(host) > 253
        or any(
            len(label) > 63
            or not re.fullmatch(
                r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label
            )
            for label in dns_labels
        )
    ):
        reject(flag, "must use a valid DNS hostname so verify-full checks the server identity")
    if port not in {None, 5432}:
        reject(flag, "must use a DNS hostname on PostgreSQL port 5432")

    try:
        pairs = parse_qsl(
            parsed.query,
            keep_blank_values=True,
            strict_parsing=True,
            encoding="utf-8",
            errors="strict",
            max_num_fields=100,
        )
    except (UnicodeDecodeError, ValueError):
        reject(flag, "contains malformed query parameters")
    keys = [key.casefold() for key, _ in pairs]
    if len(keys) != len(set(keys)):
        reject(flag, "must not contain duplicate query parameters")
    parameters = {key.casefold(): value for key, value in pairs}
    if "connectionstring" in parameters or "ssl" in parameters:
        reject(flag, "contains an unsupported nested or overriding TLS parameter")
    if parameters.get("sslmode") != "verify-full":
        reject(flag, "must set sslmode=verify-full exactly once")
    if parameters.get("sslrootcert") != ca_path:
        reject(flag, f"must set sslrootcert={ca_path} exactly once")

    write_private(destination, raw, flag)


def install_ca_bundle(flag: str, source: str, destination: str) -> None:
    try:
        raw = Path(source).read_bytes()
    except OSError:
        reject(flag, "could not be read")
    if not raw or len(raw) > 1024 * 1024:
        reject(flag, "must contain a nonempty PEM CA bundle no larger than 1 MiB")
    try:
        value = raw.decode("ascii")
    except UnicodeDecodeError:
        reject(flag, "must contain ASCII PEM certificates")
    pattern = re.compile(
        r"-----BEGIN CERTIFICATE-----\r?\n"
        r"[A-Za-z0-9+/=\r\n]+"
        r"-----END CERTIFICATE-----"
    )
    certificates = pattern.findall(value)
    if not certificates or pattern.sub("", value).strip():
        reject(flag, "must contain only PEM certificates, with no private keys or other text")
    for index, certificate in enumerate(certificates, start=1):
        result = subprocess.run(
            ["openssl", "x509", "-noout", "-text"],
            input=certificate,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            reject(flag, f"contains an invalid X.509 certificate at position {index}")
        if not re.search(r"\bCA\s*:\s*TRUE\b", result.stdout, re.IGNORECASE):
            reject(flag, f"certificate {index} is not a CA certificate")

    write_private(destination, raw, flag)


def require_validation_cluster_tags(
    tags_json: str, required_key: str, required_value: str
) -> None:
    try:
        tags = json.loads(tags_json)
    except json.JSONDecodeError:
        tags = None
    if not isinstance(tags, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in tags.items()
    ):
        sys.stderr.write("install-oce: EKS returned malformed cluster tags.\n")
        raise SystemExit(1)

    production = [
        f"{key}={value}"
        for key, value in tags.items()
        if key.casefold() in {"environment", "stage"}
        and value.casefold() in {"prod", "production"}
    ]
    if production:
        sys.stderr.write(
            "install-oce: --validation-postgres rejects production-tagged EKS "
            f"clusters ({', '.join(production)}).\n"
        )
        raise SystemExit(1)

    actual_value = tags.get(required_key)
    if not isinstance(actual_value, str) or actual_value.casefold() != required_value:
        sys.stderr.write(
            "install-oce: --validation-postgres requires the exact EKS tag "
            f"{required_key}={required_value} (value is case-insensitive).\n"
        )
        raise SystemExit(1)


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: install-oce-inputs.py COMMAND [ARG ...]")
    command, *arguments = sys.argv[1:]
    if command == "postgres-url" and len(arguments) == 4:
        install_postgres_url(*arguments)
    elif command == "ca-bundle" and len(arguments) == 3:
        install_ca_bundle(*arguments)
    elif command == "validation-cluster-tags" and len(arguments) == 3:
        require_validation_cluster_tags(*arguments)
    else:
        raise SystemExit(f"invalid arguments for {command!r}")


if __name__ == "__main__":
    main()
