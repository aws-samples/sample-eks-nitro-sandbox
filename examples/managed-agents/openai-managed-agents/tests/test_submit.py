"""Tests for scripts/submit.py session creation, with the OpenAI client mocked.

These assert the behaviour a reader running the documented defaults depends on,
without a live call:

  * the default budget asks for spend_control, but a project that does not
    accept a session budget still gets a session: submit.py drops spend_control
    and retries once, so `python scripts/submit.py` works unchanged rather than
    forcing the reader to pass --budget-cents 0. Two refusals count: a 400
    'Session budget configuration is not enabled' (param spend_control), and a
    400 whose error code is unknown_parameter and whose param is spend_control
    ("Unknown parameter: 'spend_control'.", what a new project returned);
  * --budget-cents 0 asks for no spend_control at all;
  * any OTHER error is NOT swallowed -- it propagates, so a real bad request is
    not hidden by the fallback: an unrelated 400, an unknown_parameter on another
    param, another spend_control 400, a 400 that only names those words in its
    message, and an error that is not a 400.

And, against a mocked event stream, the order a turn runs in:

  * the event stream is open before the launcher hand-off starts the executor;
  * no input is sent before agent.session.environment.connected, and the input
    is sent after it;
  * agent.session.environment.failed, or no connection within --connect-timeout,
    sends nothing and exits non-zero;
  * a follow-up turn whose environment is already connected proceeds, and an
    environment status the API will not return falls back to the stream's event;
  * only this session's own environment opens the gate: a connected or failed
    event for another session or another environment is ignored, and a status
    the API returns for another environment id is not trusted;
  * a stream that keeps replaying an event it already sent cannot hold the wait
    open past --connect-timeout.

Both inputs of each accept/reject pair are exercised, per AGENTS.md.

Run with: python -m pytest
"""

from __future__ import annotations

import importlib.util
import itertools
import pathlib
import sys
import threading
import time
from types import SimpleNamespace

import pytest

import httpx2 as httpx  # the HTTP library openai 3.31.0 ships with
from openai import BadRequestError, NotFoundError, UnprocessableEntityError


