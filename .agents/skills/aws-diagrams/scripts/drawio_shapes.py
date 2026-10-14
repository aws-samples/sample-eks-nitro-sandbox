#!/usr/bin/env python3
"""Look up AWS icon shapes in draw.io's own AWS library.

A misspelled mxgraph.aws4 name renders as a blank or plain box, and nothing in
the XML tells you. So never guess a name: search the library that ships with
draw.io and copy the style it returns.

The library is read from one of:
  * a copy fetched from the export image: run `drawio_shapes.py fetch` once
    (needs docker or podman; it lands in ~/.cache/drawio-aws-library/);
  * a draw.io desktop install (its resources/app.asar), found automatically
    in the usual places, or named with --library;
  * draw.io's public sidebar source, Sidebar-AWS4.js, downloaded from
    https://github.com/jgraph/drawio (src/main/webapp/js/diagramly/sidebar/).

Usage:
    drawio_shapes.py fetch
    drawio_shapes.py search "bedrock" "network policy" "user"
    drawio_shapes.py search --style "eks"       # also print each full style
    drawio_shapes.py check mxgraph.aws4.bedrock mxgraph.aws4.user
    drawio_shapes.py --library /path/to/app.asar search lambda

Standard library only.
"""
import argparse
import os
import re
import sys

CANDIDATES = [
    "/opt/drawio/resources/app.asar",
    "/usr/lib/drawio/resources/app.asar",
    "/snap/drawio/current/opt/drawio/resources/app.asar",
    "/Applications/draw.io.app/Contents/Resources/app.asar",
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\draw.io\resources\app.asar"),
    r"C:\Program Files\draw.io\resources\app.asar",
]
# Where `fetch` puts the library it copies out of the export image.
CACHED = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
                      "drawio-aws-library", "app.asar")

_STR = r"""(?:'[^'\n]*'|"[^"\n]*")"""
_TERM = r"(?:%s|[A-Za-z_$][\w$.]*)" % _STR
_EXPR = r"(%s(?:\s*\+\s*%s)*)" % (_TERM, _TERM)
_ASSIGN = re.compile(r"(?<![\w$.])([A-Za-z_$][\w$]*)\s*=\s*" + _EXPR)
_ENTRY = re.compile(
    r"createVertexTemplateEntry\(\s*" + _EXPR
    + r"\s*,\s*[^,]+?\s*,\s*[^,]+?\s*,\s*(" + _STR + r")\s*,\s*(" + _STR + r"|null)"
    + r"(?:\s*,\s*[^,]+?\s*,\s*[^,]+?\s*,\s*this\.getTagsForStencil\(\s*[^,]+?\s*,\s*(" + _STR + r"))?",
    re.S,
)
_TERMS = re.compile(_TERM)
_PALETTE = re.compile(r"Sidebar\.prototype\.addAWS4(\w*?)Palette\s*=\s*function")


def _unquote(s):
    return s[1:-1] if s and s[0] in "'\"" else s


def _evaluate(expr, env):
    terms = _TERMS.findall(expr)
    out = []
    for i, t in enumerate(terms):
        if t[0] in "'\"":
            out.append(t[1:-1])
        elif t == "mxConstants.STYLE_SHAPE":
            out.append("shape")
        elif t in env:
            out.append(env[t])
        else:
            # A palette parameter such as the stencil prefix: when the next
            # literal starts with '.', it stands for the aws4 namespace.
            nxt = terms[i + 1] if i + 1 < len(terms) else ""
            out.append("mxgraph.aws4" if nxt[1:2] == "." else "")
    return "".join(out)


def find_library(explicit=None):
    for p in [explicit, os.environ.get("DRAWIO_LIBRARY"), CACHED] + CANDIDATES:
        if p and os.path.isfile(p):
            return p
    return None


def fetch_library():
    """Copy draw.io's app.asar out of the pinned export image into the user cache."""
    import shutil
    import subprocess

    from export_png import IMAGE

    runtime = shutil.which("docker") or shutil.which("podman")
    if not runtime:
        raise SystemExit("fetch needs docker or podman; or install draw.io desktop, or pass --library")
    os.makedirs(os.path.dirname(CACHED), exist_ok=True)
    cid = subprocess.run([runtime, "create", IMAGE], check=True, capture_output=True, text=True).stdout.strip()
    try:
        subprocess.run([runtime, "cp", f"{cid}:/opt/drawio/resources/app.asar", CACHED], check=True)
    finally:
        subprocess.run([runtime, "rm", cid], check=False, capture_output=True)
    return CACHED


