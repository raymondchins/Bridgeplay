# Native installer

`Bridgeplay Installer.app` (shipped as `Bridgeplay-Setup.zip` on every app release) installs
or updates `/Applications/Bridgeplay.app`. It downloads the app from the release named in
Bridgeplay's Sparkle feed and checks its EdDSA signature before extracting it. On a Mac
without Game Porting Toolkit or Steam it also downloads the one-click installer zip
(`Bridgeplay-Installer.zip` on the `installer` release, signature in the `.sig` beside it),
checks it against the same key, and puts its contents in place itself
(`ComponentsPlacement` in `BridgeplayInstallerCore`), without running the `Install.command` the
zip still carries for older app versions. That zip carries GPTK, DXMT, DXVK and the default
configs, not Wine: the app downloads the WineCX runtime from dappermint/winecx-gptk during its Setup Assistant (see
[NOTICE](../NOTICE)). Discussion: [issue #17](https://github.com/raymondchins/Bridgeplay/issues/17).

## Build

```sh
make native-installer
```

This builds the `BridgeplayInstaller` SwiftPM product for arm64, copies its two resource
bundles, compiles installer translations, renders the Bridgeplay mark as the icon, signs the
app and packages `out/Bridgeplay-Setup.zip`: the app, `LICENSE` and `NOTICE`. The default is
an ad hoc local build; `BRIDGEPLAY_SIGN_IDENTITY` selects the maintainer's signing identity.
A Developer ID build also gets the hardened runtime and is notarized and stapled
(`scripts/notarize.sh`), so macOS opens the download after a single click on Open. Packaging fails above 5 MiB unless `BRIDGEPLAY_INSTALLER_MAX_BYTES` raises the budget for a deliberate size review.

CI packages the ZIP as a build artifact and runs `native-installercheck`.
`scripts/release-local.sh` attaches it to each app release after generating the appcast, so
it never becomes a Sparkle update for the product; its dry run builds an ad hoc copy. The
bootstrap builds without the Wine toolchain; the product build is in
[BUILD-LOCAL.md](BUILD-LOCAL.md). An ad hoc build has no Developer ID signature or
notarization.

## Behavior

The wizard checks the release and installed app, then offers Install or Update. An already
current app requires no download. A newer installed build is kept; the installer refuses a
downgrade. A different application or unsafe destination is not replaced.

The app archive is authenticated with the same public key as the installed app's Sparkle
updater. The app's identity, build, version and code signature are checked before replacement.
The installer stages on the destination volume, coordinates through a persistent lock,
refuses an active Bridgeplay/updater process, and keeps the prior app in the hidden
`.Bridgeplay.app.previous` sibling for recovery. An interrupted replacement is recovered
locally before release discovery, including when the network is unavailable. Unexpected
backup contents are preserved and reported instead of deleted. An older recovery bundle is
rotated by rename before replacement. Retired copies owned by another account or containing
read-only directories stay intact as hidden `.Bridgeplay.app.previous-<UUID>` siblings; an
administrator can remove them from Terminal, or in Finder after showing hidden files with
Cmd-Shift-Period. They do not block subsequent updates.

Prefixes, saves and Steam libraries are never touched. The components step writes `gptk/`,
`gamefixes-default/`, the cached DXMT/DXVK archives, and `gamecontrollerdb.txt` when there is
none yet. It never writes the user's `gamefixes/default.conf`, and from `gamefixes/` it removes
only per-game confs still identical to ones earlier installers copied there (see
[installer/README.md](../installer/README.md)).
Opening the installed app continues its Setup Assistant, which downloads the WineCX engine
and sets up Steam. Neither installer changes Sparkle's update feed.

Bridgeplay.app does not need either installer. Its Setup Assistant's Graphics step offers
Download, which fetches the same `Bridgeplay-Installer.zip` through `BridgeplayInstallerCore`
(EdDSA check, then Apple's signature on every Mach-O file in `gptk/`) and puts it in
place the same way, so a Mac with only the app gets the same files.

On Finish, users may open Bridgeplay. When the installer was started from a mounted disk
image that `hdiutil` identifies exactly, it also offers to eject the image and move it to
Trash; a helper outside the volume does that after the installer exits. Failures keep the
image and show a message. Nothing is deleted permanently.

## Verification

Run the focused installer core tests with the full app tests on the supported Xcode:

```sh
make app-tests
make scriptcheck runcheck native-installercheck
```

`scripts/test-native-installer.sh` runs an additional standalone smoke suite against the
production core sources without depending on the full app test bundle. It uses generated
signing keys and temporary app roots, leaving installed apps and game data alone.

For visual review, the executable supports deterministic, non-mutating preview states:

```sh
app/.build/debug/BridgeplayInstaller --preview update --screenshot /tmp/installer-update.png
```

For an isolated GUI test, a debug build also accepts `--test-destination` with a
`Bridgeplay.app` path inside the macOS temporary directory. Release builds always use
Applications. Do not open the installed test app unless you intend to exercise real setup.

States are `review`, `update`, `download`, `paused`, `components`, `install`, `steam`, `done`,
`current`, and `error`.
Preview screenshots establish appearance; they do not establish install/update success.

Before public rollout, exercise a fresh install, older/current/newer app, real component
setup, offline/retry, rejected signatures, low disk/permission failures, concurrent
install/update, interrupted replacement, multiple macOS users, external/case-sensitive
volumes, supported OS versions, all locales, keyboard/VoiceOver, and cleanup enabled/disabled.
Record the actual packaged size and separate local ad hoc verification from maintainer-signed
release validation. The contributor writes the PR description personally per CONTRIBUTING.md;
release publishing and keys remain with the maintainer.
