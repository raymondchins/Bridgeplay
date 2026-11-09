# Releasing Bridgeplay

Every stable release is a GitHub release of `raymondchins/Bridgeplay`, tag `vX.Y.Z`, marked
**Latest**, with four assets:

| Asset | What it is |
|---|---|
| `Bridgeplay.zip` | The app, notarized; the Sparkle update |
| `appcast.xml` | The Sparkle feed. Installed apps read `https://github.com/raymondchins/Bridgeplay/releases/latest/download/appcast.xml` (`SUFeedURL`), so whatever release is **Latest** is the update feed. Apps enrolled in beta updates, and beta builds leaving them, read the beta feed instead (see Betas) |
| `Bridgeplay.dmg` | The download bridgeplay.dev links to: the app in a disk image with an Applications link (`scripts/package-dmg.sh`), notarized. Built after the appcast so Sparkle never indexes it |
| `Bridgeplay-Setup.zip` | The native installer ([NATIVE-INSTALLER.md](NATIVE-INSTALLER.md)), notarized |

`Bridgeplay-Installer.zip` (GPTK, DXMT, DXVK and the default configs, no app) lives on its own
prerelease, tag `installer`, with a `Bridgeplay-Installer.zip.sig` beside it. `release-local.sh`
rebuilds, signs and uploads it only when its fingerprint changes. The fingerprint covers the
path and content of every regular file it ships, not symlinks: a change to the GPTK's
symlinks alone needs the installer uploaded by hand. Upload the zip together with a new
`.sig`, or the installers reject it: `scripts/package-installer.sh`, then
`app/.build/artifacts/sparkle/Sparkle/bin/sign_update out/Bridgeplay-Installer.zip` and write
its `edSignature` and `length` values, space-separated on one line, to
`Bridgeplay-Installer.zip.sig`. Replace the zip on the `installer` release first, then the
`.sig`, each the way `swap_asset` in `release-local.sh` does: upload it as `next-<name>`,
delete the old asset, then rename the new one to `<name>`. Don't use `--clobber`: it deletes
the old asset first, and installers got 404s for the minutes the upload took (#166).

## Version scheme

`dylib/version.h` holds three numbers; `make app` stamps them into the app.

| Define | Meaning | In the app | In the appcast |
|---|---|---|---|
| `BRIDGEPLAY_VERSION` | Bridgeplay semver, kept slow (it went from 3.5.0 back to 0.7.0 in build 44, so it never orders installs): patch for every normal release (fixes, features, upstream NotProton merges), so 3.5.12 is fine. Minor only for a milestone chosen on purpose (a new engine or backend, a big redesign). Major only for breaks (prefix, save or install layout). Bundle changes into one release rather than releasing per merge | `CFBundleShortVersionString`, About, Status | `sparkle:shortVersionString`, tag `v<version>` |
| `BRIDGEPLAY_BUILD` | +1 on every release; Sparkle orders updates by it | `CFBundleVersion` | `sparkle:version` |
| `NOTPROTON_VERSION` | the upstream release this is based on, exactly as upstream ships it | `NotProtonVersion`, About ("based on NotProton 1.2.0") | release notes |

The build number continues NotProton-WineHQ's counter (its last `CFBundleVersion` was
`1.1.9.31`; Bridgeplay started at build 32). Sparkle compares versions part by part, so `32`
sorts after `1.1.9.31`. The app compares the build recorded in Steam numerically (`DeploymentContent`), so since 0.7.0 that
record holds `4.0.<build>` (`AppVersion.deployKey`), not the semver: it sorts past every
older record (`1.2.0-…`, `3.5.0`), and an older app that another macOS user still runs sees
a newer install and leaves it alone. `VersioningTests` guards both.

## Betas

The committed `BRIDGEPLAY_VERSION` is always a plain `X.Y.Z`, on `main` and on `develop`, so merging
`main` into `develop` never conflicts over a version. A beta's label, build number and channel are
stamped into the app at build time by `scripts/stamp-beta.sh` and never committed;
`bump-version.sh`, `stamp-beta.sh` and `make app` refuse a beta label in `dylib/version.h`.

