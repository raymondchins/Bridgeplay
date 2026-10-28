# Installer

`Install.command` downloads the latest `Bridgeplay.zip` from the GitHub releases (checking its
signature), installs Apple's Game Porting Toolkit, the DXMT and DXVK archives and the default
configs from the folder it sits in, downloads Steam from Valve's CDN when
`/Applications/Steam.app` is missing, then opens the app's Setup Assistant. The Setup
Assistant downloads the WineCX engine (dappermint/winecx-gptk's runtime) itself: the zip does
not carry it, because it bundles GPL libraries whose source neither project publishes (see
`NOTICE`). `Bridgeplay Installer.app` and the app's own Setup Assistant (Download in its
Graphics step) no longer run this script: `ComponentsPlacement` in `BridgeplayInstallerCore`
does the same steps without the app step ([docs/NATIVE-INSTALLER.md](../docs/NATIVE-INSTALLER.md)).
The zip still carries the script for app versions before that, so a change to one belongs in
the other.

Before copying Steam, `Install.command` verifies its strict code signature against Apple's
trust chain, Valve's Team ID, and the `com.valvesoftware.steam` bundle identifier.

Build the zip with:

    scripts/package-installer.sh      # writes out/Bridgeplay-Installer.zip

The script stages `out/installer/Bridgeplay/` and fails if a piece is missing, an archive does
not match its pin in `FreeEngine.swift`, or anything from Valve or the WineCX runtime ended up
in the stage:

| Path in the zip | Source |
|---|---|
| `Install.command`, `BACA DULU.txt`, `README.txt`, `config/` | this folder |
| `config/gamefixes-default/` | `gamefixes/*.conf` at the repository root, the same files the app ships |
| `LICENSE`, `LICENSE.*`, `NOTICE` | repository root (includes `LICENSE.jsoncpp`, `LICENSE.cjson`, `LICENSE.wine`) |
| `LICENSE.dxmt`, `LICENSE.dxmt-old`, `COPYING.LIB.dxmt`, `LICENSE.dxvk` | `licenses/`: DXMT at 3Shain/dxmt `e94c312f5c054263acf261cfa109edf13e757587`, DXVK-macOS at Gcenx/DXVK-macOS `8f1e28deed3ad30802f7e1bdff428ec14e6e7817` (tag `v1.10.3-20230507-repack`) |
| `gptk/` | `~/Library/Application Support/bridgeplay/gptk` (`redist/lib` of Apple's Game Porting Toolkit DMG), without Bridgeplay's own `SOURCE.txt` note |
| `GPTK-License.rtf` | `gptk/License.rtf` from the same DMG |
| `cache/engines/` | the pinned DXMT and DXVK archives from `~/Library/Caches/bridgeplay/engines` |

On a Mac the app has not migrated to 3.0.0 yet, the script falls back to the old
`notproton` folders. `Install.command` installs into the `bridgeplay` folders. When only the
old `notproton` folders exist, it writes into those instead and leaves the move to the app,
which migrates them on first launch.

Every Mach-O file in `gptk/` must pass `codesign --verify --strict -R 'anchor apple'`
(Apple's own signature) or the script stops.

`Install.command` puts the confs from the repository's `gamefixes/`, `default.conf` (Bridgeplay's
defaults for every game) included, in `gamefixes-default/`, the folder the app owns and
refreshes on update. It never writes to the user's `gamefixes/`. Earlier installers copied
`default.conf` there and recorded that copy in `.installer/default.conf`; the app uses the
record once to trim the user's file down to their own changes.

Never shipped: Valve's Steam client and the Steam packages in `valve-packages/` (the app
downloads those from Valve's CDN) and the WineCX runtime (the app downloads it from
dappermint/winecx-gptk). GPTK is never committed. GPTK's `/redist` files are
Apple software that Apple allows to be redistributed for non-commercial use only; Bridgeplay
is free and non-commercial.

`BACA DULU.txt` (Indonesian) and `README.txt` (English) are the user guides in the zip. macOS
15 and later no longer opens unsigned scripts from right-click > Open, so step 1 sends users to
System Settings > Privacy & Security > Open Anyway.
