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

// The CLI of one of this developer's sessions, from its session record; undefined when the
// developer has no such session.
async function sessionCli(developer, session) {
  const rec = await k8s.readSessionRecord(session);
  return rec && rec.developer === developer ? rec.cli : undefined;
}

// Restore: same, on the existing folder; the CLI resumes its own conversation.
export async function restore(developer, session) {
  const cli = await sessionCli(developer, session);
  if (!cli) throw new Error(`no session ${session} for ${developer}`);
  return start(developer, cli, session, { resume: true });
}

// Starts in flight, keyed by session. A second Restore of the same session (a double click,
// a second tab) waits for the first instead of starting again with a second bridge token
// against the same claim and pod.
const starting = new Map();

// One queue per session: a start, a Close, a Delete and a release by the background loop
// of the same session run one after another, never side by side. Without it a Restore
// could begin while a Close was still stopping the old pod, two releases could both run
// session-stop.sh in one pod, and a Close could delete the claim under a Restore's new pod.
// Different sessions do not wait for each other.
const queues = new Map();
function serialized(session, fn) {
  const run = (queues.get(session) || Promise.resolve()).then(fn);
  const tail = run.then(() => {}, () => {});
  queues.set(session, tail);
  tail.then(() => { if (queues.get(session) === tail) queues.delete(session); });
  return run;
}

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
    .then(() => serialized(session, () => (reuse && live.get(session)) || startOnce(developer, cli, session, opts)))
    .finally(() => starting.delete(session));
  starting.set(session, p);
  return p;
}

async function startOnce(developer, cli, session, { resume = false } = {}) {
  // A Restore waits its turn behind a Delete of the same session; look the session up again
  // now, so it does not create the folder that Delete just removed.
  if (resume && !(await sessionCli(developer, session))) throw new Error(`no session ${session} for ${developer}`);
  // A failed clean stop of the session's last pod left a record. Start a new pod only once
  // that one is confirmed gone; otherwise two pods could have the folder.
  if (resume) {
    const pending = await k8s.pendingStopPod(session);
    if (pending) {
      if (!(await k8s.waitPodGone(pending, 10000))) {
        throw new Error(`the session's previous pod ${pending} is not confirmed stopped yet; try again in a minute, or Delete the session`);
      }
      await k8s.clearPendingStop(session);
    }
  }

  // A new session gets its record first: from here on it is listed, so whatever happens
  // next, Restore or Delete applies to it.
  if (!resume) await k8s.createSessionRecord(developer, cli, session);

  // The access point and the warm pod do not depend on each other until the mount, so ask
  // for both at once: creating the access point adds nothing to the time a Restore takes.
  console.log(`start ${session}: ensureAccessPoint + claimPod`);
  const [apResult, podResult] = await Promise.allSettled([
    store.ensureAccessPoint(developer, session, cli),
    k8s.claimPod(cli, session),
  ]);
  if (podResult.status === "rejected") {
    // No pod: an access point created for it is left for the sweep, which deletes the access
    // point of any session with no pod.
    throw podResult.reason;
  }
  const { claimName, podName, node, podIP } = podResult.value;
  if (apResult.status === "rejected") {
    // No access point, so this start mounts nothing. But the claim may be one an earlier
    // start left behind (claimPod adopts an existing claim), whose pod may still have the
    // folder mounted: release it the way a failed start does, never by deleting the claim
    // outright.
    console.error(`start ${session}: no access point, releasing claim ${claimName}: ${apResult.reason?.message || apResult.reason}`);
    cleanUpFailedStart(session, claimName, podName);
    throw apResult.reason;
  }
  const ap = apResult.value;
  console.log(`start ${session}: pod=${podName} node=${node} ap=${ap.apId}`);
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
    // The clean stop can take a minute or more, so the error goes back to the developer now
    // and the clean up runs next in the session's queue: a Restore clicked meanwhile waits
    // for it. It stops the pod only if the claim still points at it.
    console.error(`start ${session}: failed, releasing claim ${claimName}: ${e?.message || e}`);
    cleanUpFailedStart(session, claimName, podName);
    throw e;
  }

  const entry = {
    developer, cli, session, apId: ap.apId, claimName, podName, podIP, azId,
    bridgeToken, bridgeCert, startedAt: Date.now(),
  };
  live.set(session, entry);
  return entry;
}

