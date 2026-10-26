"""Give nono a controlling terminal, without putting anything on a command line.

nono expects a terminal for its own output. The controller runs it unattended from
kubectl exec, so this wrapper spawns it on a pseudo-terminal and passes its exit status
through. It takes the command as plain arguments and reads no credential.
"""
import os
import pty
import sys

sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))
