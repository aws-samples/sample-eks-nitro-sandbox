"""The Nitro sandbox compute provider: five lifecycle verbs, each one or two
Kubernetes operations against the agent-sandbox `Sandbox` API.

Nothing in this file imports Temporal. The provider is a plain class, so it can
be read, unit tested and swapped for another compute provider without touching
the workflow, which is the point of the harness shape: the provider is the only
part that changes per runtime.

Every read in here fails closed. A lookup that does not answer raises
`Undetermined`, which the caller reports as "could not determine" rather than as
"absent" or "gone". An orchestrator that reads a failed lookup as an absent
resource will confidently do the wrong thing: delete a workspace it believes is
already gone, or report a sandbox ready that it never saw.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any, Callable

from kubernetes import client, config
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream
from kubernetes.stream.ws_client import ERROR_CHANNEL

log = logging.getLogger(__name__)

SANDBOX_GROUP = "agents.x-k8s.io"
SANDBOX_VERSION = "v1beta1"
SANDBOX_PLURAL = "sandboxes"

# The placeholders in worker/sandbox.yaml, filled in when the provider creates a
# Sandbox. The manifest is never applied with a placeholder in place.
NAME_PLACEHOLDER = "__NAME__"
STORAGE_CLASS_PLACEHOLDER = "__STORAGE_CLASS__"


class ProviderError(Exception):
    """The operation failed, and the provider knows that it failed."""


class Undetermined(ProviderError):
    """A read did not answer, so the state could not be determined.

    Never raised to mean "absent". The caller retries, and if it runs out of
    attempts the failure says what could not be read rather than guessing.
    """


class PermanentProviderError(ProviderError):
    """The operation cannot succeed however many times it is retried.

    A denied permission, a manifest the API server rejects, a `Sandbox` whose
    immutable fields do not match. Retrying these is how an orchestrator hangs
    silently, so the activity marks them non-retryable and the run fails fast
    with the reason.
    """


@dataclass
class SandboxHandle:
    """What the provider returns once a sandbox is serving work."""

    name: str
    namespace: str
    pod_name: str
    pod_uid: str
    node_name: str


@dataclass
class StepResult:
    stdout: str
    stderr: str
    exit_code: int


# HTTP statuses that will not become success on a retry.
_PERMANENT_STATUSES = frozenset({400, 401, 403, 404, 405, 409, 422})


def _permanent(exc: ApiException) -> bool:
    return exc.status in _PERMANENT_STATUSES


class NitroSandboxProvider:
    """Create, drive, suspend, resume and remove one Nitro sandbox.

    `namespace` is the Kubernetes namespace the sandboxes live in, the same one
    the Worker runs in, which is the only namespace its RBAC reaches.
    """

    def __init__(
        self,
        namespace: str,
        manifest_path: str,
        storage_class: str,
        in_cluster: bool = True,
    ) -> None:
        if in_cluster:
            config.load_incluster_config()
        else:  # pragma: no cover - only used when running the provider locally
            config.load_kube_config()
        self.namespace = namespace
        self.manifest_path = manifest_path
        self.storage_class = storage_class
        self.core = client.CoreV1Api()
        self.custom = client.CustomObjectsApi()

    # ------------------------------------------------------------------ verbs

    def provision(
        self,
        name: str,
        timeout_seconds: float = 600.0,
        progress: Callable[[str], None] | None = None,
    ) -> SandboxHandle:
        """Create the `Sandbox` and wait until it reports Ready.

        The wait is bounded. A sandbox that never becomes Ready fails this call
        with the conditions and the pod's container state the cluster actually
        reported, so the failure names what happened instead of the orchestrator
        waiting on it forever. One failure worth seeing in that output is a
        `StartError` from the sandbox runtime, which the kubelet's container
        restarts do not clear.
        """
        body = self._render_manifest(name)
        try:
            self.custom.create_namespaced_custom_object(
                group=SANDBOX_GROUP,
                version=SANDBOX_VERSION,
                namespace=self.namespace,
                plural=SANDBOX_PLURAL,
                body=body,
            )
            log.info("created sandbox/%s in namespace %s", name, self.namespace)
        except ApiException as exc:
            if exc.status == 409:
                # Already there. The activity is at-least-once, so a retry after
                # a successful create that lost its answer lands here, and the
                # existing object is the one this run just made.
                log.info("sandbox/%s already exists; adopting it", name)
            elif _permanent(exc):
                raise PermanentProviderError(
                    f"the API server refused to create sandbox/{name}: {_describe(exc)}"
                ) from exc
            else:
                raise ProviderError(
                    f"could not create sandbox/{name}: {_describe(exc)}"
                ) from exc

        self._wait_for_ready(name, timeout_seconds, progress)
        return self._handle(name)

    def run_step(
        self,
        name: str,
        command: list[str],
        timeout_seconds: float = 120.0,
    ) -> StepResult:
        """Run one command in the sandbox pod and return its output and exit code.

        This goes over the Kubernetes exec channel, which keeps working for a
        sandbox pod because it rides the sandbox's own internal control channel
        rather than a network device.

        The exit code is read from the exec stream's error channel. If that
        channel says nothing, or says something this code does not recognise,
        the call raises rather than reporting success: a step whose result could
        not be read is not a step that passed.
        """
        pod = self._pod_name(name)
        try:
            resp = stream(
                self.core.connect_get_namespaced_pod_exec,
                pod,
                self.namespace,
                command=command,
                container=None,
                stderr=True,
                stdin=False,
                stdout=True,
                tty=False,
                _preload_content=False,
                _request_timeout=timeout_seconds,
            )
        except ApiException as exc:
            if _permanent(exc):
                raise PermanentProviderError(
                    f"could not open an exec channel to pod/{pod}: {_describe(exc)}"
                ) from exc
            raise ProviderError(
                f"could not open an exec channel to pod/{pod}: {_describe(exc)}"
            ) from exc

        try:
            resp.run_forever(timeout=timeout_seconds)
            stdout = resp.read_stdout(timeout=5) or ""
            stderr = resp.read_stderr(timeout=5) or ""
            channel = resp.read_channel(ERROR_CHANNEL, timeout=5)
        finally:
            resp.close()

        exit_code = _exit_code_from_channel(channel, pod)
        return StepResult(stdout=stdout, stderr=stderr, exit_code=exit_code)

    def suspend(
        self,
        name: str,
        timeout_seconds: float = 300.0,
        progress: Callable[[str], None] | None = None,
    ) -> None:
        """`operatingMode: Suspended`: the controller terminates the pod and
        keeps the `Sandbox` and its workspace volume.

        Returns only once the pod is genuinely gone. A pod this code could not
        read is not a pod it reports as deleted.
        """
        self._patch_operating_mode(name, "Suspended")
        self._wait_until(
            name,
            timeout_seconds,
            progress,
            what="suspended",
            check=lambda: self._is_suspended(name),
        )

    def resume(
        self,
        name: str,
        timeout_seconds: float = 600.0,
        progress: Callable[[str], None] | None = None,
    ) -> SandboxHandle:
        """`operatingMode: Running`: the controller brings a fresh pod back,
        re-attached to the same workspace volume."""
        self._patch_operating_mode(name, "Running")
        self._wait_for_ready(name, timeout_seconds, progress)
        return self._handle(name)

    def delete(
        self,
        name: str,
        timeout_seconds: float = 300.0,
        progress: Callable[[str], None] | None = None,
    ) -> str:
        """Delete the `Sandbox`. Its pod and its workspace volume go with it,
        because the claim carries the `Sandbox` as its `ownerReference`.

        Returns a one-line description of what happened, for the workflow's
        result. A 404 on the delete is a definite answer ("already gone"); any
        other API failure is not, and raises.
        """
        try:
            self.custom.delete_namespaced_custom_object(
                group=SANDBOX_GROUP,
                version=SANDBOX_VERSION,
                namespace=self.namespace,
                plural=SANDBOX_PLURAL,
                name=name,
            )
            outcome = f"sandbox/{name} deleted"
        except ApiException as exc:
            if exc.status == 404:
                outcome = f"sandbox/{name} was already gone"
            elif exc.status == 403:
                raise PermanentProviderError(
                    f"not allowed to delete sandbox/{name}: {_describe(exc)}"
                ) from exc
            else:
                raise ProviderError(
                    f"could not delete sandbox/{name}: {_describe(exc)}"
                ) from exc

        self._wait_until(
            name,
            timeout_seconds,
            progress,
            what="deleted",
            check=lambda: self._sandbox_absent(name),
        )
        return outcome

    # -------------------------------------------------------------- internals

    def _render_manifest(self, name: str) -> dict[str, Any]:
        with open(self.manifest_path, "r", encoding="utf-8") as handle:
            text = handle.read()
        text = text.replace(NAME_PLACEHOLDER, name)
        text = text.replace(STORAGE_CLASS_PLACEHOLDER, self.storage_class)
        for placeholder in (NAME_PLACEHOLDER, STORAGE_CLASS_PLACEHOLDER):
            if placeholder in text:
                raise PermanentProviderError(
                    f"{self.manifest_path} still holds {placeholder} after rendering"
                )
        # yaml is not imported at module scope so that this file stays free of
        # anything the Temporal workflow sandbox would have to pass through.
        import yaml

        body = yaml.safe_load(text)
        if not isinstance(body, dict):
            raise PermanentProviderError(
                f"{self.manifest_path} did not parse as a single Kubernetes object"
            )
        body.setdefault("metadata", {})["namespace"] = self.namespace
        return body

    def _get_sandbox(self, name: str) -> dict[str, Any] | None:
        """The `Sandbox` object, or None when it is definitely absent.

        Raises `Undetermined` when the read failed for any other reason, so a
        caller can never read an API error as "absent".
        """
        try:
            return self.custom.get_namespaced_custom_object(
                group=SANDBOX_GROUP,
                version=SANDBOX_VERSION,
                namespace=self.namespace,
                plural=SANDBOX_PLURAL,
                name=name,
            )
        except ApiException as exc:
            if exc.status == 404:
                return None
            raise Undetermined(
                f"could not read sandbox/{name}: {_describe(exc)}"
            ) from exc

    def _get_pod(self, pod: str) -> client.V1Pod | None:
        try:
            return self.core.read_namespaced_pod(pod, self.namespace)
        except ApiException as exc:
            if exc.status == 404:
                return None
            raise Undetermined(f"could not read pod/{pod}: {_describe(exc)}") from exc

    def _pod_name(self, name: str) -> str:
        """The name of the `Sandbox`'s pod.

        The agent-sandbox controller names the pod after the Sandbox. This reads
        the pod rather than assuming it, so a missing pod is reported as such
        instead of producing an exec against a name that is not there.
        """
        pod = self._get_pod(name)
        if pod is None:
            raise ProviderError(
                f"pod/{name} is not present, so there is nothing to run the step in"
            )
        return name

    def _handle(self, name: str) -> SandboxHandle:
        pod = self._get_pod(name)
        if pod is None:
            raise ProviderError(
                f"sandbox/{name} reported Ready but pod/{name} is not there"
            )
        uid = pod.metadata.uid
        node = pod.spec.node_name
        if not uid:
            raise Undetermined(f"pod/{name} has no UID in the object that was read")
        return SandboxHandle(
            name=name,
            namespace=self.namespace,
            pod_name=name,
            pod_uid=uid,
            node_name=node or "",
        )

    def pod_start_time(self, name: str) -> str:
        """When the kubelet started the sandbox's pod, from the API.

        Raises rather than returning a placeholder: a reading the page shows has
        to be a reading that was taken.
        """
        pod = self._get_pod(name)
        if pod is None:
            raise ProviderError(f"pod/{name} is not present, so it has no start time")
        started = pod.status.start_time
        if started is None:
            raise Undetermined(f"pod/{name} has no startTime in the object that was read")
        return started.strftime("%Y-%m-%dT%H:%M:%SZ")

    def _patch_operating_mode(self, name: str, mode: str) -> None:
        try:
            self.custom.patch_namespaced_custom_object(
                group=SANDBOX_GROUP,
                version=SANDBOX_VERSION,
                namespace=self.namespace,
                plural=SANDBOX_PLURAL,
                name=name,
                body={"spec": {"operatingMode": mode}},
            )
        except ApiException as exc:
            if exc.status == 404:
                raise PermanentProviderError(
                    f"sandbox/{name} is not there, so operatingMode cannot be set to {mode}"
                ) from exc
            if _permanent(exc):
                raise PermanentProviderError(
                    f"the API server refused to set operatingMode={mode} on "
                    f"sandbox/{name}: {_describe(exc)}"
                ) from exc
            raise ProviderError(
                f"could not set operatingMode={mode} on sandbox/{name}: {_describe(exc)}"
            ) from exc
        log.info("set operatingMode=%s on sandbox/%s", mode, name)

    def _condition(self, obj: dict[str, Any], kind: str) -> str | None:
        for cond in (obj.get("status") or {}).get("conditions") or []:
            if cond.get("type") == kind:
                return cond.get("status")
        return None

    def _is_suspended(self, name: str) -> bool:
        obj = self._get_sandbox(name)
        if obj is None:
            raise ProviderError(
                f"sandbox/{name} disappeared while waiting for it to suspend"
            )
        if self._condition(obj, "Suspended") != "True":
            return False
        # The condition is not the whole answer: the pod must be gone, because a
        # pod still terminating is still holding the guest and the volume.
        return self._get_pod(name) is None

    def _sandbox_absent(self, name: str) -> bool:
        return self._get_sandbox(name) is None

    def _wait_for_ready(
        self,
        name: str,
        timeout_seconds: float,
        progress: Callable[[str], None] | None,
    ) -> None:
        def ready() -> bool:
            obj = self._get_sandbox(name)
            if obj is None:
                raise ProviderError(
                    f"sandbox/{name} is not there while waiting for it to become Ready"
                )
            return self._condition(obj, "Ready") == "True"

        self._wait_until(name, timeout_seconds, progress, what="Ready", check=ready)

    def _wait_until(
        self,
        name: str,
        timeout_seconds: float,
        progress: Callable[[str], None] | None,
        what: str,
        check: Callable[[], bool],
    ) -> None:
        """Poll `check` until it is true or the deadline passes.

        A read that fails means "keep waiting", never "satisfied": `check`
        raises `Undetermined` and this loop keeps going, carrying the reason so
        that a deadline reached on nothing but failed reads says so. The wait is
        always bounded, so a sandbox stuck in a state nothing will clear fails
        the activity with what the cluster reported instead of hanging.
        """
        deadline = time.monotonic() + timeout_seconds
        last_undetermined: str | None = None
        attempts = 0
        while True:
            attempts += 1
            try:
                if check():
                    log.info("sandbox/%s is %s", name, what)
                    return
                last_undetermined = None
            except Undetermined as exc:
                last_undetermined = str(exc)
                log.warning("while waiting for sandbox/%s to be %s: %s", name, what, exc)
            if time.monotonic() >= deadline:
                break
            if progress is not None and attempts % 5 == 0:
                progress(f"waiting for sandbox/{name} to be {what}")
            time.sleep(2.0)

        if last_undetermined is not None:
            raise Undetermined(
                f"gave up after {timeout_seconds:.0f}s waiting for sandbox/{name} to be "
                f"{what}, and the last read did not answer, so its state could not be "
                f"determined: {last_undetermined}"
            )
        raise ProviderError(
            f"sandbox/{name} was not {what} within {timeout_seconds:.0f}s. "
            f"{self.describe_state(name)}"
        )

    def describe_state(self, name: str) -> str:
        """What the cluster says about the sandbox and its pod, for a failure
        message. Never raises: a failure message must not fail."""
        parts: list[str] = []
        try:
            obj = self._get_sandbox(name)
            if obj is None:
                parts.append(f"sandbox/{name}: not present")
            else:
                conds = (obj.get("status") or {}).get("conditions") or []
                shown = ", ".join(
                    f"{c.get('type')}={c.get('status')}"
                    f"({c.get('reason') or 'no reason'}: {c.get('message') or ''})".strip()
                    for c in conds
                ) or "no conditions"
                parts.append(f"sandbox/{name} conditions: {shown}")
        except Exception as exc:  # noqa: BLE001 - diagnostics must not raise
            parts.append(f"sandbox/{name}: could not be read ({exc})")
        try:
            pod = self._get_pod(name)
            if pod is None:
                parts.append(f"pod/{name}: not present")
            else:
                parts.append(f"pod/{name} phase: {pod.status.phase}")
                for cs in (pod.status.container_statuses or []) + (
                    pod.status.init_container_statuses or []
                ):
                    state = cs.state
                    for label in ("waiting", "terminated", "running"):
                        value = getattr(state, label, None)
                        if value is None:
                            continue
                        reason = getattr(value, "reason", None)
                        message = getattr(value, "message", None)
                        exit_code = getattr(value, "exit_code", None)
                        detail = " ".join(
                            str(x)
                            for x in (reason, f"exit {exit_code}" if exit_code is not None else None, message)
                            if x
                        )
                        parts.append(f"container {cs.name} {label}: {detail or 'no detail'}")
        except Exception as exc:  # noqa: BLE001 - diagnostics must not raise
            parts.append(f"pod/{name}: could not be read ({exc})")
        return " | ".join(parts)


def _describe(exc: ApiException) -> str:
    reason = exc.reason or "no reason"
    body = (exc.body or "").strip()
    if len(body) > 400:
        body = body[:400] + "..."
    return f"HTTP {exc.status} {reason}: {body}" if body else f"HTTP {exc.status} {reason}"


def _exit_code_from_channel(channel: str | None, pod: str) -> int:
    """Read the exit code out of the exec stream's error channel.

    Kubernetes writes a `Status` object there: `status: Success` for exit 0, or
    `status: Failure` with `details.causes[].reason == "ExitCode"` carrying the
    code. Anything else is unreadable, and an unreadable result is not a pass.
    """
    if not channel:
        raise Undetermined(
            f"the exec stream to pod/{pod} closed without a status, so the step's "
            "exit code could not be determined"
        )
    try:
        status = json.loads(channel)
    except ValueError as exc:
        raise Undetermined(
            f"the exec status from pod/{pod} did not parse as JSON, so the step's "
            f"exit code could not be determined: {channel[:200]}"
        ) from exc
    if status.get("status") == "Success":
        return 0
    for cause in (status.get("details") or {}).get("causes") or []:
        if cause.get("reason") == "ExitCode":
            try:
                return int(cause.get("message"))
            except (TypeError, ValueError) as exc:
                raise Undetermined(
                    f"the exec status from pod/{pod} carried an ExitCode cause that is "
                    f"not a number: {cause!r}"
                ) from exc
    raise Undetermined(
        f"the exec status from pod/{pod} reported neither Success nor an exit code, so "
        f"the step's result could not be determined: {channel[:200]}"
    )


def provider_from_env() -> NitroSandboxProvider:
    """Build the provider from the Worker pod's environment.

    `SANDBOX_NAMESPACE` is the namespace the Worker runs in, injected from
    `metadata.namespace`, so the provider can only ever act in the one namespace
    its Role covers.
    """
    namespace = os.environ.get("SANDBOX_NAMESPACE")
    if not namespace:
        raise PermanentProviderError("SANDBOX_NAMESPACE is not set in the Worker's environment")
    storage_class = os.environ.get("SANDBOX_STORAGE_CLASS")
    if not storage_class:
        raise PermanentProviderError(
            "SANDBOX_STORAGE_CLASS is not set in the Worker's environment; setup.sh "
            "chooses the class and renders it into the Deployment"
        )
    manifest = os.environ.get("SANDBOX_MANIFEST", "/opt/harness/sandbox.yaml")
    return NitroSandboxProvider(
        namespace=namespace,
        manifest_path=manifest,
        storage_class=storage_class,
    )
