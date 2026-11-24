#!/bin/sh
# Build the SDL controller mapping file the run script hands winebus.
#
#   scripts/update-gamecontrollerdb.sh OUTPUT [--own FILE] [--db FILE|URL]
#
# Takes the community SDL_GameControllerDB, keeps its "platform:Mac OS X" lines, appends
# the hand-written lines from FILE (default: the user's gamecontrollerdb.txt) last, keeps
# only the last line for each GUID and writes the result to OUTPUT. SDL lets a later line
# for a GUID replace an earlier one, so the own lines win. The run script points
# SDL_GAMECONTROLLERCONFIG_FILE at gamecontrollerdb.merged.txt next to gamecontrollerdb.txt.
#
# Windows and Linux lines are not converted: their button and axis indices come from
# DirectInput and evdev, which number a pad's controls differently from SDL's IOKit
# driver, so a converted GUID would carry a wrong layout.

set -eu

# A pinned commit, not master: a regenerated file changes only when this line does.
# To move it: gh api repos/mdqinc/SDL_GameControllerDB/commits/master -q .sha
db_commit=f510b74438d08d7dd55ed06673f473bd1cc28b85
db_url=https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/$db_commit/gamecontrollerdb.txt
own="$HOME/Library/Application Support/bridgeplay/gamecontrollerdb.txt"
# Before the app's 3.0.0 migration the file is still in the old support folder.
legacy_own="$HOME/Library/Application Support/notproton/gamecontrollerdb.txt"
[ -f "$own" ] || [ ! -f "$legacy_own" ] || own=$legacy_own
db="$db_url"
out=""

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--own) [ $# -ge 2 ] || usage; own="$2"; shift 2 ;;
		--db) [ $# -ge 2 ] || usage; db="$2"; shift 2 ;;
		-h|--help) usage ;;
		-*) echo "update-gamecontrollerdb: unknown option $1" >&2; usage ;;
		*) [ -z "$out" ] || usage; out="$1"; shift ;;
	esac
done
[ -n "$out" ] || usage

if [ -f "$out" ] && [ -f "$own" ] && [ "$out" -ef "$own" ]; then
	echo "update-gamecontrollerdb: OUTPUT is the own-lines file $own; the next run would treat the whole database as own lines" >&2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gamecontrollerdb.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

case "$db" in
	http://*|https://*)
		curl -fsSL --retry 2 --max-time 60 -o "$work/community.txt" "$db" ;;
	*)
		cp "$db" "$work/community.txt" ;;
esac
[ -s "$work/community.txt" ] || { echo "update-gamecontrollerdb: $db is empty" >&2; exit 1; }

tr -d '\r' < "$work/community.txt" \
	| grep -E '^[0-9a-fA-F]{32},' \
	| grep -E '(^|,)platform:Mac OS X(,|$)' > "$work/mac.txt" || true
[ -s "$work/mac.txt" ] || { echo "update-gamecontrollerdb: no Mac OS X lines in $db" >&2; exit 1; }

# Own lines: SDL's file loader skips a line without a platform field, so a Mac one is added;
# a line for another platform would never load here and is dropped.
: > "$work/own.txt"
if [ -f "$own" ]; then
	tr -d '\r' < "$own" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | awk -v src="$own" '
		!/^[0-9a-fA-F]{32},/ { printf "update-gamecontrollerdb: %s: skipped line without a GUID: %s\n", src, $0 > "/dev/stderr"; next }
		/(^|,)platform:/ {
			if ($0 ~ /(^|,)platform:Mac OS X(,|$)/) print
			else printf "update-gamecontrollerdb: %s: skipped non-Mac line: %s\n", src, $0 > "/dev/stderr"
			next
		}
		{ line = $0; sub(/,*$/, "", line); print line ",platform:Mac OS X," }
	' > "$work/own.txt"
fi

community=$(wc -l < "$work/mac.txt" | tr -d ' ')
owned=$(wc -l < "$work/own.txt" | tr -d ' ')

# GUIDs compare case-insensitively in SDL; the last line for a GUID stays, in its place.
cat "$work/mac.txt" "$work/own.txt" | awk '
	{ line[NR] = $0; g = tolower(substr($0, 1, 32)); last[g] = NR }
	END { for (i = 1; i <= NR; i++) if (last[tolower(substr(line[i], 1, 32))] == i) print line[i] }
' > "$work/merged.txt"
kept=$(wc -l < "$work/merged.txt" | tr -d ' ')

{
	echo "# SDL controller mappings for Bridgeplay, built by scripts/update-gamecontrollerdb.sh"
	echo "# on $(date -u +%Y-%m-%dT%H:%M:%SZ): $community Mac lines from $db, then $owned from $own;"
	echo "# $kept after keeping the last line per GUID. Regenerate it rather than editing it."
	cat "$work/merged.txt"
} > "$work/out.txt"

out_dir=$(dirname "$out")
mkdir -p "$out_dir"
tmp_out=$(mktemp "$out_dir/.gamecontrollerdb.XXXXXX")
cat "$work/out.txt" > "$tmp_out"
chmod 644 "$tmp_out"
mv -f "$tmp_out" "$out"
echo "update-gamecontrollerdb: wrote $out: $kept mappings ($community community Mac, $owned own, $((community + owned - kept)) replaced), $(wc -c < "$out" | tr -d ' ') bytes"
