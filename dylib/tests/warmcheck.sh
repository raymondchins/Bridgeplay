#!/bin/sh
# One Wine boot per Play and the launch stamps. Runs the run script's own prefix block, settings
# import, fonts and helper route, as Steam does for a Play (the install-script helper, then the
# game), with a fake Wine whose server counts the boots of Wine's system processes.
#   warmcheck.sh [script]                     the checks
#   warmcheck.sh script --bench old-script    boots and step times per Play, old against new
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> warmcheck: $SRC not present, skipped"; exit 0; }
BENCH=""
if [ "${2:-}" = --bench ]; then
	BENCH="${3:-}"
	[ -f "$BENCH" ] || { echo "FAIL: --bench needs the old script"; exit 1; }
fi
command -v perl >/dev/null 2>&1 || { echo "FAIL: warmcheck needs perl for the fake server's socket"; exit 1; }

# The pieces of a launch this check runs as they are. The old script has no launch stamps.
program() {
	p=""
	for name in without_lock_fds np_now_ms np_seconds mark resolve_msync set_up_prefix_contents \
		import_prefix_settings controller_ids ids_without hidraw_lines write_owned_controllers \
		plan_hidden_controllers plan_disable_hidraw winebus_lines plan_logpixels video_lines \
		link_fonts fonts_inputs; do
		part=$(sed -n "/^$name() {\$/,/^}\$/p" "$1")
		if [ -z "$part" ]; then
			[ "$name" = fonts_inputs ] && [ -n "$BENCH" ] && continue
			echo "FAIL: $name not found in $1" >&2
			return 1
		fi
		p="$p
$part"
	done
	d4=$(sed -n '/^# Launch stamps\. A step whose inputs/,/^if \[ -n "\$STEAM_COMPAT_DATA_PATH" \]; then$/p' "$1" | sed '$d')
	if [ -z "$d4" ] && [ -z "$BENCH" ]; then echo "FAIL: the launch stamps block not found in $1" >&2; return 1; fi
	prefix=$(awk '/^if \[ -n "\$STEAM_COMPAT_DATA_PATH" \]; then$/ { getline next_line
		if (next_line ~ /anti-cheat check/) { on = 1; print; print next_line; next } }
		on { print } on && /^fi$/ { exit }' "$1")
	case "$prefix" in *set_up_prefix_contents*) ;; *) echo "FAIL: the prefix block not found in $1" >&2; return 1 ;; esac
	route=$(sed -n '/^target="\$1"$/,/^fi$/p' "$1")
	[ -n "$route" ] || { echo "FAIL: the helper route not found in $1" >&2; return 1; }
	printf '%s\n' "$p" '
kernel_anticheat_notice() { :; }
prepare_prefix_directory() { mkdir -p "$WINEPREFIX/drive_c"; }
note_other_build() { :; }
refuse_foreign_prefix() { :; }
claim_prefix() { :; }
find_client_root() { :; }
note_prefix_volume() { :; }
note_other_prefixes() { :; }
offer_switch_rebuild() { :; }
launch_progress() { :; }
launch_step() { :; }
seed_prefix_from_template() { [ -f "$WINEPREFIX/system.reg" ] || echo "WINE REGISTRY Version 2" > "$WINEPREFIX/system.reg"; }
lay_out_proton_profile() { :; }
map_game_drive() { :; }
refuse_broken_prefix() { :; }
gamefix_log() { echo "gamefix: $*" >> "$log"; }
# A prefix whose controllers are as Bridgeplay left them, unless FAKE_PAD names a new one.
plan_hidden_controllers() { controllers_add=${FAKE_PAD:-}; controllers_remove=""; controllers_wanted=""; }
plan_disable_hidraw() { hidraw_value=""; }
write_owned_controllers() { :; }
np_now_ms
np_t0=$np_ms' "$d4" '
warm_server_dir() { printf "%s" "$FAKE_SERVER"; }' "$prefix" '
if [ "$verb" = waitforexitandrun ]; then
  mark "game start"
  "$WINELOADER" game.exe >> "$log" 2>&1
  "$WINESERVER" -k >> "$log" 2>&1 || true
  printf "version=1\ncode=%s\n" "${FAKE_CODE:-ok}" > "$STEAM_COMPAT_DATA_PATH/bridgeplay-last-launch"
  exit 0
fi
shim_exe="C:\\Program Files (x86)\\Steam\\steam.exe"' "$route"
}

