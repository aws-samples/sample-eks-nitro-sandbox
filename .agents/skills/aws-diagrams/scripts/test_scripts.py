#!/usr/bin/env python3
"""Tests for this skill's scripts, each check proved both ways.

    python3 .agents/skills/aws-diagrams/scripts/test_scripts.py

Every rule is exercised on a figure it must accept (the template and, when
run inside the repository, every committed figure) and on a copy broken in
exactly one way that it must reject. A check that only ever saw bad input
could be rejecting everything; one that only saw good input could be
accepting everything. Standard library only.
"""
import contextlib
import glob
import io
import os
import struct
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_drawio  # noqa: E402
import compare_png  # noqa: E402
import drawio_shapes  # noqa: E402
from measure_text import text_width  # noqa: E402

TEMPLATE = os.path.join(HERE, "..", "assets", "figure-template.drawio")
REPO_FIGURES = sorted(glob.glob(os.path.join(HERE, "..", "..", "..", "..", "examples", "**", "*.drawio"),
                            recursive=True))
NAMES = {
    "mxgraph.aws4.user", "mxgraph.aws4.group", "mxgraph.aws4.group_aws_cloud_alt",
    "mxgraph.aws4.resourceIcon", "mxgraph.aws4.eks", "mxgraph.aws4.ec2",
    "mxgraph.aws4.generic_application", "mxgraph.aws4.filtering_rule",
    "mxgraph.aws4.bedrock", "mxgraph.aws4.internet_alt1",
}


def template():
    with open(TEMPLATE, encoding="utf-8") as f:
        return f.read()


def findings(xml, names=None):
    with tempfile.NamedTemporaryFile("w", suffix=".drawio", delete=False, encoding="utf-8") as f:
        f.write(xml)
        path = f.name
    try:
        return check_drawio.Figure(path).check(names)
    finally:
        os.unlink(path)


def errors(xml, names=None):
    return {code for level, code, _, _ in findings(xml, names) if level == "ERROR"}


def broken(old, new):
    xml = template()
    assert xml.count(old) == 1, f"fixture anchor not unique: {old!r}"
    return xml.replace(old, new)


class CheckDrawio(unittest.TestCase):
    def test_template_is_clean(self):
        self.assertEqual(errors(template(), NAMES), set())

    def test_repo_figures_have_no_errors(self):
        if not REPO_FIGURES:
            self.skipTest("not inside the repository")
        for path in REPO_FIGURES:
            with self.subTest(path=os.path.basename(path)):
                found = [f for f in check_drawio.Figure(path).check(None) if f[0] == "ERROR"]
                self.assertEqual(found, [])

    def test_transparent_background(self):
        self.assertIn("background", errors(broken('background="#ffffff"', 'background="none"')))

    def test_icons_overlap(self):
        xml = broken('<mxGeometry x="1160" y="280" width="80" height="80"',
                     '<mxGeometry x="660" y="300" width="80" height="80"')
        self.assertIn("overlap", errors(xml))

    def test_frame_title_too_wide(self):
        self.assertIn("frame-title", errors(broken(
            "&gt;Amazon EKS cluster&lt;",
            "&gt;Amazon EKS cluster with a title far too long for this frame to hold&lt;")))

    def test_edge_through_icon(self):
        # the policy icon moved onto the user-to-agent line
        xml = broken('<mxGeometry x="620" y="520" width="80" height="80"',
                     '<mxGeometry x="440" y="280" width="80" height="80"')
        self.assertIn("edge-icon", errors(xml))

    def test_edge_through_label(self):
        # the refused route's vertical leg moved under the agent's label
        xml = broken('<mxPoint x="400" y="340" />\n              <mxPoint x="400" y="800" />',
                     '<mxPoint x="660" y="340" />\n              <mxPoint x="660" y="800" />')
        self.assertIn("edge-text", errors(xml))

    def test_label_over_frame_border(self):
        # the refused destination moved so its label hangs below the AWS Cloud frame
        xml = broken('<mxGeometry x="1160" y="760" width="80" height="80"',
                     '<mxGeometry x="1160" y="830" width="80" height="80"')
        self.assertIn("label-border", errors(xml))

    def test_unknown_shape(self):
        xml = broken("shape=mxgraph.aws4.filtering_rule;", "shape=mxgraph.aws4.firewall;")
        self.assertIn("unknown-shape", errors(xml, NAMES))
        self.assertNotIn("unknown-shape", errors(template(), NAMES))

    def test_implicit_bend_is_reported(self):
        xml = broken('<mxPoint x="400" y="340" />\n              <mxPoint x="400" y="800" />', "")
        codes = {code for _, code, _, _ in findings(xml)}
        self.assertIn("edge-route", codes)
        self.assertNotIn("edge-route", {code for _, code, _, _ in findings(template())})

    def test_wording(self):
        for bad in ("egress fence", "the strongest isolation", "run test.sh first",
                    "account " + "123456" + "789012",  # split so a repository scan does not flag the fixture
                    "minimum 1 vCPU", "at least 768Mi of memory",
                    "node ip-192-168-10-20", "owner@example.com", "git.corp.example.net"):
            with self.subTest(bad=bad):
                self.assertIn("wording", errors(broken("&gt;starts a task&lt;", f"&gt;{bad}&lt;")))
        for good in ("network policy", "hardware-level isolation", "Requests equal limits: 1 vCPU",
                     "api.anthropic.com", "example-org/example-app"):
            with self.subTest(good=good):
                self.assertNotIn("wording", errors(broken("&gt;starts a task&lt;", f"&gt;{good}&lt;")))

    def test_wording_split_by_inline_tags(self):
        # an inline tag inside a word renders as one word, so the rule must see one word
        for bad in ("egress fen&lt;b&gt;ce&lt;/b&gt;",
                    "account " + "1234" + "&lt;b&gt;" + "5678" + "&lt;/b&gt;" + "9012",
                    "the &lt;span&gt;strong&lt;/span&gt;est isolation"):
            with self.subTest(bad=bad):
                self.assertIn("wording", errors(broken("&gt;starts a task&lt;", f"&gt;{bad}&lt;")))
        # a line break or a block still separates two words
        for good in ("strong&lt;br&gt;est", "network&lt;br&gt;policy"):
            with self.subTest(good=good):
                self.assertNotIn("wording", errors(broken("&gt;starts a task&lt;", f"&gt;{good}&lt;")))

    def test_vm_for_the_claimed_pod(self):
        def wording(label):
            return {lvl for lvl, code, _, _ in findings(broken("&gt;starts a task&lt;", f"&gt;{label}&lt;"))
                    if code == "wording"}
        # a VM is never the thing a reader pools or claims
        for bad in ("claims a warm VM", "1. claim a VM", "a pooled microVM", "pre-booted VMs"):
            with self.subTest(bad=bad):
                self.assertIn("ERROR", wording(bad))
        # the claimed pod, and the agent-sandbox Sandbox resource, are named as the pages name them
        for good in ("claims a warm pod", "1. claim a sandbox", "3. claim a warm sandbox",
                     "runs in a lightweight VM"):
            with self.subTest(good=good):
                self.assertEqual(wording(good), set())
        # ambiguous: may describe the boundary, so it is a warning for the author to read
        self.assertEqual(wording("one kernel per VM"), {"WARN"})


