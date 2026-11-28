#!/bin/sh
# launchprogresscheck: the panel between Play and the game's first window (launch_progress and
# launch_step in compat_run.sh). It starts beside the launch without holding it up or taking
# the prefix locks, only for a game launch, and only after the kernel anti-cheat prompt.
# shellcheck disable=SC2016 # the sh -ec programs expand their own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> launchprogresscheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in launch_progress launch_step launch_ended; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done

work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

support="$work/support"
compat="$work/steamapps/compatdata/3372060"
mkdir -p "$support" "$compat"
# The app stand-in records its arguments, whether its parent is the pid it was given, and the
# descriptors it was handed, then outlives the launch so a launch that waited on it would show.
# Like the real app, it carries the flag in its file.
app="$work/Bridgeplay.app/Contents/MacOS/BridgeplayApp"
mkdir -p "$(dirname "$app")"
cat > "$app" <<'APP'
#!/bin/sh
# knows --launch-progress
out="$(dirname "$0")/started"
printf '%s\n' "$@" > "$out.args"
[ "$5" = "$PPID" ] && echo yes > "$out.parent"
for fd in 7 8 9; do { true >&"$fd"; } 2>/dev/null && echo "$fd" >> "$out.fds"; done
mv "$out.args" "$out"
sleep 5
APP
chmod +x "$app"
started="$(dirname "$app")/started"
# An app from before the panel, which would open its main window for the flag.
old_app="$work/Old.app/Contents/MacOS/BridgeplayApp"
mkdir -p "$(dirname "$old_app")"
sed 's/^# knows --launch-progress$/# an older app/; s|/started"|/old-started"|' "$app" > "$old_app"
chmod +x "$old_app"

# run VERB NEW [APP]: one launch up to the panel, with lock-like descriptors 8 and 9 open
run() {
	rm -f "$started" "$started.fds" "$started.parent" "$compat/bridgeplay-launch-step" "$work/notes"
	if [ -n "${3:-}" ]; then printf '%s' "$3" > "$support/app-executable"; else rm -f "$support/app-executable"; fi
	# The launch lives on after starting the panel, as the run script does while the game runs.
	env verb="$1" prefix_was_new="$2" app_id=3372060 np_support="$support" log="$work/log" \
		STEAM_COMPAT_DATA_PATH="$compat" notes="$work/notes" functions="$functions" work="$work" \
		sh -ec 'eval "$functions"
notify_user() { printf "%s\n" "$1" >> "$notes"; }
exec 8>> "$notes.lock" 9>> "$notes.lock"
before=$(date +%s)
if [ "$prefix_was_new" = 1 ]; then launch_progress setup; else launch_progress prepare; fi
launch_step start
echo $(($(date +%s) - before)) > "$work/took"
sleep 1'
	took=$(cat "$work/took")
}
wait_started() { i=0; while [ ! -f "$started" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }

echo "== starting it =="
run waitforexitandrun 1 "$app"
is "the launch does not wait for the panel" yes "$([ "$took" -le 1 ] && echo yes || echo no)"
wait_started
is "the app is asked for the panel with the prefix, new prefix and Wine log" \
	"--launch-progress|$compat|1|$support/launchers/3372060/bridgeplay-wine.log" \
	"$(sed -n 1,4p "$started" 2>/dev/null | paste -sd '|' -)"
is "and with the pid of the script that started it, its parent" yes "$(cat "$started.parent" 2>/dev/null)"
is "the prefix locks are not handed to it" "" "$(cat "$started.fds" 2>/dev/null)"
is "the last step is in the step file" start "$(cat "$compat/bridgeplay-launch-step")"
is "no notice when the panel shows" "" "$(cat "$work/notes" 2>/dev/null)"
run waitforexitandrun 0 "$app"
wait_started
is "a known prefix is passed as not new" 0 "$(sed -n 3p "$started" 2>/dev/null)"
printf '1795765878625\n' > "$compat/bridgeplay-first-window"
run waitforexitandrun 0 "$app"
wait_started
is "the last launch's first-window time is removed before the panel starts" no \
	"$([ -f "$compat/bridgeplay-first-window" ] && echo yes || echo no)"

echo "== without it =="
run run 1 "$app"
sleep 0.5
is "Steam's helpers (verb run) get no panel" no "$([ -f "$started" ] && echo yes || echo no)"
is "nor a step file" no "$([ -f "$compat/bridgeplay-launch-step" ] && echo yes || echo no)"
printf '1795765878625\n' > "$compat/bridgeplay-first-window"
run run 1 "$app"
is "and they leave a running game's first-window time alone" yes \
	"$([ -f "$compat/bridgeplay-first-window" ] && echo yes || echo no)"
rm -f "$compat/bridgeplay-first-window"
run waitforexitandrun 1 ""
is "no app: a new prefix gets the first-launch notice" "Getting this game ready" "$(cat "$work/notes" 2>/dev/null)"
run waitforexitandrun 0 "$work/missing"
is "no app: a known prefix gets nothing" "" "$(cat "$work/notes" 2>/dev/null)"
run waitforexitandrun 1 "$old_app"
sleep 0.5
is "an app without the flag is not started" no "$([ -f "$work/Old.app/Contents/MacOS/old-started" ] && echo yes || echo no)"
is "and a new prefix gets the notice instead" "Getting this game ready" "$(cat "$work/notes" 2>/dev/null)"
out=$(env functions="$functions" sh -ec 'eval "$functions"; launch_step dialog; echo fine')
is "a step before the panel started writes nothing" fine "$out"

echo "== order =="
# The anti-cheat prompt and the rebuild offer come first, and Bridgeplay's alerts hide the panel.
at() { grep -n "$1" "$SRC" | head -1 | cut -d: -f1; }
notice_at=$(at '^  kernel_anticheat_notice$')
switch_at=$(at '^  offer_switch_rebuild$')
panel_at=$(at 'launch_progress setup')
if [ -n "$notice_at" ] && [ -n "$switch_at" ] && [ -n "$panel_at" ] \
	&& [ "$notice_at" -lt "$panel_at" ] && [ "$switch_at" -lt "$panel_at" ]; then
	ok "the panel starts after the anti-cheat prompt and the rebuild offer"
else
	bad "the panel starts after the anti-cheat prompt and the rebuild offer" "$notice_at, $switch_at < panel" "${panel_at:-missing}"
fi
for name in show_alert show_rebuild_failure rebuild_prefix; do
	case "$(extract "$name")" in
		*"launch_step dialog"*) ok "$name hides the panel" ;;
		*) bad "$name hides the panel" "launch_step dialog" "missing" ;;
	esac
