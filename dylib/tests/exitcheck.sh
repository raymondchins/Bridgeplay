#!/bin/sh
# exitcheck: the run script's account of how a game ended (exit_summary in compat_run.sh),
# which play reports quote.
# shellcheck disable=SC2016,SC2034,SC2154 # the functions under test are eval'd, out of shellcheck's sight
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> exitcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in kernel_anticheat_name exit_anticheat exit_meaning exit_signal wine_crash_pattern exit_crash_lines \
	exit_summary exit_outcome np_now_ms np_seconds mark first_window_ms first_frame_ms launch_times \
	write_last_launch report_early_exit abandon_seed steam_facts; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done
eval "$functions"

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

clean="$work/clean.log"
printf '0118:err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems\n' > "$clean"
unset NOTPROTON_LAUNCH_SERVICES
summary() { exit_summary "$1" "$2" "$3" "${4:-$clean}"; }

echo "== how the game ended =="
is "abort() after the game's own dialog (Mewgenics)" \
	"=== exit summary: exit status 3 after 75s, the game quit by itself (likely abort() in the C runtime or a breakpoint, usually after the game's own error message) ===" \
	"$(summary 3 75 0)"
is "exit -1 (SCP: Containment Breach)" \
	"=== exit summary: exit status 255 after 19s, the game quit by itself (likely exit code -1, a failure the game reported itself) ===" \
	"$(summary 255 19 0)"
is "a quick clean quit is suspicious (Plants vs. Zombies)" \
	"=== exit summary: exit status 0 after 24s, the game quit by itself within a minute without an error code, usually after its own error message ===" \
	"$(summary 0 24 0)"
is "a long session that ends cleanly, in minutes (Roboquest)" \
	"=== exit summary: exit status 0 after 27 min, the game quit normally ===" \
	"$(summary 0 1642 0)"
is "Steam's Exit Game wins over the status" \
	"=== exit summary: exit status 143 after 6s, stopped from Steam ===" \
	"$(summary 143 6 1)"
is "SIGTERM from outside Steam" \
	"=== exit summary: exit status 143 after 30s, Wine was likely killed by SIGTERM, asked to quit from outside Steam ===" \
	"$(summary 143 30 0)"
is "a Mac-side crash is a signal, not a Windows code" \
	"=== exit summary: exit status 139 after 5s, Wine was likely killed by SIGSEGV, a crash in Mac-side code such as Wine, D3DMetal or MoltenVK ===" \
	"$(summary 139 5 0)"
is "the low byte of 0xc0000135" \
	"=== exit summary: exit status 53 after 2s, the game quit by itself (likely 0xc0000135, a DLL the game needs was not found) ===" \
	"$(summary 53 2 0)"
is "an unknown code stays raw" \
	"=== exit summary: exit status 42 after 10s, the game quit by itself ===" \
	"$(summary 42 10 0)"
is "Launch Services hides the game's status" \
	"=== exit summary: exit status 0 after 10s, started through Launch Services, so the status is open's and not the game's ===" \
	"$(export NOTPROTON_LAUNCH_SERVICES=1; summary 0 10 0)"
is "a missing Wine log adds nothing" \
	"=== exit summary: exit status 5 after 3s, the game quit by itself (likely 0xc0000005, an access violation: the game crashed) ===" \
	"$(summary 5 3 0 "$work/none.log")"

echo "== Wine's crash lines =="
crash="$work/crash.log"
{
	printf 'overlay_shim_load: pid=91135 exe=wine layer_hooks=3 overlay=present\n'
	printf '0024:err:module:import_dll Library MSVCP140.dll (which is needed by L"Z:\\\\Users\\\\someone\\\\Game.exe") not found\n'
	printf 'wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger...\n'
	printf 'overlay_shim_load: pid=91140 exe=winedbg layer_hooks=3 overlay=present\n'
	printf 'Unhandled exception: page fault on read access to 0x00000000 in 64-bit code (0x0000000140001234).\n'
	printf 'wine: Unhandled page fault again\n'
} > "$crash"
is "the first three crash lines follow the summary, then the crash handler" \
	"=== exit summary: exit status 5 after 12s, the game quit by itself (likely 0xc0000005, an access violation: the game crashed) ===
