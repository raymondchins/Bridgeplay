#!/bin/sh
# Builds d3d12-stub/d3d12.dll (x86_64 PE, no Wine builtin marker, so the prefix copy loads
# as native under d3d12=n,b).
set -eu
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -shared -s -nostdlib -e DllMain -Wall -Wextra -Wno-unused-parameter \
  -Wl,--no-insert-timestamp -Wl,--build-id=none \
  -o d3d12.dll d3d12_stub.c d3d12.def
shasum -a 256 d3d12.dll
