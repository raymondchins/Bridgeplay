# GTA San Andreas: The Definitive Edition (Steam AppID 1547000)

Releases containing this integration prepare the workaround automatically for
supported GTA San Andreas Definitive Edition installs. The shipped
`gamefixes/1547000.conf` enables it by default; those releases need no
file-copy steps.

## Automatic path

On the game's main `waitforexitandrun`, after Bridgeplay initializes its
prefix and before choosing a graphics backend, it checks for an explicit
conflicting graphics choice. A conflicting backend or DXGI override is kept,
the workaround is skipped, and the reason is written to
`compatdata/1547000/bridgeplay-run.log`. Steam's Rockstar prerequisites use the
`run` verb and are left alone.
Other compatibility engines skip this automatic path and use their normal
graphics selection.

When no conflict exists, Bridgeplay's native `gamefix-prep` helper validates
the supported game executable/build, WineCX 11.17 DXMT DLL hashes, Social Club
helper version, and every destination before changing files. It makes a
read-only status check first. Unsupported or missing files, modified
destinations, an unavailable DXVK runtime, or a missing helper stop the game
launch with a log message. Per-prefix ownership state makes repeated launches,
supported updates, and rollback safe around unknown files. Hash-verified
references keep game-local DLLs in place while another managed prefix still
uses the same Steam game install; restore removes Bridgeplay-owned DLLs only
after the last such prefix releases them. The helper relies on atomic rename
support for its file transactions and refuses preparation when the filesystem
cannot provide it. The game executable, Steam settings, registry and saves
are not changed.

After preparation, Bridgeplay selects DXVK for the Rockstar launcher and
sets DXGI to native-first (`dxgi=n,b`) for the game-local DXMT DLLs. The stock
prefix DXGI stays untouched. Matching files adopted as manual remain
user-owned.

To opt out for one launch, add this to Steam's launch options:

~~~text
BRIDGEPLAY_GTA_SA_DE_FIX=0 %command%
~~~

Or set `GTA_SA_DE_FIX=0` in the user's per-game
`~/Library/Application Support/bridgeplay/gamefixes/1547000.conf`. Bridgeplay
restores files it owns; manually adopted files stay in place. Remove the
setting or use `GTA_SA_DE_FIX=1` to enable it again.

The current manifest supports game build 16391096, WineCX 11.17, the DXMT
files bundled with that engine, and the listed Rockstar helper versions. A
game or launcher update may need a Bridgeplay update before it is supported.
Automation fixture tests validate file lifecycle and rollback; they do not add
gameplay verification.

## What it changes

The Rockstar Social Club helper runs through a small Windows x64 wrapper. The
wrapper forwards the original command line and inherited handles to the
preserved SocialClubHelper_real.exe, then appends these CEF graphics switches:

~~~text
--use-gl=angle --use-angle=swiftshader
~~~

The GTA game process uses DXMT's unmodified D3D11, DXGI and D3D10Core DLLs
beside SanAndreas.exe. After successful validation, the run script keeps the
launcher on DXVK and sets DXGI to native-then-builtin. The stock prefix DXGI
remains untouched; it is separate from the game-local DXMT copy.

The wrapper does not log or transmit command-line data, alter credentials,
bypass sign-in, or add sandbox-disabling switches. This package does not
include or modify the game executable or redistribute DXMT runtime DLLs.

## Tested report and limits

On 2026-10-31, the contributor reported this setup: Bridgeplay 0.7.60
(build 77), WineCX 11.17, Steam client 1792618285, Steam game build
16391096, Rockstar Launcher 1.0.109.3031, SocialClub 2.4.0.240, M2 Pro with
16 GB, macOS 26.6.2. Rockstar sign-in completed normally, and the first
mission completed with no gameplay problems.

This is a contributor report from the manual setup, not a maintainer
verification of the automatic path. Later missions, frame rate, other Macs,
other macOS releases, other game builds and future launcher updates are
unverified. Automation fixture tests do not change that gameplay evidence.

