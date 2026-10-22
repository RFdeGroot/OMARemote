"""The whole window (ui/boot) offscreen, started as `omaremote open <name>` starts it while
OMARemote is closed (the bar plugin's click): connections.json is read by a process of its own,
which may answer after the first session list. The open waits for it, never answering "unknown
connection" to an empty library."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..")
QS = shutil.which("qs")
PLUGIN = os.path.join(REPO, "native", "build", "qml")

# Stands in for omaremote-session: logs each command, answers `read` late, launches nothing.
SLOW_BIN = """#!/bin/bash
echo "$*" >> "$CALLS"
case $1 in
  read) sleep 1.5 ;;
  launch|connect) exit 0 ;;
esac
exec "$REAL_BIN" "$@"
"""


@unittest.skipUnless(QS and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs quickshell (qs) and the native build (ninja -C native/build)")
class Startup(unittest.TestCase):
    def test_a_cold_open_waits_for_a_late_library(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "config", "omaremote")
            os.makedirs(cfg)
            os.makedirs(os.path.join(d, "run"))
            with open(os.path.join(cfg, "connections.json"), "w") as f:
                json.dump({"connections": [{"id": "c-late", "name": "Late", "host": "late.lan", "protocol": "ssh"}]}, f)
            slow = os.path.join(d, "slowbin")
            with open(slow, "w") as f:
                f.write(SLOW_BIN)
            os.chmod(slow, 0o755)
            calls = os.path.join(d, "calls.log")
            env = dict(os.environ, HOME=d, XDG_CONFIG_HOME=os.path.join(d, "config"), XDG_RUNTIME_DIR=d,
                       OMAREMOTE_RUNTIME_DIR=os.path.join(d, "run"), QT_QPA_PLATFORM="offscreen",
                       OMAREMOTE_NO_UPDATE_CHECK="1", OMAREMOTE_NOTIFY="0", OMAREMOTE_VERSION="dev",
                       OMAREMOTE_INSTALL="package", OMAREMOTE_BIN=slow, CALLS=calls,
                       REAL_BIN=os.path.join(REPO, "bin", "omaremote-session"), QML_IMPORT_PATH=PLUGIN,
                       OMAREMOTE_OPEN="c-late")
            subprocess.run(["timeout", "6", QS, "-p", os.path.join(REPO, "ui", "boot")], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with open(calls) as f:
                log = f.read().splitlines()
            self.assertTrue(any(line.startswith("launch c-late") for line in log), log)


if __name__ == "__main__":
    unittest.main()
