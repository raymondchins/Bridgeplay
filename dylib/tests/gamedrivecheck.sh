#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> gamedrivecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^game_drive_record() {/,/^}/p;/^record_game_drive() {/,/^}/p;/^restart_for_drive() {/,/^}/p;/^unmap_game_drive() {/,/^}/p;/^map_game_drive() {/,/^}/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: map_game_drive not found in $SRC"; exit 1; }
body='without_lock_fds() { printf "%s\n" "${1##*/} $2" >> "$restarts"; }
'"$body"

# a failed mktemp must not leave work at the current folder, which the trap deletes
work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

lib="$work/Steam Library/One"
other="$work/Other Library"
mkdir -p "$lib/steamapps/common/Some Game" "$lib/steamapps/compatdata/1/pfx/dosdevices" \
	"$other/steamapps/common/Some Game"
compat="$lib/steamapps/compatdata/1"
prefix="$compat/pfx"
drive="$prefix/dosdevices/s:"
libs="$work/elsewhere/steamapps:$lib/steamapps/"

run() {
	: > "$work/log"
	: > "$work/restarts"
	env restarts="$work/restarts" WINESERVER=/runner/wineserver WINEPREFIX="$prefix" STEAM_COMPAT_DATA_PATH="$compat" log="$work/log" body="$body" \
		STEAM_COMPAT_INSTALL_PATH="$1" STEAM_COMPAT_LIBRARY_PATHS="$2" \
		extra="${3:-}" sh -ec 'eval "$body"; eval "$extra"; map_game_drive; echo reached' > "$work/out" 2>&1 || true
}
target() { readlink "$drive" 2>/dev/null || echo none; }
restarted() { tr '\n' ' ' < "$work/restarts"; }

echo "== the library holding the game becomes S:"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: points at the library root" "$lib" "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
is "the mapping is recorded" "$lib" "$(cat "$compat/notproton-game-drive")"
is "wine restarts to see S:" "wineserver -k wineserver -w " "$(restarted)"

echo "== a second launch leaves it alone"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: is unchanged" "$lib" "$(target)"
is "nothing is logged" "" "$(cat "$work/log")"
is "wine is not restarted" "" "$(restarted)"

echo "== a moved game follows its library"
run "$other/steamapps/common/Some Game" "$libs:$other/steamapps"
is "S: points at the new library" "$other" "$(target)"
is "wine restarts to see the move" "wineserver -k wineserver -w " "$(restarted)"

echo "== a user's own S: is kept"
rm -f "$drive"
ln -s /tmp "$drive"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: still points at /tmp" /tmp "$(target)"
is "wine is not restarted" "" "$(restarted)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== an S: folder is kept"
rm -f "$drive"
mkdir "$drive"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: is still a folder" yes "$([ -d "$drive" ] && [ ! -L "$drive" ] && echo yes)"
is "the launch continues" reached "$(tail -1 "$work/out")"
rmdir "$drive"

echo "== a game that left every library loses its S:"
run "$lib/steamapps/common/Some Game" "$libs"
run "$work/loose/Some Game" "$libs"
is "no S:" none "$(target)"
is "the record is gone" no "$([ -e "$compat/notproton-game-drive" ] && echo yes || echo no)"
is "wine restarts to drop S:" "wineserver -k wineserver -w " "$(restarted)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== no library paths from Steam leave S: alone"
run "$lib/steamapps/common/Some Game" "$libs"
for none in "" ":" "::"; do
	run "$lib/steamapps/common/Some Game" "$none"
	is "S: still points at the library root ($none)" "$lib" "$(target)"
	is "the mapping is still recorded ($none)" "$lib" "$(cat "$compat/notproton-game-drive")"
	is "wine is not restarted ($none)" "" "$(restarted)"
	is "the launch continues ($none)" reached "$(tail -1 "$work/out")"
done
rm -f "$drive" "$compat/notproton-game-drive"
run "$lib/steamapps/common/Some Game" ""
is "no S: is made without library paths" none "$(target)"
is "wine is not restarted without library paths" "" "$(restarted)"

echo "== a game outside every library gets no S:"
run "$work/loose/Some Game" "$libs"
is "no S:" none "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
is "wine is not restarted" "" "$(restarted)"

echo "== a user's own S: survives a game outside every library"
ln -s /tmp "$drive"
run "$work/loose/Some Game" "$libs"
is "S: still points at /tmp" /tmp "$(target)"
is "wine is not restarted" "" "$(restarted)"
rm -f "$drive"

echo "== a recorded S: deleted by hand comes back"
run "$lib/steamapps/common/Some Game" "$libs"
rm -f "$drive"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: points at the library root" "$lib" "$(target)"
is "wine restarts to see S:" "wineserver -k wineserver -w " "$(restarted)"

echo "== a failed link keeps the launch going without a restart"
rm -f "$drive"
run "$lib/steamapps/common/Some Game" "$libs" 'ln() { return 1; }'
is "no S:" none "$(target)"
is "the failure is logged" yes "$(grep -q 'could not map drive S:' "$work/log" && echo yes)"
is "wine is not restarted" "" "$(restarted)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== empty library entries are skipped"
run "$lib/steamapps/common/Some Game" "::$lib/steamapps::"
is "S: points at the library root" "$lib" "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
rm -f "$drive"

echo "== a library whose parent is not writable maps steamapps itself"
mkdir -p "$work/locked/steamapps/common/Some Game"
chmod a-w "$work/locked"
run "$work/locked/steamapps/common/Some Game" "$work/locked/steamapps"
chmod u+w "$work/locked"
is "S: points at steamapps" "$work/locked/steamapps" "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
rm -f "$drive"

echo "== a library on another volume than its parent maps steamapps itself"
mkdir -p "$work/far/steamapps/common/Some Game"
run "$work/far/steamapps/common/Some Game" "$work/far/steamapps" \
	'stat() { case "$3" in */steamapps) echo 2 ;; *) echo 1 ;; esac; }'
is "S: points at steamapps" "$work/far/steamapps" "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
rm -f "$drive"

echo "== a library whose name only starts the same does not match"
run "$lib/steamapps2/common/Some Game" "$lib/steamapps"
is "no S:" none "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== a library path that is not a steamapps folder maps as is"
mkdir -p "$work/flat/common/Some Game"
run "$work/flat/common/Some Game" "$work/flat"
is "S: points at the library itself" "$work/flat" "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
rm -f "$drive"

echo "== a prefix without dosdevices is left for wine to build"
mv "$prefix/dosdevices" "$prefix/dosdevices.off"
run "$lib/steamapps/common/Some Game" "$libs"
is "no dosdevices created" no "$([ -e "$prefix/dosdevices" ] && echo yes || echo no)"
is "the launch continues" reached "$(tail -1 "$work/out")"
mv "$prefix/dosdevices.off" "$prefix/dosdevices"

[ "$fails" -eq 0 ] || { echo "gamedrivecheck: $fails failed"; exit 1; }
echo "gamedrivecheck: all passed"
