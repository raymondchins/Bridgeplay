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
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "a line with $2" "$(cat "$3")"; fi; }

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
: > "$T/steam/appcache/appinfo.vdf"
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

echo "== GTA San Andreas automatic preparation"
repo_root=$(cd "$(dirname "$SRC")/../.." && pwd)
gta_functions=""
for name in gta_sa_de_log gta_sa_de_call gta_sa_de_dxvk_ready gta_sa_de_dxgi_mode gta_sa_de_dxgi_conflict gta_sa_de_dxgi_match gta_sa_de_conflict gta_sa_de_run; do
	body=$(sed -n "/^$name() {\$/,/^}$/p" "$SRC")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	gta_functions="$gta_functions
$body"
done
hook_prefix=$(grep -n '^  refuse_broken_prefix$' "$SRC" | cut -d: -f1)
hook_call=$(grep -n '^  gta_sa_de_run$' "$SRC" | cut -d: -f1)
hook_backend=$(grep -n '^select_backend "\$1"$' "$SRC" | cut -d: -f1)
hook_count=$(grep -c '^  gta_sa_de_run$' "$SRC")
is "one workaround hook follows prefix validation before backend selection" yes \
	"$([ "$hook_count" -eq 1 ] && [ "$hook_prefix" -lt "$hook_call" ] && [ "$hook_call" -lt "$hook_backend" ] && echo yes || echo no)"

gta_fixture="$T/gta-sa-de"
mkdir -p "$gta_fixture/support"
cat > "$gta_fixture/make_fixture.py" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data
def pe(tag):
    image = bytearray(96 + len(tag))
    image[0:2] = b"MZ"
    image[60:64] = (64).to_bytes(4, "little")
    image[64:68] = b"PE\0\0"
    image[68:70] = (0x8664).to_bytes(2, "little")
    image[88:90] = (0x20b).to_bytes(2, "little")
    image[96:] = tag
    return bytes(image)
def sha(data):
    return hashlib.sha256(data).hexdigest()

exe = put(root / "game/Gameface/Binaries/Win64/SanAndreas.exe", pe(b"game"))
runner_dir = root / "runner/lib/notproton-backends/dxmt/x86_64-windows"
dlls = {}
for name in ("d3d11.dll", "dxgi.dll", "d3d10core.dll"):
    dlls[name] = put(runner_dir / name, pe(name.encode("ascii")))
wrapper = put(root / "wrapper.exe", b"fixture-socialclub-wrapper-v1")
license_data = put(root / "license.txt", b"fixture license text\n")
vendor1 = put(root / "vendor-v1.exe", b"fixture-socialclub-vendor-v1")
vendor2 = put(root / "vendor-v2.exe", b"fixture-socialclub-vendor-v2")
(root / "vendor1.sha").write_text(sha(vendor1), encoding="ascii")
manifest = {
    "schema": 1,
    "appid": "1547000",
    "engine": "winecx-11.17",
    "gameBuild": "16391096",
    "gameExecutable": "Gameface/Binaries/Win64/SanAndreas.exe",
    "gameExecutableSHA256": sha(exe),
    "gameExecutableSize": len(exe),
    "dxmtDirectory": "lib/notproton-backends/dxmt/x86_64-windows",
    "dxmtFiles": [{"name": name, "sha256": sha(data)} for name, data in dlls.items()],
    "helperDirectory": "drive_c/Program Files/Rockstar Games/Social Club",
    "helperName": "SocialClubHelper.exe",
    "realHelperName": "SocialClubHelper_real.exe",
    "helperChecksumName": "SocialClubHelper_real.exe.sha256",
    "helperLicenseName": "SocialClubHelper.bridgeplay.LICENSE",
    "helperWrapperSHA256": sha(wrapper),
    "helperLicenseSHA256": sha(license_data),
    "supportedVendorHelpers": [
        {"version": "fixture-v1", "sha256": sha(vendor1)},
        {"version": "fixture-v2", "sha256": sha(vendor2)},
    ],
}
(root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY
python3 "$gta_fixture/make_fixture.py" "$gta_fixture"
python3 "$repo_root/scripts/embed-gta-sa-assets.py" \
	--manifest "$gta_fixture/manifest.json" --wrapper "$gta_fixture/wrapper.exe" \
	--license "$gta_fixture/license.txt" --output "$gta_fixture/GTAFixPrepAssets.swift"
swiftc -O -o "$gta_fixture/support/gamefix-prep" \
	"$repo_root/helpers/gamefix-prep.swift" "$repo_root/helpers/gamefix-transaction.swift" \
	"$gta_fixture/GTAFixPrepAssets.swift"
swiftc -O -D GTA_FIXTURE_CRASH -o "$gta_fixture/support/gamefix-prep-crash" \
	"$repo_root/helpers/gamefix-prep.swift" "$repo_root/helpers/gamefix-transaction.swift" \
	"$gta_fixture/GTAFixPrepAssets.swift"

eval "$gta_functions"
backend_available() { [ "$1" = dxvk ] && [ -f "$gta_fixture/runner/dxvk.available" ]; }
show_alert() { echo "alert: $1" >> "$log"; }
touch "$gta_fixture/runner/dxvk.available"
mkdir -p "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows"
printf 'fixture dxvk d3d11' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll"
printf 'fixture dxvk d3d10core' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
gta_game="$gta_fixture/game"
gta_runner="$gta_fixture/runner"
gta_helper="$gta_fixture/support/gamefix-prep"
gta_crash_helper="$gta_fixture/support/gamefix-prep-crash"
gta_helper_dir='drive_c/Program Files/Rockstar Games/Social Club'
gta_helper_call() {
	env GTA_SA_APP_ID=1547000 GTA_SA_DATA_PATH="$1" GTA_SA_PREFIX="$1/pfx" \
		GTA_SA_GAME="$2" GTA_SA_RUNNER="$gta_runner" GTA_SA_ENGINE_ID=winecx-11.17 \
		"$gta_helper" "$3"
}
gta_crash_helper_call() {
	env GAMEFIX_TEST_CRASH_AFTER="${4:-}" GAMEFIX_TEST_CRASH_PHASE="${5:-}" \
		GTA_SA_APP_ID=1547000 GTA_SA_DATA_PATH="$1" GTA_SA_PREFIX="$1/pfx" \
		GTA_SA_GAME="$2" GTA_SA_RUNNER="$gta_runner" GTA_SA_ENGINE_ID=winecx-11.17 \
		"$gta_crash_helper" "$3"
}
gta_seed_vendor() {
	seed_helper="$1/pfx/$gta_helper_dir"
	mkdir -p "$seed_helper"
	cp "$gta_fixture/vendor-v1.exe" "$seed_helper/SocialClubHelper.exe"
}
gta_seed_case() {
	seed_game="$1"
	seed_data="$2"
	mkdir -p "$seed_game/Gameface/Binaries/Win64" "$seed_data/pfx"
	cp "$gta_game/Gameface/Binaries/Win64/SanAndreas.exe" "$seed_game/Gameface/Binaries/Win64/SanAndreas.exe"
	gta_seed_vendor "$seed_data"
}
gta_paths() {
	STEAM_COMPAT_DATA_PATH=$1
	WINEPREFIX="$1/pfx"
	STEAM_COMPAT_INSTALL_PATH=$2
	CX_ROOT=$gta_runner
	np_build=${6:-winecx-11.17}
	np_support="$gta_fixture/support"
	app_id=${3:-1547000}
	verb=${4:-waitforexitandrun}
	NOTPROTON_GTA_SA_DE_FIX=${5:-1}
	NOTPROTON_BACKEND=""
	CX_GRAPHICS_BACKEND=""
	WINEDLLOVERRIDES=""
	gamefix_backend=""
	gamefix_from_BACKEND=""
	gamefix_dlloverrides=""
	gamefix_from_DLLOVERRIDES=""
}

echo "== hook routes only the main GTA launch"
gta_route_data="$gta_fixture/route-data"
mkdir -p "$gta_route_data/pfx"
gta_paths "$gta_route_data" "$gta_game" 1547000 run 1
gta_sa_de_run
is "Steam prerequisite verb is left untouched" 0 "$(find "$gta_route_data" -type f | wc -l | tr -d ' ')"
gta_paths "$gta_route_data" "$gta_game" 4242 waitforexitandrun 1
gta_sa_de_run
is "other AppIDs are left untouched" 0 "$(find "$gta_route_data" -type f | wc -l | tr -d ' ')"
gta_paths "$gta_route_data" "$gta_game" 1547000 waitforexitandrun 1 winehq-11.15
gta_sa_de_run
has "unsupported engine is skipped clearly" "supports WineCX 11.17" "$log"
is "unsupported engine does not mutate files" 0 "$(find "$gta_route_data" -type f | wc -l | tr -d ' ')"

echo "== missing DXVK does not block an unprepared game"
gta_no_dxvk_game="$gta_fixture/no-dxvk-game"
gta_no_dxvk_data="$gta_fixture/no-dxvk-data"
gta_seed_case "$gta_no_dxvk_game" "$gta_no_dxvk_data"
rm "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
: > "$log"
gta_paths "$gta_no_dxvk_data" "$gta_no_dxvk_game"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing DXVK component soft-skips fresh preparation" 0 "$gta_launch_rc"
has "missing DXVK component is logged" "preparation skipped: WineCX DXVK runtime is unavailable" "$log"
is "missing DXVK component leaves helper untouched" 1 "$(find "$gta_no_dxvk_data" -type f | wc -l | tr -d ' ')"
is "missing DXVK component installs no game DLLs" 0 "$(find "$gta_no_dxvk_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"
printf 'fixture dxvk d3d10core' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"

echo "== explicit graphics conflicts do not touch files"
gta_conflict_data="$gta_fixture/conflict-data"
mkdir -p "$gta_conflict_data/pfx"
gta_paths "$gta_conflict_data" "$gta_game"
gamefix_backend=dxmt gamefix_from_BACKEND=user
gta_sa_de_run
has "conflicting per-game backend is logged" "BACKEND=dxmt from the user config" "$log"
is "per-game backend conflict causes no writes" 0 "$(find "$gta_conflict_data" -type f | wc -l | tr -d ' ')"
gta_paths "$gta_conflict_data" "$gta_game"
NOTPROTON_BACKEND=dxmt
gta_sa_de_run
has "launch backend conflict is logged" "BRIDGEPLAY_BACKEND=dxmt in launch options" "$log"
gta_paths "$gta_conflict_data" "$gta_game"
CX_GRAPHICS_BACKEND=d3dmetal
gta_sa_de_run
has "Steam graphics choice conflict is logged" "CX_GRAPHICS_BACKEND=d3dmetal in launch options" "$log"
gta_paths "$gta_conflict_data" "$gta_game"
gamefix_dlloverrides='dinput8=n,b;dxgi=b'
gamefix_from_DLLOVERRIDES=user
gta_sa_de_run
has "user DXGI override conflict is logged" "DLLOVERRIDES from the user config" "$log"
gta_paths "$gta_conflict_data" "$gta_game"
gamefix_dlloverrides='dinput8=n,b;dxgi=b'
gamefix_from_DLLOVERRIDES=global
gta_sa_de_run
has "global DXGI override conflict is logged" "DLLOVERRIDES from the global config" "$log"
gta_paths "$gta_conflict_data" "$gta_game"
WINEDLLOVERRIDES='dxgi=b;d3d9=n,b'
gta_sa_de_run
has "launch DXGI override conflict is logged" "WINEDLLOVERRIDES in launch options" "$log"
is "all explicit graphics conflicts cause no writes" 0 "$(find "$gta_conflict_data" -type f | wc -l | tr -d ' ')"
gta_sa_de_dxgi_conflict 'dxgi=b;d3d9=n,b' && dxgi_conflict_after_unrelated=yes || dxgi_conflict_after_unrelated=no
is "unrelated trailing override does not hide DXGI conflict" yes "$dxgi_conflict_after_unrelated"
gta_sa_de_dxgi_conflict 'dxgi=n,b;d3d9=b' && dxgi_conflict_before_unrelated=yes || dxgi_conflict_before_unrelated=no
is "unrelated trailing override does not create DXGI conflict" no "$dxgi_conflict_before_unrelated"
gta_sa_de_dxgi_match 'd3d11,DXGI=N,B' && grouped_match=yes || grouped_match=no
is "grouped module names match case-insensitively" yes "$grouped_match"

echo "== unknown build status is read-only"
gta_unknown_game="$gta_fixture/unknown-game"
mkdir -p "$gta_unknown_game/Gameface/Binaries/Win64"
cp "$gta_game/Gameface/Binaries/Win64/SanAndreas.exe" "$gta_unknown_game/Gameface/Binaries/Win64/SanAndreas.exe"
printf 'unknown build' >> "$gta_unknown_game/Gameface/Binaries/Win64/SanAndreas.exe"
gta_unknown_data="$gta_fixture/unknown-data"
mkdir -p "$gta_unknown_data/pfx"
gta_unknown_rc=0
gta_unknown_result=$(gta_helper_call "$gta_unknown_data" "$gta_unknown_game" status 2>&1) || gta_unknown_rc=$?
is "unknown build status fails" nonzero "$([ "$gta_unknown_rc" -ne 0 ] && echo nonzero || echo 0)"
printf '%s\n' "$gta_unknown_result" > "$gta_fixture/unknown.log"
has "unknown build has a diagnostic" "unsupported-game-build" "$gta_fixture/unknown.log"
is "unknown build status writes no state" 0 "$(find "$gta_unknown_data" -type f | wc -l | tr -d ' ')"
gta_paths "$gta_unknown_data" "$gta_unknown_game"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "unsupported game build soft-skips the main launch" 0 "$gta_launch_rc"
has "unsupported game build is logged by the run hook" "automatic setup skipped: unsupported input (exit 3): gta-sa-de: unsupported-game-build" "$log"
is "skipped main launch still writes no game state" 0 "$(find "$gta_unknown_data" -type f | wc -l | tr -d ' ')"

echo "== unsupported input escalates when owned setup exists"
gta_owned_unknown_game="$gta_fixture/owned-unknown-game"
gta_owned_unknown_data="$gta_fixture/owned-unknown-data"
gta_seed_case "$gta_owned_unknown_game" "$gta_owned_unknown_data"
gta_owned_unknown_prepare=$(gta_helper_call "$gta_owned_unknown_data" "$gta_owned_unknown_game" prepare)
is "owned unknown-build fixture starts prepared" prepared "$gta_owned_unknown_prepare"
printf 'unknown build' >> "$gta_owned_unknown_game/Gameface/Binaries/Win64/SanAndreas.exe"
gta_owned_unknown_rc=0
gta_owned_unknown_result=$(gta_helper_call "$gta_owned_unknown_data" "$gta_owned_unknown_game" status 2>&1) || gta_owned_unknown_rc=$?
is "owned unsupported input status escalates to conflict" 4 "$gta_owned_unknown_rc"
printf '%s\n' "$gta_owned_unknown_result" > "$gta_fixture/owned-unknown.log"
has "owned unsupported input keeps its diagnostic" "unsupported-game-build" "$gta_fixture/owned-unknown.log"
gta_paths "$gta_owned_unknown_data" "$gta_owned_unknown_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "owned unsupported input remains a hard stop" 4 "$gta_launch_rc"
has "owned unsupported input exact status is logged" "status check failed (exit 4)" "$log"
gta_owned_unknown_restore=$(gta_helper_call "$gta_owned_unknown_data" "$gta_owned_unknown_game" restore)
is "restore remains available after a game update" restored "$gta_owned_unknown_restore"

echo "== CLI status codes retain hard-stop and fallback routing"
gta_mock_support="$gta_fixture/mock-support"
mkdir -p "$gta_mock_support"
cat > "$gta_mock_support/gamefix-prep" <<'MOCK'
#!/bin/sh
case "$1" in
  status)
    printf '%s\n' "${GTA_MOCK_STATUS_TEXT:-ready}"
    exit "${GTA_MOCK_STATUS_RC:-0}" ;;
  prepare)
    printf '%s\n' "${GTA_MOCK_PREPARE_TEXT:-prepared}"
    exit "${GTA_MOCK_PREPARE_RC:-0}" ;;
  restore)
    printf '%s\n' "${GTA_MOCK_RESTORE_TEXT:-restored}"
    exit "${GTA_MOCK_RESTORE_RC:-0}" ;;
