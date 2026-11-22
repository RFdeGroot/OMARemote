"""Omarchy's Glassy windows (ui/Glass.qml, Theme.ground, js/Contrast.js).

The maths: on every installed Omarchy theme the lifted text holds 4.5:1 (the accent 3:1) on both
see-through grounds over the blur's brightest and darkest backdrop, checked here with a WCAG
implementation of its own; a theme that cannot keep that stays opaque.

The window: the real manager window (ui/boot) offscreen, rendered over magenta and over green
(OMAREMOTE_SNAP_BACKDROP). Each channel composes as c = p*a + m*(1 - a), so the two renders give
each pixel's alpha: every region must show one plane at the glass alpha, never two over each other
(two at 0.75 would read 0.94), and off glass every pixel is opaque."""
import collections
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..")
QML = shutil.which("qml6") or shutil.which("qml")
QS = shutil.which("qs")
MAGICK = shutil.which("magick")
PLUGIN = os.path.join(REPO, "native", "build", "qml")
THEMES = "/usr/share/omarchy/themes"
BLUR = 0.75  # Glassy's white backdrop; Transparent has no blur: 1

# Fixed palettes, so the maths is checked on a machine without Omarchy too.
FIXED = {"tokyo-night": ("#1a1b26", "#a9b1d6", "#7aa2f7"),
         "catppuccin-latte": ("#eff1f5", "#4c4f69", "#1e66f5"),
         "white": ("#ffffff", "#000000", "#6e6e6e")}


def rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (1, 3, 5))


