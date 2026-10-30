#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> bridgecheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^bridge_files="steamclient64/,/^  verify_runner$/p' "$SRC")
case "$block" in
  *'bridge_matches='*'
  verify_runner') ;;
  *) echo "FAIL: the bridge staging block not found in $SRC"; exit 1 ;;
esac
block=$(printf '%s\n' "$block" | sed '$d')
legacy=$(sed -n '/^install_legacycompat() {/,/^}/p' "$SRC")
[ -n "$legacy" ] || { echo "FAIL: install_legacycompat not found in $SRC"; exit 1; }
body='same_volume() { [ -z "$cross" ]; }
volume_clones() { :; }
show_alert() { printf "alert: %s\n" "$1" >> "$log"; }
'"$block
fi"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll tier0_s.dll vstdlib_s.dll lsteamclient.dll steam.exe"
mkdir -p "$work/bridge"
for f in $files; do printf 'bridge %s\n' "$f" > "$work/bridge/$f"; done
for arch in aarch64-unix x86_64-unix; do
	mkdir -p "$work/bridge/$arch"
	printf '%s bridge\n' "$arch" > "$work/bridge/$arch/lsteamclient.so"
done
wine_unix="$work/runner/aarch64-unix"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
logged() { if grep -qxF "$2" "$work/log"; then ok "$1"; else bad "$1" "$2" "$(cat "$work/log")"; fi; }
unlogged() { if grep -qxF "$2" "$work/log"; then bad "$1" "no [$2]" "$(cat "$work/log")"; else ok "$1"; fi; }

prefix="$work/pfx"
steam="$prefix/drive_c/Program Files (x86)/Steam"
compat=""
cross=""

stage() {
	: > "$work/log"
	env bridge_src="$work/bridge" WINEPREFIX="$prefix" prefix_steam="$steam" \
		log="$work/log" body="$body" wine_unix="$wine_unix" \
		STEAM_COMPAT_DATA_PATH="$compat" cross="$cross" \
		sh -ec 'eval "$body"; echo reached' > "$work/out" 2>&1 || true
}
staged() {
	n=0
	for f in $files; do cmp -s "$work/bridge/$f" "$steam/$f" && n=$((n + 1)); done
	echo "$n"
}

echo "== a fresh prefix gets the whole bridge"
stage
is "the launch goes on past staging" reached "$(cat "$work/out")"
is "every file is copied" 8 "$(staged)"
is "the ARM64 unix library is staged beside the DLL" "aarch64-unix bridge" "$(cat "$steam/lsteamclient.so" 2>/dev/null)"
unlogged "nothing claims to be staged already" "=== bridge already staged ==="

echo "== a second launch copies nothing"
stage
is "the launch goes on" reached "$(cat "$work/out")"
logged "the copy is recognised" "=== bridge already staged ==="
is "the unix library survives pruning" "aarch64-unix bridge" "$(cat "$steam/lsteamclient.so" 2>/dev/null)"

echo "== a different Wine architecture replaces the unix library"
wine_unix="$work/runner/x86_64-unix"
stage
unlogged "the old architecture is not taken as current" "=== bridge already staged ==="
is "the x86_64 unix library replaces the ARM64 copy" "x86_64-unix bridge" "$(cat "$steam/lsteamclient.so" 2>/dev/null)"
stage
logged "the x86_64 copy is recognised" "=== bridge already staged ==="

echo "== a changed unix library is copied again"
printf 'updated x86_64 bridge\n' > "$work/bridge/x86_64-unix/lsteamclient.so"
stage
unlogged "the old unix library is not taken as current" "=== bridge already staged ==="
is "the prefix receives the updated unix library" "updated x86_64 bridge" "$(cat "$steam/lsteamclient.so" 2>/dev/null)"

echo "== changed bytes with the same size and timestamp"
cp -p "$work/bridge/steam.exe" "$work/stamp"
printf 'edited steam.exe\n' > "$work/bridge/steam.exe"
touch -r "$work/stamp" "$work/bridge/steam.exe"
is "the metadata still matches" "$(stat -f '%z %m' "$steam/steam.exe")" "$(stat -f '%z %m' "$work/bridge/steam.exe")"
stage
unlogged "matching metadata does not hide changed contents" "=== bridge already staged ==="
is "the prefix receives the changed bytes" 8 "$(staged)"

echo "== a DLL the bridge no longer ships is pruned"
printf 'old\n' > "$steam/old.dll"
stage
is "the launch goes on" reached "$(cat "$work/out")"
logged "the prune is logged" "=== pruned stale old.dll ==="
is "and the file is gone" no "$([ -e "$steam/old.dll" ] && echo yes || echo no)"

