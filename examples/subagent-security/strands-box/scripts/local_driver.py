#!/usr/bin/env python3
"""Run local Box checks inside the disposable container; export no TLS or API keys."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import strict_json

from local_supplier import LocalSupplier

SAMPLE = Path(__file__).resolve().parents[1]
SECTION = SAMPLE.parent
EXPORT = Path("/var/lib/analyst/local-export")
WORK = Path("/var/lib/analyst/local-work")
IMAGE_SAMPLE = Path("/opt/strands-box")


def hashes(root, paths):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths) if path.is_file()}


def copy_receipts(source, secrets):
    names = ["checks.json", "calls.json", "evidence.json", "recommendation.md", "comparison.json",
             "filesystem-checks.json"]
    names += ["broker/" + label + "/" + name
              for label in ("reader", "evaluator", "writer", "fresh-writer")
              for name in ("box-records.jsonl", "box-identity.json")]
    suppressed = []
    for name in names:
        path = source / name
        if not path.is_file():
            continue
        content = path.read_bytes()
        if any(secret and secret in content for secret in secrets):
            suppressed.append(name)
            continue
        target = EXPORT / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    return suppressed


def main():
    os.umask(0o077)
    EXPORT.mkdir(parents=True, exist_ok=False)
    report = {"completed": False, "image_id": os.environ["BOX_LOCAL_IMAGE_ID"],
              "local_run_id": os.environ["BOX_LOCAL_RUN_ID"], "uid": os.getuid(),
              "qualification": "Local Docker checks do not establish Nitro isolation, model, S3, or Pod Identity behavior."}
    exit_code = 1
    try:
        if os.getuid() != 1000:
            raise RuntimeError("The local container must run as UID 1000")
        expected_paths = [*SAMPLE.glob("src/*.py"), *SAMPLE.glob("policies/*.dw"), SAMPLE / "versions.json"]
        expected = hashes(SAMPLE, expected_paths)
        actual = hashes(IMAGE_SAMPLE, [IMAGE_SAMPLE / name for name in expected])
        report["image_source_sha256"] = actual
        if actual != expected:
            raise RuntimeError("The image sources differ from this checkout; build the current Dockerfile")
        sources = [SAMPLE / "Dockerfile", SAMPLE / "versions.json", SECTION / "analyst/requirements.txt"]
        for folder, patterns in ((SAMPLE / "scripts", ("*.py", "*.sh")), (SAMPLE / "src", ("*.py",)),
                                 (SAMPLE / "policies", ("*.dw",)), (SECTION / "analyst/src", ("*.py",)),
                                 (SECTION / "analyst/supplier-api", ("*.py", "Dockerfile")),
                                 (SECTION / "analyst/fixtures", ("*.json",))):
            for pattern in patterns:
                sources.extend(folder.rglob(pattern))
        report["checkout_source_sha256"] = hashes(SECTION, sources)
        report["box_sha256"] = hashlib.sha256(Path("/usr/local/bin/strands-box").read_bytes()).hexdigest()
        with LocalSupplier(parent_dir="/var/lib/analyst/private-supplier") as supplier:
            protected = []  # The local HTTP supplier uses synthetic data and no credentials.
            command = [sys.executable, "-B", "/opt/strands-box/src/controller.py", "--local",
                       "--supplier-url", supplier.origin, "--supplier-alias-url", supplier.alias_origin,
                       "--output-root", str(WORK)]
            try:
                process = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, timeout=300)
                transcript, status = process.stdout, process.returncode
            except subprocess.TimeoutExpired as error:
                transcript = error.stdout or b""
                if isinstance(transcript, bytes):
                    transcript = transcript.decode(errors="replace")
                transcript += "\nController exceeded the local deadline.\n"
                status = 124
            redacted = transcript.encode()
            for secret in protected:
                redacted = redacted.replace(secret, b"[redacted synthetic credential]")
            (EXPORT / "controller.log").write_bytes(redacted)
            runs = sorted(path for path in WORK.glob("*") if path.is_dir())
            report["controller_exit_code"] = status
            if len(runs) == 1:
                report["controller_run_id"] = runs[0].name
                report["suppressed_receipts"] = copy_receipts(runs[0], protected)
            ledger = "".join(json.dumps(row) + "\n" for row in supplier.requests)
            if any(secret and secret in ledger.encode() for secret in protected):
                raise RuntimeError("The supplier ledger contained a synthetic credential; it was not exported")
            (EXPORT / "supplier-api-requests.jsonl").write_text(ledger)
            markers = re.findall(r"^BOX_LOCAL_COMPLETE=([0-9a-f]{32})$", transcript, re.M)
            if status != 0 or len(markers) != 1 or re.search(r"^ANALYST_COMPLETE=", transcript, re.M):
                raise RuntimeError("The controller did not produce one successful local-mode completion")
            if len(runs) != 1 or markers[0] != runs[0].name or report.get("suppressed_receipts"):
                raise RuntimeError("The local run's receipts are incomplete")
            evidence = strict_json.loads((EXPORT / "evidence.json").read_text())
            if evidence.get("mode") != "local" or evidence.get("completed") is not True:
                raise RuntimeError("The controller receipt is not a completed local run")
            report["completed"] = True
            exit_code = 0
    except Exception as error:
        report["error"] = str(error)
    (EXPORT / "local-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(report["qualification"], flush=True)
    if report["completed"]:
        print("BOX_LOCAL_EXPORT=" + report["controller_run_id"], flush=True)
    else:
        print("Local run failed; inspect the exported report and controller log.", file=sys.stderr, flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
