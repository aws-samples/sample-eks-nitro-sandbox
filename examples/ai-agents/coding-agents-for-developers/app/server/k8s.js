// Kubernetes operations: claim a warm pod, resolve its node AZ, start and stop the session
// through exec, and release the claim. Exec is used only at the edges of a session: once to
// start it (delivering the mount credential and the session-bridge token on stdin, then
// reading back the bridge's certificate to pin) and once to stop it. The terminal, the
// activity read and the credential refresh in between go to session-bridge over the pod
// network (bridge.js), so the Kubernetes API is not on a session's data path.

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
  // If the claim never resolves, delete it so it does not hold a pod nobody tracks. The
  // original error is the one the caller sees; a failed delete is logged with the claim.
  try {
    const { podName, node, podIP } = await waitForClaimPod(claimName);
    return { claimName, podName, node, podIP };
  } catch (e) {
    await releaseClaim(claimName).catch((re) =>
      console.error(`claim ${claimName}: could not delete it after a failed start: ${re?.message || re}`));
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
      const podIP = pod.status?.podIP;
      if (node && ready && podIP) return { podName, node, podIP };
    }
    await sleep(250);
  }
  throw new Error(`claim ${claimName} did not resolve to a ready pod in time`);
}

// Every session claim this sample made, with the pod each resolved to: [{ claimName,
// podName }]. Used at app start to pick up sessions that kept running while the app
// restarted. Claims without a pod yet are skipped.
export async function listSessionClaims() {
  const out = await custom.listNamespacedCustomObject({
    group: GROUP, version: VERSION, namespace: NAMESPACE, plural: "sandboxclaims",
    labelSelector: "app.kubernetes.io/part-of=coding-agents-for-developers",
  });
  return (out?.items ?? [])
    .map((c) => ({ claimName: c.metadata?.name, podName: c.status?.sandbox?.name }))
    .filter((c) => c.claimName && c.podName);
}

// The node a pod runs on, and its IP, where session-bridge listens.
export async function podInfo(podName) {
  const pod = await core.readNamespacedPod({ name: podName, namespace: NAMESPACE });
  return { node: pod.spec?.nodeName, podIP: pod.status?.podIP };
}

// The pod a claim resolved to, or null when there is no such claim (or it has no pod yet).
export async function claimedPodName(claimName) {
  try {
    const claim = await custom.getNamespacedCustomObject({
      group: GROUP, version: VERSION, namespace: NAMESPACE,
      plural: "sandboxclaims", name: claimName,
    });
    return claim?.status?.sandbox?.name || null;
  } catch (e) {
    if (e?.code === 404) return null;
    throw e;
  }
}

// Delete a session's claim (the pod goes with it). A claim that is already gone is fine;
// any other failure is thrown, so Close, idle release, Delete and a failed start never
// report success while the claim and its pod remain.
export async function releaseClaim(claimName) {
  try {
    await custom.deleteNamespacedCustomObject({
      group: GROUP, version: VERSION, namespace: NAMESPACE,
      plural: "sandboxclaims", name: claimName,
    });
  } catch (e) {
    if (e?.code !== 404) throw e;
  }
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
// The second stdin line is the session-bridge token (hex, never on a command line). The
// entrypoint starts the bridge before it returns, so the bridge's certificate is read back
// right after, and returned for the caller to pin.
export async function startSession(podName, { credential, bridgeToken, fsId, apId, azId, resume = false }) {
  const script =
    `export S3_FILES_FS_ID=${fsId} S3_FILES_AP_ID=${apId} ` +
    `AWS_REGION=${REGION} POD_AZ_ID=${azId}` +
    (resume ? " SESSION_RESUME=1" : "") + "; " +
    // The entrypoint reads the credential and token lines on stdin; re-exec it with env set.
    `exec /usr/local/bin/session-entrypoint.sh`;
  await execOnce(podName, ["/bin/sh", "-c", script], b64line(credential) + bridgeToken + "\n");
  console.log(`session started in ${podName}`);
  return (await readBridge(podName)).cert;
}

// The bridge's certificate, and its token, from their root-only files in the pod. Used
// right after start (for the certificate), and when the app picks up sessions that kept
// running across its own restart (for both), since it keeps them only in memory.
export async function readBridge(podName) {
  const out = await execCapture(podName, ["/bin/sh", "-c",
    "cat /dev/shm/session/bridge-token; echo; cat /dev/shm/session/bridge.crt"]);
  const [token, ...rest] = out.split("\n");
  const cert = rest.join("\n").trim();
  if (!/^[0-9a-f]{64}$/.test(token) || !/^-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----$/.test(cert))
    throw new Error(`session-bridge is not set up in ${podName}`);
  return { token, cert: cert + "\n" };
}

// End the session's processes and unmount its folder, before the claim is released. The
// CLIs' SQLite databases and lock files sit on the NFS mount, and a lock left by a pod that
// was deleted mid-session is held by the server until its lease runs out; see
// session-stop.sh in the base image.
export async function stopSession(podName) {
  await execOnce(podName, ["/usr/local/bin/session-stop.sh"]);
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

// Run one command and resolve with its standard output. Rejects on a timeout, on an exec
// that could not start, and on a non-success terminal status, so a caller cannot mistake a
// failure for an empty answer.
function execCapture(podName, command) {
  return new Promise((resolve, reject) => {
    let out = "";
    let err = "";
    let settled = false;
    const done = (fn, arg) => { if (!settled) { settled = true; clearTimeout(timer); fn(arg); } };
    const stdout = new Writable({ write(c, _e, cb) { out += c.toString(); cb(); } });
    const stderr = new Writable({ write(c, _e, cb) { err += c.toString(); cb(); } });
    const timer = setTimeout(
      () => done(reject, new Error(`exec timed out on ${podName}: ${command.join(" ").slice(0, 80)}`)),
      15000,
    );
    exec
      .exec(NAMESPACE, podName, "agent", command, stdout, stderr, null, false,
        (status) => {
          if (status?.status === "Success") done(resolve, out);
          else done(reject, new Error(err.trim() || status?.message || `exec failed on ${podName}`));
        })
      .catch((e) => done(reject, e));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
