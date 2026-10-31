#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> settingscheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^import_prefix_settings() {$/,/^}$/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: import_prefix_settings not found in $SRC"; exit 1; }
wrapper=$(sed -n '/^without_lock_fds() {$/,/^}$/p' "$SRC")
[ -n "$wrapper" ] || { echo "FAIL: without_lock_fds not found in $SRC"; exit 1; }
helpers=""
for helper in controller_ids ids_without hidraw_lines write_owned_controllers plan_hidden_controllers \
	plan_disable_hidraw winebus_lines plan_logpixels video_lines; do
	part=$(sed -n "/^$helper() {\$/,/^}\$/p" "$SRC")
	[ -n "$part" ] || { echo "FAIL: $helper not found in $SRC"; exit 1; }
	helpers="$helpers
$part"
done
body="$wrapper
$helpers
$body"

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

cat > "$work/wine" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CALLS"
if [ "$1 $2" = "reg import" ]; then
	cp "$WINEPREFIX/drive_c/${3#C:\\}" "$FAKE_IMPORTED" 2>/dev/null || true
fi
exit "${FAKE_STATUS:-0}"
EOF
chmod +x "$work/wine"
printf '#!/bin/sh\nprintf "wineserver %%s\\n" "$*" >> "$FAKE_CALLS"\n' > "$work/wineserver"
chmod +x "$work/wineserver"

settings() {
	printf '%s\r\n' 'Windows Registry Editor Version 5.00' '' \
		'[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
		'[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
		'[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' ''
	[ -z "$1" ] || printf '%s\r\n' '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$1" ''
	[ -z "$2" ] || printf '%s\r\n' '[HKEY_CURRENT_USER\Control Panel\Desktop]' "\"LogPixels\"=dword:$2" ''
	printf '%s\r\n' '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
		'[HKEY_LOCAL_MACHINE\Software\NVIDIA Corporation\Global\NGXCore]' \
		'"FullPath"="C:\\Windows\\System32"' '' \
		'[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
		'@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' ''
}
settings '"RetinaMode"=-' > "$work/retina-off"
settings '"RetinaMode"="y"' > "$work/retina-on"
settings '' > "$work/helper"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
same_file() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "contents of ${2##*/}" "$(cat -v "$3" 2>/dev/null)"; fi; }

case_dir=""
new_case() {
	case_dir=$(mktemp -d "$work/case.XXXXXX")
	mkdir -p "$case_dir/pfx/drive_c"
	: > "$case_dir/calls"
	: > "$case_dir/log"
}
in_registry() {
	for id in "$@"; do
		printf '%s\n' "[System\\\\ControlSet001\\\\Services\\\\winebus\\\\Devices\\\\$id] 1791230000" '"Hidraw"=dword:00000000' ''
	done > "$case_dir/pfx/system.reg"
}
launch() {
	new_case
	in_registry 057e/2006 057e/2007 057e/2009
	printf '%s\n' 057e/2006 057e/2007 057e/2009 > "$case_dir/notproton-hidden-controllers"
	[ "$3" != unwritable ] || chmod 500 "$case_dir/pfx/drive_c"
	run_in "$1" "$2"
}
run_in() {
	env WINEPREFIX="$case_dir/pfx" WINELOADER="$work/wine" NOTPROTON_RETINA="$1" \
		WINESERVER="$work/wineserver" STEAM_COMPAT_DATA_PATH="$case_dir" \
		SDL_GAMECONTROLLER_IGNORE_DEVICES="${IGNORE-}" \
		SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT="${EXCEPT-}" \
		NOTPROTON_RAW_CONTROLLERS="${RAW-}" NOTPROTON_DISABLE_HIDRAW="${HIDRAW-}" verb="${VERB-waitforexitandrun}" \
		FAKE_STATUS="$2" FAKE_CALLS="$case_dir/calls" FAKE_IMPORTED="$case_dir/imported" \
		log="$case_dir/log" body="$body" \
		sh -ec 'eval "$body"; import_prefix_settings; echo returned' \
		> "$case_dir/out" 2>&1 || true
	chmod 700 "$case_dir/pfx/drive_c"
}
calls() { sed 's/notproton-settings\.[A-Za-z0-9]*$/notproton-settings.X/' "$case_dir/calls"; }
leftovers() { find "$case_dir/pfx/drive_c" -name 'notproton-settings.*' | wc -l | tr -d ' '; }

