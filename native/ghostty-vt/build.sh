#!/bin/bash
# build.sh <workdir>: builds libghostty-vt (Ghostty's terminal emulation, MIT) as a static library
# for omaremote-ssh, with the Zig it needs, both pinned by version and sha256. Prints the install
# prefix (<workdir>/stage/usr: include/ghostty, lib/libghostty-vt.a) on its last line.
#
# Downloads into <workdir>/downloads unless GHOSTTY_VT_SOURCES names a folder that has the files
# already (the PKGBUILD's makepkg sources): nothing is used before its sha256 checks out. Built
# once per version; a second run only prints the prefix. Arch's own Zig is too old (0.16), and
# libghostty-vt is not packaged, so both come from their releases.
#
# The versions and hashes are also in packaging/arch/PKGBUILD (tests/test_packaging.py keeps the
# two the same). A new version: the hashes from ziglang.org/download/index.json and from
# release.files.ghostty.org (checked against its .minisig).
set -euo pipefail

ZIG_VERSION=0.17.1
GHOSTTY_VT_VERSION=1.0.1
declare -A SHA256=(
  [zig-x86_64-linux-0.17.1.tar.xz]=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
  [zig-aarch64-linux-0.17.1.tar.xz]=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
  [libghostty-vt-1.0.1.tar.gz]=333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa
  [libghostty-vt-1.0.1-deps.tar.gz]=91a4e10960a52bf5bf4b15aa2a2cddaff8a89d6cd903d3055bda4fd17de3356d
)

[[ $# -eq 1 ]] || { echo "usage: $0 <workdir>" >&2; exit 2; }
work=$(mkdir -p "$1" && cd "$1" && pwd)
prefix=$work/stage/usr
stamp=$work/stage/built
want="zig $ZIG_VERSION, libghostty-vt $GHOSTTY_VT_VERSION"
tables=$prefix/share/ghostty-vt/nerd_font_tables.zig
if [[ -f $prefix/lib/libghostty-vt.a && -f $tables && -f $stamp && $(<"$stamp") == "$want" ]]; then
  echo "$prefix"
  exit 0
fi

case $(uname -m) in
  x86_64 | aarch64) arch=$(uname -m) ;;
  *) echo "libghostty-vt: no pinned Zig for $(uname -m)" >&2; exit 1 ;;
esac
zig_tar=zig-$arch-linux-$ZIG_VERSION.tar.xz
vt_tar=libghostty-vt-$GHOSTTY_VT_VERSION.tar.gz
deps_tar=libghostty-vt-$GHOSTTY_VT_VERSION-deps.tar.gz
declare -A URL=(
  [$zig_tar]=https://ziglang.org/download/$ZIG_VERSION/$zig_tar
  [$vt_tar]=https://release.files.ghostty.org/libghostty-vt/$GHOSTTY_VT_VERSION/$vt_tar
  [$deps_tar]=https://release.files.ghostty.org/libghostty-vt/$GHOSTTY_VT_VERSION/$deps_tar
)

# The file, from GHOSTTY_VT_SOURCES or downloaded, once its sha256 checks out.
fetch() {
  local name=$1 file
  if [[ -n ${GHOSTTY_VT_SOURCES:-} && -e $GHOSTTY_VT_SOURCES/$name ]]; then
    file=$GHOSTTY_VT_SOURCES/$name
  else
    file=$work/downloads/$name
    if [[ ! -f $file ]]; then
      mkdir -p "$work/downloads"
      echo "libghostty-vt: downloading $name" >&2
      curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 900 \
        --max-filesize $((256 << 20)) -o "$file.part" "${URL[$name]}"
      mv "$file.part" "$file"
    fi
  fi
  if [[ $(sha256sum <"$file" | cut -d' ' -f1) != "${SHA256[$name]}" ]]; then
    echo "libghostty-vt: $name does not match its sha256: not used" >&2
    [[ $file == "$work/downloads/$name" ]] && rm -f "$file"
    exit 1
  fi
  echo "$file"
}

zig_file=$(fetch "$zig_tar")
vt_file=$(fetch "$vt_tar")
deps_file=$(fetch "$deps_tar")

rm -rf "$work/src" "$work/stage"
mkdir -p "$work/src"
tar -xJf "$zig_file" -C "$work/src"
tar -xzf "$vt_file" -C "$work/src"
tar -xzf "$deps_file" -C "$work/src"

echo "libghostty-vt: building $want" >&2
# --system keeps Zig offline: the deps tarball holds every package it needs. Baseline CPU: the
# package runs on any x86_64 or aarch64, not only on the builder's.
(
  cd "$work/src/libghostty-vt-$GHOSTTY_VT_VERSION"
  ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" ZIG_LOCAL_CACHE_DIR="$work/zig-local-cache" DESTDIR="$work/stage" \
    "$work/src/zig-$arch-linux-$ZIG_VERSION/zig" build --prefix /usr \
    --system "$work/src/libghostty-vt-$GHOSTTY_VT_VERSION-deps" -Doptimize=ReleaseFast -Dcpu=baseline
) >&2
[[ -f $prefix/lib/libghostty-vt.a && -f $prefix/include/ghostty/vt.h ]] || {
  echo "libghostty-vt: the build left no lib/libghostty-vt.a or include/ghostty/vt.h" >&2; exit 1; }
# Its licence goes into the package beside OMARemote's: the library is linked in.
install -m644 "$work/src/libghostty-vt-$GHOSTTY_VT_VERSION/LICENSE" "$work/stage/LICENSE"
# Ghostty's Nerd Font glyph rules: omaremote-ssh draws icons by them (ghostty-vt/gen_nerd_font.py).
install -Dm644 "$work/src/libghostty-vt-$GHOSTTY_VT_VERSION/src/font/nerd_font_tables.zig" "$tables"
echo "$want" >"$stamp"
echo "$prefix"
