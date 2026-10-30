# dylib/

`notproton.dylib` is loaded into every Steam client on the Mac, through
`DYLD_INSERT_LIBRARIES` in `Steam.app`'s Info.plist. A crash, hang or leak here takes Steam
down for the user. The constructor in `core/loader.c` only does work in `steam_osx` and
`Steam Helper`.

- **Steam addresses** come from `signatures/macos.arm64/<steam build>.json`, resolved through
  `resolver/`. If a signature doesn't resolve on a Steam build, the feature stays off; the
  dylib must not guess an address. A new or renamed signature needs an entry in the
  signature files and a passing `make sigcheck` and `make sigdb-fixtures`. `make anchorcheck`
  checks the files against a real `steamclient.dylib`, so run it on a Mac with Steam.
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
  - Checks for the run script: `runcheck`, `envcheck`, `settingscheck`, `routecheck`,
    `gamedrivecheck`, `prefixnotecheck`, `powernotecheck`, `exitcheck`, `launchprogresscheck`,
    `launchercheck`, `gamefixescheck`, `anticheatcheck`, `padcheck`.
- **Tests** live in `dylib/tests/`. They run without Steam or Dobby; several `#include` the
  `.c` file under test for that reason. Add a new check as a Makefile target and to
  `CI_CHECKS` in the Makefile.
