#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "==> launchercheck: $SRC not present, skipped"; exit 0; }

funcs=$(sed -n '/^bundle_listing() {$/,/^install_bundle$/p' "$SRC" | sed '$d')
name_lines=$(sed -n '/^bundle_name=\$(printf/,/^\[ -n "\$bundle_name" \] || bundle_name=/p' "$SRC")
launcher_body=$(sed -n '/^cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC" | sed 1d)
loader_line=$(grep -A1 '^if \[ -x "\$loader_macos/wine" \]; then$' "$SRC" | sed -n 2p)
[ -n "$funcs" ] || { echo "FAIL: bundle functions not found"; exit 1; }
[ -n "$name_lines" ] || { echo "FAIL: bundle name lines not found"; exit 1; }
[ -n "$launcher_body" ] || { echo "FAIL: launcher script not found"; exit 1; }
# A busy lock is waited out for 30 s; the lock contention case below needs it to give up.
funcs=$(printf '%s\n' "$funcs" | sed 's|/usr/bin/lockf -s -t 30 7|/usr/bin/lockf -s -t 1 7|')
printf '%s\n' "$funcs" | grep -q 'lockf -s -t 1 7' || { echo "FAIL: bundle lock wait not found"; exit 1; }
eval "$funcs"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/runner"
printf 'a' > "$T/runner/a.so"
printf 'b' > "$T/runner/b.so"
log="$T/log"
loader_root="$T/launchers"
mkdir -p "$loader_root"

stage() {
  loader_app="$loader_root/$1.app"
  loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
  loader_stage="$loader_work/new/$1.app"
  mkdir -p "$loader_stage/Contents/MacOS" "$loader_stage/Contents/Resources"
  printf '%s' "${2:-plist}" > "$loader_stage/Contents/Info.plist"
  printf 'icon' > "$loader_stage/Contents/Resources/game.icns"
  ln -sfn "$T/runner/${3:-a.so}" "$loader_stage/Contents/MacOS/x.so"
  printf '#!/bin/sh\n' > "$loader_stage/Contents/MacOS/launcher"
  chmod "${4:-755}" "$loader_stage/Contents/MacOS/launcher"
  : > "$log"
}
build() {
  stage "$@"
  install_bundle
}
apps() { (cd "$loader_root" && for b in *.app; do [ -e "$b" ] && printf '%s|' "$b"; done; true); }
plist_inode() { stat -f %i "$loader_app/Contents/Info.plist"; }
# The lock is free once install_bundle returns. A loaded host has been seen to report it busy
# for a moment anyway, so name the holders and allow 5 s; a leaked lock stays held.
lock_free() {
  /usr/bin/lockf -s -t 0 "$loader_root/.lock" true && return 0
  echo "  note  lock busy right after install_bundle; holders:"
  lsof "$loader_root/.lock" 2>&1 | sed 's/^/          /' || true
  /usr/bin/lockf -s -t 5 "$loader_root/.lock" true
}
leftover() { (cd "$loader_root" && n=0 && for b in .build.*; do [ -e "$b" ] && n=$((n + 1)); done; echo "$n"); }

echo "== final paths =="
case "$launcher_body" in *loader_stage*|*loader_contents*|*loader_macos*|*loader_work*) bad "launcher has no staging paths" "none" "staging path" ;; *) ok "launcher has no staging paths" ;; esac
is "WINELOADER points at the installed bundle" '  WINELOADER="$loader_app/Contents/MacOS/wine"' "$loader_line"

echo "== bundle names =="
for pair in '.hack//G.U. Last Recode|hackG.U. Last Recode' '...|Steam Game' '//|Steam Game' 'Half-Life 2|Half-Life 2' 'a.b|a.b'; do
  game_name=${pair%%|*}
  eval "$name_lines"
  is "name [${pair%%|*}]" "${pair#*|}" "$bundle_name"
done

echo "== first launch =="
build "Game"
is "bundle created" "Game.app|" "$(apps)"
is "logged as updated" "launcher bundle updated" "$(cat "$log")"
is "work folder removed" "0" "$(leftover)"

echo "== same content =="
before=$(plist_inode)
build "Game"
is "logged as unchanged" "launcher bundle unchanged" "$(cat "$log")"
is "bundle kept in place" "$before" "$(plist_inode)"
is "work folder removed" "0" "$(leftover)"

