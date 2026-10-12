#!/bin/sh
# Entrypoint for the coding-agent image.
#
#   /entrypoint.sh "<prompt>"
#
# Clones REPO_URL with the token mounted from the coding-agent-git-token Secret,
# runs Claude Code non-interactively on the prompt, then makes sure the branch
# agent/issue-$ISSUE_NUMBER is pushed and has a pull request (the agent normally
# opens it; if it did not, this opens one from the branch's last commit message).
set -eu

PROMPT="${1:?usage: /entrypoint.sh <prompt>}"
: "${REPO_URL:?set REPO_URL to https://github.com/<owner>/<repo>}"
: "${ISSUE_NUMBER:?set ISSUE_NUMBER}"
TOKEN_FILE="${TOKEN_FILE:-/var/run/secrets/git/token}"
BRANCH="agent/issue-${ISSUE_NUMBER}"
REPO="${REPO_URL#https://github.com/}"
REPO="${REPO%.git}"

[ -s "$TOKEN_FILE" ] || { echo "no git token at $TOKEN_FILE" >&2; exit 1; }

# Refuse to run until this pod's egress is fenced. Two probes, both direct (no proxy):
# FENCE_ALLOWED_URL, a host the egress policy allows, must answer, or the second
# probe proves nothing (no DNS, no network); FENCE_CHECK_URL, a host it does not
# allow, must resolve and then never connect, which is how the policy drops a
# connection. Any other result (it answers, connects slowly, or does not resolve) is
# not proof, so wait up to about a minute for the policy to take effect, then give up
# rather than run the agent unfenced. Set FENCE_CHECK_URL= (empty) to skip the check.
FENCE_CHECK_URL="${FENCE_CHECK_URL-https://example.com}"
FENCE_ALLOWED_URL="${FENCE_ALLOWED_URL:-https://api.github.com}"
if [ -n "$FENCE_CHECK_URL" ]; then
  tries=0
  while :; do
    if curl -s -o /dev/null --noproxy '*' --connect-timeout 5 --max-time 10 "$FENCE_ALLOWED_URL"; then
      host="${FENCE_CHECK_URL#*://}"
      host="${host%%[/:]*}"
      if getent hosts "$host" >/dev/null; then
        rc=0
        peer="$(curl -s -o /dev/null --noproxy '*' --connect-timeout 3 --max-time 5 \
                  -w '%{remote_ip}' "$FENCE_CHECK_URL")" || rc=$?
        # Dropped: the name resolves, yet no TCP connection is ever made before the
        # timeout (curl exit 28 and no peer address). A server that accepted the
        # connection but was slow, or a lookup that timed out, is not proof.
        if [ "$rc" -eq 28 ] && [ -z "$peer" ]; then
          break
        fi
        seen="$FENCE_CHECK_URL gave curl exit $rc${peer:+ after connecting to $peer}"
      else
        seen="$host does not resolve, so a refusal would prove nothing"
      fi
    else
      seen="the allowed host $FENCE_ALLOWED_URL did not answer"
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      echo "cannot confirm the egress fence ($seen); refusing to run" >&2
      exit 1
    fi
    sleep 3
  done
  echo "Egress fence is up: $FENCE_CHECK_URL is dropped, $FENCE_ALLOWED_URL answers"
fi

# git reads the token from the mounted file on every request, so it is never
# written into the repository's config or the remote URL.
# shellcheck disable=SC2016  # $(cat ...) must run when git calls the helper, not now
git config --global credential.helper \
  '!f() { echo username=x-access-token; echo "password=$(cat '"$TOKEN_FILE"')"; }; f'
git config --global user.name "coding-agent"
# Not <login>@users.noreply.github.com: GitHub links that form to the account with that login.
git config --global user.email "coding-agent@example.com"
# The GitHub CLI uses the same token for issues and pull requests.
GH_TOKEN="$(cat "$TOKEN_FILE")"
export GH_TOKEN

echo "Cloning $REPO ..."
git clone --quiet "$REPO_URL" /workspace/repo
cd /workspace/repo

title="$(gh issue view "$ISSUE_NUMBER" --json title --jq .title)"
echo "Reading issue #$ISSUE_NUMBER: \"$title\""

echo "Running Claude Code ..."
claude -p "$PROMPT" --allowedTools "Bash,Edit,Read,Write" < /dev/null

git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
  || { echo "the agent did not create branch $BRANCH" >&2; exit 1; }
git push --quiet -u origin "$BRANCH"

# An empty answer means no open pull request for the branch yet. Any gh error aborts
# here (set -e) rather than being mistaken for "none", so a failed lookup never opens
# a duplicate. A closed or merged PR from an earlier run does not count.
pr="$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"
if [ -n "$pr" ]; then
  echo "Pushed $BRANCH ... pull request already open: $pr"
else
  pr="$(gh pr create --head "$BRANCH" --title "Fix #$ISSUE_NUMBER: $title" \
          --body "Fixes #$ISSUE_NUMBER.

$(git log -1 --format=%B "$BRANCH")")"
  echo "Pushed $BRANCH ... opened pull request $pr"
fi
