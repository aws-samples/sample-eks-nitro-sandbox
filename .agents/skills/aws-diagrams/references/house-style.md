# House style

Every value below was read from the five committed figures. The source column names them:

| Key | Figure |
|---|---|
| F1 | `examples/images/figure-1-isolation-boundary.drawio` |
| F2 | `examples/getting-started/coding-agent/images/figure-2-coding-agent-egress.drawio` |
| F3 | `examples/getting-started/warm-pool/images/figure-3-warm-pool.drawio` |
| CMA | `examples/ai-agents/claude-managed-agents/images/claude-managed-agents.drawio` |
| NP | `examples/ai-agents/claude-managed-agents/images/claude-managed-agents-network-policy.drawio` |

When a new figure needs something these figures never show, take the closest existing element and
change as little as you can. Do not invent a new colour, font size or arrow style.

## Canvas

| Property | Value | Source |
|---|---|---|
| Background | `background="#ffffff"` on `mxGraphModel`. Without it the PNG is transparent and turns dark on a dark page. | all |
| Page | `page="0"`, `grid="1" gridSize="10"` | all |
| Format | Plain, uncompressed XML, so a pull request diff is readable | all |
| Margin | The outermost frame or actor starts about 40 px from the origin | F1, F2, F3, CMA |
| Grid | Icon centres mostly on multiples of 40, every coordinate on 10 | all |
| Size | 1080×800 (F1) up to 2280×1400 (CMA) before export | all |

## Text

| Element | Size | Weight | Colour | Line height | Source |
|---|---|---|---|---|---|
| Every text-bearing cell | | | | | `fontFamily=Arial,Helvetica,sans-serif` on all of them |
| Frame title | 22 px | bold | the frame's colour | 26.4 px | all 25 frames |
| Frame sub line | 18 px | normal | `#5F6B7A` | 20 to 24 px | F1, F2, F3, CMA, NP |
| Icon label, first line | 24 px | regular | `#232F3E` | 28.8 px | F1, F2, F3, most of CMA (NP uses 22 px) |
| Icon label, detail line | 24 px | italic | `#5F6B7A` | 27.2 px | F1, F2, F3, most of CMA (NP uses 22 px) |
| Edge label | 18 px | italic (`fontStyle=2`) | `#414D5C` | default | all 26 labelled edges |
| Note under a figure | 16 px | first words bold | `#5F6B7A` | 20 px | NP |

Labels are short noun phrases. Step order is written into the edge label itself (`1. claim a
sandbox`, `2. exec / cp / logs via the Kubernetes API`): the figures use no numbered circles.

## Colours