```sh
BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=46 scripts/build-local.sh        # or make app
BRIDGEPLAY_BETA=2 BRIDGEPLAY_BETA_BUILD=47 BRIDGEPLAY_BETA_PLANNED=0.8.0 make app
```

| Variable | Meaning |
|---|---|
| `BRIDGEPLAY_BETA` | The beta number N, a positive integer. Setting it at all asks for a beta; anything but a positive integer fails the build, and so does setting the two below without it |
| `BRIDGEPLAY_BETA_BUILD` | The build number: H plus one (see Build numbers below), claimed before the build. Required, and above the committed build, so the beta orders above the stable it branched from |
| `BRIDGEPLAY_BETA_PLANNED` | The release the beta is named after. Defaults to the next patch of the committed version; name a milestone minor (`0.8.0`) to override it. Must be above the committed version |

A beta built from committed `0.7.2` therefore reads `0.7.3-beta.1` by default (`CFBundleShortVersionString`,
shown in About, Status and game reports), carries the build it was given (`CFBundleVersion`) and
`BridgeplayChannel` `beta` in `Info.plist`; a normal build keeps the committed version and build and
the `stable` channel `app/Info.plist` ships with. A missing or unreadable channel means stable.
Installs and updates are ordered by the build alone, never by the label (`AppVersion.deployKey`),
which is why every published build, prerelease or not, must take a higher number than all before it.

The stable that ships the beta is bumped as the version policy says, usually a patch, to the number
the beta was named after, and takes H, the highest build, into account so it outranks every beta:

```sh
scripts/bump-version.sh patch --named 0.7.3    # minor --named 0.8.0 for a milestone
```

`--named` fails the bump when it would land anywhere else. Without `--highest-build` (or
`BRIDGEPLAY_HIGHEST_BUILD`) the bump reads H online, and stops if it can't; pass `--highest-build N`
to bump offline.

Betas are built from `develop` or `release/*`, and upstream merges go to `develop`: `scripts/sync-upstream.sh` merges and
commits no version bump on it (`BRIDGEPLAY_BETA_BRANCH` names the branch, default `develop`). On `main`, the exception for a security or
crash hotfix from upstream, it still bumps the patch.

`release-local.sh` publishes a beta only in its beta mode (see Beta releases), which stamps the
build itself; without `--beta` a stamped build no longer matches `dylib/version.h`, so its version
check stops it. `make versioncheck` covers the stamp, the bump and the sync.

### Stable releases and betas

`release-local.sh` reads every published `vX.Y.Z-beta.N` release: the build, commit and source
branch from its ledger, the commit also from its tag, which must agree. It stops if any of them
can't be read. The stable lists the betas whose commit HEAD contains in its feed item as
`<bridgeplay:containsBetas>` (namespace `https://bridgeplay.dev/ns/appcast/1`): ascending builds
with runs folded into ranges, `82-83,86`, empty for none. A beta app takes a stable only if its own
build is in that list.

A stable that contains a beta the previous stable did not is a promotion of the newest such beta,
which must have been built from a `release/*` branch, and HEAD must have exactly that beta's tree.
Only the version header (`BRIDGEPLAY_VERSION` and `BRIDGEPLAY_BUILD` in `dylib/version.h`) and
`compat/**`, where the weekly compat bot commits, may differ. The changed `compat/**` paths are
printed and listed in the release body under "Data changed since the beta". Anything else stops
the release with the paths that differ: merge `main` into the release branch, publish a new
release-candidate beta from it, merge the release branch into `main` with a merge commit and
release again. A stable that contains no new beta is a hotfix or a plain stable and is not gated
(`promoted-from: none`), unless its tree, outside the version header and `compat/**`, equals a
published beta it does not contain: the release branch was squashed or rebased into `main`, and
the release stops.

The stable feed (I-6) must have exactly one item, no `sparkle:channel`, a plain `X.Y.Z` short
version, this build, its enclosure on this tag with an EdDSA signature, `minimumSystemVersion`
26.0, one `containsBetas`, and a valid feed signature. The legacy NotProton feed (`--legacy-feed`)
stays as it was: unsigned, with no `containsBetas`. `make stablecheck` covers all of this with a
local repository, a stub `gh`, a throwaway key and Sparkle's own tools.

