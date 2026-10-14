#!/usr/bin/env python3
"""Estimate how wide a line of text renders in a draw.io figure.

The figures use fontFamily "Arial,Helvetica,sans-serif". draw.io's exporter
renders that with Arial or a metric-compatible substitute (Liberation Sans in
the export container), so each character has a fixed advance width. This
script sums those widths. Kerning can only make real text a little narrower,
so the estimate errs on the wide side, which is the safe side for sizing.

Usage:
    measure_text.py [--size PX] [--bold] TEXT [TEXT ...]
    measure_text.py --size 24 "Amazon Bedrock" "Claude model"
    measure_text.py --size 22 --bold "Nitro sandbox"

Prints one line per TEXT: the width in px, then the text.
Standard library only.
"""
import argparse
import sys

# Advance widths in 1/1000 em for printable ASCII (32..126), then a few
# punctuation marks. Italic uses the regular widths; bold-italic uses bold.
_CHARS = (
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`"
    "abcdefghijklmnopqrstuvwxyz{|}~"
    "\u2018\u2019\u201c\u201d\u2013\u2014\u2026\u2022\u2192\u00d7\u00b7\u00e9"
)
_REGULAR = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
    222, 222, 333, 333, 556, 1000, 1000, 350, 1000, 584, 333, 556,
]
_BOLD = [
    278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
    975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
    278, 278, 500, 500, 556, 1000, 1000, 350, 1000, 584, 333, 556,
]
_TABLE = {
    False: dict(zip(_CHARS, _REGULAR)),
    True: dict(zip(_CHARS, _BOLD)),
}
# A character outside the table counts as a wide one, so an unknown glyph
# never makes a box too small.
_UNKNOWN = 1000


def text_width(text, size, bold=False):
    """Width in px of one line of `text` at font `size` px."""
    table = _TABLE[bool(bold)]
    return sum(table.get(ch, _UNKNOWN) for ch in text) * size / 1000.0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--size", type=float, default=24, help="font size in px (default 24)")
    p.add_argument("--bold", action="store_true")
    p.add_argument("--italic", action="store_true", help="accepted; italic has the regular widths")
    p.add_argument("text", nargs="+")
    a = p.parse_args(argv)
    for t in a.text:
        print(f"{text_width(t, a.size, a.bold):7.1f}  {t}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
