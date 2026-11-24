#!/bin/sh
# Build the cabextract Bridgeplay bundles for Winetricks (most verbs unpack Microsoft
# cabinets with it, and the free WineCX and WineHQ engines don't ship one).
#
#   scripts/build-cabextract.sh [OUTPUT]
#
# Downloads cabextract 1.12 (GPL-3.0-or-later, NOTICE) at a pinned sha256, builds it arm64
# for macOS 15.0, strips it and signs it ad hoc. OUTPUT defaults to the app resource. After a
# rebuild, update the sha256 pins in PrefixTools.swift, SignedPin.swift, docs/WINECX.md and NOTICE.

set -eu

version=1.12
sha256=8f39ad5f9c076b9c62c67dea4f8649e75dcc16899a2d8122ca32ba68262cb713
url=https://www.cabextract.org.uk/cabextract-$version.tar.gz
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/app/Sources/BridgeplayApp/Resources/cabextract}

work=$(mktemp -d "${TMPDIR:-/tmp}/bridgeplay-cabextract.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

curl -fsSL -o "$work/src.tar.gz" "$url"
actual=$(shasum -a 256 "$work/src.tar.gz" | cut -d' ' -f1)
[ "$actual" = "$sha256" ] || { echo "build-cabextract: $url has sha256 $actual, expected $sha256" >&2; exit 1; }
tar -xzf "$work/src.tar.gz" -C "$work"

cd "$work/cabextract-$version"
cflags="-arch arm64 -mmacosx-version-min=15.0 -O2"
./configure -q CC=clang CFLAGS="$cflags" LDFLAGS="$cflags" >/dev/null
make -s -j"$(sysctl -n hw.ncpu)" >/dev/null
strip cabextract
codesign -f -s - -i com.bridgeplay.cabextract cabextract
cp cabextract "$out"
chmod 755 "$out"
echo "build-cabextract: wrote $out ($(shasum -a 256 "$out" | cut -d' ' -f1))"