// The clean up after a start that failed with a claim: queued next in the session's queue,
// so the error goes back to the developer at once and a Restore clicked meanwhile waits for
// it. It stops the claim's pod cleanly and releases the claim, only if the claim still points
// at that pod; a failed stop is recorded first, or the claim is kept.
function cleanUpFailedStart(session, claimName, podName) {
    serialized(session, async () => {
      // If the claim cannot be read, or no longer points at this pod, leave it: a later
      // Close or Delete finds the claim and stops whatever pod it has.
      let current;
      try {
        current = await k8s.claimedPodName(claimName);
      } catch (le) {
        console.error(`start ${session}: could not read claim ${claimName}, keeping it: ${le?.message || le}`);
        return;
      }
      if (current !== podName) {
        console.error(`start ${session}: claim ${claimName} no longer points at ${podName}, leaving it`);
        return;
      }
      try {
        await k8s.stopSession(podName);
      } catch (se) {
        console.error(`start ${session}: clean stop in ${podName} failed, releasing anyway: ${se?.message || se}`);
        // As for any failed stop: record the pod, or keep its claim if that fails.
        try { await k8s.recordPendingStop(session, podName); } catch (re) {
          console.error(`start ${session}: could not record the failed stop, keeping claim ${claimName}: ${re?.message || re}`);
          return;
        }
      }
      try {
        await k8s.releaseClaim(claimName);
      } catch (re) {
        console.error(`start ${session}: could not delete claim ${claimName}: ${re?.message || re}`);
        return;
      }
      console.log(`start ${session}: cleaned up after the failed start`);
    });
}

// At app start: the app keeps running sessions in memory only, so after a restart every
// session left running (a browser closed, an agent working on its own) would otherwise
// never have its mount credential refreshed (its writes fail about an hour later) or be
// released when idle. Rebuild `live` from the sample's claims, resolving each claim's
// session to its developer and CLI from its session record and to its access point from
// the access-point paths, and reading
// each pod's session-bridge token and certificate back over exec (once per pod, at app
// start). The pod's current credential is of unknown age, so mark it due: the first loop
// pass refreshes it.
// Once per app process: a second call returns the same pick-up. The gate is set before the
// pick-up's first await, so anything that runs after this call waits for it.
// If the pick-up fails (a list call failed), the background loop runs it again: it sets
// pickUpFailed, and the next tick starts a new pick-up, which anything new waits for.
let pickUpFailed = false;
export function adoptRunningSessions() {
  if (!pickUp) {
    pickUp = Promise.resolve().then(pickUpRunningSessions).catch((e) => { pickUpFailed = true; throw e; });
  }
  return pickUp;
}

// An install from before session records kept every session as an access point only. Give
// each such session a record, so it stays in its developer's list; the sweep then deletes
// the access point of every one that has no pod. Runs in the pick-up and again on every
// sweep, so a record that could not be written is written later. Returns `records` with
// every such session added, written or not: its developer and CLI come from the path.
async function recordFromAccessPoints(aps, records) {
  for (const a of aps) {
    if (records.has(a.session) || !isSessionName(a.session)) continue;
    let ok = true;
    try {
      await k8s.createSessionRecord(a.developer, a.cli, a.session);
    } catch (e) {
      // 409: it exists. Any other error may still have created it (a timeout): read it back.
      if (e?.code !== 409 && !(await k8s.readSessionRecord(a.session).catch(() => null))) {
        ok = false;
        console.error(`session ${a.session}: could not create its record, will retry next minute: ${e?.message || e}`);
      }
    }
    records.set(a.session, { developer: a.developer, cli: a.cli, session: a.session, unrecorded: !ok });
    if (ok) console.log(`session ${a.session}: recorded from its access point`);
  }
  return records;
}

