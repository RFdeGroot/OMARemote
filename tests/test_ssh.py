import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "native", "build", os.environ.get("OMAREMOTE_SSH_HELPER", "omaremote-ssh"))

# Stands in for ssh: each run takes the next line of $FAKE_SSH_PLAN ("up", or a failure line to
# print and exit 255 with, or "exit" for a shell that ends) and counts its runs in $FAKE_SSH_DIR/n.
FAKE_SSH = r"""#!/bin/sh
n=$(cat "$FAKE_SSH_DIR/n" 2>/dev/null || echo 0)
echo $((n + 1)) > "$FAKE_SSH_DIR/n"
step=$(printf '%s\n' "$FAKE_SSH_PLAN" | sed -n "$((n + 1))p")
case $step in
  up:*) echo "Welcome"; sleep 0.4; echo "${step#up:}"; exit 255 ;;
  full:*) seq 1 200; printf '\033[5;1H'; sleep 0.2; echo "${step#full:}"; exit 255 ;;
  slow:*) sleep 0.05; echo "${step#slow:}"; exit 255 ;;
  silent:*) sleep 0.6; echo "${step#silent:}"; exit 255 ;;
  stopped:*) echo "Welcome"; sleep 0.4; exit "${step#stopped:}" ;;
  stopnow:*) exit "${step#stopnow:}" ;;
  wait) sleep 30; exit 0 ;;
  exit) echo "bye"; exit 0 ;;
  *) echo "$step"; exit 255 ;;
esac
"""


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Reconnect(unittest.TestCase):
    """omaremote-ssh trying a lost connection again in the same terminal, at 1/1000 of the pace."""

    def run_plan(self, plan, reconnect=True, pace=1):
        with tempfile.TemporaryDirectory() as d:
            ssh = os.path.join(d, "ssh")
            with open(ssh, "w") as f:
                f.write(FAKE_SSH)
            os.chmod(ssh, 0o700)
            config = "\n".join([f"arg={ssh}", "arg=pc.lan", "host=pc.lan", "font=monospace", "fontSize=10",
                                f"reconnect={1 if reconnect else 0}", f"reconnectMs={pace}"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=os.path.join(d, "s"), FAKE_SSH_DIR=d,
                       FAKE_SSH_PLAN="\n".join(plan), QT_QPA_PLATFORM="offscreen")
            out = subprocess.run([HELPER], input=config, capture_output=True, text=True, env=env, timeout=60)
            with open(os.path.join(d, "n")) as f:
                runs = int(f.read())
            return out.returncode, out.stdout + out.stderr, runs

    def test_a_dropped_connection_is_tried_until_it_answers(self):
        rc, log, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe",
                                       "ssh: connect to host pc.lan port 22: Connection refused",
                                       "ssh: connect to host pc.lan port 22: Connection timed out",
                                       "exit"])
        self.assertEqual((rc, runs), (0, 4))
        self.assertIn("connection lost: client_loop: send disconnect: Broken pipe; trying again", log)
        self.assertIn("session ended (0)", log)

    def test_a_shell_stopped_by_a_shutdown_is_tried_again(self):
        # A reboot that stops the shell (hang-up, terminate) before it cuts the connection.
        for code in (129, 143):
            rc, log, runs = self.run_plan([f"stopped:{code}",
                                           "ssh: connect to host pc.lan port 22: Connection refused", "exit"])
            self.assertEqual((rc, runs), (0, 3), code)
            self.assertIn(f"connection lost: the remote shell was stopped ({code}); trying again", log)

    def test_a_shell_ending_otherwise_is_no_drop(self):
        rc, _, runs = self.run_plan(["stopped:1"])
        self.assertEqual((rc, runs), (1, 1))
        rc, _, runs = self.run_plan(["stopped:143"], reconnect=False)
        self.assertEqual((rc, runs), (143, 1))

    def test_a_shell_stopped_at_once_is_not_retried(self):
        rc, _, runs = self.run_plan(["stopnow:143"], pace=1000)
        self.assertEqual((rc, runs), (143, 1))

    def test_a_connection_that_never_came_up_is_not_retried(self):
        rc, log, runs = self.run_plan(["ssh: connect to host pc.lan port 22: Connection refused"])
        self.assertEqual((rc, runs), (255, 1))
        self.assertIn("connection failed: ssh: connect to host pc.lan port 22: Connection refused", log)

    def test_a_refusal_before_signing_in_is_not_retried(self):
        # fail2ban or MaxStartups: trying again would only make it worse.
        rc, _, runs = self.run_plan(["up:kex_exchange_identification: Connection closed by remote host"])
        self.assertEqual((rc, runs), (255, 1))

    def test_a_refused_sign_in_ends_the_retries(self):
        rc, log, runs = self.run_plan(["up:Connection to pc.lan closed by remote host.",
                                       "user@pc.lan: Permission denied (publickey)."])
        self.assertEqual((rc, runs), (255, 2))
        self.assertIn("connection failed: user@pc.lan: Permission denied (publickey).", log)

    def test_it_gives_up_after_ten_minutes(self):
        # 10 minutes at this pace are 3 s, the pauses 10, 20, 40, then 75 ms: it stops by itself
        # (well before the 500 tries the plan has), failing with the last try's words.
        rc, log, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe"]
                                      + ["ssh: connect to host pc.lan port 22: No route to host"] * 500, pace=5)
        self.assertEqual(rc, 255)
        self.assertTrue(5 < runs < 200, runs)
        self.assertEqual(log.count("connection lost:"), 1)
        self.assertIn("connection failed: ssh: connect to host pc.lan port 22: No route to host", log)

    def test_a_server_that_keeps_saying_broken_pipe_is_not_dialled_forever(self):
        # Its own "Broken pipe" and exit 255, again and again, with no one typing: 20 drops, then it ends.
        rc, _, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe"] * 40)
        self.assertEqual((rc, runs), (255, 21))

    def test_a_slow_failing_try_is_no_new_drop(self):
        # A screen full of output, the cursor moved up, then the drop; each try then fails slowly
        # (as a timeout does). Only that ssh's own words count, never what is left on the screen.
        rc, log, runs = self.run_plan(["full:client_loop: send disconnect: Broken pipe"]
                                      + ["slow:ssh: connect to host pc.lan port 22: Connection timed out"] * 500)
        self.assertEqual(rc, 255)
        self.assertEqual(log.count("connection lost:"), 1)
        self.assertLess(runs, 80)

    def view(self, plan, answer, runs_first=0):
        """Runs a plan with a stand-in view on the session socket that answers the first
        "reconnect wait" (or "trying") line with answer, once the stand-in ssh has started
        runs_first times (a "trying" line comes before its ssh runs; on a busy machine an answer
        could otherwise land first); returns (rc, log, runs, lines seen)."""
        import socket, threading
        with tempfile.TemporaryDirectory() as d:
            ssh = os.path.join(d, "ssh")
            with open(ssh, "w") as f:
                f.write(FAKE_SSH)
            os.chmod(ssh, 0o700)
            sock = os.path.join(d, "s")
            config = "\n".join([f"arg={ssh}", "arg=pc.lan", "host=pc.lan", "font=monospace", "fontSize=10",
                                "reconnectMs=50"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, FAKE_SSH_DIR=d, FAKE_SSH_PLAN="\n".join(plan),
                       QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            seen = []

            def started():
                try:
                    with open(os.path.join(d, "n")) as f:
                        return int(f.read() or 0)
                except (OSError, ValueError):
                    return 0

            def ui():
                import time
                c = socket.socket(socket.AF_UNIX)
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                buf, answered = b"", False
                c.settimeout(20)
                try:
                    while True:
                        chunk = c.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            if line.startswith(b"reconnect"):
                                seen.append(line.decode())
                                if not answered and line.startswith(answer[1]):
                                    until = time.monotonic() + 10
                                    while started() < runs_first and time.monotonic() < until:
                                        time.sleep(0.02)
                                    c.sendall(answer[0])
                                    answered = True
                except OSError:
                    pass
            t = threading.Thread(target=ui, daemon=True)
            t.start()
            out = p.stdout.read()
            p.wait(30)
            t.join(5)
            with open(os.path.join(d, "n")) as f:
                runs = int(f.read())
            return p.returncode, out, runs, seen

    def test_the_banner_stays_while_a_try_waits_for_the_computer(self):
        # A try that prints nothing for longer than kUpMs (a connect still waiting), then fails.
        _, _, runs, seen = self.view(["up:client_loop: send disconnect: Broken pipe",
                                      "silent:ssh: connect to host pc.lan port 22: Connection timed out", "exit"],
                                     (b"", b"never"))
        self.assertEqual(runs, 3)
        self.assertEqual(seen[:4], ["reconnect wait 1 2", "reconnect trying 1", "reconnect wait 2 4", "reconnect trying 2"])
        self.assertEqual(seen[-1], "reconnect off")

    def test_cancel_gives_the_drop_up(self):
        rc, log, runs, seen = self.view(["up:client_loop: send disconnect: Broken pipe"] + ["wait"] * 3,
                                        (b"reconnect cancel\n", b"reconnect wait"))
        self.assertEqual((rc, runs), (255, 1))
        self.assertEqual(seen[0], "reconnect wait 1 2")
        self.assertEqual(seen[-1], "reconnect off")
        self.assertIn("reconnecting cancelled", log)
        self.assertIn("connection failed: client_loop: send disconnect: Broken pipe", log)

    def test_cancel_ends_a_try_that_hangs(self):
        rc, log, runs, seen = self.view(["up:client_loop: send disconnect: Broken pipe", "wait"],
                                        (b"reconnect cancel\n", b"reconnect trying"), runs_first=2)
        self.assertEqual((rc, runs), (255, 2))
        self.assertIn("reconnect trying 1", seen)
        self.assertIn("connection failed: client_loop: send disconnect: Broken pipe", log)

    def test_try_now_skips_the_pause(self):
        rc, _, runs, seen = self.view(["up:client_loop: send disconnect: Broken pipe", "exit"],
                                      (b"reconnect now\n", b"reconnect wait"))
        self.assertEqual((rc, runs), (0, 2))
        self.assertEqual(seen[-1], "reconnect off")

    def test_switched_off_it_ends_as_before(self):
        rc, _, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe", "exit"], reconnect=False)
        self.assertEqual((rc, runs), (255, 1))


# Asks the terminal whether it shows Kitty images, then records what comes back for a second.
KITTY_QUERY = r"""
import os, select, sys, termios, tty, time
tty.setraw(0)
os.write(1, b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c")
got, end = b"", time.time() + 1.0
while time.time() < end:
    if select.select([0], [], [], 0.1)[0]:
        got += os.read(0, 4096)
open(sys.argv[1], "wb").write(got)
"""


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class KittyGraphics(unittest.TestCase):
    def test_images_are_off(self):
        # Nothing here shows images, and stored ones could fill memory: the protocol is off, so
        # the query gets no answer (the device attributes after it do: the program was listening).
        with tempfile.TemporaryDirectory() as d:
            prog, rec = os.path.join(d, "q.py"), os.path.join(d, "rec")
            with open(prog, "w") as f:
                f.write(KITTY_QUERY)
            config = "\n".join(["arg=/usr/bin/python3", "arg=-I", f"arg={prog}", f"arg={rec}", "reconnect=0",
                                "font=monospace", "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=os.path.join(d, "s"), QT_QPA_PLATFORM="offscreen")
            subprocess.run([HELPER], input=config, capture_output=True, text=True, env=env, timeout=30)
            with open(rec, "rb") as f:
                got = f.read()
        self.assertIn(b"\x1b[?", got)  # the device attributes
        self.assertNotIn(b"\x1b_G", got)

# A program that asks the terminal 20000 times for its attributes and never reads the answers,
# then sets a title (after "pid " with its own pid in $1) and waits: the pty's input fills up.
DEAF_PROGRAM = r"""
import os, sys, time, tty
tty.setraw(0)
os.write(1, b"\x1b[c" * 20000)
os.write(1, b"\x1b]0;after the flood\x07")
time.sleep(30)
"""


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class DeafServer(unittest.TestCase):
    """A remote program that stops reading its input fills the pty: the terminal's answers (and
    keys, pastes) can no longer be written. That must not hang the session for good."""

    def start(self, d):
        prog = os.path.join(d, "deaf.py")
        with open(prog, "w") as f:
            f.write(DEAF_PROGRAM)
        sock = os.path.join(d, "s")
        config = "\n".join(["arg=/usr/bin/python3", "arg=-I", f"arg={prog}", "reconnect=0",
                            "font=monospace", "fontSize=10"]) + "\n"
        env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
        p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True, env=env)
        p.stdin.write(config)
        p.stdin.close()
        return p, sock

    def test_a_stop_ends_it_while_the_server_reads_nothing(self):
        import signal, time
        with tempfile.TemporaryDirectory() as d:
            p, _ = self.start(d)
            try:
                time.sleep(1.5)
                p.send_signal(signal.SIGTERM)
                p.wait(4)
            finally:
                p.kill()
                p.wait()

    def test_answers_nobody_reads_are_dropped_and_the_terminal_goes_on(self):
        import base64, socket, time
        with tempfile.TemporaryDirectory() as d:
            p, sock = self.start(d)
            try:
                c = socket.socket(socket.AF_UNIX)
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                c.settimeout(1)
                buf, title, end = b"", None, time.time() + 15
                while title is None and time.time() < end:
                    try:
                        chunk = c.recv(1 << 20)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        if line.startswith(b"title "):
                            title = base64.b64decode(line[6:])
                self.assertEqual(title, b"after the flood")
            finally:
                p.kill()
                p.wait()


GLYPH_TEST = os.path.join(HERE, "..", "native", "build", "ssh-glyph-test")


@unittest.skipUnless(os.access(GLYPH_TEST, os.X_OK), "native build missing: ninja -C native/build")
class GlyphRules(unittest.TestCase):
    """Icons are sized as Ghostty sizes them: its own test cases (native/ssh/glyph_test.cpp)."""

    def test_ghosttys_cases(self):
        out = subprocess.run([GLYPH_TEST], capture_output=True, text=True, timeout=10)
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "ok"), out.stdout)


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class SeeThrough(unittest.TestCase):
    """Omarchy's see-through terminals: the view's `opacity` line sets the alpha of the terminal's
    default background in the shared frame (premultiplied B G R A); a cell with a colour of its
    own stays solid, and 255 is solid again."""

    def test_the_default_background_takes_the_alpha_and_coloured_cells_do_not(self):
        import mmap, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            config = "\n".join(["arg=/bin/sh", "arg=-c", "arg=printf '\\033[41m    \\033[0m'; sleep 30",
                                "reconnect=0", "font=monospace", "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            try:
                c = socket.socket(socket.AF_UNIX)
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\nopacity 128\n")
                c.settimeout(1)
                frame, end = None, time.time() + 10
                while frame is None and time.time() < end:
                    try:
                        data, fds, _, _ = socket.recv_fds(c, 65536, 4)
                    except socket.timeout:
                        continue
                    for line in data.split(b"\n"):
                        # The first frame has the default size; the one asked for follows.
                        if line.startswith(b"frame") and fds:
                            w, h, stride = (int(v) for v in line.split()[1:4])
                            fd = fds.pop(0)
                            if (w, h) == (400, 300):
                                frame = (mmap.mmap(fd, stride * h, mmap.MAP_SHARED, mmap.PROT_READ), stride)
                            os.close(fd)
                self.assertIsNotNone(frame, "no frame")
                fb, stride = frame

                def pixel(x, y):
                    b, g, r, a = fb[y * stride + x * 4:y * stride + x * 4 + 4]
                    return r, g, b, a

                def settle(x, y, alpha):
                    deadline = time.time() + 5
                    while time.time() < deadline and pixel(x, y)[3] != alpha:
                        time.sleep(0.05)
                    return pixel(x, y)

                corner = settle(1, 1, 128)
                self.assertEqual(corner[3], 128, corner)
                self.assertTrue(all(v <= corner[3] for v in corner[:3]), corner)  # premultiplied
                self.assertEqual(settle(250, 200, 128)[3], 128)  # an empty cell
                # Inside the first red cell (padding 6), once the program's output is drawn.
                deadline = time.time() + 5
                while time.time() < deadline and not pixel(8, 10)[0] > pixel(8, 10)[1] + 60:
                    time.sleep(0.05)
                red = pixel(8, 10)
                self.assertEqual(red[3], 255, red)
                self.assertGreater(red[0], red[1] + 60, red)
                c.sendall(b"opacity 255\n")
                self.assertEqual(settle(1, 1, 255)[3], 255)
                self.assertEqual(settle(250, 200, 255)[3], 255)
                # And back down: the background replaces what was there, never blends over it.
                c.sendall(b"opacity 100\n")
                self.assertEqual(settle(1, 1, 100)[3], 100)
                self.assertEqual(settle(250, 200, 100)[3], 100)
                c.close()
            finally:
                p.kill()
                p.wait()


class CursorMoves(unittest.TestCase):
    """The cursor block follows a move along its row with no text changed (left and right on a
    prompt): the library marks no row dirty for it, so the session must redraw it by itself."""

    def test_the_block_follows_left_on_the_same_row(self):
        import mmap, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            config = "\n".join(["arg=/bin/sh", "arg=-c", "arg=printf '    '; sleep 1; printf '\\033[2D'; sleep 30",
                                "reconnect=0", "font=monospace", "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            try:
                c = socket.socket(socket.AF_UNIX)
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                c.settimeout(1)
                frame, end = None, time.time() + 10
                while frame is None and time.time() < end:
                    try:
                        data, fds, _, _ = socket.recv_fds(c, 65536, 4)
                    except socket.timeout:
                        continue
                    for line in data.split(b"\n"):
                        if line.startswith(b"frame") and fds:
                            w, h, stride = (int(v) for v in line.split()[1:4])
                            fd = fds.pop(0)
                            if (w, h) == (400, 300):
                                frame = (mmap.mmap(fd, stride * h, mmap.MAP_SHARED, mmap.PROT_READ), stride)
                            os.close(fd)
                self.assertIsNotNone(frame, "no frame")
                fb, stride = frame

                def block():
                    """The cursor block's left edge on the first row (the default cursor is light
                    on a dark ground), or None."""
                    y = 10
                    for x in range(400):
                        b, g, r, _ = fb[y * stride + x * 4:y * stride + x * 4 + 4]
                        if r > 150 and g > 150 and b > 150:
                            return x
                    return None

                deadline = time.time() + 5
                while time.time() < deadline and (block() is None or block() < 20):
                    time.sleep(0.05)
                first = block()
                self.assertIsNotNone(first, "no cursor drawn")
                deadline = time.time() + 5
                while time.time() < deadline and block() == first:
                    time.sleep(0.05)
                moved = block()
                self.assertIsNotNone(moved, "the cursor vanished")
                self.assertLess(moved, first, "the block stayed where the cursor was")
                c.close()
            finally:
                p.kill()
                p.wait()


@unittest.skipUnless(os.path.exists(HELPER) and shutil.which("qml6") and shutil.which("magick"),
                     "needs the native build, qml6 and ImageMagick")
class SeeThroughInTheView(unittest.TestCase):
    """The whole way: omaremote-ssh's see-through background through RdpView onto the screen. Shown
    over magenta and over green, each pixel's alpha follows from the two (c = p*a + m*(1 - a))."""

    def shown(self, alpha, backdrop, d, late=False):
        sock = os.path.join(d, f"s{backdrop[1:]}")
        config = "\n".join(["arg=/bin/sh", "arg=-c", "arg=sleep 30", "reconnect=0", "font=monospace",
                            "fontSize=10"]) + "\n"
        env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
        p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True, env=env)
        p.stdin.write(config)
        p.stdin.close()
        png = os.path.join(d, f"{alpha}-{backdrop[1:]}.png")
        try:
            plugin = os.path.join(HERE, "..", "native", "build", "qml")
            subprocess.run([shutil.which("qml6"), os.path.join(HERE, "qml", "terminal.qml"), "--", sock, str(alpha),
                            backdrop, png] + (["late"] if late else []), env=dict(os.environ, QT_QPA_PLATFORM="offscreen", QML_IMPORT_PATH=plugin),
                           capture_output=True, timeout=30)
        finally:
            p.kill()
            p.wait()
        self.assertTrue(os.path.exists(png), "nothing shown")
        out = subprocess.run(["magick", png, "-format", "%[fx:round(p{200,200}.r*255)] %[fx:round(p{200,200}.g*255)]",
                              "info:"], capture_output=True, text=True, check=True).stdout.split()
        return int(out[0]), int(out[1])

    def alpha(self, alpha, late=False):
        with tempfile.TemporaryDirectory() as d:
            m, g = self.shown(alpha, "#ff00ff", d, late), self.shown(alpha, "#00ff00", d, late)
        # Red: 255 behind magenta, 0 behind green; green the other way round. c1 - c2 = 255 (1 - a).
        return round(255 - ((m[0] - g[0]) + (g[1] - m[1])) / 2)

    def test_the_background_reaches_the_screen_at_the_alpha_asked(self):
        self.assertAlmostEqual(self.alpha(166), 166, delta=2)

    def test_told_after_the_first_frame_it_reads_that_frame_again(self):
        # The tab learns it is a terminal after a frame was mapped as RGB32 (bindings in any order).
        self.assertAlmostEqual(self.alpha(166, late=True), 166, delta=2)

    def test_solid_stays_solid(self):
        self.assertAlmostEqual(self.alpha(255), 255, delta=1)