### Beta releases

```sh
scripts/release-local.sh --beta "release notes"                       # --dry-run to rehearse
scripts/release-local.sh --beta --critical "security: ..." "notes"    # or "data-loss: ..."
scripts/release-local.sh --beta --waive-stable vX.Y.Z --reason "why" "notes"
scripts/release-local.sh --beta --rebuild-feeds [--withdraw vX.Y.Z-beta.N --reason "why"]
```

HEAD must be the tip of `develop` or a `release/*` branch on the remote found by URL, the tree
clean, and the newest stable (the `vX.Y.Z` release marked Latest) an ancestor of HEAD (I-2).
`--waive-stable` names that stable to publish without it: the waiver is printed loudly and
recorded in the ledger (`waived-stable`, `waiver-reason`). A dry run reports a failed check and
carries on; a real run stops. Release notes are required. `--critical` puts the beta on the
`beta-critical` channel and is only for a security or data-loss fix, recorded as `critical-reason`.

The label is `X.Y.Z-beta.N`: `X.Y.Z` from `release/X.Y.Z`, or on `develop` the next patch above
the newest stable, and N one above the highest beta of that `X.Y.Z` published, drafted or tagged.
A release branch named after a version that is already a stable is refused: rename it. The build
is H+1, claimed for HEAD before anything is built; if another release claims it first, the script
reads H again and tries once more, then stops. It builds with the beta stamp (see Betas), signs
and notarizes the app as a stable is, signs the zip with the same EdDSA key, and creates the
`vX.Y.Z-beta.N` prerelease, never Latest, at HEAD, carrying `Bridgeplay.zip` and nothing else
(no appcast, Setup or DMG), its body ending with the ledger. Once the uploaded digest matches, it
regenerates the beta feed and swaps it onto the `beta-feed` release by upload, rename and delete,
the one step that offers the beta. A real run then downloads the feed and the zip again and checks
the item's length and signature and the feed signature. A beta never touches the stable feed, a
`vX.Y.Z` release, the `installer` release or the legacy feed (`--legacy-feed` is refused).

