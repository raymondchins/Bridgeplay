# Developing Bridgeplay

How to build Bridgeplay, try a change inside Steam, and run the checks. For what each folder
is and where new code goes, read [ARCHITECTURE.md](ARCHITECTURE.md). The inherited upstream
README (NotProton, NotProton-WineHQ) is kept in [UPSTREAM.md](UPSTREAM.md).

## What you need

| You want to | You need |
|---|---|
| Lint shell scripts, check the run script | Any OS with shellcheck 0.11.0: `make scriptcheck runcheck` |
| Build the app, the dylib, the Wine bridge; run the C and Swift tests | An Apple Silicon Mac, macOS 26 or later, Xcode 27 (`/Applications/Xcode-beta.app` or `/Applications/Xcode.app`), Homebrew |
| Try a change in Steam, run games | The above, plus Steam installed and Apple's Game Porting Toolkit (see the app's Setup Assistant) |
| Package the installer or publish a release | The maintainer's Mac (engine cache, GPTK, Sparkle key in the keychain); see [RELEASING.md](RELEASING.md) |

Homebrew packages:

```sh
brew install cmake mingw-w64 bison flex fontforge gpatch shellcheck node
```

`/opt/homebrew` is assumed (Homebrew's bison and the Wine tree setup look there). Without
`shellcheck` or `node` the lint and panel checks skip.

`scripts/build-local.sh` installs the font tools (afdko and fonttools, pinned by `FONT_TOOLS` in
`.github/workflows/app.yml`) into `scratch/fontvenv`. A direct `make fonts` needs them on `PATH`.

## Build

```sh
scripts/build-local.sh            # full build: dylib, shims, helpers, Wine bridge, app
scripts/build-local.sh --checks   # the same, then `make ci-checks` and the Swift tests
```

A cold build takes about 15 minutes, almost all of it the Wine bridge; later builds take
under a minute. Outputs, caches and timings are in [BUILD-LOCAL.md](BUILD-LOCAL.md).

If a tool fails with a long error, read it before pasting it anywhere: some Xcode tools
print the whole shell environment, secrets included, when they fail to launch.

## Try a change in Steam

1. Quit Steam.
2. `make deploy` installs the dylib, the signature database, fonts and helpers into
   `~/Library/Application Support/bridgeplay/`. For app changes, run the built
   `build/Bridgeplay.app` and press Install on its Status page.
3. Start Steam and launch a game.

Logs:

| Log | Where |
|---|---|
| Steam side (dylib) | `~/Library/Application Support/bridgeplay/bridgeplay.log` |
| One game's launch and Wine output | `bridgeplay-run.log`, `bridgeplay-wine.log`; Prefixes page › a game › Open Log |
| The app | Setup › Reveal Log in Finder |

To try the Setup Assistant without changing anything:
`app/.build/debug/BridgeplayApp --setup-preview [--fresh] [--step N]` (debug builds only).
If it stops with `Library not loaded: @rpath/Sparkle.framework`, start it with
`DYLD_FRAMEWORK_PATH=app/.build/out/Products/Debug`.

## Checks

| Command | Runs |
|---|---|
| `make ci-checks` | Every check CI runs (the list lives in the Makefile; `.github/workflows/app.yml` and `build-local.sh --checks` both call it) |
| `make scriptcheck runcheck` | shellcheck over the build scripts and the run script (also runs on Linux) |
| `make app-tests` | The Swift tests |
| `make <name>check` | One suite; see `make ci-checks` for the names |

Run the checks your change touches before opening a pull request, and say which ones in
the PR.

## Scripts that are not part of the build

| Script | Use |
|---|---|
| `scripts/np-test-game.sh`, `np-test-batch.sh` | Launch a game (or a list) with Bridgeplay and record the result under `compat/runs/` |
| `scripts/np-inventory.py`, `np-seed-games.py`, `np_lookup.py`, `compat-table.py` | Build and query `compat/games.json` and the compatibility table |
| `scripts/steam-launch-options.py` | Read or set a game's Steam launch options |
| `scripts/sync-upstream.sh` | Merge NotProton upstream and bump the minor version |
| `scripts/update-gamecontrollerdb.sh` | Refresh the SDL controller mappings at a pinned commit |

## Conventions

- Commits follow Conventional Commits: `feat(scope):`, `fix(scope):`, `docs:`, `chore(release):`.
- Comments explain why, where the code is not obvious. Match the style of the file you edit.
- Shipped binaries in `app/Sources/BridgeplayApp/Resources/` are built from the recipe in
  their patch folder's README; a PR that changes one says how it was rebuilt.
- Runtime names (`notproton.dylib`, `NOTPROTON_*`, `com.notproton.*`) stay as they are:
  renaming them would need another migration. Paths and logs use `bridgeplay`.
