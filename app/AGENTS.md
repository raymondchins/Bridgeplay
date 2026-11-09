# app/

A SwiftPM package. Targets: `BridgeplayApp` (the app and its CLI flags, `Support/*Command.swift`),
`BridgeplayUI` (shared views and fonts), `BridgeplayInstaller` and `BridgeplayInstallerCore` (the
native installer, [docs/NATIVE-INSTALLER.md](../docs/NATIVE-INSTALLER.md)). Tests are in
`app/Tests/`. The minimum is macOS 26.

- **Tests:** run `make app-tests` from the repo root, not a bare `swift test`: it links
  Sparkle where the test bundle looks for it ([docs/BUILD-LOCAL.md](../docs/BUILD-LOCAL.md#sparkle-link-for-the-swift-tests)).
  Some tests download the real DXMT tarball into the engine cache unless `NOTPROTON_OFFLINE=1`.
  Tests that need the keychain, a real Wine or a live installer download are opt-in through
  an environment variable named in the test file (`NOTPROTON_KEYCHAIN_TEST`,
  `NOTPROTON_TEST_WINE`, `BRIDGEPLAY_LIVE_DOWNLOAD`, …). `make mincheck`
  checks that nothing in the built app needs a macOS newer than 26.
- **Strings:** both `Resources/Localization/Localizable.xcstrings` (BridgeplayApp and
  BridgeplayInstaller) carry en, it, ru and zh-Hans. A new user-facing string needs all four;
  `make l10ncheck`.
- **A built app acts on this Mac.** Once idle after launch it re-applies its Steam patch
  when Steam's is older and updates installed engines whose pins changed
  (`Support/PostUpdateRefresh.swift`, `UpdateEverything.swift`). For UI work use the debug
  previews instead: `BridgeplayApp --setup-preview` and `BridgeplayInstaller --preview <state>`.
- **Steam must be closed** before the app writes `Steam.app` or Steam's config files.
  Follow the existing guards (`SteamDefaultTool`, `PostUpdateRefresh.decide`) rather than
  writing those files directly.
- **Pins:** every downloaded or shipped engine file is pinned by sha256 in
  `Model/FreeEngine.swift`, `Model/FreeEngineWinecx.swift` and `NtdllPatcher`; signed Mach-O
  resources also need their line in `Support/SignedPin.swift` (`SignedPinTests`). A pin change
  makes an installed engine show "Update & Set Up". The table of shipped binaries is in
  [docs/WINECX.md](../docs/WINECX.md#shipped-binaries).
- **Versions** come from `dylib/version.h`, stamped in by `make app`; never edit
  `Info.plist`'s version by hand ([docs/RELEASING.md](../docs/RELEASING.md)).
