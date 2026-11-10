# Per-game fixes and graphics backends

The `run` script reads up to four optional files when a game starts. The first two apply to
every game, and the last two are named after the game's Steam app id:

1. `~/Library/Application Support/bridgeplay/gamefixes-default/default.conf`, Bridgeplay's defaults for every game
2. `~/Library/Application Support/bridgeplay/gamefixes/default.conf`, your own defaults for every game
3. `~/Library/Application Support/bridgeplay/gamefixes-default/<appid>.conf`, shipped with Bridgeplay
4. `~/Library/Application Support/bridgeplay/gamefixes/<appid>.conf`, your own

A later file wins per key. A variable you set in the game's Steam launch options
(`NAME=value %command%`) wins over all four files. Bridgeplay replaces the files in
`gamefixes-default/` on every install. It changes your `<appid>.conf` only if you click
Use Defaults for that game on the Game Defaults page, which saves a copy in `backups/` and
removes the file's lines for the settings that page shows.

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
`NOTPROTON_*` spelling from before 3.0.0 still works in launch options. Conf files reject it.

## Format

One `KEY=VALUE` per line. Blank lines and lines starting with `#` are ignored, and so is
whitespace around a line. There are no inline comments: everything after the first `=`
is the value. The files are never run as shell code. A file over 64 KiB is ignored. A line
is rejected, and the rejection logged, when:

- the key is not on the list below (`RETINA`, `STDOUT_NULL`, `VSYNC`, `HIDE_WINE_EXPORTS`,
  `FRAMEGEN`, the `FRAMEGEN_*` keys, `PERF_OVERLAY`, `FPS_LIMIT`, `FPS_LIMIT_OFF` and `SCALING_FILTER` also
  accept their `BRIDGEPLAY_` name, such as `BRIDGEPLAY_RETINA=1`; `BACKEND` does not)
- the value contains a backtick, `$(`, a quote or a control character, or is over 1024 characters

