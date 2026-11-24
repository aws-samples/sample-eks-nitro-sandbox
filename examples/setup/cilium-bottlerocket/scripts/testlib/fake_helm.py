#!/usr/bin/env python3
"""A small fake of the Helm client, for this sample's offline tests only.

  version [--short|--template ...]   prints FAKE_HELM_VERSION (default v3.19.0+g3d8990f)
  upgrade --install <rel> <chart>    records the chart, --version, every -f file's content and every
                                     --set in state["helm"]["releases"][<namespace>/<rel>] and in the
                                     call log; refuses a call without --version (an unpinned chart)
  install <rel> <chart>              the same, refused when the release exists
  status <rel> -n <ns>               "STATUS: deployed", or "Error: release: not found" (exit 1)
  get values <rel> -n <ns> [-o json] the recorded --set values and files, merged, as JSON
  uninstall <rel> -n <ns>            removes the release

Environment: FAKE_HELM_VERSION, plus FAKE_STATE, FAKE_LOG, FAKE_FAIL (fakelib.py).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakelib  # noqa: E402

try:
    import yaml
except ImportError:
    sys.stderr.write("fake_helm.py: the offline tests need PyYAML (requirements-test.txt)\n")
    sys.exit(98)

WITH_VALUE = {"--version", "-n", "--namespace", "-f", "--values", "--set", "--set-string", "-o", "--output",
              "--kube-context", "--kubeconfig", "--timeout", "--template"}


def parse(argv):
    pos, opts, i = [], {}, 0
    while i < len(argv):
        t = argv[i]
        if t.startswith("--") and "=" in t:
            k, v = t.split("=", 1)
            opts.setdefault(k, []).append(v)
        elif t in WITH_VALUE and i + 1 < len(argv):
            opts.setdefault(t, []).append(argv[i + 1])
            i += 1
        elif t.startswith("-"):
            opts.setdefault(t, []).append("true")
        else:
            pos.append(t)
        i += 1
    return pos, opts


def setpath(doc, dotted, value):
    parts = dotted.split(".")
    for p in parts[:-1]:
        doc = doc.setdefault(p, {})
    doc[parts[-1]] = value


def main(argv):
    pos, opts = parse(argv)
    if pos[:1] == ["version"]:
        print(os.environ.get("FAKE_HELM_VERSION", "v3.19.0+g3d8990f"))
        return 0
    fakelib.require_state("helm")
    ns = (opts.get("-n") or opts.get("--namespace") or ["default"])[-1]
    call = " ".join(pos[:2]) if pos[:1] == ["get"] else (pos[0] if pos else "")
    files = {f: open(f).read() for f in opts.get("-f", []) + opts.get("--values", [])}
    fakelib.log_call("helm", call, argv, {"values_files": files} if files else None)
    code = fakelib.injected_failure("helm", call, argv)
    if code:
        print(f"Error: {code}: injected by the test", file=sys.stderr)
        return 1
    with fakelib.world() as (state, _):
        rels = state.setdefault("helm", {}).setdefault("releases", {})
        if pos[:1] in (["upgrade"], ["install"]):
            rel, chart = pos[1], pos[2]
            key = f"{ns}/{rel}"
            if pos[0] == "upgrade" and "--install" not in opts:
                if key not in rels:
                    print(f'Error: UPGRADE FAILED: "{rel}" has no deployed releases', file=sys.stderr)
                    return 1
            if pos[0] == "install" and key in rels:
                print("Error: INSTALLATION FAILED: cannot re-use a name that is still in use", file=sys.stderr)
                return 1
            if not opts.get("--version"):
                print("FAKE helm: refused an install without --version (an unpinned chart)", file=sys.stderr)
                return 97
            values = {}
            for text in files.values():
                values.update(yaml.safe_load(text) or {})
            for s in opts.get("--set", []) + opts.get("--set-string", []):
                k, v = s.split("=", 1)
                setpath(values, k, v)
            rels[key] = {"chart": chart, "version": opts["--version"][-1], "values": values, "status": "deployed"}
            if rel == "cilium":
                # What the Cilium chart creates that setup.sh reads: the agent DaemonSet (Linux
                # nodes, every taint tolerated, as the chart's defaults) and the operator Deployment.
                objs = state.setdefault("k8s", {}).setdefault("objects", {})
                objs.setdefault(f"daemonsets/{ns}/cilium", {
                    "apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "cilium", "namespace": ns},
                    "spec": {"template": {"spec": {"nodeSelector": {"kubernetes.io/os": "linux"},
                                                   "tolerations": [{"operator": "Exists"}]}}}})
                objs.setdefault(f"deployments/{ns}/cilium-operator", {
                    "apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "cilium-operator", "namespace": ns}})
            print(f'Release "{rel}" has been {"upgraded" if pos[0] == "upgrade" else "installed"}. Happy Helming!')
            return 0
        if pos[:1] == ["status"]:
            r = rels.get(f"{ns}/{pos[1]}")
            if not r:
                print("Error: release: not found", file=sys.stderr)
                return 1
            print(f"NAME: {pos[1]}\nNAMESPACE: {ns}\nSTATUS: {r['status']}")
            return 0
        if pos[:2] == ["get", "values"]:
            r = rels.get(f"{ns}/{pos[2]}")
            if not r:
                print("Error: release: not found", file=sys.stderr)
                return 1
            print(json.dumps(r["values"]))
            return 0
        if pos[:1] == ["uninstall"]:
            if f"{ns}/{pos[1]}" not in rels:
                print(f"Error: uninstall: Release not loaded: {pos[1]}: release: not found", file=sys.stderr)
                return 1
            del rels[f"{ns}/{pos[1]}"]
            print(f'release "{pos[1]}" uninstalled')
            return 0
    print(f"FAKE helm: unexpected call not modelled by the test: {' '.join(argv)}", file=sys.stderr)
    return 97


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