The beta feed, `https://github.com/raymondchins/Bridgeplay/releases/download/beta-feed/appcast.xml`,
is rebuilt from the releases each time, never edited: the newest stable, with no channel and its
`containsBetas`, then the newest beta above it, then the newest `beta-critical` above it if that is
not the newest beta. Each item is copied from its release's ledger (a stable from before the
ledger, from its own `appcast.xml`), so no old zip is signed again; the whole feed is, after its
last edit. A beta whose ledger can't be read, or whose zip is not the one its ledger records,
stops it. The first real beta creates the `beta-feed` release (prerelease, never Latest, at the
newest stable's commit); a dry run says it would.

After a stable is marked Latest, the stable mode rebuilds the beta feed if `beta-feed` exists, so
it carries the new stable and the betas above it. If that fails, the stable stays released, the
run exits 1 and prints the recovery command, `scripts/release-local.sh --beta --rebuild-feeds`.
That command rebuilds the beta feed alone; `--withdraw` first marks a bad beta withdrawn (a line at
the top of its release body), so this and every later feed leave it out.

A rerun on a HEAD that is already published as a beta checks that release against its ledger and
this run's options, uploads nothing, and only exposes it; anything different stops, and no
published asset is overwritten. A beta whose upload doesn't match, or whose upload broke off and
left a draft, is deleted, so the next run starts clean. The beta mode takes the same lock as the stable mode. `make betacheck` runs all of
this through a scripted history with a local repository, a stub `gh`, a throwaway key and
Sparkle's own tools.

### Build numbers

Every build number is used once and is above all earlier ones, a stable bumped on `main` but not
yet released included. `scripts/build-ledger.sh highest` prints H, the highest of:

- the build every app release (`v*`) records: its ledger block, its `Build N, based on NotProton X.`
  line, or its `appcast.xml` (the higher wins, with a warning, when they disagree);
- every `build/<n>` claim tag;
- the committed build on `main`, `develop` and every `release/*`.

It finds the remote by URL, fetches what it needs, and fails without a number if any of these
can't be read. `scripts/build-ledger.sh claim N [COMMIT]` claims build N by pushing the lightweight
tag `build/N` at the commit, before anything is built or signed. It exits 0 when it claimed the
build or the tag is already at that commit (a resume), 2 when another commit holds it, and 3 when
the remote can't be reached; `--dry-run` pushes nothing. `release-local.sh` claims its build this
way before building. Claim tags are never moved or deleted, and
gaps in the numbers are fine. The release ledger's v1 format is frozen in `scripts/ledger-lib.sh`,
which also reads it. `make ledgercheck` covers all of this against a local repository and a stub `gh`.

The app works out its updater state on every check from the `BetaUpdates` default (a boolean,
off when missing or unreadable) and the running build's channel: `stable` (off, stable build)
reads `SUFeedURL` exactly as before; `beta` (on) and `leaving` (off, beta build) read
`https://github.com/raymondchins/Bridgeplay/releases/download/beta-feed/appcast.xml`. `beta` takes
items on the `beta` and `beta-critical` channels, `leaving` only `beta-critical`, and both take the
highest build above the running one. A stable item reaches a beta build only when its
`<bridgeplay:containsBetas>` list (`81-85,87`) names that build, so nobody is downgraded. After a
failed beta-feed check, the next check reads the stable feed under the same rules. Each check
writes one `update check:` line to `bridgeplay.log` and the app log. For testing,
`BetaFeedURLOverride` and `StableFeedURLOverride` replace the feeds in any build and are named in
that line; enclosure signatures are still required.

The switch is hidden in this phase. `defaults write com.bridgeplay.Bridgeplay BetaUpdatesUI -bool
true` shows **Get beta updates** in the Status page's Updates section; it writes `BetaUpdates`
only after the user confirms. Without the key, that section appears only while the app is in the
`beta` or `leaving` state, or once after a build that left the beta lands on stable.

## Steps

0. Push the changes first and wait for the `app` workflow to pass on them
   (`gh run watch -R raymondchins/Bridgeplay`). The release reuses that result instead of
   running the checks again; `BRIDGEPLAY_FORCE_CHECKS=1` runs them anyway. Only a push run on
   `main`, `develop`, `dev` or `release/*` counts; pull request and manual runs do not. A
   docs-only run (the gate green, build and checks skipped) does not count either, so the
   release falls back to an older run of the same sources or runs the checks here.
1. Bump and commit:
   ```sh
   scripts/bump-version.sh patch        # or minor / major, or set X.Y.Z
   git commit -m "chore(release): Bridgeplay X.Y.Z" dylib/version.h
   ```
   `set X.Y.Z` takes any version above the committed one, such as `0.7.31` after `0.7.3` for a
   small follow-up. The numbers compare as integers, so `0.7.31` sorts above `0.7.4`: after it,
   go on with `0.7.32` (or `patch`) or a minor. Updates still order by the build, which goes up
   by one. The bump reads H online; offline, pass `--highest-build N`. `scripts/sync-upstream.sh`
   already bumps the patch after an upstream merge on `main`, and reads H before merging (or takes
   `BRIDGEPLAY_HIGHEST_BUILD`); on `develop` it commits no bump (see Betas).
2. Push to `main` of `raymondchins/Bridgeplay` (the script refuses anything else).
3. Optionally rehearse: `scripts/release-local.sh --dry-run` takes an app already built
   (`build/Bridgeplay.app`, else `out/Bridgeplay.app`) and writes the zip, appcast, an unsigned
   DMG and an ad hoc native installer to `out/release/`, without publishing, claiming or reading
   the keychain. It signs with `SPARKLE_KEY_FILE` (`generate_keys -x`), or else with a throwaway
   key that signs the feed but not the zip, so its I-6 check reports the missing enclosure
   signature. Like the release, it computes the installer fingerprint, which needs this Mac's
   engine cache and GPTK, and packages the installer zip only when the fingerprint changed.
4. Release: `scripts/release-local.sh` (notes default to the commit subjects since the
   previous `vX.Y.Z` release; pass a string to override). It checks the betas HEAD contains
   (see Stable releases and betas), claims `build/<build>` for HEAD, and stops if another commit
   holds it: bump again, which reads the current H. It then builds with
   `scripts/build-local.sh --checks`, signs the app with the Developer ID and notarizes it (see
   Signing), and checks that the app's `LSMinimumSystemVersion` is 26.0, the
   `minimumSystemVersion` the appcast must carry. It signs the zip with the EdDSA key in the login
   keychain, writes the appcast, adds `containsBetas` to it, signs the appcast itself and checks
   it (I-6), builds the notarized DMG and native installer, and uploads all four to `vX.Y.Z`.
   The release is created without Latest; once the uploaded digests match the local files it is
   marked Latest, the one step that offers it to installed apps. If a run stops between the two,
   run it again: it checks the release against its ledger and the signatures, marks it Latest and
   uploads nothing. A release whose uploads don't match, or whose upload broke off and left a
   draft, is deleted (it was never Latest), so the next run starts clean. The release body ends
   with the ledger (see Build numbers).
   It then uploads a new `Bridgeplay-Installer.zip` to the `installer` release if its fingerprint
   changed. That fingerprint checks this Mac's engine cache and GPTK even when the installer is
   unchanged, so set both up before releasing: if the check fails after the release is marked
   Latest, the installer is not updated, and a rerun refuses the existing release. Last, the beta
   feed, if there is one, is rebuilt with the new stable (see Beta releases).

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
from any signer. The committed Wine and SDL binaries in `Resources/` are re-signed too; their
pins still match through `SignedPin.swift`. `np-native` and `libnp_gamepad.dylib` are not in
the app and stay ad hoc.

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

## WineCX patch source

The Corresponding Source for the patched Wine (WineCX) binaries in `app/Sources/BridgeplayApp/Resources/`
(NOTICE, "Patched Wine (WineCX) binaries") is winecx (`dappermint/winecx`) at the pinned
commits plus the patches in this repository. LGPL-2.1-or-later asks whoever distributes the
binaries to also provide that source, so `scripts/package-wine-patch-sources.sh` publishes
both onto a `wine-patch-sources-<id>` release of this project; `<id>` comes from the pinned
commits and the patch files, so unchanged pins and patches give the same name and sha256.
When `docs/WINECX.md`'s winecx pins or any of the patch directories change:

1. `scripts/package-wine-patch-sources.sh`. Copy the pin it prints into NOTICE.
2. `scripts/package-wine-patch-sources.sh --publish` creates the release. `release-local.sh`
   stops while the pinned archive is missing on GitHub.

## DXMT source

Every `dxmt-<commit>` release from `scripts/build-dxmt.sh --publish` on carries the license
texts inside the binary tarball and a `dxmt-<commit>-source.tar.gz` (the exact DXMT worktree
the build ran from, submodules included) beside it; see [DXMT.md](DXMT.md), Rebuilding. The
currently pinned `dxmt-e94c312.tar.gz` predates this and has neither; its source is the
upstream commit named in NOTICE and `FreeEngine.swift` until the next rebuild.

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
| Steam tools `notproton-winecx-11.17`, `notproton-winehq`, … | `bridgeplay-proton-winecx-11.17`, `bridgeplay-proton-winehq`, … |
| `notproton-run.log`, `notproton-wine.log`, `notproton.log` | `bridgeplay-run.log`, `bridgeplay-wine.log`, `bridgeplay.log` |
| `NOTPROTON_*` in launch options and conf files | `BRIDGEPLAY_*` (the old spelling still works) |

Unchanged: `notproton.dylib`, `lib/notproton-backends`, the prefix markers in `compatdata`
(`notproton-build`, `notproton-backend`), the launcher bundle ids
`com.notproton.launcher.<appid>` and the `NOTPROTON_VERSION` define.

The app migrates on its first launch after the update, once Steam and every game are
closed: it moves the folders and switches games mapped to a `notproton*` tool to its
`bridgeplay-proton*` name. What it replaces is backed up under
`~/Library/Application Support/bridgeplay/backups/migration-3.0.0/`. Nothing is needed in the
release steps; `scripts/release-local.sh` and `scripts/package-installer.sh` fall back to the
`notproton` folders on a Mac that has not migrated yet.