The tested diagnosis was a renderer split: D3DMetal failed during launcher
initialization, DXMT's launcher path stopped at SwapDeviceContextState, and
DXVK allowed sign-in but the game's D3DMetal DXGI crashed during swap-chain
creation. This workaround leaves the launcher on DXVK and gives the game
process app-local DXMT DLLs.

## Files, checksums and license

The exact bundled SocialClubHelper.exe is the tested artifact. The source and
binary were checked byte-for-byte against the files used in the reported
installation.

| File | SHA-256 |
|---|---|
| socialclubhelper-shim.c | d6bbf8e8e927c3abb0d1038f89dfd5eb261e3744d3e3e0598ee74129dc4187f0 |
| SocialClubHelper.exe | 80eced29c22d2f3fb7fc38c6c99792350a4f3ef6bacc32971830b5d2e27ad7d5 |

Verify the package from this directory with:

~~~sh
shasum -a 256 -c SHA256SUMS || { echo "Package checksum verification failed"; exit 1; }
~~~

The source is adapted from Matthias Schedel's SocialClubHelper shim in
rdr2-crossover-apple-silicon, pinned at
https://github.com/matthiasSchedel/rdr2-crossover-apple-silicon/commit/66215a814cb26b460ec711d9ce71ce5d31a6c090.
The full original MIT license is included in LICENSE. Keep that license and
the source attribution when redistributing these helper files.

### Rebuild the helper

The checked-in executable was built with llvm-mingw 20261020 UCRT for macOS.
The official archive is:

https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/llvm-mingw-20261020-ucrt-macos-universal.tar.xz

Its SHA-256 is
e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e.
After downloading, verify it with:

~~~sh
printf 'e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e  llvm-mingw-20261020-ucrt-macos-universal.tar.xz\n' | shasum -a 256 -c -
~~~

Then extract it and run the compiler from a separate build directory:

~~~sh
mkdir build
cp socialclubhelper-shim.c build/
cd build
/path/to/llvm-mingw-20261020-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang \
  -O2 -municode -mwindows -Wall -Wextra -Werror \
  -o SocialClubHelper.exe socialclubhelper-shim.c
~~~

A rebuild may differ in the PE timestamp. The bundled executable above is the
tested artifact; a rebuild is not promised to be byte-identical.

## Legacy manual fallback for older Bridgeplay releases

Use the remaining copy-and-configure recipe only with an older Bridgeplay
release that does not ship `gamefix-prep` and the `GTA_SA_DE_FIX` setting. The
current automatic release should not need manual copies. Do not combine this
fallback with the automatic helper.

Start the installed Steam game once through Bridgeplay so its prefix and
Rockstar components are created. If the launcher fails, close its error dialog
and exit the game and launcher before applying the workaround below.

### 1. Close the game and launcher

Exit GTA San Andreas Definitive Edition and Rockstar Games Launcher normally.
Wait until their game, launcher, and SocialClubHelper processes have exited
before changing files. Do not apply this while the game or launcher is open.

### 2. Set and check your paths

Clone or open Bridgeplay, then set these paths for your installation. Replace
the example repository, Steam library, prefix and runner paths as needed.

~~~sh
cd /path/to/Bridgeplay/workarounds/1547000
shasum -a 256 -c SHA256SUMS || { echo "Package checksum verification failed"; exit 1; }
GTA_RECIPE_DIR="$PWD"

BRIDGEPLAY_HOME="$HOME/Library/Application Support/bridgeplay"
GTA_STEAM_LIBRARY="$HOME/Library/Application Support/Steam"
GTA_PREFIX="$HOME/Library/Application Support/Steam/steamapps/compatdata/1547000/pfx"
GTA_RUNNER="$BRIDGEPLAY_HOME/runners/crossover-winecx-11.17"

