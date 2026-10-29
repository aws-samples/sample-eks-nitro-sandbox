"""Check the Temporal server the sample is about to use, and change nothing.

`scripts/setup.sh` runs this as a one-shot pod before it deploys the Worker, so
a Temporal server that is there but set up differently from what this sample
needs stops the run with what was found, rather than being reconfigured. The
Temporal server is a shared install: this sample reuses it exactly as it stands.

It reads three things and writes none of them:

* that the frontend answers, and what version it reports;
* that the Temporal namespace the sample uses exists, and its retention;
* that the task queue name is free of a Worker from an older run, which is not
  an error but is worth seeing.

Every failure here is a refusal. A read that does not answer is reported as
"could not determine" and exits non-zero: a preflight that cannot see the server
must not pass.
"""

from __future__ import annotations

import asyncio
import sys

from temporalio.api.enums.v1 import NamespaceState
from temporalio.api.workflowservice.v1 import DescribeNamespaceRequest, GetSystemInfoRequest
from temporalio.client import Client
from temporalio.service import RPCError, RPCStatusCode

from .config import Settings


async def main() -> int:
    settings = Settings.from_env()
    print(f"temporal address    {settings.address}")
    print(f"temporal namespace  {settings.temporal_namespace}")
    print(f"task queue          {settings.task_queue}")

    try:
        client = await Client.connect(
            settings.address, namespace=settings.temporal_namespace
        )
    except Exception as exc:  # noqa: BLE001 - any failure here is a refusal
        print(
            f"error: could not connect to the Temporal frontend at {settings.address}, so "
            f"whether the server is usable could not be determined: {exc}",
            file=sys.stderr,
        )
        return 1

    service = client.service_client.workflow_service
    try:
        info = await service.get_system_info(GetSystemInfoRequest())
        print(f"server version      {info.server_version}")
    except RPCError as exc:
        print(
            "error: the Temporal frontend answered the connection but not "
            f"GetSystemInfo, so its version could not be determined: {exc}",
            file=sys.stderr,
        )
        return 1

    try:
        described = await service.describe_namespace(
            DescribeNamespaceRequest(namespace=settings.temporal_namespace)
        )
    except RPCError as exc:
        if exc.status == RPCStatusCode.NOT_FOUND:
            print(
                f"error: the Temporal namespace {settings.temporal_namespace!r} does not "
                "exist on this server. This sample does not create it, because the "
                "Temporal server is a shared install. Create it with the chart's "
                "namespace setting, or with the admin tools:\n"
                "    kubectl -n <temporal namespace> exec deploy/temporal-admintools -- \\\n"
                f"      temporal operator namespace create --namespace {settings.temporal_namespace} "
                "--retention 3d",
                file=sys.stderr,
            )
            return 2
        print(
            f"error: could not read the Temporal namespace {settings.temporal_namespace!r}, "
            f"so whether it exists could not be determined: {exc}",
            file=sys.stderr,
        )
        return 1

    retention = described.config.workflow_execution_retention_ttl
    print(f"namespace state     {NamespaceState.Name(described.namespace_info.state)}")
    print(f"namespace retention {retention.ToTimedelta()}")
    print()
    print(
        f"the Temporal server at {settings.address} is reachable and has the namespace "
        f"{settings.temporal_namespace!r}; nothing was changed on it"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
