import contextlib
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

    @contextlib.contextmanager
    def watch(self, script):
        """Runs script in omaremote-ssh (400x300, offscreen) and yields light(): the left edge and
        width of the light run on the first row (the default cursor is light on a dark ground),
        or None when there is none."""
        import mmap, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            config = "\n".join(["arg=/bin/sh", "arg=-c", f"arg={script}",
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

                def light():
                    y, left = 10, None
                    for x in range(400):
                        b, g, r, _ = fb[y * stride + x * 4:y * stride + x * 4 + 4]
                        on = r > 150 and g > 150 and b > 150
                        if on and left is None:
                            left = x
                        elif not on and left is not None:
                            return left, x - left
                    return None if left is None else (left, 400 - left)

                light.send = c.sendall
                yield light
                c.close()
            finally:
                p.kill()
                p.wait()

    def settle(self, light, ready):
        """Waits up to 5 s for ready(light()) and returns light() then."""
        import time
        deadline = time.time() + 5
        while time.time() < deadline and not ready(light()):
            time.sleep(0.05)
        return light()

    def test_the_block_follows_left_on_the_same_row(self):
        with self.watch("printf '    '; sleep 1; printf '\\033[2D'; sleep 30") as light:
            first = self.settle(light, lambda s: s is not None and s[0] >= 20)
            self.assertIsNotNone(first, "no cursor drawn")
            moved = self.settle(light, lambda s: s != first)
            self.assertIsNotNone(moved, "the cursor vanished")
            self.assertLess(moved[0], first[0], "the block stayed where the cursor was")

    def test_without_the_keyboard_the_cursor_is_a_hollow_block(self):
        # Ghostty's renderer: unfocused, a hollow block. Across its middle only its two sides show.
        with self.watch("printf '    '; sleep 30") as light:
            first = self.settle(light, lambda s: s is not None and s[0] >= 20)
            self.assertIsNotNone(first, "no cursor drawn")
            light.send(b"blur\n")
            hollow = self.settle(light, lambda s: s != first)
            self.assertIsNotNone(hollow, "the cursor vanished")
            self.assertLess(hollow[1], first[1] / 2, "still a solid block")
            light.send(b"focus 2\n")
            self.assertEqual(self.settle(light, lambda s: s == first), first, "not solid again")

    def test_a_style_change_on_the_same_cell_is_drawn(self):
        """DECSCUSR (block -> bar, ESC [ 6 SP q) changes no text and no position: only the style."""
        with self.watch("printf '    '; sleep 1; printf '\\033[6 q'; sleep 30") as light:
            first = self.settle(light, lambda s: s is not None and s[0] >= 20)
            self.assertIsNotNone(first, "no cursor drawn")
            changed = self.settle(light, lambda s: s != first)
            self.assertIsNotNone(changed, "the cursor vanished")
            self.assertLess(changed[1], first[1], "the block did not become a bar")
            self.assertLessEqual(abs(changed[0] - first[0]), 1, "the cursor moved")


# Sets the terminal up ($2, with escapes), waits for the answer to a device attributes query (so
# the setup was read), then records every byte it gets into $1 as it comes.
RECORDER = r"""
import os, select, sys, tty
tty.setraw(0)
os.write(1, sys.argv[2].encode().decode("unicode_escape").encode("latin-1") + b"\x1b[c")
got = b""
while b"c" not in got:
    got += os.read(0, 64)
with open(sys.argv[1] + ".tmp", "wb", buffering=0) as f:
    os.rename(sys.argv[1] + ".tmp", sys.argv[1])
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        f.write(data)
"""


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Scrolling(unittest.TestCase):
    """The wheel and the trackpad as Ghostty scrolls (Surface.zig scrollCallback): pixels add up to
    rows, a notch is scrollWheel rows, a trackpad's pixels times 10 times scrollTouch. On the alternate
    screen they come to the program as arrow keys, to a program that asks for the mouse as
    buttons 4 to 7; the scroll keys stay the terminal's."""

    @contextlib.contextmanager
    def session(self, setup, *settings):
        import socket, time
        with tempfile.TemporaryDirectory() as d:
            prog, rec, sock = os.path.join(d, "r.py"), os.path.join(d, "rec"), os.path.join(d, "s")
            with open(prog, "w") as f:
                f.write(RECORDER)
            config = "\n".join(["arg=/usr/bin/python3", "arg=-I", f"arg={prog}", f"arg={rec}", f"arg={setup}",
                                "reconnect=0", "font=monospace", "fontSize=10", *settings]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            c = socket.socket(socket.AF_UNIX)
            try:
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                deadline = time.time() + 20
                while not os.path.exists(rec) and time.time() < deadline:
                    time.sleep(0.05)
                self.assertTrue(os.path.exists(rec), "the program did not start")

                def send(*lines):
                    c.sendall("".join(line + "\n" for line in lines).encode())

                def got(expect, wait=5):
                    """What the program got, once it holds `expect` bytes (or after `wait` s)."""
                    deadline = time.time() + wait
                    while time.time() < deadline:
                        with open(rec, "rb") as f:
                            data = f.read()
                        if len(data) >= expect:
                            return data
                        time.sleep(0.05)
                    with open(rec, "rb") as f:
                        return f.read()

                yield send, got
            finally:
                c.close()
                p.kill()
                p.wait()

    ALT = r"\x1b[?1049h"
    UP = b"\x1b[A"

    def test_a_notch_is_three_rows_as_in_ghostty(self):
        with self.session(self.ALT) as (send, got):
            send("wheel 120 0 10 10", "wheel -120 0 10 10")
            self.assertEqual(got(18), self.UP * 3 + b"\x1b[B" * 3)

    def test_the_terminal_configs_wheel_multiplier(self):
        # Omarchy's Ghostty: mouse-scroll-multiplier = 0.95. A notch is under a row, two make one:
        # what is left once a row is reached is dropped, as in Ghostty.
        with self.session(self.ALT, "scrollWheel=0.95") as (send, got):
            send("wheel 120 0 10 10")
            self.assertEqual(got(1, wait=1), b"")
            send("wheel 120 0 10 10")
            self.assertEqual(got(3), self.UP)
            send("wheel 120 0 10 10")
            self.assertEqual(got(6, wait=1), self.UP)

    def test_a_high_resolution_wheel_adds_up(self):
        # Eighths of a notch (15 each; nothing was scrolled at all before). Each is 3/8 of a row;
        # Ghostty drops what is over once a row is reached, so a notch of them makes 2 rows, not 3.
        with self.session(self.ALT) as (send, got):
            send(*["wheel 15 0 10 10"] * 8)
            self.assertEqual(got(9, wait=1), self.UP * 2)

    def test_a_trackpad_counts_its_pixels_times_ten(self):
        # Ghostty's GTK app: a pixel counts 10. 10 is less than a row at 10 points (13 px type),
        # two of them make one; 10 pixels at once are several rows.
        with self.session(self.ALT) as (send, got):
            send("wheel 12 0 10 10 1 0")
            self.assertEqual(got(1, wait=1), b"")
            send("wheel 12 0 10 10 1 0")
            self.assertEqual(got(3), self.UP)
            send("wheel 120 0 10 10 10 0")
            data = got(15)
            self.assertGreaterEqual(len(data) // 3, 5)
            self.assertEqual(data, self.UP * (len(data) // 3))

    def test_the_trackpad_multiplier(self):
        # scrollTouch=0.1 undoes the 10: back to a row for every row's worth of pixels.
        with self.session(self.ALT, "scrollTouch=0.1") as (send, got):
            send("wheel 12 0 10 10 10 0")
            self.assertEqual(got(1, wait=1), b"")
            send("wheel 12 0 10 10 10 0")
            self.assertEqual(got(3), self.UP)

    def test_no_arrows_when_the_program_turns_alternate_scroll_off(self):
        with self.session(self.ALT + r"\x1b[?1007l") as (send, got):
            send("wheel 120 0 10 10", "key 1 30 97 YQ==")
            self.assertEqual(got(1), b"a")

    def test_a_program_with_the_mouse_gets_buttons_four_to_seven(self):
        # SGR reports: 64/65 up/down, 66/67 left/right (a tilt wheel, a sideways trackpad).
        with self.session(r"\x1b[?1000h\x1b[?1006h") as (send, got):
            send("wheel 120 0 10 10", "wheel 0 120 10 10", "wheel 0 -120 10 10")
            data = got(60)
            self.assertEqual(data.count(b"\x1b[<64;"), 3)
            self.assertEqual(data.count(b"\x1b[<66;"), 1)
            self.assertEqual(data.count(b"\x1b[<67;"), 1)

    def test_the_scroll_keys_stay_the_terminals(self):
        # Shift+Home/End/PageUp and Ctrl+Shift+Up go to the view, not the program; then an "a".
        import base64
        with self.session("") as (send, got):
            send("key 1 42 65505")  # Shift_L
            for evdev, sym in ((102, 65360), (107, 65367), (104, 65365), (109, 65366)):
                send(f"key 1 {evdev} {sym}", f"key 0 {evdev} {sym}")
            send("key 1 29 65507", "key 1 103 65362", "key 0 103 65362", "key 0 29 65507")
            send("key 0 42 65505", "key 1 30 97 " + base64.b64encode(b"a").decode(), "key 0 30 97")
            self.assertEqual(got(1), b"a")

    def test_on_the_alternate_screen_they_go_to_the_program(self):
        # No scrollback there: Shift+Page Up is the program's (less, vim).
        with self.session(self.ALT) as (send, got):
            send("key 1 42 65505", "key 1 104 65365", "key 0 104 65365", "key 0 42 65505")
            self.assertEqual(got(6), b"\x1b[5;2~")


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class FocusEvents(unittest.TestCase):
    """Focus reporting (mode 1004, vim's FocusGained, tmux focus-events): the view's `focus` and
    `blur` reach a program that asked, as CSI I and CSI O, once per change."""

    session = Scrolling.session

    def test_a_program_that_asked_is_told(self):
        with self.session(r"\x1b[?1004h") as (send, got):
            send("blur", "blur", "focus 2", "focus 2")
            self.assertEqual(got(7, wait=1.5), b"\x1b[O\x1b[I")

    def test_nothing_unless_asked(self):
        with self.session("") as (send, got):
            send("blur", "focus 2", "key 1 30 97 YQ==")
            self.assertEqual(got(1), b"a")


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Scrollback(unittest.TestCase):
    """As much history as Ghostty keeps (50 MB a tab, no line limit): left to the library's own
    default (10 KB, one page), a tab kept a few hundred lines."""

    def oldest_kept(self, *settings):
        """Prints L0..L19999, goes to the top (Shift+Home), copies the first row: what it says."""
        import base64, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            script = "i=0; while [ $i -lt 20000 ]; do echo L$i; i=$((i+1)); done; echo done; sleep 30"
            config = "\n".join(["arg=/bin/sh", "arg=-c", f"arg={script}", "reconnect=0", "font=monospace",
                                "fontSize=10", *settings]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            c = socket.socket(socket.AF_UNIX)
            try:
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                c.settimeout(0.2)
                buf = b""

                def lines():
                    nonlocal buf
                    try:
                        buf += c.recv(65536)
                    except socket.timeout:
                        pass
                    *done, buf = buf.split(b"\n")
                    return done

                # The output is all there once the shell sleeps: read the view's lines meanwhile
                # (a view that stops reading is dropped).
                end = time.time() + 3
                while time.time() < end:
                    lines()
                c.sendall(b"key 1 42 65505\nkey 1 102 65360\nkey 0 102 65360\nkey 0 42 65505\n"
                          b"button 1 1 0 11\nmouse 390 11\nbutton 1 0 390 11\n"
                          b"key 1 29 65507\nkey 1 42 65505\nkey 1 46 67\nkey 0 46 67\n"
                          b"key 0 42 65505\nkey 0 29 65507\n")
                end = time.time() + 10
                while time.time() < end:
                    for line in lines():
                        if line.startswith(b"clip "):
                            return base64.b64decode(line.split()[1]).decode().strip()
                self.fail("nothing was copied")
            finally:
                c.close()
                p.kill()
                p.wait()

    def test_twenty_thousand_lines_are_all_kept(self):
        self.assertEqual(self.oldest_kept(), "L0")

    def test_a_line_limit_from_the_config(self):
        # scrollback-limit-lines = 1000 takes effect. The library trims whole pages, and a page of
        # this narrow view holds more rows than that: what is left can be fewer than 1000.
        oldest = int(self.oldest_kept("scrollback=1000")[1:])
        self.assertGreater(oldest, 20000 - 1000 - 100)


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Selecting(unittest.TestCase):
    """Ghostty's own selection gestures (libghostty-vt's): a double click selects a word, a triple
    click the line, a single click starts over, a drag past the top scrolls into the history."""

    COPY = (b"key 1 29 65507\nkey 1 42 65505\nkey 1 46 67\nkey 0 46 67\n"
            b"key 0 42 65505\nkey 0 29 65507\n")

    def copied(self, script, actions, settle=2):
        """Runs script, waits `settle` s, sends actions (bytes, or a number: seconds to wait),
        then copies: the text copied, or None when nothing was selected."""
        import base64, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            config = "\n".join(["arg=/bin/sh", "arg=-c", f"arg={script}", "reconnect=0", "font=monospace",
                                "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            c = socket.socket(socket.AF_UNIX)
            try:
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                c.settimeout(0.1)
                buf = b""

                def lines(wait):
                    nonlocal buf
                    out, end = [], time.time() + wait
                    while time.time() < end:
                        try:
                            buf += c.recv(65536)
                        except socket.timeout:
                            continue
                        *done, buf = buf.split(b"\n")
                        out += done
                    return out

                lines(settle)
                for a in actions:
                    if isinstance(a, (int, float)):
                        lines(a)
                    else:
                        c.sendall(a)
                lines(0.3)
                c.sendall(self.COPY)
                for line in lines(1.5):
                    if line.startswith(b"clip "):
                        return base64.b64decode(line.split()[1]).decode()
                return None
            finally:
                c.close()
                p.kill()
                p.wait()

    LINE = "printf 'alpha beta-gamma delta\\n'; sleep 30"
    CLICK = b"button 1 1 70 11\nbutton 1 0 70 11\n"  # on "beta-gamma", the first row

    def test_a_double_click_selects_a_word(self):
        self.assertEqual(self.copied(self.LINE, [self.CLICK * 2]), "beta-gamma")

    def test_a_triple_click_selects_the_line(self):
        self.assertEqual(self.copied(self.LINE, [self.CLICK * 3]), "alpha beta-gamma delta")

    def test_a_single_click_after_it_starts_over(self):
        # Past the repeat interval (500 ms): a new single click, nothing selected.
        self.assertIsNone(self.copied(self.LINE, [self.CLICK * 2, 0.7, self.CLICK]))

    def test_dragging_past_the_top_scrolls_into_the_history(self):
        # 200 lines, the view at the bottom: a drag from the middle up to the top edge, held there,
        # selects lines that were above the screen.
        script = "i=0; while [ $i -lt 200 ]; do echo L$i; i=$((i+1)); done; sleep 30"
        text = self.copied(script, [b"button 1 1 30 150\nmouse 30 80\nmouse 0 0\n", 1.0, b"button 1 0 0 0\n"])
        self.assertIsNotNone(text)
        first = int(text.split()[0][1:])
        self.assertLess(first, 200 - 20, "the drag did not scroll: " + text.split()[0])


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Links(unittest.TestCase):
    """Ghostty's links: with ctrl held, a URL in the text (its scheme pattern: no trailing . or ,,
    a bracketed word kept, surrounding parentheses not) or an OSC 8 hyperlink is underlined and
    told to the view (`link`); a ctrl+click asks for it to be opened (`open-url`). Not file:
    (over SSH a path is the remote computer's)."""

    CTRL_DOWN, CTRL_UP = b"key 1 29 65507\n", b"key 0 29 65507\n"

    def said(self, output, actions):
        """The view's lines after `actions`, with `output` (bytes, escapes and all) on the screen."""
        import base64, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock, out = os.path.join(d, "s"), os.path.join(d, "out")
            with open(out, "wb") as f:
                f.write(output)
            config = "\n".join(["arg=/bin/sh", "arg=-c", f"arg=cat {out}; sleep 30", "reconnect=0",
                                "font=monospace", "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            c = socket.socket(socket.AF_UNIX)
            try:
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                c.settimeout(0.1)
                buf = b""

                def lines(wait):
                    nonlocal buf
                    got, end = [], time.time() + wait
                    while time.time() < end:
                        try:
                            buf += c.recv(65536)
                        except socket.timeout:
                            continue
                        *done, buf = buf.split(b"\n")
                        got += done
                    return got

                lines(2)
                c.sendall(b"".join(actions))
                said = []
                for line in lines(1.5):
                    word = line.split(b" ")[0]
                    if word in (b"link", b"open-url"):
                        arg = line.split(b" ")[1]
                        said.append((word.decode(), "-" if arg == b"-" else base64.b64decode(arg).decode()))
                    elif word == b"cursor-pointer":
                        said.append(("cursor-pointer", ""))
                return said
            finally:
                c.close()
                p.kill()
                p.wait()

    def hover(self, x):
        return [self.CTRL_DOWN, b"mouse %d 11\n" % x]

    def test_a_url_with_ctrl_held(self):
        url = "https://example.com/a_(b)"
        said = self.said(b"see " + url.encode() + b". end\n", self.hover(90) + [b"button 1 1 90 11\nbutton 1 0 90 11\n", self.CTRL_UP])
        self.assertEqual(said, [("link", url), ("cursor-pointer", ""), ("open-url", url), ("link", "-")])

    def test_surrounding_parentheses_are_not_the_urls(self):
        said = self.said(b"x (https://e.test/q) y\n", self.hover(90))
        self.assertEqual(said[0], ("link", "https://e.test/q"))

    def test_nothing_without_ctrl(self):
        self.assertEqual(self.said(b"see https://example.com/ end\n", [b"mouse 90 11\n"]), [])

    def test_an_osc_8_hyperlink(self):
        said = self.said(b"\x1b]8;;https://x.test/p\x1b\\click here\x1b]8;;\x1b\\\n", self.hover(30))
        self.assertEqual(said[0], ("link", "https://x.test/p"))

    def test_not_a_file_link(self):
        said = self.said(b"\x1b]8;;file:///etc/passwd\x1b\\click here\x1b]8;;\x1b\\ file:///etc/passwd\n",
                         self.hover(30) + [b"mouse 120 11\n", b"button 1 1 120 11\nbutton 1 0 120 11\n"])
        self.assertEqual(said, [])


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Searching(unittest.TestCase):
    """Ghostty's search (libghostty-vt's), from the view's find bar: `search <b64>` finds every
    match in the scrollback (ASCII letters in any case) and says how many (`search-status <total>
    <selected>`, -1 none selected); the newest is selected at once, as a browser's find (Ghostty
    waits for Enter), the view going to it when it is only in the history; `search-next` selects
    the next one up, `search-prev` the one below. Matches on the screen are drawn in Ghostty's
    search colours. A view that attaches again starts without a search."""

    @contextlib.contextmanager
    def session(self, script):
        """Runs script (400x300, offscreen); yields (send, search, status, row, state): send a line,
        search for a needle, the last `search-status` (total, selected) once it settled, the
        frame's colours along a row, and the last `scrollbar` (state["scrollbar"])."""
        import base64, mmap, socket, time
        with tempfile.TemporaryDirectory() as d:
            sock = os.path.join(d, "s")
            config = "\n".join(["arg=/bin/sh", "arg=-c", f"arg={script}", "reconnect=0", "font=monospace",
                                "fontSize=10"]) + "\n"
            env = dict(os.environ, OMAREMOTE_SOCKET=sock, QT_QPA_PLATFORM="offscreen")
            p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, text=True, env=env)
            p.stdin.write(config)
            p.stdin.close()
            c = socket.socket(socket.AF_UNIX)
            state = {"buf": b"", "status": None, "frame": None, "scrollbar": None, "sock": sock, "cwd": []}
            try:
                for _ in range(100):
                    try:
                        c.connect(sock)
                        break
                    except OSError:
                        time.sleep(0.05)
                c.sendall(b"size 400 300 100\n")
                c.settimeout(0.1)

                def read(wait):
                    end = time.time() + wait
                    while time.time() < end:
                        try:
                            data, fds, _, _ = socket.recv_fds(c, 65536, 4)
                        except socket.timeout:
                            continue
                        if not data:
                            return
                        state["buf"] += data
                        *done, state["buf"] = state["buf"].split(b"\n")
                        for line in done:
                            w = line.split()
                            if w[:1] == [b"frame"] and fds:
                                width, h, stride = (int(v) for v in w[1:4])
                                fd = fds.pop(0)
                                state["frame"] = (mmap.mmap(fd, stride * h, mmap.MAP_SHARED, mmap.PROT_READ), stride)
                                os.close(fd)
                            elif w[:1] == [b"search-status"]:
                                state["status"] = (int(w[1]), int(w[2]))
                            elif w[:1] == [b"cwd"] and len(w) > 1:
                                state["cwd"].append("-" if w[1] == b"-" else base64.b64decode(w[1]).decode())
                            elif w[:1] == [b"scrollbar"]:
                                state["scrollbar"] = tuple(int(v) for v in w[1:4])

                def send(line):
                    c.sendall(line.encode() + b"\n")

                def search(needle):
                    send("search " + (base64.b64encode(needle.encode()).decode() if needle else "-"))

                def status(wait=1.5):
                    read(wait)
                    return state["status"]

                def row(y):
                    """The frame's (r, g, b) along a pixel row, once what was sent is drawn."""
                    read(0.3)
                    fb, stride = state["frame"]
                    return [tuple(fb[y * stride + x * 4:y * stride + x * 4 + 3][::-1]) for x in range(400)]

                read(2)
                yield send, search, status, row, state
            finally:
                c.close()
                p.kill()
                p.wait()

    # 300 lines, every 30th says NEEDLE (10 of them; most far up in the history), then a prompt.
    HISTORY = ("i=0; while [ $i -lt 300 ]; do if [ $((i % 30)) -eq 0 ]; then echo \"line $i NEEDLE\"; "
               "else echo \"line $i\"; fi; i=$((i+1)); done; sleep 30")

    def test_it_counts_the_matches_in_the_whole_history(self):
        with self.session(self.HISTORY) as (send, search, status, row, state):
            search("needle")  # any case
            self.assertEqual(status(), (10, 0))
            search("no such text")
            self.assertEqual(status(), (0, -1))

    def test_enter_goes_up_into_the_history_and_the_view_follows(self):
        with self.session(self.HISTORY) as (send, search, status, row, state):
            search("NEEDLE")
            self.assertEqual(status(), (10, 0))  # the newest, at once
            bottom = state["scrollbar"][1]
            for _ in range(9):
                send("search-next")
            self.assertEqual(status(), (10, 9))  # the oldest: line 0, the top of the history
            self.assertLess(state["scrollbar"][1], bottom, "the view did not scroll up to it")
            self.assertEqual(state["scrollbar"][1], 0)
            send("search-next")
            self.assertEqual(status(), (10, 0))  # round again to the newest
            send("search-prev")
            self.assertEqual(status(), (10, 9))  # shift+enter, past the newest: the oldest

    def test_matches_on_the_screen_are_drawn_in_ghosttys_colours(self):
        with self.session("printf 'one NEEDLE two\\n'; sleep 30") as (send, search, status, row, state):
            # Along the first row of text, wherever the cells fall.
            before = row(12)
            self.assertNotIn((0xFF, 0xE0, 0x82), before)
            search("needle")
            status()
            after = row(12)
            self.assertIn((0xF2, 0xA5, 0x7E), after)  # search-selected-background: the one match
            self.assertNotIn((0xFF, 0xE0, 0x82), after)
        with self.session("printf 'one NEEDLE two NEEDLE\\n'; sleep 30") as (send, search, status, row, state):
            search("needle")
            status()
            both = row(12)
            self.assertIn((0xF2, 0xA5, 0x7E), both)  # the newest (the last on the row): selected
            self.assertIn((0xFF, 0xE0, 0x82), both)  # the other: search-background
            search("")
            self.assertEqual(status(), (0, -1))
            cleared = row(12)
            self.assertNotIn((0xF2, 0xA5, 0x7E), cleared)
            self.assertNotIn((0xFF, 0xE0, 0x82), cleared)

    def test_a_match_only_in_the_history_is_gone_to_at_once(self):
        with self.session(self.HISTORY) as (send, search, status, row, state):
            status()
            bottom = state["scrollbar"][1]
            search("line 30 NEEDLE")  # one match, far above the screen
            self.assertEqual(status(), (1, 0))
            self.assertLess(state["scrollbar"][1], bottom, "the view did not go to it")

    def test_a_view_that_attaches_again_starts_without_one(self):
        import socket, time
        with self.session(self.HISTORY) as (send, search, status, row, state):
            search("NEEDLE")
            self.assertEqual(status(), (10, 0))
            again = socket.socket(socket.AF_UNIX)
            again.connect(state["sock"])
            again.settimeout(0.2)
            buf, end = b"", time.time() + 3
            while b"search-status" not in buf and time.time() < end:
                try:
                    buf += again.recv(65536)
                except socket.timeout:
                    pass
            again.close()
            self.assertIn(b"search-status 0 -1", buf)

    def test_a_long_history_does_not_hold_up_the_terminal(self):
        # 20000 matching lines: found a slice at a time, all of them in the end.
        script = "i=0; while [ $i -lt 20000 ]; do echo \"hit $i\"; i=$((i+1)); done; sleep 30"
        with self.session(script) as (send, search, status, row, state):
            status(3)
            search("hit")
            total = 0
            for _ in range(20):
                total = status(1)[0]
                if total == 20000:
                    break
            self.assertEqual(total, 20000)


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class CurrentDirectory(unittest.TestCase):
    """Where the shell says it is (OSC 7, OSC 9;9, OSC 1337 CurrentDir) goes to the view as it
    was said (`cwd <b64>`), again to a view that attaches later; one longer than any path is
    dropped. Browse files opens it (bin/omaremote-session, test_session.py)."""

    session = Searching.session

    def said(self, printf):
        with self.session(f"printf '{printf}'; sleep 30") as (send, search, status, row, state):
            status(0.5)
            return state["cwd"]

    def test_osc_7_and_the_others(self):
        self.assertEqual(self.said("\\033]7;file://srv/home/a%%20b\\033\\\\"), ["file://srv/home/a%20b"])
        self.assertEqual(self.said("\\033]9;9;/var/log\\007"), ["/var/log"])
        self.assertEqual(self.said("\\033]1337;CurrentDir=/tmp\\007"), ["/tmp"])

    def test_cleared_and_said_again_to_a_view_that_attaches(self):
        import socket, time
        script = "printf '\\033]7;file://srv/etc\\007'; sleep 1; printf '\\033]7;file://srv/usr\\007'; sleep 30"
        with self.session(script) as (send, search, status, row, state):
            status(1.5)
            self.assertEqual(state["cwd"], ["file://srv/etc", "file://srv/usr"])
            again = socket.socket(socket.AF_UNIX)
            again.connect(state["sock"])
            again.settimeout(0.2)
            buf, end = b"", time.time() + 3
            while b"cwd " not in buf and time.time() < end:
                try:
                    buf += again.recv(65536)
                except socket.timeout:
                    pass
            again.close()
            import base64
            self.assertIn(b"cwd " + base64.b64encode(b"file://srv/usr"), buf)

    def test_one_longer_than_any_path_is_dropped(self):
        long = "/" + "a" * 5000
        self.assertEqual(self.said("\\033]7;file://srv" + long + "\\007"), [])


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