echo "== changes replace the bundle =="
build "Game" "plist2"
is "plist change" "launcher bundle updated" "$(cat "$log")"
is "new plist in place" "plist2" "$(cat "$loader_app/Contents/Info.plist")"
build "Game" "plist2" "b.so"
is "symlink target change" "launcher bundle updated" "$(cat "$log")"
is "new symlink in place" "$T/runner/b.so" "$(readlink "$loader_app/Contents/MacOS/x.so")"
build "Game" "plist2" "b.so" 644
is "mode change" "launcher bundle updated" "$(cat "$log")"
build "Game" "plist2" "b.so" 644
is "then unchanged" "launcher bundle unchanged" "$(cat "$log")"
rm "$loader_app/Contents/Resources/game.icns"
build "Game" "plist2" "b.so" 644
is "missing file" "launcher bundle updated" "$(cat "$log")"

echo "== renames =="
build "Other Name"
is "old name removed" "Other Name.app|" "$(apps)"
build "OTHER NAME"
is "case-only rename" "OTHER NAME.app|" "$(apps)"
is "case-only rename replaced" "launcher bundle updated" "$(cat "$log")"
build "OTHER NAME"
is "then unchanged" "launcher bundle unchanged" "$(cat "$log")"

echo "== stray bundles =="
mkdir -p "$loader_root/Stray.app"
build "OTHER NAME"
is "stray removed when unchanged" "OTHER NAME.app|" "$(apps)"
is "still unchanged" "launcher bundle unchanged" "$(cat "$log")"

mkdir -p "$loader_root/.Hidden.app"
build "OTHER NAME"
is "hidden stray removed when unchanged" "0" "$(find "$loader_root" -maxdepth 1 -name '.Hidden.app' | wc -l | tr -d ' ')"
mkdir -p "$loader_root/.Hidden.app"
build "OTHER NAME" "plist3"
is "hidden stray removed when updated" "0" "$(find "$loader_root" -maxdepth 1 -name '.Hidden.app' | wc -l | tr -d ' ')"
build "OTHER NAME"

echo "== awkward names =="
name='Sonic Adventure™ 2 [x]*? '
build "$name"
build "$name"
is "glob characters and trailing space" "launcher bundle unchanged" "$(cat "$log")"
is "only that bundle" "$name.app|" "$(apps)"

echo "== hardlink and copy compare equal =="
mkdir -p "$T/a" "$T/b"
printf 'wine' > "$T/loader"
ln "$T/loader" "$T/a/wine"
cp "$T/loader" "$T/b/wine"
is "same listing" "$(bundle_listing "$T/a")" "$(bundle_listing "$T/b")"

echo "== lock =="
build "OTHER NAME"
if lock_free; then ok "lock released"; else bad "lock released" "free" "held"; fi

