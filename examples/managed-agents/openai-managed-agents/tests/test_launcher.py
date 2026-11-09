"""Tests for the launcher HTTP intake (launch.py) and serve's dispatch read.

The intake is started on a loopback port with a fake dispatcher, and driven with
real HTTP requests, so the auth gate, routing and error handling are exercised
end to end without a cluster. launch.main() runs against a fake pod filesystem
(the credential files and the ServiceAccount token deploy/launcher.yaml mounts),
with the dispatcher and the HTTP server replaced. serve._read_dispatch is tested
directly.

Run with: python -m pytest
"""

from __future__ import annotations

import ipaddress
import json
import logging
import re
import threading
import urllib.error
import urllib.parse
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


def _req(base, path, payload, token=None, method="POST", timeout=10):
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(payload).encode() if payload is not None else None
    # urlopen also opens file:// and other schemes; the fixture's intake is http.
    if urllib.parse.urlsplit(base).scheme != "http":
        raise ValueError(f"the test intake is plain HTTP on loopback, not {base}")
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - http only, checked above
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


def test_liveness_answers_while_a_hand_off_is_in_progress(server):
    # deploy/launcher.yaml's livenessProbe is GET / on the intake. A dispatch
    # blocks until its claim is Ready (minutes on a cold start); the probe must
    # still be answered meanwhile, or the kubelet would restart the launcher
    # and lose the hand-off it holds.
    base, d = server
    entered, release = threading.Event(), threading.Event()
    original = d.dispatch

    def slow_dispatch(**kwargs):
        entered.set()
        release.wait(30)
        return original(**kwargs)

    d.dispatch = slow_dispatch
    result = {}
    poster = threading.Thread(
        target=lambda: result.update(post=_req(base, "/sessions", _GOOD, token=TOKEN)), daemon=True
    )
    poster.start()
    try:
        assert entered.wait(10), "the dispatch never started"
        status, body = _req(base, "/", None, method="GET", timeout=2)
        assert status == 200 and body == {"status": "ok"}
        assert poster.is_alive(), "the hand-off finished before the probe was checked"
    finally:
        release.set()
        poster.join(10)
    assert result["post"][0] == 202


# --- main(): credentials from files, and the ServiceAccount token ------------
EXECUTOR_FILE_VALUE = "executor-key-from-the-mounted-file"
INTAKE_FILE_VALUE = "intake-value-from-the-mounted-file"
FAKE_SA_JWT = "header.payload.signature"  # the fake ServiceAccount file's content


class _FakeServer:
    created = []

    def __init__(self, address, handler):
        self.address, self.handler = address, handler
        _FakeServer.created.append(self)

    def serve_forever(self):
        raise KeyboardInterrupt  # main() treats it as a clean shutdown

    def server_close(self):
        pass


class _RecordingDispatcher:
    built_with = []

    def __init__(self, executor_key):
        _RecordingDispatcher.built_with.append(executor_key)
        self.namespace, self.warmpool = "default", "openai-sandbox-executor"


@pytest.fixture
def launcher_pod(tmp_path, monkeypatch):
    """A launcher's filesystem and env as deploy/launcher.yaml sets them up."""
    for name in (config.ENV_API_KEY, config.ENV_EXECUTOR_API_KEY, config.ENV_CODEX_API_KEY,
                 config.ENV_LAUNCHER_AUTH_TOKEN, "OPENAI_ORG_ID", "OPENAI_ORGANIZATION"):
        monkeypatch.delenv(name, raising=False)
    credentials = tmp_path / "openai-managed-agents"
    credentials.mkdir()
    (credentials / config.ENV_EXECUTOR_API_KEY).write_text(EXECUTOR_FILE_VALUE + "\n")
    (credentials / config.ENV_LAUNCHER_AUTH_TOKEN).write_text(INTAKE_FILE_VALUE)
    monkeypatch.setattr(config, "LAUNCHER_CREDENTIALS_DIR", str(credentials))
    service_account = tmp_path / "serviceaccount"
    service_account.mkdir()
    (service_account / "token").write_text(FAKE_SA_JWT)
    (service_account / "ca.crt").write_text("-----BEGIN CERTIFICATE-----\n")
    monkeypatch.setattr(launch.incluster_config, "SERVICE_TOKEN_FILENAME", str(service_account / "token"))
    monkeypatch.setattr(launch.incluster_config, "SERVICE_CERT_FILENAME", str(service_account / "ca.crt"))
    monkeypatch.setattr(config, "setup_logging", lambda: None)
    monkeypatch.setattr(launch.sandbox, "Dispatcher", _RecordingDispatcher)
    monkeypatch.setattr(launch, "ThreadingHTTPServer", _FakeServer)
    _FakeServer.created.clear()
    _RecordingDispatcher.built_with.clear()
    return credentials, service_account


