#!/bin/sh
# Mod loader detection in compat_run.sh: fixture game folders, the overrides it adds, the
# opt-out and the order against a conf's DLLOVERRIDES and the launch options.
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> modloadercheck: $SRC not present, skipped"; exit 0; }

functions=""
for name in gamefix_log valid_dll_overrides gamefix_reason gamefix_read gamefix_apply_env \
	load_gamefixes mod_loader_dir detect_mod_loaders compose_dll_overrides; do
	body=$(sed -n "/^$name() {\$/,/^}\$/p" "$SRC")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done
public_names=$(sed -n '/^for np_name in $(env /,/^done$/p' "$SRC")
[ -n "$public_names" ] || { echo "FAIL: the BRIDGEPLAY_ to NOTPROTON_ loop not found"; exit 1; }
grep -q '^detect_mod_loaders "\$1" || true$' "$SRC" || { echo "FAIL: detect_mod_loaders is not called"; exit 1; }
# Called after the shim stages its version.dll and before the overrides are composed.
order=$(grep -n -e '^stage_rockstar_shim || true$' -e '^detect_mod_loaders "\$1" || true$' -e '^compose_dll_overrides$' "$SRC" | cut -d: -f2- | tr '\n' ' ')
[ "$order" = 'stage_rockstar_shim || true detect_mod_loaders "$1" || true compose_dll_overrides ' ] \
	|| { echo "FAIL: detect_mod_loaders is out of order: $order"; exit 1; }

