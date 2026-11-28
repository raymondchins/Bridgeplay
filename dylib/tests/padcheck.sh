#!/bin/sh
# Controller mappings: the run script's np_pad_mappings block and
# scripts/update-gamecontrollerdb.sh.
# shellcheck disable=SC2016,SC2034 # sed patterns match literal shell text; the eval'd block reads the case variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
UPDATE="${2:-$(dirname "$0")/../../scripts/update-gamecontrollerdb.sh}"
[ -f "$SRC" ] || { echo "==> padcheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^np_pad_mappings() {$/,/^}$/p' "$SRC")
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
report=$(sed -n '/^np_pad_report() {$/,/^}$/p' "$SRC")
[ -n "$block" ] || { echo "FAIL: np_pad_mappings not found in $SRC"; exit 1; }
[ -n "$forward" ] || { echo "FAIL: the launcher environment loop not found in $SRC"; exit 1; }
[ -n "$report" ] || { echo "FAIL: np_pad_report not found in $SRC"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

g1=03000000373500002210000000010000
g2=0300000037350000221000001b010000
g3=030000005e0400008e02000000000000
own1="$g1,Own Dongle,a:b0,b:b1,platform:Mac OS X,"
own2="$g2,Own Bluetooth,a:b0,b:b1,platform:Mac OS X,"
full_g1="$g1,Community Dongle,a:b1,b:b0,platform:Mac OS X,"
full_g3="$g3,Community Pad,a:b0,b:b1,platform:Mac OS X,"

# case NAME: runs the block in a subshell against $work/NAME (support dir and runner);
# leaves FILE, ENV and the log in $work/NAME.
case_dir=""
new_case() {
	case_dir="$work/$1"
	mkdir -p "$case_dir/support" "$case_dir/runner/lib"
	: > "$case_dir/log"
}
sdl_with_hint() { printf 'xx\0SDL_GAMECONTROLLERCONFIG_FILE\0yy' > "$case_dir/runner/lib/libSDL2-2.0.0.dylib"; }
sdl_without_hint() { printf 'xx\0SDL_GAMECONTROLLERCONFIG\0yy' > "$case_dir/runner/lib/libSDL2-2.0.0.dylib"; }
run_block() {
	(
		np_support="$case_dir/support"
		CX_ROOT="$case_dir/runner"
		log="$case_dir/log"
		eval "$block"
		np_pad_mappings
		printf '%s' "${SDL_GAMECONTROLLERCONFIG_FILE-<unset>}" > "$case_dir/FILE"
		printf '%s' "${SDL_GAMECONTROLLERCONFIG-<unset>}" > "$case_dir/ENV"
	)
}
got_file() { cat "$case_dir/FILE"; }
got_env() { cat "$case_dir/ENV"; }

unset SDL_GAMECONTROLLERCONFIG SDL_GAMECONTROLLERCONFIG_FILE

echo "== run script: no mapping files =="
new_case none
sdl_with_hint
run_block
is "file hint unset" "<unset>" "$(got_file)"
is "variable unset" "<unset>" "$(got_env)"

echo "== run script: own lines only =="
new_case own
sdl_with_hint
printf '# comment\n\n%s\r\n%s\n' "$own1" "$own2" > "$case_dir/support/gamecontrollerdb.txt"
run_block
is "file hint unset without the merged file" "<unset>" "$(got_file)"
is "own lines in the variable, comments and CR gone" "$own1
$own2" "$(got_env)"

echo "== run script: merged file and an SDL with the hint =="
new_case hint
sdl_with_hint
printf '%s\n' "$own1" > "$case_dir/support/gamecontrollerdb.txt"
printf '# header\n%s\n%s\n%s\n' "$full_g1" "$full_g3" "$own1" > "$case_dir/support/gamecontrollerdb.merged.txt"
run_block
is "file hint names the merged file" "$case_dir/support/gamecontrollerdb.merged.txt" "$(got_file)"
is "only own lines in the variable" "$own1" "$(got_env)"

echo "== run script: merged file and an SDL without the hint =="
new_case nohint
sdl_without_hint
printf '%s\n' "$own1" > "$case_dir/support/gamecontrollerdb.txt"
printf '# header\n%s\n%s\n' "$full_g1" "$full_g3" > "$case_dir/support/gamecontrollerdb.merged.txt"
run_block
is "file hint unset" "<unset>" "$(got_file)"
is "database in the variable, own line replaces the community one" "$full_g3
$own1" "$(got_env)"

echo "== run script: no runner SDL counts as no hint =="
new_case nosdl
printf '%s\n' "$full_g3" > "$case_dir/support/gamecontrollerdb.merged.txt"
run_block
is "file hint unset" "<unset>" "$(got_file)"
is "database in the variable" "$full_g3" "$(got_env)"

echo "== run script: the variable is capped, the last lines kept =="
new_case cap
sdl_without_hint
i=0
while [ $i -lt 600 ]; do
	printf '03000000%08x0000000000000000,Pad %d,a:b0,b:b1,x:b2,y:b3,platform:Mac OS X,\n' "$i" "$i"
	i=$((i + 1))
done > "$case_dir/support/gamecontrollerdb.merged.txt"
printf '%s\n' "$own2" > "$case_dir/support/gamecontrollerdb.txt"
run_block
size=$(got_env | wc -c | tr -d ' ')
if [ "$size" -le 32768 ] && [ "$size" -gt 30000 ]; then ok "variable holds $size bytes, at most 32768"; else bad "variable size" "30000..32768" "$size"; fi
is "own line kept last" "$own2" "$(got_env | tail -n 1)"
is "oldest community line dropped" "" "$(got_env | grep ',Pad 0,' || true)"
if grep -q 'over the 32768-byte cap dropped' "$case_dir/log"; then ok "drop logged"; else bad "drop logged" "a cap line" "$(cat "$case_dir/log")"; fi

echo "== run script: values from the launch options are kept =="
new_case user
sdl_with_hint
printf '%s\n' "$own1" > "$case_dir/support/gamecontrollerdb.txt"
printf '%s\n' "$full_g3" > "$case_dir/support/gamecontrollerdb.merged.txt"
SDL_GAMECONTROLLERCONFIG_FILE=/user/db.txt SDL_GAMECONTROLLERCONFIG="$own2" run_block
unset SDL_GAMECONTROLLERCONFIG SDL_GAMECONTROLLERCONFIG_FILE
is "user file hint kept" "/user/db.txt" "$(got_file)"
is "user variable first, own lines after" "$own2
$own1" "$(got_env)"

echo "== run script: the launcher forwards the file hint =="
(
	SDL_GAMECONTROLLERCONFIG_FILE="/a b/gamecontrollerdb.merged.txt"
	export SDL_GAMECONTROLLERCONFIG_FILE
	set --
	eval "$forward"
	for arg in "$@"; do
		case "$arg" in SDL_GAMECONTROLLERCONFIG_FILE=*) printf '%s' "${arg#*=}" ;; esac
	done
) > "$work/forwarded"
is "SDL_GAMECONTROLLERCONFIG_FILE passed as one argument" "/a b/gamecontrollerdb.merged.txt" "$(cat "$work/forwarded")"

echo "== run script: the pads attached at launch =="
# ioreg output in its text form; the stub prints the HID or the USB tree by -c.
mkdir -p "$work/ioreg"
cat > "$work/ioreg/hid" <<'IOREG'
+-o AppleUserHIDDevice  <class AppleUserHIDDevice, id 0x1, registered, matched, active, busy 0 (1 ms), retain 9>
    {
      "Product" = "Apple Internal Keyboard / Trackpad"
      "PrimaryUsagePage" = 1
      "PrimaryUsage" = 6
      "VendorID" = 1452
      "ProductID" = 834
    }
+-o AppleBluetoothHIDDevice  <class AppleBluetoothHIDDevice, id 0x2, registered, matched, active, busy 0 (1 ms), retain 9>
    {
      "Transport" = "Bluetooth"
      "Product" = "DualSense Wireless Controller"
      "PrimaryUsagePage" = 1
      "PrimaryUsage" = 5
      "VendorID" = 1356
      "ProductID" = 3302
      "SerialNumber" = "aa-bb-cc"
    }
+-o IOHIDInterface  <class IOHIDInterface, id 0x3, registered, matched, active, busy 0 (1 ms), retain 9>
    {
      "Transport" = "USB"
      "PrimaryUsagePage" = 1
      "PrimaryUsage" = 5
      "VendorID" = 1118
      "ProductID" = 654
    }
+-o IOHIDInterface  <class IOHIDInterface, id 0x4, registered, matched, active, busy 0 (1 ms), retain 9>
    {
      "Transport" = "USB"
      "PrimaryUsagePage" = 1
      "PrimaryUsage" = 4
      "VendorID" = 13623
      "ProductID" = 4130
    }
IOREG
cat > "$work/ioreg/usb" <<'IOREG'
+-o 8BitDo Receiver@01100000  <class IOUSBHostDevice, id 0x10, registered, matched, active, busy 0 (2 ms), retain 30>
  | {
  |   "idVendor" = 11720
  |   "idProduct" = 12554
  |   "UsbExclusiveOwner" = "pid 4242, steam_osx"
  |   "USB Product Name" = "8BitDo Receiver"
  | }
  |
  +-o IOUSBHostInterface@0  <class IOUSBHostInterface, id 0x11, registered, matched, active, busy 0 (1 ms), retain 7>
      {
        "bInterfaceClass" = 255
        "bInterfaceSubClass" = 93
        "bInterfaceProtocol" = 1
      }
+-o Xbox Wireless Controller@02100000  <class IOUSBHostDevice, id 0x20, registered, matched, active, busy 0 (2 ms), retain 30>
  | {
  |   "idVendor" = 1118
  |   "idProduct" = 2834
  | }
  |
  +-o IOUSBHostInterface@0  <class IOUSBHostInterface, id 0x21, registered, matched, active, busy 0 (1 ms), retain 7>
      {
        "bInterfaceClass" = 255
        "bInterfaceSubClass" = 71
        "bInterfaceProtocol" = 208
      }
+-o USB Keyboard@03100000  <class IOUSBHostDevice, id 0x30, registered, matched, active, busy 0 (2 ms), retain 30>
  | {
  |   "idVendor" = 1452
  |   "idProduct" = 1
  | }
  |
  +-o IOUSBHostInterface@0  <class IOUSBHostInterface, id 0x31, registered, matched, active, busy 0 (1 ms), retain 7>
      {
        "bInterfaceClass" = 3
        "bInterfaceSubClass" = 1
        "bInterfaceProtocol" = 1
      }
IOREG
cat > "$work/ioreg/stub" <<'STUB'
#!/bin/sh
dir=$(dirname "$0")
case "$*" in
  *IOHIDDevice*) [ -f "$dir/hid.on" ] && cat "$dir/hid" ;;
  *IOUSBHostDevice*) [ -f "$dir/usb.on" ] && cat "$dir/usb" ;;
