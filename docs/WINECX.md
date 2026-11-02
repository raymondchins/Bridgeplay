# WineCX engine

Bridgeplay's second free engine. WineCX is CodeWeavers' open-source (LGPL) CrossOver 26.3
Wine changes, rebased by dappermint onto upstream Wine
([dappermint/winecx](https://github.com/dappermint/winecx)). It is built in CI into a Whisky
runtime by [dappermint/winecx-gptk](https://github.com/dappermint/winecx-gptk).

Two releases are pinned side by side (`FreeEngineWinecx.releases`):

| Build | Runtime | winecx | Wine | Tool | Bundle |
|---|---|---|---|---|---|
| `winecx-11.17` (current) | 4.7.3 | `e0aa380` | 11.17 | `bridgeplay-winecx-11.17` | `WineCX 11.17.app` |
| `winecx-11.15` | 4.5.125 | `5b45f45` | 11.15 | `bridgeplay-winecx` | `WineCX 11.15.app` |

The WineCX row installs the current one. Each release is its own runner build with its own
pins, ntdll detours and Steam tool. `bridgeplay-winecx` stays on 11.15: every existing prefix's
build record (`notproton-build`) names `winecx-11.15`, and `refuse_other_build` in
`compat_run.sh` refuses a prefix claimed by another build, so moving the default tool would
stop every WineCX game until its prefix is rebuilt. 11.17 is picked per game as "WineCX 11.17"
(`bridgeplay-winecx-11.17`), on a rebuilt prefix.

4.7.3 over 4.5.125: msync fixes (wake one waiter, skip wake syscalls nobody waits on, sleep
instead of spinning while a wait registers, unregister on contention), kernelbase
`FlsGetValue2` for Unity 6000.3, dxgi `CheckInterfaceSupport` for `IDXGIDevice`, winemac no
longer hiding the client view on a window-surface flush, win32u reporting the adapter
D3DMetal was told to use, and the Wine 11.16 and 11.17 merges.

Compared with the WineHQ 11.15 engine it adds:

- **msync**, CrossOver's Mach-port synchronisation (`WINEMSYNC=1`), which cuts the wineserver
  round trips that slow down CPU-heavy games.
- **D3DMetal support** through CrossOver's hooks (winemac `macdrv_functions`, the
  `libd3dshared` non-native code regions in ntdll, and the d3dkmt answers). This only works
  with Apple's Game Porting Toolkit: the one-click installer ships its redistributables
  under Apple's non-commercial license ([GPTK-LICENSE.md](GPTK-LICENSE.md)). The app links
  that copy or one you install yourself, and never downloads it.
- **DXMT master and DXVK-macOS 1.10.3** as backends a game opts into. DXMT is the same
  `e94c312` build as the WineHQ engine ([DXMT.md](DXMT.md)), not the archive's 0.80. The
  builtin Direct3D is Wine's own, or D3DMetal once a Game Porting Toolkit is linked.

In Bridgeplay the current build is `winecx-11.17`, tool `bridgeplay-winecx-11.17`, shown as
"WineCX 11.17 (msync, D3DMetal)". Like the WineHQ engine it needs no CrossOver license. The licence check
treats it as free only because the loader hash matches the pinned one, so a CrossOver install
can never pass as it.

## Artifact

### 4.7.3 (current)

| | |
|---|---|
| File | `Libraries.tar.gz`, 461,131,598 bytes |
| URL | https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3/Libraries.tar.gz |
| sha256 | `a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331` |
| Source | winecx `e0aa380780b73e20fabcfe78fd42713b94929a53`, built by winecx-gptk `0bf3eabc2f0d95154282eb86b11205cbbaae6c65` |
| Base | Wine 11.17 (`VERSION`) |
| Arch, target | x86_64 only, minos 26.0, same layout as 4.5.125 |

No Whisky mirror carries 4.7.3, so the only base is the winecx-gptk release. Its DXVK
repack is byte-identical to 4.5.125's.

### 4.5.125

| | |
|---|---|
| File | `Libraries.tar.gz`, 461,224,571 bytes |
| URL | https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.5.125/Libraries.tar.gz |
| Mirror | https://github.com/dappermint/Whisky/releases/download/v4.5.125/Libraries.tar.gz (same bytes, the copy Whisky downloads) |
| sha256 | `6db83765d9bd9d9941cacf8e09d2b8a3014738305ca4672d2188f3e6e51fae87` |
| Source | winecx `5b45f4564c4f87fa9c0f958733a5e9bb3918a058` (the tip of `wine1115`), built by winecx-gptk `7a0349b26a04081497ae494027cf69d1a4eeb10c` |
| Base | Wine 11.15 (`VERSION`), the same Wine the bridge components are built against |
| Arch | x86_64 only (Rosetta). PE halves for x86_64 and i386, no arm64/arm64EC |
| Deployment target | minos 26.0 |

Runtime 4.5.125 is the last build on the 11.15 base. Later runtimes (4.6.x, 4.7.x) are
Wine 11.16 and 11.17. It was chosen over frankea/Whisky's
[v4.5.105-beta.1](https://github.com/frankea/Whisky/releases/tag/v4.5.105-beta.1)
(winecx `c2cce0e`) because it carries the msync fixes from 2026-08-21: sleeping instead of
spinning while a wait registers, single-waiter wakeups, and skipping wake syscalls nobody is
waiting on.

Layout inside the archive: `Libraries/Wine` is the Wine tree (`bin/`, `lib/wine/{x86_64-unix,
x86_64-windows,i386-windows}`, bundled dylibs in `lib/`, `share/wine` with wine-mono 11.2.0
and gecko). `Libraries/DXMT/{x64,x32}` holds DXMT 0.80's frontends with the builtin marker
stripped, which Bridgeplay does not use. `Libraries/DXVK/{x64,x32}` holds DXVK. A 0.80-era
`winemetal` is a builtin in `lib/wine`, which Bridgeplay replaces.

## What Bridgeplay lays out

The engine root (`…/WineCX 11.17.app/Contents/SharedSupport/CrossOver`, cloned into the runner
`runners/crossover-winecx-11.17`; likewise for 11.15) is the archive's `Libraries/Wine`, plus:

```
.notproton-msync                                  engine supports msync
lib/wine/x86_64-unix/winemetal.so                 DXMT master, replacing the archive's
lib/wine/{x86_64,i386}-windows/winemetal.dll      DXMT master, replacing the archive's
lib/notproton-backends/dxmt/{x86_64,i386}-windows/{d3d11,d3d10core,dxgi}.dll   DXMT master, marker stripped
lib/notproton-backends/dxvk/{x86_64,i386}-windows/{d3d11,d3d10core}.dll        from the archive
lib/wine/x86_64-unix/winemac.so                   Retina fix, replacing the archive's (below)
lib/wine/x86_64-unix/winebus.so                   built with SDL2, replacing the archive's (Controllers)
lib/wine/x86_64-windows/winebus.sys               11.17 only: map-key fix, replacing the archive's (Controllers)
lib/wine/x86_64-windows/ws2_32.dll                11.17 only: own host name without loopback, replacing the archive's (Own host name)
lib/wine/x86_64-windows/kernel{32,base}.dll       11.17 only: GetProcAddress can hide ntdll's wine_* exports, replacing the archive's (Hidden Wine exports)
lib/wine/{x86_64,i386}-windows/d3dx11_4{2,3}.dll  11.17 only: D3DX11CreateThreadPump stub, replacing the archive's (D3DX11 thread pump)
lib/libSDL2-2.0.0.dylib                           SDL 2.32.10, x86_64, for winebus.so (Controllers)
```

DXMT comes from `dxmt-e94c312.tar.gz` (the WineHQ engine's pin, shared download cache).
`winemetal.so` and both `winemetal.dll` files are replaced together, since they share one unix-call
table and never mix with 0.80. The D3D DLLs get the 16 bytes of the Wine builtin marker at
0x40 overwritten with a DOS stub, the same bytes winecx-gptk writes, so they load as natives
from a prefix: Wine swaps a marked DLL found in a prefix for the `lib/wine` builtin of the
same name (`load_builtin`, `dlls/ntdll/unix/loader.c`). Each is pinned before and after.
nvapi64, nvngx and the WIP `d3d12.dll` are left out. The DXVK repack has no `dxgi.dll`.
Every file is pinned by sha256 (`FreeEngineWinecx.expectedFiles`); a pin change makes an
installed engine show "Update & Set Up".

DXMT on this engine does **not** need `winemac-patch/`. winecx's `winemac.so` already exports
`_macdrv_functions` (`dlls/winemac.drv/d3dmetal.c`), and the table DXMT reads is unchanged
between 0.80 and master.

The engine's `winemac.so` is still replaced, for D3DMetal: winecx's own let D3DMetal size a
swapchain from its view's frame in points, so with High Resolution (Retina) on, a game got a
half-size drawable and showed only the top-left quarter, and a `ResizeBuffers` from
`WM_SIZE` read the view's frame before it had followed the window, so the swapchain kept
its old size (Ravenswatch: 3024x1752 stretched over a 3024x1964 screen). Bridgeplay installs
`winemac-winecx-<build>.so`, built from winecx `e0aa380` with
`winemac-patch/winecx-11.17-d3dmetal-retina.patch` (11.17) or from `5b45f45` with
`winemac-patch/winecx-d3dmetal-retina.patch` (11.15), see `winemac-patch/README.md`, pinned as
each release's `macDriver`.

## Controllers

The runtime's CI built `winebus.so` without SDL2 (`SONAME_LIBSDL2` undefined, its log says
`sdl_bus_init SDL support not compiled in!`), and its XBOX bus needs `IOUSBLib.h`, which the
macOS 26 SDK lacks. A gamepad then had no path into Wine: winebus ignores the IOHID bus's raw
HID device for a gamepad unless that device has `Hidraw=1`, and with it the pad comes in as
`is_hidraw 1, is_gamepad 0`, which XInput never opens.

Bridgeplay installs `winebus-winecx-<build>.so`: that winecx tree's own, built with
`SONAME_LIBSDL2` = `libSDL2-2.0.0.dylib`, the name the WineHQ engine's `winebus.so` dlopens.
SDL's bus then presents the pad as a gamepad (`is_gamepad 1`), the device XInput opens.
dyld resolves the leaf name through the caller's `LC_RPATH`s, and `winebus.so` carries
`@loader_path/../../` (the CI adds it to every unix module), so the library sits in `lib/`.
That `libSDL2-2.0.0.dylib` is SDL 2.32.10 (zlib license, `NOTICE`) with
`winemac-patch/sdl2-iokit-gamepad-collection.patch`, signed ad hoc: a SwiftPM release build
runs `strip` on every unsigned Mach-O resource, which would change its bytes and break the
pin. To rebuild it, apply the patch to the release tarball (strip the `/private/tmp/...`
prefix from its paths, `patch -p0`), then
`cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DSDL_STATIC=OFF -DSDL_TEST=OFF`,
build, and `codesign -fs -`. The result exports the same 837 symbols and links the same
frameworks as the 2.32.8 build it replaced. The PE half `winebus.sys` is unchanged: it starts the SDL bus
either way, and only the unix half lacked it.

A per-device `Hidraw=1` under `HKLM\System\CurrentControlSet\Services\winebus\Devices\<vid>/<pid>`
makes winebus take the raw IOHID device and ignore SDL's for that pad, so XInput loses it
again; leave that key off for XInput pads.

To rebuild it, in the configured winecx build tree from `winemac-patch/README.md` (same
flags, `MACOSX_DEPLOYMENT_TARGET=26.0`), compile the unix objects of
`dlls/winebus.sys/winebus.so` with `-DSONAME_LIBSDL2=\"libSDL2-2.0.0.dylib\"` added to
`CFLAGS` and SDL2 2.32 headers on the include path (`SDL2_CFLAGS`; only `bus_sdl.o`
changes), then link and sign the way the runtime's was:

    clang -arch x86_64 -o winebus.so -dynamiclib -install_name @rpath/winebus.so \
      -Wl,-rpath,@loader_path/ dlls/winebus.sys/{bus_iohid,bus_sdl,bus_udev,bus_xbox360,hid,unixlib}.o \
      <runtime>/ntdll.so -framework IOKit -framework CoreFoundation
    codesign -fs - winebus.so
    install_name_tool -add_rpath @loader_path/../../ winebus.so
    codesign -fs - winebus.so

Built this way without the define, the result matches the runtime's `winebus.so` in every
section and in all 171 symbols and their addresses, with the same load commands in the same
order; only `__LINKEDIT`, the UUID and the linker's tool version differ. For 11.17 the same
recipe without the define reproduces the runtime's `winebus.so` in every section, symbol and
load command. The pins are each release's `gamepad`.

The PE half's `sdl_bus_load_mappings` (`dlls/winebus.sys/main.c`) stored each mapping at
`mappings[count]` after `count++`, so it wrote one slot past the string it had just allocated,
and terminated `mappings[len]` instead of the string. Any `map` value under the winebus key
then corrupted the heap and took winebus, and every pad, down. Wine master still has it
(checked 2026-10-10). 11.17 ships `winebus-winecx-11.17.sys`, built from `e0aa380` with
`winebus-patch/winecx-sdl-mappings.patch` by the tree's own rule (mingw-w64 gcc, then
`x86_64-w64-mingw32-strip --strip-debug` as the CI does). Built without the patch, the result
is byte-identical to the runtime's `winebus.sys` except the PE timestamp, checksum and build
id. 11.15 keeps the runtime's own `winebus.sys`, so the `map` key is still unsafe there.

## Own host name

macOS resolves the machine's own name (`gethostname()`, `<name>.local`) to lo0's addresses
first: `getaddrinfo` in a Windows program returned `::1`, `fe80::1`, `127.0.0.1`, `127.0.2.2`,
`127.0.2.3`, then the LAN address. Windows never returns loopback for its own name. TEKKEN 8's
online SDK takes the first result as its local IP and ranked matchmaking hangs; a hand-made
`/etc/hosts` line for the LAN address fixed it, but that pins a DHCP address.

11.17 ships `ws2_32-winecx-11.17.dll` as `lib/wine/x86_64-windows/ws2_32.dll`: winecx
`e0aa380`'s PE half with `ws2_32-patch/winecx-own-hostname.patch`. For the own host name
(case-insensitive, with or without `.local`, or its first label, and `""`) `getaddrinfo`, and
through it `GetAddrInfoW` and `GetAddrInfoExW`, drops loopback and IPv6 link-local results
while a routable one remains, keeping the order (`ws2_32-patch/README.md`). `localhost` and
`NULL` still return loopback, as on Windows. The unix half is unchanged. The pin is the
release's `network`.

Built by the tree's own rule in a tree configured as in `winemac-patch/README.md` (mingw-w64
gcc 16.2, `make dlls/ws2_32/x86_64-windows/ws2_32.dll`), then
`x86_64-w64-mingw32-strip --strip-debug` as the CI does. Built without the patch, every section
is byte-identical to the runtime's `ws2_32.dll`; only the PE timestamp, checksum and build id
differ, and the runtime's `.eh_frame` section name is cut to `.eh_fram` (10 bytes of string
table). 11.15 keeps the runtime's own `ws2_32.dll`, so it still answers loopback first.

