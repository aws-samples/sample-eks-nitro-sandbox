#!/bin/sh
# Start Kiro CLI in a session, signing in first if needed.
#
# Unsigned, `kiro-cli chat` offers "Press enter to continue to the browser" and then tries to
# open a browser. A sandbox pod has none, so it fails ("Failed to open browser for
# authentication") and the CLI exits, which ends the terminal. So check the sign-in first and,
# if there is none, run the device-flow login: it prints a code and a URL that the developer
# opens on their own machine. Retry until the sign-in succeeds, so a cancelled or expired
# attempt does not end the terminal. The sign-in is stored under $HOME, in the session's
# folder, so a restored session skips this.
#
# Arguments are passed to `kiro-cli chat --v3` (for example --resume).
until kiro-cli whoami >/dev/null 2>&1; do
  kiro-cli login --use-device-flow && continue
  printf '\nThe sign-in did not finish. Press Enter to try again.\n'
  read -r _ || exit 1
done
exec kiro-cli chat --v3 "$@"
