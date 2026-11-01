#!/bin/sh
set -eu
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
work=$(mktemp -d "${TMPDIR:-/tmp}/np-seedcheck.XXXXXX")
test "$(stat -f %d "$work")" = "$(stat -f %d "${TMPDIR:-/tmp}")"
detach_images() {
  for mounted in "$work"/mnt.*; do
    [ ! -d "$mounted" ] || /usr/bin/hdiutil detach -quiet -force "$mounted" 2>/dev/null || true
  done
}
trap 'detach_images; chmod -R u+rwX "$work"; rm -rf "$work"' EXIT
cut_block() {
  from="$1" to="$2" keep="$3" awk '
    BEGIN { from = ENVIRON["from"]; to = ENVIRON["to"]; keep = ENVIRON["keep"] }
    !on && $0 ~ from { on = 1 }
    on && $0 ~ to { if (keep) print; found = 1; exit }
    on { print }
    END { exit !found }' "$SRC" || { echo "FAIL: no block from /$1/ to /$2/ in $SRC" >&2; exit 1; }
}
functions=$(cut_block '^merge_user_dir\(\) \{' '^import_prefix_settings\(\) \{' "")
functions="$functions
$(cut_block '^runner_id=""' '^if \[ -n ".STEAM_COMPAT_DATA_PATH" \]; then' "")"
functions="$functions
$(cut_block '^without_lock_fds\(\) \{' '^\}' 1)"
np_build=fixture
export np_build CX_ROOT CX_HOME wine_unix np_tool_dir WINELOADER WINESERVER
export STEAM_COMPAT_DATA_PATH WINEPREFIX template_dir log seed_scratch seed_building
CX_ROOT="$work/runner"
CX_HOME="$work/home"
wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
np_tool_dir="$work/tool"
mkdir -p "$np_tool_dir" "$CX_ROOT/share/wine"
cp "$SRC" "$np_tool_dir/run"
printf inf > "$CX_ROOT/share/wine/wine.inf"
WINELOADER=/usr/bin/false
WINESERVER=/usr/bin/false
eval "$functions"
fails=0
check() {
  if "$@"; then printf '  ok %s\n' "$*"; else
    printf '  FAIL %s\n' "$*"
    fails=$((fails + 1))
  fi
}
fixture() {
  case_root=$(mktemp -d "$work/case.XXXXXX")
  STEAM_COMPAT_DATA_PATH="$case_root/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  template_dir="$case_root/template"
  log="$case_root/log"
  seed_scratch=""
  seed_building=0
  mkdir -p "$WINEPREFIX" "$template_dir/pfx/drive_c/windows"
  printf reg > "$template_dir/pfx/system.reg"
  printf reg > "$template_dir/pfx/user.reg"
  printf reg > "$template_dir/pfx/userdef.reg"
  printf timestamp > "$template_dir/pfx/.update-timestamp"
  printf dll > "$template_dir/pfx/drive_c/windows/ntdll.dll"
  lay_out_proton_profile "$template_dir/pfx"
}

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game" "$profile/My Documents/Game"
printf marker > "$profile/Documents/Game/steam_autocloud.vdf"
printf save > "$profile/My Documents/Game/slot.sav"
lay_out_proton_profile
check test -f "$profile/Documents/Game/slot.sav"
printf newer > "$profile/Documents/Game/slot.sav"
check lay_out_proton_profile
check test "$(cat "$profile/Documents/Game/slot.sav")" = newer

