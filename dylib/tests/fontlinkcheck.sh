#!/bin/sh
# link_fonts: links the shared fonts into a prefix and leaves fonts installed there alone.
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> fontlinkcheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^link_fonts() {/,/^}/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: link_fonts not found in $SRC"; exit 1; }

work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
volume=
trap '[ -z "$volume" ] || hdiutil detach -quiet "$volume" 2>/dev/null || true; rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

support="$work/support"
runner="$work/runner"
mkdir -p "$support/fonts/alt" "$runner/share/wine/fonts"
for f in arial.ttf times.ttf; do echo "shared $f" > "$support/fonts/$f"; done
echo "alt arial" > "$support/fonts/alt/arial.ttf"
echo "wine tahoma" > "$runner/share/wine/fonts/tahoma.ttf"

# $1: the folder the prefix lives in, $2: the app id
run() {
	mkdir -p "$1/pfx"
	: > "$1/pfx/system.reg"
	env WINEPREFIX="$1/pfx" np_support="$support" CX_ROOT="$runner" app_id="$2" log="$work/log" body="$body" \
		sh -ec 'eval "$body"; link_fonts'
}
link() { readlink "$1" 2>/dev/null || echo none; }

echo "== a new prefix gets every shared font"
run "$work/a" 1
fonts="$work/a/pfx/drive_c/windows/Fonts"
is "arial.ttf links to Bridgeplay's" "$support/fonts/arial.ttf" "$(link "$fonts/arial.ttf")"
is "tahoma.ttf links to the engine's" "$runner/share/wine/fonts/tahoma.ttf" "$(link "$fonts/tahoma.ttf")"

echo "== a game with its own arial gets the alternative"
run "$work/b" 1313860
is "arial.ttf links to alt" "$support/fonts/alt/arial.ttf" "$(link "$work/b/pfx/drive_c/windows/Fonts/arial.ttf")"

echo "== a link left dangling by an engine update is linked again"
ln -sf "$work/old-engine/times.ttf" "$fonts/times.ttf"
run "$work/a" 1
is "times.ttf links to Bridgeplay's again" "$support/fonts/times.ttf" "$(link "$fonts/times.ttf")"

echo "== a font installed in the prefix is kept"
rm "$fonts/arial.ttf"
echo "installed" > "$fonts/arial.ttf"
run "$work/a" 1
is "arial.ttf is still the installed file" "none installed" "$(link "$fonts/arial.ttf") $(cat "$fonts/arial.ttf")"
is "times.ttf still links" "$support/fonts/times.ttf" "$(link "$fonts/times.ttf")"

if ! command -v hdiutil >/dev/null 2>&1; then
	echo "==> fontlinkcheck: hdiutil not found, the case-sensitive volume cases skipped"
elif ! hdiutil create -quiet -size 8m -fs "Case-sensitive APFS" -volname fontlink "$work/cs.dmg" 2> "$work/hdiutil.err" \
	|| ! volume=$(hdiutil attach -nobrowse "$work/cs.dmg" 2>> "$work/hdiutil.err" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1) \
	|| [ -z "$volume" ]; then
	bad "a case-sensitive disk image mounts" "a mounted volume" "$(tr '\n' ' ' < "$work/hdiutil.err")"
else
	echo "== on a case-sensitive volume, Arial.TTF takes arial.ttf's place"
	run "$volume/c" 1
	cs="$volume/c/pfx/drive_c/windows/Fonts"
	rm "$cs/arial.ttf"
	echo "installed" > "$cs/Arial.TTF"
	run "$volume/c" 1
	is "no arial.ttf link beside Arial.TTF" none "$(link "$cs/arial.ttf")"
	is "times.ttf still links" "$support/fonts/times.ttf" "$(link "$cs/times.ttf")"

	echo "== an arial.ttf link made before Arial.TTF was installed is dropped"
	ln -sf "$support/fonts/arial.ttf" "$cs/arial.ttf"
	run "$volume/c" 1
	is "no arial.ttf link" none "$(link "$cs/arial.ttf")"
	is "Arial.TTF is kept" installed "$(cat "$cs/Arial.TTF")"

	echo "== a dangling ARIAL.TTF link doesn't keep arial.ttf out"
	run "$volume/d" 1
	dl="$volume/d/pfx/drive_c/windows/Fonts"
	ln -s "$work/gone/ARIAL.TTF" "$dl/ARIAL.TTF"
	run "$volume/d" 1
	is "arial.ttf still links" "$support/fonts/arial.ttf" "$(link "$dl/arial.ttf")"
	rm "$dl/arial.ttf"
	run "$volume/d" 1
	is "a missing arial.ttf is linked again" "$support/fonts/arial.ttf" "$(link "$dl/arial.ttf")"

	echo "== a dangling arial.ttf link beside an installed Arial.TTF is dropped"
	run "$volume/e" 1
	de="$volume/e/pfx/drive_c/windows/Fonts"
	ln -sf "$work/old-engine/arial.ttf" "$de/arial.ttf"
	echo "installed" > "$de/Arial.TTF"
	run "$volume/e" 1
	is "no arial.ttf link beside Arial.TTF" none "$(link "$de/arial.ttf")"
	is "Arial.TTF is kept" installed "$(cat "$de/Arial.TTF")"
fi

[ "$fails" -eq 0 ] || { echo "fontlinkcheck: $fails failed"; exit 1; }
echo "fontlinkcheck: all passed"