esac
exit 0
STUB
chmod +x "$work/ioreg/stub"
run_report() {
	(
		np_support="$case_dir/support"
		np_ioreg="$work/ioreg/stub"
		eval "$report"
		np_pad_report
	)
}

new_case report-none
rm -f "$work/ioreg/hid.on" "$work/ioreg/usb.on"
is "no pads" "controllers: no gamepad attached at launch" "$(run_report)"

new_case report-pads
: > "$work/ioreg/hid.on"; : > "$work/ioreg/usb.on"
echo "$full_g3" > "$case_dir/support/gamecontrollerdb.merged.txt"
printf '# mine\r\n%s\r\n' "$own1" > "$case_dir/support/gamecontrollerdb.txt"
out=$(run_report)
is "gamepads and joysticks, then XInput; keyboards left out" \
"controllers: pad 054c:0ce6 over Bluetooth, mapping: none in Bridgeplay's files
controllers: pad 045e:028e over USB, mapping: gamecontrollerdb.merged.txt
controllers: pad 3537:1022 over USB, mapping: gamecontrollerdb.txt
controllers: pad 2dc8:310a is USB XInput, which has no HID interface on macOS; held exclusively by pid 4242, steam_osx
controllers: pad 045e:0b12 is USB XInput, which has no HID interface on macOS" "$out"
case "$out" in *aa-bb-cc*|*DualSense*|*8BitDo*) bad "no serials or names in the log" "" "$out" ;; *) ok "no serials or names in the log" ;; esac

