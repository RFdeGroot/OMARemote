import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "ui")
INPUT = os.path.join(UI, "Input.qml")
PLUGIN = os.path.join(HERE, "..", "native", "build", "qml")
QML = shutil.which("qml6") or shutil.which("qml")

# omarchy-plugin-marketplace#11361: a text field must not read the clipboard by itself, and a paste
# is bounded. Every text field goes through ui/Input.qml, which arranges both (PasteGuard).


def code(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


class Static(unittest.TestCase):
    def test_every_text_field_is_input(self):
        offenders = []
        for base, dirs, files in os.walk(UI):
            # ui/boot and ui/window link Omarchy's own Commons and Ui: not ours to check.
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(base, d))]
            for name in files:
                path = os.path.join(base, name)
                if not name.endswith(".qml") or os.path.samefile(path, INPUT):
                    continue
                with open(path, encoding="utf-8") as f:
                    text = code(f.read())
                for m in re.finditer(r"(?<![\w.])(?:\w+\.)?(TextField|TextInput|TextArea|TextEdit)\s*\{", text):
                    offenders.append(f"{os.path.relpath(path, UI)}: {m.group(0)}")
        self.assertEqual(offenders, [], "use Input (ui/Input.qml)")

    def test_input_never_toggles_read_only(self):
        with open(INPUT, encoding="utf-8") as f:
            text = code(f.read())
        self.assertNotIn("readOnly", text)
        self.assertIn("PasteGuard.guard(", text)
        self.assertRegex(text, r"ContextMenu\.menu:\s*null")


@unittest.skipUnless(QML and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qml6 and the native build (ninja -C native/build)")
class Runtime(unittest.TestCase):
    """ui/Input.qml with the real PasteGuard, offscreen; Omarchy's TextField stands in as a plain one."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        ui = os.path.join(self.dir, "qs", "Ui")
        os.makedirs(ui)
        with open(os.path.join(ui, "qmldir"), "w") as f:
            f.write("module qs.Ui\nTextField 1.0 TextField.qml\nPanelToolTip 1.0 PanelToolTip.qml\n")
        with open(os.path.join(ui, "TextField.qml"), "w") as f:
            f.write("import QtQuick.Controls\nTextField {}\n")
        with open(os.path.join(ui, "PanelToolTip.qml"), "w") as f:
            f.write("import QtQuick.Controls\nToolTip {}\n")
        # Input.qml's js/Limits.js, next to the copy.
        shutil.copytree(os.path.join(UI, "js"), os.path.join(self.dir, "js"))
        # A copy: ui/ as a directory import brings in types that need Quickshell.
        self.input = os.path.join(self.dir, "Input.qml")
        shutil.copy(INPUT, self.input)
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        self.args = os.path.join(self.dir, "args")

    def stub(self, content, sleep=0):
        data = os.path.join(self.dir, "content")
        with open(data, "wb") as f:
            f.write(content)
        path = os.path.join(self.bin, "wl-paste")
        with open(path, "w") as f:
            f.write(f'#!/bin/sh\necho "$@" > "{self.args}"\nsleep {sleep}\nexec cat "{data}"\n')
        os.chmod(path, 0o755)

    def run_qml(self, mode):
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QT_QUICK_CONTROLS_STYLE="Basic",
                   QML_IMPORT_PATH=os.pathsep.join([PLUGIN, self.dir]),
                   PATH=os.pathsep.join([self.bin, os.environ.get("PATH", "")]))
        url = "file://" + self.input
        p = subprocess.run([QML, os.path.join(HERE, "qml", "paste.qml"), "--", mode, url],
                           env=env, capture_output=True, text=True, timeout=30)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        self.assertNotIn("error", json.loads(found.group(1)), p.stderr)
        return json.loads(found.group(1)), p.stderr

    def test_no_clipboard_read_on_change_or_focus(self):
        result, _ = self.run_qml("guard")
        self.assertTrue(result["focused"])
        self.assertGreater(result["plainReads"], 0, "the check sees an unguarded field read")
        self.assertEqual(result["reads"], 0)
        self.assertFalse(result["again"], "Input.qml guarded the field already")
        self.assertFalse(result["readOnly"])
        self.assertTrue(result["menu"])

    def test_paste_replaces_the_selection_with_one_line(self):
        self.stub(b"one\r\ntwo\tthree\x07\n")
        result, _ = self.run_qml("clipboard")
        self.assertEqual(result["text"], "abone twothreecd")
        with open(self.args) as f:
            self.assertEqual(f.read().split(), ["--no-newline", "--type", "text"])

    def test_middle_click_pastes_the_selection(self):
        self.stub(b"x")
        result, _ = self.run_qml("primary")
        self.assertEqual(result["text"], "abxcd")
        with open(self.args) as f:
            self.assertIn("--primary", f.read().split())

    def test_too_large_is_not_pasted(self):
        self.stub(b"a" * (16 * 1024 + 1))
        result, err = self.run_qml("clipboard")
        self.assertEqual(result["text"], "ab[sel]cd")
        self.assertIn("more than 16384 bytes", err)

    def test_a_field_has_a_maximum_by_default(self):
        self.stub(b"x")
        result, _ = self.run_qml("clipboard")
        self.assertEqual(result["maximum"], 256)

    def test_paste_that_does_not_fit_is_refused_whole(self):
        # "ab[sel]cd" with "[sel]" selected, at most 10: 4 kept, so 7 more do not fit.
        self.stub(b"1234567")
        result, err = self.run_qml("short")
        self.assertEqual(result["text"], "ab[sel]cd")
        self.assertEqual(result["refused"], 10)
        self.assertIn("does not fit the field (at most 10 characters)", err)

    def test_paste_that_just_fits_goes_in(self):
        self.stub(b"123456")
        result, _ = self.run_qml("short")
        self.assertEqual(result["text"], "ab123456cd")
        self.assertEqual(result["refused"], 0)

    def test_slow_is_not_pasted(self):
        self.stub(b"late", sleep=5)
        result, err = self.run_qml("clipboard")
        self.assertEqual(result["text"], "ab[sel]cd")
        self.assertIn("took more than 2000 ms", err)


if __name__ == "__main__":
    unittest.main()
