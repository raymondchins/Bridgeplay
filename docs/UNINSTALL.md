# Removing Bridgeplay

What **Remove Everything** (Status page) and `--remove-everything` do, what they leave, and how
to check the result. Code: `app/Sources/BridgeplayApp/Model/Uninstall.swift` (the removal) and
`Model/UninstallPlan.swift` (the plan, the checklist and the verify step).

## Order

1. The plan: a sheet (or `--uninstall-plan`) lists every path that will go, with sizes, the
   game prefixes it can also move to the Trash, and what stays. Nothing changes until you
   confirm.
2. A running game or Wine tool stops the removal before Steam is touched.
3. Steam quits (`steam://exit`, then the Dock's quit). On a terminal the command line asks
   first. A Steam open in another macOS account stops the removal of Steam.app.
4. Steam.app is detached, then replaced by Valve's signed bundle through Repair Steam: the
   pinned copy kept in `bridgeplay/steam-restore` when it still matches its sha256, otherwise
   the same bundle downloaded from Valve. Its signature is checked against Apple's root and
   Valve's team (`MXGJJ98X76`) before and after the swap.
5. Steam's config: Bridgeplay's default tool and per-game entries in `config.vdf`, the update
   block in `steam.cfg`. Only with Steam closed.
6. Ticked prefixes go to the Trash, one by one; a running game's prefix or one on a drive
   without a Trash stays and is named in the checklist.
7. Files: listed below. The user's own `gamefixes` (and an old `notproton/gamefixes`) move to
   `~/Library/Application Support/bridgeplay-gamefixes` instead.
8. The checklist: removed, moved to the Trash, still there (with why), and the verify result.

## What goes

All in this account's home:

| Path | What |
|---|---|
| `~/Library/Application Support/bridgeplay`, `…/notproton` | Engines, runners, launchers (the per-game apps Spotlight and the Games app list), backups, logs, Valve's kept Steam bundle |
| `~/Library/Caches/bridgeplay`, `…/notproton` | Downloads |
| `~/.bridgeplay`, `~/.notproton` | `np-native`, `libnp_gamepad.dylib` |
| `~/Library/Application Support/bridgeplay-steam-bundles.json` (and the `notproton-` one) | The record of modified Steam bundles; kept while one of them is out of reach |
| `~/Library/LaunchAgents/com.bridgeplay.*`, `com.notproton.*` | Login items. Bridgeplay adds none today; any found are unloaded and removed |
| Steam's `compatibilitytools.d/bridgeplay-proton*`, `notproton*` | The compatibility tools |
| Steam's `legacycompat`, each library's `compatdata/notproton-template` and `common/Steam.dll` link | Files the run script made |
| The signing keychain (`bridgeplay/signing`) and its password in the login keychain | The local identity Steam was signed with |

## What stays

- Game prefixes (`steamapps/compatdata/<appid>`) in every library: saves and settings not in
  Steam Cloud. Only ticked ones go, and only to the Trash.
- Your own game fixes, moved aside as above.
- Bridgeplay.app and the files macOS keeps for it (preferences, Sparkle's cache): drag the app
  to the Trash after it quits.
- Other macOS accounts' Bridgeplay files. Steam.app is shared, so those accounts stop getting
  Bridgeplay in Steam, but their own folders are theirs to remove (their Library isn't readable
  from this account). The plan names those accounts.

## Verify

`--verify-uninstall` (and **Check Again** in the checklist) exits 0 only when:

- `Steam.app` passes `codesign --verify --strict`, Valve's requirement
  (`anchor apple generic and certificate leaf[subject.OU] = "MXGJJ98X76"`) and
  `identifier "com.valvesoftware.steam"`;
- no `notproton.dylib` is in `Steam.app/Contents/MacOS`, neither Info.plist (the bundle's and
  Steam's inner `Steam.AppBundle`) names it in `DYLD_INSERT_LIBRARIES` or sets the controller
  block, `steam.cfg` has no update block, and none of Steam's folders hold the tools, the
  `legacycompat` folder, a template folder or a `Steam.dll` link.

It also lists this account's Bridgeplay files that are still there. It reads only, and runs
before the app's log and the 3.0 folder move, so it never recreates the folders it checks.

## Tests

`app/Tests/BridgeplayAppTests/UninstallPlanTests.swift` builds fixture homes, libraries and
Steam bundles in a temporary folder, with stub signature checks and a stub Trash.
`UninstallTests.swift` covers the removal itself.
