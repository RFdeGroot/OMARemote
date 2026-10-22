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
  `localKeys` in ui/Store.qml): certificate checks, security level, user names, keys, arguments,
  and anything that signs in by itself or weakens a lock (`unlockAfter`).
- **Do copies and deletions take secrets along?** A duplicate never inherits a saved password; a
  deletion for good, the trash's purge and sync's purge clear the keyring entries.

## Command lines, files and processes

- **What do other accounts see?** `/proc/<pid>/cmdline` is world-readable: no connection name,
  host, user, domain, realm, group name, system name or error text on any command line we start,
  except the documented ones (`ssh`, a Gliff session's `ssh -G` just before it, `gio mount sftp://…`). tests/test_session.py's
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

## Lessons from past findings

Each of these was a real hole (release notes in brackets). A new feature gets the same questions.
When a finding comes in, check the whole class it belongs to, not only the reported path (0.9.3:
an audit after two sync findings in a row found six more), and add the class here.

- **Sync and import: judge a change by what a session would use, not by the fields that changed.**
  Every path that ends in a connection here goes through the same check: an edit, a move into
  another group (new, or one that gained a setting in the same file), a change to a group, a group
  deleted, a restore from the trash, a new connection. Compare through the group (`_effective()`),
  the port a session will use (a protocol change moves it), signing in here checked before *and*
  after, members in the trash counted. A new sharing switch joins `SHARING_KEYS`; a new setting that
  loosens a check joins `LOCAL_KEYS`. (0.8.2, 0.9.1, 0.9.2, 0.9.3)
- **A credential set never follows a connection it was not picked for.** New synced connections,
  imports, and a quick connect address changed to another host all drop it. (0.7.0, 0.8.0, 0.9.2)
- **Broken input is skipped, never fatal.** A value of the wrong type, a file that is not an object,
  a date far in the future: skip the entry and say so; one bad file must not stop sync or an import.
  A file we write back is never rewritten from a failed read: refuse to write until it reads (the
  window wiped a connections.json with a trailing comma on the next setting change). (0.8.3, 0.9.3,
  0.9.7)
- **Everything from a server or another program is bounded in size, count and time.** Caches have a
  cap (cursors: 64, LRU), pictures a largest side (cursors 512, desktops 8192), text a byte limit
  (clipboard 1 MiB, titles 4 KiB), files a size (sync 16 MiB), lists a length. Width × height and
  offsets are computed in 64 bits before any check, and a shared buffer is checked to be as long as
  its numbers say before it is mapped. (0.9.0, 0.9.4, 0.9.5, 0.9.7)
- **A limit per item is not a limit on the whole.** Each sync file was capped, yet a round read any
  number of them. Bound the sum too, before parsing: another system's file 4 MiB, all of them 16
  MiB, 64 files (newest first), and no folder of more than 1024 OMARemote files read at all; the
  answer the window reads whole is refused above 16 MiB, and the sync command runs under
  RLIMIT_DATA 1 GiB; our own file is read under the same 4 MiB. The same for every folder read
  whole: `list` shows the newest 256 session records, each at most 16 KiB. Nesting depth is a limit too, and
  the strictest reader sets it: `[[[[…` made json.loads raise RecursionError, which no `except
  ValueError` caught; caught, 2000 levels in a connection's unknown key still merged and broke the
  window's JSON.parse (at most 1024) on every round. Every JSON file is now refused deeper than 64
  levels, checked without recursion. (0.9.14, marketplace #12587)
- **When a finding comes in, sweep its class through the whole tree, not only the line named.**
  #12587 named sync; the sweep found the same unbounded reads in the import scan (an entry it
  refuses still carried its 400 KB fields to the window; now only a short name, and 64 MiB, 500
  files, 2000 connections and 100 problems per import), `import` of an export file (4 MiB, like
  sync), the session list, hyprctl's JSON (`capped_output`: 8 MiB and a deadline), the user's own
  configs read before a rewrite (`read_text`, strict UTF-8, 4 MiB), the walks of ~/.config/hypr and
  ~/.ssh, and the window's log view (only the session's own ordinary log). connections.json stays
  written in place (an atomic write in Quickshell 0.3.2 reloads the old text), made 0600 when new;
  .broken never written through a symlink. The release container is pinned by digest. (0.9.14)
