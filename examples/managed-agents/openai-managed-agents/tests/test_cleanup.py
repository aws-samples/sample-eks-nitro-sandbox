"""Tests for scripts/cleanup.py's launcher call, with the OpenAI client and urlopen faked.

The launcher URL must be http:// or https:// before urlopen sees it, because
urlopen also opens file:// and other schemes. Both ways, per AGENTS.md: an http or
https URL reaches the launcher, any other scheme is refused before anything is
opened, and a refused URL stops the clean up before it deletes the session, so a
session is never deleted while its claim stays.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
from types import SimpleNamespace

import pytest


def _load_cleanup():
    scripts_dir = pathlib.Path(__file__).resolve().parent.parent / "scripts"
    sys.path.insert(0, str(scripts_dir))  # so cleanup.py's `from _client import ...` resolves
    try:
        spec = importlib.util.spec_from_file_location("cleanup_under_test", scripts_dir / "cleanup.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(scripts_dir))


cleanup = _load_cleanup()


class _Response:
    def __init__(self, body: bytes):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.mark.parametrize("url", ["http://127.0.0.1:8080", "https://launcher.example/"])
def test_delete_claim_accepts_an_http_or_https_launcher_url(url, monkeypatch, capsys):
    opened = []

    def fake_urlopen(req, timeout):
        opened.append(req.full_url)
        return _Response(b'{"claims_deleted": 1}')

    monkeypatch.setattr(cleanup.urllib.request, "urlopen", fake_urlopen)
    cleanup._delete_claim(url, "intake", "sess_1")
    assert opened == [url.rstrip("/") + "/sessions/claim-delete"]
    assert "deleted 1 claim(s)" in capsys.readouterr().out


@pytest.mark.parametrize("url", ["file:///etc/hostname", "ftp://127.0.0.1:8080", "127.0.0.1:8080"])
def test_delete_claim_refuses_any_other_scheme_before_opening_it(url, monkeypatch):
    def fake_urlopen(req, timeout):
        raise AssertionError(f"urlopen was called for {req.full_url}")

    monkeypatch.setattr(cleanup.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(SystemExit, match="must start with http:// or https://"):
        cleanup._delete_claim(url, "intake", "sess_1")


def test_a_refused_launcher_url_stops_before_the_session_is_deleted(monkeypatch):
    deleted = []
    sessions = SimpleNamespace(
        retrieve=lambda session_id: SimpleNamespace(id=session_id, status="idle"),
        delete=lambda session_id: deleted.append(session_id),
    )
    client = SimpleNamespace(beta=SimpleNamespace(agents=SimpleNamespace(sessions=sessions)))
    monkeypatch.setattr(cleanup, "make_client", lambda: client)
    monkeypatch.setattr(cleanup.urllib.request, "urlopen",
                        lambda req, timeout: pytest.fail("urlopen was called"))
    monkeypatch.setenv("LAUNCHER_AUTH_TOKEN", "intake")
    monkeypatch.setattr(sys, "argv", ["cleanup.py", "--launcher-url", "file:///etc/hostname", "sess_1"])
    with pytest.raises(SystemExit) as exc:
        cleanup.main()
    assert exc.value.code != 0
    assert deleted == []
