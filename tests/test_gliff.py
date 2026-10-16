import importlib.machinery
import json
import re
import shutil
import importlib.util
import os
import subprocess
import sys
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


if __name__ == "__main__":
    unittest.main()
