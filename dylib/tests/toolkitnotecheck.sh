#!/bin/sh
# A Direct3D 12 game on a WineCX engine without Apple's Game Porting Toolkit tells the player
# once per prefix and build where to get it. Engines with D3DMetal, CrossOver (no
# notproton-backends), FEX, helpers and games on another backend say nothing.
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> toolkitnotecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^d3dmetal_engine() {/,/^}/p;/^toolkit_graphics_notice() {/,/^}/p' "$SRC")
case "$body" in
  *d3dmetal_engine*toolkit_graphics_notice*bridgeplay-toolkit-noticed*) ;;
  *) echo "FAIL: toolkit_graphics_notice was not found in $SRC"; exit 1 ;;
esac
grep -q '^toolkit_graphics_notice "\$1"' "$SRC" || { echo "FAIL: toolkit_graphics_notice is never called in $SRC"; exit 1; }
body="$body"'
notify_user() { printf "%s|%s\n" "$1" "$2" >> "$notes"; }
graphics_log() { echo "graphics: $*" >> "$log"; }
imports_d3d12() { [ "$d3d12" = 1 ]; }'

# a failed mktemp must not leave work at the current folder, which the trap deletes
work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
logged() { if grep -qF -- "$2" "$work/log"; then ok "$1"; else bad "$1" "$2" "$(cat "$work/log")"; fi; }

engine="$work/engine"
prefix="$work/compatdata/1091500"
mkdir -p "$engine/lib/notproton-backends" "$prefix/pfx/drive_c/users/steamuser/Saved Games"
echo "save" > "$prefix/pfx/drive_c/users/steamuser/Saved Games/slot1.sav"
mark="$prefix/bridgeplay-toolkit-noticed"

run() { # run [VAR=value ...]: one launch, prints what the player was told
  : > "$work/log"
  : > "$work/notes"
  env log="$work/log" notes="$work/notes" backend_root="$engine/lib/notproton-backends" \
    STEAM_COMPAT_DATA_PATH="$prefix" np_build=winecx-26.1 verb=waitforexitandrun \
    wine_unix="$engine/lib/wine/x86_64-unix" backend=wined3d d3d12=1 "$@" \
    body="$body" sh -ec 'eval "$body"; toolkit_graphics_notice game.exe'
  cut -d'|' -f1 "$work/notes"
}

echo "== the notice"
is "a Direct3D 12 game without the toolkit is told" "This game uses DirectX 12" "$(run)"
is "the prefix and build are marked" winecx-26.1 "$(cat "$mark")"
logged "it is logged" "no Game Porting Toolkit"
is "a second launch of the same build says nothing" "" "$(run)"
logged "it is still logged" "no Game Porting Toolkit"
is "a new build tells it again" "This game uses DirectX 12" "$(run np_build=winecx-26.2)"
is "the save is untouched" save "$(cat "$prefix/pfx/drive_c/users/steamuser/Saved Games/slot1.sav")"

echo "== nothing to say"
rm -f "$mark"
is "a game that does not import d3d12.dll" "" "$(run d3d12=0)"
is "a game on another backend (its conf chose one)" "" "$(run backend=dxmt)"
is "a helper process" "" "$(run verb=run)"
is "Wine through FEX, which has its own notice" "" "$(run wine_unix="$engine/lib/wine/aarch64-unix")"
is "CrossOver, which has no notproton-backends" "" "$(run backend_root="$work/crossover/lib/notproton-backends")"
touch "$engine/lib/notproton-backends/d3dmetal.enabled"
is "an engine with the toolkit linked" "" "$(run)"
rm -f "$engine/lib/notproton-backends/d3dmetal.enabled"
is "no prefix folder known" "" "$(run STEAM_COMPAT_DATA_PATH=)"
is "none of these marked the prefix" no "$([ -e "$mark" ] && echo yes || echo no)"

[ "$fails" -eq 0 ] || { echo "toolkitnotecheck: $fails failed"; exit 1; }
echo "toolkitnotecheck: all passed"
