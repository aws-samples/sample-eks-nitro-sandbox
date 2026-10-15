#!/usr/bin/env python3
"""Check a .drawio figure against this repository's house style and layout rules.

It reads the XML only (no draw.io needed) and reports what a reader would see
as broken: overlapping icons and labels, a label running over a frame border,
a frame title wider than its frame, an edge drawn through an icon or a label,
an edge whose route draw.io would have to guess, off-palette colours, a
transparent background, and words a figure must not carry.

Usage:
    check_drawio.py FIGURE.drawio [FIGURE.drawio ...] [--library APP_ASAR]

Exit code: 0 no errors (warnings may print), 1 at least one error,
2 a file could not be read. With --library (or a draw.io install found
automatically) it also refuses AWS shape names the library does not have.

Geometry is estimated from the XML: text widths come from measure_text.py,
edge labels sit at the middle of their route plus the offset. It cannot see
everything; export the PNG and look at it as well.
Standard library only.
"""
import argparse
import html
import os
import re
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

sys.dont_write_bytecode = True  # leave no __pycache__ in the skill folder
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from measure_text import text_width  # noqa: E402

FONT = "Arial,Helvetica,sans-serif"
PALETTE = {
    "#232F3E", "#232F3D", "#ED7100", "#DD344C", "#545B64", "#5F6B7A", "#414D5C",
    "#7D8998", "#5A6B86", "#01A88D", "#1D8102", "#FFFFFF", "NONE",
}
# Category fills a resource icon may bring from draw.io's library.
ICON_FILLS = {"#C925D1", "#7AA116", "#8C4FFF", "#E7157B", "#01A88D", "#ED7100", "#DD344C"}

WORD_RULES = [
    (r"\bfence[sd]?\b", "say 'network policy', not 'fence'"),
    (r"\bstrongest\b|\bsafest\b|\bmost\s+(secure|isolated)\b",
     "say 'hardware-level isolation', not a superlative"),
    (r"\b(test|setup|clean)\.sh\b|\bassert\w*\b|\bpytest\b|\b(smoke|unit)[- ]tests?\b|\bchecks? passed\b",
     "no tooling or testing words on a figure"),
    (r"(?<!\d)\d{12}(?!\d)", "looks like an AWS account ID"),
    (r"\barn:aws[\w-]*:", "no ARNs on a figure"),
    (r"\b(i|sg|subnet|vpc|eni|vol)-[0-9a-f]{8,17}\b", "looks like a real resource ID"),
    (r"\bip-\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3}\b", "looks like a real node name"),
    (r"[\w.+-]+@[\w-]+\.[\w.]+|\b[\w-]+\.(corp|internal)\.[\w.-]+|\b[\w-]+\.(internal|local)\b",
     "looks like an email address or an internal hostname"),
    # A "min" right after a number is minutes ("idle after 5 min"), not "minimum": the bare
    # "min" may not follow a number, and no number may sit between a quantity and its "min".
    (r"(\b(minimum|at least|no less than)\b|(?<!\d)(?<!\d\s)\bmin\b\.?)[^.]{0,40}\b(v?cpus?|memory|mib|gib|mi|gi)\b"
     r"|\b\d+(\.\d+)?\s*(v?cpus?|m|mi|gi|mib|gib)\b[^.\d]{0,20}\bmin(imum)?\b",
     "never state a minimum CPU or memory request on a figure"),
    (r"\b(warm|claimed|pooled|pre-booted)\s+(micro)?vms?\b"
     r"|\bclaim(s|ed|ing)?\s+(a|an|the|one|each)?\s*(warm\s+)?(micro)?vms?\b",
     "call what a reader pools or claims a 'pod' (or a 'sandbox', the agent-sandbox resource), never a 'VM'"),
]
WORD_WARNINGS = [
    (r"(?<!-)\bbooted\s+(micro)?vms?\b|\b(micro)?vms?\s+per\b|\bper\s+(micro)?vm\b",
     "call the thing that is pooled, claimed or deleted a 'pod'; 'VM' only for the isolation boundary"),
]


def parse_style(s):
    d = {}
    for part in (s or "").split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            d[k.strip()] = v.strip()
        elif part.strip():
            d[part.strip()] = ""
    return d


