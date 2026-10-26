#!/usr/bin/env python3
"""The brain's one execution tool: run commands in a claimed sandbox.

The agent in the brain pod has no shell tool of its own, so this stdio MCP
server is its only way to run anything. It claims a warm, network-isolated pod
from a SandboxWarmPool and drives that one pod with `kubectl exec`, `cp` and
`logs`, which travel on the sandbox's internal control channel rather than over
a network device and so keep working with no network in the sandbox.

The pod is never a tool argument. Each tool below operates on
`status.sandbox.name` of the claim this process created, held in STATE, so the
model cannot point any of them at another pod. That is an application-level
control. The hard boundary is the Kubernetes RBAC Role in deploy/rbac.yaml,
which is namespace-bounded: see the comment at the top of that file for what it
does and does not cover.

Deliberately absent: creating or deleting a pod, port-forward, exec into a pod
of the model's choosing, and any passthrough that would let the model run
`kubectl` itself.
"""

import os
import subprocess
import tempfile
import time

from mcp.server.fastmcp import FastMCP

# Configuration, from the brain pod's environment (deploy/brain.yaml). None of
# it is reachable from a tool argument.
NAMESPACE = os.environ.get("HANDS_NAMESPACE", "default")
WARMPOOL = os.environ.get("HANDS_WARMPOOL", "hands-pool")
CLAIM = os.environ.get("HANDS_CLAIM", "brain-session")
CONTAINER = os.environ.get("HANDS_CONTAINER", "hands")
MAX_OUTPUT_BYTES = int(os.environ.get("HANDS_MAX_OUTPUT_BYTES", "65536"))
DEFAULT_TIMEOUT = int(os.environ.get("HANDS_DEFAULT_TIMEOUT", "120"))

mcp = FastMCP("hands")

# The pod the current claim adopted. Set by claim(), and by the first tool call
# that needs a pod when the agent has not called claim() itself.
STATE = {"pod": None}


