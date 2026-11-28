#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> buildcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in prefix_machine last_wine_build note_other_build claim_prefix; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

np_support="$work/support"
clone() {
	inf="$np_support/runners/crossover-$1/CrossOver/share/wine/wine.inf"
	mkdir -p "$(dirname "$inf")"
	: > "$inf"
	touch -t "$2" "$inf"
}
clone 26.3.0.39832 202607151200
clone 27.0.0.40921-fex 202608211200
printf 'bridgeplay-proton\t27.0.0.40921-fex\tfex\tCrossOver Preview (FEX)\nbridgeplay-proton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n' \
	> "$np_support/tools"
mtime() { stat -f %m "$np_support/runners/crossover-$1/CrossOver/share/wine/wine.inf"; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

launch() {
	build=$1 updated=$2 record=$3
	data=$(mktemp -d "$work/compatdata.XXXXXX")
	mkdir -p "$data/pfx"
	[ -z "$updated" ] || printf '%s\r\n' "$updated" > "$data/pfx/.update-timestamp"
	[ -z "$record" ] || printf '%s' "$record" > "$data/notproton-build"
	(
		STEAM_COMPAT_DATA_PATH=$data
		np_build=$build
		np_display="display of $build"
		CX_ROOT="$np_support/runners/crossover-$build/CrossOver"
		log="$data/log"
		# shellcheck disable=SC2329 # a switch must not raise a dialog
		show_alert() { printf 'alert: %s\n' "$2"; }
		# shellcheck disable=SC2329
		rebuild_prefix() { show_alert "rebuild" "$1"; exit 1; }
		eval "$functions"
		note_other_build
		claim_prefix
	) > "$data/out" 2>&1 && status=0 || status=$?
	echo "status=$status"
	cat "$data/out"
	grep -o 'last run by build [^=]*,' "$data/log" 2>/dev/null || true
	[ ! -f "$data/notproton-build" ] || head -1 "$data/notproton-build"
}

echo "== prefixes from before the record =="
is "a fresh prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "" "")"
is "a prefix this build last updated is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 26.3.0.39832)" "")"
is "a prefix another clone updated runs and is claimed" "status=0
last run by build 27.0.0.40921-fex (CrossOver Preview (FEX)),
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921-fex)" "")"
is "a prefix no clone updated runs and is claimed" "status=0
last run by build other (another version of CrossOver),
26.3.0.39832" "$(launch 26.3.0.39832 1 "")"
is "updates the user disabled say nothing, so the prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 disable "")"

clone 27.0.0.40921 202608211200
is "a prefix either of two clones updated names neither" "status=0
last run by build other (another version of CrossOver),
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921)" "")"

