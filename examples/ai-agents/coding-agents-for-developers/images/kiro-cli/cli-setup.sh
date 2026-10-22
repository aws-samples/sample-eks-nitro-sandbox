#!/bin/sh
# Pre-authenticate Kiro CLI from an admin-supplied token, so the developer is not asked to
# sign in. Kiro CLI keeps its sign-in (an IAM Identity Center / Builder ID OAuth token and
# the matching client registration) in a small SQLite store at
# $HOME/.local/share/kiro-cli/data.sqlite3, across two tables: auth_kv holds the token and
# the device/client registration, state holds the Identity Center region, start URL and the
# CodeWhisperer profile. When that store already carries a valid token, `kiro-cli chat`
# starts straight into the session; when it does not, Kiro CLI runs its normal device-flow
# login the first time.
#
# This hook bridges an admin-provided token into that store:
#   - If KIRO_CLI_AUTH_B64 is set and non-empty, it is base64 of a JSON bundle
#       { "auth_kv": { "<key>": "<value>", ... }, "state": { "<key>": "<value>", ... } }
#     (the rows read from an already-signed-in machine). The hook writes those rows into the
#     store, so Kiro CLI finds a ready session and never prompts. The bundle is a CREDENTIAL:
#     the admin injects it through the pod's environment (a Kubernetes Secret), never on a
#     command line, and this hook never prints its contents.
#   - If KIRO_CLI_AUTH_B64 is unset or empty, the hook does nothing and Kiro CLI logs in
#     normally. Inside a sandbox pod there is no browser, so that interactive login uses the
#     OAuth device flow (`kiro-cli login --use-device-flow`): Kiro CLI prints a code and a
#     URL the developer opens on their own machine.
#
# The session entrypoint runs this as the dev user after the workspace is mounted, because
# the store lives under the mounted home. It is idempotent: re-running upserts the same rows,
# so a restored session stays signed in.
set -eu

# --- V3 session store on a POSIX filesystem ------------------------------------------------
# The V3 agent engine locks each session with a hardlink under ~/.kiro/sessions/.../
# .lock.acquire. The S3 Files workspace mount does not support hardlinks (link() returns
# EMLINK: "too many links"), so with the session dir on the mounted home the V3 TUI loops on
# that error and never reaches the prompt. Point ~/.kiro/sessions at a pod-local tmpfs path
# instead -- hardlinks work there, and session LOCKS are runtime state that need not persist
# (V3 keeps the durable conversation server-side). Everything else under ~/.kiro and the
# workspace stays on S3 Files, so code and settings still persist across restore. This runs
# whether or not a token is supplied, because every V3 launch needs it.
mkdir -p "$HOME/.kiro" /tmp/kiro-sessions
if [ ! -L "$HOME/.kiro/sessions" ]; then
  # If a real sessions dir exists from an older run, move it aside (never delete here).
  [ -e "$HOME/.kiro/sessions" ] && mv "$HOME/.kiro/sessions" "$HOME/.kiro/sessions.pre-tmpfs.$$" 2>/dev/null || true
  ln -sfn /tmp/kiro-sessions "$HOME/.kiro/sessions"
fi

[ -n "${KIRO_CLI_AUTH_B64:-}" ] || exit 0

DB_DIR="$HOME/.local/share/kiro-cli"
DB="$DB_DIR/data.sqlite3"
mkdir -p "$DB_DIR"

# Let Kiro CLI create and migrate its own store FIRST, then seed into it. Kiro CLI
# initialises data.sqlite3 by running migrations that do `CREATE TABLE state (...)` (and
# auth_kv, history, ...) WITHOUT "IF NOT EXISTS". If this hook created those tables itself,
# that migration would fail ("table state already exists"), Kiro CLI's whole store init
# would error, and it would report "Not logged in" even with the token present. So trigger
# its init with a read-only command (whoami needs no network and no sign-in; it just opens
# and migrates the store), ignoring its "not logged in" exit, and only then upsert the rows
# into the tables Kiro CLI has now created -- never creating a table here.
kiro-cli whoami >/dev/null 2>&1 || true

# Upsert the token rows. The program is the heredoc on stdin, so the token bundle is read
# from the environment (KIRO_CLI_AUTH_B64) inside python rather than piped or passed as an
# argument -- it is never visible in the process list, and this hook never prints it.
python3 - "$DB" <<'PY'
import base64, json, os, sqlite3, sys

db = sys.argv[1]
bundle = json.loads(base64.b64decode(os.environ["KIRO_CLI_AUTH_B64"]))

con = sqlite3.connect(db)
try:
    # No CREATE TABLE here: Kiro CLI's own migration (run above) owns the schema. We only
    # write rows into auth_kv (the OAuth token + client registration) and state (the
    # Identity Center region, start URL and CodeWhisperer profile).
    for table in ("auth_kv", "state"):
        for key, value in (bundle.get(table) or {}).items():
            con.execute(
                f"INSERT INTO {table}(key, value) VALUES(?, ?) "
                f"ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, value),
            )
    con.commit()
finally:
    con.close()
PY

chmod 600 "$DB"
