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


async def _run() -> None:
    guard.assert_safe()
    environment_id = config.require(config.ENV_ENVIRONMENT_ID)
    environment_key = config.require(config.ENV_ENVIRONMENT_KEY)
    dispatcher = sandbox.Dispatcher()
    log.info("polling environment %s; claiming from warm pool %s/%s",
             environment_id, dispatcher.namespace, dispatcher.warmpool)

    async with client_factory.make_async_client() as client:
        work_api = client.beta.environments.work
        async for work in work_api.poller(
            environment_id=environment_id,
            environment_key=environment_key,
            auto_stop=False,  # the sandbox serving the session owns the stop call
        ):
            try:
                # The queue also sends non-session items (health checks).
                # Nothing else will stop them, so stop them here instead of
                # letting the lease run out.
                if work.data.type != "session":
                    log.info("stopping non-session work item %s (type=%s)", work.id, work.data.type)
                    await work_api.stop(work.id, environment_id=work.environment_id, force=True)
                    continue
                dispatched = await asyncio.to_thread(
                    dispatcher.dispatch,
                    session_id=work.data.id,
                    work_id=work.id,
                    work_secret=work.secret,
                )
                if not dispatched:
                    # A session that keeps failing would otherwise be offered forever.
                    await work_api.stop(work.id, environment_id=work.environment_id, force=True)
            except Exception:
                log.exception("work item %s failed (session=%s)", work.id, work.data.id)


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
