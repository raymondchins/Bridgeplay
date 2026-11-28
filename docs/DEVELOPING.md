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

Crash-loop breaker (`dylib/feats/breaker.c`, `make breakercheck`). Each Steam start is counted
per Steam build and Bridgeplay build in `boot.json` in the same folder. A start that ends
before 120 s after the hooks install, with no clean quit, is a bad start. After two, Steam
starts without Bridgeplay (no hooks, the insert dropped) until Steam or Bridgeplay updates, and
one notification says so. Deleting `boot.json` clears the count ("Try Again"). A file named
`paused` there turns Bridgeplay off at the next Steam start without touching `Steam.app`.
`health.json` (`steam_osx`) and `health-web.json` (Steam Helper, the compat UI gates) say what
the last start did; `BRIDGEPLAY_BREAKER_QUIET=1` skips the notification.

The signed pause list ([pause-list/README.md](../pause-list/README.md), `dylib/feats/pauselist.c`,
`make pauselistcheck`) makes a start passive the same way when it names this Steam build, with
nothing counted. It is off until its public key is in `dylib/feats/pauselist_key.h`;
`BRIDGEPLAY_PAUSE_LIST=0` ignores it.

`health.json`, which the app's Status reads (`SteamHealth.swift`):

| Key | Value |
|---|---|
| `written`, `pid` | Unix seconds, and the `steam_osx` that wrote it |
| `patch_build`, `steam_build`, `channel` | `BRIDGEPLAY_BUILD`; the client's manifest `version` (`0` when unreadable); `package/beta`, else `stable` (`unknown` when odd) |
| `sigdb_build` | the signature database's build |
| `mode`, `strikes` | `active`, `passive` or `off`; bad starts counted on this Steam and Bridgeplay build |
| `mode_reason` | empty while active, else `paused` (the app's Pause), `strikes` or `pause_list` |
| `signatures_resolved`, `signatures_required`, `hooks_installed`, `hooks_total`, `layout_known` | what the install found |
| `pause_list` | the cached list: `ok`, `expired`, `none`, `invalid`, `ignored` or `unkeyed` |
| `pause_list_serial`, `pause_list_expires` | its serial and expiry, `0` without a readable list |
| `pause_note`, `pause_fixed_in`, `pause_url` | the entry that paused this start; empty otherwise |

Background check (Settings › Check Steam in the Background, off by default). It registers
`app/LaunchAgents/com.bridgeplay.Bridgeplay.background.plist` with `SMAppService`, which runs
`BridgeplayApp --background-check` as the user at login. The agent waits on FSEvents for
`Steam.app` and on Steam or the app quitting, then decides with `Model/BackgroundCheck.swift`:
it notifies once per Steam update that removed Bridgeplay, or, in its second mode, runs
`--install-into-steam` once Steam and every game are closed. `paused`, a passive breaker
verdict for this build, Repair Steam and an open Bridgeplay app all stop it. Its lines in the
app log start with `background check:`.

`bridgeplay-run.log` gives each launch step a `time: <step> at <seconds>s` line, counted from
the run script's start, with milliseconds where `/bin/date` has `%N` (macOS 27 does; older
systems use perl, then whole seconds). When the game exits it adds `time: game exited at`, the
first window as the launch panel saw it, and the first Metal frame when the overlay shim is
loaded, both in seconds after the game started.

### The outcome record

