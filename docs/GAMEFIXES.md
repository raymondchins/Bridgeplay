# Per-game fixes and graphics backends

The `run` script reads up to four optional files when a game starts. The first two apply to
every game, and the last two are named after the game's Steam app id:

1. `~/Library/Application Support/bridgeplay/gamefixes-default/default.conf`, Bridgeplay's defaults for every game
2. `~/Library/Application Support/bridgeplay/gamefixes/default.conf`, your own defaults for every game
3. `~/Library/Application Support/bridgeplay/gamefixes-default/<appid>.conf`, shipped with Bridgeplay
4. `~/Library/Application Support/bridgeplay/gamefixes/<appid>.conf`, your own

A later file wins per key. A variable you set in the game's Steam launch options
(`NAME=value %command%`) wins over all four files. Bridgeplay replaces the files in
`gamefixes-default/` on every install and never writes to your `<appid>.conf`.

The Game Defaults page in the app edits file 2. It rewrites only the lines for the settings
it shows and keeps every other line and comment. When you pick what files below it already
give, it removes the line instead of writing it, so a later change to Bridgeplay's defaults
still reaches you. Turning off a setting that Bridgeplay turns on writes `KEY=0`. The page
also lists the games that set something of their own, in a conf or in their launch options.
In Steam, Properties › Bridgeplay has a Use Bridgeplay defaults button that removes those
settings from a game's launch options.

Installers before the split copied Bridgeplay's defaults into file 2. The app trims that copy
once, after saving the original in `backups/`. It drops the lines identical to the copy last
installed (`.installer/default.conf`) and writes `KEY=0` for a shipped `KEY=1` you had
deleted, so your file keeps only your own changes.

Bridgeplay's own variables are spelled `BRIDGEPLAY_*` (`BRIDGEPLAY_RETINA=1`). The
`NOTPROTON_*` spelling from before 3.0.0 still works, in launch options and in conf files.

## Format

One `KEY=VALUE` per line. Blank lines and lines starting with `#` are ignored, and so is
whitespace around a line. There are no inline comments: everything after the first `=`
is the value. The files are never run as shell code. A line is rejected, and the rejection
logged, when:

- the key is not on the list below
- the value contains a backtick, `$(`, a quote or a control character, or is over 1024 characters

