import array
import base64
import os
import re
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


def fake_server(listener, stall, size=(64, 48), pixels=False, got=None, cuts=(), burst=0):
    """RFB 3.8 without a password; then a partial, empty, or synthetic pixel update. Whatever the
    client sends after that lands in got; cuts are ServerCutTexts as (seconds after the update, text);
    burst: that many more small updates over the first second, as a busy screen sends."""
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
        conn.settimeout(0.05)
        start = time.monotonic()
        cuts = list(cuts)
        updates = [(i / max(1, burst), 2 + i % 50) for i in range(burst)]
        end = start + 30
        while time.monotonic() < end:
            while updates and time.monotonic() - start >= updates[0][0]:
                x = updates.pop(0)[1]
                conn.sendall(struct.pack(">BxH", 0, 1) + struct.pack(">HHHHi", x % 60, 4, 2, 3, 0)
                             + bytes((68, 85, 102, 7)) * 6)
            while cuts and time.monotonic() - start >= cuts[0][0]:
                text = cuts.pop(0)[1]
                conn.sendall(struct.pack(">B3xI", 3, len(text)) + text)
            try:
                data = conn.recv(4096)
                if not data:
                    return
                if got is not None:
                    got.extend(data)
            except socket.timeout:
                pass
            except OSError:
                return


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build (ninja -C native/build)")
class VncSession(unittest.TestCase):
    def start(self, stall, size=(64, 48), pixels=False, got=None, cuts=(), burst=0):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        threading.Thread(target=fake_server, args=(listener, stall, size, pixels, got, cuts, burst), daemon=True).start()
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

    def clip_session(self, lines=(), cuts=(), until=1.0, pixels=True, burst=0):
        """Attaches as the view does. lines: (seconds after connecting, line) sent to the session;
        cuts: what the server sends, see fake_server. Returns what the server got, and the
        clipboard texts the session passed to the view ("-" for empty)."""
        got = bytearray()
        p = self.start(stall=False, pixels=pixels, got=got, cuts=cuts, burst=burst)
        view = socket.socket(socket.AF_UNIX)
        for _ in range(50):
            try:
                view.connect(self.socket_path)
                break
            except OSError:
                time.sleep(0.1)
        said = bytearray()
        view.settimeout(0.05)
        lines = list(lines)
        start = None
        limit = time.monotonic() + 15
        while time.monotonic() < limit:
            try:
                socket_data = view.recv(1 << 20)
                said.extend(socket_data)
            except socket.timeout:
                pass
            if start is None and b"state connected" in said:
                start = time.monotonic()
            if start is None:
                continue
            while lines and time.monotonic() - start >= lines[0][0]:
                view.sendall(lines.pop(0)[1] + b"\n")
            if not lines and time.monotonic() - start >= until:
                break
        self.assertIsNotNone(start, "never connected")
        view.close()
        p.terminate()
        p.wait(5)
        self.session_log = p.stdout.read()
        clips = [l[5:] for l in said.split(b"\n") if l.startswith(b"clip ")]
        return bytes(got), [c.decode() if c == b"-" else base64.b64decode(c).decode() for c in clips]

    # ClientCutText: type 6, three padding bytes, the length, the text.
    EMPTY_CUT = struct.pack(">B3xI", 6, 0)
    SECRET = b"clip " + base64.b64encode(b"secret")

    def test_a_clear_after_an_offer_empties_the_servers_clipboard(self):
        got, _ = self.clip_session([(0.3, self.SECRET), (0.6, b"clip -")])
        offer = got.index(struct.pack(">B3xI", 6, 6) + b"secret")
        self.assertIn(self.EMPTY_CUT, got[offer:])

    def test_a_clear_with_nothing_offered_sends_nothing(self):
        got, _ = self.clip_session([(0.3, b"clip -")])
        self.assertNotIn(self.EMPTY_CUT, got)

    def test_a_clear_leaves_a_copy_made_on_the_server_alone(self):
        # Well past connecting and past the offer: a real copy there, which clears localClip.
        got, said = self.clip_session([(0.3, self.SECRET), (3.8, b"clip -")],
                                      cuts=[(0.0, b"at connect"), (3.2, b"theirs")], until=4.1)
        self.assertEqual(said, ["theirs"])
        self.assertIn(b"secret", got)
        self.assertNotIn(self.EMPTY_CUT, got)

    # As Gliff (native/gliff/clipboard.cpp, onOffer).
    def test_the_servers_clipboard_at_connect_stays_there(self):
        _, said = self.clip_session(cuts=[(0.2, b"at connect")], until=1.0)
        self.assertEqual(said, [])

    def test_only_its_first_text_counts_as_at_connect(self):
        _, said = self.clip_session(cuts=[(0.1, b"at connect"), (0.5, b"copied")], until=1.0)
        self.assertEqual(said, ["copied"])

    def test_a_first_text_well_after_the_picture_is_a_real_copy(self):
        _, said = self.clip_session(cuts=[(2.6, b"copied")], until=3.0)
        self.assertEqual(said, ["copied"])

    def test_text_crossing_our_offer_does_not_replace_it(self):
        # The first text is out of the way, then one arrives just after ours went.
        _, said = self.clip_session([(1.0, self.SECRET)], cuts=[(0.1, b"at connect"), (1.5, b"crossed")], until=2.0)
        self.assertEqual(said, [])

    def test_text_later_than_our_offer_is_a_real_copy(self):
        _, said = self.clip_session([(0.3, self.SECRET)], cuts=[(0.1, b"at connect"), (2.6, b"copied")], until=3.0)
        self.assertEqual(said, ["copied"])

    def test_empty_text_takes_away_only_what_came_from_the_server(self):
        _, said = self.clip_session(cuts=[(0.1, b"at connect"), (0.5, b"copied"), (0.9, b"")], until=1.3)
        self.assertEqual(said, ["copied", "-"])

    def test_empty_text_leaves_a_clipboard_it_did_not_give(self):
        _, said = self.clip_session(cuts=[(0.1, b"at connect"), (0.5, b"")], until=0.9)
        self.assertEqual(said, [])

    def test_empty_text_leaves_a_copy_made_here_while_unfocused(self):
        # A copy while unfocused reaches the session as "clip -": what the server gave is gone here.
        _, said = self.clip_session([(0.9, b"clip -")], cuts=[(0.1, b"at connect"), (0.5, b"copied"), (2.2, b"")],
                                    until=2.6)
        self.assertEqual(said, ["copied"])

    def test_empty_text_leaves_a_copy_made_here_after_its_text(self):
        _, said = self.clip_session([(0.9, self.SECRET)], cuts=[(0.1, b"at connect"), (0.5, b"copied"), (2.2, b"")],
                                    until=2.6)
        self.assertEqual(said, ["copied"])

    # Measuring a slow session (plans/vnc-speed.md): one line for each busy second.
    def test_a_busy_picture_logs_its_cost(self):
        self.clip_session(until=2.2, burst=20)
        found = re.search(r"stats: updates=(\d+)/s pixels=([\d.]+)M box=([\d.]+)M kbyte=(\d+)/s decode=(\d+)ms/s",
                          self.session_log)
        self.assertTrue(found, self.session_log)
        self.assertGreaterEqual(int(found.group(1)), 5)
        self.assertGreater(int(found.group(4)), 0)  # 12 KiB of pixels came over the network

    def test_a_still_picture_logs_nothing(self):
        self.clip_session(until=2.2, pixels=False)
        self.assertNotIn("stats:", self.session_log)

    def test_a_slowly_changing_picture_logs_nothing(self):
        # A blinking cursor or a clock: a change or two a second, all day. The log has a size cap.
        self.clip_session(until=2.2, burst=2)
        self.assertNotIn("stats:", self.session_log)

    def test_the_views_numbers_are_logged(self):
        self.clip_session([(0.2, b"view-stats 2000 24 12 8192")])
        self.assertIn("view: damage=12/s drawn=6/s upload=4.0MB/s", self.session_log)

    def test_a_slow_view_is_not_logged(self):
        self.clip_session([(0.2, b"view-stats 2000 10 6 4096")])
        self.assertNotIn("view:", self.session_log)

    def test_the_views_numbers_are_numbers_only(self):
        self.clip_session([(0.2, b"view-stats 2000 10 x 4096"), (0.3, b"view-stats 2000 10 6 4096 7"),
                           (0.4, b"view-stats 2000 -1 6 4096"), (0.5, b"view-stats 50 10 6 4096")])
        self.assertNotIn("view:", self.session_log)

    def test_an_idle_session_is_not_cut(self):
        p = self.start(stall=False)
        time.sleep(5)  # more than twice readTimeout
        self.assertIsNone(p.poll(), p.stdout.read() if p.poll() is not None else "")
        p.terminate()
        self.assertEqual(p.wait(5), 11)


if __name__ == "__main__":
    unittest.main()