def _kubectl(args, stdin_data=None, timeout=DEFAULT_TIMEOUT):
    """Run kubectl in the hands' namespace and return (exit code, output).

    stdout and stderr are returned together: the agent is told what the command
    printed either way, and an error message is as useful to it as output.
    """
    cmd = ["kubectl", "-n", NAMESPACE, *args]
    try:
        done = subprocess.run(cmd, input=stdin_data, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, f"[hands] timed out after {timeout}s".encode()
    return done.returncode, done.stdout + done.stderr


def _decode(raw: bytes) -> str:
    if len(raw) > MAX_OUTPUT_BYTES:
        raw = raw[:MAX_OUTPUT_BYTES] + (
            b"\n[hands] output truncated at %d bytes" % MAX_OUTPUT_BYTES
        )
    return raw.decode("utf-8", errors="replace")


def _container_args():
    return ["-c", CONTAINER] if CONTAINER else []


def _jsonpath(kind, name, path, timeout=30):
    code, out = _kubectl(["get", kind, name, "-o", f"jsonpath={{{path}}}"], timeout=timeout)
    return out.decode("utf-8", errors="replace").strip() if code == 0 else ""


def _claim():
    """Create the SandboxClaim if it is absent, wait for the pod it adopts, and
    return (pod name, launch type, seconds).

    The seconds are this process's own wall-clock, from just before the claim is
    created to the moment the pod is Ready, so they include the kubectl round
    trips the tool makes. That overstates the adoption a little and never
    understates it. The claim object's own timestamps would be the tighter
    measurement, but the Ready condition's lastTransitionTime has one-second
    granularity, so for a warm claim it reads as zero.
    """
    started = time.monotonic()
    claim_yaml = f"""apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: {CLAIM}
  namespace: {NAMESPACE}
spec:
  warmPoolRef:
    name: {WARMPOOL}
"""
    # create, not apply: a claim of this name that already exists means this
    # session already holds a pod, and _pod() below resolves it without
    # touching the object. Applying over it would reset nothing useful and
    # would make an old claim's timestamps read as this call's.
    code, out = _kubectl(["create", "-f", "-"], stdin_data=claim_yaml.encode(), timeout=30)
    if code != 0 and b"AlreadyExists" not in out:
        raise RuntimeError(f"could not create the claim: {_decode(out)}")

    pod = ""
    for _ in range(60):
        pod = _jsonpath("sandboxclaim", CLAIM, ".status.sandbox.name")
        if pod:
            break
        time.sleep(1)
    if not pod:
        raise RuntimeError(
            f"claim '{CLAIM}' never named a pod. Is the warm pool '{WARMPOOL}' ready?"
        )
    # The exit status matters: a timeout or a refusal here means the pod is NOT
    # Ready, and reporting the elapsed time anyway would hand the model, and the
    # page, a "claim to Ready" figure for a claim that was never served.
    code, out = _kubectl(
        ["wait", "--for=condition=Ready", f"pod/{pod}", "--timeout=120s"], timeout=130
    )
    if code != 0:
        raise RuntimeError(
            f"claim '{CLAIM}' named pod '{pod}', but it did not become Ready: {_decode(out)}"
        )
    seconds = time.monotonic() - started
    launch_type = _jsonpath(
        "sandbox", pod, r".metadata.labels.agents\.x-k8s\.io/launch-type"
    )
    STATE["pod"] = pod
    return pod, launch_type, seconds


def _pod():
    if STATE["pod"] is None:
        _claim()
    return STATE["pod"]


@mcp.tool()
def claim() -> str:
    """Claim a pre-booted sandbox from the warm pool and report how long the
    claim took to be served. Call this first. Every other tool here runs in the
    sandbox this claim adopted. Safe to call again: it returns the same pod."""
    pod, launch_type, seconds = _claim()
    lines = [
        f"claimed sandbox pod: {pod}",
        "launch-type: {} ({})".format(
            launch_type or "unknown",
            "adopted from the warm pool"
            if launch_type == "warm"
            else "NOT adopted from the pool",
        ),
    ]
    lines.append(f"claim to Ready: {seconds:.2f}s (wall clock, this tool's kubectl calls included)")
    return "\n".join(lines)


@mcp.tool()
def run(command: str, stdin: str = "", timeout_seconds: int = DEFAULT_TIMEOUT) -> str:
    """Run a shell command in the claimed sandbox and return its combined
    output and exit code. This is the only way to run a command. Pass `stdin` to
    feed data on standard input. The sandbox has no network, so a command that
    tries to reach one fails."""
    pod = _pod()
    args = ["exec"]
    if stdin:
        args.append("-i")
    args += [pod, *_container_args(), "--", "sh", "-c", command]
    code, out = _kubectl(
        args, stdin_data=stdin.encode() if stdin else None, timeout=timeout_seconds
    )
    return f"exit code: {code}\n{_decode(out)}"


@mcp.tool()
def write_file(path: str, content: str) -> str:
    """Copy `content` into the claimed sandbox at absolute `path`, with
    `kubectl cp`."""
    pod = _pod()
    with tempfile.NamedTemporaryFile(mode="w", delete=False) as handle:
        handle.write(content)
        local = handle.name
    try:
        # --no-preserve: kubectl cp copies through tar, which by default tries
        # to set the owner it recorded. The hands drop every capability, so the
        # chown fails and kubectl reports an error even though the bytes landed.
        code, out = _kubectl(
            ["cp", "--no-preserve=true", local, f"{pod}:{path}", *_container_args()]
        )
    finally:
        os.unlink(local)
    if code != 0:
        return f"exit code: {code}\n{_decode(out)}"
    return f"wrote {len(content)} bytes to {pod}:{path}"


@mcp.tool()
def read_file(path: str) -> str:
    """Copy the file at absolute `path` out of the claimed sandbox with
    `kubectl cp` and return its contents."""
    pod = _pod()
    with tempfile.NamedTemporaryFile(mode="rb", delete=False) as handle:
        local = handle.name
    try:
        code, out = _kubectl(
            ["cp", "--no-preserve=true", f"{pod}:{path}", local, *_container_args()]
        )
        if code != 0:
            return f"exit code: {code}\n{_decode(out)}"
        with open(local, "rb") as fh:
            return _decode(fh.read())
    finally:
        os.unlink(local)


@mcp.tool()
def logs(tail_lines: int = 200) -> str:
    """Return the last `tail_lines` lines of the claimed sandbox container's log
    stream, with `kubectl logs`."""
    pod = _pod()
    code, out = _kubectl(["logs", pod, *_container_args(), f"--tail={tail_lines}"])
    return _decode(out)


@mcp.tool()
def release() -> str:
    """Release the claimed sandbox by deleting the claim. Its pod is torn down
    and the pool boots a replacement. Call this when the session is done."""
    code, out = _kubectl(["delete", "sandboxclaim", CLAIM, "--ignore-not-found"])
    STATE["pod"] = None
    if code != 0:
        return f"exit code: {code}\n{_decode(out)}"
    return "released the claim; the sandbox is gone"


if __name__ == "__main__":
    mcp.run()
