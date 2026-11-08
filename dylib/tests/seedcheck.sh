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
# A volume just written to can stay busy for a moment, and CI then fails with EBUSY.
detach_image() {
  tries=0
  until /usr/bin/hdiutil detach -quiet -force "$1"; do
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || return 1
    sleep 1
  done
}
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
  detach_image "$work/mnt.hfs"
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
  detach_image "$work/mnt.drive"
  # Another disk takes the drive's old device node while it is away.
  attach_image HFS+ other || true
  if ! attach_image HFS+ drive; then
    no_image HFS+ "the re-plugged drive seed"
  else
    check test "$(stat -f %d "$work/mnt.drive")" != "$plugged"
    finish_dead_seeds
    check seeded_whole
    check grep -q 'finished seeding this prefix' "$log"
    detach_image "$work/mnt.drive"
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
  detach_image "$work/mnt.exfat"
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

# The WineHQ engine is stock Wine, which names the profile after the Mac user while Steam
# Cloud syncs steamuser (#2618). That name is folded into steamuser and linked there.
notify_user() { printf '%s\n' "$1" >> "$case_root/notified"; }
saved_user=${USER:-}
USER=tester
np_build=winehq-11.15

fixture
check test "$(readlink "$template_dir/pfx/drive_c/users/tester")" = steamuser
check test "$(prefix_is_bare && echo bare || echo refused)" = bare
lay_out_proton_profile
check test "$(readlink "$WINEPREFIX/drive_c/users/tester")" = steamuser
check test "$(prefix_is_bare && echo bare || echo refused)" = bare

# A prefix an earlier launch split: the game's saves under the Mac user, Steam Cloud's under
# steamuser, Wine's links out to the home folders, and a copy that differs on each side.
split_prefix() {
  users="$WINEPREFIX/drive_c/users"
  mine="$users/tester/AppData/LocalLow/Perfect_Random/Sulfur"
  cloud="$users/steamuser/AppData/LocalLow/Perfect_Random/Sulfur"
  mkdir -p "$mine/deep" "$cloud" "$case_root/home/Documents" "$users/tester/Saved Games/Other"
  printf local > "$mine/Sulfur_SaveSlot_2.sss"
  printf mac > "$mine/settings.json"
  printf same > "$mine/same.txt"
  printf deep > "$mine/deep/inner.sav"
  printf other > "$users/tester/Saved Games/Other/slot.sav"
  printf cloud > "$cloud/Sulfur_SaveSlot_1.sss"
  printf steam > "$cloud/settings.json"
  printf same > "$cloud/same.txt"
  ln -s "$case_root/home/Documents" "$users/tester/Documents"
}
# A fresh prefix laid out as before the fix, then split.
split_fixture() {
  fixture
  lay_out_proton_profile
  rm "$WINEPREFIX/drive_c/users/tester"
  split_prefix
}
split_fixture
check lay_out_proton_profile
check test "$(readlink "$users/tester")" = steamuser
check test "$(cat "$cloud/Sulfur_SaveSlot_1.sss")" = cloud
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss")" = local
check test "$(cat "$cloud/settings.json")" = steam
check test "$(cat "$cloud/settings.json BACKUP")" = mac
check test "$(cat "$cloud/same.txt")" = same
check test ! -e "$cloud/same.txt BACKUP"
check test "$(cat "$cloud/deep/inner.sav")" = deep
check test "$(cat "$users/steamuser/Saved Games/Other/slot.sav")" = other
check test ! -L "$users/steamuser/Documents"
check test "$(readlink "$users/tester BACKUP/Documents")" = "$case_root/home/Documents"
check grep -q "kept both copies, this one as: .*settings.json BACKUP" "$log"
check test "$(wc -l < "$case_root/notified" | tr -d ' ')" = 1
check lay_out_proton_profile
check test "$(find "$users" -name '*BACKUP*' | wc -l | tr -d ' ')" = 2
check test "$(wc -l < "$case_root/notified" | tr -d ' ')" = 1

# Wine linked the profile's Documents to the Mac's. What a game saved there stays there,
# and the player is told so even when nothing else needed keeping.
split_fixture
mkdir -p "$case_root/home/Documents/Game"
printf mine > "$case_root/home/Documents/Game/slot.sav"
rm "$mine/settings.json"
check lay_out_proton_profile
check test "$(cat "$case_root/home/Documents/Game/slot.sav")" = mine
check test "$(readlink "$users/tester BACKUP/Documents")" = "$case_root/home/Documents"
check grep -qF "tester/Documents led to $case_root/home/Documents, whose files stay there" "$log"
check test "$(wc -l < "$case_root/notified" | tr -d ' ')" = 1

