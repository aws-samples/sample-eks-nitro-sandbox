"""The activities: one thin, retryable wrapper per provider verb.

Every side effect the workflow has goes through one of these. They are
deliberately thin, because the interesting code is the provider and the
interesting behaviour is the workflow's.

Two rules they all follow:

* **A failure that a retry cannot fix is marked non-retryable.** A denied
  permission or a manifest the API server rejects is a `PermanentProviderError`,
  which becomes an `ApplicationError(non_retryable=True)`. Retrying those is how
  an orchestrator ends up looking busy forever instead of failing with a reason.
* **A read that did not answer is reported as "could not determine".** It stays
  retryable, because it may answer next time, but its message never claims the
  resource was absent.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from temporalio import activity
from temporalio.exceptions import ApplicationError

from .provider import (
    NitroSandboxProvider,
    PermanentProviderError,
    ProviderError,
    SandboxHandle,
    Undetermined,
    provider_from_env,
)

log = logging.getLogger(__name__)

# One provider per Worker process. Built lazily so that importing this module
# (which the workflow does, to name the activities) needs no cluster.
_provider: NitroSandboxProvider | None = None


def get_provider() -> NitroSandboxProvider:
    global _provider
    if _provider is None:
        _provider = provider_from_env()
    return _provider


def set_provider(provider: NitroSandboxProvider) -> None:
    """Used by the Worker entrypoint, and by a test that supplies its own."""
    global _provider
    _provider = provider


@dataclass
class SandboxRef:
    name: str


@dataclass
class StepRequest:
    name: str
    # The command, already split. Passed as a list so nothing is re-parsed by a
    # shell on the way in.
    command: list[str]
    label: str = "step"
    # When true, the activity raises on its first attempt and only its first.
    # The sample sets this on one activity so the page can show Temporal's retry
    # and the attempt count in the workflow history.
    fail_first_attempt: bool = False


@dataclass
class SandboxState:
    name: str
    pod_name: str
    pod_uid: str
    node_name: str


@dataclass
class StepOutcome:
    label: str
    exit_code: int
    stdout: str
    stderr: str
    attempts: int


def _state(handle: SandboxHandle) -> SandboxState:
    return SandboxState(
        name=handle.name,
        pod_name=handle.pod_name,
        pod_uid=handle.pod_uid,
        node_name=handle.node_name,
    )


def _reraise(exc: ProviderError, what: str) -> ApplicationError:
    """Turn a provider failure into the Temporal error that says what to do with it."""
    if isinstance(exc, PermanentProviderError):
        return ApplicationError(f"{what}: {exc}", type="PermanentProviderError", non_retryable=True)
    if isinstance(exc, Undetermined):
        return ApplicationError(f"{what}: {exc}", type="Undetermined")
    return ApplicationError(f"{what}: {exc}", type="ProviderError")


def _heartbeat(message: str) -> None:
    # Heartbeating is what lets Temporal notice a Worker that died in the middle
    # of a long wait and hand the activity to another one, rather than waiting
    # out the whole start-to-close timeout.
    activity.heartbeat(message)


@activity.defn
def provision_sandbox(ref: SandboxRef) -> SandboxState:
    """Create the `Sandbox` and wait until it is serving work."""
    provider = get_provider()
    _heartbeat(f"creating sandbox/{ref.name}")
    try:
        handle = provider.provision(ref.name, progress=_heartbeat)
    except ProviderError as exc:
        raise _reraise(exc, f"provisioning sandbox/{ref.name} failed") from exc
    log.info(
        "sandbox/%s is Ready: pod %s uid %s on node %s",
        handle.name,
        handle.pod_name,
        handle.pod_uid,
        handle.node_name,
    )
    return _state(handle)


@activity.defn
def run_step(request: StepRequest) -> StepOutcome:
    """Run one command in the sandbox and return what it printed.

    A non-zero exit code is a failure of the step, and it is raised as a
    retryable error so the retry policy applies to it the same way an API
    hiccup would. The workflow's own result carries the output.
    """
    attempt = activity.info().attempt
    if request.fail_first_attempt and attempt == 1:
        # The deliberate transient failure. It happens before anything is run in
        # the sandbox, so the retry re-runs the whole step rather than half of it.
        raise ApplicationError(
            f"injected failure on attempt {attempt} of the '{request.label}' step, so the "
            "page can show Temporal retrying an activity; the next attempt runs normally",
            type="InjectedTransientFailure",
        )

    provider = get_provider()
    _heartbeat(f"running the '{request.label}' step in sandbox/{request.name}")
    try:
        result = provider.run_step(request.name, request.command)
    except ProviderError as exc:
        raise _reraise(exc, f"the '{request.label}' step in sandbox/{request.name} failed") from exc

    if result.exit_code != 0:
        raise ApplicationError(
            f"the '{request.label}' step in sandbox/{request.name} exited "
            f"{result.exit_code}: {(result.stderr or result.stdout or '').strip()[:400]}",
            type="StepFailed",
        )
    return StepOutcome(
        label=request.label,
        exit_code=result.exit_code,
        stdout=result.stdout,
        stderr=result.stderr,
        attempts=attempt,
    )


@activity.defn
def suspend_sandbox(ref: SandboxRef) -> str:
    """`operatingMode: Suspended`. Returns once the pod is really gone."""
    provider = get_provider()
    _heartbeat(f"suspending sandbox/{ref.name}")
    try:
        provider.suspend(ref.name, progress=_heartbeat)
    except ProviderError as exc:
        raise _reraise(exc, f"suspending sandbox/{ref.name} failed") from exc
    return f"sandbox/{ref.name} is suspended; its pod is gone and its workspace volume is kept"


@activity.defn
def resume_sandbox(ref: SandboxRef) -> SandboxState:
    """`operatingMode: Running`. Returns the new pod's UID."""
    provider = get_provider()
    _heartbeat(f"resuming sandbox/{ref.name}")
    try:
        handle = provider.resume(ref.name, progress=_heartbeat)
    except ProviderError as exc:
        raise _reraise(exc, f"resuming sandbox/{ref.name} failed") from exc
    return _state(handle)


