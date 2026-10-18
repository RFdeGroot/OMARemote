import importlib.machinery
import json
import re
import importlib.util
import os
import sys
import time
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("session", os.path.join(HERE, "..", "bin", "omaremote-session"))
_spec = importlib.util.spec_from_loader("session", _loader)
session = importlib.util.module_from_spec(_spec)
_loader.exec_module(session)


def conn(**kw):
    return dict({"id": "c1", "name": "Work", "host": "pc.lan"}, **kw)


class BuildArgs(unittest.TestCase):
    def test_minimal_fit_follows_window(self):
        args = session.build_args(conn(), auto_scale=100)
        self.assertEqual(args[0], "/v:pc.lan")
        self.assertIn("+dynamic-resolution", args)
        self.assertNotIn("+smart-sizing", args)
        self.assertFalse(any(a.startswith("/scale") for a in args))

    def test_custom_port(self):
        self.assertEqual(session.build_args(conn(port=3390))[0], "/v:pc.lan:3390")

    def test_auto_scale_uses_monitor(self):
        args = session.build_args(conn(scale="auto"), auto_scale=160)
        self.assertIn("/scale-desktop:160", args)
        self.assertIn("/scale-device:140", args)

    def test_explicit_scale_wins_over_monitor(self):
        args = session.build_args(conn(scale="200"), auto_scale=160)
        self.assertIn("/scale-desktop:200", args)
        self.assertIn("/scale-device:180", args)

    def test_scale_is_clamped(self):
        self.assertIn("/scale-desktop:500", session.build_args(conn(scale="900")))
        self.assertFalse(any(a.startswith("/scale") for a in session.build_args(conn(scale="50"))))

    def test_fixed_uses_smart_sizing(self):
        args = session.build_args(conn(display="fixed", width=1280, height=720))
        self.assertIn("/size:1280x720", args)
        self.assertIn("+smart-sizing", args)
        self.assertNotIn("+dynamic-resolution", args)

    def test_fullscreen(self):
        args = session.build_args(conn(display="fullscreen"))
        self.assertIn("/f", args)
        self.assertIn("+dynamic-resolution", args)

    def test_credentials_and_password(self):
        args = session.build_args(conn(username="me", domain="CORP"), password="p w,d")
        self.assertIn("/u:me", args)
        self.assertIn("/d:CORP", args)
        self.assertIn("/p:p w,d", args)
        self.assertIn("/p:********", session.redact(args))
        self.assertNotIn("/p:p w,d", session.redact(args))

    def test_gateway_reuses_credentials_and_redacts(self):
        args = session.build_args(conn(username="me", gateway="gw.corp:443"), password="s3cret")
        gw = [a for a in args if a.startswith("/gateway:")][0]
        self.assertEqual(gw, "/gateway:g:gw.corp:443,u:me,p:s3cret")
        self.assertEqual([a for a in session.redact(args) if a.startswith("/gateway:")][0],
                         "/gateway:g:gw.corp:443,u:me,p:********")

    def test_gateway_own_credentials(self):
        c = conn(username="me", domain="CORP", gateway="gw.corp", gatewayUser="gwuser", gatewayDomain="GW")
        gw = lambda args: [a for a in args if a.startswith("/gateway:")][0]
        # Its own user and no password of its own: the connection's password is not the gateway's.
        self.assertEqual(gw(session.build_args(c, password="s3cret")), "/gateway:g:gw.corp,u:gwuser,d:GW")
        args = session.build_args(c, password="s3cret", gateway_password="gwpw")
        self.assertEqual(gw(args), "/gateway:g:gw.corp,u:gwuser,d:GW,p:gwpw")
        self.assertEqual(gw(session.redact(args)), "/gateway:g:gw.corp,u:gwuser,d:GW,p:********")
        # The gateway's own password wins over the connection's when both sign in as the same user.
        same = session.build_args(conn(username="me", gateway="gw.corp"), password="s3cret", gateway_password="gwpw")
        self.assertEqual(gw(same), "/gateway:g:gw.corp,u:me,p:gwpw")

    def test_gateway_passwords_freerdp_can_and_cannot_take(self):
        # FreeRDP splits /gateway: on commas, takes a double-quoted element whole, and refuses any
        # quote character inside (tried against FreeRDP 3.31).
        c = conn(gateway="gw.corp", gatewayUser="gu")
        gw = lambda pw: [a for a in session.build_args(c, gateway_password=pw) if a.startswith("/gateway:")][0]
        self.assertEqual(gw("plain"), "/gateway:g:gw.corp,u:gu,p:plain")
        self.assertEqual(gw("x,y"), '/gateway:g:gw.corp,u:gu,"p:x,y"')
        self.assertEqual(session.redact([gw("x,y")]), ["/gateway:g:gw.corp,u:gu,p:********"])
        # A quote, or a trailing backslash: left out, so FreeRDP asks for it when connecting.
        self.assertEqual(gw("it's"), "/gateway:g:gw.corp,u:gu")
        self.assertEqual(gw('say "hi"'), "/gateway:g:gw.corp,u:gu")
        self.assertEqual(gw("ends\\"), "/gateway:g:gw.corp,u:gu")
        # The connection's own password, reused by the gateway, gets the same care.
        same = session.build_args(conn(username="me", gateway="gw.corp"), password="a,b")
        self.assertIn('/gateway:g:gw.corp,u:me,"p:a,b"', same)

    def test_audio_and_redirection(self):
        args = session.build_args(conn(audio="off", clipboard=False, homeDrive=True, microphone=True))
        self.assertIn("/audio-mode:2", args)
        self.assertIn("-clipboard", args)
        self.assertIn("+home-drive", args)
        self.assertIn("/microphone", args)

    def test_extra_args_are_shell_split(self):
        args = session.build_args(conn(extraArgs="/kbd:layout:0x409 '/drive:Share Name,/tmp'"))
        self.assertEqual(args[-2:], ["/kbd:layout:0x409", "/drive:Share Name,/tmp"])

    def test_requires_host(self):
        with self.assertRaises(ValueError):
            session.build_args(conn(host=" "))


class Misc(unittest.TestCase):
    def test_device_scale_steps(self):
        self.assertEqual([session.device_scale(v) for v in (100, 119, 125, 150, 160, 175, 300)],
                         [100, 100, 140, 140, 140, 180, 180])

    def test_describe_exit(self):
        self.assertIsNone(session.describe_exit(0, ""))
        self.assertIsNone(session.describe_exit(-15, ""))
        self.assertIn("Authentication failed", session.describe_exit(132, ""))
        self.assertTrue(session.describe_exit(131, "x ERRCONNECT_CONNECT_FAILED y").endswith("(ERRCONNECT_CONNECT_FAILED)"))
        self.assertIn("RDP error 3", session.describe_exit(35, ""))


if __name__ == "__main__":
    unittest.main()


class OddFiles(unittest.TestCase):
    # A hand edit of another shape: the bar's list and a launch read it as empty, sync, export and
    # import refuse it whole (they write back what they read).
    SHAPES = ['5', 'null', '"x"', '{"connections": 5}', '{"groups": [1]}', '{"ui": [1]}', '{"quick": {}}']

    def test_readers_never_crash(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "connections.json")
            for text in self.SHAPES:
                with open(path, "w") as f:
                    f.write(text)
                self.assertEqual(session.load_connections(path), [], text)
                with self.assertRaises(ValueError, msg=text):
                    session.export_file(os.path.join(d, "out.json"), path)

    def test_an_odd_session_record_is_skipped(self):
        import tempfile
        saved = session.SESSIONS_DIR
        with tempfile.TemporaryDirectory() as d:
            session.SESSIONS_DIR = d
            try:
                with open(os.path.join(d, "s1.json"), "w") as f:
                    f.write("[1]")
                self.assertEqual(session.list_sessions(), [])
            finally:
                session.SESSIONS_DIR = saved


class RuntimeFallback(unittest.TestCase):
    # Without XDG_RUNTIME_DIR the runtime folder is in /tmp under a predictable name.
    def test_only_a_private_folder_of_ours_is_used(self):
        import shutil
        saved = session.APP
        session.APP = "omaremote-test-%d" % os.getpid()
        base = "/tmp/%s-%d" % (session.APP, os.getuid())
        try:
            self.assertEqual(session.private_tmp_base(), base)
            self.assertEqual(os.stat(base).st_mode & 0o777, 0o700)
            os.chmod(base, 0o755)
            with self.assertRaises(SystemExit):
                session.private_tmp_base()
            os.rmdir(base)
            os.symlink("/tmp", base)
            with self.assertRaises(SystemExit):
                session.private_tmp_base()
        finally:
            session.APP = saved
            if os.path.islink(base):
                os.unlink(base)
            shutil.rmtree(base, ignore_errors=True)


