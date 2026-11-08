# d3d12-stub

`d3d12.dll` for the `dxmt` backend on a WineCX engine with D3DMetal (#2513). The app installs
it as `lib/notproton-backends/d3d12-stub/x86_64-windows/d3d12.dll`, and under `dxmt` the run
script copies it into the prefix's `system32` and sets `d3d12=n,b`.

DXMT has no D3D12. On a D3DMetal engine the builtin `d3d12` is Apple's, and with DXMT's
`dxgi` beside it, `D3D12CreateDevice` on DXMT's adapter reads address 0 inside
`libd3dshared.dylib`. Games that try D3D12 first crash there before they can fall back to
D3D11: RuneScape: Dragonwilds (Unreal Engine 5) and Hell Maiden (Unity 6) do.

The stub answers the way Windows does on a GPU without D3D12: `D3D12CreateDevice` returns
`DXGI_ERROR_UNSUPPORTED`, and the other exports return `E_NOINTERFACE` or `E_NOTIMPL`. Turning
`d3d12` off (`d3d12=d`) does not work: Unity delay-loads `d3d12.dll` and does not catch the
failed load (exception `0xc06d007e`). The ordinals match Windows' because Unity imports
`D3D12CreateDevice` (101) and `D3D12GetDebugInterface` (102) by ordinal.

It is 64-bit only; a 32-bit game keeps the builtin. A game whose exe imports `d3d12.dll`
statically is a D3D12 game, so the run script runs it on `d3dmetal` instead.

Build with `./build.sh` (mingw-w64). It prints the sha256, which goes into
`FreeEngineWinecx.swift` (`v1117.dxmt`) and `docs/WINECX.md`. The build is reproducible.