fixture
printf original > "$WINEPREFIX/drive_c"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
mkdir -p "$case_root/external" "$WINEPREFIX/drive_c/users"
ln -s "$case_root/external" "$WINEPREFIX/drive_c/users/steamuser"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser"
chmod 000 "$WINEPREFIX/drive_c/users/steamuser"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused
chmod 700 "$WINEPREFIX/drive_c/users/steamuser"

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
before=$(stat -f %i "$WINEPREFIX")
copy_template_into_prefix
check test "$before" = "$(stat -f %i "$WINEPREFIX")"
check test -f "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
check test -f "$WINEPREFIX/.update-timestamp"
check test -f "$WINEPREFIX/system.reg"
check test ! "$template_dir/pfx/drive_c/windows/ntdll.dll" -ef "$WINEPREFIX/drive_c/windows/ntdll.dll"
check test "$(stat -f %l "$WINEPREFIX/drive_c/windows/ntdll.dll")" = 1
check test "$(stat -f %l "$WINEPREFIX/system.reg")" = 1
check test ! -e "$WINEPREFIX/.notproton-seed-target"
check test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 0
check test "$(find "$template_dir/pfx" | wc -l)" -eq "$(find "$WINEPREFIX" -path "$WINEPREFIX/drive_c/users/steamuser/Documents/Game*" -prune -o -print | wc -l)"
first_prefix="$WINEPREFIX"
STEAM_COMPAT_DATA_PATH="$case_root/next-game"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
copy_template_into_prefix
check test ! "$first_prefix/drive_c/windows/ntdll.dll" -ef "$WINEPREFIX/drive_c/windows/ntdll.dll"
printf changed > "$first_prefix/drive_c/windows/ntdll.dll"
printf changed >> "$first_prefix/system.reg"
check test "$(cat "$template_dir/pfx/drive_c/windows/ntdll.dll")" = dll
check test "$(cat "$WINEPREFIX/drive_c/windows/ntdll.dll")" = dll
check test "$(cat "$template_dir/pfx/system.reg")" = reg
check test "$(cat "$WINEPREFIX/system.reg")" = reg

# Killed after it put $1 entries in, or with $2 set, between linking a file in and removing
# its staged name: the launch and its merge both die on the spot.
kill_seed_after() {
  env functions="$functions" moves="$1" on_rm="${2:-}" /bin/sh -c "
    eval \"\$functions\"
    die() { kill -KILL \"\$\$\"; exec /usr/bin/true; }
    count() {
      [ \"\$moves\" -gt 0 ] || die
      moves=\$((moves - 1))
    }
    mv() { count; command mv \"\$@\"; }
    ln() {
      for destination; do :; done
      case \"\$destination\" in */.notproton-seed-link) ;; *) count ;; esac
      command ln \"\$@\"
    }
    rm() { if [ -n \"\$on_rm\" ] && [ \"\$1\" = -f ]; then die; fi; command rm \"\$@\"; }
    copy_template_into_prefix
  "
}
seeded_whole() {
  test -f "$WINEPREFIX/system.reg" && test -f "$WINEPREFIX/.update-timestamp" \
    && test "$(cat "$WINEPREFIX/drive_c/windows/ntdll.dll")" = dll \
    && test "$(readlink "$WINEPREFIX/drive_c/users/crossover")" = steamuser \
    && test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav")" = save \
    && test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 0
}
for moved in 0 1 2; do
  fixture
  mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
  printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
  interrupted_status=0
  { kill_seed_after "$moved"; } 2>/dev/null || interrupted_status=$?
  check test "$interrupted_status" -eq 137
  check test ! -e "$WINEPREFIX/system.reg"
  check test -f "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
  check test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 1
  seed_prefix_from_template
  check seeded_whole
  check grep -q 'finished seeding this prefix' "$log"
done

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
{ kill_seed_after 99 on-rm; } 2>/dev/null || true
check test "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*/user.reg -ef "$WINEPREFIX/user.reg"
check test ! -e "$WINEPREFIX/system.reg"
finish_dead_seeds
check seeded_whole
check grep -q 'finished seeding this prefix' "$log"

# A save that appears after the check is never replaced by the template's file.
fixture
mkdir -p "$template_dir/pfx/drive_c/users/steamuser/Documents/Game" \
  "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf template > "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/slot.sav"
(
  eval 'ln() {
    for destination; do :; done
    case "$destination" in */pfx/drive_c/users/steamuser/Documents/Game/slot.sav)
      printf player > "$destination" ;;
    esac
    command ln "$@"
  }'
  copy_template_into_prefix
) 2>/dev/null
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav")" = player
check test ! -e "$WINEPREFIX/system.reg"

# A folder that appears where a file or link goes is left as the player made it.
for entry in file link; do
  fixture
  profile="$WINEPREFIX/drive_c/users/steamuser"
  mkdir -p "$template_dir/pfx/drive_c/users/steamuser/Documents/Game" "$profile/Documents/Game"
  printf template > "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/slot.sav"
  [ "$entry" = file ] && racing="$profile/Documents/Game/slot.sav" || racing="$profile/My Documents"
  (
    eval 'ln() {
      for destination; do :; done
      [ "$destination" != "$racing" ] || mkdir "$destination"
      command ln "$@"
    }'
    copy_template_into_prefix
  ) 2>/dev/null
  check test -d "$racing"
  check test "$(find "$racing" | wc -l | tr -d ' ')" = 1
  check test ! -e "$WINEPREFIX/system.reg"
done

# A link the player already had in that folder stays.
fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game"
(
  eval 'ln() {
    for destination; do :; done
    if [ "$destination" = "$profile/My Documents" ]; then
      mkdir "$destination" && command ln -s ./Documents "$destination/Documents"
    fi
    command ln "$@"
  }'
  copy_template_into_prefix
) 2>/dev/null
check test "$(readlink "$profile/My Documents/Documents")" = ./Documents
check test ! -e "$WINEPREFIX/system.reg"

# Nor does a folder that appears after the check end up holding the template's inside it.
fixture
mkdir -p "$template_dir/pfx/drive_c/users/steamuser/Documents/Game" \
  "$WINEPREFIX/drive_c/users/steamuser/Documents"
printf template > "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/default.ini"
(
  eval 'mv() {
    for destination; do :; done
    case "$destination" in */pfx/drive_c/users/steamuser/Documents/Game)
      mkdir "$destination" && printf player > "$destination/slot.sav" ;;
    esac
    command mv "$@"
  }'
  copy_template_into_prefix
) 2>/dev/null
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav")" = player
check test ! -e "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/Game"
check test ! -e "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/default.ini"
check test ! -e "$WINEPREFIX/system.reg"
check test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 0

