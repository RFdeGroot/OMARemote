# What the Omarchy bar plugin relies on

The [bar plugin](https://github.com/RFdeGroot/omarchy-omaremote) (`rfdegroot.omaremote`) talks to
OMARemote only through the interface below. A change to any of it is a change for the plugin too:
keep it compatible, or raise the plugin's `omaremote.minimumVersion` in the same breath. The
plugin's `AGENTS.md` points back here.

| What | Where in OMARemote | Plugin use |
| --- | --- | --- |
| `omaremote --version` prints `omaremote <version>` (e.g. `omaremote 0.1.3-alpha`) | `bin/omaremote` | installed, and new enough? (minimum 0.1.3-alpha) |
| `omaremote` with no arguments opens the manager, or focuses the open one | `bin/omaremote` | the open-OMARemote button, `o` |
| `omaremote open <id\|name\|host>`: running session forward, else connect in a tab; starts OMARemote when needed | `bin/omaremote`, `ui/Body.qml` (`openNamed`) | clicking a session or favourite |
| `omaremote open --window <id\|name\|host>` (0.1.6-alpha): the connection in a floating window of its own (90% of the screen) on the current workspace. Running in a tab: moves out of it (the connection stays up). In a window already: that window moves to the current workspace and is focused. Not running: connects straight into a window, without opening the manager | `bin/omaremote`, `bin/omaremote-session` (`open_window`) | clicking with "open in own window" on |
| Quickshell IPC target `omaremote`: `open(name) -> "ok" \| "unknown connection: …"`, `focus()`. `name` is a connection's id, name or host; failing those, a running session's connection id or session id (so a session whose connection was deleted while it ran still comes forward) | `ui/Body.qml` (`openNamed`, `showRunning`) | through `omaremote open` |
| `omaremote-session paths` prints JSON `{runtime, changes, connections}` | `bin/omaremote-session` | which files to watch |
| The `changes` file is rewritten in place on every session event | `bin/omaremote-session` (`touch_changes`) | refresh the session list |
| `omaremote-session list` prints a JSON array of sessions: `id`, `connection`, `name`, `host`, `protocol`, `state` (`connecting`, `connected`, `failed`, …), `tab` (bool: drawn by OMARemote, in a tab or an own window; false for FreeRDP's own window), `view` (`tab` or `window`: where it is shown now; always `window` when `tab` is false), `viewer` (process of OMARemote's own window, or null, always null for FreeRDP's window), `pid` | `bin/omaremote-session` (`list_sessions`) | the ACTIVE rows (`view` says "own window") |
| `connections.json`: `{connections: [{id, name, host, protocol, favourite, …}]}` (a bare array is accepted too), written in place | `ui/Store.qml` | the FAVOURITES rows |
| Window app id / Hyprland class `omaremote` | `ui/boot/shell.qml` (`AppId` pragma) | is OMARemote open? (autohide) |
| Release assets `omaremote-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst` on GitHub releases, x86_64 and aarch64 | `.github/workflows/release.yml` | the Install/Update button |

## What OMARemote relies on from the plugin

OMARemote's sidebar offers to install the plugin when it is missing and to update it when it has a
newer release (`omaremote-session plugin-check`, `ui/Updates.qml`). For that it relies on:

| What | Used for |
| --- | --- |
| The plugin id `rfdegroot.omaremote`, installed by Omarchy as a git checkout in `~/.config/omarchy/plugins/rfdegroot.omaremote` | installed? (`manifest.json` there) |
| `manifest.json` `version` is the released version (`0.3.0`, no `v`) | the installed version |
| Releases on GitHub tagged `v<version>`, matching that manifest version | the newest version (drafts are ignored) |
| **`main` only moves at a release** (work happens on a `dev` branch and is merged into `main` when it is released) | `omarchy plugin add` and `omarchy plugin update` take `main`'s latest commit, so the update button installs exactly the newest release |
| Installing: `omarchy plugin add https://github.com/RFdeGroot/omarchy-omaremote.git --enable`; updating: `omarchy plugin update rfdegroot.omaremote` | the two buttons, run in a floating terminal |
