# wined3d-patch

`winecx-driver-version.patch` changes `wined3d_driver_info_init()` in `dlls/wined3d/directx.c`
(the PE half). When `NOTPROTON_DRIVER_VERSION` holds a four-part version such as
`32.0.15.9541`, it replaces the driver version wined3d reports, which for a current NVIDIA GPU
is the GeForce 8 era `31.0.13.4052` (340.52). Games behind the NVIDIA identity D3DMetal is
given read it through d3d9; Deadlock (Source 2) warns of an old driver and turns off
asynchronous shader creation. Without the variable, or with a malformed value, nothing changes.
`win32u-patch` (as `35.0.15.9541`) and `nvapi-shim` report the same driver, 595.41; keep the three in step.

Build: against winecx `e0aa380` (runtime 4.7.3), in a tree configured as in
`winemac-patch/README.md`, with the tree's own rule
`make dlls/wined3d/x86_64-windows/wined3d.dll`, then `x86_64-w64-mingw32-strip --strip-debug`
(as for `ws2_32-patch`, see `docs/WINECX.md`, Own host name).

Output: `app/Sources/BridgeplayApp/Resources/wined3d-winecx-11.17.dll`, installed at
`lib/wine/x86_64-windows/wined3d.dll`, sha256
`9298c83d927b3b80d0fa36f52bb5f2ecd60ec4daffff3c93d9b080293e59dfe9`
(pinned in `FreeEngineWinecx.swift`).
