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
 └ omaremote-rdp / -vnc / -ssh / -gliff  the session processes (native/): a line protocol over a socket to
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
| hotkey windows | `toggle`, `place_window` (also `fullscreen_mode`: an RDP Fullscreen window is made fullscreen or maximised), `hide_window`, `terminal_tag`, `find_window`, `hypr_dispatch`, `hypr_hotkeys_sync`, `close_key` |
| files over SFTP | `browse`, `sftp_uri`, `unmount_files`, `mounted_files`, `restart_gvfs`, `files_after_session` |
| arguments | `build_args` (FreeRDP), `build_vnc_config`, `build_ssh_command`, `build_gliff_command`, `gateway_element`, `check_host`, `check_lines` |
| ssh keys and ~/.ssh/omaremote.conf | `ssh-keys`, the opt-in ssh config block |
| import from other clients | `parse_rdp`, `parse_remmina`, `parse_1remote`, `parse_ssh_config`, `scan_foreign` (status per entry: new, here, trashed, twice, invalid), `import_foreign` (adds only) |
| kerberos | private krb5.conf, SRV lookup (Gio.Resolver) |
| session state | the runtime state files, `list_sessions` |
| supervisor | `main()`: the command switch (`if cmd == "…"`), launching and watching a session |

Commands (`omaremote-session <cmd>`): list stop forget args export import sync pick ssh-keys
import-sources import-scan import-foreign ssh-config watch-folder system-name paths view float terminal-tag summon open-window toggle place
hide close-key browse unmount mounts restart-gvfs hotkeys hypr-hotkeys fullscreen center plugin-check
update-check focus monitor-scale secret, plus launch.

## ui/ (QML)

Singletons:

| File | What |
| --- | --- |
| Store.qml | connections.json: `stored`, `connections` (resolved), `quick`, trash, credential sets, groups, `write()`, `upsert`, `quickConnect`, `saveQuick` |
| Sessions.qml | the running sessions (`omaremote-session list`), `launch`, `launchInTab`, `stop`, secrets, files over SFTP |
| Sync.qml | export/import, folder sync, the file pickers, import from other clients (`scanForeign`, `importPreview`, `applyForeign`) |
| Hotkeys.qml | hotkey windows and the Hyprland config they write |
| Updates.qml | the update check and `omaremote-update` |
| Keymap.qml | every key binding: the one table the keys, the keymap sheet and the hints read; the session keys (Settings › Keyboard: `session()`, `isHostKey`, `isSessionChord`) |
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
| SessionWindow.qml | a session's own or hotkey window; `wholeScreen` (Hyprland fullscreen: chrome hidden, the top edge slides in `connectionBar`) |
| TabBar.qml, PinnedList.qml, StatusBar.qml | chrome (StatusBar: a Gliff tab's stats, a health dot and the facts that fit, a click opens the card; words in Format.js `parseStats`/`statsParts`/`statsRows`) |
| SettingsPanel.qml, KeymapSheet.qml | settings, the keymap sheet (?) |
| QuickConnectCard.qml, GroupPicker.qml, AboutCard.qml, ImportCard.qml | cards over the window (ImportCard: what an import from another client would add) |
| Input.qml, Check.qml, Segment.qml, ActionButton.qml, Glyph.qml, FormRow.qml, ScrollHint.qml | small controls (ScrollHint: the slim scrollbar on panes that scroll; Input wraps Omarchy's TextField; every text field is an Input, which never reads the clipboard by itself: PasteGuard) |
| js/Limits.js | the most characters each kind of field takes (`maximumLength: Limits.host`); the same as `LIMITS` in omaremote-session; sources in docs/limits.md |
| js/Format.js | pure helpers: `matches`, `quickSpec`, `ago`, labels, `sessionSpec`/`isSessionChord` |

## native/ (C++)

| Path | What |
| --- | --- |
| plugin/rdpview.cpp | the QML item drawing a session: frame, keys (`keyPressEvent`, chords for sent shortcuts), mouse, clipboard (`shareClipboard`, `sendClipboard` through clipread, `MaxClipBytes` both ways), cursor |
| plugin/yuvnode.cpp, plugin/shaders/yuv.* | Gliff pictures drawn from the decoder's dmabufs: EGL import, the shader converts (BT.709, Dual420 recombined); RdpView `addSurface`, `showSurfaces`, `updatePaintNode` |
| plugin/shortcutinhibit.cpp | keyboard-shortcuts-inhibit for Gliff tabs (`captureShortcuts`, release key in rdpview.cpp `keyPressEvent`) |
| plugin/clipread.cpp | `oma::readClipboard`: the only way the UI reads the clipboard (wl-paste in its own process, size and time limits); never `QClipboard::text()` (tests/test_clipboard.py checks) |
| plugin/pasteguard.cpp | `PasteGuard.guard` (cuts a field loose from clipboard changes), `paste` (wl-paste, 16 KiB, 2 s, one line; refused whole when it does not fit `maximumLength`) |
| rdp/main.cpp | FreeRDP client: `handle_line` (UI lines: key, mouse, clip, size), `rdp_scancode` |
| rdp/gfxguard.cpp | `oma::guard_gfx`: wraps FreeRDP's RDPGFX CreateSurface (8192 a side, 2 GiB for all surfaces with their progressive tiles) and SurfaceToCache (128 MiB of cache, read back from gdi's entries); gfxguard-test.cpp = rdp-gfx-test |
| vnc/main.cpp | libvncclient client |
| ssh/main.cpp | ssh in a pty + libvterm terminal: keys, selection/copy, scrollback; `start_ssh`/`run_ssh`, a lost connection tried again (`lost_words`, `transient_words`, `wait_serving`) |
| gliff/main.cpp | Gliff client (Omarchy desktops): `ssh … gliff-server --stdio` in pipes (`start_server`, reconnect with backoff), two H.264 decoders (VA-API or CPU; `kMaxStreamW/H` = what Hello asks for, `pick_format` refuses a picture larger than its StreamConfig before FFmpeg allocates), pictures as dmabufs when the UI says `gpu 1` (`show_gpu`, `export_surface`, `release`) or converted into shared memory, UI lines to Gliff input, `send_stats` (key=value words; a Ping a second, `on_pong`, `health`: noreply / congested / latency) |
| gliff/msg.hpp, cbor.hpp | Gliff's protocol v1 by hand (gliff-proto's msg.rs/frame.rs, clipboard messages); test.cpp = gliff-proto-test, its fixtures |
| gliff/video.hpp | `convert420` / `convert444` (Dual420 recombined on the fly), BT.709 into BGRX, per damaged rectangle, OpenMP |
| gliff/seat.cpp | the session process's own Wayland connection: keymap (wl_keyboard) and clipboard (ext-data-control, `OWN_MARK`) |
| gliff/askpass.cpp | ssh's host-key question in the session view: omaremote-gliff is ssh's SSH_ASKPASS (`askpass_main`), the question goes to the session over `<socket>.askpass` (`answer_askpass` in main.cpp, `hostkey` prompt line), other questions to the system askpass; `hostkey_failure` words the failures |
| gliff/clipboard.cpp | Gliff's clipboard: lazy offers, 256 KiB chunks with acks, files into ~/.cache/omaremote/clipboard; shared only while focused |
| common/link.cpp | the socket and shared-memory frame shared by all session processes; `limit_memory` (RLIMIT_DATA `kMaxSessionData`, 4 GiB; a failed `new` exits 147) first in each main |