class _Lines(HTMLParser):
    """Split a cell value into rendered lines with their font size and weight."""

    def __init__(self, size, bold, line_height):
        super().__init__(convert_charrefs=True)
        self.base = (size, bold, line_height)
        self.stack = [self.base]
        self.lines = []
        self.cur = None

    def _open_line(self):
        if self.cur is None:
            size, bold, lh = self.stack[-1]
            self.cur = {"text": "", "size": size, "bold": bold, "lh": lh}

    def _close_line(self):
        if self.cur is not None:
            self.lines.append(self.cur)
            self.cur = None

    def handle_starttag(self, tag, attrs):
        size, bold, lh = self.stack[-1]
        st = dict(attrs).get("style", "") or ""
        m = re.search(r"font-size:\s*([\d.]+)px", st)
        if m:
            size = float(m.group(1))
            lh = size * 1.2
        m = re.search(r"line-height:\s*([\d.]+)px", st)
        if m:
            lh = float(m.group(1))
        if re.search(r"font-weight:\s*(bold|[6-9]00)", st) or tag in ("b", "strong"):
            bold = True
        if re.search(r"font-weight:\s*normal", st):
            bold = False
        if tag == "br":
            self._close_line()
            return
        if tag in ("div", "p"):
            self._close_line()
        self.stack.append((size, bold, lh))
        if self.cur is not None and tag not in ("div", "p"):
            # a span that changes size or weight mid-line sets the line's look
            self.cur["size"] = max(self.cur["size"], size)
            self.cur["bold"] = self.cur["bold"] or bold
        if tag in ("div", "p"):
            self._open_line()
            self.cur.update(size=size, bold=bold, lh=lh)

    def handle_endtag(self, tag):
        if tag == "br":
            return
        if len(self.stack) > 1:
            self.stack.pop()
        if tag in ("div", "p"):
            self._close_line()

    def handle_data(self, data):
        if not data.strip() and self.cur is None:
            return
        self._open_line()
        self.cur["text"] += data

    def result(self):
        self._close_line()
        return [ln for ln in self.lines if ln["text"].strip()]


def text_lines(value, st, html_mode):
    size = float(st.get("fontSize", 12))
    bold = bool(int(st.get("fontStyle", 0) or 0) & 1)
    if not value:
        return []
    if html_mode:
        p = _Lines(size, bold, size * 1.2)
        p.feed(value)
        return p.result()
    return [{"text": t, "size": size, "bold": bold, "lh": size * 1.2} for t in value.split("\n") if t.strip()]


def block_size(lines):
    w = max((text_width(ln["text"].strip(), ln["size"], ln["bold"]) for ln in lines), default=0)
    h = sum(ln["lh"] for ln in lines)
    return w, h


class Box:
    def __init__(self, x, y, w, h, kind, cid, text=""):
        self.x, self.y, self.w, self.h, self.kind, self.cid, self.text = x, y, w, h, kind, cid, text

    @property
    def r(self):
        return self.x + self.w

    @property
    def b(self):
        return self.y + self.h

    def intersects(self, o, pad=0.0):
        return (self.x + pad < o.r - pad and o.x + pad < self.r - pad
                and self.y + pad < o.b - pad and o.y + pad < self.b - pad)

    def contains(self, o, slack=1.0):
        return (o.x >= self.x - slack and o.y >= self.y - slack
                and o.r <= self.r + slack and o.b <= self.b + slack)

    def __repr__(self):
        return f"{self.kind}:{self.cid}({self.x:.0f},{self.y:.0f},{self.w:.0f}x{self.h:.0f})"


def seg_hits_box(p, q, box, pad=2.0):
    """True when the axis-aligned segment p-q passes through the box interior."""
    (x1, y1), (x2, y2) = p, q
    left, right, top, bottom = box.x + pad, box.r - pad, box.y + pad, box.b - pad
    if left >= right or top >= bottom:
        return False
    if abs(y1 - y2) < 0.5:
        return top < y1 < bottom and min(x1, x2) < right and max(x1, x2) > left
    if abs(x1 - x2) < 0.5:
        return left < x1 < right and min(y1, y2) < bottom and max(y1, y2) > top
    return False


def crosses_border(inner, frame):
    """True when inner straddles the frame's outline (partly in, partly out)."""
    return inner.intersects(frame, pad=0.5) and not frame.contains(inner, slack=0.5)


