"""One durable workflow that brackets a sandbox's whole life.

The workflow is deterministic and holds no Kubernetes client: every side effect
goes through an activity. What Temporal adds over a script that called the five
verbs in order is in three places, and each one is something the page shows:

* **Retries.** Each activity carries a retry policy, so a transient Kubernetes
  API or exec hiccup is retried rather than failing the run. One step is made to
  fail on its first attempt on purpose, so the history shows the retry.
* **Durability.** The state of this function lives in Temporal's history, not in
  the Worker's memory. Delete the Worker pod while the workflow is waiting out
  the suspend and a new Worker replays the history and carries on.
* **A record.** The Web UI lists the run and, inside it, the ordered activities
  that drove the sandbox.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from .activities import (
        SandboxRef,
        SandboxState,
        StepOutcome,
        StepRequest,
        delete_sandbox,
        provision_sandbox,
        read_sandbox_signals,
        resume_sandbox,
        run_step,
        suspend_sandbox,
        whoami,
    )

# The file the step writes before the suspend and reads back after the resume.
# It lives on the sandbox's EBS workspace, which is what survives.
NOTES = "/workspace/notes.log"


@dataclass
class LifecycleRequest:
    sandbox_name: str
    # How long the workflow waits while the sandbox is suspended. This is the
    # window the page uses to delete the Worker pod mid-run.
    suspended_seconds: int = 120
    # Make the write step fail on its first attempt, so the history shows the
    # retry and the attempt count.
    fail_first_step_attempt: bool = True


@dataclass
class LifecycleResult:
    sandbox_name: str
    # One line per transition, in order, as the workflow saw it.
    timeline: list[str] = field(default_factory=list)
    pod_uid_before_suspend: str = ""
    pod_uid_after_resume: str = ""
    notes_after_resume: str = ""
    signals_before_suspend: str = ""
    signals_after_resume: str = ""
    write_step_attempts: int = 0
    worker_at_start: str = ""
    worker_after_resume: str = ""
    deleted: str = ""


# Each verb is a single Kubernetes operation plus a bounded wait, so the retry
# policy is the same shape for all of them: retry a transient failure a few
# times with backoff, and stop. `maximum_attempts` is what keeps a failure that
# is not going to clear from looking like work in progress forever.
LIFECYCLE_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=4,
)

# The waits inside provision and resume are bounded by the provider at ten
# minutes, so the activity timeout has to be longer than that for the provider's
# own message to be the one that surfaces.
LONG = timedelta(minutes=12)
SHORT = timedelta(minutes=5)
# A Worker that dies mid-activity stops heartbeating, and Temporal hands the
# activity to another Worker about this long afterwards rather than waiting out
# the whole start-to-close timeout.
HEARTBEAT = timedelta(seconds=60)


@workflow.defn(name="SandboxLifecycleWorkflow")
class SandboxLifecycleWorkflow:
    @workflow.run
    async def run(self, request: LifecycleRequest) -> LifecycleResult:
        name = request.sandbox_name
        result = LifecycleResult(sandbox_name=name)
        provisioned = False

        try:
            result.worker_at_start = await workflow.execute_activity(
                whoami,
                start_to_close_timeout=SHORT,
                retry_policy=LIFECYCLE_RETRY,
            )

            # 1. Provision on demand.
            state: SandboxState = await workflow.execute_activity(
                provision_sandbox,
                SandboxRef(name=name),
                start_to_close_timeout=LONG,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            provisioned = True
            result.pod_uid_before_suspend = state.pod_uid
            result.timeline.append(
                f"created sandbox/{name}: pod {state.pod_name} uid {state.pod_uid} "
                f"on node {state.node_name}"
            )

            signals: StepOutcome = await workflow.execute_activity(
                read_sandbox_signals,
                SandboxRef(name=name),
                start_to_close_timeout=SHORT,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            result.signals_before_suspend = signals.stdout.strip()

            # 2. Drive execution. The step writes a line to the workspace, which
            #    is the thing the resume has to bring back.
            write: StepOutcome = await workflow.execute_activity(
                run_step,
                StepRequest(
                    name=name,
                    command=[
                        "sh",
                        "-c",
                        f"mkdir -p /workspace && echo \"step ran on kernel $(uname -r), "
                        f'boot $(cut -d. -f1 /proc/uptime)s old" >> {NOTES} && cat {NOTES}',
                    ],
                    label="write",
                    fail_first_attempt=request.fail_first_step_attempt,
                ),
                start_to_close_timeout=SHORT,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            result.write_step_attempts = write.attempts
            result.timeline.append(
                f"ran the write step in sandbox/{name} on attempt {write.attempts}: "
                f"{write.stdout.strip()}"
            )

            # 3. Persist across a pause.
            suspended = await workflow.execute_activity(
                suspend_sandbox,
                SandboxRef(name=name),
                start_to_close_timeout=SHORT,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            result.timeline.append(suspended)

            # The durable pause. Nothing of this workflow is in any process while
            # it waits: the timer is the server's. This is the window the page
            # uses to delete the Worker pod and show the run carry on.
            if request.suspended_seconds > 0:
                result.timeline.append(
                    f"waiting {request.suspended_seconds}s with sandbox/{name} suspended; "
                    "no pod and no Worker state are needed to hold this"
                )
                await workflow.sleep(timedelta(seconds=request.suspended_seconds))

            # 4. Resume.
            resumed: SandboxState = await workflow.execute_activity(
                resume_sandbox,
                SandboxRef(name=name),
                start_to_close_timeout=LONG,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            result.pod_uid_after_resume = resumed.pod_uid
            result.timeline.append(
                f"resumed sandbox/{name}: pod {resumed.pod_name} uid {resumed.pod_uid} "
                f"on node {resumed.node_name}"
            )

            result.worker_after_resume = await workflow.execute_activity(
                whoami,
                start_to_close_timeout=SHORT,
                retry_policy=LIFECYCLE_RETRY,
            )

            read_back: StepOutcome = await workflow.execute_activity(
                run_step,
                StepRequest(
                    name=name,
                    command=["sh", "-c", f"cat {NOTES}"],
                    label="read-back",
                ),
                start_to_close_timeout=SHORT,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            result.notes_after_resume = read_back.stdout.strip()
            result.timeline.append(
                f"read {NOTES} back from the resumed sandbox/{name}"
            )

            signals_again: StepOutcome = await workflow.execute_activity(
                read_sandbox_signals,
                SandboxRef(name=name),
                start_to_close_timeout=SHORT,
                heartbeat_timeout=HEARTBEAT,
                retry_policy=LIFECYCLE_RETRY,
            )
            result.signals_after_resume = signals_again.stdout.strip()

        finally:
            # 5. Clean up. The delete runs whether the body above completed,
            #    raised, or was cancelled, so a failed run does not leave a
            #    sandbox and its volume behind. The shield is what lets the
            #    activity run after a cancellation: without it the await here
            #    would be cancelled too.
            #
            #    This is the workflow's own backstop, not the only one. A Worker
            #    that is deleted and never replaced, or a workflow terminated
            #    rather than cancelled, leaves the sandbox for
            #    `scripts/cleanup.sh`, which deletes it by its exact name.
            if provisioned:
                result.deleted = await asyncio.shield(
                    workflow.execute_activity(
                        delete_sandbox,
                        SandboxRef(name=name),
                        start_to_close_timeout=SHORT,
                        heartbeat_timeout=HEARTBEAT,
                        retry_policy=LIFECYCLE_RETRY,
                    )
                )
                result.timeline.append(result.deleted)

        return result
