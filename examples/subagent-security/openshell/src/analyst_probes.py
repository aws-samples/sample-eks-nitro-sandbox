"""The analyst, as OpenShell runs it: the shared worker plus this sample's own probes.

Every Subagent security sample runs the same program, `analyst/src/worker.py`, under its
own confinement layer. This file is how that happens here: it adds the probes this layer
needs and hands them to the shared worker rather than editing it, which is the contract
the shared worker documents.

    python3 /opt/openshell/analyst_probes.py <action> [args...]

The shared worker supplies `read`, `write`, `evaluate`, `api`, `socket` and `connect`, and
prints every result on one `ANALYST_RESULT=` line. The rules it sets are what make this
page's output readable as evidence, and they hold for the probes below too:

  * a refusal comes back as structured data, never as a crash;
  * everything else is an error, with a non-zero exit and no result line.

That second rule is the one that matters most here. A startup failure, a timeout, a TLS
error or a 401 must never be able to read as a policy refusal, so none of them is caught.
"""
import errno
import json
import os
import sys
from pathlib import Path

# The shared analyst modules are found by path, not by PYTHONPATH. OpenShell starts the
# restricted process with an environment it builds rather than the image's, so the
# image's own PYTHONPATH does not reach it, and an import that depended on one would
# fail at startup. A startup failure must never be able to read as a policy refusal, so
# the program makes itself importable instead.
for _directory in ("/opt/analyst", "/opt/openshell"):
    if _directory not in sys.path:
        sys.path.insert(0, _directory)

import worker
from business import (CASE, availability_from_reply, compare, load_json,
                      proposal_matches_case, render_report, report_cites_sources,
                      report_choice_matches)

FIXTURES = Path("/opt/analyst/fixtures")
WORKSPACE = Path("/sandbox/output")

# Paths the analyst is deliberately pointed at, and what each one is for.
#   the case         inside a granted read-only path: it must open
#   a proposal       inside the same granted path, mode 666 in the image, so a refused
#                    write is the policy and not a Unix permission
#   the canary       outside every granted path, mode 644, so the same control can read it
#   the boundary key OpenShell's own material, staged at pod start and gone before the
#                    analyst runs
#   the token        a Kubernetes service-account token, never mounted into this pod
CANARY = "/protected/canary"
BOUNDARY_KEY = "/.openshell/state/bootstrap/boundary.json"
SERVICE_TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"


def act_identity(args):
    """Report the restricted process's own identity, with no value of any credential.

    Each field here is enforced by a different mechanism, and the page has to say which,
    so they are reported together rather than credited to one thing:

      uid, gid        OpenShell's policy, `process.run_as_user` and `run_as_group`, and
                      the same identity in the pod spec its driver generates
      CapEff          the generated pod spec: capabilities.drop ALL
      NoNewPrivs      the generated pod spec: allowPrivilegeEscalation false
      kernel, devices the Nitro sandbox, not OpenShell at all

    The credential is reported by name, by prefix and by keyed digest, never by value.
    The digest key is a per-run salt the operator passes in; it is not a secret, and the
    real key never comes near this process. The operator computes the same digest over
    the real key outside the sandbox: equal digests would mean the real key had reached
    the analyst, and the run fails if they match.
    """
    digest_key = args[0] if args else ""
    if not digest_key:
        raise ValueError(
            "act_identity needs a per-run digest salt as its argument, so the operator "
            "can compare this process's credential against the real one without either "
            "value being printed.")
    status = dict(line.split(":\t", 1)
                  for line in Path("/proc/self/status").read_text().splitlines()
                  if ":\t" in line)
    credential = os.environ.get("SUPPLIER_API_KEY", "")
    return {
        "uid": os.getuid(),
        "gid": os.getgid(),
        "no_new_privs": status.get("NoNewPrivs", "").strip(),
        "cap_eff": status.get("CapEff", "").strip(),
        "kernel": os.uname().release,
        "kernel_version": os.uname().version,
        # A Nitro sandbox guest sees virtio disks where an ordinary pod sees the
        # instance's NVMe devices.
        "block_devices": sorted(
            line.split()[-1]
            for line in Path("/proc/partitions").read_text().splitlines()[2:]
            if line.split()),
        "uptime_seconds": float(
            Path("/proc/uptime").read_text().split()[0]),
        # Credentials by name and shape only.
        "aws_names": sorted(k for k in os.environ if k.startswith("AWS_")),
        "aws_credential_names": sorted(k for k in worker.AWS_CREDENTIAL_VARS
                                       if k in os.environ),
        "model_key_names": sorted(k for k in os.environ
                                  if k.endswith("_API_KEY") and k != "SUPPLIER_API_KEY"),
        "api_key_present": bool(credential),
        "api_key_length": len(credential),
        # OpenShell hands a restricted process a placeholder of the form
        # openshell:resolve:env:<VAR>. The prefix is what the page checks; the whole
        # value is not printed, because the shape of a credential is not worth
        # publishing even when it is only a placeholder.
        "api_key_is_placeholder": credential.startswith("openshell:"),
        "api_key_digest": worker.keyed_digest(digest_key, credential),
    }


def act_setuid_root(args):
    """Try to become root. OpenShell's in-pod runtime refuses this with a fixed seccomp
    filter, which is not policy-configurable, so the refusal is the runtime's and not
    something this sample's policy asked for."""
    try:
        os.setuid(0)
    except OSError as error:
        return {"denied_errno": error.errno}
    # Reaching here is a failure of the thing the sample claims, not a result to record.
    raise RuntimeError("os.setuid(0) succeeded, so the analyst is able to become root")


