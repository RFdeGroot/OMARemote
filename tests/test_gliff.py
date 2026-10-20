import base64
import importlib.machinery
import json
import re
import shutil
import socket
import importlib.util
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("session", os.path.join(HERE, "..", "bin", "omaremote-session"))
_spec = importlib.util.spec_from_loader("session", _loader)
session = importlib.util.module_from_spec(_spec)
_loader.exec_module(session)

PROTO_TEST = os.path.join(HERE, "..", "native", "build", "gliff-proto-test")


def gliff(**kw):
    return dict({"id": "g1", "name": "PC", "host": "pc.lan", "protocol": "gliff"}, **kw)


class Protocol(unittest.TestCase):
    @unittest.skipUnless(os.access(PROTO_TEST, os.X_OK), "native build missing: ninja -C native/build")
    def test_encodings_match_gliff_proto(self):
        """native/gliff/msg.hpp against gliff-proto's own fixtures, and hostile bodies."""
        out = subprocess.run([PROTO_TEST], capture_output=True, text=True, timeout=10)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    @unittest.skipUnless(os.access(PROTO_TEST, os.X_OK), "native build missing: ninja -C native/build")
    def test_a_servers_text_cannot_forge_log_lines(self):
        """The supervisor reads the session log line by line; a server's error message with line breaks
        must not add "connected to" or "connection failed" lines (security review 0.9.0)."""
        out = subprocess.run([PROTO_TEST], capture_output=True, text=True, timeout=10).stdout
        lines = out.splitlines()
        self.assertTrue(any(l.startswith("[omaremote] server error 1: x ") for l in lines), out)
        self.assertFalse(any(l.startswith("[omaremote] connected to") for l in lines))
        self.assertEqual(session.SSH_FAILED_RE.findall(out), [])


class Command(unittest.TestCase):
    def test_ssh_as_gliff_runs_it(self):
        """Mirroring the main screen by default, as Gliff's own client does without arguments."""
        self.assertEqual(session.build_gliff_command(gliff()),
                         ["ssh", "-T", "-o", "Compression=no", "-o", "IPQoS=lowdelay", "--", "pc.lan",
                          "gliff-server", "--stdio", "--output", "auto"])

    def test_user_key_and_options_go_before_the_host(self):
        cmd = session.build_gliff_command(gliff(port=2222, username="me", sshKey="~/.ssh/id_x", sshArgs="-J jump.lan"))
        host = cmd.index("pc.lan")
        self.assertEqual(cmd[host - 1], "--")
        for word in ("-p", "2222", "-l", "me", "-J", "jump.lan", "IdentitiesOnly=yes"):
            self.assertLess(cmd.index(word), host)

    def test_the_remote_command_is_fixed_words(self):
        """ssh hands the remote command to the remote shell: nothing of the connection goes into it."""
        cmd = session.build_gliff_command(gliff(sshArgs="-A", gliffScreen="private; touch /tmp/x", name="$(x)"))
        self.assertEqual(cmd[cmd.index("pc.lan") + 1:], ["gliff-server", "--stdio", "--output", "auto"])
        cmd = session.build_gliff_command(gliff(gliffScreen="private"))
        self.assertEqual(cmd[cmd.index("pc.lan") + 1:], ["gliff-server", "--stdio", "--headless"])

    def test_server_options_are_fixed_words(self):
        cmd = session.build_gliff_command(gliff(gliffOutput="DP-1", gliffColour="low", gliffCapture="shm"))
        self.assertEqual(cmd[cmd.index("pc.lan") + 1:],
                         ["gliff-server", "--stdio", "--output", "DP-1", "--low-bandwidth", "--capture", "shm"])
        cmd = session.build_gliff_command(gliff(gliffColour="full", gliffCapture="weird", gliffServer="~/bin/gliff-server"))
        self.assertEqual(cmd[cmd.index("pc.lan") + 1:], ["~/bin/gliff-server", "--stdio", "--output", "auto", "--full-chroma"])
        # A private screen names no output, whatever is stored.
        cmd = session.build_gliff_command(gliff(gliffScreen="private", gliffOutput="DP-1"))
        self.assertEqual(cmd[cmd.index("pc.lan") + 1:], ["gliff-server", "--stdio", "--headless"])

    def test_shell_characters_never_reach_the_remote_command(self):
        """A synced screen name or server path could carry a command for the remote shell."""
        for bad in ("DP-1; rm -rf ~", "$(id)", "`id`", "a b", "-oFoo", "x|y", "a\nb", "DP-1&"):
            with self.assertRaises(ValueError, msg=bad):
                session.build_gliff_command(gliff(gliffOutput=bad))
        for bad in ("gliff-server; id", "$(id)", "-x", "a b", "env FOO=1 gliff-server", "x>y"):
            with self.assertRaises(ValueError, msg=bad):
                session.build_gliff_command(gliff(gliffServer=bad))

    def test_decoding_choice(self):
        self.assertIn("video=auto", session.build_gliff_config(gliff()))
        self.assertIn("video=cpu", session.build_gliff_config(gliff(gliffVideo="cpu")))
        self.assertIn("video=auto", session.build_gliff_config(gliff(gliffVideo="gpu; x")))

    def test_a_host_that_looks_like_an_option_is_refused(self):
        with self.assertRaises(ValueError):
            session.build_gliff_command(gliff(host="-oProxyCommand=evil"))

    def test_config_lines(self):
        lines = session.build_gliff_config(gliff())
        self.assertIn("host=pc.lan", lines)
        self.assertIn("headless=0", lines)
        self.assertIn("arg=gliff-server", lines)
        self.assertIn("headless=1", session.build_gliff_config(gliff(gliffScreen="private")))
        self.assertIn("clipboard=1", lines)
        self.assertIn("clipboard=0", session.build_gliff_config(gliff(clipboard=False)))

    def test_default_port(self):
        data = {"credentials": [], "groups": {}, "connections": []}
        self.assertEqual(session.resolve(gliff(), data)["port"], 22)


