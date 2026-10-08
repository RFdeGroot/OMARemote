# OMARemote

A keyboard-first remote desktop client for [Omarchy](https://omarchy.org), styled after
[Flea](https://github.com/thisisgm/flea): a Quickshell UI built from Omarchy's own shell components
(`/usr/share/omarchy/shell/Commons` and `Ui`), so it follows your theme, live.

- **RDP** through FreeRDP and **VNC** through libvncclient.
- **Sessions in tabs** inside the app, or (RDP) in their own window for multi-monitor; pin the
  connections list beside them and the remote desktop resizes to fit.
- **HiDPI scaling** that follows Hyprland: the remote desktop matches the tab's size and your scale.
- **Credential sets** shared between hosts, and **group settings** that connections inherit.
- **Fast Kerberos** on networks with many domain controllers.
- **Keyboard-driven**, with a keymap sheet on `?`; the mouse works everywhere too.
- Passwords optional, in your keyring; sessions survive closing the window.

## Install

```bash
git clone https://github.com/RFdeGroot/OMARemote.git && cd OMARemote
./install.sh                 # checks dependencies, builds the tab renderers, links into ~/.local
omaremote                    # or "OMARemote" from the launcher
```

The installer checks everything first and lists what is missing, grouped by what needs it, with
the packages to install:

| For | Needs (Arch package) |
| --- | --- |
| the app | `quickshell`, `python`, `libsecret`, `hyprland`, Omarchy's shell |
| building the tab renderers | `cmake`, `ninja`, `gcc`, `pkgconf`, `qt6-declarative` |
| RDP | `freerdp` (3.x) |
| VNC | `libvncserver` (for libvncclient) |
| optional | `libnotify` (a notification when a session fails) |

`./install.sh --install-deps` installs the missing packages with pacman (it asks first),
`./install.sh --check` only checks, and `./install.sh --uninstall` removes the links (your
connections stay in `~/.config/omaremote`).

## Use

Everything works from the keyboard. Press **`?`** (or **F1**; **Ctrl+Alt+K** inside a session) for
the keymap sheet with every binding, grouped. Type to filter it and press ⏎ to run the highlighted
action. The status bar always shows the keys for where you are.

The most used:

| Key | Action |
| --- | --- |
| `⏎` | connect, or switch to the connection's running session |
| `j` `k` / arrows | move through the list |
| `n` / `e` / `d` | new / edit / duplicate connection |
| `del` `del` | delete (press twice) |
| `f` | toggle favourite |
| `s` | settings of the connection's group |
| `c` | new credential set |
| `l` | log of the last session (`w` warnings only, `esc` close) |
| `/` | search |
| `1`–`4` | All, Favourites, Recent, Active |
| `tab` | move to the sidebar (`j` `k`, `⏎` open, `s` group settings, `esc` back) |
| `ctrl+tab`, `alt+1`–`9` | switch tabs |
| `p` | pin the connections list beside session tabs |
| `ctrl+s` / `esc` | save / cancel in an editor; `tab` walks every field |

Inside a session every key goes to the remote desktop, except these:

| Key | Action |
| --- | --- |
| `ctrl+alt+home` | back to the connections tab |
| `ctrl+alt+pgup` / `pgdn` | previous / next tab |
| `ctrl+alt+end` | send ctrl+alt+del |
| `ctrl+alt+⏎` | fullscreen, chrome hidden |
| `ctrl+alt+p` | pin or unpin the connections list |
| `ctrl+alt+k` | keymap sheet |

**Pinning** (`p`, `ctrl+alt+p` or the pin in the tab strip) docks the connections on the left of
every session tab, in the sidebar's style: running sessions under *Active*, the rest under their
groups, always all of them whatever the connections tab is searching. The session gives up that
width, and a desktop that follows its tab resizes to the room left; unpin and it grows back to the
full width. Click a running connection to switch to it, double-click any to connect. The choice is
remembered.

Closing a tab disconnects (a Windows session stays logged in). Closing the app does not: sessions
keep running and come back as tabs when it opens again.

From a keybinding or script: `omaremote connect "Work PC"`.

## Credentials and groups

- **All connections** lists them under their group headings once any group exists, favourites first
  within each group, and those without a group under OTHER. A search, and the other views, list
  them flat.
- **Credential sets** (sidebar, CREDENTIALS) hold a user name, domain and optionally a password
  (in the keyring) that any number of connections can use.
- **Group settings**: right-click a group, click its gear, or press `s`. A group can name a
  credential set and set any connection setting; a setting left at — is up to each connection.
  *Apply* makes the group's connections follow it now (their own values for those settings go, and
  they inherit its credentials).
- A connection's **Credentials** dropdown: *Inherited from group* (the default in a group that has
  credentials), any credential set, *Specify below* (user, domain, password, *Save credentials*),
  or *New credential set…*.
