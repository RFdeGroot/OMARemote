import os
import re
import unittest

UI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui")

# Qt 6.12's QtQuick has a Color singleton of its own, which a bare `Color` resolves to: Omarchy's
# palette then reads undefined and every theme colour comes out transparent (seen on the MacBook,
# Arch Linux ARM). Omarchy (omacom/omarchy#14553) and Flea (#276) use `Commons.Color`; so do we.
BARE_COLOR = re.compile(r"(?<![\w.])Color\s*[.\[]")
COMMONS_IMPORT = re.compile(r"^\s*import\s+qs\.Commons(\s+[\d.]+)?\s+as\s+Commons\s*$", re.M)


def sources():
    for base, dirs, files in os.walk(UI):
        # ui/boot and ui/window link Omarchy's own Commons and Ui: not ours to check.
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(base, d))]
        for name in files:
            if name.endswith((".qml", ".js")):
                yield os.path.join(base, name)


def code(text):
    """The text without comments, so a comment may still mention Color."""
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


class Palette(unittest.TestCase):
    def test_no_bare_color(self):
        offenders = []
        for path in sources():
            with open(path, encoding="utf-8") as f:
                for n, line in enumerate(code(f.read()).split("\n"), 1):
                    if BARE_COLOR.search(line):
                        offenders.append(f"{os.path.relpath(path, UI)}:{n}: {line.strip()}")
        self.assertEqual(offenders, [], "use Commons.Color (import qs.Commons as Commons)")

    def test_a_file_reading_commons_imports_it_by_that_name(self):
        missing = []
        for path in sources():
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if re.search(r"(?<![\w.])Commons\.", code(text)) and not COMMONS_IMPORT.search(text):
                missing.append(os.path.relpath(path, UI))
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
