# Releasing Bridgeplay

Every release is a GitHub release of `raymondchins/Bridgeplay` carrying `Bridgeplay.zip`
(the Sparkle update), `appcast.xml`, `Bridgeplay.dmg` (the download bridgeplay.dev links to:
the app in a disk image with an Applications link, built by `scripts/package-dmg.sh` after
the appcast so Sparkle never indexes it) and the small native installer,
`Bridgeplay-Setup.zip`. All three are notarized, so macOS only asks once whether to open
them. The native installer also downloads the `installer`
release's `Bridgeplay-Installer.zip` for GPTK, the engine and the configs, checked against
the `Bridgeplay-Installer.zip.sig` that `release-local.sh` signs and uploads beside it. The one-click `Bridgeplay-Installer.zip` lives on its own prerelease, tag
`installer`. It carries no app: `Install.command`
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

## Betas

The committed `BRIDGEPLAY_VERSION` is always a plain `X.Y.Z`, on `main` and on `dev`, so merging
`main` into `dev` never conflicts over a version. A beta's label, build number and channel are
stamped into the app at build time by `scripts/stamp-beta.sh` and never committed;
`bump-version.sh`, `stamp-beta.sh` and `make app` refuse a beta label in `dylib/version.h`.

```sh
BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=46 scripts/build-local.sh        # or make app
BRIDGEPLAY_BETA=2 BRIDGEPLAY_BETA_BUILD=47 BRIDGEPLAY_BETA_PLANNED=0.8.0 make app
```

| Variable | Meaning |
|---|---|
| `BRIDGEPLAY_BETA` | The beta number N, a positive integer. Setting it at all asks for a beta; anything but a positive integer fails the build, and so does setting the two below without it |
| `BRIDGEPLAY_BETA_BUILD` | The build number: the highest build ever published, stable or beta, plus one. Required, and above the committed build, so the beta orders above the stable it branched from |
| `BRIDGEPLAY_BETA_PLANNED` | The release the beta is named after. Defaults to the next patch of the committed version; name a milestone minor (`0.8.0`) to override it. Must be above the committed version |

A beta built from committed `0.7.2` therefore reads `0.7.3-beta.1` by default (`CFBundleShortVersionString`,
shown in About, Status and game reports), carries the build it was given (`CFBundleVersion`) and
`BridgeplayChannel` `beta` in `Info.plist`; a normal build keeps the committed version and build and
the `stable` channel `app/Info.plist` ships with. A missing or unreadable channel means stable.
Installs and updates are ordered by the build alone, never by the label (`AppVersion.deployKey`),
which is why every published build, prerelease or not, must take a higher number than all before it.

The stable that ships the beta is bumped as the version policy says, usually a patch, to the number
the beta was named after, and takes the highest published build into account so it outranks every beta:

```sh
scripts/bump-version.sh patch --named 0.7.3 --highest-build 47    # minor --named 0.8.0 for a milestone
```

`--named` fails the bump when it would land anywhere else, and `BRIDGEPLAY_HIGHEST_BUILD` can stand in
for `--highest-build`. Without it the bump only knows the committed build, so give it the real maximum.

Betas are built from `dev`, and upstream merges go there: `scripts/sync-upstream.sh` merges and
commits no version bump on it (`BRIDGEPLAY_BETA_BRANCH` names the branch, default `dev`). On `main`, the exception for a security or
crash hotfix from upstream, it still bumps the patch.

`release-local.sh` does not publish betas: a stamped build no longer matches `dylib/version.h`, so
its version check stops it. `make versioncheck` covers the stamp, the bump and the sync.

## Steps

0. Push the changes first and wait for the `app` workflow to pass on them
   (`gh run watch -R raymondchins/Bridgeplay`, about 10 minutes, free on this public repo).
   The release then reuses that result instead of running the checks again here. A docs-only run
   (the gate green, build and checks skipped) does not count; the release falls back to an older run
   of the same sources or runs the checks here.
1. Bump and commit:
   ```sh
   scripts/bump-version.sh patch        # or minor / major, or set X.Y.Z
   git commit -m "chore(release): Bridgeplay X.Y.Z" dylib/version.h
   ```
   `set X.Y.Z` takes any version above the committed one, such as `0.7.31` after `0.7.3` for a
   small follow-up. The numbers compare as integers, so `0.7.31` sorts above `0.7.4`: after it,
   go on with `0.7.32` (or `patch`) or a minor. Updates still order by the build, which goes up by one.
   `scripts/sync-upstream.sh` already bumps the patch after an upstream merge on `main`; on `dev` it
   commits no bump, see Betas.