echo "== case twin =="
rm -rf "$loader_root"/*.app
mkdir -p "$loader_root/Twin.APP"
if [ -d "$loader_root/Twin.app" ]; then
  build "Twin"
  is "twin replaced" "Twin.app|" "$(apps)"
else
  ok "volume is case-sensitive, skipped"
fi

echo "== symlinked bundle =="
mkdir -p "$T/elsewhere.app"
rm -rf "$loader_root"/*.app
ln -s "$T/elsewhere.app" "$loader_root/Linked.app"
build "Linked"
is "symlink replaced by a real bundle" "launcher bundle updated" "$(cat "$log")"
if [ -L "$loader_root/Linked.app" ]; then bad "not a symlink" "dir" "symlink"; else ok "not a symlink"; fi
if [ -d "$T/elsewhere.app" ]; then ok "symlink target untouched"; else bad "symlink target untouched" "present" "gone"; fi

echo "== lock contention =="
build "Original"
before=$(plist_inode)
stage "Replacement"
exec 8>> "$loader_root/.lock"
/usr/bin/lockf -s -t 0 8
if (exec 8>&-; install_bundle); then
  bad "busy lock refuses installation" "failure" "success"
else
  ok "busy lock refuses installation"
fi
is "locked bundle untouched" "$before" "$(stat -f %i "$loader_root/Original.app/Contents/Info.plist")"
is "no replacement without lock" "Original.app|" "$(apps)"
exec 8>&-
install_bundle
is "retry after unlock succeeds" "Replacement.app|" "$(apps)"

echo "== rollback =="
for failure in install backup signal signal-installed missing-stage restore; do
  build "Original"
  before=$(plist_inode)
  mkdir -p "$loader_root/.Hidden.app" "$loader_root/Stray.app"
  stage "Replacement"
  staged_inode=$(stat -f %i "$loader_stage/Contents/Info.plist")
  if env funcs="$funcs" failure="$failure" loader_root="$loader_root" loader_app="$loader_app" \
      loader_work="$loader_work" loader_stage="$loader_stage" log="$log" /bin/sh -c '
    set -e
    eval "$funcs"
    mv() {
      case "$failure" in
        install|restore) [ "$1" != "$loader_stage" ] || return 1 ;;
        backup) [ "$1" != "$loader_root/Stray.app" ] || return 1 ;;
        missing-stage)
          if [ "$1" = "$loader_stage" ]; then rm -rf "$loader_stage"; return 1; fi ;;
      esac
      if [ "$failure" = restore ]; then
        case "$1" in "$loader_root"/.backup.*/Original.app) return 1 ;; esac
      fi
      command mv "$@" || return 1
      if [ "$failure" = signal ] && [ "$1" = "$loader_root/Original.app" ]; then
        /bin/sh -c '\''kill -TERM "$PPID"'\''
      fi
      if [ "$failure" = signal-installed ] && [ "$1" = "$loader_stage" ]; then
        /bin/sh -c '\''kill -TERM "$PPID"'\''
      fi
    }
    install_bundle
  '; then
    bad "$failure reports failure" "failure" "success"
  else
    ok "$failure reports failure"
  fi
  if [ "$failure" = signal-installed ]; then
    is "signal after rename keeps new bundle" "$staged_inode" "$(plist_inode)"
    is "signal after rename does not nest old bundles" "Replacement.app|" "$(apps)"
    is "signal after rename cleans staging" "0" "$(leftover)"
    if lock_free; then ok "$failure releases lock"; else bad "$failure releases lock" "free" "held"; fi
    continue
  fi
  if [ "$failure" = restore ]; then
    is "failed rollback preserves backup" "$before" "$(stat -f %i "$loader_root"/.backup.*/Original.app/Contents/Info.plist)"
    mv "$loader_root"/.backup.*/Original.app "$loader_root/Original.app"
    rmdir "$loader_root"/.backup.*
  fi
  is "$failure keeps original name and inode" "$before" "$(stat -f %i "$loader_root/Original.app/Contents/Info.plist")"
  is "$failure restores visible bundles" "Original.app|Stray.app|" "$(apps)"
  if [ -d "$loader_root/.Hidden.app" ]; then ok "$failure keeps hidden bundle"; else bad "$failure keeps hidden bundle" "present" "missing"; fi
  if lock_free; then ok "$failure releases lock"; else bad "$failure releases lock" "free" "held"; fi
  is "$failure cleans staging" "0" "$(leftover)"
done

echo "== launch Dock icon =="
icon_funcs=$(sed -n '/^find_client_root() {$/,/^case "\$verb" in$/p' "$SRC" | sed '$d')
icon_lines=$(sed -n '/^icon_arg=""$/,/^\[ -n "\$icon_arg" \] ||/p' "$SRC")
[ -n "$icon_funcs" ] && [ -n "$icon_lines" ] || { echo "FAIL: launch icon code not found"; exit 1; }
eval "$icon_funcs"
np_support="$T/support"
iconmaker="$np_support/iconmaker"
mkdir -p "$np_support" "$T/steam/appcache/librarycache/100"
printf '#!/bin/sh\nprintf "icon=abc123\\n"\n' > "$np_support/appinfo"
printf '#!/bin/sh\ncp "$1" "$2"\n' > "$iconmaker"
chmod 755 "$np_support/appinfo" "$iconmaker"
mkdir -p "$T/steam/appcache/appinfo"
printf 'game art' > "$T/steam/appcache/librarycache/100/abc123.jpg"
app_id=100
target=""
find_client_root "$T/steam/Steam.AppBundle/Steam/Contents/MacOS"
read_app_meta
loader_root="$T/launchers/100"
loader_res="$loader_root/new/Contents/Resources"
mkdir -p "$loader_res"
: > "$log"
eval "$icon_lines"
is "icon key set" "  <key>CFBundleIconFile</key><string>game</string>" "$icon_arg"
is "bundle gets the artwork" "game art" "$(cat "$loader_res/game.icns")"
is "artwork cached with the launcher" "game art" "$(cat "$loader_root/game.icns")"
is "artwork built" "icon built from $T/steam/appcache/librarycache/100/abc123.jpg" "$(cat "$log")"
rm -f "$iconmaker" "$loader_res/game.icns"
: > "$log"
eval "$icon_lines"
is "cached artwork reused" "icon reused from $T/steam/appcache/librarycache/100/abc123.jpg" "$(cat "$log")"
is "reused artwork copied" "game art" "$(cat "$loader_res/game.icns")"
rm "$T/steam/appcache/librarycache/100/abc123.jpg" "$loader_res/game.icns"
: > "$log"
eval "$icon_lines"
is "no artwork, no icon key" "" "$icon_arg"
is "no artwork logged" "no icon resolved, launching without one" "$(cat "$log")"
if [ -d "$np_support/shortcut-icons" ]; then bad "launch leaves shortcut cache alone" "absent" "present"; else ok "launch leaves shortcut cache alone"; fi

