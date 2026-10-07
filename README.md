# OMARemote

A keyboard-first remote desktop client for [Omarchy](https://omarchy.org), styled after
[Flea](https://github.com/thisisgm/flea): a Quickshell UI that reuses Omarchy's own shell theme
(`/usr/share/omarchy/shell/Commons` and `Ui`), so it follows theme switches live.

RDP first, built on FreeRDP. Sessions open in **tabs** inside the app (a small native renderer,
`omaremote-rdp`, on libfreerdp), or per connection in their own `sdl-freerdp3` window, which is
the choice for multi-monitor.

## Install

```bash
./install.sh          # links bin/ and the desktop entry into ~/.local
omaremote            # or "OMARemote" from the launcher
```

Needs `quickshell`, `freerdp` (3.x), `libsecret` and `python` — all already present on Omarchy.

## Use

| Key | Action |
| --- | --- |
| `⏎` | connect (or jump to the running session) |
| `n` / `e` / `d` | new / edit / duplicate |
| `del` `del` | delete (press twice) |
| `f` | toggle favourite |
| `l` | session log (`w` warnings only, `esc` close) |
| `/` | search |
| `j` `k` / arrows | move |
| `1`–`4` | All, Favourites, Recent, Active |
| `ctrl+s` / `esc` | save / cancel in the editor |
| `ctrl+tab`, `alt+1`–`9` | switch tabs from the connections view |

Inside a session every key goes to the remote desktop, except these:

| Key | Action |
| --- | --- |
| `ctrl+alt+home` | back to the connections tab |
| `ctrl+alt+pgup` / `pgdn` | previous / next tab |
| `ctrl+alt+end` | send ctrl+alt+del |
| `ctrl+alt+⏎` | fullscreen, chrome hidden |

Closing a tab disconnects (the Windows session stays logged in). Closing the app does not:
sessions keep running and reattach as tabs when it opens again.

From a keybinding or script: `omaremote connect "Work PC"`.

## Credentials and groups

- **Credential sets** (sidebar, CREDENTIALS) hold a user name, domain and optionally a password
  (in the keyring) that any number of connections can use.
- **Group settings**: right-click a group, or its gear. A group can name a credential set and set
  any connection setting; a setting left at — is up to each connection. *Apply* makes the group's
  connections follow it now (their own values for those settings go, and they inherit its
  credentials).
- A connection's **Credentials** dropdown: *Inherited from group* (the default in a group that has
  credentials), any credential set, *Specify below* (user, domain, password, *Save credentials*),
  or *New credential set…*.
- A connection is built as defaults → group settings → its own values, and stores only what differs
  from what it inherits; settings that come from the group are marked "· group" in the editor.

## Scaling

- **Fit window** (default) sends resolution updates as the Hyprland window resizes, so the
  remote desktop always matches the tile, fullscreen or floating size, at native pixels.
- **Scale → Auto** reads the focused monitor's Hyprland scale at connect time (`hyprctl monitors`)
  and sends it to Windows as the desktop scale (`/scale-desktop`) plus the nearest device scale
  (100/140/180). Pinning a value (100–200) overrides it.
- **Fixed** asks for a set resolution and scales the image to the window (`+smart-sizing`).

## Kerberos

MIT Kerberos (what FreeRDP uses on Linux) tries every domain controller the realm lists in DNS,
one at a time, waiting a second for each UDP attempt before falling back to TCP. With dozens of
DCs behind a VPN that drops UDP, a sign-in can take a minute or more. Windows avoids this by
locating a DC in its own site.

omaremote does the equivalent at connect time: it looks up `_kerberos._tcp.<realm>`, tries all
KDCs in parallel over TCP, and keeps the three fastest (cached for 6 hours in
`~/.cache/omaremote/`, re-probed if they stop answering). FreeRDP gets a private krb5.conf with
just those, TCP only, through `KRB5_CONFIG`. `/etc/krb5.conf` is never touched.

- The realm comes from the connection's domain when it is a DNS name (`acme.lan`), otherwise from
  the host's DNS suffix. Use the full DNS domain rather than the NetBIOS name: with a short name
  like `acme`, Kerberos cannot find a realm and FreeRDP falls back to NTLM.
- **Kerberos KDC** in the editor pins specific DCs and skips discovery.
- The session card shows whether the sign-in used Kerberos or NTLM.

## Tabs

Wayland has no way to embed another program's window, so tab sessions are drawn by the app
itself. Each session is its own process, `omaremote-rdp` (`native/rdp/`), so one crashing never
takes the window or other tabs with it:

- libfreerdp renders into a shared-memory framebuffer (memfd);
- the UI attaches over a Unix socket in `$XDG_RUNTIME_DIR/omaremote/sessions/`, receives that
  framebuffer as a file descriptor plus damage rectangles, and sends input back;
- `RdpView` (`native/plugin/`, a Qt Quick item) draws it and forwards keys (Linux scancodes),
  mouse, wheel, text clipboard, and resizes with the HiDPI scale;
- certificate and credential questions are asked inside the tab.

Build it with `./install.sh` (needs cmake, ninja, a C++ compiler; Qt and FreeRDP headers come
with their Arch packages).

## How it fits together

```
ui/            Quickshell UI (boot/shell.qml is the entry; Commons/Ui link to Omarchy's shell)
bin/omaremote            launcher (opens the UI, or `connect <name>`)
bin/omaremote-session    backend: FreeRDP arguments, keyring, session supervisor
```

- Connections live in `~/.config/omaremote/connections.json`.
- Passwords are optional and live in the keyring (`secret-tool`, attributes
  `application=omaremote connection=<id>`). They reach FreeRDP over stdin
  (`/args-from:stdin`), never on the command line.
- Each session runs under a detached supervisor, so closing the manager keeps sessions open.
  State and logs live in `$XDG_RUNTIME_DIR/omaremote/sessions/`.
- Session windows have the Wayland app id `omaremote-session`, for Hyprland window rules.

## Tests

```bash
python3 -m unittest discover tests
```

## License

MIT, see [LICENSE](LICENSE).