Build: `ninja -C native/build`.

## Tests, tools, docs

- `python3 -m unittest discover tests`: test_session.py (the supervisor, by section), test_update.py
  (the updater), test_qml_palette.py (Commons.Color, PlainText), test_paste.py (Input.qml and
  PasteGuard, offscreen through tests/qml/paste.qml; needs the native build), test_limits.py (field
  limits: UI and backend equal, every Input names one, import and sync refuse longer),
  test_quick.py (Format.quickCredential through tests/qml/format.qml), test_import.py (.rdp, Remmina,
  1Remote, ~/.ssh/config: parsers, refused values, idempotent re-import), test_gliff.py (the protocol
  against gliff-proto's fixtures via gliff-proto-test, the ssh command, exit messages; Decoder: omaremote-gliff against a fake
  gliff-server with ffmpeg-made pictures), test_memory.py (rdp-gfx-test, every session process's memory ceiling), test_session_keys.py (the session
  keys through tests/qml/sessionkeys.qml, and every chord and hint following the setting), test_clipboard.py
  (a session tab's clipboard through tests/qml/clipboard.qml against a fake session socket: wl-paste only,
  nothing when not shared, size and time limits; cursors: size limit, at most 64 kept), test_vnc.py (omaremote-vnc
  against a fake RFB server: a server stalling mid-message ends the session, an idle one is kept), test_ssh.py
  (omaremote-ssh with a stand-in ssh: a dropped connection tried again, what is never retried).
- `debugAction` in Body.qml drives the UI offscreen for screenshots (OMAREMOTE_SNAPSHOT and
  OMAREMOTE_ACTIONS, read by ui/boot/shell.qml).
- docs/plugin-interface.md (the bar plugin's contract), docs/security-review.md (before every
  release), docs/releases/<tag>.md (notes prepended to a release).
