# Sourced by the sample scripts that use bash 4 features (associative arrays, mapfile,
# ${var^^} and ${var,,}). It stops the script with a clear message when the shell is older
# than bash 4, before the first of those lines runs.
#
# Why: macOS ships bash 3.2. On it those lines fail part way through a run, and one failure
# left a clean up stopped after it had deleted the Jobs and before it removed the volumes.
#
# Use it as the first command of the script, before `set -u`, with the path to this file
# from the script's own folder:
#
#   # shellcheck source=../../../../scripts/lib/require-bash.sh
#   . "$(dirname "$0")/../../../../scripts/lib/require-bash.sh"
#
# It is written for bash 3.2 and POSIX sh, so it can run on the shell it refuses. Keep it
# free of bash 4 syntax.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  if [ -n "${BASH_VERSION:-}" ]; then
    require_bash_shell="bash $BASH_VERSION"
  else
    require_bash_shell="not bash"
  fi
  {
    echo "error: $0 needs bash 4 or later, and this shell is $require_bash_shell."
    echo "macOS ships bash 3.2. Run the sample from AWS CloudShell or a Linux host, or install a"
    echo "newer bash on the Mac:"
    echo "  brew install bash"
    echo "Open a new terminal and check that \`bash --version\` reports 4 or later, then run this"
    echo "again. If it still reports 3.2, run the script with the new bash by name:"
    echo "  \"\$(brew --prefix)/bin/bash\" $0"
  } >&2
  exit 1
fi
