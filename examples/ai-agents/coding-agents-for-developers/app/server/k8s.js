// Kubernetes operations: claim a warm pod, resolve its node AZ, deliver the mount
// credential and start the session through exec, attach a terminal to tmux, and release
// the claim. Everything the app does to a pod goes through the Kubernetes exec API, so
// the sandbox pods accept no network ingress at all.

import * as k8s from "@kubernetes/client-node";
import { Writable, Readable } from "node:stream";

const NAMESPACE = process.env.NAMESPACE;
const REGION = process.env.AWS_REGION;
const FS_ID = process.env.S3_FILES_FS_ID;

const kc = new k8s.KubeConfig();
kc.loadFromCluster(); // the app runs in-cluster with the agent-app service account
const core = kc.makeApiClient(k8s.CoreV1Api);
const custom = kc.makeApiClient(k8s.CustomObjectsApi);
const exec = new k8s.Exec(kc);

const GROUP = "extensions.agents.x-k8s.io";
const VERSION = "v1beta1";

// Claim a warm pod from the CLI's pool. Returns the claim name and the resolved pod.
export const claimNameFor = (session) => `agent-${session}`.slice(0, 63);

export async function claimPod(cli, session) {
  const claimName = claimNameFor(session);
  try {
    await custom.createNamespacedCustomObject({
      group: GROUP,
      version: VERSION,
      namespace: NAMESPACE,
      plural: "sandboxclaims",
      body: {
        apiVersion: `${GROUP}/${VERSION}`,
        kind: "SandboxClaim",
        metadata: {
          name: claimName,
          labels: { "app.kubernetes.io/part-of": "coding-agents-for-developers" },
        },
        spec: { warmPoolRef: { name: `agent-${cli}` } },
      },
    });
  } catch (e) {
    // A claim with this name already exists: the session is still claimed (the app lost
    // its in-memory record across a restart, or the browser reconnected). Adopt the
    // existing claim and its pod instead of failing, so reopen and restore are
    // idempotent. Any other error is real.
    if (e?.code !== 409) throw e;
  }

  // Wait for the claim to resolve to a sandbox pod AND for that pod to be scheduled onto
  // a node. A warm pod is adopted in well under a second, but if the pool is momentarily
  // empty the claim creates a new pod that is briefly Pending with no node yet. The node
  // is needed to resolve the mount target's AZ, so wait for it rather than reading a node
  // name that is still undefined.
  // If the claim never resolves, delete it so it does not hold a pod nobody tracks.
  try {
    const { podName, node } = await waitForClaimPod(claimName);
    return { claimName, podName, node };
  } catch (e) {
    await releaseClaim(claimName);
    throw e;
  }
}

async function waitForClaimPod(claimName, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  let podName;
  while (Date.now() < deadline) {
    if (!podName) {
      const claim = await custom.getNamespacedCustomObject({
        group: GROUP, version: VERSION, namespace: NAMESPACE,
        plural: "sandboxclaims", name: claimName,
      });
      podName = claim?.status?.sandbox?.name;
    }
    if (podName) {
      // When the pool is empty the controller names the new pod in the claim's status a
      // moment before the pod object exists, so a 404 here means "not created yet": keep
      // polling until the deadline instead of failing the start.
      let pod;
      try {
        pod = await core.readNamespacedPod({ name: podName, namespace: NAMESPACE });
      } catch (e) {
        if (e?.code !== 404) throw e;
        await sleep(250);
        continue;
      }
      const node = pod.spec?.nodeName;
      // Wait for the pod to be scheduled (node assigned) AND Ready. A warm pod adopted
      // from the pool is already Ready; but if the pool was momentarily empty the claim
      // creates a cold pod, and exec-ing into it before its container is Ready races the
      // kubelet and fails. The Ready condition is true only once the container accepts
      // exec, so this makes a cold claim wait the few seconds the pod needs instead.
      const ready = pod.status?.conditions?.some(
        (c) => c.type === "Ready" && c.status === "True"
      );
      if (node && ready) return { podName, node };
    }
    await sleep(250);
  }
  throw new Error(`claim ${claimName} did not resolve to a ready pod in time`);
}

