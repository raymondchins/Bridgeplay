#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> envcheck: $SRC not present, skipped"; exit 0; }

strip() { sed 's/^[[:space:]]*//'; }
dllpath_line=$(grep 'export WINEDLLPATH=' "$SRC" | grep 'x86_64-windows' | strip)
overrides_line=$(grep 'export WINEDLLOVERRIDES=' "$SRC" | grep 'lsteamclient=b' | strip)
[ -n "$dllpath_line" ] || { echo "FAIL: WINEDLLPATH merge not found"; exit 1; }
[ -n "$overrides_line" ] || { echo "FAIL: WINEDLLOVERRIDES merge not found"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "== WINEDLLPATH (first match wins, runner first) =="
CX_ROOT=/R
wine_unix=/R/lib/wine/x86_64-unix
WINEDLLPATH=""
eval "$dllpath_line"
is "no user value" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix" "$WINEDLLPATH"
WINEDLLPATH="/user/dir"
eval "$dllpath_line"
is "user value last" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix:/user/dir" "$WINEDLLPATH"

echo "== WINEDLLOVERRIDES (last wins, trio last) =="
WINEDLLOVERRIDES=""
eval "$overrides_line"
is "no user value" "steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="winhttp=n,b"
eval "$overrides_line"
is "user value first" "winhttp=n,b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="lsteamclient=n"
eval "$overrides_line"
is "trio outranks user" "lsteamclient=n;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides="vcruntime140_1=n,b;"
WINEDLLOVERRIDES="vcruntime140_1=b"
eval "$overrides_line"
is "user outranks the native runtime" \
  "vcruntime140_1=n,b;vcruntime140_1=b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides=""

echo "== Microsoft's Visual C++ runtime loads when it is installed =="
vc_fn=$(sed -n '/^native_vc_runtime() {/,/^}/p' "$SRC")
[ -n "$vc_fn" ] || { echo "FAIL: native_vc_runtime not found"; exit 1; }
eval "$vc_fn"
vc_work=$(mktemp -d)
WINEPREFIX="$vc_work/pfx"
sys32="$WINEPREFIX/drive_c/windows/system32"
mkdir -p "$sys32"
pe() { printf 'MZ%062d%s' 0 "$2" > "$sys32/$1.dll"; }
is "empty prefix overrides nothing" "" "$(native_vc_runtime)"
pe vcruntime140 "Wine builtin DLL"
pe msvcp140_2 "Wine builtin DLL"
is "Wine's own copies are left alone" "" "$(native_vc_runtime)"
pe msvcp140_2 "This program cannot be run in DOS mode."
pe vcruntime140_1 "This program cannot be run in DOS mode."
: > "$sys32/msvcp140.dll"
is "Microsoft's copies load first" "msvcp140=n,b;msvcp140_2=n,b;vcruntime140_1=n,b;" "$(native_vc_runtime)"
rm -rf "$vc_work"

echo "== Apple GPTK initialization and launcher environment =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/bridgeplay"
np_build="test"
library="$np_support/runners/crossover-$np_build/CrossOver/lib64/apple_gptk/external/libd3dshared.dylib"
init=$(sed -n '/^CX_ROOT=/,/^wine_unix=/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$init" ] && [ -n "$forward" ] || { echo "FAIL: runner environment blocks not found"; exit 1; }
unset CX_APPLEGPTK_LIBD3DSHARED_PATH
eval "$init"
is "runner without the library leaves the path unset" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
mkdir -p "$(dirname "$library")"
: > "$library"
eval "$init"
is "bundled library is selected" "$library" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
is "helpers inherit the library path" "$library" "$(sh -c 'printf %s "$CX_APPLEGPTK_LIBD3DSHARED_PATH"')"
set --
eval "$forward"
forwarded=""
for arg in "$@"; do
  case "$arg" in CX_APPLEGPTK_LIBD3DSHARED_PATH=*) forwarded=${arg#*=} ;; esac
done
is "game launcher receives the path as one argument" "$library" "$forwarded"
# macOS sed stops at the first invalid UTF-8 value.
# shellcheck disable=SC2016 # The stub and loop expand inside the child shell.
after_bad=$(env -i PATH="$PATH" LANG=en_US.UTF-8 DXVK_HUD=1 sh -c '
  env() { printf "A_BAD=a\377b\nDXVK_HUD=1\n"; }
  f=$1; set --; eval "$f"; printf "%s " "$@"' sh "$forward")
is "settings after a non-UTF-8 value are forwarded" "--env DXVK_HUD=1 " "$after_bad"

echo "== Rosetta-only settings on arm64 Wine =="
drop=$(sed -n '/^np_dropped=""$/,/^fi$/p' "$SRC")
[ -n "$drop" ] || { echo "FAIL: the arm64 settings block was not found"; exit 1; }
drop_at=$(grep -n '^np_dropped=""$' "$SRC" | cut -d: -f1)
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward_at=$(grep -n '^for name in $(env ' "$SRC" | cut -d: -f1)
[ "$drop_at" -lt "$forward_at" ] ||
  bad "the arm64 settings block runs before the forwarding loop" "< $forward_at" "$drop_at"
seen() { sh -c 'env | sed -nE "s/^(CX_GRAPHICS_BACKEND|D3DM_[A-Z0-9_]*|DXMT_[A-Z0-9_]*|ROSETTA_[A-Z0-9_]*)=.*/\1/p" | sort | tr "\n" " "'; }
for name in $(seen); do unset -v "$name"; done
CX_ROOT="/R R"
set_all() { export CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 ROSETTA_ADVERTISE_AVX=0 DXMT_CONFIG=x; }
set_all
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine keeps every setting" \
  "CX_GRAPHICS_BACKEND D3DM_ENABLE_METALFX DXMT_CONFIG ROSETTA_ADVERTISE_AVX " "$(seen)"
is "x86_64 Wine logs nothing" "" "$np_dropped"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "D3DMetal and Rosetta settings leave the environment" "DXMT_CONFIG " "$(seen)"
is "the run log names what was ignored" \
  "CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX" "$np_dropped"
set_all
export CX_GRAPHICS_BACKEND=dxmt
unset -v D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX
eval "$drop"
is "other backends stay" "CX_GRAPHICS_BACKEND DXMT_CONFIG " "$(seen)"
is "nothing to ignore logs nothing" "" "$np_dropped"
unset -v CX_GRAPHICS_BACKEND DXMT_CONFIG

echo "== Rosetta AVX =="
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine turns it on" "1" "$ROSETTA_ADVERTISE_AVX"
is "the default is logged as the default" "default" "$avx_from"
is "helpers inherit it" "1" "$(sh -c 'printf %s "$ROSETTA_ADVERTISE_AVX"')"
ROSETTA_ADVERTISE_AVX=0
eval "$drop"
is "a launch option of 0 is kept" "0" "$ROSETTA_ADVERTISE_AVX"
is "a launch option is logged as one" "environment" "$avx_from"
ROSETTA_ADVERTISE_AVX=
eval "$drop"
is "an empty launch option turns it on" "1" "$ROSETTA_ADVERTISE_AVX"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "arm64 Wine leaves it unset" "unset" "${ROSETTA_ADVERTISE_AVX-unset}"

echo "== FEX reduced x87 precision =="
unset -v FEX_X87REDUCEDPRECISION
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine leaves it unset" "unset" "${FEX_X87REDUCEDPRECISION-unset}"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "arm64 Wine turns it on" "1" "$FEX_X87REDUCEDPRECISION"
is "the default is logged as the default" "default" "$fex_from"
is "helpers inherit it" "1" "$(sh -c 'printf %s "$FEX_X87REDUCEDPRECISION"')"
FEX_X87REDUCEDPRECISION=0
eval "$drop"
is "a launch option of 0 is kept" "0" "$FEX_X87REDUCEDPRECISION"
is "a launch option is logged as one" "environment" "$fex_from"
FEX_X87REDUCEDPRECISION=
eval "$drop"
is "an empty launch option is kept" "" "$FEX_X87REDUCEDPRECISION"
export FEX_X87REDUCEDPRECISION=0 FEX_MULTIBLOCK=0
set --
eval "$forward"
fex_args=""
for arg in "$@"; do
  case "$arg" in FEX_*) fex_args="$fex_args$arg
" ;; esac
done
is "FEX settings reach the game" "FEX_MULTIBLOCK=0 FEX_X87REDUCEDPRECISION=0 " "$(printf %s "$fex_args" | sort | tr '\n' ' ')"
unset -v FEX_X87REDUCEDPRECISION FEX_MULTIBLOCK

echo "== the support folder and the BRIDGEPLAY_ names =="
# shellcheck disable=SC2016 # Match the literal assignment.
pick=$(sed -n '/^np_support="\$HOME\/Library\/Application Support\/bridgeplay"$/,/^fi$/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal loop.
names=$(sed -n '/^for np_name in \$(env /,/^done$/p' "$SRC")
[ -n "$pick" ] && [ -n "$names" ] || { echo "FAIL: the support folder or name blocks not found"; exit 1; }
support_for() {
  # shellcheck disable=SC2030 # HOME changes in this subshell only
  (HOME="$work/home-$1"; mkdir -p "$HOME/Library/Application Support"
   for d in $2; do mkdir -p "$HOME/Library/Application Support/$d"; done
   eval "$pick"; printf '%s' "${np_support##*/}")
}
is "a migrated home uses bridgeplay" "bridgeplay" "$(support_for new bridgeplay)"
is "a home with only the old folder keeps using it" "notproton" "$(support_for old notproton)"
is "both present: bridgeplay wins" "bridgeplay" "$(support_for both 'bridgeplay notproton')"
is "a fresh home gets bridgeplay" "bridgeplay" "$(support_for none '')"
# shellcheck disable=SC2016 # the inner sh expands them
mapped() { env -i PATH="$PATH" "$@" names="$names" sh -ec 'eval "$names"; printf "%s|%s" "${NOTPROTON_RETINA-unset}" "${NOTPROTON_FRAMEGEN-unset}"'; }
is "BRIDGEPLAY_ names reach the NOTPROTON_ ones" "1|2" "$(mapped BRIDGEPLAY_RETINA=1 BRIDGEPLAY_FRAMEGEN=2)"
is "a NOTPROTON_ name already set wins" "0|unset" "$(mapped BRIDGEPLAY_RETINA=1 NOTPROTON_RETINA=0)"
is "an empty BRIDGEPLAY_ value is still a value" "|unset" "$(mapped BRIDGEPLAY_RETINA=)"
is "a value holding a quote and a newline is copied as is" "a'b
c|unset" "$(mapped "BRIDGEPLAY_RETINA=a'b
c")"

echo "== the run log and the Steam login =="
logged=$(grep -F "env | grep -iE '^(Steam|SDL_)'" "$SRC" | strip)
[ -n "$logged" ] || { echo "FAIL: the Steam environment log line not found"; exit 1; }
# shellcheck disable=SC2016 # the inner sh expands it
run_log() { env -i PATH="$PATH" "$@" logged="$logged" sh -ec 'eval "$logged"'; }
is "the login name and video token stay out, the rest stays" "SDL_JOYSTICK_MFI=0
SteamAppId=4242
SteamGameId=4242" "$(run_log SteamUser=login SteamAppUser=login STEAMVIDEOTOKEN=1002 \
  SteamAppId=4242 SteamGameId=4242 SDL_JOYSTICK_MFI=0)"
is "a log with only those lines is empty, not a stopped script" "" "$(run_log SteamUser=login)"
# shellcheck disable=SC2016 # the inner sh expands them
is "the game still gets them" "login|1002" "$(env -i PATH="$PATH" SteamUser=login STEAMVIDEOTOKEN=1002 \
  logged="$logged" sh -ec 'eval "$logged" > /dev/null; printf "%s|%s" "$SteamUser" "$STEAMVIDEOTOKEN"')"

if [ "$fails" -eq 0 ]; then
	echo "==> envcheck: all assertions hold"
else
	echo "==> envcheck: $fails failed"
	exit 1
fi
