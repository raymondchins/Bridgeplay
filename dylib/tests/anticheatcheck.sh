#!/bin/sh
# anticheatcheck: the kernel anti-cheat scan of a game folder and the prompt before launch
# (kernel_anticheat_notice in compat_run.sh). Only Launch Anyway may start the game.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "anticheatcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=$(grep '^kernel_anticheat_wait=' "$SRC") || { echo "FAIL: kernel_anticheat_wait not found in $SRC"; exit 1; }
for name in kernel_anticheat_name find_kernel_anticheat kernel_anticheat_notice; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done
eval "$functions"
# shellcheck disable=SC2154 # the eval above sets it from the run script
wait_seconds=$kernel_anticheat_wait

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "*$2*" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "no $2" "$3" ;; *) ok "$1" ;; esac; }

echo "== scan =="
game() { g="$work/game $1"; mkdir -p "$g"; printf '%s' "$g"; }
put() { mkdir -p "$(dirname "$1")"; : > "$1"; }

g=$(game ricochet); put "$g/Randgrid.sys"
is "Ricochet beside the game" "Ricochet (Randgrid.sys)" "$(find_kernel_anticheat "$g")"
g=$(game upper); put "$g/a/b/RANDGRID.SYS"
is "any case, three folders down" "Ricochet (RANDGRID.SYS)" "$(find_kernel_anticheat "$g")"
g=$(game deep); put "$g/a/b/c/Randgrid.sys"
is "four folders down is not searched" "" "$(find_kernel_anticheat "$g")"
g=$(game xigncode); put "$g/bin/xhunter1.sys"
is "XIGNCODE3" "XIGNCODE3 (xhunter1.sys)" "$(find_kernel_anticheat "$g")"
g=$(game javelin); put "$g/EAAntiCheat.GameServiceLauncher.exe"
is "EA Javelin's launcher" "EA Javelin (EAAntiCheat.GameServiceLauncher.exe)" "$(find_kernel_anticheat "$g")"
g=$(game javelin2); put "$g/__Installer/EAAntiCheat.Installer.exe"
is "EA Javelin's installer" "EA Javelin (EAAntiCheat.Installer.exe)" "$(find_kernel_anticheat "$g")"
g=$(game battleye); put "$g/BattlEye/BEDaisy.sys"; put "$g/BattlEye/BEService_x64.exe"
is "BattlEye is left alone, BEDaisy.sys included" "" "$(find_kernel_anticheat "$g")"
g=$(game vanguard); put "$g/vgk.sys"
is "vgk.sys in a game folder is not Vanguard" "" "$(find_kernel_anticheat "$g")"
g=$(game eac); put "$g/EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe"; put "$g/drivers/other.sys"
is "Easy Anti-Cheat and other drivers are left alone" "" "$(find_kernel_anticheat "$g")"
g=$(game folder); mkdir -p "$g/Randgrid.sys"
is "a folder named like a driver is not one" "" "$(find_kernel_anticheat "$g")"
is "a missing game folder" "" "$(find_kernel_anticheat "$work/nowhere")"

echo "== prompt =="
ka_game=$(game prompt); put "$ka_game/Randgrid.sys"
plain=$(game plain); put "$plain/game.exe"
# prompt_case <name> <verb> <game folder> <stub|missing>: runs the notice under set -e as the
# run script does, then "launched" when it returned. The stub answers $stub_out, $stub_rc.
prompt_case() {
	case_dir="$work/case $1"
	mkdir -p "$case_dir"
	(
		set -e
		# shellcheck disable=SC2034 # kernel_anticheat_notice reads them
		verb=$2 STEAM_COMPAT_INSTALL_PATH=$3 log="$case_dir/bridgeplay-run.log"
		if [ "$4" = missing ]; then
			mkdir "$case_dir/bin"
			for tool in find tr; do ln -s "$(command -v "$tool")" "$case_dir/bin/$tool"; done
			PATH="$case_dir/bin"
		else
			# shellcheck disable=SC2329 # kernel_anticheat_notice runs this in place of the dialog
			osascript() {
				cat > "$case_dir/script"
				shift
				printf '%s\n' "$@" > "$case_dir/args"
				[ -z "$stub_err" ] || echo "$stub_err" >&2
				[ -z "$stub_out" ] || printf '%s\n' "$stub_out"
				return "$stub_rc"
			}
		fi
		kernel_anticheat_notice
		echo launched > "$case_dir/launched"
	) && rc=0 || rc=$?
	log=$(cat "$case_dir/bridgeplay-run.log" 2>/dev/null || true)
	launched=$([ -f "$case_dir/launched" ] && echo yes || echo no)
	asked=$([ -f "$case_dir/args" ] && echo yes || echo no)
}
answer() { stub_out=$1 stub_rc=${2:-0} stub_err=${3:-}; }

