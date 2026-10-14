#!/usr/bin/env python3
"""Export a .drawio figure to PNG with this repository's settings.

    export_png.py FIGURE.drawio [--out FIGURE.png] [--border 20] [--engine auto]

Settings: PNG, scale 2, the given border (20 for a new figure; an existing
figure keeps the border it was exported with, see references/export.md).

Engines:
  container  the pinned draw.io export image (docker or podman). This is the
             reference: it renders Arial as Liberation Sans, exactly as the
             committed PNGs were rendered, and runs with no network.
  desktop    the draw.io desktop CLI (drawio on PATH, or the macOS/Windows
             app). Same layout; glyph shapes can differ slightly where the
             machine has real Arial, so use it for drafts if no container
             runtime is available and say so in the pull request.
  auto       container when docker or podman is on PATH, else desktop.

Standard library only. Prints the PNG path and its size.
"""
import argparse
import os
import platform
import shutil
import struct
import subprocess
import sys

IMAGE = ("docker.io/rlespinasse/drawio-desktop-headless:v1.75.0"
         "@sha256:e1727782c9ea6a6e19793ac2ec89642a2f2e485c783ba4e989151ec26c130897")
DESKTOP = [
    "drawio", "draw.io",
    "/Applications/draw.io.app/Contents/MacOS/draw.io",
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\draw.io\draw.io.exe"),
    r"C:\Program Files\draw.io\draw.io.exe",
]


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


def run_container(runtime, src, out, border):
    folder = os.path.dirname(src)
    tmp_name = os.path.splitext(os.path.basename(src))[0] + ".export-tmp.png"
    cmd = [runtime, "run", "--rm", "--network", "none", "--shm-size=1g", "-e", "HOME=/tmp",
           "-v", f"{folder}:/data"]
    if hasattr(os, "getuid"):
        cmd += ["--user", f"{os.getuid()}:{os.getgid()}"]
    cmd += [IMAGE, "-x", "-f", "png", "-s", "2", "--border", str(border),
            "-o", f"/data/{tmp_name}", f"/data/{os.path.basename(src)}"]
    subprocess.run(cmd, check=True)
    shutil.move(os.path.join(folder, tmp_name), out)


def run_desktop(src, out, border):
    exe = next((shutil.which(c) or (c if os.path.isfile(c) else None) for c in DESKTOP
                if shutil.which(c) or os.path.isfile(c)), None)
    if not exe:
        raise SystemExit("no container runtime and no draw.io desktop found; install one of them")
    cmd = [exe, "-x", "-f", "png", "-s", "2", "--border", str(border), "-o", out, src]
    if platform.system() == "Linux":
        cmd += ["--no-sandbox", "--disable-gpu"]
        if not os.environ.get("DISPLAY") and shutil.which("xvfb-run"):
            cmd = ["xvfb-run", "-a"] + cmd
    subprocess.run(cmd, check=True)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("figure")
    p.add_argument("--out", help="PNG path (default: next to the .drawio)")
    p.add_argument("--border", type=int, default=20)
    p.add_argument("--engine", choices=["auto", "container", "desktop"], default="auto")
    a = p.parse_args(argv)
    src = os.path.abspath(a.figure)
    out = os.path.abspath(a.out or os.path.splitext(src)[0] + ".png")
    runtime = shutil.which("docker") or shutil.which("podman")
    engine = a.engine if a.engine != "auto" else ("container" if runtime else "desktop")
    if engine == "container":
        if not runtime:
            raise SystemExit("--engine container needs docker or podman on PATH")
        run_container(runtime, src, out, a.border)
    else:
        run_desktop(src, out, a.border)
    w, h = png_size(out)
    print(f"{out}  {w}x{h}  ({engine}, scale 2, border {a.border})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