work=$(mktemp -d) || exit 1
[ -n "$work" ] && [ -d "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT

engine="$work/engine"
mkdir -p "$engine/bin" "$engine/lib/wine/x86_64-unix" "$engine/share/wine/fonts" "$work/support/fonts" "$work/home"
for n in $(seq 1 60); do : > "$engine/share/wine/fonts/font$n.ttf"; done
: > "$engine/.notproton-msync"

# A client: the first one in a session boots Wine's system processes, with its environment.
cat > "$engine/bin/wine" <<'EOF'
#!/bin/sh
[ -S "$FAKE_SERVER/socket" ] || "$WINESERVER" --by-client
if [ ! -f "$FAKE_SERVER/booted" ]; then
	printf 'boot by %s: SDL_PLAYTEST=%s SDL_HELPERTEST=%s\n' "$1" "${SDL_PLAYTEST-unset}" "${SDL_HELPERTEST-unset}" >> "$FAKE_EVENTS"
	: > "$FAKE_SERVER/booted"
	[ "${FAKE_BOOT_SECONDS:-0}" = 0 ] || sleep "$FAKE_BOOT_SECONDS"
fi
printf 'client %s: SDL_PLAYTEST=%s\n' "$1" "${SDL_PLAYTEST-unset}" >> "$FAKE_EVENTS"
case "$1" in *steam.exe) exit "${FAKE_HELPER_STATUS:-0}" ;; esac
exit 0
EOF
# The server: -p starts one unless one is up (status 2), -k ends it.
cat > "$engine/bin/wineserver" <<'EOF'
#!/bin/sh
case "$1" in
	-k) [ ! -d "$FAKE_SERVER" ] || { rm -rf "$FAKE_SERVER"; echo "server killed" >> "$FAKE_EVENTS"; } ;;
	-w) ;;
	-p*|--by-client)
		if [ -S "$FAKE_SERVER/socket" ]; then [ "$1" = --by-client ] && exit 0; exit 2; fi
		mkdir -p "$FAKE_SERVER"
		perl -e 'use Socket; socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die; bind($s, pack_sockaddr_un($ARGV[0])) or die' "$FAKE_SERVER/socket"
		echo "server started $1 WINEMSYNC=${WINEMSYNC:-}" >> "$FAKE_EVENTS" ;;
esac
EOF
chmod +x "$engine/bin/wine" "$engine/bin/wineserver"
: > "$engine/lib/wine/x86_64-unix/ntdll.so"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
logged() { if grep -qF -- "$2" "$case_dir/$3.log"; then ok "$1"; else bad "$1" "a line with $2" "$(cat "$case_dir/$3.log")"; fi; }
unlogged() { if grep -qF -- "$2" "$case_dir/$3.log"; then bad "$1" "no line with $2" "$(grep -F -- "$2" "$case_dir/$3.log")"; else ok "$1"; fi; }
boots() { grep -c '^boot by' "$case_dir/events" || true; }

case_dir=""
new_case() {
	case_dir=$(mktemp -d "$work/case.XXXXXX")
	mkdir -p "$case_dir/compat"
	: > "$case_dir/events"
}
# run <script> <verb> <log name> [NAME=value...]: one run of the script, as Steam starts it.
run() {
	script=$1 verb=$2 name=$3
	shift 3
	body=$(program "$script") || exit 1
	env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$work/home" LANG=en_US.UTF-8 \
		verb="$verb" log="$case_dir/$name.log" body="$body" np_clock=date-ns \
		STEAM_COMPAT_DATA_PATH="$case_dir/compat" CX_ROOT="$engine" wine_unix="$engine/lib/wine/x86_64-unix" \
		WINELOADER="$engine/bin/wine" WINESERVER="$engine/bin/wineserver" np_build=test-1 \
		np_support="$work/support" app_id=4000 ROSETTA_ADVERTISE_AVX=1 avx_from=default \
		FAKE_SERVER="$case_dir/server" FAKE_EVENTS="$case_dir/events" SDL_PLAYTEST=same "$@" \
		sh -ec 'eval "$body"' "$script" helper.exe >> "$case_dir/$name.log" 2>&1 || echo "exit $?" >> "$case_dir/$name.log"
}
play() { # play <tag> [NAME=value...] for both; HELPER_ and GAME_ prefixed ones for one side
	tag=$1
	shift
	helper_env="" game_env=""
	for kv in "$@"; do
		case "$kv" in
			HELPER_*) helper_env="$helper_env ${kv#HELPER_}" ;;
			GAME_*) game_env="$game_env ${kv#GAME_}" ;;
			*) helper_env="$helper_env $kv"; game_env="$game_env $kv" ;;
		esac
	done
	# shellcheck disable=SC2086 # the lists hold NAME=value words without spaces
	run "$SRC" run "$tag-helper" $helper_env
	[ -z "${between:-}" ] || eval "$between"
	# shellcheck disable=SC2086
	run "$SRC" waitforexitandrun "$tag-game" $game_env
}