answer "Don't Launch"
prompt_case dont waitforexitandrun "$ka_game" stub
is "Don't Launch: exits cleanly" 0 "$rc"
is "Don't Launch: the game does not start" no "$launched"
is "the dialog names the anti-cheat and the wait" "Ricochet (Randgrid.sys)
$wait_seconds" "$(cat "$work/case dont/args")"
has "the dialog gives up by itself" 'giving up after ((item 2 of argv) as integer)' "$(cat "$work/case dont/script")"
has "giving up is told apart from a choice" 'if gave up of answer then return "gave up"' "$(cat "$work/case dont/script")"
has "Don't Launch is the default" "default button \"Don't Launch\"" "$(cat "$work/case dont/script")"
has "Don't Launch: logged" "=== not launched: kernel anti-cheat, the player chose Don't Launch ===" "$log"
has "Don't Launch: exit cause" "=== exit cause: blocked: kernel anti-cheat Ricochet (Randgrid.sys) not confirmed, the player chose Don't Launch ===" "$log"

answer "Launch Anyway"
prompt_case anyway waitforexitandrun "$ka_game" stub
is "Launch Anyway: the game starts" yes "$launched"
has "Launch Anyway: logged" "anticheat: the player chose Launch Anyway" "$log"
lacks "Launch Anyway: no exit cause" "exit cause" "$log"

answer "gave up"
prompt_case timeout waitforexitandrun "$ka_game" stub
is "no answer in time: exits cleanly" 0 "$rc"
is "no answer in time: the game does not start" no "$launched"
has "no answer in time: logged" "=== not launched: kernel anti-cheat, no answer within ${wait_seconds}s ===" "$log"
has "no answer in time: exit summary" "=== exit summary: not launched, stopped before Wine started ===" "$log"
has "no answer in time: exit cause" "=== exit cause: blocked: kernel anti-cheat Ricochet (Randgrid.sys) not confirmed, no answer within ${wait_seconds}s ===" "$log"

answer "" 1 "execution error: No user interaction allowed. (-1713)"
prompt_case error waitforexitandrun "$ka_game" stub
is "dialog error: exits cleanly" 0 "$rc"
is "dialog error: the game does not start" no "$launched"
has "dialog error: why" "=== not launched: kernel anti-cheat, the dialog could not be shown (exit 1) ===" "$log"
has "dialog error: the error is kept" "No user interaction allowed. (-1713)" "$log"
has "dialog error: exit cause" "=== exit cause: blocked: kernel anti-cheat Ricochet (Randgrid.sys) not confirmed, the dialog could not be shown (exit 1) ===" "$log"

answer "" 0
prompt_case empty waitforexitandrun "$ka_game" stub
is "no choice returned: the game does not start" no "$launched"
has "no choice returned: why" "=== not launched: kernel anti-cheat, the dialog returned no choice ===" "$log"

prompt_case missing waitforexitandrun "$ka_game" missing
is "no dialog tool: exits cleanly" 0 "$rc"
is "no dialog tool: the game does not start" no "$launched"
has "no dialog tool: why" "=== not launched: kernel anti-cheat, the dialog could not be shown (exit 127) ===" "$log"

answer "Don't Launch"
prompt_case helper run "$ka_game" stub
is "Steam's helpers (verb run) are not asked" no "$asked"
is "Steam's helpers still run" yes "$launched"
prompt_case clean waitforexitandrun "$plain" stub
is "a game without kernel anti-cheat is not asked" no "$asked"
is "a game without kernel anti-cheat starts" yes "$launched"

echo "== order =="
# The prompt comes before anything that touches the prefix or starts Wine.
notice_at=$(grep -n '^  kernel_anticheat_notice$' "$SRC" | cut -d: -f1)
prefix_at=$(grep -n '^  export WINEPREFIX=' "$SRC" | head -1 | cut -d: -f1)
lock_at=$(grep -n '^  prepare_prefix_directory$' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$notice_at" ] && [ -n "$prefix_at" ] && [ -n "$lock_at" ] \
	&& [ "$notice_at" -lt "$prefix_at" ] && [ "$notice_at" -lt "$lock_at" ]; then
	ok "the prompt runs before the prefix is set or locked"
else
	bad "the prompt runs before the prefix is set or locked" "notice < $prefix_at, $lock_at" "${notice_at:-missing}"
fi

[ "$fails" -eq 0 ] || { echo "anticheatcheck: $fails failed"; exit 1; }
echo "==> anticheatcheck: the kernel anti-cheat scan and prompt behave"