echo "== session lasts as long as the shim =="
session_trap=$(sed -n '/^terminate() {$/,/^trap terminate TERM INT HUP$/p' "$SRC")
# NotProton-WineHQ launches directly unless NOTPROTON_LAUNCH_SERVICES=1; the open branch is the one tested.
session_wait=$(sed -n '/^if \[ "\${NOTPROTON_LAUNCH_SERVICES:-0}" = "1" \]; then$/,/^exit \$status$/p' "$SRC")
[ -n "$session_trap" ] && [ -n "$session_wait" ] || { echo "FAIL: session code not found"; exit 1; }
{
  printf 'log=%s\nopen() { sleep "$1"; return "$2"; }\n' "$T/session.log"
  printf 'kill_wine_prefix() { echo kill >> "%s"; }\n' "$T/session.ev"
  printf 'exit_summary() { echo "summary $1 $3" >> "%s"; }\n' "$T/session.ev"
  printf '%s\n' "$session_trap"
  printf 'set -- "$1" "$2"\nloader_app=x\nnp_terminated=0\nNOTPROTON_LAUNCH_SERVICES=1\n'
  printf '%s\n' "$session_wait" | sed 's/open -n -W -a "\$loader_app" "\$@"/open "$@"/'
} > "$T/session.sh"
grep -q '^ *open "\$@"' "$T/session.sh" || { echo "FAIL: session launch line not rewritten"; exit 1; }
: > "$T/session.ev"
start=$(date +%s)
rc=0; sh "$T/session.sh" 3 7 || rc=$?
is "the shim's exit status is the session's" 7 "$rc"
is "the session waits for the shim" yes "$([ $(($(date +%s) - start)) -ge 3 ] && echo yes || echo no)"
is "the prefix is torn down once, then the exit is summed up" "kill
summary 7 0" "$(cat "$T/session.ev")"
: > "$T/session.ev"
start=$(date +%s)
sh "$T/session.sh" 30 0 & sp=$!
sleep 1
kill -TERM "$sp"
rc=0; wait "$sp" || rc=$?
is "exit game ends the session" 143 "$rc"
is "exit game does not wait out the shim" yes "$([ $(($(date +%s) - start)) -lt 5 ] && echo yes || echo no)"
is "exit game tears the prefix down" yes "$(grep -q kill "$T/session.ev" && echo yes || echo no)"
is "exit game is summed up as stopped from Steam" "summary 143 1" "$(grep summary "$T/session.ev")"

