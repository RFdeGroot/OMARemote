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


@unittest.skipUnless(os.path.isdir("/usr/share/omarchy/shell/Commons"), "needs Omarchy's shell")
class Restart(unittest.TestCase):
    def test_restart_by_a_relative_path_starts_it_by_its_full_path(self):
        # `bin/omaremote restart` handed uwsm-app "bin/omaremote", which it could not find: the
        # window closed and never came back ("Path bin/omaremote does not exist").
        import time
        with tempfile.TemporaryDirectory() as d:
            seen = os.path.join(d, "seen")
            for name, body in (("hyprctl", "exit 1"), ("uwsm-app", f'echo "$@" > "{seen}"')):
                stub = os.path.join(d, name)
                with open(stub, "w") as f:
                    f.write(f"#!/bin/sh\n{body}\n")
                os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
            repo = os.path.dirname(os.path.dirname(os.path.abspath(LAUNCHER)))
            subprocess.run(["bin/omaremote", "restart"], cwd=repo, timeout=10, capture_output=True,
                           env=dict(os.environ, PATH=d + ":" + os.environ["PATH"]))
            for _ in range(50):
                if os.path.exists(seen) and os.path.getsize(seen):
                    break
                time.sleep(0.1)
            with open(seen) as f:
                self.assertEqual(f.read().split(), ["--", os.path.realpath(LAUNCHER)])


if __name__ == "__main__":
    unittest.main()