| Key | Values | Effect |
| --- | --- | --- |
| `BACKEND` | `dxmt`, `dxvk`, `wined3d`, `d3dmetal` | Graphics backend, see below |
| `ROSETTA_ADVERTISE_AVX` | `0`, `1` | `1` makes Rosetta report AVX/AVX2 to the game (needed by AVX-only titles) |
| `ARGS` | space-separated arguments of `A-Za-z0-9_+./:=,-` | Added to the game's command line after the launch options' own arguments. Ignored for installers and other helpers |
| `DLLOVERRIDES` | Wine syntax, e.g. `dinput8=n,b;xinput1_3=n` | Added to `WINEDLLOVERRIDES` after the backend's entries and before the launch options' |
| `MSYNC` | `0`, `1` | `1` turns msync on when the engine supports it; `0` turns it off |
| `RETINA` | `0`, `1` | Same as `BRIDGEPLAY_RETINA` (High Resolution). DPI-unaware games on the OpenGL/wined3d path (D3D9, OpenGL) can draw into the top-left quarter with RETINA=1; set RETINA=0 in their gamefix, as gamefixes/49520.conf does. |
| `FRAMEGEN` | `0`, `1`, `2`, `3`, `adaptive` | Same as `BRIDGEPLAY_FRAMEGEN`: experimental frame generation in overlay-shim, adds up to half a frame of latency. `2` and `3` multiply the frame rate, `adaptive` fills up to the display refresh, `1` is the same as `2`, `0` is off (the default) |
| `FRAMEGEN_QUALITY` | `performance`, `balanced`, `quality` | Same as `BRIDGEPLAY_FRAMEGEN_QUALITY`. `balanced` when unset |
| `FRAMEGEN_UI` | `0`, `1` | Same as `BRIDGEPLAY_FRAMEGEN_UI`, Protect UI: keeps static HUD and menus sharp. On when unset |
| `FRAMEGEN_FALLBACK` | `0`, `1` | Same as `BRIDGEPLAY_FRAMEGEN_FALLBACK`, Fast-motion fallback: skips generated frames that would smear. On when unset |
| `FRAMEGEN_ENGINE` | `own`, `metalfx` | Same as `BRIDGEPLAY_FRAMEGEN_ENGINE`: the built-in optical flow (`own`, the default) or MetalFX frame interpolation |
| `FPS_LIMIT` | `15` to `360`; also read: `0`, `display`, `half`, `10` to `14` | Same as `BRIDGEPLAY_FPS_LIMIT`: overlay-shim holds the game to that many frames per second, never below 15 nor above the refresh rate of the display the game is on, and turns display sync on as `VSYNC=1` does, so frames land on refreshes. It never changes the display's refresh rate. A number at or above the display's rate is display sync alone. Frame generation adds its frames on top. The settings write whole numbers from a slider; values from earlier releases still work: `display` is the display's rate, `half` half of it, `10` to `14` count as 15, and `0` is no limit. No limit by default. Works on the game's Metal layer (D3DMetal, DXMT, DXVK through MoltenVK, native Metal games), not on OpenGL |
| `FPS_LIMIT_OFF` | `0`, `1` | Same as `BRIDGEPLAY_FPS_LIMIT_OFF`, the Enable frame limit switch turned off: `1` lifts the limit and keeps `FPS_LIMIT`, so switching it back on (`0`) restores the same value |
| `SCALING_FILTER` | `0`, `linear`, `nearest`, `integer` | Same as `BRIDGEPLAY_SCALING_FILTER`: the filter Core Animation scales the game's frames up to the screen with, when the game draws fewer pixels than the screen (High Resolution off, the default, draws half a Retina display's pixels; a game set below its window's resolution). `0` (the default) leaves it as it is: Wine's Mac driver uses nearest while High Resolution is off, so Windows games are pixel-doubled, and native games get macOS's linear. `linear` smooths, `nearest` keeps every pixel sharp at any scale. `integer` is nearest at an exact whole-number scale and linear otherwise. It runs after the game and after DXMT's MetalFX upscaling, and changes nothing when the frame already matches the screen. Metal layers only (D3DMetal, DXMT, DXVK through MoltenVK, native Metal games), not OpenGL |
| `PERF_OVERLAY` | `0`, `fps`, `summary`, `detailed` | Same as `BRIDGEPLAY_PERF_OVERLAY`: Bridgeplay's performance overlay, drawn by overlay-shim in the top-left corner. `fps` is the frame rate alone, `summary` one row with frame time, CPU, GPU, memory and battery, `detailed` a panel with a frame-time graph. Off (`0`) by default. It sits on the game's Metal layer (D3DMetal, DXMT, DXVK through MoltenVK, native Metal games), not on OpenGL. `MTL_HUD_ENABLED=1` shows Apple's Metal HUD instead of it |
| `NVAPI` | `0`, `1` | `1` turns on Apple's `nvapi64` and `nvngx` (DLSS on MetalFX) on an engine with a linked Game Porting Toolkit, for `d3dmetal` only. On WineCX 11.17, Bridgeplay's `nvapi-shim` goes in front of Apple's nvapi to report a newer driver, and `NOTPROTON_NGX_SIGNER` lets Streamline accept Apple's `nvngx` (`ngx-signer-patch/`); 11.15 ships neither, so Streamline games there can still lack DLSS. It also makes D3DMetal report an NVIDIA GeForce RTX 4090 (`D3DM_VENDOR_ID=0x10de`, `D3DM_DEVICE_ID=0x2684`, `D3DM_DEVICE_DESCRIPTION`; a `D3DM_*` from a conf or the launch options wins) and a driver version of 32.0.15.9541 (`NOTPROTON_DRIVER_VERSION`), since games offer DLSS only on an NVIDIA adapter. Without the key, the run script treats it as `0`. Bridgeplay's `gamefixes-default/default.conf` sets `NVAPI=1`, so it is on for every game unless a later conf says `NVAPI=0`. It has no launch-option spelling. An nvapi that answers sends some games down NVIDIA-only paths, which is the reason to turn it off |
| `DLSS_FG` | `0`, `1` | With `NVAPI=1` on `d3dmetal`, `1` sets `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` so WineCX reports hardware GPU scheduling, which DLSS frame generation requires. Experimental and off by default (`gamefixes-default/default.conf` leaves it out): [frankea/Whisky#231](https://github.com/frankea/Whisky/pull/231) saw MetalFX frame interpolation on an M5 with D3DMetal 4.0b2 hang WindowServer |
| `STDOUT_NULL` | `0`, `1` | `1` starts the game without a stdout handle, as Steam on Windows does. Source 2 treats any stdout as a console build (`Plat_IsConsoleApplication`) and then skips NGX, so Deadlock offers no DLSS |
| `VSYNC` | `0`, `1` | `1` makes the game's Metal layer wait for the display even when the game turns vsync off, like forcing vsync in the NVIDIA control panel. For games that lock vsync off with frame generation on (Resident Evil Requiem) and tear above the refresh rate |
| `HIDE_WINE_EXPORTS` | `0`, `1` | `1` makes `GetProcAddress` fail for ntdll's `wine_*` exports on the WineCX 11.17 engine (`hide-wine-exports-patch/`), like Wine Staging's `HideWineExports`. For games that turn features off under Wine: The Witcher 3 5.0 skips NVIDIA Streamline, so no DLSS |
| `STEAMDECK` | `0`, `1` | Exported as `SteamDeck` (mixed case, which a conf key can't spell). Mortal Kombat 1 reads controllers only with `1` (`gamefixes/1971870.conf`) |
| `ROCKSTAR_SHIM` | `0`, `1` | `1` stages `rockstar-shim/`'s `version.dll` next to `SocialClubHelper.exe` (`C:\Program Files\Rockstar Games\Social Club`) and in the game folder (next to GTA5.exe) at the game launch, and adds `version=n,b`. It makes the Rockstar Games Launcher's CEF windows draw on winemac and, on `dxvk`, gives GTA5.exe DXVK's dxgi instead of D3DMetal's (`NOTPROTON_ROCKSTAR_DXGI`) and stages that dxgi as `dxgi.dll` in `Gameface/Binaries/Win64` with `dxgi=n,b` (SanAndreas.exe imports it statically). A `version.dll` or `dxgi.dll` already where one is staged is moved to `<name>.bridgeplay-orig` first; a `version.dll` in `Gameface/Binaries/Win64` (a mod loader) is never staged over and keeps loading. Without the key, or on an engine without the shim, staged copies are removed and that file is put back, except in a game folder another launch (another macOS user's too) is still using. WineCX 11.17 only; `gamefixes/271590.conf` (GTA V Legacy) and `gamefixes/1547000.conf` (GTA San Andreas DE) set it. Details in `rockstar-shim/README.md` |
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
4. For anything but the game launch itself (an installer or other helper), the backend the
   game last ran with
5. Auto-detect. If the game's `.exe` imports `d3d12.dll` in its PE import table, the game
   gets `wined3d`. Otherwise it gets `dxmt`. Delay-loaded and `LoadLibrary` imports do not
   count, and neither does a file that does not parse as a PE. On an engine with D3DMetal
   every game gets `d3dmetal`
6. `dxmt`, or `d3dmetal` on an engine with D3DMetal

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
- except `d3d12` under `dxmt`: Apple's d3d12 crashes on DXMT's adapter, so the 64-bit
  `d3d12` is Bridgeplay's `d3d12-stub` instead, staged into `system32` as a native. It
  creates no device, as Windows on a GPU without D3D12, so a game that tries D3D12 first
  (Unreal Engine 5, Unity 6) falls back to D3D11. A game whose `.exe` imports `d3d12.dll`
  runs on `d3dmetal`, and the run log says so. An engine without the stub keeps Apple's
  d3d12, and a DXMT build that ships its own `d3d12.dll` keeps that one
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

## In-game quick settings

While a game runs with overlay-shim loaded (a Steam game with the Steam overlay on, or one that
sets `PERF_OVERLAY`, `FPS_LIMIT`, `SCALING_FILTER` or `FRAMEGEN`), Option-Command-P opens
Bridgeplay's quick settings on the right edge of the game's window. They change the performance
overlay level, the frame rate limit and the scaling filter at once, and show the battery and
power the Mac reports. The overlay level is a stepped slider. The frame rate limit is a slider in
whole frames per second from 15 to the refresh rate of the display the game is on, with Enable
frame limit under it: that switch applies the limit, and while it is off the slider is dimmed
and keeps its value. The scaling filter is a row of named choices. Up and Down pick a
setting, Left and Right change it (the limit by 1 FPS), Return or Space flips the switch, a click
or a drag along a slider sets it, and Option-Command-P, Escape or a click outside close them.
While they are open the game gets no key presses, clicks, drags, scrolls or mouse movement (raw
input included); releases still reach it. The cursor is theirs then: the arrow, shown and free to
move, also in a game that hides it, clips it to its window or keeps pulling it back to the middle
for mouse look, and the game's own reading of the cursor stays where it left it. Closing them gives
the game its cursor back as it last asked for it: hidden, clipped or held, and back where the game
put it.

Each change is also written to `quick-settings/<appid>.conf` in the support folder. Steam's page
collects it within a couple of seconds and saves it to the game's launch options with the same
logic as the Bridgeplay tab in Steam Properties, so the next launch uses it. A change Steam cannot
place yet is tried again for about a minute. One left from an earlier Steam session, which may
have been another Steam account's, is dropped. The Metal HUD, when a game starts with it,
stays the only overlay and the overlay row is locked. Controllers cannot open or move through
the quick settings. `BRIDGEPLAY_QUICK_SETTINGS=0` in the launch options turns them off.

## Native macOS games

A Mac build with no compatibility tool pinned runs through `~/.bridgeplay/np-native`, not the
`run` script, so the files above do not apply to it. np-native reads its own two files,
with variable names as they are (`BRIDGEPLAY_FRAMEGEN=2`, `NP_PAD_MODE=hid`, `MTL_HUD_ENABLED=1`):

1. `~/Library/Application Support/bridgeplay/gamefixes/native-default.conf`, for every native game
2. `~/Library/Application Support/bridgeplay/gamefixes/native/<appid>.conf`, which wins per key

The Bridgeplay tab in Steam Properties for such a game shows the performance overlay
(`BRIDGEPLAY_PERF_OVERLAY`, or `MTL_HUD_ENABLED=1` for the Metal HUD), the frame rate limit
(`BRIDGEPLAY_FPS_LIMIT` and `BRIDGEPLAY_FPS_LIMIT_OFF`), the scaling filter (`BRIDGEPLAY_SCALING_FILTER`), Frame Generation and the controller
layer (`NP_PAD_MODE`: `hid`, `gc` or `off`). It writes the launch options as
`<home>/.bridgeplay/np-native VAR=VALUE ... %command% <game args>`, and rewrites the older
`/usr/bin/arch -arm64 -x86_64 -e VAR=VALUE ... %command%` form into that one, dropping its
`DYLD_INSERT_LIBRARIES`.
