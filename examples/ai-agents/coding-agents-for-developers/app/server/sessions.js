// Session lifecycle: New agent and Restore both claim a warm pod, mount the session's
// folder and start the CLI; close/idle release the pod and keep the folder; a background
// loop refreshes mount credentials and reaps idle sessions.

import { randomBytes } from "node:crypto";
import * as store from "./storage.js";
import * as k8s from "./k8s.js";
import * as bridge from "./bridge.js";
import { randomName, displayName, isSessionName } from "./names.js";

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
// A new session never reuses a running entry, even in the unlikely case that its random
// name matches one: it waits for the pick-up, then takes a name nothing is using.
export async function newAgent(developer, cli) {
  await afterPickUp();
  let session = randomName();
  while (live.has(session) || starting.has(session)) session = randomName();
  return start(developer, cli, session, { reuse: false });
}

// Restore: same, on the existing folder; the CLI resumes its own conversation. Look up
// only THIS session's access point (not the whole list), so restore does not fan out a
// tag read over every session and trip the S3 Files API's request rate limit.
export async function restore(developer, session) {
  const cli = await store.sessionCli(developer, session);
  if (!cli) throw new Error(`no session ${session} for ${developer}`);
  return start(developer, cli, session, { resume: true });
}

// Starts in flight, keyed by session. A second Restore of the same session (a double click,
// a second tab) waits for the first instead of starting again with a second bridge token
// against the same claim and pod.
const starting = new Map();

// The app-start pick-up of running sessions (adoptRunningSessions), run once. New agent,
// Restore, Close and Delete all wait for it, so none of them runs side by side with it: a
// Restore that arrives while the pick-up is still reading pods starts after it, and gets
// the session it picked up, if it found one. The wait is bounded: if the pick-up is still
// running after PICKUP_WAIT_MS, the request fails with a retry message instead of hanging.
let pickUp = null;
const PICKUP_WAIT_MS = parseInt(process.env.PICKUP_WAIT_MS, 10) || 90 * 1000;

async function afterPickUp() {
  if (!pickUp) return;
  let timer;
  const done = await Promise.race([
    pickUp.then(() => true, () => true),
    new Promise((r) => { timer = setTimeout(() => r(false), PICKUP_WAIT_MS); }),
  ]);
  clearTimeout(timer);
  if (!done) throw new Error("the app is still picking up running sessions after a restart; try again in a minute");
}

function start(developer, cli, session, { reuse = true, ...opts } = {}) {
  if (reuse && live.has(session)) return Promise.resolve(live.get(session));
  if (starting.has(session)) return starting.get(session);
  const p = afterPickUp()
    .then(() => (reuse && live.get(session)) || startOnce(developer, cli, session, opts))
    .finally(() => starting.delete(session));
  starting.set(session, p);
  return p;
}

