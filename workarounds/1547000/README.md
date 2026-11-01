# GTA San Andreas: The Definitive Edition (Steam AppID 1547000)

Releases containing this integration prepare the workaround automatically for
supported GTA San Andreas Definitive Edition installs. The shipped
`gamefixes/1547000.conf` enables it by default; those releases need no
file-copy steps.

## Automatic path

On the game's main `waitforexitandrun`, after Bridgeplay initializes its
prefix and before choosing a graphics backend, it checks for an explicit
conflicting graphics choice. The per-game fix selects DXVK even if a global
`BACKEND` gamefix sets another default. A conflicting launch-option or
per-game backend, or an effective conflicting DXGI override (including one
from a global config), is kept; the workaround is skipped and the reason is
written to `compatdata/1547000/bridgeplay-run.log`. Unrelated DLL overrides
remain in effect. Steam's Rockstar prerequisites use the `run` verb and are
left alone.
Other compatibility engines skip this automatic path and use their normal
graphics selection.

When no conflict exists, Bridgeplay's native `gamefix-prep` helper validates
the supported game executable/build, WineCX 11.17 DXMT DLL hashes, Social Club
helper version, and every destination before changing files. It makes a
read-only status check first. Unsupported setup input with no managed state to
change, reported as status 3 (such as an unknown game build, unsupported
Social Club helper, or missing runtime/helper files), is logged and skipped so
it does not block an otherwise normal launch. Preparation revalidates its
inputs; if they become unsupported between status and prepare, the same
status-3 fallback applies only when no managed state needs changing. Unsafe or
inconsistent state (status 4) and I/O or transaction errors (status 5) stop the
launch with the original helper exit code. Without a DXVK runtime, the new
setup is skipped before it changes files; an already managed setup that needs
DXVK stops the launch rather than running with only part of its configuration.
This strict check also applies when another prefix has no private ownership
state but shared managed game DLLs are already present. A matching manual setup
remains unowned, but the launch still stops if its required DXVK runtime is
missing. Unsupported input can soft-skip only when there is no managed setup
to preserve or update.
A missing Bridgeplay `gamefix-prep` executable is still treated as an incomplete
installation and stops launch. Per-prefix ownership state makes repeated
launches, supported updates, and rollback safe around unknown files. Hash-verified
references keep game-local DLLs in place while another managed prefix still
uses the same Steam game install; restore removes Bridgeplay-owned DLLs only
after the last such prefix releases them. The helper relies on atomic rename
support for its file transactions and refuses preparation when the filesystem
cannot provide it. These game-local DLLs persist between sessions in the Steam
install. Before switching that install to another compatibility tool or native
Windows, or removing Bridgeplay, use
`BRIDGEPLAY_GTA_SA_DE_FIX=0 %command%` for each managed prefix. Bridgeplay
removes the shared DLLs after every managed prefix releases its reference.
Matching files adopted as manual remain the user's
responsibility. The game executable, Steam settings, registry and saves are
not changed.

An interrupted file transaction is recovered by the next prepare or restore
before that operation validates or changes files. The transaction publishes a
shared pending marker beside the game install; it contains only the AppID,
schema version and transaction UUID. Only the prefix whose private journal
matches that marker may recover it. A different prefix's status, prepare or
restore stops with status 4 and leaves the marker and files untouched. Recover
the transaction from its original prefix before another prefix can change the
shared setup. Read-only status inspection does not perform recovery. If a
journaled target or staged file has changed, recovery stops and leaves the
changed file and journal in place for inspection. Once shared release is
complete and the marker is removed, a later prefix may prepare the same game
install; cleanup of the original finished journal does not roll back those new
shared files.
During restore, missing shared ownership metadata means Bridgeplay leaves the
shared game-local DLLs in place because it cannot verify other prefixes'
references. If the current Social Club helper is an unrecognized vendor build,
it is left in place while independently verified Bridgeplay-owned game DLLs
can still be cleaned up when shared ownership metadata is intact. Shared
ownership metadata and its read-only lock support multiple macOS accounts using
the same game install. Mode-policy fixtures exercise the accepted and rejected
owner/mode combinations, but reads and writes from a second macOS UID have not
been verified.

### Manual recovery for an orphan pending marker

This is an exceptional recovery for a marker whose owner transaction journal
is confirmed irretrievably lost. It is not part of normal setup. Bridgeplay
fails closed because the shared marker does not identify an account or contain
the journal's operations; automatically adopting it could lose another
prefix's ownership or overwrite files. A different macOS account being
temporarily unavailable does not make a marker orphaned: wait for that owner
and let its normal `gamefix-prep prepare` or `restore` recover the transaction.
Never wait for a timeout and unlink the marker by hand.

