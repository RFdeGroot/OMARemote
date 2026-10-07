pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "js/Contrast.js" as Contrast

// The app is its own process, so it feeds Omarchy's Color and Style the way the bar's shell.qml does,
// and follows a theme switch live.
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/current"

    readonly property color background: Color.background
    readonly property color foreground: Color.foreground
    readonly property color accent: Color.accent
    readonly property color urgent: Color.urgent
    // Secondary text (hosts, times, hints, labels), Flea's dimmed foreground: the theme's own
    // text colour stepped a third of the way toward its background, so it is a quieter grey on
    // dark and light themes alike, held to WCAG AA (4.5:1) on the panel colour.
    readonly property color muted: {
        var c = Contrast.ensure(mix(foreground, background, 0.35), surface, 4.5)
        return Qt.rgba(c.r, c.g, c.b, 1)
    }
    property color success: "#a6e3a1"
    property color warning: "#f9e2af"
    // Panels sit one step off the background, toward the foreground.
    readonly property color surface: mix(background, foreground, 0.045)
    readonly property color raised: mix(background, foreground, 0.08)
    readonly property color hairline: mix(background, foreground, 0.12)
    readonly property color selection: Util.alpha(accent, 0.16)
    readonly property color hover: Util.alpha(foreground, 0.05)

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

    function applyColors(body) {
        Color.loadColors(body)
        root.success = pick(body, ["green", "color2"], root.success)
        root.warning = pick(body, ["yellow", "color3"], root.warning)
    }

    FileView {
        id: colorsFile
        path: root.stateDir + "/theme/colors.toml"
        blockLoading: true
        printErrors: false
        onLoaded: root.applyColors(text())
        Component.onCompleted: root.applyColors(colorsFile.text())
    }

    FileView {
        id: shellFile
        path: root.stateDir + "/theme/shell.toml"
        blockLoading: true
        printErrors: false
        onLoaded: Color.loadShell(text())
        onLoadFailed: Color.loadShell("")
    }

    // omarchy-theme-set replaces the theme directory, killing any watch inside it; theme.name is
    // rewritten in place after the swap, so it is the one file whose watch survives (Flea, Theme.qml).
    FileView {
        path: root.stateDir + "/theme.name"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: {
            reload()
            colorsFile.reload()
            shellFile.reload()
            Style.scheduleRefresh()
        }
    }
}
