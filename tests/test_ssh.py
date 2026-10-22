import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "native", "build", "omaremote-ssh")

# Stands in for ssh: each run takes the next line of $FAKE_SSH_PLAN ("up", or a failure line to
# print and exit 255 with, or "exit" for a shell that ends) and counts its runs in $FAKE_SSH_DIR/n.
FAKE_SSH = r"""#!/bin/sh
n=$(cat "$FAKE_SSH_DIR/n" 2>/dev/null || echo 0)
echo $((n + 1)) > "$FAKE_SSH_DIR/n"
step=$(printf '%s\n' "$FAKE_SSH_PLAN" | sed -n "$((n + 1))p")
case $step in
  up:*) echo "Welcome"; sleep 0.2; echo "${step#up:}"; exit 255 ;;
  exit) echo "bye"; exit 0 ;;
  *) echo "$step"; exit 255 ;;
esac
"""


@unittest.skipUnless(os.path.exists(HELPER), "needs the native build")
class Reconnect(unittest.TestCase):
    """omaremote-ssh trying a lost connection again in the same terminal, at 1/1000 of the pace."""

    def run_plan(self, plan, reconnect=True):
        with tempfile.TemporaryDirectory() as d:
            ssh = os.path.join(d, "ssh")
            with open(ssh, "w") as f:
                f.write(FAKE_SSH)
            os.chmod(ssh, 0o700)
            config = "\n".join([f"arg={ssh}", "arg=pc.lan", "host=pc.lan", "font=monospace", "fontSize=10",
                                f"reconnect={1 if reconnect else 0}", "reconnectMs=1"]) + "\n"
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
        # 10 minutes at this pace are 0.6 s: pauses of 2, 4, 8, then 15 (ms) give some 40 tries.
        rc, log, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe"]
                                      + ["ssh: connect to host pc.lan port 22: No route to host"] * 500)
        self.assertEqual(rc, 255)
        self.assertTrue(20 < runs < 80, runs)
        self.assertIn("connection failed: ssh: connect to host pc.lan port 22: No route to host", log)

    def test_a_server_that_keeps_saying_broken_pipe_is_not_dialled_forever(self):
        # Its own "Broken pipe" and exit 255, again and again, with no one typing: 20 drops, then it ends.
        rc, _, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe"] * 40)
        self.assertEqual((rc, runs), (255, 21))

    def test_switched_off_it_ends_as_before(self):
        rc, _, runs = self.run_plan(["up:client_loop: send disconnect: Broken pipe", "exit"], reconnect=False)
        self.assertEqual((rc, runs), (255, 1))


if __name__ == "__main__":
    unittest.main()