class Figure:
    def __init__(self, path):
        self.path = path
        root = ET.parse(path).getroot()
        if root.find(".//diagram") is not None and root.find(".//mxGraphModel") is None:
            raise ValueError("compressed diagram: save it uncompressed (File > Properties > Compressed off)")
        self.model = root.find(".//mxGraphModel")
        self.cells = {c.get("id"): c for c in root.iter("mxCell")}
        self.findings = []

    def add(self, level, code, cells, msg):
        self.findings.append((level, code, cells, msg))

    def origin(self, cid):
        """Absolute top-left of a cell's coordinate space (sum of vertex parents)."""
        x = y = 0.0
        seen = set()
        while cid in self.cells and cid not in seen:
            seen.add(cid)
            c = self.cells[cid]
            g = c.find("mxGeometry")
            if c.get("vertex") == "1" and g is not None and g.get("relative") != "1":
                x += float(g.get("x", 0))
                y += float(g.get("y", 0))
            cid = c.get("parent")
        return x, y

    def run(self, library_names=None):
        bg = (self.model.get("background") or "").upper()
        if bg not in ("#FFFFFF", "WHITE"):
            self.add("ERROR", "background", [], 'set background="#ffffff" on mxGraphModel; '
                     "otherwise the PNG is transparent and turns dark on a dark page")
        icons, labels, frames, titles, texts, edges = [], [], [], [], [], []
        vbox = {}
        for cid, c in self.cells.items():
            st = parse_style(c.get("style"))
            value = c.get("value") or ""
            html_mode = st.get("html") == "1"
            self._colours(cid, st, value)
            self._words(cid, value, html_mode)
            if c.get("vertex") == "1":
                g = c.find("mxGeometry")
                if g is None:
                    continue
                ox, oy = self.origin(c.get("parent"))
                x, y = ox + float(g.get("x", 0)), oy + float(g.get("y", 0))
                w, h = float(g.get("width", 0)), float(g.get("height", 0))
                shape = st.get("shape", "")
                lines = text_lines(value, st, html_mode)
                if lines and "fontFamily" in st and st["fontFamily"] != FONT:
                    self.add("WARN", "font", [cid], f"fontFamily {st['fontFamily']!r}; the house font is {FONT}")
                elif lines and "fontFamily" not in st:
                    self.add("WARN", "font", [cid], f"no fontFamily; set fontFamily={FONT}")
                if "text" in st and not shape:
                    tb = self._text_box(x, y, w, h, st, lines, cid)
                    if tb:
                        texts.append(tb)
                    continue
                is_tab = shape == "mxgraph.aws4.resourceIcon" and (w, h) == (48, 48) and not lines
                if is_tab:
                    continue
                if shape.startswith("mxgraph.aws4.") and shape != "mxgraph.aws4.group":
                    box = Box(x, y, w, h, "icon", cid)
                    icons.append(box)
                    vbox[cid] = box
                    if (w, h) != (80, 80):
                        self.add("WARN", "icon-size", [cid], f"icon is {w:.0f}x{h:.0f}; house icons are 80x80")
                    lb = self._icon_label(box, st, lines)
                    if lb:
                        labels.append(lb)
                else:
                    box = Box(x, y, w, h, "frame", cid)
                    frames.append(box)
                    vbox[cid] = box
                    tb = self._frame_title(box, st, lines)
                    if tb:
                        titles.append(tb)
                for kname in ("shape", "resIcon", "grIcon"):
                    nm = st.get(kname, "")
                    if library_names is not None and nm.startswith("mxgraph.aws4.") and nm not in library_names:
                        self.add("ERROR", "unknown-shape", [cid], f"{nm} is not in draw.io's AWS library: it renders blank")
            elif c.get("edge") == "1":
                edges.append((cid, c, st, value, html_mode))

        self._layout(icons, labels, frames, titles, texts)
        for e in edges:
            self._edge(e, vbox, icons, labels, titles, texts, frames)

    # -- text boxes -------------------------------------------------------
    def _icon_label(self, icon, st, lines):
        if not lines:
            return None
        w, h = block_size(lines)
        pos = st.get("labelPosition", "center")
        vpos = st.get("verticalLabelPosition", "middle")
        sp = float(st.get("spacing", 2))
        if pos == "left":
            x = icon.x - float(st.get("spacingRight", 0)) - sp - w
        elif pos == "right":
            x = icon.r + float(st.get("spacingLeft", 0)) + sp
        else:
            x = icon.x + icon.w / 2 - w / 2
        if vpos == "bottom":
            y = icon.b + sp + float(st.get("spacingTop", 0))
        elif vpos == "top":
            y = icon.y - sp - h
        else:
            y = icon.y + icon.h / 2 - h / 2
        return Box(x, y, w, h, "label", icon.cid, " / ".join(ln["text"].strip() for ln in lines))

    def _frame_title(self, frame, st, lines):
        if not lines:
            return None
        w, h = block_size(lines)
        left = float(st.get("spacingLeft", 0)) + float(st.get("spacing", 2))
        top = max(0.0, float(st.get("spacingTop", 0)) + float(st.get("spacing", 2)))
        box = Box(frame.x + left, frame.y + top, w, h, "title", frame.cid, lines[0]["text"].strip())
        if st.get("whiteSpace") != "wrap" and box.r > frame.r - 8:
            self.add("ERROR", "frame-title", [frame.cid],
                     f"title/sub line is {w:.0f}px wide but only {frame.w - left - 8:.0f}px fit; "
                     "widen the frame or move words to a sub line")
        return box

    def _text_box(self, x, y, w, h, st, lines, cid):
        if not lines:
            return None
        tw, th = block_size(lines)
        if st.get("whiteSpace") == "wrap":
            return Box(x, y, w, h, "text", cid)
        align = st.get("align", "center")
        bx = x if align == "left" else (x + w - tw if align == "right" else x + w / 2 - tw / 2)
        return Box(bx, y, tw, max(th, 1), "text", cid)

    # -- checks -------------------------------------------------------------
    def _colours(self, cid, st, value):
        for k in ("strokeColor", "fillColor", "fontColor", "labelBackgroundColor"):
            v = st.get(k, "").upper()
            if v and v not in PALETTE and not (k == "fillColor" and v in ICON_FILLS):
                self.add("WARN", "palette", [cid], f"{k}={v} is outside the house palette")
        for v in re.findall(r"color:\s*(#[0-9A-Fa-f]{6})", value):
            if v.upper() not in PALETTE:
                self.add("WARN", "palette", [cid], f"inline color {v} is outside the house palette")

    def _words(self, cid, value, html_mode):
        text = value
        if html_mode:
            # A line break or a block starts a new word; an inline tag (b, i, span,
            # font) renders inside one, so "fen<b>ce</b>" must read as "fence".
            text = re.sub(r"<\s*/?\s*(br|div|p|pre|blockquote|li|tr|td|th|hr|h[1-6])\b[^>]*>", " ",
                          text, flags=re.I)
            text = html.unescape(re.sub(r"<[^>]+>", "", text))
        for pat, msg in WORD_RULES:
            if re.search(pat, text, re.I):
                self.add("ERROR", "wording", [cid], f"{msg}: {text.strip()[:60]!r}")
        for pat, msg in WORD_WARNINGS:
            if re.search(pat, text, re.I):
                self.add("WARN", "wording", [cid], f"{msg}: {text.strip()[:60]!r}")

    def _layout(self, icons, labels, frames, titles, texts):
        for i, a in enumerate(icons):
            for b in icons[i + 1:]:
                if a.intersects(b):
                    self.add("ERROR", "overlap", [a.cid, b.cid], "icons overlap")
        texty = labels + titles + texts
        for t in texty:
            for ic in icons:
                if t.cid != ic.cid and t.intersects(ic, pad=1):
                    self.add("ERROR", "overlap", [t.cid, ic.cid], f"text {t.text[:30]!r} runs into an icon")
        for i, a in enumerate(texty):
            for b in texty[i + 1:]:
                if a.cid != b.cid and a.intersects(b, pad=1):
                    self.add("ERROR", "overlap", [a.cid, b.cid], f"texts {a.text[:24]!r} and {b.text[:24]!r} overlap")
        for t in labels + texts:
            for f in frames:
                if crosses_border(t, f):
                    self.add("ERROR", "label-border", [t.cid, f.cid],
                             f"text {t.text[:30]!r} runs over the border of frame {f.cid}")
        for ic in icons:
            for f in frames:
                if crosses_border(ic, f):
                    self.add("WARN", "icon-border", [ic.cid, f.cid],
                             "icon straddles a frame border; fine only for a boundary gateway")
        for i, a in enumerate(frames):
            for b in frames[i + 1:]:
                if a.intersects(b) and not a.contains(b) and not b.contains(a):
                    self.add("ERROR", "frames-cross", [a.cid, b.cid], "frames partly overlap; nest one inside the other")

    def _terminal(self, box, st, prefix, toward):
        """Where an edge leaves (prefix='exit') or enters ('entry') a box."""
        fx, fy = st.get(prefix + "X"), st.get(prefix + "Y")
        dx, dy = float(st.get(prefix + "Dx", 0)), float(st.get(prefix + "Dy", 0))
        if fx is not None and fy is not None:
            return (box.x + float(fx) * box.w + dx, box.y + float(fy) * box.h + dy), True
        tx, ty = toward
        # unanchored: draw.io picks a side; take the side facing the next point,
        # level with it when it lies within the box's span
        if box.x <= tx <= box.r:
            return (tx, box.y if ty < box.y else box.b), False
        if box.y <= ty <= box.b:
            return (box.x if tx < box.x else box.r, ty), False
        cx, cy = box.x + box.w / 2, box.y + box.h / 2
        if abs(tx - cx) >= abs(ty - cy):
            return (box.r if tx > cx else box.x, cy), False
        return (cx, box.b if ty > cy else box.y), False

    def _edge(self, e, vbox, icons, labels, titles, texts, frames):
        cid, c, st, value, html_mode = e
        g = c.find("mxGeometry")
        ox, oy = self.origin(c.get("parent"))
        pts, src_pt, dst_pt = [], None, None
        if g is not None:
            arr = g.find("Array")
            if arr is not None:
                pts = [(ox + float(p.get("x", 0)), oy + float(p.get("y", 0))) for p in arr.findall("mxPoint")]
            for p in g.findall("mxPoint"):
                if p.get("as") == "sourcePoint":
                    src_pt = (ox + float(p.get("x", 0)), oy + float(p.get("y", 0)))
                elif p.get("as") == "targetPoint":
                    dst_pt = (ox + float(p.get("x", 0)), oy + float(p.get("y", 0)))
        s, t = vbox.get(c.get("source")), vbox.get(c.get("target"))
        if (c.get("source") and not s) or (c.get("target") and not t):
            self.add("WARN", "edge-end", [cid], "edge source/target is not an icon or frame on this page")
        far_t = (t.x + t.w / 2, t.y + t.h / 2) if t else dst_pt
        far_s = (s.x + s.w / 2, s.y + s.h / 2) if s else src_pt
        if s:
            start, anchored_s = self._terminal(s, st, "exit", pts[0] if pts else (far_t or (s.r, s.y)))
        else:
            start, anchored_s = src_pt, True
        if t:
            end, anchored_t = self._terminal(t, st, "entry", pts[-1] if pts else (start or far_s))
        else:
            end, anchored_t = dst_pt, True
        if start is None or end is None:
            self.add("WARN", "edge-end", [cid], "edge has no source/target and no source/targetPoint")
            return
        if not (anchored_s and anchored_t):
            self.add("INFO", "edge-anchor", [cid], "an end has no exitX/exitY or entryX/entryY; route estimated")
        route = [start] + pts + [end]
        self._routes.append((cid, route))
        for p, q in zip(route, route[1:]):
            if abs(p[0] - q[0]) > 0.5 and abs(p[1] - q[1]) > 0.5:
                self.add("WARN", "edge-route", [cid],
                         f"({p[0]:.0f},{p[1]:.0f})->({q[0]:.0f},{q[1]:.0f}) is not straight: draw.io adds its own "
                         "bend here; add a waypoint so the route is the one you mean")
        own = {c.get("source"), c.get("target")}
        for p, q in zip(route, route[1:]):
            for ic in icons:
                if ic.cid not in own and seg_hits_box(p, q, ic):
                    self.add("ERROR", "edge-icon", [cid, ic.cid], "edge runs through an icon")
            for lb in labels + titles + texts:
                if seg_hits_box(p, q, lb, pad=1):
                    self.add("ERROR", "edge-text", [cid, lb.cid], f"edge runs through text {lb.text[:30]!r}")
        lines = text_lines(value, st, html_mode)
        if not lines:
            return
        lb = self._edge_label(route, g, st, lines, cid)
        for ic in icons:
            if lb.intersects(ic, pad=1):
                self.add("ERROR", "edge-label", [cid, ic.cid], f"edge label {lb.text!r} runs into an icon")
        for other in labels + titles + texts:
            if lb.intersects(other, pad=1):
                self.add("ERROR", "edge-label", [cid, other.cid], f"edge label {lb.text!r} overlaps text {other.text[:24]!r}")
        for f in frames:
            if crosses_border(lb, f):
                self.add("WARN", "edge-label", [cid, f.cid], f"edge label {lb.text!r} runs over the border of {f.cid}")
        self._edge_labels.append((lb, cid))

    def _edge_label(self, route, g, st, lines, cid):
        lengths = [abs(q[0] - p[0]) + abs(q[1] - p[1]) for p, q in zip(route, route[1:])]
        total = sum(lengths)
        rel = float(g.get("x", 0)) if g is not None else 0.0
        target = total * (rel + 1) / 2
        x, y = route[0]
        for (p, q), ln in zip(zip(route, route[1:]), lengths):
            if target <= ln and ln > 0:
                f = target / ln
                x, y = p[0] + (q[0] - p[0]) * f, p[1] + (q[1] - p[1]) * f
                break
            target -= ln
            x, y = q
        off = g.find("mxPoint[@as='offset']") if g is not None else None
        if off is not None:
            x += float(off.get("x", 0))
            y += float(off.get("y", 0))
        w, h = block_size(lines)
        align, valign = st.get("align", "center"), st.get("verticalAlign", "middle")
        bx = x if align == "left" else (x - w if align == "right" else x - w / 2)
        # Measured on the export container: an edge label's text box starts
        # about 5px below the anchor when top-aligned, ends about 1px above it
        # when bottom-aligned, and sits about 1px low when centred.
        by = y + 5 if valign == "top" else (y - h - 1 if valign == "bottom" else y - h / 2 + 1)
        return Box(bx, by, w, h, "edge-label", cid, " / ".join(ln["text"].strip() for ln in lines))

    def check(self, library_names=None):
        self._edge_labels = []
        self._routes = []
        self.run(library_names)
        for lb, cid in self._edge_labels:
            for ecid, route in self._routes:
                # any edge, its own included (a bend drawn inside its own label);
                # pad 3 because the box carries a little space above the glyphs
                if any(seg_hits_box(p, q, lb, pad=3) for p, q in zip(route, route[1:])):
                    whose = "its own label" if ecid == cid else "edge label"
                    self.add("ERROR", "edge-text", sorted({ecid, cid}), f"edge runs through {whose} {lb.text!r}")
        for i, (a, ca) in enumerate(self._edge_labels):
            for b, cb in self._edge_labels[i + 1:]:
                if a.intersects(b, pad=1):
                    self.add("ERROR", "edge-label", [ca, cb], f"edge labels {a.text!r} and {b.text!r} overlap")
        return self.findings

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("figures", nargs="+")
    p.add_argument("--library", help="draw.io app.asar or Sidebar-AWS4.js, to verify AWS shape names")
    p.add_argument("--quiet", action="store_true", help="print errors only")
    a = p.parse_args(argv)
    names = None
    try:
        import drawio_shapes
        lib = drawio_shapes.find_library(a.library)
        if lib:
            names = drawio_shapes.known_names(lib)
    except Exception as exc:  # the shape check is optional
        print(f"note: shape names not verified ({exc})", file=sys.stderr)
    if names is None:
        print("note: draw.io library not found, AWS shape names NOT verified; run "
              "'drawio_shapes.py fetch' or install draw.io desktop", file=sys.stderr)
    worst = 0
    for path in a.figures:
        try:
            fig = Figure(path)
            findings = fig.check(names)
        except (ET.ParseError, ValueError, OSError) as exc:
            print(f"{path}: cannot read: {exc}")
            worst = 2
            continue
        seen = set()
        errors = 0
        for level, code, cells, msg in findings:
            key = (level, code, tuple(sorted(cells)), msg)
            if key in seen or (a.quiet and level != "ERROR"):
                continue
            seen.add(key)
            errors += level == "ERROR"
            print(f"{path}: {level:5} {code:13} {','.join(cells) or '-'}: {msg}")
        print(f"{path}: {errors} error(s)")
        if errors and worst < 1:
            worst = 1
    return worst


if __name__ == "__main__":
    sys.exit(main())
