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

// ---- See-through windows (Omarchy's Glassy and Transparent), ported from Flea 0.4.3's
// src/theme/material.rs. Text on a see-through ground is held to its ratio over the worst backdrop:
// black, and white, dimmed by glass.lua's blur brightness (0.75) when Glassy blurs what is behind.
// Colors are {r, g, b} in 0..1, rounded to 8 bits as the screen shows them.

function quantize(c) {
    return { r: Math.round(c.r * 255) / 255, g: Math.round(c.g * 255) / 255, b: Math.round(c.b * 255) / 255 }
}

function mixed(a, b, t) {
    return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t }
}

// plane at alpha (0..255) over backdrop.
function over(plane, alpha, backdrop) {
    return quantize(mixed(backdrop, plane, alpha / 255))
}

function backdrops(m) {
    return [quantize({ r: m.white, g: m.white, b: m.white }), { r: 0, g: 0, b: 0 }]
}

// The lowest ratio ink reaches on any of the planes at alpha, over either backdrop, and with washes
// ({r, g, b, a}: a selected or hovered row's tint) over each of those grounds too. With m.fade below 1
// Hyprland fades the whole window (text included) to that opacity: ink and ground are both seen
// through it.
function worst(m, ink, planes, alpha, washes) {
    var low = Infinity, drops = backdrops(m), f = m.fade
    for (var i = 0; i < planes.length; i++)
        for (var j = 0; j < drops.length; j++) {
            var seen = f < 1 ? over(ink, f * 255, drops[j]) : ink
            var ground = over(planes[i], alpha * f, drops[j])
            low = Math.min(low, ratio(seen, ground))
            for (var k = 0; washes && k < washes.length; k++)
                low = Math.min(low, ratio(seen, over(washes[k], washes[k].a * f * 255, ground)))
        }
    return low
}

// Inks move toward white on a dark theme, toward black on a light one.
function toward(m) {
    return luminance(m.foreground) > luminance(m.background) ? { r: 1, g: 1, b: 1 } : { r: 0, g: 0, b: 0 }
}

// from itself when it holds; otherwise the least step toward the material's lift colour that does.
function search(m, from, holds) {
    if (holds(from))
        return from
    var to = toward(m), lo = 0, hi = 1
    for (var i = 0; i < 20; i++) {
        var mid = (lo + hi) / 2
        if (holds(quantize(mixed(from, to, mid))))
            hi = mid
        else
            lo = mid
    }
    for (var t = hi; t <= 1; t += 1 / 512) {
        var c = quantize(mixed(from, to, t))
        if (holds(c))
            return c
    }
    return to
}

// Lifted to need on the planes; with washes, on the selected and hovered rows too.
function lift(m, ink, alpha, need, washes) {
    return search(m, ink, function (c) { return worst(m, c, m.planes, alpha, washes ? m.washes : null) >= need })
}

// Secondary text stays quieter than primary text (at least 1.25:1 apart), so the two still read
// as two levels once both are lifted.
function quieter(m, ink, primary) {
    var less = toward(m).r === 1 ? luminance(ink) < luminance(primary) : luminance(ink) > luminance(primary)
    return less && ratio(ink, primary) >= 1.25
}

// Primary text sits on selected and hovered rows; secondary text is held on the plain planes only,
// as off glass, where it is already below 4.5:1 on a selection (lifting it there would leave most
// themes opaque).
function primaryHolds(m, ink, alpha, need, muted) {
    return worst(m, ink, m.planes, alpha, m.washes) >= need && quieter(m, muted, ink)
}

// m: { background, surface, foreground, muted } (the opaque theme). Returns { foreground, muted }
// lifted to need on the planes at alpha.
function inks(m, alpha, need) {
    var muted = lift(m, m.muted, alpha, need)
    var primary = search(m, m.foreground, function (c) { return primaryHolds(m, c, alpha, need, muted) })
    return { foreground: primary, muted: muted }
}

// The lowest alpha (192..254) at which lifted text holds need on both planes; 255 when none does.
function floor(m, need) {
    for (var a = 192; a < 255; a++) {
        var k = inks(m, a, need)
        if (primaryHolds(m, k.foreground, a, need, k.muted) && worst(m, k.muted, m.planes, a) >= need)
            return a
    }
    return 255
}

// washes: the tints rows draw over the ground ({r, g, b, a}: Theme.selection and Theme.hover);
// white: how bright the brightest backdrop is: Hyprland's blur brightness in Glassy (glass.lua's
// 0.75), 1 for the bare desktop (Transparent); 0.75 when not given. fade: the whole window's opacity
// in Hyprland (1 when not given).
function material(background, surface, foreground, muted, washes, white, fade) {
    var q = function (c) { return quantize({ r: c.r, g: c.g, b: c.b }) }
    return { background: q(background), surface: q(surface), foreground: q(foreground), muted: q(muted),
             white: typeof white === "number" ? Math.min(1, Math.max(0, white)) : white === false ? 1 : 0.75,
             fade: typeof fade === "number" ? Math.min(1, Math.max(0.5, fade)) : 1,
             planes: [q(background), q(surface)],
             washes: (washes || []).map(function (w) { var c = q(w); c.a = w.a; return c }) }
}
