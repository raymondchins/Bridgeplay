# Releasing Bridgeplay

Every release is a GitHub release of `raymondchins/Bridgeplay` carrying `Bridgeplay.zip` and
`appcast.xml`. The one-click `Bridgeplay-Installer.zip` lives on its own prerelease, tag
`installer` (bridgeplay.dev/download redirects to
`releases/download/installer/Bridgeplay-Installer.zip`). It carries no app: `Install.command`
downloads the Latest release's `Bridgeplay.zip` when it runs, so `release-local.sh` uploads
the installer again only when its fingerprint (every file it ships) changes, which is when
the engines, GPTK, the configs or the installer itself change. A release whose sources
already passed `make ci-checks`, here or in the `app` workflow on GitHub (only the version
bump differs), skips them;
`BRIDGEPLAY_FORCE_CHECKS=1` runs them anyway. Installed apps read
`https://github.com/raymondchins/Bridgeplay/releases/latest/download/appcast.xml`
(`SUFeedURL`), so whatever release is marked **Latest** is the update feed.

## Version scheme

`dylib/version.h` holds three numbers; `make app` stamps them into the app.

| Define | Meaning | In the app | In the appcast |
|---|---|---|---|
| `BRIDGEPLAY_VERSION` | Bridgeplay semver, kept slow (it went from 3.5.0 back to 0.7.0 in build 44, so it never orders installs): patch for every normal release (fixes, features, upstream NotProton merges), so 3.5.12 is fine. Minor only for a milestone chosen on purpose (a new engine or backend, a big redesign). Major only for breaks (prefix, save or install layout). Bundle changes into one release rather than releasing per merge | `CFBundleShortVersionString`, About, Status | `sparkle:shortVersionString`, tag `v<version>` |
| `BRIDGEPLAY_BUILD` | +1 on every release; Sparkle orders updates by it | `CFBundleVersion` | `sparkle:version` |
| `NOTPROTON_VERSION` | the upstream release this is based on, exactly as upstream ships it | `NotProtonVersion`, About ("based on NotProton 1.2.0") | release notes |

The build number continues the old counter, so the first Bridgeplay release orders after
every NotProton-WineHQ build:

| Old release | Old `CFBundleVersion` | New |
|---|---|---|
| `1.1.9-winehq.1-ray.31` (last shipped) | `1.1.9.31` | — |
| `1.2.0-winehq.1-ray.32` (never released) | `1.2.0.32` | Bridgeplay `2.0.0`, build `32` |
| next fix | — | `2.0.1`, build `33` |
| next upstream merge | — | `2.1.0`, build `34` |

Sparkle compares `32` with `1.1.9.31` part by part, so `32 > 1` makes it newer. The app
compares the build recorded in Steam numerically (`DeploymentContent`), so since 0.7.0 that
record holds `4.0.<build>` (`AppVersion.deployKey`), not the semver: it sorts past every
older record (`1.2.0-…`, `3.5.0`), and an older app that another macOS user still runs sees
a newer install and leaves it alone. `VersioningTests` guards both.

## Steps

0. Push the changes first and wait for the `app` workflow to pass on them
   (`gh run watch -R raymondchins/Bridgeplay`, about 10 minutes, free on this public repo).
   The release then reuses that result instead of running the checks again here.
1. Bump and commit:
   ```sh
   scripts/bump-version.sh patch        # or minor / major
   git commit -m "chore(release): Bridgeplay X.Y.Z" dylib/version.h
   ```
   `scripts/sync-upstream.sh` already bumps the patch after an upstream merge.
2. Push to `main` of `raymondchins/Bridgeplay` (the script refuses anything else).
3. Optionally rehearse: `scripts/release-local.sh --dry-run` writes the zip and appcast to
   `out/release/` from an app already built with `make app`, without publishing or reading
   the keychain.
4. Release: `scripts/release-local.sh` (notes default to the commit subjects since the
   previous `vX.Y.Z` release; pass a string to override). It builds with
   `scripts/build-local.sh --checks`, signs the app with the `Bridgeplay Release` identity
   (see Signing), signs the zip with the EdDSA key in the login keychain, writes an appcast with `minimumSystemVersion` 26.0, packages the installer from the
   same app (`scripts/package-installer.sh`) and publishes `vX.Y.Z` as Latest with all three.

Any other release in the repository (a DXMT build, say) must be created with
`--latest=false`, or the feed URL stops serving `appcast.xml` until the next app release.

## What users see

