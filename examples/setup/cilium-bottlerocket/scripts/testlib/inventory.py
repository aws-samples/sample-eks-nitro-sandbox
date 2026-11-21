#!/usr/bin/env python3
"""The check inventory of this sample, generated from the scripts.
Nothing in it is written by hand.

    inventory.py <sample-dir>                 JSON: {"tags": {tag: [site, ...]}, "untagged": [site, ...]}
    inventory.py <sample-dir> --mutate <tag> <out-sample-dir>
        copy the sample to <out-sample-dir> with every site of <tag> neutralised; print the
        changed sites; exit 1 when a changed file no longer parses (bash -n, compile())

A site is {"file", "line", "form"}. The refusal forms it knows:
  bash    die "E_<TAG>: ..."   (anywhere on the line: after || or &&, inside if)
  Python  need(<cond>, "E_<TAG>", ...) / require(<cond>, "E_<TAG>...", ...)   any helper whose name is
          in CALL_HELPERS, with the tag as the first string literal among its arguments
          raise <Exception>("E_<TAG>...", ...)
An untagged site is the same form with no E_<TAG> literal: a die "<text>", a need/require whose
message has no tag, a raise of a refusal exception without a tag, and in bash a printf or echo of
"ERROR:" not followed by a tag.

The mutants: bash `die` becomes `:` (a no-op that keeps its arguments), Python need/require gets
`True or ` before its condition, and a raise becomes `if False: raise ...`.
"""
import ast
import json
import os
import re
import shutil
import subprocess
import sys

TAG = re.compile(r"E_[A-Z0-9_]+")
CALL_HELPERS = {"need", "require"}
RAISE_NAMES = {"Refused", "Reject", "Unknown", "Refusal", "CheckFailed"}
SCAN = [("setup.sh", "sh"), ("test.sh", "sh"), ("clean.sh", "sh")]
SCAN_DIRS = [("scripts", False), ("scripts/lib", False), ("scripts/builder", False), ("packages/lib", False),
             ("variant", False)]
SKIP = re.compile(r"^scripts/(test-[^/]*\.sh|testlib/.*)$")
# die / could_not, then either an unquoted tag word (die E_TAG "text") or a quoted "E_TAG: text".
BASH_DIE = re.compile(r"(^|[\s;&|({!])(die|could_not)(\s+)")
BASH_TAG = re.compile(r"(?:(E_[A-Z0-9_]+)(?=[\s;)]|$)|([\"'])(E_[A-Z0-9_]+):)")
BASH_ERRPRINT = re.compile(r"(printf|echo)\s+[\"'][^\"']*ERROR:(?!\s*(E_|%s))")
# echo "ERROR: E_TAG: ..." >&2; exit 1  on one line (used before die exists)
BASH_ECHO_TAG = re.compile(r"(?:printf|echo)\s+[\"']ERROR:\s*(E_[A-Z0-9_]+):")


def files(root):
    out = []
    for name, kind in SCAN:
        if os.path.isfile(os.path.join(root, name)):
            out.append((name, kind))
    for d, _ in SCAN_DIRS:
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for n in sorted(os.listdir(p)):
            rel = f"{d}/{n}"
            if SKIP.match(rel) or not os.path.isfile(os.path.join(root, rel)):
                continue
            if n.endswith(".sh"):
                out.append((rel, "sh"))
            elif n.endswith(".py"):
                out.append((rel, "py"))
    return out


def bash_sites(rel, text):
    tagged, untagged = [], []
    all_lines = text.splitlines()
    for n, line in enumerate(all_lines, 1):
        s = line.lstrip()
        if s.startswith("#") or re.match(r"^\s*(die|could_not)\s*\(\)", line):
            continue
        found = False
        for m in BASH_DIE.finditer(line):
            found = True
            t = BASH_TAG.match(line[m.end():])
            tag = (t.group(1) or t.group(3)) if t else None
            (tagged if tag else untagged).append({"file": rel, "line": n, "form": "bash-die", "tag": tag,
                                                  "col": m.start(2)})
        if found:
            continue
        e = BASH_ECHO_TAG.search(line)
        x = re.search(r"\b(exit|return)\s+[0-9]", line)
        # The exit can also be the next line (a case branch: printf 'ERROR: E_TAG: ...' >&2, then exit "$rc").
        xn = re.match(r"^\s*(exit|return)\b", all_lines[n]) if n < len(all_lines) else None
        if e and x:
            tagged.append({"file": rel, "line": n, "form": "bash-echo", "tag": e.group(1),
                           "col": x.start(), "word": x.group(1), "ecol": e.start()})
        elif e and xn:
            tagged.append({"file": rel, "line": n, "form": "bash-echo", "tag": e.group(1), "exit_line": n + 1,
                           "col": xn.start(1), "word": xn.group(1), "ecol": e.start()})
        elif BASH_ERRPRINT.search(line):
            untagged.append({"file": rel, "line": n, "form": "bash-print", "tag": None})
    return tagged, untagged