=== exit cause: 0024:err:module:import_dll Library MSVCP140.dll (which is needed by L\"Z:\\\\Users\\\\someone\\\\Game.exe\") not found ===
=== exit cause: wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger... ===
=== exit cause: Unhandled exception: page fault on read access to 0x00000000 in 64-bit code (0x0000000140001234). ===
=== exit note: Wine started its crash handler, whose error dialog can sit behind the game ===" \
	"$(summary 5 12 0 "$crash")"

echo "== kernel anti-cheat =="
cod="$work/cod.log"
{
	printf '01e0:err:module:import_dll Library ci.dll (which is needed by L"S:\\\\steamapps\\\\common\\\\Call of Duty HQ\\\\Randgrid.sys") not found\n'
	printf '01e0:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\\\Registry\\\\Machine\\\\System\\\\CurrentControlSet\\\\Services\\\\atvi-randgrid_sr": c0000142\n'
} > "$cod"
is "Ricochet's driver is named first (Call of Duty)" \
	"=== exit summary: exit status 0 after 13s, the game quit by itself within a minute without an error code, usually after its own error message ===
=== exit cause: kernel anti-cheat Ricochet (Randgrid.sys) could not load its Windows driver, which Wine cannot run, so the game will not start ===
=== exit cause: 01e0:err:module:import_dll Library ci.dll (which is needed by L\"S:\\\\steamapps\\\\common\\\\Call of Duty HQ\\\\Randgrid.sys\") not found ===" \
	"$(summary 0 13 0 "$cod")"
printf '0024:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\\\Driver\\\\winebth.sys": c00000e5\n' > "$work/winebth.log"
is "Wine's own drivers are not anti-cheat" "" "$(exit_anticheat "$work/winebth.log")"

odd="$work/odd.log"
long=$(printf '%0400d' 0)
{
	printf 'wine: could not load /Users/jos\303\251/Library/\377x.dll\r\n'
	printf 'wine: cannot find %s\n' "$long"
	printf 'wine: configuration in L"\\\\??\\\\C:\\\\users" has been updated.\n'
	# The cut falls inside the two bytes of the last character.
	printf 'wine: failed %s\303\251\n' "$(printf '%0286d' 0)"
} > "$odd"
lines=$(exit_crash_lines "$odd")
is "a home folder keeps its accents for redaction; invalid bytes and carriage returns go" \
	"wine: could not load /Users/josé/Library/x.dll" "$(printf '%s\n' "$lines" | sed -n 1p)"
is "a long line is cut" 300 "$(printf '%s\n' "$lines" | sed -n 2p | tr -d '\n' | wc -c | tr -d ' ')"
is "only crash lines are kept" 3 "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
is "what is kept is valid UTF-8" yes "$(printf '%s\n' "$lines" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo yes || echo no)"

echo "== the outcome record's code =="
outcome() { exit_outcome "$1" "$2" "$3" "${4:-$clean}"; }
is "a long clean session is ok" "ok game" "$(outcome 0 1642 0)"
is "a quick clean quit is not ok" "quit_early game" "$(outcome 0 24 0)"
is "a quick quit with a crash line crashed" "crashed game" "$(outcome 0 12 0 "$crash")"
is "a long clean exit stays ok with a crash line of some helper" "ok game" "$(outcome 0 600 0 "$crash")"
is "Steam's Stop wins over the status" "stopped_from_steam steam" "$(outcome 143 6 1)"
is "Launch Services hides the status" "launch_services unknown" "$(NOTPROTON_LAUNCH_SERVICES=1 exit_outcome 5 10 0 "$clean")"
is "a kernel anti-cheat driver names the cause" "anticheat_driver game" "$(outcome 0 13 0 "$cod")"
is "an access violation" "access_violation game" "$(outcome 5 3 0)"
is "a Mac-side crash" "sigsegv game" "$(outcome 139 5 0)"
is "killed from outside, by someone" "sigkill unknown" "$(outcome 137 900 0)"
is "a generic failure" "generic_failure game" "$(outcome 1 4 0)"
is "a generic failure with a crash line crashed" "crashed game" "$(outcome 1 4 0 "$crash")"
is "exit -1" "game_error game" "$(outcome 255 19 0)"
is "an unknown code" "exit_code game" "$(outcome 42 10 0)"
words=""
code=0
while [ "$code" -le 255 ]; do
	if [ -n "$(exit_meaning "$code")$(exit_signal "$code")" ]; then
		word=$(outcome "$code" 30 0)
		word=${word% *}
		case "$word" in
			exit_code|crashed|quit_early|ok) bad "exit $code has its own word" "a word of its own" "$word" ;;
			*[!a-z0-9_]*|'') bad "exit $code is one lower-case word" "a snake_case word" "$word" ;;
		esac
		words="$words