QML = shutil.which("qml6") or shutil.which("qml")


@unittest.skipUnless(QML, "needs qml6")
class Stats(unittest.TestCase):
    """The stats line in the bottom bar: Format.parseStats, statsParts (most important first, the
    bar drops from the end) and statsRows (the card), through tests/qml/format.qml."""

    @classmethod
    def setUpClass(cls):
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
        p = subprocess.run([QML, os.path.join(HERE, "qml", "format.qml")], env=env,
                           capture_output=True, text=True, timeout=30)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        assert found, p.stderr
        cls.r = json.loads(found.group(1))
        assert "error" not in cls.r, cls.r["error"]

    def test_a_good_link_starts_with_fps(self):
        self.assertEqual(self.r["okParts"], ["60 fps", "4 ms ping", "42.3 Mbit/s", "decode 6.1 ms (VA-API)",
                                             "3668×2064 4:4:4", "server GPU"])
        self.assertEqual(self.r["okRows"][0], ["Connection", "good"])

    def test_a_warning_names_its_reason_first(self):
        self.assertEqual(self.r["warnParts"][:2], ["congested, at most 15 fps", "3 fps"])
        # No round trip measured yet: no ping fact.
        self.assertNotIn("-1 ms ping", self.r["warnParts"])

    def test_reconnecting_has_only_the_reason(self):
        self.assertEqual(self.r["reconnecting"], ["reconnecting"])

    def test_unknown_health_is_ok_and_empty_is_nothing(self):
        self.assertEqual(self.r["odd"], "ok")
        self.assertIsNone(self.r["noStats"])


class Exit(unittest.TestCase):
    def test_a_disconnect_is_no_error(self):
        for code in (0, 11, -15):
            self.assertIsNone(session.describe_exit(code, "", "gliff"))

    def test_the_session_says_why(self):
        tail = "[omaremote] connection failed: No gliff-server on pc.lan: install it there with omarchy pkg add gliff\n"
        self.assertEqual(session.describe_exit(131, tail, "gliff"),
                         "No gliff-server on pc.lan: install it there with omarchy pkg add gliff")

    def test_otherwise_the_code(self):
        self.assertEqual(session.describe_exit(147, "", "gliff"), "The connection was lost")


