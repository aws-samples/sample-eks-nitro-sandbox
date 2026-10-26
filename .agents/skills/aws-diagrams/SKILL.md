---
name: aws-diagrams
description: Draw or edit an architecture figure for a sample page in this repository - an editable draw.io file in the style of the existing figures, with AWS icons, exported to PNG, plus its caption and alt text. Use it for any new figure, any change to an existing .drawio, or a question about how the figures are made.
---

# AWS diagrams for the sample pages

A figure on a sample page is two files side by side in the page's `images/` folder: the `.drawio`
source and the `.png` the page shows. The page gives it an italic caption and a full alt text.
Every figure shows **one idea** in the same look as the figures already published: same fonts,
colours, frames, icons and arrows.

You need a text editor, Python 3 and draw.io, either as the export container (Docker or Podman)
or as draw.io desktop. Nothing else: the scripts here use only Python's standard library.

| File (in this skill's folder) | What it is for |
|---|---|
| `references/house-style.md` | Every number, colour and style string, and which figure it came from. Read it before drawing. |
| `references/export.md` | Export engines and commands, the border each figure uses, the control render. |
| `assets/figure-template.drawio` | A small figure with one of each house element, to copy cells from. |
| `scripts/drawio_shapes.py` | Search draw.io's own AWS icon library for exact shape names and styles (`fetch` gets the library once). |
| `scripts/measure_text.py` | Width in px of a label at a font size, to size boxes and spacing. |
| `scripts/check_drawio.py` | Checks a `.drawio`: overlaps, clipped labels, edges through icons, wording, palette. |
| `scripts/export_png.py` | Exports the PNG with the repository's settings. |
| `scripts/compare_png.py` | Compares two PNGs on a white background, for the control render. |
| `scripts/test_scripts.py` | Proves the checks both ways; run it after changing a script. |

Run every command below from the repository root, where these files are under
`.agents/skills/aws-diagrams/`.

## Quick start

**Set up once per machine.** With Docker or Podman installed, run:

```bash
python3 .agents/skills/aws-diagrams/scripts/drawio_shapes.py fetch
```

This pulls the pinned export image (draw.io desktop, run headless) and copies draw.io's AWS
icon library out of it into `~/.cache/drawio-aws-library/`. It takes about a minute the first
time. After that, `check_drawio.py` can verify shape names, and `export_png.py` exports with no
further download; when Docker or Podman is on `PATH`, it uses the container. With draw.io
desktop installed instead, skip this step: the scripts find the desktop's library and
`export_png.py` falls back to the desktop CLI.

**Confirm the setup** by rendering a committed figure and comparing it with its PNG:

```bash
python3 .agents/skills/aws-diagrams/scripts/export_png.py examples/images/figure-1-isolation-boundary.drawio --border 0 --out /tmp/setup-check.png
python3 .agents/skills/aws-diagrams/scripts/compare_png.py examples/images/figure-1-isolation-boundary.png /tmp/setup-check.png
```

`byte-identical` means your engine is the one that made the committed figures.

**Make each figure** with this loop. The sections below explain each step.

1. Copy the template into the page's `images/` folder:
   `cp .agents/skills/aws-diagrams/assets/figure-template.drawio examples/<section>/<sample>/images/<name>.drawio`
2. Find each icon's exact shape: `drawio_shapes.py search "<service or thing>"`.
3. Edit the XML, sizing labels with `measure_text.py`.
4. Run `check_drawio.py` on the file until it prints no `ERROR`. Fix each `WARN` too, unless it
   is deliberate and you can say why.
5. Export: `export_png.py <file> --border 20`.
6. Open the PNG and look at it.

## What a figure may say

These rules apply to every label, title and note on a figure, and to its caption and alt text.

- **"pod" for the running unit a reader pools, claims, execs into or deletes:** a warm pod, the
  claimed pod, one pod per session. **"sandbox"** names the agent-sandbox resources (`Sandbox`,
  `SandboxClaim`, `SandboxWarmPool`: "1. claim a sandbox", "claim a warm sandbox") and the
  isolation boundary. **Never "VM" or "microVM" for the claimed thing**; say "VM" only to explain
  how the boundary works: the pod's containers run in a lightweight VM with its own kernel.
- **"network policy"**, never "fence".
- **"hardware-level isolation"**, never "strongest" or another superlative.
- **No tooling or testing words:** a figure shows what the feature does, not how the sample was
  built or checked (no script names, test counts, assertions, review notes).
- **No account values:** no account IDs, ARNs, cluster names, real hostnames, node names,
  usernames, email addresses or internal URLs. Use the placeholders the pages use
  (`example-org/example-app`).
- **Never a minimum CPU or memory request.** Showing a pod's actual size next to its manifest is
  fine; stating a minimum is not.
- **Only facts the page shows or AWS documentation states.** If the figure needs a claim the page
  does not make, add it to the page with its evidence first, or leave it off the figure.

`check_drawio.py` refuses the common forms of these (fence, superlatives, tooling words, account
IDs, ARNs, node names, emails, internal hostnames, a stated minimum, a claimed "VM"). It cannot
know your cluster names, user names or what the page states, so read every label for those too.

## Make a new figure

1. **Brief.** Write the figure's one idea in one sentence, then list what it shows: the actors,
   the boundaries (they become frames), each connection with its label, and, where the sample
   includes a network policy or any other policy, what is refused. Take
   each fact from the page the figure goes on. Open the existing figure closest to yours (the
   home page's isolation boundary, the coding agent's egress, the warm pool, Claude Managed
   Agents and its network policy) and its PNG, and reuse its arrangement where it fits.

2. **Plan on paper, then on the grid.** Read `references/house-style.md`. The main flow runs left
   to right on one row where it can: callers outside the AWS Cloud frame on the left, external
   services on the right, refused destinations below or to the right in red. Nest frames
   AWS Cloud › EKS cluster (or node) › Nitro sandbox › pod box. Put icon centres on a 40 px grid,
   one shared `y` per row and one shared `x` per column. Write the arithmetic down.

3. **Pick every icon from draw.io's library.** A wrong name draws a blank square and nothing in
   the XML says so. Search all of them at once and copy the style the library returns:

   ```bash
   python3 .agents/skills/aws-diagrams/scripts/drawio_shapes.py search "bedrock" "user" "filtering rule" "internet"
   python3 .agents/skills/aws-diagrams/scripts/drawio_shapes.py search --style "eks"
   ```

   It reads draw.io's library from a copy it fetches once out of the export image
   (`drawio_shapes.py fetch`, needs Docker or Podman), from an installed draw.io desktop, or
   from `--library` pointing at draw.io's public `Sidebar-AWS4.js`. Run `fetch` first if you
   have no desktop install: `check_drawio.py` uses the same library to refuse unknown shape
   names. Prefer a shape
   the existing figures already use for the same meaning (listed in the house style). Keep the
   library's `shape`, `resIcon` and category `fillColor`; replace its font and label settings
   with the house ones.

4. **Measure every string you will draw**, at the size it will have:

   ```bash
   python3 .agents/skills/aws-diagrams/scripts/measure_text.py --size 24 "Amazon Bedrock" "Claude model"
   python3 .agents/skills/aws-diagrams/scripts/measure_text.py --size 22 --bold "Nitro sandbox pod"
   python3 .agents/skills/aws-diagrams/scripts/measure_text.py --size 18 "clone / push with token"
   ```

   From the widths: neighbours on a row need centre pitch ≥ (wA + wB) / 2 + 24, and at least
   200; rows are about 240 apart (more under three-line labels). A frame must hold its title
   (text start 62 with a tab, 16 without, plus the width, plus 16) and keep 40 px between its
   edge and every child, counting labels. An edge label needs a straight segment at least its
   width plus 32. A label longer than about 25 characters breaks into two lines instead.

5. **Write the XML.** Start from a copy of `assets/figure-template.drawio`: keep its
   `mxGraphModel` line (white background, no page) and copy the cells you need. Put every cell on
   `parent="1"` with absolute coordinates, unless you are editing a figure built with nested
   containers. Give cells short readable ids (`bedrock`, `sandbox`, `e-app-bedrock`). Anchor both
   ends of each edge (`exitX`/`exitY`, `entryX`/`entryY`) and give each bend as a waypoint, so
   draw.io draws the route you planned. Save it uncompressed.

6. **Check it.**

   ```bash
   python3 .agents/skills/aws-diagrams/scripts/check_drawio.py path/to/images/figure.drawio
   ```

   Fix every `ERROR`. Fix each `WARN` too, unless it is deliberate and you can say why (an icon
   straddling a frame edge on purpose, say). `INFO` lines need no action. If it prints "AWS shape
   names NOT verified", run `drawio_shapes.py fetch` and check again. Fix only the element a
   finding names; do not re-plan the figure to clear one finding. Never drop a part of the
   architecture to make a finding go away: move it, re-route it or resize its frame.

7. **Export** with border 20 (see `references/export.md` for the engines):

   ```bash
   python3 .agents/skills/aws-diagrams/scripts/export_png.py path/to/images/figure.drawio --border 20
   ```

8. **Look at the PNG.** Open the PNG file itself with your image-viewing tool, so you see its
   pixels: Claude Code's `Read`, Codex's `view_image`, Kiro's image read, or your client's
   equivalent. The checker's output, the export log and the XML are not looking. Compare it with
   an existing figure's PNG and go through the list at the end of `references/export.md`; fix
   what you see, export again and look again. If your tools cannot show you an image, write "I
   could not view the PNG" in your reply and ask someone to look. Never describe a figure you have
   not seen.

9. **Caption and alt text.** On the page, right above the image:

   ```markdown
   *Figure 2: The network policy around one sandbox pod. The policy admits the poller inbound
   and allows egress to CoreDNS and the Claude API; everything else is refused.*

   ![A focused view of the network policy. Inside an EKS Auto Mode node, ...](images/figure.png)
   ```

   The caption names the idea in a few words, then says what to notice. The alt text walks the
   figure in reading order (each boundary, what runs in it, each connection with its label, and
   any refusal the figure shows) so a reader who cannot see the image gets the same facts. Write
   both as plain sentences, as the pages do: no em dashes.

## Edit an existing figure

The prime rule: **change only what you were asked to change.** Styles, waypoints, label
offsets, ids, the coordinate scheme and the export border stay exactly as they were. If
something else looks wrong, mention it instead of fixing it in the same change.

1. **Control render first.** Export the unchanged `.drawio` with the figure's own border and
   compare it with the committed PNG. Set `BORDER` from the table in `references/export.md`:
   0 for the three Getting started figures, 20 for `claude-managed-agents`, 15 for
   `claude-managed-agents-network-policy`.

   ```bash
   BORDER=0   # this figure's own border, from the table in references/export.md
   python3 .agents/skills/aws-diagrams/scripts/export_png.py path/to/images/figure.drawio --out /tmp/control.png --border "$BORDER"
   python3 .agents/skills/aws-diagrams/scripts/compare_png.py path/to/images/figure.png /tmp/control.png
   ```

   Byte-identical means your engine matches the one that made the committed PNG. If it differs,
   your engine is a different build: from here on compare against your control render, not the
   committed PNG.
2. Run `check_drawio.py` on the unchanged file and keep its output: the existing figures carry a
   few warnings of their own, and you are answerable only for what your edit adds.
3. Edit only the cells asked for. A renamed label is re-measured; a moved or added cell follows
   the house numbers; a new edge takes a side of the icon the existing edges leave free.
4. Check again: no new `ERROR` or `WARN` compared with step 2.
5. Export with the same border and compare with your control render: the pixels that changed
   should be only where you edited. Look at the PNG.
6. If the figure's content changed, update its caption and alt text to match.

In the pull request, say which engine exported the PNG, what the control render showed, and that
you looked at the result.