echo "== one import per launch"
launch "" 0
is "Retina unset runs a single import and nothing else" 'reg import C:\notproton-settings.X' "$(calls)"
same_file "Retina unset deletes RetinaMode" "$work/retina-off" "$case_dir/imported"
is "the file is gone after the import" 0 "$(leftovers)"
is "a clean import only logs the controller count" "controllers: 3 kept off hidraw" "$(cat "$case_dir/log")"
is "the launch carries on" returned "$(cat "$case_dir/out")"

launch 1 0
settings '"RetinaMode"="y"' 000000c0 > "$work/expected"
same_file "Retina on sets RetinaMode to y and doubles LogPixels" "$work/expected" "$case_dir/imported"

launch 0 0
same_file "Retina off deletes RetinaMode" "$work/retina-off" "$case_dir/imported"

echo "== failures"
launch "" 1
is "a failed import is logged" "=== prefix settings import exited status=1 ===" "$(cat "$case_dir/log")"
is "a failed import still removes the file" 0 "$(leftovers)"
is "a failed import does not end the launch" returned "$(cat "$case_dir/out")"

launch "" 0 unwritable
is "an unwritable C: drive falls back to wineboot, which builds the prefix" "wineboot --init" "$(calls)"
is "an unwritable C: drive is logged" "=== could not write the prefix settings, launching without them ===" "$(cat "$case_dir/log")"
is "an unwritable C: drive does not end the launch" returned "$(cat "$case_dir/out")"

echo "== controllers on Steam's ignore list"
again() { : > "$case_dir/calls"; : > "$case_dir/log"; rm -f "$case_dir/imported"; run_in "$1" "$2"; }
hidden() { printf '%s\r\n' "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$1]" '"Hidraw"=dword:00000000' ''; }
shown() { printf '%s\r\n' "[-HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$1]" ''; }
owned() { tr '\n' ' ' < "$case_dir/notproton-hidden-controllers" | sed 's/ $//'; }

new_case
IGNORE='' EXCEPT='' RAW=''
again "" 0
{ cat "$work/retina-off"; hidden 057e/2006; hidden 057e/2007; hidden 057e/2009; } > "$work/expected"
same_file "the Switch pads get Hidraw=0 with nothing on the list" "$work/expected" "$case_dir/imported"

new_case
IGNORE='0x054C/0x0CE6,0x054c/0x09cc,0x057e/0x2009,0x54c/0x5c4,junk,' EXCEPT='' RAW=''
again "" 0
{ cat "$work/retina-off"; hidden 054c/09cc; hidden 054c/0ce6; hidden 057e/2006; hidden 057e/2007; hidden 057e/2009; } > "$work/expected"
same_file "each listed controller gets Hidraw=0 in the same import" "$work/expected" "$case_dir/imported"
is "new keys restart the prefix so winebus reads them" "reg import C:\\notproton-settings.X
wineserver -k
wineserver -w" "$(calls)"
is "malformed entries are skipped and the rest are tracked" "054c/09cc 054c/0ce6 057e/2006 057e/2007 057e/2009" "$(owned)"
is "the count is logged" "controllers: 5 kept off hidraw" "$(cat "$case_dir/log")"

in_registry 054c/09cc 054c/0ce6 057e/2006 057e/2007 057e/2009
IGNORE='0x054c/0x0ce6' EXCEPT='' RAW=''
again "" 0
{ cat "$work/retina-off"; shown 054c/09cc; } > "$work/expected"
same_file "a controller that leaves the list loses the key and nothing is rewritten" "$work/expected" "$case_dir/imported"
is "the listed controller and the Nintendo pads stay tracked" "054c/0ce6 057e/2006 057e/2007 057e/2009" "$(owned)"
is "a removed key restarts the prefix too" "wineserver -w" "$(calls | tail -1)"
in_registry 054c/0ce6 057e/2006 057e/2007 057e/2009
IGNORE='0x054c/0x0ce6' EXCEPT='' RAW=''
again "" 0
is "an unchanged list does not restart the prefix" "reg import C:\\notproton-settings.X" "$(calls)"