2. Push to `main` of `raymondchins/Bridgeplay` (the script refuses anything else).
3. Optionally rehearse: `scripts/release-local.sh --dry-run` writes the zip, appcast and
   an ad hoc native installer ZIP to
   `out/release/` from an app already built with `make app`, without publishing or reading
   the keychain.
4. Release: `scripts/release-local.sh` (notes default to the commit subjects since the
   previous `vX.Y.Z` release; pass a string to override). It builds with
   `scripts/build-local.sh --checks`, signs the app with the maintainer's Developer ID and
   notarizes it (see Signing), signs the zip with the EdDSA key in the login keychain, writes an appcast with `minimumSystemVersion` 26.0, packages the installer from the
   same app (`scripts/package-installer.sh`). It also builds the native installer ZIP with the same
   Developer ID, notarized, and attaches it beside the product ZIP and appcast on `vX.Y.Z` Latest.
   The existing bundled installer ZIP remains on the separate `installer` tag.

Any other release in the repository (a DXMT build, say) must be created with
`--latest=false`, or the feed URL stops serving `appcast.xml` until the next app release.

## What users see

- The app checks once a day (`SUScheduledCheckInterval` 86400), downloads the update in
  the background and installs it when Bridgeplay quits (`SUAutomaticallyUpdate`). Check
  for Updates… in the app menu does it on demand.
- On the next launch, if the patch inside Steam is from an older Bridgeplay, the app
  re-applies it by itself once Steam and every game are closed. While Steam or a game is
  open, a banner says so and the Status row shows "Update available". The app looks again
  when it comes to the front and every five minutes, so no relaunch is needed.

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
  Settings still looks on, but no longer applies. Releases are therefore signed with the
  maintainer's Developer ID (Team `AF38EA29BA`), and the requirement becomes
  `identifier "com.bridgeplay.Bridgeplay" and anchor apple generic and … certificate
  leaf[subject.OU] = AF38EA29BA`, the same for every build and every renewed certificate of
  that team.
- **Notarization** lets Gatekeeper open a downloaded copy without Open Anyway. Apple scans
  the signed app; `scripts/notarize.sh` submits it with `notarytool`, staples the ticket and
  checks that `spctl` reports `Notarized Developer ID`. It needs the hardened runtime and a
  secure timestamp on every Mach-O file, which only a Developer ID gets.

`make app` signs with `APP_SIGN_ID`, which defaults to `$BRIDGEPLAY_SIGN_IDENTITY` and
then to ad hoc (`-`), so any checkout still builds. Everything inside is signed with the
same identity first, inside out: Sparkle's helpers (`Autoupdate`, `Updater.app`, its XPC
services) and every Mach-O file in the payload, each under the explicit identifier
`PAYLOAD_SIGN_IDS` in the Makefile gives it. `make app` stops if the payload holds a Mach-O
file that list does not name, so a new helper needs an entry there. With a Developer ID
(`APP_SIGN_FLAGS` in the Makefile) every signature gets `--options runtime --timestamp`;
ad hoc and self-signed builds get neither, since library validation needs a Team ID. A
Developer ID build also re-signs the Wine binaries and libSDL2 in `Resources/`, which are
committed ad hoc and pinned; `SignedPin.swift` keeps their pins valid (see
[WINECX.md](WINECX.md), Shipped binaries). `release-local.sh` stops before notarizing if any
Mach-O file in the app lacks the Developer ID or a timestamp. The app
needs no entitlements: it sends no Apple Events (the Rosetta prompt's `do shell script` runs
inside `osascript`) and loads only its own and Apple's code. `scripts/release-local.sh` uses
`BRIDGEPLAY_SIGN_IDENTITY` (default `Developer ID Application: Raymond Chin (AF38EA29BA)`)
and the notarytool profile `BRIDGEPLAY_NOTARY_PROFILE` (default `bridgeplay-notary`), stops
before building if either is missing, checks the designated requirement, the hardened runtime
and the timestamp, then notarizes and staples the app before zipping it. Sparkle accepts the
change of certificate because the EdDSA key stays the same (`SUUpdateValidator`). Changing
the team changes the requirement, and every user has to grant App Management once more; the
first Developer ID release, coming from `Bridgeplay Release`, does that once as well.
`installer/Install.command` accepts either signer, so an older installer zip keeps working.

### The payload helpers

| Payload file | Identifier | Runs as |
|---|---|---|
| `notproton.dylib` | `com.bridgeplay.notproton` | inside Steam; the app re-signs Steam's copy with the local identity below |
| `overlay-shim.dylib` | `com.bridgeplay.overlay-shim` | inserted into the game's Wine loader |
| `iconmaker`, `appinfo` | `com.bridgeplay.iconmaker`, `com.bridgeplay.appinfo` | command-line tools the run script calls |
| `bridge/*-unix-lsteamclient.so` | `com.bridgeplay.lsteamclient` | loaded by Wine |