echo "$own1" > "$case_dir/support/gamecontrollerdb.txt"
echo "${full_g3%%,*}" | tr 'a-f' 'A-F' > "$case_dir/support/gamecontrollerdb.merged.txt"
is "upper-case GUIDs match" "controllers: pad 045e:028e over USB, mapping: gamecontrollerdb.merged.txt" "$(run_report | grep 045e:028e)"

new_case report-usb-only
rm -f "$work/ioreg/hid.on"
is "only the XInput pads" "2" "$(run_report | grep -c 'USB XInput')"

if sed -n '/^np_pad_report() {$/,/^fi$/p' "$SRC" | grep -q '^if \[ "$verb" = waitforexitandrun \]; then$'; then
	ok "the report runs for the game launch only"
else
	bad "the report runs for the game launch only" "guarded by verb=waitforexitandrun" "missing"
fi

if [ -f "$UPDATE" ]; then
	echo "== update-gamecontrollerdb.sh =="
	db="$work/community.txt"
	{
		echo "# Mac OS X"
		echo "$full_g1"
		printf '%s\r\n' "$full_g3"
		echo "$g3,Windows Pad,a:b0,platform:Windows,"
		echo "$g2,Linux Pad,a:b0,platform:Linux,"
		echo "not a mapping,platform:Mac OS X,"
	} > "$db"
	own="$work/own.txt"
	{
		echo "# mine"
		echo "$own1"
		echo "$g2,Own Bluetooth,a:b0,b:b1"
		echo "$g3,Own Linux,a:b0,platform:Linux,"
	} > "$own"

	if sh "$UPDATE" > "$work/usage.out" 2>&1; then status=0; else status=$?; fi
	is "no OUTPUT prints usage and fails" "2" "$status"

	out="$work/out/merged.txt"
	sh "$UPDATE" "$out" --db "$db" --own "$own" > "$work/update.out" 2> "$work/update.err"
	is "three header comments" "3" "$(grep -c '^#' "$out")"
	is "Mac lines, own lines last, last per GUID" "$full_g3
$own1
$g2,Own Bluetooth,a:b0,b:b1,platform:Mac OS X," "$(grep -v '^#' "$out")"
	if grep -q 'skipped non-Mac line' "$work/update.err"; then ok "own non-Mac line reported"; else bad "own non-Mac line reported" "a skip line" "$(cat "$work/update.err")"; fi
	is "no CR left" "" "$(tr -d -c '\r' < "$out")"
	is "file readable by others" "-rw-r--r--" "$(stat -f %Sp "$out")"
	is "nothing else left in the output directory" "merged.txt" "$(ls -A "$work/out")"
else
	echo "==> padcheck: $UPDATE not present, the update script section is skipped"
fi

if [ "$fails" -eq 0 ]; then
	echo "==> padcheck: all assertions hold"
else
	echo "==> padcheck: $fails failed"
	exit 1
fi