$word"
	fi
	code=$((code + 1))
done
is "every code the summary explains has its own word" \
	"$(printf '%s\n' "$words" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" "$(printf '%s\n' "$words" | sed '/^$/d' | wc -l | tr -d ' ')"
for word in $words ok quit_early crashed generic_failure game_error exit_code stopped_from_steam launch_services \
	anticheat_driver anticheat_blocked aborted rosetta_missing engine_missing engine_unsupported; do
	grep -q -F -- "\`$word\`" "$(dirname "$SRC")/../../docs/DEVELOPING.md" 2>/dev/null \
		|| bad "docs/DEVELOPING.md lists $word" "a row for $word" "none"
done
ok "docs/DEVELOPING.md lists every code"

echo "== step times =="
np_t0=1000000
np_seconds 1234
is "milliseconds read as seconds" 1.234 "$np_sec"
np_seconds 5
is "with the leading zeros" 0.005 "$np_sec"
np_seconds -3
is "and a clock that went back reads as zero" 0.000 "$np_sec"
# Each clock this Mac has: /bin/date has %N only on newer macOS, perl's Time::HiRes may be
# missing. The run script picks among the same, so an absent one is never used there.
ns=$(/bin/date +%s%N 2>/dev/null) || ns=""
case "$ns" in *[!0-9]*|'') ns="" ;; esac
[ "${#ns}" -ge 19 ] || ns=""
best=seconds
for np_clock in date-ns perl-hires seconds; do
	case "$np_clock" in
		date-ns) if [ -z "$ns" ]; then echo "  skip  date-ns: /bin/date has no %N here"; continue; fi ;;
		perl-hires) if ! /usr/bin/perl -MTime::HiRes -e 1 2>/dev/null; then
				echo "  skip  perl-hires: no Time::HiRes here"; continue; fi ;;
	esac
	[ "$best" != seconds ] || best=$np_clock
	np_now_ms
	case "$np_ms" in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ok "the $np_clock clock gives milliseconds" ;;
		*) bad "the $np_clock clock gives milliseconds" "13 digits" "$np_ms" ;;
	esac
done
np_clock=$best
np_now_ms
np_t0=$np_ms
log="$work/steps.log"
: > "$log"
mark "prefix seed"
is "a step is logged with its time" yes \
	"$(grep -qE '^time: prefix seed at [0-9]+\.[0-9]{3}s$' "$log" && echo yes || echo no)"
is "and is the step an abort names" "prefix seed" "$stage_step"

compat="$work/compat"
mkdir -p "$compat"
STEAM_COMPAT_DATA_PATH=$compat
printf '1795765890625\n' > "$compat/bridgeplay-first-window"
frames="$work/frames.log"
printf 'overlay_shim hook_next_drawable: layer=CAMetalLayer drawable=yes t=1795765892000\n' > "$frames"
np_t0=1795765870000
launch_times 1795765878625 1795766000000 "$frames" > "$work/times"
is "the game's times, from its start" "time: game exited at 130.000s
time: first window 12.000s after the game started
time: first frame 13.375s after the game started" "$(cat "$work/times")"
is "the first window in whole seconds" 12 "$np_window"
printf 'overlay_shim hook_next_drawable: layer=CAMetalLayer drawable=no t=1795765880000\n%s\n' \
	'overlay_shim hook_next_drawable: layer=CAMetalLayer drawable=yes t=1795765892000' > "$frames"
launch_times 1795765878625 1795766000000 "$frames" > "$work/times"
is "a first call that got no drawable is not the first frame" "time: first frame 13.375s after the game started" \
	"$(grep 'first frame' "$work/times")"
