"""Where an RdpView puts a picture on the screen's pixels, at whole and fractional scales."""
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
class PixelForPixel(unittest.TestCase):
    def shown(self, scale, left, width, height, frame):
        """The picture's rect in screen pixels, for a view at `left` showing a frame of `frame`."""
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "s")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            server.settimeout(10)

            def session():
                conn, _ = server.accept()
                with conn:
                    fd = os.memfd_create("frame")
                    os.ftruncate(fd, frame[0] * frame[1] * 4)
                    socket.send_fds(conn, [b"frame %d %d %d\n" % (frame[0], frame[1], frame[0] * 4)], [fd])
                    os.close(fd)
                    while conn.recv(4096):
                        pass

            thread = threading.Thread(target=session, daemon=True)
            thread.start()
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1",
                       QT_SCALE_FACTOR=str(scale), QML_IMPORT_PATH=PLUGIN)
            p = subprocess.run([QML, os.path.join(HERE, "qml", "picture.qml"), "--", path,
                                str(left), str(width), str(height)],
                               env=env, capture_output=True, text=True, timeout=30)
            server.close()
            thread.join(5)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        return json.loads(found.group(1))

    def assert_on_whole_pixels(self, r, frame):
        self.assertAlmostEqual(r["x"], round(r["x"]), places=6, msg=r)
        self.assertAlmostEqual(r["y"], round(r["y"]), places=6, msg=r)
        self.assertAlmostEqual(r["width"], frame[0], places=6)
        self.assertAlmostEqual(r["height"], frame[1], places=6)

    # An RDP desktop's width is even, so an odd tab leaves half a pixel over: centred as it is,
    # the picture falls between two pixels and columns are drawn twice or not at all.
    def test_an_even_desktop_in_an_odd_tab_starts_on_a_whole_pixel(self):
        self.assert_on_whole_pixels(self.shown(1.25, 0, 300, 200, (374, 250)), (374, 250))

    def test_so_it_does_at_150_percent(self):
        self.assert_on_whole_pixels(self.shown(1.5, 0, 301, 200, (450, 300)), (450, 300))

    def test_a_tab_starting_between_two_pixels_is_taken_into_account(self):
        self.assert_on_whole_pixels(self.shown(1.25, 285, 304, 200, (380, 250)), (380, 250))

    def test_a_picture_that_is_scaled_is_still_centred_in_the_tab(self):
        # Larger than the tab: fitted, and no longer pixel for pixel.
        r = self.shown(1.25, 0, 200, 200, (500, 250))
        self.assertAlmostEqual(r["width"], 250, places=3)
        self.assertAlmostEqual(r["y"], (250 - r["height"]) / 2, places=3)


if __name__ == "__main__":
    unittest.main()