# A fake gliff-server on the helper's stdin/stdout: HelloAck, one StreamConfig of the given size,
# then one keyframe (an Annex B H.264 picture made by ffmpeg) of its own size.
FAKE_SERVER = r'''
import struct, sys, time

def head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    for extra, fmt in ((24, ">B"), (25, ">H"), (26, ">I"), (27, ">Q")):
        if n < 1 << (8 * struct.calcsize(fmt)):
            return bytes([major << 5 | extra]) + struct.pack(fmt, n)

def cbor(v):
    if v is None:
        return b"\xf6"
    if isinstance(v, bool):
        return b"\xf5" if v else b"\xf4"
    if isinstance(v, int):
        return head(0, v)
    if isinstance(v, bytes):
        return head(2, len(v)) + v
    if isinstance(v, str):
        return head(3, len(v.encode())) + v.encode()
    return head(4, len(v)) + b"".join(cbor(x) for x in v)

def send(variant, fields, payload=b""):
    body = cbor([variant, fields])
    sys.stdout.buffer.write(struct.pack("<II", len(body), len(payload)) + body + payload)
    sys.stdout.buffer.flush()

width, height, picture = int(sys.argv[1]), int(sys.argv[2]), open(sys.argv[3], "rb").read()
send(0, [1, [False, "DP-1"], [["DP-1", width, height, 1000]], []])
send(1, [1, 2, None, width, height, 1000, b"", None, width, height, 60])
send(2, [1, 0, True, [[0, 0, width, height]], len(picture), 0], picture)
while sys.stdin.buffer.read(4096):
    pass
'''

GLIFF = os.path.join(HERE, "..", "native", "build", "omaremote-gliff")


@unittest.skipUnless(os.path.exists(GLIFF), "needs the native build (ninja -C native/build)")
@unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg with libx264 to make a test picture")
class Decoder(unittest.TestCase):
    """A server sizes the decoder: its stream may not pass what Hello asked for (3840x2160), and its
    pictures not their StreamConfig, or FFmpeg allocates for them before anything is shown
    (omarchy-plugin-marketplace#12352)."""

    def picture(self, d, size):
        path = os.path.join(d, size + ".h264")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=black:s={size}:r=25",
                        "-frames:v", "1", "-c:v", "libx264", "-preset", "ultrafast", "-f", "h264", path], check=True)
        return path

    def run_session(self, stream, picture):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        server = os.path.join(d, "server.py")
        with open(server, "w") as f:
            f.write(FAKE_SERVER)
        w, h = stream
        args = [sys.executable, "-I", server, str(w), str(h), self.picture(d, picture)]
        p = subprocess.Popen([GLIFF], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env=dict(os.environ, OMAREMOTE_SOCKET=os.path.join(d, "s")), text=True)
        self.addCleanup(p.stdout.close)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write("host=pc.lan\nvideo=cpu\nclipboard=0\n" + "".join(f"arg={a}\n" for a in args))
        p.stdin.close()
        return p

    def test_a_picture_of_its_stream_size_is_shown(self):
        p = self.run_session((64, 40), "64x40")
        lines = []
        reader = threading.Thread(target=lambda: lines.extend(p.stdout), daemon=True)
        reader.start()
        deadline = time.monotonic() + 10
        while not any("desktop is 64x40" in l for l in lines) and time.monotonic() < deadline and p.poll() is None:
            time.sleep(0.02)
        p.terminate()
        rc = p.wait(5)
        reader.join(5)
        self.assertIn("desktop is 64x40", "".join(lines))
        self.assertEqual(rc, 11, "".join(lines))

    def test_a_stream_larger_than_asked_for_ends_the_session(self):
        p = self.run_session((12000, 12000), "64x40")
        rc = p.wait(15)
        log = p.stdout.read()
        self.assertIn("larger than this client asked for", log)
        self.assertNotIn("desktop is", log)
        self.assertEqual(rc, 147, log)

    def test_a_picture_larger_than_its_stream_is_refused_before_decoding(self):
        p = self.run_session((64, 40), "1280x720")
        rc = p.wait(15)
        log = p.stdout.read()
        self.assertIn("pictures larger than its stream", log)
        self.assertNotIn("desktop is", log)
        self.assertEqual(rc, 147, log)



# A fake ssh for a host never seen before: it asks its askpass (OMARemote) as ssh does, then runs
# the fake gliff-server on a yes, or fails as ssh fails.
FAKE_SSH = r'''
import os, subprocess, sys
assert os.environ.get("SSH_ASKPASS_REQUIRE") == "force"
question = ("The authenticity of host 'pc.lan (127.0.0.1)' can't be established.\n"
            "ED25519 key fingerprint is: SHA256:testkey\n"
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
answer = subprocess.run([os.environ["SSH_ASKPASS"], question], capture_output=True, text=True)
if answer.returncode != 0 or answer.stdout.strip() != "yes":
    sys.stderr.write("Host key verification failed.\n")
    sys.exit(255)
os.execv(sys.executable, [sys.executable, "-I"] + sys.argv[1:])
'''


