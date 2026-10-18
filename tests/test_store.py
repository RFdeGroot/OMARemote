"""ui/Store.qml against connections.json on disk, run in Quickshell offscreen: a file that does not
read is never overwritten, and last-connected.json is shown without connections.json changing."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "ui")
QS = shutil.which("qs")

SHELL = """import Quickshell
import QtQuick
import "store"
ShellRoot {
    property bool created: Store.path !== ""
    property int waited: 0
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            waited += 100
            if (!Store.loaded && waited < 5000)
                return
            stop()
            var c = Store.connections.filter(function (c) { return c.id === "c1" })[0]
            console.log("PROBE " + JSON.stringify({ loaded: Store.loaded, broken: Store.broken,
                count: Store.stored.length, last: c ? c.lastConnected : null, port: c ? c.port : null }))
            Store.setUi("pinned", true)
            done.start()
        }
    }
    Timer { id: done; interval: 600; onTriggered: Qt.quit() }
}
"""


@unittest.skipUnless(QS, "needs quickshell (qs)")
class StoreFile(unittest.TestCase):
    def run_store(self, text, stamps=None):
        with tempfile.TemporaryDirectory() as d:
            shell = os.path.join(d, "shell")
            os.makedirs(os.path.join(shell, "store"))
            shutil.copy(os.path.join(UI, "Store.qml"), os.path.join(shell, "store"))
            shutil.copytree(os.path.join(UI, "js"), os.path.join(shell, "store", "js"))
            with open(os.path.join(shell, "store", "qmldir"), "w") as f:
                f.write("singleton Store 1.0 Store.qml\n")
            with open(os.path.join(shell, "shell.qml"), "w") as f:
                f.write(SHELL)
            cfg = os.path.join(d, "config", "omaremote")
            os.makedirs(cfg)
            path = os.path.join(cfg, "connections.json")
            if text is None:
                os.mkdir(path)
            else:
                with open(path, "w") as f:
                    f.write(text)
            if stamps is not None:
                with open(os.path.join(cfg, "last-connected.json"), "w") as f:
                    json.dump(stamps, f)
            env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(d, "config"), QT_QPA_PLATFORM="offscreen",
                       QT_FORCE_STDERR_LOGGING="1", XDG_RUNTIME_DIR=d)
            out = subprocess.run([QS, "-p", shell], env=env, capture_output=True, text=True, timeout=30)
            probe = [l for l in (out.stdout + out.stderr).splitlines() if "PROBE " in l]
            self.assertTrue(probe, out.stderr[-2000:])
            self.last_err = out.stderr
            after = None
            if os.path.isfile(path):
                with open(path) as f:
                    after = f.read()
            broken = os.path.join(cfg, "connections.json.broken")
            kept = None
            if os.path.exists(broken):
                with open(broken) as f:
                    kept = f.read()
            return json.loads(probe[0].split("PROBE ", 1)[1]), after, kept

    def test_a_broken_file_is_never_overwritten(self):
        text = '{"connections": [{"id": "c1", "host": "a.lan"},]}'
        probe, after, kept = self.run_store(text)
        self.assertTrue(probe["broken"])
        self.assertEqual(after, text)
        self.assertEqual(kept, text)

    def test_a_path_that_cannot_be_read_is_broken_not_new(self):
        # Only a missing file is a fresh start: anything else that fails to load must not be
        # replaced by an empty list (a folder in its place here; Store's own chmod 600 would
        # undo an unreadable file's mode).
        probe, after, _ = self.run_store(None)
        self.assertTrue(probe["broken"], self.last_err[-1500:])
        self.assertIsNone(after)

    def test_a_non_object_is_broken_too(self):
        probe, after, _ = self.run_store("5")
        self.assertTrue(probe["broken"])
        self.assertEqual(after, "5")

    def test_a_good_file_is_written_and_shows_the_stamp(self):
        text = json.dumps({"connections": [{"id": "c1", "host": "a.lan", "protocol": "gliff", "lastConnected": 100}]})
        probe, after, kept = self.run_store(text, {"c1": 200})
        self.assertFalse(probe["broken"])
        self.assertEqual(probe["last"], 200)
        self.assertEqual(probe["port"], 22)
        self.assertIsNone(kept)
        data = json.loads(after)
        self.assertTrue(data["ui"]["pinned"])
        self.assertEqual(data["connections"][0]["lastConnected"], 100)


if __name__ == "__main__":
    unittest.main()
