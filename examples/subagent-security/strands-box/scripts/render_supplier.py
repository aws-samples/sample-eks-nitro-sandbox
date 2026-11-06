#!/usr/bin/env python3
"""Render the synthetic supplier manifest with this sample's image architecture."""
import argparse
from pathlib import Path
import re
import sys


def render(template, mode, image, namespace, managed_by):
    if mode not in ("eks", "nitro"):
        raise ValueError("deployment mode must be eks or nitro")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", namespace):
        raise ValueError("namespace must be a Kubernetes DNS label")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/@-]*", image):
        raise ValueError("supplier image must be a nonempty image reference")
    if not re.fullmatch(r"strands-box-[a-f0-9]{20}", managed_by):
        raise ValueError("managed_by must be the derived deployment owner")
    documents = template.split("\n---\n")
    deployment = [index for index, text in enumerate(documents)
                  if re.search(r"^kind: Deployment$", text, re.M)]
    if len(deployment) != 1:
        raise ValueError("expected one synthetic supplier Deployment")
    index = deployment[0]
    text = documents[index]
    anchor = "\n    spec:\n      automountServiceAccountToken: false\n"
    if text.count(anchor) != 1 or re.search(r"^\s*nodeSelector:", text, re.M):
        raise ValueError("synthetic supplier pod template changed; review its architecture selector")
    architecture = "arm64"
    documents[index] = text.replace(anchor, "\n    spec:\n      nodeSelector:\n"
                                   f"        kubernetes.io/arch: {architecture}\n"
                                   "      automountServiceAccountToken: false\n")
    result = "\n---\n".join(documents)
    for token, value in (("<NAMESPACE>", namespace), ("<MANAGED_BY>", managed_by),
                         ("<SUPPLIER_API_IMAGE>", image)):
        if token not in result:
            raise ValueError(f"synthetic supplier template is missing {token}")
        result = result.replace(token, value)
    if re.search(r"<[A-Z_]+>", result):
        raise ValueError("supplier manifest has an unresolved placeholder")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("eks", "nitro"), required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--managed-by", required=True)
    parser.add_argument("--output", type=Path,
                        help="write here; otherwise print the rendered manifest")
    args = parser.parse_args()
    template = Path(__file__).resolve().parents[1] / "deploy/supplier-api.yaml"
    result = render(template.read_text(), args.mode, args.image, args.namespace, args.managed_by)
    if args.output:
        args.output.write_text(result)
    else:
        sys.stdout.write(result)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(f"Supplier rendering failed: {error}")