echo "== game mode: the bundle hosts the loader and ntdll =="
stage_func=$(sed -n '/^stage_loader() {$/,/^}$/p' "$SRC")
block_func=$(sed -n '/^block_loader_links() {$/,/^}$/p' "$SRC")
[ -n "$stage_func" ] && [ -n "$block_func" ] || { echo "FAIL: game mode functions not found"; exit 1; }
eval "$stage_func"
eval "$block_func"
cx="$T/cx"
wine_unix="$cx/lib/wine/x86_64-unix"
mkdir -p "$wine_unix" "$cx/lib/wine/x86_64-windows" "$cx/lib/wine/i386-windows" "$cx/share/wine" "$cx/bin"
printf 'loader' > "$wine_unix/wine"
printf 'ntdll' > "$wine_unix/ntdll.so"
printf 'mac' > "$wine_unix/winemac.so"
chmod 755 "$wine_unix/wine"
gm_stage() {
  loader_root="$T/gm"
  rm -rf "$loader_root"
  mkdir -p "$loader_root"
  stage Game
  rm -f "$loader_stage/Contents/MacOS/x.so"
  loader_macos="$loader_stage/Contents/MacOS"
  stage_loader
}
same() { if [ "$1" -ef "$2" ]; then echo yes; else echo no; fi; }
WINELOADER="$wine_unix/wine"
gm_stage
is "hosted" 1 "$loader_hosts_ntdll"
is "loader is a copy" "loader" "$(cat "$loader_macos/wine")"
is "loader has its own inode" no "$(same "$loader_macos/wine" "$wine_unix/wine")"
is "loader runs" yes "$([ -x "$loader_macos/wine" ] && echo yes || echo no)"
is "ntdll.so is the engine's file" yes "$(same "$loader_macos/ntdll.so" "$wine_unix/ntdll.so")"
is "ntdll.so is no symlink" no "$([ -L "$loader_macos/ntdll.so" ] && echo yes || echo no)"
is "other unix libraries are symlinks" "$wine_unix/winemac.so" "$(readlink "$loader_macos/winemac.so")"
is "x86_64-unix next to ntdll" "$wine_unix" "$(readlink "$loader_macos/x86_64-unix")"
is "x86_64-windows next to ntdll" "$cx/lib/wine/x86_64-windows" "$(readlink "$loader_macos/x86_64-windows")"
is "i386-windows next to ntdll" "$cx/lib/wine/i386-windows" "$(readlink "$loader_macos/i386-windows")"
is "share two levels up" "$cx/share" "$(readlink "$loader_stage/share")"
is "bin two levels up" "$cx/bin" "$(readlink "$loader_stage/bin")"
is "no temporary link left" no "$([ -e "$loader_macos/.ntdll.so" ] && echo yes || echo no)"
install_bundle
is "hosted bundle installed" "launcher bundle updated" "$(cat "$log")"
installed_loader=$(stat -f %i "$loader_app/Contents/MacOS/wine")
stage Game
rm -f "$loader_stage/Contents/MacOS/x.so"
loader_macos="$loader_stage/Contents/MacOS"
stage_loader
install_bundle
is "same engine keeps the bundle" "launcher bundle unchanged" "$(cat "$log")"
is "and its loader inode" "$installed_loader" "$(stat -f %i "$loader_app/Contents/MacOS/wine")"
mv "$wine_unix/ntdll.so" "$T/old-ntdll.so"
printf 'ntdll' > "$wine_unix/ntdll.so"
stage Game
rm -f "$loader_stage/Contents/MacOS/x.so"
loader_macos="$loader_stage/Contents/MacOS"
stage_loader
install_bundle
is "an engine reinstalled with equal bytes replaces it" "launcher bundle updated" "$(cat "$log")"
is "with the new ntdll.so" yes "$(same "$loader_app/Contents/MacOS/ntdll.so" "$wine_unix/ntdll.so")"

echo "== game mode: the bundle's loader is signed ad hoc =="
signed_id() { /usr/bin/codesign -dv "$1" 2>&1 | sed -n 's/^Identifier=//p'; }
cp /usr/bin/true "$wine_unix/wine"
/usr/bin/codesign --remove-signature "$wine_unix/wine"
gm_stage
is "unsigned loader: signed under the bundle's identifier" "com.notproton.launcher.$app_id" "$(signed_id "$loader_macos/wine")"
is "unsigned loader: the engine's file stays unsigned" no "$(/usr/bin/codesign -d "$wine_unix/wine" >/dev/null 2>&1 && echo yes || echo no)"
is "unsigned loader: nothing logged" "" "$(cat "$log")"
signed_sum=$(cksum < "$loader_macos/wine")
gm_stage
is "unsigned loader: the same bytes each launch" "$signed_sum" "$(cksum < "$loader_macos/wine")"
cp /usr/bin/true "$wine_unix/wine"
gm_stage
is "signed loader: keeps its own signature" "$(signed_id /usr/bin/true)" "$(signed_id "$loader_macos/wine")"
printf 'loader' > "$wine_unix/wine"
chmod 755 "$wine_unix/wine"

