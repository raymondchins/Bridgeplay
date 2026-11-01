#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> routecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^target="\$1"$/,/^fi$/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: the launch routing not found in $SRC"; exit 1; }
case "$body" in
  *'case "$verb" in'*) ;;
  *) echo "FAIL: the routing no longer decides on the verb"; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/wine" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CALLS"
exit "${FAKE_STATUS:-0}"
EOF
chmod +x "$work/wine"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

shim='C:\Program Files (x86)\Steam\steam.exe'
url='steam2ea://launchgame/1222670?platform=steam&theme=ts4'

case_dir=""
route() {
	verb="$1"
	shift
	case_dir=$(mktemp -d "$work/case.XXXXXX")
	: > "$case_dir/calls"
	: > "$case_dir/log"
	env WINELOADER="$work/wine" STEAM_COMPAT_INSTALL_PATH=/g \
		FAKE_STATUS="${FAKE_STATUS:-0}" FAKE_CALLS="$case_dir/calls" \
		log="$case_dir/log" body="$body" verb="$verb" \
		sh -ec 'eval "$body"; echo "fell through foreground=$foreground"' \
		"$verb" "$@" > "$case_dir/out" 2>&1 || true
}
calls() { cat "$case_dir/calls"; }
out() { cat "$case_dir/out"; }
status() { sed -n 's/^=== helper exited status=\([0-9]*\) ===$/\1/p' "$case_dir/log"; }

echo "== the game goes to the window path, whatever shape the target has"
route waitforexitandrun /g/game.exe
is "an exe under the install path falls through" "fell through foreground=1" "$(out)"
is "and the loader is not called there" "" "$(calls)"
route waitforexitandrun "$url"
is "a protocol URL falls through too" "fell through foreground=1" "$(out)"
is "and the loader is not called there either" "" "$(calls)"

echo "== helpers go through the shim"
route run /c/legacycompat/iscriptevaluator.exe 'legacycompat\evaluatorscript_1222670.vdf'
is "run puts steam.exe in front of the helper" \
	"$shim /c/legacycompat/iscriptevaluator.exe legacycompat\\evaluatorscript_1222670.vdf" "$(calls)"
route run "$url"
is "a URL reaches the shim rather than the loader" "$shim $url" "$(calls)"

echo "== runinprefix keeps the raw loader"
route runinprefix /c/tool.exe --flag
is "no shim in front" "/c/tool.exe --flag" "$(calls)"

echo "== the helper's status is what Steam gets"
FAKE_STATUS=3 route run /c/helper.exe
FAKE_STATUS=0
is "a failing helper is logged with its status" 3 "$(status)"

echo "== a target with spaces stays one argument"
route run '/c/My Helper/helper.exe' '--opt=a b'
is "quoting survives the shim" "$shim /c/My Helper/helper.exe --opt=a b" "$(calls)"

echo "== only the game itself is given an app id"
ids=$(sed -n '/^app_id="\$STEAM_COMPAT_APP_ID"$/,/^esac$/p' "$SRC")
[ -n "$ids" ] || { echo "FAIL: the app id block not found in $SRC"; exit 1; }
gameid() {
	env -u SteamAppId -u SteamGameId verb="$1" STEAM_COMPAT_APP_ID=1222670 \
		log=/dev/null ids="$ids" \
		sh -ec 'eval "$ids"; echo "${SteamGameId:-unset}"'
}
is "the game is the game" 1222670 "$(gameid waitforexitandrun)"
is "a helper is not, or the shim reports it to Steam as a running app" \
	unset "$(gameid run)"
is "and neither is runinprefix" unset "$(gameid runinprefix)"

appid() {
	env -u SteamAppId -u SteamGameId verb=waitforexitandrun STEAM_COMPAT_APP_ID=0 \
		SteamAppId="$1" SteamGameId="$2" log=/dev/null ids="$ids" \
		sh -ec 'eval "$ids"; echo "${SteamAppId-unset} $SteamGameId"'
}
is "a shortcut does not pass its ID off as a Steam app" \
	"unset 11332531184899981312" "$(appid 2638560530 11332531184899981312)"
is "the largest shortcut ID is still a shortcut" \
	"unset 18446744069448138752" "$(appid 4294967295 18446744069448138752)"
is "a Steam app keeps its app ID" "1222670 1222670" "$(appid 1222670 1222670)"
is "a mod is not a shortcut" "1222670 11332531184884426766" "$(appid 1222670 11332531184884426766)"
is "a game ID that is not a number is left alone" "7 bogus" "$(appid 7 bogus)"

if [ "$fails" -eq 0 ]; then
	echo "==> routecheck: all assertions hold"
else
	echo "==> routecheck: $fails failed"
	exit 1
fi
