import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("session", os.path.join(HERE, "..", "bin", "omaremote-session"))
_spec = importlib.util.spec_from_loader("session", _loader)
session = importlib.util.module_from_spec(_spec)
_loader.exec_module(session)

# Import from other clients: .rdp files, Remmina profiles and ~/.ssh/config. A foreign import only
# adds; the same server twice (in one import, or by importing again) is never added twice.

RDP = ("screen mode id:i:2\r\nfull address:s:files.acme.lan:3390\r\nusername:s:ACME\\jan\r\n"
       "gatewayhostname:s:gw.acme.lan\r\ngatewayusagemethod:i:1\r\nredirectclipboard:i:0\r\n"
       "audiomode:i:2\r\naudiocapturemode:i:1\r\ndrivestoredirect:s:*\r\nauthentication level:i:0\r\n"
       "password 51:b:01000000D08C9DDF\r\n")


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        self.ssh = os.path.join(self.root, "ssh")
        os.mkdir(self.ssh)
        self.conns = os.path.join(self.root, "connections.json")
        self.save({"connections": []})

    def tearDown(self):
        self.dir.cleanup()

    def save(self, data):
        with open(self.conns, "w", encoding="utf-8") as f:
            json.dump(data, f)

    def write(self, name, text, encoding="utf-8"):
        path = os.path.join(self.root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding=encoding, newline="") as f:
            f.write(text)
        return path

    def scan(self, *sources):
        return session.scan_foreign(list(sources), self.conns, self.ssh)

    def run_import(self, *sources, picked=None):
        """Imports and saves, as the UI does. Returns the report."""
        out = session.import_foreign(list(sources), picked, self.conns, self.ssh)
        self.save(out["data"])
        return out["report"]

    def stored(self):
        with open(self.conns, encoding="utf-8") as f:
            return json.load(f)["connections"]

    # ------------------------------------------------ parsers

    def test_rdp_utf16_with_bom(self):
        path = self.write("Files.rdp", RDP, encoding="utf-16")
        (e,) = self.scan(path)["entries"]
        conn = e["_conn"]
        self.assertEqual(e["status"], "new")
        self.assertEqual((conn["host"], conn["port"], conn["name"]), ("files.acme.lan", 3390, "Files"))
        self.assertEqual((conn["domain"], conn["username"]), ("ACME", "jan"))
        self.assertEqual(conn["gateway"], "gw.acme.lan")
        self.assertEqual((conn["clipboard"], conn["audio"], conn["microphone"]), (False, "off", True))

    def test_rdp_never_turns_checks_off_or_shares_drives(self):
        conn = self.scan(self.write("a.rdp", RDP))["entries"][0]["_conn"]
        for key in ("ignoreCert", "security", "homeDrive", "savePassword", "display", "extraArgs"):
            self.assertNotIn(key, conn)
        self.assertIn("asks to share drives: not taken over", self.scan(self.write("a.rdp", RDP))["entries"][0]["notes"])

    def test_rdp_gateway_only_when_used(self):
        conn = self.scan(self.write("a.rdp", "full address:s:h\ngatewayhostname:s:gw\ngatewayusagemethod:i:0\n"))
        self.assertNotIn("gateway", conn["entries"][0]["_conn"])

    def test_remmina_keeps_its_group_and_leaves_passwords(self):
        path = self.write("r/a.remmina", "[remmina]\nname=Build box\nprotocol=SSH\nserver=build.acme.lan:2222\n"
                                         "username=jan\ngroup=Work\npassword=c2VjcmV0\nssh_privatekey=~/.ssh/id\n")
        (e,) = self.scan(path)["entries"]
        self.assertEqual(e["group"], "Work")
        self.assertEqual(e["_conn"], {"protocol": "ssh", "name": "Build box", "host": "build.acme.lan", "port": 2222,
                                      "group": "Work", "username": "jan", "sshKey": "~/.ssh/id"})

    def test_remmina_vnc_display_and_unsupported_protocol(self):
        vnc = self.write("r/v.remmina", "[remmina]\nprotocol=VNC\nserver=pi.lan:1\nviewonly=1\n")
        self.write("r/s.remmina", "[remmina]\nprotocol=SPICE\nserver=x\n")
        scan = self.scan(os.path.dirname(vnc))
        (e,) = scan["entries"]
        self.assertEqual((e["port"], e["_conn"]["viewOnly"]), (5901, True))
        self.assertTrue(any("SPICE" in err for err in scan["errors"]))

    def test_no_group_goes_to_imported(self):
        self.write("r/a.remmina", "[remmina]\nprotocol=RDP\nserver=a.lan\n")
        self.assertEqual(self.scan(os.path.join(self.root, "r"))["entries"][0]["group"], "Imported")

    def test_ssh_config_aliases_includes_and_not_our_own(self):
        with open(os.path.join(self.ssh, "config"), "w") as f:
            f.write("Include omaremote.conf\nInclude conf.d/*\nHost *\n  User x\nHost build !no b?x\n"
                    "  HostName build.acme.lan\nMatch host foo\n  HostName other\nHost \"a b\"\n")
        with open(os.path.join(self.ssh, "omaremote.conf"), "w") as f:
            f.write("Host mine\n")
        os.mkdir(os.path.join(self.ssh, "conf.d"))
        with open(os.path.join(self.ssh, "conf.d", "web"), "w") as f:
            f.write("Host web\n  HostName web.acme.lan\n  Port 2222\n")
        entries = self.scan("ssh-config")["entries"]
        self.assertEqual([e["host"] for e in entries], ["web", "build", "a b"])
        self.assertEqual(entries[0]["notes"], ["web.acme.lan:2222"])
        self.assertEqual(entries[1]["port"], 22)  # ssh's config sets the real one
        self.assertEqual(entries[2]["status"], "invalid")

    def test_bent_values_are_not_taken_in(self):
        self.write("x/a.rdp", "full address:s:-oProxyCommand=evil\n")
        self.write("x/b.rdp", "full address:s:ok.lan\ngatewayhostname:s:gw;rm\ngatewayusagemethod:i:1\n")
        self.write("x/c.rdp", "full address:s:ok2.lan\nusername:s:" + "u" * 2000 + "\n")
        self.write("x/d.rdp", "full address:s:ok3.lan:99999\n")
        entries = self.scan(os.path.join(self.root, "x"))["entries"]
        self.assertEqual([e["status"] for e in entries], ["invalid"] * 4)
        self.assertIn("longer than", entries[2]["reason"])
        self.assertEqual(self.run_import(os.path.join(self.root, "x"))["added"], [])

    def test_large_file_refused(self):
        path = self.write("big.rdp", "full address:s:a\n" + "x" * (1 << 20))
        scan = self.scan(path)
        self.assertEqual(scan["entries"], [])
        self.assertIn("larger than 1 MiB", scan["errors"][0])

    # ------------------------------------------------ idempotent

    def test_importing_twice_adds_nothing_the_second_time(self):
        path = self.write("a.rdp", RDP)
        self.assertEqual(self.run_import(path)["added"], ["a"])
        self.assertEqual(self.scan(path)["entries"][0]["status"], "here")
        self.assertEqual(self.run_import(path)["added"], [])
        self.assertEqual(len(self.stored()), 1)

    def test_overlapping_files_add_only_what_is_new(self):
        first = self.write("one.rdp", "full address:s:files.acme.lan:3390\n")
        self.run_import(first)
        self.write("r/a.remmina", "[remmina]\nprotocol=RDP\nserver=FILES.acme.lan:3390\nname=Same\n")
        self.write("r/b.remmina", "[remmina]\nprotocol=RDP\nserver=mail.acme.lan\n")
        report = self.run_import(os.path.join(self.root, "r"))
        self.assertEqual(report["added"], ["b"])  # named after its file
        self.assertEqual(sorted(c["host"] for c in self.stored()), ["files.acme.lan", "mail.acme.lan"])

    def test_the_same_server_twice_in_one_import(self):
        self.write("x/a.rdp", "full address:s:h.lan\n")
        self.write("x/b.rdp", "full address:s:h.lan:3389\n")
        self.assertEqual([e["status"] for e in self.scan(os.path.join(self.root, "x"))["entries"]], ["new", "twice"])
        self.assertEqual(len(self.run_import(os.path.join(self.root, "x"))["added"]), 1)

    def test_ssh_alias_and_real_name_are_the_same_server(self):
        with open(os.path.join(self.ssh, "config"), "w") as f:
            f.write("Host build\n  HostName build.acme.lan\n")
        self.run_import("ssh-config")
        remmina = self.write("r/a.remmina", "[remmina]\nprotocol=SSH\nserver=build.acme.lan\n")
        self.assertEqual(self.scan(remmina)["entries"][0]["status"], "here")
        # And the other way round: the real name first, then the alias.
        self.save({"connections": []})
        self.run_import(remmina)
        self.assertEqual(self.scan("ssh-config")["entries"][0]["status"], "here")

    def test_an_existing_connection_is_never_changed(self):
        mine = {"id": "c-1", "protocol": "rdp", "host": "files.acme.lan", "port": 3390, "name": "Mine",
                "savePassword": True, "modified": 1}
        self.save({"connections": [mine]})
        self.run_import(self.write("evil.rdp", RDP))
        self.assertEqual(self.stored(), [mine])

    def test_only_the_picked_and_trashed_only_when_picked(self):
        self.save({"connections": [], "trash": [{"connection": {"id": "c-9", "host": "old.lan"}, "deleted": 5}]})
        self.write("x/a.rdp", "full address:s:old.lan\n")
        self.write("x/b.rdp", "full address:s:new1.lan\n")
        self.write("x/c.rdp", "full address:s:new2.lan\n")
        folder = os.path.join(self.root, "x")
        self.assertEqual([e["status"] for e in self.scan(folder)["entries"]], ["trashed", "new", "new"])
        self.assertEqual(self.run_import(folder, picked=["rdp|new2.lan|3389"])["added"], ["c"])
        self.assertEqual(self.run_import(folder)["added"], ["b"])
        self.assertEqual(self.run_import(folder, picked=["rdp|old.lan|3389"])["added"], ["a"])

    def test_never_a_group_credential_set(self):
        # A file can name your group and its own host: the set's password must not go there.
        self.save({"connections": [], "groups": {"Office": {"credential": "k-1", "settings": {}},
                                                 "Imported": {"credential": "k-2", "settings": {}}}})
        self.write("r/a.remmina", "[remmina]\nprotocol=RDP\nserver=evil.example.net\ngroup=Office\n")
        self.write("x/b.rdp", "full address:s:b.lan\n")
        self.run_import(os.path.join(self.root, "r"), os.path.join(self.root, "x"))
        self.assertEqual({c["host"]: (c["group"], c["credential"]) for c in self.stored()},
                         {"evil.example.net": ("Office", "custom"), "b.lan": ("Imported", "custom")})
        self.assertTrue(all(session.ID_RE.match(c["id"]) for c in self.stored()))

    def test_the_gateway_is_shown(self):
        (e,) = self.scan(self.write("a.rdp", RDP))["entries"]
        self.assertEqual(e["gateway"], "gw.acme.lan")
        with open(os.path.join(HERE, "..", "ui", "ImportCard.qml"), encoding="utf-8") as f:
            self.assertIn('"  via gateway " + modelData.gateway', f.read())

    def test_only_ordinary_files(self):
        fifo = os.path.join(self.root, "x", "pipe.rdp")
        os.makedirs(os.path.dirname(fifo))
        os.mkfifo(fifo)
        scan = self.scan(os.path.dirname(fifo))  # would block forever on open or read
        self.assertEqual(scan["entries"], [])
        self.assertIn("not an ordinary file", scan["errors"][0])

    def test_names_and_keys_cannot_add_ssh_options(self):
        # A synced name with line breaks once became a Host * block with a ProxyCommand in
        # ~/.ssh/omaremote.conf; a key path with a space would add arguments.
        text, count = session.ssh_managed_text([
            {"id": "c-1", "protocol": "ssh", "host": "git.lan", "sshKey": "~/.ssh/id",
             "name": "Git\nHost *\n    ProxyCommand touch /tmp/pwned"},
            {"id": "c-2", "protocol": "ssh", "host": "b.lan", "sshKey": "/x ProxyCommand evil", "name": "B"},
            {"id": "c-3", "protocol": "ssh", "host": "c.lan", "sshKey": "/x\nProxyCommand evil", "name": "C"}])
        self.assertEqual(count, 1)
        # What ssh reads: every line not a comment. The name stays, harmless, in its comment line.
        self.assertNotIn("ProxyCommand", "\n".join(l for l in text.split("\n") if not l.startswith("#")))
        self.assertEqual([l for l in text.split("\n") if l.startswith("Host")], ["Host git.lan"])

    def test_a_host_pattern_never_gets_a_key(self):
        # "Host *" would hand the key, its IdentitiesOnly and the user to every server.
        text, count = session.ssh_managed_text([
            {"id": "c-%d" % i, "protocol": "ssh", "host": h, "sshKey": "~/.ssh/id", "username": "me"}
            for i, h in enumerate(("*", "!a.lan", "a.lan,b.lan", "*.lan", "ok.lan"))])
        self.assertEqual(count, 1)
        self.assertEqual([l for l in text.split("\n") if l.startswith("Host")], ["Host ok.lan"])

    def test_the_ui_passes_sources_and_picks_outside_the_command_line(self):
        # File names are often server names (/proc/<pid>/cmdline is readable by other accounts).
        with open(os.path.join(HERE, "..", "ui", "Sync.qml"), encoding="utf-8") as f:
            qml = f.read()
        self.assertIn('command: [Sessions.bin, "import-scan"]\n', qml)
        self.assertIn('command: [Sessions.bin, "import-foreign"]\n', qml)
        self.assertNotIn(".concat(sources)", qml)
        self.assertNotIn(".concat(p.sources)", qml)


if __name__ == "__main__":
    unittest.main()
