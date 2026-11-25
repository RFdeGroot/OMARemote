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


TESTRUNNER = shutil.which("qmltestrunner6") or shutil.which("qmltestrunner") or (
    "/usr/lib/qt6/bin/qmltestrunner" if os.access("/usr/lib/qt6/bin/qmltestrunner", os.X_OK) else None)


def stand_ins(d):
    """ScrollHint.qml in d, with plain stand-ins for Theme and Omarchy's Util."""
    commons = os.path.join(d, "qs", "Commons")
    os.makedirs(commons)
    with open(os.path.join(commons, "qmldir"), "w") as f:
        f.write("module qs.Commons\nsingleton Util 1.0 Util.qml\n")
    with open(os.path.join(commons, "Util.qml"), "w") as f:
        f.write("pragma Singleton\nimport QtQuick\nQtObject {\n"
                "    function alpha(c, a) { c = Qt.color(c); return Qt.rgba(c.r, c.g, c.b, a) }\n}\n")
    with open(os.path.join(d, "qmldir"), "w") as f:
        f.write("singleton Theme 1.0 Theme.qml\nScrollHint 1.0 ScrollHint.qml\n")
    with open(os.path.join(d, "Theme.qml"), "w") as f:
        f.write("pragma Singleton\nimport QtQuick\nQtObject { readonly property color foreground: \"white\" }\n")
    shutil.copy(os.path.join(UI, "ScrollHint.qml"), d)


@unittest.skipUnless(TESTRUNNER, "needs qmltestrunner")
class ScrollHintPointer(unittest.TestCase):
    """The pointer on the bar keeps it shown (it blinked: the bar's MouseArea took the hover from
    the pane and the bar faded out from under it), and the thumb can be dragged."""

    def test_on_the_bar_and_dragging(self):
        with tempfile.TemporaryDirectory() as d:
            stand_ins(d)
            # The test next to the copy, so `ScrollHint` resolves from the directory.
            shutil.copy(os.path.join(HERE, "qml", "tst_scrollhint.qml"), d)
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
            p = subprocess.run([TESTRUNNER, "-import", d, "-input", os.path.join(d, "tst_scrollhint.qml")],
                               env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


@unittest.skipUnless(QML, "needs qml6")
class ScrollHint(unittest.TestCase):
    """ui/ScrollHint.qml as an overlay scrollbar: out of sight at rest (also while a list lays
    out), shown while the pane scrolls, faded out a moment after, never on a pane that fits.
    Theme and Omarchy's Util stand in as plain ones."""

    def test_shown_while_scrolling_only(self):
        with tempfile.TemporaryDirectory() as d:
            stand_ins(d)
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QML_IMPORT_PATH=d)
            p = subprocess.run([QML, os.path.join(HERE, "qml", "scrollhint.qml"), "--",
                                "file://" + os.path.join(d, "ScrollHint.qml")],
                               env=env, capture_output=True, text=True, timeout=30)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        seen = json.loads(found.group(1))
        self.assertFalse(seen["anyShownAtStart"], "the bar flashed up while the list laid out")
        self.assertEqual(seen["atRest"], {"shown": False, "visible": False})
        self.assertEqual(seen["scrolled"], {"shown": True, "visible": True})
        self.assertEqual(seen["later"], {"shown": False, "visible": False, "opacity": 0})
        self.assertEqual(seen["fits"], {"shown": False, "visible": False})


if __name__ == "__main__":
    unittest.main()
