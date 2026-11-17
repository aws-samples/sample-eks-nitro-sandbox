// The web app server: a small JSON API, a WebSocket terminal bridge to the browser, and the
// static UI. The browser's terminal WebSocket is relayed to the pod's own session-bridge
// over the pod network (see bridge.js), so the Kubernetes API is not on a session's data path.
// Bound to 0.0.0.0:8080 behind a ClusterIP Service, reached only with kubectl
// port-forward. The sign-in is a demo picker, not authentication: the page says so.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize } from "node:path";
import { WebSocketServer } from "ws";

import * as sessions from "./sessions.js";
import * as bridge from "./bridge.js";
import { displayName, isSessionName } from "./names.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(__dirname, "..", "public");
const PORT = 8080;
const CLIS = (process.env.AGENT_CLIS || "").split(",").map((s) => s.trim()).filter(Boolean);

const json = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

// Input checks. The developer, CLI and session name become parts of a SandboxClaim name,
// an access-point root path and a bucket prefix, so each is checked before anything is
// created from it: a bad value gets a 400 and leaves no access point or claim behind.
// developer: a short DNS-label-style name; cli: one of the app's agent list; session: a
// name randomName produced.
const DEVELOPER_RE = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/;
class BadRequest extends Error {}
function check({ developer, cli, session }, need) {
  if (need.includes("developer") && !(typeof developer === "string" && DEVELOPER_RE.test(developer)))
    throw new BadRequest("invalid developer");
  if (need.includes("cli") && !(typeof cli === "string" && CLIS.includes(cli)))
    throw new BadRequest("invalid cli");
  if (need.includes("session") && !isSessionName(session))
    throw new BadRequest("invalid session");
}

// The cap is on bytes, not characters: a body of multibyte UTF-8 has fewer characters than
// bytes. Past the cap, stop keeping the body but keep reading it, so the request ends
// normally and the 400 reaches the client; destroying the request here would close the
// socket before the response.
const MAX_BODY = 16 * 1024;
const readBody = (req) =>
  new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    let tooLarge = false;
    req.on("data", (c) => {
      if (tooLarge) return;
      bytes += c.length;
      if (bytes > MAX_BODY) { tooLarge = true; chunks.length = 0; return; }
      chunks.push(c);
    });
    req.on("error", reject);
    req.on("end", () => {
      if (tooLarge) return reject(new BadRequest("body too large"));
      try {
        const text = Buffer.concat(chunks).toString("utf8");
        const v = text ? JSON.parse(text) : {};
        resolve(v && typeof v === "object" ? v : {});
      } catch {
        reject(new BadRequest("invalid JSON"));
      }
    });
  });

const CONTENT_TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

async function serveStatic(req, res) {
  let path = req.url.split("?")[0];
  if (path === "/") path = "/index.html";
  const file = normalize(join(PUBLIC, path));
  if (!file.startsWith(PUBLIC)) return json(res, 403, { error: "forbidden" });
  try {
    const data = await readFile(file);
    const ext = file.slice(file.lastIndexOf("."));
    res.writeHead(200, { "content-type": CONTENT_TYPES[ext] || "application/octet-stream" });
    res.end(data);
  } catch {
    json(res, 404, { error: "not found" });
  }
}

