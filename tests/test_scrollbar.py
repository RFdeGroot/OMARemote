"""An SSH tab's scrollbar: omaremote-ssh's `scrollbar` lines, through RdpView, and back as `scroll-to`."""
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
HELPER = os.path.join(os.path.dirname(HERE), "native", "build", "omaremote-ssh")
QML = shutil.which("qml6") or shutil.which("qml")


@unittest.skipUnless(QML and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qml6 and the native build (ninja -C native/build)")
class TheView(unittest.TestCase):
    def test_rows_kept_in_range_a_row_asked_for_and_zero_once_detached(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "s")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            server.settimeout(10)
            asked, told = [], []

            def session():
                conn, _ = server.accept()
                with conn:
                    fd = os.memfd_create("frame")
                    os.ftruncate(fd, 64 * 64 * 4)
                    socket.send_fds(conn, [b"frame 64 64 256\n"], [fd])
                    os.close(fd)
                    # A sane one, then one out of range: an offset past the end, a screen longer
                    # than the whole.
                    conn.sendall(b"scrollbar 1000 900 50\nscrollbar 5 99 9\n")
                    conn.settimeout(10)
                    buf = b""
                    while b"scroll-to" not in buf:
                        data = conn.recv(4096)
                        if not data:
                            break
                        buf += data
                    asked.extend(l for l in buf.decode().splitlines() if l.startswith("scroll-to"))
                    told.extend(l for l in buf.decode().splitlines() if l in ("blur",) or l.startswith("focus"))

            thread = threading.Thread(target=session, daemon=True)
            thread.start()
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QML_IMPORT_PATH=PLUGIN)
            p = subprocess.run([QML, os.path.join(HERE, "qml", "scrollbar.qml"), "--", path],
                               env=env, capture_output=True, text=True, timeout=30)
            server.close()
            thread.join(5)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        result = json.loads(found.group(1))
        self.assertNotIn("timeout", result, p.stderr)
        self.assertEqual(result["seen"], [[1000, 900, 50], [5, 0, 5], [0, 0, 0]])
        self.assertEqual(asked, ["scroll-to 7"])
        # Where the keyboard is, said at attach: this view does not have it.
        self.assertEqual(told[:1], ["blur"])


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class TheSession(unittest.TestCase):
    """omaremote-ssh says where the view is in the history, follows a `scroll-to`, says it again
    to a view that attaches later, and says there is no history on the alternate screen."""

    def run_session(self, script, steps):
        """Runs script; for each step (lines to send, or None to reattach) the last `scrollbar`
        line after it, as (total, offset, length)."""
        import time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            config = "\n".join(["arg=/bin/sh", "arg=-c", f"arg={script}", "reconnect=0", "font=monospace",
                                "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            c = None
            try:
                def attach():
                    s = socket.socket(socket.AF_UNIX)
                    for _ in range(100):
                        try:
                            s.connect(sock)
                            break
                        except OSError:
                            time.sleep(0.05)
                    s.sendall(b"size 400 300 100\n")
                    s.settimeout(0.1)
                    return s

                def last_bar(wait):
                    """The last scrollbar line within `wait` seconds (reading all the while)."""
                    bar, buf, end = None, b"", time.time() + wait
                    while time.time() < end:
                        try:
                            data = c.recv(65536)
                        except socket.timeout:
                            continue
                        if not data:
                            break
                        buf += data
                        *lines, buf = buf.split(b"\n")
                        for line in lines:
                            if line.startswith(b"scrollbar "):
                                bar = tuple(int(v) for v in line.split()[1:4])
                    return bar

                c = attach()
                seen = [last_bar(3)]
                for step in steps:
                    if step is None:
                        c.close()
                        c = attach()
                    else:
                        c.sendall(step)
                    seen.append(last_bar(1.5))
                return seen
            finally:
                if c:
                    c.close()
                p.kill()
                p.wait()

    def test_where_the_view_is_in_the_history(self):
        page_up = b"key 1 42 65505\nkey 1 104 65365\nkey 0 104 65365\nkey 0 42 65505\n"
        at_bottom, paged, top, again = self.run_session(
            "seq 1 200; sleep 30", [page_up, b"scroll-to 0\n", None])
        total, offset, length = at_bottom
        self.assertGreater(total, 200)           # the history and the screen
        self.assertEqual(offset, total - length)  # at the bottom
        self.assertEqual(paged, (total, offset - length, length))  # a page up
        self.assertEqual(top, (total, 0, length))
        self.assertEqual(again, top)             # told again to a view that attaches later

    def test_no_history_on_the_alternate_screen(self):
        enter = b"key 1 28 65293\nkey 0 28 65293\n"  # the shell switches once it reads a line
        (at_bottom, alt) = self.run_session("seq 1 200; read x; printf '\\033[?1049h'; sleep 30", [enter])
        self.assertGreater(at_bottom[0], at_bottom[2])
        self.assertEqual(alt[0], alt[2])         # nothing above the screen: no bar


if __name__ == "__main__":
    unittest.main()
