// Session lifecycle: New agent and Restore both claim a warm pod, mount the session's
// folder and start the CLI; close/idle release the pod and keep the folder; a background
// loop refreshes mount credentials and reaps idle sessions.

import * as store from "./storage.js";
import * as k8s from "./k8s.js";
import { randomName, displayName } from "./names.js";

const IDLE_MS = (parseInt(process.env.IDLE_MINUTES, 10) || 30) * 60 * 1000;
const FS_ID = process.env.S3_FILES_FS_ID;
const REFRESH_MS = 30 * 60 * 1000; // refresh the 60-min credential well before expiry

// Live sessions keyed by session name: { developer, cli, session, apId, podName,
// claimName, azId, startedAt }.
const live = new Map();
// Exported only so a test can seed an entry and check release() keeps it on failure.
export const __liveForTest = live;

// New agent: generate a name, claim a pod, mount a fresh folder, start the CLI.
export async function newAgent(developer, cli) {
  const session = randomName();
  return start(developer, cli, session);
}

// Restore: same, on the existing folder; the CLI resumes its own conversation. Look up
// only THIS session's access point (not the whole list), so restore does not fan out a
// tag read over every session and trip the S3 Files API's request rate limit.
export async function restore(developer, session) {
  const cli = await store.sessionCli(developer, session);
  if (!cli) throw new Error(`no session ${session} for ${developer}`);
  return start(developer, cli, session, { resume: true });
}

async function start(developer, cli, session, { resume = false } = {}) {
  if (live.has(session)) return live.get(session);

  console.log(`start ${session}: ensureAccessPoint`);
  const ap = await store.ensureAccessPoint(developer, session, cli);
  console.log(`start ${session}: claimPod (ap=${ap.apId})`);
  const { claimName, podName, node } = await k8s.claimPod(cli, session);
  console.log(`start ${session}: pod=${podName} node=${node}`);
  let azId;
  try {
    azId = await k8s.nodeAzId(node);
    const credential = await store.mountCredential(ap.apId, developer, cli, session);
    console.log(`start ${session}: startSession azId=${azId}`);
    await k8s.startSession(podName, { credential, fsId: FS_ID, apId: ap.apId, azId, resume });
  } catch (e) {
    // The session never became live, so nothing else would release its pod. The folder
    // (access point) stays: the session shows in the list and Restore or Delete applies.
    console.error(`start ${session}: failed, releasing claim ${claimName}: ${e?.message || e}`);
    await k8s.releaseClaim(claimName).catch((re) =>
      console.error(`start ${session}: could not delete claim ${claimName}: ${re?.message || re}`));
    throw e;
  }

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
  let entry = live.get(session);
  if (!entry) {
    // The app keeps running sessions in memory only, so after an app restart a session can
    // still hold a claim and a pod the app has no record of. Look the pod up from the claim,
    // so Close (and idle, and Delete) still stop and release it instead of doing nothing.
    const claimName = k8s.claimNameFor(session);
    const podName = await k8s.claimedPodName(claimName);
    if (!podName) return; // no claim: nothing is running
    entry = { session, claimName, podName, adopted: true };
  }
  live.delete(session);
  // Stop the CLI and unmount the folder first, so its locks are released now rather than
  // when the NFS lease runs out. The pod is released either way: a failed stop is logged,
  // and the next Restore then waits out the lease (Codex) or may find a stale database.
  try {
    await k8s.stopSession(entry.podName);
    console.log(`session ${session}: stopped in ${entry.podName}`);
  } catch (e) {
    console.error(`session ${session}: clean stop in ${entry.podName} failed, releasing anyway: ${e?.message || e}`);
  }
  // If the claim cannot be deleted, the pod is still there: keep tracking the session, so
  // the background loop retries the release and the caller sees the error.
  try {
    await k8s.releaseClaim(entry.claimName);
  } catch (e) {
    // Keep tracking a session the app started, so the idle loop retries the release. One it
    // only looked up from its claim has no full record to track; the next Close retries it.
    if (!entry.adopted && !live.has(session)) live.set(session, entry);
    throw new Error(`could not delete claim ${entry.claimName}: ${e?.message || e}`);
  }
}

export async function listClosed(developer) {
  const all = await store.listSessions(developer);
  return all.map((s) => ({ ...s, display: displayName(s.session), running: live.has(s.session) }));
}

export async function remove(developer, session) {
  await release(session);
  // Also delete the claim by its name when the app holds no record of it (a start that
  // failed under an older app, or an app restart): Delete leaves no pod behind.
  await k8s.releaseClaim(k8s.claimNameFor(session));
  await store.deleteSession(developer, session);
}

// Background loop, every minute: release idle pods, and refresh each session's mount
// credential before it expires. Failures are logged with the session name, never dropped.
// A failed refresh leaves lastRefresh unchanged, so it is retried on the next tick; the
// credential being replaced is valid for an hour and is refreshed after 30 minutes, so
// there are about 30 retries before the session's mount credential would lapse.
export function startBackgroundLoop() {
  setInterval(async () => {
    const now = Date.now();
    for (const entry of [...live.values()]) {
      let step = "idle check";
      try {
        const last = (await k8s.lastActivity(entry.podName)) * 1000;
        const idleFor = now - (last || entry.startedAt);
        if (idleFor > IDLE_MS) {
          step = "idle release";
          await release(entry.session);
          console.log(`session ${entry.session}: released after ${Math.round(idleFor / 60000)} idle minutes`);
          continue;
        }
        if (now - (entry.lastRefresh || entry.startedAt) > REFRESH_MS) {
          step = "credential refresh";
          const cred = await store.mountCredential(entry.apId, entry.developer, entry.cli, entry.session);
          await k8s.refreshCredential(entry.podName, cred);
          entry.lastRefresh = now;
          console.log(`session ${entry.session}: mount credential refreshed`);
        }
      } catch (e) {
        const age = Math.round((now - (entry.lastRefresh || entry.startedAt)) / 60000);
        console.error(
          `session ${entry.session} (pod ${entry.podName}): ${step} failed, will retry next minute; ` +
          `credential age ${age} min: ${e?.message || e}`
        );
      }
    }
  }, 60 * 1000).unref();
}