esac
exit 64
MOCK
chmod +x "$gta_mock_support/gamefix-prep"
GTA_MOCK_STATUS_RC=3 GTA_MOCK_STATUS_TEXT='gta-sa-de: unsupported-game-build' GTA_MOCK_PREPARE_RC=0
GTA_MOCK_PREPARE_TEXT=prepared
export GTA_MOCK_STATUS_RC GTA_MOCK_STATUS_TEXT GTA_MOCK_PREPARE_RC GTA_MOCK_PREPARE_TEXT
gta_paths "$gta_fixture/mock-data-3" "$gta_game"
np_support=$gta_mock_support
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "mock status exit 3 soft-skips" 0 "$gta_launch_rc"
has "mock status exit 3 keeps its reason" "unsupported input (exit 3): gta-sa-de: unsupported-game-build" "$log"

GTA_MOCK_STATUS_RC=0 GTA_MOCK_STATUS_TEXT=ready
GTA_MOCK_PREPARE_RC=3 GTA_MOCK_PREPARE_TEXT='gta-sa-de: unsupported-vendor-helper'
export GTA_MOCK_STATUS_RC GTA_MOCK_STATUS_TEXT GTA_MOCK_PREPARE_RC GTA_MOCK_PREPARE_TEXT
gta_paths "$gta_fixture/mock-prepare-3" "$gta_game"
np_support=$gta_mock_support
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "mock prepare exit 3 after ready soft-skips" 0 "$gta_launch_rc"
has "mock prepare exit 3 records revalidation fallback" "skipped after revalidation: unsupported input (exit 3)" "$log"

for gta_mock_rc in 4 5; do
  GTA_MOCK_STATUS_RC=$gta_mock_rc GTA_MOCK_STATUS_TEXT="gta-sa-de: unsafe-state-$gta_mock_rc"
  export GTA_MOCK_STATUS_RC GTA_MOCK_STATUS_TEXT
  gta_paths "$gta_fixture/mock-status-$gta_mock_rc" "$gta_game"
  np_support=$gta_mock_support
  : > "$log"
  gta_launch_rc=0
  (gta_sa_de_run) || gta_launch_rc=$?
  is "mock status exit $gta_mock_rc is preserved" "$gta_mock_rc" "$gta_launch_rc"
  has "mock status exit $gta_mock_rc stays a hard stop" "status check failed (exit $gta_mock_rc)" "$log"
done

for gta_mock_rc in 4 5; do
  GTA_MOCK_STATUS_RC=0 GTA_MOCK_STATUS_TEXT=ready
  GTA_MOCK_PREPARE_RC=$gta_mock_rc GTA_MOCK_PREPARE_TEXT="gta-sa-de: transaction-failed-$gta_mock_rc"
  export GTA_MOCK_STATUS_RC GTA_MOCK_STATUS_TEXT GTA_MOCK_PREPARE_RC GTA_MOCK_PREPARE_TEXT
  gta_paths "$gta_fixture/mock-prepare-$gta_mock_rc" "$gta_game"
  np_support=$gta_mock_support
  : > "$log"
  gta_launch_rc=0
  (gta_sa_de_run) || gta_launch_rc=$?
  is "mock prepare exit $gta_mock_rc is preserved" "$gta_mock_rc" "$gta_launch_rc"
  has "mock prepare exit $gta_mock_rc stays a hard stop" "preparation failed (exit $gta_mock_rc)" "$log"
done

GTA_MOCK_RESTORE_RC=3 GTA_MOCK_RESTORE_TEXT='gta-sa-de: restore-input-error'
export GTA_MOCK_RESTORE_RC GTA_MOCK_RESTORE_TEXT
gta_paths "$gta_fixture/mock-restore-3" "$gta_game" 1547000 waitforexitandrun 0
np_support=$gta_mock_support
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "mock restore exit 3 remains strict during opt-out" 3 "$gta_launch_rc"
has "opt-out restore logs its exact exit code" "restore failed (exit 3): gta-sa-de: restore-input-error" "$log"

echo "== missing DXVK is strict for existing managed setup"
rm -f "$gta_fixture/runner/dxvk.available" \
	"$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
GTA_MOCK_STATUS_RC=0 GTA_MOCK_STATUS_TEXT=manual GTA_MOCK_PREPARE_RC=0
export GTA_MOCK_STATUS_RC GTA_MOCK_STATUS_TEXT GTA_MOCK_PREPARE_RC
gta_paths "$gta_fixture/mock-manual-no-dxvk" "$gta_game"
np_support=$gta_mock_support
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing DXVK stops a matching manual setup" nonzero "$([ "$gta_launch_rc" -ne 0 ] && echo nonzero || echo 0)"
has "missing DXVK manual stop is logged" "matching manual setup needs the WineCX DXVK runtime" "$log"
for gta_mock_status in ready-owned prepared; do
  GTA_MOCK_STATUS_TEXT=$gta_mock_status
  export GTA_MOCK_STATUS_TEXT
  gta_paths "$gta_fixture/mock-$gta_mock_status-no-dxvk" "$gta_game"
  np_support=$gta_mock_support
  : > "$log"
  gta_launch_rc=0
  (gta_sa_de_run) || gta_launch_rc=$?
  is "missing DXVK stops a $gta_mock_status setup" nonzero "$([ "$gta_launch_rc" -ne 0 ] && echo nonzero || echo 0)"
  has "missing DXVK is explicit for $gta_mock_status" "managed setup needs the WineCX DXVK runtime" "$log"
done
touch "$gta_fixture/runner/dxvk.available"
printf 'fixture dxvk d3d10core' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"

echo "== interrupted prepare and restore recover on the next operation"
gta_crash_prepare_game="$gta_fixture/crash-prepare-game"
gta_crash_prepare_data="$gta_fixture/crash-prepare-data"
gta_seed_case "$gta_crash_prepare_game" "$gta_crash_prepare_data"
gta_crash_rc=0
gta_crash_helper_call "$gta_crash_prepare_data" "$gta_crash_prepare_game" prepare 1 >/dev/null 2>&1 || gta_crash_rc=$?
is "SIGKILL interrupts prepare after a target rename" 137 "$gta_crash_rc"
gta_pending_status=$(gta_helper_call "$gta_crash_prepare_data" "$gta_crash_prepare_game" status)
is "status reports a pending prepare without recovering it" ready-owned "$gta_pending_status"
gta_recovered_prepare=$(gta_crash_helper_call "$gta_crash_prepare_data" "$gta_crash_prepare_game" prepare)
is "next prepare recovers then completes" prepared "$gta_recovered_prepare"
gta_pending_status=$(gta_helper_call "$gta_crash_prepare_data" "$gta_crash_prepare_game" status)
is "completed prepare clears its journal" prepared "$gta_pending_status"
is "prepare recovery removes every abandoned stage" 0 "$(find "$gta_crash_prepare_game" "$gta_crash_prepare_data" -name '.bridgeplay-gta-sa-de-*.tmp' | wc -l | tr -d ' ')"

gta_crash_restore_game="$gta_fixture/crash-restore-game"
gta_crash_restore_data="$gta_fixture/crash-restore-data"
gta_seed_case "$gta_crash_restore_game" "$gta_crash_restore_data"
gta_restore_setup=$(gta_helper_call "$gta_crash_restore_data" "$gta_crash_restore_game" prepare)
is "restore crash fixture starts prepared" prepared "$gta_restore_setup"
gta_crash_rc=0
gta_crash_helper_call "$gta_crash_restore_data" "$gta_crash_restore_game" restore 1 >/dev/null 2>&1 || gta_crash_rc=$?
is "SIGKILL interrupts restore after a target rename" 137 "$gta_crash_rc"
gta_pending_status=$(gta_helper_call "$gta_crash_restore_data" "$gta_crash_restore_game" status)
is "status reports a pending restore without recovering it" ready-owned "$gta_pending_status"
gta_recovered_restore=$(gta_crash_helper_call "$gta_crash_restore_data" "$gta_crash_restore_game" restore)
is "next restore recovers then completes" restored "$gta_recovered_restore"
is "restore recovery returns vendor helper" yes "$(cmp -s "$gta_crash_restore_data/pfx/$gta_helper_dir/SocialClubHelper.exe" "$gta_fixture/vendor-v1.exe" && echo yes || echo no)"
is "restore recovery removes owned game DLLs" 0 "$(find "$gta_crash_restore_game/Gameface/Binaries/Win64" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
is "restore recovery removes every abandoned stage" 0 "$(find "$gta_crash_restore_game" "$gta_crash_restore_data" -name '.bridgeplay-gta-sa-de-*.tmp' | wc -l | tr -d ' ')"

echo "== foreign prefix cannot recover a shared transaction"
gta_shared_pending_game="$gta_fixture/shared-pending-game"
gta_shared_pending_a="$gta_fixture/shared-pending-a"
gta_shared_pending_b="$gta_fixture/shared-pending-b"
gta_seed_case "$gta_shared_pending_game" "$gta_shared_pending_a"
mkdir -p "$gta_shared_pending_b/pfx"
gta_shared_pending_setup=$(gta_helper_call "$gta_shared_pending_a" "$gta_shared_pending_game" prepare)
is "shared pending fixture starts prepared" prepared "$gta_shared_pending_setup"
gta_crash_rc=0
gta_crash_helper_call "$gta_shared_pending_a" "$gta_shared_pending_game" restore 5 >/dev/null 2>&1 || gta_crash_rc=$?
is "SIGKILL interrupts restore after its first shared DLL park" 137 "$gta_crash_rc"
gta_shared_pending_marker="$gta_shared_pending_game/.bridgeplay-gta-sa-de-1547000.pending.json"
gta_shared_pending_journal="$gta_shared_pending_a/.bridgeplay-gta-sa-de-1547000/.bridgeplay-gta-sa-de-1547000.transaction.json"
is "interrupted shared transaction publishes a pending marker" yes "$(test -f "$gta_shared_pending_marker" && echo yes || echo no)"
is "interrupted owner retains its private journal" yes "$(test -f "$gta_shared_pending_journal" && echo yes || echo no)"
gta_shared_pending_marker_valid=$(python3 -c 'import json,re,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print("yes" if d.get("version") == 1 and d.get("appid") == "1547000" and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", d.get("transactionUUID", "")) else "no")' "$gta_shared_pending_marker")
is "pending marker contains only its canonical transaction identity" yes "$gta_shared_pending_marker_valid"
gta_pending_owner_uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_shared_pending_marker")
for gta_pending_action in status prepare restore; do
	gta_pending_rc=0
	gta_pending_result=$(gta_helper_call "$gta_shared_pending_b" "$gta_shared_pending_game" "$gta_pending_action" 2>&1) || gta_pending_rc=$?
	is "foreign pending marker blocks B $gta_pending_action" 4 "$gta_pending_rc"
	printf '%s\n' "$gta_pending_result" > "$gta_fixture/foreign-pending-$gta_pending_action.log"
	has "B $gta_pending_action identifies the foreign transaction" "transaction-shared-busy" "$gta_fixture/foreign-pending-$gta_pending_action.log"
done
gta_paths "$gta_shared_pending_b" "$gta_shared_pending_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "run hook hard-stops B on a foreign pending transaction" 4 "$gta_launch_rc"
has "run hook logs the shared transaction conflict" "status check failed (exit 4)" "$log"
is "blocked B preparation creates no private state" 0 "$(find "$gta_shared_pending_b" -name state.json | wc -l | tr -d ' ')"
is "blocked B leaves the parked DLL in the owner's journal" no "$(test -f "$gta_shared_pending_game/Gameface/Binaries/Win64/d3d11.dll" && echo yes || echo no)"
is "blocked B leaves the owner's marker intact" yes "$(test -f "$gta_shared_pending_marker" && echo yes || echo no)"
gta_pending_after_b_uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_shared_pending_marker")
is "blocked B does not replace the pending transaction identity" "$gta_pending_owner_uuid" "$gta_pending_after_b_uuid"
gta_shared_pending_recovered=$(gta_helper_call "$gta_shared_pending_a" "$gta_shared_pending_game" restore)
is "original owner recovers and completes its restore" restored "$gta_shared_pending_recovered"
is "owner recovery clears its shared marker" no "$(test -e "$gta_shared_pending_marker" && echo yes || echo no)"
is "owner recovery removes shared DLLs" 0 "$(find "$gta_shared_pending_game/Gameface/Binaries/Win64" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
gta_seed_vendor "$gta_shared_pending_b"
gta_shared_pending_b_prepared=$(gta_helper_call "$gta_shared_pending_b" "$gta_shared_pending_game" prepare)
is "B can prepare after the original owner recovers" prepared "$gta_shared_pending_b_prepared"

