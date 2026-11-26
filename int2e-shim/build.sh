#!/bin/sh
# Kompilasi int2e-shim/version.dll (x86_64 PE tanpa penanda Wine builtin agar
# dimuat sebagai native ketika diletakkan di system32 bersama override version=n,b).
set -eu
cd "$(dirname "$0")"

CC="${CC:-x86_64-w64-mingw32-gcc}"

"$CC" -O1 -shared -s -nostdlib -e DllMain \
    -fno-builtin -fno-tree-loop-distribute-patterns \
    -Wall -Wextra -Wno-unused-parameter \
    -Wl,--no-insert-timestamp \
    -Wl,--build-id=none \
    -Wl,--enable-stdcall-fixup \
    -o version.dll int2e_shim.c version.def \
    -lkernel32

shasum -a 256 version.dll
