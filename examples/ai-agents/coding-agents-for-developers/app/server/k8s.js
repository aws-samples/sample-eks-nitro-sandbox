// Kubernetes operations: claim a warm pod, resolve its node AZ, start and stop the session
// through exec, and release the claim. Exec is used only at the edges of a session: to
// start it (delivering the mount credential and the session-bridge token on stdin, then
// reading back the bridge's token and certificate, and pinning the certificate), to stop it,
// and once per running pod after
// an app restart (readBridge). The terminal, the activity read and the credential refresh
// in between go to session-bridge over the pod network (bridge.js), so the Kubernetes API
// is not on the path between the app and a running session's pod.

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
// restarted.
export async function listSessionClaims() {
  const out = await custom.listNamespacedCustomObject({
    group: GROUP, version: VERSION, namespace: NAMESPACE, plural: "sandboxclaims",
    labelSelector: "app.kubernetes.io/part-of=coding-agents-for-developers",
  });
  // A claim with no pod yet is returned too (podName undefined): the pick-up looks again
  // once it has one.
  return (out?.items ?? [])
    .map((c) => ({ claimName: c.metadata?.name, podName: c.status?.sandbox?.name }))
    .filter((c) => c.claimName);
}

// The names of every claim this sample made, whether or not it has a pod yet. The access-
// point sweep treats any claim as "a pod may have the folder mounted".
export async function listClaimNames() {
  const out = await custom.listNamespacedCustomObject({
    group: GROUP, version: VERSION, namespace: NAMESPACE, plural: "sandboxclaims",
    labelSelector: "app.kubernetes.io/part-of=coding-agents-for-developers",
  });
  return new Set((out?.items ?? []).map((c) => c.metadata?.name).filter(Boolean));
}

// Whether a claim exists, with or without a pod. "Could not tell" is an error, not "no".
export async function claimExists(claimName) {
  try {
    await custom.getNamespacedCustomObject({
      group: GROUP, version: VERSION, namespace: NAMESPACE, plural: "sandboxclaims", name: claimName,
    });
    return true;
  } catch (e) {
    if (e?.code === 404) return false;
    throw e;
  }
}

// The node a pod runs on, and its IP, where session-bridge listens.
export async function podInfo(podName) {
  const pod = await core.readNamespacedPod({ name: podName, namespace: NAMESPACE });
  const labels = pod.metadata?.labels || {};
  return { node: pod.spec?.nodeName, podIP: pod.status?.podIP, app: labels.app, cli: labels["agent-cli"] };
}

// A durable record that a Delete could not confirm a session's clean stop, kept as a
// ConfigMap so it outlives the app process: until the pod it names is confirmed gone, every
// Delete of that session waits for it before removing the folder.
const pendingName = (session) => `pending-stop-${session}`;
export async function recordPendingStop(session, podName) {
  try {
    await core.createNamespacedConfigMap({ namespace: NAMESPACE, body: {
      metadata: { name: pendingName(session), labels: { "app.kubernetes.io/part-of": "coding-agents-for-developers" } },
      data: { pod: podName },
    } });
  } catch (e) {
    if (e?.code !== 409) throw e;
    // Already recorded by an earlier attempt: fine only if it names this same pod.
    const recorded = await pendingStopPod(session);
    if (recorded !== podName) {
      throw new Error(`an unconfirmed stop of pod ${recorded} is already recorded for this session`);
    }
  }
}
// The pod a pending-stop record names, or null when there is no record. A record without a
// pod name is an error, not "no record".
export async function pendingStopPod(session) {
  let cm;
  try {
    cm = await core.readNamespacedConfigMap({ name: pendingName(session), namespace: NAMESPACE });
  } catch (e) {
    if (e?.code === 404) return null;
    throw e;
  }
  if (!cm?.data?.pod) throw new Error(`the pending-stop record for this session names no pod`);
  return cm.data.pod;
}
export async function clearPendingStop(session) {
  try {
    await core.deleteNamespacedConfigMap({ name: pendingName(session), namespace: NAMESPACE });
  } catch (e) {
    if (e?.code !== 404) throw e;
  }
}

// The session record: one ConfigMap per session, the source of truth for the session list.
// A session's folder needs an access point only while a pod has it mounted, so the list
// cannot come from access points any more. Named for the session; labelled so the list for
// one developer is one paginated, label-selected ConfigMap list.
const PART_OF = "coding-agents-for-developers";
const recordName = (session) => `session-${session}`;
// The access point being deleted for this session, written to its record before the delete
// is asked for, so it survives an app restart: a Restore never reuses it, and waits for it
// to be gone before making a new one.
const DELETING_AP = "coding-agents/deleting-access-point";
const DELETING_AT = "coding-agents/deleting-since";
// Set when the developer pressed Delete: the session is gone from their list at once, and the
// app finishes the Delete in the background, again after an app restart if it has to.
const DELETE_REQUESTED = "coding-agents/delete-requested";
const recordOf = (cm) => cm?.data?.developer && cm.data.cli && cm.data.session
  ? {
      developer: cm.data.developer, cli: cm.data.cli, session: cm.data.session, created: cm.data.created,
      deletingAp: cm.metadata?.annotations?.[DELETING_AP] || null,
      deletingSince: Number(cm.metadata?.annotations?.[DELETING_AT]) || 0,
      deleteRequested: Boolean(cm.metadata?.annotations?.[DELETE_REQUESTED]),
    }
  : null;
