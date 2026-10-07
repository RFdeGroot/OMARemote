pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The saved connections. connections.json is shared with bin/omaremote-session, which stamps
// lastConnected in place, so the file is watched and written in place too.
Singleton {
    id: root

    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omaremote"
    readonly property string path: configDir + "/connections.json"

    // As saved: each connection holds only what differs from what it inherits.
    property var stored: []
    // Shared credential sets: [{id, username, domain, savePassword}]; passwords live in the keyring.
    property var credentials: []
    // Per group: {credential: set id or "", settings: {key: value}}.
    property var groupSettings: ({})
    property bool loaded: false

    // Keep in step with DEFAULTS in bin/omaremote-session.
    readonly property var defaults: ({
        protocol: "rdp", name: "", group: "", host: "", port: 3389,
        username: "", domain: "", savePassword: false, credential: "custom",
        display: "fit", width: 1920, height: 1080, scale: "auto", multimon: false,
        clipboard: true, audio: "local", microphone: false, homeDrive: false, grabKeyboard: false,
        security: "auto", ignoreCert: false, network: "auto",
        gateway: "", gatewayUser: "", gatewayDomain: "", kdc: "",
        extraArgs: "", openIn: "tab", vncScaling: "fit", vncQuality: "auto", viewOnly: false,
        favourite: false, lastConnected: 0
    })
    // Settings a group can set (SETTING_KEYS in bin/omaremote-session).
    readonly property var settingKeys: ["display", "width", "height", "scale", "multimon", "clipboard", "audio",
        "microphone", "homeDrive", "grabKeyboard", "security", "ignoreCert", "network", "gateway",
        "gatewayUser", "gatewayDomain", "kdc", "extraArgs", "openIn", "vncScaling", "vncQuality", "viewOnly"]
    readonly property var defaultPorts: ({ rdp: 3389, vnc: 5900 })
    readonly property var resolvedOnly: ["credentialSource", "secretKind", "secretId"]

    // Every connection as it will be used: defaults, then its group, then its own values.
    readonly property var connections: stored.map(function (c) { return root.resolve(c) })

    readonly property var groups: {
        var seen = {}
        var out = []
        function add(g) {
            if (g && !seen[g]) {
                seen[g] = true
                out.push(g)
            }
        }
        for (var i = 0; i < stored.length; i++)
            add(stored[i].group)
        for (var name in groupSettings)
            add(name)
        return out.sort(function (a, b) { return a.localeCompare(b) })
    }

    function group(name) {
        var g = groupSettings[name || ""]
        return { credential: g && g.credential ? g.credential : "", settings: g && g.settings ? g.settings : {} }
    }

    function credential(id) {
        for (var i = 0; i < credentials.length; i++)
            if (credentials[i].id === id)
                return credentials[i]
        return null
    }

    function credentialLabel(cred) {
        if (!cred)
            return ""
        return cred.domain ? cred.domain + "\\" + cred.username : (cred.username || "(no user name)")
    }

    // Mirrors resolve() in bin/omaremote-session.
    function resolve(c) {
        var g = group(c.group)
        var out = {}
        var k
        for (k in defaults)
            out[k] = defaults[k]
        for (k in g.settings)
            if (settingKeys.indexOf(k) >= 0)
                out[k] = g.settings[k]
        for (k in c)
            out[k] = c[k]
        if (!c.port)
            out.port = defaultPorts[out.protocol || "rdp"] || 3389
        var mode = c.credential || "custom"
        if (mode === "custom") {
            out.credentialSource = "custom"
            out.secretKind = "connection"
            out.secretId = c.id
        } else {
            var credId = mode === "inherit" ? g.credential : mode
            var cred = credId ? credential(credId) : null
            out.username = cred ? cred.username : ""
            out.domain = cred ? cred.domain : ""
            out.savePassword = cred ? !!cred.savePassword : false
            out.credentialSource = mode === "inherit" ? "group" : "set"
            out.secretKind = "credential"
            out.secretId = credId || ""
        }
        return out
    }

    // What a connection in this group would get if it set nothing itself.
    function inherited(groupName) {
        return resolve({ group: groupName, credential: "custom" })
    }

    // Strips a full (edited) connection down to what differs from its inheritance.
    function normalize(c) {
        var base = inherited(c.group)
        var out = {}
        for (var k in c) {
            if (resolvedOnly.indexOf(k) >= 0)
                continue
            if (settingKeys.indexOf(k) >= 0 && String(c[k]) === String(base[k]))
                continue
            out[k] = c[k]
        }
        if (out.credential && out.credential !== "custom") {
            delete out.username
            delete out.domain
            delete out.savePassword
        }
        return out
    }

    function blank() {
        var c = withDefaults({})
        c.id = ""
        return c
    }

    function withDefaults(c) {
        var out = {}
        for (var k in defaults)
            out[k] = defaults[k]
        for (var key in c)
            out[key] = c[key]
        return out
    }

    // A new connection in a group starts from the group's settings and credentials.
    function blankIn(groupName) {
        var c = resolve({ group: groupName || "", credential: group(groupName).credential ? "inherit" : "custom" })
        c.id = ""
        return c
    }

    function get(id) {
        for (var i = 0; i < connections.length; i++)
            if (connections[i].id === id)
                return connections[i]
        return null
    }

    function storedGet(id) {
        for (var i = 0; i < stored.length; i++)
            if (stored[i].id === id)
                return stored[i]
        return null
    }

    function newId(prefix) {
        return (prefix || "c-") + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
    }

    function parse(text) {
        try {
            var data = JSON.parse(text || "{}")
            if (Array.isArray(data))
                data = { connections: data }
            root.stored = (data.connections || []).filter(function (c) { return c && c.id })
            root.credentials = (data.credentials || []).filter(function (c) { return c && c.id })
            root.groupSettings = data.groups || {}
        } catch (e) {
            console.warn("connections.json is not valid JSON, leaving it untouched: " + e)
        }
        root.loaded = true
    }

    function write() {
        file.setText(JSON.stringify({ version: 2, credentials: credentials, groups: groupSettings, connections: stored }, null, 2) + "\n")
    }

    function saveStored(list) {
        root.stored = list
        write()
    }

    // Takes a full connection (as the editor holds it); returns the stored id.
    function upsert(c) {
        var copy = normalize(c)
        if (!copy.id)
            copy.id = newId("c-")
        var list = stored.slice()
        var at = -1
        for (var i = 0; i < list.length; i++)
            if (list[i].id === copy.id)
                at = i
        if (at >= 0)
            list[at] = copy
        else
            list.push(copy)
        saveStored(list)
        return copy.id
    }

    function remove(id) {
        saveStored(stored.filter(function (c) { return c.id !== id }))
    }

    function duplicate(id) {
        var c = storedGet(id)
        if (!c)
            return ""
        var copy = JSON.parse(JSON.stringify(c))
        copy.id = newId("c-")
        copy.name = (c.name || c.host) + " (copy)"
        copy.lastConnected = 0
        if ((copy.credential || "custom") === "custom")
            copy.savePassword = false // the password belongs to the original's keyring entry
        saveStored(stored.concat([copy]))
        return copy.id
    }

    function toggleFavourite(id) {
        saveStored(stored.map(function (c) {
            if (c.id !== id)
                return c
            var copy = JSON.parse(JSON.stringify(c))
            copy.favourite = !copy.favourite
            return copy
        }))
    }

    // ---------------------------------------------------------------- credential sets

    // Returns the set's id.
    function upsertCredential(cred) {
        var copy = { id: cred.id || newId("k-"), username: cred.username || "", domain: cred.domain || "",
                     savePassword: !!cred.savePassword }
        var list = credentials.filter(function (c) { return c.id !== copy.id })
        var at = -1
        for (var i = 0; i < credentials.length; i++)
            if (credentials[i].id === copy.id)
                at = i
        if (at >= 0)
            list.splice(at, 0, copy)
        else
            list.push(copy)
        root.credentials = list
        write()
        return copy.id
    }

    // Connections and groups that use a set, directly or through their group.
    function credentialUsers(id) {
        var out = { connections: 0, groups: 0 }
        for (var i = 0; i < connections.length; i++)
            if (connections[i].secretKind === "credential" && connections[i].secretId === id)
                out.connections++
        for (var name in groupSettings)
            if (groupSettings[name].credential === id)
                out.groups++
        return out
    }

    function removeCredential(id) {
        root.credentials = credentials.filter(function (c) { return c.id !== id })
        var groupsCopy = JSON.parse(JSON.stringify(groupSettings))
        for (var name in groupsCopy)
            if (groupsCopy[name].credential === id)
                groupsCopy[name].credential = ""
        root.groupSettings = groupsCopy
        // Connections that named the set ask for credentials from now on.
        root.stored = stored.map(function (c) {
            if (c.credential !== id)
                return c
            var copy = JSON.parse(JSON.stringify(c))
            copy.credential = "custom"
            return copy
        })
        write()
    }

    // ---------------------------------------------------------------- groups

    // settings holds only the keys the group sets. applyToMembers makes every connection in the
    // group follow it: their own values for those keys go, and they inherit its credentials.
    function setGroup(name, credentialId, settings, applyToMembers) {
        var groupsCopy = JSON.parse(JSON.stringify(groupSettings))
        groupsCopy[name] = { credential: credentialId || "", settings: settings || {} }
        root.groupSettings = groupsCopy
        if (applyToMembers) {
            root.stored = stored.map(function (c) {
                if (c.group !== name)
                    return c
                var copy = JSON.parse(JSON.stringify(c))
                for (var k in settings)
                    delete copy[k]
                if (credentialId) {
                    copy.credential = "inherit"
                    delete copy.username
                    delete copy.domain
                    delete copy.savePassword
                }
                return copy
            })
        }
        write()
    }

    function membersOf(name) {
        return stored.filter(function (c) { return c.group === name }).length
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", root.configDir]
        running: true
    }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        watchChanges: true
        atomicWrites: false
        printErrors: false
        onLoaded: root.parse(text())
        onLoadFailed: root.loaded = true
        onFileChanged: reload()
    }
}