- The app checks once a day (`SUScheduledCheckInterval` 86400), downloads the update in
  the background and installs it when Bridgeplay quits (`SUAutomaticallyUpdate`). Check
  for Updates… in the app menu does it on demand.
- On the next launch, if the patch inside Steam is from an older Bridgeplay, the app
  re-applies it by itself once Steam and every game are closed. If Steam is open, the
  Status row shows "Update available" until the user installs it or relaunches with Steam
  closed.

## Signing

Two signatures, for different things:

- **Sparkle (EdDSA)** decides whether an update is trusted: its signature must match
  `SUPublicEDKey`, and the archive is checked before extraction
  (`SUVerifyUpdateBeforeExtraction`). Losing that keychain key means no installed copy can
  update again, so keep a backup (`generate_keys -x`).
- **Apple code signing** has to be valid (`codesign --verify --strict --deep`), and its
  designated requirement is what macOS keys permissions to (App Management, which lets
  Bridgeplay patch Steam.app). An ad hoc signature's requirement is the cdhash, which is new
  with every build, so macOS treats each update as a different app: the toggle in System
  Settings still looks on, but no longer applies. Releases are therefore signed with a
  stable self-signed identity, and the requirement becomes
  `identifier "com.bridgeplay.Bridgeplay" and certificate leaf = H"<sha1>"`, the same for
  every build signed with that certificate.

`make app` signs with `APP_SIGN_ID`, which defaults to `$BRIDGEPLAY_SIGN_IDENTITY` and
then to ad hoc (`-`), so any checkout still builds. Everything inside is signed with the
same identity first, inside out: Sparkle's helpers (`Autoupdate`, `Updater.app`, its XPC
services) and every Mach-O file in the payload, each under the explicit identifier
`PAYLOAD_SIGN_IDS` in the Makefile gives it. `make app` stops if the payload holds a Mach-O
file that list does not name, so a new helper needs an entry there. There is no hardened
runtime: library validation needs a Team ID, which a self-signed certificate does not have. `scripts/release-local.sh` uses `BRIDGEPLAY_SIGN_IDENTITY` (default
`Bridgeplay Release`), refuses ad hoc, stops if the identity is not in the keychain, prints
the designated requirement and stops unless it is the certificate form signed by that
identity. Changing the identity or its certificate, or marking it trusted (which can turn
`certificate leaf` into `certificate root`), changes the requirement, and every user has to
grant App Management once more. The first release signed this way does that once as well,
coming from ad hoc.

### The payload helpers

| Payload file | Identifier | Runs as |
|---|---|---|
| `notproton.dylib` | `com.bridgeplay.notproton` | inside Steam; the app re-signs Steam's copy with the local identity below |
| `overlay-shim.dylib`, `game-host.dylib` | `com.bridgeplay.overlay-shim`, `com.notproton.game-host` | inserted into the game's Wine loader |
| `controllers/dualsense/bridge.dylib`, `controllers/steam-input/rumble.dylib` | `com.notproton.dualsense.bridge`, `com.notproton.steam-input.rumble` | inserted into the game's Wine loader |
| `controllers/dualsense/launch`, `controllers/dualsense/broker` | `com.notproton.dualsense.launch`, `com.notproton.dualsense.broker` | child processes of the run script |
| `iconmaker`, `appinfo`, `prepare-game-loader` | `com.bridgeplay.iconmaker`, `com.bridgeplay.appinfo`, `com.notproton.game-metadata` | command-line tools the run script calls |
| `bridge/*-unix-lsteamclient.so` | `com.bridgeplay.lsteamclient` | loaded by Wine |

None of them is launched by launchd or LaunchServices, so none is its own responsible
process: macOS charges Bluetooth, Input Monitoring and the other privacy checks to the
process that started the chain, which is Steam (signed on each Mac with `NotProton Local
Signing`, `LocalSigning.swift`) or Bridgeplay itself. Signing them with the release identity
keeps their requirement stable all the same, should one of them ever hold a permission of
its own. Signing does not change what loads where: a self-signed library, like an ad hoc
one, has no Team ID, so a process with library validation refuses both and one without it
takes both. The committed Wine and SDL binaries in `Resources/` keep their own signatures,
since their sha256 is pinned (`FreeEngineWinecx.swift`). `np-native` and
`libnp_gamepad.dylib` are not in the app and stay ad hoc.

To check a build:

```sh
p=out/Bridgeplay.app/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload
for f in $(find "$p" -type f); do file -b "$f" | grep -q ^Mach-O && codesign -d -r- "$f" 2>&1 | grep designated; done
```