GTA_GAME_DIR="$GTA_STEAM_LIBRARY/steamapps/common/GTA San Andreas - The Definitive Edition/Gameface/Binaries/Win64"
GTA_HELPER_DIR="$GTA_PREFIX/drive_c/Program Files/Rockstar Games/Social Club"
GTA_DXMT_DLLS="$GTA_RUNNER/CrossOver/lib/notproton-backends/dxmt/x86_64-windows"
GTA_CONF="$BRIDGEPLAY_HOME/gamefixes/1547000.conf"
GTA_HELPER="$GTA_HELPER_DIR/SocialClubHelper.exe"
GTA_HELPER_REAL="$GTA_HELPER_DIR/SocialClubHelper_real.exe"
GTA_HELPER_REAL_SHA="$GTA_HELPER_DIR/SocialClubHelper_real.exe.sha256"
GTA_HELPER_LICENSE="$GTA_HELPER_DIR/SocialClubHelper.bridgeplay.LICENSE"
~~~

If the game is in an external Steam library, set GTA_STEAM_LIBRARY to that
library's root. Set GTA_PREFIX separately to the active AppID 1547000 prefix;
Steam may keep compatdata under a different library. Set GTA_RUNNER to the
installed Bridgeplay WineCX runner whose DXMT files you intend to use. The
source hashes below describe the tested WineCX 11.17 files; if your runner is
different or updated, verify its DXMT files and compatibility before
proceeding.

### 3. Preflight every destination

Check the executable, helper and all three app-local DLL destinations before
copying anything. Stop if a target already exists, including a mod or symlink;
do not overwrite or move it.

~~~sh
test -f "$GTA_GAME_DIR/SanAndreas.exe" || { echo "SanAndreas.exe not found"; exit 1; }
if [ -L "$GTA_HELPER" ] || [ ! -f "$GTA_HELPER" ]; then
  echo "Refusing: SocialClubHelper.exe is missing or is a symlink"
  exit 1
fi
if cmp -s "$GTA_HELPER" "$GTA_RECIPE_DIR/SocialClubHelper.exe"; then
  echo "The helper shim is already installed; stop and inspect the current setup"
  exit 1
fi
for GTA_PATH in "$GTA_HELPER_REAL" "$GTA_HELPER_REAL_SHA" "$GTA_HELPER_LICENSE"; do
  if [ -e "$GTA_PATH" ] || [ -L "$GTA_PATH" ]; then
    echo "Refusing to overwrite an existing helper, checksum, or license file: $GTA_PATH"
    exit 1
  fi
done
for GTA_DLL in d3d11.dll dxgi.dll d3d10core.dll; do
  if [ -e "$GTA_GAME_DIR/$GTA_DLL" ] || [ -L "$GTA_GAME_DIR/$GTA_DLL" ]; then
    echo "Refusing to overwrite an existing game DLL or mod: $GTA_GAME_DIR/$GTA_DLL"
    exit 1
  fi
done
if ! (
  cd "$GTA_DXMT_DLLS" || exit 1
  printf '%s\n' \
    'c1c8c4779686990bf343162a8804dd2d1564b2a893e64e5ddcc7db5e76ce409e  d3d11.dll' \
    '1bb4939ff43e676eac8b3f3cb0583985ab8f7b1a8e11760d14931da3fc44223b  dxgi.dll' \
    'aeb43e1ca7d9f221b9f0070c8654fa3579fd767006272cf675a9113e27bc6e72  d3d10core.dll' \
    | shasum -a 256 -c -
); then
  echo "Refusing: tested DXMT source DLLs are missing or have changed"
  exit 1
fi
~~~

For the tested runner, the three source hashes must be:

| Runtime DLL | SHA-256 |
|---|---|
| d3d11.dll | c1c8c4779686990bf343162a8804dd2d1564b2a893e64e5ddcc7db5e76ce409e |
| dxgi.dll | 1bb4939ff43e676eac8b3f3cb0583985ab8f7b1a8e11760d14931da3fc44223b |
| d3d10core.dll | aeb43e1ca7d9f221b9f0070c8654fa3579fd767006272cf675a9113e27bc6e72 |

Do not proceed if the game executable is missing, the source DLLs do not
match the expected trusted runtime, or any destination already exists.

### 4. Configure this game

Confirm the gamefixes parent directory first. This guarded branch installs
the sample only when the config path is neither an existing file nor a
symlink; it does not create or chmod the parent directory.

~~~sh
if [ ! -d "$(dirname "$GTA_CONF")" ]; then
  echo "Refusing: gamefixes parent directory does not exist"
  exit 1