async function pickUpRunningSessions() {
  const aps = await store.listAllAccessPoints();
  const records = await recordFromAccessPoints(aps, new Map((await k8s.listSessionRecords()).map((r) => [r.session, r])));
  const claims = await k8s.listSessionClaims();
  if (claims.length === 0) return 0;
  const apIds = new Map(aps.map((a) => [a.session, a.apId]));
  const bySession = new Map([...records].filter(([s]) => apIds.has(s)).map(([s, r]) => [s, { ...r, apId: apIds.get(s) }]));
  let adopted = 0;
  // Independently and a few at a time, so one pod that cannot be read (an image from before
  // session-bridge, a pod going away) does not hold up the others for its exec timeout.
  await eachLimited(claims, TICK_CONCURRENCY, async ({ claimName, podName }) => {
    // Only a claim named the way claimPod names one, for a well-formed session name.
    if (!claimName.startsWith("agent-")) return;
    const session = claimName.slice("agent-".length);
    if (!isSessionName(session) || k8s.claimNameFor(session) !== claimName) return;
    const s = bySession.get(session);
    // No record, or no access point: not a running session we can pick up. A pod without an
    // access point has nothing mounted that the app can refresh; Close or Delete still
    // releases it, from its claim.
    if (!s || live.has(session)) return;
    // In the session's queue: a pick-up the background loop runs again (after one that failed)
    // can overlap requests already past afterPickUp, and must not interleave with them.
    await serialized(session, async () => {
    if (live.has(session)) return;
    try {
      const { node, podIP, app, cli } = await k8s.podInfo(podName);
      // Only a session pod made from this CLI's template: its labels are the ones the network
      // policy selects on, and the CLI is the one the session's folder was made for.
      if (app !== "agent-session" || cli !== s.cli) {
        console.error(`session ${session}: not picking up pod ${podName}: labels app=${app} agent-cli=${cli}, expected agent-session and ${s.cli}`);
        return;
      }
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
  return serialized(session, () => releaseNow(session));
}

async function releaseNow(session, { wipe = false } = {}) {
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
  // For Delete (wipe), a failed stop is also returned, so Delete stops there.
  let stopError = null;
  try {
    await k8s.stopSession(entry.podName, { wipe });
    console.log(`session ${session}: stopped in ${entry.podName}${wipe ? ", folder emptied" : ""}`);
  } catch (e) {
    stopError = e;
    console.error(`session ${session}: clean stop in ${entry.podName} failed, releasing anyway: ${e?.message || e}`);
  }
  // A failed clean stop (Close, idle, Delete) leaves a pod that may still have the folder
  // mounted until it is gone. Record it before its claim goes: the next Restore does not
  // start a pod, and no Delete removes the folder, until that pod is confirmed gone, whatever
  // happens to the app in between. If the record cannot be written, keep the claim.
  if (stopError) {
    try {
      await k8s.recordPendingStop(session, entry.podName);
    } catch (re) {
      if (!entry.adopted && !live.has(session)) live.set(session, entry);
      throw new Error(`the session's clean stop failed and could not be recorded, so nothing was released: ${re?.message || re}`);
    }
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
  // The pod is going and nothing else has the folder mounted, so the session no longer needs
  // an access point. After a failed stop the pod may still have it mounted until it is gone:
  // keep the access point then, and the sweep deletes it once the pending-stop record clears.
  // A delete that fails is logged and left to the sweep too; the session is released either
  // way.
  if (!stopError) await releaseAccessPointOf(session, entry.developer);
  return { podName: entry.podName, stopError };
}

async function releaseAccessPointOf(session, developer) {
  try {
    const dev = developer || (await k8s.readSessionRecord(session))?.developer;
    if (dev && (await store.releaseAccessPoint(dev, session))) console.log(`session ${session}: access point deleted`);
  } catch (e) {
    console.error(`session ${session}: could not delete its access point, the sweep retries: ${e?.message || e}`);
  }
}

// The sweep, once a minute: delete the access point of every recorded session that has no
// pod. That is the retry for an access-point delete that failed after a release, for a
// release an app restart cut short, and for an install from before session records, whose
// closed sessions each held one. A session counts as possibly mounted, and keeps its access
// point, while the app tracks it, a start is in flight, any claim for it exists (with or
// without a pod), or a failed stop of its last pod is recorded. Each delete runs in the
// session's own queue and checks again there, so it never runs beside a start or a release.
// One listing of access points, records and claims per sweep, then one record read, one
// claim read and one delete per idle access point, SWEEP_CONCURRENCY at a time: the work
// grows with the number of idle access points, not with its square.
const SWEEP_CONCURRENCY = 8;
async function sweepAccessPoints() {
  const aps = await store.listAllAccessPoints();
  await recordFromAccessPoints(aps, new Map((await k8s.listSessionRecords()).map((r) => [r.session, r])));
  const idle = aps.filter((a) => !live.has(a.session) && !starting.has(a.session));
  if (idle.length === 0) return;
  const claims = await k8s.listClaimNames();
  await eachLimited(idle.filter((a) => !claims.has(k8s.claimNameFor(a.session))), SWEEP_CONCURRENCY, (a) =>
    serialized(a.session, async () => {
      if (live.has(a.session) || starting.has(a.session)) return;
      if (!(await k8s.readSessionRecord(a.session))) return; // not a session the app knows
      // After a failed stop, the recorded pod may still have the folder mounted. Once it is
      // confirmed gone the record has done its job: clear it here, so a closed session does
      // not hold its access point until its next Restore or Delete.
      const pending = await k8s.pendingStopPod(a.session);
      if (pending) {
        if (!(await k8s.waitPodGone(pending, 0))) return;
        await k8s.clearPendingStop(a.session);
      }
      if (await k8s.claimExists(k8s.claimNameFor(a.session))) return;
      await store.deleteAccessPoint(a.apId, a.status);
      console.log(`session ${a.session}: access point deleted, the session has no pod`);
    }).catch((e) => console.error(`session ${a.session}: access-point sweep: ${e?.message || e}`)));
}

// The developer's sessions, from their records. A session name starts with its creation
// time in base 36, so sorting by name lists the newest first.
export async function listClosed(developer) {
  const all = await k8s.listSessionRecords(developer);
  return all
    .sort((x, y) => y.session.localeCompare(x.session))
    .map((s) => ({ session: s.session, cli: s.cli, display: displayName(s.session), running: live.has(s.session) }));
}

// Delete: release, then remove the folder, as one step in the session's queue, so no
// Restore can start the session between the two.
export async function remove(developer, session) {
  await afterPickUp();
  return serialized(session, async () => {
    const rec = await k8s.readSessionRecord(session);
    if (!rec || rec.developer !== developer) return; // no such session: nothing to delete
    // Empty the folder through the mount while the pod still has it: a file written in the
    // last minute has not been exported yet, and removed now it never is.
    const stopped = await releaseNow(session, { wipe: true });
    // Also delete the claim by its name when the app holds no record of it (a start that
    // failed under an older app, or an app restart): Delete leaves no pod behind.
    await k8s.releaseClaim(k8s.claimNameFor(session));
    // If a clean stop and wipe could not be confirmed, now or on an earlier Delete, the
    // folder may still hold files and that pod may still have it mounted. Go on only once
    // the recorded pod is gone: then nothing can write the folder, and the drain below
    // removes what S3 Files exports from it. Otherwise keep the folder and the record.
    const pending = await k8s.pendingStopPod(session);
    if (pending) {
      if (!(await k8s.waitPodGone(pending))) {
        throw new Error(`the session's pod ${pending} could not be confirmed stopped, so the folder was kept; ` +
          `try Delete again in a minute${stopped?.stopError ? ` (${stopped.stopError?.message || stopped.stopError})` : ""}`);
      }
      await k8s.clearPendingStop(session);
    }
    await store.deleteSession(developer, rec.cli, session);
    // The record goes last, so a Delete that fails before here leaves the session listed.
    await k8s.deleteSessionRecord(session);
  });
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
// releasing by name then would release the new session. It waits its turn in the session's
// queue and checks the entry there, so a Close or Restore queued ahead of it has finished.
function releaseIfCurrent(entry) {
  return serialized(entry.session, async () => {
    if (live.get(entry.session) !== entry || starting.has(entry.session)) return false;
    await releaseNow(entry.session);
    return true;
  });
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
    // The pod restarts a bridge that exited, with a new certificate. From the second failure
    // on, read the bridge back over exec and pin its new certificate if it changed; the next
    // check then reaches it. Every failure until the release tries again, so one failed read
    // does not release a session whose bridge came back.
    if (entry.bridgeFailures >= 2 && entry.bridgeFailures < BRIDGE_FAIL_LIMIT) {
      try {
        const { token, cert } = await k8s.readBridge(entry.podName);
        if (live.get(entry.session) === entry && token === entry.bridgeToken && cert !== entry.bridgeCert) {
          entry.bridgeCert = cert;
          console.log(`session ${entry.session}: session-bridge restarted in ${entry.podName}; pinned its new certificate`);
        }
      } catch (re) {
        console.error(`session ${entry.session}: could not read session-bridge back from ${entry.podName}: ${re?.message || re}`);
      }
    }
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

export async function checkTick(now = Date.now()) {
  await eachLimited(live.values(), TICK_CONCURRENCY, (entry) => checkSession(entry, now));
}

// The pick-up again if it failed, then the access-point sweep. Only once a pick-up has
// finished, so a running session it has not reached yet is never taken for one with no pod
// (its claim protects it too).
export async function sweepTick() {
  if (!pickUp) return;
  await pickUp.catch(() => {});
  if (pickUpFailed) {
    pickUpFailed = false;
    pickUp = null;
    console.error("picking up running sessions again: the last pick-up failed");
    await adoptRunningSessions().catch((e) => console.error(`pick-up failed again, will retry next minute: ${e?.message || e}`));
    if (pickUpFailed) return;
  }
  await sweepAccessPoints().catch((e) => console.error(`access-point sweep: ${e?.message || e}`));
}

export async function backgroundTick(now = Date.now()) {
  await checkTick(now);
  await sweepTick();
}

// Two loops, each a minute after its own last pass ends: the idle check and credential
// refresh, and the sweep. Separate, so a long sweep (an upgrade with many closed sessions)
// does not hold up any running session's refresh.
export function startBackgroundLoop() {
  const every = (name, fn) => {
    const run = () => fn()
      .catch((e) => console.error(`${name}: ${e?.message || e}`))
      .finally(() => setTimeout(run, 60 * 1000).unref());
    setTimeout(run, 60 * 1000).unref();
  };
  every("background loop", () => checkTick());
  every("access-point sweep", () => sweepTick());
}