def test_main_reads_both_credentials_from_files_and_serves(launcher_pod, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    launch.main()
    assert _RecordingDispatcher.built_with == [EXECUTOR_FILE_VALUE]  # trailing newline stripped
    (srv,) = _FakeServer.created
    assert srv.auth_token == INTAKE_FILE_VALUE
    host, port = srv.address
    assert ipaddress.ip_address(host).is_unspecified  # the all-interface pod bind
    assert port == config.DEFAULT_LAUNCHER_PORT
    # The preflight reads the ServiceAccount token but never logs or prints it.
    printed = capsys.readouterr()
    for text in (caplog.text, printed.out, printed.err):
        assert FAKE_SA_JWT not in text


@pytest.mark.parametrize("name", ["token", "ca.crt"])
@pytest.mark.parametrize("state", ["missing", "empty", "whitespace", "directory"])
def test_main_refuses_to_start_without_a_service_account_token(launcher_pod, name, state):
    # automountServiceAccountToken is false; without the hand-mounted volume the
    # launcher must stop at startup, naming the file, before it builds a client
    # or serves the intake. A file of only whitespace counts as empty.
    _, service_account = launcher_pod
    path = service_account / name
    path.unlink()
    if state == "empty":
        path.write_text("")
    elif state == "whitespace":
        path.write_text(" \n\t\n")
    elif state == "directory":
        path.mkdir()
    message = re.escape(f"{path} is missing, empty or only whitespace") + ".*refusing to start"
    with pytest.raises(RuntimeError, match=message) as exc:
        launch.main()
    assert FAKE_SA_JWT not in str(exc.value)
    assert _RecordingDispatcher.built_with == []
    assert _FakeServer.created == []


@pytest.mark.parametrize("padding", [("", "\n"), ("  ", "  ")])
def test_main_accepts_a_token_with_surrounding_whitespace(launcher_pod, padding):
    # The other side of the whitespace check: a real token padded by a newline or
    # spaces is still a token, and the launcher starts.
    _, service_account = launcher_pod
    (service_account / "token").write_text(padding[0] + FAKE_SA_JWT + padding[1])
    launch.main()
    assert len(_FakeServer.created) == 1


@pytest.mark.parametrize("name", [config.ENV_EXECUTOR_API_KEY, config.ENV_LAUNCHER_AUTH_TOKEN])
def test_main_refuses_to_start_without_a_credential_file(launcher_pod, name):
    credentials, _ = launcher_pod
    (credentials / name).unlink()
    with pytest.raises(RuntimeError, match=name):
        launch.main()
    assert _RecordingDispatcher.built_with == []
    assert _FakeServer.created == []


def test_main_never_reads_its_credentials_from_the_environment(launcher_pod, monkeypatch):
    credentials, _ = launcher_pod
    (credentials / config.ENV_LAUNCHER_AUTH_TOKEN).unlink()
    monkeypatch.setenv(config.ENV_LAUNCHER_AUTH_TOKEN, INTAKE_FILE_VALUE)
    with pytest.raises(RuntimeError, match=config.ENV_LAUNCHER_AUTH_TOKEN):
        launch.main()
    assert _FakeServer.created == []


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
