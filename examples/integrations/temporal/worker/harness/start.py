"""Start one workflow and print its result.

Run it inside the Worker pod, which already has the SDK and already reaches the
Temporal frontend over ClusterIP:

    kubectl exec deploy/<worker> -- python -m harness.start

`scripts/run-workflow.sh` is the wrapper the page uses. `--wait` waits for the
run and prints its result; without it the command returns as soon as the run has
started, which is what you want when you are about to delete the Worker pod.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from dataclasses import asdict

from temporalio.api.enums.v1 import EventType
from temporalio.client import Client, WorkflowFailureError

from .config import Settings
from .workflow import LifecycleRequest, LifecycleResult, SandboxLifecycleWorkflow


async def print_timeline(client: Client, workflow_id: str) -> None:
    """Print the run's activity timeline out of Temporal's durable history.

    One line per event that matters to the lifecycle: each activity scheduled,
    started, completed or failed, with its attempt number, plus the timer the
    run waits on while the sandbox is suspended. This is what the Web UI's
    Workflow page shows; it is printed here so the page can show it as text.
    """
    handle = client.get_workflow_handle(workflow_id)
    names: dict[int, str] = {}
    print(f"{'event':>5}  {'time':<21} {'type':<34} detail")
    async for event in handle.fetch_history_events():
        kind = EventType.Name(event.event_type).removeprefix("EVENT_TYPE_")
        when = event.event_time.ToDatetime().strftime("%Y-%m-%dT%H:%M:%SZ")
        detail = ""
        if kind == "ACTIVITY_TASK_SCHEDULED":
            attrs = event.activity_task_scheduled_event_attributes
            names[event.event_id] = attrs.activity_type.name
            detail = attrs.activity_type.name
        elif kind == "ACTIVITY_TASK_STARTED":
            attrs = event.activity_task_started_event_attributes
            detail = (
                f"{names.get(attrs.scheduled_event_id, '?')} attempt {attrs.attempt}"
                f" on {attrs.identity}"
            )
        elif kind == "ACTIVITY_TASK_COMPLETED":
            attrs = event.activity_task_completed_event_attributes
            detail = names.get(attrs.scheduled_event_id, "?")
        elif kind == "ACTIVITY_TASK_FAILED":
            attrs = event.activity_task_failed_event_attributes
            detail = f"{names.get(attrs.scheduled_event_id, '?')}: {attrs.failure.message[:100]}"
        elif kind == "TIMER_STARTED":
            attrs = event.timer_started_event_attributes
            detail = f"{attrs.start_to_fire_timeout.ToTimedelta()} server-side timer"
        elif kind == "WORKFLOW_EXECUTION_STARTED":
            detail = event.workflow_execution_started_event_attributes.task_queue.name
        elif kind == "WORKFLOW_TASK_STARTED":
            detail = event.workflow_task_started_event_attributes.identity
        if kind.startswith("WORKFLOW_TASK") and kind != "WORKFLOW_TASK_STARTED":
            continue
        print(f"{event.event_id:>5}  {when:<21} {kind:<34} {detail}")


async def report(handle) -> int:
    """Wait for a run and print its timeline and its full result."""
    try:
        result: LifecycleResult = await handle.result()
    except WorkflowFailureError as exc:
        print(f"the run failed: {exc.cause}", file=sys.stderr)
        return 1
    print()
    for line in result.timeline:
        print(f"  {line}")
    print()
    print(json.dumps(asdict(result), indent=2, sort_keys=True))
    return 0


async def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workflow-id",
        default=None,
        help="the workflow id; defaults to sandbox-lifecycle-<sandbox name>",
    )
    parser.add_argument("--wait", action="store_true", help="wait for the run and print its result")
    parser.add_argument(
        "--describe",
        action="store_true",
        help="print the status of the run with this id and exit, starting nothing",
    )
    parser.add_argument(
        "--result",
        action="store_true",
        help="wait for the run with this id and print its result, starting nothing",
    )
    parser.add_argument(
        "--history",
        action="store_true",
        help="print the activity timeline of the run with this id and exit, starting nothing",
    )
    parser.add_argument(
        "--suspended-seconds",
        type=int,
        default=None,
        help="override how long the workflow waits with the sandbox suspended",
    )
    args = parser.parse_args(argv)

    settings = Settings.from_env()
    workflow_id = args.workflow_id or f"sandbox-lifecycle-{settings.sandbox_name}"
    client = await Client.connect(settings.address, namespace=settings.temporal_namespace)

    if args.describe:
        handle = client.get_workflow_handle(workflow_id)
        described = await handle.describe()
        print(f"workflow id   {described.id}")
        print(f"run id        {described.run_id}")
        print(f"status        {described.status.name if described.status else 'unknown'}")
        print(f"task queue    {described.task_queue}")
        return 0

    if args.history:
        # The same timeline the Web UI's Workflow page shows, read from the
        # server's durable history rather than from any Worker's memory.
        await print_timeline(client, workflow_id)
        return 0

    if args.result:
        # Wait for a run that is already going, which is what you do after
        # deleting the Worker pod mid-run: the run is the server's, so a new
        # client can pick its result up. get_workflow_handle_for, not
        # get_workflow_handle, so the result is decoded into LifecycleResult
        # rather than left as a plain dict.
        return await report(
            client.get_workflow_handle_for(SandboxLifecycleWorkflow.run, workflow_id)
        )

    request = LifecycleRequest(
        sandbox_name=settings.sandbox_name,
        suspended_seconds=(
            args.suspended_seconds
            if args.suspended_seconds is not None
            else settings.suspended_seconds
        ),
        fail_first_step_attempt=settings.fail_first_step_attempt,
    )

    # A fixed workflow id means the server refuses a second start while a run is
    # open, so two runs can never drive the same Sandbox at once.
    handle = await client.start_workflow(
        SandboxLifecycleWorkflow.run,
        request,
        id=workflow_id,
        task_queue=settings.task_queue,
    )
    print(f"started workflow id {handle.id}, run id {handle.result_run_id}")
    print(f"task queue          {settings.task_queue}")
    print(f"sandbox             {request.sandbox_name} in the Worker's own namespace")
    print(f"suspended for       {request.suspended_seconds}s")
    if not args.wait:
        return 0

    return await report(handle)


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main(sys.argv[1:])))
