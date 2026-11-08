"""Run a local, unauthenticated HTTP instance of the shared synthetic supplier.

Importing this helper starts nothing. Its child process owns the server and its
environment; the controller receives only origins and the independent request log.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import select
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import strict_json
import tempfile

SHARED = Path(__file__).resolve().parents[2] / "analyst"
LAUNCHER = Path(__file__).resolve().parents[1] / "supplier/http_supplier.py"


class LocalSupplier:
    """Create one owned fixture directory and retain its logs after context exit."""

    def __init__(self, parent_dir=None):
        parent = (Path(parent_dir) if parent_dir else
                  Path(__file__).resolve().parents[4] / "tmp/strands-box-local-supplier")
        parent.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
        self.state_dir = self.directory / "supplier-state"
        self._process = None
        self._stderr = None
        self._origin = None
        self._closed = False
        self._manifest = self.directory / "fixture.json"
        self._manifest.write_text(json.dumps({"directory": str(self.directory),
                                             "shared": str(SHARED)}, indent=2) + "\n")

    @property
    def origin(self):
        if self._origin is None:
            raise RuntimeError("Start the local supplier before reading its origin")
        return self._origin

    @property
    def alias_origin(self):
        return self.origin.replace("http://127.0.0.1:", "http://localhost:", 1)

    @property
    def url(self):
        return self.origin

    @property
    def requests(self):
        ledger = self.state_dir / "requests.jsonl"
        return [strict_json.loads(line) for line in ledger.read_text().splitlines()] if ledger.exists() else []

    @property
    def drafts(self):
        return [strict_json.loads(path.read_text()) for path in sorted((self.state_dir / "drafts").glob("*.json"))]

    def start(self):
        if self._closed:
            raise RuntimeError("The local supplier is closed")
        if self._process is None:
            self._stderr = (self.directory / "server.stderr.log").open("w")
            self._process = subprocess.Popen(
                [sys.executable, "-B", "-u", str(Path(__file__).resolve()), "--serve", str(self._manifest)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=self._stderr,
                env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"}, text=True,
            )
            try:
                ready, _, _ = select.select([self._process.stdout], [], [], 10)
                if not ready:
                    raise RuntimeError("Local supplier did not start within ten seconds")
                record = strict_json.loads(self._process.stdout.readline())
                self._origin = record["origin"]
            except Exception:
                self.close()
                raise RuntimeError("Local supplier startup failed; inspect its local stderr file") from None
        return self

    def close(self):
        if not self._closed:
            if self._process is not None:
                self._process.terminate()
                try:
                    self._process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait(timeout=5)
                self._process.stdout.close()
            if self._stderr is not None:
                self._stderr.close()
            self._closed = True

    def __enter__(self):
        return self.start()

    def __exit__(self, *args):
        self.close()


def _serve(manifest):
    values = strict_json.loads(Path(manifest).read_text())
    directory, shared = Path(values["directory"]), Path(values["shared"])
    spec = importlib.util.spec_from_file_location("http_supplier", LAUNCHER)
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)
    launcher.serve(bind="127.0.0.1", port=0, analyst_source=shared / "src",
                   supplier_source=shared / "supplier-api/supplier_api.py",
                   fixtures=shared / "fixtures", state=directory / "supplier-state")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--serve":
        raise SystemExit("Import LocalSupplier and use it as a context manager")
    _serve(sys.argv[2])
