"""An SSH tab's find bar and working directory: RdpView's half (what it asks omaremote-ssh, the
counts and the directory it keeps). The session's half is tests/test_ssh.py's Searching and
CurrentDirectory."""
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(os.path.dirname(HERE), "native", "build", "qml")
QML = shutil.which("qml6") or shutil.which("qml")


@unittest.skipUnless(QML and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qml6 and the native build (ninja -C native/build)")
class TheView(unittest.TestCase):
    def test_what_it_asks_the_counts_kept_in_range_and_the_working_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "s")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            server.settimeout(10)
            asked = []

            def session():
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(10)
                    buf = b""
                    while buf.count(b"\nsearch") + buf.startswith(b"search") < 4:
                        data = conn.recv(4096)
                        if not data:
                            break
                        buf += data
                    asked.extend(l for l in buf.decode().splitlines() if l.startswith("search"))
                    # A sane count, then one whose selected match is past the end, then nonsense.
                    conn.sendall(b"search-status 7 3\nsearch-status 5 9\nsearch-status -4 x\n")
                    # Where the shell is: one, then one far too long (none), then one again.
                    conn.sendall(b"cwd " + base64.b64encode(b"file://srv/home/a") + b"\ncwd " +
                                 base64.b64encode(b"/" + b"x" * 9000) + b"\ncwd " + base64.b64encode(b"/tmp") + b"\n")
                    # Bells: known words once each, the sound only as an absolute path, its volume
                    # kept to 0..1.
                    snd = base64.b64encode(b"/s/bell.oga")
                    conn.sendall(b"bell title bogus title attention\nbell audio=" + snd + b":7\n"
                                 b"bell audio=" + base64.b64encode(b"rel.oga") + b":0.2\nbell\n")
                    # Progress: pause keeps its value, nonsense goes nowhere, percent to 0..100.
                    conn.sendall(b"progress set 40\nprogress pause -1\nprogress bogus 5\nprogress error 900\n"
                                 b"progress remove -1\nprogress indeterminate -7\n")
                    conn.recv(4096)  # until the view has read them

            thread = threading.Thread(target=session, daemon=True)
            thread.start()
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QML_IMPORT_PATH=PLUGIN)
            p = subprocess.run([QML, os.path.join(HERE, "qml", "search.qml"), "--", path],
                               env=env, capture_output=True, text=True, timeout=30)
            server.close()
            thread.join(5)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        result = json.loads(found.group(1))
        self.assertNotIn("timeout", result, p.stderr)
        needle = base64.b64encode("Ab ü".encode()).decode()
        self.assertEqual(asked, ["search " + needle, "search-next", "search-prev", "search -"])
        # The selected one past the end is none; nonsense is nothing; detached, nothing again
        # (already nothing: no change).
        self.assertEqual(result["seen"], [[7, 3], [5, -1], [0, -1]])
        # Detached: none again.
        self.assertEqual(result["dirs"], ["file://srv/home/a", "", "/tmp", ""])
        # Detached: none again.
        self.assertEqual(result["progress"], [["set", 40], ["pause", 40], ["error", 100], ["", -1],
                                              ["indeterminate", -1], ["", -1]])
        self.assertEqual(result["bells"], [[["title", "attention"], "", 0.5], [["audio"], "/s/bell.oga", 1],
                                           [[], "", 0.5], [[], "", 0.5]])


TESTRUNNER = shutil.which("qmltestrunner6") or shutil.which("qmltestrunner") or (
    "/usr/lib/qt6/bin/qmltestrunner" if os.access("/usr/lib/qt6/bin/qmltestrunner", os.X_OK) else None)


@unittest.skipUnless(TESTRUNNER and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qmltestrunner and the native build")
class PrimarySelection(unittest.TestCase):
    """A terminal's middle click (Ghostty's primary-paste): the view reads the desktop's selection
    for the session only right after a middle click it sent (`want-primary` otherwise unanswered),
    once a click."""

    def test_answered_only_after_a_middle_click(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "s")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            server.settimeout(10)
            seen = []

            def session():
                import time
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(0.2)
                    conn.sendall(b"want-primary\n")  # no click yet: not answered
                    buf, end, asked = b"", time.time() + 8, False
                    while time.time() < end:
                        try:
                            data = conn.recv(4096)
                        except socket.timeout:
                            continue
                        if not data:
                            break
                        buf += data
                        *lines, buf = buf.split(b"\n")
                        for line in lines:
                            word = line.split(b" ")[0]
                            if word in (b"button", b"primary-paste"):
                                seen.append(line.decode())
                            if line.startswith(b"button 3 1") and not asked:
                                asked = True
                                conn.sendall(b"want-primary\n")
                            elif word == b"primary-paste":
                                conn.sendall(b"want-primary\n")  # again, no new click: not answered
                                end = min(end, time.time() + 1)

            thread = threading.Thread(target=session, daemon=True)
            thread.start()
            with open(os.path.join(HERE, "qml", "tst_primary.qml")) as f:
                qml = f.read().replace("@SOCKET@", path)
            test = os.path.join(folder, "tst_primary.qml")
            with open(test, "w") as f:
                f.write(qml)
            # No Wayland display: wl-paste fails, so the answer is "nothing", and the test never
            # reads this desktop's own selection.
            env = {k: v for k, v in os.environ.items() if k != "WAYLAND_DISPLAY"}
            env.update(QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QML_IMPORT_PATH=PLUGIN)
            p = subprocess.run([TESTRUNNER, "-import", PLUGIN, "-input", test], env=env,
                               capture_output=True, text=True, timeout=60)
            server.close()
            thread.join(5)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        answers = [l for l in seen if l.startswith("primary-paste")]
        self.assertEqual(answers, ["primary-paste -"], seen)
        self.assertTrue(seen.index(answers[0]) > 0 and seen[0].startswith("button 3 1"), seen)


if __name__ == "__main__":
    unittest.main()