work=$(mktemp -d) || exit 1
[ -d "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "a line with $2" "$(cat "$3")"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then bad "$1" "no line with $2" "$(cat "$3")"; else ok "$1"; fi; }

case_dir="" game=""
new_case() {
	case_dir=$(mktemp -d "$work/case.XXXXXX")
	game="$case_dir/common/My Game"
	mkdir -p "$case_dir/support/gamefixes-default" "$case_dir/support/gamefixes" "$game"
	: > "$case_dir/log"
	printf 'MZ game\n' > "$game/game.exe"
}
put() { for f in "$@"; do mkdir -p "$game/$(dirname "$f")"; printf 'MZ %s\n' "$f" > "$game/$f"; done; }
user_conf() { printf '%s\n' "$@" > "$case_dir/support/gamefixes/4242.conf"; }

# The script's sequence from the conf to the composed overrides. Extra arguments are the
# launch options' environment.
launch() {
	verb=$1 target=$2
	shift 2
	env -i PATH="$PATH" HOME="$HOME" "$@" \
		functions="$functions" public_names="$public_names" \
		app_id=4242 verb="$verb" log="$case_dir/log" np_support="$case_dir/support" \
		STEAM_COMPAT_INSTALL_PATH="${install:-$game}" \
		sh -ec '
			eval "$public_names"
			eval "$functions"
			gamefix_keys="" gamefix_dlloverrides="" backend=d3dmetal backend_overrides="dxgi=b"
			load_gamefixes || true
			detect_mod_loaders "$1" || true
			compose_dll_overrides
			printf "WINEDLLOVERRIDES=%s\n" "${WINEDLLOVERRIDES-<unset>}"
		' launch "$target" > "$case_dir/out" 2>&1 || bad "the launch sequence ran to the end" "exit 0" "exit $? $(tail -1 "$case_dir/out")"
}
got() { sed -n "s/^$1=//p" "$case_dir/out"; }
run_game() { launch waitforexitandrun "$game/game.exe" "$@"; }

echo "== loaders found beside the game"
new_case
put winhttp.dll doorstop_config.ini BepInEx/core/BepInEx.dll
run_game
is "BepInEx: winhttp native first" "dxgi=b;winhttp=n,b" "$(got WINEDLLOVERRIDES)"
has "BepInEx is logged" "gamefix: mod loader: BepInEx in $game, winhttp=n,b" "$case_dir/log"

new_case
put version.dll doorstop_config.ini
run_game
is "Unity Doorstop alone: version native first" "dxgi=b;version=n,b" "$(got WINEDLLOVERRIDES)"
has "Unity Doorstop is logged" "mod loader: Unity Doorstop in $game, version=n,b" "$case_dir/log"

new_case
put version.dll MelonLoader/net6/MelonLoader.dll
run_game
is "MelonLoader: version native first" "dxgi=b;version=n,b" "$(got WINEDLLOVERRIDES)"

new_case
put dinput8.dll scripts/mod.asi
run_game
is "ASI loader with scripts/*.asi: dinput8 native first" "dxgi=b;dinput8=n,b" "$(got WINEDLLOVERRIDES)"
has "the ASI loader is logged" "mod loader: an ASI loader in $game, dinput8=n,b" "$case_dir/log"

new_case
put version.dll plugins/cyber_engine_tweaks.asi
run_game
is "ASI loader with plugins/*.asi: version native first" "dxgi=b;version=n,b" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll Widescreen.ASI
run_game
is "ASI loader with an .ASI beside the game" "dxgi=b;winhttp=n,b" "$(got WINEDLLOVERRIDES)"

new_case
put dinput8.dll ScriptHookV.dll
run_game
is "Script Hook V: dinput8 native first" "dxgi=b;dinput8=n,b" "$(got WINEDLLOVERRIDES)"
has "Script Hook is logged" "mod loader: Script Hook in $game, dinput8=n,b" "$case_dir/log"

new_case
put winhttp.dll version.dll dinput8.dll doorstop_config.ini BepInEx/core/x.dll scripts/a.asi
run_game
is "several proxies, one entry each" "dxgi=b;winhttp=n,b;version=n,b;dinput8=n,b" "$(got WINEDLLOVERRIDES)"

echo "== DLLs the game ships for itself"
new_case
put dinput8.dll version.dll winhttp.dll
run_game
is "no loader files: no override" "dxgi=b" "$(got WINEDLLOVERRIDES)"
has "an unmatched DLL is logged" "mod loader: dinput8.dll in $game matches no known loader, left to Wine's default" "$case_dir/log"

new_case
put dinput8.dll doorstop_config.ini BepInEx/core/x.dll
run_game
is "BepInEx files do not vouch for dinput8" "dxgi=b" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll ScriptHookV.dll
run_game
is "Script Hook does not vouch for winhttp" "dxgi=b" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll dxgi.dll d3d11.dll doorstop_config.ini BepInEx/core/x.dll
run_game
is "dxgi and d3d11 stay with the backend" "dxgi=b;winhttp=n,b" "$(got WINEDLLOVERRIDES)"
has "dxgi is logged as left alone" "mod loader: dxgi.dll in $game left to the d3dmetal backend" "$case_dir/log"
has "d3d11 is logged as left alone" "mod loader: d3d11.dll in $game left to the d3dmetal backend" "$case_dir/log"

new_case
put dxgi.dll d3d11.dll scripts/a.asi ReShade.ini
run_game
is "no proxy: nothing added" "dxgi=b" "$(got WINEDLLOVERRIDES)"
lacks "no proxy: nothing logged" "mod loader" "$case_dir/log"

echo "== where it looks"
new_case
mkdir -p "$game/Binaries/Win64"
printf 'MZ game\n' > "$game/Binaries/Win64/Game-Win64-Shipping.exe"
put Binaries/Win64/dinput8.dll Binaries/Win64/scripts/a.asi
launch waitforexitandrun "$game/Binaries/Win64/Game-Win64-Shipping.exe"
is "beside an exe below the install folder" "dxgi=b;dinput8=n,b" "$(got WINEDLLOVERRIDES)"

new_case
mkdir -p "$game/bin/x64"
printf 'MZ launcher\n' > "$game/bin/x64/launcher.exe"
put winhttp.dll doorstop_config.ini
launch waitforexitandrun "$game/bin/x64/launcher.exe"
is "the install folder above the exe" "dxgi=b;winhttp=n,b" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll doorstop_config.ini
launch run "$game/game.exe"
is "a helper verb: no detection" "dxgi=b" "$(got WINEDLLOVERRIDES)"
lacks "a helper verb: nothing logged" "mod loader" "$case_dir/log"

echo "== opt-out and order"
new_case
put winhttp.dll doorstop_config.ini
run_game BRIDGEPLAY_MOD_LOADERS=0
is "BRIDGEPLAY_MOD_LOADERS=0 turns it off" "dxgi=b" "$(got WINEDLLOVERRIDES)"
has "the opt-out is logged" "mod loader: detection off (MOD_LOADERS=0)" "$case_dir/log"

new_case
put winhttp.dll doorstop_config.ini
user_conf MOD_LOADERS=0
run_game
is "MOD_LOADERS=0 in the game's conf turns it off" "dxgi=b" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll doorstop_config.ini
user_conf MOD_LOADERS=0
run_game BRIDGEPLAY_MOD_LOADERS=1
is "the launch options win over the conf" "dxgi=b;winhttp=n,b" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll doorstop_config.ini
user_conf MOD_LOADERS=yes
run_game
is "MOD_LOADERS=yes is rejected, detection stays on" "dxgi=b;winhttp=n,b" "$(got WINEDLLOVERRIDES)"
has "the rejection is logged" "rejected MOD_LOADERS: not 0 or 1" "$case_dir/log"

new_case
put winhttp.dll version.dll doorstop_config.ini
user_conf 'DLLOVERRIDES=winhttp=b'
run_game
is "a conf entry for the DLL replaces the automatic one" "dxgi=b;version=n,b;winhttp=b" "$(got WINEDLLOVERRIDES)"
has "the conf entry is logged" "mod loader: Unity Doorstop in $game, winhttp already set by DLLOVERRIDES or a shim" "$case_dir/log"

new_case
put version.dll doorstop_config.ini
user_conf 'DLLOVERRIDES=xinput1_3,version=n'
run_game
is "a conf list naming the DLL second" "dxgi=b;xinput1_3,version=n" "$(got WINEDLLOVERRIDES)"

new_case
put winhttp.dll doorstop_config.ini
user_conf 'DLLOVERRIDES=xinput1_3=n,b'
run_game WINEDLLOVERRIDES='winhttp=b'
is "the launch options come last and win" "dxgi=b;winhttp=n,b;xinput1_3=n,b;winhttp=b" "$(got WINEDLLOVERRIDES)"

if [ "$fails" -gt 0 ]; then
	echo "==> modloadercheck: $fails failed"
	exit 1
fi
echo "==> modloadercheck: passed"