After the exit summary, the run script writes `compatdata/<appid>/bridgeplay-last-launch` for
the game launch (verb `waitforexitandrun`, never Steam's helpers), written aside and renamed
over:

| Key | Value |
|---|---|
| `version` | `1` |
| `code` | one word from the table below |
| `exit` | the game's exit status; empty when the game never started |
| `seconds` | how long the game ran, whole seconds; `0` when it never started |
| `stopped` | `steam` (Steam's Stop or Steam quitting), `game` or `unknown` |
| `backend` | the backend id of `notproton-backend` (`d3dmetal`, `dxmt`, `dxvk`, `wined3d`, `dxmt-builtin`); empty before the backend step |
| `engine` | the tool's build (`notproton-build`), such as `winecx-11.17` |
| `window` | whole seconds from the game's start to its first window; empty when the launch panel watched until the game exited and saw none; left out when nothing watched (no app, the panel's 15-minute limit, or a stop before the game started) |
| `ended` | Unix seconds when the record was written |

| Code | When | `stopped` |
|---|---|---|
| `ok` | exit 0 after a minute or more | `game` |
| `quit_early` | exit 0 within a minute, no Wine crash line | `game` |
| `crashed` | a Wine crash line, with exit 0 within a minute, exit 1 or a code not listed here | `game` |
| `generic_failure`, `game_error`, `exit_code` | exit 1, exit 255 (-1), any other code, without a crash line | `game` |
| `abort` (3), `access_violation` (5), `fail_fast` (9), `invalid_parameter` (23), `illegal_instruction` (29), `dll_not_found` (53), `dll_init_failed` (66), `cpp_exception` (99), `heap_corruption` (116), `stack_overflow` (253) | the low byte of a Windows exception code | `game` |
| `sigill` (132), `sigtrap` (133), `sigabrt` (134), `sigfpe` (136), `sigbus` (138), `sigsegv` (139) | Wine died of a crash in Mac-side code | `game` |
| `sighup` (129), `sigint` (130), `sigkill` (137), `sigterm` (143) | Wine was killed from outside Steam | `unknown` |
| `anticheat_driver` | a kernel anti-cheat could not load its Windows driver | `game` |
| `stopped_from_steam` | Steam's Stop, or Steam quitting | `steam` |
| `launch_services` | `BRIDGEPLAY_LAUNCH_SERVICES=1`, so the status is `open`'s | `unknown` |
| `anticheat_blocked` | the kernel anti-cheat prompt got no Launch Anyway | `unknown` |
| `rosetta_missing` | Rosetta 2 is missing and the engine's loader cannot start | `unknown` |
| `engine_missing` | the tool's engine is not set up | `unknown` |
| `engine_unsupported` | Wine through FEX on macOS before 26.5 | `unknown` |
| `aborted` | any other stop before the game started | `steam` when Steam's Stop did it, else `unknown` |

The codes before the game started (the last five) leave `exit` empty and `seconds` at `0`.

### Why it stopped, and a way out of a hang

Right after the record, `launch_ended` starts `BridgeplayApp --launch-ended-panel <compatdata>`
(`LaunchEnded.swift`) reparented to launchd, and the app calls `setsid`, so Steam shows Play
again at once. The app reads the record and shows the Status card's sentence (`LaunchVerdict`)
with one button: See Reports opens `bridgeplay.dev/compatibility/<slug>-<appid>`, which the site
redirects to the game's page (`HelpLinks.gamePage`); a kernel anti-cheat gets Other Ways to
Play. It shows nothing after `ok`, a Steam Stop after a window, a kill from outside Steam,
`launch_services`, `generic_failure`, `game_error` or `exit_code` after a minute (some games
quit with 1), or a stop before the game started (those have their own alerts), nor for a record
older than two minutes. It goes when the game is launched again, or after 30 minutes.
Without the app, or with one from before the flag, nothing is shown.

The launch panel (`LaunchProgress.swift`) asks Keep Waiting or Stop Game after 120 seconds in
step `start` with no game window. Stop Game sends TERM to the run script, as Steam's Stop does,
and the panel stays until the script ends, so the record says `stopped_from_steam` with an empty
`window` and the panel above says the game never opened a window. A question nobody answered
stays up past the panel's 15-minute limit.
`=== session health:` in the run log is separate: `healthy` only after a minute or more
without a crash, `failed` for a crash within the first minute that Steam did not stop, and
`unknown` with its reason otherwise.

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
