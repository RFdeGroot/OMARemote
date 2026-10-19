.pragma library

// "just now", "5 min ago", "3 h ago", "yesterday", "12 days ago", or "" for never.
function ago(seconds, now) {
    if (!seconds)
        return ""
    var d = Math.max(0, Math.floor((now || Date.now() / 1000) - seconds))
    if (d < 60)
        return "just now"
    if (d < 3600)
        return Math.floor(d / 60) + " min ago"
    if (d < 86400)
        return Math.floor(d / 3600) + " h ago"
    if (d < 172800)
        return "yesterday"
    return Math.floor(d / 86400) + " days ago"
}

function clock(seconds) {
    if (!seconds)
        return ""
    var t = new Date(seconds * 1000)
    function pad(n) { return n < 10 ? "0" + n : "" + n }
    return pad(t.getHours()) + ":" + pad(t.getMinutes())
}

// Each protocol's own port: the one table the UI reads (DEFAULT_PORTS in bin/omaremote-session).
var defaultPorts = { rdp: 3389, vnc: 5900, ssh: 22, gliff: 22 }

function defaultPort(protocol) {
    return defaultPorts[protocol || "rdp"] || 3389
}

function address(c) {
    if (!c)
        return ""
    var host = c.host || ""
    return (c.port && Number(c.port) !== defaultPort(c.protocol)) ? host + ":" + c.port : host
}

function account(c) {
    if (!c || !c.username)
        return ""
    return c.domain ? c.domain + "\\" + c.username : c.username
}

function displayLabel(c, monitorScale) {
    if (c.protocol === "gliff")
        return openInLabel(c) + " · " + (c.gliffScreen === "private" ? "Private screen, follows the size" : "Mirrors the main screen")
    if (c.protocol === "vnc") {
        var how = c.vncScaling === "native" ? "Native pixels" : c.vncScaling === "resize" ? "Remote follows tab size" : "Scaled to fit"
        var quality = c.vncQuality === "high" ? "high quality" : c.vncQuality === "low" ? "low bandwidth" : "auto quality"
        return "Tab · " + how + " · " + quality + (c.viewOnly ? " · view only" : "")
    }
    var mode = c.display === "fixed" ? c.width + "×" + c.height + " scaled to fit"
             : c.display === "fullscreen" ? "Fullscreen" : "Follows size"
    var scale = c.scale === "auto" ? "auto (" + (monitorScale || 100) + "%)" : c.scale + "%"
    return openInLabel(c) + " · " + mode + " · scale " + scale
}

// Where a connection opens: "Tab", "Own window", or "Hotkey window (SUPER + ALT + W)".
function openInLabel(c) {
    if (c.openIn === "hotkey")
        return "Hotkey window" + (c.hotkey ? " (" + c.hotkey + ")" : "")
    return c.openIn === "window" ? "Own window" : "Tab"
}

function devicesLabel(c) {
    if (c.protocol === "gliff")
        return c.clipboard === false ? "none" : "clipboard"
    if (c.protocol === "vnc")
        return c.clipboard ? "clipboard" : "none"
    var out = []
    if (c.clipboard)
        out.push("clipboard")
    if (c.audio === "local")
        out.push("sound here")
    else if (c.audio === "remote")
        out.push("sound on remote")
    if (c.microphone)
        out.push("microphone")
    if (c.homeDrive)
        out.push("home folder")
    if (c.grabKeyboard)
        out.push("Super key")
    return out.length ? out.join(", ") : "none"
}

function matches(c, query) {
    if (!query)
        return true
    var hay = [c.name, c.host, c.username, c.domain, c.group].join(" ").toLowerCase()
    var words = query.toLowerCase().split(/\s+/)
    for (var i = 0; i < words.length; i++)
        if (words[i] && hay.indexOf(words[i]) < 0)
            return false
    return true
}

// What a search reads as, to connect to straight away: {protocol, host, port, username}, or null.
// "pc.lan", "rdp://pc.lan:3390", "vnc://10.0.0.5", "ssh://alice@srv", "alice@srv:2222", "[fe80::1]".
// The quick connect card's credential set once the address changes. A set filled in from a recent
// quick connection (filledFor: its host) belongs to that host: typed to another, the set is let
// go, or its password would go to a server nobody chose it for. A set picked by hand (filledFor
// "") stays. Returns {credential, filledFor}.
function quickCredential(credential, filledFor, host) {
    if (!filledFor || String(host || "").toLowerCase() === filledFor.toLowerCase())
        return { credential: credential, filledFor: filledFor }
    return { credential: "custom", filledFor: "" }
}

