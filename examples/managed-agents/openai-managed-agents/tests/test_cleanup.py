"""Tests for scripts/cleanup.py's launcher call, with the OpenAI client and urlopen faked.

The launcher URL must be http:// or https:// before urlopen sees it, because
urlopen also opens file:// and other schemes. Both ways, per AGENTS.md: an http or
https URL reaches the launcher, any other scheme is refused before anything is
opened, and a refused URL stops the clean up before it deletes the session, so a
session is never deleted while its claim stays.

The order per session is recheck, claim delete, session delete. A claim delete
that fails (502, launcher unreachable) keeps that session, the next session is
still tried, and the exit status is non-zero; a 401 stops at once.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import urllib.error
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


# --- a session is deleted only after its claim is ---------------------------
URL_MARKER = "synthetic-reason-text-must-not-appear"


def _run(monkeypatch, capsys, session_ids, claim_result, *, keep_claim=False):
    """Run main() over ``session_ids``; return its exit code, the call order and the output.

    ``claim_result(session_id)`` returns the claim-delete response body, or
    raises what urlopen would.
    """
    calls = []
    sessions = SimpleNamespace(
        retrieve=lambda session_id: calls.append(("retrieve", session_id))
        or SimpleNamespace(id=session_id, status="idle"),
        delete=lambda session_id: calls.append(("delete", session_id)),
    )
    client = SimpleNamespace(beta=SimpleNamespace(agents=SimpleNamespace(sessions=sessions)))
    monkeypatch.setattr(cleanup, "make_client", lambda: client)

    def fake_urlopen(req, timeout):
        session_id = json.loads(req.data)["session_id"]
        calls.append(("claim-delete", session_id))
        return _Response(claim_result(session_id))

    monkeypatch.setattr(cleanup.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setenv("LAUNCHER_AUTH_TOKEN", "intake")
    argv = ["cleanup.py", *(["--keep-claim"] if keep_claim else []), *session_ids]
    monkeypatch.setattr(sys, "argv", argv)
    with pytest.raises(SystemExit) as exc:
        cleanup.main()
    printed = capsys.readouterr()
    return exc.value.code, calls, printed.out + printed.err


def _http_error(code):
    return urllib.error.HTTPError("http://127.0.0.1:8080/sessions/claim-delete", code, URL_MARKER, None, None)


def test_a_session_is_deleted_after_its_claim(monkeypatch, capsys):
    code, calls, _ = _run(monkeypatch, capsys, ["sess_1"], lambda _s: b'{"claims_deleted": 1}')
    assert code == 0
    assert calls == [("retrieve", "sess_1"), ("claim-delete", "sess_1"), ("delete", "sess_1")]


@pytest.mark.parametrize("failure", ["502", "unreachable"])
def test_a_failed_claim_delete_keeps_the_session_and_fails(monkeypatch, capsys, failure):
    def claim_result(_session_id):
        if failure == "502":
            raise _http_error(502)
        raise urllib.error.URLError(URL_MARKER)

    code, calls, output = _run(monkeypatch, capsys, ["sess_1"], claim_result)
    assert code == 1
    assert calls == [("retrieve", "sess_1"), ("claim-delete", "sess_1")]
    assert "sess_1: session not deleted, because its claim was not" in output
    assert output.count(URL_MARKER) == 0


def test_a_401_stops_before_any_session_is_deleted(monkeypatch, capsys):
    def claim_result(_session_id):
        raise _http_error(401)

    code, calls, _ = _run(monkeypatch, capsys, ["sess_1", "sess_2"], claim_result)
    assert code == "launcher rejected the request (401): LAUNCHER_AUTH_TOKEN does not match the launcher-auth Secret."
    assert calls == [("retrieve", "sess_1"), ("claim-delete", "sess_1")]


def test_a_failed_claim_delete_does_not_stop_the_next_session(monkeypatch, capsys):
    def claim_result(session_id):
        if session_id == "sess_2":
            raise _http_error(502)
        return b'{"claims_deleted": 1}'

    code, calls, _ = _run(monkeypatch, capsys, ["sess_1", "sess_2", "sess_3"], claim_result)
    assert code == 1
    assert calls == [
        ("retrieve", "sess_1"), ("claim-delete", "sess_1"), ("delete", "sess_1"),
        ("retrieve", "sess_2"), ("claim-delete", "sess_2"),
        ("retrieve", "sess_3"), ("claim-delete", "sess_3"), ("delete", "sess_3"),
    ]


def test_keep_claim_deletes_only_the_session(monkeypatch, capsys):
    code, calls, _ = _run(monkeypatch, capsys, ["sess_1"], lambda _s: pytest.fail("claim delete"),
                          keep_claim=True)
    assert code == 0
    assert calls == [("retrieve", "sess_1"), ("delete", "sess_1")]
