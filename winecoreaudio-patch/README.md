# winecoreaudio render buffer patch (WineCX 11.17)

`winecoreaudio.drv` set the CoreAudio device buffer to Wine's whole 10 ms period. A render
callback then regularly asked for more frames than the client had written, and
`ca_render_cb` padded the shortfall with silence, heard as crackling (Deadlock, CS2;
CodeWeavers' Deadlock tip works around it with a 96 kHz output). `winecx-render-buffer.patch`
(against winecx `e0aa380`) asks for half a period on output streams; Wine's period stays
10 ms. Capture streams are unchanged.

Verified 2026-10-12: Deadlock at 44.1 kHz no longer crackles.

Build in the tree configured as in `winemac-patch/README.md`
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`), with the runtime's own
`ntdll.so` in place of the tree's (`dlls/ntdll/ntdll.so`) and the product's deployment target:
`MACOSX_DEPLOYMENT_TARGET=26.0 make dlls/winecoreaudio.drv/winecoreaudio.so`. Without it the
toolchain defaults to its SDK (27.0) and the driver does not load on macOS 26; `make mincheck`
catches that. Then sign ad hoc under the runtime's identifier:
`codesign -f -s - -i winecoreaudio-5555494448b257546f33317180481a4e0075393b winecoreaudio.so`.
Pins: `FreeEngineWinecx.v1117.audio`, `docs/WINECX.md`, and its line in `SignedPin.swift` (the new sha256 and its hash without the signature, see `docs/WINECX.md`, Shipped binaries).
