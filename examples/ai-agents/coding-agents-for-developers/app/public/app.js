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
    el.innerHTML = `<div class="name">${cli}</div><div class="muted">New agent</div>`;
    el.onclick = async () => {
      const { session } = await api("/api/new", { developer, cli });
      openTerminal(session, cli);
      loadSessions();
    };
    tiles.appendChild(el);
  }
}

async function loadSessions() {
  const { sessions } = await api("/api/sessions?developer=" + encodeURIComponent(developer));
  const rows = $("#session-rows");
  rows.innerHTML = "";
  for (const s of sessions) {
    const tr = document.createElement("tr");
    const used = s.lastUsed ? new Date(s.lastUsed).toLocaleString() : "";
    tr.innerHTML =
      `<td>${s.session}</td><td>${s.cli}</td><td class="muted">${used}</td>`;
    const actions = document.createElement("td");
    const restore = document.createElement("button");
    restore.textContent = s.running ? "Open" : "Restore";
    restore.onclick = async () => {
      if (!s.running) await api("/api/restore", { developer, session: s.session });
      openTerminal(s.session, s.cli);
    };
    const del = document.createElement("button");
    del.textContent = "Delete";
    del.className = "link";
    del.onclick = async () => {
      if (!confirm(`Delete session ${s.session}? This removes its folder.`)) return;
      await api("/api/delete", { developer, session: s.session });
      loadSessions();
    };
    actions.append(restore, del);
    tr.appendChild(actions);
    rows.appendChild(tr);
  }
}

// --- Floating terminal windows ---
const windows = new Map();
let zTop = 10;

function openTerminal(session, cli) {
  if (windows.has(session)) return focusWindow(session);

  const win = document.createElement("div");
  win.className = "term-window";
  win.style.left = `${80 + windows.size * 28}px`;
  win.style.top = `${80 + windows.size * 28}px`;
  win.style.zIndex = ++zTop;
  win.innerHTML = `
    <div class="term-titlebar">
      <span class="title">${cli} · ${session}</span>
      <button data-act="min">–</button>
      <button data-act="close">×</button>
    </div>
    <div class="term-body"></div>
    <div class="resize-handle"></div>`;
  $("#windows").appendChild(win);

  const term = new window.Terminal({
    fontFamily: "ui-monospace, Menlo, Consolas, monospace",
    fontSize: 13, theme: { background: "#000000" }, cursorBlink: true,
  });
  const fit = new window.FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(win.querySelector(".term-body"));
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

  windows.set(session, { win, term, ws, cli });
  win.addEventListener("mousedown", () => { win.style.zIndex = ++zTop; });
  win.querySelector('[data-act="close"]').onclick = async () => {
    ws.close(); win.remove(); windows.delete(session);
    await api("/api/close", { session }); loadSessions();
  };
  win.querySelector('[data-act="min"]').onclick = () => minimize(session);
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
  chip.textContent = `${w.cli} · ${session}`;
  chip.onclick = () => focusWindow(session);
  $("#dock").appendChild(chip);
}
function removeChip(session) {
  $("#dock").querySelector(`[data-session="${CSS.escape(session)}"]`)?.remove();
}

function makeDraggable(win, handle) {
  let sx, sy, ox, oy;
  handle.addEventListener("mousedown", (e) => {
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
