"""The Worker: an ordinary pod that hosts the workflow and its activities.

The Worker is not sandboxed, and that is the sample's central design decision.
It is the trusted orchestrator: it holds the namespace-scoped RBAC and calls the
Kubernetes API to create, exec into, suspend, resume and delete sandboxes.
Sandboxing it would defeat its job. The one thing that runs in a sandbox is the
step's pod, which is where agent-generated code would run.

Run it with `python -m harness.worker`.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import signal

from temporalio.client import Client
from temporalio.worker import Worker

from .activities import (
    delete_sandbox,
    provision_sandbox,
    read_sandbox_signals,
    resume_sandbox,
    run_step,
    set_provider,
    suspend_sandbox,
    whoami,
    worker_identity,
)
from .config import Settings
from .provider import provider_from_env
from .workflow import SandboxLifecycleWorkflow

ACTIVITIES = [
    provision_sandbox,
    run_step,
    read_sandbox_signals,
    suspend_sandbox,
    resume_sandbox,
    delete_sandbox,
    whoami,
]


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    log = logging.getLogger("harness.worker")
    settings = Settings.from_env()

    # Build the provider before connecting, so a Worker with the wrong
    # environment fails here with a clear message rather than when the first
    # activity runs.
    set_provider(provider_from_env())

    client = await Client.connect(settings.address, namespace=settings.temporal_namespace)
    log.info(
        "worker %s connected to %s, namespace %s, task queue %s",
        worker_identity(),
        settings.address,
        settings.temporal_namespace,
        settings.task_queue,
    )

    # The activities are synchronous, because the Kubernetes client is, so they
    # run in a thread pool.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        worker = Worker(
            client,
            task_queue=settings.task_queue,
            workflows=[SandboxLifecycleWorkflow],
            activities=ACTIVITIES,
            activity_executor=executor,
        )

        # SIGTERM is what `kubectl delete pod` sends, so handling it is what
        # makes the deletion a clean Worker shutdown rather than a kill. Either
        # way the workflow survives, because its state is in the server's
        # history; a clean shutdown just returns any in-flight activity to the
        # queue at once instead of waiting for its heartbeat to time out.
        loop = asyncio.get_running_loop()
        stop = asyncio.Event()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)

        run = asyncio.create_task(worker.run())
        waiting = asyncio.create_task(stop.wait())
        done, _ = await asyncio.wait({run, waiting}, return_when=asyncio.FIRST_COMPLETED)
        if run in done:
            waiting.cancel()
            await run
            return
        log.info("shutting down on a signal; in-flight activities go back to the queue")
        await worker.shutdown()
        await run


if __name__ == "__main__":
    asyncio.run(main())
