"""Exercise the pure evaluator with synthetic AgentGateway logfmt records."""

from __future__ import annotations

import base64
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EVALUATOR = ROOT / "scripts/lib/evaluate-agentgateway-telemetry.mjs"
NODE = shutil.which("node")
TRACE = "1" * 32
OTHER_TRACE = "2" * 32
SPAN_A = "a" * 16
SPAN_B = "b" * 16
GATEWAY_MODEL = "nova-lite"
BEDROCK_MODEL = "amazon.nova-lite-v1:0"


def record(**changes: str | None) -> str:
    fields = {
        "http.status": "200",
        "trace.id": TRACE,
        "span.id": SPAN_A,
        "gen_ai.provider.name": "aws.bedrock",
        "gen_ai.request.model": BEDROCK_MODEL,
        "agw.ai.original_model": GATEWAY_MODEL,
    }
    fields.update(changes)
    return "2026-01-01T00:00:00Z\tINFO\trequest " + " ".join(
        f"{key}={value}" for key, value in fields.items() if value is not None
    )


def evaluate(lines: list[str] | str, **changes: object) -> dict:
    assert NODE is not None, "Node is required for telemetry contract tests"
    payload = {
        "lines": lines,
        "traceId": TRACE,
        "gatewayModel": GATEWAY_MODEL,
        "bedrockModel": BEDROCK_MODEL,
    }
    payload.update(changes)
    # Match the parent validator's import: no filesystem or CLI dependencies.
    source = base64.b64encode(EVALUATOR.read_bytes()).decode()
    program = """
        import { readFileSync } from 'node:fs';
        const { evaluateAgentGatewayTelemetry } = await import(process.argv[1]);
        try {
            const input = JSON.parse(readFileSync(0, 'utf8'));
            console.log(JSON.stringify({ result: evaluateAgentGatewayTelemetry(input) }));
        } catch (error) {
            console.log(JSON.stringify({ error: error.message }));
        }
    """
    completed = subprocess.run(
        [NODE, "--input-type=module", "-e", program,
         "data:text/javascript;base64," + source],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
        timeout=5,
    )
    return json.loads(completed.stdout)


def test_two_spans_one_root_sorted_deduplicated_without_request_id():
    result = evaluate([
        record(**{"span.id": SPAN_B}),
        record(),
        record(),
        record(**{"trace.id": OTHER_TRACE, "http.status": "503"}),
    ])
    assert result == {"result": {
        "traceId": TRACE, "spanIds": [SPAN_A, SPAN_B],
        "provider": "aws.bedrock", "gatewayModel": GATEWAY_MODEL,
        "bedrockModel": BEDROCK_MODEL, "invocationCount": 2,
    }}


def test_ansi_quoted_values_and_escaped_message():
    line = record()
    for value in [TRACE, SPAN_A, GATEWAY_MODEL, BEDROCK_MODEL, "aws.bedrock", "200"]:
        line = line.replace("=" + value, '="' + value + '"')
    line += r' message="quoted \"text\" and \\ slash"'
    result = evaluate("\x1b[32m" + line + "\x1b[0m\r\n")
    assert result["result"]["spanIds"] == [SPAN_A]


@pytest.mark.parametrize("key", [
    "span.id", "gen_ai.provider.name", "agw.ai.original_model",
    "gen_ai.request.model", "http.status",
])
@pytest.mark.parametrize("value", [None, "", '""'])
def test_required_fields_missing_or_empty_rejected(key, value):
    assert "error" in evaluate([record(**{key: value})])


@pytest.mark.parametrize(("key", "value"), [
    ("agw.ai.original_model", "nova-lite-extra"),
    ("gen_ai.request.model", "amazon.nova-lite-v1:0-extra"),
    ("gen_ai.provider.name", "aws.bedrock-extra"),
    ("gen_ai.provider.name", "openai"),
    ("http.status", "201"), ("http.status", "500"), ("http.status", "2000"),
    ("span.id", "0" * 16), ("span.id", "a" * 15),
    ("span.id", "g" * 16), ("span.id", "A" * 16),
])
def test_bad_record_rejected_even_alongside_success(key, value):
    assert "error" in evaluate([record(), record(**{key: value})])


@pytest.mark.parametrize("trace", [
    "", "0" * 32, "1" * 31, "1" * 33, "g" * 32, "A" * 32, None, 123,
])
def test_requested_trace_must_be_lowercase_nonzero_hex(trace):
    assert "error" in evaluate([record()], traceId=trace)


@pytest.mark.parametrize("suffix", [
    f" span.id={SPAN_A}", " http.status=200",
    f" trace.id={OTHER_TRACE}", " extra=one extra=one",
    " extra=", ' extra=""', ' extra="unfinished',
    ' extra="value"junk', r' extra="bad\q"', " extra=one=two",
    " trailing-bare-token",
])
def test_duplicate_or_malformed_target_fields_rejected(suffix):
    assert "error" in evaluate([record(), record() + suffix])


def test_contradictory_same_span_optional_field_rejected():
    assert "error" in evaluate([record() + " duration=1ms",
                                record() + " duration=2ms"])


def test_other_roots_and_embedded_trace_text_are_ignored():
    other = record(**{"trace.id": OTHER_TRACE, "span.id": "invalid"})
    embedded = f'INFO request message="trace.id={TRACE}"'
    prefixed = record().replace("trace.id=", "parent.trace.id=")
    assert evaluate([other, embedded, prefixed, record()])["result"]["invocationCount"] == 1
    assert "error" in evaluate([other, embedded, prefixed])


@pytest.mark.parametrize("lines", [[], "", "\n", ["INFO started"], None, [123]])
def test_no_matching_span_or_malformed_input_rejected(lines):
    assert "error" in evaluate(lines)


@pytest.mark.parametrize("name", ["gatewayModel", "bedrockModel"])
@pytest.mark.parametrize("value", ["", " ", None, 123])
def test_model_arguments_required(name, value):
    assert "error" in evaluate([record()], **{name: value})


def test_same_span_reordered_fields_deduplicated():
    line = record()
    reordered = " ".join(reversed(line.split()[3:]))
    assert evaluate([line, reordered])["result"]["invocationCount"] == 1