in_registry 054c/0ce6 057e/2006 057e/2007 057e/2009
IGNORE='0x054c/0x0ce6' EXCEPT='' RAW='1'
again "" 0
{ cat "$work/retina-off"; shown 054c/0ce6; shown 057e/2006; shown 057e/2007; shown 057e/2009; } > "$work/expected"
same_file "NOTPROTON_RAW_CONTROLLERS=1 removes every key Bridgeplay wrote" "$work/expected" "$case_dir/imported"
is "NOTPROTON_RAW_CONTROLLERS=1 tracks nothing" "" "$(owned)"
is "NOTPROTON_RAW_CONTROLLERS=1 is logged" "controllers: games read them directly (BRIDGEPLAY_RAW_CONTROLLERS=1)" "$(cat "$case_dir/log")"

new_case
in_registry 28de/1304 057e/2009
IGNORE='0x28de/0x1304,0x054c/0x0ce6' EXCEPT='' RAW=''
again "" 0
{ cat "$work/retina-off"; hidden 054c/0ce6; hidden 057e/2006; hidden 057e/2007; } > "$work/expected"
same_file "a key the user wrote is left alone" "$work/expected" "$case_dir/imported"
is "a key the user wrote is not tracked" "054c/0ce6 057e/2006 057e/2007" "$(owned)"
in_registry 28de/1304 054c/0ce6 057e/2006 057e/2007 057e/2009
IGNORE='0x28de/0x1304,0x054c/0x0ce6' EXCEPT='' RAW='1'
again "" 0
{ cat "$work/retina-off"; shown 054c/0ce6; shown 057e/2006; shown 057e/2007; } > "$work/expected"
same_file "NOTPROTON_RAW_CONTROLLERS=1 keeps a key the user wrote" "$work/expected" "$case_dir/imported"

new_case
IGNORE='0x054c/0x09cc,0x054c/0x0ce6,0x057e/0x2009' EXCEPT='0x054C/0x0CE6,0x057e/0x2009' RAW=''
again "" 0
{ cat "$work/retina-off"; hidden 054c/09cc; hidden 057e/2006; hidden 057e/2007; hidden 057e/2009; } > "$work/expected"
same_file "a controller on the exception list keeps hidraw" "$work/expected" "$case_dir/imported"
is "a Nintendo pad on the exception list still gets Hidraw=0" "054c/09cc 057e/2006 057e/2007 057e/2009" "$(owned)"

IGNORE='0x054c/0x0ce6' EXCEPT='' RAW=''
launch "" 1
is "a failed import still tracks what it may have written" "054c/0ce6 057e/2006 057e/2007 057e/2009" "$(owned)"
in_registry 054c/0ce6 057e/2006 057e/2007 057e/2009
IGNORE='' EXCEPT='' RAW=''
again "" 0
{ cat "$work/retina-off"; shown 054c/0ce6; } > "$work/expected"
same_file "so the next launch can remove it once it leaves the list" "$work/expected" "$case_dir/imported"

echo "== helper launches"
new_case
in_registry 054c/0ce6 057e/2006 057e/2007 057e/2009
printf '%s\n' 054c/0ce6 057e/2006 057e/2007 057e/2009 > "$case_dir/notproton-hidden-controllers"
IGNORE='' EXCEPT='' RAW='' VERB=run
again "" 0
same_file "a helper with no list keeps the hidden controllers" "$work/helper" "$case_dir/imported"
is "a helper does not restart the prefix" "reg import C:\\notproton-settings.X" "$(calls)"
is "a helper keeps them tracked" "054c/0ce6 057e/2006 057e/2007 057e/2009" "$(owned)"
IGNORE='' EXCEPT='' RAW='1' VERB=run
again "" 0
{ cat "$work/helper"; shown 054c/0ce6; shown 057e/2006; shown 057e/2007; shown 057e/2009; } > "$work/expected"
same_file "NOTPROTON_RAW_CONTROLLERS=1 still clears them in a helper" "$work/expected" "$case_dir/imported"
in_registry 054c/0ce6 057e/2006 057e/2007 057e/2009
printf '%s\n' 054c/0ce6 057e/2006 057e/2007 057e/2009 > "$case_dir/notproton-hidden-controllers"
IGNORE='' EXCEPT='' RAW='' VERB=waitforexitandrun
again "" 0
{ cat "$work/retina-off"; shown 054c/0ce6; } > "$work/expected"
same_file "a game with no list still drops them" "$work/expected" "$case_dir/imported"
unset VERB

