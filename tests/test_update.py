import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
UPDATE = os.path.join(HERE, "..", "bin", "omaremote-update")
_loader = importlib.machinery.SourceFileLoader("session", os.path.join(HERE, "..", "bin", "omaremote-session"))
_spec = importlib.util.spec_from_loader("session", _loader)
session = importlib.util.module_from_spec(_spec)
_loader.exec_module(session)


class Update(unittest.TestCase):
    """bin/omaremote-update, run for real with stand-ins for the network, gpgv, sudo and pacman."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.bin = os.path.join(self.dir, "bin")
        self.stubs = os.path.join(self.dir, "stubs")
        os.makedirs(self.bin)
        os.makedirs(self.stubs)
        self.log = os.path.join(self.dir, "log")
        shutil.copy(UPDATE, os.path.join(self.bin, "omaremote-update"))
        url = "https://example.invalid/omaremote-9.9.9-1-x86_64.pkg.tar.zst"
        self.script("bin/omaremote", 'echo "omaremote 1.0.0"')
        self.script("bin/omaremote-session", "echo '%s'" % json.dumps({"latest": "9.9.9", "url": url, "newer": True}))
        # curl -o <file> <url>: the package, or its signature. Each call's arguments go to curl.log.
        self.curl_log = os.path.join(self.dir, "curl.log")
        self.script("stubs/curl", 'echo "$*" >> "%s"; out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && '
                                  '{ out=$2; shift; }; shift; done; echo data > "$out"' % self.curl_log)
        self.script("stubs/gpgv", 'echo "[GNUPG:] VALIDSIG D7FC432CF643656A400BDDEB3BE7753BBB50B393 x"')
        self.script("stubs/bsdtar", 'echo "installed = qt6-base-6.11.2-3-x86_64"')
        self.script("stubs/pacman", 'echo "qt6-base 6.11.2-3"')
        self.script("stubs/vercmp", 'echo 0')
        # What pacman -U would see: every file beside the package it is given.
        self.script("stubs/sudo", 'echo "$@" >> "%s"; for f in "$(dirname "${@: -1}")"/*; do '
                                  'echo "beside: $(basename "$f")" >> "%s"; done' % (self.log, self.log))
        for name in ("hyprctl", "qs", "setsid", "uwsm-app"):
            self.script("stubs/" + name, "exit 0")

    def script(self, path, body):
        full = os.path.join(self.dir, path)
        with open(full, "w") as f:
            f.write("#!/bin/bash\n" + body + "\n")
        os.chmod(full, os.stat(full).st_mode | stat.S_IEXEC)

    def run_update(self):
        env = dict(os.environ, PATH=self.stubs + ":" + os.environ["PATH"])
        return subprocess.run([os.path.join(self.bin, "omaremote-update")], env=env,
                              capture_output=True, text=True, timeout=30)

    def test_pacman_never_finds_a_signature_beside_the_package(self):
        # pacman -U checks a .sig beside a package against its own keyring, which lacks
        # OMARemote's key, and refuses the update (0.4.0 to 0.4.2).
        out = self.run_update()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        with open(self.log) as f:
            log = f.read()
        self.assertIn("pacman -U", log)
        self.assertIn("beside: omaremote-9.9.9-1-x86_64.pkg.tar.zst", log)
        self.assertNotIn(".pkg.tar.zst.sig", log)

    def test_a_bad_signature_installs_nothing(self):
        self.script("stubs/gpgv", 'echo "[GNUPG:] BADSIG D7FC432CF643656A400BDDEB3BE7753BBB50B393 x"')
        out = self.run_update()
        self.assertNotEqual(out.returncode, 0)
        self.assertFalse(os.path.exists(self.log))

    def test_an_older_release_is_never_installed(self):
        # 0.9.7 installed, 0.9.6 listed as the newest (a pulled release): no downgrade.
        url = "https://example.invalid/omaremote-0.9.6-1-x86_64.pkg.tar.zst"
        self.script("bin/omaremote", 'echo "omaremote 0.9.7"')
        self.script("bin/omaremote-session", "echo '%s'" % json.dumps({"latest": "0.9.6", "url": url, "newer": False}))
        out = self.run_update()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("newest release already", out.stdout)
        self.assertNotIn("Updating", out.stdout)
        self.assertFalse(os.path.exists(self.log))

    def test_a_good_signature_by_another_key_installs_nothing(self):
        self.script("stubs/gpgv", 'echo "[GNUPG:] VALIDSIG 0123456789ABCDEF0123456789ABCDEF01234567 x 0123456789ABCDEF0123456789ABCDEF01234567"')
        out = self.run_update()
        self.assertNotEqual(out.returncode, 0)
        self.assertFalse(os.path.exists(self.log))

    def test_every_download_has_a_cap_and_a_deadline(self):
        # Both files arrive before the signature is checked: a server streaming without end would
        # fill the disk first (marketplace #12133, the plugin's install command and this one).
        out = self.run_update()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        with open(self.curl_log) as f:
            calls = f.read().splitlines()
        self.assertEqual(len(calls), 2)
        package, signature = calls
        for call in calls:
            self.assertIn("--proto =https", call)
            self.assertIn("--proto-redir =https", call)
            self.assertIn("--connect-timeout", call)
            self.assertIn("--max-time", call)
        self.assertIn("--max-filesize %d " % (64 << 20), package)
        self.assertIn("--max-filesize %d " % (64 << 10), signature)

    def test_a_failed_download_installs_nothing(self):
        # curl exit 63: past --max-filesize.
        self.script("stubs/curl", "exit 63")
        out = self.run_update()
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("at most 64 MiB", out.stdout)
        self.assertFalse(os.path.exists(self.log))


class Response:
    """A response that sends `chunks` (repeating the last one forever when endless), pausing between."""

    def __init__(self, chunks, endless=False, pause=0):
        self.chunks, self.endless, self.pause = list(chunks), endless, pause

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read1(self, n):
        if self.pause:
            import time
            time.sleep(self.pause)
        if len(self.chunks) > 1 or (self.chunks and not self.endless):
            return self.chunks.pop(0)
        return self.chunks[0] if self.chunks else b""


class FetchJson(unittest.TestCase):
    """The update and plugin checks read GitHub's releases list: capped, with a deadline, https only."""

    def fetch(self, response, **kw):
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch("urllib.request.build_opener", return_value=opener) as build:
            result = session.fetch_json("https://api.github.com/x", "omaremote", **kw)
        return result, build

    def test_reads_a_list(self):
        result, _ = self.fetch(Response([b'[{"tag_name": ', b'"v1.0.0"}]']))
        self.assertEqual(result, [{"tag_name": "v1.0.0"}])

    def test_a_stream_past_the_cap_is_refused(self):
        # Before: json.load(response) read whatever the server sent.
        with self.assertRaises(OSError):
            self.fetch(Response([b"[" + b" " * 65536], endless=True), cap=1 << 20)

    def test_a_trickle_stops_at_the_deadline(self):
        # A socket timeout is per read: one byte every so often never trips it.
        with self.assertRaises(OSError):
            self.fetch(Response([b"[", b" "], endless=True, pause=0.01), deadline=0.3)

    def serve(self, reply, pause=0):
        """A local plain-HTTP server that sends reply one byte at a time, pause seconds apart; returns
        an opener whose open() reaches it (fetch_json itself only takes https)."""
        import socket
        import threading
        import time
        import urllib.request
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        self.addCleanup(server.close)

        def answer():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            with conn:
                conn.recv(65536)
                try:
                    for byte in reply:
                        conn.sendall(bytes([byte]))
                        time.sleep(pause)
                except OSError:
                    pass
        threading.Thread(target=answer, daemon=True).start()
        url = "http://127.0.0.1:%d/" % server.getsockname()[1]
        opener = mock.Mock()
        real = urllib.request.build_opener()
        opener.open.side_effect = lambda *args, **kw: real.open(url, timeout=5)
        return opener

    def test_trickled_headers_stop_at_the_deadline(self):
        # Before: the deadline only covered the body; open() read the status line and headers with
        # the 20 s per-read timeout, so one header byte every few seconds held it far longer.
        import time
        opener = self.serve(b"HTTP/1.1 200 OK\r\n" + b"X: " + b"y" * 200 + b"\r\n\r\n[]", pause=0.05)
        start = time.monotonic()
        with mock.patch("urllib.request.build_opener", return_value=opener), self.assertRaises(OSError):
            session.fetch_json("https://api.github.com/x", "omaremote", deadline=0.5)
        self.assertLess(time.monotonic() - start, 3)

    def test_a_garbled_answer_is_an_oserror(self):
        # Before: http.client.BadStatusLine escaped, and plugin-check/update-check ended in a traceback.
        opener = self.serve(b"garbage\r\n\r\n")
        with mock.patch("urllib.request.build_opener", return_value=opener), self.assertRaises(OSError):
            session.fetch_json("https://api.github.com/x", "omaremote", deadline=5)

    def test_only_https(self):
        with self.assertRaises(OSError):
            session.fetch_json("http://api.github.com/x", "omaremote")
        _, build = self.fetch(Response([b"[]"]))
        handler = build.call_args.args[0]()
        with self.assertRaises(OSError):
            handler.redirect_request(mock.Mock(), None, 302, "Found", {}, "http://evil.invalid/")

    def test_both_checks_go_through_it(self):
        with mock.patch.object(session, "fetch_json", return_value=[]) as fetch:
            session.update_check("1.0.0")
        self.assertEqual(fetch.call_args.args[0], session.RELEASES_API)
        with tempfile.TemporaryDirectory() as plugins, \
                mock.patch.object(session, "fetch_json", side_effect=OSError("too big")), \
                mock.patch("shutil.which", return_value="/usr/bin/omarchy-plugin-add"):
            self.assertEqual(session.plugin_check(plugins_dir=plugins)["latest"], "")


if __name__ == "__main__":
    unittest.main()
