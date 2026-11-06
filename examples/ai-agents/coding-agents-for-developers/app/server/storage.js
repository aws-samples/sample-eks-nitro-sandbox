// S3 Files per-session storage: create a session's access point when a pod mounts its
// folder and delete it when the pod goes, mint a short-lived credential scoped to it, and
// delete a session's data. A session's folder outlives its access points: deleting an
// access point leaves the directory and its files, and a new one on the same path sees
// them again (shown on a live run). So a session holds an access point only while it runs,
// starts, or waits for the clean up after its pod, and the S3 Files quota of 25,000 access
// points per file system bounds those, not retained sessions. The session list comes from
// the session records (k8s.js).
//
// The security property proven live: the Mount role grants ClientMount/ClientWrite on the
// file system, and this module narrows each session's credential with an STS session
// policy conditioned on s3files:AccessPointArn, so a session's credential can mount only
// its own access point. The first credential is handed to the pod through exec stdin at
// session start (see k8s.js and the base image's session-entrypoint.sh), and each refresh
// through the pod's session-bridge over TLS (bridge.js); it never appears on a command line.

import {
  S3FilesClient,
  CreateAccessPointCommand,
  DeleteAccessPointCommand,
  ListAccessPointsCommand,
} from "@aws-sdk/client-s3files";
import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";

const REGION = process.env.AWS_REGION;
const FS_ID = process.env.S3_FILES_FS_ID;
const BUCKET = process.env.S3_BUCKET_NAME;
const PREFIX = process.env.S3_PREFIX; // e.g. "coding-agents"
const MOUNT_ROLE_ARN = process.env.MOUNT_ROLE_ARN;

// Adaptive retry with a generous attempt budget: the S3 Files control-plane API rate-
// limits per account, and listing access points plus reading their tags can brush that
// limit when many sessions exist. Adaptive mode backs off and retries on throttling
// instead of surfacing a 500 to the user.
const retry = { maxAttempts: 8, retryMode: "adaptive" };
const s3files = new S3FilesClient({ region: REGION, ...retry });
const sts = new STSClient({ region: REGION, ...retry });

const accountIdFromArn = (arn) => arn.split(":")[4];
const ACCOUNT_ID = accountIdFromArn(MOUNT_ROLE_ARN);

// An access point's root path and the S3 prefix share the same shape. The path carries
// the developer, the CLI and the session name, so the app can match a running session to
// its access point, and the sweep can find every access point's session, from one
// ListAccessPoints listing with no per-access-point tag read (which at scale would hit the
// S3 Files control-plane rate limit).
//   access point root:  /<developer>/<cli>/<session>
//   bucket key prefix:   <PREFIX>/<developer>/<cli>/<session>/
export const sessionRoot = (developer, cli, session) => `/${developer}/${cli}/${session}`;
export const sessionKeyPrefix = (developer, cli, session) =>
  `${PREFIX}/${developer}/${cli}/${session}`;

export const accessPointArn = (apId) =>
  `arn:aws:s3files:${REGION}:${ACCOUNT_ID}:file-system/${FS_ID}/access-point/${apId}`;

// Create the access point rooted at the session's folder with POSIX uid/gid 1000, for one
// run of the session. Idempotent: if an access point for this root already exists (one
// left by a run whose delete did not go through yet), return it.
export async function ensureAccessPoint(developer, session, cli) {
  const root = sessionRoot(developer, cli, session);

  // One left by an earlier run: reuse it if it is (or is becoming) available. One that is
  // being deleted, or failed, cannot be mounted: wait until it is gone, then make a new one.
  const existing = await findAccessPoint(developer, session);
  if (existing && (existing.status === "available" || existing.status === "creating")) return existing;
  if (existing) await deleteAccessPoint(existing.apId, existing.status);

  // posixUser pins every client of this access point to uid/gid 1000, so files the CLI
  // writes are owned by the dev user and scoping is by access point. creationPermissions
  // makes the access point CREATE its own root directory owned uid/gid 1000, mode 0770
  // (rwxrwx---), so the dev user owns /workspace and can create its home there. This works
  // only because the root directory does not already exist as a bucket object: an object
  // written under the prefix first would be imported owned by root (uid 0), and the
  // access point's uid 1000 could not write it. So ensureAccessPoint does NOT pre-create
  // the folder; the access point creates its root on first mount. On a later run the root
  // already exists, and creationPermissions is not reapplied over its owner and mode.
  const out = await s3files.send(
    new CreateAccessPointCommand({
      fileSystemId: FS_ID,
      posixUser: { uid: 1000, gid: 1000 },
      rootDirectory: {
        path: root,
        creationPermissions: { ownerUid: 1000, ownerGid: 1000, permissions: "0770" },
      },
      tags: [
        { key: "ManagedBy", value: "coding-agents-for-developers" },
        { key: "auto-delete", value: "no" },
        { key: "developer", value: developer },
        { key: "session", value: session },
        { key: "cli", value: cli },
        { key: "lastUsed", value: new Date().toISOString() },
      ],
    })
  );
  return { apId: out.accessPointId, developer, session, cli };
}

