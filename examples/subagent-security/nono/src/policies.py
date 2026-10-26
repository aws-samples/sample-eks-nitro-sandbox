"""The nono profile for each of the analyst's tool roles.

The trusted controller generates these and writes them into a directory of its own, which
no role may write, so a role cannot widen its own profile and neither the model's answer
nor anything a role produces reaches this code.

Three roles, one function. What differs between them is small and deliberate:

  reader     reads its assigned input, writes its own output, and may send one GET to the
             approved supplier hostname.
  evaluator  the same files, and no network at all: network.block refuses even creating a
             socket, so the deterministic comparison runs offline.
  writer     the same files, the same GET, plus the one POST that submits a draft.

Every profile grants the shared analyst code read-only, because a role has to be able to
run it. "Reader" names the role in the procurement task, not a blanket read-only mount:
each role can write its own output directory and nothing else.

The field names here are nono's profile schema at the pinned version, v0.80.0:
workdir.access, filesystem.read, filesystem.allow, environment.allow_vars, network.block,
network.allow_domain, network.credentials and network.custom_credentials with its
endpoint_policy.
"""
import argparse
import json
import sys
from pathlib import Path

CASE = "rfp-001"

# Paths inside the sandbox. CODE and the fixtures are read-only in the image; SECRET and
# CA are Secret and ConfigMap mounts on the pod.
CODE = "/opt/analyst"
SECRET = "/opt/supplier-key/api-key"
CA = "/opt/supplier-ca/ca.crt"

ROLES = ("reader", "evaluator", "writer")

# The committed profiles under policies/, which the page shows, are generated for these
# two placeholders rather than for one cluster's names. The run checks both that the
# committed files are what the generator produces for them, and that substituting this
# run's namespace and run id into a committed file gives exactly the profile the run used.
PLACEHOLDER_NAMESPACE = "<NAMESPACE>"
PLACEHOLDER_RUN = "<RUN>"
PLACEHOLDER_API = f"https://supplier-api.{PLACEHOLDER_NAMESPACE}.svc.cluster.local:8443"
PLACEHOLDER_WORKSPACE = f"/var/lib/analyst/{PLACEHOLDER_RUN}"

# The only environment variables a role gets. The controller's own AWS variables are not
# in this list, so they are not inherited: an empty AWS environment is not on its own
# proof of credential isolation, which is why the sample also shows the role refused the
# Pod Identity token file and the Pod Identity endpoint.
ALLOW_VARS = ["PATH", "HOME", "LANG", "LC_ALL", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE"]


def profile(role: str, workspace, api_url: str) -> dict:
    """Build one role's profile.

    workspace is the role's own directory; it gets <workspace>/in read-only and
    <workspace>/out read-write. api_url is the approved supplier base URL, so the
    allowlist and the upstream always name the same host.
    """
    if role not in ROLES:
        raise ValueError(f"unknown role: {role}")
    workspace = Path(workspace)
    policy = {
        "meta": {"name": f"analyst-{role}", "version": "1.0.0"},
        # The process gets no access to the directory it was started in, so a role cannot
        # read or write the controller's working tree by relative path.
        "workdir": {"access": "none"},
        "filesystem": {
            "read": [CODE, str(workspace / "in")],
            "allow": [str(workspace / "out")],
        },
        "environment": {"allow_vars": list(ALLOW_VARS)},
        # Offline is the default, so a role that needs no network says nothing to get it.
        "network": {"block": True},
    }
    if role == "evaluator":
        return policy

    allow = [{"method": "GET", "path": f"/cases/{CASE}/suppliers"}]
    if role == "writer":
        allow.append({"method": "POST", "path": f"/cases/{CASE}/recommendations"})
    policy["network"] = {
        # One host, with its port. This is what the proxy will forward; it is not by
        # itself a demonstration that a role has no other route to the API. The run
        # probes that separately, by having a role try the resolved address directly,
        # and records the one refusal it gets rather than a general claim.
        "allow_domain": [api_url.split("://", 1)[1]],
        "credentials": ["supplier"],
        "custom_credentials": {
            "supplier": {
                "upstream": api_url,
                # The real key stays a file the proxy reads. The role is given a
                # placeholder in SUPPLIER_API_KEY and sends it in the ordinary header;
                # the proxy substitutes the real key for an approved request.
                "credential_key": "file://" + SECRET,
                "env_var": "SUPPLIER_API_KEY",
                "inject_header": "X-Api-Key",
                "credential_format": "{}",
                "tls_ca": CA,
                # Reaching the supplier is not the same permission as performing every
                # supplier operation: default deny, then the exact methods and paths.
                "endpoint_policy": {
                    "default": {"decision": "deny"},
                    "allow": allow,
                },
            }
        },
    }
    return policy


def rendered(role: str, api_url: str, workspace_root) -> str:
    """One role's profile as a file, from the run root that holds every role's workspace."""
    return json.dumps(profile(role, Path(workspace_root) / role, api_url), indent=2) + "\n"


def dump(directory, api_url=PLACEHOLDER_API, workspace_root=PLACEHOLDER_WORKSPACE) -> list:
    """Write every role's profile to a directory, formatted as the page shows them.

    The committed copies under policies/ are written by this function, so what the page
    shows cannot drift from what the controller generates. The run checks them: see
    check_committed below.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for role in ROLES:
        path = directory / f"{role}.json"
        path.write_text(rendered(role, api_url, workspace_root))
        written.append(path)
    return written


def check_committed(directory, api_url=PLACEHOLDER_API,
                    workspace_root=PLACEHOLDER_WORKSPACE) -> list:
    """Return the roles whose committed profile differs from the generated one."""
    directory = Path(directory)
    differ = []
    for role in ROLES:
        path = directory / f"{role}.json"
        if not path.exists() or path.read_text() != rendered(role, api_url, workspace_root):
            differ.append(role)
    return differ


def committed_for(directory, role: str, namespace: str, run_id: str) -> dict:
    """Read a committed profile and substitute this run's namespace and run id.

    What comes back is what the profile the run actually used has to equal, so the page
    and the live run cannot show different rules.
    """
    text = (Path(directory) / f"{role}.json").read_text()
    return json.loads(text.replace(PLACEHOLDER_NAMESPACE, namespace)
                          .replace(PLACEHOLDER_RUN, run_id))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("directory")
    parser.add_argument("--api-url", default=PLACEHOLDER_API)
    parser.add_argument("--workspace", default=PLACEHOLDER_WORKSPACE,
                        help="the run root that holds every role's workspace")
    parser.add_argument("--check", action="store_true",
                        help="report differences instead of writing")
    args = parser.parse_args()
    if args.check:
        differ = check_committed(args.directory, args.api_url, args.workspace)
        if differ:
            print("profiles differ from the generator: " + ", ".join(differ))
            sys.exit(1)
        print(f"the committed profiles match the generator for: {', '.join(ROLES)}")
    else:
        for written in dump(args.directory, args.api_url, args.workspace):
            print(written)
