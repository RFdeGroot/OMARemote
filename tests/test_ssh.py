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
  up:*) echo "Welcome"; sleep 0.4; echo "${step#up:}"; exit 255 ;;
  full:*) seq 1 200; printf '\033[5;1H'; sleep 0.2; echo "${step#full:}"; exit 255 ;;
  slow:*) sleep 0.05; echo "${step#slow:}"; exit 255 ;;
  silent:*) sleep 0.6; echo "${step#silent:}"; exit 255 ;;
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

    def view(self, plan, answer):
        """Runs a plan with a stand-in view on the session socket that answers the first
        "reconnect wait" (or "trying") line with answer; returns (rc, log, runs, lines seen)."""
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
                                        (b"reconnect cancel\n", b"reconnect trying"))
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


if __name__ == "__main__":
    unittest.main()
