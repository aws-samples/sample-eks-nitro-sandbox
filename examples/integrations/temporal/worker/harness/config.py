"""The Worker pod's settings, all from its environment.

Nothing here is a secret: the Worker holds no model key, no API token and no
Temporal credential. The self-hosted server this sample uses has no
authentication of its own, which is exactly why the page keeps it on ClusterIP
and reaches it only with `kubectl port-forward`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    address: str
    temporal_namespace: str
    task_queue: str
    sandbox_name: str
    suspended_seconds: int
    fail_first_step_attempt: bool

    @staticmethod
    def from_env() -> "Settings":
        return Settings(
            address=_required("TEMPORAL_ADDRESS"),
            temporal_namespace=os.environ.get("TEMPORAL_NAMESPACE", "default"),
            task_queue=os.environ.get("TEMPORAL_TASK_QUEUE", "nitro-sandbox-lifecycle"),
            sandbox_name=os.environ.get("SANDBOX_NAME", "lifecycle"),
            suspended_seconds=int(os.environ.get("SUSPENDED_SECONDS", "120")),
            fail_first_step_attempt=os.environ.get("FAIL_FIRST_STEP_ATTEMPT", "true").lower()
            == "true",
        )


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"error: {name} is not set in the Worker's environment")
    return value
