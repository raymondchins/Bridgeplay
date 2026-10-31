# Architecture

Bridgeplay has three moving parts: an app that sets everything up, a dylib that runs inside
the Mac Steam client, and patched Wine engines that run the games. This page says what
each folder is, which process it ends up in, and where new code belongs.

## Components

| Folder | Runs in | How it gets there |
|---|---|---|
| `app/` | The Bridgeplay app (SwiftUI, Sparkle updates); also a CLI (`--install-into-steam`, `--setup-winecx`, `--remove-everything`) | `installer/Install.command` copies it to `/Applications` |
| `dylib/` (`notproton.dylib`: hooks, signature resolver, Steam web UI patches, compat tool registration, the run script `feats/compat_run.sh`) | The Steam client (`steam_osx`) and Steam Helper | The app copies it into `Steam.app/Contents/MacOS`, sets `DYLD_INSERT_LIBRARIES` in Steam's Info.plist and re-signs Steam |
| `signatures/macos.arm64/` | Data the dylib reads to find Steam functions | Copied to Application Support; the highest-numbered file wins |
| `lsteamclient/`, `steam-shim/` | Wine: the steamclient bridge and the Windows `steam.exe` | Built against the Wine tree in `bridge/`, shipped in the app payload, put into runners |
| `ntdll-patch/` | Detours patched into the engine's `ntdll.dll` | Prebuilt `detour*.bin` in the app's Resources, applied by `NtdllPatcher.swift` |
| `win32u-patch/`, `winemac-patch/`, `winebus-patch/`, `winecoreaudio-patch/`, `wined3d-patch/`, `ws2_32-patch/`, `ngx-signer-patch/`, `d3dx11-patch/`, `hide-wine-exports-patch/` | Replacement Wine files inside the engine | Rebuilt binaries are committed in the app's Resources and copied over the engine at setup |
| `nvapi-shim/` | Windows `nvapi64.dll` in the game (reports an NVIDIA driver so games offer DLSS) | Prebuilt in the app's Resources |
| `overlay-shim/` | Mac dylib in the game process (HDR, Metal 4, frame generation) | `DYLD_INSERT_LIBRARIES` from the run script, or loaded by lsteamclient |
| `native-launch/` (`np-native`), `native-shim/` (`libnp_gamepad.dylib`) | Native Mac games | A Steam launch option re-execs the game with the shim inserted |
| `helpers/` | Small CLIs the dylib and run script call (`iconmaker`, `appinfo`) | Application Support |
| `gamefixes/` | Per-game defaults read by the run script | Bundled in the app payload and the installer |
| `installer/` | `Install.command` and its config | Zipped by `scripts/package-installer.sh` |
| `bridge/`, `scripts/`, `fonts/`, `compat/`, `vendor/` | Build tooling, the Proton font build, the compatibility table, vendored code | Build time only |

## How it fits together

1. The app patches Steam, clones and patches the Wine runners, and re-applies its patch
   when Steam updates itself.
2. Steam starts with the dylib, which registers the `bridgeplay-proton-*` compatibility
   tools, so Windows games show Install and Play like Mac games.
3. Steam launches a Windows game through the `run` script, which picks the engine
   (WineCX with D3DMetal, DXMT or DXVK), applies the game's gamefixes and injects the
   game-side shims.

## Where new code goes

| Change | Folder |
|---|---|
| Setup, Status, prefixes, updates | `app/` |
| Something Steam does or shows | `dylib/` (and `signatures/` when it needs a new Steam function) |
| How a game is launched, per-game environment | `dylib/feats/compat_run.sh`, `gamefixes/` |
| A fix inside Wine | The matching `*-patch/` folder: a patch plus a README with the build recipe and sha256 pins, then the rebuilt binary in the app's Resources |
| Something inside the game process on the Mac side | `overlay-shim/` |
| Native Mac games | `native-launch/`, `native-shim/` |

## Naming

Runtime identifiers kept their NotProton names (`notproton.dylib`, `NOTPROTON_*` variables,
`com.notproton.*` signing identifiers, the `NotProtonVersion` plist key); renaming them
would need another migration. Everything on disk uses `bridgeplay` since 3.0.0; see
[RELEASING.md](RELEASING.md#the-300-rename).