const MERGE_PATCH = k8s.setHeaderOptions("Content-Type", k8s.PatchStrategy.MergePatch);

export async function markDeleteRequested(session) {
  await core.patchNamespacedConfigMap({
    name: recordName(session), namespace: NAMESPACE,
    body: { metadata: { annotations: { [DELETE_REQUESTED]: new Date().toISOString() } } },
  }, MERGE_PATCH);
}

export async function markAccessPointDeleting(session, apId) {
  await core.patchNamespacedConfigMap({
    name: recordName(session), namespace: NAMESPACE,
    body: { metadata: { annotations: { [DELETING_AP]: apId, [DELETING_AT]: String(Date.now()) } } },
  }, MERGE_PATCH);
}

// Clear the marker, only if it still names this access point.
export async function clearAccessPointDeleting(session, apId) {
  const rec = await readSessionRecord(session);
  if (!rec || rec.deletingAp !== apId) return;
  await core.patchNamespacedConfigMap({
    name: recordName(session), namespace: NAMESPACE,
    body: { metadata: { annotations: { [DELETING_AP]: null, [DELETING_AT]: null } } },
  }, MERGE_PATCH);
}

export async function createSessionRecord(developer, cli, session) {
  await core.createNamespacedConfigMap({ namespace: NAMESPACE, body: {
    metadata: {
      name: recordName(session),
      labels: {
        "app.kubernetes.io/part-of": PART_OF,
        "coding-agents/record": "session",
        "coding-agents/developer": developer,
        "coding-agents/cli": cli,
      },
    },
    data: { developer, cli, session, created: new Date().toISOString() },
  } });
}

// One session's record, or null when it has none. A record that is missing a field is an
// error, not "no session".
export async function readSessionRecord(session) {
  let cm;
  try {
    cm = await core.readNamespacedConfigMap({ name: recordName(session), namespace: NAMESPACE });
  } catch (e) {
    if (e?.code === 404) return null;
    throw e;
  }
  const rec = recordOf(cm);
  if (!rec || rec.session !== session) throw new Error(`the record for session ${session} is malformed`);
  return rec;
}

// Every session record, or one developer's: [{ developer, cli, session, created }].
export async function listSessionRecords(developer) {
  const selector = ["app.kubernetes.io/part-of=" + PART_OF, "coding-agents/record=session"];
  if (developer) selector.push(`coding-agents/developer=${developer}`);
  const out = [];
  let _continue;
  do {
    const page = await core.listNamespacedConfigMap({
      namespace: NAMESPACE, labelSelector: selector.join(","), limit: 500, _continue,
    });
    for (const cm of page?.items ?? []) {
      const rec = recordOf(cm);
      if (rec && cm.metadata?.name === recordName(rec.session)) out.push(rec);
    }
    _continue = page?.metadata?._continue;
  } while (_continue);
  return out;
}

// A delete that failed counts as done if the record is gone anyway (a timeout after it
// went through), so Delete does not report a failure for a session it did remove.
export async function deleteSessionRecord(session) {
  try {
    await core.deleteNamespacedConfigMap({ name: recordName(session), namespace: NAMESPACE });
  } catch (e) {
    if (e?.code === 404) return;
    let still;
    try { still = await readSessionRecord(session); } catch { throw e; }
    if (still) throw e;
  }
}

// Wait until a pod no longer exists (the API answers 404). Resolves true when it is gone,
// false when it is still there after timeoutMs. Any other error is thrown: "could not tell"
// is not "gone".
export async function waitPodGone(podName, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      await core.readNamespacedPod({ name: podName, namespace: NAMESPACE });
    } catch (e) {
      if (e?.code === 404) return true;
      throw e;
    }
    if (Date.now() >= deadline) return false;
    await new Promise((r) => setTimeout(r, 2000));
  }
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
// Whether the session's folder is still mounted in its pod. After a clean stop it is not
// (session-stop.sh unmounts it), even though the pod and its session-bridge are still there.
export async function workspaceMounted(podName) {
  const out = await execCapture(podName, ["/bin/sh", "-c", "mountpoint -q /workspace && echo mounted || echo unmounted"]);
  if (/^mounted/m.test(out)) return true;
  if (/^unmounted/m.test(out)) return false;
  throw new Error(`could not tell whether /workspace is mounted in ${podName}`);
}

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
// With wipe (Delete), it also empties the folder through the mount first.
export async function stopSession(podName, { wipe = false } = {}) {
  await execOnce(podName, ["/usr/local/bin/session-stop.sh", ...(wipe ? ["--wipe"] : [])]);
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