echo "== prefixes with a record =="
is "the record wins over the Wine that updated the prefix" "status=0
27.0.0.40921-fex" "$(launch 27.0.0.40921-fex "$(mtime 26.3.0.39832)" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"
is "an older build takes over a newer build's prefix" "status=0
last run by build 27.0.0.40921-fex (CrossOver Preview (FEX)),
26.3.0.39832" "$(launch 26.3.0.39832 "" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"
is "a newer build takes over an older build's prefix" "status=0
last run by build 26.3.0.39832 (CrossOver 26.3),
27.0.0.40921-fex" "$(launch 27.0.0.40921-fex "" "26.3.0.39832
CrossOver 26.3
")"

# A WineCX bump moves games on Steam's default to the new build's tool: the older build's
# prefix runs as is, and a crash right after can be laid on the switch.
clone winecx-11.17 202610101200
clone winecx-11.99 202612011200
data=$(mktemp -d "$work/compatdata.XXXXXX")
mkdir -p "$data/pfx"
printf 'winecx-11.17\nWineCX 11.17\n' > "$data/notproton-build"
printf 'winecx-11.17\n' > "$data/notproton-healthy"
out=$(
	STEAM_COMPAT_DATA_PATH=$data
	np_build=winecx-11.99
	np_display="WineCX 11.99"
	wine_unix="$np_support/runners/crossover-winecx-11.99/CrossOver/lib/wine/x86_64-unix"
	CX_ROOT="$np_support/runners/crossover-winecx-11.99/CrossOver"
	log="$data/log"
	# shellcheck disable=SC2329
	show_alert() { printf 'alert: %s\n' "$2"; }
	# shellcheck disable=SC2329
	rebuild_prefix() { show_alert "rebuild" "$1"; exit 1; }
	eval "$functions"
	note_other_build
	claim_prefix
	echo "status=$?"
) 2>&1
is "a newer WineCX build runs an older WineCX build's prefix and claims it" "status=0
winecx-11.99" "$out
$(head -1 "$data/notproton-build")"
is "the switch names the WineCX build the game ran on" "winecx-11.17
WineCX 11.17" "$(sed -n 1,2p "$data/notproton-switch" 2>/dev/null)"

echo "== alerts =="
alert=$(extract show_alert)
[ -n "$alert" ] || { echo "FAIL: show_alert not found in $SRC"; exit 1; }
alert="$(extract launch_step)
$(extract alert_language)
$(extract alert_text)
$alert"
data=$(mktemp -d "$work/compatdata.XXXXXX")
(
	verb=waitforexitandrun
	# shellcheck disable=SC2329 # show_alert runs this in place of the real dialog
	osascript() {
		if /usr/bin/lockf -s -t 0 "$data/.notproton-prefix.lock" true; then
			echo free > "$data/during-alert"
		else
			echo held > "$data/during-alert"
		fi
		shift
		printf '%s\n' "$@" > "$data/alert-args"
	}
	eval "$alert"
	exec 8>> "$data/.notproton-prefix.lock"
	/usr/bin/lockf -s -t 0 8
	show_alert "title" 'a "quoted" \ message'
)
is "an open alert does not keep the prefix locked" "free" "$(cat "$data/during-alert" 2>/dev/null)"
is "alert text reaches osascript untouched, as arguments" 'title
a "quoted" \ message' "$(cat "$data/alert-args" 2>/dev/null)"

echo "== rebuild choices =="
arch_functions="$(extract alert_language)
$(extract alert_text)
$(extract alert_join)
$(extract prefix_machine)
$(extract preview_name)
$(extract running_name)
$(extract tool_name)
$(extract refuse_foreign_prefix)"
arch_data="$work/arch/pfx/drive_c/windows/system32"
mkdir -p "$arch_data"
dd if=/dev/zero bs=1 count=60 of="$arch_data/ntdll.dll" 2>/dev/null
# DOS header points at a PE header with the x86_64 machine word.
printf '\100\000\000\000PE\000\000\144\206' >> "$arch_data/ntdll.dll"
arch_case() {
	(
		WINEPREFIX="$work/arch/pfx" wine_unix="$1" log=/dev/null np_display="CrossOver 2026 10 15-ARM64 - FEX" had_display="${2:-}"
		# shellcheck disable=SC2329
		rebuild_prefix() { printf 'rebuild: %s: %s\n' "$1" "$2"; }
		eval "$arch_functions"
		refuse_foreign_prefix
	)
}
is "an architecture mismatch offers rebuilding" 'rebuild: Prefix rebuild needed: A Rosetta prefix must be rebuilt for FEX.

Rebuild for CrossOver Preview 2026 10 15‑ARM64, running through FEX? Saves are kept.' "$(arch_case aarch64-unix)"
is "the build that set up the prefix is named" 'rebuild: Prefix rebuild needed: Last used by CrossOver 26.3, running through Rosetta. A Rosetta prefix must be rebuilt for FEX.

Rebuild for CrossOver Preview 2026 10 15‑ARM64, running through FEX? Saves are kept.' "$(arch_case aarch64-unix 'CrossOver 26.3')"
is "a tool name's own arch suffix is not repeated" 'rebuild: Prefix rebuild needed: Last used by CrossOver Preview 2026 10 15‑ARM64, running through Rosetta. A Rosetta prefix must be rebuilt for FEX.

Rebuild for CrossOver Preview 2026 10 15‑ARM64, running through FEX? Saves are kept.' "$(arch_case aarch64-unix 'CrossOver 2026 10 15-ARM64 - Rosetta')"
is "a matching architecture needs no rebuild" "" "$(arch_case x86_64-unix)"
rebuild="$(extract launch_step)
$(extract alert_language)
$(extract alert_text)
$(extract run_rebuild)
$(extract rebuild_prefix)"
mkdir -p "$work/app with spaces"
cat > "$work/app with spaces/NotProtonApp" <<'SH'
#!/bin/sh
data=$2
[ -z "$DYLD_INSERT_LIBRARIES$TEST_LEAK" ] || exit 65
printf '%s\n' "$@" > "$data/arguments"
printf '%s' "$NOTPROTON_REBUILD_WINDOW" > "$data/window"
/usr/bin/lockf -s -t 0 "$data/.notproton-prefix.lock" true || exit 66
[ ! -f "$data/slow" ] || sleep 3
echo finished > "$data/finished"
exit "$(cat "$data/status")"
SH
chmod +x "$work/app with spaces/NotProtonApp"
printf '%s' "$work/app with spaces/NotProtonApp" > "$np_support/app-executable"

rebuild_case() {
	choice=$1 command_status=$2 launch_verb=$3 skip=${4:-} mode=${5:-}
	data=$(mktemp -d "$work/compat data.XXXXXX")
	(
		export TEST_LEAK=1
		printf '%s' "$command_status" > "$data/status"
		STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=selected-build np_flavor=rosetta
		np_display='Selected "tool" with \ and a newline
in its name'
		verb=$launch_verb log="$data/log"
		# shellcheck disable=SC2329
		osascript() { cat > "$data/prompt"; shift; printf '%s\n' "$@" > "$data/prompt-args"; [ "$choice" != cancel ] || return 1; printf '%s\n' "$choice"; }
		# shellcheck disable=SC2329
		show_alert() { echo "$1" >> "$data/alerts"; }
		# shellcheck disable=SC2329
		show_rebuild_failure() { echo "rebuild failed" >> "$data/alerts"; }
		# shellcheck disable=SC2329
		prepare_prefix_directory() { [ -z "${relock_fails:-}" ] || [ ! -f "$data/arguments" ] || return 1; exec 8>> "$data/.notproton-prefix.lock"; /usr/bin/lockf -s -t 0 8; echo locked >> "$data/checks"; }
		# shellcheck disable=SC2329
		note_other_build() { echo build >> "$data/checks"; }
		# shellcheck disable=SC2329
		refuse_foreign_prefix() { echo arch >> "$data/checks"; }
		eval "$rebuild"
		prepare_prefix_directory
		: > "$data/checks"
		echo stale > "$data/notproton-switch"
		if [ -n "$mode" ]; then
			rebuild_prefix 'A title' 'Previous "tool" with \ and a newline
in its name' "$skip" "$mode"
		else
			rebuild_prefix 'A title' 'Previous "tool" with \ and a newline
in its name' ${skip:+"$skip"}
		fi
		[ -z "${second_rebuild:-}" ] || rebuild_prefix 'A title' 'Still broken' "$skip" "$mode"
		echo launched >> "$data/checks"
	) && status=0 || status=$?
}
rebuild_case 'Backup & Rebuild Prefix' 0 waitforexitandrun
is "backup rebuild succeeds with lock released for the app" 0 "$status"
is "selected tool and backup choice reach the app as arguments" "--rebuild-prefix
$data
chosen
selected-build
rosetta
keep-backup" "$(cat "$data/arguments")"
is "launch retakes its lock and rechecks both mismatches" "locked
build
arch
launched" "$(cat "$data/checks")"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "rebuild without backup succeeds" 0 "$status"
is "rebuild without backup passes discard-backup" discard-backup "$(tail -1 "$data/arguments")"
rebuild_case cancel 0 waitforexitandrun
is "cancel stops the launch" 1 "$status"
is "cancel never calls the app" no "$([ -f "$data/arguments" ] && echo yes || echo no)"
rebuild_case 'Rebuild Prefix' 7 waitforexitandrun
is "a failed rebuild stops the launch" 1 "$status"
is "a failed rebuild never continues launch preparation" "" "$(cat "$data/checks")"
is "a failed rebuild says so" "rebuild failed" "$(cat "$data/alerts")"
rebuild_case 'Rebuild Prefix' 0 run
is "install helpers refuse silently" 1 "$status"
is "install helpers never prompt" no "$([ -f "$data/prompt" ] && echo yes || echo no)"
rebuild_case cancel 0 waitforexitandrun 'Launch Anyway'
is "skipping an offered rebuild goes on with the launch" 0 "$status"
is "a skipped rebuild retakes the lock and launches" "locked
launched" "$(cat "$data/checks")"
is "a skipped rebuild never calls the app" no "$([ -f "$data/arguments" ] && echo yes || echo no)"
is "the skip button is labelled as asked" "Launch Anyway" "$(tail -5 "$data/prompt-args" | head -1)"
is "a missing Bridgeplay icon falls back to caution" "" "$(tail -4 "$data/prompt-args" | head -1)"
is "an offered rebuild keeps the backup choice" "" "$(tail -3 "$data/prompt-args" | head -1)"
is "the rebuild buttons are labelled in the player's language" "Rebuild Prefix
Backup & Rebuild Prefix" "$(tail -2 "$data/prompt-args")"
is "a translated button answers in English" yes "$(grep -q -F 'if button returned of answer is backupLabel then return "Backup & Rebuild Prefix"' "$data/prompt" && echo yes || echo no)"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun '' keep-backup
is "single-choice rebuild succeeds" 0 "$status"
is "single-choice rebuild passes keep-backup to the prompt" keep-backup "$(tail -3 "$data/prompt-args" | head -1)"
is "single-choice rebuild keeps the original prefix" keep-backup "$(tail -1 "$data/arguments")"
second_rebuild=1
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun '' keep-backup
second_rebuild=
is "a second rebuild in one launch stops" 1 "$status"
is "a second rebuild reports rebuild failure" "rebuild failed" "$(cat "$data/alerts")"
rebuild_case 'Rebuild Prefix' 0 run 'Launch Anyway'
is "install helpers skip an offered rebuild silently" 0 "$status"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "the app gets none of Steam's environment" 0 "$status"
is "a rebuild from Play asks the app for its progress window" 1 "$(cat "$data/window")"
is "a finished rebuild clears the switch record" no "$([ -f "$data/notproton-switch" ] && echo yes || echo no)"
relock_fails=1
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
relock_fails=
is "a launch that cannot retake its lock after a rebuild stops" 1 "$status"
is "and says another launch has the prefix" "Prefix rebuilt" "$(cat "$data/alerts")"
printf '%s' "$work/missing" > "$np_support/app-executable"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "a moved or missing app stops the launch" 1 "$status"
is "a missing app explains how to repair" "Couldn't find the Bridgeplay app" "$(cat "$data/alerts")"

data=$(mktemp -d "$work/stopped.XXXXXX")
printf 0 > "$data/status"
: > "$data/slow"
(
	STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=b np_flavor=rosetta log="$data/log"
	eval "$rebuild"
	TMPDIR="$work" run_rebuild "$work/app with spaces/NotProtonApp" keep-backup
) &
waiter=$!
sleep 1
pkill -KILL -P "$waiter" 2>/dev/null || true
kill -KILL "$waiter" 2>/dev/null || true
sleep 4
is "Stop kills the launch but not the rebuild under it" finished "$(cat "$data/finished" 2>/dev/null)"

data=$(mktemp -d "$work/concurrent.XXXXXX")
cat > "$work/concurrent-app" <<'SH'
#!/bin/sh
case "$6" in
	keep-backup)
		: > "$2/first-started"
		for attempt in 1 2 3 4 5 6 7 8 9 10; do
			[ ! -f "$2/second-returned" ] || exit 0
			sleep 1
		done
		exit 2
		;;
	*) exit 1 ;;
esac
SH
chmod +x "$work/concurrent-app"
(
	STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=b np_flavor=rosetta log="$data/log"
	eval "$rebuild"
	run_rebuild "$work/concurrent-app" keep-backup
) &
first_waiter=$!
for attempt in 1 2 3 4 5; do
	[ ! -f "$data/first-started" ] || break
	sleep 1
done
is "the first rebuild app started" yes "$([ -f "$data/first-started" ] && echo yes || echo no)"
(
	STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=b np_flavor=rosetta log="$data/log"
	eval "$rebuild"
	run_rebuild "$work/concurrent-app" discard-backup
) && status=0 || status=$?
: > "$data/second-returned"
is "a competing rebuild returns its own failure" 1 "$status"
wait "$first_waiter" && status=0 || status=$?
is "the first rebuild returns its own success" 0 "$status"

echo "== crashes after a switch =="
health_functions="$(extract prefix_machine)
$(extract note_other_build)
$(extract preview_name)
$(extract running_name)
$(extract tool_name)
$(extract last_wine_build)
$(extract wine_crash_pattern)
$(extract crash_status)
$(extract session_health)
$(extract set_switch_state)
$(extract record_session)
$(extract offer_switch_rebuild)
$(extract alert_language)
$(extract alert_text)"
crash_log="$work/crash.log"
printf 'wine: Unhandled page fault on execute access to 0000000001A23DA0\n' > "$crash_log"
clean_log="$work/clean.log"
printf 'fixme:ntdll:stub\n' > "$clean_log"
health() {
	(
		log=/dev/null
		eval "$health_functions"
		session_health "$@"
	)
}
is "a crash in the first minute is a failure" "failed, a crash within the first minute" "$(health "$crash_log" 5 0 5)"
is "a crash after a minute says nothing" "unknown, a crash after the first minute" "$(health "$crash_log" 300 0 0)"
is "a crash Steam stopped says nothing" "unknown, stopped from Steam after a crash" "$(health "$crash_log" 5 1 143)"
is "a minute without a crash is healthy" healthy "$(health "$clean_log" 75 0 0)"
is "so is a long one with the game's own exit code" healthy "$(health "$clean_log" 900 0 1)"
is "a quick clean quit says nothing (exit 0 within a minute)" "unknown, quit within a minute" "$(health "$clean_log" 24 0 0)"
is "nor does a quick generic failure" "unknown, quit within a minute" "$(health "$clean_log" 4 0 1)"
is "a crash code is a crash without a crash line" "failed, a crash within the first minute" "$(health "$clean_log" 12 0 5)"
is "so is a Mac-side crash" "failed, a crash within the first minute" "$(health "$clean_log" 12 0 139)"
is "and a crash code after a minute says nothing" "unknown, a crash after the first minute" "$(health "$clean_log" 300 0 5)"
is "through Launch Services the status is open's" "unknown, quit within a minute" "$(NOTPROTON_LAUNCH_SERVICES=1; export NOTPROTON_LAUNCH_SERVICES; health "$clean_log" 12 0 5)"
illegal_log="$work/illegal.log"
printf 'wine: Unhandled illegal instruction at address 00006FFFFFC3A2B1 (thread 0024), starting debugger...\n' > "$illegal_log"
is "an illegal instruction is a crash" "failed, a crash within the first minute" "$(health "$illegal_log" 8 0 0)"
is "a long session Steam stopped is healthy" healthy "$(health "$clean_log" 600 1 143)"
is "a short session Steam stopped says nothing" "unknown, stopped from Steam within a minute" "$(health "$clean_log" 5 1 143)"
is "a missing log is healthy after a minute" healthy "$(health "$work/none.log" 90 0 0)"
is "and says nothing before" "unknown, quit within a minute" "$(health "$work/none.log" 5 0 0)"
quick=$(mktemp -d "$work/quick.XXXXXX")
(
	STEAM_COMPAT_DATA_PATH=$quick np_build=new-build log="$quick/run.log"
	eval "$health_functions"
	record_session "$clean_log" 24 0 0
)
is "a quick clean quit is logged with its reason" "=== session health: unknown after 24s, quit within a minute ===" "$(cat "$quick/run.log")"
is "and does not mark the build healthy" no "$([ -f "$quick/notproton-healthy" ] && echo yes || echo no)"

# Each step is one launch: switch to a build, then a session that ends healthy or failed.
switch_world() {
	data=$(mktemp -d "$work/switch.XXXXXX")
	[ -z "$1" ] || printf '%s\n' "$1" > "$data/notproton-healthy"
	printf 'old-build\nOld Tool\n' > "$data/notproton-build"
}
session() {
	(
		STEAM_COMPAT_DATA_PATH=$data np_build=$1 np_display="New Tool" log=/dev/null verb=waitforexitandrun
		# shellcheck disable=SC2329
		rebuild_prefix() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$data/offers"; }
		eval "$health_functions"
		note_other_build
		printf '%s\nNew Tool\n' "$1" > "$data/notproton-build"
		offer_switch_rebuild
		record_session "$2" "$3" 0 0
	)
}
state() { sed -n 3p "$data/notproton-switch" 2>/dev/null || echo none; }

switch_world old-build
session new-build "$clean_log" 90
is "a switch from a build that worked is tracked" 1 "$(state)"
session new-build "$clean_log" 90
is "two healthy sessions clear the record" none "$([ -f "$data/notproton-switch" ] && state || echo none)"
is "the healthy build is remembered" new-build "$(cat "$data/notproton-healthy")"

switch_world old-build
session new-build "$crash_log" 5
is "a crash after the switch is recorded" failed "$(state)"
is "nothing is offered in the session that crashed" no "$([ -f "$data/offers" ] && echo yes || echo no)"
session new-build "$crash_log" 5
is "the next launch offers a rebuild for the selected tool" "Prefix rebuild may help|The last launch failed.

Rebuild for New Tool, running through Rosetta? Saves are kept.|Launch Anyway" "$(cat "$data/offers")"
is "the offer is made once per switch" none "$([ -f "$data/notproton-switch" ] && state || echo none)"
session new-build "$crash_log" 5
is "a crash after the offer is not offered again" 1 "$(grep -c "^Prefix rebuild may help" "$data/offers")"

switch_world ""
session new-build "$crash_log" 5
is "a game never seen working is not blamed on the switch" none "$([ -f "$data/notproton-switch" ] && state || echo none)"
switch_world other-build
session new-build "$crash_log" 5
is "a game seen working on another build is not blamed on this switch" none "$([ -f "$data/notproton-switch" ] && state || echo none)"

if [ "$fails" -eq 0 ]; then
	echo "==> buildcheck: all assertions hold"
else
	echo "==> buildcheck: $fails failed"
	exit 1
fi
