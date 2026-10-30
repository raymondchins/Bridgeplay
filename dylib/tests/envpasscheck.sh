#!/bin/sh
# A launch option named NOTPROTON_ENV_FOO reaches the game as FOO, except where that
# would replace something the launch sets for itself.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> envpasscheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^np_env_passed=/,/^done$/p' "$SRC")
case "$block" in
  *NOTPROTON_ENV_*) ;;
  *) echo "FAIL: the passthrough loop was not found in $SRC"; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$block" > "$work/block.sh"

# Runs the loop with a given environment and prints the --env arguments it added.
forwarded() {
  # shellcheck disable=SC2016 # the block expands inside the child shell, not here
  env -i PATH="$PATH" log=/dev/null "$@" \
    sh -c 'w=$1; set --; . "$w/block.sh"; printf "%s\n" "$@"' sh "$work" |
    sed -e '/^--env$/d' -e '/^$/d' | LC_ALL=C sort | tr '\n' ' '
}

fail=0
ok() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else
  echo "  FAIL  $1 (want [$3], got [$2])"; fail=1; fi; }

ok "nothing set forwards nothing" "$(forwarded)" ""
ok "one option reaches the game under its own name" \
  "$(forwarded NOTPROTON_ENV_FRAMESCOPE_HZ=60)" "FRAMESCOPE_HZ=60 "
ok "several are each forwarded" \
  "$(forwarded NOTPROTON_ENV_A_ONE=1 NOTPROTON_ENV_B_TWO=2)" "A_ONE=1 B_TWO=2 "
ok "a value with spaces survives" \
  "$(forwarded NOTPROTON_ENV_MSG='two words')" "MSG=two words "
ok "an empty value is still passed" "$(forwarded NOTPROTON_ENV_EMPTY=)" "EMPTY= "

# The launch sets these itself; letting a game replace them breaks it in ways that look
# like NotProton is at fault.
for reserved in CX_ROOT WINEPREFIX PATH HOME STEAM_DYLD_INSERT_LIBRARIES STEAM_COMPAT_APP_ID \
  WINEDLLOVERRIDES WINEMSYNC DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH NOTPROTON_FEATURE_DYLIBS \
  NOTPROTON_GAME_CWD; do
  ok "$reserved is refused" "$(forwarded "NOTPROTON_ENV_$reserved=x")" ""
done
ok "Wine's own settings still pass" \
  "$(forwarded NOTPROTON_ENV_WINEDEBUG=+loaddll NOTPROTON_ENV_WINEESYNC=1)" "WINEDEBUG=+loaddll WINEESYNC=1 "
ok "a name the script uses itself reaches the game as given" \
  "$(forwarded NOTPROTON_ENV_name=HELLO NOTPROTON_ENV_log=x)" "log=x name=HELLO "
ok "a refusal does not stop the rest" \
  "$(forwarded NOTPROTON_ENV_CX_ROOT=x NOTPROTON_ENV_KEEP=yes)" "KEEP=yes "

# The name comes out of a sed capture, so anything that is not a C identifier never
# reaches the eval below it.
ok "a name with a dash is not matched" "$(forwarded 'NOTPROTON_ENV_BAD-NAME=x')" ""
ok "the bare prefix is not matched" "$(forwarded 'NOTPROTON_ENV_=x')" ""

[ "$fail" -eq 0 ] || exit 1
echo "==> envpasscheck: launch options reach the game, reserved names do not"
