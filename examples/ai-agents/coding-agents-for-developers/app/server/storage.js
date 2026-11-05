// S3 Files per-session storage: create or find a session's access point, mint a
// short-lived credential scoped to it, and build the session list from access-point tags.
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
// the developer, the CLI and the session name, so the session list can be built from the
// access-point paths alone, with no per-access-point tag read. That matters at scale: a
// developer-facing list of thousands of sessions would otherwise be thousands of
// ListTagsForResource calls and would hit the S3 Files control-plane rate limit.
//   access point root:  /<developer>/<cli>/<session>
//   bucket key prefix:   <PREFIX>/<developer>/<cli>/<session>/
export const sessionRoot = (developer, cli, session) => `/${developer}/${cli}/${session}`;
export const sessionKeyPrefix = (developer, cli, session) =>
  `${PREFIX}/${developer}/${cli}/${session}`;

export const accessPointArn = (apId) =>
  `arn:aws:s3files:${REGION}:${ACCOUNT_ID}:file-system/${FS_ID}/access-point/${apId}`;

// Create the session's folder in the bucket (access points do not auto-create their
// root), then create the access point rooted at it with POSIX uid/gid 1000. Idempotent:
// if an access point for this root already exists (restore), return it.
export async function ensureAccessPoint(developer, session, cli) {
  const root = sessionRoot(developer, cli, session);

  const existing = await findAccessPoint(developer, session);
  if (existing) return existing;

  // posixUser pins every client of this access point to uid/gid 1000, so files the CLI
  // writes are owned by the dev user and scoping is by access point. creationPermissions
  // makes the access point CREATE its own root directory owned uid/gid 1000, mode 0770
  // (rwxrwx---), so the dev user owns /workspace and can create its home there. This works
  // only because the root directory does not already exist as a bucket object: an object
  // written under the prefix first would be imported owned by root (uid 0), and the
  // access point's uid 1000 could not write it. So ensureAccessPoint does NOT pre-create
  // the folder; the access point creates its root on first mount.
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

// List every access point once, paginated, and parse each path. No per-access-point tag
// read, so this is a handful of API calls regardless of how many sessions exist.
async function listAllAccessPoints() {
  const all = [];
  let token;
  do {
    const out = await s3files.send(
      new ListAccessPointsCommand({ fileSystemId: FS_ID, nextToken: token })
    );
    for (const ap of out.accessPoints ?? []) {
      const parsed = parseRoot(ap.rootDirectory?.path);
      if (parsed) all.push({ apId: ap.accessPointId, ...parsed });
    }
    token = out.nextToken;
  } while (token);
  return all;
}

// Every session on the file system: [{ apId, developer, cli, session }], from the paths.
export async function listAllSessions() {
  return listAllAccessPoints();
}

async function findAccessPoint(developer, session) {
  const all = await listAllAccessPoints();
  return all.find((a) => a.developer === developer && a.session === session) ?? null;
}

// The CLI of one session, from its access-point path. Used by restore.
export async function sessionCli(developer, session) {
  const ap = await findAccessPoint(developer, session);
  return ap?.cli;
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

// The signed-in developer's sessions. Built entirely from the access-point paths
// (/<developer>/<cli>/<session>) with no per-access-point tag read, so it stays a handful
// of API calls whether a developer has five sessions or five thousand. The session name
// embeds a creation timestamp prefix, so sorting by name newest-first needs no tag either.
export async function listSessions(developer) {
  const all = await listAllAccessPoints();
  return all
    .filter((a) => a.developer === developer)
    .map((a) => ({ session: a.session, cli: a.cli, apId: a.apId }))
    .sort((x, y) => y.session.localeCompare(x.session));
}

// How Delete waits for S3 Files exports to settle. S3 Files exports a change after 60
// seconds with no writes to the file (Amazon S3 User Guide, *Understanding how
// synchronization works*); on a live run the first export of a fresh write arrived at
// 66 s and the last of 20 at 78 s. So the prefix must stay empty for quietMs (90 s) after
// the last change could have been made, not for two quick lists. Exported so a test can
// shorten it.
export const deleteTiming = { settleMs: 15000, quietMs: 90000, maxRounds: 20 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function deleteSession(developer, session) {
  const ap = await findAccessPoint(developer, session);
  if (!ap) return;
  // By now the session's pod has been released (sessions.remove), so nothing has the folder
  // mounted, and only the app hands out the credential that mounts it. Writes made before
  // that can still be on their way from the file system to the bucket (S3 Files exports
  // asynchronously), so a version deleted now can come back. So drain the prefix, wait,
  // and list it again, until it has stayed empty for quietMs.
  //
  // The access point goes last. The session list is built from access points, so until
  // the drain has finished the session stays listed: a Delete that fails, or that an app
  // restart cuts short, leaves the row in place and Delete can be run again.
  try {
    // Quiet is counted from the first list that came back, so a slow first list cannot
    // stand in for the whole wait.
    let quietSince;
    for (let round = 1; round <= deleteTiming.maxRounds; round++) {
      const deleted = await deleteFolder(developer, ap.cli, session);
      const now = Date.now();
      if (deleted > 0) {
        quietSince = now;
        console.log(`delete ${session}: removed ${deleted} version(s) in round ${round}`);
      } else if (quietSince === undefined) {
        quietSince = now;
      } else if (now - quietSince >= deleteTiming.quietMs) {
        await s3files.send(new DeleteAccessPointCommand({ accessPointId: ap.apId }));
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