## Hidden Wine exports

Some games turn features off once `GetProcAddress(ntdll, "wine_get_version")` answers. The
Witcher 3 5.0 then never calls `slInit`: Streamline logs only `SL not initialized or no plugins
found` and the game offers FSR and XeSS but no DLSS. Wine Staging's `HideWineExports` covers
this; WineCX has no equivalent.

11.17 ships `kernel32-winecx-11.17.dll` and `kernelbase-winecx-11.17.dll` as
`lib/wine/x86_64-windows/kernel32.dll` and `kernelbase.dll`: winecx `e0aa380`'s PE halves with
`hide-wine-exports-patch/winecx-hide-wine-exports.patch`. With `NOTPROTON_HIDE_WINE_EXPORTS`
set (gamefix key `HIDE_WINE_EXPORTS=1`), both `GetProcAddress` copies fail a lookup by name of
an ntdll export starting with `wine_`. `__wine_*` stays, since every builtin's
`__wine_init_unix_call` needs it. Without the variable they behave as the runtime's.
Built and pinned as in `hide-wine-exports-patch/README.md`; the pins are the release's
`loader`. 11.15 keeps the runtime's own.

## D3DX11 thread pump

Wine's `d3dx11_43` and `d3dx11_42` declare `D3DX11CreateThreadPump` as a spec stub, so a game
that imports it (Persona 4 Golden) dies at the first call with
`unimplemented function d3dx11_43.dll.D3DX11CreateThreadPump` (Wine bug 56176). Wine master
still has the stub (checked 2026-10-22); MR 6654 (closed, not merged) added an `E_NOTIMPL`
stub, MR 5357 (open) a fuller thread pump.