def load_entries(path):
    """Return a list of dicts: name, label, palette, style, tags."""
    with open(path, "rb") as f:
        text = f.read().decode("latin-1")
    starts = [m for m in _PALETTE.finditer(text)]
    entries = []
    for m in starts:
        end = text.find("Sidebar.prototype.", m.end())
        block = text[m.start(): end if end > 0 else len(text)]
        palette = m.group(1) or "AWS"
        # Every assignment in the block, in order, so an entry uses the value
        # its variable held at that point.
        assigns = [(a.start(), a.group(1), a.group(2)) for a in _ASSIGN.finditer(block)
                   if re.search(_STR, a.group(2))]
        for e in _ENTRY.finditer(block):
            env = {}
            for pos, name, expr in assigns:
                if pos > e.start():
                    break
                env[name] = _evaluate(expr, env)
            style = _evaluate(e.group(1), env)
            label = _unquote(e.group(2)) or _unquote(e.group(3) or "")
            tags = _unquote(e.group(4) or "")
            kv = dict(p.split("=", 1) for p in style.split(";") if "=" in p)
            name = kv.get("resIcon") or kv.get("grIcon") or kv.get("shape", "")
            if not name.startswith("mxgraph.aws4."):
                continue
            entries.append({"name": name, "label": label, "palette": palette,
                            "style": style, "tags": tags})
    return entries


def known_names(path):
    names = set()
    for e in load_entries(path):
        kv = dict(p.split("=", 1) for p in e["style"].split(";") if "=" in p)
        for k in ("shape", "resIcon", "grIcon"):
            if kv.get(k, "").startswith("mxgraph.aws4."):
                names.add(kv[k])
    return names


def _score(entry, words):
    label = entry["label"].lower()
    short = entry["name"].split(".")[-1].lower()
    hay = " ".join([label, short.replace("_", " "), entry["tags"].lower()])
    score = 0
    for w in words:
        if w == label or w == short:
            score += 10
        if re.search(r"\b%s\b" % re.escape(w), label):
            score += 4
        if re.search(r"\b%s\b" % re.escape(w), short.replace("_", " ")):
            score += 3
        if w in hay:
            score += 1
        else:
            return 0
    if entry["palette"] == "Retired":
        score -= 2
    return score


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--library", help="draw.io app.asar or Sidebar-AWS4.js")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search", help="search labels, names and tags; one result list per query")
    s.add_argument("--style", action="store_true", help="print the full style of each match")
    s.add_argument("--limit", type=int, default=5)
    s.add_argument("query", nargs="+")
    c = sub.add_parser("check", help="exit 1 unless every name is in the library")
    c.add_argument("name", nargs="+")
    sub.add_parser("fetch", help=f"copy the library out of the export image into {CACHED}")
    a = p.parse_args(argv)

    if a.cmd == "fetch":
        print(f"library copied to {fetch_library()}")
        return 0
    lib = find_library(a.library)
    if not lib:
        print("draw.io library not found: run 'drawio_shapes.py fetch' (needs docker or podman), "
              "install draw.io desktop, or pass --library", file=sys.stderr)
        return 2
    entries = load_entries(lib)
    if not entries:
        print(f"no AWS entries parsed from {lib}", file=sys.stderr)
        return 2

    if a.cmd == "check":
        names = known_names(lib)
        missing = [n for n in a.name if n not in names]
        for n in a.name:
            print(("ok       " if n in names else "MISSING  ") + n)
        return 1 if missing else 0

    for q in a.query:
        words = q.lower().split()
        ranked = sorted((e for e in entries if _score(e, words) > 0),
                        key=lambda e: (-_score(e, words), e["label"]))
        seen, shown = set(), 0
        print(f"== {q}")
        for e in ranked:
            if e["name"] in seen:
                continue
            seen.add(e["name"])
            print(f"  {e['name']:48} {e['label']}  [{e['palette']}]")
            if a.style:
                print(f"      {e['style']}")
            shown += 1
            if shown >= a.limit:
                break
        if not shown:
            print("  (no match: try the service's current name or what it does)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