None of them is launched by launchd or LaunchServices, so none is its own responsible
process: macOS charges Bluetooth, Input Monitoring and the other privacy checks to the
process that started the chain, which is Steam (signed on each Mac with `NotProton Local
Signing`, `LocalSigning.swift`) or Bridgeplay itself. Signing them with the release identity
keeps their requirement stable all the same, should one of them ever hold a permission of
its own. Signing does not change what loads where: the processes these load into (Steam,
re-signed locally, and the Wine loaders) have no library validation, so they take a library
from any signer. The committed Wine and SDL binaries in `Resources/` keep their own signatures,
since their sha256 is pinned (`FreeEngineWinecx.swift`). `np-native` and
`libnp_gamepad.dylib` are not in the app and stay ad hoc.

To check a build:

```sh
p=out/Bridgeplay.app/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload
for f in $(find "$p" -type f); do file -b "$f" | grep -q ^Mach-O && codesign -d -r- "$f" 2>&1 | grep designated; done
```

Each line should end in `certificate leaf[subject.OU] = AF38EA29BA`, the app's team. `scripts/release-local.sh` stops if any of them is not signed by the identity. The
first release with signed helpers moves them from ad hoc to the certificate once; if a user
ever granted one of them a permission directly, they grant it once more after that update.

### Setting up the Developer ID (once per Mac)

1. In https://developer.apple.com/account/resources/certificates/add create a **Developer ID
   Application** certificate (G2 Sub-CA) from a CSR, download it and import it with its
   private key into the login keychain. `security find-identity -v -p codesigning` lists it.
2. Back it up: Keychain Access, My Certificates, Export as `.p12` with a password. Keep the
   `.p12` and the password apart (cloud drive and password manager). On a new Mac,
   double-click the `.p12`.
3. Create an app-specific password at https://account.apple.com/account/manage, then
   `xcrun notarytool store-credentials bridgeplay-notary --apple-id <id> --team-id AF38EA29BA`.

Renew the certificate before its expiry date (Keychain Access shows it). A renewed certificate of the
same team keeps the designated requirement.

### The old self-signed identity

Releases up to the switch were signed with `Bridgeplay Release`. `scripts/make-release-cert.sh`
still creates the self-signed `Bridgeplay Release` code signing identity (RSA 3072, 20 years)
in the login keychain, asks for a backup password (12 characters or more) and writes
`~/Desktop/Bridgeplay-Release.p12`. Move the `.p12` and its password into a password
manager and delete the file from the Desktop; on a new Mac, double-click the `.p12` to
import it. Without the backup, a new certificate means one more App Management grant for
every user. Do not change the certificate's Trust settings. The first `make app` with the
identity asks for access to its key; choose Always Allow.

## CJK fonts

The Chinese, Japanese and Korean fonts (Makefile `CJK_FONTS`, about 85 MB) are not in the app.
`CJKFonts.swift` downloads them once the fonts folder exists, from a `fonts-cjk-<id>`
prerelease, and checks the archive and every font against its pins. Existing installs already
have them from earlier apps, so they download nothing. When `fonts/` changes:

1. `make fonts`, then `scripts/package-fonts.sh`. The archive is reproducible, and `<id>` comes
   from the fonts, so unchanged fonts give the same name and pins.
2. Copy the pins it prints into `CJKFonts.swift`.
3. `scripts/package-fonts.sh --publish` creates the release. `release-local.sh` stops while the
   pinned archive is missing on GitHub.

## Compatibility reports

The app's one-tap reports go to `https://bridgeplay.dev/api/report` (bridgeplay-web,
`api/report.mjs`), which posts each one as a Discussion in the `compatibility-reports`
category of this repository. `api/compat.mjs` counts them (only posts by the report bot)
for the compatibility page, cached for an hour; `compat/games.json` holds the results a
maintainer checked and wins over them. Both functions post and read as the
[Bridgeplay Reports](https://github.com/settings/apps/bridgeplay-reports) GitHub App
(`bridgeplay-reports[bot]`), installed on this repository only with Discussions read and
write. Its Vercel env vars are `BRIDGEPLAY_APP_ID`, `BRIDGEPLAY_APP_INSTALLATION_ID` and
`BRIDGEPLAY_APP_PRIVATE_KEY`. Reports from before 2026-10-22 were posted with a personal
token and carry the owner's login; they still count.

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