11.17 ships `d3dx11_43-winecx-11.17{,-i386}.dll` and `d3dx11_42-winecx-11.17{,-i386}.dll` as
`lib/wine/{x86_64,i386}-windows/d3dx11_4{3,2}.dll`: winecx `e0aa380`'s PE halves with
`d3dx11-patch/winecx-create-thread-pump.patch`, MR 6654's change, which returns `E_NOTIMPL`.
`d3dx11_42` forwards to `d3dx11_43` (`-import`), so both are rebuilt and ship together. The
pins are the release's `d3dx`.

Built in a tree configured as in `winemac-patch/README.md` but with
`--enable-archs=i386,x86_64` (mingw-w64 gcc 16.2 for both), brew's bison on `PATH` for `make`
too, `make dlls/d3dx11_4{3,2}/{x86_64,i386}-windows/d3dx11_4{3,2}.dll`, then
`{x86_64,i686}-w64-mingw32-strip --strip-debug`. Built without the patch, every section of
all four is byte-identical to the runtime's; only the build id differs and the runtime's
`.eh_frame` name is cut to `.eh_fram`. 11.15 keeps the runtime's own.

## D3DMetal: the builtin model

Apple's forwarders only work as builtins: only a builtin gets its unix half
(`get_builtin_unix_funcs`), and Wine searches its own `lib/wine` before any `WINEDLLPATH`
entry, swapping a marked copy in a prefix for the `lib/wine` builtin. So, as Whisky does,
a linked Game Porting Toolkit *becomes* the engine's Direct3D builtins:

```
lib/wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll  -> <gptk>/wine/x86_64-windows/<name>
lib/wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so      -> <gptk>/wine/x86_64-unix/<name>.so
                                                         (or <gptk>/external/libd3dshared.dylib
                                                         when the GPTK has no unix folder)
lib/wine/x86_64-{windows,unix}/nvapi64.{dll,so}       -> <gptk>, when the GPTK has it
lib/wine/x86_64-{windows,unix}/nvapi.{dll,so}         -> <gptk>/…/nvapi64.*, the internal name Wine finds Apple's nvapi64 by
lib/external/{D3DMetal.framework,libd3dshared.dylib}  -> <gptk>/external/
lib/notproton-backends/wine-stock/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll  Wine's originals
lib/notproton-backends/d3dmetal.enabled
```

**Link** (`WinecxD3DMetal.link`): each of Wine's four DLLs is checked against its pin
(`FreeEngineWinecx.current.d3dStock`) and moved, not copied, into `wine-stock`. A DLL that
does not match refuses the link. Then the symlinks are created, every link is checked to
resolve, and `d3dmetal.enabled` is written last. Nothing of Apple's is copied. A failure at
any step runs unlink.

**Unlink** (`WinecxD3DMetal.unlink`): the marker goes first, then only symlinks are removed,
and Wine's originals are moved back from `wine-stock`, byte for byte. A real file is never
deleted. `lib/external` keeps winecx's `README`.

