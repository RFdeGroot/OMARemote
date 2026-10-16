import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "native", "build", "omaremote-vnc")

# A VNC server that stops in the middle of a message held omaremote-vnc inside libvncclient for
# good, deaf to SIGTERM (found while testing omarchy-plugin-marketplace#11853): now a read gives
# up after readTimeout seconds, and an idle session is still not cut.


def fake_server(listener, stall):
    """RFB 3.8 without a password; then half a FramebufferUpdate (stall) or a whole empty one."""
    conn, _ = listener.accept()
    with conn:
        conn.sendall(b"RFB 003.008\n")
        conn.recv(12)
        conn.sendall(b"\x01\x01")  # one security type: none
        conn.recv(1)
        conn.sendall(struct.pack(">I", 0))
        conn.recv(1)  # ClientInit
        pixel = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        conn.sendall(struct.pack(">HH", 64, 48) + pixel + struct.pack(">I", 4) + b"fake")
        time.sleep(0.3)  # SetPixelFormat, SetEncodings, the first update request
        if stall:
            conn.sendall(struct.pack(">BxH", 0, 1) + b"\x00\x00\x00\x00")  # 4 of the 12 header bytes
        else:
            conn.sendall(struct.pack(">BxH", 0, 0))
        conn.settimeout(0.2)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            try:
                if not conn.recv(4096):
                    return
            except socket.timeout:
                pass
            except OSError:
                return


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build (ninja -C native/build)")
class ReadDeadline(unittest.TestCase):
    def start(self, stall):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        threading.Thread(target=fake_server, args=(listener, stall), daemon=True).start()
        port = listener.getsockname()[1]
        p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env=dict(os.environ, OMAREMOTE_SOCKET=os.path.join(d, "s")), text=True)
        self.addCleanup(p.stdout.close)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write(f"host=127.0.0.1\nport={port}\nreadTimeout=2\n")
        p.stdin.close()
        return p

    def test_a_server_stalling_mid_message_ends_the_session(self):
        p = self.start(stall=True)
        started = time.monotonic()
        try:
            rc = p.wait(15)
        except subprocess.TimeoutExpired:
            self.fail("omaremote-vnc still waits for the rest of the message")
        log = p.stdout.read()
        self.assertIn("connected to fake", log)
        self.assertEqual(rc, 147, log)
        self.assertLess(time.monotonic() - started, 10)

    def test_an_idle_session_is_not_cut(self):
        p = self.start(stall=False)
        time.sleep(5)  # more than twice readTimeout
        self.assertIsNone(p.poll(), p.stdout.read() if p.poll() is not None else "")
        p.terminate()
        self.assertEqual(p.wait(5), 11)


if __name__ == "__main__":
    unittest.main()