def _load_submit():
    scripts_dir = pathlib.Path(__file__).resolve().parent.parent / "scripts"
    sys.path.insert(0, str(scripts_dir))  # so submit.py's `from _client import ...` resolves
    try:
        spec = importlib.util.spec_from_file_location("submit_under_test", scripts_dir / "submit.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(scripts_dir))


submit = _load_submit()


def _api_error(cls, status: int, message: str, param: str | None, code: str | None = None):
    """Build a real SDK status error the way the SDK would, so .body/.code/.param are set.

    The SDK passes the inner `error` object as `body` (see openai/_client.py,
    _make_status_error), and its `message` is the whole "Error code: ..." string.
    """
    request = httpx.Request("POST", "https://api.openai.com/v1/agents/sessions")
    body = {"error": {"message": message, "param": param, "type": "invalid_request_error"}}
    if code is not None:
        body["error"]["code"] = code
    response = httpx.Response(status, request=request, json=body)
    return cls(f"Error code: {status} - {body}", response=response, body=body["error"])


def _bad_request(message: str, param: str | None, code: str | None = None) -> BadRequestError:
    return _api_error(BadRequestError, 400, message, param, code)


# The refusal a new project returned for a session created with spend_control.
UNKNOWN_SPEND_CONTROL = dict(message="Unknown parameter: 'spend_control'.",
                             param="spend_control", code="unknown_parameter")


class _SessionsRecorder:
    """Records each sessions.create call and can fail the first with a chosen error."""

    def __init__(self, first_error: Exception | None = None):
        self._first_error = first_error
        self.calls: list[dict] = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        if self._first_error is not None and len(self.calls) == 1:
            raise self._first_error
        return object()  # a stand-in session; the fallback path does not read it


class _Client:
    def __init__(self, sessions):
        self.beta = type("B", (), {"agents": type("A", (), {"sessions": sessions})()})()


# --- the predicate: accepted -------------------------------------------------
def test_predicate_matches_spend_control_not_enabled_by_param():
    exc = _bad_request("Session budget configuration is not enabled", param="spend_control")
    assert submit._is_spend_control_unsupported(exc) is True


def test_predicate_does_not_match_not_enabled_words_without_the_param():
    # Words in a message are not the refusal: the body must name param spend_control.
    exc = _bad_request("spend_control is not enabled for this project", param=None)
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_another_not_enabled_message_on_spend_control():
    exc = _bad_request("The audit feature is not enabled; the request also mentioned spend_control.",
                       param="spend_control")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_matches_unknown_parameter_spend_control():
    exc = _bad_request(**UNKNOWN_SPEND_CONTROL)
    assert submit._is_spend_control_unsupported(exc) is True


# --- the predicate: rejected -------------------------------------------------
def test_predicate_does_not_match_an_unrelated_400():
    exc = _bad_request("model is required", param="model")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_unknown_parameter_on_another_param():
    exc = _bad_request("Unknown parameter: 'budget'.", param="budget", code="unknown_parameter")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_another_spend_control_400():
    exc = _bad_request("spend_control.limit must be a positive integer.",
                       param="spend_control", code="invalid_value")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_reads_code_and_param_from_the_body_not_the_message():
    # The words are in the message, but the structured fields say otherwise.
    exc = _bad_request("unknown_parameter spend_control appears only in this text",
                       param="input", code="invalid_value")
    assert submit._is_spend_control_unsupported(exc) is False


def test_predicate_does_not_match_an_error_that_is_not_a_400():
    exc = _api_error(UnprocessableEntityError, 422, **UNKNOWN_SPEND_CONTROL)
    assert submit._is_spend_control_unsupported(exc) is False


# --- create_session fallback: accepted ---------------------------------------
@pytest.mark.parametrize("error", [
    _bad_request("Session budget configuration is not enabled", param="spend_control"),
    _bad_request(**UNKNOWN_SPEND_CONTROL),
], ids=["not-enabled", "unknown-parameter"])
def test_spend_control_400_is_tolerated_and_retried_without_it(capsys, error):
    sessions = _SessionsRecorder(first_error=error)
    client = _Client(sessions)

    submit.create_session(client, "agent_1", {"limit": 100})

    assert len(sessions.calls) == 2, "should retry exactly once"
    assert "spend_control" in sessions.calls[0], "first attempt asks for the budget"
    assert "spend_control" not in sessions.calls[1], "retry drops the budget"
    first_without_budget = {k: v for k, v in sessions.calls[0].items() if k != "spend_control"}
    assert sessions.calls[1] == first_without_budget, "the retry changes nothing else"
    out = capsys.readouterr().out  # the reader is told why, and what it means
    assert "does not accept a session budget" in out
    assert "no budget ceiling" in out


# --- create_session fallback: rejected ---------------------------------------
@pytest.mark.parametrize("error", [
    _bad_request("model is required", param="model"),
    _bad_request("Unknown parameter: 'budget'.", param="budget", code="unknown_parameter"),
    _bad_request("spend_control.limit must be a positive integer.",
                 param="spend_control", code="invalid_value"),
    _api_error(UnprocessableEntityError, 422, **UNKNOWN_SPEND_CONTROL),
], ids=["unrelated-400", "unknown-parameter-other-param", "other-spend-control-400", "not-a-400"])
def test_other_errors_are_not_swallowed(error):
    sessions = _SessionsRecorder(first_error=error)
    client = _Client(sessions)

    with pytest.raises(type(error)) as raised:
        submit.create_session(client, "agent_1", {"limit": 100})
    assert raised.value is error, "the original error propagates unchanged"
    assert len(sessions.calls) == 1, "an error that is not the budget refusal is not retried"


# --- the same, through the real SDK client and its own error parsing ----------
def _sdk_client(refusal: dict, calls: list):
    """A real OpenAI client whose transport refuses any create that asks for spend_control."""
    import json

    from openai import OpenAI

    def handler(request):
        body = json.loads(request.content)
        calls.append(sorted(body))
        if "spend_control" in body:
            return httpx.Response(400, json={"error": refusal})
        return httpx.Response(200, json={"id": "sesn_test", "object": "agent.session"})

    # The transport is mocked, so no request leaves the process and the key is a placeholder.
    return OpenAI(api_key="not-used",  # pragma: allowlist secret
                  base_url="https://api.openai.test/v1", max_retries=0,
                  http_client=httpx.Client(transport=httpx.MockTransport(handler)))


def test_the_live_refusal_through_the_sdk_is_retried_without_a_budget():
    calls: list = []
    refusal = {"type": "invalid_request_error", "code": "unknown_parameter",
               "message": "Unknown parameter: 'spend_control'.", "param": "spend_control"}

    session = submit.create_session(_sdk_client(refusal, calls), "agent_1", {"limit": 100})

    assert session.id == "sesn_test"
    assert len(calls) == 2 and "spend_control" in calls[0] and "spend_control" not in calls[1]


def test_unknown_parameter_on_another_param_through_the_sdk_is_raised():
    calls: list = []
    refusal = {"type": "invalid_request_error", "code": "unknown_parameter",
               "message": "Unknown parameter: 'metadata'.", "param": "metadata"}

    with pytest.raises(BadRequestError):
        submit.create_session(_sdk_client(refusal, calls), "agent_1", {"limit": 100})
    assert len(calls) == 1


def test_budget_cents_zero_sends_no_spend_control():
    sessions = _SessionsRecorder()
    client = _Client(sessions)

    submit.create_session(client, "agent_1", None)

    assert len(sessions.calls) == 1
    assert "spend_control" not in sessions.calls[0]


def test_a_budget_is_passed_through_when_the_project_supports_it():
    sessions = _SessionsRecorder()
    client = _Client(sessions)

    submit.create_session(client, "agent_1", {"limit": 100})

    assert len(sessions.calls) == 1
    assert sessions.calls[0]["spend_control"] == {"limit": 100}


# --- the turn waits for the environment to connect ---------------------------
_ids = itertools.count(1)


def _event(kind: str, **fields):
    return SimpleNamespace(type=kind, event_id=f"evt_{next(_ids)}", **fields)


SESSION, ENVIRONMENT = "sess_1", "env_1"  # the ids of _FakeAPI's session and its environment


def _env_event(kind: str, status: str, session_id: str = SESSION, environment_id: str = ENVIRONMENT, **env):
    """An environment event as the SDK models it: its session_id and environment.id are set."""
    return _event(kind, session_id=session_id,
                  environment=SimpleNamespace(id=environment_id, status=status, **env))


def _connected(**ids):
    return _env_event("agent.session.environment.connected", "connected", **ids)


def _pending(**ids):
    return _env_event("agent.session.environment.pending", "pending", **ids)


def _failed(error: str, **ids):
    return _env_event("agent.session.environment.failed", "failed", error=error, **ids)


def _turn(text: str = "hello from the sandbox"):
    """The events of one finished turn, as the stream sends them after the input."""
    turn = SimpleNamespace(subagent_id=None, error=None)
    return [
        _event("agent.session.in_progress"),
        _event("agent.session.turn.created", turn=turn, turn_id="turn_1"),
        _event("agent.session.turn.output_text.delta", delta=text),
        _event("agent.session.turn.completed", turn=turn, turn_id="turn_1"),
        _event("agent.session.idle"),
    ]


class _FakeAPI:
    """The SDK calls submit.py makes for a turn, recording the order they happen in.

    The stream yields `before_input` at once. It yields `after_input` only once an
    input has been sent, then holds the connection open until it is closed, the way
    a live session's stream stays open.
    """

    def __init__(self, before_input, after_input=(), env_status="pending", env_error=None,
                 env_retrieved_id=None):
        self.before_input = list(before_input)
        self.after_input = list(after_input)
        self.env_status = env_status
        self.env_error = env_error
        self.env_retrieved_id = env_retrieved_id  # the id the status read returns, if not the one asked for
        self.log: list[str] = []
        self.inputs: list[list] = []
        self.input_before_connected = None
        self._sent = threading.Event()
        self._closed = threading.Event()
        events = SimpleNamespace(stream=self._stream, create=self._send)
        sessions = SimpleNamespace(create=self._create_session, retrieve=self._retrieve_session, events=events)
        environments = SimpleNamespace(retrieve=self._retrieve_environment)
        self.beta = SimpleNamespace(agents=SimpleNamespace(sessions=sessions, environments=environments))

    def _create_session(self, **kwargs):
        env = SimpleNamespace(type="self_hosted", id="env_1", remote_url="https://remote.test/rt")
        return SimpleNamespace(id="sess_1", environment=env)

    def _retrieve_session(self, session_id):
        return SimpleNamespace(id=session_id, status="idle", environment=SimpleNamespace(id="env_1"))

    def _retrieve_environment(self, environment_id):
        self.log.append("environment status read")
        if self.env_error is not None:
            raise self.env_error
        return SimpleNamespace(id=self.env_retrieved_id or environment_id, status=self.env_status)

    def _send(self, session_id, *, events, idempotency_key):
        self.log.append("input sent")
        self.inputs.append(events)
        self._sent.set()

    def _events(self):
        for event in self.before_input:
            if event.type == "agent.session.environment.connected":
                time.sleep(0.05)  # room for an early input to land first
                self.input_before_connected = self._sent.is_set()
            self.log.append(f"yield {event.type}")
            yield event
        if self.after_input and self._sent.wait(5):
            for event in self.after_input:
                self.log.append(f"yield {event.type}")
                yield event
        self._closed.wait(10)

    def _stream(self, session_id):
        self.log.append("stream opened")
        api = self

        class _Stream:
            def __iter__(self):
                return api._events()

            def close(self):
                api.log.append("stream closed")
                api._closed.set()

        return _Stream()


def _run_main(monkeypatch, api, *argv):
    """Run submit.main() against `api`, with the launcher hand-off recorded, not sent."""
    monkeypatch.setattr(submit, "make_client", lambda: api)
    monkeypatch.setattr(submit, "hand_off_to_launcher", lambda *a: api.log.append("hand-off"))
    monkeypatch.setenv("AGENT_ID", "agent_1")
    monkeypatch.setenv("LAUNCHER_AUTH_TOKEN", "test-token")  # pragma: allowlist secret
    monkeypatch.setattr(sys, "argv", ["submit.py", *argv])
    with pytest.raises(SystemExit) as raised:
        submit.main()
    return raised.value.code


def test_first_turn_sends_no_input_before_the_environment_connects(monkeypatch):
    api = _FakeAPI(before_input=[_pending(), _pending(), _connected()], after_input=_turn())

    _run_main(monkeypatch, api, "--budget-cents", "0", "do the task")

    assert api.input_before_connected is False, "the input went before the environment connected"
    assert api.log.index("input sent") > api.log.index("yield agent.session.environment.connected")


def test_first_turn_sends_the_input_after_the_environment_connects(monkeypatch, capsys):
    api = _FakeAPI(before_input=[_pending(), _connected()], after_input=_turn())

    code = _run_main(monkeypatch, api, "--budget-cents", "0", "do the task")

    assert code == 0
    assert api.log.index("stream opened") < api.log.index("hand-off"), "the stream opens before the executor starts"
    assert api.log.index("hand-off") < api.log.index("input sent")
    assert len(api.inputs) == 1
    assert api.inputs[0] == [{"type": "agent.session.input.message",
                              "input": [{"role": "user", "content": [{"type": "input_text", "text": "do the task"}]}]}]
    assert "stream closed" in api.log
    out = capsys.readouterr().out
    assert "[environment connected]" in out and "hello from the sandbox" in out
    assert "final status: idle" in out


def test_environment_failed_sends_nothing_and_exits_non_zero(monkeypatch, capsys):
    api = _FakeAPI(before_input=[_pending(), _failed("executor registration refused")], after_input=_turn())

    code = _run_main(monkeypatch, api, "--budget-cents", "0", "--connect-timeout", "2", "do the task")

    assert code not in (0, None)
    assert "environment failed" in str(code) and "no prompt was sent" in str(code)
    assert api.inputs == [] and "input sent" not in api.log
    assert "stream closed" in api.log


def test_no_connection_within_the_timeout_sends_nothing_and_exits_non_zero(monkeypatch):
    api = _FakeAPI(before_input=[_pending()], after_input=_turn())

    start = time.monotonic()
    code = _run_main(monkeypatch, api, "--budget-cents", "0", "--connect-timeout", "0.3", "do the task")
    elapsed = time.monotonic() - start

    assert code not in (0, None)
    assert "did not connect within 0.3s" in str(code) and "no prompt was sent" in str(code)
    assert api.inputs == [] and "input sent" not in api.log
    assert 0.3 <= elapsed < 5
    assert "stream closed" in api.log


def test_follow_up_turn_with_the_environment_already_connected_proceeds(monkeypatch, capsys):
    # No connection event comes: the environment connected during the first turn.
    api = _FakeAPI(before_input=[], after_input=_turn("first line"), env_status="connected")

    start = time.monotonic()
    code = _run_main(monkeypatch, api, "--session-id", "sess_1", "--connect-timeout", "3", "read it back")

    assert code == 0
    assert time.monotonic() - start < 2, "an already-connected environment must not wait for the timeout"
    assert api.log.index("environment status read") < api.log.index("input sent")
    assert len(api.inputs) == 1
    out = capsys.readouterr().out
    assert "[environment already connected]" in out and "first line" in out


def test_follow_up_turn_with_the_environment_not_connected_waits(monkeypatch):
    api = _FakeAPI(before_input=[], after_input=_turn(), env_status="disconnected")

    code = _run_main(monkeypatch, api, "--session-id", "sess_1", "--connect-timeout", "0.3", "read it back")

    assert code not in (0, None) and "did not connect" in str(code)
    assert api.inputs == []


def test_an_unreadable_environment_status_falls_back_to_the_connection_event(monkeypatch, capsys):
    error = _api_error(NotFoundError, 404, "No environment found", param=None)
    api = _FakeAPI(before_input=[_pending(), _connected()], after_input=_turn(), env_error=error)

    code = _run_main(monkeypatch, api, "--budget-cents", "0", "do the task")

    assert code == 0
    assert api.input_before_connected is False
    assert "could not read the environment's status (HTTP 404)" in capsys.readouterr().out


# --- only this session's own environment opens the gate ----------------------
OTHERS = pytest.mark.parametrize("other", [
    dict(environment_id="env_other"),
    dict(session_id="sess_other"),
], ids=["another-environment", "another-session"])


@OTHERS
def test_a_connected_event_for_another_session_or_environment_sends_nothing(monkeypatch, other):
    api = _FakeAPI(before_input=[_pending(), _connected(**other)], after_input=_turn())

    code = _run_main(monkeypatch, api, "--budget-cents", "0", "--connect-timeout", "0.3", "do the task")

    assert code not in (0, None)
    assert "did not connect within 0.3s" in str(code) and "no prompt was sent" in str(code)
    assert api.inputs == [] and "input sent" not in api.log


@OTHERS
def test_a_failed_event_for_another_session_or_environment_is_ignored(monkeypatch, other):
    api = _FakeAPI(before_input=[_failed("not this environment", **other), _connected()], after_input=_turn())

    code = _run_main(monkeypatch, api, "--budget-cents", "0", "--connect-timeout", "2", "do the task")

    assert code == 0, "another environment's failure stopped this turn"
    assert len(api.inputs) == 1


def test_the_matching_connected_event_after_unrelated_ones_sends_the_input(monkeypatch):
    api = _FakeAPI(before_input=[_connected(environment_id="env_other"), _connected(session_id="sess_other"),
                                 _connected()], after_input=_turn())

    code = _run_main(monkeypatch, api, "--budget-cents", "0", "do the task")

    assert code == 0
    assert api.input_before_connected is False, "an unrelated connected event let the input go first"
    last_connected = max(i for i, line in enumerate(api.log) if line == "yield agent.session.environment.connected")
    assert api.log.index("input sent") > last_connected
    assert len(api.inputs) == 1


def test_a_connected_status_for_another_environment_id_is_not_trusted(monkeypatch, capsys):
    # The status read answers "connected", but for another id: wait for this one's event.
    api = _FakeAPI(before_input=[], after_input=_turn(), env_status="connected", env_retrieved_id="env_other")

    code = _run_main(monkeypatch, api, "--session-id", "sess_1", "--connect-timeout", "0.3", "read it back")

    assert code not in (0, None) and "did not connect" in str(code)
    assert api.inputs == []
    assert "the status of another environment" in capsys.readouterr().out


def test_a_failed_status_for_another_environment_id_does_not_stop_the_turn(monkeypatch):
    api = _FakeAPI(before_input=[_connected()], after_input=_turn(), env_status="failed",
                   env_retrieved_id="env_other")

    code = _run_main(monkeypatch, api, "--session-id", "sess_1", "--connect-timeout", "2", "read it back")

    assert code == 0
    assert len(api.inputs) == 1


# --- replayed duplicates cannot stretch --connect-timeout (second review) -----
class _Stream:
    def __init__(self, events):
        self._events = events

    def __iter__(self):
        return iter(self._events)

    def close(self):
        pass


def test_duplicate_events_cannot_extend_the_absolute_connection_deadline():
    # Duplicates of one event id arrive for 0.25 s, then a connected event: with a
    # 0.05 s timeout the wait must give up first, not accept the late connection.
    duplicate = _pending()

    def delayed_events():
        yield duplicate
        until = time.monotonic() + 0.25
        while time.monotonic() < until:
            yield duplicate
            time.sleep(0.005)
        yield _connected()

    environments = SimpleNamespace(retrieve=lambda env_id: SimpleNamespace(id=env_id, status="pending"))
    client = SimpleNamespace(beta=SimpleNamespace(agents=SimpleNamespace(environments=environments)))
    pump = submit._EventPump(_Stream(delayed_events()))
    started = time.monotonic()
    try:
        with pytest.raises(SystemExit, match="did not connect within 0.05s"):
            submit.wait_for_environment(client, pump, SESSION, ENVIRONMENT, 0.05)
    finally:
        pump.close()
    assert time.monotonic() - started < 0.2


# --- the launcher URL must be http or https before urlopen sees it -----------
class _Response:
    def __init__(self, body: bytes):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.mark.parametrize("url", ["http://127.0.0.1:8080/sessions", "https://launcher.example/sessions"])
def test_post_accepts_an_http_or_https_launcher_url(url, monkeypatch):
    opened = []

    def fake_urlopen(req, timeout):
        opened.append(req.full_url)
        return _Response(b'{"sandbox": "sandbox-claim-x"}')

    monkeypatch.setattr(submit.urllib.request, "urlopen", fake_urlopen)
    assert submit._post(url, {"session_id": SESSION}, "intake", 5) == {"sandbox": "sandbox-claim-x"}
    assert opened == [url]


@pytest.mark.parametrize("url", ["file:///etc/hostname", "ftp://127.0.0.1/sessions", "127.0.0.1:8080/sessions"])
def test_post_refuses_any_other_scheme_before_opening_it(url, monkeypatch):
    def fake_urlopen(req, timeout):
        raise AssertionError(f"urlopen was called for {req.full_url}")

    monkeypatch.setattr(submit.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(SystemExit, match="must start with http:// or https://"):
        submit._post(url, {"session_id": SESSION}, "intake", 5)
