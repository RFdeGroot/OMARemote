# Code map

Where things live, so a change starts in the right file. Search by the names below
(`grep -n "function connect(" ui/Body.qml`); line numbers drift, names do not.

## Processes

```
omaremote (bin/omaremote, bash)          entry point: open, connect, toggle, quick, restart, adopt, window
 └ qs -p ui/boot  (Quickshell, QML)       the manager window: ui/Body.qml inside ui/boot/shell.qml
 └ qs -p ui/window                        a session's own or hotkey window: ui/SessionWindow.qml
omaremote-session (bin/omaremote-session, Python)
                                          every command the UI and the plugin run, and the detached
                                          supervisor that keeps one session alive
 └ omaremote-rdp / -vnc / -ssh (native/)  the session processes: a line protocol over a socket to
                                          RdpView, the frame in shared memory
```

## bin/omaremote-session (Python, one file)

Sections, in order (`# ------- <name>` lines):

| Section | What |
| --- | --- |
| store | `load_data`, `load_connections` (saved + quick), `resolve` (group inheritance), `mark_connected` |
| export, import and sync | `portable`, `merge` (guards: `LOCAL_KEYS`, `ADDRESS_KEYS`, `_signs_in_here`, tombstones), `HOST_RE`, `ID_RE` |
| keyring | secret-tool calls, labels by id |
| scaling | monitor scale, desktop scale |
| hotkey windows | `toggle`, `place_window`, `hide_window`, `terminal_tag`, `find_window`, `hypr_dispatch`, `hypr_hotkeys_sync`, `close_key` |
| files over SFTP | `browse`, `sftp_uri`, `unmount_files`, `mounted_files`, `restart_gvfs`, `files_after_session` |
| arguments | `build_args` (FreeRDP), `build_vnc_config`, `build_ssh_command`, `gateway_element`, `check_host`, `check_lines` |
| ssh keys and ~/.ssh/omaremote.conf | `ssh-keys`, the opt-in ssh config block |
| kerberos | private krb5.conf, SRV lookup (Gio.Resolver) |
| session state | the runtime state files, `list_sessions` |
| supervisor | `main()`: the command switch (`if cmd == "…"`), launching and watching a session |

Commands (`omaremote-session <cmd>`): list stop forget args export import sync pick ssh-keys
ssh-config watch-folder system-name paths view float terminal-tag summon open-window toggle place
hide close-key browse unmount mounts restart-gvfs hotkeys hypr-hotkeys fullscreen plugin-check
update-check focus monitor-scale secret, plus launch.

## ui/ (QML)

Singletons:

| File | What |
| --- | --- |
| Store.qml | connections.json: `stored`, `connections` (resolved), `quick`, trash, credential sets, groups, `write()`, `upsert`, `quickConnect`, `saveQuick` |
| Sessions.qml | the running sessions (`omaremote-session list`), `launch`, `launchInTab`, `stop`, secrets, files over SFTP |
| Sync.qml | export/import, folder sync, the file pickers |
| Hotkeys.qml | hotkey windows and the Hyprland config they write |
| Updates.qml | the update check and `omaremote-update` |
| Keymap.qml | every key binding: the one table the keys, the keymap sheet and the hints read |
| Theme.qml | colours from Omarchy (`Commons.Color`), sizes |

The manager window:

| File | What |
| --- | --- |
| Body.qml | the window: state (`filter`, `query`, `selectedId`, `currentTab`), the list (`listed`, `shownWithQuick`), keys (`Keys.onPressed` → `runAction`), tabs (`showTab`, `closeTab`, `popOut`, `adoptSession`), editing (`startNew`, `startEdit`, `saveEdit`), quick connect (`openQuick`, `quickCardConnect`, `connectQuick`), groups, the IPC handler, `debugAction` (snapshot hook) |
| Sidebar.qml, SidebarRow.qml | library filters, groups, credential sets |
| ConnectionList.qml, ConnectionRow.qml | the list and one row |
| Detail.qml | the right-hand pane of the selected connection |
| Editor.qml, GroupEditor.qml, CredentialEditor.qml | the editors |
| SessionView.qml | one session: RdpView, the sign-in/certificate prompt, the ended panel, `chord()` (ctrl+alt keys) |
| SessionWindow.qml | a session's own or hotkey window |
| TabBar.qml, PinnedList.qml, StatusBar.qml | chrome |
| SettingsPanel.qml, KeymapSheet.qml | settings, the keymap sheet (?) |
| QuickConnectCard.qml, GroupPicker.qml, AboutCard.qml | cards over the window |
| Input.qml, Check.qml, Segment.qml, ActionButton.qml, Glyph.qml, FormRow.qml | small controls (Input wraps Omarchy's TextField) |
| js/Format.js | pure helpers: `matches`, `quickSpec`, `ago`, labels |

## native/ (C++)

| Path | What |
| --- | --- |
| plugin/rdpview.cpp | the QML item drawing a session: frame, keys (`keyPressEvent`, chords for sent shortcuts), mouse, clipboard, cursor |
| rdp/main.cpp | FreeRDP client: `handle_line` (UI lines: key, mouse, clip, size), `rdp_scancode` |
| vnc/main.cpp | libvncclient client |
| ssh/main.cpp | libssh + libvterm terminal: keys, selection/copy, scrollback |
| common/link.cpp | the socket and shared-memory frame shared by all three |

Build: `ninja -C native/build`.

## Tests, tools, docs

- `python3 -m unittest discover tests`: test_session.py (the supervisor, by section), test_update.py
  (the updater), test_qml_palette.py (Commons.Color, PlainText).
- `debugAction` in Body.qml drives the UI offscreen for screenshots (OMAREMOTE_SNAPSHOT and
  OMAREMOTE_ACTIONS, read by ui/boot/shell.qml).
- docs/plugin-interface.md (the bar plugin's contract), docs/security-review.md (before every
  release), docs/releases/<tag>.md (notes prepended to a release).
