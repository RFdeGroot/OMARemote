.pragma library

// WCAG 2.1 contrast, so text colours derived from a theme can be held to a minimum ratio.

function linear(c) {
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

// c: a QML color (r, g, b in 0..1).
function luminance(c) {
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
}

function ratio(a, b) {
    var la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

// fg itself when it already reaches minRatio on bg; otherwise fg moved toward white (on a dark
// background) or black (on a light one), just far enough. Returns {r, g, b}.
function ensure(fg, bg, minRatio) {
    if (ratio(fg, bg) >= minRatio)
        return fg
    var to = luminance(bg) > 0.179 ? 0 : 1
    var lo = 0, hi = 1
    for (var i = 0; i < 20; i++) {
        var mid = (lo + hi) / 2
        var c = { r: fg.r + (to - fg.r) * mid, g: fg.g + (to - fg.g) * mid, b: fg.b + (to - fg.b) * mid }
        if (ratio(c, bg) >= minRatio)
            hi = mid
        else
            lo = mid
    }
    return { r: fg.r + (to - fg.r) * hi, g: fg.g + (to - fg.g) * hi, b: fg.b + (to - fg.b) * hi }
}
