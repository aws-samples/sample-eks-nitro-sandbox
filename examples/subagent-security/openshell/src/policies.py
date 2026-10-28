"""The OpenShell policies this sample applies, and the one-rule update it then makes.

The committed files in policy/ are what the page shows, so they are generated from this
module rather than hand-edited, and scripts/setup.sh refuses to run when the two disagree:

    python3 src/policies.py policy --check     # the check setup.sh runs
    ./scripts/policies.sh                      # regenerate policy/ after an edit here

Every field below is OpenShell's own v1 policy schema at the pinned release; nothing here
is this sample's invention. The schema is documented upstream under
docs/how-it-works/policies/schema.mdx at the commit versions.json pins.

Two things about the shape are worth knowing before reading it:

  * The two endpoints are separate entries, not one. The analyst reaches two different
    in-cluster destinations, the supplier API and the model bridge, so each one carries
    its own operation rules. A single entry covering both would let an operation allowed
    on one host be allowed on the other.
  * `binaries` names the interpreter allowed to use the destinations. It is configured
    here and the page says plainly that this sample does not run a second executable as
    its negative control, so the reader is not left thinking that half was tested.
"""
import json
import sys
from copy import deepcopy
from pathlib import Path

CASE = "rfp-001"

# The interpreter in the analyst image. python:3.13-slim installs it here, and the
# Dockerfile's own check asserts the path, so a base-image bump cannot silently leave
# this rule naming a binary that is not there.
PYTHON = "/usr/local/bin/python3.13"


def initial(supplier_host: str, bridge_host: str) -> dict:
    """The policy the sandbox is created with: one supplier read and the model call."""
    return {
        "version": 1,
        "filesystem_policy": {
            # The analyst's working directory is not granted just because it is the
            # working directory. Everything it may touch is listed.
            "include_workdir": False,
            # The interpreter and its standard library, the shared analyst code and the
            # proposals.
            #
            # Five of these seven paths OpenShell would add anyway: once a policy has any
            # network rule it puts /usr, /lib, /etc, /app, /var/log, /proc and
            # /dev/urandom in its own read-only baseline, and /tmp and /dev/null in the
            # writable one. They are written out here so the file states what the analyst
            # can actually open, rather than reading as though this sample had narrowed
            # the set to just these.
            #
            # The last two are the ones this sample adds, and they are the analyst's code
            # and inputs: /opt/analyst holds the shared analyst modules and the proposals,
            # /opt/openshell this sample's own probes. Both are needed, and a path that is
            # not listed is not readable: leaving /opt/openshell out made the interpreter
            # itself fail to open the program with EACCES, which is the policy working
            # rather than a bug, but it is also how a page could end up showing a startup
            # failure where it meant to show a refusal.
            "read_only": ["/usr", "/lib", "/etc", "/proc", "/dev/urandom",
                          "/opt/analyst", "/opt/openshell"],
            # The workspace the analyst writes its recommendation to, and scratch space.
            "read_write": ["/sandbox", "/tmp", "/dev/null"],
        },
        # hard_requirement means the sandbox fails to start if the kernel cannot enforce
        # the filesystem rules, rather than running without them and logging a finding.
        # The guest kernel has to provide Landlock ABI v3 or later; the run shows the
        # sandbox starting, which is what makes the later refusals attributable.
        "landlock": {"compatibility": "hard_requirement"},
        # These two fields are the whole of OpenShell's `process` schema: an identity, and
        # nothing else. There is no capability field and no no_new_privs field here, so
        # the page must not credit this block with those. They come from the pod spec
        # OpenShell's Kubernetes driver generates (capabilities.drop: ALL,
        # allowPrivilegeEscalation: false, seccompProfile: RuntimeDefault), and the
        # refused transition to root comes from a fixed seccomp filter inside OpenShell's
        # own in-pod runtime, which is not policy-configurable. The run reads all three
        # from the live process and the page says which mechanism each one is.
        "process": {"run_as_user": "1000", "run_as_group": "1000"},
        "network_policies": {
            "supplier": {
                "endpoints": [
                    {
                        "host": supplier_host,
                        "port": 8443,
                        "protocol": "rest",
                        "enforcement": "enforce",
                        "credential_binding": {"provider": "supplier"},
                        # The availability lookup, and nothing else on this host yet.
                        # The draft POST is added by draft_enabled() while the pod runs.
                        "rules": [
                            {"allow": {"method": "GET", "path": f"/cases/{CASE}/suppliers"}},
                        ],
                    },
                    {
                        "host": bridge_host,
                        "port": 8443,
                        "protocol": "rest",
                        "enforcement": "enforce",
                        "credential_binding": {"provider": "supplier"},
                        "rules": [
                            {"allow": {"method": "POST", "path": "/v1/chat/completions"}},
                        ],
                    },
                ],
                "binaries": [{"path": PYTHON}],
            },
        },
    }


