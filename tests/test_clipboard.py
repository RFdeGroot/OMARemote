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

    def test_only_vnc_keeps_the_clipboard_back_at_connect(self):
        with open(os.path.join(HERE, "..", "ui", "SessionView.qml"), encoding="utf-8") as f:
            text = code(f.read())
        self.assertIn('offerAtConnect: !!root.connection && root.connection.protocol !== "vnc"', text)


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
        self.watch_script = os.path.join(self.dir, "watch")
        self.watch("")

    def watch(self, events, baseline="data"):
        """What wl-paste --watch reports: the state at the start, then events (shell lines)."""
        with open(self.watch_script, "w") as f:
            f.write(f'#!/bin/sh\necho $$ >> "{self.watch_script}.ran"\necho {baseline}\n{events}\nexec sleep 60\n')
        os.chmod(self.watch_script, 0o755)

    def stub(self, content, sleep=0):
        data = os.path.join(self.dir, "content")
        with open(data, "wb") as f:
            f.write(content)
        path = os.path.join(self.bin, "wl-paste")
        with open(path, "w") as f:
            f.write(f'#!/bin/sh\n[ "$1" = "--watch" ] && exec "{self.watch_script}"\n'
                    f'echo "$@" >> "{self.calls}"\nsleep {sleep}\nexec cat "{data}"\n')
        os.chmod(path, 0o755)

    def stub_types(self, content, *types):
        """wl-paste: --list-types gives the next of types (the last one again after that)."""
        self.stub(content)
        answers = os.path.join(self.dir, "types")
        with open(answers, "w") as f:
            f.write("\n".join(types) + "\n")
        path = os.path.join(self.bin, "wl-paste")
        with open(path) as f:
            body = f.read().split("\n", 1)[1]
        with open(path, "w") as f:
            f.write(f'''#!/bin/sh
if [ "$1" = "--list-types" ]; then
    line=$(head -n 1 "{answers}")
    [ "$(wc -l < "{answers}")" -gt 1 ] && sed -i 1d "{answers}"
    [ "$line" = "EMPTY" ] && exit 1
    [ "$line" = "LONG" ] && {{ head -c 70000 /dev/zero | tr '\\0' 'x'; printf '\\nx-kde-passwordManagerHint\\n'; exit 0; }}
    printf 'text/plain\\n%s\\n' "$line"
    exit 0
fi
{body}''')

    def wl_paste_calls(self):
        if not os.path.exists(self.calls):
            return 0
        with open(self.calls) as f:
            return len(f.read().splitlines())

    def run_view(self, share, ms=1500, send=(), lines=(), frames=(), mode="focused", timed=(), env=None):
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
                later = sorted(timed)
                fds = list(frames)
                while True:
                    if pending and time.monotonic() - start > 0.8:
                        conn.sendall(b"".join(l + b"\n" for l in pending))
                        pending = []
                    while later and time.monotonic() - start > later[0][0]:
                        conn.sendall(later.pop(0)[1] + b"\n")
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
                   QML_IMPORT_PATH=PLUGIN, PATH=os.pathsep.join([self.bin, os.environ.get("PATH", "")]), **(env or {}))
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
        clips = [l[5:] for l in received.decode().splitlines() if l.startswith("clip ")]
        # In order: the text offered, "-" where what was offered is taken back.
        self.sent = ["-" if c == "-" else base64.b64decode(c).decode() for c in clips]
        offered = [c for c in self.sent if c != "-"]
        self.received_lines = received.decode().splitlines()
        return result, offered, p.stderr

    def test_shared_clipboard_is_read_with_wl_paste_and_offered(self):
        self.stub(b"from the desktop")
        result, offered, _ = self.run_view(True)
        self.assertEqual(offered, ["from the desktop"])
        self.assertGreaterEqual(self.wl_paste_calls(), 1)
        with open(self.calls) as f:
            self.assertEqual(f.readline().split(), ["--no-newline", "--type", "text"])

    def test_a_password_is_withheld_when_asked(self):
        self.stub_types(b"secret", "x-kde-passwordManagerHint")
        _, offered, _ = self.run_view(True, mode="withhold")
        self.assertEqual(offered, [])

    def test_a_password_arriving_during_the_read_is_withheld(self):
        self.stub_types(b"secret", "x-other", "x-kde-passwordManagerHint")
        _, offered, _ = self.run_view(True, mode="withhold")
        self.assertEqual(offered, [])

    def test_a_password_cleared_during_the_read_is_withheld(self):
        self.stub_types(b"secret", "x-other", "EMPTY")
        _, offered, _ = self.run_view(True, mode="withhold")
        self.assertEqual(offered, [])

    def test_a_type_list_too_long_to_read_is_withheld(self):
        self.stub_types(b"secret", "LONG")
        _, offered, _ = self.run_view(True, mode="withhold")
        self.assertEqual(offered, [])

    def test_withholding_leaves_other_text_alone(self):
        self.stub_types(b"from the desktop", "x-other")
        _, offered, _ = self.run_view(True, mode="withhold")
        self.assertEqual(offered, ["from the desktop"])

    def test_a_password_is_offered_without_the_withholding(self):
        self.stub_types(b"secret", "x-kde-passwordManagerHint")
        _, offered, _ = self.run_view(True)
        self.assertEqual(offered, ["secret"])

    def test_not_shared_never_reads_or_writes_the_clipboard(self):
        self.stub(b"from the desktop")
        result, offered, _ = self.run_view(False, send=[b"from the session"])
        self.assertEqual(self.wl_paste_calls(), 0)
        self.assertEqual(offered, [])
        self.assertEqual(self.sent, [])
        self.assertEqual(result["clipboard"], "copied")
        self.assertFalse(os.path.exists(self.watch_script + ".ran"))

    # A cleared clipboard reaches the session, focused or not; a copy elsewhere while the view lacks
    # the keyboard takes back what the session was offered.
    def test_a_clear_takes_back_what_was_offered(self):
        self.stub(b"from the desktop")
        self.watch("sleep 1\necho nil")
        self.run_view(True, ms=2000, mode="quiet")
        self.assertEqual(self.sent, ["from the desktop", "-"])

    def test_a_clear_reaches_the_session_without_the_keyboard(self):
        self.stub(b"from the desktop")
        self.watch("sleep 1\necho nil")
        self.run_view(True, ms=2000, mode="quiet-away")
        self.assertEqual(self.sent[:2], ["from the desktop", "-"])

    def test_a_copy_elsewhere_without_the_keyboard_takes_it_back_unread(self):
        self.stub(b"from the desktop")
        self.watch("sleep 1\necho data")
        self.run_view(True, ms=1900, mode="quiet-away")
        self.assertEqual(self.sent[:2], ["from the desktop", "-"])
        # Back on the keyboard the clipboard is offered again; read for that, and at attaching only.
        self.assertEqual(self.sent[2:], ["from the desktop"])
        self.assertEqual(self.wl_paste_calls(), 2)

    def test_the_state_at_the_start_is_no_change(self):
        self.stub(b"from the desktop")
        self.run_view(True, ms=1200, mode="quiet-vnc")
        self.assertEqual(self.sent, [])

    def test_cleared_with_no_view_attached_is_taken_back_on_attaching(self):
        # The session outlives its view and may still hold a password cleared here meanwhile.
        self.stub(b"")
        self.watch("", baseline="nil")
        self.run_view(True, ms=1200, mode="quiet-vnc")
        self.assertEqual(self.sent, ["-"])

    def test_turning_sharing_off_takes_it_back(self):
        self.stub(b"from the desktop")
        self.run_view(True, ms=1500, mode="quiet-shareoff")
        self.assertEqual(self.sent, ["from the desktop", "-"])

    def watch_alive_at(self, seconds):
        """Whether the first watch process runs, seconds from now, as a one-item list filled by then."""
        found = []

        def check():
            with open(self.watch_script + ".ran") as f:
                pid = int(f.readline())
            try:
                os.kill(pid, 0)
                found.append(True)
            except ProcessLookupError:
                found.append(False)

        timer = threading.Timer(seconds, check)
        timer.start()
        self.addCleanup(timer.cancel)
        return found

    def test_the_watch_runs_while_attached_and_sharing(self):
        self.stub(b"from the desktop")
        alive = self.watch_alive_at(1.0)
        self.run_view(True, ms=1500, mode="quiet")
        self.assertEqual(alive, [True])

    def test_the_watch_stops_when_sharing_is_turned_off(self):
        self.stub(b"from the desktop")
        alive = self.watch_alive_at(1.3)
        self.run_view(True, ms=1800, mode="quiet-shareoff")
        self.assertEqual(alive, [False])

    def test_the_watch_stops_on_detaching(self):
        self.stub(b"from the desktop")
        alive = self.watch_alive_at(1.3)
        self.run_view(True, ms=2200, mode="quiet-detach")
        self.assertEqual(alive, [False])

    def test_the_watch_dies_with_the_window(self):
        self.stub(b"from the desktop")
        path = os.path.join(self.dir, "s")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        self.addCleanup(server.close)
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QML_IMPORT_PATH=PLUGIN,
                   PATH=os.pathsep.join([self.bin, os.environ.get("PATH", "")]))
        p = subprocess.Popen([QML, os.path.join(HERE, "qml", "clipboard.qml"), "--", path, "1", "20000", "quiet"],
                             env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        ran = self.watch_script + ".ran"
        end = time.monotonic() + 10
        while not os.path.exists(ran) and time.monotonic() < end:
            time.sleep(0.05)
        time.sleep(0.2)
        with open(ran) as f:
            pid = int(f.readline())
        os.kill(pid, 0)  # running now
        p.kill()  # a crash: nothing gets the chance to stop it
        p.wait(5)
        end = time.monotonic() + 3
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        os.kill(pid, 9)
        self.fail("the watch outlived the window")

    def test_a_change_drops_text_held_from_the_session(self):
        # Sent while the view lacks the keyboard, then cleared here: the clear changed last.
        self.stub(b"from the desktop")
        self.watch("sleep 1.3\necho nil")
        result, _, _ = self.run_view(True, ms=2300, send=[b"from the session"], mode="quiet-away")
        self.assertEqual(result["clipboard"], "")

    def test_held_text_is_set_when_nothing_changed(self):
        self.stub(b"from the desktop")
        result, _, _ = self.run_view(True, ms=2300, send=[b"from the session"], mode="quiet-away")
        self.assertEqual(result["clipboard"], "from the session")

    def test_a_clear_during_a_read_drops_what_the_read_gives(self):
        self.stub(b"secret", sleep=1)
        self.watch("sleep 0.5\necho nil")
        self.run_view(True, ms=2500, mode="quiet")
        self.assertEqual(self.sent, ["-"])

    def test_an_empty_clipboard_read_takes_it_back(self):
        self.stub(b"")
        self.run_view(True)
        self.assertEqual(set(self.sent), {"-"})

    def test_a_password_copied_while_focused_takes_back_the_text_before_it(self):
        self.stub_types(b"secret", "x-other", "x-other", "x-kde-passwordManagerHint")
        self.watch("sleep 1\necho sensitive")
        self.run_view(True, ms=2200, mode="withhold-quiet")
        self.assertEqual(self.sent, ["secret", "-"])

    # VNC, as Gliff: nothing moves until something is copied during the session.
    def test_vnc_offers_nothing_at_connect(self):
        self.stub(b"from the desktop")
        result, _, _ = self.run_view(True, ms=1500, mode="vnc")  # with Qt's change signal at 400 ms
        self.assertEqual(self.sent, [])
        self.assertEqual(self.wl_paste_calls(), 0)

    def test_vnc_offers_nothing_when_focus_returns_either(self):
        self.stub(b"from the desktop")
        self.run_view(True, ms=1500, mode="quiet-vnc-away")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.wl_paste_calls(), 0)

    def test_vnc_offers_nothing_for_a_change_before_attaching(self):
        # Qt's signal at the keyboard's arrival in a new window looks like this one.
        self.stub(b"from the desktop")
        self.run_view(True, ms=1500, mode="quiet-early-vnc")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.wl_paste_calls(), 0)

    def test_vnc_offers_nothing_for_a_change_before_attaching_without_a_watch(self):
        self.stub(b"from the desktop")
        with open(self.watch_script, "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        self.run_view(True, ms=1500, mode="quiet-early-vnc")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.wl_paste_calls(), 0)

    def test_vnc_offers_a_copy_made_during_the_session(self):
        self.stub(b"from the desktop")
        self.watch("sleep 0.8\necho data")
        self.run_view(True, ms=1600, mode="quiet-vnc")
        self.assertEqual(self.sent, ["from the desktop"])

    def test_vnc_offers_a_copy_made_away_when_focus_returns(self):
        self.stub(b"from the desktop")
        self.watch("sleep 1\necho data")
        self.run_view(True, ms=1900, mode="quiet-vnc-away")
        self.assertEqual(self.sent, ["-", "from the desktop"])

    def test_without_a_watch_qts_signal_still_shares(self):
        # A compositor without data-control: wl-paste --watch gives up at once.
        self.stub(b"from the desktop")
        with open(self.watch_script, "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        _, offered, log = self.run_view(True, ms=1500, mode="vnc")
        self.assertEqual(offered, ["from the desktop"])
        self.assertIn("--watch stopped", log)

    def test_without_a_watch_vnc_offers_nothing_on_focus_with_no_copy_made(self):
        self.stub(b"from the desktop")
        with open(self.watch_script, "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        self.run_view(True, ms=1500, mode="quiet-vnc-away")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.wl_paste_calls(), 0)

    def test_offer_at_connect_arriving_late_still_offers(self):
        # Bindings run in any order; RDP must not depend on it.
        self.stub(b"from the desktop")
        self.run_view(True, ms=1500, mode="quiet-vnc-late")
        self.assertEqual(self.sent, ["from the desktop"])

    def test_a_copy_with_a_watch_is_read_once(self):
        self.stub(b"from the desktop")
        self.watch("sleep 0.8\necho data")
        self.run_view(True, ms=1600, mode="vnc")  # Qt's change signal at 400 ms too
        self.assertEqual(self.sent, ["from the desktop"])
        self.assertEqual(self.wl_paste_calls(), 1)

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

    def test_the_view_reports_what_it_drew(self):
        # A picture, then changes for well over a second: one report, with every number in it.
        frames = [(64 * 4 * 48, b"frame 64 48 256")]
        timed = [(1.0 + i * 0.15, b"damage 0 0 64 48") for i in range(10)]
        self.run_view(False, ms=2800, frames=frames, timed=timed)
        reports = [l.split() for l in self.received_lines if l.startswith("view-stats ")]
        self.assertTrue(reports, self.received_lines)
        ms, damage, drawn, kbyte = (int(x) for x in reports[0][1:])
        self.assertGreaterEqual(ms, 1000)
        self.assertGreaterEqual(damage, 1)
        self.assertGreaterEqual(drawn, 2)
        self.assertEqual(kbyte, drawn * 64 * 48 * 4 // 1024)

    def test_only_what_changed_is_uploaded(self):
        # plans/vnc-speed.md: a blinking cursor on a Retina screen took the whole picture each time.
        frames = [(640 * 4 * 480, b"frame 640 480 2560")]
        timed = [(1.0 + i * 0.15, b"damage 10 20 4 40") for i in range(10)]
        _, _, err = self.run_view(False, ms=2800, frames=frames, timed=timed,
                                  env={"QT_QUICK_BACKEND": "rhi", "QSG_RHI_BACKEND": "opengl"})
        reports = [l.split() for l in self.received_lines if l.startswith("view-stats ")]
        self.assertTrue(reports, err)
        ms, damage, drawn, kbyte = (int(x) for x in reports[0][1:])
        full = 640 * 480 * 4 // 1024
        if kbyte >= drawn * full:
            self.skipTest("this scene graph has no GPU (software): whole pictures, as before")
        self.assertLess(kbyte, full + drawn)  # the first picture whole, then 640 bytes a time

    def test_a_pause_starts_a_new_count(self):
        # One change long after the last: not a report over the pause.
        frames = [(64 * 4 * 48, b"frame 64 48 256")]
        self.run_view(False, ms=3800, frames=frames, timed=[(3.2, b"damage 0 0 64 48")])
        self.assertFalse([l for l in self.received_lines if l.startswith("view-stats ")])

    def test_a_still_view_reports_nothing(self):
        frames = [(64 * 4 * 48, b"frame 64 48 256")]
        self.run_view(False, ms=2500, frames=frames)
        self.assertFalse([l for l in self.received_lines if l.startswith("view-stats ")])

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
