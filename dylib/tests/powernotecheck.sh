#!/bin/sh
# A game started in Low Power Mode tells the player once per Low Power Mode session, beside
# the launch. An unknown power state says and clears nothing, and games starting together
# take turns.
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> powernotecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^low_power_mode() {/,/^}/p;/^low_power_notice() {/,/^}/p' "$SRC")
case "$body" in
  *low_power_mode*low_power_notice*'/usr/bin/lockf -s -t 5 7'*) ;;
  *) echo "FAIL: the Low Power Mode notice and its lock were not found in $SRC"; exit 1 ;;
esac
# lockf is macOS's. Elsewhere the lock is left out and the cases that need it do not run.
if [ -x /usr/bin/lockf ]; then
  locks=1
  body=$(printf '%s\n' "$body" | sed 's|/usr/bin/lockf -s -t 5 7|/usr/bin/lockf -s -t 1 7|')
else
  locks=0
  body=$(printf '%s\n' "$body" | sed 's|/usr/bin/lockf -s -t 5 7|true|')
fi
body="$body"'
notify_user() { printf "%s|%s\n" "$1" "$2" >> "$notes"; }
pmset() { [ "$1" = -g ] || return 1; [ -z "$during" ] || eval "$during"; [ -n "$pm" ] || return 1; printf "%s\n" "$pm"; }'

# a failed mktemp must not leave work at the current folder, which the trap deletes
work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "$2" "$(cat "$3")"; fi; }
marked() { [ -e "$mark" ] && echo yes || echo no; }

support="$work/Application Support/bridgeplay"
mkdir -p "$support"
mark="$support/low-power-noticed"
lock="$support/.low-power.lock"

# pmset -g as macOS prints it, with the power mode line given
pmset_g() {
  printf 'System-wide power settings:\nCurrently in use:\n standby              1\n%s\n displaysleep         2\n tcpkeepalive         1\n' "$1"
}

mode() { env pm="$1" body="$body" sh -ec 'eval "$body"; low_power_mode'; }

run() { # run PMSET_OUTPUT [VERB [DURING]]: one launch, waits for the notice beside it.
  # DURING runs while pmset is read.
  : > "$work/log"
  : > "$work/notes"
  env log="$work/log" notes="$work/notes" np_support="$support" pm="$1" verb="${2:-waitforexitandrun}" \
    during="${3:-}" body="$body" sh -ec 'eval "$body"; low_power_notice; wait'
}

on=$(pmset_g ' lowpowermode         1')
off=$(pmset_g ' lowpowermode         0')

echo "== reading pmset"
is "lowpowermode 1 is on" 1 "$(mode "$on")"
is "lowpowermode 0 is off" 0 "$(mode "$off")"
is "powermode 1 is on" 1 "$(mode "$(pmset_g ' powermode            1')")"
is "powermode 2 (High Power) is off" 0 "$(mode "$(pmset_g ' powermode            2')")"
is "powermode 0 (Automatic) is off" 0 "$(mode "$(pmset_g ' powermode            0')")"
is "no power mode line is unknown" "" "$(mode "$(pmset_g ' womp                 0')")"
is "pmset failing is unknown" "" "$(mode "")"
is "a lowpowermodefoo key is not read" "" "$(mode "$(pmset_g ' lowpowermodefoo      1')")"

echo "== the notice"
rm -f "$mark"
run "$on"
has "Low Power Mode on notifies" "Low Power Mode is on|Games run slower while it is on." "$work/notes"
has "it is logged" "power: Low Power Mode is on" "$work/log"
is "the session is marked" yes "$(marked)"
run "$on"
is "a second launch in the same session says nothing" "" "$(cat "$work/notes")"
has "it is still logged" "power: Low Power Mode is on" "$work/log"
run ""
is "an unknown state says nothing" "" "$(cat "$work/notes" "$work/log")"
is "an unknown state keeps the mark" yes "$(marked)"
run "$off"
is "Low Power Mode off says nothing" "" "$(cat "$work/notes" "$work/log")"
is "Low Power Mode off ends the session" no "$(marked)"
run "$on"
has "the next session notifies again" "Low Power Mode is on|" "$work/notes"

echo "== launches that are not the game"
rm -f "$mark"
run "$on" run
is "install-script helpers say nothing" "" "$(cat "$work/notes" "$work/log")"
is "they leave no mark" no "$(marked)"

echo "== where the mark cannot be written"
: > "$work/notes"
env log="$work/log" notes="$work/notes" np_support="$work/missing" pm="$on" verb=waitforexitandrun \
  body="$body" sh -ec 'eval "$body"; low_power_notice; wait'
is "no support folder says nothing rather than every launch" "" "$(cat "$work/notes")"

echo "== games starting together"
if [ "$locks" = 1 ]; then
  rm -f "$mark"
  run "$off" waitforexitandrun \
    '/usr/bin/lockf -s -t 0 "$np_support/.low-power.lock" true || echo held >> "$notes"'
  is "pmset is read under the lock" held "$(cat "$work/notes")"
  : > "$work/notes"
  env log="$work/log" notes="$work/notes" np_support="$support" pm="$on" verb=waitforexitandrun \
    body="$body" sh -ec 'eval "$body"; low_power_notice; low_power_notice; low_power_notice; wait'
  is "three at once notify once" 1 "$(grep -c 'Low Power Mode is on' "$work/notes")"
  rm -f "$mark"
  /usr/bin/lockf -s -t 0 "$lock" sleep 3 &
  holder=$!
  sleep 1
  run "$on"
  is "a launch that cannot take the lock says nothing" "" "$(cat "$work/notes")"
  is "and leaves no mark" no "$(marked)"
  wait "$holder" || true
  : > "$mark"
  /usr/bin/lockf -s -t 0 "$lock" sleep 3 &
  holder=$!
  sleep 1
  run "$off"
  is "or keeps the mark it found" yes "$(marked)"
  wait "$holder" || true
else
  echo "  not run: these need macOS's /usr/bin/lockf"
fi

echo "== the run script"
if grep -qx 'low_power_notice' "$SRC"; then ok "every launch calls it"; else bad "every launch calls it" "low_power_notice" "no call"; fi

[ "$fails" -eq 0 ] || exit 1
if [ "$locks" = 1 ]; then
  echo "==> powernotecheck: Low Power Mode is named once per session, unknown says nothing"
else
  echo "==> powernotecheck: Low Power Mode is named once per session, unknown says nothing (lock cases not run: no /usr/bin/lockf)"
fi
