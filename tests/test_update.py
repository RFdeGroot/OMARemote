import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
UPDATE = os.path.join(HERE, "..", "bin", "omaremote-update")


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
        # curl -o <file> <url>: the package, or its signature.
        self.script("stubs/curl", 'out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done; '
                                  'echo data > "$out"')
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


if __name__ == "__main__":
    unittest.main()
