pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
// Omarchy's palette by its module name: Qt 6.12 brings a `Color` type of its own, which a bare
// `Color` resolves to there (Omarchy did the same, omacom/omarchy#14553).
import qs.Commons as Commons
import "js/Contrast.js" as Contrast

// The app is its own process, so it feeds Omarchy's Color and Style the way the bar's shell.qml does,
// and follows a theme switch live.
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/current"

    readonly property color background: Commons.Color.background
    readonly property color foreground: glass.on ? glass.foreground : Commons.Color.foreground
    readonly property color accent: glass.on ? glass.accent : Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent
    // Secondary text (hosts, times, hints, labels), Flea's dimmed foreground: the theme's own
    // text colour stepped a third of the way toward its background, so it is a quieter grey on
    // dark and light themes alike, held to WCAG AA (4.5:1) on the panel colour.
    readonly property color opaqueMuted: {
        var c = Contrast.ensure(mix(Commons.Color.foreground, background, 0.35), surface, 4.5)
        return Qt.rgba(c.r, c.g, c.b, 1)
    }
    readonly property color muted: glass.on ? glass.muted : opaqueMuted

    // See-through windows (Glass.qml): the alpha of a region's ground and the text lifted to read on
    // it, Flea's material (js/Contrast.js). Glassy: the lowest alpha at which lifted text holds 4.5:1
    // over the blur's brightest and darkest backdrop, 1 when none does. Transparent: Omarchy's own
    // terminals' 0.985 focused and 0.96 not (o.transparent_window; groundAlpha), text lifted for 0.96.
    // Opaque: 1.
    // The text is lifted for a window Hyprland fades to 0.96 as well: while an SSH tab is shown the
    // window carries the `terminal` tag (omaremote-session terminal_tag, for Omarchy's clipboard keys)
    // and Omarchy's rule fades it, text included, as it fades foot. Always, so text does not change
    // colour with the tab; the ground's alpha is worked out without it.
    readonly property var glass: {
        if (!Glass.glassy && !Glass.transparent)
            return { on: false, alpha: 1, terminal: 255 }
        var white = Glass.glassy ? Glass.blurBrightness : 1
        var washes = [selection, hover]
        var m = Contrast.material(background, surface, Commons.Color.foreground, opaqueMuted, washes, white)
        var a = Glass.glassy ? Contrast.floor(m, 4.5) : 245
        if (a >= 255)
            return { on: false, alpha: 1, terminal: 255 }
        var faded = Contrast.material(background, surface, Commons.Color.foreground, opaqueMuted, washes, white, 0.96)
        var k = Contrast.inks(faded, a, 4.5)
        var accent = Contrast.lift(faded, Commons.Color.accent, a, 3, true)
        var rgb = function (c) { return Qt.rgba(c.r, c.g, c.b, 1) }
        return { on: true, alpha: a / 255,
                 // A terminal's own background: the default terminal's, from its theme file (Glass.qml;
                 // omarchy-theme-set-glass writes 0.65 there in Glassy, or keeps the theme's own).
                 // In Transparent a terminal stays solid, as foot does: Omarchy's rule fades the window.
                 terminal: Glass.glassy ? Math.round(Glass.terminalOpacity * 255) : 255,
                 foreground: rgb(k.foreground), muted: rgb(k.muted), accent: rgb(accent) }
    }

    // The ground's alpha, apart from glass so a focus change does not rerun the contrast search:
    // Transparent follows Omarchy's focused / unfocused opacity.
    readonly property real groundAlpha: !glass.on ? 1 : Glass.transparent && Qt.application.active ? 0.985 : glass.alpha

    // A region's ground (the header, sidebar, list, detail, status bar): see-through on glass, so
    // every pixel carries one plane at the glass alpha. Only regions use it; cards, menus and the
    // area around a remote desktop keep their opaque colours.
    function ground(c) {
        return glass.on ? Qt.rgba(c.r, c.g, c.b, groundAlpha) : c
    }
    property color success: "#a6e3a1"
    property color warning: "#f9e2af"
    // Panels sit one step off the background, toward the foreground.
    // From Omarchy's own colours, never the lifted ones: glass is worked out from these.
    readonly property color surface: mix(background, Commons.Color.foreground, 0.045)
    readonly property color raised: mix(background, Commons.Color.foreground, 0.08)
    readonly property color hairline: mix(background, Commons.Color.foreground, 0.12)
    readonly property color selection: Util.alpha(Commons.Color.accent, 0.16)
    readonly property color hover: Util.alpha(Commons.Color.foreground, 0.05)

    readonly property string font: Style.font.family
    readonly property int caption: Style.font.caption
    readonly property int small: Style.font.bodySmall
    readonly property int body: Style.font.body
    readonly property int title: Style.font.title
    readonly property int heading: Style.font.heading
    readonly property int display: Style.font.display
    readonly property int icon: Style.font.icon
    readonly property int radius: Style.cornerRadius

    readonly property int gap: Style.spacing.rowGap
    readonly property int padX: Style.spacing.rowPaddingX
    readonly property int padY: Style.spacing.controlPaddingY
    readonly property int control: Style.spacing.controlHeight
    readonly property int panelPad: Style.spacing.panelPadding

    // Tab strip height, Flea's chrome rule: 0.72 of a list row (a 1.8 line box plus padding).
    readonly property int chrome: Math.round((Math.round(small * 1.8) + 2 * padY) * 0.72)
    // WCAG 2.5.8 floor for anything clickable, whatever it draws.
    readonly property int hitMin: 24

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }

    function pick(body, keys, fallback) {
        for (var i = 0; i < keys.length; i++) {
            var m = String(body).match(new RegExp("^\\s*" + keys[i] + "\\s*=\\s*[\"']?(#[0-9A-Fa-f]{6})", "m"))
            if (m)
                return m[1]
        }
        return fallback
    }

    // A theme file is a few hundred characters; one longer than this is not parsed here (Omarchy's
    // Commons.Color still reads it, see below).
    readonly property int maxThemeLength: 64 * 1024

    function applyColors(body) {
        Commons.Color.loadColors(body)
        root.success = pick(body, ["green", "color2"], root.success)
        root.warning = pick(body, ["yellow", "color3"], root.warning)
    }

    // Whether the theme has been read (or could not be): the windows show once it has, so they never
    // show the default colours first (boot/shell.qml, window/shell.qml, with a timeout of their own).
    readonly property bool loaded: colorsRead && shellRead
    property bool colorsRead: false
    property bool shellRead: false

    // Read in the background, never on the UI thread (blockLoading): a theme file that does not end
    // (a FIFO, a slow disk) must not freeze the window. Omarchy's Commons.Color reads the same files
    // itself, whole, so no size bound here would bound this process.
    FileView {
        id: colorsFile
        path: root.stateDir + "/theme/colors.toml"
        printErrors: false
        onLoaded: {
            var t = text()
            if (t.length <= root.maxThemeLength)
                root.applyColors(t)
            root.colorsRead = true
        }
        onLoadFailed: root.colorsRead = true
    }

    FileView {
        id: shellFile
        path: root.stateDir + "/theme/shell.toml"
        printErrors: false
        onLoaded: {
            var t = text()
            Commons.Color.loadShell(t.length <= root.maxThemeLength ? t : "")
            root.shellRead = true
        }
        onLoadFailed: {
            Commons.Color.loadShell("")
            root.shellRead = true
        }
    }

    // omarchy-theme-set replaces the theme directory, killing any watch inside it; theme.name is
    // rewritten in place after the swap, so it is the one file whose watch survives (Flea, Theme.qml).
    FileView {
        path: root.stateDir + "/theme.name"
        preload: false
        watchChanges: true
        printErrors: false
        // Watch only: its content is never used, and the watch keeps firing without a reload.
        onFileChanged: {
            colorsFile.reload()
            shellFile.reload()
            Style.scheduleRefresh()
            Glass.reread()
        }
    }
}