# Old folder names are merged through steamuser's links to their new ones, but a link that
# leads out of the profile is never followed.
split_fixture
mkdir -p "$users/tester/My Documents/Game" "$users/tester/Application Data/Roam" \
  "$users/tester/Local Settings/Application Data/Loc" "$users/tester/Away" "$case_root/outside"
printf docs > "$users/tester/My Documents/Game/slot.sav"
printf roam > "$users/tester/Application Data/Roam/slot.sav"
printf loc > "$users/tester/Local Settings/Application Data/Loc/slot.sav"
printf away > "$users/tester/Away/slot.sav"
ln -s "$case_root/outside" "$users/steamuser/Away"
check lay_out_proton_profile
check test "$(cat "$users/steamuser/Documents/Game/slot.sav")" = docs
check test "$(cat "$users/steamuser/AppData/Roaming/Roam/slot.sav")" = roam
check test "$(cat "$users/steamuser/AppData/Local/Loc/slot.sav")" = loc
check test ! -e "$users/steamuser/My Documents BACKUP"
check test "$(cat "$users/steamuser/Away BACKUP/slot.sav")" = away
check test -z "$(ls "$case_root/outside")"

# Names that end in a space or a tab move, and their note is cleared.
split_fixture
printf space > "$mine/trailing "
printf tab > "$mine/tab	"
mkdir -p "$mine/folder "
printf inner > "$mine/folder /slot.sav"
mkdir -p "$cloud/folder "
check lay_out_proton_profile
check test "$(cat "$cloud/trailing ")" = space
check test "$(cat "$cloud/tab	")" = tab
check test "$(cat "$cloud/folder /slot.sav")" = inner
check test ! -e "$users/.notproton-fold-moving"
check test "$(readlink "$users/tester")" = steamuser

# A line break would split the note, so that name stays where it is and the launch stops.
split_fixture
printf broken > "$mine/line
break.sav"
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
check test "$(cat "$mine/line
break.sav")" = broken
check test ! -e "$users/.notproton-fold-moving"
check grep -q 'has a line break in its name' "$log"
rm "$mine/line
break.sav"
check lay_out_proton_profile
check test "$(readlink "$users/tester")" = steamuser

# A file that cannot move stops the launch with everything still on one side or the other.
split_fixture
chmod 500 "$mine"
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
chmod 700 "$mine"
check test -d "$users/tester" -a ! -L "$users/tester"
check test "$(cat "$mine/settings.json")" = mac
check test "$(cat "$cloud/settings.json")" = steam
check lay_out_proton_profile
check test "$(readlink "$users/tester")" = steamuser
check test "$(cat "$cloud/settings.json BACKUP")" = mac

# An unreadable folder looks empty: it stops the launch instead of leaving the profile.
split_fixture
mkdir -p "$users/tester/AppData/LocalLow/Perfect_Random/Sulfur/deep/locked"
printf locked > "$mine/deep/locked/slot.sav"
mkdir -p "$cloud/deep/locked"
chmod 000 "$mine/deep/locked"
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
chmod 700 "$mine/deep/locked"
check test -d "$users/tester" -a ! -L "$users/tester"
check test "$(cat "$mine/deep/locked/slot.sav")" = locked
check lay_out_proton_profile
check test "$(cat "$cloud/deep/locked/slot.sav")" = locked