in_registry
rm -f "$case_dir/notproton-hidden-controllers"
ln -s /dev/null "$case_dir/notproton-hidden-controllers"
IGNORE='0x054c/0x0ce6' EXCEPT='' RAW=''
again "" 0
same_file "a linked tracking file writes no controller keys" "$work/retina-off" "$case_dir/imported"
is "a linked tracking file is logged" "=== could not track the hidden controllers, leaving them as they are ===" "$(cat "$case_dir/log")"

echo "== Disable hidraw"
winebus() { printf '%s\r\n' '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus]' "$1" ''; }
IGNORE='' EXCEPT='' RAW=''
new_case
in_registry 057e/2006 057e/2007 057e/2009
printf '%s\n' 057e/2006 057e/2007 057e/2009 > "$case_dir/notproton-hidden-controllers"
HIDRAW=1
again "" 0
{ cat "$work/retina-off"; winebus '"DisableHidraw"=dword:00000001'; } > "$work/expected"
same_file "on" "$work/expected" "$case_dir/imported"
printf '%s\n' '[System\\ControlSet001\\Services\\winebus] 1791230000' '"DisableHidraw"=dword:00000001' '' >> "$case_dir/pfx/system.reg"
HIDRAW=''
again "" 0
{ cat "$work/retina-off"; winebus '"DisableHidraw"=-'; } > "$work/expected"
same_file "off" "$work/expected" "$case_dir/imported"
unset HIDRAW

echo "== LogPixels"
user_reg() { printf '%s\n' '[Software\\Wine\\Mac Driver] 1791230000' "$1" '' '[Control Panel\\Desktop] 1791230000' "$2" '' > "$case_dir/pfx/user.reg"; }
new_case
in_registry 057e/2006 057e/2007 057e/2009
printf '%s\n' 057e/2006 057e/2007 057e/2009 > "$case_dir/notproton-hidden-controllers"
user_reg '"RetinaMode"="y"' '"LogPixels"=dword:000000c0'
again 1 0
same_file "already on" "$work/retina-on" "$case_dir/imported"
again 0 0
settings '"RetinaMode"=-' 00000060 > "$work/expected"
same_file "off halves it" "$work/expected" "$case_dir/imported"
is "off restarts the prefix" "wineserver -w" "$(calls | tail -1)"
is "off is logged" "video: LogPixels=96" "$(grep video "$case_dir/log")"
user_reg '"RetinaMode"="y"' ''
printf '%s\n' '[System\\ControlSet001\\Hardware Profiles\\Current\\Software\\Fonts] 1791230000' '"LogPixels"=dword:00000060' '' >> "$case_dir/pfx/system.reg"
again 1 0
settings '"RetinaMode"="y"' 000000c0 > "$work/expected"
same_file "on at 96 doubles it" "$work/expected" "$case_dir/imported"
user_reg '"RetinaMode"="y"' '"LogPixels"=dword:00000060'
again 0 0
same_file "off at 96 stays 96" "$work/retina-off" "$case_dir/imported"
user_reg '"RetinaMode"="y"' '"LogPixels"=dword:000000c0'
VERB=run
again "" 0
same_file "a helper leaves them alone" "$work/helper" "$case_dir/imported"
unset VERB

if [ "$fails" -eq 0 ]; then
	echo "==> settingscheck: all assertions hold"
else
	echo "==> settingscheck: $fails failed"
	exit 1
fi