export async function releaseClaim(claimName) {
  await custom
    .deleteNamespacedCustomObject({
      group: GROUP, version: VERSION, namespace: NAMESPACE,
      plural: "sandboxclaims", name: claimName,
    })
    .catch(() => {});
}

// The AZ id of the node a pod runs on, for the S3 Files mount-target DNS name.
export async function nodeAzId(nodeName) {
  const node = await core.readNode({ name: nodeName });
  return node.metadata?.labels?.["topology.k8s.aws/zone-id"];
}

// The credential is delivered as one base64 line, newline-terminated, so the reader in
// the pod returns on the newline and does not wait for the exec channel to signal EOF.
const b64line = (credential) => Buffer.from(credential, "utf8").toString("base64") + "\n";

// Start the session: the credential goes in on stdin (base64, one line), the session
// parameters as the command's environment, and the pod's entrypoint mounts the access
// point and starts the CLI in tmux. Runs once; the long-lived process is the pod's own.
// On Restore, SESSION_RESUME=1 tells the entrypoint to start the CLI with its own
// continue-the-last-conversation option.
export async function startSession(podName, { credential, fsId, apId, azId, resume = false }) {
  const script =
    `export S3_FILES_FS_ID=${fsId} S3_FILES_AP_ID=${apId} ` +
    `AWS_REGION=${REGION} POD_AZ_ID=${azId}` +
    (resume ? " SESSION_RESUME=1" : "") + "; " +
    // The entrypoint reads the base64 credential line on stdin; re-exec it with env set.
    `exec /usr/local/bin/session-entrypoint.sh`;
  await execOnce(podName, ["/bin/sh", "-c", script], b64line(credential));
  console.log(`session started in ${podName}`);
}

// Refresh the mount credential before it expires: write the new body into the pod's
// tmpfs credential file. Same one-line base64 delivery, decoded in the pod.
//
// Fail CLOSED: decode into a temporary file first, require a non-empty line, a successful
// base64 decode AND a well-formed credential body, then chmod and atomically rename over
// the live file. The live credential is never truncated until a valid replacement exists,
// so empty stdin or a corrupt line leaves the running mount's credential intact and the
// exec exits non-zero (which execOnce surfaces as a rejected promise) rather than
// replacing a good credential with an empty file.
export async function refreshCredential(podName, credential) {
  const script = [
    "set -eu",
    "IFS= read -r b64",
    '[ -n "${b64:-}" ] || { echo "refresh: empty credential on stdin" >&2; exit 1; }',
    "tmp=/dev/shm/session/credentials.new",
    'printf %s "$b64" | base64 -d > "$tmp" || { echo "refresh: base64 decode failed" >&2; rm -f "$tmp"; exit 1; }',
    'grep -q "^aws_access_key_id" "$tmp" || { echo "refresh: credential malformed" >&2; rm -f "$tmp"; exit 1; }',
    'chmod 600 "$tmp"',
    'mv -f "$tmp" /dev/shm/session/credentials',
  ].join("; ");
  await execOnce(podName, ["/bin/sh", "-c", script], b64line(credential));
}

// End the session's processes and unmount its folder, before the claim is released. The
// CLIs' SQLite databases and lock files sit on the NFS mount, and a lock left by a pod that
// was deleted mid-session is held by the server until its lease runs out; see
// session-stop.sh in the base image.
export async function stopSession(podName) {
  await execOnce(podName, ["/usr/local/bin/session-stop.sh"]);
}

// tmux last-activity epoch, to find idle sessions.
export async function lastActivity(podName) {
  const out = await execCapture(podName, [
    "/usr/bin/setpriv", "--reuid=1000", "--regid=1000", "--init-groups", "--inh-caps=-all",
    "env", "HOME=/workspace/home",
    "/bin/sh", "-c",
    "tmux display-message -p -t agent '#{session_activity}' 2>/dev/null || echo 0",
  ]);
  return parseInt(out.trim(), 10) || 0;
}

