"""Run the production gateway challenge with synthetic, offline responses."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "validate-live.sh"
NODE = shutil.which("node")
TRACE_PREFIX = "SYNTHETIC_REQUEST_TRACE="


def _guest_program() -> str:
    function = re.search(
        r"^verify_agentgateway_key_contract\(\) \{\n.*?^\}",
        SCRIPT.read_text(encoding="utf-8"),
        re.MULTILINE | re.DOTALL,
    )
    assert function is not None, "production key-contract function is missing"
    program = re.search(r"node -e '(.*?)\n\s*' >", function[0], re.DOTALL)
    assert program is not None, "production key-contract JavaScript is missing"
    return program[1]


# Only HTTPS and the guest's CA read are mocked. Crypto uses real host entropy;
# a transparent spy counts real operand draws without replacing their values.
# replies derive their expected answer from each outgoing production prompt.
# No real network, files containing credentials, cloud, or container is accessed.
HARNESS = textwrap.dedent(
    r"""
    const assert = require("node:assert/strict");
    const crypto = require("node:crypto");
    const { EventEmitter } = require("node:events");
    const vm = require("node:vm");
    const calls = [];
    let operandDrawCount = 0;
    let positiveCount = 0;
    let previousExpected = "";
    const observedCrypto = new Proxy(crypto, {
      get(target, property) {
        if (property !== "randomInt") return target[property];
        return (...args) => {
          operandDrawCount++;
          return target.randomInt(...args);
        };
      }
    });
    process.on("exit", () => {
      process.stderr.write(
        "\nSYNTHETIC_REQUEST_TRACE=" + JSON.stringify(calls) + "\n"
      );
    });

    const fakeFs = {
      readFileSync(path) {
        assert.equal(path, "/etc/agentgateway-ca/ca.crt");
        return Buffer.from("synthetic CA fixture");
      }
    };
    const fakeHttps = {
      request(options, callback) {
        assert.equal(options.path, "/v1/responses");
        assert.equal(options.method, "POST");
        assert.equal(options.rejectUnauthorized, true);
        assert.equal(options.ca.toString(), "synthetic CA fixture");
        const operation = new EventEmitter();
        operation.setTimeout = () => operation;
        operation.destroy = error => operation.emit("error", error);
        operation.end = body => {
          const payload = JSON.parse(body);
          assert.equal(payload.model, "nova-lite");
          const challenge = payload.input.match(
            /nonce is ([0-9a-f]{24})\. Calculate (\d+) \+ (\d+)\./
          );
          assert.ok(challenge, "production request must carry a nonce and sum");
          const [, nonce, leftText, rightText] = challenge;
          const left = Number(leftText);
          const right = Number(rightText);
          const expected = `${nonce}:${left + right}`;
          const authorization = options.headers.authorization;
          let kind;
          if (authorization === undefined) kind = "missing";
          else if (authorization === "Bearer x") kind = "valid";
          else {
            assert.match(authorization, /^Bearer wrong-[0-9a-f]{48}$/);
            kind = "wrong";
          }
          calls.push({ kind, nonce, left, right, operandDrawCount });
          let status;
          let responseBody;
          if (kind !== "valid") {
            status = kind === "missing" ? scenario.missing : scenario.wrong;
            responseBody = JSON.stringify({ error: "synthetic denied response" });
          } else {
            const response = scenario.positive[positiveCount++];
            assert.ok(response, "unexpected extra positive request");
            status = response.status ?? 200;
            if (response.mode === "malformed") {
              responseBody = "{synthetic invalid JSON";
            } else {
              let text = expected;
              if (response.mode === "math") text = `${nonce}:${left + right + 1}`;
              if (response.mode === "nonce") {
                const otherNonce = (nonce[0] === "0" ? "1" : "0") + nonce.slice(1);
                text = `${otherNonce}:${left + right}`;
              }
              if (response.mode === "empty") text = "";
              if (response.mode === "stale") text = previousExpected || "stale";
              if (response.mode === "normalized") {
                text = " \n" + expected.replace(
                  /[0-9a-f:]/g,
                  value => String.fromCharCode(value.charCodeAt(0) + 0xfee0)
                ) + "\n ";
              }
              const output = response.nested ? {
                output: [
                  { content: [{ type: "reasoning", text: "ignored fixture" }] },
                  { content: [
                    { type: "output_text", text: text.slice(0, 12) },
                    { type: "output_text", text: text.slice(12) }
                  ] }
                ]
              } : { output_text: text };
              responseBody = JSON.stringify(output);
            }
            previousExpected = expected;
          }
          queueMicrotask(() => {
            const response = new EventEmitter();
            response.statusCode = status;
            response.setEncoding = encoding => assert.equal(encoding, "utf8");
            callback(response);
            response.emit("data", responseBody);
            response.emit("end");
          });
        };
        return operation;
      }
    };
    vm.runInNewContext(productionProgram, {
      Buffer,
      process,
      require(name) {
        if (name === "node:crypto") return observedCrypto;
        if (name === "node:fs") return fakeFs;
        if (name === "node:https") return fakeHttps;
        throw new Error("Unexpected guest dependency: " + name);
      }
    }, { filename: "production-agentgateway-key-contract.js" });
    """
)


@pytest.fixture
def run_contract():
    assert NODE is not None, "Node is required to execute the production contract"

    def run(positive, *, missing=401, wrong=401):
        scenario = {"missing": missing, "wrong": wrong, "positive": positive}
        result = subprocess.run(
            [
                NODE,
                "-e",
                f"const scenario = {json.dumps(scenario)};\n"
                f"const productionProgram = {json.dumps(_guest_program())};\n"
                + HARNESS,
            ],
            # Deliberately low-entropy synthetic auth fixture; never deployable.
            check=False,
            env={"OPENAI_API_KEY": "x"},
            capture_output=True,
            text=True,
            timeout=5,
        )
        traces = [
            line.removeprefix(TRACE_PREFIX)
            for line in result.stderr.splitlines()
            if line.startswith(TRACE_PREFIX)
        ]
        assert len(traces) == 1, result.stderr
        calls = json.loads(traces[0])
        result.stderr = "\n".join(
            line
            for line in result.stderr.splitlines()
            if not line.startswith(TRACE_PREFIX)
        ).strip()
        return result, calls

    return run


def _positive_calls(calls):
    return [call for call in calls if call["kind"] == "valid"]


def _assert_success(result, *, missing=401, wrong=401):
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "marker": "LIVE_AGENTGATEWAY_KEY_CONTRACT",
        "noKeyStatus": missing,
        "wrongKeyStatus": wrong,
        "acceptedStatus": 200,
        "challengeMatch": True,
    }


def _assert_fresh_challenges(calls):
    positives = _positive_calls(calls)
    assert len({call["nonce"] for call in positives}) == len(positives)
    for attempt, call in enumerate(positives, start=1):
        assert 100 <= call["left"] < 500
        assert 100 <= call["right"] < 500
        assert call["operandDrawCount"] == attempt * 2
    # Negative auth probes share the first positive challenge.
    for field in ("nonce", "left", "right"):
        assert calls[0][field] == calls[1][field] == positives[0][field]


@pytest.mark.parametrize(
    "response,missing,wrong",
    [
        ({}, 401, 401),
        ({"nested": True}, 403, 403),
        ({"mode": "normalized"}, 401, 403),
    ],
)
def test_first_correct_reply_preserves_exact_five_field_evidence(
    run_contract, response, missing, wrong
):
    result, calls = run_contract([response], missing=missing, wrong=wrong)

    _assert_success(result, missing=missing, wrong=wrong)
    assert [call["kind"] for call in calls] == ["missing", "wrong", "valid"]
    assert result.stderr == ""


@pytest.mark.parametrize("mode", ["math", "nonce"])
def test_first_mismatch_retries_fresh_challenge_then_passes_and_logs(
    run_contract, mode
):
    result, calls = run_contract([{"mode": mode}, {"nested": True}])

    _assert_success(result)
    assert len(calls) == 4
    _assert_fresh_challenges(calls)
    assert result.stderr == "Responses model challenge retry 2/3"


def test_third_attempt_can_pass_after_two_incorrect_replies(run_contract):
    result, calls = run_contract([{"mode": "math"}, {"mode": "nonce"}, {}])

    _assert_success(result)
    assert len(_positive_calls(calls)) == 3
    _assert_fresh_challenges(calls)
    assert result.stderr.splitlines() == [
        "Responses model challenge retry 2/3",
        "Responses model challenge retry 3/3",
    ]


@pytest.mark.parametrize("mode", ["math", "empty", "stale"])
def test_three_mismatches_fail_74_with_diagnostic_and_no_fourth_attempt(
    run_contract, mode
):
    result, calls = run_contract([{"mode": mode}] * 3)

    assert result.returncode == 74, result.stderr
    assert result.stdout == ""
    assert len(calls) == 5
    _assert_fresh_challenges(calls)
    assert result.stderr.splitlines() == [
        "Responses model challenge retry 2/3",
        "Responses model challenge retry 3/3",
        "Responses model challenge mismatched after 3 attempts",
    ]


def test_missing_key_accepted_fails_71_without_any_positive_request(run_contract):
    result, calls = run_contract([], missing=200)

    assert result.returncode == 71, result.stderr
    assert result.stdout == ""
    assert _positive_calls(calls) == []
    assert [call["kind"] for call in calls] in (
        ["missing"],
        ["missing", "wrong"],
    )
    assert "Responses model challenge retry" not in result.stderr


def test_wrong_key_accepted_fails_72_without_any_positive_request(run_contract):
    result, calls = run_contract([], wrong=200)

    assert result.returncode == 72, result.stderr
    assert result.stdout == ""
    assert [call["kind"] for call in calls] == ["missing", "wrong"]
    assert "Responses model challenge retry" not in result.stderr


@pytest.mark.parametrize("status", [401, 503])
@pytest.mark.parametrize("prior_mismatch", [False, True])
def test_non_200_valid_key_response_fails_74_immediately(
    run_contract, status, prior_mismatch
):
    # Non-200 error bodies need not be JSON: HTTP failure takes precedence.
    responses = ([{"mode": "math"}] if prior_mismatch else []) + [
        {"status": status, "mode": "malformed"}
    ]
    result, calls = run_contract(responses)

    assert result.returncode == 74, result.stderr
    assert result.stdout == ""
    assert len(_positive_calls(calls)) == len(responses)
    expected_log = ["Responses model challenge retry 2/3"] if prior_mismatch else []
    assert result.stderr.splitlines() == expected_log + [
        f"Responses request with tenant key returned HTTP {status}"
    ]


@pytest.mark.parametrize("prior_mismatch", [False, True])
def test_malformed_200_json_fails_73_without_retrying_parse_error(
    run_contract, prior_mismatch
):
    responses = ([{"mode": "math"}] if prior_mismatch else []) + [{"mode": "malformed"}]
    result, calls = run_contract(responses)

    assert result.returncode == 73, result.stderr
    assert result.stdout == ""
    assert len(_positive_calls(calls)) == len(responses)
    expected_log = ["Responses model challenge retry 2/3"] if prior_mismatch else []
    assert result.stderr.splitlines() == expected_log