def lum(c):
    lin = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def ratio(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def over(plane, alpha, backdrop):
    return tuple(round((b + (p - b) * alpha / 255) * 255) / 255 for p, b in zip(plane, backdrop))


def worst(ink, planes, alpha, washes=(), white=BLUR, fade=1.0):
    """The lowest ratio on any plane over either backdrop; washes ((colour, alpha): a selected or
    hovered row's tint) over each of those grounds too. fade: Hyprland's opacity for the whole
    window (the `terminal` tag while an SSH tab is shown), text included."""
    drops = [(round(white * 255) / 255,) * 3, (0, 0, 0)]
    low = float("inf")
    for p in planes:
        for d in drops:
            seen = over(ink, fade * 255, d) if fade < 1 else ink
            ground = over(p, alpha * fade, d)
            low = min([low, ratio(seen, ground)] + [ratio(seen, over(c, a * fade * 255, ground)) for c, a in washes])
    return low


def q(v):
    return round(v * 255) / 255


def worst_rounded(ink, planes, alpha, washes=(), white=BLUR, fade=0.96):
    """worst() the way the screen gets there: rounded to 8 bits in the window's buffer
    (premultiplied: the ground, then a wash over it), then faded by Hyprland and composited over the
    backdrop in its shader (floating point), rounded again in the framebuffer. An exact 4.5 in
    worst() can come out below it here."""
    drops = [(q(white),) * 3, (0, 0, 0)]

    def seen(premul, a, d):  # a window pixel (premultiplied colour, alpha) faded and composited
        return tuple(q(c * fade + bd * (1 - a * fade)) for c, bd in zip(premul, d))

    low = float("inf")
    for p in planes:
        a = q(alpha / 255)
        ground = [q(c * a) for c in p]
        pixels = [(ground, a)]
        for c, wa in washes:  # a wash over the ground, in the window's buffer
            pixels.append(([q(wc * wa + g * (1 - wa)) for wc, g in zip(c, ground)], q(wa + a * (1 - wa))))
        for d in drops:
            text = seen([q(c) for c in ink], 1.0, d)
            low = min([low] + [ratio(text, seen(px, pa, d)) for px, pa in pixels])
    return low


def installed():
    found = {}
    if not os.path.isdir(THEMES):
        return found
    for name in sorted(os.listdir(THEMES)):
        try:
            with open(os.path.join(THEMES, name, "colors.toml")) as f:
                text = f.read()
        except OSError:
            continue
        pick = lambda key: (re.search(rf'^\s*{key}\s*=\s*"(#[0-9A-Fa-f]{{6}})"', text, re.M) or [None, None])[1]
        if pick("background") and pick("foreground") and pick("accent"):
            found[name] = (pick("background"), pick("foreground"), pick("accent"))
    return found


def theme_numbers():
    """Theme.qml's own: the contrast text and accent aim for through Hyprland's fade, the fade it
    lifts for, and the selection and hover washes, read from the file so the harness runs what
    ships."""
    with open(os.path.join(REPO, "ui", "Theme.qml")) as f:
        text = f.read()
    find = lambda pattern: float(re.search(pattern, text).group(1))
    return (find(r"readonly property real fadedNeed: ([\d.]+)"),
            find(r"readonly property real fadedAccentNeed: ([\d.]+)"),
            find(r"var faded = Contrast\.material\([^)]*, white, ([\d.]+)\)"),
            find(r"readonly property color selection: Util\.alpha\(Commons\.Color\.accent, ([\d.]+)\)"),
            find(r"readonly property color hover: Util\.alpha\(Commons\.Color\.foreground, ([\d.]+)\)"))


@unittest.skipUnless(QML, "needs qml6")
class Maths(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        palettes = cls.palettes = dict(FIXED, **installed())
        cls.theme = theme_numbers()
        p = subprocess.run([QML, os.path.join(HERE, "qml", "glass.qml"), "--",
                            "theme=" + ",".join(str(v) for v in cls.theme)]
                           + [f"{k}={','.join(v)}" for k, v in palettes.items()],
                           env=dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1"), capture_output=True, text=True, timeout=60)
        found = re.search(r"RESULT (\{.*\})", p.stderr + p.stdout)
        assert found, p.stderr
        cls.result = json.loads(found.group(1))

    def test_lifted_text_holds_on_both_grounds_over_either_backdrop(self):
        for name, r in self.result["palettes"].items():
            with self.subTest(theme=name):
                if r["alpha"] >= 255:
                    continue  # stays opaque
                self.assertGreaterEqual(r["alpha"], 192)
                planes = [rgb(r["background"]), rgb(r["surface"])]
                _, fg, accent = self.palettes[name]
                # Theme.selection and Theme.hover, from the theme's own colours.
                washes = [(rgb(accent), self.theme[3]), (rgb(fg), self.theme[4])]
                # Unfaded, and seen through Hyprland's fade while an SSH tab is shown (0.985, 0.96).
                for fade in (1.0, 0.985, 0.96):
                    self.assertGreaterEqual(worst(rgb(r["foreground"]), planes, r["alpha"], washes, BLUR, fade), 4.5)
                    self.assertGreaterEqual(worst(rgb(r["accent"]), planes, r["alpha"], washes, BLUR, fade), 3)
                    # Secondary text on the plain grounds; on a selection it is below 4.5 off glass too.
                    self.assertGreaterEqual(worst(rgb(r["muted"]), planes, r["alpha"], (), BLUR, fade), 4.5)
                # Secondary text still reads as quieter than primary text.
                self.assertGreaterEqual(ratio(rgb(r["foreground"]), rgb(r["muted"])), 1.25)

    def test_text_holds_through_the_fade_rounded_as_the_screen_rounds(self):
        # Theme.fadedNeed's margin: through Hyprland's fade, rounded at every step, still 4.5 and 3.
        for name, r in self.result["palettes"].items():
            _, fg, accent = self.palettes[name]
            washes = [(rgb(accent), self.theme[3]), (rgb(fg), self.theme[4])]
            cases = [(r, r["alpha"], BLUR), (r["transparent"], 245, 1)]
            for inks, alpha, white in cases:
                if alpha >= 255:
                    continue
                planes = [rgb(r["background"]), rgb(r["surface"])]
                for fade in (0.985, 0.96):
                    with self.subTest(theme=name, white=white, fade=fade):
                        self.assertGreaterEqual(worst_rounded(rgb(inks["foreground"]), planes, alpha, washes, white, fade), 4.5)
                        self.assertGreaterEqual(worst_rounded(rgb(inks["accent"]), planes, alpha, washes, white, fade), 3)
                        self.assertGreaterEqual(worst_rounded(rgb(inks["muted"]), planes, alpha, (), white, fade), 4.5)

    def test_transparent_text_holds_over_the_bare_desktop(self):
        for name, r in self.result["palettes"].items():
            with self.subTest(theme=name):
                t = r["transparent"]
                planes = [rgb(r["background"]), rgb(r["surface"])]
                _, fg, accent = self.palettes[name]
                washes = [(rgb(accent), self.theme[3]), (rgb(fg), self.theme[4])]
                for fade in (1.0, 0.96):
                    self.assertGreaterEqual(worst(rgb(t["foreground"]), planes, 245, washes, 1, fade), 4.5)
                    self.assertGreaterEqual(worst(rgb(t["accent"]), planes, 245, washes, 1, fade), 3)
                    self.assertGreaterEqual(worst(rgb(t["muted"]), planes, 245, (), 1, fade), 4.5)

    def test_most_themes_go_see_through(self):
        alphas = {n: r["alpha"] for n, r in self.result["palettes"].items()}
        clear = [n for n, a in alphas.items() if a < 255]
        self.assertIn("tokyo-night", clear, alphas)
        self.assertGreater(len(clear), len(alphas) / 2, alphas)

    def test_quick_enough_for_a_theme_switch(self):
        # Every palette at once; the window works out one, when the theme changes.
        self.assertLess(self.result["ms"] / len(self.result["palettes"]), 200, self.result["ms"])


@unittest.skipUnless(QS and MAGICK and os.path.isdir(os.path.join(PLUGIN, "OMARemote")),
                     "needs quickshell (qs), ImageMagick and the native build (ninja -C native/build)")
class Window(unittest.TestCase):
    def render(self, d, backdrop, glass, actions):
        png = os.path.join(d, f"{backdrop[1:]}-{glass}.png")
        env = dict(os.environ, HOME=d, XDG_CONFIG_HOME=os.path.join(d, "config"), XDG_RUNTIME_DIR=d,
                   XDG_STATE_HOME=os.path.join(d, "state"), OMAREMOTE_RUNTIME_DIR=os.path.join(d, "run"),
                   QT_QPA_PLATFORM="offscreen", QT_SCALE_FACTOR="1", OMAREMOTE_NO_UPDATE_CHECK="1",
                   OMAREMOTE_NOTIFY="0", OMAREMOTE_VERSION="dev", OMAREMOTE_INSTALL="package",
                   OMAREMOTE_BIN=os.path.join(REPO, "bin", "omaremote-session"), QML_IMPORT_PATH=PLUGIN,
                   OMAREMOTE_SNAPSHOT=png, OMAREMOTE_SNAP_BACKDROP=backdrop, OMAREMOTE_ACTIONS=actions,
                   OMARCHY_PATH=os.path.join(d, "omarchy"),
                   # A stand-in ssh that stays connected, so an SSH tab shows its terminal.
                   PATH=os.path.join(d, "bin") + os.pathsep + os.environ.get("PATH", ""))
        env.pop("OMAREMOTE_GLASS", None)
        if glass is not None:
            env["OMAREMOTE_GLASS"] = glass
        subprocess.run(["timeout", "25", QS, "-p", os.path.join(REPO, "ui", "boot")], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertTrue(os.path.exists(png), "no snapshot")
        raw = subprocess.run([MAGICK, png, "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout
        size = subprocess.run([MAGICK, "identify", "-format", "%w %h", png], capture_output=True, text=True,
                              check=True).stdout.split()
        return raw, int(size[0]), int(size[1])

    def alphas(self, glass, actions="", toggles=False, foot=None):
        """Each pixel's alpha in 0..255, from renders over magenta and over green. glass: the
        OMAREMOTE_GLASS hook ("1", "0") or None for what Omarchy's files say; toggles: Glassy
        switched on there (window-glassy.lua, and Omarchy's glass.lua)."""
        with tempfile.TemporaryDirectory() as d:
            if toggles:
                files = {True: ["window-glassy.lua"], "transparent": [], "opaque": ["window-opaque.lua"]}[toggles]
                for path in ["state/omarchy/toggles/hypr/" + f for f in files] + ["omarchy/default/hypr/glass.lua"]:
                    os.makedirs(os.path.dirname(os.path.join(d, path)), exist_ok=True)
                    open(os.path.join(d, path), "w").close()
            theme = os.path.join(d, ".local", "state", "omarchy", "current", "theme")
            os.makedirs(theme)
            bg, fg, accent = FIXED["tokyo-night"]
            with open(os.path.join(theme, "colors.toml"), "w") as f:
                f.write(f'background = "{bg}"\nforeground = "{fg}"\naccent = "{accent}"\n')
            os.makedirs(os.path.join(d, "bin"))
            with open(os.path.join(d, "bin", "ssh"), "w") as f:
                f.write("#!/bin/sh\necho connected\nexec sleep 30\n")
            os.chmod(os.path.join(d, "bin", "ssh"), 0o755)
            # foot is the default terminal; its theme file, when given, sets the glassy terminal's alpha.
            with open(os.path.join(d, "bin", "xdg-terminal-exec"), "w") as f:
                f.write("#!/bin/sh\necho foot.desktop\n")
            os.chmod(os.path.join(d, "bin", "xdg-terminal-exec"), 0o755)
            if foot is not None:
                with open(os.path.join(theme, "foot.ini"), "w") as f:
                    f.write(foot)
            os.makedirs(os.path.join(d, "config", "omaremote"))
            os.makedirs(os.path.join(d, "run"))
            with open(os.path.join(d, "config", "omaremote", "connections.json"), "w") as f:
                json.dump({"connections": [{"id": "c-one", "name": "One", "host": "one.lan", "protocol": "ssh"}]}, f)
            m, w, h = self.render(d, "#ff00ff", glass, actions)
            g, w2, h2 = self.render(d, "#00ff00", glass, actions)
        self.assertEqual((w, h), (w2, h2))
        # Red: 255 behind magenta, 0 behind green; green the other way round. c1 - c2 = 255 (1 - a).
        out = []
        for i in range(0, len(m), 3):
            seen = ((m[i] - g[i]) + (g[i + 1] - m[i + 1])) / 2
            out.append(round(255 - seen))
        return out, w, h

    def modal(self, alphas, w, box):
        x0, y0, x1, y1 = box
        counts = collections.Counter(alphas[y * w + x] for y in range(y0, y1) for x in range(x0, x1))
        return counts.most_common(1)[0][0]

    def test_glass_regions_are_one_plane_each(self):
        alphas, w, h = self.alphas("1")
        regions = {"sidebar": (10, 200, 200, 400), "list": (230, 200, 560, 400),
                   "detail": (w - 380, 200, w - 20, 400), "status": (230, h - 12, w - 20, h - 4),
                   "header": (300, 4, 600, 20)}
        found = {n: self.modal(alphas, w, box) for n, box in regions.items()}
        for name, a in found.items():
            self.assertTrue(190 <= a <= 194, found)  # Tokyo Night's glass alpha is 192
        # Nowhere two planes over each other, and nowhere bare desktop. Text edges pass through every
        # alpha between the ground's and 1, so only a solid 4x4 block counts as an area.
        self.assert_one_plane(alphas, w, h)

    def blocks(self, alphas, w, h, inside):
        found = []
        for y in range(0, h - 4, 4):
            for x in range(0, w - 4, 4):
                if all(inside(alphas[(y + j) * w + x + i]) for j in range(4) for i in range(4)):
                    found.append((x, y))
        return found[:10]

    def assert_one_plane(self, alphas, w, h):
        self.assertEqual(self.blocks(alphas, w, h, lambda a: 235 <= a <= 243), [])
        self.assertEqual(self.blocks(alphas, w, h, lambda a: a < 150), [])

    def test_the_editor_is_one_plane(self):
        alphas, w, h = self.alphas("1", "new")
        self.assertTrue(190 <= self.modal(alphas, w, (w - 400, 200, w - 20, 400)) <= 194)
        self.assert_one_plane(alphas, w, h)

    def test_a_session_tab_stays_opaque_beside_the_glass_dock(self):
        alphas, w, h = self.alphas("1", "ui:pinned:true tab:s-1")
        found = {"session": self.modal(alphas, w, (400, 200, w - 20, 500)),
                 "dock": self.modal(alphas, w, (10, 200, 120, 500))}
        self.assertEqual(found["session"], 255, found)
        self.assertTrue(190 <= found["dock"] <= 194, found)
        self.assert_one_plane(alphas, w, h)

    def test_an_ssh_tab_is_see_through_like_omarchys_terminals(self):
        # Omarchy's glassy terminals are 0.65 (166); nothing solid under the terminal (the letterbox
        # ground was, and made it much darker than foot).
        alphas, w, h = self.alphas("1", "connect")
        found = self.modal(alphas, w, (300, 200, w - 40, 500))
        self.assertTrue(164 <= found <= 168, found)

    def test_an_ssh_tab_follows_the_default_terminals_theme(self):
        # A theme (or the user) with its own opacity for the default terminal: the SSH tab follows it.
        alphas, w, h = self.alphas("1", "connect", foot="[colors-dark]\nalpha=0.5\nbackground=1a1b26\n")
        found = self.modal(alphas, w, (300, 200, w - 40, 500))
        self.assertTrue(126 <= found <= 130, found)

    def test_omarchy_glassy_switches_it_on(self):
        alphas, w, _ = self.alphas(None, toggles=True)
        self.assertTrue(190 <= self.modal(alphas, w, (230, 200, 560, 400)) <= 194)

    def test_without_omarchy_4_5_every_pixel_is_opaque(self):
        # Omarchy 4.0.6 has no toggle files and no glass.lua, and fades every window itself.
        alphas, _, _ = self.alphas(None)
        self.assertEqual(sum(1 for a in alphas if a < 254), 0)

    def test_omarchy_transparent_is_the_default_on_4_5(self):
        alphas, w, h = self.alphas(None, toggles="transparent")
        found = {n: self.modal(alphas, w, box) for n, box in
                 {"list": (230, 200, 560, 400), "sidebar": (10, 200, 200, 400), "status": (230, h - 12, w - 20, h - 4)}.items()}
        for a in found.values():
            self.assertTrue(243 <= a <= 252, found)  # 0.96 unfocused, 0.985 focused
        self.assertEqual(self.blocks(alphas, w, h, lambda a: a < 235), [])

    def test_omarchy_opaque_is_opaque(self):
        alphas, _, _ = self.alphas(None, toggles="opaque")
        self.assertEqual(sum(1 for a in alphas if a < 254), 0)

    def test_off_glass_every_pixel_is_opaque(self):
        alphas, _, _ = self.alphas("0", toggles=True)
        self.assertEqual(sum(1 for a in alphas if a < 254), 0)


if __name__ == "__main__":
    unittest.main()