done

echo "== after the game ended =="
# launch_ended starts the why-it-stopped panel. The stand-in records its arguments, the
# descriptors it got and, once the script's subshell is gone, its parent.
ended_app="$work/Ended.app/Contents/MacOS/BridgeplayApp"
mkdir -p "$(dirname "$ended_app")"
cat > "$ended_app" <<'APP'
#!/bin/sh
# knows --launch-ended-panel
out="$(dirname "$0")/ended"
printf '%s\n' "$@" > "$out.args"
for fd in 5 6 7 8 9; do { true >&"$fd"; } 2>/dev/null && echo "$fd" >> "$out.fds"; done
sleep 0.5
echo "$PPID" > "$out.parent"
mv "$out.args" "$out"
sleep 3
APP
chmod +x "$ended_app"
ended="$(dirname "$ended_app")/ended"
old_ended="$work/OldEnded.app/Contents/MacOS/BridgeplayApp"
mkdir -p "$(dirname "$old_ended")"
sed 's/^# knows --launch-ended-panel$/# an older app/' "$ended_app" > "$old_ended"
chmod +x "$old_ended"

# ended VERB CODE WINDOW [APP]: the end of one launch, with lock-like descriptors open
ended() {
	rm -f "$ended" "$ended.fds" "$ended.parent" "$(dirname "$old_ended")/ended" "$work/took"
	if [ -n "${4:-}" ]; then printf '%s' "$4" > "$support/app-executable"; else rm -f "$support/app-executable"; fi
	env verb="$1" code="$2" window="$3" app_id=3372060 np_support="$support" log="$work/log" \
		STEAM_COMPAT_DATA_PATH="$compat" functions="$functions" work="$work" \
		sh -ec 'eval "$functions"
exec 5>> "$work/log.lock" 6>> "$work/log.lock" 7>> "$work/log.lock" 8>> "$work/log.lock" 9>> "$work/log.lock"
before=$(date +%s)
launch_ended "$code" "$window"
echo $(($(date +%s) - before)) > "$work/took"'
	# No file: launch_ended failed under sh -e
	took=$(cat "$work/took" 2>/dev/null || echo error)
}
wait_ended() { i=0; while [ ! -f "$ended" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done; }

ended waitforexitandrun access_violation 3 "$ended_app"
is "the script does not wait for the panel" yes "$([ "$took" -le 1 ] && echo yes || echo no)"
wait_ended
is "a crash starts the panel with the prefix" "--launch-ended-panel|$compat" "$(paste -sd '|' - < "$ended" 2>/dev/null)"
is "out of the script's process tree, so Steam shows Play" 1 "$(cat "$ended.parent" 2>/dev/null)"
is "no descriptor of the launch is handed to it" "" "$(cat "$ended.fds" 2>/dev/null)"
ended waitforexitandrun stopped_from_steam "" "$ended_app"
wait_ended
is "a stop with no window ever starts it" yes "$([ -f "$ended" ] && echo yes || echo no)"
for case in "ok|" "ok|8" "launch_services|" "stopped_from_steam|8" "stopped_from_steam|-"; do
	ended waitforexitandrun "${case%|*}" "${case#*|}" "$ended_app"
	sleep 0.8
	is "no panel after ${case%|*} with window [${case#*|}]" no "$([ -f "$ended" ] && echo yes || echo no)"
done
ended run access_violation 3 "$ended_app"
sleep 0.8
is "Steam's helpers get none" no "$([ -f "$ended" ] && echo yes || echo no)"
ended waitforexitandrun access_violation 3 "$old_ended"
sleep 0.8
is "an app without the flag is not started" no "$([ -f "$(dirname "$old_ended")/ended" ] && echo yes || echo no)"
ended waitforexitandrun access_violation 3 ""
# Whole seconds: a quick call that crosses a second boundary reads 1
is "no app: nothing, and no error" yes "$([ "$took" != error ] && [ "$took" -le 1 ] && [ ! -f "$ended" ] && echo yes || echo no)"
end_record_at=$(at '^write_last_launch "${outcome')
end_panel_at=$(at '^launch_ended "${outcome')
if [ -n "$end_record_at" ] && [ -n "$end_panel_at" ] && [ $((end_panel_at - end_record_at)) -eq 1 ]; then
	ok "the panel starts right after the record it reads is written"
else
	bad "the panel starts right after the record it reads is written" "write_last_launch, then launch_ended" "$end_record_at, $end_panel_at"
fi

[ "$fails" -eq 0 ] || { echo "launchprogresscheck: $fails failed"; exit 1; }
echo "==> launchprogresscheck: the launch panel starts beside the launch"