// Parse an access-point root path "/<developer>/<cli>/<session>" into its parts. Returns
// null for a path that is not one of ours (wrong depth), so a foreign access point on the
// same file system is ignored.
function parseRoot(path) {
  const parts = (path ?? "").split("/").filter(Boolean);
  if (parts.length !== 3) return null;
  return { developer: parts[0], cli: parts[1], session: parts[2] };
}

// List every access point, paginated, and parse each path: [{ apId, status, developer,
// cli, session }]. No per-access-point tag read: one page call per page of access points.
export async function listAllAccessPoints({ includeDeleted = false } = {}) {
  const all = [];
  let token;
  do {
    const out = await s3files.send(
      new ListAccessPointsCommand({ fileSystemId: FS_ID, nextToken: token })
    );
    for (const ap of out.accessPoints ?? []) {
      const parsed = parseRoot(ap.rootDirectory?.path);
      if (parsed && (includeDeleted || ap.status !== "deleted")) all.push({ apId: ap.accessPointId, status: ap.status, ...parsed });
    }
    token = out.nextToken;
  } while (token);
  return all;
}

async function findAccessPoint(developer, session) {
  const all = await listAllAccessPoints();
  return all.find((a) => a.developer === developer && a.session === session) ?? null;
}

// Delete a session's access point, when its pod no longer has the folder mounted. The
// folder and its files stay. Returns true when it deleted one, false when there was none.
export async function releaseAccessPoint(developer, session) {
  const ap = await findAccessPoint(developer, session);
  if (!ap) return false;
  await deleteAccessPoint(ap.apId, ap.status);
  return true;
}

// Delete one access point by id and wait until it is no longer listed, so a Restore right
// after never finds it half-deleted. A delete call that failed counts as done if the access
// point goes anyway (a timeout after it succeeded); one already being deleted is only
// waited for. Throws if it is still listed after waitMs. Exported for the sweep, which has
// the id from its own listing and passes wait: false, so its work stays one listing per
// sweep: a Restore of that session later waits out a deleting access point in
// ensureAccessPoint, so nothing depends on the sweep's delete having finished.
export const apDeleteTiming = { pollMs: 1000, waitMs: 60000 };
export async function deleteAccessPoint(apId, status, { wait = true } = {}) {
  let callError = null;
  if (status !== "deleting") {
    try {
      await s3files.send(new DeleteAccessPointCommand({ accessPointId: apId }));
    } catch (e) {
      if (e?.name === "ResourceNotFoundException" || e?.$metadata?.httpStatusCode === 404) return;
      callError = e;
    }
  }
  if (!wait) {
    if (callError) throw callError;
    return;
  }
  // Confirm by listing, counting a "deleted" entry as still there, until it is absent.
  // (GetAccessPoint cannot confirm it: for an access point that no longer exists, the App
  // role's request is refused as unauthorized, since its policy names access points under
  // this file system, rather than answered not-found.)
  const deadline = Date.now() + apDeleteTiming.waitMs;
  for (;;) {
    const ap = (await listAllAccessPoints({ includeDeleted: true })).find((a) => a.apId === apId);
    if (!ap) return;
    // A failed call whose delete did not start: report it. One deleting or deleted is going.
    if (callError && ap.status !== "deleting" && ap.status !== "deleted") throw callError;
    if (Date.now() >= deadline) throw new Error(`access point ${apId} is still listed ${apDeleteTiming.waitMs / 1000} s after its delete`);
    await sleep(apDeleteTiming.pollMs);
  }
}

// Mint a credential that can mount ONLY this session's access point. This is the proven
// scoping: s3files:ClientMount on the file-system ARN, conditioned on the access point.
export async function mountCredential(apId, developer, cli, session) {
  const apArn = accessPointArn(apId);
  const keyPrefix = sessionKeyPrefix(developer, cli, session);
  const sessionPolicy = {
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "MountOnlyThisSession",
        Effect: "Allow",
        Action: ["s3files:ClientMount", "s3files:ClientWrite"],
        Resource: `arn:aws:s3files:${REGION}:${ACCOUNT_ID}:file-system/${FS_ID}`,
        Condition: { StringEquals: { "s3files:AccessPointArn": apArn } },
      },
      {
        Sid: "ReadOnlyThisSessionObjects",
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:GetObjectVersion"],
        Resource: `arn:aws:s3:::${BUCKET}/${keyPrefix}/*`,
        Condition: { StringEquals: { "aws:ResourceAccount": ACCOUNT_ID } },
      },
      {
        Sid: "ListOnlyThisSessionPrefix",
        Effect: "Allow",
        Action: ["s3:ListBucket"],
        Resource: `arn:aws:s3:::${BUCKET}`,
        Condition: {
          StringEquals: { "aws:ResourceAccount": ACCOUNT_ID },
          StringLike: { "s3:prefix": `${keyPrefix}/*` },
        },
      },
    ],
  };

  const out = await sts.send(
    new AssumeRoleCommand({
      RoleArn: MOUNT_ROLE_ARN,
      RoleSessionName: `s-${session}`.slice(0, 64),
      Policy: JSON.stringify(sessionPolicy),
      DurationSeconds: 3600,
    })
  );
  const c = out.Credentials;
  // The AWS credentials-file body the pod's entrypoint reads from stdin.
  return [
    "[session]",
    `aws_access_key_id=${c.AccessKeyId}`,
    `aws_secret_access_key=${c.SecretAccessKey}`,
    `aws_session_token=${c.SessionToken}`,
    "",
  ].join("\n");
}