rm "$compat/bridgeplay-first-window"
launch_times 1795765878625 1795766000000 "$clean" 1 > "$work/times"
is "no window file while the panel watched, no window" "" "$np_window"
is "and the log says none was noted" "time: game exited at 130.000s
time: no first window noted" "$(cat "$work/times")"
launch_times 1795765878625 1795766000000 "$clean" > "$work/times"
is "no window file and no panel watching, not measured" "-" "$np_window"
is "and the log says so" "time: game exited at 130.000s
time: first window not measured, the launch panel was not watching" "$(cat "$work/times")"
printf 'garbage\n' > "$compat/bridgeplay-first-window"
launch_times 1795765878625 1795766000000 "$clean" 1 > /dev/null
is "a file that is not a number is no window" "" "$np_window"

echo "== the outcome record =="
backend=d3dmetal np_build=winecx-11.17 verb=waitforexitandrun
write_last_launch access_violation 5 12 game 3
ended=$(sed -n 's/^ended=//p' "$compat/bridgeplay-last-launch")
is "KEY=VALUE lines in a fixed order" "version=1
code=access_violation
exit=5
seconds=12
stopped=game
backend=d3dmetal
engine=winecx-11.17
window=3
ended=$ended" "$(cat "$compat/bridgeplay-last-launch")"
write_last_launch ok 0 900 steam -
is "not measured leaves the window key out" "no" \
	"$(grep -q '^window' "$compat/bridgeplay-last-launch" && echo yes || echo no)"
write_last_launch ok 0 900 steam ""
is "no window is an empty key" "window=" "$(grep '^window' "$compat/bridgeplay-last-launch")"
write_last_launch access_violation 5 12 game 3
is "ended is the time in seconds" yes "$(printf '%s' "$ended" | grep -qE '^[1-9][0-9]{9}$' && echo yes || echo no)"
is "nothing is left beside it" no "$([ -e "$compat/bridgeplay-last-launch.new" ] && echo yes || echo no)"

echo "== the Steam the launch ran under =="
real_home=$HOME
HOME="$work/home"
pkg="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/package"
steam_facts
is "no Steam package folder: no build or branch" "[][]" "[$steam_build][$steam_channel]"
write_last_launch ok 0 900 game 20
is "and the record names neither" no "$(grep -q '^steam_' "$compat/bridgeplay-last-launch" && echo yes || echo no)"
mkdir -p "$pkg"
printf '"bins_osx"\n{\n\t"version"\t\t"1795500000"\n}\n' > "$pkg/steam_client_osx.manifest"
: > "$pkg/steam_client_osx.installed"
touch -t 202601010000 "$pkg/steam_client_osx.installed"
: > "$pkg/steam_client_publicbeta_osx.installed"
steam_facts
is "the newest package without a manifest gives way to an older one" "[1795500000][stable]" "[$steam_build][$steam_channel]"
printf '"bins_osx"\n{\n\t"version"\t\t"1795567705"\n\t"files"\n\t{\n\t\t"version"\t"2"\n\t}\n}\n' \
	> "$pkg/steam_client_publicbeta_osx.manifest"
printf 'publicbeta\n' > "$pkg/beta"
steam_facts
is "the newest manifest's version and package/beta" "[1795567705][publicbeta]" "[$steam_build][$steam_channel]"
write_last_launch ok 0 900 game 20
is "the record carries both, before ended" "steam_build=1795567705
steam_channel=publicbeta" "$(sed -n '/^steam_/p' "$compat/bridgeplay-last-launch")"
is "and keeps ended last" ended "$(tail -n 1 "$compat/bridgeplay-last-launch" | cut -d= -f1)"
printf 'a b; rm\n' > "$pkg/beta"
steam_facts
is "an odd branch name is unknown" unknown "$steam_channel"
: > "$pkg/beta"
steam_facts
is "an empty beta file is stable" stable "$steam_channel"
printf '"bins_osx"\n{\n\t"version"\t\t"1.0 beta"\n}\n' > "$pkg/steam_client_publicbeta_osx.manifest"
printf '"bins_osx"\n{\n\t"version"\t\t"12"\n}\n' > "$pkg/steam_client_osx.manifest"
steam_facts
is "no plausible version: no build" "" "$steam_build"
HOME=$real_home
steam_build="" steam_channel=""

