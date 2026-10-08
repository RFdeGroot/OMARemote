#!/bin/bash
# Builds the Arch package in a clean container, against the repositories Omarchy installs from on
# this architecture, and leaves it in /src/out. Run by .github/workflows/release.yml, with the
# checkout mounted at /src: Arch Linux on x86_64, Arch Linux ARM on aarch64 (Omarchy on Apple
# Silicon runs on Arch Linux ARM's own repositories).
set -euo pipefail

case $(uname -m) in
  x86_64)
    # Omarchy's own mirror trails Arch, and a Qt plugin built against a newer Qt than the user's
    # will not load: build against what Omarchy installs (it keeps working on newer Qt).
    echo 'Server = https://stable-mirror.omarchy.org/$repo/os/$arch' > /etc/pacman.d/mirrorlist
    pacman -Syyuu --noconfirm
    ;;
  aarch64)
    # The plain Arch Linux ARM root filesystem: set up its keyring, add the build tools. Docker
    # blocks pacman's download sandbox (Landlock); Arch's own image turns it off the same way.
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
    pacman-key --init
    pacman-key --populate archlinuxarm
    pacman -Syu --noconfirm --needed base-devel
    ;;
esac
pacman -S --noconfirm --needed git cmake ninja pkgconf qt6-declarative freerdp libvncserver
pacman -Q qt6-base qt6-declarative freerdp libvncserver

useradd -m builder
install -d -o builder /home/builder/pkg
install -m644 -o builder /src/packaging/arch/PKGBUILD /home/builder/pkg/PKGBUILD
cd /home/builder/pkg
# Runtime-only dependencies (omarchy among them) are not in the distribution's repos and are not
# needed to build; the build dependencies are installed above.
sudo -u builder env PACKAGER="$PACKAGER" makepkg --nodeps
install -d /src/out
cp ./*.pkg.tar.zst /src/out/
ls -l /src/out