rm -rf "$cx/share/wine"
gm_stage
is "no data folder: not hosted" 0 "$loader_hosts_ntdll"
is "no data folder: loader hard link" yes "$(same "$loader_macos/wine" "$wine_unix/wine")"
is "no data folder: ntdll.so symlink" "$wine_unix/ntdll.so" "$(readlink "$loader_macos/ntdll.so")"
is "no data folder: no share link" no "$([ -L "$loader_stage/share" ] && echo yes || echo no)"
mkdir -p "$cx/share/wine"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
mkdir -p "${WINELOADER%/*}"
printf 'app loader' > "$WINELOADER"
gm_stage
is "wine.app loader: not hosted" 0 "$loader_hosts_ntdll"
is "wine.app loader: copied as before" "app loader" "$(cat "$loader_macos/wine")"
is "wine.app loader: ntdll.so symlink" "$wine_unix/ntdll.so" "$(readlink "$loader_macos/ntdll.so")"
rm -rf "$wine_unix/wine.app"
WINELOADER="$wine_unix/wine"

echo "== game mode: winetemp links blocked =="
# shellcheck disable=SC2329 # block_loader_links calls it
getconf() { printf '%s/\n' "$T/tmp"; }
mkdir -p "$T/tmp"
gm_loader="$T/gm-loader"
printf 'loader' > "$gm_loader"
touch -d 2026-01-02T03:04:05.012345678 "$gm_loader"
gm_dir="$T/tmp/winetemp-$(stat -f '%i-%z-%m' "$gm_loader")-12345678"
: > "$log"
block_loader_links "$gm_loader"
is "folder named as ntdll names it" yes "$([ -d "$gm_dir" ] && echo yes || echo no)"
is "folder read-only" 500 "$(stat -f %Lp "$gm_dir")"
is "logged" "loader links blocked in $gm_dir" "$(cat "$log")"
chmod 700 "$gm_dir"
ln "$gm_loader" "$gm_dir/Game"
ln -s "$gm_loader" "$gm_dir/.hidden"
block_loader_links "$gm_loader"
is "links made earlier are removed" "" "$(ls -A "$gm_dir")"
is "and the folder is read-only again" 500 "$(stat -f %Lp "$gm_dir")"
touch -d 2026-01-02T03:04:05 "$gm_loader"
block_loader_links "$gm_loader"
is "whole seconds end in 0" yes "$([ -d "$T/tmp/winetemp-$(stat -f '%i-%z-%m' "$gm_loader")-0" ] && echo yes || echo no)"
touch -d 2026-01-02T03:04:05.000000500 "$gm_loader"
block_loader_links "$gm_loader"
is "leading zeros of the nanoseconds dropped" yes "$([ -d "$T/tmp/winetemp-$(stat -f '%i-%z-%m' "$gm_loader")-500" ] && echo yes || echo no)"
chmod -R 700 "$T/tmp"
unset -f getconf

echo "== reuse of the last good launch's bundle =="
reuse_funcs=""
for name in own_note stamp_key bundle_inputs bundle_reusable bundle_record; do
  body=$(sed -n "/^$name() {\$/,/^}\$/p" "$SRC")
  [ -n "$body" ] || { echo "FAIL: $name not found"; exit 1; }
  reuse_funcs="$reuse_funcs
$body"
done
eval "$reuse_funcs"
np_uid=$(id -u)
np_stamps=1
app_id=4242
unset SteamGameId
R="$T/reuse"
# A fresh engine, staged bundle files and an installed bundle that matches them, recorded.
reuse_fresh() {
  rm -rf "$R"
  wine_unix="$R/engine/lib/wine/x86_64-unix"
  mkdir -p "$wine_unix" "$R/engine/bin" "$R/engine/share/wine" "$R/support" "$R/staged/Contents/Resources"
  printf 'ntdll' > "$wine_unix/ntdll.so"
  printf '#!/bin/sh\n' > "$R/engine/bin/wine"
  chmod 755 "$R/engine/bin/wine"
  WINELOADER="$R/engine/bin/wine"
  bundle_engine_loader=$WINELOADER
  np_support="$R/support"
  np_stamp_base="base"
  loader_contents="$R/staged/Contents"
  loader_res="$loader_contents/Resources"
  printf 'plist gamemode=1' > "$loader_contents/Info.plist"
  printf 'icon' > "$loader_res/game.icns"
  loader_root="$R/launchers"
  loader_app="$loader_root/Game.app"
  bundle_stamp="$loader_root/.bridgeplay-bundle-stamp"
  mkdir -p "$loader_app/Contents/MacOS" "$loader_app/Contents/Resources"
  cp "$WINELOADER" "$loader_app/Contents/MacOS/wine"
  printf '#!/bin/sh\n' > "$loader_app/Contents/MacOS/launcher"
  chmod 755 "$loader_app/Contents/MacOS/launcher"
  ln "$wine_unix/ntdll.so" "$loader_app/Contents/MacOS/ntdll.so"
  cp "$loader_contents/Info.plist" "$loader_app/Contents/Info.plist"
  cp "$loader_res/game.icns" "$loader_app/Contents/Resources/game.icns"
  loader_hosts_ntdll=1
  bundle_record "${1:-0}"
}
reused() { if bundle_reusable; then echo yes; else echo no; fi; }