| Colour | Used for | Source |
|---|---|---|
| `#232F3E` | AWS Cloud frame, pod and VM boxes, icon label text | all |
| `#232F3D` | Fill of the dark glyph icons (user, document, generic application, gear, credentials, git repository, source code) | all |
| `#ED7100` | EKS cluster and EKS node frames; fill of every 48 px frame tab icon; container glyphs | all |
| `#DD344C` | Nitro sandbox and Nitro Partition frames; security controls (network policy, Pod Identity role); refused destinations; refused edges | all |
| `#545B64` | Every ordinary edge | all |
| `#5F6B7A` | Secondary text: frame sub lines, icon detail lines, notes | all |
| `#414D5C` | Edge label text | all |
| `#7D8998` / `#5A6B86` | Dashed logical group (the agent-sandbox controller): outline / title | F3, CMA |
| `#01A88D` | Amazon Bedrock resource icon (the AI category colour draw.io's library gives it) | F2, F3 |
| `#1D8102` | Allowed egress paths, only when the figure contrasts allowed with refused | NP |

A resource icon (`shape=mxgraph.aws4.resourceIcon`) keeps the category fill draw.io's library
gives it, with `strokeColor=#ffffff`. A glyph icon takes one of the fills above with
`strokeColor=none`: dark `#232F3D` by default, red `#DD344C` for a security control or a refused
destination, orange `#ED7100` for a container.

## Frames

All frames: `strokeWidth=2`, `fillColor=none`, `rounded=0`, `verticalAlign=top`, `align=left`,
`spacing=0`, `whiteSpace=nowrap`, `fontStyle=1`, `fontSize=14` on the cell with the real sizes in
the value's HTML. `spacingTop` sets where the title starts. A title alone uses 6.417 in every
figure; a title with sub lines uses -5.583 (F1, F2, F3), 4 or 8 (CMA, NP). For a new figure use
the template's values, 6 for a title alone and 4 with a sub line, which keep both lines beside
the 48 px tab.

| Kind | Outline and title | Tab | Text starts | Source |
|---|---|---|---|---|
| AWS Cloud | `#232F3E` | `shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.group_aws_cloud_alt;grStroke=1;grIconSize=48` on the frame itself | `spacingLeft=62` | F2, F3, CMA |
| EKS cluster, EKS node | `#ED7100` | separate 48×48 cell at the frame's top-left corner, `resIcon=mxgraph.aws4.eks` (F1 draws "EKS node (EC2 instance)" with `ec2`) | `spacingLeft=62` | all |
| Nitro sandbox, Nitro Partition | `#DD344C` | 48×48 cell, `resIcon=mxgraph.aws4.ec2` | `spacingLeft=62` | all |
| Pod or VM box inside a sandbox frame, a regular pod, a third-party service | `#232F3E` | none | `spacingLeft=16` | F1, F3, CMA |
| Logical group (a controller) | `#7D8998`, `dashed=1;dashPattern=8 5;fixDash=1`, title `#5A6B86` | none | `spacingLeft=16` | F3, CMA |

The tab cell is `fillColor=#ED7100;strokeColor=#ffffff;shape=mxgraph.aws4.resourceIcon;resIcon=…`,
48×48, with no value. Copy one from `assets/figure-template.drawio`.

**Nesting** from outside in: AWS Cloud › EKS cluster (or EKS node) › Nitro sandbox › pod box › icons.
F1 goes EKS node › Nitro Partition › Lightweight VM › containers. Actors that are not AWS (a user, a
GitHub issue, GitHub itself) sit outside the AWS Cloud frame: callers on the left, external
services on the right (F2, F3). A third party's own control plane is a plain `#232F3E` box
outside AWS (CMA).

**Spacing:** a child frame's top is 80 px below its parent's top (100 when the parent has a sub
line, NP), inset 30 to 60 px from its left edge (usually 40). The first row of icons in a frame has
its icon tops 80 px below the frame top. Keep 40 px or more between a frame edge and anything in
it, measured from the icon's label, not the icon, and not much more: a frame is its content plus
that padding. A frame holding one small row should not be a tall empty box; shrink it, and let a
parent frame shrink with it.

**Title width:** the title and every sub line must fit: text start (62 with a tab, 16 without)
plus the measured width plus 16 px ≤ frame width. Too wide: shorten, move words to a sub line, or
widen the frame.

## Icons

| Property | Value | Source |
|---|---|---|
| Size | 80×80, every icon (30 of them); tab icons 48×48 | all |
| Label position | Below, centred: `verticalLabelPosition=bottom;verticalAlign=top;align=center;spacing=0` | all |
| Label lines | Name, then an italic grey detail line; three lines at most | all |
| Label block | About 29 px per line below the icon bottom: 1 line 29, 2 lines 56, 3 lines 85 | measured |
| Side label | `labelPosition=left` or `right`, `verticalLabelPosition=middle`, `spacingLeft/Right=12`, only to keep a horizontal pair readable | CMA |

Shapes in use (all present in draw.io's AWS library): `user`, `document`, `documents`,
`generic_application`, `gear`, `credentials`, `git_repository`, `source_code`, `filtering_rule`
(a network policy), `role` (Pod Identity), `internet_alt1` (destinations outside), `container_1`
and `container_2`, and the resource icon `bedrock`. Reuse these for the same meaning.

Icon label HTML, two lines:

```xml
value="&lt;div style=&quot;line-height:28.80px&quot;&gt;Amazon Bedrock&lt;/div&gt;&lt;div style=&quot;line-height:27.20px&quot;&gt;&lt;i&gt;&lt;span style=&quot;color:#5F6B7A&quot;&gt;Claude model&lt;/span&gt;&lt;/i&gt;&lt;/div&gt;"
```

Frame title HTML with a sub line:

```xml
value="&lt;div style=&quot;font-size:22px;line-height:26.40px&quot;&gt;Nitro sandbox pod&lt;/div&gt;&lt;div style=&quot;font-size:18px;line-height:22px&quot;&gt;&lt;span style=&quot;font-weight:normal&quot;&gt;&lt;span style=&quot;color:#5F6B7A&quot;&gt;runtimeClassName: isolated-sandbox&lt;/span&gt;&lt;/span&gt;&lt;/div&gt;"
```

## Edges

Common to every edge: `edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeWidth=2.5;endSize=10`,
and for a labelled edge `fontSize=18;fontStyle=2;fontColor=#414D5C;fontFamily=Arial,Helvetica,sans-serif;labelBackgroundColor=none`.

| Meaning | Style | Source |
|---|---|---|
| A call or a flow | `strokeColor=#545B64;endArrow=block;endFill=1;startArrow=none` | all |
| Two-way (exec and logs, tool calls in and results out) | as above plus `startArrow=block;startFill=1;startSize=10` | F1, F3, CMA |
| Refused or unreachable | `strokeColor=#DD344C;dashed=1;dashPattern=8 6;fixDash=1`, labelled `refused`, `denied` or `no route out` | F2, F3, CMA, NP |
| The path a feature does not take (a pod without the runtime class) | `strokeColor=#545B64;dashed=1;dashPattern=8 6;fixDash=1` | F1 |
| A control attached to what it governs | `strokeColor=#545B64;endArrow=none;startArrow=none` | F2, NP |
| Allowed egress next to refused egress | `strokeColor=#1D8102`, label background `#ffffff` | NP |

Colour and dash carry meaning, so use them only as the table says.

**Routing:** segments are horizontal or vertical. Anchor both ends (`exitX`, `exitY`, `entryX`,
`entryY`, plus `exitDx`/`entryDx` for a few pixels' nudge) and give every bend as a waypoint in
`<Array as="points">`, so draw.io draws the route you planned instead of inventing one. NP's
`e-dns` and `e-api` have no waypoints, which is why `check_drawio.py` warns on them; do not copy
that. Two edges
on one side of an icon sit at `0.25` and `0.75` (F1, F2); three at `0.125`, `0.5`, `0.875` (F3).
Do not leave an icon through its bottom: its label is there. Edges never pass through an icon or a
label.

**Edge labels:** on a horizontal segment, 15 px above it: `<mxPoint x="…" y="-15" as="offset" />`.
The label anchors at the middle of the whole route; the offset's `x` slides it along, or set the
geometry's own `x` between `-1` (source end) and `1` (target end), as the template's refused edge
does. Beside a vertical segment: `align=left` with offset `x=12` (CMA). A label must fit on its
segment with room to spare and must not cross a frame border.

## Pages: caption, alt text and files

- **Files:** the `.drawio` and its `.png` sit side by side in an `images/` folder next to the page's
  `README.md`. Names are `figure-<n>-<topic>` under Getting started and `<sample>-<topic>` in
  other sections.
- **Caption:** an italic paragraph right above the image, `*Figure <n>: <Title>. <One or two
  sentences on what the reader should notice.>*`. Getting started numbers figures across its pages
  from the home page (1 to 4); the Claude Managed Agents page starts again at 1. Follow the
  numbering already used where the figure goes, and ask before renumbering another page.
- **Alt text:** one paragraph in the image's `![…](images/<name>.png)` that gives a reader who
  cannot see the figure the same facts in reading order: each boundary, what runs inside it, each
  connection with its label, and what is refused. Do not start with "Image of" or "Diagram of".
- **One idea per figure.** The network policy figure (NP) zooms in on one pod rather than adding
  the policy to the overview (CMA).