if [ -n "$BENCH" ]; then
	for side in old new; do
		script=$SRC
		[ "$side" = new ] || script=$BENCH
		new_case
		for n in 1 2 3; do
			: > "$case_dir/events"
			run "$script" run "p$n-helper" FAKE_BOOT_SECONDS=1
			run "$script" waitforexitandrun "p$n-game" FAKE_BOOT_SECONDS=1
			game_start=$(sed -n 's/^time: game start at \(.*\)s$/\1/p' "$case_dir/p$n-game.log")
			helper_end=$(grep '^time: ' "$case_dir/p$n-helper.log" | tail -1 | sed 's/^time: \(.*\) at \(.*\)s$/\1 \2/')
			printf '%s play %s: %s boots, helper last step "%ss", game start at %ss\n' \
				"$side" "$n" "$(boots)" "$helper_end" "$game_start"
		done
		echo "$side game steps, play 3:"
		grep '^time: ' "$case_dir/p3-game.log" | sed 's/^/    /'
	done
	exit 0
fi

echo "== a Play whose helper and game share an environment boots Wine once"
new_case
play p1
is "one boot" 1 "$(boots)"
logged "the helper starts the server for the session" "warm start: Wine server started" p1-helper
logged "the helper leaves it" "warm start: Wine session left up for the game" p1-helper
logged "the game reuses it" "warm start: reusing the Wine session the helper left" p1-game
is "the game ran in that session" "client game.exe: SDL_PLAYTEST=same" "$(grep '^client game' "$case_dir/events")"
is "the note is used once" no "$([ -e "$case_dir/compat/bridgeplay-warm-server" ] && echo yes || echo no)"
is "the game ends the session" no "$([ -e "$case_dir/server" ] && echo yes || echo no)"
play p2
is "every Play boots once" 2 "$(boots)"

echo "== the helper boots Wine's system processes with the game's environment"
new_case
play p1 HELPER_SDL_PLAYTEST=helper HELPER_SDL_HELPERTEST=1 GAME_SDL_PLAYTEST=game
is "a first Play with another environment boots twice" 2 "$(boots)"
logged "the game says why" "the engine, prefix, WINEMSYNC or boot environment differs (SDL_HELPERTEST SDL_PLAYTEST)" p1-game
: > "$case_dir/events"
play p2 HELPER_SDL_PLAYTEST=helper HELPER_SDL_HELPERTEST=1 GAME_SDL_PLAYTEST=game
is "then once" 1 "$(boots)"
is "the boot has the game's variables, not the helper's own" \
	"boot by reg: SDL_PLAYTEST=game SDL_HELPERTEST=unset" "$(grep '^boot' "$case_dir/events")"
is "the helper's program keeps the helper's environment" \
	"client C:\\Program Files (x86)\\Steam\\steam.exe: SDL_PLAYTEST=helper" "$(grep '^client C:' "$case_dir/events")"
record=$(cat "$case_dir/compat/bridgeplay-boot-env")
case "$record" in *WINEPREFIX=*|*WINESERVER=*|*CX_ROOT=*) bad "the record keeps the engine's paths out" "none" "$record" ;; *) ok "the record keeps the engine's paths out" ;; esac
: > "$case_dir/events"
play p3 HELPER_SDL_PLAYTEST=helper GAME_SDL_PLAYTEST=changed
is "a game whose environment changed boots its own" 2 "$(boots)"