reuse_fresh
rm -f "$bundle_stamp"
is "no stamp: built again" no "$(reused)"
reuse_fresh 0
is "a recorded bundle is reused" yes "$(reused)"
bundle_reusable || true
is "and says Launch Services has not seen it" "0 1" "$bundle_registered $bundle_hosts"
reuse_fresh 1
bundle_reusable || true
is "a registered bundle says so" 1 "$bundle_registered"
reuse_fresh 0
bundle_reusable || true
is "a second check still reuses it" yes "$(reused)"

reuse_fresh
printf 'more' >> "$WINELOADER"
is "the engine's loader changed: built again" no "$(reused)"
reuse_fresh
mkdir -p "$R/other"
cp "$WINELOADER" "$R/other/wine"
bundle_engine_loader="$R/other/wine"
is "another engine's loader: built again" no "$(reused)"
reuse_fresh
printf 'more' >> "$wine_unix/ntdll.so"
is "the engine's ntdll.so changed: built again" no "$(reused)"
reuse_fresh
rm "$loader_app/Contents/MacOS/ntdll.so"
cp "$wine_unix/ntdll.so" "$loader_app/Contents/MacOS/ntdll.so"
bundle_record 0
is "a bundle whose ntdll.so is no longer the engine's: built again" no "$(reused)"

reuse_fresh
printf 'echo hi\n' >> "$loader_app/Contents/MacOS/launcher"
is "a launcher file edited: built again" no "$(reused)"
reuse_fresh
chmod 700 "$loader_app/Contents/MacOS/launcher"
is "a launcher file's mode changed: built again" no "$(reused)"
reuse_fresh
printf 'x' > "$loader_app/Contents/MacOS/extra"
is "a file added to the bundle: built again" no "$(reused)"
reuse_fresh
chmod 644 "$loader_app/Contents/MacOS/wine"
bundle_record 0
is "a bundle loader that can't run: built again" no "$(reused)"

reuse_fresh
printf 'new icon' > "$loader_res/game.icns"
is "a new icon: built again" no "$(reused)"
reuse_fresh
rm "$loader_res/game.icns"
is "the icon gone: built again" no "$(reused)"
reuse_fresh
printf 'plist gamemode=0' > "$loader_contents/Info.plist"
is "a settings change in the Info.plist: built again" no "$(reused)"
reuse_fresh
np_stamp_base="base changed"
is "a new launch base (script, engine, prefix): built again" no "$(reused)"

reuse_fresh
mkdir -p "$loader_root/Other.app"
is "another bundle beside it: built again" no "$(reused)"
reuse_fresh
np_stamps=0
is "launch stamps off: built again" no "$(reused)"
np_stamps=1
reuse_fresh
mv "$bundle_stamp" "$R/stamp"
ln -s "$R/stamp" "$bundle_stamp"
is "a stamp that is a symlink: built again" no "$(reused)"
reuse_fresh
sed 's/^hosts=.*/hosts=2/' "$bundle_stamp" > "$R/stamp" && cat "$R/stamp" > "$bundle_stamp"
is "a stamp with a bad hosts value: built again" no "$(reused)"
reuse_fresh
sed "s|^loader=.*|loader=$R/elsewhere/wine|" "$bundle_stamp" > "$R/stamp" && cat "$R/stamp" > "$bundle_stamp"
is "a stamp naming another loader: built again" no "$(reused)"