const server = createServer(async (req, res) => {
  try {
    console.log(`${req.method} ${req.url}`);
    const url = new URL(req.url, "http://localhost");
    if (req.method === "GET" && url.pathname === "/api/clis") {
      return json(res, 200, { clis: CLIS });
    }
    if (req.method === "GET" && url.pathname === "/api/sessions") {
      const developer = url.searchParams.get("developer");
      check({ developer }, ["developer"]);
      return json(res, 200, { sessions: await sessions.listClosed(developer) });
    }
    if (req.method === "POST" && url.pathname === "/api/new") {
      const { developer, cli } = await readBody(req);
      check({ developer, cli }, ["developer", "cli"]);
      console.log(`/api/new developer=${developer} cli=${cli}`);
      const entry = await sessions.newAgent(developer, cli);
      console.log(`/api/new done session=${entry.session}`);
      return json(res, 200, { session: entry.session, display: displayName(entry.session), cli: entry.cli });
    }
    if (req.method === "POST" && url.pathname === "/api/restore") {
      const { developer, session } = await readBody(req);
      check({ developer, session }, ["developer", "session"]);
      const entry = await sessions.restore(developer, session);
      return json(res, 200, { session: entry.session, display: displayName(entry.session), cli: entry.cli });
    }
    if (req.method === "POST" && url.pathname === "/api/close") {
      const { session } = await readBody(req);
      check({ session }, ["session"]);
      await sessions.release(session);
      return json(res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/api/delete") {
      const { developer, session } = await readBody(req);
      check({ developer, session }, ["developer", "session"]);
      await sessions.remove(developer, session);
      return json(res, 200, { ok: true });
    }
    return serveStatic(req, res);
  } catch (e) {
    if (e instanceof BadRequest) {
      console.log(`rejected ${req.method} ${req.url}: ${e.message}`);
      return json(res, 400, { error: e.message });
    }
    console.error(`request error ${req.method} ${req.url}:`, e);
    json(res, 500, { error: String(e?.message || e) });
  }
});

// WebSocket terminal: /ws?session=<name>. Relays the browser to the pod's tmux, both ways.
// maxPayload matches the bridge's own frame limit (1 MiB), well above a large paste.
const wss = new WebSocketServer({ server, path: "/ws", maxPayload: 1 << 20 });
const PENDING_MAX = 64 * 1024;
const PENDING_MIN = 64; // at most PENDING_MAX / PENDING_MIN (1024) queued messages
wss.on("connection", async (ws, req) => {
  const url = new URL(req.url, "http://localhost");
  const session = url.searchParams.get("session");
  const entry = isSessionName(session) ? sessions.getLive(session) : undefined;
  if (!entry) {
    ws.close(1008, "session not running");
    return;
  }
  // The browser sends its size the moment its socket opens, before the bridge has accepted
  // the terminal. Queue what arrives until then, so that first resize is not lost.
  let term;
  const pending = [];
  let browserClosed = false;
  const handle = (data, isBinary) => {
    // Control frames carry {resize:[cols,rows]}; everything else is keystrokes.
    if (!isBinary) {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.resize) return term.resize(msg.resize[0], msg.resize[1]);
      } catch {}
    }
    term.write(data);
  };
  // Bounded by bytes and by count (each message is charged at least PENDING_MIN, so empty
  // messages fill it too). Past the bound the browser is closed with 1009, the queue is
  // dropped and nothing more is taken. If the attach then completes, the terminal is
  // closed at once and receives no queued input.
  let pendingBytes = 0;
  ws.on("message", (data, isBinary) => {
    if (browserClosed) return;
    if (term) return handle(data, isBinary);
    pendingBytes += Math.max(data.length, PENDING_MIN);
    if (pendingBytes > PENDING_MAX) {
      browserClosed = true;
      pending.length = 0;
      return ws.close(1009, "too much input before the terminal opened");
    }
    pending.push([data, isBinary]);
  });
  ws.on("close", () => { browserClosed = true; term?.close(); });
  try {
    // To the pod's own session-bridge over the pod network, not the Kubernetes exec API.
    term = await bridge.attachTerminal(entry, {
      onData: (chunk) => ws.readyState === ws.OPEN && ws.send(chunk),
      onClose: () => { try { ws.close(); } catch {} },
    });
  } catch (e) {
    console.error(`terminal ${session}: ${e?.message || e}`);
    ws.close(1011, "terminal unavailable");
    return;
  }
  // The browser may have gone, or begun closing, while the bridge was connecting.
  if (browserClosed || ws.readyState !== ws.OPEN) return term.close();
  for (const [data, isBinary] of pending.splice(0)) handle(data, isBinary);
});

// Pick up sessions that kept running while the app was down, so the loop refreshes their
// credentials and releases them when idle, and only then start listening: until then a
// running session would show as idle. The wait has a deadline, so a pick-up that hangs
// cannot keep the app from serving; one that finishes later still lands, and does not
// overwrite a session a Restore has started meanwhile (sessions.js). A failure is logged;
// the app still starts. The Deployment's readiness probe holds traffic until the listener
// is up.
const ADOPT_DEADLINE_MS = 60 * 1000;
let deadlineTimer;
Promise.race([
  sessions.adoptRunningSessions()
    .then((n) => console.log(`picked up ${n} running session(s) after start`))
    .catch((e) => console.error(`could not pick up running sessions after start: ${e?.message || e}`)),
  new Promise((r) => { deadlineTimer = setTimeout(() => {
    console.error(`picking up running sessions is taking over ${ADOPT_DEADLINE_MS / 1000} s; serving now, it continues`);
    r();
  }, ADOPT_DEADLINE_MS); }),
]).finally(() => {
  clearTimeout(deadlineTimer);
  sessions.startBackgroundLoop();
  server.listen(PORT, "0.0.0.0", () => {
    console.log(`coding-agents-for-developers app on :${PORT}, CLIs: ${CLIS.join(", ")}`);
  });
});