# Killed right after mv put the folder inside the one that appeared, before it could check:
# the next launch puts it back and merges it with the player's.
fixture
mkdir -p "$template_dir/pfx/drive_c/users/steamuser/Documents/Game" \
  "$WINEPREFIX/drive_c/users/steamuser/Documents"
printf template > "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/default.ini"
env functions="$functions" /bin/sh -c "
  eval \"\$functions\"
  mv() {
    for destination; do :; done
    case \"\$destination\" in */pfx/drive_c/users/steamuser/Documents/Game)
      mkdir \"\$destination\" && printf player > \"\$destination/slot.sav\"
      command mv \"\$@\"
      kill -KILL \"\$\$\"
      exec /usr/bin/true ;;
    esac
    command mv \"\$@\"
  }
  copy_template_into_prefix
" 2>/dev/null || true
check test -e "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/Game"
finish_dead_seeds
check test ! -e "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/Game"
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav")" = player
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/default.ini")" = template
check test -f "$WINEPREFIX/system.reg"
check test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 0

# A prefix rebuilt since the seed was killed is seeded again, not finished with the leftovers.
fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
{ kill_seed_after 1; } 2>/dev/null || true
mv "$WINEPREFIX" "$case_root/old-pfx"
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
finish_dead_seeds
check prefix_is_bare
copy_template_into_prefix
check seeded_whole
check test ! -e "$case_root/old-pfx/system.reg"
check test "$(grep -c 'finished seeding this prefix' "$log" || true)" = 0
check grep -q 'dropped pfx.seeding.[0-9]*, an earlier launch.s unfinished seed: it was for a prefix that has been replaced since' "$log"

# Killed while cloning, before the merge: the prefix was never touched.
fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
/bin/sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$dead"
printf partial > "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$dead/system.reg"
finish_dead_seeds
check grep -q "dropped pfx.seeding.$dead, an earlier launch's unfinished seed: it stopped before it moved anything in" "$log"
check prefix_is_bare
copy_template_into_prefix
check seeded_whole
check test "$(cat "$WINEPREFIX/system.reg")" = reg

