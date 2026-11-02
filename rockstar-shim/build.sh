#!/bin/sh
# Builds rockstar-shim/version.dll (x86_64 PE, no Wine builtin marker, so the copies next to
# SocialClubHelper.exe and the game load as native under version=n,b).
set -eu
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O1 -shared -s -nostdlib -e DllMain -fno-builtin \
  -fno-tree-loop-distribute-patterns -Wall -Wextra -Wno-unused-parameter \
  -Wl,--no-insert-timestamp -Wl,--build-id=none -Wl,--enable-stdcall-fixup \
  -o version.dll version_shim.c version.def -lkernel32
shasum -a 256 version.dll
