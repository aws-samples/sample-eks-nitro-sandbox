#!/usr/bin/env python3
"""A small fake of kubectl, for this sample's offline tests only.

It answers from the "k8s" part of the world state (fakelib.py):

  k8s.objects   {"<plural>/<namespace or ->/<name>": object}; plurals: nodes, pods, services,
                namespaces, runtimeclasses, daemonsets, deployments, ciliumendpoints,
                configmaps, serviceaccounts
  k8s.answers   [{"match": substring of the joined argv, "stdout": "", "stderr": "", "rc": 0,
                  "times": n}]: canned answers, tried first, first match wins; with "times" the
                rule answers only n calls
  k8s.exec      [{"target": pod name or "node/<name>", "match": substring of the command after
                  "--", "stdout": "", "stderr": "", "rc": 0}]: kubectl exec and kubectl debug

Rules it enforces, each a refusal with exit 97 so a test sees it:
  * KUBECONFIG must be set and resolve under CB_RUN_DIR (the sample's own kubeconfig);
  * no `config use-context` and no `config set-context`;
  * no delete by label selector, --all or --field-selector (AGENTS.md: delete by exact name).

Environment: FAKE_KUBECTL_VERSION (default v1.36.2), plus FAKE_STATE, FAKE_LOG, FAKE_FAIL.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakelib  # noqa: E402

try:
    import yaml
except ImportError:
    sys.stderr.write("fake_kubectl.py: the offline tests need PyYAML (requirements-test.txt)\n")
    sys.exit(98)

PLURAL = {"node": "nodes", "no": "nodes", "pod": "pods", "po": "pods", "service": "services", "svc": "services",
          "namespace": "namespaces", "ns": "namespaces", "runtimeclass": "runtimeclasses",
          "daemonset": "daemonsets", "ds": "daemonsets", "deployment": "deployments", "deploy": "deployments",
          "ciliumendpoint": "ciliumendpoints", "cep": "ciliumendpoints", "configmap": "configmaps",
          "cm": "configmaps", "serviceaccount": "serviceaccounts", "sa": "serviceaccounts"}
CLUSTER_SCOPED = {"nodes", "namespaces", "runtimeclasses"}
WITH_VALUE = {"-n", "--namespace", "-o", "--output", "-l", "--selector", "-f", "--filename", "-c", "--container",
              "--context", "--kubeconfig", "--timeout", "--for", "--image", "--profile", "--field-selector",
              "--request-timeout", "--type", "-p", "--patch"}


def plural(kind):
    k = kind.lower().split(".")[0]
    return PLURAL.get(k, k if k.endswith("s") else k + "s")


def parse(argv):
    pos, opts, after = [], {}, None
    i = 0
    while i < len(argv):
        t = argv[i]
        if t == "--":
            after = argv[i + 1:]
            break
        if t.startswith("--") and "=" in t:
            k, v = t.split("=", 1)
            opts.setdefault(k, []).append(v)
        elif t.startswith("-o") and len(t) > 2 and not t.startswith("--"):
            opts.setdefault("-o", []).append(t[2:])
        elif t in WITH_VALUE and i + 1 < len(argv):
            opts.setdefault(t, []).append(argv[i + 1])
            i += 1
        elif t.startswith("-"):
            opts.setdefault(t, []).append("true")
        else:
            pos.append(t)
        i += 1
    return pos, opts, after


def opt(opts, *names):
    for n in names:
        if opts.get(n):
            return opts[n][-1]
    return None


def labels_match(obj, sel):
    labels = (obj.get("metadata") or {}).get("labels") or {}
    for term in [s for s in sel.split(",") if s]:
        if term.startswith("!"):
            if term[1:] in labels:
                return False
        elif "!=" in term:
            k, v = term.split("!=", 1)
            if labels.get(k) == v:
                return False
        elif "=" in term:
            k, v = term.split("=", 1)
            if labels.get(k.rstrip("=")) != v:
                return False
        elif term not in labels:
            return False
    return True


# ---- a small JSONPath, for the forms kubectl -o jsonpath= calls in this sample use --------------
def jp_tokens(expr):
    """'.a.b\\.c[0][*][?(@.type=="Ready")]' -> ['a', 'b.c', 0, '*', ('?', 'type', 'Ready')]"""
    toks, i, cur = [], 0, ""
    while i < len(expr):
        ch = expr[i]
        if ch == "\\" and i + 1 < len(expr):
            cur += expr[i + 1]
            i += 2
            continue
        if ch == ".":
            if cur:
                toks.append(cur)
            cur = ""
        elif ch == "[":
            if cur:
                toks.append(cur)
            cur = ""
            j = expr.index("]", i)
            inner = expr[i + 1:j]
            if inner == "*":
                toks.append("*")
            elif inner.isdigit():
                toks.append(int(inner))
            else:
                m = re.fullmatch(r"\?\(@\.([\w.\-/]+)\s*==\s*[\"']([^\"']*)[\"']\)", inner)
                if not m:
                    raise ValueError(f"jsonpath filter not modelled: {inner}")
                toks.append(("?", m.group(1), m.group(2)))
            i = j
        else:
            cur += ch
        i += 1
    if cur:
        toks.append(cur)
    return toks


def jp_eval(doc, expr):
    vals = [doc]
    for t in jp_tokens(expr):
        nxt = []
        for v in vals:
            if t == "*":
                nxt += v if isinstance(v, list) else list(v.values()) if isinstance(v, dict) else []
            elif isinstance(t, int):
                if isinstance(v, list) and t < len(v):
                    nxt.append(v[t])
            elif isinstance(t, tuple):
                for item in v if isinstance(v, list) else []:
                    got = item
                    for p in t[1].split("."):
                        got = got.get(p) if isinstance(got, dict) else None
                    if got is not None and str(got) == t[2]:
                        nxt.append(item)
            elif isinstance(v, dict) and t in v:
                nxt.append(v[t])
        vals = nxt
    return vals


def jp_render(doc, template):
    out, i = "", 0
    for m in re.finditer(r"\{([^{}]*)\}", template):
        out += template[i:m.start()]
        inner = m.group(1)
        if inner.startswith('"') and inner.endswith('"'):
            out += inner[1:-1].encode().decode("unicode_escape")
        else:
            vals = jp_eval(doc, inner.lstrip("."))
            out += " ".join(v if isinstance(v, str) else json.dumps(v) for v in vals)
        i = m.end()
    return out + template[i:]


def objects(state, kind, ns, name=None, sel=None):
    objs = state.setdefault("k8s", {}).setdefault("objects", {})
    p = plural(kind)
    out = []
    for key, obj in sorted(objs.items()):
        k, n, nm = key.split("/", 2)
        if k != p:
            continue
        if p not in CLUSTER_SCOPED and ns is not None and n != ns:
            continue
        if name and nm != name:
            continue
        if sel and not labels_match(obj, sel):
            continue
        out.append(obj)
    return out


def emit(result, fmt, single):
    if fmt is None or fmt == "wide":
        for o in result if not single else [result]:
            print((o.get("metadata") or {}).get("name", ""))
        return
    if fmt == "json":
        print(json.dumps(result, indent=4))
    elif fmt == "yaml":
        print(yaml.safe_dump(result, sort_keys=False))
    elif fmt == "name":
        for o in result.get("items", []) if not single else [result]:
            print(f"{plural(o.get('kind', 'object'))[:-1]}/{o['metadata']['name']}")
    elif fmt.startswith("jsonpath="):
        sys.stdout.write(jp_render(result, fmt[len("jsonpath="):]))
    else:
        raise SystemExit(f"FAKE kubectl: output format {fmt} not modelled")


def load_docs(path):
    text = sys.stdin.read() if path == "-" else open(path).read()
    return [d for d in yaml.safe_load_all(text) if d]


def key_of(doc, ns_default):
    p = plural(doc["kind"])
    ns = "-" if p in CLUSTER_SCOPED else (doc.get("metadata", {}).get("namespace") or ns_default or "default")
    return f"{p}/{ns}/{doc['metadata']['name']}"


def refuse(msg):
    print(f"FAKE kubectl: {msg}", file=sys.stderr)
    return 97


def run(argv, state):
    pos, opts, after = parse(argv)
    ns = opt(opts, "-n", "--namespace")
    fmt = opt(opts, "-o", "--output")
    k8s = state.setdefault("k8s", {})
    joined = " ".join(argv)
    for rule in k8s.get("answers", []):
        if rule["match"] in joined and rule.get("times", 1) > 0:
            if "times" in rule:
                rule["times"] -= 1
            sys.stdout.write(rule.get("stdout", ""))
            sys.stderr.write(rule.get("stderr", ""))
            return rule.get("rc", 0)
    verb = pos[0] if pos else ""
    if verb == "version":
        v = os.environ.get("FAKE_KUBECTL_VERSION", "v1.36.2")
        mm = re.match(r"v(\d+)\.(\d+)", v)
        if fmt == "json":
            print(json.dumps({"clientVersion": {"gitVersion": v, "major": mm.group(1) if mm else "",
                                                "minor": mm.group(2) if mm else ""}}))
        else:
            print(f"Client Version: {v}")
        return 0
    if verb == "config":
        if pos[1:2] in (["use-context"], ["set-context"]):
            return refuse(f"refused `kubectl config {pos[1]}`: the sample must not change a context")
        if pos[1:2] == ["current-context"]:
            print(k8s.get("context", "fake-context"))
            return 0
        if pos[1:2] == ["view"]:
            path = opt(opts, "--kubeconfig") or os.environ.get("KUBECONFIG", "")
            try:
                doc = yaml.safe_load(open(path)) or {}
            except OSError:
                print(f"error: stat {path}: no such file or directory", file=sys.stderr)
                return 1
            ctx = opt(opts, "--context") or doc.get("current-context")
            if "--minify" in opts:
                c = next((x for x in doc.get("contexts") or [] if x.get("name") == ctx), None)
                if c is None:
                    print(f'error: context "{ctx}" does not exist', file=sys.stderr)
                    return 1
                cl = c["context"].get("cluster")
                doc = dict(doc, contexts=[c], clusters=[x for x in doc.get("clusters") or [] if x.get("name") == cl])
            emit(doc, fmt or "yaml", True)
            return 0
    if verb == "get" and "--raw" in opts:
        # get --raw <path>: the answer the test state holds for that API path (k8s.raw), else 404.
        path = pos[1] if len(pos) > 1 else ""
        raw = k8s.get("raw", {})
        if path not in raw:
            print(f'Error from server (NotFound): the server could not find the requested resource ({path})', file=sys.stderr)
            return 1
        body = raw[path]
        sys.stdout.write(body if isinstance(body, str) else json.dumps(body))
        return 0
    if verb == "get":
        if len(pos) < 2:
            return refuse(f"get without a kind: {joined}")
        kinds = pos[1].split(",")
        name = pos[2] if len(pos) > 2 else None
        if "/" in pos[1]:
            kinds, name = [pos[1].split("/")[0]], pos[1].split("/", 1)[1]
        sel = opt(opts, "-l", "--selector")
        all_ns = "-A" in opts or "--all-namespaces" in opts
        items = []
        if len(pos) > 3 and "/" not in pos[1]:
            # Several names of one kind (`get daemonset aws-node kube-proxy`): the ones found, as a list.
            for n in pos[2:]:
                for kind in kinds:
                    scope = None if (all_ns or plural(kind) in CLUSTER_SCOPED) else (ns or "default")
                    found = objects(state, kind, scope, n, sel)
                    if not found and "--ignore-not-found" not in opts:
                        print(f'Error from server (NotFound): {plural(kind)} "{n}" not found', file=sys.stderr)
                        return 1
                    items += found
            emit({"apiVersion": "v1", "kind": "List", "items": items}, fmt, False)
            return 0
        for kind in kinds:
            scope = None if (all_ns or plural(kind) in CLUSTER_SCOPED) else (ns or "default")
            items += objects(state, kind, scope, name, sel)
        if name:
            if not items:
                if "--ignore-not-found" in opts:
                    return 0
                print(f'Error from server (NotFound): {plural(kinds[0])} "{name}" not found', file=sys.stderr)
                return 1
            emit(items[0], fmt, True)
            return 0
        emit({"apiVersion": "v1", "kind": "List", "items": items}, fmt, False)
        return 0
    if verb in ("apply", "create"):
        path = opt(opts, "-f", "--filename")
        if path is None:
            return refuse(f"{verb} without -f: {joined}")
        objs = k8s.setdefault("objects", {})
        made = []
        for doc in load_docs(path):
            key = key_of(doc, ns)
            if verb == "create" and key in objs:
                print(f'Error from server (AlreadyExists): {key.split("/")[0]} "{doc["metadata"]["name"]}" already exists', file=sys.stderr)
                return 1
            objs[key] = doc
            made.append(key)
            print(f"{plural(doc['kind'])[:-1]}/{doc['metadata']['name']} {'created' if verb == 'create' else 'configured'}")
        fakelib.log_call("kubectl", f"{verb} objects", [], {"objects": made})
        return 0
    if verb == "delete":
        if opt(opts, "-l", "--selector", "--field-selector") or "--all" in opts:
            return refuse(f"refused a delete by selector or --all: {joined}")
        objs = k8s.setdefault("objects", {})
        targets = []
        path = opt(opts, "-f", "--filename")
        if path:
            targets = [key_of(d, ns) for d in load_docs(path)]
        elif len(pos) >= 3:
            p = plural(pos[1])
            targets = [f"{p}/{'-' if p in CLUSTER_SCOPED else (ns or 'default')}/{n}" for n in pos[2:]]
        elif len(pos) == 2 and "/" in pos[1]:
            k, n = pos[1].split("/", 1)
            p = plural(k)
            targets = [f"{p}/{'-' if p in CLUSTER_SCOPED else (ns or 'default')}/{n}"]
        else:
            return refuse(f"delete without an exact name: {joined}")
        for t in targets:
            if t in objs:
                if not objs[t].get("StaysAfterDelete"):
                    del objs[t]
                print(f"{t.split('/')[0][:-1]} \"{t.split('/')[2]}\" deleted")
            elif "--ignore-not-found" not in opts and opt(opts, "--ignore-not-found") != "true":
                print(f'Error from server (NotFound): {t.split("/")[0]} "{t.split("/")[2]}" not found', file=sys.stderr)
                return 1
        fakelib.log_call("kubectl", "delete objects", [], {"objects": targets})
        return 0
    if verb in ("exec", "debug"):
        target = next((p for p in pos[1:]), "")
        cmd = " ".join(after or [])
        for rule in k8s.get("exec", []):
            if rule.get("target") == target and rule.get("match", "") in cmd:
                sys.stdout.write(rule.get("stdout", ""))
                sys.stderr.write(rule.get("stderr", ""))
                return rule.get("rc", 0)
        return refuse(f"no exec rule in the test state for {verb} {target} -- {cmd}")
    if verb in ("wait", "rollout"):
        return k8s.get("wait_rc", 0)
    if verb == "cluster-info":
        print("Kubernetes control plane is running at https://EXAMPLE.gr7.us-west-2.eks.amazonaws.com")
        return 0
    return refuse(f"unexpected call not modelled by the test: {joined}")


def main(argv):
    if argv[:2] == ["version", "--client"] and not os.environ.get("FAKE_STATE"):
        print(f"Client Version: {os.environ.get('FAKE_KUBECTL_VERSION', 'v1.36.2')}")
        return 0
    fakelib.require_state("kubectl")
    pos, _, after = parse(argv)
    call = " ".join(pos[:2]) if pos else ""
    fakelib.log_call("kubectl", call, argv)
    run_dir = os.path.realpath(os.environ.get("CB_RUN_DIR", "")) if os.environ.get("CB_RUN_DIR") else ""
    kc = next((a.split("=", 1)[1] for a in argv if a.startswith("--kubeconfig=")), None)
    if kc is None and "--kubeconfig" in argv and argv.index("--kubeconfig") + 1 < len(argv):
        kc = argv[argv.index("--kubeconfig") + 1]
    kc = kc or os.environ.get("KUBECONFIG", "")
    if pos[:1] != ["version"]:
        if not run_dir or not kc or not (os.path.realpath(kc) + "/").startswith(run_dir + "/"):
            return refuse(f"KUBECONFIG ({kc or 'unset'}) is not under CB_RUN_DIR ({run_dir or 'unset'}); "
                          "the sample must use its own kubeconfig")
    code = fakelib.injected_failure("kubectl", call, argv)
    if code:
        print(f"Error from server ({code}): injected by the test", file=sys.stderr)
        return 1
    with fakelib.world() as (state, _):
        return run(argv, state)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
