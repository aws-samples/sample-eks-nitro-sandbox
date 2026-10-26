"""What a container can read about the machine it is running on.

The generated confidential policy denies exec (Amazon EKS User Guide, *Cedar policies*),
so a pod cannot be read from the outside. Everything the page shows about where this
workload ran is printed here by the workload itself and read back with `kubectl logs`,
which the policy permits.

`python readings.py` prints the four machine readings and nothing else. That is how the
ordinary comparison pod runs this file: same image, same code, an ordinary pod.
"""

from __future__ import annotations

import os
import sys


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError as error:
        return f"unavailable ({error.strerror})"


def print_machine_readings() -> None:
    """Print the four readings that say whether this ran in a sandbox of its own.

    The hello sandbox page introduces them. In a sandbox the kernel is the guest's own
    build, the uptime matches the pod's age because the VM booted with the pod, the disks
    are virtio devices, and the product name is the VM rather than the EC2 instance type.
    """
    uname = os.uname()
    print(f"kernel:  {uname.release} {uname.version}", flush=True)
    print(f"uptime:  {_read('/proc/uptime').split(' ')[0]}s", flush=True)
    try:
        disks = " ".join(sorted(os.listdir("/sys/block")))
    except OSError as error:
        disks = f"unavailable ({error.strerror})"
    print(f"disks:   {disks}", flush=True)
    print(f"product: {_read('/sys/class/dmi/id/product_name')}", flush=True)


def main() -> int:
    print_machine_readings()
    return 0


if __name__ == "__main__":
    sys.exit(main())