// How Delete waits for S3 Files exports to settle. S3 Files exports a change after 60
// seconds with no writes to the file (Amazon S3 User Guide, *Understanding how
// synchronization works*); on a live run the first export of a fresh write arrived at
// 66 s and the last of 20 at 78 s. So the prefix must stay empty for quietMs (90 s) after
// the last change could have been made, not for two quick lists. Exported so a test can
// shorten it.
export const deleteTiming = { settleMs: 15000, quietMs: 90000, maxRounds: 20 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function deleteSession(developer, cli, session) {
  // By now the session's pod has been released (sessions.remove), so nothing has the folder
  // mounted, and only the app hands out the credential that mounts it. Writes made before
  // that can still be on their way from the file system to the bucket (S3 Files exports
  // asynchronously), so a version deleted now can come back. So drain the prefix, wait,
  // and list it again, until it has stayed empty for quietMs. A closed session has no
  // access point; its folder is drained all the same.
  //
  // The access point, if one is left, goes last, and the caller deletes the session record
  // after that. Until then the session stays listed: a Delete that fails, or that an app
  // restart cuts short, leaves the row in place and Delete can be run again.
  try {
    // Quiet is counted from the first list that came back, so a slow first list cannot
    // stand in for the whole wait.
    let quietSince;
    for (let round = 1; round <= deleteTiming.maxRounds; round++) {
      const deleted = await deleteFolder(developer, cli, session);
      const now = Date.now();
      if (deleted > 0) {
        quietSince = now;
        console.log(`delete ${session}: removed ${deleted} version(s) in round ${round}`);
      } else if (quietSince === undefined) {
        quietSince = now;
      } else if (now - quietSince >= deleteTiming.quietMs) {
        await releaseAccessPoint(developer, session);
        return;
      }
      if (round < deleteTiming.maxRounds) await sleep(deleteTiming.settleMs);
    }
    throw new Error(`objects kept reappearing under the session's prefix after ${deleteTiming.maxRounds} rounds`);
  } catch (e) {
    throw new Error(`deleting session ${session}: ${e?.message || e}`);
  }
}

// --- S3 object helpers (session folder delete), via the SDK's S3 client ---
import { S3Client, ListObjectVersionsCommand, DeleteObjectsCommand } from "@aws-sdk/client-s3";
const s3 = new S3Client({ region: REGION, ...retry });

// Delete a session's data for good. The bucket is versioned, so deleting the current
// objects only adds a delete marker in front of each one and keeps every old version: the
// data stays in the bucket and the version count grows with every session. So list every
// version AND delete marker under the session prefix and delete each by VersionId, one page
// (at most 1000 entries, the DeleteObjects limit) at a time, until none are left.
// DeleteObjects reports per-key failures in `Errors` rather than throwing, so treat a
// non-empty `Errors` as a failure.
// Returns how many versions and markers it deleted (0 when the prefix was already empty).
async function deleteFolder(developer, cli, session) {
  const Prefix = `${sessionKeyPrefix(developer, cli, session)}/`;
  let total = 0;
  for (;;) {
    // Always list from the start: the previous page's entries are gone once deleted.
    const out = await s3.send(
      new ListObjectVersionsCommand({ Bucket: BUCKET, Prefix, MaxKeys: 1000 })
    );
    const objects = [...(out.Versions ?? []), ...(out.DeleteMarkers ?? [])]
      .map((v) => ({ Key: v.Key, VersionId: v.VersionId }))
      .slice(0, 1000);
    if (objects.length === 0) return total;
    total += objects.length;
    const del = await s3.send(
      new DeleteObjectsCommand({ Bucket: BUCKET, Delete: { Objects: objects, Quiet: true } })
    );
    if (del.Errors?.length) {
      const e = del.Errors[0];
      throw new Error(
        `deleting ${Prefix}: ${del.Errors.length} object(s) not deleted, first: ` +
        `${e.Key} (${e.Code}: ${e.Message})`
      );
    }
  }
}
