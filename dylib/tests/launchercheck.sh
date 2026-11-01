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
for name in gta_sa_de_log gta_sa_de_dxvk_ready gta_sa_de_dxgi_mode gta_sa_de_dxgi_conflict gta_sa_de_dxgi_match gta_sa_de_conflict gta_sa_de_run; do
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
	"$repo_root/helpers/gamefix-prep.swift" "$gta_fixture/GTAFixPrepAssets.swift"

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
gta_helper_dir='drive_c/Program Files/Rockstar Games/Social Club'
gta_helper_call() {
	env GTA_SA_APP_ID=1547000 GTA_SA_DATA_PATH="$1" GTA_SA_PREFIX="$1/pfx" \
		GTA_SA_GAME="$2" GTA_SA_RUNNER="$gta_runner" GTA_SA_ENGINE_ID=winecx-11.17 \
		"$gta_helper" "$3"
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

echo "== DXVK availability is checked before preparation"
gta_no_dxvk_game="$gta_fixture/no-dxvk-game"
gta_no_dxvk_data="$gta_fixture/no-dxvk-data"
gta_seed_case "$gta_no_dxvk_game" "$gta_no_dxvk_data"
rm "$gta_fixture/runner/lib/notproton-backends/dxvk/x86_64-windows/d3d10core.dll"
: > "$log"
gta_paths "$gta_no_dxvk_data" "$gta_no_dxvk_game"
gta_launch_rc=0
(gta_sa_de_run) || gta_launch_rc=$?
is "missing DXVK component stops preparation" nonzero "$([ "$gta_launch_rc" -ne 0 ] && echo nonzero || echo 0)"
has "missing DXVK component is logged" "WineCX DXVK runtime is unavailable" "$log"
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
is "unsupported game build fails the main launch" nonzero "$([ "$gta_launch_rc" -ne 0 ] && echo nonzero || echo 0)"
has "unsupported game build is logged by the run hook" "status check failed: gta-sa-de: unsupported-game-build" "$log"
is "failed main launch still writes no game state" 0 "$(find "$gta_unknown_data" -type f | wc -l | tr -d ' ')"

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
has "symlinked game directory ancestor is identified" "unsafe-directory-chain" "$gta_fixture/ancestor.log"
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