def first_str(nodes):
    for a in nodes:
        if isinstance(a, ast.Constant) and isinstance(a.value, str):
            return a.value
        if isinstance(a, ast.JoinedStr) and a.values and isinstance(a.values[0], ast.Constant):
            return str(a.values[0].value)
    return None


def call_name(func):
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def py_sites(rel, text):
    """Direct sites carry the tag literal in the call. An indirect site passes the tag in a
    variable (need(ok, tag, ...)); the tags that reach it are the exact "E_<TAG>" string constants of
    the file that no direct site uses, and each of them maps to every indirect site of the file."""
    tagged, untagged, indirect = [], [], []
    tree = ast.parse(text)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docstrings.add(id(first.value))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and call_name(node.func) in CALL_HELPERS and len(node.args) >= 2:
            s = first_str(node.args[1:] + [k.value for k in node.keywords])
            t = TAG.match(s or "")
            site = {"file": rel, "line": node.lineno, "form": "py-call", "tag": t.group(0) if t else None,
                    "col": node.args[0].col_offset, "arg_line": node.args[0].lineno}
            if t:
                tagged.append(site)
            elif isinstance(node.args[1], ast.Name):
                indirect.append(dict(site, form="py-call-indirect"))
            else:
                untagged.append(site)
        elif isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call) and call_name(node.exc.func) in RAISE_NAMES:
            s = first_str(node.exc.args)
            t = TAG.match(s or "")
            site = {"file": rel, "line": node.lineno, "form": "py-raise", "tag": t.group(0) if t else None,
                    "col": node.col_offset}
            if t:
                tagged.append(site)
            elif s is not None:
                untagged.append(site)
    if indirect:
        direct = {s["tag"] for s in tagged}
        consts = sorted({n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)
                         and id(n) not in docstrings and TAG.fullmatch(n.value)} - direct)
        for tag in consts:
            tagged += [dict(s, tag=tag) for s in indirect]
    return tagged, untagged


CLUSTER_HELPER = "scripts/cilium_bottlerocket.py"


def check_tag(command):
    """The cluster helper's tag of one subcommand (scripts/lib/cb_base.py check_tag)."""
    name = command[len("check-"):] if command.startswith("check-") else command
    return "E_" + name.upper().replace("-", "_")


def subcommands(root):
    """{(module, function): subcommand} from the add("name", module.func, ...) calls of the helper."""
    path = os.path.join(root, CLUSTER_HELPER)
    if not os.path.isfile(path):
        return {}
    out = {}
    for node in ast.walk(ast.parse(open(path, encoding="utf-8").read())):
        if (isinstance(node, ast.Call) and call_name(node.func) == "add" and len(node.args) >= 2
                and isinstance(node.args[0], ast.Constant) and isinstance(node.args[1], ast.Attribute)
                and isinstance(node.args[1].value, ast.Name)):
            out[(node.args[1].value.id, node.args[1].attr)] = node.args[0].value
    return out


def cluster_py_sites(rel, text, cmds):
    """Sites of the cluster helper's modules: a require() or raise Reject inside a subcommand's
    function carries that subcommand's tag, a raise Unknown its _UNKNOWN tag. A site in a shared
    function (aws(), setting(), ...) belongs to every caller and is listed as shared."""
    mod = os.path.splitext(os.path.basename(rel))[0]
    tagged, shared = [], []
    tree = ast.parse(text)
    owner = {}
    for fn in tree.body:
        if isinstance(fn, ast.FunctionDef):
            for node in ast.walk(fn):
                owner[id(node)] = fn.name
    for node in ast.walk(tree):
        site = None
        if isinstance(node, ast.Call) and call_name(node.func) in CALL_HELPERS and node.args:
            site = {"file": rel, "line": node.lineno, "form": "py-call", "col": node.args[0].col_offset,
                    "arg_line": node.args[0].lineno, "unknown": False}
        elif isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call) and call_name(node.exc.func) in ("Reject", "Unknown"):
            site = {"file": rel, "line": node.lineno, "form": "py-raise", "col": node.col_offset,
                    "unknown": call_name(node.exc.func) == "Unknown"}
        if site is None:
            continue
        cmd = cmds.get((mod, owner.get(id(node), "")))
        if cmd is None:
            shared.append(dict(site, tag=None, function=owner.get(id(node), "<module>")))
        else:
            tagged.append(dict(site, tag=check_tag(cmd) + ("_UNKNOWN" if site["unknown"] else "")))
    return tagged, shared