Quit Steam, every Wine process, GTA and Rockstar Launcher in **all macOS
accounts** that use this Steam installation. Keep them stopped through the
recovery. In the original owner's account, try its normal recovery first. Do
not continue while its journal exists, is inaccessible, or might still be
recoverable. Do not copy or share private journals. Confirm that the owner
journal is permanently missing or otherwise irretrievably lost before setting
the acknowledgement below.

Set the absolute Steam game install root and copy the lowercase transaction
UUID from `.bridgeplay-gta-sa-de-1547000.pending.json`. Keep the three pinned
hashes unchanged. Run the following setup and recovery blocks in the same
shell, from a Mac with `plutil`, `shasum`, `stat`, `mv`, `mktemp`, `cmp` and `id`:

~~~sh
# BEGIN GTA 1547000 ORPHAN PIN SETUP
GTA_GAME='/absolute/path/to/GTA San Andreas - The Definitive Edition'
GTA_EXPECTED_TRANSACTION_UUID='00000000-0000-0000-0000-000000000000'
GTA_ORPHAN_ACK='I_CONFIRMED_THE_OWNER_JOURNAL_IS_IRRETRIEVABLY_LOST'
GTA_PIN_D3D11='c1c8c4779686990bf343162a8804dd2d1564b2a893e64e5ddcc7db5e76ce409e'
GTA_PIN_DXGI='1bb4939ff43e676eac8b3f3cb0583985ab8f7b1a8e11760d14931da3fc44223b'
GTA_PIN_D3D10CORE='aeb43e1ca7d9f221b9f0070c8654fa3579fd767006272cf675a9113e27bc6e72'
export GTA_GAME GTA_EXPECTED_TRANSACTION_UUID GTA_ORPHAN_ACK
export GTA_PIN_D3D11 GTA_PIN_DXGI GTA_PIN_D3D10CORE
# END GTA 1547000 ORPHAN PIN SETUP
~~~

The guarded block checks every source, schema, hash, path and destination
before its first move. It quarantines game DLLs only when the shared state's
`files` metadata proves Bridgeplay ownership and pins the hashes of all three
DLLs. A complete pinned triplet with absent, preexisting or uncertain ownership
stays in the game folder as user-owned. A partial pinned triplet without that
ownership proof stops before any move; use the checks in
“5. Install the helper and game-local DXMT files” in the manual recipe below
to complete a verified set, or coordinate a backup of the affected files
before retrying. The block also moves the recognized shared-state file (when
present) and finally the pending marker. The unique mode-700 quarantine is a
sibling of the game folder. Prefixes, saves, registry data, the game
executable, unknown files and all `.tmp` stages are left in place.

~~~sh
# BEGIN GTA 1547000 ORPHAN RECOVERY BODY
(
set -eu
gta_refuse() { printf 'Refusing orphan recovery: %s\n' "$1" >&2; exit 1; }
gta_stop() {
  printf 'STOP: keep Steam/Wine closed; preserve quarantine %s and follow the interruption instructions.\n' "${GTA_BACKUP-}" >&2
  exit 1
}
gta_hash() { GTA_HASH_LINE=$(shasum -a 256 "$1") || return 1; printf '%s' "${GTA_HASH_LINE%% *}"; }
[ "${GTA_ORPHAN_ACK-}" = 'I_CONFIRMED_THE_OWNER_JOURNAL_IS_IRRETRIEVABLY_LOST' ] || gta_refuse 'owner-journal loss was not acknowledged'
case "${GTA_EXPECTED_TRANSACTION_UUID-}" in ????????-????-????-????-????????????) ;; *) gta_refuse 'invalid transaction UUID' ;; esac
case "$GTA_EXPECTED_TRANSACTION_UUID" in *[!0123456789abcdef-]*) gta_refuse 'UUID must be lowercase hexadecimal' ;; esac
for GTA_PIN in "${GTA_PIN_D3D11-}" "${GTA_PIN_DXGI-}" "${GTA_PIN_D3D10CORE-}"; do
  case "$GTA_PIN" in ????????*) [ "${#GTA_PIN}" -eq 64 ] || gta_refuse 'invalid pinned hash' ;; *) gta_refuse 'missing pinned hash' ;; esac
  case "$GTA_PIN" in *[!0123456789abcdef]*) gta_refuse 'invalid pinned hash' ;; esac
