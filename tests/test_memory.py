import os
import subprocess
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "native", "build")

# What a server can make a session allocate (omarchy-plugin-marketplace#12352): Gliff's decoder is
# bounded in tests/test_gliff.py (Decoder); RDP's graphics pipeline here; and every session process
# has a ceiling for what slips past both (native/common/link.hpp, kMaxSessionData).


class RdpGraphics(unittest.TestCase):
    @unittest.skipUnless(os.access(os.path.join(BUILD, "rdp-gfx-test"), os.X_OK), "native build missing: ninja -C native/build")
    def test_surfaces_are_bounded_before_freerdp_allocates_them(self):
        out = subprocess.run([os.path.join(BUILD, "rdp-gfx-test")], capture_output=True, text=True, timeout=10)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)


class SessionCeiling(unittest.TestCase):
    @unittest.skipUnless(os.access(os.path.join(BUILD, "rdp-gfx-test"), os.X_OK), "native build missing: ninja -C native/build")
    def test_reaching_it_ends_the_session_without_a_crash(self):
        # Not std::bad_alloc, abort and a core dump ("Process crashed"): the code a lost connection has.
        out = subprocess.run([os.path.join(BUILD, "rdp-gfx-test"), "ceiling"], capture_output=True, text=True, timeout=10)
        self.assertEqual(out.returncode, 147, out.stdout + out.stderr)
        self.assertIn("memory ceiling", out.stdout + out.stderr)

    def max_data(self, helper):
        path = os.path.join(BUILD, helper)
        if not os.access(path, os.X_OK):
            self.skipTest("native build missing: ninja -C native/build")
        # Each reads its settings from stdin first: held open, it waits there with the limit set.
        p = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             env=dict(os.environ, OMAREMOTE_SOCKET="/nonexistent/s"))
        self.addCleanup(lambda: p.poll() is None and p.kill())
        self.addCleanup(p.stdin.close)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with open(f"/proc/{p.pid}/limits") as f:
                line = next(l for l in f if l.startswith("Max data size"))
            soft, hard = line.split()[3:5]
            if soft != "unlimited":
                return int(soft), int(hard)
            time.sleep(0.02)
        self.fail(f"{helper} runs without a memory ceiling")

    def test_every_session_process_has_one(self):
        for helper in ("omaremote-rdp", "omaremote-vnc", "omaremote-ssh", "omaremote-gliff"):
            with self.subTest(helper):
                self.assertEqual(self.max_data(helper), (4 << 30, 4 << 30))


if __name__ == "__main__":
    unittest.main()