def inventory(root):
    tags, untagged, shared = {}, [], []
    cmds = subcommands(root)
    cluster_mods = {m for m, _ in cmds}
    for rel, kind in files(root):
        text = open(os.path.join(root, rel), encoding="utf-8").read()
        if kind == "py" and rel.startswith("scripts/lib/") and os.path.splitext(os.path.basename(rel))[0] in cluster_mods | {"cb_base"}:
            t, sh = cluster_py_sites(rel, text, cmds)
            shared += sh
            u = []
        else:
            t, u = (bash_sites if kind == "sh" else py_sites)(rel, text)
        for s in t:
            tags.setdefault(s["tag"], []).append(s)
        untagged += u
    # Every subcommand of the cluster helper can answer E_<TAG>_UNKNOWN: main_wrapper turns an
    # Unknown from a shared reader (an unreadable or empty capture) into it. Such a tag has no
    # site of its own; it is listed with the handler as an implicit site, which a mutant cannot
    # remove for one subcommand alone.
    base = os.path.join(root, "scripts", "lib", "cb_base.py")
    if cmds and os.path.isfile(base):
        line = next((n for n, l in enumerate(open(base, encoding="utf-8"), 1) if "_UNKNOWN: could not check" in l), 0)
        for c in cmds.values():
            tags.setdefault(check_tag(c) + "_UNKNOWN", []).append(
                {"file": "scripts/lib/cb_base.py", "line": line, "form": "implicit", "tag": check_tag(c) + "_UNKNOWN"})
    return {"tags": dict(sorted(tags.items())), "untagged": untagged, "shared": shared,
            "subcommands": {check_tag(c): c for c in cmds.values()}}


def mutate(root, tag, out):
    inv = inventory(root)
    sites = [s for s in inv["tags"].get(tag, []) if s["form"] != "implicit"]
    if not sites:
        print(f"no site of tag {tag} can be mutated on its own (implicit or absent)", file=sys.stderr)
        return 3
    if os.path.exists(out):
        shutil.rmtree(out)
    shutil.copytree(root, out, symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    by_file = {}
    for s in sites:
        by_file.setdefault(s["file"], []).append(s)
    bad = 0
    for rel, ss in by_file.items():
        path = os.path.join(out, rel)
        lines = open(path, encoding="utf-8").read().split("\n")
        # Edit from the end so earlier columns stay right.
        for s in sorted(ss, key=lambda x: (x.get("arg_line", x["line"]), x.get("col", 0)), reverse=True):
            if s["form"] == "bash-die":
                i, c = s["line"] - 1, s["col"]
                word = "could_not" if lines[i][c:].startswith("could_not") else "die"
                lines[i] = lines[i][:c] + ":" + lines[i][c + len(word):]
            elif s["form"] == "bash-echo":
                # The guard removed: no exit (or return), and no refusal line either (a mutant that
                # still printed "ERROR: E_TAG:" would pass a reject case that reads only the line).
                i, c = s.get("exit_line", s["line"]) - 1, s["col"]
                lines[i] = lines[i][:c] + ":" + lines[i][c + len(s.get("word", "exit")):]
                j = s["line"] - 1
                k = lines[j].find("ERROR:", s.get("ecol", 0))
                if k >= 0:
                    lines[j] = lines[j][:k] + "MUTANT:" + lines[j][k + len("ERROR:"):]
            elif s["form"] in ("py-call", "py-call-indirect"):
                i = s["arg_line"] - 1
                b = lines[i].encode("utf-8")
                lines[i] = (b[:s["col"]] + b"True or " + b[s["col"]:]).decode("utf-8")
            elif s["form"] == "py-raise":
                i = s["line"] - 1
                b = lines[i].encode("utf-8")
                lines[i] = (b[:s["col"]] + b"if False: " + b[s["col"]:]).decode("utf-8")
            print(f"mutated {rel}:{s['line']} ({s['form']})")
        open(path, "w", encoding="utf-8").write("\n".join(lines))
        if rel.endswith(".sh"):
            r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
            ok, err = r.returncode == 0, r.stderr
        else:
            try:
                compile(open(path, encoding="utf-8").read(), path, "exec")
                ok, err = True, ""
            except SyntaxError as e:
                ok, err = False, str(e)
        if not ok:
            print(f"NOT PARSE-VALID {rel}: {err.strip()}", file=sys.stderr)
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[2] == "--mutate":
        sys.exit(mutate(sys.argv[1], sys.argv[3], sys.argv[4]))
    print(json.dumps(inventory(sys.argv[1]), indent=1))
