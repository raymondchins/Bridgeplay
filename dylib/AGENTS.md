# dylib/

`notproton.dylib` is loaded into every Steam client on the Mac, through
`DYLD_INSERT_LIBRARIES` in `Steam.app`'s Info.plist. A crash, hang or leak here takes Steam
down for the user. The constructor in `core/loader.c` does its work in `steam_osx`; in the
main `Steam Helper` (no `--type=` argument) it only installs the spawn hook.

- **Steam addresses** come from `signatures/macos.arm64/<steam build>.json` (the
  highest-numbered file wins), resolved through `resolver/`. The dylib must never guess an
  address. If a `steamclient.dylib` signature doesn't resolve, the loader installs none of the
  steamclient hooks; a steamui signature that doesn't resolve turns off only its own hook.
  A new or renamed signature needs an entry in the signature files and a passing
  `make sigcheck`. `make sigdb-fixtures` and `make anchorcheck` check the files against the
  installed `steamclient.dylib`, so run them on a Mac with Steam; they are not in CI.
- **Child processes:** `hooks/hook_spawn.c` strips the insert from processes Steam starts,
  so games and other apps don't inherit the dylib. Keep that true for any new spawn path
  (`make spawn-env`).
- **The run script** is `feats/compat_run.sh`. It is POSIX `sh`, runs once per game launch,
  and is embedded into the dylib at build time (`embed_script.py` →
  `out/generated/compat_run.h`), so run `make` after editing it.
  - It reads settings as `NOTPROTON_<X>`. The loop at its top maps the user-facing
    `BRIDGEPLAY_<X>` spelling onto them, so document new settings as `BRIDGEPLAY_<X>`.
  - Gamefix `.conf` files are data, never shell code. A new key needs a case in the
    allow-list in `gamefix_reason`, a row in [docs/GAMEFIXES.md](../docs/GAMEFIXES.md), and
    a passing `make gamefixescheck`.
  - Checks that run it: `runcheck`, `envcheck`, `envpasscheck`, `settingscheck`, `routecheck`,
    `buildcheck`, `bridgecheck`, `seedcheck`, `gamedrivecheck`, `prefixnotecheck`,
    `powernotecheck`, `exitcheck`, `launchprogresscheck`, `launchercheck`, `gamefixescheck`,
    `anticheatcheck`, `padcheck`, `shortcutcheck`.
  - Controllers: the script starts the game's launcher bundle itself rather than through
    `open`, so macOS charges HID access to Steam and games need no Input Monitoring grant of
    their own (`BRIDGEPLAY_LAUNCH_SERVICES=1` goes back to `open`). It exports
    `SDL_JOYSTICK_MFI=0` and the SDL mappings from `gamecontrollerdb*.txt`. Never set winebus
    `Hidraw=1` for an XInput pad ([docs/WINECX.md](../docs/WINECX.md#controllers)).
- **Tests** live in `dylib/tests/`. Most run without Steam or Dobby, and several `#include`
  the `.c` file under test for that reason. Add a new check as a Makefile target and to
  `CI_CHECKS` in the Makefile.
