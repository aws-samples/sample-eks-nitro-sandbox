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
# Create the directory with mode 700 only when it is absent, so pointing
# LOCAL_DIR at a directory you already have (your home directory, say) never
# changes that directory's mode. Every file written below is created under
# umask 077 and is mode 600 regardless of the directory.
if [[ ! -d "$LOCAL_DIR" ]]; then
  mkdir -p "$(dirname "$LOCAL_DIR")"
  mkdir -m 700 "$LOCAL_DIR"
fi

from_stdin=0
case "${1:-}" in
  "")        : ;;
  --stdin)   from_stdin=1 ;;
  *)         die "unknown argument: $1 (use --stdin to read a password from standard input, or no argument to generate one)" ;;
esac

# Every write below goes to a fresh file from mktemp, which creates it mode 600,
# and nothing is moved into place until BOTH the password and its hash are in
# hand. So the plaintext is never in a world-readable file, a file that already
# exists keeps its own mode until it is replaced, and a run that stops part way
# through leaves the password you already had exactly as it was, hash included.
# That last part is why the moves are at the end rather than beside each write:
# the editor already on the cluster still accepts the old password, so a run that
# replaced the password file and then failed to hash it would destroy the only
# copy of the one thing that opens the editor.
require_commands mktemp tr
umask 077

# Remove either temporary file on any exit, so a run that fails or is interrupted
# never leaves the plaintext or the hash behind under a temporary name. Each
# variable is cleared as soon as its file has been moved into place.
pw_tmp=""
hash_tmp=""
drop_temps() {
  [[ -n "$pw_tmp" ]] && rm -f "$pw_tmp"
  [[ -n "$hash_tmp" ]] && rm -f "$hash_tmp"
  return 0
}
trap drop_temps EXIT

# -s, not -f: an empty password file is as useless as a missing one, and reusing
# one would hash the empty string into a hash that looks perfectly valid.
hash_needed=1
if [[ -s "$PASSWORD_FILE" && $from_stdin -eq 0 ]]; then
  echo "reusing the password already in $(rel "$PASSWORD_FILE") (delete it to generate a new one)"
  pw_src="$PASSWORD_FILE"
  # Keep the hash that goes with it rather than making a new one. argon2 salts
  # every hash afresh, so hashing an unchanged password again produces a
  # DIFFERENT encoded hash. setup.sh compares the hash on this machine with the
  # one the Secret already holds, so a fresh hash of the same password would stop
  # the run with "the editor would keep accepting the older password" when the
  # password had not changed at all.
  # This only checks that the file holds something shaped like an argon2 hash, not
  # that it is a hash OF this password: argon2-cli 0.25.1 has no verify mode, and
  # re-hashing to find out is the very thing that breaks setup.sh. So the two
  # files are assumed to belong together, which holds as long as neither is
  # edited by hand. Say that rather than claim more.
  if [[ -s "$HASH_FILE" ]] && grep -q '^[$]argon2' "$HASH_FILE"; then
    echo "keeping the argon2 hash already in $(rel "$HASH_FILE"); it is not re-checked"
    echo "  against the password, so if you edited either file yourself, delete both and re-run"
    hash_needed=0
  fi
else
  pw_tmp="$(mktemp "$LOCAL_DIR/.password.XXXXXX")"
  pw_src="$pw_tmp"
  if [[ $from_stdin -eq 1 ]]; then
    # Read standard input, drop any trailing newline the shell or the terminal
    # added: code-server compares the password byte for byte.
    tr -d '\r\n' > "$pw_tmp"
    [[ -s "$pw_tmp" ]] \
      || die "nothing arrived on standard input; no password written, and $(rel "$PASSWORD_FILE") is unchanged"
  else
    require_commands openssl
    openssl rand -base64 24 | tr -d '\r\n' > "$pw_tmp"
    [[ -s "$pw_tmp" ]] \
      || die "openssl produced no password; $(rel "$PASSWORD_FILE") is unchanged"
  fi
fi

# Hash it, reading whichever file holds the password: the one being reused, or
# the temporary file that is not in place yet. argon2-cli reads the password on
# standard input and prints the encoded argon2 hash, exactly as the code-server
# FAQ shows. tr strips the trailing newline: the Secret must hold the hash and
# nothing else, or code-server cannot parse it.
#
# The version is pinned, like every other version this sample uses: this is the
# one program that sees the plaintext, so which code runs is not something to
# leave to whatever npm publishes next. The page's versions table states the pin.
if [[ $hash_needed -eq 1 ]]; then
  hash_tmp="$(mktemp "$LOCAL_DIR/.hashed-password.XXXXXX")"
  npx --yes argon2-cli@0.25.1 -e < "$pw_src" | tr -d '\r\n' > "$hash_tmp" \
    || die "could not hash the password with 'npx argon2-cli@0.25.1 -e'; $(rel "$PASSWORD_FILE") and $(rel "$HASH_FILE") are both unchanged"
  grep -q '^[$]argon2' "$hash_tmp" \
    || die "the hasher did not produce an argon2 hash; $(rel "$PASSWORD_FILE") and $(rel "$HASH_FILE") are both unchanged"
fi

# Both are in hand, so put them in place: the password first, then its hash.
# Nothing above this point can change either file, which is what keeps the two in
# step even when a run fails half way.
if [[ -n "$pw_tmp" ]]; then
  mv -f "$pw_tmp" "$PASSWORD_FILE"
  pw_tmp=""
  if [[ $from_stdin -eq 1 ]]; then
    echo "wrote the password you supplied to $(rel "$PASSWORD_FILE")"
  else
    echo "generated a random password in $(rel "$PASSWORD_FILE")"
  fi
fi
if [[ -n "$hash_tmp" ]]; then
  mv -f "$hash_tmp" "$HASH_FILE"
  hash_tmp=""
fi

echo
echo "hash (this is what the Kubernetes Secret will hold):"
sed 's/^/  /' "$HASH_FILE"; echo
echo
echo "Read the password when you need to type it:   cat $(rel "$PASSWORD_FILE")"
echo "Next:                                         ./scripts/setup.sh"