done
case "${GTA_GAME-}" in /*) ;; *) gta_refuse 'GTA_GAME must be absolute' ;; esac
[ "$GTA_GAME" != / ] || gta_refuse 'GTA_GAME cannot be the filesystem root'
while [ "$GTA_GAME" != / ] && [ "${GTA_GAME%/}" != "$GTA_GAME" ]; do GTA_GAME=${GTA_GAME%/}; done
[ -n "$GTA_GAME" ] && [ "$GTA_GAME" != / ] || gta_refuse 'invalid game root'
[ -d "$GTA_GAME" ] || gta_refuse 'game root is unavailable'
GTA_GAME=$(CDPATH= cd -P "$GTA_GAME" 2>/dev/null && pwd -P) || gta_refuse 'cannot canonicalize game root'
GTA_GAME=${GTA_GAME%/}
[ -n "$GTA_GAME" ] && [ "$GTA_GAME" != / ] || gta_refuse 'invalid game root'
GTA_PARENT=${GTA_GAME%/*}
[ -d "$GTA_PARENT" ] && [ ! -L "$GTA_PARENT" ] || gta_refuse 'unsafe game-root parent'
GTA_PHYSICAL_PARENT=$(CDPATH= cd -P "$GTA_PARENT" 2>/dev/null && pwd -P) || gta_refuse 'cannot canonicalize parent'
[ "$GTA_PARENT" = "$GTA_PHYSICAL_PARENT" ] || gta_refuse 'game-root parent is not canonical'
GTA_DLL_DIR="$GTA_GAME/Gameface/Binaries/Win64"
for GTA_DIR in "$GTA_GAME/Gameface" "$GTA_GAME/Gameface/Binaries" "$GTA_DLL_DIR"; do
  [ -d "$GTA_DIR" ] && [ ! -L "$GTA_DIR" ] || gta_refuse 'unsafe or missing game directory'
done
GTA_EXE="$GTA_DLL_DIR/SanAndreas.exe"
[ -f "$GTA_EXE" ] && [ ! -L "$GTA_EXE" ] || gta_refuse 'SanAndreas.exe is not a regular game file'
GTA_MARKER="$GTA_GAME/.bridgeplay-gta-sa-de-1547000.pending.json"
GTA_STATE="$GTA_GAME/.bridgeplay-gta-sa-de-1547000.json"
[ -f "$GTA_MARKER" ] && [ ! -L "$GTA_MARKER" ] || gta_refuse 'pending marker is missing, non-regular or a symlink'
[ "$(stat -f %Lp "$GTA_MARKER")" = 644 ] || gta_refuse 'pending marker mode is not 644'
[ "$(stat -f %z "$GTA_MARKER")" -le 4096 ] || gta_refuse 'pending marker is oversized'
plutil -convert json -o /dev/null "$GTA_MARKER" >/dev/null 2>&1 || gta_refuse 'pending marker is not valid JSON'
[ "$(plutil -extract version raw -o - "$GTA_MARKER" 2>/dev/null)" = 1 ] || gta_refuse 'unknown marker schema'
[ "$(plutil -extract appid raw -o - "$GTA_MARKER" 2>/dev/null)" = 1547000 ] || gta_refuse 'wrong marker AppID'
[ "$(plutil -extract transactionUUID raw -o - "$GTA_MARKER" 2>/dev/null)" = "$GTA_EXPECTED_TRANSACTION_UUID" ] || gta_refuse 'marker UUID does not match the confirmed transaction'
GTA_MARKER_HASH=$(gta_hash "$GTA_MARKER") || gta_refuse 'cannot hash marker'
GTA_STATE_HASH=absent
if [ -e "$GTA_STATE" ] || [ -L "$GTA_STATE" ]; then
  [ -f "$GTA_STATE" ] && [ ! -L "$GTA_STATE" ] || gta_refuse 'shared state is non-regular or a symlink'
  [ "$(stat -f %Lp "$GTA_STATE")" = 644 ] || gta_refuse 'shared-state mode is not 644'
  [ "$(stat -f %z "$GTA_STATE")" -le 1048576 ] || gta_refuse 'shared state is oversized'
  plutil -convert json -o /dev/null "$GTA_STATE" >/dev/null 2>&1 || gta_refuse 'shared state is not valid JSON'
  [ "$(plutil -extract schema raw -o - "$GTA_STATE" 2>/dev/null)" = 1 ] || gta_refuse 'unknown shared-state schema'
  [ "$(plutil -extract appid raw -o - "$GTA_STATE" 2>/dev/null)" = 1547000 ] || gta_refuse 'wrong shared-state AppID'
  [ "$(plutil -type references "$GTA_STATE" 2>/dev/null)" = array ] || gta_refuse 'unknown shared-state references field'
  [ "$(plutil -type files "$GTA_STATE" 2>/dev/null)" = dictionary ] || gta_refuse 'unknown shared-state files field'
  GTA_STATE_HASH=$(gta_hash "$GTA_STATE") || gta_refuse 'cannot hash shared state'
fi
GTA_DLLS_OWNED=no
if [ "$GTA_STATE_HASH" != absent ]; then
  GTA_DLLS_OWNED=yes
  for GTA_NAME in d3d11.dll dxgi.dll d3d10core.dll; do
    case "$GTA_NAME" in d3d11.dll) GTA_PIN=$GTA_PIN_D3D11 ;; dxgi.dll) GTA_PIN=$GTA_PIN_DXGI ;; *) GTA_PIN=$GTA_PIN_D3D10CORE ;; esac
    GTA_KEY="files.${GTA_NAME%.dll}\\.dll"
    GTA_FILE_OWNER=$(plutil -extract "$GTA_KEY.ownership" raw -o - "$GTA_STATE" 2>/dev/null) || GTA_FILE_OWNER=unknown
    GTA_FILE_HASH=$(plutil -extract "$GTA_KEY.sha256" raw -o - "$GTA_STATE" 2>/dev/null) || GTA_FILE_HASH=unknown
    if [ "$GTA_FILE_OWNER" != bridgeplay ] || [ "$GTA_FILE_HASH" != "$GTA_PIN" ]; then
      GTA_DLLS_OWNED=no
    fi
  done
fi
GTA_DLL_PRESENT_COUNT=0
for GTA_NAME in d3d11.dll dxgi.dll d3d10core.dll; do
  case "$GTA_NAME" in d3d11.dll) GTA_PIN=$GTA_PIN_D3D11 ;; dxgi.dll) GTA_PIN=$GTA_PIN_DXGI ;; *) GTA_PIN=$GTA_PIN_D3D10CORE ;; esac
  GTA_FILE="$GTA_DLL_DIR/$GTA_NAME"
  if [ -e "$GTA_FILE" ] || [ -L "$GTA_FILE" ]; then
    [ -f "$GTA_FILE" ] && [ ! -L "$GTA_FILE" ] || gta_refuse "unsafe DLL: $GTA_NAME"
    [ "$(gta_hash "$GTA_FILE")" = "$GTA_PIN" ] || gta_refuse "unknown or modified DLL: $GTA_NAME"
    GTA_DLL_PRESENT_COUNT=$((GTA_DLL_PRESENT_COUNT + 1))
  fi
done
if [ "$GTA_DLL_PRESENT_COUNT" -gt 0 ] && [ "$GTA_DLL_PRESENT_COUNT" -lt 3 ] && [ "$GTA_DLLS_OWNED" != yes ]; then
  gta_refuse 'partial DLL set has no verified Bridgeplay ownership; complete manual recipe section 5 or coordinate a backup'
fi
GTA_BACKUP="$GTA_PARENT/.bridgeplay-gta-sa-de-orphan-$GTA_EXPECTED_TRANSACTION_UUID"
[ ! -e "$GTA_BACKUP" ] && [ ! -L "$GTA_BACKUP" ] || gta_refuse 'quarantine destination already exists'
(umask 077 && mkdir -m 700 "$GTA_BACKUP") || gta_refuse 'cannot create private quarantine'
[ -d "$GTA_BACKUP" ] && [ ! -L "$GTA_BACKUP" ] && [ "$(stat -f %Lp "$GTA_BACKUP")" = 700 ] || gta_stop
gta_move() {
  GTA_SOURCE=$1; GTA_NAME=$2; GTA_EXPECTED=$3; GTA_DEST="$GTA_BACKUP/$GTA_NAME"
  if [ "$GTA_EXPECTED" = absent ]; then
    { [ ! -e "$GTA_SOURCE" ] && [ ! -L "$GTA_SOURCE" ]; } || gta_stop
    return
  fi
  [ -f "$GTA_SOURCE" ] && [ ! -L "$GTA_SOURCE" ] && [ ! -e "$GTA_DEST" ] && [ ! -L "$GTA_DEST" ] || gta_stop
  [ "$(gta_hash "$GTA_SOURCE")" = "$GTA_EXPECTED" ] || gta_stop
  mv -n "$GTA_SOURCE" "$GTA_DEST" || gta_stop
  { [ ! -e "$GTA_SOURCE" ] && [ ! -L "$GTA_SOURCE" ]; } || gta_stop
  [ -f "$GTA_DEST" ] && [ ! -L "$GTA_DEST" ] && [ "$(gta_hash "$GTA_DEST")" = "$GTA_EXPECTED" ] || gta_stop
}
if [ "$GTA_DLLS_OWNED" = yes ]; then
  for GTA_NAME in d3d11.dll dxgi.dll d3d10core.dll; do
    case "$GTA_NAME" in d3d11.dll) GTA_PIN=$GTA_PIN_D3D11 ;; dxgi.dll) GTA_PIN=$GTA_PIN_DXGI ;; *) GTA_PIN=$GTA_PIN_D3D10CORE ;; esac
    GTA_FILE="$GTA_DLL_DIR/$GTA_NAME"
    if [ -e "$GTA_FILE" ] || [ -L "$GTA_FILE" ]; then gta_move "$GTA_FILE" "$GTA_NAME" "$GTA_PIN"; else gta_move "$GTA_FILE" "$GTA_NAME" absent; fi
  done
fi
gta_move "$GTA_STATE" .bridgeplay-gta-sa-de-1547000.json "$GTA_STATE_HASH"
gta_move "$GTA_MARKER" .bridgeplay-gta-sa-de-1547000.pending.json "$GTA_MARKER_HASH"
printf 'Quarantine complete: %s\n' "$GTA_BACKUP"
)
# END GTA 1547000 ORPHAN RECOVERY BODY
~~~

If any move fails or the script is interrupted, keep every account's Steam,
Wine and game processes stopped. If the marker is missing from the game root,
verify it in the quarantine and restore it first to reinstate the block; if it
is still in the game root, leave it there. Then restore each quarantined DLL or
shared-state file only after verifying its hash and confirming the destination
is absent. Once all files are verified in their original paths, use `rmdir`
on that exact quarantine directory only if it is empty; this permits a retry
with the same UUID. Never recursively delete the quarantine. If you cannot
safely finish or undo the moves, use a separate clean Steam game install and
retain the quarantine for recovery. This manual sequence is not crash-proof or
atomic.

After a completed quarantine, restore each surviving prefix directly, from its
own macOS account. This does not launch the game. Set `GTA_DATA` to that
account's existing `compatdata/1547000` directory; do not create or replace
the prefix folder. Run this in the shell where `GTA_GAME` was set above:

~~~sh
GTA_DATA='/absolute/path/to/steamapps/compatdata/1547000'
GTA_FIX_HELPER="$HOME/Library/Application Support/bridgeplay/gamefix-prep"
GTA_SA_APP_ID=1547000 GTA_SA_DATA_PATH="$GTA_DATA" \
GTA_SA_PREFIX="$GTA_DATA/pfx" GTA_SA_GAME="$GTA_GAME" \
  "$GTA_FIX_HELPER" restore
~~~

#### Manual recovery for an orphaned Social Club helper backup

Use this only after the orphan game quarantine above is complete and only for
the original owner prefix whose transaction journal is irretrievably lost.
First try that prefix's normal `gamefix-prep restore`; run this only when it
reports `no-owned-state` and both its `state.json` and transaction journal
are absent. Keep Steam, Wine, GTA and Rockstar Launcher stopped in every
macOS account using this install. The acknowledgement records that you checked
the original owner prefix, confirmed the journal is irretrievably lost, and
stopped all those sessions.

This covers the fresh-install interruption after the vendor helper was copied
to `SocialClubHelper_real.exe` but before the wrapper replaced the active
helper, including checkpoints where the checksum and license were installed
first. The script leaves the active helper in place. It quarantines the
duplicate real helper only when both files are regular, non-symlink files,
byte-identical, and match the pinned supported vendor build. It also
quarantines the checksum only when its exact expected bytes match, and the
license only when its pinned hash matches. Changed files, symlinks, unknown
vendor builds, a current wrapper, or any present owner state/journal stop the
script before its first move. The unique mode-700 quarantine is beside this
one prefix's `pfx` directory, outside it. Do not run this against every
account's backup. It does not touch saves, authentication data, registry data,
or the active helper. After it completes, retry normal preparation for this
prefix.

Set `GTA_GAME` to the game root and `GTA_DATA` to this original owner's
existing `compatdata/1547000` directory, and set the acknowledgement exactly
as shown. Keep all three pinned helper hashes unchanged.

~~~sh
GTA_GAME='/absolute/path/to/GTA San Andreas - The Definitive Edition'
GTA_DATA='/absolute/path/to/compatdata/1547000'
GTA_HELPER_ORPHAN_ACK='I_CONFIRMED_ORIGINAL_OWNER_PREFIX_JOURNAL_LOST_AND_ALL_STEAM_WINE_SESSIONS_STOPPED'
export GTA_GAME GTA_DATA GTA_HELPER_ORPHAN_ACK

# BEGIN GTA 1547000 ORPHAN HELPER PIN SETUP
GTA_PIN_VENDOR='d3bd835897a97207d26e703969232ded54fd32c4388691c7ebd95709a54f9a6d'
GTA_PIN_WRAPPER='80eced29c22d2f3fb7fc38c6c99792350a4f3ef6bacc32971830b5d2e27ad7d5'
GTA_PIN_LICENSE='2985ef68fb7ab2e5163a39352917e271eac05ceec0aa4a9fab6e78cec917a6d6'
export GTA_PIN_VENDOR GTA_PIN_WRAPPER GTA_PIN_LICENSE
# END GTA 1547000 ORPHAN HELPER PIN SETUP

# BEGIN GTA 1547000 ORPHAN HELPER RECOVERY BODY
(
set -eu
gta_helper_refuse() { printf 'Refusing orphan helper recovery: %s\n' "$1" >&2; exit 1; }
gta_helper_stop() {
  printf 'STOP: keep Steam/Wine closed; preserve quarantine %s and inspect every file.\n' "${GTA_BACKUP-}" >&2
  exit 1
}
gta_helper_hash() { GTA_HASH_LINE=$(shasum -a 256 "$1") || return 1; printf '%s' "${GTA_HASH_LINE%% *}"; }
[ "${GTA_HELPER_ORPHAN_ACK-}" = 'I_CONFIRMED_ORIGINAL_OWNER_PREFIX_JOURNAL_LOST_AND_ALL_STEAM_WINE_SESSIONS_STOPPED' ] || gta_helper_refuse 'original-owner journal loss and stopped sessions were not acknowledged'
for GTA_PIN in "${GTA_PIN_VENDOR-}" "${GTA_PIN_WRAPPER-}" "${GTA_PIN_LICENSE-}"; do
  case "$GTA_PIN" in ????????*) [ "${#GTA_PIN}" -eq 64 ] || gta_helper_refuse 'invalid pinned helper hash' ;; *) gta_helper_refuse 'missing pinned helper hash' ;; esac
  case "$GTA_PIN" in *[!0123456789abcdef]*) gta_helper_refuse 'pinned helper hash must be lowercase hexadecimal' ;; esac
done
case "${GTA_GAME-}" in /*) ;; *) gta_helper_refuse 'GTA_GAME must be absolute' ;; esac
case "${GTA_DATA-}" in /*) ;; *) gta_helper_refuse 'GTA_DATA must be absolute' ;; esac
[ "$GTA_GAME" != / ] && [ "$GTA_DATA" != / ] || gta_helper_refuse 'game and data roots cannot be /'
[ -d "$GTA_GAME" ] && [ ! -L "$GTA_GAME" ] || gta_helper_refuse 'game root is unavailable or a symlink'
[ -d "$GTA_DATA" ] && [ ! -L "$GTA_DATA" ] || gta_helper_refuse 'prefix data root is unavailable or a symlink'
GTA_GAME_PHYSICAL=$(CDPATH= cd -P "$GTA_GAME" 2>/dev/null && pwd -P) || gta_helper_refuse 'cannot canonicalize game root'
GTA_DATA_PHYSICAL=$(CDPATH= cd -P "$GTA_DATA" 2>/dev/null && pwd -P) || gta_helper_refuse 'cannot canonicalize prefix data root'
GTA_GAME=$GTA_GAME_PHYSICAL
GTA_DATA=$GTA_DATA_PHYSICAL
[ "$GTA_GAME" != / ] && [ "$GTA_DATA" != / ] || gta_helper_refuse 'canonical game and data roots cannot be /'
GTA_PREFIX="$GTA_DATA/pfx"
[ "$(id -u)" = "$(stat -f %u "$GTA_DATA")" ] || gta_helper_refuse 'prefix data root is not owned by this account'
[ -d "$GTA_PREFIX" ] && [ ! -L "$GTA_PREFIX" ] || gta_helper_refuse 'prefix root is unavailable or a symlink'
[ "$(id -u)" = "$(stat -f %u "$GTA_PREFIX")" ] || gta_helper_refuse 'prefix root is not owned by this account'
for GTA_DIR in "$GTA_PREFIX" "$GTA_PREFIX/drive_c" "$GTA_PREFIX/drive_c/Program Files" \
  "$GTA_PREFIX/drive_c/Program Files/Rockstar Games" \
  "$GTA_PREFIX/drive_c/Program Files/Rockstar Games/Social Club"; do
  [ -d "$GTA_DIR" ] && [ ! -L "$GTA_DIR" ] || gta_helper_refuse "unsafe or missing prefix directory: $GTA_DIR"
done
GTA_MARKER="$GTA_GAME/.bridgeplay-gta-sa-de-1547000.pending.json"
[ ! -e "$GTA_MARKER" ] && [ ! -L "$GTA_MARKER" ] || gta_helper_refuse 'complete orphan game quarantine before helper recovery'
GTA_STATE_DIR="$GTA_DATA/.bridgeplay-gta-sa-de-1547000"
if [ -e "$GTA_STATE_DIR" ] || [ -L "$GTA_STATE_DIR" ]; then
  [ -d "$GTA_STATE_DIR" ] && [ ! -L "$GTA_STATE_DIR" ] || gta_helper_refuse 'unsafe prefix state directory'
  [ "$(id -u)" = "$(stat -f %u "$GTA_STATE_DIR")" ] || gta_helper_refuse 'prefix state directory belongs to another account'
  [ "$(stat -f %Lp "$GTA_STATE_DIR")" = 700 ] || gta_helper_refuse 'prefix state directory mode is not 700'
  [ -r "$GTA_STATE_DIR" ] && [ -x "$GTA_STATE_DIR" ] || gta_helper_refuse 'prefix state directory is not readable and searchable'
fi
GTA_STATE="$GTA_STATE_DIR/state.json"
GTA_JOURNAL="$GTA_STATE_DIR/.bridgeplay-gta-sa-de-1547000.transaction.json"
for GTA_FILE in "$GTA_STATE" "$GTA_JOURNAL"; do
  { [ ! -e "$GTA_FILE" ] && [ ! -L "$GTA_FILE" ]; } || gta_helper_refuse 'prefix state or owner journal is present; recover it normally'
done
GTA_HELPER_DIR="$GTA_PREFIX/drive_c/Program Files/Rockstar Games/Social Club"
GTA_HELPER="$GTA_HELPER_DIR/SocialClubHelper.exe"
GTA_REAL="$GTA_HELPER_DIR/SocialClubHelper_real.exe"
GTA_CHECKSUM="$GTA_HELPER_DIR/SocialClubHelper_real.exe.sha256"
GTA_LICENSE="$GTA_HELPER_DIR/SocialClubHelper.bridgeplay.LICENSE"
[ -f "$GTA_HELPER" ] && [ ! -L "$GTA_HELPER" ] || gta_helper_refuse 'active helper is not a regular file'
[ -f "$GTA_REAL" ] && [ ! -L "$GTA_REAL" ] || gta_helper_refuse 'saved real helper is not a regular file'
GTA_HELPER_HASH=$(gta_helper_hash "$GTA_HELPER") || gta_helper_refuse 'cannot hash active helper'
GTA_REAL_HASH=$(gta_helper_hash "$GTA_REAL") || gta_helper_refuse 'cannot hash saved real helper'
[ "$GTA_HELPER_HASH" != "$GTA_PIN_WRAPPER" ] || gta_helper_refuse 'active helper is already the Bridgeplay wrapper'
[ "$GTA_HELPER_HASH" = "$GTA_PIN_VENDOR" ] && [ "$GTA_REAL_HASH" = "$GTA_PIN_VENDOR" ] || gta_helper_refuse 'active and saved helpers are not the pinned supported vendor build'
cmp -s "$GTA_HELPER" "$GTA_REAL" || gta_helper_refuse 'active and saved helpers are not byte-identical'
GTA_CHECKSUM_PRESENT=no
GTA_CHECKSUM_HASH=$(printf '%s  SocialClubHelper_real.exe\n' "$GTA_PIN_VENDOR" | shasum -a 256) || gta_helper_refuse 'cannot hash expected checksum bytes'
GTA_CHECKSUM_HASH=${GTA_CHECKSUM_HASH%% *}
if [ -e "$GTA_CHECKSUM" ] || [ -L "$GTA_CHECKSUM" ]; then
  [ -f "$GTA_CHECKSUM" ] && [ ! -L "$GTA_CHECKSUM" ] || gta_helper_refuse 'checksum is not a regular file'
  printf '%s  SocialClubHelper_real.exe\n' "$GTA_PIN_VENDOR" | cmp -s "$GTA_CHECKSUM" - || gta_helper_refuse 'checksum bytes are unknown'
  GTA_CHECKSUM_PRESENT=yes
fi
GTA_LICENSE_PRESENT=no
if [ -e "$GTA_LICENSE" ] || [ -L "$GTA_LICENSE" ]; then
  [ -f "$GTA_LICENSE" ] && [ ! -L "$GTA_LICENSE" ] || gta_helper_refuse 'license is not a regular file'
  [ "$(gta_helper_hash "$GTA_LICENSE")" = "$GTA_PIN_LICENSE" ] || gta_helper_refuse 'license hash is unknown'
  GTA_LICENSE_PRESENT=yes
fi
GTA_BACKUP=$(umask 077 && mktemp -d "$GTA_DATA/.bridgeplay-gta-sa-de-helper-orphan.XXXXXXXX") || gta_helper_refuse 'cannot create a unique private quarantine'
[ -d "$GTA_BACKUP" ] && [ ! -L "$GTA_BACKUP" ] && [ "$(stat -f %Lp "$GTA_BACKUP")" = 700 ] || gta_helper_stop
case "$GTA_BACKUP" in "$GTA_PREFIX"/*) gta_helper_stop ;; esac
gta_helper_move() {
  GTA_SOURCE=$1; GTA_NAME=$2; GTA_EXPECTED=$3; GTA_DEST="$GTA_BACKUP/$GTA_NAME"
  [ -f "$GTA_SOURCE" ] && [ ! -L "$GTA_SOURCE" ] && [ ! -e "$GTA_DEST" ] && [ ! -L "$GTA_DEST" ] || gta_helper_stop
  [ "$(gta_helper_hash "$GTA_SOURCE")" = "$GTA_EXPECTED" ] || gta_helper_stop
  mv -n "$GTA_SOURCE" "$GTA_DEST" || gta_helper_stop
  { [ ! -e "$GTA_SOURCE" ] && [ ! -L "$GTA_SOURCE" ]; } || gta_helper_stop
  [ -f "$GTA_DEST" ] && [ ! -L "$GTA_DEST" ] && [ "$(gta_helper_hash "$GTA_DEST")" = "$GTA_EXPECTED" ] || gta_helper_stop
}
[ "$(gta_helper_hash "$GTA_HELPER")" = "$GTA_PIN_VENDOR" ] && cmp -s "$GTA_HELPER" "$GTA_REAL" || gta_helper_stop
gta_helper_move "$GTA_REAL" SocialClubHelper_real.exe "$GTA_PIN_VENDOR"
if [ "$GTA_CHECKSUM_PRESENT" = yes ]; then
  gta_helper_move "$GTA_CHECKSUM" SocialClubHelper_real.exe.sha256 "$GTA_CHECKSUM_HASH"
else
  { [ ! -e "$GTA_CHECKSUM" ] && [ ! -L "$GTA_CHECKSUM" ]; } || gta_helper_stop
fi
if [ "$GTA_LICENSE_PRESENT" = yes ]; then
  gta_helper_move "$GTA_LICENSE" SocialClubHelper.bridgeplay.LICENSE "$GTA_PIN_LICENSE"
else
  { [ ! -e "$GTA_LICENSE" ] && [ ! -L "$GTA_LICENSE" ]; } || gta_helper_stop
fi
printf 'Orphan helper files quarantined for this prefix: %s\n' "$GTA_BACKUP"
)
# END GTA 1547000 ORPHAN HELPER RECOVERY BODY
~~~

As an alternative, use `BRIDGEPLAY_GTA_SA_DE_FIX=0` once for each surviving
prefix to clear its private ownership before enabling the fix again. The
quarantine does not prove that any private journal is lost: inspect and
recover each one from its owner account. The marker and shared state are public
shared files; never put private journal paths in them or share private
journals.

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
Automation fixtures cover file lifecycle, rollback, cross-prefix transaction
recovery and mode policy; they do not provide gameplay verification or verify
operation as a second macOS UID.

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

Before using the manual fallback, inspect the game's Steam launch options and
per-game graphics choice for a conflicting backend or DXGI override. Remove or
change only a conflicting `BRIDGEPLAY_BACKEND`/`NOTPROTON_BACKEND` or
`CX_GRAPHICS_BACKEND` choice. In `WINEDLLOVERRIDES` or `DLLOVERRIDES`, update
only the conflicting `dxgi` entry. Preserve unrelated launch arguments and DLL
module entries.

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
