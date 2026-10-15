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

from anthropic.lib.environments import aiter_work

from . import client_factory, config, guard, sandbox

log = logging.getLogger(__name__)


async def _stop(work_api, work, why: str) -> None:
    log.warning("stopping work item %s: %s", work.id, why)
    await work_api.stop(work.id, environment_id=work.environment_id, force=True)


async def handle_work(
    work, work_api, dispatcher: sandbox.Dispatcher, failures: dict[str, int], *, on_aws: bool = False
) -> None:
    """Dispatch one claimed work item, or stop it if it cannot or should not run.

    On Claude Platform on AWS (``on_aws``) the sandbox signs with its own Pod
    Identity role, so the work item's secret is neither required nor forwarded.

    ``failures`` counts failed dispatches per session id. A failed dispatch
    deletes its claim, so the claims cannot carry the count; without this a
    session that always fails would claim a warm sandbox every time it is
    offered again, forever. Its limits:

    - It lives in this poller process only. A restart starts it empty, and a
      second poller replica would keep its own.
    - A successful dispatch clears a session's entry. A session whose
      dispatches alternate between failing and succeeding (its sandbox dying
      after each hand-off) therefore starts from zero after each success and
      never reaches the limit.
    - An entry is removed only on success or once its stop goes through. A
      session that fails once or twice and is never offered again keeps its
      small entry until the process restarts.
    """
    # The queue also sends non-session items (health checks). Nothing else
    # will stop them, so stop them here instead of letting the lease run out.
    if work.data.type != "session":
        await _stop(work_api, work, f"not a session (type={work.data.type})")
        return
    if not on_aws and not work.secret:
        # The sandbox's only credential is the session's token in this
        # secret. Without it there is nothing safe to hand over.
        await _stop(work_api, work, "no per-session secret")
        return

    session_id = work.data.id
    try:
        dispatched = await asyncio.to_thread(
            dispatcher.dispatch,
            session_id=session_id,
            work_id=work.id,
            work_secret=None if on_aws else work.secret,
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
    on_aws = config.on_aws()
    dispatcher = sandbox.Dispatcher()
    log.info("polling environment %s%s; claiming from warm pool %s/%s",
             environment_id, " on Claude Platform on AWS" if on_aws else "",
             dispatcher.namespace, dispatcher.warmpool)

    failures: dict[str, int] = {}
    async with client_factory.make_async_client() as client:
        work_api = client.beta.environments.work
        if on_aws:
            # The SigV4 client authenticates every request itself, so run the
            # SDK's poll/ack loop on it directly. work.poller() would first make
            # a Bearer copy of the client for an environment key this path does
            # not have.
            work_items = aiter_work(work_api, environment_id=environment_id, auto_stop=False)
        else:
            work_items = work_api.poller(
                environment_id=environment_id,
                environment_key=config.require(config.ENV_ENVIRONMENT_KEY),
                auto_stop=False,  # the sandbox serving the session owns the stop call
            )
        async for work in work_items:
            try:
                await handle_work(work, work_api, dispatcher, failures, on_aws=on_aws)
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
