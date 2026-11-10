#!/bin/sh
# Tests for native-launch/np-native.c.
#
#   sh native-launch/tests/run.sh [path/to/np-native]
#
# Without an argument the launcher is built into the temp dir. The probe
# program, the x86_64-only probe and the marker dylibs are always built here.
set -u

here=$(cd "$(dirname "$0")" && pwd)
src=$here/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/np-native-tests.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

CC=${CC:-clang}
UNI="-arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -Wall -Wextra -Werror"

fail=0
pass=0
ok() { pass=$((pass + 1)); echo "    ok   $1"; }
bad() { fail=$((fail + 1)); echo "    FAIL $1" >&2; }

# shellcheck disable=SC2086
build() { "$CC" $UNI "$@" || { echo "==> np-native-tests: build failed: $*" >&2; exit 1; }; }

if [ $# -ge 1 ]; then
	launcher=$1
else
	launcher=$tmp/np-native
	build "$src/np-native.c" -framework CoreFoundation -o "$launcher"
	codesign -s - -f "$launcher" 2>/dev/null
fi
[ -x "$launcher" ] || { echo "==> np-native-tests: no launcher at $launcher" >&2; exit 1; }

probe=$tmp/probe
build "$here/probe.c" -o "$probe"
"$CC" -arch x86_64 -mmacosx-version-min=11.0 -O2 "$here/probe.c" -o "$tmp/probe-x86" ||
	{ echo "==> np-native-tests: x86_64 probe build failed" >&2; exit 1; }

# fake HOME with real tiny dylibs where the launcher looks for them
H=$tmp/home
mkdir -p "$H/.bridgeplay" "$H/Library/Application Support/bridgeplay/gamefixes/native" "$tmp/libs"
pad=$H/.bridgeplay/libnp_gamepad.dylib
ov="$H/Library/Application Support/bridgeplay/overlay-shim.dylib"
steamlib=$tmp/libs/steamoverlay.dylib
build -dynamiclib -DMARKER='"pad"' "$here/marker.c" -o "$pad"
build -dynamiclib -DMARKER='"overlay"' "$here/marker.c" -o "$ov"
# arm64e too: without SIP (GitHub runners) dyld loads it into /usr/bin/arch
build -arch arm64e -dynamiclib -DMARKER='"steam"' "$here/marker.c" -o "$steamlib"
build -dynamiclib -DMARKER='"user"' "$here/marker.c" -o "$tmp/libs/user.dylib"
for f in "$launcher" "$probe" "$tmp/probe-x86" "$pad" "$ov" "$steamlib" "$tmp/libs/user.dylib"; do
	codesign -s - -f "$f" 2>/dev/null
done
confdir="$H/Library/Application Support/bridgeplay/gamefixes"

# run: clean env (env -i) with HOME pointing at the fake home; extra
# NAME=VALUE pairs before "--" go into the parent environment
run() {
	envs=""
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		envs="$envs
$1"
		shift
	done
	[ $# -gt 0 ] && shift
	(
		IFS='
'
		# shellcheck disable=SC2086
		exec env -i HOME="$H" PATH=/usr/bin:/bin $envs "$launcher" "$@"
	) >"$tmp/out" 2>"$tmp/err"
	rc=$?
}

has() { grep -qxF -- "$1" "$tmp/out" "$tmp/err" 2>/dev/null; }
expect() { # name, line...
	name=$1
	shift
	for line; do
		if ! grep -qxF -- "$line" "$tmp/out" && ! grep -qxF -- "$line" "$tmp/err"; then
			bad "$name: missing \"$line\""
			sed 's/^/         | /' "$tmp/out" "$tmp/err" >&2
			return
		fi
	done
	ok "$name"
}
expect_rc() { # name, rc
	if [ "$rc" -eq "$2" ]; then ok "$1"; else
		bad "$1: exit $rc, want $2"
		sed 's/^/         | /' "$tmp/out" "$tmp/err" >&2
	fi
}

echo "==> np-native-tests"

# --- VAR=VALUE parsing ---------------------------------------------------
mv "$pad" "$pad.off"
run NP_PROBE_VARS=FOO:BAZ:EMPTY -- FOO=bar BAZ="a b=c" EMPTY= "$probe" -novid "x y"
expect_rc "assignments: exit 0" 0
expect "assignments: values and game args" "FOO=bar" "BAZ=a b=c" "EMPTY=" "arg1=-novid" "arg2=x y"
run NP_PROBE_VARS=FOO -- FOO=1 -- "$probe" BAR=2
expect "assignments: -- ends assignments, later VAR=x stays an arg" "FOO=1" "arg1=BAR=2"
mv "$pad.off" "$pad"

# --- conf precedence -------------------------------------------------------
cat >"$confdir/native-default.conf" <<'EOF'
# defaults
A=def
B=def
C=def
P="$HOME/x"
EOF
cat >"$confdir/native/4242.conf" <<'EOF'
B=app
  C = app
EOF
run SteamAppId=4242 NP_PAD_MODE=off A=env D=env NP_PROBE_VARS=A:B:C:D:P -- C=arg "$probe"
expect_rc "conf: exit 0" 0
expect "conf: args > per-app > default > env" "A=def" "B=app" "C=arg" "D=env" "P=$H/x"
run SteamGameId=4242 NP_PAD_MODE=off NP_PROBE_VARS=B -- "$probe"
expect "conf: SteamGameId fallback" "B=app"
run SteamAppId=9999 NP_PAD_MODE=off NP_PROBE_VARS=B -- "$probe"
expect "conf: other appid only gets default" "B=def"
run SteamAppId=../4242 NP_PAD_MODE=off NP_PROBE_VARS=B -- "$probe"
expect "conf: non-numeric appid ignored" "B=def"
rm -f "$confdir/native-default.conf" "$confdir/native/4242.conf"

# --- DYLD composition ------------------------------------------------------
V=NP_PROBE_VARS=DYLD_INSERT_LIBRARIES:STEAM_DYLD_INSERT_LIBRARIES
run "$V" "DYLD_INSERT_LIBRARIES=$steamlib" -- NP_PAD_MODE=hid BRIDGEPLAY_FRAMEGEN=1 "$probe"
expect_rc "dyld: exit 0" 0
expect "dyld: ours first, Steam's kept, all loaded" \
	"DYLD_INSERT_LIBRARIES=$pad:$ov:$steamlib" \
	"STEAM_DYLD_INSERT_LIBRARIES=$pad:$ov:$steamlib" \
	"loaded:pad" "loaded:overlay" "loaded:steam"
run "$V" "DYLD_INSERT_LIBRARIES=$pad:$steamlib" "STEAM_DYLD_INSERT_LIBRARIES=$steamlib" -- "$probe"
expect "dyld: de-duplicated, pad by default when shim exists" \
	"DYLD_INSERT_LIBRARIES=$pad:$steamlib"
run "$V" "STEAM_DYLD_INSERT_LIBRARIES=$steamlib" -- NP_PAD_MODE=off BRIDGEPLAY_FRAMEGEN=0 "$probe"
expect "dyld: pad off, framegen 0, STEAM_DYLD_ only (SIP-stripped parent)" \
	"DYLD_INSERT_LIBRARIES=$steamlib" "loaded:steam"
if has "loaded:pad" || has "loaded:overlay"; then bad "dyld: off shims still loaded"; else ok "dyld: off shims not loaded"; fi
run "$V" "DYLD_INSERT_LIBRARIES=$steamlib" -- DYLD_INSERT_LIBRARIES="$tmp/libs/user.dylib" NP_PAD_MODE=gc "$probe"
expect "dyld: user list between ours and Steam's" \
	"DYLD_INSERT_LIBRARIES=$pad:$tmp/libs/user.dylib:$steamlib" "loaded:user"
run "$V" -- NP_PAD_MODE=off "$probe"
expect "dyld: nothing to inject leaves it unset" "DYLD_INSERT_LIBRARIES=(unset)"
run "$V" "STEAM_DYLD_INSERT_LIBRARIES=$tmp/libs/missing.dylib" -- NP_PAD_MODE=off "$probe"
expect "dyld: a STEAM_DYLD_ list of missing libraries is unset too" \
	"DYLD_INSERT_LIBRARIES=(unset)" "STEAM_DYLD_INSERT_LIBRARIES=(unset)"

# shell-script games (dota.sh): SIP strips DYLD_* in /bin/sh, the script
# restores it from STEAM_DYLD_INSERT_LIBRARIES
cat >"$tmp/game.sh" <<'EOF'
#!/bin/sh
echo "script DYLD=${DYLD_INSERT_LIBRARIES:-}"
echo "script STEAM_DYLD=${STEAM_DYLD_INSERT_LIBRARIES:-}"
EOF
chmod +x "$tmp/game.sh"
run "DYLD_INSERT_LIBRARIES=$steamlib" -- NP_PAD_MODE=hid "$tmp/game.sh"
expect_rc "script: exit 0" 0
expect "script: STEAM_DYLD_ carries the composed list" "script STEAM_DYLD=$pad:$steamlib"

# Steam passes some games as the .app bundle itself (Chained Beasts 3569420)
mkdir -p "$tmp/Game.app/Contents/MacOS"
cp "$probe" "$tmp/Game.app/Contents/MacOS/Game"
cat >"$tmp/Game.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Game</string></dict></plist>
EOF
run -- NP_PAD_MODE=off "$tmp/Game.app" -novid
expect_rc "bundle: exit 0" 0
expect "bundle: runs the bundle's executable, arm64" "arch=arm64" "arg1=-novid"

# --- architecture ----------------------------------------------------------
(exec env -i HOME="$H" PATH=/usr/bin:/bin NP_NATIVE_LOG=1 NP_PAD_MODE=hid \
	"DYLD_INSERT_LIBRARIES=$steamlib" \
	/usr/bin/arch -x86_64 "$launcher" "$probe") >"$tmp/out" 2>"$tmp/err"
rc=$?
expect_rc "arch: exit 0 from x86_64 parent" 0
expect "arch: launcher ran x86_64, game runs arm64" \
	"np-native: launcher arch x86_64; arch preference: arm64, x86_64" "arch=arm64" \
	"loaded:pad"
run NP_PAD_MODE=off -- "$tmp/probe-x86"
expect_rc "arch: x86_64-only program exit 0" 0
expect "arch: x86_64-only program runs" "arch=x86_64"
run NP_PAD_MODE=hid -- "$tmp/probe-x86"
expect "arch: x86_64-only program gets universal shim" "arch=x86_64" "loaded:pad"

# --- pid is kept (POSIX_SPAWN_SETEXEC) --------------------------------------
(exec env -i HOME="$H" PATH=/usr/bin:/bin NP_PAD_MODE=off \
	"$launcher" /bin/sh -c 'echo "shpid=$$"') >"$tmp/out" 2>"$tmp/err" &
bg=$!
wait "$bg"
expect "pid: program replaces the launcher" "shpid=$bg"

# --- errors -> 127 ---------------------------------------------------------
run -- FOO=1
expect_rc "error: no program" 127
run -- lower=1 "$probe"
expect_rc "error: invalid variable name" 127
run -- "$tmp/does-not-exist"
expect_rc "error: missing program" 127
run -- "$tmp"
expect_rc "error: program is a directory" 127
# --- fail open: problems outside the command line warn and still launch -----
V=NP_PROBE_VARS=DYLD_INSERT_LIBRARIES:STEAM_DYLD_INSERT_LIBRARIES
mv "$pad" "$pad.off"
run "$V" -- NP_PAD_MODE=hid "$probe"
expect_rc "fail open: NP_PAD_MODE set, shim missing: exit 0" 0
expect "fail open: missing pad shim warned and left out" \
	"np-native: warning: $pad does not exist; left out of DYLD_INSERT_LIBRARIES" \
	"arch=arm64" "DYLD_INSERT_LIBRARIES=(unset)"
run NP_PROBE_VARS=X -- X=1 "$probe"
expect_rc "no shim, NP_PAD_MODE unset: exit 0" 0
if grep -q warning "$tmp/err"; then bad "no shim, NP_PAD_MODE unset: unexpected warning"; else ok "no shim, NP_PAD_MODE unset: silent"; fi
mv "$pad.off" "$pad"
mv "$ov" "$ov.off"
run "$V" -- NP_PAD_MODE=off NOTPROTON_FRAMEGEN=1 "$probe"
expect_rc "fail open: framegen requested, overlay shim missing: exit 0" 0
expect "fail open: missing overlay shim warned and left out" \
	"np-native: warning: $ov does not exist; left out of DYLD_INSERT_LIBRARIES" \
	"DYLD_INSERT_LIBRARIES=(unset)"
mv "$ov.off" "$ov"
# (dyld reads DYLD_INSERT_LIBRARIES for the launcher itself, so the dead path
# arrives through STEAM_DYLD_INSERT_LIBRARIES, which only np-native reads)
run "$V" "DYLD_INSERT_LIBRARIES=$steamlib" "STEAM_DYLD_INSERT_LIBRARIES=$tmp/libs/gone.dylib:$steamlib" -- NP_PAD_MODE=hid "$probe"
expect_rc "fail open: nonexistent Steam library: exit 0" 0
expect "fail open: nonexistent Steam library dropped" \
	"np-native: warning: $tmp/libs/gone.dylib does not exist; left out of DYLD_INSERT_LIBRARIES" \
	"DYLD_INSERT_LIBRARIES=$pad:$steamlib" "loaded:pad" "loaded:steam"
printf 'GOOD=1\nthis line is junk\nbad-name=2\nLATER=3\n' >"$confdir/native-default.conf"
run NP_PROBE_VARS=GOOD:LATER -- NP_PAD_MODE=off "$probe"
expect_rc "fail open: malformed conf: exit 0" 0
expect "fail open: bad conf lines warned (file:line), good lines applied" \
	"np-native: warning: $confdir/native-default.conf:2: expected KEY=VALUE, got \"this line is junk\"; line skipped" \
	"np-native: warning: $confdir/native-default.conf:3: invalid variable name \"bad-name\"; line skipped" \
	"GOOD=1" "LATER=3" "arch=arm64"
rm -f "$confdir/native-default.conf"

# --- BRIDGEPLAY_ names and the pre-3.0 layout ----------------------------------
R=NP_PROBE_VARS=NOTPROTON_RETINA:BRIDGEPLAY_RETINA
run "$R" -- NP_PAD_MODE=off BRIDGEPLAY_RETINA=1 "$probe"
expect "names: a BRIDGEPLAY_ argument sets the NOTPROTON_ one" "NOTPROTON_RETINA=1" "BRIDGEPLAY_RETINA=1"
run "$R" -- NP_PAD_MODE=off NOTPROTON_RETINA=0 BRIDGEPLAY_RETINA=1 "$probe"
expect "names: NOTPROTON_ wins within one source" "NOTPROTON_RETINA=0"
run "$R" BRIDGEPLAY_RETINA=1 -- NP_PAD_MODE=off "$probe"
expect "names: a BRIDGEPLAY_ variable from Steam is mapped" "NOTPROTON_RETINA=1"
run "$R" BRIDGEPLAY_RETINA=1 NOTPROTON_RETINA=0 -- NP_PAD_MODE=off "$probe"
expect "names: a NOTPROTON_ variable from Steam is kept" "NOTPROTON_RETINA=0"
printf 'BRIDGEPLAY_RETINA=0\n' >"$confdir/native-default.conf"
run "$R" NOTPROTON_RETINA=1 -- NP_PAD_MODE=off "$probe"
expect "names: a conf BRIDGEPLAY_ beats the environment's NOTPROTON_" "NOTPROTON_RETINA=0"
printf 'NOTPROTON_RETINA=0\n' >"$confdir/native-default.conf"
run "$R" -- NP_PAD_MODE=off BRIDGEPLAY_RETINA=1 "$probe"
expect "names: a BRIDGEPLAY_ argument beats a conf NOTPROTON_" "NOTPROTON_RETINA=1"
rm -f "$confdir/native-default.conf"
run "$V" -- NP_PAD_MODE=off NOTPROTON_FRAMEGEN=1 "$probe"
expect "names: NOTPROTON_FRAMEGEN still loads the overlay shim" "DYLD_INSERT_LIBRARIES=$ov"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_PERF_OVERLAY=summary "$probe"
expect "the performance overlay loads the overlay shim" "DYLD_INSERT_LIBRARIES=$ov"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_PERF_OVERLAY=0 "$probe"
expect "a performance overlay that is off loads no shim" "DYLD_INSERT_LIBRARIES=(unset)"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_FPS_LIMIT=30 "$probe"
expect "a frame rate limit loads the overlay shim" "DYLD_INSERT_LIBRARIES=$ov"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_FPS_LIMIT=off "$probe"
expect "a frame rate limit that is off loads no shim" "DYLD_INSERT_LIBRARIES=(unset)"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_FPS_LIMIT=45 BRIDGEPLAY_FPS_LIMIT_OFF=1 "$probe"
expect "a limit switched off keeps its value and loads no shim" "DYLD_INSERT_LIBRARIES=(unset)"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_FPS_LIMIT=45 BRIDGEPLAY_FPS_LIMIT_OFF=0 "$probe"
expect "a limit switched back on loads the overlay shim" "DYLD_INSERT_LIBRARIES=$ov"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_SCALING_FILTER=nearest "$probe"
expect "a scaling filter loads the overlay shim" "DYLD_INSERT_LIBRARIES=$ov"
run "$V" -- NP_PAD_MODE=off BRIDGEPLAY_SCALING_FILTER=0 "$probe"
expect "the default scaling filter loads no shim" "DYLD_INSERT_LIBRARIES=(unset)"
# A home the app has not moved over yet: only ~/.notproton and .../notproton exist.
old_support="$H/Library/Application Support/notproton"
mv "$H/.bridgeplay" "$H/.notproton"
mv "$H/Library/Application Support/bridgeplay" "$old_support"
printf 'FROM=old\n' >"$old_support/gamefixes/native-default.conf"
run "$V" NP_PROBE_VARS=DYLD_INSERT_LIBRARIES:FROM -- NP_PAD_MODE=hid BRIDGEPLAY_FRAMEGEN=1 "$probe"
expect "legacy layout: shims and confs come from the old folders" \
	"DYLD_INSERT_LIBRARIES=$H/.notproton/libnp_gamepad.dylib:$old_support/overlay-shim.dylib" "FROM=old" \
	"loaded:pad" "loaded:overlay"
rm -f "$old_support/gamefixes/native-default.conf"
mv "$H/.notproton" "$H/.bridgeplay"
mv "$old_support" "$H/Library/Application Support/bridgeplay"

echo "==> np-native-tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
