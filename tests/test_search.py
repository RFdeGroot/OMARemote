"""An SSH tab's find bar: RdpView's half (what it asks omaremote-ssh, the counts it keeps). The
session's half, the search itself, is tests/test_ssh.py's Searching."""
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
    def test_what_it_asks_and_the_counts_kept_in_range(self):
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


if __name__ == "__main__":
    unittest.main()
