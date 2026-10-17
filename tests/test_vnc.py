import array
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


def fake_server(listener, stall, size=(64, 48), pixels=False):
    """RFB 3.8 without a password; then a partial, empty, or synthetic pixel update."""
    conn, _ = listener.accept()
    with conn:
        conn.sendall(b"RFB 003.008\n")
        conn.recv(12)
        conn.sendall(b"\x01\x01")  # one security type: none
        conn.recv(1)
        conn.sendall(struct.pack(">I", 0))
        conn.recv(1)  # ClientInit
        pixel = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        conn.sendall(struct.pack(">HH", *size) + pixel + struct.pack(">I", 4) + b"fake")
        time.sleep(0.3)  # SetPixelFormat, SetEncodings, the first update request
        if pixels:
            # Padding is deliberately not alpha, including both zero and nonzero values.
            full = b"".join(bytes((17, 34, 51, i % 256)) for i in range(64 * 48))
            patch = bytes((68, 85, 102, 7)) * 6
            conn.sendall(struct.pack(">BxH", 0, 2)
                         + struct.pack(">HHHHi", 0, 0, 64, 48, 0) + full
                         + struct.pack(">HHHHi", 3, 4, 2, 3, 0) + patch)
        elif stall:
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
class VncSession(unittest.TestCase):
    def start(self, stall, size=(64, 48), pixels=False):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        threading.Thread(target=fake_server, args=(listener, stall, size, pixels), daemon=True).start()
        port = listener.getsockname()[1]
        p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env=dict(os.environ, OMAREMOTE_SOCKET=os.path.join(d, "s")), text=True)
        self.addCleanup(p.stdout.close)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write(f"host=127.0.0.1\nport={port}\nreadTimeout=2\n")
        p.stdin.close()
        self.socket_path = os.path.join(d, "s")
        return p

    def test_framebuffer_padding_is_opaque_without_changing_rgb(self):
        p = self.start(stall=False, pixels=True)
        ui = socket.socket(socket.AF_UNIX)
        self.addCleanup(ui.close)
        ui.settimeout(5)
        deadline = time.monotonic() + 5
        while True:
            try:
                ui.connect(self.socket_path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    self.fail("VNC session did not open its UI socket")
                time.sleep(0.01)
        received = b""
        frame_fd = None
        while b"damage " not in received or frame_fd is None:
            data, ancillary, _, _ = ui.recvmsg(4096, socket.CMSG_SPACE(4 * 4))
            self.assertTrue(data, "session closed before sending a frame")
            received += data
            for level, kind, payload in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    fds = array.array("i")
                    fds.frombytes(payload[:len(payload) - len(payload) % fds.itemsize])
                    for fd in fds:
                        self.addCleanup(os.close, fd)
                        frame_fd = fd
        self.assertIn(b"frame 64 48 256\n", received)
        actual = os.pread(frame_fd, 64 * 48 * 4, 0)
        expected = bytearray(bytes((17, 34, 51, 255)) * (64 * 48))
        for y in range(4, 7):
            offset = (y * 64 + 3) * 4
            expected[offset:offset + 8] = bytes((68, 85, 102, 255)) * 2
        self.assertEqual(actual, expected)
        p.terminate()
        self.assertEqual(p.wait(5), 11)

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

    def test_a_desktop_past_8192_a_side_ends_the_session(self):
        # 65535x65535 would be a 17 GB shared framebuffer, mapped by the manager window.
        p = self.start(stall=False, size=(65535, 65535))
        try:
            rc = p.wait(15)
        except subprocess.TimeoutExpired:
            self.fail("omaremote-vnc took a 65535x65535 desktop")
        log = p.stdout.read()
        self.assertIn("larger than OMARemote shows", log)
        self.assertNotIn("connected to fake", log)
        self.assertNotEqual(rc, 0)

    def test_an_idle_session_is_not_cut(self):
        p = self.start(stall=False)
        time.sleep(5)  # more than twice readTimeout
        self.assertIsNone(p.poll(), p.stdout.read() if p.poll() is not None else "")
        p.terminate()
        self.assertEqual(p.wait(5), 11)


if __name__ == "__main__":
    unittest.main()