echo "== a changed bridge file is copied again"
printf 'bridge steamclient64.dll, newer build\n' > "$work/bridge/steamclient64.dll"
stage
is "the launch goes on" reached "$(cat "$work/out")"
unlogged "the old copy is not taken as current" "=== bridge already staged ==="
is "every file matches the bridge" 8 "$(staged)"

echo "== a bridge missing a file still stages the rest"
rm -rf "$prefix"
rm "$work/bridge/steam.exe"
stage
is "the launch goes on" reached "$(cat "$work/out")"
logged "the missing file is logged" "=== bridge missing steam.exe ==="
is "the other files are copied" 7 "$(staged)"
printf 'bridge steam.exe\n' > "$work/bridge/steam.exe"

echo "== a prefix on the same drive clones from the bridge itself"
rm -rf "$prefix"
compat="$work/library/compatdata/1"
cache="$work/library/compatdata/notproton-template/bridge"
stage
is "every file is copied" 8 "$(staged)"
is "no copy of the bridge is made" no "$([ -e "$cache" ] && echo yes || echo no)"

echo "== a prefix on another drive clones from that drive's copy"
rm -rf "$prefix"
cross=1
stage
is "the launch goes on" reached "$(cat "$work/out")"
is "every file is copied" 8 "$(staged)"
is "the drive keeps a copy of steam.exe" "bridge steam.exe" "$(cat "$cache/steam.exe" 2>/dev/null)"
is "the drive keeps the unix library under its architecture" "updated x86_64 bridge" \
	"$(cat "$cache/x86_64-unix/lsteamclient.so" 2>/dev/null)"
is "no temporary copies are left" "" "$(find "$cache" -name '*.[0-9]*' 2>/dev/null)"

echo "== a changed bridge file refreshes the drive's copy"
printf 'bridge steam.exe, newer build\n' > "$work/bridge/steam.exe"
stage
is "the drive's copy is replaced" "bridge steam.exe, newer build" "$(cat "$cache/steam.exe" 2>/dev/null)"
is "the prefix receives the new file" "bridge steam.exe, newer build" "$(cat "$steam/steam.exe" 2>/dev/null)"

echo "== a linked copy on the drive is not used"
rm -rf "$prefix" "$cache"
mkdir -p "$work/elsewhere"
ln -s "$work/elsewhere" "$cache"
stage
is "every file is copied" 8 "$(staged)"
is "nothing is written through the link" "" "$(ls "$work/elsewhere")"
rm "$cache"

echo "== a drive that cannot hold a copy still gets the bridge"
rm -rf "$prefix"
mkdir -p "${cache%/*}"
chmod 500 "${cache%/*}"
stage
chmod 700 "${cache%/*}"
is "the launch goes on" reached "$(cat "$work/out")"
is "every file is copied" 8 "$(staged)"

echo "== a file that cannot be staged stops the launch"
cross=""
rm "$steam/steam.exe"
chmod 500 "$steam"
stage
chmod 700 "$steam"
is "the launch stops" "" "$(grep -x reached "$work/out")"
logged "the failure is logged" "=== could not copy steam.exe to $steam/steam.exe ==="
is "the reason is logged" yes "$(grep -q 'Permission denied' "$work/log" && echo yes || echo no)"
logged "the player is told" "alert: Steam files could not be copied"
stage
is "the next launch stages it" reached "$(cat "$work/out")"
is "every file is copied" 8 "$(staged)"

echo "== a syswow64 trigger that cannot be installed stops the launch"
trigger=$(sed -n '/^install_lsteamclient_trigger() {/,/^}/p;/^bridge_origin() {/,/^}/p;/^place_bridge_file() {/,/^}/p' "$SRC")
mkdir -p "$work/bridge/i386-windows" "$prefix/drive_c/windows/syswow64"
printf 'i386 bridge\n' > "$work/bridge/i386-windows/lsteamclient.dll"
chmod 500 "$prefix/drive_c/windows/syswow64"
: > "$work/log"
env bridge_src="$work/bridge" WINEPREFIX="$prefix" log="$work/log" bridge_cache="" trigger="$trigger" \
	sh -ec 'eval "$trigger"; if install_lsteamclient_trigger; then echo installed; else echo refused; fi' > "$work/out" 2>&1 || true