Each line should read `identifier "<id>" and certificate leaf = H"<sha1>"`, the same hash as
the app's. `scripts/release-local.sh` stops if any of them is not signed by the identity. The
first release with signed helpers moves them from ad hoc to the certificate once; if a user
ever granted one of them a permission directly, they grant it once more after that update.

### Creating the release identity (once)

```sh
scripts/make-release-cert.sh
```

It creates the self-signed `Bridgeplay Release` code signing identity (RSA 3072, 20 years)
in the login keychain, asks for a backup password (12 characters or more) and writes
`~/Desktop/Bridgeplay-Release.p12`. Move the `.p12` and its password into a password
manager and delete the file from the Desktop; on a new Mac, double-click the `.p12` to
import it. Without the backup, a new certificate means one more App Management grant for
every user. Do not change the certificate's Trust settings. The first `make app` with the
identity asks for access to its key; choose Always Allow.

## Compatibility reports

The app's one-tap reports go to `https://bridgeplay.dev/api/report` (bridgeplay-web,
`api/report.mjs`), which posts each one as a Discussion in the `compatibility-reports`
category of this repository. `api/compat.mjs` counts them (only posts by the report bot)
for the compatibility page, cached for an hour; `compat/games.json` holds the results a
maintainer checked and wins over them. Both functions use the `BRIDGEPLAY_BOT_TOKEN`
Vercel env var: a fine-grained token on this repository with Discussions read and write and
nothing else.

The app asks about a game at most once per Bridgeplay version (an answer, Not Now or an
automatic report all count), so a release is when players get asked again about the games
they play. In between, it asks again only if a game crashes after the player answered
Smooth. Don't Ask About This Game in the card's menu stops the question for that game for
good; Report This Game… on the Prefixes page always asks. It never asks about (or
auto-shares) a game that `compat/games.json` already lists as tested on a Mac with the same
chip (`tested_on`, `reports[].chip` or `reports[].device`, e.g. "M5 Max"); the app reads that
file from `main` at most once a day and caches it, and asks as usual when it can't. Prefix ›
Report Your Games… lists every game with a session in its log, minus those, for answering
in one go; the reports go out one by one, within the endpoint's per-install limit of 50 an
hour.

## Moving NotProton users over

NotProton builds up to `1.1.9-winehq.1-ray.31` read the feed of
`raymondchins/NotProton-WineHQ`, look for `NotProton.app` or `com.notproton.NotProton` in the
archive, and never check on their own (`SUEnableAutomaticChecks` was false).
`scripts/release-local.sh --legacy-feed` also publishes the release there as Latest, with
the same app zipped as `NotProton.app`. Those users get it from Check for Updates…; it
installs over `/Applications/NotProton.app`, and later updates come from the Bridgeplay
feed, matched by bundle identifier.

## The 3.0.0 rename

3.0.0 renames everything on disk from `notproton` to `bridgeplay`:

| Before | From 3.0.0 |
|---|---|
| `~/Library/Application Support/notproton` | `~/Library/Application Support/bridgeplay` |
| `~/Library/Caches/notproton` | `~/Library/Caches/bridgeplay` |
| `~/.notproton` (np-native, libnp_gamepad.dylib) | `~/.bridgeplay` |
| Steam tools `notproton-winecx-11.17`, `notproton-winehq`, … | `bridgeplay-winecx-11.17`, `bridgeplay-winehq`, … |
| `notproton-run.log`, `notproton-wine.log`, `notproton.log` | `bridgeplay-run.log`, `bridgeplay-wine.log`, `bridgeplay.log` |
| `NOTPROTON_*` in launch options and conf files | `BRIDGEPLAY_*` (the old spelling still works) |

Unchanged: `notproton.dylib`, `lib/notproton-backends`, the prefix markers in `compatdata`
(`notproton-build`, `notproton-backend`), the launcher bundle ids
`com.notproton.launcher.<appid>` and the `NOTPROTON_VERSION` define.

The app migrates on its first launch after the update, once Steam and every game are
closed: it moves the folders and switches games mapped to a `notproton*` tool to its
`bridgeplay*` name. What it replaces is backed up under
`~/Library/Application Support/bridgeplay/backups/migration-3.0.0/`. Nothing is needed in the
release steps; `scripts/release-local.sh` and `scripts/package-installer.sh` fall back to the
`notproton` folders on a Mac that has not migrated yet.