echo "== anything that differs from the helper's session kills it"
new_case
play msync HELPER_WINEMSYNC=1 GAME_WINEMSYNC=0
logged "another WINEMSYNC" "not reusing the helper's Wine session, the engine, prefix, WINEMSYNC or boot environment differs" msync-game
is "boots twice" 2 "$(boots)"
new_case
between='touch -t 202601010000 "$engine/bin/wineserver"'
play engine
between=""
logged "another wineserver" "the engine, prefix, WINEMSYNC or boot environment differs" engine-game
new_case
between='sed "s/^ended=.*/ended=$(($(date +%s) - 60))/" "$case_dir/compat/bridgeplay-warm-server" > "$case_dir/note" && mv "$case_dir/note" "$case_dir/compat/bridgeplay-warm-server"'
play old
between=""
logged "an old note" "not reusing the helper's Wine session, it is 6" old-game
new_case
between='rm -rf "$case_dir/server"'
play gone
between=""
logged "a server that went away" "its Wine server is gone or was replaced" gone-game
is "the game boots its own" 2 "$(boots)"
new_case
between='FAKE_SERVER="$case_dir/server" FAKE_EVENTS="$case_dir/events" "$engine/bin/wineserver" -k
FAKE_SERVER="$case_dir/server" FAKE_EVENTS="$case_dir/events" "$engine/bin/wineserver" -p3'
play replaced
between=""
logged "a server that was replaced" "its Wine server is gone or was replaced" replaced-game
new_case
between='mv "$case_dir/compat/bridgeplay-warm-server" "$case_dir/note" && ln -s "$case_dir/note" "$case_dir/compat/bridgeplay-warm-server"'
play link
between=""
unlogged "a note that is a link is not read" "warm start: reusing" link-game
is "and it is gone" no "$([ -e "$case_dir/compat/bridgeplay-warm-server" ] || [ -L "$case_dir/compat/bridgeplay-warm-server" ] && echo yes || echo no)"

echo "== a restart for new controller settings ends the session as before"
new_case
play pad HELPER_FAKE_PAD=057e/2009
is "the game boots after the helper's restart" 3 "$(boots)"
unlogged "the helper leaves nothing" "left up for the game" pad-helper

echo "== a helper that fails takes its session and the stamps with it"
new_case
play ok
: > "$case_dir/events"
play failed HELPER_FAKE_HELPER_STATUS=3
logged "the helper reports its status" "=== helper exited status=3 ===" failed-helper
unlogged "no session is left" "left up for the game" failed-helper
is "its server is killed before the game starts" "server killed" \
	"$(awk '/^client C:/ { on = 1; next } on && /^server started/ { exit } on' "$case_dir/events")"
unlogged "the game finds none" "warm start: reusing" failed-game
logged "the game runs every step" "launch stamps: every step runs in full" failed-game

echo "== BRIDGEPLAY_FULL_LAUNCH=1 runs the old way"
new_case
play full NOTPROTON_FULL_LAUNCH=1
is "two boots" 2 "$(boots)"
unlogged "no server is kept" "warm start:" full-helper
logged "every step runs" "launch stamps: every step runs in full (BRIDGEPLAY_FULL_LAUNCH=1)" full-game

echo "== launch stamps"
new_case
play p1
logged "nothing on record runs in full" "launch stamps: every step runs in full (no last launch on record)" p1-helper
is "fonts linked" 60 "$(find "$case_dir/compat/pfx/drive_c/windows/Fonts" -type l | wc -l | tr -d ' ')"
play p2
logged "after a good launch steps are skipped" "launch stamps: steps whose inputs match the last launch are skipped" p2-helper
logged "fonts unchanged" "fonts: unchanged since the last good launch, links kept" p2-helper
logged "for the game too" "fonts: unchanged since the last good launch, links kept" p2-game
: > "$engine/share/wine/fonts/new.ttf"
play p3
unlogged "a new engine font is linked" "fonts: unchanged" p3-helper
is "the new font is there" yes "$([ -L "$case_dir/compat/pfx/drive_c/windows/Fonts/new.ttf" ] && echo yes || echo no)"
rm -f "$engine/share/wine/fonts/new.ttf"
play crashed GAME_FAKE_CODE=crash
play after-crash
logged "after a crash every step runs" "launch stamps: every step runs in full (the last launch ended crash)" after-crash-helper
unlogged "fonts too" "fonts: unchanged" after-crash-helper
play again
logged "a good launch after it skips again" "fonts: unchanged" again-game

[ "$fails" -eq 0 ] || { echo "==> warmcheck: $fails failed"; exit 1; }
echo "==> warmcheck: one Wine boot per Play, the session and the stamps are dropped on any change"
