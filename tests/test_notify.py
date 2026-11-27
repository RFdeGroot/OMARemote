"""A terminal's desktop notifications through native/plugin/notifier.cpp: what goes to the
notification server over D-Bus (never markup, whatever the server reads: &, < and > as look-alikes), which
clicks come back, and taking them back. On a private bus with a stand-in server, never the
desktop's own."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(os.path.dirname(HERE), "native", "build", "qml")
QML = shutil.which("qml6") or shutil.which("qml")

# The stand-in: owns org.freedesktop.Notifications, says its capabilities (argv[2], comma
# separated), notes every call in argv[1] (a JSON line each), and for a notification titled
# "click me" says first that someone else's (id 999) was clicked, then this one.
SERVER = r"""
import json, sys
from gi.repository import Gio, GLib
XML = '''<node><interface name="org.freedesktop.Notifications">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="Notify"><arg type="s"/><arg type="u"/><arg type="s"/><arg type="s"/><arg type="s"/>
<arg type="as"/><arg type="a{sv}"/><arg type="i"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface></node>'''
log, caps = sys.argv[1], [c for c in sys.argv[2].split(",") if c]
state = {"id": 0}
def note(entry):
    with open(log, "a") as f:
        f.write(json.dumps(entry) + "\n")
def call(conn, sender, path, iface, method, params, inv):
    if method == "GetCapabilities":
        inv.return_value(GLib.Variant("(as)", (caps,)))
    elif method == "Notify":
        app, _replaces, icon, summary, body, actions, hints, expire = params.unpack()
        state["id"] += 1
        nid = state["id"]
        note({"call": "Notify", "id": nid, "app": app, "icon": icon, "summary": summary, "body": body,
              "actions": actions, "entry": hints.get("desktop-entry"), "expire": expire})
        inv.return_value(GLib.Variant("(u)", (nid,)))
        if summary == "click me":
            def click():
                for i in (999, nid):
                    conn.emit_signal(None, path, iface, "ActionInvoked", GLib.Variant("(us)", (i, "default")))
                return False
            GLib.timeout_add(200, click)
    elif method == "CloseNotification":
        note({"call": "CloseNotification", "id": params.unpack()[0]})
        inv.return_value(None)
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
bus.register_object("/org/freedesktop/Notifications", info, call, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.Notifications", Gio.BusNameOwnerFlags.NONE, None, None)
note({"call": "ready"})
GLib.MainLoop().run()
"""


# A bus of its own that starts no services (a --session bus would start the desktop's portals:
# a copy of xdg-desktop-portal-hyprland on the live desktop, which crashed on the way out). Its
# socket in /tmp under a random name: a temporary folder's path can be past a socket's 108 bytes.
BUS_CONFIG = """<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy>
</busconfig>
"""


@unittest.skipUnless(QML and shutil.which("dbus-daemon") and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs qml6, dbus-daemon and the native build")
class Notifier(unittest.TestCase):
    def run_with(self, caps):
        with tempfile.TemporaryDirectory() as d:
            config = os.path.join(d, "bus.conf")
            with open(config, "w") as f:
                f.write(BUS_CONFIG)
            bus = subprocess.Popen(["dbus-daemon", "--config-file", config, "--nofork", "--nopidfile",
                                    "--print-address"], stdout=subprocess.PIPE, text=True)
            try:
                address = bus.stdout.readline().strip()
                self.assertTrue(address, "the private bus did not start")
                # Nothing here reaches the desktop: no Wayland or X display (offscreen needs none).
                env = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "DISPLAY")}
                env["DBUS_SESSION_BUS_ADDRESS"] = address
                log, prog = os.path.join(d, "log"), os.path.join(d, "server.py")
                with open(prog, "w") as f:
                    f.write(SERVER)
                server = subprocess.Popen([sys.executable, "-I", prog, log, caps], env=env)
                try:
                    end = time.time() + 10
                    while not os.path.exists(log) and time.time() < end:
                        time.sleep(0.05)
                    env.update(QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1", QML_IMPORT_PATH=PLUGIN)
                    p = subprocess.run([QML, os.path.join(HERE, "qml", "notify.qml")], env=env,
                                       capture_output=True, text=True, timeout=30)
                finally:
                    server.kill()
                    server.wait()
                with open(log) as f:
                    calls = [json.loads(l) for l in f if l.strip()]
            finally:
                bus.kill()
                bus.wait()
                bus.stdout.close()
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        self.assertTrue(found, p.stderr)
        return json.loads(found.group(1)), [c for c in calls if c["call"] != "ready"]

    def test_sent_clicked_and_taken_back(self):
        result, calls = self.run_with("body,body-markup,actions")
        notes = [c for c in calls if c["call"] == "Notify"]
        self.assertEqual(len(notes), 3)
        build, click, _ = notes
        self.assertEqual((build["app"], build["icon"], build["entry"]), ("OMARemote", "omaremote", "omaremote"))
        self.assertEqual(build["summary"], "Build")
        # Markup as look-alikes, the bell character gone.
        self.assertEqual(build["body"], "a \u2039b\u203a\uff06c\u2039/b\u203a done")
        self.assertEqual(build["actions"], ["default", "Show"])
        self.assertEqual((build["expire"], click["expire"]), (-1, 3000))
        # Only its own click: not someone else's notification's.
        self.assertEqual(result["activated"], ["s2"])
        # Taking back s1's: its id, and only that one.
        self.assertEqual([c["id"] for c in calls if c["call"] == "CloseNotification"], [build["id"]])

    def test_no_markup_reaches_any_server(self):
        """Escaping was not enough: Omarchy's shell decodes entities (three passes) and then lets
        <b> and <a href> through, so an escaped link from the remote side came back clickable, with
        a label of its choosing, in a toast from OMARemote. No &, < or > leave at all, in the title
        too, and no control or bidirectional characters (a right-to-left override flips a toast)."""
        for caps in ("body,body-markup,actions", "body,actions"):
            _, calls = self.run_with(caps)
            evil = [c for c in calls if c["call"] == "Notify"][2]
            for field in ("summary", "body"):
                self.assertFalse(set(evil[field]) & set("<>&"), (caps, field, evil[field]))
                self.assertFalse(re.search("[\u0080-\u009f\u202a-\u202e\u2066-\u2069]", evil[field]), evil[field])
            self.assertIn("evil", evil["body"])  # the words themselves stay
        markup = "/usr/share/omarchy/shell/plugins/notifications/Markup.js"
        node = shutil.which("node")
        if not (node and os.path.exists(markup)):
            return
        # Through the Omarchy shell's own renderer: no tag survives.
        script = """
const fs = require("fs"), path = require("path");
const load = (file, deps) => {
  let text = fs.readFileSync(file, "utf8").replace(/^\\.pragma.*$/m, "").replace(/^\\.import.*$/mg, "");
  const names = Object.keys(deps);
  const body = text + "\\nreturn {" + (text.match(/^function (\\w+)/mg) || []).map(f => f.slice(9)).join(",") + "};";
  return new Function(...names, body)(...names.map(n => deps[n]));
};
const dir = path.dirname(process.argv[1]);
const Security = load(path.join(dir, "Security.js"), {});
const Markup = load(process.argv[1], { Security });
process.stdout.write(Markup.render(process.argv[2]));
"""
        rendered = subprocess.run([node, "-e", script, markup, evil["body"]], capture_output=True, text=True,
                                  timeout=30)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertNotIn("<a", rendered.stdout)
        self.assertNotIn("<b>", rendered.stdout)


if __name__ == "__main__":
    unittest.main()