// The protocol is the scheme's, else RDP for DOMAIN\user@, SSH for user@ or :22, VNC for
// :5900-5999, else RDP. A bare
// word (no dot, scheme, user or port) only counts when `alone` (nothing in the list matched it).
function quickSpec(query, alone) {
    var q = String(query || "").trim()
    if (!q || /\s/.test(q))
        return null
    var m = q.match(/^(rdp|vnc|ssh):\/\/(.*)$/i)
    var scheme = m ? m[1].toLowerCase() : ""
    var rest = m ? m[2].replace(/\/$/, "") : q
    var user = ""
    var at = rest.lastIndexOf("@")
    if (at >= 0) {
        user = rest.slice(0, at)
        rest = rest.slice(at + 1)
        if (!/^[A-Za-z0-9._\\-]{1,64}$/.test(user))
            return null
    }
    var host = rest, port = 0
    var v6 = rest.match(/^\[([0-9A-Fa-f:.%a-zA-Z]+)\](?::(\d{1,5}))?$/)
    if (v6) {
        host = v6[1]
        port = v6[2] ? parseInt(v6[2]) : 0
    } else {
        var hp = rest.match(/^([A-Za-z0-9._-]+)(?::(\d{1,5}))?$/)
        if (!hp)
            return null
        host = hp[1]
        port = hp[2] ? parseInt(hp[2]) : 0
    }
    // The same rule as hosts everywhere else (HOST_RE in bin/omaremote-session).
    if (!host || host[0] === "-" || host.length > 253 || port > 65535)
        return null
    var looksLikeHost = scheme || user || port || v6 || host.indexOf(".") >= 0
    if (!looksLikeHost && !alone)
        return null
    // DOMAIN\user is a Windows sign-in: RDP, with the domain apart.
    var domain = ""
    var slash = user.indexOf("\\")
    if (slash >= 0) {
        domain = user.slice(0, slash)
        user = user.slice(slash + 1)
    }
    var protocol = scheme || (domain ? "rdp" : user || port === 22 ? "ssh" : (port >= 5900 && port <= 5999 ? "vnc" : "rdp"))
    return { protocol: protocol, host: host, port: port || defaultPort(protocol), portGiven: port > 0,
             schemeGiven: !!scheme, username: user, domain: domain }
}

// FreeRDP log text -> [{level, text}], compacted to "time  LEVEL  source  function: message".
// Sample line: [21:41:46:330] [576177:0008cabc] [WARN][com.freerdp.crypto] - [verify_cb]: CN = X
var LOG_RE = /^\[(\d\d:\d\d:\d\d):\d+\] \[[^\]]*\] \[(\w+)\]\[([^\]]*)\] - \[([^\]]*)\]:? ?(.*)$/

function logLines(text, problemsOnly) {
    var raw = String(text || "").split("\n")
    var out = []
    for (var i = Math.max(0, raw.length - 3000); i < raw.length; i++) {
        var line = raw[i]
        if (!line)
            continue
        var m = line.match(LOG_RE)
        var level = m ? m[2] : (line.indexOf("[omaremote]") === 0 ? "INFO" : "")
        if (problemsOnly && level !== "WARN" && level !== "ERROR")
            continue
        var body = m ? m[1] + "  " + (m[2] + "    ").slice(0, 5) + " " + m[3].replace(/^com\.(freerdp|winpr)\./, "")
                       + "  " + m[4] + ": " + m[5]
                     : line
        if (body.length > 400)
            body = body.slice(0, 400) + " …"
        out.push({ level: level, text: body })
    }
    return out
}

// The session keys (Settings › Keyboard, ui.sessionKeys): "ctrlalt" (default), "rctrl" (Right Ctrl,
// a host key) or "ctrlaltshift". Anything else is the default.
function sessionMode(value) {
    return ["ctrlalt", "rctrl", "ctrlaltshift"].indexOf(value) >= 0 ? value : "ctrlalt"
}

// A key as typed with those session keys: "ctrl+alt+home" -> "rctrl+home". Other keys unchanged.
function sessionSpec(mode, spec) {
    var prefix = { ctrlalt: "ctrl+alt", rctrl: "rctrl", ctrlaltshift: "ctrl+alt+shift" }[sessionMode(mode)]
    return spec.indexOf("ctrl+alt+") === 0 ? prefix + spec.slice(8) : spec
}

// Whether a key comes with the session keys held. hostHeld: Right Ctrl is down. With Right Ctrl,
// Ctrl must be held as well, so a release missed (the focus gone meanwhile) never leaves every key
// taken.
function isSessionChord(mode, ctrl, alt, shift, hostHeld) {
    mode = sessionMode(mode)
    if (mode === "rctrl")
        return !!hostHeld && ctrl
    if (mode === "ctrlaltshift")
        return ctrl && alt && shift
    return ctrl && alt
}

// A size for people: "512 B", "3.4 MB", "1.2 GB".
function bytes(n) {
    n = Number(n) || 0
    if (n < 1000)
        return Math.round(n) + " B"
    var units = ["kB", "MB", "GB", "TB"]
    var i = -1
    do { n /= 1000; i++ } while (n >= 1000 && i < units.length - 1)
    return (n < 10 ? n.toFixed(1) : Math.round(n)) + " " + units[i]
}

