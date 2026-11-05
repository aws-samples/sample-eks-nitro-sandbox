// Session lifecycle: New agent and Restore both claim a warm pod, mount the session's
// folder and start the CLI; close/idle release the pod and keep the folder; a background
// loop refreshes mount credentials and reaps idle sessions.

import { randomBytes } from "node:crypto";
import * as store from "./storage.js";
import * as k8s from "./k8s.js";
import * as bridge from "./bridge.js";
import { randomName, displayName } from "./names.js";

const IDLE_MS = (parseInt(process.env.IDLE_MINUTES, 10) || 30) * 60 * 1000;
const FS_ID = process.env.S3_FILES_FS_ID;
const REFRESH_MS = 30 * 60 * 1000; // refresh the 60-min credential well before expiry

// Live sessions keyed by session name: { developer, cli, session, apId, podName, podIP,
// claimName, azId, bridgeToken, bridgeCert, startedAt }. podIP, bridgeToken and bridgeCert
// are how the app reaches the pod's session-bridge (bridge.js).
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
  const { claimName, podName, node, podIP } = await k8s.claimPod(cli, session);
  console.log(`start ${session}: pod=${podName} node=${node}`);
  // A fresh token per session start: the pod's session-bridge accepts only this one.
  const bridgeToken = randomBytes(32).toString("hex");
  let azId, bridgeCert;
  try {
    azId = await k8s.nodeAzId(node);
    const credential = await store.mountCredential(ap.apId, developer, cli, session);
    console.log(`start ${session}: startSession azId=${azId}`);
    bridgeCert = await k8s.startSession(podName, { credential, bridgeToken, fsId: FS_ID, apId: ap.apId, azId, resume });
  } catch (e) {
    // The session never became live, so nothing else would release its pod. The folder
    // (access point) stays: the session shows in the list and Restore or Delete applies.
    console.error(`start ${session}: failed, releasing claim ${claimName}: ${e?.message || e}`);
    await k8s.releaseClaim(claimName).catch((re) =>
      console.error(`start ${session}: could not delete claim ${claimName}: ${re?.message || re}`));
    throw e;
  }

  const entry = {
    developer, cli, session, apId: ap.apId, claimName, podName, podIP, azId,
    bridgeToken, bridgeCert, startedAt: Date.now(),
  };
  live.set(session, entry);
  return entry;
}

// At app start: the app keeps running sessions in memory only, so after a restart every
// session left running (a browser closed, an agent working on its own) would otherwise
// never have its mount credential refreshed (its writes fail about an hour later) or be
// released when idle. Rebuild `live` from the sample's claims, resolving each claim's
// session to its developer, CLI and access point from the access-point paths, and reading
// each pod's session-bridge token and certificate back over exec (once per pod, at app
// start). The pod's current credential is of unknown age, so mark it due: the first loop
// pass refreshes it.
export async function adoptRunningSessions() {
  const claims = await k8s.listSessionClaims();
  if (claims.length === 0) return 0;
  const bySession = new Map((await store.listAllSessions()).map((s) => [s.session, s]));
  let adopted = 0;
  for (const { claimName, podName } of claims) {
    const session = claimName.replace(/^agent-/, "");
    const s = bySession.get(session);
    if (!s || live.has(session)) continue; // no access point: not a session folder we know
    try {
      const { node, podIP } = await k8s.podInfo(podName);
      const azId = await k8s.nodeAzId(node);
      const { token: bridgeToken, cert: bridgeCert } = await k8s.readBridge(podName);
      const now = Date.now();
      live.set(session, {
        developer: s.developer, cli: s.cli, session, apId: s.apId, claimName, podName, podIP, azId,
        bridgeToken, bridgeCert, startedAt: now, lastRefresh: now - REFRESH_MS - 1,
      });
      adopted++;
      console.log(`session ${session}: picked up after an app restart (pod ${podName})`);
    } catch (e) {
      console.error(`session ${session}: could not pick up pod ${podName} after a restart: ${e?.message || e}`);
    }
  }
  return adopted;
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
// credential before it expires. The idle check and the refresh are independent: a failed
// activity read must not skip the refresh, or a read that keeps failing would let the
// credential lapse. Failures are logged with the session name, never dropped. A failed
// refresh leaves lastRefresh unchanged, so it is retried on the next tick; the credential
// being replaced is valid for an hour and is refreshed after 30 minutes, so there are
// about 30 retries before the session's mount credential would lapse.
export async function backgroundTick(now = Date.now()) {
  for (const entry of [...live.values()]) {
    try {
      const last = (await bridge.lastActivity(entry)) * 1000;
      const idleFor = now - (last || entry.startedAt);
      if (idleFor > IDLE_MS) {
        try {
          await release(entry.session);
          console.log(`session ${entry.session}: released after ${Math.round(idleFor / 60000)} idle minutes`);
          continue;
        } catch (e) {
          console.error(`session ${entry.session} (pod ${entry.podName}): idle release failed, will retry next minute: ${e?.message || e}`);
        }
      }
    } catch (e) {
      console.error(`session ${entry.session} (pod ${entry.podName}): idle check failed, will retry next minute: ${e?.message || e}`);
    }
    // A session the idle check released is gone from the map; refresh only the ones still
    // tracked, whatever the idle check did.
    if (live.get(entry.session) !== entry) continue;
    if (now - (entry.lastRefresh || entry.startedAt) > REFRESH_MS) {
      try {
        const cred = await store.mountCredential(entry.apId, entry.developer, entry.cli, entry.session);
        await bridge.refreshCredential(entry, cred);
        entry.lastRefresh = now;
        console.log(`session ${entry.session}: mount credential refreshed`);
      } catch (e) {
        const age = Math.round((now - (entry.lastRefresh || entry.startedAt)) / 60000);
        console.error(
          `session ${entry.session} (pod ${entry.podName}): credential refresh failed, will retry next minute; ` +
          `credential age ${age} min: ${e?.message || e}`
        );
      }
    }
  }
}

export function startBackgroundLoop() {
  setInterval(() => { backgroundTick().catch((e) => console.error(`background loop: ${e?.message || e}`)); }, 60 * 1000).unref();
}
