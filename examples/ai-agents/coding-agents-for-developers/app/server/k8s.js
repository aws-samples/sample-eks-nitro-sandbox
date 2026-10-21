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
export async function claimPod(cli, session) {
  const claimName = `agent-${session}`.slice(0, 63);
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

  // Wait for the claim to resolve to a sandbox (adopts an already-running warm pod,
  // Ready in under a second).
  const podName = await waitForClaimPod(claimName);
  const pod = await core.readNamespacedPod({ name: podName, namespace: NAMESPACE });
  return { claimName, podName, node: pod.spec?.nodeName };
}

async function waitForClaimPod(claimName, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const claim = await custom.getNamespacedCustomObject({
      group: GROUP, version: VERSION, namespace: NAMESPACE,
      plural: "sandboxclaims", name: claimName,
    });
    const name = claim?.status?.sandbox?.name;
    if (name) return name;
    await sleep(250);
  }
  throw new Error(`claim ${claimName} did not resolve to a sandbox in time`);
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

// Start the session: the credential body goes in on stdin, the session parameters as the
// command's environment, and the pod's entrypoint mounts the access point and starts the
// CLI in tmux. Runs once per session; the long-lived process is the pod's own.
export async function startSession(podName, { credential, fsId, apId, azId }) {
  const script =
    `export S3_FILES_FS_ID=${fsId} S3_FILES_AP_ID=${apId} ` +
    `AWS_REGION=${REGION} POD_AZ_ID=${azId}; ` +
    // The entrypoint reads the credential on stdin; re-exec it here with the env set.
    `exec /usr/local/bin/session-entrypoint.sh`;
  await execOnce(podName, ["/bin/sh", "-c", script], credential);
}

// Refresh the mount credential before it expires: write the new body into the pod's
// tmpfs credential file. The mount helper re-reads it for its periodic re-auth.
export async function refreshCredential(podName, credential) {
  await execOnce(
    podName,
    ["/bin/sh", "-c", "cat > /dev/shm/session/credentials && chmod 600 /dev/shm/session/credentials"],
    credential
  );
}

// tmux last-activity epoch, to find idle sessions.
export async function lastActivity(podName) {
  const out = await execCapture(podName, [
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
  const ws = await exec.exec(
    NAMESPACE, podName, "agent",
    ["/bin/sh", "-c", `exec tmux attach -t agent`],
    stdout, stdout, stdin, true,
  );
  return {
    write: (data) => stdin.push(data),
    resize: (c, r) => ws?.send?.(JSON.stringify({ Width: c, Height: r })),
    close: () => { try { ws?.close?.(); } catch {} },
  };
}

// --- exec helpers ---
function execOnce(podName, command, stdinBody) {
  return new Promise((resolve, reject) => {
    const stdin = new Readable({ read() {} });
    let err = "";
    const stderr = new Writable({ write(c, _e, cb) { err += c.toString(); cb(); } });
    exec
      .exec(NAMESPACE, podName, "agent", command, null, stderr, stdin, false,
        (status) => (status?.status === "Success" ? resolve() : reject(new Error(err || status?.message))))
      .then(() => { if (stdinBody) stdin.push(stdinBody); stdin.push(null); })
      .catch(reject);
  });
}

function execCapture(podName, command) {
  return new Promise((resolve, reject) => {
    let out = "";
    const stdout = new Writable({ write(c, _e, cb) { out += c.toString(); cb(); } });
    exec
      .exec(NAMESPACE, podName, "agent", command, stdout, stdout, null, false,
        (status) => (status?.status === "Success" ? resolve(out) : resolve(out)))
      .catch(reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