def act_open_probe(args):
    """Open a path for reading or writing, without reading or writing a byte.

    os.open rather than the shared worker's read and write actions, which load and dump
    file contents: a probe against credential material must not pull its bytes into a
    process whose output the page publishes.

    Three modes, and the distinction between the last two matters:

      read    O_RDONLY
      write   O_WRONLY, and deliberately no O_CREAT. Every `write` probe here targets a
              file that already exists inside a read-only grant, so creating one would
              turn "refused" into "created something new" and the result would no longer
              be about the policy.
      create  O_WRONLY|O_CREAT, for the writable workspace, where the point is that the
              analyst really can make a file. Without O_CREAT this returned ENOENT for a
              path that simply did not exist yet, which reads as a refusal and is not one.
    """
    path, mode = args[0], args[1]
    if mode not in ("read", "write", "create"):
        raise ValueError(f"unknown open-probe mode: {mode!r}")
    flags = {"read": os.O_RDONLY,
             "write": os.O_WRONLY,
             "create": os.O_WRONLY | os.O_CREAT}[mode]
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        # ENOENT is kept distinct from a refusal: the boundary key is expected to be
        # absent rather than forbidden, and the two are different claims.
        return {"denied_errno": error.errno,
                "errno_name": errno.errorcode.get(error.errno, "")}
    os.close(descriptor)
    return {"allowed": True}


def act_analyze(args):
    """The analyst's actual work, through OpenShell and the model bridge.

    Nothing in here is about confinement. It reads the case, checks each proposal
    document against the case's own summary, looks up availability through the one
    allowed supplier operation, runs the shared deterministic comparison, has the model
    explain it, and checks the answer before saving it.
    """
    supplier_api, bridge, run_id, model = args[:4]
    case = load_json(FIXTURES / "case.json")

    # The comparison is tied to the documents that will be cited, not to the summary
    # baked into the case file.
    for supplier in case["suppliers"]:
        # The case names each source by its S3 key, "proposals/<case>/<id>.json", which is
        # what the model has to cite. In the image the same documents sit under
        # fixtures/proposals/, so only the file name carries over.
        document = load_json(FIXTURES / "proposals" / Path(supplier["source"]).name)
        if not proposal_matches_case(document, supplier):
            raise RuntimeError(
                f"the proposal document for {supplier['id']} does not match the case")

    lookup = worker.request(f"{supplier_api}/cases/{CASE}/suppliers", "GET",
                            f"{run_id}-availability")
    if lookup.get("status") != 200:
        raise RuntimeError(f"the supplier availability lookup failed: {lookup}")
    comparison = compare(case, availability_from_reply(lookup["body"]))

    prompt = (
        "Explain this verified supplier comparison for a procurement recommendation. "
        "Return ONLY a JSON object with two fields: recommended_supplier, the exact "
        "supplier id selected from the evidence, and analysis_markdown, a concise "
        "Markdown comparison. Cite each supplier's source path exactly as the evidence "
        "gives it. Recommend only a supplier the evidence marks eligible. This is a "
        "draft: do not place an order and do not propose changing a supplier record.\n"
        + json.dumps({"requirements": case["requirements"], **comparison}))
    answer = worker.request(
        f"{bridge}/v1/chat/completions", "POST", f"{run_id}-inference",
        body={"model": model, "messages": [{"role": "user", "content": prompt}]})
    if answer.get("status") != 200:
        raise RuntimeError(f"the model call failed: {answer}")
    completion = answer["body"]
    text = completion["choices"][0]["message"]["content"].strip()
    # Models commonly wrap JSON in a code block even when asked not to.
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    report = json.loads(text)

    # The two gates, from the shared module, run before anything is saved. They are
    # separate on purpose: the first reads the model's explicit choice field and nothing
    # else, so a supplier named only in the prose or in a citation cannot satisfy it.
    if not report_choice_matches(report, comparison["recommended_supplier"]):
        raise RuntimeError(
            "the model's recommended_supplier does not match the verified comparison")
    if not report_cites_sources(report, case):
        raise RuntimeError("the model's analysis does not cite every original proposal")

    WORKSPACE.mkdir(parents=True, exist_ok=True)
    (WORKSPACE / "recommendation.md").write_text(render_report(report, case))
    (WORKSPACE / "evidence.json").write_text(json.dumps(
        {"run_id": run_id, "comparison": comparison, "report": report}, indent=2))
    return {
        "run_id": run_id,
        "recommended_supplier": report["recommended_supplier"],
        "cites_all_sources": True,
        "model": completion["model"],
        "usage": completion["usage"],
        "bridge_credential_provider": completion["bridge_credential_provider"],
        "workspace": str(WORKSPACE),
    }


def act_submit(args):
    """Submit the saved recommendation to the supplier API.

    Denied by the initial policy and allowed after the operator's update, with nothing
    about the request itself changing between the two attempts.
    """
    supplier_api, run_id = args[:2]
    evidence = load_json(WORKSPACE / "evidence.json")
    return worker.request(f"{supplier_api}/cases/{CASE}/recommendations", "POST",
                          run_id, body={"draft": evidence["report"]})


EXTRA = {
    "identity": act_identity,
    "setuid-root": act_setuid_root,
    "open-probe": act_open_probe,
    "analyze": act_analyze,
    "submit": act_submit,
}

if __name__ == "__main__":
    worker.main(extra=EXTRA)
