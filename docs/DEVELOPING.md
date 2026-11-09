# Developing Bridgeplay

How to build Bridgeplay, try a change inside Steam, and run the checks. What each folder is
and where new code goes: [ARCHITECTURE.md](ARCHITECTURE.md). How to send a change:
[CONTRIBUTING.md](../CONTRIBUTING.md).

## What you need

| You want to | You need |
|---|---|
| Lint the shell scripts and the run script | Any OS with shellcheck 0.11.0: `make scriptcheck runcheck` |
| Build the app, the dylib and the Wine bridge; run the C and Swift tests | An Apple Silicon Mac, macOS 26 or later, Xcode 27 and Homebrew. Packages and caches: [BUILD-LOCAL.md](BUILD-LOCAL.md) |
| Try a change in Steam, run games | The above, plus Steam and Apple's Game Porting Toolkit (the app's Setup Assistant gets both) |
| Package the native installer locally | The Mac above: `make native-installer` builds an ad hoc `out/Bridgeplay-Setup.zip`, with no Wine, GPTK or keys |
| Package `Bridgeplay-Installer.zip` | A Mac with the engine cache and GPTK set up by the app: `scripts/package-installer.sh` ([installer/README.md](../installer/README.md)) |
| Publish a release | The maintainer's Mac: the above, plus the Sparkle key, the Developer ID and the notary profile. See [RELEASING.md](RELEASING.md) |

## Build

```sh
scripts/build-local.sh            # full build: dylib, shims, helpers, Wine bridge, fonts, app
scripts/build-local.sh --checks   # the same, then `make ci-checks`
```

A cold build takes about 15 minutes, almost all of it the Wine bridge; later builds take
under a minute. Prerequisites, outputs, caches, timings and how to seed a new worktree are
in [BUILD-LOCAL.md](BUILD-LOCAL.md).

If a tool fails with a long error, read it before pasting it anywhere: some Xcode tools
print the whole shell environment, secrets included, when they fail to launch.

## Try a change in Steam

1. Quit Steam.
2. `make deploy` (after `make fonts`, or a full build) copies `notproton.dylib` into
   `Steam.app/Contents/MacOS/` and installs the signature database, fonts, `iconmaker` and
   `appinfo` into `~/Library/Application Support/bridgeplay/`. It sets the app's build record
   aside so the next app install sees an update, and warns when a built `Bridgeplay.app`
   carries a different dylib (launching it would undo the deploy).
3. For app changes, run the built `build/Bridgeplay.app` and press Install on its Status page.
4. Start Steam and launch a game.

A built app is not a dry run: once idle after launch, it re-applies its Steam patch when
Steam carries an older one, and updates installed engines whose pins changed
(`PostUpdateRefresh`). To try the Setup Assistant without
changing anything, build the debug app (`swift build --package-path app --product BridgeplayApp`;
the full build makes only the release one) and run
`app/.build/debug/BridgeplayApp --setup-preview [--fresh] [--step N]`. If it stops with
`Library not loaded: @rpath/Sparkle.framework`, start it with
`DYLD_FRAMEWORK_PATH=app/.build/out/Products/Debug`.

Logs:

| Log | Where |
|---|---|
| Steam side (dylib) | `~/Library/Application Support/bridgeplay/bridgeplay.log` |
| One game's launch and Wine output | `bridgeplay-run.log`, `bridgeplay-wine.log`; Prefixes page › a game › Open Log |
| The app | Setup › Reveal Log in Finder |

## Checks

| Command | Runs |
|---|---|
| `make ci-checks` | Every check the `app` workflow runs. The list is `CI_CHECKS` in the Makefile |
| `make scriptcheck runcheck` | shellcheck over the build scripts and the run script; the `lint` workflow, also on Linux |
| `make app-tests` | The Swift tests |
| `make <target>` | One suite, by its name in `CI_CHECKS` |
| `make tests-list` | The folders that hold tests |

A check whose tool or input is missing prints `skipped` and exits 0. That is not a pass:
install the tool, or say the check didn't run.

On GitHub, the `lint` workflow runs on Linux. The `app` workflow first decides on Linux whether
a change is docs-only (`.github/docs-only-paths`); if not, it builds and runs the checks on
macOS. Either way it ends in the `app gate` job.

## Scripts outside the build

| Script | Use |
|---|---|
| `scripts/np-test-game.sh`, `np-test-batch.sh` | Launch a game (or a list) with Bridgeplay and record the result under `compat/runs/` |
| `scripts/np-inventory.py`, `np-seed-games.py`, `np_lookup.py`, `compat-table.py` | Build and query `compat/games.json` and the compatibility table |
| `scripts/steam-launch-options.py` | Prepend a token to some games' Steam launch options (Steam must be closed) |
| `scripts/sync-upstream.sh` | Merge NotProton upstream; on `main` it also bumps the patch version ([RELEASING.md](RELEASING.md#betas)) |
| `scripts/update-gamecontrollerdb.sh` | Refresh the SDL controller mappings at a pinned commit |
| `scripts/worktree-seed.sh` | Seed a new worktree's build caches ([BUILD-LOCAL.md](BUILD-LOCAL.md#a-new-worktree)) |

The inherited NotProton README is kept in [UPSTREAM.md](UPSTREAM.md).
