# Security review before every release

No version is tagged before the changes since the last release have been through this list. The
outcome goes into that version's release notes (`docs/releases/<tag>.md`, a "Security review"
section): what was checked, what was found and fixed, and what was left as it is and why.

```bash
git diff --stat "$(git describe --tags --abbrev=0)"..HEAD   # what is being reviewed
git diff "$(git describe --tags --abbrev=0)"..HEAD
```

Read every change against the questions below, with these three in mind: a malicious **server**
(RDP, VNC, SSH, a gateway, DNS), a malicious **sync or import file** (another system, or whoever
can write the sync folder), and **another account** on the same machine.

## Data that is not ours

- **Where can it come from?** Synced and imported connections and groups (host, name, gateway,
  KDC, group names, ids, aliases), what a server sends (errors, clipboard, titles), DNS answers,
  the GitHub API, files on disk the user did not write.
- **Does it reach a setting read line by line or comma by comma?** FreeRDP's `/args-from:stdin`
  and `/gateway:`, omaremote-vnc and omaremote-ssh's `key=value` lines, the private krb5.conf. It
  must pass `check_host` / `check_lines` / `gateway_element`, or it must be a plain value we made.
- **Does it reach a shell?** A string handed to `omarchy launch … terminal`, a Hyprland binding,
  `bash -c`: every value in it `shlex.quote`d, ids matching `ID_RE`. Prefer an argument list.
- **Does it reach a command line as an option?** A value starting with `-` (ids never do), `--`
  before positional arguments of tools that parse options (`qs ipc … call`).
- **Is it shown?** Every QML `Text` is `textFormat: Text.PlainText` (tests/test_qml_palette.py
  checks); nothing becomes HTML, links or remote images.
- **Is it opened?** `xdg-open` only on a folder we checked, never on a file a server chose.

## Credentials

- **Where do passwords go?** Only the keyring (labels by id, never names), stdin, or D-Bus. Never
  a command line, a log (`redact`), connections.json, a sync or export file, or a notification.
- **Can a synced change send them elsewhere?** A change to where a connection or group points
  (`ADDRESS_KEYS`) waits for the user when this system signs in there (`_signs_in_here`: saved
  password, credential set, group set, saved gateway password).
- **Does a new setting weaken a check?** It must not sync (`LOCAL_KEYS` / `GROUP_LOCAL_SETTINGS`, and
  `localKeys` in ui/Store.qml): certificate checks, security level, user names, keys, arguments.
- **Do copies and deletions take secrets along?** A duplicate never inherits a saved password; a
  deletion for good, the trash's purge and sync's purge clear the keyring entries.

## Command lines, files and processes

- **What do other accounts see?** `/proc/<pid>/cmdline` is world-readable: no connection name,
  host, user, domain, realm, group name, system name or error text on any command line we start,
  except the documented ones (`ssh`, `gio mount sftp://…`). tests/test_session.py's
  NothingPrivateInArgv checks the known paths; extend it for new ones.
- **Files we write:** the user's only (config 700/600, runtime 700); through symlinks, never over
  them (`write_user_file`); never a read-only file (`user_file_writable`); atomically.
- **Config we change outside our own files** (`~/.ssh/config`, `hyprland.lua`): opt-in only, backed
  up first, a marked block removed exactly, nothing written while the config reports errors, and
  undone when the change breaks it.
- **Processes:** killed by PID only, never by pattern; nothing left running by accident.

## Updates and packages

- **Signatures:** every package signed in CI, checked with gpgv before `pacman -U`; the signature
  never beside the package (pacman would check it against its own keyring).
- **Build inputs:** downloaded over HTTPS and checked against a key or checksum kept in the
  repository; no new download without that.
- **Dependencies:** a new one is in the Arch repositories, and it is in the PKGBUILD and install.sh.

## Then

- Every finding fixed gets a test that fails without the fix.
- `python3 -m unittest discover tests` passes.
- The private-names scan finds nothing (the maintainer's own list).
- The release notes say what the review covered.
