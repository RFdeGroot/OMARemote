"""ui/ProgressStrip.qml, Ghostty's progress bar for a terminal (OSC 9;4): the share done, the
theme's red, paused as the accent faded, a sliding block without a percentage, nothing
without a report."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "ui")
QML = shutil.which("qml6") or shutil.which("qml")


@unittest.skipUnless(QML, "needs qml6")
class ProgressStrip(unittest.TestCase):
    def test_each_state(self):
        with tempfile.TemporaryDirectory() as d:
            commons = os.path.join(d, "qs", "Commons")
            os.makedirs(commons)
            with open(os.path.join(commons, "qmldir"), "w") as f:
                f.write("module qs.Commons\nsingleton Util 1.0 Util.qml\n")
            with open(os.path.join(commons, "Util.qml"), "w") as f:
                f.write("pragma Singleton\nimport QtQuick\nQtObject {\n"
                        "    function alpha(c, a) { c = Qt.color(c); return Qt.rgba(c.r, c.g, c.b, a) }\n}\n")
            with open(os.path.join(d, "qmldir"), "w") as f:
                f.write("singleton Theme 1.0 Theme.qml\nProgressStrip 1.0 ProgressStrip.qml\n")
            with open(os.path.join(d, "Theme.qml"), "w") as f:
                f.write('pragma Singleton\nimport QtQuick\nQtObject {\n    readonly property color foreground: "white"\n'
                        '    readonly property color accent: "#0000ff"\n    readonly property color urgent: "#ff0000"\n'
                        '    readonly property color warning: "#ffff00"\n}\n')
            shutil.copy(os.path.join(UI, "ProgressStrip.qml"), d)
            shutil.copy(os.path.join(HERE, "qml", "progressstrip.qml"), d)
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QML_IMPORT_PATH=d)
            p = subprocess.run([QML, os.path.join(d, "progressstrip.qml")], env=env, capture_output=True,
                               text=True, timeout=30)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        r = json.loads(found.group(1))
        self.assertFalse(r[":-1"]["shown"])
        self.assertEqual((r["set:25"]["width"], r["set:25"]["pulsing"], r["set:25"]["ink"]), (50, False, "#0000ff"))
        self.assertTrue(r["set:-1"]["pulsing"])
        self.assertEqual((r["error:50"]["width"], r["error:50"]["ink"]), (100, "#ff0000"))
        self.assertEqual((r["pause:80"]["width"], r["pause:80"]["ink"], r["pause:80"]["opacity"]), (160, "#0000ff", 0.5))
        self.assertEqual(r["set:25"]["opacity"], 1)
        self.assertTrue(r["indeterminate:-1"]["pulsing"])
        self.assertEqual(r["indeterminate:-1"]["width"], 0)


if __name__ == "__main__":
    unittest.main()
