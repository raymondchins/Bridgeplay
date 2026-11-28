#!/bin/sh
# A new prefix names an older one for the same game in another Steam library, and every run
# logs the file system of the library holding the prefix. A prefix Wine did not finish stops the launch.
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> prefixnotecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^without_lock_fds() {/,/^}/p;/^volume_type() {/,/^}/p;/^note_prefix_volume() {/,/^}/p;/^steam_libraries() {/,/^}/p;/^note_other_prefixes() {/,/^}/p;/^refuse_broken_prefix() {/,/^}/p;/^missing_core_dll() (/,/^)/p' "$SRC")
case "$body" in
  *without_lock_fds*note_prefix_volume*refuse_broken_prefix*note_other_prefixes*missing_core_dll*) ;;
  *) echo "FAIL: the prefix notes were not found in $SRC"; exit 1 ;;
esac
retry=$(awk '/^  set_up_prefix_contents$/{on=1} on{print; if(/^  fi$/ && prev ~ /refuse_broken_prefix/) exit} {prev=$0}' "$SRC")
case "$retry" in
  *set_up_prefix_contents*refuse_broken_prefix*broken_rebuilt*) ;;
  *) echo "FAIL: the broken-prefix retry block was not found in $SRC"; exit 1 ;;
esac
body="$body"'
# Both take English text with {1} for $3, which these fill in as the alert would.
filled() { case "$1" in *"{1}"*) printf "%s" "${1%%"{1}"*}$2${1#*"{1}"}" ;; *) printf "%s" "$1" ;; esac; }
notify_user() { printf "%s|%s\n" "$1" "$(filled "$2" "${3:-}")" >> "$notes"; }
show_alert() { printf "%s|%s\n" "$1" "$(filled "$2" "${3:-}")" >> "$notes"; }
show_rebuild_failure() { echo "rebuild failed" >> "$notes"; }
# The player cancels unless the case sets rebuild=ok.
rebuild_prefix() { printf "%s|%s|%s\n" "$1" "$2" "$4" >> "$notes"; [ "${rebuild:-}" = ok ] || exit 1; }'

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
has "the player is told where it is" "New prefix for this game|The old one is still in $one/steamapps/compatdata/42," "$work/notes"
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
has "a new prefix on exFAT notifies" "Steam library isn't APFS|Games on exfat may freeze." "$work/notes"
run 1 ""
has "an unknown file system is logged" "volume: compatdata on unknown" "$work/log"
is "an unknown file system does not notify" "" "$(cat "$work/notes")"

echo "== a prefix Wine did not finish"
pfx="$two/steamapps/compatdata/42/pfx"
check_prefix() { # check_prefix FS [FREE_KB]: prints the exit status
	: > "$work/log"
	: > "$work/notes"
	env log="$work/log" notes="$work/notes" body="$body" fs="$1" WINEPREFIX="$pfx" rebuild="${rebuild:-}" \
		verb="${verb:-waitforexitandrun}" \
		STEAM_COMPAT_DATA_PATH="$two/steamapps/compatdata/42" \
		free="${2:-99999999}" sh -c 'eval "$body"; volume_type() { [ -z "$fs" ] || echo "$fs /Volumes/Drive"; }
			df() { printf "Filesystem 1024-blocks Used Available\n/dev/disk3 1 1 %s\n" "$free"; }
			refuse_broken_prefix; echo "rebuilt=${broken_rebuilt:-0}" >> "$log"' && echo 0 || echo $?
}
is "no dosdevices stops the launch" 1 "$(check_prefix apfs)"
has "it is logged" "Wine did not finish building it" "$work/log"
has "the player is offered a rebuild" "Prefix setup failed|The game can't start. Rebuild it now?" "$work/notes"
has "the rebuild keeps a backup" "|keep-backup" "$work/notes"
is "a rebuild lets the launch go on" 0 "$(rebuild=ok check_prefix apfs)"
has "the rebuild is reported" "rebuilt=1" "$work/log"
cat > "$work/wineserver" <<'SH'
#!/bin/sh
echo "server $1" >> "$notes"
SH
chmod +x "$work/wineserver"
( WINESERVER="$work/wineserver" rebuild=ok check_prefix apfs >/dev/null )
is "wineserver is stopped before offering a rebuild" "server -k
server -w
Prefix setup failed|The game can't start. Rebuild it now? The old prefix is backed up.|keep-backup" "$(cat "$work/notes")"
is "install helpers stop silently on a broken prefix" 1 "$(verb=run WINESERVER="$work/wineserver" rebuild=ok check_prefix apfs)"
is "install helpers skip both the rebuild and its server shutdown" "" "$(cat "$work/notes")"