class MeasureText(unittest.TestCase):
    def test_widths(self):
        # widths measured on the export container's render, within a few px
        self.assertAlmostEqual(text_width("Amazon Bedrock", 24), 182, delta=4)
        self.assertAlmostEqual(text_width("EKS Auto Mode cluster", 22, bold=True), 241, delta=4)
        self.assertGreater(text_width("Nitro sandbox", 22, bold=True), text_width("Nitro sandbox", 22))
        self.assertEqual(text_width("", 24), 0)
        self.assertGreaterEqual(text_width("\u4e2d", 24), 24)  # unknown glyphs count wide


SIDEBAR_SOURCE = """
Sidebar.prototype.addAWS4ComputePalette = function(s, w, h, w2, gn, sb)
{
    var n2 = 'sketch=0;fillColor=#ED7100;strokeColor=#ffffff;' + mxConstants.STYLE_SHAPE + "=mxgraph.aws4.";
    this.addPaletteFunctions('aws4Compute', 'AWS / Compute', false, [
        this.createVertexTemplateEntry(n2 + 'resourceIcon;resIcon=' + gn + '.ec2;',
            w2, w2, '', 'EC2', null, null, this.getTagsForStencil(gn, 'ec2', dt).join(' '))]);
};
Sidebar.prototype.addOther = function() {};
"""
SIDEBAR_MINIFIED = (
    'Sidebar.prototype.addAWS4GeneralResourcesPalette=function(a,c,e,b,d,f){c="sketch=0;fillColor=#232F3D;'
    'strokeColor=none;"+mxConstants.STYLE_SHAPE+"=mxgraph.aws4.";this.addPaletteFunctions("x","y",!1,'
    '[this.createVertexTemplateEntry(c+"user;",78*a,78*a,"","User",null,null,'
    'this.getTagsForStencil(d,"user","aws").join(" "))])};Sidebar.prototype.addZ=function(){};'
)


class DrawioShapes(unittest.TestCase):
    def _names(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(text)
        try:
            return drawio_shapes.known_names(f.name), drawio_shapes.load_entries(f.name)
        finally:
            os.unlink(f.name)

    def test_source_form(self):
        names, entries = self._names(SIDEBAR_SOURCE)
        self.assertIn("mxgraph.aws4.ec2", names)
        self.assertEqual(entries[0]["label"], "EC2")
        self.assertIn("fillColor=#ED7100", entries[0]["style"])
        self.assertNotIn("mxgraph.aws4.lambda", names)

    def test_minified_form(self):
        names, entries = self._names(SIDEBAR_MINIFIED)
        self.assertIn("mxgraph.aws4.user", names)
        self.assertEqual(entries[0]["style"], "sketch=0;fillColor=#232F3D;strokeColor=none;shape=mxgraph.aws4.user;")


def _png(w, h, ctype, pixels):
    bpp = 3 if ctype == 2 else 4
    raw = b"".join(b"\x00" + bytes(pixels[y * w * bpp:(y + 1) * w * bpp]) for y in range(h))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class ComparePng(unittest.TestCase):
    def _cmp(self, a, b):
        paths = []
        for data in (a, b):
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
                f.write(data)
                paths.append(f.name)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                return compare_png.main(paths)
        finally:
            for p in paths:
                os.unlink(p)

    def test_transparent_equals_white(self):
        rgba = _png(2, 1, 6, [0, 0, 0, 0, 200, 0, 0, 255])
        rgb = _png(2, 1, 2, [255, 255, 255, 200, 0, 0])
        self.assertEqual(self._cmp(rgba, rgb), 0)

    def test_colour_change_with_same_alpha_is_caught(self):
        # same alpha everywhere: an alpha-only comparison would call these equal
        a = _png(2, 1, 6, [200, 0, 0, 255, 0, 0, 0, 0])
        b = _png(2, 1, 6, [0, 0, 200, 255, 0, 0, 0, 0])
        self.assertEqual(self._cmp(a, b), 1)

    def test_size_difference(self):
        self.assertEqual(self._cmp(_png(1, 1, 2, [1, 2, 3]), _png(2, 1, 2, [1, 2, 3, 1, 2, 3])), 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
