#!/bin/sh
# A new prefix names an older one for the same game in another Steam library, and every run
# logs the file system of the library holding the prefix. A prefix Wine did not finish stops the launch.
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> prefixnotecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^volume_type() {/,/^}/p;/^note_prefix_volume() {/,/^}/p;/^steam_libraries() {/,/^}/p;/^note_other_prefixes() {/,/^}/p;/^refuse_broken_prefix() {/,/^}/p' "$SRC")
case "$body" in
  *note_prefix_volume*refuse_broken_prefix*note_other_prefixes*) ;;
  *) echo "FAIL: the prefix notes were not found in $SRC"; exit 1 ;;
esac
body="$body"'
notify_user() { printf "%s|%s\n" "$1" "$2" >> "$notes"; }
show_alert() { printf "%s|%s\n" "$1" "$2" >> "$notes"; }'

# a failed mktemp must not leave work at the current folder, which the trap deletes
work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "$2" "$(cat "$3")"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then bad "$1" "no $2" "$(cat "$3")"; else ok "$1"; fi; }

client="$work/Steam"
one="$work/Library One"
two="$work/Library Two"
mkdir -p "$client/steamapps" "$one/steamapps/compatdata/42/pfx" "$two/steamapps/compatdata/42/pfx"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' \
	"$one" "$two" > "$client/steamapps/libraryfolders.vdf"

run() { # run NEW FS [APPID]: the game's prefix is in Library Two
	: > "$work/log"
	: > "$work/notes"
	env log="$work/log" notes="$work/notes" client_root="$client" body="$body" fs="$2" \
		STEAM_COMPAT_DATA_PATH="$two/steamapps/compatdata/42" prefix_was_new="$1" app_id="${3:-42}" \
		sh -ec 'eval "$body"; volume_type() { [ -z "$fs" ] || echo "$fs /Volumes/Drive"; }
			note_prefix_volume; note_other_prefixes'
}

echo "== libraryfolders.vdf"
is "both libraries are read" "$one
$two" "$(env client_root="$client" body="$body" sh -ec 'eval "$body"; steam_libraries')"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"/Volumes/A\\\\B"\n\t}\n}\n' > "$work/escaped.vdf"
mkdir -p "$work/escaped/steamapps"
cp "$work/escaped.vdf" "$work/escaped/steamapps/libraryfolders.vdf"
is "an escaped backslash is unescaped" '/Volumes/A\B' \
	"$(env client_root="$work/escaped" body="$body" sh -ec 'eval "$body"; steam_libraries')"
is "no libraryfolders.vdf lists nothing" "" \
	"$(env client_root="$work/none" body="$body" sh -ec 'eval "$body"; steam_libraries')"

echo "== an older prefix in another library"
: > "$one/steamapps/compatdata/42/pfx/system.reg"
run 1 apfs
has "the old prefix is logged" "an older prefix for this game is in another library: $one/steamapps/compatdata/42" "$work/log"
has "the player is told where it is" "This game starts with a new prefix|Its earlier prefix is still in $one/steamapps/compatdata/42." "$work/notes"
run 0 apfs
is "an existing prefix says nothing" "" "$(cat "$work/notes" "$work/log" | grep -v '^volume:' || true)"
run 1 apfs 7
is "another game's prefix does not count" "" "$(cat "$work/notes")"
rm "$one/steamapps/compatdata/42/pfx/system.reg"
run 1 apfs
is "an empty old prefix does not count" "" "$(cat "$work/notes")"

echo "== the game's own prefix is not another one"
: > "$two/steamapps/compatdata/42/pfx/system.reg"
ln -s "$two" "$work/Library Link"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$work/Library Link" \
	> "$client/steamapps/libraryfolders.vdf"
run 1 apfs
is "the same folder through a link is skipped" "" "$(cat "$work/notes")"
rm "$two/steamapps/compatdata/42/pfx/system.reg"

echo "== file system"
run 0 apfs
has "APFS is logged" "volume: compatdata on apfs (/Volumes/Drive)" "$work/log"
lacks "APFS is not warned about" "not APFS" "$work/log"
run 0 hfs
lacks "HFS+ is not warned about" "not APFS" "$work/log"
run 0 exfat
has "exFAT is warned about in the log" "compatdata is on exfat, not APFS" "$work/log"
is "an existing prefix on exFAT does not notify" "" "$(cat "$work/notes")"
run 1 exfat
has "a new prefix on exFAT notifies" "This Steam library is not on APFS|It is formatted exfat." "$work/notes"
run 1 ""
has "an unknown file system is logged" "volume: compatdata on unknown" "$work/log"
is "an unknown file system does not notify" "" "$(cat "$work/notes")"

echo "== a prefix Wine did not finish"
pfx="$two/steamapps/compatdata/42/pfx"
check_prefix() { # check_prefix FS [FREE_KB]: prints the exit status
	: > "$work/log"
	: > "$work/notes"
	env log="$work/log" notes="$work/notes" body="$body" fs="$1" WINEPREFIX="$pfx" \
		STEAM_COMPAT_DATA_PATH="$two/steamapps/compatdata/42" \
		free="${2:-99999999}" sh -c 'eval "$body"; volume_type() { [ -z "$fs" ] || echo "$fs /Volumes/Drive"; }
			df() { printf "Filesystem 1024-blocks Used Available\n/dev/disk3 1 1 %s\n" "$free"; }
			refuse_broken_prefix' && echo 0 || echo $?
}
is "no dosdevices stops the launch" 1 "$(check_prefix apfs)"
has "it is logged" "Wine did not finish building it" "$work/log"
has "the player is told to rebuild" "The game's prefix could not be set up|Wine did not finish building it. Rebuild the prefix" "$work/notes"
is "a full disk stops the launch" 1 "$(check_prefix apfs 1024)"
has "a full disk is named" "The disk is too full for the game's prefix" "$work/notes"
is "exFAT stops the launch" 1 "$(check_prefix exfat)"
has "exFAT names the file system" "This Steam library cannot hold the game's prefix|It is formatted exfat" "$work/notes"
mkdir -p "$pfx/drive_c/windows/system32" "$pfx/dosdevices"
ln -s ../drive_c "$pfx/dosdevices/c:"
is "C: without kernel32.dll stops the launch" 1 "$(check_prefix apfs)"
: > "$pfx/drive_c/windows/system32/kernel32.dll"
is "a finished prefix launches" 0 "$(check_prefix apfs)"
is "a finished prefix says nothing" "" "$(cat "$work/notes" "$work/log")"
rm -rf "$pfx/dosdevices" "$pfx/drive_c"

echo "== the real mount table"
real=$(env body="$body" sh -ec 'eval "$body"; volume_type /')
case "$real" in apfs\ /*|hfs\ /*) ok "/ is read as \"$real\"" ;; *) bad "/ reads as a file system and mount point" "apfs /" "$real" ;; esac

[ "$fails" -eq 0 ] || exit 1
echo "==> prefixnotecheck: new prefixes name an older one elsewhere, file systems are logged"