chmod 700 "$prefix/drive_c/windows/syswow64"
is "the trigger reports the failure" refused "$(cat "$work/out")"
logged "the failure is logged" "=== could not copy i386-windows/lsteamclient.dll to $prefix/drive_c/windows/syswow64/lsteamclient.dll ==="
is "the reason is logged" yes "$(grep -q 'Permission denied' "$work/log" && echo yes || echo no)"
is "the launch checks the trigger" 1 "$(grep -c '^  if ! install_lsteamclient_trigger; then$' "$SRC")"
env bridge_src="$work/bridge" WINEPREFIX="$prefix" log="$work/log" bridge_cache="" trigger="$trigger" \
	sh -ec 'eval "$trigger"; if install_lsteamclient_trigger; then echo installed; else echo refused; fi' > "$work/out" 2>&1 || true
is "a writable prefix gets the trigger" installed "$(cat "$work/out")"

echo "== a legacycompat file that cannot be installed does not stop the launch"
mkdir -p "$work/bridge/legacycompat" "$work/client/legacycompat"
printf 'bridge Steam.dll\n' > "$work/bridge/legacycompat/Steam.dll"
chmod 500 "$work/client/legacycompat"
: > "$work/log"
env bridge_src="$work/bridge" STEAM_COMPAT_CLIENT_INSTALL_PATH="$work/client" log="$work/log" \
	legacy="$legacy" sh -ec 'eval "$legacy"; install_legacycompat; echo reached' > "$work/out" 2>&1 || true
chmod 700 "$work/client/legacycompat"
is "the launch goes on" reached "$(cat "$work/out")"
logged "the failure is logged" "=== could not copy legacycompat/Steam.dll to $work/client/legacycompat/Steam.dll ==="
is "the reason is logged" yes "$(grep -q 'Permission denied' "$work/log" && echo yes || echo no)"

echo "== the legacy Steam.dll is linked next to the game folder"
link=$(sed -n '/^link_legacy_steam_dll() {/,/^}/p' "$SRC")
[ -n "$link" ] || { echo "FAIL: link_legacy_steam_dll not found in $SRC"; exit 1; }
is "the launch links it" 1 "$(grep -c '^  link_legacy_steam_dll$' "$SRC")"
mkdir -p "$work/lib/common/Game"
printf 'client Steam.dll\n' > "$work/client/legacycompat/Steam.dll"
run_link() {
	env STEAM_COMPAT_CLIENT_INSTALL_PATH="$work/client" STEAM_COMPAT_INSTALL_PATH="$work/lib/common/Game" \
		log="$work/log" link="$link" sh -ec 'eval "$link"; link_legacy_steam_dll; echo reached' > "$work/out" 2>&1 || true
}
: > "$work/log"
run_link
is "the launch goes on" reached "$(cat "$work/out")"
is "a missing link is created" "$work/client/legacycompat/Steam.dll" "$(readlink "$work/lib/common/Steam.dll")"
logged "the link is logged" "=== linked legacy Steam.dll at $work/lib/common/Steam.dll ==="
is "a new link is hidden" hidden "$(stat -f %Sf "$work/lib/common/Steam.dll")"
is "the linked file is not hidden" - "$(stat -f %Sf "$work/client/legacycompat/Steam.dll")"
chflags -h nohidden "$work/lib/common/Steam.dll"
: > "$work/log"
run_link
is "a current link is left alone" "" "$(cat "$work/log")"
is "a current link is not touched" - "$(stat -f %Sf "$work/lib/common/Steam.dll")"
ln -sfn "$work/old/Steam.dll" "$work/lib/common/Steam.dll"
run_link
is "a stale link is replaced" "$work/client/legacycompat/Steam.dll" "$(readlink "$work/lib/common/Steam.dll")"
is "a replaced link is hidden" hidden "$(stat -f %Sf "$work/lib/common/Steam.dll")"
rm -f "$work/lib/common/Steam.dll"
printf 'real\n' > "$work/lib/common/Steam.dll"
run_link
is "a real file is kept" real "$(cat "$work/lib/common/Steam.dll")"
is "a real file is not hidden" - "$(stat -f %Sf "$work/lib/common/Steam.dll")"
rm -f "$work/lib/common/Steam.dll"
chmod 500 "$work/lib/common"
: > "$work/log"
run_link
chmod 700 "$work/lib/common"
is "an unwritable library does not stop the launch" reached "$(cat "$work/out")"
logged "the failure is logged" "=== could not link legacy Steam.dll at $work/lib/common/Steam.dll ==="

[ "$fails" -eq 0 ] || { echo "==> bridgecheck: $fails failure(s)"; exit 1; }
echo "==> bridgecheck: the bridge stages on fresh, current, stale and incomplete prefixes"
