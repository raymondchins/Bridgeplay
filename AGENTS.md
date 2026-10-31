# Bridgeplay

Bridgeplay runs Windows-only Steam games on Apple Silicon Macs inside the native macOS Steam
client. It turns on Steam Play in Mac Steam and runs games through CodeWeavers' WineCX with
Apple's Game Porting Toolkit (D3DMetal), DXMT or DXVK. It is a GPL-3.0 fork of
[NotProton](https://github.com/NotProtonNot/NotProton). The user-facing overview is in
[README.md](README.md). `docs/DEVELOPING.md` is the developer guide, and `docs/UPSTREAM.md`
keeps the old upstream README.

## Where code lives

| Path | What it is | Runs in |
|---|---|---|
| `app/` | SwiftUI app and CLI (Swift package, Sparkle updates). Sets up Steam, engines and runners. Tests are in `app/Tests/` | Its own process |
| `dylib/` | `notproton.dylib`: hooks, Steam web UI patches, compat tool registration, and the game `run` script (`dylib/feats/compat_run.sh`). See [dylib/AGENTS.md](dylib/AGENTS.md) | Steam client and Steam Helper |
| `signatures/macos.arm64/` | Byte signatures the dylib resolves per Steam build | Read by the dylib |
| `lsteamclient/`, `steam-shim/`, `bridge/` | Proton's steamclient bridge and `steam.exe`, built against the Wine tree that `bridge/` sets up | Wine |
| `ntdll-patch/` | Detours patched into the engine's `ntdll.dll`; the prebuilt `detour*.bin` live in `app/Sources/BridgeplayApp/Resources/` | Wine |
| `*-patch/` (win32u, winemac, winebus, winecoreaudio, wined3d, ws2_32, ngx-signer, d3dx11, hide-wine-exports) | Patches for single WineCX/WineHQ files. The rebuilt binaries are committed in `app/Sources/BridgeplayApp/Resources/` | Wine |
| `nvapi-shim/` | Windows `nvapi64.dll` that lets games use DLSS (answered by MetalFX) | Wine |
| `overlay-shim/` | HDR, Metal 4 and frame generation | Game process |
| `native-launch/`, `native-shim/` | Launch wrapper and gamepad shim for native Mac games | Native game process |
| `helpers/` | Small tools the dylib and run script call (icons, app info, shortcuts) | Command line |
| `gamefixes/` | Per-game defaults, `<appid>.conf`. Format: [docs/GAMEFIXES.md](docs/GAMEFIXES.md) | Read by the run script |
| `installer/`, `scripts/` | The `Install.command` installer, plus build, test and release scripts | — |
| `fonts/`, `vendor/` | Proton's font build; vendored cJSON (Dobby is cloned, see [vendor/README.md](vendor/README.md)) | — |
| `compat/` | Game compatibility list, generated from `compat/games.json`. Don't edit `compat/README.md` by hand | — |

More docs: [docs/WINECX.md](docs/WINECX.md) (engine, patch build recipes and pins),
[docs/DXMT.md](docs/DXMT.md) and [docs/RELEASING.md](docs/RELEASING.md).

## Build and check

A full build needs an Apple Silicon Mac with Xcode 27. Prerequisites, caches and timings
are in [docs/BUILD-LOCAL.md](docs/BUILD-LOCAL.md). The lint workflow runs only `make scriptcheck`
and `make runcheck` (shellcheck 0.11.0) on Linux. The `app` workflow decides on Linux whether a change is
docs-only (`.github/docs-only-paths`) and ends in the `app gate` job; everything else runs on macOS.

```sh
scripts/build-local.sh            # full build in CI order; --checks also runs checks and Swift tests
```

Or build step by step, in the order `.github/workflows/app.yml` uses:

```sh
git clone https://github.com/jmpews/Dobby.git vendor/dobby
git -C vendor/dobby checkout 5dfc8546954ce3b3198132ab13fddb89ee92cdd7   # DOBBY_COMMIT in app.yml
make dobby
make all overlay-shim iconmaker appinfo
make bridge                                     # Wine tree, lsteamclient, steam.exe (slow on first run)
make fonts                                      # needs fontforge, gpatch, afdko, fonttools
make app-payload app                            # out/Bridgeplay.app
```

The checks the workflows run (`make -s <target>`). `make ci-checks` runs all of them except the
lint targets, and its list is `CI_CHECKS` in the Makefile:

- **Lint:** `scriptcheck`, `runcheck`
- **App:** `mincheck`, `l10ncheck`, `app-tests` (the Swift tests)
- **C, shell and Python suites:** `sigcheck`, `callscheck`, `np-test-batch-check`, `webpatch-fixtures`, `peicon-fixtures`,
  `panel-behavior`, `spawn-env`, `activatecheck`, `compat-reported-import-check`, `compatcheck`, `compatsvc-check`, `prefixstate-check`,
  `shortcutcheck`, `launch-shell`, `envcheck`, `buildcheck`, `settingscheck`, `routecheck`,
  `bridgecheck`, `envpasscheck`, `prefixnotecheck`, `powernotecheck`, `exitcheck`, `anticheatcheck`, `launchprogresscheck`, `gamedrivecheck`, `launchercheck`, `seedcheck`, `gamefixescheck`, `versioncheck`, `cicheck`,
  `padcheck`, `detourcheck`, `compat-reported-check`, `np-inventory-check`, `np-native-tests`, `native-shim-tests`,
  `native-installercheck`

`make tests-list` prints the test paths. A check whose tool or input is missing prints
`skipped` and exits 0: that is not a pass. Install the tool, or say the check didn't run.

To try a change against your own Steam, run `make deploy` after `make fonts`. It copies
the dylib into `Steam.app` and installs the signatures, fonts and helpers into
`~/Library/Application Support/bridgeplay/`; restart Steam afterwards. Logs go to
`~/Library/Application Support/bridgeplay/bridgeplay.log`.

## Rules

- **Large changes:** open an issue first. Check closed issues and PRs for duplicate work.
  Changes that belong upstream go to NotProton. Port an upstream PR only after it is merged
  there; until then, wait for the maintainer's version.
- **Credit:** code taken from someone else keeps its author. Use `git cherry-pick -x` and
  don't amend or reset the author; a rewrite keeps the original author or adds a
  `Co-authored-by:` line and names the source commit or PR. New third-party code goes in
  [NOTICE](NOTICE). See CONTRIBUTING.md.
- **PR descriptions:** an agent may draft one, filling every section of
  `.github/pull_request_template.md` with the checks actually run and what wasn't tested.
  The contributor reviews it before the PR opens. Replies to people in issues, PRs and
  discussions are written by a human, not generated.
- **Comments:** keep them short. Comment where the code is hard to follow, not where it is
  obvious.
- **Run the checks your change touches** before opening a PR.
- **Licence:** contributions are GPL-3.0. Files under other licences are listed in
  [NOTICE](NOTICE) and keep their terms.
- **The hard parts interact in subtle ways:** code inside Steam, the run script,
  lsteamclient, Wine patches and game saves. Design for several Steam accounts on one Mac,
  several Steam library folders (including external drives), several macOS users sharing
  one `/Applications/Steam.app`, and volumes that are case-sensitive or not APFS. The app
  must not rewrite `Steam.app` or Steam's config files while Steam is running (Steam
  rewrites `config.vdf` when it quits). Never lose a game's save or prefix data.
- **Wine patches:** a patch change is not finished until the binary it produces is
  rebuilt with the recipe in [docs/WINECX.md](docs/WINECX.md) or the patch folder's
  README. Then update its sha256 pins (in `docs/WINECX.md` and
  `app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift`, plus
  `app/Sources/BridgeplayApp/Support/SignedPin.swift` for a `.so` or `.dylib`) and its
  entry in [NOTICE](NOTICE). Don't commit a binary without its patch.
- **Legacy names stay:** existing installs depend on `notproton.dylib`, the `NOTPROTON_*`
  variables, `com.notproton.*` identifiers and the fallback to the old `notproton` support
  folders. Don't rename them. User-facing names are Bridgeplay's (`BRIDGEPLAY_*`).
- **Localization:** user-facing app strings are localized (en, it, zh-Hans) in
  `app/Sources/BridgeplayApp/Resources/Localization/Localizable.xcstrings`. `make l10ncheck`
  checks them.
- **Versions:** version bumps are separate `chore(release)` commits made with
  `scripts/bump-version.sh`; see [docs/RELEASING.md](docs/RELEASING.md).
- **Commits:** Conventional Commits, e.g. `feat(setup): …`, `fix(migration): …`,
  `docs: …`.