class QuickConnections(unittest.TestCase):
    # A host typed in the search field: started like a saved connection, but this system's only.
    def data(self):
        return {"connections": [conn()],
                "quick": [{"id": "q-1", "protocol": "ssh", "name": "srv.lan", "host": "srv.lan", "port": 22,
                           "username": "alex", "credential": "custom", "used": 1}]}

    def test_a_session_finds_it(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "connections.json")
            with open(path, "w") as f:
                json.dump(self.data(), f)
            found = {c["id"]: c for c in session.load_connections(path)}
            self.assertEqual(found["q-1"]["host"], "srv.lan")
            self.assertEqual(found["q-1"]["protocol"], "ssh")
            self.assertIn("c1", found)
            with open(path) as f:
                before = f.read()
            stamps = os.path.join(d, "last-connected.json")
            session.mark_connected("q-1", stamps)
            # The UI is the only writer of connections.json; the stamp goes into a file of its own.
            with open(path) as f:
                self.assertEqual(f.read(), before)
            with open(stamps) as f:
                self.assertGreater(json.load(f)["q-1"], 0)

    def test_stamps_survive_a_broken_file_and_odd_entries(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            stamps = os.path.join(d, "last-connected.json")
            with open(stamps, "w") as f:
                f.write('{"c1": 5, "../x": 1, "c2": "soon"')
            session.mark_connected("c3", stamps)
            with open(stamps) as f:
                self.assertEqual(list(json.load(f)), ["c3"])
            session.mark_connected("c1", stamps)
            with open(stamps) as f:
                self.assertEqual(sorted(json.load(f)), ["c1", "c3"])

    def test_it_never_syncs_or_exports(self):
        for kind in ("sync", "export"):
            doc = session.portable(self.data(), "laptop", kind)
            self.assertEqual([c["id"] for c in doc["connections"]], ["c1"])
            self.assertNotIn("quick", doc)
            self.assertNotIn("srv.lan", json.dumps(doc))

    def test_a_sync_keeps_it(self):
        merged, _ = session.merge(self.data(), [session.portable({"connections": [conn(id="c2", host="b.lan")]}, "pc")])
        self.assertEqual([q["id"] for q in merged["quick"]], ["q-1"])
        self.assertNotIn("q-1", [c["id"] for c in merged["connections"]])


class Kerberos(unittest.TestCase):
    def test_realm_from_dotted_domain(self):
        self.assertEqual(session.kerberos_realm({"domain": "acme.lan", "host": "x"}), "ACME.LAN")

    def test_realm_from_host_suffix_when_domain_is_short(self):
        self.assertEqual(session.kerberos_realm({"domain": "acme", "host": "pc.acme.lan"}), "ACME.LAN")

    def test_no_realm_for_ip_or_bare_host(self):
        self.assertIsNone(session.kerberos_realm({"host": "10.0.0.5"}))
        self.assertIsNone(session.kerberos_realm({"host": "pc"}))

    def test_config_pins_realm_to_tcp_kdcs(self):
        text = session.krb5_config("ACME.LAN", ["dc1.acme.lan:88", "dc2.acme.lan:88"], "pc.acme.lan")
        self.assertIn("udp_preference_limit = 1", text)
        self.assertIn("kdc = dc1.acme.lan:88", text)
        self.assertIn(".acme.lan = ACME.LAN", text)

    def test_env_uses_manual_kdcs_and_keeps_system_config(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            env = session.kerberos_env({"domain": "acme.lan", "host": "pc.acme.lan", "kdc": "dc9:88"},
                                       runtime_dir=d, discover=lambda realm: self.fail("should not discover"))
            path, rest = env["KRB5_CONFIG"].split(":", 1)
            self.assertTrue(rest.endswith("krb5.conf"))
            with open(path) as f:
                self.assertIn("kdc = dc9:88", f.read())

    def test_env_refuses_a_realm_that_is_not_a_plain_name(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            env = session.kerberos_env({"domain": "../../x.lan", "host": "pc", "kdc": "dc9:88"}, runtime_dir=d)
            self.assertEqual(env, {})
            self.assertEqual(os.listdir(d), [])

    def test_env_empty_without_kdcs(self):
        self.assertEqual(session.kerberos_env({"domain": "acme.lan", "host": "pc"}, discover=lambda r: []), {})

    def test_stage_markers(self):
        self.assertEqual(session.session_stage("x [credssp_auth_init]: Using package"), ("Signing in", None))
        self.assertEqual(session.session_stage("Negotiated mechanism: Kerberos (1.2.840)"), ("Signing in", "Kerberos"))
        self.assertEqual(session.session_stage("nothing"), (None, None))


class TabMode(unittest.TestCase):
    def test_tab_starts_at_tab_size_and_scale(self):
        args = session.build_args(conn(), tab={"width": 2561, "height": 1500, "scale": 160}, auto_scale=125)
        self.assertIn("/size:2560x1500", args)
        self.assertIn("+dynamic-resolution", args)
        self.assertIn("/scale-desktop:160", args)
        self.assertFalse(any(a.startswith("/t:") for a in args))

    def test_tab_drops_window_only_options(self):
        args = session.build_args(conn(display="fullscreen", multimon=True), tab={"width": 800, "height": 600, "scale": 100})
        self.assertNotIn("/f", args)
        self.assertNotIn("/multimon", args)

    def test_tab_fixed_keeps_its_resolution(self):
        args = session.build_args(conn(display="fixed", width=1280, height=720), tab={"width": 800, "height": 600, "scale": 100})
        self.assertIn("/size:1280x720", args)
        self.assertNotIn("+dynamic-resolution", args)

    def test_explicit_scale_beats_tab_scale(self):
        args = session.build_args(conn(scale="200"), tab={"width": 800, "height": 600, "scale": 160})
        self.assertIn("/scale-desktop:200", args)

    def test_parse_tab(self):
        self.assertEqual(session.parse_tab("2560x1500@160"), {"width": 2560, "height": 1500, "scale": 160})
        with self.assertRaises(ValueError):
            session.parse_tab("big")


class Rename(unittest.TestCase):
    def test_legacy_folders_move_once(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            cfg, cache = os.path.join(d, "config"), os.path.join(d, "cache")
            os.makedirs(os.path.join(cfg, "oma-remote"))
            with open(os.path.join(cfg, "oma-remote", "connections.json"), "w") as f:
                f.write("{}")
            os.makedirs(os.path.join(cache, "omaremote"))  # already new: left alone
            os.makedirs(os.path.join(cache, "oma-remote"))
            saved = session.CONFIG_DIR, session.CACHE_DIR
            session.CONFIG_DIR, session.CACHE_DIR = os.path.join(cfg, "omaremote"), os.path.join(cache, "omaremote")
            try:
                session.migrate_legacy()
            finally:
                session.CONFIG_DIR, session.CACHE_DIR = saved
            self.assertTrue(os.path.exists(os.path.join(cfg, "omaremote", "connections.json")))
            self.assertFalse(os.path.exists(os.path.join(cfg, "oma-remote")))
            self.assertTrue(os.path.exists(os.path.join(cache, "oma-remote")))


class Inheritance(unittest.TestCase):
    data = {
        "credentials": [{"id": "k1", "username": "admin", "domain": "corp", "savePassword": True}],
        "groups": {"Servers": {"credential": "k1", "settings": {"scale": "125", "audio": "off"}}},
        "connections": [],
    }

    def test_group_settings_fill_in_and_own_values_win(self):
        c = session.resolve({"id": "c", "host": "h", "group": "Servers", "audio": "local"}, self.data)
        self.assertEqual(c["scale"], "125")
        self.assertEqual(c["audio"], "local")
        self.assertEqual(c["display"], "fit")  # neither: the default

    def test_inherited_credentials_come_from_the_group_set(self):
        c = session.resolve({"id": "c", "host": "h", "group": "Servers", "credential": "inherit"}, self.data)
        self.assertEqual((c["username"], c["domain"], c["savePassword"]), ("admin", "corp", True))
        self.assertEqual((c["secretKind"], c["secretId"], c["credentialSource"]), ("credential", "k1", "group"))

    def test_inherit_without_group_credentials_means_none(self):
        c = session.resolve({"id": "c", "host": "h", "group": "Other", "credential": "inherit", "username": "x"}, self.data)
        self.assertEqual(c["username"], "")
        self.assertIsNone(c["secretId"])

    def test_explicit_set_and_custom(self):
        c = session.resolve({"id": "c", "host": "h", "credential": "k1"}, self.data)
        self.assertEqual((c["username"], c["credentialSource"]), ("admin", "set"))
        c = session.resolve({"id": "c", "host": "h", "username": "me", "savePassword": True}, self.data)
        self.assertEqual((c["username"], c["secretKind"], c["secretId"]), ("me", "connection", "c"))

    def test_args_use_resolved_credentials(self):
        c = session.resolve({"id": "c", "host": "h", "group": "Servers", "credential": "inherit"}, self.data)
        args = session.build_args(c, password="pw")
        self.assertIn("/u:admin", args)
        self.assertIn("/d:corp", args)
        self.assertIn("/audio-mode:2", args)


class ShortDomain(unittest.TestCase):
    def test_netbios_name_becomes_the_hosts_dns_domain(self):
        self.assertEqual(session.kerberos_domain({"domain": "acme", "host": "pc.acme.lan"}), "acme.lan")
        self.assertEqual(session.kerberos_domain({"domain": "ACME", "host": "pc.acme.lan"}), "acme.lan")

    def test_other_domains_are_left_alone(self):
        self.assertEqual(session.kerberos_domain({"domain": "corp", "host": "pc.acme.lan"}), "corp")
        self.assertEqual(session.kerberos_domain({"domain": "acme.lan", "host": "pc.acme.lan"}), "acme.lan")
        self.assertEqual(session.kerberos_domain({"domain": "acme", "host": "10.0.0.5"}), "acme")
        self.assertEqual(session.kerberos_domain({"domain": "", "host": "pc.acme.lan"}), "")


class Vnc(unittest.TestCase):
    def test_config_lines(self):
        lines = session.build_vnc_config(conn(protocol="vnc", host="nas.lan", username="me", viewOnly=True,
                                              vncScaling="resize", vncQuality="low"), password="pw")
        self.assertEqual(lines[:5], ["host=nas.lan", "port=5900", "scaling=resize", "quality=low", "viewOnly=1"])
        self.assertIn("username=me", lines)
        self.assertIn("password=pw", lines)
        self.assertIn("password=********", session.redact(lines))

    def test_clipboard_switch_reaches_the_session(self):
        self.assertIn("clipboard=1", session.build_vnc_config(conn(protocol="vnc")))
        self.assertIn("clipboard=0", session.build_vnc_config(conn(protocol="vnc", clipboard=False)))

    def test_explicit_port_and_safe_defaults(self):
        lines = session.build_vnc_config(conn(protocol="vnc", port=5901, vncScaling="weird"))
        self.assertIn("port=5901", lines)
        self.assertIn("scaling=fit", lines)
        self.assertFalse(any(l.startswith("password=") for l in lines))

    def test_vnc_client_is_found_by_protocol(self):
        self.assertTrue(session.tab_client("vnc").endswith("omaremote-vnc"))
        self.assertTrue(session.tab_client("rdp").endswith("omaremote-rdp"))

    def test_port_defaults_follow_the_protocol(self):
        data = {"credentials": [], "groups": {}, "connections": []}
        self.assertEqual(session.resolve({"id": "v", "host": "h", "protocol": "vnc"}, data)["port"], 5900)
        self.assertEqual(session.resolve({"id": "r", "host": "h"}, data)["port"], 3389)
        self.assertEqual(session.resolve({"id": "v", "host": "h", "protocol": "vnc", "port": 5901}, data)["port"], 5901)


class Updates(unittest.TestCase):
    def test_versions_numbers_then_prerelease(self):
        cmp = session.compare_versions
        self.assertEqual(cmp("0.1.4-alpha", "0.1.4-alpha"), 0)
        self.assertEqual(cmp("v0.1.5-alpha", "0.1.4-alpha"), 1)
        self.assertEqual(cmp("0.1.10-alpha", "0.1.9-alpha"), 1)
        self.assertEqual(cmp("0.1.4-alpha", "0.1.4-beta"), -1)
        self.assertEqual(cmp("0.1.4", "0.1.4-alpha"), 1)
        self.assertEqual(cmp("0.2", "0.1.9"), 1)

    def test_newest_release_with_this_machines_package(self):
        base = "https://github.com/RFdeGroot/OMARemote/releases/download/"
        releases = [
            {"tag_name": "v0.2.0-alpha", "draft": True,
             "assets": [{"name": "omaremote-0.2.0alpha-1-x86_64.pkg.tar.zst", "browser_download_url": base + "draft"}]},
            {"tag_name": "v0.1.5-alpha",
             "assets": [{"name": "omaremote-0.1.5alpha-1-aarch64.pkg.tar.zst", "browser_download_url": base + "arm"}]},
            {"tag_name": "v0.1.4-alpha",
             "assets": [{"name": "PKGBUILD", "browser_download_url": base + "pkgbuild"},
                        {"name": "omaremote-debug-0.1.4alpha-1-x86_64.pkg.tar.zst", "browser_download_url": base + "debug"},
                        {"name": "omaremote-0.1.4alpha-1-x86_64.pkg.tar.zst", "browser_download_url": base + "x86"}]},
        ]
        self.assertEqual(session.newest_release(releases, "x86_64"), ("0.1.4-alpha", base + "x86"))
        self.assertEqual(session.newest_release(releases, "aarch64"), ("0.1.5-alpha", base + "arm"))
        self.assertEqual(session.newest_release([], "x86_64"), (None, None))


class Ssh(unittest.TestCase):
    def ssh(self, **kw):
        return conn(protocol="ssh", **kw)

    def test_plain_host_leaves_the_rest_to_ssh_config(self):
        self.assertEqual(session.build_ssh_command(self.ssh(port=22)), ["ssh", "pc.lan"])

    def test_port_user_and_options(self):
        cmd = session.build_ssh_command(self.ssh(port=2222, username="admin", sshArgs="-J jump.lan -A"))
        self.assertEqual(cmd, ["ssh", "-p", "2222", "-l", "admin", "-J", "jump.lan", "-A", "pc.lan"])

    def test_freerdp_arguments_never_reach_ssh(self):
        self.assertEqual(session.build_ssh_command(self.ssh(extraArgs="/kbd:layout:0x409")), ["ssh", "pc.lan"])

    def test_a_host_that_looks_like_an_option_is_refused(self):
        with self.assertRaises(ValueError):
            session.build_ssh_command(self.ssh(host="-oProxyCommand=evil"))

    def test_config_lines(self):
        lines = session.build_ssh_config(self.ssh())
        self.assertEqual(lines[:2], ["arg=ssh", "arg=pc.lan"])
        self.assertIn("font=monospace", lines)
        self.assertTrue(any(l.startswith("theme=") and l.endswith("foot.ini") for l in lines))
        # OSC 52 (a program on the server setting the clipboard) follows the Clipboard switch.
        self.assertIn("clipboard=1", lines)
        self.assertIn("clipboard=0", session.build_ssh_config(self.ssh(clipboard=False)))

    def test_shell_exit_codes_are_not_failures(self):
        self.assertIsNone(session.describe_exit(0, "", "ssh"))
        self.assertIsNone(session.describe_exit(1, "", "ssh"))
        self.assertIsNone(session.describe_exit(130, "", "ssh"))

    def test_ssh_failure_says_why(self):
        tail = "[omaremote] connected to pc.lan\n[omaremote] connection failed: ssh: connect to host pc.lan port 22: Connection refused\n"
        self.assertEqual(session.describe_exit(255, tail, "ssh"), "ssh: connect to host pc.lan port 22: Connection refused")
        self.assertEqual(session.describe_exit(255, "", "ssh"), "Could not connect to the server")

    def test_font_size_from_the_terminal_config(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "foot.ini")
            with open(path, "w") as f:
                f.write("[main]\nfont=JetBrainsMono Nerd Font:size=11\n")
            saved = dict(session.FONT_SIZE_RES)
            try:
                session.FONT_SIZE_RES.clear()
                session.FONT_SIZE_RES["foot"] = (path, saved["foot"][1])
                self.assertEqual(session.terminal_font_size("foot"), 11.0)
                session.FONT_SIZE_RES["foot"] = (os.path.join(d, "missing"), saved["foot"][1])
                self.assertEqual(session.terminal_font_size("foot"), 9.0)
            finally:
                session.FONT_SIZE_RES.clear()
                session.FONT_SIZE_RES.update(saved)


class SshKeys(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.ssh = os.path.join(self.tmp.name, ".ssh")
        os.makedirs(self.ssh)
        self.conf = os.path.join(self.tmp.name, "connections.json")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.ssh, name), "w") as f:
            f.write(text)

    def read(self, name):
        with open(os.path.join(self.ssh, name)) as f:
            return f.read()

    def connections(self, *conns, terminal=True):
        with open(self.conf, "w") as f:
            json.dump({"ui": {"sshTerminalKeys": terminal}, "connections": list(conns)}, f)

    def test_lists_private_keys_and_agent_keys(self):
        self.write("id_work", "-----BEGIN OPENSSH PRIVATE KEY-----\nxx\n")
        self.write("id_work.pub", "ssh-ed25519 AAAA alice@work\n")
        self.write("onepassword.pub", "ssh-rsa AAAA from 1Password\n")
        self.write("known_hosts", "host ssh-ed25519 AAAA\n")
        self.write("notes.pub", "not a key\n")
        keys = {k["name"]: k for k in session.ssh_keys(self.ssh)}
        self.assertEqual(sorted(keys), ["id_work", "onepassword.pub"])
        self.assertEqual((keys["id_work"]["kind"], keys["id_work"]["type"], keys["id_work"]["comment"]),
                         ("file", "ed25519", "alice@work"))
        self.assertEqual(keys["onepassword.pub"]["kind"], "agent")

    def test_the_key_goes_along_when_ssh_starts(self):
        cmd = session.build_ssh_command(conn(protocol="ssh", sshKey="/k/id_work"))
        self.assertEqual(cmd, ["ssh", "-i", "/k/id_work", "-o", "IdentitiesOnly=yes", "pc.lan"])

    def test_the_key_never_syncs(self):
        self.assertNotIn("sshKey", session.portable_connection(conn(sshKey="~/.ssh/id_work")))

    def test_a_symlinked_ssh_config_is_written_through_not_replaced(self):
        dots = os.path.join(self.tmp.name, "dotfiles")
        os.makedirs(dots)
        with open(os.path.join(dots, "ssh_config"), "w") as f:
            f.write("Host mine\n    User me\n")
        os.symlink(os.path.join(dots, "ssh_config"), os.path.join(self.ssh, "config"))
        self.connections(conn(id="c1", host="web.lan", protocol="ssh", sshKey="~/.ssh/id_work"))
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh)["mode"], "auto")
        self.assertTrue(os.path.islink(os.path.join(self.ssh, "config")))
        with open(os.path.join(dots, "ssh_config")) as f:
            self.assertTrue(f.read().startswith(session.SSH_MARKER))
        self.connections(conn(id="c1", host="web.lan", protocol="ssh", sshKey="~/.ssh/id_work"), terminal=False)
        session.ssh_config_sync(self.conf, self.ssh)
        self.assertTrue(os.path.islink(os.path.join(self.ssh, "config")))
        with open(os.path.join(dots, "ssh_config")) as f:
            self.assertEqual(f.read(), "Host mine\n    User me\n")

    def test_the_marker_is_found_with_trailing_space_or_crlf(self):
        # ssh_config_sync tested for the marker as a substring, then looked it up as an exact line:
        # an editor's trailing space or CRLF raised ValueError.
        for end in (" ", "\r"):
            self.write("config", session.SSH_MARKER + end + "\n" + session.SSH_INCLUDE + end + "\n\nHost mine\n")
            self.connections(conn(id="c1", host="web.lan", protocol="ssh", sshKey="~/.ssh/id_work"), terminal=False)
            session.ssh_config_sync(self.conf, self.ssh)
            with open(os.path.join(self.ssh, "config")) as f:
                self.assertEqual(f.read(), "Host mine\n", repr(end))

    def test_a_read_only_ssh_config_is_left_to_its_owner(self):
        self.write("config", "Host mine\n")
        os.chmod(os.path.join(self.ssh, "config"), 0o444)
        self.connections(conn(id="c1", host="web.lan", protocol="ssh", sshKey="~/.ssh/id_work"))
        out = session.ssh_config_sync(self.conf, self.ssh)
        self.assertEqual(out["mode"], "readonly")
        self.assertEqual(self.read("config"), "Host mine\n")
        self.assertIn("web.lan", self.read("omaremote.conf"))

    def test_managed_file_and_one_include_at_the_top(self):
        self.write("config", "Host mine\n    User me\n")
        self.connections(conn(id="c1", name="web", host="web.lan", protocol="ssh", port=2222, username="admin",
                              credential="custom", sshKey="~/.ssh/id_work"),
                         conn(id="c2", host="rdp.lan", sshKey="~/.ssh/ignored"))
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh), {"mode": "auto", "keys": 1, "changed": True})
        managed = self.read("omaremote.conf")
        self.assertIn("Host web.lan\n    IdentityFile ~/.ssh/id_work\n    IdentitiesOnly yes\n    User admin\n    Port 2222\n", managed)
        self.assertNotIn("rdp.lan", managed)
        config = self.read("config")
        self.assertTrue(config.splitlines()[1] == "Include omaremote.conf")
        self.assertTrue(config.endswith("Host mine\n    User me\n"))
        self.assertEqual(self.read("config.omaremote-backup"), "Host mine\n    User me\n")
        # Again: nothing to change, and never a second Include.
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh), {"mode": "auto", "keys": 1, "changed": False})
        self.assertEqual(self.read("config").count("Include omaremote.conf"), 1)

    def test_removing_the_key_empties_the_managed_file_but_leaves_config_alone(self):
        self.write("config", "Include omaremote.conf\nHost mine\n")
        self.connections(conn(id="c1", host="web.lan", protocol="ssh", sshKey="~/.ssh/id_work"))
        session.ssh_config_sync(self.conf, self.ssh)
        self.connections(conn(id="c1", host="web.lan", protocol="ssh"))
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh)["keys"], 0)
        self.assertNotIn("web.lan", self.read("omaremote.conf"))
        self.assertEqual(self.read("config"), "Include omaremote.conf\nHost mine\n")
        self.assertFalse(os.path.exists(os.path.join(self.ssh, "config.omaremote-backup")))

    def keyed(self, terminal):
        self.connections(conn(id="c1", host="web.lan", protocol="ssh", sshKey="~/.ssh/id_work"), terminal=terminal)

    def test_off_by_default_nothing_in_ssh_is_touched(self):
        self.write("config", "Host mine\n")
        with open(self.conf, "w") as f:
            json.dump({"connections": [conn(protocol="ssh", sshKey="~/.ssh/id_work")]}, f)
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh)["mode"], "off")
        self.assertEqual(sorted(os.listdir(self.ssh)), ["config"])
        self.assertEqual(self.read("config"), "Host mine\n")

    def test_turning_it_off_takes_out_exactly_what_was_added(self):
        original = "# my own comment\nHost mine\n    User me\n"
        self.write("config", original)
        self.keyed(True)
        session.ssh_config_sync(self.conf, self.ssh)
        self.keyed(False)
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh)["mode"], "off")
        self.assertEqual(self.read("config"), original)
        self.assertFalse(os.path.exists(os.path.join(self.ssh, "omaremote.conf")))

    def test_an_include_added_by_hand_is_left_alone_and_served(self):
        self.write("config", "Host mine\n\nInclude ~/.ssh/omaremote.conf\n")
        self.keyed(False)
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh)["mode"], "manual")
        self.assertIn("Host web.lan", self.read("omaremote.conf"))
        self.assertEqual(self.read("config"), "Host mine\n\nInclude ~/.ssh/omaremote.conf\n")
        self.keyed(True)  # on as well: still no second Include
        session.ssh_config_sync(self.conf, self.ssh)
        self.assertEqual(self.read("config").lower().count("include"), 1)

    def test_nothing_is_written_while_no_connection_has_a_key(self):
        self.connections(conn(protocol="ssh"))
        self.assertEqual(session.ssh_config_sync(self.conf, self.ssh), {"mode": "auto", "keys": 0, "changed": False})
        self.assertEqual(os.listdir(self.ssh), [])


