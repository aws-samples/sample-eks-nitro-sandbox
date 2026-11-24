#!/usr/bin/env python3
"""Static scans of the sample folder for the offline tests (scripts/test-static.sh).

    static_scan.py <rule> <sample-dir>

Each rule prints one line per finding ("<path>:<line>: <rule>: <text>") and exits 1 when it finds
one, 0 when it finds none, 2 when it could not read a file. Comment lines (# and //) are skipped
before matching, and patterns are anchored where the format allows (AGENTS.md: "Anchor search
patterns and strip comments before matching"). The test suite runs each rule on the real folder
(accept) and on a planted copy (reject).

Rules:
  cilium-version   a Cilium version (1.<minor>.<patch> next to "cilium", or CILIUM_VERSION= with a
                   literal version) in any file but cilium.lock, the page (README.md) and the tests
  owner-tags       an auto-delete or Owner tag key (#281: tags are ManagedBy, RunId, Name,
                   plus SandboxSlots and pin tags)
  account-ids      a 12-digit number (an AWS account ID shape) outside scripts/testlib/, where only
                   the AWS documentation example account appears
  em-dash          the em dash character (the owner's writing rule)
  exposure         a Service of type LoadBalancer or NodePort, an Ingress, a hostPort or hostNetwork
                   in deploy/ or eksctl/
  network-policy   a NetworkPolicy, CiliumNetworkPolicy or CiliumClusterwideNetworkPolicy object
"""
import os
import re
import sys

SKIP_DIRS = {".git", "__pycache__", "images"}
TEXT_EXT = {".sh", ".py", ".yaml", ".yml", ".json", ".toml", ".hcl", ".md", ".env", ".lock", ".example",
            ".spec", ".conf", ".service", ".network", ".tmpl", ".txt", ".edits", ".pub", ""}
EXAMPLE_ACCOUNT = "111122223333"


def files(root):
    for d, dirs, names in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for n in names:
            p = os.path.join(d, n)
            ext = os.path.splitext(n)[1]
            if ext in TEXT_EXT or n.endswith(".env.example") or n == ".gitignore":
                yield os.path.relpath(p, root), p


def lines(path):
    with open(path, encoding="utf-8", errors="strict") as f:
        for n, line in enumerate(f, 1):
            yield n, line.rstrip("\n")


def code_line(line):
    s = line.lstrip()
    return not (s.startswith("#") or s.startswith("//"))


def is_test(rel):
    return rel.startswith("scripts/testlib/") or re.fullmatch(r"scripts/test-[^/]+\.sh", rel) is not None


RULES = {
    "cilium-version": (lambda rel: rel not in ("cilium.lock", "README.md") and not is_test(rel),
                       re.compile(r"(?i)(cilium[^\n]{0,40}\b1\.(1[0-9]|2[0-9])\.[0-9]+\b"
                                  r"|^\s*(export\s+)?CILIUM_VERSION=[\"']?v?[0-9])"),
                       True),
    "owner-tags": (lambda rel: not is_test(rel),
                   re.compile(r"(auto-delete|\bKey=Owner\b|^\s*Owner\s*[:=]|[\"']Owner[\"']\s*:|\bOWNER_TAG=|\beniTags\.Owner\b)"),
                   True),
    "account-ids": (lambda rel: not rel.startswith("scripts/testlib/"),
                    # a UUID's last group is 12 hex digits after a hyphen, not an account ID
                    re.compile(r"(?<![0-9A-Za-z-])[0-9]{12}(?![0-9A-Za-z-])"), False),
    "em-dash": (lambda rel: True, re.compile("\u2014"), False),
    "exposure": (lambda rel: rel.startswith(("deploy/", "eksctl/")),
                 re.compile(r"^\s*(type:\s*[\"']?(LoadBalancer|NodePort)\b|kind:\s*Ingress\b|hostPort:|hostNetwork:\s*true)"),
                 True),
    "network-policy": (lambda rel: rel.startswith(("deploy/", "eksctl/")) or rel.endswith((".yaml", ".yml")) and not is_test(rel),
                       re.compile(r"^\s*kind:\s*(NetworkPolicy|CiliumNetworkPolicy|CiliumClusterwideNetworkPolicy)\b"),
                       True),
}


def main(rule, root):
    want, rx, strip_comments = RULES[rule]
    found, unreadable = 0, 0
    for rel, path in sorted(files(root)):
        if not want(rel):
            continue
        try:
            for n, line in lines(path):
                if strip_comments and not code_line(line):
                    continue
                m = rx.search(line)
                if not m:
                    continue
                if rule == "account-ids" and m.group(0) == EXAMPLE_ACCOUNT:
                    continue
                found += 1
                text = line.strip() if rule != "account-ids" else "<a 12-digit number>"
                print(f"{rel}:{n}: {rule}: {text[:120]}")
        except UnicodeDecodeError:
            continue
        except OSError as e:
            print(f"{rel}: could not read: {e.strerror}")
            unreadable += 1
    return 2 if unreadable else (1 if found else 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