fi
if [ -L "$GTA_CONF" ]; then
  echo "Refusing: config path is a symlink"
  exit 1
elif [ -e "$GTA_CONF" ]; then
  echo "Existing config: use the manual merge path below; sample not copied."
elif [ ! -e "$GTA_CONF" ]; then
  install -m 600 "$GTA_RECIPE_DIR/1547000.conf" "$GTA_CONF"
fi
~~~

For an existing regular config, inspect it first and stop if its format or
settings are unfamiliar. Only after deciding it is safe to merge, make a
no-overwrite backup and open it for editing. Do not run this backup block for
a config you just created from the sample:

~~~sh
GTA_CONF_BACKUP="$GTA_CONF.before-gta-sa-de-workaround"
if [ ! -f "$GTA_CONF" ] || [ -L "$GTA_CONF" ]; then
  echo "Refusing: existing config is missing or is a symlink"
  exit 1
fi
if [ -e "$GTA_CONF_BACKUP" ] || [ -L "$GTA_CONF_BACKUP" ]; then
  echo "Refusing: config backup already exists"
  exit 1
fi
cp -p "$GTA_CONF" "$GTA_CONF_BACKUP"
open -e "$GTA_CONF"
~~~

Keep exactly one BACKEND=dxvk and one DLLOVERRIDES line. If an existing
DLLOVERRIDES value has other semicolon-separated module overrides, preserve
them and append or update only the dxgi entry to dxgi=n,b in that same value;
do not replace the whole value with dxgi=n,b. For example, retain
DLLOVERRIDES=d3d11=n;dxgi=n,b. Stop if duplicate or conflicting dxgi entries
cannot be reconciled safely. Preserve all unrelated config lines. The fresh
sample remains the same as the tested minimal config.

### 5. Install the helper and game-local DXMT files

Repeat the destination checks immediately before copying. Keep the original
vendor helper beside the shim as SocialClubHelper_real.exe; never overwrite
an existing real-helper, checksum, or license-notice file.

~~~sh
if [ -L "$GTA_HELPER" ] || [ ! -f "$GTA_HELPER" ]; then
  echo "Refusing: SocialClubHelper.exe is missing or is a symlink"
  exit 1
fi
for GTA_PATH in "$GTA_HELPER_REAL" "$GTA_HELPER_REAL_SHA" "$GTA_HELPER_LICENSE"; do
  if [ -e "$GTA_PATH" ] || [ -L "$GTA_PATH" ]; then
    echo "Refusing to overwrite an existing helper, checksum, or license file: $GTA_PATH"
    exit 1
  fi
done
for GTA_DLL in d3d11.dll dxgi.dll d3d10core.dll; do
  if [ -e "$GTA_GAME_DIR/$GTA_DLL" ] || [ -L "$GTA_GAME_DIR/$GTA_DLL" ]; then
    echo "Refusing to overwrite an existing game DLL or mod: $GTA_GAME_DIR/$GTA_DLL"
    exit 1
  fi
done
cp -p "$GTA_HELPER" "$GTA_HELPER_REAL"
cmp -s "$GTA_HELPER" "$GTA_HELPER_REAL" || { echo "Original helper backup mismatch"; exit 1; }
if [ -e "$GTA_HELPER_REAL_SHA" ] || [ -L "$GTA_HELPER_REAL_SHA" ]; then
  echo "Refusing to overwrite the original helper checksum"
  exit 1
fi
(
  cd "$GTA_HELPER_DIR" || exit 1
  set -C
  shasum -a 256 SocialClubHelper_real.exe > SocialClubHelper_real.exe.sha256
) || { echo "Could not record original helper checksum"; exit 1; }
(
  cd "$GTA_HELPER_DIR" && shasum -a 256 -c SocialClubHelper_real.exe.sha256
) || { echo "Original helper checksum verification failed"; exit 1; }
if [ -e "$GTA_HELPER_LICENSE" ] || [ -L "$GTA_HELPER_LICENSE" ]; then
  echo "Refusing to overwrite the helper license notice"
  exit 1
