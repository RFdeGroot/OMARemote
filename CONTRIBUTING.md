# Contributing to OMARemote

OMARemote wants to be the remote desktop client for Omarchy, and it gets there faster with more
people using it on more networks than one. Bug reports, feature requests and pull requests are all
welcome; so is a note that it simply works for you.

## Reporting a bug

[Open an issue](https://github.com/RFdeGroot/OMARemote/issues/new/choose) with:

- `omaremote --version`, your architecture (`uname -m`), and whether you installed a release or run a
  checkout;
- what you did, what you expected, and what happened instead;
- the session log: select the connection and press `l` (or *Log* on a failed tab). Start
  `omaremote` from a terminal to see what the window itself prints.

**Before pasting a log, replace your own host names, user names and domains** (`dc01.acme.lan`,
`alex`, `ACME` will do). Logs never contain passwords, but they do contain where you connect to.

## Asking for a feature

Open an issue that says what you are trying to do and how you do it today. "Connect to a
server behind an RD Gateway with smart card login" says more than "gateway support". If it is
something another client does well, name it.

## Pull requests

Small and focused is easiest to review: one feature or fix per pull request. For anything big
(a new protocol, a new panel), open an issue first so we can agree on the shape.

### Getting started

```bash
git clone https://github.com/RFdeGroot/OMARemote.git && cd OMARemote
./install.sh                 # checks dependencies, builds native/build, links into ~/.local
omaremote
```

A checkout runs straight from its files: change a `.qml` file and restart the app (`ctrl+q`, then
`omaremote`); change anything under `native/` and run `ninja -C native/build` first. The README's
*How it works* section maps the code.

### How things are done here

- **Keyboard first.** Every action has a key, and every key lives in one table, `ui/Keymap.qml`,
  which both handles it and draws the keymap sheet (`?`). A new action gets a row there.
- **Omarchy's look.** Colours, fonts and sizes come from the live Omarchy theme through
  `ui/Theme.qml`, never hard-coded, so the app follows a theme switch. Layout and behaviour follow
  [Flea](https://github.com/thisisgm/flea), Omarchy's file manager: compact rows, quiet secondary
  text, a status bar with the keys that matter right now.
- **Sessions are processes.** Each session runs in its own process (`native/rdp`, `native/vnc`)
  and talks to the window over a socket, so a crash takes down one tab, not the app.
- **Match the code around you**: its naming, its comments (why, not what), its size.

### Before you open the pull request

- Run the tests: `python3 -m unittest discover tests`.
- For a change you can see, add a screenshot or a short recording. The app renders offscreen for
  that: `OMAREMOTE_SNAPSHOT=out.png` (with `QT_QPA_PLATFORM=offscreen`) saves the window and quits,
  and `OMAREMOTE_ACTIONS` drives it first (see `debugAction` in `ui/Body.qml`). Point
  `XDG_CONFIG_HOME` at a folder with sample connections, so your own never end up in a picture.
- Keep real host names, user names and domains out of code, tests and screenshots.
- New keys are in `ui/Keymap.qml` and the README's key tables.

By opening a pull request you agree that your contribution is released under the project's
[MIT license](LICENSE).
