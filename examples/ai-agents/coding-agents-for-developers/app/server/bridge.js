// The app's side of session-bridge, the small server each session pod runs (see
// images/base/session-bridge). The terminal, the activity read and the mount-credential
// refresh go straight to the pod over TLS on the pod network, so the traffic between the
// app and a running session's pod does not go through the Kubernetes API. Exec is used only
// to start and stop a session, and once per running pod after an app restart (k8s.js).
//
// Each request presents the session's bridge token, and the connection trusts exactly one
// certificate: the one the bridge made for itself at start, which the app read from a
// root-only file in the pod over exec and pinned in entry.bridgeCert. Code in the sandbox
// runs as uid 1000 and can read neither the token nor the bridge's key.

import https from "node:https";
import tls from "node:tls";
import { WebSocket } from "ws";

export const BRIDGE_PORT = 7681;
const SERVER_NAME = "session-bridge"; // the name in the bridge's certificate
const TIMEOUT_MS = 10000;

const tlsOptions = (entry) => ({
  ca: entry.bridgeCert,
  servername: SERVER_NAME,
  // The pod is dialled by IP; the pinned certificate names session-bridge instead.
  checkServerIdentity: (_host, cert) => tls.checkServerIdentity(SERVER_NAME, cert),
  minVersion: "TLSv1.3",
});
const authHeader = (entry) => ({ authorization: `Bearer ${entry.bridgeToken}` });

// Open the session's terminal. Resolves once the bridge has accepted it, with write
// (keystrokes), resize and close; onData gets the terminal's output, onClose its end.
export function attachTerminal(entry, { onData, onClose, cols = 200, rows = 50 }) {
  return new Promise((resolve, reject) => {
    const url = `wss://${entry.podIP}:${BRIDGE_PORT}/v1/terminal?cols=${cols}&rows=${rows}`;
    const ws = new WebSocket(url, {
      ...tlsOptions(entry),
      headers: authHeader(entry),
      perMessageDeflate: false,
      handshakeTimeout: TIMEOUT_MS,
    });
    let opened = false;
    ws.on("open", () => {
      opened = true;
      ws._socket?.setNoDelay(true);
      resolve({
        write: (data) => ws.readyState === ws.OPEN && ws.send(data, { binary: true }),
        resize: (c, r) => ws.readyState === ws.OPEN && ws.send(JSON.stringify({ resize: [c, r] })),
        close: () => ws.close(),
      });
    });
    ws.on("message", (data) => onData(data));
    ws.on("unexpected-response", (req, res) => {
      req.destroy();
      reject(new Error(`session-bridge refused the terminal: HTTP ${res.statusCode}`));
    });
    ws.on("error", (e) => { if (!opened) reject(e); });
    ws.on("close", () => { if (opened) onClose?.(); });
  });
}

function call(entry, method, path, body) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      ...tlsOptions(entry),
      host: entry.podIP, port: BRIDGE_PORT, method, path, agent: false, timeout: TIMEOUT_MS,
      headers: {
        ...authHeader(entry),
        ...(body !== undefined ? { "content-type": "text/plain", "content-length": Buffer.byteLength(body) } : {}),
      },
    }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(text);
        else reject(new Error(`session-bridge ${method} ${path}: HTTP ${res.statusCode} ${text.trim().slice(0, 200)}`));
      });
    });
    req.on("timeout", () => req.destroy(new Error(`session-bridge ${method} ${path}: timed out`)));
    req.on("error", reject);
    req.end(body);
  });
}

// The last time anything happened in the session's terminal, as an epoch: the newest of
// tmux's session_activity (key input) and each window's window_activity (output), so an
// agent still working on its own is not idle. 0 when the pod has no tmux session. Anything
// unreadable throws: it must never read as "idle" and release a live session.
export async function lastActivity(entry) {
  const v = JSON.parse(await call(entry, "GET", "/v1/activity"))?.activity;
  if (!Number.isInteger(v) || v < 0) throw new Error(`session-bridge returned activity ${JSON.stringify(v)}`);
  return v;
}

// Replace the session's mount credential before it expires. The bridge replaces the file
// only with a well-formed credential, so a failed refresh leaves the running one in place.
export async function refreshCredential(entry, credential) {
  await call(entry, "PUT", "/v1/credential", credential);
}
