// UI: demo-picker sign-in, per-CLI launcher tiles, draggable/resizable/minimizable
// floating terminals wired to the server's WebSocket bridge, and the session list.
// xterm.js (6.0.0) and the fit addon are loaded from /vendor as globals.

const $ = (sel) => document.querySelector(sel);
let developer = null;

const api = async (path, body) => {
  const res = await fetch(path, {
    method: body ? "POST" : "GET",
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error((await res.json()).error || res.statusText);
  return res.json();
};

$("#signin-btn").onclick = async () => {
  developer = $("#developer").value;
  $("#who").textContent = `Signed in as ${developer} (demo)`;
  $("#signin").classList.add("hidden");
  $("#workspace").classList.remove("hidden");
  await Promise.all([loadTiles(), loadSessions()]);
};
$("#signout-btn").onclick = () => location.reload();

async function loadTiles() {
  const { clis } = await api("/api/clis");
  const tiles = $("#tiles");
  tiles.innerHTML = "";
  for (const cli of clis) {
    const el = document.createElement("div");
    el.className = "tile";
    el.innerHTML = `<div class="name">${cli}</div><div class="sub">New agent</div>`;
    const sub = el.querySelector(".sub");
    // A new session takes seconds from a warm pod, and up to a minute on the first mount or
    // a cold start. The tile gave no sign of it, so a second click started a second session
    // (claude-code, from a pool of one, then waited for a cold start). While a start
    // is in flight the tile says so and ignores clicks; a failed start shows its error on
    // the tile and lets the next click try again.
    el.onclick = async () => {
      if (el.classList.contains("busy")) return;
      el.classList.add("busy");
      el.classList.remove("failed");
      el.setAttribute("aria-busy", "true");
      sub.textContent = "Starting...";
      try {
        const { session, display } = await api("/api/new", { developer, cli });
        openTerminal(session, cli, display);
        sub.textContent = "New agent";
        loadSessions();
      } catch (err) {
        el.classList.add("failed");
        sub.textContent = `Could not start: ${err.message}`;
      } finally {
        el.classList.remove("busy");
        el.removeAttribute("aria-busy");
      }
    };
    tiles.appendChild(el);
  }
}

// When the session started, as a relative string, from the base-36 millisecond timestamp
// the session name carries as its first segment (see names.js). The list tracks no
// server-side "last activity" -- that was dropped so the list can be built from access-point
// paths alone at thousands of sessions -- so this is the start time, which is what the
// "Started" column shows.
function relativeTime(session) {
  const prefix = String(session).split("-")[0];
  const ms = parseInt(prefix, 36);
  if (!Number.isFinite(ms)) return "";
  const secs = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (secs < 60) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  return `${days}d ago`;
}

// Sessions whose Delete is still running. Delete takes 40 seconds or more (the server
// drains the folder's object versions until two checks 20 seconds apart find none) and the
// row gave no sign of it. Kept outside the table, because the table is rebuilt whenever the
// list reloads, which would otherwise reset a row that is still being deleted.
const deleting = new Set();
// Sessions whose Restore is still running, for the same reason.
const restoring = new Set();

async function loadSessions() {
  const { sessions } = await api("/api/sessions?developer=" + encodeURIComponent(developer));
  const rows = $("#session-rows");
  rows.innerHTML = "";
  for (const s of sessions) {
    const tr = document.createElement("tr");
    const name = s.display || s.session;
    const status = s.running ? "running" : "idle";
    tr.innerHTML =
      `<td class="name-cell">${name}</td><td class="muted">${s.cli}</td>` +
      `<td><span class="status ${status}">${status}</span></td>` +
      `<td class="muted">${relativeTime(s.session)}</td>`;
    const actions = document.createElement("td");
    actions.className = "row-actions";
    const restore = document.createElement("button");
    restore.className = "btn-sm";
    const del = document.createElement("button");
    del.className = "btn-sm btn-ghost";
    // Draw both buttons from the operation state, which lives outside the table, so a row
    // rebuilt by a list reload mid-operation still shows it and still ignores clicks.
    const render = () => {
      const r = restoring.has(s.session), d = deleting.has(s.session);
      restore.textContent = r ? "Restoring..." : s.running ? "Open" : "Restore";
      del.textContent = d ? "Deleting..." : "Delete";
      restore.disabled = del.disabled = r || d;
      for (const [b, busy] of [[restore, r], [del, d]]) {
        if (busy) b.setAttribute("aria-busy", "true");
        else b.removeAttribute("aria-busy");
      }
    };
    render();
    // Restore claims a pod and mounts the folder, which takes a few seconds. Say so while it
    // runs, then reload the list so the row shows the session as running.
    restore.onclick = async () => {
      if (restoring.has(s.session) || deleting.has(s.session)) return;
      if (s.running) return openTerminal(s.session, s.cli, name);
      restoring.add(s.session);
      render();
      try {
        await api("/api/restore", { developer, session: s.session });
        openTerminal(s.session, s.cli, name);
      } catch (err) {
        alert(`Could not restore ${name}: ${err.message}`);
      } finally {
        restoring.delete(s.session);
        render(); // the buttons come back even if the reload below fails
        loadSessions().catch(() => {});
      }
    };
    del.onclick = async () => {
      if (restoring.has(s.session) || deleting.has(s.session)) return;
      if (!confirm(`Delete session ${s.session}? This removes its folder.`)) return;
      deleting.add(s.session);
      render();
      try {
        await api("/api/delete", { developer, session: s.session });
      } catch (err) {
        alert(`Could not delete ${name}: ${err.message}`);
      } finally {
        deleting.delete(s.session);
        render();
        loadSessions().catch(() => {});
      }
    };
    actions.append(restore, del);
    tr.appendChild(actions);
    rows.appendChild(tr);
  }
}

// --- Floating terminal windows ---
const windows = new Map();
let zTop = 10;

function openTerminal(session, cli, display) {
  const label = display || session;
  if (windows.has(session)) return focusWindow(session);

  const win = document.createElement("div");
  win.className = "term-window";
  // Cascade new windows, but wrap the offset so a fourth or fifth window does not march off
  // the bottom-right edge (and behind the dock). Keep each fully on screen.
  const step = (windows.size % 6) * 30;
  win.style.left = `${64 + step}px`;
  win.style.top = `${72 + step}px`;
  win.style.zIndex = ++zTop;
  win.innerHTML = `
    <div class="term-titlebar">
      <span class="title">${cli} · ${label}</span>
      <span class="dots">
        <button data-act="min" title="Minimize">–</button>
        <button data-act="close" title="Close">×</button>
      </span>
    </div>
    <div class="term-body"></div>
    <div class="resize-handle"></div>`;
  $("#windows").appendChild(win);

  const term = new window.Terminal({
    // Name a full-coverage monospace font for each OS before the generic fallback: the
    // agent TUIs draw box-drawing (▎ ─ │), status glyphs (● ✻ ⚠) and accented text, and
    // the generic `monospace` on some systems maps to a font that lacks them and renders
    // each as `_`. DejaVu/Liberation/Noto (Linux), Menlo (macOS) and Consolas (Windows)
    // all carry these, so one of them is picked before the fallback.
    fontFamily: '"DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", ui-monospace, Menlo, Consolas, "Cascadia Mono", monospace',
    fontSize: 13, theme: { background: "#000000" }, cursorBlink: true,
    // allowProposedApi lets the unicode11 addon register; customGlyphs:false stops xterm
    // drawing its own versions of box-drawing/powerline glyphs, which distorts the agent
    // TUIs' own art (e.g. Claude Code's logo). Both follow the terminal that ships these
    // CLIs in production.
    allowProposedApi: true,
    customGlyphs: false,
  });
  const fit = new window.FitAddon.FitAddon();
  term.loadAddon(fit);
  // Unicode 11 width tables. The agent TUIs draw wide glyphs (powerline ⏵⏵, emoji, CJK)
  // whose cell width xterm's default (Unicode 6) tables get wrong, which smears the status
  // line and the logo. Activating version 11 measures them the way tmux and the CLI do, so
  // the browser grid and the pod's grid agree.
  const uni = new window.Unicode11Addon.Unicode11Addon();
  term.loadAddon(uni);
  term.unicode.activeVersion = "11";
  term.open(win.querySelector(".term-body"));
  // WebGL renderer: the agent TUIs (Codex especially) repaint the whole screen on every
  // keystroke, and the default DOM renderer is slow to paint that burst, which is most of
  // the perceived input lag. The WebGL renderer draws it on the GPU, so repaints keep up.
  // It must be loaded AFTER term.open(); on GPU context loss, drop it and fall back to the
  // DOM renderer so the terminal keeps working rather than freezing.
  try {
    const webgl = new window.WebglAddon.WebglAddon();
    webgl.onContextLoss(() => { try { webgl.dispose(); } catch {} });
    term.loadAddon(webgl);
  } catch { /* no WebGL (e.g. headless/software GL): stay on the DOM renderer */ }
  fit.fit();

  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws?session=${encodeURIComponent(session)}`);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => sendResize();
  ws.onmessage = (e) => term.write(new Uint8Array(e.data));
  ws.onclose = () => term.write("\r\n[detached]\r\n");
  term.onData((d) => ws.readyState === ws.OPEN && ws.send(d));

  const sendResize = () => {
    fit.fit();
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ resize: [term.cols, term.rows] }));
  };

  windows.set(session, { win, term, ws, cli, label });
  win.addEventListener("mousedown", () => { win.style.zIndex = ++zTop; });
  const closeBtn = win.querySelector('[data-act="close"]');
  closeBtn.addEventListener("mousedown", (e) => e.stopPropagation());
  closeBtn.onclick = async (e) => {
    e.stopPropagation();
    ws.close(); win.remove(); windows.delete(session);
    await api("/api/close", { session }); loadSessions();
  };
  const minBtn = win.querySelector('[data-act="min"]');
  // stopPropagation so the window-level mousedown (z-raise) and titlebar drag do not also
  // react to a click meant for the button.
  minBtn.addEventListener("mousedown", (e) => e.stopPropagation());
  minBtn.onclick = (e) => { e.stopPropagation(); minimize(session); };
  makeDraggable(win, win.querySelector(".term-titlebar"));
  makeResizable(win, win.querySelector(".resize-handle"), sendResize);
}

function focusWindow(session) {
  const w = windows.get(session);
  if (w) { w.win.classList.remove("hidden"); w.win.style.zIndex = ++zTop; removeChip(session); }
}

function minimize(session) {
  const w = windows.get(session);
  if (!w) return;
  w.win.classList.add("hidden");
  const chip = document.createElement("div");
  chip.className = "chip";
  chip.dataset.session = session;
  chip.textContent = `${w.cli} · ${w.label || session}`;
  chip.onclick = () => focusWindow(session);
  $("#dock").appendChild(chip);
}
function removeChip(session) {
  $("#dock").querySelector(`[data-session="${CSS.escape(session)}"]`)?.remove();
}

function makeDraggable(win, handle) {
  let sx, sy, ox, oy;
  handle.addEventListener("mousedown", (e) => {
    // The titlebar holds the minimize/close buttons; a mousedown on one of them must not
    // start a drag, or the drag swallows the click and the button never fires.
    if (e.target.closest("button")) return;
    sx = e.clientX; sy = e.clientY;
    ox = win.offsetLeft; oy = win.offsetTop;
    const move = (ev) => { win.style.left = `${ox + ev.clientX - sx}px`; win.style.top = `${oy + ev.clientY - sy}px`; };
    const up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up); };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  });
}
function makeResizable(win, handle, onResize) {
  handle.addEventListener("mousedown", (e) => {
    e.preventDefault();
    const sx = e.clientX, sy = e.clientY, sw = win.offsetWidth, sh = win.offsetHeight;
    const move = (ev) => {
      win.style.width = `${Math.max(360, sw + ev.clientX - sx)}px`;
      win.style.height = `${Math.max(240, sh + ev.clientY - sy)}px`;
      onResize();
    };
    const up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up); };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  });
}
