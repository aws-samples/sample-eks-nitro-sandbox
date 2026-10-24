#!/usr/bin/env bash
# Generate the editor's password and its argon2 hash, on this machine only.
#
#   ./scripts/new-password.sh            # generate a random password
#   ./scripts/new-password.sh --stdin    # read a password you choose from stdin
#
# Writes two files under the repository's tmp/ (git ignores it):
#   tmp/ide/password          the plaintext, mode 600, for you to type in the browser
#   tmp/ide/hashed-password   the argon2 hash, which is all the cluster ever sees
#
# The plaintext never appears on a command line: it is written to a file with
# mode 600 and piped to the hasher on standard input. setup.sh then creates the
# Kubernetes Secret from the hash FILE (kubectl create secret --from-file), so the
# hash is not on a command line either.
#
# code-server prefers a hashed-password over a plaintext password and reads the
# hash from $HASHED_PASSWORD (code-server FAQ, "Can I store my password hashed?").
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

# npx comes with Node.js and runs code-server's own documented hasher, argon2-cli.
require_commands npx
mkdir -p "$LOCAL_DIR"
chmod 700 "$LOCAL_DIR"

from_stdin=0
case "${1:-}" in
  "")        : ;;
  --stdin)   from_stdin=1 ;;
  *)         die "unknown argument: $1 (use --stdin to read a password from standard input, or no argument to generate one)" ;;
esac

if [[ -f "$PASSWORD_FILE" && $from_stdin -eq 0 ]]; then
  echo "reusing the password already in $(rel "$PASSWORD_FILE") (delete it to generate a new one)"
else
  # Create the file with mode 600 BEFORE anything is written to it, so the
  # plaintext is never briefly world-readable.
  umask 077
  if [[ $from_stdin -eq 1 ]]; then
    require_commands tr
    # Read standard input, drop any trailing newline the shell or the terminal
    # added: code-server compares the password byte for byte.
    tr -d '\r\n' > "$PASSWORD_FILE"
    [[ -s "$PASSWORD_FILE" ]] || die "nothing arrived on standard input; no password written"
    echo "wrote the password you supplied to $(rel "$PASSWORD_FILE")"
  else
    require_commands openssl tr
    openssl rand -base64 24 | tr -d '\r\n' > "$PASSWORD_FILE"
    echo "generated a random password in $(rel "$PASSWORD_FILE")"
  fi
  chmod 600 "$PASSWORD_FILE"
fi

# Hash it. argon2-cli reads the password on standard input and prints the encoded
# argon2 hash, exactly as the code-server FAQ shows. tr strips the trailing
# newline: the Secret must hold the hash and nothing else, or code-server cannot
# parse it.
umask 077
npx --yes argon2-cli -e < "$PASSWORD_FILE" | tr -d '\r\n' > "$HASH_FILE" \
  || die "could not hash the password with 'npx argon2-cli -e'"
grep -q '^[$]argon2' "$HASH_FILE" \
  || die "the hasher did not produce an argon2 hash; $(rel "$HASH_FILE") holds something else"
chmod 600 "$HASH_FILE"

echo
echo "hash (this is what the Kubernetes Secret will hold):"
sed 's/^/  /' "$HASH_FILE"; echo
echo
echo "Read the password when you need to type it:   cat $(rel "$PASSWORD_FILE")"
echo "Next:                                         ./scripts/setup.sh"
