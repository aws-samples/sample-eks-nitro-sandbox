"""``worker poll`` -- claim sessions from the work queue and dispatch each one.

Runs as one always-on Deployment. For each claimed session it claims a warm
sandbox from the SandboxWarmPool and hands the session to it (see sandbox.py).
The poller runs no tools and does not wait for the session: it polls with
``auto_stop=False`` -- "someone else stops this work item" -- because the
sandbox's ``EnvironmentWorker.handle_item()`` heartbeats the lease and stops the
item when the session ends. That hand-off is what lets sessions run in parallel,
each in its own sandbox.
"""

from __future__ import annotations

import asyncio
import logging

from . import client_factory, config, guard, sandbox

log = logging.getLogger(__name__)


async def _stop(work_api, work, why: str) -> None:
    log.warning("stopping work item %s: %s", work.id, why)
    await work_api.stop(work.id, environment_id=work.environment_id, force=True)


async def handle_work(work, work_api, dispatcher: sandbox.Dispatcher, failures: dict[str, int]) -> None:
    """Dispatch one claimed work item, or stop it if it cannot or should not run.

    ``failures`` counts failed dispatches per session id in this process. A
    failed dispatch deletes its claim, so the claims cannot carry the count;
    without this a session that always fails would claim a warm sandbox every
    time it is offered again, forever.
    """
    # The queue also sends non-session items (health checks). Nothing else
    # will stop them, so stop them here instead of letting the lease run out.
    if work.data.type != "session":
        await _stop(work_api, work, f"not a session (type={work.data.type})")
        return
    if not work.secret:
        # The sandbox's only credential is the session's token in this
        # secret. Without it there is nothing safe to hand over.
        await _stop(work_api, work, "no per-session secret")
        return

    session_id = work.data.id
    try:
        dispatched = await asyncio.to_thread(
            dispatcher.dispatch, session_id=session_id, work_id=work.id, work_secret=work.secret
        )
    except Exception:
        failures[session_id] = failures.get(session_id, 0) + 1
        log.exception("dispatch %d of %d failed for session %s",
                      failures[session_id], dispatcher.max_redispatch, session_id)
        if failures[session_id] >= dispatcher.max_redispatch:
            await _stop(work_api, work, f"{dispatcher.max_redispatch} dispatches failed")
            # Only once the stop went through: if it raised, the count stays and
            # the next offer of this session is stopped again after one try.
            del failures[session_id]
        return
    failures.pop(session_id, None)
    if not dispatched:
        # Its sandboxes kept dying after hand-off; see Dispatcher.dispatch.
        await _stop(work_api, work, f"handed to {dispatcher.max_redispatch} sandboxes already")


async def _run() -> None:
    guard.assert_safe(guard.ROLE_POLL)
    environment_id = config.require(config.ENV_ENVIRONMENT_ID)
    environment_key = config.require(config.ENV_ENVIRONMENT_KEY)
    dispatcher = sandbox.Dispatcher()
    log.info("polling environment %s; claiming from warm pool %s/%s",
             environment_id, dispatcher.namespace, dispatcher.warmpool)

    failures: dict[str, int] = {}
    async with client_factory.make_async_client() as client:
        work_api = client.beta.environments.work
        async for work in work_api.poller(
            environment_id=environment_id,
            environment_key=environment_key,
            auto_stop=False,  # the sandbox serving the session owns the stop call
        ):
            try:
                await handle_work(work, work_api, dispatcher, failures)
            except Exception:
                # Health-check items are not modelled and may have no id.
                log.exception("work item %s failed (session=%s)", work.id, getattr(work.data, "id", None))


def main() -> None:
    config.setup_logging()
    try:
        asyncio.run(_run())
    except KeyboardInterrupt:
        # Sandboxes already serving sessions keep running; they are not children
        # of this process.
        log.info("poller shutting down")


if __name__ == "__main__":
    main()
