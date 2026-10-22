import importlib.machinery
import importlib.util
import os
import re
import sys
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "ui")
_loader = importlib.machinery.SourceFileLoader("session", os.path.join(HERE, "..", "bin", "omaremote-session"))
_spec = importlib.util.spec_from_loader("session", _loader)
session = importlib.util.module_from_spec(_spec)
_loader.exec_module(session)

# Every field has a maximum length (ui/js/Limits.js), and files that arrive by import and sync are
# held to the same numbers (omaremote-session LIMITS). Sources: docs/limits.md.


def js_limits():
    with open(os.path.join(UI, "js", "Limits.js"), encoding="utf-8") as f:
        return {k: int(v) for k, v in re.findall(r"^var (\w+) = (\d+)", f.read(), re.M)}


def input_blocks():
    """(file, line, the Input's own lines) for every Input in ui/."""
    for name in sorted(os.listdir(UI)):
        if not name.endswith(".qml") or name == "Input.qml":
            continue
        with open(os.path.join(UI, name), encoding="utf-8") as f:
            lines = f.read().split("\n")
        for n, line in enumerate(lines):
            if not re.match(r"^\s*Input \{", line):
                continue
            # The Input's own lines: up to the first nested block or its end.
            own = line
            for more in lines[n + 1:n + 8]:
                if "{" in more or more.strip() == "}":
                    break
                own += "\n" + more
            yield name, n + 1, own


def inputs():
    """(file, line, limit name or None) for every Input in ui/."""
    for name, n, own in input_blocks():
        m = re.search(r"maximumLength:\s*Limits\.(\w+)", own)
        yield name, n, m.group(1) if m else None


class Limits(unittest.TestCase):
    def test_ui_and_backend_agree(self):
        self.assertEqual(js_limits(), session.LIMITS)

    def test_ui_and_backend_agree_on_counts(self):
        with open(os.path.join(UI, "js", "Limits.js"), encoding="utf-8") as f:
            block = re.search(r"^var count = \{(.*?)\}", f.read(), re.M | re.S).group(1)
        counts = {k: int(v) for k, v in re.findall(r"(\w+): (\d+)", block)}
        self.assertEqual(counts, {"connections": session.STORE_MAX_CONNECTIONS, "groups": session.STORE_MAX_GROUPS,
                                  "credentials": session.STORE_MAX_CREDENTIALS, "trash": session.STORE_MAX_TRASH,
                                  "quick": session.STORE_MAX_QUICK})

    def test_every_field_names_its_limit(self):
        known = js_limits()
        missing = [f"{f}:{n}" for f, n, lim in inputs() if lim is None]
        unknown = [f"{f}:{n}: {lim}" for f, n, lim in inputs() if lim and lim not in known]
        self.assertEqual(missing, [], "give the field maximumLength: Limits.<kind>")
        self.assertEqual(unknown, [])
        self.assertGreater(len(list(inputs())), 30)

    def test_no_field_falls_back_to_a_default_text(self):
        # text: String(port || 3389) fills an emptied field straight back up: it can never be
        # cleared to type another number. A default belongs in placeholderText.
        offenders = [f"{f}:{n}" for f, n, own in input_blocks()
                     if re.search(r'(?:^|[;{]|\n)\s*text:[^;\n]*\|\|\s*(?!""|\'\')\S', own)]
        self.assertEqual(offenders, [])

    def test_input_has_a_default(self):
        with open(os.path.join(UI, "Input.qml"), encoding="utf-8") as f:
            self.assertRegex(f.read(), r"maximumLength:\s*Limits\.standard")

    def test_backend_fields_name_a_known_limit(self):
        for key, kind in session.FIELD_LIMITS.items():
            self.assertIn(kind, session.LIMITS, key)

    def test_counted_as_qt_counts(self):
        self.assertIsNone(session.too_long({"name": "a" * 256}))
        self.assertEqual(session.too_long({"name": "a" * 257}), ("name", 256))
        # An emoji is two UTF-16 units, as in Qt's maximumLength.
        self.assertEqual(session.too_long({"name": "\U0001F600" * 129}), ("name", 256))
        self.assertEqual(session.too_long({"port": 123456}), ("port", 5))
        self.assertIsNone(session.too_long({"width": 1920, "ignoreCert": True}))


class Merge(unittest.TestCase):
    NOW = 1_000_000

    def remote(self, conns=(), groups=None):
        return {"format": "omaremote-sync", "version": 1, "system": "laptop", "written": self.NOW,
                "connections": list(conns), "groups": groups or {}, "deleted": {}}

    def c(self, cid="c1", **kw):
        return dict({"id": cid, "name": cid, "host": "pc.lan", "protocol": "rdp", "port": 3389, "modified": 100}, **kw)

    def local(self):
        return {"connections": [], "groups": {}, "trash": [], "deleted": {}}

    def test_a_connection_with_a_field_too_long_is_skipped(self):
        script = "#!/bin/sh\n" + "echo x\n" * 2000
        data, report = session.merge(self.local(), [self.remote([self.c("c1", extraArgs=script), self.c("c2")])],
                                     self.NOW)
        self.assertEqual([c["id"] for c in data["connections"]], ["c2"])
        self.assertEqual(len(report["errors"]), 1)
        self.assertIn("'c1': its extraArgs is longer than 4096 characters", report["errors"][0])

    def test_a_group_with_a_setting_too_long_is_skipped(self):
        groups = {"Servers": {"modified": 100, "settings": {"kdc": "dc.lan," * 400}},
                  "Desk": {"modified": 100, "settings": {"kdc": "dc.lan"}}}
        data, report = session.merge(self.local(), [self.remote(groups=groups)], self.NOW)
        self.assertEqual(sorted(data["groups"]), ["Desk"])
        self.assertIn("'Servers': its kdc is longer than 2048 characters", report["errors"][0])

    def test_the_message_holds_no_line_breaks(self):
        _, report = session.merge(self.local(), [self.remote([self.c("c1", name="a\nb", gateway="g" * 300)])],
                                  self.NOW)
        self.assertNotIn("\n", report["errors"][0])

    def test_import_is_held_to_the_same(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "in.json")
            with open(src, "w") as f:
                json.dump(self.remote([self.c("c1", host="h" * 254)]), f)
            out = session.import_file(src, os.path.join(d, "connections.json"), self.NOW)
        self.assertEqual(out["data"]["connections"], [])
        self.assertTrue(out["report"]["errors"])


if __name__ == "__main__":
    unittest.main()
