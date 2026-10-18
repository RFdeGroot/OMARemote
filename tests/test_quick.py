import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CARD = os.path.join(HERE, "..", "ui", "QuickConnectCard.qml")
QML = shutil.which("qml6") or shutil.which("qml")
_loader = importlib.machinery.SourceFileLoader("session", os.path.join(HERE, "..", "bin", "omaremote-session"))
session = importlib.util.module_from_spec(importlib.util.spec_from_loader("session", _loader))
_loader.exec_module(session)

# The quick connect card never sends a credential set's password to a server nobody chose it for:
# a set filled in from a recent quick connection is let go when the address changes to another host.


@unittest.skipUnless(QML, "needs qml6")
class QuickCredential(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
        p = subprocess.run([QML, os.path.join(HERE, "qml", "format.qml")], env=env,
                           capture_output=True, text=True, timeout=30)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        assert found, p.stderr
        cls.r = json.loads(found.group(1))
        assert "error" not in cls.r, cls.r["error"]

    def test_same_host_keeps_the_set(self):
        self.assertEqual(self.r["same"], {"credential": "k1", "filledFor": "pc.acme.lan"})

    def test_another_host_lets_it_go(self):
        self.assertEqual(self.r["other"], {"credential": "custom", "filledFor": ""})
        self.assertEqual(self.r["typed"], {"credential": "custom", "filledFor": ""})

    def test_a_set_picked_by_hand_stays(self):
        self.assertEqual(self.r["picked"], {"credential": "k1", "filledFor": ""})
        self.assertEqual(self.r["none"], {"credential": "custom", "filledFor": ""})

    def test_one_port_table_equal_to_the_backend(self):
        # Gliff connections without a port of their own showed host:3389 (Store had no gliff).
        self.assertEqual(self.r["ports"], session.DEFAULT_PORTS)
        self.assertEqual(self.r["gliffAddress"], "pc.lan")


class Card(unittest.TestCase):
    def test_the_card_applies_it(self):
        with open(CARD, encoding="utf-8") as f:
            text = f.read()
        follow = re.search(r"function follow\(\) \{.*?\n    \}", text, re.S).group(0)
        fill = re.search(r"function fill\(c\) \{.*?\n    \}", text, re.S).group(0)
        self.assertIn("Format.quickCredential(credential, credentialFor, p.host)", follow)
        self.assertRegex(fill, r"credentialFor = credential !== \"custom\" \? c\.host")


if __name__ == "__main__":
    unittest.main()
