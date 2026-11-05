#!/bin/bash
# Keep Codex's interactive TUI alive across browser detach/reattach.
#
# Unlike the other CLIs, Codex (v0.163) splits its interactive session into a long-lived
# local app-server daemon that holds the conversation and runs the model turns, and a
# thin TUI client that draws it. When the TUI's terminal goes away -- which is exactly
# what happens here every time the developer closes the browser tab and tmux detaches its
# client -- the TUI prints "Disconnected from this task. Any running work continues." and
# exits, leaving the task running on the daemon. The sample's model is the opposite: the
# CLI runs in a detached tmux session and the browser attaches and detaches a tmux client
# as the tab opens and closes, and the CLI must survive that. So without this wrapper the
# Codex window shows "[exited]" the moment the first detach happens.
#
# This wrapper bridges the two. It runs the TUI in a loop: the first iteration starts a
# fresh session; every later iteration reconnects to the still-running daemon task with
# `codex resume --last`, which is the reconnect Codex itself tells the user to run. So a
# detach drops the TUI, the loop immediately reattaches to the same task, and the next
# browser attach sees the session with its full history. tmux is the thing that detaches
# and reattaches the terminal; the daemon task never stops.
#
# A short sleep between iterations keeps a genuine startup failure (bad config, no
# credentials) from spinning in a tight loop; in that case `codex resume --last` also
# fails and the window still shows the error, just retried, rather than a silent exit.
set -u

# First iteration. On Restore (--resume) the pod is new but the home came back with the
# session's folder, so continue the most recent recorded session; if there is none yet,
# start a fresh one. Otherwise it is a new session.
#
# The loop ends when the developer quits Codex themselves (/quit): the TUI exits with status
# 0 while a browser terminal is still attached to tmux. The script then returns, and the
# entrypoint leaves the developer in a shell with the command to go back. Any other exit
# goes round again: a detach (no terminal attached), or an error. On a fresh home the
# first start fails with "app server did not become ready" while Codex sets up its
# background server, and the next attempt comes up.
attached() { [ -n "$(tmux list-clients -t agent 2>/dev/null)" ]; }

# Start Codex's background app server, and wait for it, before the TUI. Started by the TUI
# instead, the server was still coming up when the TUI drew its prompt, and what a
# developer typed in a new session's first seconds was dropped: on a live run, a prompt
# typed six seconds after the window opened left no trace, while the same prompt a minute
# later was answered.
codex app-server daemon start >/dev/null 2>&1 || true

if [ "${1:-}" = "--resume" ]; then
  shift
  codex resume --last "$@" || codex "$@"
else
  codex "$@"
fi
rc=$?

# Every subsequent iteration: reconnect to the daemon task this pod already started.
# `--last` picks the most recent session, which is this pod's own (the home is per
# session, so there is only ever one). On a fresh home there is no session yet, so fall
# back to a new one.
while ! { [ "$rc" -eq 0 ] && attached; }; do
  sleep 1
  codex resume --last || codex
  rc=$?
done
