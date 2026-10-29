"""The Temporal harness that drives a Nitro sandbox's lifecycle.

* `provider.py`  the five lifecycle verbs, each one Kubernetes operation. No
                 Temporal import, so it can be read and tested on its own.
* `activities.py` one thin retryable activity per verb.
* `workflow.py`  the durable workflow that brackets the whole lifecycle.
* `worker.py`    the Worker process, which hosts both.
* `start.py`     starts a run and prints its result.
* `preflight.py` reads the Temporal server and changes nothing.
"""
