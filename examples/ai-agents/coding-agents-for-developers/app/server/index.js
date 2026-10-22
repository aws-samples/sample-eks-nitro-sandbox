// The web app server: a small JSON API, a WebSocket terminal bridge, and the static UI.
// Bound to 0.0.0.0:8080 behind a ClusterIP Service, reached only with kubectl
// port-forward. The sign-in is a demo picker, not authentication: the page says so.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize } from "node:path";
import { WebSocketServer } from "ws";

import * as sessions from "./sessions.js";
import * as k8s from "./k8s.js";
import { displayName } from "./names.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(__dirname, "..", "public");
const PORT = 8080;
const CLIS = (process.env.AGENT_CLIS || "").split(",").map((s) => s.trim()).filter(Boolean);

const json = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

const readBody = (req) =>
  new Promise((resolve) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => resolve(b ? JSON.parse(b) : {}));
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
      return json(res, 200, { sessions: await sessions.listClosed(developer) });
    }
    if (req.method === "POST" && url.pathname === "/api/new") {
      const { developer, cli } = await readBody(req);
      console.log(`/api/new developer=${developer} cli=${cli}`);
      const entry = await sessions.newAgent(developer, cli);
      console.log(`/api/new done session=${entry.session}`);
      return json(res, 200, { session: entry.session, display: displayName(entry.session), cli: entry.cli });
    }
    if (req.method === "POST" && url.pathname === "/api/restore") {
      const { developer, session } = await readBody(req);
      const entry = await sessions.restore(developer, session);
      return json(res, 200, { session: entry.session, display: displayName(entry.session), cli: entry.cli });
    }
    if (req.method === "POST" && url.pathname === "/api/close") {
      const { session } = await readBody(req);
      await sessions.release(session);
      return json(res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/api/delete") {
      const { developer, session } = await readBody(req);
      await sessions.remove(developer, session);
      return json(res, 200, { ok: true });
    }
    return serveStatic(req, res);
  } catch (e) {
    console.error(`request error ${req.method} ${req.url}:`, e);
    json(res, 500, { error: String(e?.message || e) });
  }
});

// WebSocket terminal: /ws?session=<name>. Pipes tmux attach both ways.
const wss = new WebSocketServer({ server, path: "/ws" });
wss.on("connection", async (ws, req) => {
  const url = new URL(req.url, "http://localhost");
  const session = url.searchParams.get("session");
  const entry = sessions.getLive(session);
  if (!entry) {
    ws.close(1008, "session not running");
    return;
  }
  let term;
  try {
    term = await k8s.attachTerminal(entry.podName, {
      onData: (chunk) => ws.readyState === ws.OPEN && ws.send(chunk),
    });
  } catch (e) {
    ws.close(1011, String(e?.message || e));
    return;
  }
  ws.on("message", (data, isBinary) => {
    // Control frames carry {resize:[cols,rows]}; everything else is keystrokes.
    if (!isBinary) {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.resize) return term.resize(msg.resize[0], msg.resize[1]);
      } catch {}
    }
    term.write(data);
  });
  ws.on("close", () => term.close());
});

sessions.startBackgroundLoop();
server.listen(PORT, "0.0.0.0", () => {
  console.log(`coding-agents-for-developers app on :${PORT}, CLIs: ${CLIS.join(", ")}`);
});
