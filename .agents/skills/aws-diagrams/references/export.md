# Export

Every figure is exported as **PNG, scale 2**, from its `.drawio`, with a white background set in
the file. Use `scripts/export_png.py`; it runs one of the two engines below with those settings.

```bash
python3 .agents/skills/aws-diagrams/scripts/export_png.py path/to/images/figure.drawio --border 20
```

## Engines

**The export container (reference).** A public image of draw.io desktop that exports headless:
[rlespinasse/drawio-desktop-headless](https://github.com/rlespinasse/drawio-desktop-headless) (MIT),
pinned by digest. Tag `v1.75.0` carries draw.io desktop 32.4.1 and renders
`Arial,Helvetica,sans-serif` as Liberation Sans, as the committed PNGs were rendered. Use the
full image, not the `minimal` variant, which ships fewer fonts.

```bash
docker run --rm --network none --shm-size=1g --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/examples/getting-started/hello-sandbox/images:/data" \
  docker.io/rlespinasse/drawio-desktop-headless:v1.75.0@sha256:e1727782c9ea6a6e19793ac2ec89642a2f2e485c783ba4e989151ec26c130897 \
  -x -f png -s 2 --border 20 -o /data/figure.png /data/figure.drawio
```

- `--network none`: the export needs no network, so give it none.
- `--shm-size=1g`: without it Electron's renderer can crash on large figures.
- `--user` and `HOME=/tmp`: the PNG is owned by you, not root.
- Podman takes the same arguments.
- Lines about D-Bus and `sqlite_persistent_store` in the output are noise from Electron; the
  export succeeded if it prints `/data/figure.drawio -> /data/figure.png`.

**draw.io desktop CLI.** Install [draw.io desktop](https://github.com/jgraph/drawio-desktop/releases)
and run the same flags:

```bash
drawio -x -f png -s 2 --border 20 -o figure.png figure.drawio                       # Linux, on PATH
xvfb-run -a drawio -x -f png -s 2 --border 20 -o figure.png figure.drawio --no-sandbox --disable-gpu   # Linux, no display
/Applications/draw.io.app/Contents/MacOS/draw.io -x -f png -s 2 --border 20 -o figure.png figure.drawio  # macOS
"C:\Program Files\draw.io\draw.io.exe" -x -f png -s 2 --border 20 -o figure.png figure.drawio           # Windows
```

The layout is the same, but where the machine has real Arial the glyphs differ slightly from the
container's. Fine for drafts; for the PNG you commit, prefer the container, and if you could not,
say which engine you used in the pull request.

## Border

`--border` is in diagram units, so at scale 2 a border of 20 adds 40 px to each side.

| Figure | Border |
|---|---|
| `figure-1-isolation-boundary` | 0 |
| `figure-2-coding-agent-egress` | 0 |
| `figure-3-warm-pool` | 0 |
| `claude-managed-agents` | 20 |
| `claude-managed-agents-network-policy` | 15 |
| any new figure | 20 |

Re-export an existing figure with its own border, or its size changes on the page.

## Control render

Before you trust a render of an edited figure, export the **unchanged** `.drawio` with your
engine and compare it with the committed PNG:

```bash
python3 .agents/skills/aws-diagrams/scripts/compare_png.py committed.png control.png
```

`compare_png.py` flattens both images onto white before it compares them. Comparing only the
alpha channel would miss any change drawn in colour, and a transparent pixel next to a white one
would look like a difference.

- **Byte-identical:** your engine is the one that made the committed PNG. After your edit, the
  only pixels that change should be where you edited.
- **Different:** your engine differs from the one that made the committed PNG, for example a
  newer draw.io build. Then compare your edited render with **your control render**, not with
  the committed PNG, and check that the differences sit only where you edited.

Results with the pinned image (v1.75.0, draw.io 32.4.1) against the committed PNGs:

| Figure | Result |
|---|---|
| `figure-1-isolation-boundary` (border 0) | byte-identical |
| `claude-managed-agents-network-policy` (border 15) | byte-identical |
| `figure-2-coding-agent-egress` (border 0) | same size; one edge label ("clone / push with token") sits 2 px (one diagram unit) further left |
| `figure-3-warm-pool` (border 0) | same size; two edge labels ("1. claim a sandbox", "under 1 s: adopt a pre-booted pod") sit 2 px further left |
| `claude-managed-agents` (border 20) | 20 px wider and taller, and the two-line label of step 5 sits about 2 px higher. The committed PNG came from an earlier draw.io build |

## After the export: look at it

Open the PNG at full size and read it as a reader would. A check of the XML cannot see
everything; look for:

- every label fully inside the image, not clipped or running over a line or a frame border;
- no edge passing through an icon or a label, and arrowheads touching the shape they point to;
- every icon drawn: a blank or plain square means a wrong shape name;
- the frames, fonts and colours of the existing figures: open one next to yours;
- white background, not transparent;
- the figure readable at the page's width: the site scales a wide figure down, so a very wide,
  shallow figure ends up with small text.