| Key | Values | Effect |
| --- | --- | --- |
| `BACKEND` | `dxmt`, `dxvk`, `wined3d`, `d3dmetal` | Graphics backend, see below |
| `ROSETTA_ADVERTISE_AVX` | `1` makes Rosetta report AVX/AVX2 to the game (needed by AVX-only titles) |
| `ARGS` | space-separated arguments of `A-Za-z0-9_+./:=,-` | Added to the game's command line after the launch options' own arguments. Ignored for installers and other helpers |
| `DLLOVERRIDES` | Wine syntax, e.g. `dinput8=n,b;xinput1_3=n` | Added to `WINEDLLOVERRIDES` after the backend's entries and before the launch options' |
| `MSYNC` | `0`, `1` | `1` turns msync on when the engine supports it; `0` turns it off |
| `RETINA` | `0`, `1` | Same as `BRIDGEPLAY_RETINA` (High Resolution). DPI-unaware games on the OpenGL/wined3d path (D3D9, OpenGL) can draw into the top-left quarter with RETINA=1; set RETINA=0 in their gamefix, as gamefixes/49520.conf does. |
| `FRAMEGEN` | `0`, `1`, `2`, `3`, `adaptive` | Same as `BRIDGEPLAY_FRAMEGEN`: experimental frame generation in overlay-shim, adds up to half a frame of latency. `2` and `3` multiply the frame rate, `adaptive` fills up to the display refresh, `1` is the same as `2`, `0` is off (the default) |
| `FRAMEGEN_QUALITY` | `performance`, `balanced`, `quality` | Same as `BRIDGEPLAY_FRAMEGEN_QUALITY`. `balanced` when unset |
| `FRAMEGEN_UI` | `0`, `1` | Same as `BRIDGEPLAY_FRAMEGEN_UI`, Protect UI: keeps static HUD and menus sharp. On when unset |
| `FRAMEGEN_FALLBACK` | `0`, `1` | Same as `BRIDGEPLAY_FRAMEGEN_FALLBACK`, Fast-motion fallback: skips generated frames that would smear. On when unset |
| `FRAMEGEN_ENGINE` | `own`, `metalfx` | Same as `BRIDGEPLAY_FRAMEGEN_ENGINE`: the built-in optical flow (`own`, the default) or MetalFX frame interpolation |
| `NVAPI` | `0`, `1` | `1` turns on Apple's `nvapi64` and `nvngx` (DLSS on MetalFX) on an engine with a linked Game Porting Toolkit, for `d3dmetal` only, and makes D3DMetal report an NVIDIA GeForce RTX 4090 (`D3DM_VENDOR_ID=0x10de`, `D3DM_DEVICE_ID=0x2684`, `D3DM_DEVICE_DESCRIPTION`; a `D3DM_*` from a conf or the launch options wins) and a driver version of 32.0.15.9541 (`NOTPROTON_DRIVER_VERSION`), since games offer DLSS only on an NVIDIA adapter. Without the key, the run script treats it as `0`. Bridgeplay's `gamefixes-default/default.conf` sets `NVAPI=1`, so it is on for every game unless a game's conf or launch options say `NVAPI=0`. An nvapi that answers sends some games down NVIDIA-only paths, which is the reason to turn it off |
| `DLSS_FG` | `0`, `1` | With `NVAPI=1` on `d3dmetal`, `1` sets `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` so WineCX reports hardware GPU scheduling, which DLSS frame generation requires. Experimental and off by default (`gamefixes-default/default.conf` leaves it out): [frankea/Whisky#231](https://github.com/frankea/Whisky/pull/231) saw MetalFX frame interpolation on an M5 with D3DMetal 4.0b2 hang WindowServer |
| `STDOUT_NULL` | `0`, `1` | `1` starts the game without a stdout handle, as Steam on Windows does. Source 2 treats any stdout as a console build (`Plat_IsConsoleApplication`) and then skips NGX, so Deadlock offers no DLSS |
| `VSYNC` | `0`, `1` | `1` makes the game's Metal layer wait for the display even when the game turns vsync off, like forcing vsync in the NVIDIA control panel. For games that lock vsync off with frame generation on (Resident Evil Requiem) and tear above the refresh rate |
| `HIDE_WINE_EXPORTS` | `0`, `1` | `1` makes `GetProcAddress` fail for ntdll's `wine_*` exports on the WineCX 11.17 engine (`hide-wine-exports-patch/`), like Wine Staging's `HideWineExports`. For games that turn features off under Wine: The Witcher 3 5.0 skips NVIDIA Streamline, so no DLSS |
| `DXMT_*`, `DXVK_*`, `MVK_*`, `VKD3D_*`, `D3DM_*`, `STAGING_*` | any | Exported as is |
| `MTL_HUD_ENABLED`, `WINEDEBUG`, `WINE_LARGE_ADDRESS_AWARE`, `WINE_CPU_TOPOLOGY` | any | Exported as is |
| `CX_FWD_COMPAT_GL_CTX` | any | Exported as is: WineCX's switch for forward-compatible OpenGL contexts, for testing OpenGL (`wined3d`) games |

Wine uses the last entry for a DLL in `WINEDLLOVERRIDES`. The order is: backend, then
`DLLOVERRIDES`, then the launch options, then the Steam client DLLs, which always come last.

## Graphics backends

| Name | What runs D3D10/11 | D3D12 |
| --- | --- | --- |
| `dxmt` | DXMT master (Metal), the default without D3DMetal | does not work |
| `dxvk` | DXVK-macOS (MoltenVK); the engine's own `dxgi` stays builtin | vkd3d, or D3DMetal |
| `wined3d` | Wine's own DLLs, not on an engine with D3DMetal | vkd3d |
| `d3dmetal` | Apple D3DMetal, on the WineCX engine with a linked Game Porting Toolkit; the default there | D3DMetal |

The backend is picked in this order:

1. `BRIDGEPLAY_BACKEND=<name>` (or `NOTPROTON_BACKEND`) in the launch options
2. `CX_GRAPHICS_BACKEND` in the launch options, which the Graphics menu in the game's Steam Properties › Bridgeplay sets.
   Any case is accepted. `d3dmetal`, `dxmt` and `dxvk` map to themselves, and `wined3d`,
   `opengl` and `wine` map to `wined3d`. Other values are logged and ignored
3. `BACKEND=` in a conf file
4. Auto-detect. If the game's `.exe` imports `d3d12.dll` in its PE import table, the game
   gets `wined3d`. Otherwise it gets `dxmt`. Delay-loaded and `LoadLibrary` imports do not
   count, and neither does a file that does not parse as a PE. On an engine with D3DMetal
   every game gets `d3dmetal`
5. `dxmt`, or `d3dmetal` on an engine with D3DMetal

A backend the engine lacks falls back: `dxvk` → `dxmt` → `wined3d`, and `d3dmetal` → `dxmt`.

### WineCX with D3DMetal

When a Game Porting Toolkit is linked into the WineCX engine
(`lib/notproton-backends/d3dmetal.enabled`, see [WINECX.md](WINECX.md)), Apple's
forwarders are that engine's `dxgi`, `d3d10`, `d3d11` and `d3d12` builtins and Wine's own
are set aside. So on that engine:

- the default, and auto-detection for D3D11 and D3D12 games alike, is `d3dmetal`
- `wined3d`, from any source (launch options, the Bridgeplay tab in Steam, a conf, the last launch), is
  logged as not available and runs `d3dmetal`
- a missing `dxmt` falls back to `d3dmetal`, and so does a `dxmt` or `dxvk` that cannot be
  staged into the prefix
- `dxmt` and `dxvk` still work per game: their DLLs go into the prefix as natives (`n,b`),
  and `d3d10`/`d3d12` stay builtin, which is Apple's
- `d3dmetal` sets every D3D DLL (`d3d10`, `d3d10core`, `d3d11`, `d3d12`, `dxgi`) to `b`,
  exports `CX_GRAPHICS_BACKEND=d3dmetal` and `CX_APPLEGPTK_LIBD3DSHARED_PATH`
- Apple's `nvapi64` and `nvngx` are set to `d` unless the conf says `NVAPI=1` and the backend is
  `d3dmetal`

Without a linked Game Porting Toolkit the WineCX engine behaves like the WineHQ one.
Engines without `lib/notproton-backends` have their graphics DLLs built in. They show the
backend `dxmt-builtin` and do not swap anything.

The chosen backend's DLLs are copied into the prefix's `system32` and `syswow64` and set
to `n,b`. Wine swaps a DLL carrying the Wine builtin marker found in a prefix for the
`lib/wine` builtin of the same name, so a marked copy would quietly run Wine's own; the
engine install strips the marker from DXMT's DLLs for that reason.
Every other DLL that any backend ships is set to `b`. When you switch backends, a copy
left behind by another backend is replaced with Wine's own (the set-aside copy on an
engine with D3DMetal; Apple's files are never copied into a prefix). `d3dmetal` also sets
`CX_GRAPHICS_BACKEND=d3dmetal`. The run log
(`bridgeplay-run.log`) shows each decision. The `notproton-backend` file in the game's
compatdata folder has the current backend and why it was picked.

## Examples

An Unreal game that defaults to D3D12, moved onto its D3D11 renderer under DXVK:

```
BACKEND=dxvk
ARGS=-dx11
DXVK_HUD=fps
```

A game that needs native input DLLs and verbose loader logs:

```
DLLOVERRIDES=dinput8=n,b;xinput1_3=n,b
WINEDEBUG=+loaddll
```

A game on the WineCX engine that runs better on DXMT than on D3DMetal:

```
BACKEND=dxmt
```

A D3DMetal game that needs an nvapi to answer:

```
BACKEND=d3dmetal
NVAPI=1
```

A DXMT game with MetalFX, msync off and High Resolution on:

```
BACKEND=dxmt
DXMT_METALFX_SPATIAL_SWAPCHAIN=1
MSYNC=0
RETINA=1
```

## Native macOS games

A Mac build with no compatibility tool pinned runs through `~/.bridgeplay/np-native`, not the
`run` script, so the files above do not apply to it. np-native reads its own two files,
with variable names as they are (`BRIDGEPLAY_FRAMEGEN=2`, `NP_PAD_MODE=hid`, `MTL_HUD_ENABLED=1`):

1. `~/Library/Application Support/bridgeplay/gamefixes/native-default.conf`, for every native game
2. `~/Library/Application Support/bridgeplay/gamefixes/native/<appid>.conf`, which wins per key

The Bridgeplay tab in Steam Properties for such a game shows the Metal HUD, Frame Generation and the controller
layer (`NP_PAD_MODE`: `hid`, `gc` or `off`). It writes the launch options as
`<home>/.bridgeplay/np-native VAR=VALUE ... %command% <game args>`, and rewrites the older
`/usr/bin/arch -arm64 -x86_64 -e VAR=VALUE ... %command%` form into that one, dropping its
`DYLD_INSERT_LIBRARIES`.
