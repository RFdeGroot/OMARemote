import importlib.machinery
import importlib.util
import os
import sys
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
            self.assertIn("kdc = dc9:88", open(path).read())

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
            open(os.path.join(cfg, "oma-remote", "connections.json"), "w").write("{}")
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