echo "== released recovery preserves the next owner's shared state"
gta_release_game="$gta_fixture/released-game"
gta_release_a="$gta_fixture/released-a"
gta_release_b="$gta_fixture/released-b"
gta_seed_case "$gta_release_game" "$gta_release_a"
gta_seed_vendor "$gta_release_b"
mkdir -p "$gta_release_b/pfx"
gta_release_a_prepared=$(gta_helper_call "$gta_release_a" "$gta_release_game" prepare)
is "release race fixture starts prepared" prepared "$gta_release_a_prepared"
gta_crash_rc=0
gta_crash_helper_call "$gta_release_a" "$gta_release_game" restore "" after-shared-release >/dev/null 2>&1 || gta_crash_rc=$?
is "SIGKILL leaves a released private journal after clearing its marker" 137 "$gta_crash_rc"
gta_release_marker="$gta_release_game/.bridgeplay-gta-sa-de-1547000.pending.json"
gta_release_a_journal="$gta_release_a/.bridgeplay-gta-sa-de-1547000/.bridgeplay-gta-sa-de-1547000.transaction.json"
is "release checkpoint removes the public pending marker" no "$(test -e "$gta_release_marker" && echo yes || echo no)"
is "release checkpoint leaves its finished private journal" yes "$(test -f "$gta_release_a_journal" && echo yes || echo no)"
gta_release_b_prepared=$(gta_helper_call "$gta_release_b" "$gta_release_game" prepare)
is "B can prepare after A releases shared assets" prepared "$gta_release_b_prepared"
gta_release_shared="$gta_release_game/.bridgeplay-gta-sa-de-1547000.json"
gta_release_b_shared_before=$(shasum -a 256 "$gta_release_shared" | awk '{print $1}')
is "B owns a new shared reference after preparing" yes "$(test -f "$gta_release_b/.bridgeplay-gta-sa-de-1547000/state.json" && echo yes || echo no)"
is "B reinstalled the released shared DXMT DLLs" 3 "$(find "$gta_release_game/Gameface/Binaries/Win64" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
gta_crash_rc=0
gta_crash_helper_call "$gta_release_b" "$gta_release_game" restore 1 >/dev/null 2>&1 || gta_crash_rc=$?
is "B can publish its own pending marker while restoring" 137 "$gta_crash_rc"
gta_release_b_marker="$gta_release_marker"
gta_release_b_uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_release_b_marker")
gta_release_b_marker_hash=$(shasum -a 256 "$gta_release_b_marker" | awk '{print $1}')
for gta_release_action in status prepare restore; do
	gta_release_rc=0
	gta_release_result=$(gta_helper_call "$gta_release_a" "$gta_release_game" "$gta_release_action" 2>&1) || gta_release_rc=$?
	is "A cannot enter B's pending transaction through $gta_release_action" 4 "$gta_release_rc"
	printf '%s\n' "$gta_release_result" > "$gta_fixture/released-foreign-$gta_release_action.log"
	has "A $gta_release_action reports B's transaction as foreign" "transaction-shared-busy" "$gta_fixture/released-foreign-$gta_release_action.log"
	is "A $gta_release_action preserves B's marker" "$gta_release_b_marker_hash" "$(shasum -a 256 "$gta_release_b_marker" | awk '{print $1}')"
done
is "B's transaction identity remains stable while A is blocked" "$gta_release_b_uuid" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_release_b_marker")"
is "A blocked by B leaves its released journal for later cleanup" yes "$(test -f "$gta_release_a_journal" && echo yes || echo no)"
gta_release_b_recovered=$(gta_helper_call "$gta_release_b" "$gta_release_game" prepare)
is "B recovers and completes its interrupted restore" already-prepared "$gta_release_b_recovered"
is "B recovery clears only its own pending marker" no "$(test -e "$gta_release_b_marker" && echo yes || echo no)"
gta_release_a_cleanup=$(gta_helper_call "$gta_release_a" "$gta_release_game" restore)
is "A cleans its released journal after B finishes" no-owned-state "$gta_release_a_cleanup"
is "A cleanup removes its private journal" no "$(test -e "$gta_release_a_journal" && echo yes || echo no)"
is "A cleanup preserves B's shared reference" "$gta_release_b_shared_before" "$(shasum -a 256 "$gta_release_shared" | awk '{print $1}')"
is "A cleanup preserves B's private state" yes "$(test -f "$gta_release_b/.bridgeplay-gta-sa-de-1547000/state.json" && echo yes || echo no)"
is "A cleanup preserves B's shared DLLs" 3 "$(find "$gta_release_game/Gameface/Binaries/Win64" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"

echo "== documented orphan-marker quarantine"
gta_orphan_readme="$repo_root/workarounds/1547000/README.md"
gta_orphan_manifest="$repo_root/gamefix-assets/1547000.json"
gta_orphan_script="$gta_fixture/orphan-recovery.sh"
sed -n '/^# BEGIN GTA 1547000 ORPHAN RECOVERY BODY$/,/^# END GTA 1547000 ORPHAN RECOVERY BODY$/p' "$gta_orphan_readme" | sed '1d;$d' > "$gta_orphan_script"
sh -n "$gta_orphan_script"
gta_orphan_doc_pins=$(python3 - "$gta_orphan_readme" "$gta_orphan_manifest" <<'PY'
import json
import re
import sys

readme = open(sys.argv[1], encoding="utf-8").read()
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
setup = re.search(r"(?ms)^# BEGIN GTA 1547000 ORPHAN PIN SETUP\n(.*?)^# END GTA 1547000 ORPHAN PIN SETUP$", readme)
pins = dict(re.findall(r"^GTA_PIN_(D3D11|DXGI|D3D10CORE)='([0-9a-f]{64})'$", setup.group(1), re.M)) if setup else {}
expected = {"D3D11": "", "DXGI": "", "D3D10CORE": ""}
for item in manifest["dxmtFiles"]:
    expected[{"d3d11.dll": "D3D11", "dxgi.dll": "DXGI", "d3d10core.dll": "D3D10CORE"}[item["name"]]] = item["sha256"]
print("yes" if pins == expected else "no")
PY
)
is "documented orphan pins match the production manifest" yes "$gta_orphan_doc_pins"

gta_orphan_helper_script="$gta_fixture/orphan-helper-recovery.sh"
sed -n '/^# BEGIN GTA 1547000 ORPHAN HELPER RECOVERY BODY$/,/^# END GTA 1547000 ORPHAN HELPER RECOVERY BODY$/p' "$gta_orphan_readme" | sed '1d;$d' > "$gta_orphan_helper_script"
sh -n "$gta_orphan_helper_script"
gta_orphan_helper_doc_pins=$(python3 - "$gta_orphan_readme" "$gta_orphan_manifest" <<'PY'
import json
import re
import sys

readme = open(sys.argv[1], encoding="utf-8").read()
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
setup = re.search(r"(?ms)^# BEGIN GTA 1547000 ORPHAN HELPER PIN SETUP\n(.*?)^# END GTA 1547000 ORPHAN HELPER PIN SETUP$", readme)
pins = dict(re.findall(r"^GTA_PIN_(VENDOR|WRAPPER|LICENSE)='([0-9a-f]{64})'$", setup.group(1), re.M)) if setup else {}
expected = {
    "VENDOR": manifest["supportedVendorHelpers"][0]["sha256"],
    "WRAPPER": manifest["helperWrapperSHA256"],
    "LICENSE": manifest["helperLicenseSHA256"],
}
print("yes" if pins == expected else "no")
PY
)
is "documented helper recovery pins match the production manifest" yes "$gta_orphan_helper_doc_pins"
gta_orphan_helper_fixture_pins=$(python3 - "$gta_fixture/manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print(manifest["supportedVendorHelpers"][0]["sha256"],
      manifest["helperWrapperSHA256"], manifest["helperLicenseSHA256"])