async function startOnce(developer, cli, session, { resume = false } = {}) {

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
    // The entrypoint may have got as far as mounting the folder and starting the CLI (an
    // image without session-bridge does, then fails here), so stop it cleanly first, as
    // Close does, before the pod goes: its locks on the folder are released now.
    console.error(`start ${session}: failed, releasing claim ${claimName}: ${e?.message || e}`);
    await k8s.stopSession(podName).catch((se) =>
      console.error(`start ${session}: clean stop in ${podName} failed, releasing anyway: ${se?.message || se}`));
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
// Once per app process: a second call returns the same pick-up. The gate is set before the
// pick-up's first await, so anything that runs after this call waits for it.
export function adoptRunningSessions() {
  if (!pickUp) pickUp = Promise.resolve().then(pickUpRunningSessions);
  return pickUp;
}

async function pickUpRunningSessions() {
  const claims = await k8s.listSessionClaims();
  if (claims.length === 0) return 0;
  const bySession = new Map((await store.listAllSessions()).map((s) => [s.session, s]));
  let adopted = 0;
  // Independently and a few at a time, so one pod that cannot be read (an image from before
  // session-bridge, a pod going away) does not hold up the others for its exec timeout.
  await eachLimited(claims, TICK_CONCURRENCY, async ({ claimName, podName }) => {
    // Only a claim named the way claimPod names one, for a well-formed session name.
    if (!claimName.startsWith("agent-")) return;
    const session = claimName.slice("agent-".length);
    if (!isSessionName(session) || k8s.claimNameFor(session) !== claimName) return;
    const s = bySession.get(session);
    if (!s || live.has(session)) return; // no access point: not a session folder we know
    try {
      const { node, podIP } = await k8s.podInfo(podName);
      const azId = await k8s.nodeAzId(node);
      const { token: bridgeToken, cert: bridgeCert } = await k8s.readBridge(podName);
      // No start, Close or Delete runs while the pick-up does (they wait for it), but the
      // claim can still change outside the app (someone deletes it by hand): pick up the
      // pod only if the claim still points at it. Never overwrite an entry.
      if ((await k8s.claimedPodName(claimName)) !== podName) return;
      if (live.has(session)) return;
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
  });
  return adopted;
}

export function getLive(session) {
  return live.get(session);
}

// Close or idle: release the claim (the pod goes, the folder stays). The session then
// shows in the developer's list and can be restored.
// Close (and Delete, through remove) wait for the app-start pick-up, so a pick-up still
// reading pods cannot put back a session they are ending. The background loop releases
// through releaseNow directly: it checks the entry and releases with no await between.
export async function release(session) {
  await afterPickUp();
  return releaseNow(session);
}

async function releaseNow(session) {
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
  await release(session); // waits for the pick-up
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
//
// Sessions are checked independently, TICK_CONCURRENCY at a time, so one slow or dead
// bridge (each call is bounded at 10 s) does not hold up the others; and the next tick is
// scheduled only after this one has finished, so ticks never overlap.
//
// A bridge that does not answer the activity read for BRIDGE_FAIL_LIMIT ticks in a row
// (it exited, or the claim's pod is gone) leaves a session the app can no longer reach:
// no terminal, no refresh, and it would never go idle. Release it, as idle does; the folder
// stays, and Restore brings the session back on a new pod.
const TICK_CONCURRENCY = 8;
const BRIDGE_FAIL_LIMIT = parseInt(process.env.BRIDGE_FAIL_LIMIT, 10) || 5;

// Release a session from the background loop only if this entry is still the one the app
// tracks for it. A check that started before a Close and a new Restore holds the old entry;
// releasing by name then would release the new session.
async function releaseIfCurrent(entry) {
  if (live.get(entry.session) !== entry || starting.has(entry.session)) return false;
  await releaseNow(entry.session);
  return true;
}

async function checkSession(entry, now) {
  try {
    const last = (await bridge.lastActivity(entry)) * 1000;
    entry.bridgeFailures = 0;
    const idleFor = now - (last || entry.startedAt);
    if (idleFor > IDLE_MS) {
      try {
        if (!(await releaseIfCurrent(entry))) return;
        console.log(`session ${entry.session}: released after ${Math.round(idleFor / 60000)} idle minutes`);
        return;
      } catch (e) {
        console.error(`session ${entry.session} (pod ${entry.podName}): idle release failed, will retry next minute: ${e?.message || e}`);
      }
    }
  } catch (e) {
    entry.bridgeFailures = (entry.bridgeFailures || 0) + 1;
    console.error(`session ${entry.session} (pod ${entry.podName}): idle check failed ` +
      `(${entry.bridgeFailures} in a row), will retry next minute: ${e?.message || e}`);
    if (entry.bridgeFailures >= BRIDGE_FAIL_LIMIT) {
      try {
        if (!(await releaseIfCurrent(entry))) return;
        console.log(`session ${entry.session}: released, its session-bridge did not answer ${entry.bridgeFailures} times in a row`);
        return;
      } catch (re) {
        console.error(`session ${entry.session}: release after bridge failures failed, will retry next minute: ${re?.message || re}`);
      }
    }
  }
  // A session the idle check released is gone from the map; refresh only the ones still
  // tracked, whatever the idle check did.
  if (live.get(entry.session) !== entry) return;
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

// Run fn over items, at most `limit` at a time; every item runs, whatever the others do.
async function eachLimited(items, limit, fn) {
  const queue = [...items];
  const worker = async () => { while (queue.length) await fn(queue.shift()).catch(() => {}); };
  await Promise.all(Array.from({ length: Math.min(limit, queue.length) }, worker));
}

export async function backgroundTick(now = Date.now()) {
  await eachLimited(live.values(), TICK_CONCURRENCY, (entry) => checkSession(entry, now));
}

export function startBackgroundLoop() {
  const tick = () => backgroundTick()
    .catch((e) => console.error(`background loop: ${e?.message || e}`))
    .finally(() => setTimeout(tick, 60 * 1000).unref());
  setTimeout(tick, 60 * 1000).unref();
}