- **A library allocating for a server is bounded before it allocates, not by what we show after.**
  The 8192 desktop check came after FFmpeg had already sized its decoder from the server's SPS, and
  FreeRDP's /gfx surfaces never met it at all. Bound what a server announces against what we asked
  for (Gliff: StreamConfig within Hello's 3840x2160), hook the library where it learns a size
  (FFmpeg's get_format, FreeRDP's CreateSurface and SurfaceToCache), and keep a process ceiling for
  what slips past (RLIMIT_DATA 4 GiB per session; a failed `new` exits 147, not a core dump). Ask of every library a server feeds: where does it allocate, and
  from which number? (0.9.12, marketplace #12352)
- **Trust questions are the user's, with the facts in front of them.** Gliff's ssh had no way to
  ask about a new host key and failed with words that read like a wrong key. It now asks through
  OMARemote (its askpass) with the fingerprint shown; ssh still decides and writes known_hosts, a
  changed key is never offered, and only "yes" after Trust is ever answered. (0.9.12)
- **Nothing waits without a deadline.** No unbounded read in the window's main thread (the clipboard
  only through `oma::readClipboard`); every read in a session process has a timeout so a server
  stopping mid-message ends the session; only ordinary files are opened (a FIFO hangs: sync files
  too); queries on a foreign database stop after a few seconds; a sync round and a clipboard owner's
  pipe have one too. (0.8.0, 0.8.3, 0.9.4, 0.9.5, 0.9.7)
- **A switch works for every protocol.** A new setting is checked in each session process (RDP, VNC,
  SSH, Gliff): VNC shared the clipboard with the switch off. Off means untouched, not just unused.
  (0.9.4)
- **Check what you open, then use what you checked.** Read checked contents from memory instead of
  opening the file by name again. A file opened later is opened from a descriptor kept since the
  check, through the *whole* path without symlinks (`openat2` with `RESOLVE_BENEATH |
  RESOLVE_NO_SYMLINKS`; `O_NOFOLLOW` covers the last part only), then `fstat`: an ordinary file
  with the device and inode that were checked. Any file read by path is a regular file first: a
  FIFO by a config's name hangs the reader (0.8.0's import; 0.9.12's Hyprland rule scan and
  known_hosts). (0.8.3, 0.9.0, 0.9.6, 0.9.12)
- **Never a fixed name in a folder others write.** A temporary file in the sync folder (or any
  shared folder) gets a random name with `O_EXCL` (`mkstemp`), then `os.replace`: a fixed name can
  be planted as a symlink to any file of the user's. The same for files two of our own processes
  rewrite: a unique temp name and a lock around read-modify-write (session records). One writer per
  file where possible (lastConnected moved out of connections.json). (0.9.7)
- **A server acts on the desktop only while its tab has the keyboard.** What a session sends for
  the clipboard waits until the view is focused and is dropped when the desktop copied since (Gliff,
  then RDP, VNC and SSH's OSC 52). (0.9.7)
- **Text that reaches a systemd unit's command line is expanded by systemd first.** Since systemd
  262, `uwsm-app` and `omarchy launch … terminal` expand `${…}` anywhere in the command line, also
  inside shell quotes, and blank names they cannot read. No `${` in a command we hand them, and
  nothing a connection holds may produce one (hosts pass HOST_RE, user names are URL-encoded).
  (plugin 0.4.11; checked for OMARemote in 0.9.7)
- **Updates only go forward, signed by our key.** The updater installs only a release newer than
  this one, and takes a signature only from the release key's fingerprint, whatever else a keyring
  holds; CI Actions are pinned by commit while the job holds the signing key. (0.9.7)
- **Nothing downloaded before it is checked is unbounded.** A package and its signature are
  fetched before gpgv sees them, the releases list before it is parsed: each has a byte cap
  (`curl --max-filesize`, which also stops a stream with no announced length; `read` up to cap + 1
  in Python) and a deadline for the whole transfer (a socket timeout is per read: a trickle never
  trips it), HTTPS only, redirects too. In CI too (the Arch Linux ARM image). (marketplace #12133;
  0.9.10) The deadline covers the status line, headers and every redirect, not only the body
  (urllib's `open()` reads those with the per-read timeout alone), and a garbled answer
  (`http.client.HTTPException`, which is no OSError) is a failure, not a traceback. (Reviewer, 0.9.11)
- **Text into a line-based file stays one line.** Log lines (read back for "connected"/"failed"),
  `~/.ssh/omaremote.conf` (a name with a line break added a `Host *` block). (0.8.0, 0.9.0)
- **A running operation keeps what it started with, or ends when that changes.** Gliff's file
  paste read the *current* offer and spool at each step: a new offer from the server mid-paste
  gave it the new file list at the old index and an empty spool path, so it wrote relative to the
  working directory. Each paste now holds its own manifest, serial and spool (as a descriptor),
  writes beneath that descriptor only (`openat2`, never a path string), and a new offer ends
  every running paste. Look for any member a later step reads that a message can replace in
  between. (0.9.13)
- **A signal goes to the process that was recorded, not to a number.** A session's record names
  its processes with their start time (`proc_start`); "alive" means that pid with that start time,
  and `stop` pins the pid (pidfd) before checking and signalling: a pid reused by another program
  after a crash is left alone. (0.9.13)
- **A log a server can make longer is capped where it is written.** The session log is in RAM
  (the runtime folder) and the log view reads it whole: `copy_log` keeps lines to 8 KiB and the
  file to 8 MiB, while every line still reaches the state parser. (0.9.13)
- **Files that are not ours alone are read through `read_text`/`read_json_file`**: one open,
  without blocking, the descriptor checked for an ordinary file, a size limit; never `isfile()`
  and then `open()`. Our own files at fixed names are written by replacing them (`write_private`,
  `write_user_file`) or created new (`O_EXCL`), never with `open(path, "w")`. (0.9.13; the
  omarchy-plugin-security skill's grep audit finds the rest of this class)

## Then

- Every finding fixed gets a test that fails without the fix.
- `python3 -m unittest discover tests` passes.
- The private-names scan finds nothing (the maintainer's own list).
- The release notes say what the review covered.