echo "== started bare (Spotlight, the Games app) =="
game_id_func=$(sed -n '/^shortcut_game_id() {$/,/^}$/p' "$SRC")
bare_lines=$(sed -n '/^bare_game_id=\$app_id$/,/^case "\$bare_game_id" in/p' "$SRC")
[ -n "$game_id_func" ] && [ -n "$bare_lines" ] || { echo "FAIL: bare start lines not found"; exit 1; }
eval "$game_id_func"
for spec in '440||exec /usr/bin/open steam://rungameid/440' \
            '440|440|exec /usr/bin/open steam://rungameid/440' \
            '3355443|14411517982146560|exec /usr/bin/open steam://rungameid/14411517982146560' \
            '0||exit 1' '0|12345|exit 1'; do
  app_id=${spec%%|*} rest=${spec#*|}
  SteamGameId=${rest%%|*}
  eval "$bare_lines"
  is "app $app_id, game ID [$SteamGameId]" "${rest#*|}" "$bare_start"
done
unset SteamGameId
launcher_heredoc=$(sed -n '/^cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC")
bare_dir="$T/bare"
mkdir -p "$bare_dir/Contents/MacOS"
printf '#!/bin/sh\nprintf "ran %%s" "$*"\n' > "$bare_dir/wine"
chmod +x "$bare_dir/wine"
WINELOADER="$bare_dir/wine" loader_root="$bare_dir" np_support="$bare_dir" loader_macos="$bare_dir/Contents/MacOS" \
  bare_start="exit 7" body="$launcher_heredoc" sh -ec 'eval "$body"'
chmod +x "$bare_dir/Contents/MacOS/launcher"
status=0
"$bare_dir/Contents/MacOS/launcher" || status=$?
is "no arguments: the bare start runs" 7 "$status"
is "and the wine log is not touched" no "$([ -e "$bare_dir/bridgeplay-wine.log" ] && echo yes || echo no)"
"$bare_dir/Contents/MacOS/launcher" game.exe -x || true
is "with arguments: Wine runs the game" "ran game.exe -x" "$(cat "$bare_dir/bridgeplay-wine.log")"
rm -f "$bare_dir/bridgeplay-wine.log"
WINELOADER="$bare_dir/wine" loader_root="$bare_dir" np_support="$bare_dir" loader_macos="$bare_dir/Contents/MacOS" \
  bare_start="" body="$launcher_heredoc" sh -ec 'eval "$body"'
status=0
"$bare_dir/Contents/MacOS/launcher" || status=$?
is "no bare start set: exits 1 without running Wine" "1 no" "$status $([ -e "$bare_dir/bridgeplay-wine.log" ] && echo yes || echo no)"

echo "== a launch files older Steam shortcuts with games =="
category_loop=$(sed -n '/^for shortcut in "\$HOME"\/Applications\/\*\.app; do$/,/^done$/p' "$SRC")
[ -n "$category_loop" ] || { echo "FAIL: shortcut category loop not found"; exit 1; }
cat_home="$T/cat-home"
for name in Game Other Filed; do mkdir -p "$cat_home/Applications/$name.app/Contents/MacOS"; done
printf '#!/bin/bash\n# autogenerated file - do not edit\n\nopen steam://run/440\n\n' > "$cat_home/Applications/Game.app/Contents/MacOS/run.sh"
printf '#!/bin/bash\n# autogenerated file - do not edit\n\nopen steam://run/4400\n\n' > "$cat_home/Applications/Other.app/Contents/MacOS/run.sh"
printf '#!/bin/bash\n# autogenerated file - do not edit\n\nopen steam://run/570\n\n' > "$cat_home/Applications/Filed.app/Contents/MacOS/run.sh"
printf '<key>LSApplicationCategoryType</key>' > "$cat_home/Applications/Filed.app/Contents/Info.plist"
iconmaker="$T/cat-iconmaker"
printf '#!/bin/sh\nprintf "%%s " "$@" >> "%s/calls"\n' "$T" > "$iconmaker"
chmod +x "$iconmaker"
category_run() { : > "$T/calls"; (HOME=$cat_home app_id=$1; eval "$category_loop"); cat "$T/calls"; }
is "a shortcut without the category: iconmaker runs once" "--games-category 440 " "$(category_run 440)"
is "no shortcut for the game: nothing runs" "" "$(category_run 44)"
is "already filed: nothing runs" "" "$(category_run 570)"
rm -rf "$cat_home/Applications"
is "no Applications folder: nothing runs" "" "$(category_run 440)"

[ "$fails" -eq 0 ] || { echo "launchercheck: $fails failed"; exit 1; }
echo "launchercheck: all passed"
