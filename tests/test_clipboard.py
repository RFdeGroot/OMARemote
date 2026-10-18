import base64
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.join(HERE, "..", "native")
PLUGIN = os.path.join(NATIVE, "build", "qml")
QML = shutil.which("qml6") or shutil.which("qml")
MAX = 1024 * 1024  # RdpView::MaxClipBytes, kMaxClipBytes

# omarchy-plugin-marketplace#11850: a session tab must not read the clipboard with Qt's own reader
# (no deadline, no size limit, in the GUI thread), must not touch it at all when the connection
# does not share it, and keeps text from the session to a size.


def code(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


class Static(unittest.TestCase):
    def test_the_plugin_never_reads_the_clipboard_through_qt(self):
        offenders = []
        plugin = os.path.join(NATIVE, "plugin")
        for name in sorted(os.listdir(plugin)):
            if name.endswith((".cpp", ".h")):
                with open(os.path.join(plugin, name), encoding="utf-8") as f:
                    text = code(f.read())
                for m in re.finditer(r"clipboard\(\)\s*->\s*(text|mimeData)\s*\(", text):
                    offenders.append(f"{name}: {m.group(0)}")
        self.assertEqual(offenders, [], "read it with oma::readClipboard (clipread.h)")

    def test_the_session_view_follows_the_connections_switch(self):
        with open(os.path.join(HERE, "..", "ui", "SessionView.qml"), encoding="utf-8") as f:
            text = code(f.read())
        self.assertRegex(text, r"shareClipboard:[^\n]*\n[^\n]*clipboard !== false")


@unittest.skipUnless(QML and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qml6 and the native build (ninja -C native/build)")
class Runtime(unittest.TestCase):
    """The real RdpView, offscreen, attached to a fake session on a Unix socket."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        self.calls = os.path.join(self.dir, "calls")

    def stub(self, content, sleep=0):
        data = os.path.join(self.dir, "content")
        with open(data, "wb") as f:
            f.write(content)
        path = os.path.join(self.bin, "wl-paste")
        with open(path, "w") as f:
            f.write(f'#!/bin/sh\necho "$@" >> "{self.calls}"\nsleep {sleep}\nexec cat "{data}"\n')
        os.chmod(path, 0o755)

    def wl_paste_calls(self):
        if not os.path.exists(self.calls):
            return 0
        with open(self.calls) as f:
            return len(f.read().splitlines())

    def run_view(self, share, ms=1500, send=(), lines=(), frames=(), mode="focused"):
        """Runs the view; the fake session sends `send` 800 ms after the view attaches. Returns the
        RESULT, the clipboard texts the view offered the session, and Qt's log. `lines` are sent
        as they are, after `send`; `frames` are (memfd size, "frame w h stride") sent with the fd."""
        path = os.path.join(self.dir, "s")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        server.settimeout(10)
        received = bytearray()

        def session():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(0.1)
                start = time.monotonic()
                pending = [b"clip " + base64.b64encode(t) for t in send] + list(lines)
                fds = list(frames)
                while True:
                    if pending and time.monotonic() - start > 0.8:
                        conn.sendall(b"".join(l + b"\n" for l in pending))
                        pending = []
                    if fds and time.monotonic() - start > 0.8:
                        for size, line in fds:
                            fd = os.memfd_create("frame")
                            os.ftruncate(fd, size)
                            socket.send_fds(conn, [line + b"\n"], [fd])
                            os.close(fd)
                        fds = []
                    try:
                        chunk = conn.recv(65536)
                    except socket.timeout:
                        continue
                    except OSError:
                        return
                    if not chunk:
                        return
                    received.extend(chunk)

        thread = threading.Thread(target=session, daemon=True)
        thread.start()
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1",
                   QML_IMPORT_PATH=PLUGIN, PATH=os.pathsep.join([self.bin, os.environ.get("PATH", "")]))
        p = subprocess.run([QML, os.path.join(HERE, "qml", "clipboard.qml"), "--", path, "1" if share else "0", str(ms), mode],
                           env=env, capture_output=True, text=True, timeout=30)
        server.close()
        thread.join(5)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        import json
        result = json.loads(found.group(1))
        self.assertTrue(result["attached"], p.stderr)
        self.assertTrue(result["focused"], p.stderr)
        offered = [base64.b64decode(l[5:]).decode() for l in received.decode().splitlines() if l.startswith("clip ")]
        return result, offered, p.stderr

    def test_shared_clipboard_is_read_with_wl_paste_and_offered(self):
        self.stub(b"from the desktop")
        result, offered, _ = self.run_view(True)
        self.assertEqual(offered, ["from the desktop"])
        self.assertGreaterEqual(self.wl_paste_calls(), 1)
        with open(self.calls) as f:
            self.assertEqual(f.readline().split(), ["--no-newline", "--type", "text"])

    def test_not_shared_never_reads_or_writes_the_clipboard(self):
        self.stub(b"from the desktop")
        result, offered, _ = self.run_view(False, send=[b"from the session"])
        self.assertEqual(self.wl_paste_calls(), 0)
        self.assertEqual(offered, [])
        self.assertEqual(result["clipboard"], "copied")

    # A server never rewrites the clipboard while the user works elsewhere: what it sends while the
    # view lacks the keyboard is set when the view gets it back, unless the desktop copied since.
    def test_text_from_the_session_waits_for_the_keyboard(self):
        self.stub(b"from the desktop")
        result, _, err = self.run_view(True, ms=2500, send=[b"from the session"], mode="away")
        self.assertEqual(result["whileAway"], "copied", err)
        self.assertEqual(result["clipboard"], "from the session", err)

    def test_a_copy_elsewhere_wins_over_held_text(self):
        self.stub(b"from the desktop")
        result, _, err = self.run_view(True, ms=2500, send=[b"from the session"], mode="copy-away")
        self.assertEqual(result["clipboard"], "copied later", err)

    def test_a_copy_arriving_with_the_keyboard_wins_too(self):
        self.stub(b"from the desktop")
        result, _, err = self.run_view(True, ms=2500, send=[b"from the session"], mode="copy-return-away")
        self.assertEqual(result["clipboard"], "copied on return", err)

    def test_text_from_the_session_is_set_up_to_the_limit(self):
        self.stub(b"from the desktop")
        result, _, _ = self.run_view(True, send=[b"x" * (MAX + 1), b"from the session"])
        self.assertEqual(result["clipboard"], "from the session")

    def test_text_from_the_session_over_the_limit_is_dropped(self):
        self.stub(b"from the desktop")
        result, _, _ = self.run_view(True, send=[b"x" * (MAX + 1)])
        self.assertEqual(result["clipboard"], "copied")

    def test_too_large_is_not_offered(self):
        self.stub(b"a" * (MAX + 1))
        _, offered, err = self.run_view(True)
        self.assertEqual(offered, [])
        self.assertIn(f"more than {MAX} bytes", err)

    def test_slow_owner_neither_stalls_the_window_nor_is_offered(self):
        self.stub(b"late", sleep=5)
        result, offered, err = self.run_view(True, ms=3000)
        self.assertEqual(offered, [])
        self.assertIn("took more than 2000 ms", err)
        # Ten ticks a second while wl-paste hangs: the window kept running.
        self.assertGreaterEqual(result["ticks"], 20)

    # omarchy-plugin-marketplace#11853: every cursor shape a server sent was kept for good, and the
    # size check multiplied in int (32768 x 16384 x 4 wraps to INT_MIN and passed with 4 bytes).
    # A desktop size from the session is checked before it is mapped: 65535 a side would be a 17 GB
    # mapping in the window, and a memfd shorter than stride * height a SIGBUS on the first read.
    def test_frames_past_the_limit_or_past_the_memfd_are_not_mapped(self):
        frames = [(4096, b"frame 65535 65535 262140"),
                  (4096, b"frame 640 480 2560"),
                  (64 * 4 * 48, b"frame 64 48 100"),
                  (64 * 4 * 48, b"frame 64 48 256")]
        result, _, err = self.run_view(False, frames=frames)
        self.assertEqual(result["remote"], [64, 48], err)
        self.assertEqual(err.count("from the session was not shown"), 3, err)

    def test_cursors_are_kept_to_a_number(self):
        self.stub(b"")
        pixel = base64.b64encode(b"\xff" * 16)  # 2 x 2
        lines = [b"cursor %d 0 0 2 2 %s" % (i, pixel) for i in range(1, 201)] + [b"cursor-set 200"]
        result, _, err = self.run_view(False, lines=lines)
        self.assertEqual(result["cursors"], 64, err)

    def test_cursor_sizes_that_overflow_or_exceed_the_limit_are_refused(self):
        self.stub(b"")
        tiny = base64.b64encode(b"\xff" * 4)
        lines = [b"cursor 1 0 0 32768 16384 " + tiny, b"cursor-set 1",
                 b"cursor 2 0 0 513 1 " + base64.b64encode(b"\xff" * 513 * 4), b"cursor-set 2",
                 b"cursor 3 0 0 512 512 " + base64.b64encode(b"\xff" * 512 * 512 * 4)]
        result, _, err = self.run_view(False, lines=lines)
        self.assertEqual(result["cursors"], 1, err)


if __name__ == "__main__":
    unittest.main()
