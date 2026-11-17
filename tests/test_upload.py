"""What an RdpView sends to the GPU: only what the session says changed (plans/vnc-speed.md)."""
import mmap
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(os.path.dirname(HERE), "native", "build", "qml")
QML = shutil.which("qml6") or shutil.which("qml")
W, H = 64, 48
OLD, NEW, HIDDEN = (10, 20, 30), (200, 100, 50), (0, 255, 0)  # R G B


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6, width, height, maxval, then exactly one whitespace byte before the pixels (a pixel byte
    # may itself look like whitespace, so no split over the data).
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    assert fields[0] == b"P6", fields[0]
    w = int(fields[1])
    pixels = data[pos + 1:]
    return lambda x, y: tuple(pixels[(y * w + x) * 3:(y * w + x) * 3 + 3])


@unittest.skipUnless(QML and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qml6 and the native build (ninja -C native/build)")
class OnlyWhatChanged(unittest.TestCase):
    def show(self, env, again=False, damage=b"damage 8 8 16 8"):
        """A frame of OLD; 0.6 s later a NEW patch, damaged, and a HIDDEN pixel that is not. With
        again, a second frame of the same size instead, all HIDDEN, and no damage line."""
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        path, ppm = os.path.join(folder, "s"), os.path.join(folder, "shown.ppm")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        server.settimeout(10)

        def put(m, x, y, rgb):
            m[(y * W + x) * 4:(y * W + x) * 4 + 4] = bytes((rgb[2], rgb[1], rgb[0], 255))

        def session():
            conn, _ = server.accept()
            with conn:
                fd = os.memfd_create("frame")
                os.ftruncate(fd, W * H * 4)
                m = mmap.mmap(fd, W * H * 4)
                for y in range(H):
                    for x in range(W):
                        put(m, x, y, OLD)
                socket.send_fds(conn, [b"frame %d %d %d\n" % (W, H, W * 4)], [fd])
                os.close(fd)
                time.sleep(0.6)
                if again:
                    # A reconnect: a new mapping of the same size. Its pixels are all new.
                    fd = os.memfd_create("frame")
                    os.ftruncate(fd, W * H * 4)
                    m = mmap.mmap(fd, W * H * 4)
                    for y in range(H):
                        for x in range(W):
                            put(m, x, y, HIDDEN)
                    socket.send_fds(conn, [b"frame %d %d %d\n" % (W, H, W * 4)], [fd])
                    os.close(fd)
                for y in range(8, 16) if not again else ():
                    for x in range(8, 24):
                        put(m, x, y, NEW)
                if not again:
                    put(m, 50, 40, HIDDEN)
                    conn.sendall(damage + b"\n")
                conn.settimeout(0.2)
                end = time.monotonic() + 15
                while time.monotonic() < end:
                    try:
                        if not conn.recv(4096):
                            return
                    except socket.timeout:
                        pass
                    except OSError:
                        return

        thread = threading.Thread(target=session, daemon=True)
        thread.start()
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QT_SCALE_FACTOR="1",
                   QML_IMPORT_PATH=PLUGIN, **env)
        p = subprocess.run([QML, os.path.join(HERE, "qml", "upload.qml"), "--", path, ppm],
                           env=env, capture_output=True, text=True, timeout=30)
        server.close()
        thread.join(5)
        self.assertEqual(p.returncode, 0, p.stderr)
        return read_ppm(ppm)

    def test_on_the_gpu_only_the_damaged_part_is_uploaded(self):
        at = self.show({"QT_QUICK_BACKEND": "rhi", "QSG_RHI_BACKEND": "opengl"})
        if at(0, 0) == (0, 0, 0):
            self.skipTest("no OpenGL offscreen here")
        self.assertEqual(at(0, 0), OLD)
        self.assertEqual(at(8, 8), NEW)
        self.assertEqual(at(23, 15), NEW)
        self.assertEqual(at(24, 15), OLD)
        self.assertEqual(at(8, 16), OLD)
        # Changed in the frame but never damaged: the GPU still has the old pixel. Proves the part.
        self.assertEqual(at(50, 40), OLD)

    def test_a_large_change_heals_what_was_not_reported(self):
        # A quarter of the picture changed: once it settles, the whole picture goes up again, so a
        # change the session failed to report does not stay on screen (a window dragged over RDP).
        at = self.show({"QT_QUICK_BACKEND": "rhi", "QSG_RHI_BACKEND": "opengl"}, damage=b"damage 8 8 32 24")
        if at(0, 0) == (0, 0, 0):
            self.skipTest("no OpenGL offscreen here")
        self.assertEqual(at(8, 8), NEW)
        self.assertEqual(at(50, 40), HIDDEN)

    def test_a_new_frame_of_the_same_size_is_uploaded_whole(self):
        at = self.show({"QT_QUICK_BACKEND": "rhi", "QSG_RHI_BACKEND": "opengl"}, again=True)
        if at(0, 0) == (0, 0, 0):
            self.skipTest("no OpenGL offscreen here")
        self.assertEqual(at(0, 0), HIDDEN)
        self.assertEqual(at(50, 40), HIDDEN)

    def test_without_a_gpu_the_whole_picture_is_drawn(self):
        at = self.show({})
        self.assertEqual(at(8, 8), NEW)
        self.assertEqual(at(50, 40), HIDDEN)