for signal in TERM:143 INT:130 HUP:129; do
  fixture
  mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
  printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
  interrupted_status=0
  env functions="$functions" signal="${signal%:*}" status="${signal#*:}" /bin/sh -c "
    eval \"\$functions\"
    mv() { command mv \"\$@\"; kill -\"\$signal\" \"\$\$\"; }
    trap \"abandon_seed \$status\" \"\$signal\"
    copy_template_into_prefix
  " || interrupted_status=$?
  check test "$interrupted_status" -eq "${signal#*:}"
  check seeded_whole
done

fixture
mkdir -p "$template_dir/pfx.building.$$"
printf partial > "$template_dir/pfx.building.$$/system.reg"
rm -rf "$template_dir/pfx"
check test "$(build_prefix_template && echo accepted || echo refused)" = refused
check test ! -e "$template_dir/pfx"

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game" "$profile/My Documents/Game"
printf modern > "$profile/Documents/Game/slot.sav"
printf legacy > "$profile/My Documents/Game/slot.sav"
check test "$(lay_out_proton_profile && echo accepted || echo refused)" = refused
check test "$(cat "$profile/Documents/Game/slot.sav")" = modern
check test "$(cat "$profile/My Documents/Game/slot.sav")" = legacy
check test ! -L "$profile/My Documents"

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game" "$profile/My Documents BACKUP/Game"
ln -s ./Documents "$profile/My Documents"
printf save > "$profile/My Documents BACKUP/Game/slot.sav"
lay_out_proton_profile
check test ! -e "$profile/Documents/Game/slot.sav"
check test -f "$profile/My Documents BACKUP/Game/slot.sav"

fixture
mkdir -p "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$"
printf stale > "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$/system.reg"
copy_template_into_prefix
check test ! -e "$WINEPREFIX/system.reg"
check test "$(cat "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$/system.reg")" = stale
check test ! -e "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$/pfx"

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents" "$profile/My Documents BACKUP/Game"
ln -s ./Documents "$profile/My Documents"
ln -s "$case_root/offline" "$profile/Documents/Game"
printf historical > "$profile/My Documents BACKUP/Game/slot.sav"
check lay_out_proton_profile
check test -L "$profile/Documents/Game"
check test "$(readlink "$profile/Documents/Game")" = "$case_root/offline"

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf original > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save"
(
  eval 'cp() { return 1; }'
  copy_template_into_prefix
)
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save")" = original
check test ! -e "$WINEPREFIX/system.reg"

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf original > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save"
(
  eval 'mv() { return 1; }'
  copy_template_into_prefix
)
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save")" = original
check test ! -e "$WINEPREFIX/system.reg"
check test ! -e "$WINEPREFIX/drive_c/windows"
check test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 0

# Attaches a fresh disk image of file system $1 at $work/mnt.$2.
attach_image() {
  [ -f "$work/$2.dmg" ] \
    || /usr/bin/hdiutil create -quiet -size 32m -fs "$1" -volname "np-$2" "$work/$2.dmg" || return 1
  mkdir -p "$work/mnt.$2"
  /usr/bin/hdiutil attach -quiet -nobrowse -mountpoint "$work/mnt.$2" "$work/$2.dmg"
}
no_image() {
  printf '  FAIL could not attach a %s disk image, %s did not run\n' "$1" "$2"
  fails=$((fails + 1))
}

# A library on another volume, here HFS+, gets a full copy that shares nothing with the template.
fixture
if ! attach_image HFS+ hfs; then
  no_image HFS+ "the other-volume seed"
else
  check test "$(stat -f %d "$work/mnt.hfs")" != "$(stat -f %d "$template_dir")"
  STEAM_COMPAT_DATA_PATH="$work/mnt.hfs/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
  printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
  copy_template_into_prefix
  check seeded_whole
  check grep -q 'copied this prefix from the .* template, not a clone' "$log"
  check test "$(stat -f %l "$WINEPREFIX/drive_c/windows/ntdll.dll")" = 1
  printf changed > "$WINEPREFIX/drive_c/windows/ntdll.dll"
  check test "$(cat "$template_dir/pfx/drive_c/windows/ntdll.dll")" = dll
  /usr/bin/hdiutil detach -quiet -force "$work/mnt.hfs"
fi

# An external drive can come back with another device number: a seed killed on it is still
# finished by the next launch.
fixture
if ! attach_image HFS+ drive; then
  no_image HFS+ "the re-plugged drive seed"
else
  STEAM_COMPAT_DATA_PATH="$work/mnt.drive/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
  printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
  { kill_seed_after 1; } 2>/dev/null || true
  check test ! -e "$WINEPREFIX/system.reg"
  plugged=$(stat -f %d "$work/mnt.drive")
  /usr/bin/hdiutil detach -quiet -force "$work/mnt.drive"
  # Another disk takes the drive's old device node while it is away.
  attach_image HFS+ other || true
  if ! attach_image HFS+ drive; then
    no_image HFS+ "the re-plugged drive seed"
  else
    check test "$(stat -f %d "$work/mnt.drive")" != "$plugged"
    finish_dead_seeds
    check seeded_whole
    check grep -q 'finished seeding this prefix' "$log"
    /usr/bin/hdiutil detach -quiet -force "$work/mnt.drive"
  fi
  [ ! -d "$work/mnt.other" ] || /usr/bin/hdiutil detach -quiet -force "$work/mnt.other" 2>/dev/null || true
fi

# A volume without hard links (exFAT) is left as it was, so Wine builds the prefix as before.
# The prefix is empty: macOS gives every entry made on exFAT a ._ companion, which a prefix
# holding saves already fails prefix_is_bare on.
fixture
if ! attach_image ExFAT exfat; then
  no_image exFAT "the seed without hard links"
else
  STEAM_COMPAT_DATA_PATH="$work/mnt.exfat/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX"
  check prefix_is_bare
  copy_template_into_prefix
  check grep -q 'this volume has no hard links' "$log"
  check test -z "$(ls -A "$WINEPREFIX")"
  # Killed right after it recorded the prefix: the next launch has nothing to finish there.
  : > "$log"
  { env functions="$functions" /bin/sh -c "
    eval \"\$functions\"
    stat() {
      command stat \"\$@\"
      [ \"\$2:\$3\" != \"%i:\$WINEPREFIX\" ] || { kill -KILL \"\$\$\"; exec /usr/bin/true; }
    }
    copy_template_into_prefix
  "; } 2>/dev/null || true
  finish_dead_seeds
  check test -z "$(ls -A "$WINEPREFIX")"
  check test "$(grep -c 'finished seeding this prefix' "$log" || true)" = 0
  check test "$(find "$STEAM_COMPAT_DATA_PATH" -maxdepth 1 -name 'pfx.seeding.*' | wc -l | tr -d ' ')" = 0
  /usr/bin/hdiutil detach -quiet -force "$work/mnt.exfat"
fi

# A conflict anywhere moves nothing in.
fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf original > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save"
printf file > "$WINEPREFIX/drive_c/users/steamuser/AppData"
copy_template_into_prefix
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save")" = original
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/AppData")" = file
check test ! -e "$WINEPREFIX/drive_c/windows"
check test ! -e "$WINEPREFIX/system.reg"
check test ! -e "$WINEPREFIX/drive_c/users/steamuser/Desktop"

# The player's files win over the template's, as they always did.
fixture
mkdir -p "$template_dir/pfx/drive_c/users/steamuser/Documents/Game" \
  "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf template > "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/save"
printf template > "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/other"
printf player > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save"
copy_template_into_prefix
check test -f "$WINEPREFIX/system.reg"
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save")" = player
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/other")" = template
check test "$(cat "$template_dir/pfx/drive_c/users/steamuser/Documents/Game/save")" = template

fixture
mkdir -p "$WINEPREFIX/dosdevices"
ln -s ../drive_c "$WINEPREFIX/dosdevices/c:"
ln -s / "$WINEPREFIX/dosdevices/z:"
check prefix_is_bare
ln -s /outside "$WINEPREFIX/dosdevices/d:"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
mkdir -p "$WINEPREFIX/dosdevices" "$template_dir/pfx/dosdevices"
for dir in "$WINEPREFIX" "$template_dir/pfx"; do
  ln -s ../drive_c "$dir/dosdevices/c:"
  ln -s / "$dir/dosdevices/z:"
done
ln -s /library "$WINEPREFIX/dosdevices/s:"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused
printf '/elsewhere\n' > "$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused
printf '/library\n' > "$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
check prefix_is_bare
copy_template_into_prefix
check test -f "$WINEPREFIX/system.reg"
check test "$(readlink "$WINEPREFIX/dosdevices/s:")" = /library
check test "$(readlink "$WINEPREFIX/dosdevices/c:")" = ../drive_c

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser"
mkfifo "$WINEPREFIX/drive_c/users/steamuser/fifo"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
export WINEDLLOVERRIDES=leak WINEARCH=win32 WINEMSYNC=1 SteamAppId=123
isolated=$(in_template_env "$WINEPREFIX" /usr/bin/env)
check test "$(printf '%s\n' "$isolated" | grep -Ec '^(WINEDLLOVERRIDES|WINEARCH|WINEMSYNC|SteamAppId)=' || true)" = 0

fixture
prepare_prefix_directory
probe_lock() {
  env functions="$functions" /bin/sh -c "
    exec 8>&- 9>&-
    eval \"\$functions\"
    prepare_prefix_directory && echo unlocked || echo locked
  "
}
check test "$(probe_lock)" = locked
exec 8>&-
check prepare_prefix_directory
exec 8>&-

cat > "$work/daemonize" <<'STUB'
#!/bin/sh
sleep 30 &
echo "$!" > "$1"
STUB
chmod +x "$work/daemonize"

fixture
prepare_prefix_directory
"$work/daemonize" "$case_root/leaked.pid"
exec 8>&-
check test "$(probe_lock)" = locked
kill "$(cat "$case_root/leaked.pid")" 2>/dev/null || true

fixture
prepare_prefix_directory
without_lock_fds "$work/daemonize" "$case_root/held.pid"
exec 8>&-
check test "$(probe_lock)" = unlocked
kill "$(cat "$case_root/held.pid")" 2>/dev/null || true

fixture
mkdir -p "$STEAM_COMPAT_DATA_PATH/pfx.replaced.123"
printf save > "$STEAM_COMPAT_DATA_PATH/pfx.replaced.123/save"
recovery_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  show_alert() { :; }
  prepare_prefix_directory
  : > \"\$STEAM_COMPAT_DATA_PATH/continued\"
" || recovery_status=$?
check test "$recovery_status" -eq 1
check test ! -e "$STEAM_COMPAT_DATA_PATH/continued"
check test -f "$STEAM_COMPAT_DATA_PATH/pfx.replaced.123/save"

fixture
identity_before=$(template_identity)
printf changed > "$CX_ROOT/share/wine/wine.inf"
check test "$identity_before" != "$(template_identity)"
identity_before=$(template_identity)
printf '\n' >> "$np_tool_dir/run"
check test "$identity_before" != "$(template_identity)"

export fake_initializer="in_template_env() (
  if [ \"\$3\" = wineboot ]; then
    mkdir -p \"\$1/drive_c/windows\"
    printf system > \"\$1/system.reg\"
    printf user > \"\$1/user.reg\"
    printf defaults > \"\$1/userdef.reg\"
    printf dll > \"\$1/drive_c/windows/ntdll.dll\"
    if [ -n \"\${ready_pipe:-}\" ]; then
      printf ready > \"\$ready_pipe\"
      read -r proceed < \"\$resume_pipe\"
    fi
    return \"\${fake_init_status:-0}\"
  fi
  return \"\${fake_wait_status:-0}\"
)"
eval "$fake_initializer"

fixture
rm -rf "$template_dir/pfx"
export fake_init_status=1
check test "$(build_prefix_template && echo accepted || echo refused)" = refused
check test ! -e "$template_dir/pfx"
fake_init_status=0
export fake_wait_status=1
check test "$(build_prefix_template && echo accepted || echo refused)" = refused
check test ! -e "$template_dir/pfx"
fake_wait_status=0

fixture
set -- dosbox.exe -conf '.\base\plutoniam.conf'
seed_prefix_from_template
check test -f "$WINEPREFIX/system.reg"
check test "$#" -eq 3
check test "$3" = '.\base\plutoniam.conf'
set --

fixture
seed_prefix_from_template
check test -f "$WINEPREFIX/system.reg"
check test -f "$template_dir/ready"
check test ! -e "$STEAM_COMPAT_DATA_PATH/pfx.replaced.$$"
first_prefix="$WINEPREFIX"
printf first-game > "$first_prefix/system.reg"
printf obsolete > "$template_dir/pfx/obsolete"
printf updated-inf > "$CX_ROOT/share/wine/wine.inf"
STEAM_COMPAT_DATA_PATH="$case_root/next-game"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
seed_prefix_from_template
check test "$(cat "$first_prefix/system.reg")" = first-game
check test "$(cat "$WINEPREFIX/system.reg")" = system
check test ! -e "$template_dir/pfx/obsolete"
check test ! -e "$WINEPREFIX/obsolete"

fixture
export ready_pipe="$case_root/ready" resume_pipe="$case_root/resume"
mkfifo "$ready_pipe" "$resume_pipe"
first_prefix="$WINEPREFIX"
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  prepare_prefix_directory
  seed_prefix_from_template
" &
builder=$!
read -r ready < "$ready_pipe" || true
check test "$ready" = ready
STEAM_COMPAT_DATA_PATH="$case_root/second"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
unset ready_pipe resume_pipe
seed_prefix_from_template
check test ! -e "$WINEPREFIX/system.reg"
printf 'continue\n' > "$case_root/resume"
wait "$builder"
check test -f "$first_prefix/system.reg"
seed_prefix_from_template
check test -f "$WINEPREFIX/system.reg"
check test "$(find "$template_dir" -maxdepth 2 -name 'pfx.building.*' | wc -l | tr -d ' ')" = 0

# A template that lands while this one builds is kept, and the build leaves nothing behind.
fixture
export ready_pipe="$case_root/ready" resume_pipe="$case_root/resume"
mkfifo "$ready_pipe" "$resume_pipe"
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  rm -rf \"\$template_dir/pfx\"
  build_prefix_template
" &
builder=$!
read -r ready < "$ready_pipe" || true
check test "$ready" = ready
mkdir -p "$template_dir/pfx"
printf existing > "$template_dir/pfx/system.reg"
printf 'continue\n' > "$case_root/resume"
wait "$builder"
unset ready_pipe resume_pipe
check test "$(cat "$template_dir/pfx/system.reg")" = existing
check test "$(find "$template_dir" -maxdepth 2 -name 'pfx.building.*' | wc -l | tr -d ' ')" = 0

fixture
chmod 500 "$case_root"
cache_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  seed_prefix_from_template
" || cache_status=$?
chmod 700 "$case_root"
check test "$cache_status" -eq 0
check test ! -e "$WINEPREFIX/system.reg"

fixture
: > "$case_root/.notproton-template.lock"
chmod 400 "$case_root/.notproton-template.lock"
cache_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  seed_prefix_from_template
" || cache_status=$?
chmod 600 "$case_root/.notproton-template.lock"
check test "$cache_status" -eq 0
check test ! -e "$WINEPREFIX/system.reg"

fixture
seed_prefix_from_template
printf stale > "$template_dir/ready"
chmod 500 "$template_dir"
STEAM_COMPAT_DATA_PATH="$case_root/second"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
cache_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  seed_prefix_from_template
" || cache_status=$?
chmod 700 "$template_dir"
check test "$cache_status" -eq 0
check test ! -e "$WINEPREFIX/system.reg"
check test "$(cat "$template_dir/ready")" = stale

printf 'seedcheck: %s failures\n' "$fails"
test "$fails" -eq 0
