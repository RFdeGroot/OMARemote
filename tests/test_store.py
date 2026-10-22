"""ui/Store.qml against connections.json on disk, run in Quickshell offscreen: a file that does not
read is never overwritten, and last-connected.json is shown without connections.json changing."""
import json
import os
import shutil
import subprocess
import tempfile
import time
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
            if ((!Store.loaded || waited < Number(Quickshell.env("PROBE_AFTER") || 0)) && waited < 8000)
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
    def run_store(self, text, stamps=None, missing=False, before=None, later=None, probe_after=0):
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
            if missing:
                pass
            elif text is None:
                os.mkdir(path)
            else:
                with open(path, "w") as f:
                    f.write(text)
            if stamps is not None:
                with open(os.path.join(cfg, "last-connected.json"), "w") as f:
                    json.dump(stamps, f)
            if before:
                before(cfg)
            env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(d, "config"), QT_QPA_PLATFORM="offscreen",
                       QT_FORCE_STDERR_LOGGING="1", XDG_RUNTIME_DIR=d,
                       OMAREMOTE_BIN=os.path.join(HERE, "..", "bin", "omaremote-session"))
            env["PROBE_AFTER"] = str(probe_after)
            if getattr(self, "bin", None):
                env["REAL_BIN"], env["OMAREMOTE_BIN"] = env["OMAREMOTE_BIN"], self.bin
            proc = subprocess.Popen([QS, "-p", shell], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if later:
                time.sleep(later[0])
                later[1](cfg)
            stdout, stderr = proc.communicate(timeout=30)
            out = subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
            probe = [l for l in (out.stdout + out.stderr).splitlines() if "PROBE " in l]
            self.assertTrue(probe, out.stderr[-2000:])
            self.last_err = out.stderr
            after = None
            if os.path.isfile(path):
                self.mode = os.stat(path).st_mode & 0o777
                with open(path) as f:
                    after = f.read()
            self.outside = None
            if os.path.exists(os.path.join(d, "outside")):
                with open(os.path.join(d, "outside")) as f:
                    self.outside = f.read()
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

    def test_a_new_file_is_only_the_users(self):
        old = os.umask(0o022)
        try:
            probe, after, _ = self.run_store(None, missing=True)
        finally:
            os.umask(old)
        self.assertFalse(probe["broken"])
        self.assertTrue(json.loads(after)["ui"]["pinned"])
        self.assertEqual(self.mode, 0o600)

    def test_a_symlink_at_broken_is_replaced_not_written_through(self):
        def plant(cfg):
            outside = os.path.join(os.path.dirname(os.path.dirname(cfg)), "outside")
            with open(outside, "w") as f:
                f.write("mine\n")
            os.symlink(outside, os.path.join(cfg, "connections.json.broken"))
        text = '{"connections": [,]}'
        probe, after, kept = self.run_store(text, before=plant)
        self.assertTrue(probe["broken"])
        self.assertEqual(kept, text)
        self.assertEqual(self.outside, "mine\n")

    # Read through `omaremote-session read` (bounded there), never whole by the window.
    def test_a_fifo_is_broken_and_never_waited_for(self):
        probe, after, kept = self.run_store(None, missing=True,
                                            before=lambda cfg: os.mkfifo(os.path.join(cfg, "connections.json")))
        self.assertTrue(probe["broken"])
        self.assertIsNone(kept)

    def test_more_connections_than_it_holds_is_broken(self):
        conns = [{"id": f"c{i}", "host": "a.lan"} for i in range(2001)]
        text = json.dumps({"connections": conns})
        probe, after, kept = self.run_store(text)
        self.assertTrue(probe["broken"])
        self.assertEqual(after, text)
        self.assertEqual(kept, text)

    def test_a_file_above_16_mib_is_broken(self):
        text = json.dumps({"connections": [{"id": "c1", "host": "a.lan"}], "pad": "x" * (17 << 20)})
        probe, after, _ = self.run_store(text)
        self.assertTrue(probe["broken"])
        self.assertEqual(len(after), len(text))

    def test_a_read_without_an_answer_is_tried_again(self):
        # omaremote-session gone for a moment (mid-upgrade): the first read answers nothing, and
        # nothing changes the file after. The window must not refuse to save for good.
        def flaky(cfg):
            bin_ = os.path.join(os.path.dirname(os.path.dirname(cfg)), "flaky")
            with open(bin_, "w") as f:
                # The first two: the start's own read, and the one its chmod of the file brings.
                f.write('#!/bin/sh\nif [ "$1 $2" = "read connections" ] && [ ! -e "$0.2" ]; then\n'
                        '  [ -e "$0.1" ] && touch "$0.2" || touch "$0.1"; exit 1\nfi\nexec "$REAL_BIN" "$@"\n')
            os.chmod(bin_, 0o755)
            self.bin = bin_
        text = json.dumps({"connections": [{"id": "c1", "host": "a.lan"}]})
        probe, after, kept = self.run_store(text, before=flaky, probe_after=4500)
        self.assertFalse(probe["broken"], self.last_err[-1500:])
        self.assertEqual(probe["count"], 1)
        self.assertIsNone(kept)
        self.assertNotIn("not read yet", self.last_err)

    def test_a_huge_last_connected_is_left_out(self):
        text = json.dumps({"connections": [{"id": "c1", "host": "a.lan", "lastConnected": 100}]})
        probe, _, _ = self.run_store(text, {"c1": 200, "pad": "x" * (2 << 20)})
        self.assertFalse(probe["broken"])
        self.assertEqual(probe["last"], 100)


if __name__ == "__main__":
    unittest.main()