def draft_enabled(policy: dict) -> dict:
    """The same policy with one more rule: the analyst may submit its recommendation.

    Returned as a whole policy, because `openshell policy set` replaces the sandbox's
    policy rather than patching it. Only the supplier endpoint's rules change: the
    filesystem grants are fixed for the life of the sandbox, and the purchase-order and
    supplier-record paths are still absent, so they stay denied.
    """
    result = deepcopy(policy)
    supplier = result["network_policies"]["supplier"]["endpoints"][0]
    supplier["rules"].append(
        {"allow": {"method": "POST", "path": f"/cases/{CASE}/recommendations"}})
    return result


def supplier_profile() -> dict:
    """The provider profile: how to authenticate, and deliberately nothing about where.

    `endpoints` and `binaries` are empty on purpose. A provider profile that named an
    endpoint would grant network permission of its own, on top of the worker policy's.
    With both lists empty the profile adds a credential and nothing else, and the
    endpoints above opt into it with `credential_binding`.

    auth_style `header` puts the credential straight into the named header, with no
    "Bearer " prefix, which is what the shared supplier API reads. `bearer` would send
    "Bearer <key>" in Authorization instead, and the shared API would reject it.
    """
    return {
        "id": "procurement-supplier",
        "display_name": "Procurement supplier",
        "category": "data",
        "inference_capable": False,
        "credentials": [{
            "name": "api_key",
            # The variable the analyst finds its placeholder in. The shared worker reads
            # SUPPLIER_API_KEY and sends it in the ordinary API header, so the analyst's
            # own code is the same here as in the other two Subagent security samples.
            "env_vars": ["SUPPLIER_API_KEY"],
            "required": True,
            "auth_style": "header",
            "header_name": "x-api-key",
        }],
        "endpoints": [],
        "binaries": [],
    }


FILES = ("initial", "draft-enabled", "supplier-profile")


def render(supplier_host: str, bridge_host: str) -> dict:
    policy = initial(supplier_host, bridge_host)
    return {"initial": policy,
            "draft-enabled": draft_enabled(policy),
            "supplier-profile": supplier_profile()}


# The committed files use these placeholder hosts; setup.sh substitutes the reader's own
# namespace at apply time, the same way the manifests in deploy/ are rendered. So the
# page can show the policy exactly as it is committed.
SUPPLIER_HOST = "supplier-api.<NAMESPACE>.svc.cluster.local"
BRIDGE_HOST = "analyst-bridge.<NAMESPACE>.svc.cluster.local"


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    target = Path(argv[0])
    check = "--check" in argv[1:]
    rendered = render(SUPPLIER_HOST, BRIDGE_HOST)
    stale = []
    for name in FILES:
        path = target / f"{name}.json"
        text = json.dumps(rendered[name], indent=2) + "\n"
        if check:
            if not path.exists() or path.read_text() != text:
                stale.append(str(path))
        else:
            path.write_text(text)
    if check and stale:
        print("These files are not what src/policies.py produces:", file=sys.stderr)
        for path in stale:
            print("  " + path, file=sys.stderr)
        print("Run ./scripts/policies.sh to regenerate them.", file=sys.stderr)
        return 1
    if not check:
        print(f"wrote {len(FILES)} files to {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