// Attach a browser terminal to the pod's tmux session. Returns the exec's streams so the
// caller can pipe them to a WebSocket.
export async function attachTerminal(podName, { onData, cols, rows }) {
  const stdout = new Writable({ write(chunk, _enc, cb) { onData(chunk); cb(); } });
  const stdin = new Readable({ read() {} });
  // Attach as the dev user (uid 1000), the identity that started the tmux server in the
  // entrypoint. `kubectl exec` runs as the container's default user (root), whose tmux
  // looks at a different socket and reports "no sessions", so drop to 1000 with the same
  // HOME the session uses before attaching.
  // Set a UTF-8 locale on the attach, and attach with `-u`. tmux decides whether the
  // attaching client can take UTF-8 from its locale (LC_ALL/LANG/LC_CTYPE) at attach time;
  // with none set it treats the client as non-UTF-8 and downgrades every multibyte glyph
  // -- the box-drawing (▎ ─ │), status (● ✻ ⚠) and smart-quote characters the agent TUIs
  // draw -- to `_` in the bytes it sends to the browser. That is what put the `_` streaks
  // in the terminal. `-u` forces UTF-8 regardless, and the locale makes it stick.
  const ws = await exec.exec(
    NAMESPACE, podName, "agent",
    ["/usr/bin/setpriv", "--reuid=1000", "--regid=1000", "--init-groups", "--inh-caps=-all",
      "env", "HOME=/workspace/home", "TERM=xterm-256color", "LANG=C.UTF-8", "LC_ALL=C.UTF-8",
      "/bin/sh", "-c", "exec tmux -u attach -t agent"],
    stdout, stdout, stdin, true,
  );
  return {
    write: (data) => stdin.push(data),
    resize: (c, r) => ws?.send?.(JSON.stringify({ Width: c, Height: r })),
    close: () => { try { ws?.close?.(); } catch {} },
  };
}

// --- exec helpers ---
// Run one command in the pod. When stdinBody is given, it is written to the command's
// standard input and the stream is ended so the container sees EOF (otherwise a reader
// like `cat` in the entrypoint blocks forever). Resolves on the exec's terminal status;
// a per-call timeout guards against a stuck channel.
function execOnce(podName, command, stdinBody) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };

    const stdin = new Readable({ read() {} });
    let err = "";
    const stdout = new Writable({ write(_c, _e, cb) { cb(); } });
    const stderr = new Writable({ write(c, _e, cb) { err += c.toString(); cb(); } });

    const timer = setTimeout(
      () => done(reject, new Error(`exec timed out on ${podName}: ${command.join(" ").slice(0, 80)}`)),
      120000,
    );

    // The Kubernetes exec status callback is the ONLY authority on success: it fires once
    // with status "Success" (exit 0) or a Failure object (non-zero exit / error). Resolve
    // only from a "Success" status; treat anything else, and a socket close that arrives
    // before any status, as a failure. A bare socket close is NOT success -- resolving on
    // it would make a failed command (a bad credential refresh, a mount that never
    // happened) look like it worked.
    let gotStatus = false;
    exec
      .exec(NAMESPACE, podName, "agent", command, stdout, stderr, stdin, false,
        (status) => {
          gotStatus = true;
          clearTimeout(timer);
          if (status?.status === "Success") done(resolve);
          else done(reject, new Error(err.trim() || status?.message || "exec failed"));
        })
      .then((ws) => {
        // Write the body and signal EOF. push(null) ends the Readable; the client library
        // then closes the exec's stdin channel, which the container reads as end of input.
        if (stdinBody !== undefined) stdin.push(stdinBody);
        stdin.push(null);
        // If the socket closes before the status callback fired, that is a failure, not a
        // success: the command's terminal status never arrived.
        if (ws && typeof ws.on === "function") {
          ws.on("close", () => {
            if (!gotStatus) {
              clearTimeout(timer);
              done(reject, new Error(err.trim() || `exec on ${podName} closed before a terminal status`));
            }
          });
        }
      })
      .catch((e) => { clearTimeout(timer); done(reject, e); });
  });
}

function execCapture(podName, command) {
  return new Promise((resolve) => {
    let out = "";
    const stdout = new Writable({ write(c, _e, cb) { out += c.toString(); cb(); } });
    const stderr = new Writable({ write(_c, _e, cb) { cb(); } });
    const finish = () => resolve(out);
    const timer = setTimeout(finish, 15000);
    exec
      .exec(NAMESPACE, podName, "agent", command, stdout, stderr, null, false,
        () => { clearTimeout(timer); finish(); })
      .catch(() => { clearTimeout(timer); finish(); });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
