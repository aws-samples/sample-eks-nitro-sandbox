"""``worker stats`` -- size the SandboxWarmPool from work-queue depth (optional).

Every interval it reads the environment's ``work.stats`` and sets the warm
pool's replicas, through its ``/scale`` subresource, to
``clamp(depth + pending, WARMPOOL_MIN, WARMPOOL_MAX)``. ``depth`` counts work
waiting to be picked up and ``pending`` work polled but not yet acknowledged;
the poller acknowledges at once, so in practice this keeps WARMPOOL_MIN
sandboxes warm plus one for each session waiting in the queue. A session that
is already running counts in neither. It reads the stats with the environment
key, as the poller does.
"""

from __future__ import annotations

import logging
import time

from kubernetes import client as k8s
from kubernetes import config as k8s_config

from . import client_factory, config, guard

log = logging.getLogger(__name__)

WARMPOOL_GROUP = "extensions.agents.x-k8s.io"
WARMPOOL_VERSION = "v1beta1"
WARMPOOL_PLURAL = "sandboxwarmpools"


def main() -> None:
    config.setup_logging()
    guard.assert_safe(guard.ROLE_STATS)

    environment_id = config.require(config.ENV_ENVIRONMENT_ID)
    namespace = config.optional(config.ENV_SANDBOX_NAMESPACE, config.DEFAULT_NAMESPACE)
    warmpool = config.optional(config.ENV_SANDBOX_WARMPOOL, config.DEFAULT_WARMPOOL)
    interval = config.optional_int(config.ENV_POLL_INTERVAL_SECONDS, config.DEFAULT_POLL_INTERVAL_SECONDS)
    low = config.optional_int(config.ENV_WARMPOOL_MIN, config.DEFAULT_WARMPOOL_MIN)
    high = config.optional_int(config.ENV_WARMPOOL_MAX, config.DEFAULT_WARMPOOL_MAX)

    client = client_factory.make_sync_client()
    k8s_config.load_incluster_config()
    custom = k8s.CustomObjectsApi()
    log.info("environment=%s warm pool=%s/%s replicas in [%d, %d] every %ds",
             environment_id, namespace, warmpool, low, high, interval)

    last = None
    while True:
        try:
            stats = client.beta.environments.work.stats(environment_id)
            target = max(low, min(high, stats.depth + stats.pending))
            # Patch every tick, not only when the target changes: if anything
            # else set the pool's replicas (re-applying sandbox-template.yaml,
            # say), the next tick puts the target back. Setting the same value
            # again changes nothing, and the Role needs only `patch` this way.
            scale = custom.patch_namespaced_custom_object_scale(
                group=WARMPOOL_GROUP,
                version=WARMPOOL_VERSION,
                namespace=namespace,
                plural=WARMPOOL_PLURAL,
                name=warmpool,
                body={"spec": {"replicas": target}},
            )
            current = ((scale or {}).get("status") or {}).get("replicas")
            if target != last:
                log.info("depth=%d pending=%d -> %s replicas %s -> %d (pool has %s)",
                         stats.depth, stats.pending, warmpool, last, target, current)
                last = target
            else:
                log.debug("depth=%d pending=%d -> %s replicas %d (pool has %s)",
                          stats.depth, stats.pending, warmpool, target, current)
        except Exception as exc:  # noqa: BLE001 - keep the loop alive
            log.warning("tick failed: %s", exc)
        time.sleep(interval)


if __name__ == "__main__":
    main()
