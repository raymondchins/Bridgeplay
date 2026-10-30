# Local build

`scripts/build-local.sh` builds the full app on an Apple Silicon Mac with the same make
targets, in the same order, as `.github/workflows/app.yml`.

## Prerequisites

- Xcode 27 at `/Applications/Xcode-beta.app` or `/Applications/Xcode.app`. The script
  exports `DEVELOPER_DIR` for its own process, so the Command Line Tools can stay the
  active developer dir and you don't need `xcode-select`. To use a different Xcode, set
  `DEVELOPER_DIR` yourself.
- Homebrew: `brew install cmake mingw-w64 bison flex fontforge gpatch` (bison must be
  Homebrew's, at `/opt/homebrew/opt/bison/bin`). `shellcheck` and `node` are optional; without
  them the lint and panel checks skip.
- Font tools: the script installs afdko and fonttools into `scratch/fontvenv`, at the versions
  in `FONT_TOOLS` in app.yml. A direct `make fonts` needs those tools on `PATH`.
- Network on the first run: Dobby, Wine 11.15 (gitlab.winehq.org), the Proton tarball,
  the font tools and Sparkle.

## Commands

```sh
scripts/build-local.sh            # build only
scripts/build-local.sh --checks   # build, then `make ci-checks` (the list CI runs) and the Swift tests
```

`JOBS=n` overrides the parallelism (default: `hw.ncpu`). Every phase also writes its
output to `build/logs/<phase>.log`.

## Outputs

| Path | What |
|---|---|
| `build/Bridgeplay.app` | app signed ad hoc (or with `BRIDGEPLAY_SIGN_IDENTITY` when set), passes `codesign --verify --strict` |
| `build/Bridgeplay.zip` | `ditto -c -k --keepParent` of the app, as CI packages it |
| `out/Bridgeplay.app` | the bundle `make app` writes; the script copies it to `build/` |

At the end the script prints the version (from `dylib/version.h`: `make app` writes
`BRIDGEPLAY_VERSION` into `CFBundleShortVersionString` and `BRIDGEPLAY_BUILD` into
`CFBundleVersion`, see [RELEASING.md](RELEASING.md)) and the zip's sha256. A beta build prints its
stamped label instead (see "Betas" in RELEASING.md).

## Timings (M5 Max, 18 cores, Xcode 27.0 beta 27A5218g)

| Phase | Cold | Warm |
|---|---|---|
| dobby | 4s | skipped |
| all (dylib) | 1s | 0s |
| overlay-shim | 1s | 0s |
| helpers (iconmaker, appinfo) | 3s | 0s |
| bridge | 14m00s | 13s |
| app-payload | 0s | 0s |
| app | 42s | 13s |
| checks (`--checks`, side by side) | about 1m05s | 55s |
| total | about 15m, about 16m with checks | 27s, 1m22s with checks |

A `fonts` phase (the Proton font build, needs fontforge and the font tools) also runs; it is
not in the table because it was added after these timings.

The cold bridge phase breaks down roughly as follows:

| Step | Time |
|---|---|
| Wine shallow clone | about 8m30s (network) |
| two configures | about 1m10s |
| `ntdll.so` for both trees | about 10s |
| lsteamclient and steam.exe | about 4m15s |

The lsteamclient unix halves compile their 219 files one at a time in
`lsteamclient/build.sh`, so `-j` cannot speed that step up.

## Caches

Re-runs are incremental because everything CI restores from `actions/cache` stays on
disk. All of these paths are gitignored:

| Path | Contents | Size |
|---|---|---|
| `vendor/dobby`, `build/dobby` | Dobby at the pinned commit; rebuilt only when `DOBBY_COMMIT` in app.yml changes | 5 MB |
| `scratch/wine` | Wine 11.15 source, plus `register-components.diff` | 551 MB |
| `scratch/wine-build-dual` | x86_64 cross tree: PE halves, rosetta unix half, steam.exe | 341 MB |
| `scratch/wine-build-arm64` | arm64 tree: FEX unix half | 134 MB |
| `scratch/proton-lsc` | Proton tarball for lsteamclient | 182 MB |
| `app/.build` | SwiftPM build and the Sparkle checkout | 772 MB |

`setup-wine-tree.sh` skips anything that already exists. When `setup-wine-tree.sh` or
`register-components.diff` changes, the script prints a warning. To rebuild fresh the way
CI would, run `rm -rf scratch/wine scratch/wine-build-dual scratch/wine-build-arm64 scratch/.wine-key`.

The bridge phase is skipped when `scratch/.bridge-key` (written after each bridge build)
matches `scripts/bridge-key.sh`, a hash of `bridge/`, `lsteamclient/` and `steam-shim/`, the
same sources CI keys its bridge cache on.

### A new worktree

The Wine build trees record their source tree by absolute path (`srcdir = <repo>/scratch/wine`),
so they can't be copied, and two checkouts building in one shared tree would overwrite each
other's bridge. Seed the worktree instead, then build:

```sh
scripts/worktree-seed.sh      # from the main worktree; or pass another checkout
scripts/build-local.sh
```

The seed clones (APFS `cp -c`: instant, no extra disk) Dobby, the fonts and their stamp, the
Proton tarball and, when both checkouts have the same bridge sources, the five bridge outputs.
The font venv is linked. Measured on the M5 Max: the seed takes 1–2s and the first build 45s,
instead of about 15m. When the bridge sources differ, the Wine source is cloned instead and the
bridge is built in the worktree without the 8m30s clone: 3m21s, 4m05s for the whole build.
`app/.build` is not seeded: SwiftPM records absolute paths, and a cold app build is 35s.

## Sparkle link for the Swift tests

On Xcode 27 beta 27A5218g, SwiftPM leaves `app/.build/out/Products/Debug/PackageFrameworks`
empty. The Swift test bundle only looks for `Sparkle.framework` there, so it fails to
load before any test runs. `make app-tests`, which CI and `--checks` both run, builds the
tests and then links `PackageFrameworks/Sparkle.framework` to `../Sparkle.framework`. That
link is a build-product fix-up; no source changes.