@activity.defn
def delete_sandbox(ref: SandboxRef) -> str:
    """Delete the `Sandbox`, and with it its pod and its workspace volume."""
    provider = get_provider()
    _heartbeat(f"deleting sandbox/{ref.name}")
    try:
        return provider.delete(ref.name, progress=_heartbeat)
    except ProviderError as exc:
        raise _reraise(exc, f"deleting sandbox/{ref.name} failed") from exc


@activity.defn
def read_sandbox_signals(ref: SandboxRef) -> StepOutcome:
    """Read the three signals that show the pod's containers ran in a sandbox of
    their own: the guest's kernel build, its boot, and its virtio disks.

    This is a `run_step` with a fixed command, kept as its own activity so the
    workflow history names what it was for.
    """
    provider = get_provider()
    command = [
        "sh",
        "-c",
        "echo \"read at $(date -u +%Y-%m-%dT%H:%M:%SZ)\"; uname -rv; cat /proc/uptime; "
        "ls /sys/block; "
        "cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'product_name unreadable'; "
        "ip -4 -o addr show; ip route show default",
    ]
    _heartbeat(f"reading the sandbox signals in sandbox/{ref.name}")
    try:
        result = provider.run_step(ref.name, command)
    except ProviderError as exc:
        raise _reraise(exc, f"reading the sandbox signals in sandbox/{ref.name} failed") from exc
    if result.exit_code != 0:
        raise ApplicationError(
            f"reading the sandbox signals in sandbox/{ref.name} exited {result.exit_code}",
            type="StepFailed",
        )
    # The pod's own start time, so the uptime above can be read against it: a
    # guest that booted with the pod reports the pod's age, where an ordinary
    # pod reports the node's. Read from the API, not from inside the guest.
    started = provider.pod_start_time(ref.name)
    return StepOutcome(
        label="signals",
        exit_code=result.exit_code,
        stdout=f"pod startTime {started}\n{result.stdout}",
        stderr=result.stderr,
        attempts=activity.info().attempt,
    )


def worker_identity() -> str:
    """The Worker pod's name, so the workflow result records which Worker ran
    which activity. That is what shows a run carried on across a restart."""
    return os.environ.get("POD_NAME", "unknown-worker")


@activity.defn
def whoami() -> str:
    return worker_identity()