fi
install -m 644 "$GTA_RECIPE_DIR/LICENSE" "$GTA_HELPER_LICENSE"
cmp -s "$GTA_HELPER_LICENSE" "$GTA_RECIPE_DIR/LICENSE" || { echo "License copy mismatch"; exit 1; }
cp -p "$GTA_RECIPE_DIR/SocialClubHelper.exe" "$GTA_HELPER"
cmp -s "$GTA_HELPER" "$GTA_RECIPE_DIR/SocialClubHelper.exe" || { echo "Helper copy mismatch"; exit 1; }
shasum -a 256 "$GTA_HELPER"

cp -p "$GTA_DXMT_DLLS/d3d11.dll" "$GTA_GAME_DIR/d3d11.dll"
cp -p "$GTA_DXMT_DLLS/dxgi.dll" "$GTA_GAME_DIR/dxgi.dll"
cp -p "$GTA_DXMT_DLLS/d3d10core.dll" "$GTA_GAME_DIR/d3d10core.dll"
shasum -a 256 "$GTA_GAME_DIR/d3d11.dll" "$GTA_GAME_DIR/dxgi.dll" "$GTA_GAME_DIR/d3d10core.dll"
~~~

Compare the helper and DLL hashes with this guide and verify the three
game-local hashes match the selected runner sources. Do not alter
SanAndreas.exe, the prefix DXGI, Steam settings, registry or account data.

When all checks pass, start the game normally from Steam. Rockstar sign-in
should remain a normal sign-in. If the launcher or game fails, close both
normally before rolling back.

## Roll back carefully

Do not remove or replace files until their current contents match the
workaround artifacts.

- For each game-local DLL, run shasum -a 256 on the three files and compare
  every result with the matching source hash above. Remove only files that
  still match exactly; leave any changed file or unknown mod in place.
- Restore the launcher helper only if SocialClubHelper.exe still matches the
  bundled shim, and the saved real helper plus its checksum sidecar are regular
  non-symlink files. Verify the saved vendor copy before replacing anything:

~~~sh
if [ -L "$GTA_HELPER" ] || [ ! -f "$GTA_HELPER" ]; then
  echo "Refusing: current helper is missing or is a symlink"
  exit 1
fi
cmp -s "$GTA_HELPER" "$GTA_RECIPE_DIR/SocialClubHelper.exe" || {
  echo "Refusing: current helper is not the bundled shim"
  exit 1
}
if [ -L "$GTA_HELPER_REAL" ] || [ ! -f "$GTA_HELPER_REAL" ] || \
   [ -L "$GTA_HELPER_REAL_SHA" ] || [ ! -f "$GTA_HELPER_REAL_SHA" ]; then
  echo "Refusing: saved helper or checksum is missing or is a symlink"
  exit 1
fi
(
  cd "$GTA_HELPER_DIR" &&
  shasum -a 256 -c SocialClubHelper_real.exe.sha256
) || { echo "Refusing: saved vendor helper checksum failed"; exit 1; }
cp -p "$GTA_HELPER_REAL" "$GTA_HELPER"
cmp -s "$GTA_HELPER" "$GTA_HELPER_REAL" || {
  echo "Restored helper does not match the saved vendor copy"
  exit 1
}
if [ -L "$GTA_HELPER_LICENSE" ]; then
  echo "Leave the license symlink in place and inspect it manually"
elif [ -f "$GTA_HELPER_LICENSE" ] && cmp -s "$GTA_HELPER_LICENSE" "$GTA_RECIPE_DIR/LICENSE"; then
  rm "$GTA_HELPER_LICENSE"
else
  echo "Leave the unknown or changed license sidecar in place"
fi
~~~

  Keep SocialClubHelper_real.exe and its .sha256 file until restoration is
  confirmed.
- For an existing config, compare it with GTA_CONF_BACKUP. Restore that backup
  only if the difference is limited to this workaround; otherwise remove or
  correct only the two settings after reviewing the file.
- If the config was newly created from the sample, remove it only if it still
  matches the sample. Do not remove a config that has since gained unrelated
  settings.
- The prefix DXGI is left stock by this procedure. Never reset or delete the
  prefix as a rollback step.
