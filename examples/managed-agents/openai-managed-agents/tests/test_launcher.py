"""Tests for the launcher HTTP intake (launch.py) and serve's dispatch read.

The intake is started on a loopback port with a fake dispatcher, and driven with
real HTTP requests, so the auth gate, routing and error handling are exercised
end to end without a cluster. serve._read_dispatch is tested directly.

Run with: python -m pytest
"""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from launcher import config, launch, serve

TOKEN = "test-launcher-token-abc123"
REMOTE = "https://codex-cloud-environments.chatgpt.com/e/env_1"
SECRET_KEY = "sk-key-must-not-leak-to-a-client"


class _FakeDispatcher:
    def __init__(self):
        self.namespace = "default"
        self.warmpool = "openai-sandbox-executor"
        self.dispatched_with = None
        self.deleted_session = None
        self.raise_on_dispatch = False

    def dispatch(self, *, session_id, environment_id, remote_url):
        self.dispatched_with = (session_id, environment_id, remote_url)
        if self.raise_on_dispatch:
            raise RuntimeError(SECRET_KEY)  # even an error must not leak a secret to the client
        return {"sandbox": "openai-sandbox-executor-xyz", "reused": False}

    def delete_claim_for_session(self, session_id):
        self.deleted_session = session_id
        return 1


@pytest.fixture
def server():
    dispatcher = _FakeDispatcher()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), launch._Handler)
    httpd.dispatcher = dispatcher
    httpd.auth_token = TOKEN
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    host, port = httpd.server_address
    base = f"http://{host}:{port}"
    try:
        yield base, dispatcher
    finally:
        httpd.shutdown()
        httpd.server_close()


def _req(base, path, payload, token=None, method="POST"):
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


_GOOD = {"session_id": "sesn_a", "environment_id": "env_a", "remote_url": REMOTE}


# --- authentication ----------------------------------------------------------
def test_dispatch_without_token_is_401(server):
    base, d = server
    status, _ = _req(base, "/sessions", _GOOD, token=None)
    assert status == 401
    assert d.dispatched_with is None  # never reached the dispatcher


def test_dispatch_with_wrong_token_is_401(server):
    base, d = server
    status, _ = _req(base, "/sessions", _GOOD, token="wrong-token")
    assert status == 401
    assert d.dispatched_with is None


def test_dispatch_with_right_token_succeeds(server):
    base, d = server
    status, body = _req(base, "/sessions", _GOOD, token=TOKEN)
    assert status == 202
    assert body["sandbox"] == "openai-sandbox-executor-xyz"
    assert d.dispatched_with == ("sesn_a", "env_a", REMOTE)


# --- routing and validation --------------------------------------------------
def test_bad_field_is_400(server):
    base, _ = server
    status, _ = _req(base, "/sessions", {**_GOOD, "remote_url": "http://insecure"}, token=TOKEN)
    assert status == 400


def test_unknown_path_is_404(server):
    base, _ = server
    status, _ = _req(base, "/nope", _GOOD, token=TOKEN)
    assert status == 404


def test_claim_delete_route(server):
    base, d = server
    status, body = _req(base, "/sessions/claim-delete", {"session_id": "sesn_a"}, token=TOKEN)
    assert status == 200
    assert body["claims_deleted"] == 1
    assert d.deleted_session == "sesn_a"


def test_claim_delete_requires_token(server):
    base, d = server
    status, _ = _req(base, "/sessions/claim-delete", {"session_id": "sesn_a"}, token=None)
    assert status == 401
    assert d.deleted_session is None


def test_get_is_an_unauthenticated_health_probe(server):
    base, _ = server
    status, body = _req(base, "/", None, token=None, method="GET")
    assert status == 200
    assert body["status"] == "ok"


# --- a dispatch error must not leak a secret to the client -------------------
def test_dispatch_error_response_has_no_secret(server):
    base, d = server
    d.raise_on_dispatch = True
    status, body = _req(base, "/sessions", _GOOD, token=TOKEN)
    assert status == 502
    assert SECRET_KEY not in json.dumps(body)
    assert body["detail"] == "RuntimeError"  # the type only, never the message


# --- serve._read_dispatch ----------------------------------------------------
def _set_claim_env(monkeypatch, **over):
    vals = {
        config.ENV_SESSION_ID: "sesn_a",
        config.ENV_ENVIRONMENT_ID: "env_a",
        config.ENV_REMOTE_URL: REMOTE,
        config.ENV_CODEX_API_KEY: SECRET_KEY,
    }
    vals.update(over)
    for name in (config.ENV_SESSION_ID, config.ENV_ENVIRONMENT_ID,
                 config.ENV_REMOTE_URL, config.ENV_CODEX_API_KEY):
        monkeypatch.delenv(name, raising=False)
    for k, v in vals.items():
        if v is not None:
            monkeypatch.setenv(k, v)


def test_read_dispatch_ok(monkeypatch):
    _set_claim_env(monkeypatch)
    d = serve._read_dispatch()
    assert d == {"session_id": "sesn_a", "environment_id": "env_a", "remote_url": REMOTE}


def test_read_dispatch_rejects_bad_remote(monkeypatch):
    _set_claim_env(monkeypatch, **{config.ENV_REMOTE_URL: "http://insecure"})
    with pytest.raises(RuntimeError, match="remote URL"):
        serve._read_dispatch()


def test_read_dispatch_requires_key(monkeypatch):
    _set_claim_env(monkeypatch, **{config.ENV_CODEX_API_KEY: None})
    with pytest.raises(RuntimeError, match=config.ENV_CODEX_API_KEY):
        serve._read_dispatch()
