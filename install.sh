#!/bin/bash
# Install omaremote for the current user by linking this checkout into ~/.local.
# Run with --uninstall to remove the links again.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
bin="$HOME/.local/bin"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

if [[ ${1:-} == --uninstall ]]; then
  rm -f "$bin/omaremote" "$bin/omaremote-session" "$apps/omaremote.desktop"
  echo "Removed. Saved connections stay in ~/.config/omaremote."
  exit 0
fi

for dep in qs sdl-freerdp3 secret-tool; do
  command -v "$dep" >/dev/null || { echo "missing: $dep (install quickshell, freerdp, libsecret)" >&2; exit 1; }
done

# Sessions in tabs need the native renderer (C++, libfreerdp + Qt Quick).
if command -v cmake >/dev/null && command -v ninja >/dev/null; then
  cmake -S "$src/native" -B "$src/native/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
  ninja -C "$src/native/build"
else
  echo "cmake/ninja missing: sessions will open in their own window only" >&2
fi

# Links from before the rename to OMARemote.
rm -f "$bin/oma-remote" "$bin/oma-remote-session" "$apps/oma-remote.desktop"

mkdir -p "$bin" "$apps"
ln -sfn "$src/bin/omaremote" "$bin/omaremote"
ln -sfn "$src/bin/omaremote-session" "$bin/omaremote-session"
ln -sfn "$src/share/applications/omaremote.desktop" "$apps/omaremote.desktop"
echo "Installed. Launch 'OMARemote' from the app launcher, or run: omaremote"