PY
)
gta_orphan_helper_fixture_vendor=${gta_orphan_helper_fixture_pins%% *}
gta_orphan_helper_fixture_pins=${gta_orphan_helper_fixture_pins#* }
gta_orphan_helper_fixture_wrapper=${gta_orphan_helper_fixture_pins%% *}
gta_orphan_helper_fixture_license=${gta_orphan_helper_fixture_pins#* }
gta_orphan_helper_script_fixture="$gta_orphan_helper_script"

gta_orphan_game="$gta_fixture/orphan-recovery-game"
gta_orphan_data_a="$gta_fixture/orphan-recovery-data-a"
gta_orphan_data_b="$gta_fixture/orphan-recovery-data-b"
gta_seed_case "$gta_orphan_game" "$gta_orphan_data_a"
mkdir -p "$gta_orphan_data_b/pfx"
gta_seed_vendor "$gta_orphan_data_b"
gta_orphan_game=$(CDPATH='' cd -P "$gta_orphan_game" && pwd -P)
gta_orphan_save="$gta_orphan_game/UserData/saves/fixture-save.dat"
gta_orphan_stage="$gta_orphan_game/.bridgeplay-gta-sa-de-11111111-1111-4111-8111-111111111111.tmp"
mkdir -p "$(dirname "$gta_orphan_save")"
printf 'fixture save bytes\n' > "$gta_orphan_save"
printf 'unowned staged bytes\n' > "$gta_orphan_stage"
printf 'owner registry bytes\n' > "$gta_orphan_data_a/pfx/user.reg"
printf 'second prefix registry bytes\n' > "$gta_orphan_data_b/pfx/user.reg"
gta_orphan_initial=$(gta_helper_call "$gta_orphan_data_a" "$gta_orphan_game" prepare)
is "orphan fixture A starts prepared" prepared "$gta_orphan_initial"
gta_orphan_b_initial=$(gta_helper_call "$gta_orphan_data_b" "$gta_orphan_game" prepare)
is "orphan fixture B starts prepared" prepared "$gta_orphan_b_initial"
gta_crash_rc=0
gta_crash_helper_call "$gta_orphan_data_a" "$gta_orphan_game" restore 5 >/dev/null 2>&1 || gta_crash_rc=$?
is "SIGKILL interrupts A restore after shared-state update with B present" 137 "$gta_crash_rc"
gta_orphan_marker="$gta_orphan_game/.bridgeplay-gta-sa-de-1547000.pending.json"
gta_orphan_shared="$gta_orphan_game/.bridgeplay-gta-sa-de-1547000.json"
gta_orphan_journal="$gta_orphan_data_a/.bridgeplay-gta-sa-de-1547000/.bridgeplay-gta-sa-de-1547000.transaction.json"
is "orphan fixture retains the shared marker" yes "$(test -f "$gta_orphan_marker" && echo yes || echo no)"
is "interrupted A restore leaves shared state and all three DLLs" 3 "$(find "$gta_orphan_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"
is "test owner journal exists before simulated loss" yes "$(test -f "$gta_orphan_journal" && echo yes || echo no)"
rm "$gta_orphan_journal"
is "test deletes only the owner transaction journal" no "$(test -e "$gta_orphan_journal" && echo yes || echo no)"
is "surviving B prefix state remains" yes "$(test -f "$gta_orphan_data_b/.bridgeplay-gta-sa-de-1547000/state.json" && echo yes || echo no)"

gta_orphan_block_rc=0
gta_orphan_block=$(gta_helper_call "$gta_orphan_data_b" "$gta_orphan_game" prepare 2>&1) || gta_orphan_block_rc=$?
is "B remains blocked by an orphan marker before quarantine" 4 "$gta_orphan_block_rc"
printf '%s\n' "$gta_orphan_block" > "$gta_fixture/orphan-b-blocked.log"
has "B reports the shared transaction as busy" "transaction-shared-busy" "$gta_fixture/orphan-b-blocked.log"

gta_orphan_snapshot() {
	find "$gta_orphan_game" "$gta_orphan_data_a" "$gta_orphan_data_b" \( -type f -o -type l \) -print | LC_ALL=C sort
	find "$gta_orphan_game" "$gta_orphan_data_a" "$gta_orphan_data_b" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
	find "$gta_orphan_game" "$gta_orphan_data_a" "$gta_orphan_data_b" -type l -exec readlink {} \; | LC_ALL=C sort
}
gta_orphan_tmp_inventory() {
	find "$gta_orphan_game" "$gta_orphan_data_a" "$gta_orphan_data_b" -type f -name '*.tmp' -exec shasum -a 256 {} \; | LC_ALL=C sort
}
gta_orphan_hash() { shasum -a 256 "$1" | awk '{print $1}'; }
gta_orphan_runtime="$gta_runner/lib/notproton-backends/dxmt/x86_64-windows"
gta_orphan_fixture_pins=$(python3 - "$gta_fixture/manifest.json" <<'PY'
import json
import sys
pins = {item["name"]: item["sha256"] for item in json.load(open(sys.argv[1], encoding="utf-8"))["dxmtFiles"]}
print(pins["d3d11.dll"], pins["dxgi.dll"], pins["d3d10core.dll"])
PY
)
gta_orphan_pin_d3d11=${gta_orphan_fixture_pins%% *}
gta_orphan_fixture_pins=${gta_orphan_fixture_pins#* }
gta_orphan_pin_dxgi=${gta_orphan_fixture_pins%% *}
gta_orphan_pin_d3d10core=${gta_orphan_fixture_pins#* }
gta_orphan_uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_orphan_marker")
gta_orphan_parent=${gta_orphan_game%/*}
gta_orphan_backup="$gta_orphan_parent/.bridgeplay-gta-sa-de-orphan-$gta_orphan_uuid"
gta_orphan_run() {
	gta_orphan_expected_uuid=$1
	gta_orphan_root=$2
	gta_orphan_log=$3
	gta_orphan_rc=0
	env GTA_GAME="$gta_orphan_root" GTA_EXPECTED_TRANSACTION_UUID="$gta_orphan_expected_uuid" \
		GTA_ORPHAN_ACK=I_CONFIRMED_THE_OWNER_JOURNAL_IS_IRRETRIEVABLY_LOST \
		GTA_PIN_D3D11="$gta_orphan_pin_d3d11" GTA_PIN_DXGI="$gta_orphan_pin_dxgi" \
		GTA_PIN_D3D10CORE="$gta_orphan_pin_d3d10core" sh "$gta_orphan_script" > "$gta_orphan_log" 2>&1 || gta_orphan_rc=$?
}
gta_orphan_helper_run_for() {
	gta_orphan_helper_test_game=$1
	gta_orphan_helper_test_data=$2
	gta_orphan_helper_test_log=$3
	gta_orphan_helper_rc=0
	env GTA_GAME="$gta_orphan_helper_test_game" GTA_DATA="$gta_orphan_helper_test_data" \
		GTA_HELPER_ORPHAN_ACK=I_CONFIRMED_ORIGINAL_OWNER_PREFIX_JOURNAL_LOST_AND_ALL_STEAM_WINE_SESSIONS_STOPPED \
		GTA_PIN_VENDOR="$gta_orphan_helper_fixture_vendor" GTA_PIN_WRAPPER="$gta_orphan_helper_fixture_wrapper" \
		GTA_PIN_LICENSE="$gta_orphan_helper_fixture_license" \
		sh "$gta_orphan_helper_script_fixture" > "$gta_orphan_helper_test_log" 2>&1 || gta_orphan_helper_rc=$?
}

gta_orphan_before=$(gta_orphan_snapshot)
case "$gta_orphan_uuid" in 0*) gta_orphan_wrong_uuid="1${gta_orphan_uuid#?}" ;; *) gta_orphan_wrong_uuid="0${gta_orphan_uuid#?}" ;; esac
gta_orphan_run "$gta_orphan_wrong_uuid" "$gta_orphan_game" "$gta_fixture/orphan-wrong-uuid.log"
is "wrong UUID is rejected before any change" nonzero "$([ "$gta_orphan_rc" -ne 0 ] && echo nonzero || echo 0)"
is "wrong UUID refusal leaves every fixture file unchanged" "$gta_orphan_before" "$(gta_orphan_snapshot)"
is "wrong UUID refusal creates no quarantine" no "$(test -e "$gta_orphan_parent/.bridgeplay-gta-sa-de-orphan-$gta_orphan_wrong_uuid" && echo yes || echo no)"

gta_orphan_dll_dir="$gta_orphan_game/Gameface/Binaries/Win64"
printf 'unrecognized modified DXMT DLL\n' > "$gta_orphan_dll_dir/d3d11.dll"
gta_orphan_before=$(gta_orphan_snapshot)
gta_orphan_run "$gta_orphan_uuid" "$gta_orphan_game" "$gta_fixture/orphan-unknown-dll.log"
is "unknown DLL hash is rejected before any change" nonzero "$([ "$gta_orphan_rc" -ne 0 ] && echo nonzero || echo 0)"
is "unknown DLL refusal leaves every fixture file unchanged" "$gta_orphan_before" "$(gta_orphan_snapshot)"
is "unknown DLL refusal creates no quarantine" no "$(test -e "$gta_orphan_backup" && echo yes || echo no)"
cp -p "$gta_orphan_runtime/d3d11.dll" "$gta_orphan_dll_dir/d3d11.dll"

mv "$gta_orphan_dll_dir/d3d11.dll" "$gta_fixture/orphan-d3d11.saved"
ln -s "$gta_orphan_runtime/d3d11.dll" "$gta_orphan_dll_dir/d3d11.dll"
gta_orphan_before=$(gta_orphan_snapshot)
gta_orphan_run "$gta_orphan_uuid" "$gta_orphan_game" "$gta_fixture/orphan-symlink.log"
is "DLL symlink is rejected before any change" nonzero "$([ "$gta_orphan_rc" -ne 0 ] && echo nonzero || echo 0)"
is "symlink refusal leaves every fixture file unchanged" "$gta_orphan_before" "$(gta_orphan_snapshot)"
is "symlink refusal creates no quarantine" no "$(test -e "$gta_orphan_backup" && echo yes || echo no)"
rm "$gta_orphan_dll_dir/d3d11.dll"
mv "$gta_fixture/orphan-d3d11.saved" "$gta_orphan_dll_dir/d3d11.dll"

printf 'occupied quarantine destination\n' > "$gta_orphan_backup"
gta_orphan_before=$(gta_orphan_snapshot)
gta_orphan_backup_hash=$(gta_orphan_hash "$gta_orphan_backup")
gta_orphan_run "$gta_orphan_uuid" "$gta_orphan_game" "$gta_fixture/orphan-destination-exists.log"
is "existing quarantine destination is refused" nonzero "$([ "$gta_orphan_rc" -ne 0 ] && echo nonzero || echo 0)"
is "destination refusal leaves every fixture file unchanged" "$gta_orphan_before" "$(gta_orphan_snapshot)"
is "destination refusal preserves its existing file" "$gta_orphan_backup_hash" "$(gta_orphan_hash "$gta_orphan_backup")"
rm "$gta_orphan_backup"

gta_orphan_run "$gta_orphan_uuid" / "$gta_fixture/orphan-root-path.log"
is "filesystem root is rejected before any change" nonzero "$([ "$gta_orphan_rc" -ne 0 ] && echo nonzero || echo 0)"
is "root refusal leaves every fixture file unchanged" "$gta_orphan_before" "$(gta_orphan_snapshot)"

gta_orphan_marker_hash=$(gta_orphan_hash "$gta_orphan_marker")
gta_orphan_shared_hash=$(gta_orphan_hash "$gta_orphan_shared")
gta_orphan_exe_hash=$(gta_orphan_hash "$gta_orphan_dll_dir/SanAndreas.exe")
gta_orphan_save_hash=$(gta_orphan_hash "$gta_orphan_save")
gta_orphan_stage_inventory=$(gta_orphan_tmp_inventory)
gta_orphan_prefix_inventory=$(find "$gta_orphan_data_a" "$gta_orphan_data_b" \( -type f -o -type l \) -print | LC_ALL=C sort)
gta_orphan_prefix_hashes=$(find "$gta_orphan_data_a" "$gta_orphan_data_b" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort)
gta_orphan_run "$gta_orphan_uuid" "$gta_orphan_game/" "$gta_fixture/orphan-complete.log"
is "documented recovery body completes on fixture pins" 0 "$gta_orphan_rc"
has "documented recovery reports its quarantine" "Quarantine complete:" "$gta_fixture/orphan-complete.log"
is "quarantine is a private sibling outside the game folder" 700 "$(stat -f %Lp "$gta_orphan_backup")"
is "quarantine is outside the game folder" "$gta_orphan_parent" "$(dirname "$gta_orphan_backup")"
is "quarantined marker bytes are preserved" "$gta_orphan_marker_hash" "$(gta_orphan_hash "$gta_orphan_backup/.bridgeplay-gta-sa-de-1547000.pending.json")"
is "quarantined shared-state bytes are preserved" "$gta_orphan_shared_hash" "$(gta_orphan_hash "$gta_orphan_backup/.bridgeplay-gta-sa-de-1547000.json")"
for gta_orphan_name in d3d11.dll dxgi.dll d3d10core.dll; do
	is "quarantined $gta_orphan_name matches its fixture runtime" yes "$(cmp -s "$gta_orphan_runtime/$gta_orphan_name" "$gta_orphan_backup/$gta_orphan_name" && echo yes || echo no)"
done
is "quarantine removes only the known shared DLL destinations" 0 "$(find "$gta_orphan_dll_dir" -maxdepth 1 \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
is "quarantine moves marker and shared state out of game root" no "$(test -e "$gta_orphan_marker" -o -L "$gta_orphan_marker" -o -e "$gta_orphan_shared" -o -L "$gta_orphan_shared" && echo yes || echo no)"
is "game executable is unchanged" "$gta_orphan_exe_hash" "$(gta_orphan_hash "$gta_orphan_dll_dir/SanAndreas.exe")"
is "save bytes remain unchanged" "$gta_orphan_save_hash" "$(gta_orphan_hash "$gta_orphan_save")"
is "unknown staged files remain unchanged" "$gta_orphan_stage_inventory" "$(gta_orphan_tmp_inventory)"
is "both prefixes and registry data remain unchanged" "$gta_orphan_prefix_hashes" "$(find "$gta_orphan_data_a" "$gta_orphan_data_b" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort)"
is "both prefix file sets remain unchanged" "$gta_orphan_prefix_inventory" "$(find "$gta_orphan_data_a" "$gta_orphan_data_b" \( -type f -o -type l \) -print | LC_ALL=C sort)"
gta_orphan_b_restore=$(gta_helper_call "$gta_orphan_data_b" "$gta_orphan_game" restore)
is "B restores after orphan shared metadata quarantine" restored "$gta_orphan_b_restore"
is "B restore keeps quarantined DLL destinations absent without shared metadata" 0 "$(find "$gta_orphan_dll_dir" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
is "B restore leaves missing shared metadata absent" no "$(test -e "$gta_orphan_shared" && echo yes || echo no)"
gta_orphan_b_prepared=$(gta_helper_call "$gta_orphan_data_b" "$gta_orphan_game" prepare)
is "B prepares after restore with missing shared metadata" prepared "$gta_orphan_b_prepared"
is "B reprepare reinstalls the owned shared DLL set" 3 "$(find "$gta_orphan_dll_dir" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"

echo "== orphan quarantine refuses an unowned partial DLL set"
gta_partial_orphan_game="$gta_fixture/orphan-partial-game"
gta_partial_orphan_data="$gta_fixture/orphan-partial-data"
gta_seed_case "$gta_partial_orphan_game" "$gta_partial_orphan_data"
gta_partial_orphan_game=$(CDPATH='' cd -P "$gta_partial_orphan_game" && pwd -P)
gta_partial_orphan_dll_dir="$gta_partial_orphan_game/Gameface/Binaries/Win64"
gta_partial_orphan_uuid='22222222-2222-4222-8222-222222222222'
gta_partial_orphan_marker="$gta_partial_orphan_game/.bridgeplay-gta-sa-de-1547000.pending.json"
gta_partial_orphan_parent=$(dirname "$gta_partial_orphan_game")
gta_partial_orphan_backup="$gta_partial_orphan_parent/.bridgeplay-gta-sa-de-orphan-$gta_partial_orphan_uuid"
cp -p "$gta_orphan_runtime/d3d11.dll" "$gta_partial_orphan_dll_dir/d3d11.dll"
printf '{"version":1,"appid":"1547000","transactionUUID":"%s"}\n' "$gta_partial_orphan_uuid" > "$gta_partial_orphan_marker"
chmod 644 "$gta_partial_orphan_marker"
gta_partial_orphan_snapshot() {
	find "$gta_partial_orphan_game" "$gta_partial_orphan_data" \( -type f -o -type l \) -print | LC_ALL=C sort
	find "$gta_partial_orphan_game" "$gta_partial_orphan_data" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
	find "$gta_partial_orphan_game" "$gta_partial_orphan_data" -type l -exec readlink {} \; | LC_ALL=C sort
}
gta_partial_orphan_before=$(gta_partial_orphan_snapshot)
gta_orphan_run "$gta_partial_orphan_uuid" "$gta_partial_orphan_game" "$gta_fixture/orphan-partial-refused.log"
is "orphan quarantine refuses partial DLLs without ownership proof" nonzero "$([ "$gta_orphan_rc" -ne 0 ] && echo nonzero || echo 0)"
has "partial DLL refusal points to manual recovery" "complete manual recipe section 5" "$gta_fixture/orphan-partial-refused.log"
is "partial DLL refusal happens before any file move" "$gta_partial_orphan_before" "$(gta_partial_orphan_snapshot)"
is "partial DLL refusal creates no quarantine" no "$(test -e "$gta_partial_orphan_backup" && echo yes || echo no)"
cp -p "$gta_orphan_runtime/dxgi.dll" "$gta_partial_orphan_dll_dir/dxgi.dll"
cp -p "$gta_orphan_runtime/d3d10core.dll" "$gta_partial_orphan_dll_dir/d3d10core.dll"
gta_orphan_run "$gta_partial_orphan_uuid" "$gta_partial_orphan_game" "$gta_fixture/orphan-partial-completed.log"
is "complete manually verified set permits shared reset" 0 "$gta_orphan_rc"
is "completed manual set leaves no ownership metadata" no "$(test -e "$gta_partial_orphan_game/.bridgeplay-gta-sa-de-1547000.json" && echo yes || echo no)"
is "completed manual set leaves its three user DLLs active" 3 "$(find "$gta_partial_orphan_dll_dir" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
for gta_partial_orphan_name in d3d11.dll dxgi.dll d3d10core.dll; do
	is "manual $gta_partial_orphan_name matches the pinned runtime" yes "$(cmp -s "$gta_orphan_runtime/$gta_partial_orphan_name" "$gta_partial_orphan_dll_dir/$gta_partial_orphan_name" && echo yes || echo no)"
done

echo "== lost first helper checkpoint keeps the active vendor helper"
gta_helper_first_game="$gta_fixture/helper-orphan-real-only-game"
gta_helper_first_data_a="$gta_fixture/helper-orphan-real-only-data-a"
gta_helper_first_data_b="$gta_fixture/helper-orphan-real-only-data-b"
gta_seed_case "$gta_helper_first_game" "$gta_helper_first_data_a"
mkdir -p "$gta_helper_first_data_b/pfx"
gta_seed_vendor "$gta_helper_first_data_b"
gta_helper_first_game=$(CDPATH='' cd -P "$gta_helper_first_game" && pwd -P)
gta_helper_first_data_a=$(CDPATH='' cd -P "$gta_helper_first_data_a" && pwd -P)
gta_helper_first_dll_dir="$gta_helper_first_game/Gameface/Binaries/Win64"
for gta_helper_name in d3d11.dll dxgi.dll d3d10core.dll; do
	cp -p "$gta_orphan_runtime/$gta_helper_name" "$gta_helper_first_dll_dir/$gta_helper_name"
done
gta_crash_rc=0
gta_crash_helper_call "$gta_helper_first_data_a" "$gta_helper_first_game" prepare 1 >/dev/null 2>&1 || gta_crash_rc=$?
is "fresh prepare crashes after its first helper backup mutation" 137 "$gta_crash_rc"
gta_helper_first_dir="$gta_helper_first_data_a/pfx/$gta_helper_dir"
gta_helper_first_active="$gta_helper_first_dir/SocialClubHelper.exe"
gta_helper_first_real="$gta_helper_first_dir/SocialClubHelper_real.exe"
gta_helper_first_checksum="$gta_helper_first_dir/SocialClubHelper_real.exe.sha256"
gta_helper_first_license="$gta_helper_first_dir/SocialClubHelper.bridgeplay.LICENSE"
gta_helper_first_marker="$gta_helper_first_game/.bridgeplay-gta-sa-de-1547000.pending.json"
gta_helper_first_journal="$gta_helper_first_data_a/.bridgeplay-gta-sa-de-1547000/.bridgeplay-gta-sa-de-1547000.transaction.json"
gta_helper_first_state="$gta_helper_first_data_a/.bridgeplay-gta-sa-de-1547000/state.json"
is "first checkpoint keeps the active vendor helper" yes "$(cmp -s "$gta_fixture/vendor-v1.exe" "$gta_helper_first_active" && echo yes || echo no)"
is "first checkpoint has the byte-identical saved real helper" yes "$(cmp -s "$gta_helper_first_active" "$gta_helper_first_real" && echo yes || echo no)"
is "first checkpoint has no checksum or license yet" no "$(test -e "$gta_helper_first_checksum" -o -e "$gta_helper_first_license" && echo yes || echo no)"
is "first checkpoint has no prefix state.json" no "$(test -e "$gta_helper_first_state" && echo yes || echo no)"
is "first checkpoint retains its owner journal before simulated loss" yes "$(test -f "$gta_helper_first_journal" && echo yes || echo no)"
rm "$gta_helper_first_journal"
gta_helper_first_uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_helper_first_marker")
gta_orphan_run "$gta_helper_first_uuid" "$gta_helper_first_game" "$gta_fixture/helper-first-game-quarantine.log"
is "first checkpoint game reset completes with complete user DLLs" 0 "$gta_orphan_rc"
is "first checkpoint game reset preserves the complete user DLL set" 3 "$(find "$gta_helper_first_dll_dir" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"
gta_helper_first_restore=$(gta_helper_call "$gta_helper_first_data_a" "$gta_helper_first_game" restore)
is "restore after the lost first checkpoint reports no-owned-state" no-owned-state "$gta_helper_first_restore"
gta_orphan_helper_run_for "$gta_helper_first_game" "$gta_helper_first_data_a" "$gta_fixture/helper-first-cleanup.log"
is "guarded first-checkpoint cleanup succeeds" 0 "$gta_orphan_helper_rc"
gta_helper_first_backup=$(sed -n 's/^Orphan helper files quarantined for this prefix: //p' "$gta_fixture/helper-first-cleanup.log")
if [ -n "$gta_helper_first_backup" ]; then
	is "helper quarantine is private" 700 "$(stat -f %Lp "$gta_helper_first_backup")"
	is "helper quarantine is outside pfx" "$gta_helper_first_data_a" "$(dirname "$gta_helper_first_backup")"
	is "first checkpoint quarantines only the verified duplicate real helper" 1 "$(find "$gta_helper_first_backup" -type f | wc -l | tr -d ' ')"
	is "first checkpoint preserves duplicate helper bytes" yes "$(cmp -s "$gta_fixture/vendor-v1.exe" "$gta_helper_first_backup/SocialClubHelper_real.exe" && echo yes || echo no)"
else
	bad "first checkpoint reports its helper quarantine" present missing
fi
is "first checkpoint leaves the active vendor helper in place" yes "$(cmp -s "$gta_fixture/vendor-v1.exe" "$gta_helper_first_active" && echo yes || echo no)"
is "first checkpoint removes only the active duplicate path" no "$(test -e "$gta_helper_first_real" && echo yes || echo no)"
gta_helper_first_a_prepared=$(gta_helper_call "$gta_helper_first_data_a" "$gta_helper_first_game" prepare)
is "A prepares after guarded helper cleanup" prepared "$gta_helper_first_a_prepared"
gta_helper_first_b_prepared=$(gta_helper_call "$gta_helper_first_data_b" "$gta_helper_first_game" prepare)
is "B prepares against the complete user DLL set" prepared "$gta_helper_first_b_prepared"
gta_helper_first_a_restore=$(gta_helper_call "$gta_helper_first_data_a" "$gta_helper_first_game" restore)
is "A restore leaves the user DLL set in place" restored "$gta_helper_first_a_restore"
gta_helper_first_b_restore=$(gta_helper_call "$gta_helper_first_data_b" "$gta_helper_first_game" restore)
is "B restore leaves the user DLL set in place" restored "$gta_helper_first_b_restore"
is "manual DLL set remains outside shared ownership metadata" no "$(test -e "$gta_helper_first_game/.bridgeplay-gta-sa-de-1547000.json" && echo yes || echo no)"
for gta_helper_name in d3d11.dll dxgi.dll d3d10core.dll; do
	is "user-owned $gta_helper_name survives A and B restore byte-for-byte" yes "$(cmp -s "$gta_orphan_runtime/$gta_helper_name" "$gta_helper_first_dll_dir/$gta_helper_name" && echo yes || echo no)"
done

echo "== lost later helper checkpoint quarantines only pinned sidecars"
gta_helper_later_game="$gta_fixture/helper-orphan-later-game"
gta_helper_later_data="$gta_fixture/helper-orphan-later-data"
gta_seed_case "$gta_helper_later_game" "$gta_helper_later_data"
gta_helper_later_game=$(CDPATH='' cd -P "$gta_helper_later_game" && pwd -P)
gta_helper_later_data=$(CDPATH='' cd -P "$gta_helper_later_data" && pwd -P)
gta_helper_later_dll_dir="$gta_helper_later_game/Gameface/Binaries/Win64"
for gta_helper_name in d3d11.dll dxgi.dll d3d10core.dll; do
	cp -p "$gta_orphan_runtime/$gta_helper_name" "$gta_helper_later_dll_dir/$gta_helper_name"
done
gta_crash_rc=0
gta_crash_helper_call "$gta_helper_later_data" "$gta_helper_later_game" prepare 3 >/dev/null 2>&1 || gta_crash_rc=$?
is "later fresh checkpoint crashes after real, checksum and license install" 137 "$gta_crash_rc"
gta_helper_later_dir="$gta_helper_later_data/pfx/$gta_helper_dir"
gta_helper_later_active="$gta_helper_later_dir/SocialClubHelper.exe"
gta_helper_later_real="$gta_helper_later_dir/SocialClubHelper_real.exe"
gta_helper_later_checksum="$gta_helper_later_dir/SocialClubHelper_real.exe.sha256"
gta_helper_later_license="$gta_helper_later_dir/SocialClubHelper.bridgeplay.LICENSE"
gta_helper_later_marker="$gta_helper_later_game/.bridgeplay-gta-sa-de-1547000.pending.json"
gta_helper_later_journal="$gta_helper_later_data/.bridgeplay-gta-sa-de-1547000/.bridgeplay-gta-sa-de-1547000.transaction.json"
is "later checkpoint still has the active vendor helper" yes "$(cmp -s "$gta_fixture/vendor-v1.exe" "$gta_helper_later_active" && echo yes || echo no)"
is "later checkpoint installed the expected checksum bytes" yes "$(printf '%s  SocialClubHelper_real.exe\n' "$gta_orphan_helper_fixture_vendor" | cmp -s "$gta_helper_later_checksum" - && echo yes || echo no)"
is "later checkpoint installed the pinned license" yes "$(gta_orphan_hash "$gta_helper_later_license" | grep -q "^$gta_orphan_helper_fixture_license$" && echo yes || echo no)"
rm "$gta_helper_later_journal"
gta_helper_later_uuid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["transactionUUID"])' "$gta_helper_later_marker")
gta_orphan_run "$gta_helper_later_uuid" "$gta_helper_later_game" "$gta_fixture/helper-later-game-quarantine.log"
is "later checkpoint game reset preserves its user DLL set" 0 "$gta_orphan_rc"
gta_helper_later_restore=$(gta_helper_call "$gta_helper_later_data" "$gta_helper_later_game" restore)
is "later checkpoint restore reports no-owned-state" no-owned-state "$gta_helper_later_restore"
gta_orphan_helper_run_for "$gta_helper_later_game" "$gta_helper_later_data" "$gta_fixture/helper-later-cleanup.log"
is "later guarded helper cleanup succeeds" 0 "$gta_orphan_helper_rc"
gta_helper_later_backup=$(sed -n 's/^Orphan helper files quarantined for this prefix: //p' "$gta_fixture/helper-later-cleanup.log")
if [ -n "$gta_helper_later_backup" ]; then
	is "later checkpoint quarantines all three verified helper files" 3 "$(find "$gta_helper_later_backup" -type f | wc -l | tr -d ' ')"
	is "later checkpoint preserves the duplicate real helper" yes "$(cmp -s "$gta_fixture/vendor-v1.exe" "$gta_helper_later_backup/SocialClubHelper_real.exe" && echo yes || echo no)"
	is "later checkpoint preserves the checksum sidecar" yes "$(printf '%s  SocialClubHelper_real.exe\n' "$gta_orphan_helper_fixture_vendor" | cmp -s "$gta_helper_later_backup/SocialClubHelper_real.exe.sha256" - && echo yes || echo no)"
	is "later checkpoint preserves the license" yes "$(gta_orphan_hash "$gta_helper_later_backup/SocialClubHelper.bridgeplay.LICENSE" | grep -q "^$gta_orphan_helper_fixture_license$" && echo yes || echo no)"
else
	bad "later checkpoint reports its helper quarantine" present missing
fi
is "later checkpoint leaves current vendor helper in place" yes "$(cmp -s "$gta_fixture/vendor-v1.exe" "$gta_helper_later_active" && echo yes || echo no)"

echo "== helper recovery refuses changed and wrapped files before writes"
gta_helper_orphan_snapshot() {
	find "$gta_helper_test_game" "$gta_helper_test_data" \( -type f -o -type l \) -print | LC_ALL=C sort
	find "$gta_helper_test_game" "$gta_helper_test_data" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
	find "$gta_helper_test_game" "$gta_helper_test_data" -type l -exec readlink {} \; | LC_ALL=C sort
}
gta_helper_negative_game="$gta_fixture/helper-orphan-negative-hash-game"
gta_helper_negative_data="$gta_fixture/helper-orphan-negative-hash-data"
gta_seed_case "$gta_helper_negative_game" "$gta_helper_negative_data"
gta_helper_negative_dir="$gta_helper_negative_data/pfx/$gta_helper_dir"
cp "$gta_fixture/vendor-v1.exe" "$gta_helper_negative_dir/SocialClubHelper_real.exe"
printf 'changed vendor bytes\n' > "$gta_helper_negative_dir/SocialClubHelper_real.exe"
gta_helper_test_game=$(CDPATH='' cd -P "$gta_helper_negative_game" && pwd -P)
gta_helper_test_data=$(CDPATH='' cd -P "$gta_helper_negative_data" && pwd -P)
gta_helper_negative_before=$(gta_helper_orphan_snapshot)
gta_orphan_helper_run_for "$gta_helper_test_game" "$gta_helper_test_data" "$gta_fixture/helper-negative-hash.log"
is "changed helper hash is refused" nonzero "$([ "$gta_orphan_helper_rc" -ne 0 ] && echo nonzero || echo 0)"
is "changed helper refusal makes no file changes" "$gta_helper_negative_before" "$(gta_helper_orphan_snapshot)"
is "changed helper refusal creates no quarantine" 0 "$(find "$gta_helper_negative_data" -maxdepth 1 -name '.bridgeplay-gta-sa-de-helper-orphan.*' | wc -l | tr -d ' ')"

gta_helper_mismatch_game="$gta_fixture/helper-orphan-mismatch-game"
gta_helper_mismatch_data="$gta_fixture/helper-orphan-mismatch-data"
gta_seed_case "$gta_helper_mismatch_game" "$gta_helper_mismatch_data"
gta_helper_mismatch_dir="$gta_helper_mismatch_data/pfx/$gta_helper_dir"
cp "$gta_fixture/vendor-v2.exe" "$gta_helper_mismatch_dir/SocialClubHelper_real.exe"
gta_helper_test_game=$(CDPATH='' cd -P "$gta_helper_mismatch_game" && pwd -P)
gta_helper_test_data=$(CDPATH='' cd -P "$gta_helper_mismatch_data" && pwd -P)
gta_helper_mismatch_before=$(gta_helper_orphan_snapshot)
gta_orphan_helper_run_for "$gta_helper_test_game" "$gta_helper_test_data" "$gta_fixture/helper-current-not-real.log"
is "current helper differing from saved real helper is refused" nonzero "$([ "$gta_orphan_helper_rc" -ne 0 ] && echo nonzero || echo 0)"
is "current-versus-real refusal makes no file changes" "$gta_helper_mismatch_before" "$(gta_helper_orphan_snapshot)"
is "current-versus-real refusal creates no quarantine" 0 "$(find "$gta_helper_mismatch_data" -maxdepth 1 -name '.bridgeplay-gta-sa-de-helper-orphan.*' | wc -l | tr -d ' ')"

gta_helper_wrapper_game="$gta_fixture/helper-orphan-wrapper-game"
gta_helper_wrapper_data="$gta_fixture/helper-orphan-wrapper-data"
gta_seed_case "$gta_helper_wrapper_game" "$gta_helper_wrapper_data"
gta_helper_wrapper_dir="$gta_helper_wrapper_data/pfx/$gta_helper_dir"
cp "$gta_fixture/wrapper.exe" "$gta_helper_wrapper_dir/SocialClubHelper.exe"
cp "$gta_fixture/vendor-v1.exe" "$gta_helper_wrapper_dir/SocialClubHelper_real.exe"
gta_helper_test_game=$(CDPATH='' cd -P "$gta_helper_wrapper_game" && pwd -P)
gta_helper_test_data=$(CDPATH='' cd -P "$gta_helper_wrapper_data" && pwd -P)
gta_helper_wrapper_before=$(gta_helper_orphan_snapshot)
gta_orphan_helper_run_for "$gta_helper_test_game" "$gta_helper_test_data" "$gta_fixture/helper-wrapper-current.log"
is "current wrapper is refused" nonzero "$([ "$gta_orphan_helper_rc" -ne 0 ] && echo nonzero || echo 0)"
is "current-wrapper refusal makes no file changes" "$gta_helper_wrapper_before" "$(gta_helper_orphan_snapshot)"
is "current-wrapper refusal creates no quarantine" 0 "$(find "$gta_helper_wrapper_data" -maxdepth 1 -name '.bridgeplay-gta-sa-de-helper-orphan.*' | wc -l | tr -d ' ')"

gta_helper_sidecar_game="$gta_fixture/helper-orphan-sidecar-game"
gta_helper_sidecar_data="$gta_fixture/helper-orphan-sidecar-data"
gta_seed_case "$gta_helper_sidecar_game" "$gta_helper_sidecar_data"
gta_helper_sidecar_dir="$gta_helper_sidecar_data/pfx/$gta_helper_dir"
cp "$gta_fixture/vendor-v1.exe" "$gta_helper_sidecar_dir/SocialClubHelper_real.exe"
printf 'unknown checksum bytes\n' > "$gta_helper_sidecar_dir/SocialClubHelper_real.exe.sha256"
gta_helper_test_game=$(CDPATH='' cd -P "$gta_helper_sidecar_game" && pwd -P)
gta_helper_test_data=$(CDPATH='' cd -P "$gta_helper_sidecar_data" && pwd -P)
gta_helper_sidecar_before=$(gta_helper_orphan_snapshot)
gta_orphan_helper_run_for "$gta_helper_test_game" "$gta_helper_test_data" "$gta_fixture/helper-unknown-sidecar.log"
is "unknown helper sidecar is refused" nonzero "$([ "$gta_orphan_helper_rc" -ne 0 ] && echo nonzero || echo 0)"
is "unknown sidecar refusal makes no file changes" "$gta_helper_sidecar_before" "$(gta_helper_orphan_snapshot)"
is "unknown sidecar refusal creates no quarantine" 0 "$(find "$gta_helper_sidecar_data" -maxdepth 1 -name '.bridgeplay-gta-sa-de-helper-orphan.*' | wc -l | tr -d ' ')"

gta_helper_state_mode_game="$gta_fixture/helper-orphan-state-mode-game"
gta_helper_state_mode_data="$gta_fixture/helper-orphan-state-mode-data"
gta_seed_case "$gta_helper_state_mode_game" "$gta_helper_state_mode_data"
gta_helper_state_mode_dir="$gta_helper_state_mode_data/.bridgeplay-gta-sa-de-1547000"
mkdir -m 755 "$gta_helper_state_mode_dir"
cp "$gta_fixture/vendor-v1.exe" "$gta_helper_state_mode_data/pfx/$gta_helper_dir/SocialClubHelper_real.exe"
gta_helper_test_game=$(CDPATH='' cd -P "$gta_helper_state_mode_game" && pwd -P)
gta_helper_test_data=$(CDPATH='' cd -P "$gta_helper_state_mode_data" && pwd -P)
gta_helper_state_mode_before=$(gta_helper_orphan_snapshot)
gta_orphan_helper_run_for "$gta_helper_test_game" "$gta_helper_test_data" "$gta_fixture/helper-unsafe-state-mode.log"
is "non-private owner state directory is refused" nonzero "$([ "$gta_orphan_helper_rc" -ne 0 ] && echo nonzero || echo 0)"
is "unsafe state-directory refusal makes no file changes" "$gta_helper_state_mode_before" "$(gta_helper_orphan_snapshot)"
is "unsafe state-directory mode is not changed" 755 "$(stat -f %Lp "$gta_helper_state_mode_dir")"
is "unsafe state-directory refusal creates no quarantine" 0 "$(find "$gta_helper_state_mode_data" -maxdepth 1 -name '.bridgeplay-gta-sa-de-helper-orphan.*' | wc -l | tr -d ' ')"

echo "== recovery preserves a changed target"
gta_crash_changed_game="$gta_fixture/crash-changed-game"
gta_crash_changed_data="$gta_fixture/crash-changed-data"
gta_seed_case "$gta_crash_changed_game" "$gta_crash_changed_data"
gta_crash_rc=0
gta_crash_helper_call "$gta_crash_changed_data" "$gta_crash_changed_game" prepare 1 >/dev/null 2>&1 || gta_crash_rc=$?
is "changed-target fixture crashes during prepare" 137 "$gta_crash_rc"
printf 'user change after interrupted install' > "$gta_crash_changed_game/Gameface/Binaries/Win64/d3d11.dll"
gta_crash_recovery_rc=0
gta_crash_recovery_result=$(gta_crash_helper_call "$gta_crash_changed_data" "$gta_crash_changed_game" prepare 2>&1) || gta_crash_recovery_rc=$?
is "recovery stops on an unrecognized changed target" 5 "$gta_crash_recovery_rc"
printf '%s\n' "$gta_crash_recovery_result" > "$gta_fixture/crash-changed.log"
has "recovery reports its conflict" "transaction-recovery-conflict" "$gta_fixture/crash-changed.log"
is "recovery preserves the changed target" "user change after interrupted install" "$(cat "$gta_crash_changed_game/Gameface/Binaries/Win64/d3d11.dll")"
gta_pending_status=$(gta_helper_call "$gta_crash_changed_data" "$gta_crash_changed_game" status)
is "recovery conflict keeps the journal for inspection" ready-owned "$gta_pending_status"

echo "== recovery preserves a changed staged file"
gta_crash_stage_game="$gta_fixture/crash-stage-game"
gta_crash_stage_data="$gta_fixture/crash-stage-data"
gta_seed_case "$gta_crash_stage_game" "$gta_crash_stage_data"
gta_crash_rc=0
gta_crash_helper_call "$gta_crash_stage_data" "$gta_crash_stage_game" prepare 1 >/dev/null 2>&1 || gta_crash_rc=$?
is "changed-stage fixture crashes during prepare" 137 "$gta_crash_rc"
gta_changed_stage=$(find "$gta_crash_stage_game" "$gta_crash_stage_data" -type f \
	-name '.bridgeplay-gta-sa-de-*.tmp' ! -name '.bridgeplay-gta-sa-de-journal-*.tmp' | head -1)
if [ -n "$gta_changed_stage" ]; then
	printf 'user change to registered stage' > "$gta_changed_stage"
	gta_crash_recovery_rc=0
	gta_crash_recovery_result=$(gta_crash_helper_call "$gta_crash_stage_data" "$gta_crash_stage_game" prepare 2>&1) || gta_crash_recovery_rc=$?
	is "recovery stops on a changed registered stage" nonzero "$([ "$gta_crash_recovery_rc" -ne 0 ] && echo nonzero || echo 0)"
	is "recovery preserves changed staged bytes" "user change to registered stage" "$(cat "$gta_changed_stage")"
	gta_pending_status=$(gta_helper_call "$gta_crash_stage_data" "$gta_crash_stage_game" status)
	is "changed staged bytes keep the journal" ready-owned "$gta_pending_status"
else
	bad "changed-stage fixture has a registered temp to edit" present missing
fi

echo "== unsupported vendor, conflicting DLL and symlink stop before writes"
gta_unknown_vendor_game="$gta_fixture/unknown-vendor-game"
gta_unknown_vendor_data="$gta_fixture/unknown-vendor-data"
gta_seed_case "$gta_unknown_vendor_game" "$gta_unknown_vendor_data"
printf 'unknown vendor helper' > "$gta_unknown_vendor_data/pfx/$gta_helper_dir/SocialClubHelper.exe"
gta_before=$(find "$gta_unknown_vendor_data" -type f | wc -l | tr -d ' ')
gta_case_rc=0
gta_case_result=$(gta_helper_call "$gta_unknown_vendor_data" "$gta_unknown_vendor_game" prepare 2>&1) || gta_case_rc=$?
printf '%s\n' "$gta_case_result" > "$gta_fixture/unknown-vendor.log"
is "unsupported vendor helper fails preparation" nonzero "$([ "$gta_case_rc" -ne 0 ] && echo nonzero || echo 0)"
has "unsupported vendor helper has a diagnostic" "unsupported-vendor-helper" "$gta_fixture/unknown-vendor.log"
is "unsupported vendor helper causes no writes" "$gta_before" "$(find "$gta_unknown_vendor_data" -type f | wc -l | tr -d ' ')"
gta_paths "$gta_unknown_vendor_data" "$gta_unknown_vendor_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "unsupported vendor soft-skips the main launch" 0 "$gta_launch_rc"
has "unsupported vendor soft-skip is logged" "automatic setup skipped: unsupported input (exit 3): gta-sa-de: unsupported-vendor-helper" "$log"
is "unsupported vendor launch does not create ownership state" "$gta_before" "$(find "$gta_unknown_vendor_data" -type f | wc -l | tr -d ' ')"

gta_missing_social_data="$gta_fixture/missing-social-data"
gta_missing_social_game="$gta_fixture/missing-social-game"
mkdir -p "$gta_missing_social_data/pfx"
mkdir -p "$gta_missing_social_game/Gameface/Binaries/Win64"
cp "$gta_game/Gameface/Binaries/Win64/SanAndreas.exe" "$gta_missing_social_game/Gameface/Binaries/Win64/SanAndreas.exe"
gta_paths "$gta_missing_social_data" "$gta_missing_social_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing Social Club files soft-skip the main launch" 0 "$gta_launch_rc"
has "missing Social Club files are logged as unsupported input" "automatic setup skipped: unsupported input (exit 3): gta-sa-de: social-club-directory-unavailable" "$log"
is "missing Social Club files create no ownership state" 0 "$(find "$gta_missing_social_data" -type f | wc -l | tr -d ' ')"

gta_conflict_game="$gta_fixture/conflicting-dll-game"
gta_conflict_prefix_data="$gta_fixture/conflicting-dll-data"
gta_seed_case "$gta_conflict_game" "$gta_conflict_prefix_data"
printf 'unknown game DLL' > "$gta_conflict_game/Gameface/Binaries/Win64/d3d11.dll"
gta_before=$(find "$gta_conflict_prefix_data" -type f | wc -l | tr -d ' ')
gta_case_rc=0
gta_case_result=$(gta_helper_call "$gta_conflict_prefix_data" "$gta_conflict_game" prepare 2>&1) || gta_case_rc=$?
printf '%s\n' "$gta_case_result" > "$gta_fixture/conflicting-dll.log"
is "unknown game DLL fails preparation" nonzero "$([ "$gta_case_rc" -ne 0 ] && echo nonzero || echo 0)"
has "unknown game DLL has a diagnostic" "game-dll-conflict" "$gta_fixture/conflicting-dll.log"
is "unknown game DLL is preserved" "unknown game DLL" "$(cat "$gta_conflict_game/Gameface/Binaries/Win64/d3d11.dll")"
is "unknown game DLL causes no writes" "$gta_before" "$(find "$gta_conflict_prefix_data" -type f | wc -l | tr -d ' ')"

gta_symlink_game="$gta_fixture/symlink-game"
gta_symlink_data="$gta_fixture/symlink-data"
gta_seed_case "$gta_symlink_game" "$gta_symlink_data"
printf 'symlink target' > "$gta_fixture/dll-link-target"
ln -s "$gta_fixture/dll-link-target" "$gta_symlink_game/Gameface/Binaries/Win64/dxgi.dll"
gta_before=$(find "$gta_symlink_data" \( -type f -o -type l \) | wc -l | tr -d ' ')
gta_case_rc=0
gta_case_result=$(gta_helper_call "$gta_symlink_data" "$gta_symlink_game" prepare 2>&1) || gta_case_rc=$?
printf '%s\n' "$gta_case_result" > "$gta_fixture/symlink.log"
is "symlink target fails preparation" nonzero "$([ "$gta_case_rc" -ne 0 ] && echo nonzero || echo 0)"
has "symlink target has a diagnostic" "game-dll-symlink-or-nonfile" "$gta_fixture/symlink.log"
is "game-local symlink is preserved" yes "$(test -L "$gta_symlink_game/Gameface/Binaries/Win64/dxgi.dll" && echo yes || echo no)"
is "symlink target causes no writes" "$gta_before" "$(find "$gta_symlink_data" \( -type f -o -type l \) | wc -l | tr -d ' ')"

gta_partial_game="$gta_fixture/partial-dll-game"
gta_partial_data="$gta_fixture/partial-dll-data"
gta_seed_case "$gta_partial_game" "$gta_partial_data"
cp "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/dxgi.dll" "$gta_partial_game/Gameface/Binaries/Win64/dxgi.dll"
gta_partial_before=$(find "$gta_partial_data" -type f | wc -l | tr -d ' ')
gta_partial_rc=0
gta_partial_result=$(gta_helper_call "$gta_partial_data" "$gta_partial_game" prepare 2>&1) || gta_partial_rc=$?
printf '%s\n' "$gta_partial_result" > "$gta_fixture/partial-dll.log"
is "one preexisting matching DLL refuses partial preparation" 4 "$gta_partial_rc"
has "partial DLL set is diagnosed" "partial-game-dll-set" "$gta_fixture/partial-dll.log"
is "the matching DLL is preserved" yes "$(cmp -s "$gta_partial_game/Gameface/Binaries/Win64/dxgi.dll" "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/dxgi.dll" && echo yes || echo no)"
is "partial DLL set installs no other game DLLs" 1 "$(find "$gta_partial_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"
is "partial DLL set writes no prefix state" "$gta_partial_before" "$(find "$gta_partial_data" -type f | wc -l | tr -d ' ')"

gta_ancestor_game="$gta_fixture/ancestor-game"
gta_ancestor_target="$gta_fixture/ancestor-target/Binaries/Win64"
gta_ancestor_data="$gta_fixture/ancestor-data"
mkdir -p "$gta_ancestor_game/Gameface" "$gta_ancestor_target" "$gta_ancestor_data/pfx"
cp "$gta_game/Gameface/Binaries/Win64/SanAndreas.exe" "$gta_ancestor_target/SanAndreas.exe"
ln -s "$gta_fixture/ancestor-target/Binaries" "$gta_ancestor_game/Gameface/Binaries"
gta_seed_vendor "$gta_ancestor_data"
gta_ancestor_rc=0
gta_ancestor_result=$(gta_helper_call "$gta_ancestor_data" "$gta_ancestor_game" prepare 2>&1) || gta_ancestor_rc=$?
printf '%s\n' "$gta_ancestor_result" > "$gta_fixture/ancestor.log"
is "symlinked game directory ancestor returns the expected error" 4 "$gta_ancestor_rc"
has "symlinked game directory ancestor is identified" "transaction-symlink-or-file-ancestor" "$gta_fixture/ancestor.log"
is "symlinked game directory ancestor installs no DLLs" 0 "$(find "$gta_ancestor_target" -name '*.dll' | wc -l | tr -d ' ')"
is "symlinked game directory ancestor writes no state" 1 "$(find "$gta_ancestor_data" -type f | wc -l | tr -d ' ')"

echo "== staging failure cleans preflighted DLL copies"
gta_stage_game="$gta_fixture/staging-failure-game"
gta_stage_data="$gta_fixture/staging-failure-data"
gta_seed_case "$gta_stage_game" "$gta_stage_data"
gta_stage_helper="$gta_stage_data/pfx/$gta_helper_dir"
chmod 555 "$gta_stage_helper"
gta_stage_rc=0
gta_stage_result=$(gta_helper_call "$gta_stage_data" "$gta_stage_game" prepare 2>&1) || gta_stage_rc=$?
chmod 755 "$gta_stage_helper"
printf '%s\n' "$gta_stage_result" > "$gta_fixture/staging-failure.log"
is "unwritable helper directory fails preparation" nonzero "$([ "$gta_stage_rc" -ne 0 ] && echo nonzero || echo 0)"
is "staging failure leaves no game DLLs" 0 "$(find "$gta_stage_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"
is "staging failure keeps the vendor helper" yes "$(cmp -s "$gta_stage_helper/SocialClubHelper.exe" "$gta_fixture/vendor-v1.exe" && echo yes || echo no)"
is "staging failure creates no real-helper backup" no "$(test -e "$gta_stage_helper/SocialClubHelper_real.exe" && echo yes || echo no)"
is "staging failure writes no private state" 0 "$(find "$gta_stage_data" -name state.json | wc -l | tr -d ' ')"
is "staging failure leaves no transaction temps" 0 "$(find "$gta_stage_game" "$gta_stage_data" -name '.bridgeplay-gta-sa-de-*.tmp' | wc -l | tr -d ' ')"

echo "== fresh and idempotent preparation"
gta_data_a="$gta_fixture/data-a"
mkdir -p "$gta_data_a/pfx"
gta_seed_vendor "$gta_data_a"
: > "$log"
gta_paths "$gta_data_a" "$gta_game"
gta_status_files=$(find "$gta_data_a" -type f | wc -l | tr -d ' ')
gta_initial=$(gta_helper_call "$gta_data_a" "$gta_game" status)
is "fresh status is read-only and ready" ready "$gta_initial"
is "fresh status creates no state" "$gta_status_files" "$(find "$gta_data_a" -type f | wc -l | tr -d ' ')"
gamefix_backend=wined3d gamefix_from_BACKEND=global
gta_sa_de_run
is "automatic per-game backend overrides a global default" dxvk "$gamefix_backend"
is "successful preparation adds native-first DXGI" dxgi=n,b "$gamefix_dlloverrides"
has "automatic preparation is logged" "ready: prepared" "$log"
gta_helper_a="$WINEPREFIX/$gta_helper_dir"
is "original Social Club helper is preserved" yes "$(cmp -s "$gta_helper_a/SocialClubHelper_real.exe" "$gta_fixture/vendor-v1.exe" && echo yes || echo no)"
is "Social Club wrapper is installed" yes "$(cmp -s "$gta_helper_a/SocialClubHelper.exe" "$gta_fixture/wrapper.exe" && echo yes || echo no)"
is "game-local DXMT DLL is installed" yes "$(cmp -s "$gta_game/Gameface/Binaries/Win64/dxgi.dll" "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/dxgi.dll" && echo yes || echo no)"
gta_shared_metadata="$gta_game/.bridgeplay-gta-sa-de-1547000.json"
gta_shared_lock="$gta_game/.bridgeplay-gta-sa-de-1547000.lock"
gta_private_metadata="$gta_data_a/.bridgeplay-gta-sa-de-1547000"
is "shared ownership metadata is public-readable" 644 "$(stat -f %Lp "$gta_shared_metadata")"
is "shared lock is public-readable" 644 "$(stat -f %Lp "$gta_shared_lock")"
is "prefix ownership directory remains private" 700 "$(stat -f %Lp "$gta_private_metadata")"
is "prefix ownership file remains private" 600 "$(stat -f %Lp "$gta_private_metadata/state.json")"
gta_shared_read_source=$(sed -n '/private func readSharedData/,/^    }/p' "$repo_root/helpers/gamefix-prep.swift")
gta_shared_uid_check=$(printf '%s\n' "$gta_shared_read_source" | grep -q 'geteuid' && echo yes || echo no)
is "shared metadata read has no single-UID ownership check" no "$gta_shared_uid_check"
{
	printf 'import Foundation\nimport Darwin\n'
	sed -n '/^private enum SharedDataModePolicy {$/,/^}/p' "$repo_root/helpers/gamefix-prep.swift"
	sed -n '/^private func sharedDataModePolicy(/,/^}/p' "$repo_root/helpers/gamefix-prep.swift"
	cat <<'SWIFT'
func policyToken(owner: uid_t, mode: mode_t, currentUID: uid_t) -> String {
    switch sharedDataModePolicy(owner: owner, mode: mode, currentUID: currentUID) {
    case .makePublic: return "make-public"
    case .accept: return "accept"
    case .reject: return "reject"
    }
}
print(policyToken(owner: 501, mode: mode_t(0o600), currentUID: 501))
print(policyToken(owner: 501, mode: mode_t(0o664), currentUID: 501))
print(policyToken(owner: 502, mode: mode_t(0o644), currentUID: 501))
print(policyToken(owner: 502, mode: mode_t(0o444), currentUID: 501))
SWIFT
} > "$gta_fixture/shared-data-mode-policy.swift"
swiftc -O -o "$gta_fixture/shared-data-mode-policy" "$gta_fixture/shared-data-mode-policy.swift"
gta_shared_policy_results=$("$gta_fixture/shared-data-mode-policy")
is "shared metadata mode policy covers current and foreign owners" 'make-public
reject
accept
reject' "$gta_shared_policy_results"
gta_shared_lock_source=$(sed -n '/^private func acquireSharedLock/,/^}/p' "$repo_root/helpers/gamefix-prep.swift")
gta_shared_lock_readonly=$(printf '%s\n' "$gta_shared_lock_source" | grep -q 'O_RDONLY' && echo yes || echo no)
is "shared lock opens read-only" yes "$gta_shared_lock_readonly"
gta_shared_lock_uses_flock=$(printf '%s\n' "$gta_shared_lock_source" | grep -q 'flock(fd, LOCK_EX | LOCK_NB)' && echo yes || echo no)
is "shared read-only descriptor is flock-locked" yes "$gta_shared_lock_uses_flock"
gta_shared_lock_public_uid_branch=$(printf '%s\n' "$gta_shared_lock_source" | grep -q 'else if info.st_mode & mode_t(0o777) != mode_t(0o644)' && echo yes || echo no)
is "shared lock accepts other UIDs with public mode" yes "$gta_shared_lock_public_uid_branch"
gta_shared_status=$(gta_helper_call "$gta_data_a" "$gta_game" status)
is "shared public metadata can be read during status" prepared "$gta_shared_status"

echo "== shared DXMT state keeps a fresh prefix strict"
gta_shared_b_data="$gta_fixture/shared-b-data"
mkdir -p "$gta_shared_b_data/pfx"
gta_seed_vendor "$gta_shared_b_data"
gta_shared_b_status=$(gta_helper_call "$gta_shared_b_data" "$gta_game" status)
is "fresh prefix sees shared managed DLLs as owned setup" ready-owned "$gta_shared_b_status"
rm -f "$gta_fixture/runner/dxvk.available" \
	"$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
gta_paths "$gta_shared_b_data" "$gta_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing DXVK hard-stops a fresh prefix with shared DLLs" nonzero "$([ "$gta_launch_rc" -ne 0 ] && echo nonzero || echo 0)"
has "shared DLL hard stop requires DXVK" "managed setup needs the WineCX DXVK runtime" "$log"
is "shared DLL hard stop creates no B state" 0 "$(find "$gta_shared_b_data" -name state.json | wc -l | tr -d ' ')"
is "shared DLL hard stop leaves DXMT files in place" yes "$(cmp -s "$gta_game/Gameface/Binaries/Win64/dxgi.dll" "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/dxgi.dll" && echo yes || echo no)"
touch "$gta_fixture/runner/dxvk.available"
printf 'fixture dxvk d3d10core' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"

gta_shared_unknown_vendor_data="$gta_fixture/shared-unknown-vendor-data"
mkdir -p "$gta_shared_unknown_vendor_data/pfx/$gta_helper_dir"
printf 'unknown Social Club helper' > "$gta_shared_unknown_vendor_data/pfx/$gta_helper_dir/SocialClubHelper.exe"
rm -f "$gta_fixture/runner/dxvk.available" \
	"$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
gta_shared_unknown_vendor_rc=0
gta_shared_unknown_vendor_result=$(gta_helper_call "$gta_shared_unknown_vendor_data" "$gta_game" status 2>&1) || gta_shared_unknown_vendor_rc=$?
is "unknown Social Club input is strict beside shared DLLs" 4 "$gta_shared_unknown_vendor_rc"
printf '%s\n' "$gta_shared_unknown_vendor_result" > "$gta_fixture/shared-unknown-vendor.log"
has "shared DLL unknown-helper status is diagnosed" "unsupported-vendor-helper" "$gta_fixture/shared-unknown-vendor.log"
gta_paths "$gta_shared_unknown_vendor_data" "$gta_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "unknown Social Club input cannot soft-skip beside shared DLLs" 4 "$gta_launch_rc"
has "shared DLL unknown-helper hard stop is logged" "status check failed (exit 4)" "$log"
is "unknown Social Club hard stop preserves the helper" "unknown Social Club helper" "$(cat "$gta_shared_unknown_vendor_data/pfx/$gta_helper_dir/SocialClubHelper.exe")"
touch "$gta_fixture/runner/dxvk.available"
printf 'fixture dxvk d3d10core' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"

gta_shared_unknown_data="$gta_fixture/shared-unknown-data"
mkdir -p "$gta_shared_unknown_data/pfx"
gta_shared_unknown_rc=0
gta_shared_unknown_result=$(gta_helper_call "$gta_shared_unknown_data" "$gta_game" status 2>&1) || gta_shared_unknown_rc=$?
is "missing Social Club input is strict beside shared DLLs" 4 "$gta_shared_unknown_rc"
printf '%s\n' "$gta_shared_unknown_result" > "$gta_fixture/shared-unknown.log"
has "shared DLL missing-helper status is diagnosed" "social-club-directory-unavailable" "$gta_fixture/shared-unknown.log"
gta_paths "$gta_shared_unknown_data" "$gta_game"
: > "$log"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing Social Club input cannot soft-skip a fresh shared prefix" 4 "$gta_launch_rc"
has "shared DLL missing-helper hard stop is logged" "status check failed (exit 4)" "$log"
is "missing Social Club hard stop creates no B state" 0 "$(find "$gta_shared_unknown_data" -name state.json | wc -l | tr -d ' ')"

gta_wrapper_inode=$(stat -f %i "$gta_helper_a/SocialClubHelper.exe")
gta_dxgi_inode=$(stat -f %i "$gta_game/Gameface/Binaries/Win64/dxgi.dll")
: > "$log"
gta_paths "$gta_data_a" "$gta_game"
gta_sa_de_run
is "repeat launch keeps the wrapper inode" "$gta_wrapper_inode" "$(stat -f %i "$WINEPREFIX/$gta_helper_dir/SocialClubHelper.exe")"
is "repeat launch keeps the DXMT inode" "$gta_dxgi_inode" "$(stat -f %i "$gta_game/Gameface/Binaries/Win64/dxgi.dll")"
has "repeat launch reports prepared" "ready: prepared" "$log"

echo "== restore preserves a modified game DLL"
gta_modified_game="$gta_fixture/modified-game"
gta_modified_data="$gta_fixture/modified-data"
gta_seed_case "$gta_modified_game" "$gta_modified_data"
gta_modified_prepare=$(gta_helper_call "$gta_modified_data" "$gta_modified_game" prepare)
is "modified-file fixture starts prepared" prepared "$gta_modified_prepare"
printf 'user modification' > "$gta_modified_game/Gameface/Binaries/Win64/dxgi.dll"
gta_modified_restore=$(gta_helper_call "$gta_modified_data" "$gta_modified_game" restore)
is "modified-file rollback succeeds" restored "$gta_modified_restore"
is "modified game DLL is left intact" "user modification" "$(cat "$gta_modified_game/Gameface/Binaries/Win64/dxgi.dll")"

echo "== restore with missing shared metadata leaves shared DLLs alone"
gta_missing_shared_game="$gta_fixture/missing-shared-game"
gta_missing_shared_data="$gta_fixture/missing-shared-data"
gta_seed_case "$gta_missing_shared_game" "$gta_missing_shared_data"
gta_missing_shared_prepare=$(gta_helper_call "$gta_missing_shared_data" "$gta_missing_shared_game" prepare)
is "missing shared-state fixture starts prepared" prepared "$gta_missing_shared_prepare"
rm "$gta_missing_shared_game/.bridgeplay-gta-sa-de-1547000.json"
gta_missing_shared_restore=$(gta_helper_call "$gta_missing_shared_data" "$gta_missing_shared_game" restore)
is "restore succeeds without shared ownership metadata" restored "$gta_missing_shared_restore"
is "missing metadata preserves game-local DXMT" 3 "$(find "$gta_missing_shared_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"
is "missing metadata preserves verified DLL bytes" yes "$(cmp -s "$gta_missing_shared_game/Gameface/Binaries/Win64/dxgi.dll" "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/dxgi.dll" && echo yes || echo no)"

echo "== restore preserves an unknown current vendor helper while cleaning owned files"
gta_unknown_restore_game="$gta_fixture/unknown-restore-game"
gta_unknown_restore_data="$gta_fixture/unknown-restore-data"
gta_seed_case "$gta_unknown_restore_game" "$gta_unknown_restore_data"
gta_unknown_restore_prepare=$(gta_helper_call "$gta_unknown_restore_data" "$gta_unknown_restore_game" prepare)
is "unknown vendor restore fixture starts prepared" prepared "$gta_unknown_restore_prepare"
printf 'unrecognized vendor helper after update' > "$gta_unknown_restore_data/pfx/$gta_helper_dir/SocialClubHelper.exe"
gta_unknown_restore=$(gta_helper_call "$gta_unknown_restore_data" "$gta_unknown_restore_game" restore)
is "restore tolerates an unknown regular helper" restored "$gta_unknown_restore"
is "restore preserves the unknown regular helper" "unrecognized vendor helper after update" "$(cat "$gta_unknown_restore_data/pfx/$gta_helper_dir/SocialClubHelper.exe")"
is "restore removes verified owned DXMT files" 0 "$(find "$gta_unknown_restore_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"

echo "== restore replaces a missing current helper from its verified backup"
gta_missing_helper_game="$gta_fixture/missing-current-helper-game"
gta_missing_helper_data="$gta_fixture/missing-current-helper-data"
gta_seed_case "$gta_missing_helper_game" "$gta_missing_helper_data"
gta_missing_helper_prepare=$(gta_helper_call "$gta_missing_helper_data" "$gta_missing_helper_game" prepare)
is "missing current-helper fixture starts prepared" prepared "$gta_missing_helper_prepare"
rm "$gta_missing_helper_data/pfx/$gta_helper_dir/SocialClubHelper.exe"
gta_missing_helper_restore=$(gta_helper_call "$gta_missing_helper_data" "$gta_missing_helper_game" restore)
is "restore reinstalls a missing helper from verified backup" restored "$gta_missing_helper_restore"
is "restored missing helper matches vendor binary" yes "$(cmp -s "$gta_missing_helper_data/pfx/$gta_helper_dir/SocialClubHelper.exe" "$gta_fixture/vendor-v1.exe" && echo yes || echo no)"
is "missing-helper restore removes owned game DLLs" 0 "$(find "$gta_missing_helper_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"

echo "== manual adoption and opt-out preserve manual files"
gta_manual_game="$gta_fixture/manual-game"
mkdir -p "$gta_manual_game/Gameface/Binaries/Win64"
cp "$gta_game/Gameface/Binaries/Win64/SanAndreas.exe" "$gta_manual_game/Gameface/Binaries/Win64/SanAndreas.exe"
gta_manual_data="$gta_fixture/manual-data"
gta_manual_prefix="$gta_manual_data/pfx"
gta_manual_helper="$gta_manual_prefix/$gta_helper_dir"
mkdir -p "$gta_manual_helper"
for name in d3d11.dll dxgi.dll d3d10core.dll; do
	cp "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/$name" "$gta_manual_game/Gameface/Binaries/Win64/$name"
done
cp "$gta_fixture/wrapper.exe" "$gta_manual_helper/SocialClubHelper.exe"
cp "$gta_fixture/vendor-v1.exe" "$gta_manual_helper/SocialClubHelper_real.exe"
printf '%s  SocialClubHelper_real.exe\n' "$(cat "$gta_fixture/vendor1.sha")" > "$gta_manual_helper/SocialClubHelper_real.exe.sha256"
cp "$gta_fixture/license.txt" "$gta_manual_helper/SocialClubHelper.bridgeplay.LICENSE"
gta_manual_status=$(gta_helper_call "$gta_manual_data" "$gta_manual_game" status)
is "matching manual fixture is reported as unowned manual state" manual "$gta_manual_status"
rm -f "$gta_fixture/runner/dxvk.available" \
	"$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
: > "$log"
gta_paths "$gta_manual_data" "$gta_manual_game"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing DXVK hard-stops actual manual matching files" nonzero "$([ "$gta_launch_rc" -ne 0 ] && echo nonzero || echo 0)"
has "actual manual matching hard stop is logged" "matching manual setup needs the WineCX DXVK runtime" "$log"
is "actual manual hard stop creates no private state" 0 "$(find "$gta_manual_data" -name state.json | wc -l | tr -d ' ')"
is "actual manual hard stop preserves wrapper" yes "$(cmp -s "$gta_manual_helper/SocialClubHelper.exe" "$gta_fixture/wrapper.exe" && echo yes || echo no)"
touch "$gta_fixture/runner/dxvk.available"
printf 'fixture dxvk d3d10core' > "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
: > "$log"
gta_paths "$gta_manual_data" "$gta_manual_game"
gta_sa_de_run
has "matching manual files are adopted" "ready: manual" "$log"
is "manual adoption writes no ownership state" 0 "$(find "$gta_manual_data" -name state.json | wc -l | tr -d ' ')"
gta_paths "$gta_manual_data" "$gta_manual_game" 1547000 waitforexitandrun 0
gta_sa_de_run
is "opt-out keeps manually adopted wrapper" yes "$(cmp -s "$gta_manual_helper/SocialClubHelper.exe" "$gta_fixture/wrapper.exe" && echo yes || echo no)"
is "opt-out keeps manually adopted DXMT" yes "$(cmp -s "$gta_manual_game/Gameface/Binaries/Win64/dxgi.dll" "$gta_runner/lib/notproton-backends/dxmt/x86_64-windows/dxgi.dll" && echo yes || echo no)"

echo "== two prefixes, manual shared reference, supported update and rollback"
gta_data_b="$gta_fixture/data-b"
gta_prefix_b="$gta_data_b/pfx"
gta_helper_b="$gta_prefix_b/$gta_helper_dir"
mkdir -p "$gta_helper_b"
cp "$gta_fixture/wrapper.exe" "$gta_helper_b/SocialClubHelper.exe"
cp "$gta_fixture/vendor-v1.exe" "$gta_helper_b/SocialClubHelper_real.exe"
printf '%s  SocialClubHelper_real.exe\n' "$(cat "$gta_fixture/vendor1.sha")" > "$gta_helper_b/SocialClubHelper_real.exe.sha256"
cp "$gta_fixture/license.txt" "$gta_helper_b/SocialClubHelper.bridgeplay.LICENSE"
gta_paths "$gta_data_b" "$gta_game"
gta_sa_de_run
has "second prefix adopts its manual Social Club helper" "ready: adopted-manual" "$log"
is "manual second-prefix helper stays unchanged" yes "$(cmp -s "$gta_helper_b/SocialClubHelper.exe" "$gta_fixture/wrapper.exe" && echo yes || echo no)"
gta_paths "$gta_data_a" "$gta_game" 1547000 waitforexitandrun 0
gta_sa_de_run
is "restoring first prefix preserves the second reference's DLLs" yes "$(test -f "$gta_game/Gameface/Binaries/Win64/dxgi.dll" && echo yes || echo no)"
is "first prefix returns to vendor helper" yes "$(cmp -s "$WINEPREFIX/$gta_helper_dir/SocialClubHelper.exe" "$gta_fixture/vendor-v1.exe" && echo yes || echo no)"
gta_paths "$gta_data_b" "$gta_game" 1547000 waitforexitandrun 0
gta_sa_de_run
is "last rollback leaves the manual helper in place" yes "$(cmp -s "$gta_helper_b/SocialClubHelper.exe" "$gta_fixture/wrapper.exe" && echo yes || echo no)"
is "last rollback removes owned shared game DLLs" 0 "$(find "$gta_game/Gameface/Binaries/Win64" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"

echo "== library move keeps the shared ownership reference valid"
gta_library_before="$gta_fixture/library-before"
gta_library_after="$gta_fixture/library-after"
gta_library_data="$gta_fixture/library-data"
gta_seed_case "$gta_library_before" "$gta_library_data"
gta_library_prepare=$(gta_helper_call "$gta_library_data" "$gta_library_before" prepare)
is "library-move fixture starts prepared" prepared "$gta_library_prepare"
mv "$gta_library_before" "$gta_library_after"
gta_library_status=$(gta_helper_call "$gta_library_data" "$gta_library_after" status)
is "moved game install keeps its prepared state" prepared "$gta_library_status"
gta_library_restore=$(gta_helper_call "$gta_library_data" "$gta_library_after" restore)
is "restore after library move succeeds" restored "$gta_library_restore"
is "restore after library move removes owned DLLs" 0 "$(find "$gta_library_after/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"

echo "== cloned prefixes add a reference; moved prefixes migrate one"
gta_clone_game="$gta_fixture/clone-game"
gta_clone_original="$gta_fixture/clone-original-data"
gta_clone_copy="$gta_fixture/clone-copy-data"
gta_seed_case "$gta_clone_game" "$gta_clone_original"
gta_clone_initial=$(gta_helper_call "$gta_clone_original" "$gta_clone_game" prepare)
is "clone fixture starts prepared" prepared "$gta_clone_initial"
gta_clone_shared="$gta_clone_game/.bridgeplay-gta-sa-de-1547000.json"
gta_clone_original_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["references"][0])' "$gta_clone_shared")
ditto "$gta_clone_original" "$gta_clone_copy"
gta_clone_status=$(gta_helper_call "$gta_clone_copy" "$gta_clone_game" status)
is "cloned prefix is recognized as needing a reference update" ready-owned "$gta_clone_status"
gta_clone_prepare=$(gta_helper_call "$gta_clone_copy" "$gta_clone_game" prepare)
is "prepare adds the clone as a separate reference" prepared "$gta_clone_prepare"
gta_clone_refs=$(python3 -c 'import json,sys; refs=json.load(open(sys.argv[1]))["references"]; print("yes" if len(refs)==2 and sys.argv[2] in refs and len(set(refs))==2 else "no")' "$gta_clone_shared" "$gta_clone_original_id")
is "cloned prefix keeps both references" yes "$gta_clone_refs"
gta_clone_original_restore=$(gta_helper_call "$gta_clone_original" "$gta_clone_game" restore)
is "restoring the source clone keeps DLLs for the copy" yes "$(test -f "$gta_clone_game/Gameface/Binaries/Win64/dxgi.dll" && echo yes || echo no)"
gta_clone_copy_restore=$(gta_helper_call "$gta_clone_copy" "$gta_clone_game" restore)
is "restoring the final clone succeeds" restored "$gta_clone_copy_restore"
is "final clone restore removes shared DLLs" 0 "$(find "$gta_clone_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"

gta_move_game="$gta_fixture/moved-prefix-game"
gta_move_original="$gta_fixture/moved-prefix-data"
gta_move_destination="$gta_fixture/moved-prefix-data-new"
gta_seed_case "$gta_move_game" "$gta_move_original"
gta_move_initial=$(gta_helper_call "$gta_move_original" "$gta_move_game" prepare)
is "move fixture starts prepared" prepared "$gta_move_initial"
gta_move_shared="$gta_move_game/.bridgeplay-gta-sa-de-1547000.json"
gta_move_old_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["references"][0])' "$gta_move_shared")
mv "$gta_move_original" "$gta_move_destination"
gta_move_status=$(gta_helper_call "$gta_move_destination" "$gta_move_game" status)
is "moved prefix is recognized as needing reference migration" ready-owned "$gta_move_status"
gta_move_prepare=$(gta_helper_call "$gta_move_destination" "$gta_move_game" prepare)
is "prepare migrates the moved prefix reference" prepared "$gta_move_prepare"
gta_move_refs=$(python3 -c 'import json,sys; refs=json.load(open(sys.argv[1]))["references"]; print("yes" if len(refs)==1 and refs[0]!=sys.argv[2] else "no")' "$gta_move_shared" "$gta_move_old_id")
is "moved prefix replaces the old reference identity" yes "$gta_move_refs"
gta_move_restore=$(gta_helper_call "$gta_move_destination" "$gta_move_game" restore)
is "restore after prefix move succeeds" restored "$gta_move_restore"
is "restore after prefix move removes owned DLLs" 0 "$(find "$gta_move_game/Gameface/Binaries/Win64" -name '*.dll' | wc -l | tr -d ' ')"

echo "== supported launcher update and rollback"
gta_data_c="$gta_fixture/data-c"
mkdir -p "$gta_data_c/pfx"
gta_seed_vendor "$gta_data_c"
gta_paths "$gta_data_c" "$gta_game"
gta_sa_de_run
is "fresh prefix after shared restore prepares" prepared "$gta_sa_de_result"
gta_prefix_c="$gta_data_c/pfx"
gta_helper_c="$gta_prefix_c/$gta_helper_dir"
cp "$gta_fixture/vendor-v2.exe" "$gta_helper_c/SocialClubHelper.exe"
gta_paths "$gta_data_c" "$gta_game"
gta_sa_de_run
is "supported helper update is wrapped" yes "$(cmp -s "$gta_helper_c/SocialClubHelper.exe" "$gta_fixture/wrapper.exe" && echo yes || echo no)"
is "supported helper update preserves the new vendor binary" yes "$(cmp -s "$gta_helper_c/SocialClubHelper_real.exe" "$gta_fixture/vendor-v2.exe" && echo yes || echo no)"
gta_paths "$gta_data_c" "$gta_game" 1547000 waitforexitandrun 0
gta_sa_de_run
is "rollback restores the updated vendor helper" yes "$(cmp -s "$gta_helper_c/SocialClubHelper.exe" "$gta_fixture/vendor-v2.exe" && echo yes || echo no)"
is "last rollback removes owned game DLLs" 0 "$(find "$gta_game/Gameface/Binaries/Win64" \( -name 'd3d11.dll' -o -name 'dxgi.dll' -o -name 'd3d10core.dll' \) | wc -l | tr -d ' ')"

[ "$fails" -eq 0 ] || { echo "launchercheck: $fails failed"; exit 1; }
echo "launchercheck: all passed"