retry_prefix() { # retry_prefix repair|broken: exercises the post-rebuild setup and recheck
	: > "$work/log"
	: > "$work/notes"
	: > "$work/seq"
	rm -rf "$pfx/dosdevices" "$pfx/drive_c"
	mkdir -p "$pfx"
	env log="$work/log" notes="$work/notes" seq="$work/seq" body="$body" retry="$retry" \
		WINEPREFIX="$pfx" STEAM_COMPAT_DATA_PATH="$two/steamapps/compatdata/42" outcome="$1" \
		sh -c 'eval "$body"
			volume_type() { echo "apfs /Volumes/Drive"; }
			df() {
				free=99999999
				[ "${np_rebuilt:-0}" = 0 ] || free=1024
				printf "Filesystem 1024-blocks Used Available\n/dev/disk3 1 1 %s\n" "$free"
			}
			launch_step() { echo "$1" >> "$seq"; }
			set_up_prefix_contents() { echo "setup" >> "$seq"; }
			rebuild_prefix() {
				echo "rebuild" >> "$notes"
				np_rebuilt=1
				if [ "$outcome" = repair ]; then
					mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/dosdevices"
					ln -s ../drive_c "$WINEPREFIX/dosdevices/c:"
					for name in kernel32 mspatcha ucrtbase user32 version win32u ws2_32; do
						: > "$WINEPREFIX/drive_c/windows/system32/$name.dll"
					done
				fi
			}
			eval "$retry"
			echo "rebuilt=${broken_rebuilt:-unset}" >> "$log"' && echo 0 || echo $?
}
is "a repaired prefix reruns setup and launches" 0 "$(retry_prefix repair)"
is "setup runs before and after the rebuild" "setup
prepare
setup" "$(cat "$work/seq")"
has "the recheck clears broken_rebuilt" "rebuilt=0" "$work/log"
is "a prefix still broken after rebuild stops" 1 "$(retry_prefix broken)"
is "setup still ran twice before stopping" "setup
prepare
setup" "$(cat "$work/seq")"
is "a still-broken prefix reports rebuild failure without offering again" "rebuild
rebuild failed" "$(cat "$work/notes")"
rm -rf "$pfx/dosdevices" "$pfx/drive_c"
is "a full disk stops the launch" 1 "$(check_prefix apfs 1024)"
has "a full disk is named" "Not enough disk space" "$work/notes"
is "exFAT stops the launch" 1 "$(check_prefix exfat)"
has "exFAT names the file system" "This library can't hold the prefix|exfat has no symbolic links." "$work/notes"
mkdir -p "$pfx/drive_c/windows/system32" "$pfx/dosdevices"
ln -s ../drive_c "$pfx/dosdevices/c:"
is "C: without kernel32.dll stops the launch" 1 "$(check_prefix apfs)"
: > "$pfx/drive_c/windows/system32/kernel32.dll"
# wineboot cut short by a full disk: the registry and kernel32.dll, no user32.dll (#4025)
is "a prefix with only kernel32.dll stops the launch" 1 "$(check_prefix apfs)"
has "the missing DLL is named" 'the prefix has no C:\windows\system32\mspatcha.dll' "$work/log"
for name in mspatcha ucrtbase user32 version win32u ws2_32; do
	: > "$pfx/drive_c/windows/system32/$name.dll"
done
is "a finished prefix launches" 0 "$(check_prefix apfs)"
is "a finished prefix says nothing" "rebuilt=0" "$(cat "$work/notes" "$work/log")"
mkdir "$pfx/drive_c/windows/syswow64"
for name in kernel32 mspatcha ucrtbase user32 version; do
	: > "$pfx/drive_c/windows/syswow64/$name.dll"
done
is "a 32-bit side without win32u.dll stops the launch" 1 "$(check_prefix apfs)"
has "the 32-bit DLL is named" 'the prefix has no C:\windows\syswow64\win32u.dll' "$work/log"
has "the player is told to rebuild it" "Prefix setup failed" "$work/notes"
: > "$pfx/drive_c/windows/syswow64/win32u.dll"
: > "$pfx/drive_c/windows/syswow64/ws2_32.dll"
is "a finished 32-bit side launches" 0 "$(check_prefix apfs)"
rm -rf "$pfx/dosdevices" "$pfx/drive_c"

echo "== the real mount table"
real=$(env body="$body" sh -ec 'eval "$body"; volume_type /')
case "$real" in apfs\ /*|hfs\ /*) ok "/ is read as \"$real\"" ;; *) bad "/ reads as a file system and mount point" "apfs /" "$real" ;; esac

[ "$fails" -eq 0 ] || exit 1
echo "==> prefixnotecheck: new prefixes name an older one elsewhere, file systems are logged"