# A name taken between the check and the move: mv would put the save inside a folder that
# appeared there, or not move it past a file. Either way it stays where it was.
split_fixture
# shellcheck disable=SC2329 # fold_move calls it in place of mv
mv() {
  for destination; do :; done
  case "$destination" in
    */steamuser/*/Sulfur_SaveSlot_2.sss) mkdir -p "$destination" ;;
    *"/settings.json BACKUP") printf other > "$destination" ;;
  esac
  command mv "$@"
}
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
unset -f mv
check test "$(cat "$mine/Sulfur_SaveSlot_2.sss")" = local
check test "$(cat "$mine/settings.json")" = mac
check test ! -e "$cloud/Sulfur_SaveSlot_2.sss/Sulfur_SaveSlot_2.sss"
check test "$(cat "$cloud/settings.json BACKUP")" = other
rmdir "$cloud/Sulfur_SaveSlot_2.sss"
check lay_out_proton_profile
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss")" = local
check test "$(cat "$cloud/settings.json BACKUP 2")" = mac

# Killed right after mv put a save inside a folder that appeared at its name: the next
# launch puts it back before it folds anything, and it is kept beside that folder.
split_fixture
killed=0
/usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV' env functions="$functions" /bin/sh -c '
  eval "$functions"
  notify_user() { :; }
  mv() {
    for destination; do :; done
    case "$destination" in */steamuser/*/Sulfur_SaveSlot_2.sss)
      mkdir -p "$destination"
      command mv "$@"
      kill -KILL 0 ;;
    esac
    command mv "$@"
  }
  lay_out_proton_profile
' 2>/dev/null || killed=$?
check test "$killed" -ne 0
check test -f "$cloud/Sulfur_SaveSlot_2.sss/Sulfur_SaveSlot_2.sss"
check test -f "$users/.notproton-fold-moving"
check lay_out_proton_profile
check test ! -e "$cloud/Sulfur_SaveSlot_2.sss/Sulfur_SaveSlot_2.sss"
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss BACKUP")" = local
check test ! -e "$users/.notproton-fold-moving"
check grep -q "put back tester/.*Sulfur_SaveSlot_2.sss" "$log"

# A nested move that cannot be put back keeps its note: no later move may overwrite it,
# so the next launch still finds the save.
split_fixture
# shellcheck disable=SC2329 # fold_move calls it in place of mv
mv() {
  for destination; do :; done
  case "$destination" in */steamuser/*/Sulfur_SaveSlot_2.sss)
    mkdir -p "$destination"
    command mv "$@"
    chmod 500 "$destination"
    return ;;
  esac
  command mv "$@"
}
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
unset -f mv
chmod 700 "$cloud/Sulfur_SaveSlot_2.sss"
check test "$(sed -n 2p "$users/.notproton-fold-moving")" = "tester/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss"
check test -d "$mine"
check lay_out_proton_profile
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss BACKUP")" = local
check test "$(cat "$cloud/settings.json BACKUP")" = mac
check test ! -e "$users/.notproton-fold-moving"

# A killed launch can leave the note's source folder gone: putting it back makes it again.
split_fixture
mkdir "$cloud/Sulfur_SaveSlot_2.sss"
printf '%s\n%s\n%s\n' "$(stat -f %i "$mine/Sulfur_SaveSlot_2.sss")" \
  tester/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss \
  steamuser/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss \
  > "$users/.notproton-fold-moving"
command mv "$mine/Sulfur_SaveSlot_2.sss" "$cloud/Sulfur_SaveSlot_2.sss/"
rm -rf "$users/tester/AppData/LocalLow/Perfect_Random"
check lay_out_proton_profile
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss BACKUP")" = local
check test ! -e "$users/.notproton-fold-moving"

# A note is only cleared once the file is found where its move left it or where it began.
# Behind a folder that cannot be searched, the launch stops and the note stays.
split_fixture
mkdir "$cloud/Sulfur_SaveSlot_2.sss"
printf '%s\n%s\n%s\n' "$(stat -f %i "$mine/Sulfur_SaveSlot_2.sss")" \
  tester/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss \
  steamuser/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss \
  > "$users/.notproton-fold-moving"
command mv "$mine/Sulfur_SaveSlot_2.sss" "$cloud/Sulfur_SaveSlot_2.sss/"
chmod 000 "$cloud/Sulfur_SaveSlot_2.sss"
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
chmod 700 "$cloud/Sulfur_SaveSlot_2.sss"
check test -f "$users/.notproton-fold-moving"
check lay_out_proton_profile
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss BACKUP")" = local
check test ! -e "$users/.notproton-fold-moving"

# A folder that appears at the source before the put-back takes the save inside it. The
# note stays, so launches stop rather than fold the save in from the wrong place.
split_fixture
mkdir "$cloud/Sulfur_SaveSlot_2.sss"
printf '%s\n%s\n%s\n' "$(stat -f %i "$mine/Sulfur_SaveSlot_2.sss")" \
  tester/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss \
  steamuser/AppData/LocalLow/Perfect_Random/Sulfur/Sulfur_SaveSlot_2.sss \
  > "$users/.notproton-fold-moving"
command mv "$mine/Sulfur_SaveSlot_2.sss" "$cloud/Sulfur_SaveSlot_2.sss/"
# shellcheck disable=SC2329 # fold_unnest calls it in place of mv
mv() {
  for destination; do :; done
  case "$destination" in */tester/*/Sulfur_SaveSlot_2.sss) mkdir -p "$destination" ;; esac
  command mv "$@"
}
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
unset -f mv
check test "$(lay_out_proton_profile && echo launched || echo stopped)" = stopped
check test -f "$users/.notproton-fold-moving"
check test "$(cat "$mine/Sulfur_SaveSlot_2.sss/Sulfur_SaveSlot_2.sss")" = local
check grep -q "is not where its move left it" "$log"

# The note names paths inside users, so it still matches once the library has moved. One
# that cannot be read is only a note: it is dropped and the launch goes on.
split_fixture
printf '%s\n%s\n%s\n' "$(stat -f %i "$mine/settings.json")" \
  tester/AppData/LocalLow/Perfect_Random/Sulfur/settings.json \
  "steamuser/AppData/LocalLow/Perfect_Random/Sulfur/settings.json BACKUP" \
  > "$users/.notproton-fold-moving"
command mv "$STEAM_COMPAT_DATA_PATH" "$case_root/moved"
STEAM_COMPAT_DATA_PATH="$case_root/moved"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
users="$WINEPREFIX/drive_c/users"
cloud="$users/steamuser/AppData/LocalLow/Perfect_Random/Sulfur"
check lay_out_proton_profile
check test "$(cat "$cloud/settings.json BACKUP")" = mac
check test ! -e "$users/.notproton-fold-moving"
split_fixture
printf 'garbage\n/etc\n../../x\n' > "$users/.notproton-fold-moving"
check lay_out_proton_profile
check test "$(cat "$cloud/Sulfur_SaveSlot_2.sss")" = local
check test ! -e "$users/.notproton-fold-moving"
check grep -q "dropped an unreadable note" "$log"

# A case-sensitive volume keeps names apart that Wine reads as one.
if ! attach_image "Case-sensitive APFS" folds; then
  no_image "case-sensitive APFS" "the case-sensitive fold"
else
  fixture
  STEAM_COMPAT_DATA_PATH="$work/mnt.folds/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX"
  lay_out_proton_profile
  rm "$WINEPREFIX/drive_c/users/tester"
  users="$WINEPREFIX/drive_c/users"
  mkdir -p "$users/tester/AppData/LocalLow/perfect_random" "$users/steamuser/AppData/LocalLow/Perfect_Random"
  printf mac > "$users/tester/AppData/LocalLow/perfect_random/slot.sav"
  printf cloud > "$users/steamuser/AppData/LocalLow/Perfect_Random/Slot.sav"
  check lay_out_proton_profile
  check test ! -e "$users/steamuser/AppData/LocalLow/perfect_random"
  check test "$(cat "$users/steamuser/AppData/LocalLow/Perfect_Random/Slot.sav")" = cloud
  check test "$(cat "$users/steamuser/AppData/LocalLow/Perfect_Random/Slot.sav BACKUP")" = mac
  # A library folder whose name has a line that looks like the folder being looked for.
  fixture
  STEAM_COMPAT_DATA_PATH="$work/mnt.folds/A
saves
B/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX"
  lay_out_proton_profile
  rm "$WINEPREFIX/drive_c/users/tester"
  users="$WINEPREFIX/drive_c/users"
  mkdir -p "$users/tester/AppData/saves" "$users/steamuser/AppData/SAVES"
  printf mac > "$users/tester/AppData/saves/two.sav"
  printf cloud > "$users/steamuser/AppData/SAVES/one.sav"
  check lay_out_proton_profile
  check test ! -e "$users/steamuser/AppData/saves"
  check test "$(cat "$users/steamuser/AppData/SAVES/two.sav")" = mac
  detach_image "$work/mnt.folds" || true
fi

# CrossOver's lineage names its profile crossover: a folder under the Mac user is left be.
np_build=winecx-11.17
fixture
lay_out_proton_profile
check test ! -e "$WINEPREFIX/drive_c/users/tester"
check test ! -e "$template_dir/pfx/drive_c/users/tester"
mkdir -p "$WINEPREFIX/drive_c/users/tester/AppData"
printf mine > "$WINEPREFIX/drive_c/users/tester/AppData/save.sav"
check lay_out_proton_profile
check test ! -L "$WINEPREFIX/drive_c/users/tester"
check test "$(cat "$WINEPREFIX/drive_c/users/tester/AppData/save.sav")" = mine
np_build=fixture
USER=$saved_user

printf 'seedcheck: %s failures\n' "$fails"
test "$fails" -eq 0