printf 'theirs\n' > "$work/outside"
rm "$compat/bridgeplay-last-launch"
ln -s "$work/outside" "$compat/bridgeplay-last-launch"
write_last_launch ok 0 900 game 20
is "a link at its name is replaced, never written through" "theirs" "$(cat "$work/outside")"
is "by a file" yes "$([ -f "$compat/bridgeplay-last-launch" ] && [ ! -L "$compat/bridgeplay-last-launch" ] && echo yes || echo no)"
rm "$compat/bridgeplay-last-launch"
(verb=run; write_last_launch ok 0 900 game 20)
is "a helper writes none" no "$([ -e "$compat/bridgeplay-last-launch" ] && echo yes || echo no)"

# One launch that ends before the game starts: the trap writes the record.
early() {
	rm -f "$compat/bridgeplay-last-launch"
	: > "$log"
	# A subshell, so the shell's note that a child was killed by a signal stays out of the output.
	(env functions="$functions" log="$log" verb=waitforexitandrun STEAM_COMPAT_DATA_PATH="$compat" \
		np_build=winecx-11.17 sh -c 'eval "$functions"; np_outcome=""; stage_step="prefix lock"
trap report_early_exit EXIT
'"$1") 2>/dev/null || true
}
record_line() { grep -E '^(code|exit|seconds|stopped)=' "$compat/bridgeplay-last-launch" 2>/dev/null | paste -sd ' ' -; }
early 'exit 1'
is "a failed step is aborted, with no game status" "code=aborted exit= seconds=0 stopped=unknown" "$(record_line)"
is "and the log names the step" "=== aborted during prefix lock (exit 1) before launch ===" "$(cat "$log")"
early 'np_outcome=rosetta_missing; exit 1'
is "a missing Rosetta has its code" "code=rosetta_missing exit= seconds=0 stopped=unknown" "$(record_line)"
early 'np_outcome=engine_missing; exit 1'
is "so does a missing engine" "code=engine_missing exit= seconds=0 stopped=unknown" "$(record_line)"
early 'np_outcome=anticheat_blocked; exit 0'
is "the anti-cheat prompt's Don't Launch" "code=anticheat_blocked exit= seconds=0 stopped=unknown" "$(record_line)"
is "with no abort line" "" "$(cat "$log")"
early 'kill -TERM $$; sleep 1'
is "Steam's Stop before the game started" "code=aborted exit= seconds=0 stopped=steam" "$(record_line)"
is "and the log says it stopped there" "=== stopped during prefix lock before launch ===" "$(cat "$log")"
early 'stage_step="prefix seed"; trap "abandon_seed 143" TERM; kill -TERM $$; sleep 1'
is "Steam's Stop while the prefix is seeded, whose trap exits 143" "code=aborted exit= seconds=0 stopped=steam" "$(record_line)"
is "and the log says it stopped there" "=== stopped during prefix seed before launch ===" "$(cat "$log")"

echo "== order =="
at() { grep -n -- "$1" "$SRC" | head -1 | cut -d: -f1; }
summary_at=$(at '^exit_summary "$status"')
record_at=$(at '^write_last_launch "${outcome')
clear_at=$(at '^trap - EXIT$')
start_at=$(at '^launch_step start$')
if [ -n "$summary_at" ] && [ -n "$record_at" ] && [ "$summary_at" -lt "$record_at" ]; then
	ok "the record is written after the exit summary"
else
	bad "the record is written after the exit summary" "exit_summary before write_last_launch" "$summary_at, $record_at"
fi
if [ -n "$clear_at" ] && [ -n "$start_at" ] && [ "$clear_at" -lt "$start_at" ] && [ $((start_at - clear_at)) -lt 6 ]; then
	ok "a game launch keeps the abort report until the game starts"
else
	bad "a game launch keeps the abort report until the game starts" "trap - EXIT just before launch_step start" "$clear_at, $start_at"
fi
for code in anticheat_blocked rosetta_missing engine_missing engine_unsupported; do
	if grep -q "np_outcome=$code" "$SRC"; then ok "$code is set before its exit"; else bad "$code is set before its exit" "np_outcome=$code" "none"; fi
done

if [ "$fails" -ne 0 ]; then
	echo "exitcheck: $fails failure(s)"
	exit 1
fi
echo "==> exitcheck: exit summaries read as expected"