- A connection is built as defaults → group settings → its own values, and stores only what differs
  from what it inherits; settings that come from the group are marked "· group" in the editor.

## RDP

### Scaling

- **Fit window** (default) sends resolution updates as the tab or window resizes, so the remote
  desktop always matches it, at native pixels.
- **Scale → Auto** uses Hyprland's scale for the focused monitor (`hyprctl monitors`) and sends it
  to Windows as the desktop scale plus the nearest device scale (100/140/180). Pinning a value
  (100–200) overrides it.
- **Fixed** asks for a set resolution and scales the picture to fit.
- **Open in: Own window** runs `sdl-freerdp3` instead of a tab, which also covers *All monitors*.

### Kerberos

MIT Kerberos (what FreeRDP uses on Linux) tries every domain controller the realm lists in DNS,
one at a time, waiting a second for each UDP attempt before falling back to TCP. With dozens of
DCs behind a VPN that drops UDP, a sign-in can take a minute or more. Windows avoids this by
locating a DC in its own site.

OMARemote does the equivalent at connect time: it looks up `_kerberos._tcp.<realm>`, tries all
KDCs in parallel over TCP, and keeps the three fastest (cached for 6 hours in
`~/.cache/omaremote/`, re-probed if they stop answering). FreeRDP gets a private krb5.conf with
just those, TCP only, through `KRB5_CONFIG`. `/etc/krb5.conf` is never touched.

- The realm comes from the connection's domain when it is a DNS name (`acme.lan`), otherwise from
  the host's DNS suffix. A NetBIOS domain (`acme`) that matches the host's DNS domain is signed in
  as that DNS domain (`acme.lan`), so Kerberos still works; NTLM accepts either.
- **Kerberos KDC** in the editor pins specific DCs and skips discovery.
- The session card shows whether the sign-in used Kerberos or NTLM.

## VNC

Pick **VNC** as a connection's protocol (port 5900 by default). VNC sessions always open in a tab.
They sign in with a VNC password, or a user name and password for servers that ask for one
(VeNCrypt, Apple Remote Desktop); either can come from a credential set or be asked inside the tab.

- **Scaling**: *Fit window* scales the remote screen to the tab, *Native pixels* shows it pixel for
  pixel, *Resize remote* asks the server to match the tab's size (servers with ExtendedDesktopSize,
  such as TigerVNC, wayvnc and libvncserver-based ones).
- **Quality**: *Auto* (Tight with JPEG), *High* (lossless ZRLE), *Low* (strong compression).
- **View only** watches without sending keyboard or mouse input.
- Clipboard text goes both ways (UTF-8 where the server supports it), and the server's cursor is
  drawn locally. Keys are sent as X keysyms, so the server's own keyboard layout applies.

## How it works

```
ui/                      Quickshell UI (boot/shell.qml is the entry; Commons/Ui link to Omarchy's shell)
bin/omaremote            launcher: opens the UI, or `connect <name>`
bin/omaremote-session    backend: session settings, keyring, Kerberos discovery, session supervisor
native/rdp/              omaremote-rdp: an RDP session for a tab (libfreerdp)
native/vnc/              omaremote-vnc: a VNC session for a tab (libvncclient)
native/common/           the link both share with the UI
native/plugin/           RdpView, the Qt Quick item that shows a session in a tab
```

**Tabs.** Wayland has no way to embed another program's window, so the app draws sessions itself.
Each session is its own process, so one crashing never takes the window or other tabs with it:

- libfreerdp or libvncclient renders into a shared-memory framebuffer (memfd);
- the UI attaches over a Unix socket in `$XDG_RUNTIME_DIR/omaremote/sessions/`, receives that
  framebuffer as a file descriptor plus damage rectangles, and sends input back: keys (scancodes
  for RDP, keysyms for VNC), mouse, wheel, text clipboard, and resizes with the HiDPI scale;
- certificate and credential questions are asked inside the tab.

**Sessions** run under a detached supervisor, so closing the window keeps them open. State and logs
live in `$XDG_RUNTIME_DIR/omaremote/sessions/`; RDP sessions in their own window have the Wayland
app id `omaremote-session`, for Hyprland window rules.

**Data.** Connections, credential sets, group settings and whether the list is pinned live in
`~/.config/omaremote/connections.json`. Passwords are optional and live in the keyring
(`secret-tool`, attributes `application=omaremote` plus `connection=<id>` or `credential=<id>`).
They reach the session process over stdin, never on the command line.

**Keys** come from one table, `ui/Keymap.qml`, which both handles them and draws the keymap sheet.

## Tests

```bash
python3 -m unittest discover tests
```

## License

MIT, see [LICENSE](LICENSE).
