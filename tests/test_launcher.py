"""bin/omaremote, the entry point (bash, set -euo pipefail)."""
import os
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER = os.path.join(HERE, "..", "bin", "omaremote")


class RunningPid(unittest.TestCase):
    def test_a_failing_hyprctl_is_no_window_not_the_end(self):
        # open, quick, adopt and restart ran pid=$(running_pid) under set -e: with hyprctl failing
        # they ended without a word.
        with tempfile.TemporaryDirectory() as d:
            stub = os.path.join(d, "hyprctl")
            with open(stub, "w") as f:
                f.write("#!/bin/sh\nexit 1\n")
            os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
            script = ('set -euo pipefail; source <(sed -n "/^running_pid()/,/^}/p" "$1"); '
                      'pid=$(running_pid); echo "pid=[$pid]"')
            out = subprocess.run(["bash", "-c", script, "bash", LAUNCHER], capture_output=True, text=True,
                                 env=dict(os.environ, PATH=d + ":" + os.environ["PATH"]), timeout=10)
            self.assertEqual((out.returncode, out.stdout.strip()), (0, "pid=[]"), out.stderr)


if __name__ == "__main__":
    unittest.main()
