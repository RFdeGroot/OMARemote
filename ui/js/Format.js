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

function address(c) {
    if (!c)
        return ""
    var host = c.host || ""
    return (c.port && Number(c.port) !== 3389) ? host + ":" + c.port : host
}

function account(c) {
    if (!c || !c.username)
        return ""
    return c.domain ? c.domain + "\\" + c.username : c.username
}

function displayLabel(c, monitorScale) {
    var mode = c.display === "fixed" ? c.width + "×" + c.height + " scaled to fit"
             : c.display === "fullscreen" ? "Fullscreen" : "Follows size"
    var scale = c.scale === "auto" ? "auto (" + (monitorScale || 100) + "%)" : c.scale + "%"
    return (c.openIn === "window" ? "Own window · " : "Tab · ") + mode + " · scale " + scale
}

function devicesLabel(c) {
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
