#!/bin/bash
# Install OMARemote for the current user by linking this checkout into ~/.local and building the
# native tab renderers (native/build).
#
#   ./install.sh                 check dependencies, build, link
#   ./install.sh --check         only check dependencies
#   ./install.sh --install-deps  install missing packages with pacman (asks first), then install
#   ./install.sh --uninstall     remove the links (saved connections stay)
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
bin="$HOME/.local/bin"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mode="${1:-install}"

if [[ $mode == --uninstall ]]; then
  rm -f "$bin/omaremote" "$bin/omaremote-session" "$apps/omaremote.desktop" "$icons/omaremote.svg"
  echo "Removed. Saved connections stay in ~/.config/omaremote."
  exit 0
fi

# ---------------------------------------------------------------- dependencies

missing_packages=()  # Arch packages that would fix what is missing
problems=()          # one line per missing piece, grouped by what it is for

need_command() { # <what it is for> <command> <package>
  command -v "$2" >/dev/null 2>&1 && return 0
  problems+=("$1: $2 not found (package $3)")
  missing_packages+=("$3")
}

need_pkgconfig() { # <what it is for> <pkg-config module> <package>
  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "$2" && return 0
  problems+=("$1: $2 development files not found (package $3)")
  missing_packages+=("$3")
}

# The app itself.
need_command "app" qs quickshell
need_command "app" python3 python
need_command "app" secret-tool libsecret
need_command "app" hyprctl hyprland
need_command "app" stdbuf coreutils
if [[ ! -d /usr/share/omarchy/shell/Commons || ! -d /usr/share/omarchy/shell/Ui ]]; then
  problems+=("app: Omarchy's shell (/usr/share/omarchy/shell) not found: OMARemote needs Omarchy")
fi

# Building the tab renderers (RDP and VNC sessions are drawn inside the window).
need_command "build" cmake cmake
need_command "build" ninja ninja
need_command "build" g++ gcc
need_command "build" pkg-config pkgconf
need_pkgconfig "build" Qt6Quick qt6-declarative

# RDP: FreeRDP 3 (its own window, and the library behind RDP tabs).
need_command "RDP" sdl-freerdp3 freerdp
need_pkgconfig "RDP" freerdp3 freerdp
need_pkgconfig "RDP" freerdp-client3 freerdp
need_pkgconfig "RDP" winpr3 freerdp

# VNC: libvncclient (VNC tabs).
need_pkgconfig "VNC" libvncclient libvncserver

# Nice to have: a desktop notification when a session started from the command line fails.
if ! command -v notify-send >/dev/null 2>&1; then
  echo "note: notify-send not found (package libnotify): no desktop notification when a session fails" >&2
fi

# One entry per package, in the order first needed.
unique=()
for p in "${missing_packages[@]+"${missing_packages[@]}"}"; do
  [[ " ${unique[*]+"${unique[*]}"} " == *" $p "* ]] || unique+=("$p")
done

if ((${#problems[@]} > 0)); then
  echo "OMARemote is missing some dependencies:" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  if ((${#unique[@]} > 0)); then
    if [[ $mode == --install-deps ]]; then
      echo "Installing: ${unique[*]}" >&2
      sudo pacman -S --needed "${unique[@]}"
      exec "$0" install
    fi
    echo >&2
    echo "Install them with:" >&2
    echo "  sudo pacman -S --needed ${unique[*]}" >&2
    echo "or run: ./install.sh --install-deps" >&2
  fi
  exit 1
fi
echo "Dependencies: all present (app, build, RDP, VNC)."
[[ $mode == --check ]] && exit 0

# ---------------------------------------------------------------- build and link

cmake -S "$src/native" -B "$src/native/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
ninja -C "$src/native/build"

# Links from before the rename to OMARemote.
rm -f "$bin/oma-remote" "$bin/oma-remote-session" "$apps/oma-remote.desktop"

mkdir -p "$bin" "$apps" "$icons"
ln -sfn "$src/bin/omaremote" "$bin/omaremote"
ln -sfn "$src/bin/omaremote-session" "$bin/omaremote-session"
ln -sfn "$src/share/applications/omaremote.desktop" "$apps/omaremote.desktop"
ln -sfn "$src/share/icons/hicolor/scalable/apps/omaremote.svg" "$icons/omaremote.svg"
echo "Installed. Launch 'OMARemote' from the app launcher, or run: omaremote"