// The bottom-bar hint for a Gliff tab: how to give Hyprland's shortcuts back while they are taken
// (the session keys + Esc, which StatusBar draws as Settings › Keyboard has them), or how to take
// them again.
function gliffKeyHint(captured) {
    return captured ? ["ctrl+alt+esc", "stop sending super"] : ["click", "send super"]
}

// A Gliff stats line from omaremote-gliff (send_stats): words "key=value". Null when empty.
function parseStats(text) {
    if (!text)
        return null
    var s = {}
    String(text).split(" ").forEach(function (w) {
        var i = w.indexOf("=")
        if (i > 0)
            s[w.slice(0, i)] = w.slice(i + 1)
    })
    s.health = s.health === "warn" || s.health === "bad" ? s.health : "ok"
    return s
}

// Why the dot is not green, in words; "" when it is.
function statsReason(s) {
    if (!s || s.health === "ok")
        return ""
    if (s.why === "reconnecting") return "reconnecting"
    if (s.why === "noreply") return "the server does not answer"
    if (s.why === "congested") return "congested, at most " + s.cap + " fps"
    if (s.why === "latency") return "slow link, " + s.rtt + " ms"
    return "connection problem"
}

// The bar's line, most important first: it drops from the end to fit (the reason and fps stay).
function statsParts(s) {
    if (!s)
        return []
    var parts = []
    var reason = statsReason(s)
    if (reason)
        parts.push(reason)
    if (s.fps === undefined)
        return parts
    parts.push(s.fps + " fps")
    if (Number(s.rtt) >= 0)
        parts.push(s.rtt + " ms ping")
    parts.push(s.mbit + " Mbit/s")
    parts.push("decode " + s.decode + " ms (" + s.decoder + ")")
    parts.push(String(s.size).replace("x", "×") + " " + s.chroma)
    parts.push("server " + s.server)
    return parts
}

// The card's rows: [label, value].
function statsRows(s) {
    if (!s)
        return []
    var rows = [["Connection", statsReason(s) || "good"]]
    if (s.fps === undefined)
        return rows
    rows.push(["Round trip", Number(s.rtt) >= 0 ? s.rtt + " ms (± " + s.dev + " ms)" : "measuring…"])
    rows.push(["Frame rate", s.fps + " fps" + (Number(s.cap) > 0 ? ", at most " + s.cap : "")])
    rows.push(["Bandwidth", s.mbit + " Mbit/s"])
    rows.push(["Decoding", s.decode + " ms a frame, " + (s.decoder === "CPU" ? "on the CPU" : "on the GPU (VA-API)")])
    rows.push(["Stream", String(s.size).replace("x", "×") + ", " + s.chroma])
    rows.push(["Server encodes", s.server === "?" ? "unknown" : "on the " + s.server])
    return rows
}

// Whether coming back to a session after awayMs reconnects it (the connection's unlockAfter, in
// minutes; RDP only). A value that is no whole number from 1 to 1440 counts as off.
function unlockDue(protocol, unlockAfter, awayMs) {
    var minutes = Number(unlockAfter)
    if ((protocol || "rdp") !== "rdp" || typeof unlockAfter === "boolean" || !Number.isInteger(minutes)
            || minutes < 1 || minutes > 1440)
        return false
    return Number(awayMs) >= minutes * 60000
}

// A reconnect of a live session (ctrl+alt+r, unlock on return) keeps the old one on screen until
// the new one is up: its new session for that connection, started after requestedAt (ms), or none.
// The list is newest first: the first match is the newest.
function reconnectCandidate(sessions, connection, oldId, requestedAt) {
    for (var i = 0; i < (sessions || []).length; i++) {
        var s = sessions[i]
        if (s.connection === connection && s.id !== oldId && (Number(s.started) || 0) * 1000 >= requestedAt - 2000)
            return s
    }
    return null
}

// What to do with it: "swap" once connected (the old one stops); "show" after 5 s still
// connecting (it may be asking for a password or a certificate: shown, the old one kept running
// behind it); "failed" (back to the old one); else "wait".
function reconnectStep(s, requestedAt, now) {
    if (!s)
        return now - requestedAt > 60000 ? "failed" : "wait"
    if (s.state === "connected")
        return "swap"
    if (s.state === "connecting")
        return now - requestedAt >= 5000 ? "show" : "wait"
    return "failed"
}

// Whether a failed session is news: not when a newer session of its connection is running (a
// reconnect replaced it, and Windows ended it for the new sign-in).
function failureReplaced(sessions, s) {
    for (var i = 0; i < (sessions || []).length; i++) {
        var o = sessions[i]
        if (o.id !== s.id && o.connection === s.connection && (Number(o.started) || 0) >= (Number(s.started) || 0)
                && (o.state === "connecting" || o.state === "connected"))
            return true
    }
    return false
}