The engine passes its layout check in exactly two states: stock (Wine's four DLLs in
`lib/wine` under their pins, no `wine-stock`, no `.so` for them, no marker) or linked (the
marker, symlinks in `lib/wine` and `lib/external`, Wine's four intact in `wine-stock`).
Anything else makes the engine show "Update & Set Up". A Game Porting Toolkit that was moved
or deleted leaves the linked shape with dangling links: the Status page then shows it as not
found, and Rescan unlinks.

Linking happens when the engine is installed (before the runner is cloned from it, so the
runner carries the same links) and when you press **Rescan**, which relinks or unlinks both
the engine and `runners/crossover-winecx-11.15`. It refuses while a game is running. The
32-bit side is untouched: D3DMetal has no i386 half.

`d3dmetal.enabled` is a `key=value` file: `source=` (the GPTK `lib` folder), `version=`
(D3DMetal.framework's version), `libd3dshared=lib/external/libd3dshared.dylib` (exported as
`CX_APPLEGPTK_LIBD3DSHARED_PATH`, relative to `CX_ROOT`) and `model=builtin`.

What `compat_run.sh` does with it is in [GAMEFIXES.md](GAMEFIXES.md#winecx-with-d3dmetal):
`d3dmetal` becomes the default and the D3D12 choice, `wined3d` runs `d3dmetal`, and `dxmt`
and `dxvk` still work per game as natives.

`nvngx-on-metalfx.dll` is linked as `nvngx.dll` (and its unix half as `nvngx.so`), the
name CrossOver gives it when it copies it into each prefix. The prefix's placeholder
`nvngx.dll` then resolves to it, and the prefix gets `HKLM\Software\NVIDIA Corporation\Global\NGXCore`
`FullPath=C:\Windows\System32` so the game's NGX loader finds it. Apple's `nvapi64` and
`nvngx` are linked but disabled per game unless its conf says `NVAPI=1`. With both on and
`D3DM_ENABLE_METALFX=1`, games show DLSS and D3DMetal serves it with MetalFX.

## Using D3DMetal with your own Game Porting Toolkit

Apple's licence does not let Bridgeplay redistribute D3DMetal, so you supply it:

1. Download the Game Porting Toolkit from Apple:
   https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit (free Apple
   developer account).
2. Open the disk image ("Evaluation environment for Windows games").
3. Copy the **contents of its `redist/lib` folder** into
   `~/Library/Application Support/bridgeplay/gptk/`, so you end up with `gptk/external/` and
   `gptk/wine/`.
4. In Bridgeplay's Status page, press **Rescan** on the "Game Porting Toolkit" row. It turns
   green with "Linked from <path>." If the WineCX engine is not installed yet, "Download & Set
   Up" on the "WineCX Engine" row links it during setup.

Bridgeplay looks in this order and links the first complete copy: that folder (the
`redist` folder itself, or the whole volume, is also accepted), then
`/Applications/Game Porting Toolkit.app` (`brew install --cask gcenx/wine/game-porting-toolkit`,
which keeps it in `Contents/Resources/wine/lib`), then `~/Applications/Game Porting Toolkit.app`.

A copy counts only when `external/libd3dshared.dylib`, `external/D3DMetal.framework` and
`wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll` are all present and each forwarder carries
the `Wine builtin DLL` marker. GPTK 4.0 beta 2 also has `wine/x86_64-unix/<name>.so` (links
to `../../external/libd3dshared.dylib`), `nvapi64` and `nvngx-on-metalfx`, `License.rtf` and
`SOURCE.txt`; the unix halves and nvapi64 are linked when present. Bridgeplay only reads the
folder.

## Risks

- **D3DMetal is engine-wide.** With a GPTK linked, every game on the WineCX engine that
  does not choose `dxmt` or `dxvk` runs D3DMetal, and Wine's `wined3d` is not reachable on
  that engine (use the WineHQ engine for it). A `dxmt`/`dxvk` game still gets Apple's
  `d3d10`/`d3d12` builtins. `wineboot --update` copies `lib/wine` builtins into a prefix, so
  Apple's forwarders can end up in a prefix's `system32`, as they do under Whisky. No game was
  launched in this work.
- **Upstream maturity.** The runtimes are CI builds from one maintainer, tagged automatically.
  The `runtime-v4.5.1xx` tags carry only a version table. The 11.15 notes
  ([v4.5.0](https://github.com/dappermint/winecx-gptk/releases/tag/v4.5.0),
  [v4.5.1](https://github.com/dappermint/winecx-gptk/releases/tag/v4.5.1)) list one known
  caveat: a non-reproducible Steam renderer wedge under `WINEMSYNC=1` on a heavily loaded
  machine. The workaround is `WINEMSYNC=0`. frankea
  validated Steam's UI, D3D12 via D3DMetal and DXVK D3D11 on 11.15, but not a DX12 game
  launched from Steam
  ([v4.5.105-beta.1](https://github.com/frankea/Whisky/releases/tag/v4.5.105-beta.1)).
- **msync needs the wineserver started with the same `WINEMSYNC`.** Otherwise the client
  aborts with "Server is running with WINEMSYNC but this process is not"
  (`dlls/ntdll/unix/msync.c`). `compat_run.sh` exports `WINEMSYNC` before it starts the
  prefix's server.
- **The CrossOver user profile.** A prefix built by another engine keeps its profile under
  `users/<name>`, while CrossOver-lineage Wine uses `users/crossover`
  ([frankea notes](https://github.com/frankea/Whisky/releases/tag/v4.5.105-beta.1)).
  Bridgeplay prefixes are tied to one build, so this only matters if a prefix is moved
  between engines.
- **Bridge compatibility is inferred, not run.** `ntdll.so` exports a superset of stock
  11.15's (299 → 302 symbols), so `lsteamclient.so` resolves. The PE `ntdll.dll` exports were
  not compared, because no stock 11.15 `ntdll.dll` was built locally. `RunnerPatcher` replaces
  winecx's own `lsteamclient` with the bridge's. The bridge has no wineserver-protocol
  component. No game was launched in this work.
- **DXVK.** The archive's DXVK has no `dxgi.dll` for either arch. A 32-bit game on DXVK paired
  with Wine's dxgi can fail with "Adapter is not a DXVK adapter" (winecx-gptk `build.yml`
  comment).
- **Licences.** Wine is LGPL-2.1+, DXMT master LGPL-2.1+ (source at
  https://github.com/3Shain/dxmt/tree/e94c312f5c054263acf261cfa109edf13e757587), DXVK zlib, MoltenVK Apache-2.0. The tarball also
  bundles nixpkgs libraries: ffmpeg 7.1.1 built `--enable-gpl` with x264/x265 (GPL-3.0+),
  and gstreamer's fdk-aac plugin. It ships **no licence texts**, and winecx-gptk has no
  licence of its own. Bridgeplay only downloads the upstream release on the user's machine
  and redistributes none of it. Anyone mirroring the archive takes on those obligations.
- **Rosetta.** The engine is x86_64 and Apple has said Rosetta is largely going away in
  macOS 28. D3DMetal is x86_64 only too (winecx-gptk README).
- **GPTK authenticity.** Bridgeplay checks the builtin marker and file presence but not Apple's
  code signature (Whisky checks both, in `GPTKImporter+Authenticity.swift`). The payload is
  a local folder the user chose.

## Regenerating the pins

```
tar -xzf Libraries.tar.gz
cd ntdll-patch
python3 resolve.py ../Libraries/Wine          # self-tests against PINNED
./build.sh   ../Libraries/Wine/lib/wine/x86_64-windows/ntdll.dll winecx-<11.17|11.15>
./build32.sh ../Libraries/Wine/lib/wine/i386-windows/ntdll.dll  winecx-<11.17|11.15>
python3 apply.py <ntdll.dll> <out> <detour bin>   # patched hashes
```

- Any new or bumped engine needs a 32-bit game smoke test: launch a 32-bit game from Steam on it and check that it reaches Steam. `make detourcheck` only proves each detour reads the register its pin names.

4.7.3 (`winecx-11.17`): both detours fit in `.text` padding. The detour payloads and
every other shipped file are in [Shipped binaries](#shipped-binaries).

| Pin | sha256 |
|---|---|
| loader `lib/wine/x86_64-unix/wine` | `a680abba30b4888355adb39d8b62255e43546eb33d163897260627f7741ef648` |
| clean x86_64 ntdll | `8b32c9f6f71b4f15fcaccb19b0f2adab9391ae73ad539cae9e136f8ee7d24128` |
| patched x86_64 ntdll | `4573d521671a48212670e7543aa9ebf0921e383dada69477f677f435df2bef5a` |
| clean i386 ntdll | `cc8a9035cea0e26c5d333ef220f1becefc27ae44d2cdcdaea3278e8739d26fd9` |
| patched i386 ntdll | `628d08854dc42009f63dc489005c2a49a3f1fe4c6a949dc1ac505915004e5b70` |

4.5.125 (`winecx-11.15`):

| Pin | sha256 |
|---|---|
| loader `lib/wine/x86_64-unix/wine` | `a4b677428a6834f97f536a84d32c5da982c9a449e5d483c6be3d1c9b8f308998` |
| clean x86_64 ntdll | `5710d16382c7a822ed8b1cba58d95fd86fe01905f039c296ca7224abff8f98e8` |
| patched x86_64 ntdll | `4efd956e573726777827cddaa89ef3b7f72d6cfd7b8e2049e41f5f5bdf4a6306` |
| clean i386 ntdll | `e1b208073c804a443e64ada577899d96a5c8eaee435813e4a30e0d143bca6e3c` |
| patched i386 ntdll | `ffdf7f49a4b07b582a1172092a4af452b5beb7377b59f423cb2d1a1e9c18c9af` |

The unpack test (`FreeEngineWinecxTests.unpacksRealArchive`, once per release) checks all of
this against the real archive when `NOTPROTON_WINECX_ARCHIVE` points at it, or when it sits in
Bridgeplay's download cache.

## Corresponding Source

Every patched binary below (LGPL-2.1-or-later) is built from winecx (`dappermint/winecx`) at
the commit pinned at the top of this page plus one of the patches above. The license asks
whoever distributes these binaries to also provide that source, so
`scripts/package-wine-patch-sources.sh` publishes winecx's source at those commits with the
patches and recipes onto a `wine-patch-sources-<id>` release of this project, pinned in
NOTICE. See [RELEASING.md](RELEASING.md), WineCX patch source, for when to rebuild and
republish it.

## Shipped binaries

Every binary in `app/Sources/BridgeplayApp/Resources/` built from a patch or source in this
repository, with the sha256 of the committed file, which must equal the Swift pin in the last
column. Build recipes are in the sections above and in each patch folder's README.

The Mach-O files (`.so`, `.dylib`) are committed signed ad hoc. A release re-signs them with
the Developer ID so Apple notarizes the app (see [RELEASING.md](RELEASING.md), Signing), which
changes their bytes but not their code. `SignedPin.swift` maps each sha256 below to the hash
of the file without its signature, so both copies, and engines laid out by either, pass. A
rebuilt Mach-O file needs its line there updated too; `SignedPinTests` fails until it is.

| File | Built from | sha256 | Pinned in |
|---|---|---|---|
| `crypt32-winecx-11.17.dll` | `ngx-signer-patch/` | `27b485cc2a6bf651d8d72173e5d40dbc914666d3f8e8f6a4031a91c5ff22ebbf` | `FreeEngineWinecx.v1117.nvidia` |
| `wintrust-winecx-11.17.dll` | `ngx-signer-patch/` | `256f3b7106cb8f7f390e1551f209bfb72ccf43744d6d583e5664e44d7602bfee` | `FreeEngineWinecx.v1117.nvidia` |
| `nvapi64-shim.dll` | `nvapi-shim/` | `a80aea6347a8b1e72542e458f410d37fdedb39e194c0fcee45a5ae6cd7f571be` | `FreeEngineWinecx.v1117.nvidia` |
| `win32u-winecx-11.17.so` | `win32u-patch/patch-driver-version.sh` | `b012382d09b2ff1b3c0750d93867f72dd04a7c902bc4179be406b6c558ab162d` | `FreeEngineWinecx.v1117.nvidia` |
| `wined3d-winecx-11.17.dll` | `wined3d-patch/` | `9298c83d927b3b80d0fa36f52bb5f2ecd60ec4daffff3c93d9b080293e59dfe9` | `FreeEngineWinecx.v1117.nvidia` |
| `winecoreaudio-winecx-11.17.so` | `winecoreaudio-patch/` | `680b267e8cf41af0868de4adf7f6760615a434a4be06b4ab0cfeece2d9240faa` | `FreeEngineWinecx.v1117.audio` |
| `ws2_32-winecx-11.17.dll` | `ws2_32-patch/` | `cb0a5670ce6dbf949ed25cca54e9f1c4930cd4c2ade895836d518d3d9073079c` | `FreeEngineWinecx.v1117.network` |
| `kernel32-winecx-11.17.dll` | `hide-wine-exports-patch/` | `9cffe153abd3f91f7157f936377baac47c5aef9fa807e263a0f9e051c6010af3` | `FreeEngineWinecx.v1117.loader` |
| `kernelbase-winecx-11.17.dll` | `hide-wine-exports-patch/` | `4d55600b204724046567688ca96132e49e53af1baac7a362f3e2bf285f669a8a` | `FreeEngineWinecx.v1117.loader` |
| `d3dx11_43-winecx-11.17.dll` | `d3dx11-patch/` | `7d23cdfacc922f67dfa2eba98df277ae2ae351ad3646c3191a84966b55dbbfd3` | `FreeEngineWinecx.v1117.d3dx` |
| `d3dx11_43-winecx-11.17-i386.dll` | `d3dx11-patch/` | `dd4dd351f2a5880c9848d5ccf4944a0b5e7622bb7fb196544115b1f9c92d749c` | `FreeEngineWinecx.v1117.d3dx` |
| `d3dx11_42-winecx-11.17.dll` | `d3dx11-patch/` | `3d97e1de9000a78e27eb5c90d0ab9b36d54fd350760063da27226d22c90c8e1b` | `FreeEngineWinecx.v1117.d3dx` |
| `d3dx11_42-winecx-11.17-i386.dll` | `d3dx11-patch/` | `85075f8b4f30f1a993238a0d6ab772a3a3df6c031e87ee9401c4367a527cd57c` | `FreeEngineWinecx.v1117.d3dx` |
| `version-rockstar-shim.dll` | `rockstar-shim/` | `deedb5d799330a3e274fe5cc7f569536280a2420543ef12145fcaa8fcbb7f6d4` | `FreeEngineWinecx.v1117.rockstar` |
| `dxgi-dxvk-macos-1.10.3.dll` | DXVK-macOS v1.10.3-20230507 `x64/dxgi.dll`, unmodified | `e74f5c985fe98f38f1a096258ef35d62e03a64df7096837965c7383e3cfe153d` | `FreeEngineWinecx.v1117.rockstar` |
| `winemac-winecx-11.17.so` | `winemac-patch/winecx-11.17-d3dmetal-retina.patch` | `aa192f846ad15d56de200fc92752eaf2d455700846ae2cf1ccc7b27b535f1c00` | `FreeEngineWinecx.v1117.macDriver` |
| `winebus-winecx-11.17.so` | Controllers (SDL2 build) | `6223c035c824c90708abbc3e733f8d1d6ed6b8b4e9a3e1a5c813493ceba50473` | `FreeEngineWinecx.v1117.gamepad` |
| `winebus-winecx-11.17.sys` | `winebus-patch/` | `da108d1c3788fa32807ef08c4d26d8a89812c230317ffa7ba5111e126bda607c` | `FreeEngineWinecx.v1117.gamepad` |
| `winemac-winecx-11.15.so` | `winemac-patch/winecx-d3dmetal-retina.patch` | `76d8f93839386f37e8badf0c82bb31b5ead22ac580f17896f9d2a729af0fc147` | `FreeEngineWinecx.v1115.macDriver` |
| `winebus-winecx-11.15.so` | Controllers (SDL2 build) | `1bc53184f5d026ab84a26cf6ef721348fc3b028c019ff969e69eb6cf9b9d1af9` | `FreeEngineWinecx.v1115.gamepad` |
| `libSDL2-2.0.0.dylib` | SDL 2.32.10, `winemac-patch/sdl2-iokit-gamepad-collection.patch` | `aeeec088bf51f9eac0dbd8e26ae994c7b8568fb42fc676835d6dc2109fc559d1` | `FreeEngineWinecx` `sdl` (both releases) |
| `winemac-winehq-11.15.so` | `winemac-patch/dxmt_export.c` | `d95fe40b6321ba8a34933a6b394af6d75547220a7168896c357af3a32377b08f` | `FreeEngine` `macDriver` |
| `detour2-41069.bin` | `ntdll-patch/build.sh` (41069) | `660ea7c935620e620a45a46e552c0a3de9292e031bf93ef676968154d45e78d5` | `NtdllPatcher.byBuild` |
| `detour2-41073.bin` | `ntdll-patch/build.sh` (41073) | `971c9c8c0f5a9fc7338fb5012a88f8a5297924e48cadb0aa0fa827cce0984a6e` | `NtdllPatcher.byBuild` |
| `detour2-cx26.bin` | `ntdll-patch/build.sh` (cx26) | `e35b834408599c45f30b23a6d2bf38acfa5c3df4d15206617c471e23a4a01bfb` | `NtdllPatcher.byBuild` |
| `detour2-fex-41069.bin` | `ntdll-patch/build.sh` (fex-41069) | `0084bba1d7399e749d918dba4f313f1dc1825d2a487f3169b469b57c5b161ca5` | `NtdllPatcher.byBuild` |
| `detour2-fex-41073.bin` | `ntdll-patch/build.sh` (fex-41073) | `d3b922ad4eae11d9a95cdab1276546af08bd3b28e041427ea0ebc557b094ad32` | `NtdllPatcher.byBuild` |
| `detour2-fex.bin` | `ntdll-patch/build.sh` (fex) | `6af3f36658907cc94c096e432006807d6997bd970560f2579df748d6fd6e2bc6` | `NtdllPatcher.byBuild` |
| `detour2-winecx-11.15.bin` | `ntdll-patch/build.sh` (winecx-11.15) | `fde56854b9a7a32da19babe2427d19ff6a6b83de1917fe8d32aaddd2991fc6b9` | `FreeEngineWinecx.v1115.ntdllPatches` |
| `detour2-winecx-11.17.bin` | `ntdll-patch/build.sh` (winecx-11.17) | `e1bbd185b19de3e23d627ae3a8bf25ed1b767bff5690102c5312a5ed3813e736` | `FreeEngineWinecx.v1117.ntdllPatches` |
| `detour2-winehq-11.15.bin` | `ntdll-patch/build.sh` (winehq-11.15) | `d394a6b7f4c55e2bb8b99aeb51cd4555527f8e10fa49339e95a8156486c5e2e5` | `NtdllPatcher.byBuild` |
| `detour2.bin` | `ntdll-patch/build.sh` (rosetta) | `8504714bba0195439cb5b44c89f25c68dbb7f01bae6f72ca0a258a0daec3e244` | `NtdllPatcher.byBuild` |
| `detour32-41069.bin` | `ntdll-patch/build32.sh` (41069) | `3eaa5021add0c8e30e324d6b1a6392a32720f5f73596418a2086b7f8081eb1bd` | `NtdllPatcher.byBuild` |
| `detour32-41073.bin` | `ntdll-patch/build32.sh` (41073) | `693d6b8ac801c5697dc7d86aeb4f23fbfb1fd08bb3f949ad3e4b2311cd28348a` | `NtdllPatcher.byBuild` |
| `detour32-cx26.bin` | `ntdll-patch/build32.sh` (cx26) | `be465bc936cafafae4aa1b4c41f668e08848492d9858c2cf2ad483a9f1ab25e5` | `NtdllPatcher.byBuild` |
| `detour32-fex-41069.bin` | `ntdll-patch/build32.sh` (fex-41069) | `6ff6c7289e639c4caad85c2670bfa849d9f36baa24152b6979896caede5e249b` | `NtdllPatcher.byBuild` |
| `detour32-fex-41073.bin` | `ntdll-patch/build32.sh` (fex-41073) | `e0b3a73bb287ecdebe7a9516a732b60e8de95fa0a756ae5ea4c5bd46e4a807c2` | `NtdllPatcher.byBuild` |
| `detour32-fex.bin` | `ntdll-patch/build32.sh` (fex) | `b4c697ba396ecb59125c505666ad3465d1208b8a1e3e53a0c457657b341376b9` | `NtdllPatcher.byBuild` |
| `detour32-winecx-11.15.bin` | `ntdll-patch/build32.sh` (winecx-11.15) | `b8363acbaeedeb5f22379e0ec6394cf721c384f484b80e1f51a08fb74e41d13b` | `FreeEngineWinecx.v1115.ntdllPatches` |
| `detour32-winecx-11.17.bin` | `ntdll-patch/build32.sh` (winecx-11.17) | `085df281ffe81c2803f44dd30df885248e5510c8560f0f20a5ae36e8446f7559` | `FreeEngineWinecx.v1117.ntdllPatches` |
| `detour32-winehq-11.15.bin` | `ntdll-patch/build32.sh` (winehq-11.15) | `527431a3a74e9dff7bc3582277ddfa7b44bcac6fba285c028fd2c94fd9202418` | `NtdllPatcher.byBuild` |
| `detour32.bin` | `ntdll-patch/build32.sh` (rosetta) | `2758d4f6783c853c460187f83f4fb9b1105380d194126ef83fc85e2596d3036a` | `NtdllPatcher.byBuild` |
| `detour64-fex-41069.bin` | `ntdll-patch/build64.sh` (fex-41069) | `b27484eaed592366ddd3a5b3c565c2dc05e8fa255fbd7e19d9d8eb619ff57c23` | `NtdllPatcher.byBuild` |
| `detour64-fex-41073.bin` | `ntdll-patch/build64.sh` (fex-41073) | `8a6fe80587815393059cb2cecfdc542b666c158e147560875ff19f37221726d2` | `NtdllPatcher.byBuild` |
| `detour64-fex.bin` | `ntdll-patch/build64.sh` (fex) | `68a458ec9c32041c79fdd622d18e91cfbe825a5292cae362d310930e34dd598e` | `NtdllPatcher.byBuild` |

`detour32-winehq-11.15.bin` and `detour2-winecx-11.17.bin` rebuild byte for byte from the
current sources (checked 2026-10-24). `detour2-winehq-11.15.bin` does not: it was built from
`detour.c` before 160968c and still jumps to lsteamclient's DllMain, while the current source
gives an 832-byte payload (`dc4d86de…`) that skips it, like the other engines. It stays until a
WineHQ x86_64 game has been tested with the rebuilt payload.