class Sync(unittest.TestCase):
    NOW = 1_800_000_000_000

    def local(self, *conns, **extra):
        return dict({"connections": list(conns), "groups": {}, "trash": [], "deleted": {}}, **extra)

    def remote(self, *conns, deleted=None, groups=None, system="laptop"):
        return {"format": "omaremote-sync", "version": 1, "system": system, "written": self.NOW,
                "connections": list(conns), "groups": groups or {}, "deleted": deleted or {}}

    def c(self, cid="c1", host="pc.lan", modified=100, **kw):
        return dict({"id": cid, "name": cid, "host": host, "protocol": "rdp", "port": 3389, "modified": modified}, **kw)

    def test_nothing_local_travels(self):
        data = self.local(self.c(username="alice", domain="ACME", credential="k1", savePassword=True,
                                 gatewayUser="gw", gatewayDomain="ACME", extraArgs="/u:alice", sshArgs="-l alice",
                                 lastConnected=5, favourite=True),
                          groups={"Servers": {"credential": "k1", "settings": {"gatewayUser": "gw", "audio": "off"}}})
        out = json.dumps(session.portable(data, "here"))
        for secret in ("alice", "ACME", "k1", "savePassword", "gw", "/u:", "-l ", "lastConnected"):
            self.assertNotIn(secret, out)
        self.assertIn('"favourite": true', out)
        self.assertIn('"audio": "off"', out)

    def test_a_gliff_server_path_never_travels(self):
        """The program ssh runs on the remote is chosen here, like sshArgs: a sync or import file
        never sets it (security review 0.9.0)."""
        data = self.local(self.c(protocol="gliff", gliffServer="~/bin/gliff-server"))
        self.assertNotIn("gliffServer", json.dumps(session.portable(data, "here")))
        evil = self.c(protocol="gliff", modified=200, gliffServer="/tmp/planted")
        merged, _ = session.merge(self.local(self.c(protocol="gliff", gliffServer="~/bin/gliff-server")),
                                  [self.remote(evil)], self.NOW)
        self.assertEqual(merged["connections"][0].get("gliffServer"), "~/bin/gliff-server")
        added, _ = session.merge(self.local(), [self.remote(evil)], self.NOW)
        self.assertNotEqual(added["connections"][0].get("gliffServer"), "/tmp/planted")

    def test_adds_unknown_connections_without_credentials(self):
        data, report = session.merge(self.local(), [self.remote(self.c())], self.NOW)
        self.assertEqual(report["added"], ["c1"])
        self.assertEqual(data["connections"][0]["credential"], "custom")

    def test_an_added_connection_never_takes_its_groups_credentials(self):
        """omarchy-plugin-marketplace#11837: a sync writer could add one for any host to a group
        with a set, and the set's password would go there; the user picks the set here."""
        local = self.local(groups={"Servers": {"credential": "k1", "settings": {}}})
        data, _ = session.merge(local, [self.remote(self.c(group="Servers"))], self.NOW)
        self.assertEqual(data["connections"][0]["credential"], "custom")

    def test_an_added_ssh_connection_never_takes_a_credential_set(self):
        local = self.local(groups={"Servers": {"credential": "k1", "settings": {}}})
        data, _ = session.merge(local, [self.remote(self.c(group="Servers", protocol="ssh", port=22))], self.NOW)
        self.assertEqual(data["connections"][0]["credential"], "custom")

    def test_newer_change_wins_and_local_fields_stay(self):
        local = self.local(self.c(name="old", modified=100, username="alice", credential="custom"))
        data, report = session.merge(local, [self.remote(self.c(name="new", modified=200))], self.NOW)
        self.assertEqual(report["updated"], ["new"])
        self.assertEqual(data["connections"][0]["username"], "alice")
        data, report = session.merge(local, [self.remote(self.c(name="older", modified=50))], self.NOW)
        self.assertEqual(data["connections"][0]["name"], "old")
        self.assertEqual(report["updated"], [])

    def test_same_server_with_another_id_is_one_connection(self):
        local = self.local(self.c("mine", host="PC.lan", modified=100))
        data, report = session.merge(local, [self.remote(self.c("theirs", modified=200))], self.NOW)
        self.assertEqual([c["id"] for c in data["connections"]], ["mine"])
        self.assertEqual(report["updated"], ["theirs"])

    def test_a_duplicate_arrives_as_a_connection_of_its_own(self):
        # Duplicated on the other system: same host and port, another id, both in its file.
        local = self.local(self.c("orig", name="Server", modified=100))
        incoming = self.remote(self.c("orig", name="Server", modified=100),
                               self.c("copy", name="Server (copy)", modified=200))
        data, report = session.merge(local, [incoming], self.NOW)
        self.assertEqual(sorted(c["id"] for c in data["connections"]), ["copy", "orig"])
        self.assertEqual(next(c for c in data["connections"] if c["id"] == "orig")["name"], "Server")
        self.assertFalse(any(c.get("aliases") for c in data["connections"]))
        self.assertEqual(report["added"], ["Server (copy)"])

    def test_a_duplicate_taken_for_its_original_is_split_again(self):
        # What 0.4.3 left on the other system: the copy's data on the original, its id as an alias.
        local = self.local(self.c("orig", name="Server (copy)", modified=200, aliases=["copy"]))
        incoming = self.remote(self.c("orig", name="Server", modified=300),
                               self.c("copy", name="Server (copy)", modified=200))
        data, _ = session.merge(local, [incoming], self.NOW)
        by_id = {c["id"]: c for c in data["connections"]}
        self.assertEqual(sorted(by_id), ["copy", "orig"])
        self.assertNotIn("aliases", by_id["orig"])
        self.assertEqual(by_id["orig"]["name"], "Server")

    def test_an_alias_naming_a_connection_here_is_dropped(self):
        # And on the system where the copy was made: both there, one recorded as the other's alias.
        local = self.local(self.c("orig", modified=200, aliases=["copy"]), self.c("copy", modified=200))
        incoming = self.remote(self.c("orig", name="from there", modified=150, aliases=["copy"]))
        data, report = session.merge(local, [incoming], self.NOW)
        by_id = {c["id"]: c for c in data["connections"]}
        self.assertNotIn("aliases", by_id["orig"])
        self.assertEqual(by_id["copy"]["name"], "copy")  # never overwritten by the original
        self.assertEqual(report["updated"], [])

    def test_with_two_copies_here_a_new_id_for_that_server_is_not_guessed(self):
        local = self.local(self.c("a", modified=100), self.c("b", modified=100))
        data, report = session.merge(local, [self.remote(self.c("z", name="new", modified=300))], self.NOW)
        self.assertEqual(sorted(c["id"] for c in data["connections"]), ["a", "b", "z"])
        self.assertEqual(report["added"], ["new"])

    def test_a_server_known_by_another_id_follows_its_deletion(self):
        local = self.local(self.c("mine", modified=100))
        data, _ = session.merge(local, [self.remote(self.c("theirs", modified=50))], self.NOW)
        self.assertEqual(data["connections"][0]["aliases"], ["theirs"])
        data, report = session.merge(data, [self.remote(deleted={"theirs": 300})], self.NOW)
        self.assertEqual(report["trashed"], ["mine"])

    def test_deletion_goes_to_the_trash_never_out(self):
        local = self.local(self.c(modified=100, username="alice"))
        data, report = session.merge(local, [self.remote(deleted={"c1": 300})], self.NOW)
        self.assertEqual(data["connections"], [])
        self.assertEqual(data["trash"][0]["connection"]["username"], "alice")
        self.assertEqual(data["trash"][0]["from"], "laptop")
        self.assertEqual(report["trashed"], ["c1"])

    def test_a_later_local_change_survives_an_older_deletion(self):
        local = self.local(self.c(modified=500))
        data, _ = session.merge(local, [self.remote(deleted={"c1": 300})], self.NOW)
        self.assertEqual(len(data["connections"]), 1)

    def test_deleted_here_is_not_brought_back_by_an_older_copy(self):
        local = self.local(trash=[{"connection": self.c(modified=100), "deleted": 300, "from": "local"}],
                           deleted={"c1": 300})
        data, report = session.merge(local, [self.remote(self.c(modified=100))], self.NOW)
        self.assertEqual(data["connections"], [])
        self.assertEqual(report["added"] + report["restored"], [])

    def test_a_newer_change_restores_from_the_trash_with_local_fields(self):
        local = self.local(trash=[{"connection": self.c(modified=100, username="alice"), "deleted": 300, "from": "local"}],
                           deleted={"c1": 300})
        data, report = session.merge(local, [self.remote(self.c(name="back", modified=400))], self.NOW)
        self.assertEqual(report["restored"], ["back"])
        self.assertEqual(data["connections"][0]["username"], "alice")
        self.assertEqual(data["trash"], [])
        self.assertNotIn("c1", data["deleted"])

    def test_many_deletions_at_once_wait_for_the_user(self):
        conns = [self.c(f"c{i}", host=f"pc{i}.lan") for i in range(6)]
        doomed = {f"c{i}": 300 for i in range(4)}
        data, report = session.merge(self.local(*conns), [self.remote(deleted=doomed)], self.NOW)
        self.assertEqual(len(data["connections"]), 6)
        self.assertEqual(report["pendingDeletions"][0]["system"], "laptop")
        self.assertEqual(len(report["pendingDeletions"][0]["ids"]), 4)
        data, report = session.merge(self.local(*conns), [self.remote(deleted=doomed)], self.NOW,
                                     allow_deletions=("laptop",))
        self.assertEqual(len(data["connections"]), 2)

    def test_groups_merge_but_keep_their_local_credentials(self):
        local = self.local(groups={"Servers": {"credential": "k1", "settings": {"gatewayUser": "gw"}, "modified": 1}})
        incoming = self.remote(groups={"Servers": {"settings": {"audio": "off"}, "modified": 9}})
        data, _ = session.merge(local, [incoming], self.NOW)
        self.assertEqual(data["groups"]["Servers"],
                         {"credential": "k1", "settings": {"audio": "off", "gatewayUser": "gw"}, "modified": 9})

    def test_a_group_deleted_elsewhere_goes_here_too(self):
        local = self.local(groups={"Lab": {"credential": "k1", "settings": {"audio": "off"}, "modified": 100}})
        incoming = dict(self.remote(), deletedGroups={"Lab": 300})
        data, _ = session.merge(local, [incoming], self.NOW)
        self.assertNotIn("Lab", data["groups"])
        self.assertEqual(data["deletedGroups"], {"Lab": 300})
        self.assertIn("deletedGroups", session.portable(data, "here"))

    def test_a_group_changed_here_after_its_deletion_stays(self):
        local = self.local(groups={"Lab": {"credential": "", "settings": {}, "modified": 500}})
        data, _ = session.merge(local, [dict(self.remote(), deletedGroups={"Lab": 300})], self.NOW)
        self.assertIn("Lab", data["groups"])

    def test_a_deleted_group_is_not_brought_back_by_an_older_copy(self):
        local = self.local(deletedGroups={"Lab": 300})
        incoming = self.remote(groups={"Lab": {"settings": {}, "modified": 200}})
        data, _ = session.merge(local, [incoming], self.NOW)
        self.assertNotIn("Lab", data["groups"])
        incoming = self.remote(groups={"Lab": {"settings": {}, "modified": 400}})
        data, _ = session.merge(local, [incoming], self.NOW)
        self.assertIn("Lab", data["groups"])

    def test_a_rename_elsewhere_arrives_as_the_new_group_with_its_connections(self):
        local = self.local(self.c(group="Lab", modified=100),
                           groups={"Lab": {"credential": "", "settings": {"audio": "off"}, "modified": 100}})
        incoming = dict(self.remote(self.c(group="Test", modified=300),
                                    groups={"Test": {"settings": {"audio": "off"}, "modified": 300}}),
                        deletedGroups={"Lab": 300})
        data, _ = session.merge(local, [incoming], self.NOW)
        self.assertEqual(list(data["groups"]), ["Test"])
        self.assertEqual(data["connections"][0]["group"], "Test")

    def test_group_deletions_are_forgotten_with_the_trash(self):
        old = self.NOW - 31 * session.DAY_MS
        data = self.local(deletedGroups={"Old": old, "New": self.NOW})
        session.purge_trash(data, self.NOW)
        self.assertEqual(data["deletedGroups"], {"New": self.NOW})

    def test_a_manual_export_carries_no_group_deletions(self):
        data = self.local(deletedGroups={"Lab": 300})
        self.assertEqual(session.portable(data, "here", "export")["deletedGroups"], {})

    def test_old_files_without_change_times_load(self):
        data, report = session.merge(self.local({"id": "c1", "host": "pc.lan"}),
                                     [self.remote(self.c(name="new", modified=200))], self.NOW)
        self.assertEqual(report["updated"], ["new"])

    def test_trash_is_emptied_after_thirty_days(self):
        old = self.NOW - 31 * session.DAY_MS
        data = self.local(trash=[{"connection": self.c("old"), "deleted": old},
                                 {"connection": self.c("new"), "deleted": self.NOW}],
                          deleted={"old": old, "new": self.NOW})
        self.assertEqual(session.purge_trash(data, self.NOW), ["old"])
        self.assertEqual([t["connection"]["id"] for t in data["trash"]], ["new"])
        self.assertEqual(list(data["deleted"]), ["new"])

    def test_a_manual_import_never_removes(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            conf = os.path.join(d, "connections.json")
            with open(conf, "w") as f:
                json.dump(self.local(self.c(modified=100)), f)
            export = os.path.join(d, "export.json")
            with open(export, "w") as f:
                json.dump(dict(self.remote(self.c("c2", host="other.lan"), deleted={"c1": 999}),
                               format="omaremote-export"), f)
            out = session.import_file(export, conf, self.NOW)
            self.assertEqual(sorted(c["id"] for c in out["data"]["connections"]), ["c1", "c2"])
            with open(export) as f:
                again = session.merge(out["data"], [json.load(f)], self.NOW)[1]
            self.assertEqual(again["added"], [])

    def test_folder_sync_writes_its_own_file_only_when_it_changed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            folder = os.path.join(d, "Nextcloud")
            os.makedirs(folder)
            conf = os.path.join(d, "connections.json")
            with open(conf, "w") as f:
                json.dump(dict(self.local(self.c(username="alice")),
                               ui={"sync": {"folder": folder, "system": "here"}}), f)
            with open(os.path.join(folder, "laptop.omaremote.json"), "w") as f:
                json.dump(self.remote(self.c("c2", host="other.lan")), f)
            out = session.sync_folder(conf, self.NOW)
            own = os.path.join(folder, "here.omaremote.json")
            with open(own) as f:
                self.assertNotIn("alice", f.read())
            self.assertEqual(out["report"]["added"], ["c2"])
            before = os.stat(own).st_mtime_ns
            session.sync_folder(conf, self.NOW + 5000)
            self.assertEqual(os.stat(own).st_mtime_ns, before)

    def test_the_folder_watch_reports_arrived_files_only(self):
        import io, tempfile, threading
        with tempfile.TemporaryDirectory() as d:
            out, done = io.StringIO(), threading.Event()
            t = threading.Thread(target=session.watch_folder, args=(d, out, 0.05, done.is_set))
            t.start()
            time.sleep(0.3)
            session.write_json_atomic(os.path.join(d, "macbook.omaremote.json"), {"a": 1})  # tmp file, then rename
            with open(os.path.join(d, "notes.txt"), "w") as f:
                f.write("not ours")
            time.sleep(0.3)
            done.set()
            t.join(3)
            self.assertEqual(out.getvalue().split(), ["macbook.omaremote.json"])

    def sync_setup(self, d):
        folder = os.path.join(d, "sync")
        os.makedirs(folder)
        conf = os.path.join(d, "connections.json")
        with open(conf, "w") as f:
            json.dump({"connections": [], "ui": {"sync": {"folder": folder, "system": "here"}}}, f)
        return folder, conf

    def test_others_files_are_ordinary_small_files_or_skipped(self):
        # Whoever writes the sync folder: a FIFO would block the round forever, a symlink to
        # /dev/zero or a huge file would eat the memory.
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            folder, conf = self.sync_setup(d)
            os.mkfifo(os.path.join(folder, "fifo.omaremote.json"))
            os.symlink("/dev/zero", os.path.join(folder, "zero.omaremote.json"))
            with open(os.path.join(folder, "big.omaremote.json"), "w") as f:
                f.write('{"pad": "' + "x" * (session.SYNC_MAX_BYTES + 1) + '"}')
            with open(os.path.join(folder, "laptop.omaremote.json"), "w") as f:
                json.dump(self.remote(self.c("c2", host="other.lan")), f)
            out = session.sync_folder(conf, self.NOW)
            self.assertEqual(out["report"]["added"], ["c2"])
            errors = " ".join(out["report"]["errors"])
            for name in ("fifo", "zero", "big"):
                self.assertIn(name + ".omaremote.json", errors)

    def test_a_planted_symlink_never_redirects_our_write(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            folder, conf = self.sync_setup(d)
            victim = os.path.join(d, "victim.txt")
            with open(victim, "w") as f:
                f.write("mine\n")
            os.symlink(victim, os.path.join(folder, ".here.omaremote.json.tmp"))
            os.symlink(victim, os.path.join(folder, "here.omaremote.json"))
            session.sync_folder(conf, self.NOW)
            with open(victim) as f:
                self.assertEqual(f.read(), "mine\n")
            own = os.path.join(folder, "here.omaremote.json")
            self.assertFalse(os.path.islink(own))
            self.assertEqual(session.read_json_file(own)["format"], "omaremote-sync")

    def test_a_missing_sync_folder_is_an_error_not_a_new_folder(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            conf = os.path.join(d, "connections.json")
            with open(conf, "w") as f:
                json.dump({"ui": {"sync": {"folder": os.path.join(d, "not-mounted")}}}, f)
            with self.assertRaises(ValueError):
                session.sync_folder(conf, self.NOW)
            self.assertFalse(os.path.exists(os.path.join(d, "not-mounted")))


class Views(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.saved = (session.RUNTIME_DIR, session.SESSIONS_DIR, session.CHANGES)
        session.RUNTIME_DIR = self.dir
        session.SESSIONS_DIR = os.path.join(self.dir, "sessions")
        session.CHANGES = os.path.join(self.dir, "changes")

    def tearDown(self):
        import shutil
        session.RUNTIME_DIR, session.SESSIONS_DIR, session.CHANGES = self.saved
        shutil.rmtree(self.dir)

    def record(self, **kw):
        state = dict({"id": "s1", "connection": "c1", "state": "connected", "tab": True,
                      "supervisor": os.getpid(), "view": "tab", "viewer": None, "started": 1}, **kw)
        session.write_session(state)
        return state

    def listed(self):
        return {s["id"]: s for s in session.list_sessions()}["s1"]

    def test_the_supervisor_and_the_window_never_undo_each_other(self):
        # Both rewrite sessions/s1.json, from separate processes, at the same moment: the record
        # stays whole, the supervisor's state and the window's view both survive.
        import multiprocessing as mp
        ctx = mp.get_context("fork")
        for trial in range(40):
            self.record(state="connecting", view="tab")
            sup = ctx.Process(target=lambda: [session.write_session({"id": "s1", "state": "connected", "n": i})
                                              for i in range(3)])
            win = ctx.Process(target=lambda: [session.set_view("s1", "window", 4242) for _ in range(3)])
            win.start()
            sup.start()
            sup.join(10)
            win.join(10)
            self.assertEqual((sup.exitcode, win.exitcode), (0, 0))
            with open(os.path.join(session.SESSIONS_DIR, "s1.json")) as f:
                rec = json.load(f)
            self.assertEqual((rec["state"], rec["view"], rec["viewer"]), ("connected", "window", 4242))
        self.assertEqual(sorted(os.listdir(session.SESSIONS_DIR)), [".lock", "s1.json"])

    def test_supervisor_rewrite_keeps_the_window_view(self):
        state = self.record()
        self.assertTrue(session.set_view("s1", "window", os.getpid()))
        state["state"] = "connected"   # the supervisor's copy still says view "tab"
        session.write_session(state)
        self.assertEqual((self.listed()["view"], self.listed()["viewer"]), ("window", os.getpid()))

    def test_a_closed_window_hands_its_session_back_to_the_tabs(self):
        self.record()
        session.set_view("s1", "window", 2 ** 22 + 12345)   # no such process
        self.assertEqual(self.listed()["view"], "tab")

    def test_freerdp_window_sessions_stay_windows(self):
        self.record(tab=False, view="window")
        self.assertEqual(self.listed()["view"], "window")

    def test_old_records_get_a_view(self):
        state = self.record()
        del state["view"], state["viewer"]
        with open(session._session_path("s1"), "w") as f:
            json.dump(state, f)
        self.assertEqual(self.listed()["view"], "tab")

    def test_unknown_session(self):
        self.assertFalse(session.set_view("nope", "tab"))


class FloatSize(unittest.TestCase):
    def test_ninety_percent_in_logical_pixels(self):
        self.assertEqual(session.float_size({"width": 2560, "height": 1600, "scale": 1.0}, 90), (2304, 1440))
        self.assertEqual(session.float_size({"width": 3840, "height": 2160, "scale": 2.0}, 90), (1728, 972))

    def test_rotated_monitor(self):
        self.assertEqual(session.float_size({"width": 1920, "height": 1080, "scale": 1, "transform": 1}, 50), (540, 960))

    def test_unknown_monitor_falls_back(self):
        self.assertEqual(session.float_size({}, 90), (1728, 972))


class PluginCheck(unittest.TestCase):
    def test_newest_tag_skips_drafts(self):
        self.assertEqual(session.newest_tag([{"tag_name": "v0.4.0", "draft": True}, {"tag_name": "v0.3.0"}]), "0.3.0")
        self.assertEqual(session.newest_tag([]), "")

    def test_not_installed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as plugins:
            result = session.plugin_check(offline=True, plugins_dir=plugins)
        self.assertEqual((result["installed"], result["version"], result["newer"]), (False, "", False))

    def test_installed_version_from_its_manifest(self):
        import tempfile
        with tempfile.TemporaryDirectory() as plugins:
            folder = os.path.join(plugins, session.PLUGIN_ID)
            os.makedirs(os.path.join(folder, ".git"))
            with open(os.path.join(folder, "manifest.json"), "w") as f:
                json.dump({"id": session.PLUGIN_ID, "version": "0.2.0"}, f)
            result = session.plugin_check(offline=True, plugins_dir=plugins)
        self.assertEqual((result["installed"], result["version"], result["git"]), (True, "0.2.0", True))


class Hotkeys(unittest.TestCase):
    def window(self, ws="special:omaremote-c1", address="0x1"):
        return {"address": address, "pid": 42, "workspace": {"name": ws}}

    def monitors(self, special="", focused=True):
        return [{"name": "eDP-1", "focused": focused, "specialWorkspace": {"name": special}},
                {"name": "DP-1", "focused": not focused, "specialWorkspace": {"name": ""}}]

    def test_a_hotkey_window_is_rdp_or_ssh_on_one_monitor(self):
        self.assertTrue(session.is_hotkey({"openIn": "hotkey", "protocol": "ssh"}))
        self.assertTrue(session.is_hotkey({"openIn": "hotkey", "protocol": "rdp"}))
        self.assertFalse(session.is_hotkey({"openIn": "hotkey", "protocol": "vnc"}))
        self.assertFalse(session.is_hotkey({"openIn": "hotkey", "protocol": "rdp", "multimon": True}))
        self.assertFalse(session.is_hotkey({"openIn": "window", "protocol": "rdp"}))

    def test_special_names_are_safe(self):
        self.assertEqual(session.special_name("c-abc12"), "omaremote-c-abc12")
        self.assertEqual(session.special_name("a b/c"), "omaremote-a-b-c")

    def test_toggle_hides_a_focused_shown_window_and_shows_otherwise(self):
        w = self.window()
        shown = self.monitors("special:omaremote-c1")
        self.assertEqual(session.hotkey_action(w, "omaremote-c1", {"address": "0x1"}, shown), "hide")
        self.assertEqual(session.hotkey_action(w, "omaremote-c1", {"address": "0x1"}, shown, show_only=True), "show")
        self.assertEqual(session.hotkey_action(w, "omaremote-c1", {"address": "0x2"}, shown), "show")
        self.assertEqual(session.hotkey_action(w, "omaremote-c1", {"address": "0x1"}, self.monitors()), "show")
        # Shown on the other monitor: comes to this one, not hidden.
        other = self.monitors("special:omaremote-c1", focused=False)
        self.assertEqual(session.hotkey_action(w, "omaremote-c1", {"address": "0x1"}, other), "show")

    def test_a_window_on_a_normal_workspace_moves_to_its_special_one(self):
        self.assertEqual(session.hotkey_action(self.window(ws="4"), "omaremote-c1", {}, self.monitors()), "move")

    def test_shortcuts_parse_like_hyprland(self):
        self.assertEqual(session.parse_hotkey("SUPER + ALT + W"), (72, "W"))
        self.assertEqual(session.parse_hotkey("super+shift+return"), (65, "RETURN"))
        self.assertIsNone(session.parse_hotkey("SUPER + ALT"))
        self.assertIsNone(session.parse_hotkey("HYPER + W"))
        self.assertIsNone(session.parse_hotkey(""))

    def test_hyprland_binds_leave_out_omaremotes_own(self):
        binds = [{"modmask": 64, "key": "S", "description": "Toggle scratchpad"},
                 {"modmask": 72, "key": "w", "description": "OMARemote: Work PC"},
                 {"modmask": 0, "key": "mouse:272", "mouse": True}]
        self.assertEqual(session.hypr_hotkeys(binds), [{"mask": 64, "key": "S", "description": "Toggle scratchpad"}])

    def test_listed_sessions_say_whether_they_are_hotkey_windows(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            for sid, cid in (("s1", "hk"), ("s2", "plain"), ("s3", "vnc")):
                with open(os.path.join(d, sid + ".json"), "w") as f:
                    json.dump({"id": sid, "connection": cid, "state": "ended", "tab": True, "started": 1}, f)
            conns = [{"id": "hk", "openIn": "hotkey", "protocol": "rdp"},
                     {"id": "plain", "openIn": "window", "protocol": "rdp"},
                     {"id": "vnc", "openIn": "hotkey", "protocol": "vnc"}]
            with mock.patch.object(session, "SESSIONS_DIR", d), \
                 mock.patch.object(session, "load_connections", lambda *a: conns):
                flags = {s["id"]: s["hotkey"] for s in session.list_sessions()}
        self.assertEqual(flags, {"s1": True, "s2": False, "s3": False})

    def test_the_close_key_is_whatever_closes_a_window(self):
        self.assertEqual(session.close_key([{"modmask": 64, "key": "W", "description": "Close window"}]), "super+w")
        self.assertEqual(session.close_key([{"modmask": 64, "key": "W", "description": "Something else"},
                                            {"modmask": 65, "key": "Q", "description": "Close window"}]), "super+shift+q")
        self.assertEqual(session.close_key([{"modmask": 72, "key": "C", "dispatcher": "killactive"}]), "super+alt+c")
        self.assertEqual(session.close_key([]), "super+w")

    def test_the_shortcut_never_syncs(self):
        data = {"connections": [{"id": "c1", "host": "pc", "openIn": "hotkey", "hotkey": "SUPER + ALT + W"}]}
        out = session.portable(data, "here")
        self.assertNotIn("hotkey\"", json.dumps(out).replace('"openIn": "hotkey"', ""))
        self.assertEqual(out["connections"][0]["openIn"], "hotkey")

    def write_config(self, d, ui, conns):
        conf = os.path.join(d, "connections.json")
        with open(conf, "w") as f:
            json.dump({"ui": ui, "connections": conns}, f)
        return conf

    def test_hyprland_config_gets_the_bindings_only_when_allowed_and_loses_them_again(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            hypr = os.path.join(d, "hypr")
            os.makedirs(hypr)
            main = os.path.join(hypr, "hyprland.lua")
            original = '-- mine\nrequire("default.hypr.omarchy")\n'
            with open(main, "w") as f:
                f.write(original)
            conns = [{"id": "c1", "name": "Work \"PC\"", "host": "pc", "protocol": "rdp", "openIn": "hotkey",
                      "hotkey": "super + alt + w"},
                     {"id": "c2", "name": "Tab one", "host": "t", "protocol": "rdp", "hotkey": "SUPER + T"}]
            conf = self.write_config(d, {}, conns)
            out = session.hypr_hotkeys_sync(conf, hypr, "/usr/bin/omaremote", reload=False)
            self.assertEqual(out, {"mode": "off", "shortcuts": 1, "changed": False})
            with open(main) as f:
                self.assertEqual(f.read(), original)

            conf = self.write_config(d, {"hyprHotkeys": True}, conns)
            out = session.hypr_hotkeys_sync(conf, hypr, "/usr/bin/omaremote", reload=False)
            self.assertEqual(out["mode"], "on")
            with open(os.path.join(hypr, "omaremote.lua")) as f:
                managed = f.read()
            self.assertIn('o.bind("SUPER + ALT + W", "OMARemote: hotkey window", "/usr/bin/omaremote toggle c1")', managed)
            self.assertNotIn("Work", managed)
            self.assertNotIn("Tab one", managed)
            with open(main) as f:
                text = f.read()
            self.assertTrue(text.startswith(original))
            self.assertEqual(text.count(session.HYPR_MARKER_BEGIN), 1)
            self.assertTrue(os.path.exists(main + ".omaremote-backup"))
            # Again: nothing changes, the block is not added twice.
            self.assertFalse(session.hypr_hotkeys_sync(conf, hypr, "/usr/bin/omaremote", reload=False)["changed"])

            conf = self.write_config(d, {"hyprHotkeys": False}, conns)
            session.hypr_hotkeys_sync(conf, hypr, "/usr/bin/omaremote", reload=False)
            with open(main) as f:
                self.assertEqual(f.read(), original)
            self.assertFalse(os.path.exists(os.path.join(hypr, "omaremote.lua")))

    def sync_config(self, original, on):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d)
        hypr = os.path.join(d, "hypr")
        os.makedirs(hypr)
        main = os.path.join(hypr, "hyprland.lua")
        with open(main, "w") as f:
            f.write(original)
        conf = self.write_config(d, {"hyprHotkeys": on}, [])
        out = session.hypr_hotkeys_sync(conf, hypr, "omaremote", reload=False)
        with open(main) as f:
            return out, f.read(), hypr, d

    def test_on_then_off_gives_back_the_file_exactly(self):
        for original in ('-- mine\nrequire("x")\n', "-- mine\n\n\n", "", "-- mine\n\n-- after\n"):
            out, added, hypr, d = self.sync_config(original, True)
            self.assertTrue(added.startswith(original), repr(original))
            conf = self.write_config(d, {"hyprHotkeys": False}, [])
            session.hypr_hotkeys_sync(conf, hypr, "omaremote", reload=False)
            with open(os.path.join(hypr, "hyprland.lua")) as f:
                self.assertEqual(f.read(), original)

    def test_the_users_own_blank_lines_and_text_around_the_block_stay(self):
        block = session.HYPR_MARKER_BEGIN + "\ndofile(x)\n" + session.HYPR_MARKER_END
        original = "-- top\n\n\n" + block + "\n\n\n-- below, the user's own\n"
        out, text, _, _ = self.sync_config(original, False)
        self.assertTrue(out["changed"])
        self.assertEqual(text, "-- top\n\n\n\n-- below, the user's own\n")

    def test_a_start_without_its_end_leaves_the_file_alone(self):
        original = "-- mine\n" + session.HYPR_MARKER_BEGIN + "\ndofile(x)\n-- the user removed the end\nrequire(\"y\")\n"
        for on in (False, True):
            out, text, _, _ = self.sync_config(original, on)
            self.assertEqual(text, original)
            self.assertIn("end marker", out["error"])

    def test_a_marker_inside_a_comment_is_not_the_block(self):
        original = "-- I once had " + session.HYPR_MARKER_BEGIN + " here\nrequire(\"y\")\n"
        out, text, _, _ = self.sync_config(original, False)
        self.assertEqual(text, original)
        self.assertFalse(out["changed"])
        out, text, _, _ = self.sync_config(original, True)
        self.assertEqual(text.count(session.HYPR_MARKER_END), 1)
        self.assertTrue(text.startswith(original))

    def test_a_symlinked_hyprland_lua_is_written_through_not_replaced(self):
        # Dotfile managers link the config to a file they own (after hyprmoncfg's WriteFileAtomic).
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d)
        hypr, dots = os.path.join(d, "hypr"), os.path.join(d, "dotfiles")
        os.makedirs(hypr)
        os.makedirs(dots)
        with open(os.path.join(dots, "hyprland.lua"), "w") as f:
            f.write("-- mine\n")
        os.symlink(os.path.join(dots, "hyprland.lua"), os.path.join(hypr, "hyprland.lua"))
        for on in (True, False):
            conf = self.write_config(d, {"hyprHotkeys": on}, [])
            session.hypr_hotkeys_sync(conf, hypr, "omaremote", reload=False)
            self.assertTrue(os.path.islink(os.path.join(hypr, "hyprland.lua")))
            with open(os.path.join(dots, "hyprland.lua")) as f:
                self.assertEqual(session.HYPR_MARKER_BEGIN in f.read(), on)
        self.assertEqual([n for n in os.listdir(dots) + os.listdir(hypr) if "omaremote-" in n and not n.endswith("backup")], [])

    def test_a_read_only_hyprland_lua_is_left_to_its_owner(self):
        import tempfile, stat as st
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d)
        hypr = os.path.join(d, "hypr")
        os.makedirs(hypr)
        main = os.path.join(hypr, "hyprland.lua")
        with open(main, "w") as f:
            f.write("-- generated\n")
        os.chmod(main, 0o444)
        conn = {"id": "c1", "name": "W", "host": "pc", "protocol": "rdp", "openIn": "hotkey", "hotkey": "SUPER + W"}
        conf = self.write_config(d, {"hyprHotkeys": True}, [conn])
        out = session.hypr_hotkeys_sync(conf, hypr, "omaremote", reload=False)
        self.assertEqual(out["mode"], "readonly")
        self.assertIn("dofile(path)", out["line"])
        with open(main) as f:
            self.assertEqual(f.read(), "-- generated\n")
        self.assertTrue(os.path.exists(os.path.join(hypr, "omaremote.lua")))  # its own file is still kept
        self.assertFalse(os.path.exists(main + ".omaremote-backup"))

    def hypr_with(self, before, after):
        """hypr_hotkeys_sync with a stand-in Hyprland: configerrors says `before`, then `after`."""
        from unittest import mock
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d)
        hypr = os.path.join(d, "hypr")
        os.makedirs(hypr)
        with open(os.path.join(hypr, "hyprland.lua"), "w") as f:
            f.write("-- mine\n")
        conn = {"id": "c1", "name": "W", "host": "pc", "protocol": "rdp", "openIn": "hotkey", "hotkey": "SUPER + W"}
        conf = self.write_config(d, {"hyprHotkeys": True}, [conn])
        answers = iter([before, after])
        with mock.patch.object(session, "hypr_config_errors", lambda: next(answers)), \
             mock.patch.object(session, "hypr_reload", lambda: True):
            out = session.hypr_hotkeys_sync(conf, hypr, "omaremote", reload=True)
        with open(os.path.join(hypr, "hyprland.lua")) as f:
            return out, f.read(), hypr

    def test_nothing_is_written_while_hyprland_already_reports_errors(self):
        out, text, hypr = self.hypr_with(["line 3: oops"], [])
        self.assertIn("already reports", out["error"])
        self.assertEqual(text, "-- mine\n")
        self.assertFalse(os.path.exists(os.path.join(hypr, "omaremote.lua")))

    def test_a_change_hyprland_rejects_is_taken_out_again(self):
        out, text, hypr = self.hypr_with([], ["omaremote.lua:4: unexpected symbol"])
        self.assertTrue(out["revert"])
        self.assertEqual(text, "-- mine\n")
        self.assertFalse(os.path.exists(os.path.join(hypr, "omaremote.lua")))

    def test_a_clean_reload_keeps_the_change(self):
        out, text, hypr = self.hypr_with([], [])
        self.assertNotIn("error", out)
        self.assertIn(session.HYPR_MARKER_BEGIN, text)

    def test_the_loader_follows_xdg_config_home_when_it_is_set(self):
        from unittest import mock
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/elsewhere"}):
            self.assertIn('os.getenv("XDG_CONFIG_HOME")', session.hypr_loader_line())
        env = {k: v for k, v in os.environ.items() if k != "XDG_CONFIG_HOME"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertIn('os.getenv("HOME") .. "/.config/hypr/omaremote.lua"', session.hypr_loader_line())

    def test_without_a_lua_config_nothing_is_written(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            conf = self.write_config(d, {"hyprHotkeys": True}, [])
            out = session.hypr_hotkeys_sync(conf, os.path.join(d, "hypr"), "omaremote", reload=False)
            self.assertEqual(out["mode"], "unsupported")
            self.assertFalse(os.path.exists(os.path.join(d, "hypr")))


class NothingPrivateInArgv(unittest.TestCase):
    """Other accounts can read any process's command line (/proc/<pid>/cmdline): names, hosts, user
    names and error texts must never go on one (omarchy-plugin-marketplace#11163)."""

    PRIVATE = ("Secret Office PC", "pc.secret.lan", "alice", "SECRET.LAN")

    def setUp(self):
        self.argvs = []
        real_run, real_popen = session.subprocess.run, session.subprocess.Popen

        def run(args, *a, **k):
            self.argvs.append(list(args))
            return session.subprocess.CompletedProcess(args, 0, "", "")
        session.subprocess.run = run
        session.subprocess.Popen = lambda args, *a, **k: self.argvs.append(list(args)) or self.fail("Popen")
        self.addCleanup(setattr, session.subprocess, "run", real_run)
        self.addCleanup(setattr, session.subprocess, "Popen", real_popen)

    def assertClean(self):
        text = json.dumps(self.argvs)
        for word in self.PRIVATE:
            self.assertNotIn(word, text)

    def test_a_failure_notification_names_nothing_on_a_command_line(self):
        # No session bus here: the fallback path. (With a bus the same text goes over D-Bus; a test
        # must not put notifications on the desktop.)
        from unittest import mock
        with mock.patch.dict(os.environ, {"DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent"}):
            session.notify()
        self.assertEqual(self.argvs[0][0], "notify-send")
        self.assertClean()

    def test_the_notification_text_itself_names_nothing(self):
        # Whatever shows the notification may put its text on a command line (Omarchy's does).
        self.assertEqual((session.NOTIFY_SUMMARY, session.NOTIFY_BODY),
                         ("OMARemote", "A connection failed: open OMARemote for details"))
        import inspect
        self.assertEqual(list(inspect.signature(session.notify).parameters), [])

    def test_keyring_labels_carry_only_the_id(self):
        session.secret_set("c-1", "hunter2", session.secret_label("c-1"))
        session.secret_set("k-1", "hunter2", session.secret_label("k-1", "credential"), "credential")
        self.assertTrue(self.argvs)
        self.assertClean()
        self.assertNotIn("hunter2", json.dumps(self.argvs))

    def test_kerberos_lookup_runs_in_process(self):
        session.srv_records("_kerberos._tcp.SECRET.LAN")
        self.assertEqual(self.argvs, [])

    def test_hotkey_bindings_name_connections_by_id(self):
        text, _ = session.hypr_managed_text([{"id": "c-1", "name": "Secret Office PC", "host": "pc.secret.lan",
                                              "protocol": "rdp", "openIn": "hotkey", "hotkey": "SUPER + W"}],
                                            "omaremote")
        command = re.search(r'"(omaremote toggle [^"]*)"', text).group(1)
        self.assertEqual(command, "omaremote toggle c-1")


class NoInjection(unittest.TestCase):
    """Hosts, names and gateways arrive from other systems through sync. The clients read their
    settings one per line, so a line break (or a comma inside /gateway:) would add settings of
    its own: FreeRDP's /drive: could share the whole disk with the server."""

    def test_a_line_break_in_the_host_never_reaches_freerdp(self):
        with self.assertRaises(ValueError):
            session.build_args(conn(host="pc.lan\n/drive:all,/"))
        with self.assertRaises(ValueError):
            session.build_vnc_config(conn(protocol="vnc", host="pc.lan\npassword=x"))
        with self.assertRaises(ValueError):
            session.build_ssh_config(conn(protocol="ssh", host="pc.lan\narg=-oProxyCommand=sh"))

    def test_a_gateway_cannot_add_gateway_options(self):
        with self.assertRaises(ValueError):
            session.build_args(conn(gateway="gw.lan,p:stolen"))
        self.assertIn("/gateway:g:gw.lan:443", session.build_args(conn(gateway="gw.lan:443")))

    def test_a_name_with_a_line_break_becomes_one_title(self):
        args = session.build_args(conn(name="Office\n/drive:all,/"))
        titles = [a for a in args if a.startswith("/t:")]
        self.assertEqual(len(titles), 1)
        self.assertNotIn("\n", titles[0])
        self.assertFalse(any(a.startswith("/drive:") for a in args))

    def test_ordinary_hosts_still_pass(self):
        for host in ("pc.acme.lan", "10.0.0.5", "[fe80::1%eth0]", "alice@server", "srv_01"):
            session.check_host(host)

    def test_sync_takes_in_no_connection_with_an_odd_id_or_host(self):
        remote = {"format": "omaremote-sync", "version": 1, "system": "laptop", "written": 1,
                  "connections": [{"id": "c-1; rm -rf ~", "host": "pc.lan", "modified": 5},
                                  {"id": "c-2", "host": "pc.lan\n/drive:x,/", "modified": 5},
                                  {"id": "c-3", "host": "ok.lan", "modified": 5}],
                  "groups": {}, "deleted": {}}
        data, report = session.merge({"connections": [], "groups": {}, "trash": [], "deleted": {}}, [remote], 10)
        self.assertEqual([c["id"] for c in data["connections"]], ["c-3"])
        self.assertTrue(any("invalid id or host" in e for e in report["errors"]))

    def test_an_id_never_starts_with_a_dash(self):
        # Ids go on command lines (omaremote open <id>, qs ipc … open <id>): "--help" would be an option.
        for bad in ("--help", "-n", "--window"):
            self.assertIsNone(session.ID_RE.match(bad))
        self.assertTrue(session.ID_RE.match("c-abc123xyz"))
        remote = {"format": "omaremote-sync", "version": 1, "system": "laptop", "written": 1,
                  "connections": [{"id": "--window", "host": "pc.lan", "modified": 5},
                                  {"id": "c-4", "host": "pc4.lan", "modified": 5, "aliases": ["-x"]}],
                  "groups": {}, "deleted": {}}
        data, _ = session.merge({"connections": [], "groups": {}, "trash": [], "deleted": {}}, [remote], 10)
        self.assertEqual(data["connections"], [])

    def test_the_hotkey_command_quotes_what_it_runs(self):
        text, _ = session.hypr_managed_text([{"id": "c-1", "host": "pc", "protocol": "rdp", "openIn": "hotkey",
                                              "hotkey": "SUPER + W"}], "/opt/my apps/omaremote")
        self.assertIn("'/opt/my apps/omaremote' toggle c-1", text)

    def test_a_non_ascii_home_reaches_lua_as_written(self):
        # JSON's \\u00e9 is no escape Lua knows: the binding pointed nowhere.
        text, _ = session.hypr_managed_text([{"id": "c-1", "host": "pc", "protocol": "rdp", "openIn": "hotkey",
                                              "hotkey": "SUPER + W"}], "/home/josé/.local/bin/omaremote")
        self.assertIn("'/home/josé/.local/bin/omaremote' toggle c-1", text)
        self.assertNotIn("\\u", text)


class AddressGuard(unittest.TestCase):
    """A synced change to where a connection points waits for the user when this system signs in
    there with saved credentials: they would go to the new address."""

    def remote(self, *conns, groups=None):
        return {"format": "omaremote-sync", "version": 1, "system": "laptop", "written": 1,
                "connections": list(conns), "groups": groups or {}, "deleted": {}}

    def local(self, *conns, groups=None):
        return {"connections": list(conns), "groups": groups or {}, "trash": [], "deleted": {}}

    def c(self, **kw):
        return dict({"id": "c1", "name": "Files", "host": "files.lan", "protocol": "rdp", "port": 3389, "modified": 100}, **kw)

    def test_a_new_host_for_a_connection_with_a_saved_password_waits(self):
        local = self.local(self.c(savePassword=True, username="alice"))
        data, report = session.merge(local, [self.remote(self.c(host="evil.example", modified=200))], 1000)
        self.assertEqual(data["connections"][0]["host"], "files.lan")
        self.assertEqual(report["pendingAddress"][0]["id"], "c1")
        self.assertEqual((report["pendingAddress"][0]["from"], report["pendingAddress"][0]["to"]),
                         ("files.lan", "evil.example"))
        data, report = session.merge(local, [self.remote(self.c(host="evil.example", modified=200))], 1000,
                                     allow_address=("c1",))
        self.assertEqual(data["connections"][0]["host"], "evil.example")
        self.assertEqual(report["pendingAddress"], [])

    def test_a_gateway_or_kdc_counts_as_an_address_too(self):
        local = self.local(self.c(credential="k1"))
        for change in ({"gateway": "gw.example"}, {"kdc": "kdc.example"}, {"port": 3390}):
            _, report = session.merge(local, [self.remote(self.c(modified=200, **change))], 1000)
            self.assertEqual(len(report["pendingAddress"]), 1, change)

    def test_a_saved_gateway_password_waits_too(self):
        local = self.local(self.c(credential="custom", gateway="gw.lan", gatewaySavePassword=True))
        for change in ({"gateway": "gw.example"}, {"host": "new.lan"}):
            data, report = session.merge(local, [self.remote(self.c(modified=200, **dict({"gateway": "gw.lan"}, **change)))], 1000)
            self.assertEqual(len(report["pendingAddress"]), 1, change)
            self.assertEqual(data["connections"][0]["gateway"], "gw.lan")

    def test_without_credentials_here_the_change_just_arrives(self):
        local = self.local(self.c(credential="custom", savePassword=False))
        data, report = session.merge(local, [self.remote(self.c(host="new.lan", modified=200))], 1000)
        self.assertEqual(data["connections"][0]["host"], "new.lan")
        self.assertEqual(report["pendingAddress"], [])

    def test_switching_on_sharing_waits_like_an_address(self):
        local = self.local(self.c(savePassword=True))
        for change in ({"homeDrive": True}, {"microphone": True}):
            data, report = session.merge(local, [self.remote(self.c(modified=200, **change))], 1000)
            self.assertEqual(len(report["pendingAddress"]), 1, change)
            self.assertFalse(data["connections"][0].get(next(iter(change))), change)
            self.assertIn(", ", report["pendingAddress"][0]["to"])
        # Switching it off again, or any other setting, just arrives.
        local = self.local(self.c(savePassword=True, homeDrive=True))
        data, report = session.merge(local, [self.remote(self.c(modified=200, homeDrive=False, clipboard=False))], 1000)
        self.assertEqual(report["pendingAddress"], [])
        self.assertFalse(data["connections"][0]["homeDrive"])

    def test_a_groups_sharing_waits_when_it_signs_in_here(self):
        local = self.local(groups={"Servers": {"credential": "k1", "settings": {}, "modified": 1}})
        incoming = self.remote(groups={"Servers": {"settings": {"homeDrive": True}, "modified": 9}})
        data, report = session.merge(local, [incoming], 1000)
        self.assertNotIn("homeDrive", data["groups"]["Servers"]["settings"])
        self.assertEqual(report["pendingAddress"][0]["id"], "group:Servers")

    def test_a_move_into_a_new_group_with_sharing_waits(self):
        """omarchy-plugin-marketplace#11776: a new group with homeDrive (or a gateway, a KDC) and a
        connection that signs in here moved into it; the move changes only `group`."""
        for setting in ({"homeDrive": True}, {"microphone": True}, {"gateway": "gw.example"}, {"kdc": "kdc.example"}):
            local = self.local(self.c(savePassword=True))
            incoming = self.remote(self.c(group="Evil", modified=200),
                                   groups={"Evil": {"settings": setting, "modified": 9}})
            data, report = session.merge(local, [incoming], 1000)
            self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"], setting)
            self.assertNotEqual(data["connections"][0].get("group"), "Evil", setting)
            data, report = session.merge(local, [incoming], 1000, allow_address=("c1",))
            self.assertEqual(data["connections"][0]["group"], "Evil", setting)

    def test_a_move_into_a_group_that_just_gained_sharing_waits(self):
        """The group itself signs in nowhere, so its new setting arrives; the member moved into it
        signs in here, so the move waits."""
        local = self.local(self.c(savePassword=True),
                           groups={"Lab": {"credential": "", "settings": {}, "modified": 1}})
        incoming = self.remote(self.c(group="Lab", modified=200),
                               groups={"Lab": {"settings": {"homeDrive": True, "gateway": "gw.example"}, "modified": 9}})
        data, report = session.merge(local, [incoming], 1000)
        self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"])
        self.assertIn("home folder", report["pendingAddress"][0]["to"])
        self.assertIsNone(data["connections"][0].get("group"))

    def test_a_new_group_a_member_here_already_names_waits(self):
        local = self.local(self.c(group="Gone", savePassword=True))
        incoming = self.remote(groups={"Gone": {"settings": {"homeDrive": True}, "modified": 9}})
        data, report = session.merge(local, [incoming], 1000)
        self.assertEqual(report["pendingAddress"][0]["id"], "group:Gone")
        self.assertNotIn("Gone", data["groups"])

    def binned(self, conn):
        return dict(self.local(), trash=[{"connection": conn, "deleted": 150, "from": "local"}],
                    deleted={conn["id"]: 150})

    def test_a_restore_that_shares_more_waits(self):
        """omarchy-plugin-marketplace#11837: a restore from the trash keeps this system's sign-in."""
        for change in ({"homeDrive": True}, {"microphone": True}, {"host": "evil.example"},
                       {"gateway": "gw.example"}, {"kdc": "kdc.example"}):
            local = self.binned(self.c(savePassword=True, username="alice"))
            incoming = self.remote(self.c(modified=200, **change))
            data, report = session.merge(local, [incoming], 1000)
            self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"], change)
            self.assertEqual((data["connections"], len(data["trash"]), report["restored"]), ([], 1, []), change)
            data, report = session.merge(local, [incoming], 1000, allow_address=("c1",))
            self.assertEqual(report["restored"], ["Files"], change)
            self.assertEqual(data["connections"][0]["username"], "alice", change)

    def test_a_restore_into_a_group_with_sharing_waits(self):
        local = self.binned(self.c(credential="k1"))
        incoming = self.remote(self.c(group="Evil", modified=200), groups={"Evil": {"settings": {"homeDrive": True}, "modified": 9}})
        data, report = session.merge(local, [incoming], 1000)
        self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"])
        self.assertEqual(data["connections"], [])

    def test_a_restore_without_credentials_here_just_arrives(self):
        local = self.binned(self.c(credential="custom"))
        data, report = session.merge(local, [self.remote(self.c(host="new.lan", homeDrive=True, modified=200))], 1000)
        self.assertEqual(report["pendingAddress"], [])
        self.assertEqual(data["connections"][0]["host"], "new.lan")

    def test_a_restore_that_widens_nothing_just_arrives(self):
        local = self.binned(self.c(savePassword=True))
        data, report = session.merge(local, [self.remote(self.c(name="Back", modified=200))], 1000)
        self.assertEqual(report["pendingAddress"], [])
        self.assertEqual(report["restored"], ["Back"])

    def test_a_move_into_a_group_whose_set_signs_in_waits(self):
        """Its own group has no set, the new one does: it signs in after the move, not before."""
        local = self.local(self.c(credential="inherit"),
                           groups={"Servers": {"credential": "k1", "settings": {}, "modified": 1}})
        data, report = session.merge(local, [self.remote(self.c(host="evil.example", group="Servers", modified=200))], 1000)
        self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"])
        self.assertEqual(data["connections"][0]["host"], "files.lan")

    def test_a_move_that_widens_nothing_just_arrives(self):
        local = self.local(self.c(savePassword=True), groups={"Lab": {"credential": "", "settings": {"audio": "off"}, "modified": 1}})
        data, report = session.merge(local, [self.remote(self.c(group="Lab", modified=200))], 1000)
        self.assertEqual(report["pendingAddress"], [])
        self.assertEqual(data["connections"][0]["group"], "Lab")

    def test_an_ssh_key_signs_in_here_too(self):
        # The key would be offered to the new host, and omaremote.conf would name it for that host.
        local = self.local(self.c(protocol="ssh", port=22, credential="custom", sshKey="~/.ssh/id_ed25519"))
        data, report = session.merge(local, [self.remote(self.c(protocol="ssh", port=22, host="evil.example",
                                                                modified=200))], 1000)
        self.assertEqual(data["connections"][0]["host"], "files.lan")
        self.assertEqual(len(report["pendingAddress"]), 1)

    def test_a_connection_using_its_groups_set_waits_too(self):
        local = self.local(self.c(credential="inherit", group="Servers"),
                           groups={"Servers": {"credential": "k1", "settings": {}, "modified": 1}})
        _, report = session.merge(local, [self.remote(self.c(host="new.lan", group="Servers", modified=200))], 1000)
        self.assertEqual(len(report["pendingAddress"]), 1)

    def test_a_groups_new_gateway_waits_when_the_group_signs_in_here(self):
        local = self.local(groups={"Servers": {"credential": "k1", "settings": {"gateway": "gw.lan"}, "modified": 1}})
        incoming = self.remote(groups={"Servers": {"settings": {"gateway": "gw.example"}, "modified": 9}})
        data, report = session.merge(local, [incoming], 1000)
        self.assertEqual(data["groups"]["Servers"]["settings"]["gateway"], "gw.lan")
        self.assertEqual(report["pendingAddress"][0]["id"], "group:Servers")

    def test_a_groups_new_gateway_waits_when_a_member_signs_in_here(self):
        for member in ({"gatewaySavePassword": True}, {"savePassword": True}):
            local = self.local(self.c(group="G", credential="custom", **member),
                               groups={"G": {"credential": "", "settings": {"gateway": "gw.lan"}, "modified": 1}})
            incoming = self.remote(groups={"G": {"settings": {"gateway": "evil.example"}, "modified": 9}})
            data, report = session.merge(local, [incoming], 1000)
            self.assertEqual(data["groups"]["G"]["settings"]["gateway"], "gw.lan", member)
            self.assertEqual(report["pendingAddress"][0]["id"], "group:G")
        # A group nobody signs in through here: the change just arrives.
        local = self.local(self.c(group="G", credential="custom"),
                           groups={"G": {"credential": "", "settings": {"gateway": "gw.lan"}, "modified": 1}})
        data, report = session.merge(local, [self.remote(groups={"G": {"settings": {"gateway": "gw2.lan"}, "modified": 9}})], 1000)
        self.assertEqual(data["groups"]["G"]["settings"]["gateway"], "gw2.lan")

    def test_switching_the_clipboard_back_on_waits(self):
        local = self.local(self.c(savePassword=True, clipboard=False))
        for change in ({"clipboard": True}, {}):  # {}: dropping the override turns it on as well
            incoming = self.remote(dict({k: v for k, v in self.c(modified=200).items()}, **change))
            data, report = session.merge(local, [incoming], 1000)
            self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"], change)
            self.assertIn("clipboard", report["pendingAddress"][0]["to"])
            self.assertFalse(data["connections"][0]["clipboard"], change)
        # On by default on both sides: nothing to say about it.
        local = self.local(self.c(savePassword=True))
        data, report = session.merge(local, [self.remote(self.c(clipboard=True, modified=200))], 1000)
        self.assertEqual(report["pendingAddress"], [])

    def test_a_new_protocol_without_a_port_counts_as_a_new_port(self):
        local = self.local(self.c(savePassword=True, port=None))
        _, report = session.merge(local, [self.remote(self.c(protocol="vnc", port=None, modified=200))], 1000)
        self.assertEqual([p["id"] for p in report["pendingAddress"]], ["c1"])
        # The default port written out or left out is the same port.
        local = self.local(self.c(savePassword=True, port=None))
        _, report = session.merge(local, [self.remote(self.c(name="Renamed", port=3389, modified=200))], 1000)
        self.assertEqual(report["pendingAddress"], [])

    def test_a_groups_change_counts_its_members_in_the_trash(self):
        """A group's new gateway arrived while its only member that signs in was in the trash; the
        restore after it then compared against the new gateway and widened nothing."""
        local = dict(self.binned(self.c(group="G", savePassword=True)),
                     groups={"G": {"credential": "", "settings": {"gateway": "gw.lan"}, "modified": 1}})
        incoming = self.remote(groups={"G": {"settings": {"gateway": "evil.example"}, "modified": 9}})
        data, report = session.merge(local, [incoming], 1000)
        self.assertEqual([p["id"] for p in report["pendingAddress"]], ["group:G"])
        self.assertEqual(data["groups"]["G"]["settings"]["gateway"], "gw.lan")

    def test_a_synced_group_deletion_that_loosens_waits(self):
        for settings in ({"gateway": "gw.lan"}, {"kdc": "kdc.lan"}, {"security": "nla"}):
            local = self.local(self.c(group="G", savePassword=True),
                               groups={"G": {"credential": "", "settings": settings, "modified": 1}})
            incoming = dict(self.remote(), deletedGroups={"G": 9})
            data, report = session.merge(local, [incoming], 1000)
            self.assertEqual([p["id"] for p in report["pendingAddress"]], ["group:G"], settings)
            self.assertIn("G", data["groups"], settings)
            self.assertNotIn("G", data["deletedGroups"], settings)
            data, _ = session.merge(local, [incoming], 1000, allow_address=("group:G",))
            self.assertNotIn("G", data["groups"], settings)
        # Nobody signs in through it, or it held nothing that matters: it just goes.
        for member, settings in (({}, {"gateway": "gw.lan"}), ({"savePassword": True}, {"audio": "off"})):
            local = self.local(self.c(group="G", **member),
                               groups={"G": {"credential": "", "settings": settings, "modified": 1}})
            data, report = session.merge(local, [dict(self.remote(), deletedGroups={"G": 9})], 1000)
            self.assertEqual(report["pendingAddress"], [])
            self.assertNotIn("G", data["groups"])

    def test_changes_dated_in_the_future_are_not_taken_in(self):
        later = 1000 + session.SYNC_SKEW_MS + 1
        local = self.local(self.c(), groups={"G": {"credential": "", "settings": {}, "modified": 1}})
        incoming = dict(self.remote(self.c(name="Mine forever", modified=later),
                                    groups={"G": {"settings": {"audio": "off"}, "modified": later}}),
                        deleted={"c9": later}, deletedGroups={"G": later})
        data, report = session.merge(local, [incoming], 1000)
        self.assertEqual(data["connections"][0]["name"], "Files")
        self.assertEqual(data["groups"]["G"]["settings"], {})
        self.assertNotIn("c9", data["deleted"])
        self.assertEqual(len([e for e in report["errors"] if "future" in e]), 2)
        # A clock a little ahead is fine.
        data, _ = session.merge(local, [self.remote(self.c(name="Soon", modified=1000 + 60000))], 1000)
        self.assertEqual(data["connections"][0]["name"], "Soon")

    def test_values_of_the_wrong_kind_are_skipped_not_fatal(self):
        local = self.local(self.c(), groups={"G": {"credential": "", "settings": {}, "modified": 1}})
        for bad in ({"host": 5}, {"modified": "9"}, {"aliases": "c2"}, {"gateway": ["x"]},
                    {"homeDrive": "yes"}, {"width": [1]}):
            data, report = session.merge(local, [self.remote(dict(self.c(id="c2", modified=200), **bad))], 1000)
            self.assertEqual([c["id"] for c in data["connections"]], ["c1"], bad)
            self.assertTrue(report["errors"], bad)
        for group in ({"modified": "x"}, {"settings": "x", "modified": 9}, {"settings": {"gateway": 1}, "modified": 9}):
            data, report = session.merge(local, [self.remote(groups={"G": group})], 1000)
            self.assertEqual(data["groups"]["G"]["modified"], 1, group)
        for whole in ({"version": "x"}, {"groups": "x"}, {"deleted": [1]}, {"connections": {"a": 1}}):
            _, report = session.merge(local, [dict(self.remote(), **whole)], 1000)
            self.assertTrue(report["errors"], whole)
        # What OMARemote writes itself still arrives.
        data, report = session.merge(local, [self.remote(self.c(id="c2", host="b.lan", port="3390", scale=150,
                                                                multimon=False, modified=200))], 1000)
        self.assertEqual(report["errors"], [])
        self.assertEqual(len(data["connections"]), 2)

    def test_a_hand_import_deletes_no_groups(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            cfg, src = os.path.join(d, "connections.json"), os.path.join(d, "in.json")
            with open(cfg, "w") as f:
                json.dump(self.local(groups={"G": {"credential": "k1", "settings": {}, "modified": 1}}), f)
            with open(src, "w") as f:
                json.dump(dict(self.remote(), format="omaremote-export", deletedGroups={"G": 9}), f)
            self.assertIn("G", session.import_file(src, path=cfg, now=1000)["data"]["groups"])

    def test_a_sync_file_that_is_not_an_object_is_an_error(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            cfg, folder = os.path.join(d, "connections.json"), os.path.join(d, "sync")
            os.mkdir(folder)
            with open(cfg, "w") as f:
                json.dump({"ui": {"sync": {"folder": folder, "system": "here"}}}, f)
            with open(os.path.join(folder, "other.omaremote.json"), "w") as f:
                json.dump([1, 2], f)
            out = session.sync_folder(cfg, now=1000)
            self.assertTrue(any("other" in e for e in out["report"]["errors"]))

    def test_certificate_checks_never_travel(self):
        out = json.dumps(session.portable(self.local(self.c(ignoreCert=True, security="rdp")), "here"))
        self.assertNotIn("ignoreCert", out)
        self.assertNotIn('"security"', out)
        local = self.local(self.c(ignoreCert=False))
        data, _ = session.merge(local, [self.remote(self.c(ignoreCert=True, security="rdp", modified=200))], 1000)
        self.assertFalse(data["connections"][0].get("ignoreCert"))
        self.assertNotEqual(data["connections"][0].get("security"), "rdp")


class Files(unittest.TestCase):
    """An SSH connection's files through GVFS, opened in the user's own file manager."""

    def test_the_sftp_url_of_a_connection(self):
        self.assertEqual(session.sftp_uri({"protocol": "ssh", "host": "srv.lan"}), "sftp://srv.lan/")
        self.assertEqual(session.sftp_uri({"protocol": "ssh", "host": "srv.lan", "username": "alice", "port": 2222}),
                         "sftp://alice@srv.lan:2222/")
        self.assertEqual(session.sftp_uri({"protocol": "ssh", "host": "bob@srv.lan"}), "sftp://bob@srv.lan/")
        self.assertEqual(session.sftp_uri({"protocol": "ssh", "host": "fe80::1"}), "sftp://[fe80::1]/")
        self.assertEqual(session.sftp_uri({"protocol": "ssh", "host": "srv", "username": "a b"}), "sftp://a%20b@srv/")
        for bad in ({"protocol": "rdp", "host": "srv"}, {"protocol": "ssh", "host": "srv\n/x"}, {"protocol": "ssh", "host": "-oX"}):
            with self.assertRaises(ValueError):
                session.sftp_uri(bad)

    def test_the_folder_layer_is_found_in_the_mount_table(self):
        fuse = session.GVFS_FUSE
        self.assertTrue(session.gvfs_fuse_ready(f"gvfsd-fuse {fuse} fuse.gvfsd-fuse rw 0 0\n"))
        self.assertFalse(session.gvfs_fuse_ready("proc /proc proc rw 0 0\n"))
        self.assertFalse(session.gvfs_fuse_ready(f"other {fuse} tmpfs rw 0 0\n"))

    def run_browse(self, fuse=True, mounted_after=True, gio_ok=True, isdir=True):
        from unittest import mock
        calls = []
        mount = mock.Mock()
        mount.get_default_location.return_value.get_path.return_value = "/run/user/1000/gvfs/sftp:host=srv/home/alice"
        state = {"mounted": False}

        def gio_mount(uri):
            return mount if state["mounted"] else None

        def run(args, *a, **k):
            calls.append(list(args))
            if args[:2] == ["gio", "mount"] and gio_ok:
                state["mounted"] = mounted_after
            return session.subprocess.CompletedProcess(args, 0 if gio_ok else 1, "", "")

        conns = [{"id": "c1", "protocol": "ssh", "host": "srv"}]
        with mock.patch.object(session, "load_connections", lambda *a: conns), \
             mock.patch.object(session, "gvfs_fuse_ready", lambda *a: fuse), \
             mock.patch.object(session, "_gio_mount", gio_mount), \
             mock.patch.object(session.shutil, "which", lambda n: "/usr/bin/" + n), \
             mock.patch.object(session.glob, "glob", lambda p: [p]), \
             mock.patch.object(session.subprocess, "run", run), \
             mock.patch.object(session.subprocess, "Popen", lambda args, **k: calls.append(list(args))), \
             mock.patch.object(session.os.path, "isdir", lambda p: isdir):
            return session.browse("c1"), calls

    def test_mounted_files_open_in_the_default_file_manager(self):
        out, calls = self.run_browse()
        self.assertEqual(out, {"state": "opened"})
        self.assertIn(["xdg-open", "/run/user/1000/gvfs/sftp:host=srv/home/alice"], calls)

    def test_a_host_that_asks_gets_a_terminal(self):
        out, calls = self.run_browse(gio_ok=False)
        self.assertEqual(out, {"state": "terminal"})
        terminal = next(c for c in calls if c[0] == "omarchy")
        self.assertIn("gio mount sftp://srv/", terminal[-1])

    def unmount_after(self, setting, others=False, mounted=True):
        from unittest import mock
        calls = []
        sessions = [{"connection": "c1", "state": "connected"}] if others else [{"connection": "c1", "state": "ended"}]
        with mock.patch.object(session, "load_raw", lambda *a: {"ui": {"sftpOnEnd": setting}}), \
             mock.patch.object(session, "list_sessions", lambda: sessions), \
             mock.patch.object(session, "files_mounted", lambda c: mounted), \
             mock.patch.object(session, "touch_changes", lambda: None), \
             mock.patch.object(session.subprocess, "run", lambda args, **k: calls.append(list(args))):
            session.files_after_session({"id": "c1", "protocol": "ssh", "host": "srv"})
        return calls

    def test_unmount_after_the_last_session_however_it_ended(self):
        self.assertEqual(self.unmount_after("unmount"), [["gio", "mount", "-u", "sftp://srv/"]])

    def test_ask_and_keep_and_other_sessions_leave_the_files(self):
        self.assertEqual(self.unmount_after("ask"), [])
        self.assertEqual(self.unmount_after("keep"), [])
        self.assertEqual(self.unmount_after("unmount", others=True), [])
        self.assertEqual(self.unmount_after("unmount", mounted=False), [])

    def test_only_a_folder_is_ever_opened(self):
        out, calls = self.run_browse(isdir=False)
        self.assertIn("error", out)
        self.assertFalse(any(c[0] == "xdg-open" for c in calls))

    def test_without_the_folder_layer_nothing_is_mounted_and_the_ui_asks(self):
        out, calls = self.run_browse(fuse=False)
        self.assertEqual(out, {"state": "needs-fuse"})
        self.assertEqual(calls, [])
