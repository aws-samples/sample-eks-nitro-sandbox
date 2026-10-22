// Session lifecycle: New agent and Restore both claim a warm pod, mount the session's
// folder and start the CLI; close/idle release the pod and keep the folder; a background
// loop refreshes mount credentials and reaps idle sessions.

import * as store from "./storage.js";
import * as k8s from "./k8s.js";
import { randomName } from "./names.js";

const IDLE_MS = (parseInt(process.env.IDLE_MINUTES, 10) || 30) * 60 * 1000;
const FS_ID = process.env.S3_FILES_FS_ID;
const REFRESH_MS = 30 * 60 * 1000; // refresh the 60-min credential well before expiry

// Live sessions keyed by session name: { developer, cli, session, apId, podName,
// claimName, azId, startedAt }.
const live = new Map();

// New agent: generate a name, claim a pod, mount a fresh folder, start the CLI.
export async function newAgent(developer, cli) {
  const session = randomName();
  return start(developer, cli, session);
}

// Restore: same, on the existing folder; the CLI resumes its own conversation.
export async function restore(developer, session) {
  const sessions = await store.listSessions(developer);
  const meta = sessions.find((s) => s.session === session);
  if (!meta) throw new Error(`no session ${session} for ${developer}`);
  return start(developer, meta.cli, session);
}

async function start(developer, cli, session) {
  if (live.has(session)) return live.get(session);

  console.log(`start ${session}: ensureAccessPoint`);
  const ap = await store.ensureAccessPoint(developer, session, cli);
  console.log(`start ${session}: claimPod (ap=${ap.apId})`);
  const { claimName, podName, node } = await k8s.claimPod(cli, session);
  console.log(`start ${session}: pod=${podName} node=${node}`);
  const azId = await k8s.nodeAzId(node);

  const credential = await store.mountCredential(ap.apId, developer, session);
  console.log(`start ${session}: startSession azId=${azId}`);
  await k8s.startSession(podName, { credential, fsId: FS_ID, apId: ap.apId, azId });

  const entry = {
    developer, cli, session, apId: ap.apId, claimName, podName, azId,
    startedAt: Date.now(),
  };
  live.set(session, entry);
  return entry;
}

export function getLive(session) {
  return live.get(session);
}

// Close or idle: release the claim (the pod goes, the folder stays). The session then
// shows in the developer's list and can be restored.
export async function release(session) {
  const entry = live.get(session);
  if (!entry) return;
  live.delete(session);
  await k8s.releaseClaim(entry.claimName);
}

export async function listClosed(developer) {
  const all = await store.listSessions(developer);
  return all.map((s) => ({ ...s, running: live.has(s.session) }));
}

export async function remove(developer, session) {
  await release(session);
  await store.deleteSession(developer, session);
}

// Background loop: refresh credentials, release idle pods.
export function startBackgroundLoop() {
  setInterval(async () => {
    const now = Date.now();
    for (const entry of [...live.values()]) {
      try {
        const last = (await k8s.lastActivity(entry.podName)) * 1000;
        const idleFor = now - (last || entry.startedAt);
        if (idleFor > IDLE_MS) {
          await release(entry.session);
          continue;
        }
        if (now - (entry.lastRefresh || entry.startedAt) > REFRESH_MS) {
          const cred = await store.mountCredential(entry.apId, entry.developer, entry.session);
          await k8s.refreshCredential(entry.podName, cred);
          entry.lastRefresh = now;
        }
      } catch {
        // A pod that has gone (node drained, crashed) is dropped from the live set on
        // the next claim attempt; the folder is intact for restore.
      }
    }
  }, 60 * 1000).unref();
}