@unittest.skipUnless(os.path.exists(GLIFF), "needs the native build (ninja -C native/build)")
@unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg with libx264 to make a test picture")
class HostKey(unittest.TestCase):
    """A host this computer never connected to: ssh asks through OMARemote, shown in the session."""

    def run_session(self, answer):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        server, ssh = os.path.join(d, "server.py"), os.path.join(d, "ssh.py")
        with open(server, "w") as f:
            f.write(FAKE_SERVER)
        with open(ssh, "w") as f:
            f.write(FAKE_SSH)
        picture = Decoder.picture(self, d, "64x40")
        args = [sys.executable, "-I", ssh, server, "64", "40", picture]
        sock = os.path.join(d, "s")
        p = subprocess.Popen([GLIFF], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env=dict(os.environ, OMAREMOTE_SOCKET=sock), text=True)
        self.addCleanup(p.stdout.close)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write("host=pc.lan\nvideo=cpu\nclipboard=0\n" + "".join(f"arg={a}\n" for a in args))
        p.stdin.close()
        lines = []
        threading.Thread(target=lambda: lines.extend(p.stdout), daemon=True).start()
        ui = socket.socket(socket.AF_UNIX)
        self.addCleanup(ui.close)
        deadline = time.monotonic() + 10
        while True:
            try:
                ui.connect(sock)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.assertLess(time.monotonic(), deadline, "no session socket")
                time.sleep(0.02)
        ui.settimeout(10)
        received = b""
        while b"\nhostkey " not in b"\n" + received:
            data = ui.recv(65536)
            self.assertTrue(data, "the session ended without asking")
            received += data
        line = (b"\n" + received).split(b"\nhostkey ", 1)[1].split(b"\n", 1)[0].decode()
        host, key, details, warn = line.split()
        self.assertEqual(base64.b64decode(host).decode(), "pc.lan (127.0.0.1)")
        self.assertEqual(base64.b64decode(key).decode(), "ED25519 key fingerprint is: SHA256:testkey")
        self.assertTrue(base64.b64decode(details).decode().startswith("The authenticity of host"))
        self.assertEqual(warn, "0")
        ui.sendall(answer.encode() + b"\n")
        return p, lines

    def test_this_computers_own_key_is_refused_without_asking(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        ssh = os.path.join(d, "ssh.py")
        with open(ssh, "w") as f:
            f.write(FAKE_SSH)
        p = subprocess.Popen([GLIFF], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env=dict(os.environ, OMAREMOTE_SOCKET=os.path.join(d, "s")), text=True)
        self.addCleanup(p.stdout.close)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write("host=pc.lan\nvideo=cpu\nclipboard=0\nselfkey=SHA256:other\nselfkey=SHA256:testkey\n"
                      + "".join(f"arg={a}\n" for a in [sys.executable, "-I", ssh, "-c", "pass"]))
        p.stdin.close()
        rc = p.wait(15)
        log = p.stdout.read()
        self.assertIn("offers this computer's own host key", log)
        self.assertIn("This is this computer", log)
        self.assertNotIn("ssh asks whether to trust", log)
        self.assertNotEqual(rc, 0)

    def wait_for(self, p, lines, text):
        deadline = time.monotonic() + 10
        while not any(text in l for l in lines) and time.monotonic() < deadline and p.poll() is None:
            time.sleep(0.02)
        return "".join(lines)

    def test_trusted_it_connects(self):
        p, lines = self.run_session("cert-answer 1")
        log = self.wait_for(p, lines, "desktop is 64x40")
        self.assertIn("host key trusted", log)
        self.assertIn("desktop is 64x40", log)
        p.terminate()
        self.assertEqual(p.wait(5), 11)

    def test_not_trusted_says_so(self):
        p, lines = self.run_session("cancel")
        rc = p.wait(15)
        time.sleep(0.2)
        log = "".join(lines)
        self.assertIn("the host key of pc.lan was not trusted", log)
        self.assertNotIn("desktop is", log)
        self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
