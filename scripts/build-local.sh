#!/bin/sh
# Build the whole app on this Mac the way .github/workflows/app.yml does on CI.
#
#   scripts/build-local.sh            build build/Bridgeplay.app and build/Bridgeplay.zip
#   scripts/build-local.sh --checks   the same, then the CI check targets and Swift tests
#
# Phases run in CI order: dobby, all, overlay-shim, iconmaker+appinfo, bridge, fonts,
# app-payload, app. Everything CI restores from actions/cache stays on disk here
# instead, so a re-run only rebuilds what changed:
#   vendor/dobby, build/dobby        Dobby source and build (rebuilt when the pinned commit moves)
#   scratch/wine                     Wine 11.15 source
#   scratch/wine-build-dual          x86_64 cross tree (PE halves + rosetta unix half)
#   scratch/wine-build-arm64         arm64 tree (FEX unix half)
#   scratch/proton-lsc               Proton tarball for lsteamclient
#   app/.build                       SwiftPM build and the Sparkle checkout
# The bridge phase is skipped when scratch/.bridge-key matches the bridge sources.
# A new worktree: scripts/worktree-seed.sh first, then this.
#
# Overridable: DEVELOPER_DIR (default Xcode-beta), JOBS (default hw.ncpu)
# A beta build: BRIDGEPLAY_BETA=N BRIDGEPLAY_BETA_BUILD=B [BRIDGEPLAY_BETA_PLANNED=X.Y.Z], see docs/RELEASING.md

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

usage() {
	sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
}

run_checks=0
for arg in "$@"; do
	case "$arg" in
		--checks) run_checks=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "==> unknown argument $arg" >&2; usage >&2; exit 1 ;;
	esac
done

# The active developer dir on this machine is the Command Line Tools, which have
# no actool and no macOS 27 SDK. Point at Xcode for this process only rather than
# running xcode-select, which would change it for everything else too.
if [ -z "${DEVELOPER_DIR:-}" ]; then
	for xc in /Applications/Xcode-beta.app /Applications/Xcode.app; do
		if [ -d "$xc/Contents/Developer" ]; then
			DEVELOPER_DIR=$xc/Contents/Developer
			break
		fi
	done
fi
if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -d "$DEVELOPER_DIR" ]; then
	echo "==> no Xcode found, set DEVELOPER_DIR to <Xcode>.app/Contents/Developer" >&2
	exit 1
fi
export DEVELOPER_DIR

# A malformed beta stamp (BRIDGEPLAY_BETA*, see stamp-beta.sh) fails now, not after the slow phases.
sh scripts/stamp-beta.sh check

JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
LOG_DIR=$repo/build/logs
mkdir -p "$LOG_DIR"

# --- prerequisites -----------------------------------------------------------------

missing=""
need() {
	command -v "$1" >/dev/null 2>&1 || missing="$missing $1"
}
for tool in git make cmake curl python3 rsync lipo codesign ditto shasum \
	i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
	need "$tool"
done
# setup-wine-tree.sh puts Homebrew's keg-only bison first on PATH, macOS's is too old.
[ -x /opt/homebrew/opt/bison/bin/bison ] || missing="$missing bison(homebrew)"
xcrun --find swift >/dev/null 2>&1 || missing="$missing swift"
xcrun --find actool >/dev/null 2>&1 || missing="$missing actool"
if [ -n "$missing" ]; then
	echo "==> missing:$missing" >&2
	echo "    brew install cmake mingw-w64 bison flex, and install Xcode" >&2
	exit 1
fi
if [ "$run_checks" -eq 1 ]; then
	command -v node >/dev/null 2>&1 || echo "==> note: node not found, panel-behavior will skip"
fi

echo "==> toolchain"
echo "    $(xcodebuild -version | tr '\n' ' ')"
echo "    $(swift --version 2>&1 | head -1)"
echo "    macOS SDK $(xcrun --sdk macosx --show-sdk-version), jobs $JOBS"

# --- phase runner ------------------------------------------------------------------

timings=""
total_start=$(date +%s)

fmt() {
	printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
}

print_timings() {
	echo "==> phase timings"
	printf '%s\n' "$timings" | while read -r name secs; do
		[ -n "$name" ] || continue
		printf '    %-14s %s\n' "$name" "$(fmt "$secs")"
	done
	printf '    %-14s %s\n' total "$(fmt $(($(date +%s) - total_start)))"
}

# phase NAME CMD... runs CMD with its output on the terminal and in build/logs/NAME.log
phase() {
	name=$1
	shift
	log=$LOG_DIR/$name.log
	rcf=$LOG_DIR/.$name.rc
	echo "==> [$name] $*"
	start=$(date +%s)
	{
		rc=0
		"$@" || rc=$?
		echo "$rc" >"$rcf"
	} 2>&1 | tee "$log"
	rc=$(cat "$rcf")
	rm -f "$rcf"
	secs=$(($(date +%s) - start))
	timings="$timings
$name $secs"
	if [ "$rc" -ne 0 ]; then
		echo "==> [$name] failed with exit $rc after $(fmt "$secs"), log: $log" >&2
		print_timings
		exit "$rc"
	fi
	echo "==> [$name] done in $(fmt "$secs")"
}

# --- dobby -------------------------------------------------------------------------

DOBBY_COMMIT=$(sed -n 's/^[[:space:]]*DOBBY_COMMIT:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' .github/workflows/app.yml)
[ -n "$DOBBY_COMMIT" ] || { echo "==> DOBBY_COMMIT not found in .github/workflows/app.yml" >&2; exit 1; }

if [ ! -d vendor/dobby/.git ]; then
	git clone --no-checkout https://github.com/jmpews/Dobby.git vendor/dobby
	git -C vendor/dobby checkout -q "$DOBBY_COMMIT"
fi
if [ "$(git -C vendor/dobby rev-parse HEAD)" != "$DOBBY_COMMIT" ]; then
	git -C vendor/dobby fetch -q origin
	git -C vendor/dobby checkout -q "$DOBBY_COMMIT"
fi

dobby_stamp=build/dobby/.notproton-commit
if [ -f build/dobby/libdobby.a ] && [ "$(cat "$dobby_stamp" 2>/dev/null)" = "$DOBBY_COMMIT" ]; then
	echo "==> [dobby] build/dobby is current for $DOBBY_COMMIT, skipped"
else
	rm -rf build/dobby
	phase dobby make dobby
	echo "$DOBBY_COMMIT" >"$dobby_stamp"
fi

# --- dylib, shim, helpers ----------------------------------------------------------

phase all make -j"$JOBS" all
phase overlay-shim make -j"$JOBS" overlay-shim
phase helpers make -j"$JOBS" iconmaker appinfo

# --- bridge ------------------------------------------------------------------------

# CI keys its Wine cache on these two files. A local tree configured by an older
# version of them is kept, because setup-wine-tree.sh skips whatever exists, so say so.
wine_key=$(cat bridge/setup-wine-tree.sh bridge/register-components.diff | shasum -a 256 | cut -c1-16)
wine_stamp=scratch/.wine-key
if [ -f "$wine_stamp" ] && [ "$(cat "$wine_stamp")" != "$wine_key" ]; then
	echo "==> warning: scratch/wine* was set up by a different setup-wine-tree.sh or"
	echo "    register-components.diff. CI would start fresh; to do the same here:"
	echo "    rm -rf scratch/wine scratch/wine-build-dual scratch/wine-build-arm64 $wine_stamp"
fi

# Like CI's bridge cache: outputs built from these exact sources are reused, which is how a
# worktree seeded by worktree-seed.sh skips the Wine clone and build.
bridge_key=$(sh scripts/bridge-key.sh)
bridge_stamp=scratch/.bridge-key
bridge_built=0
if [ "$(cat "$bridge_stamp" 2>/dev/null)" = "$bridge_key" ]; then
	bridge_built=1
	for f in $(sh scripts/bridge-key.sh --outputs); do [ -f "$f" ] || bridge_built=0; done
fi
if [ "$bridge_built" -eq 1 ]; then
	echo "==> [bridge] skipped: already built from these sources ($bridge_key)"
else
	rm -f "$bridge_stamp"
	# The wine-tree scripts call plain make, which joins this make's jobserver.
	phase bridge make -j"$JOBS" bridge
	[ -f "$wine_stamp" ] || echo "$wine_key" >"$wine_stamp"
	echo "$bridge_key" >"$bridge_stamp"
fi

# --- fonts -------------------------------------------------------------------------

# CI's font toolchain: Homebrew fontforge + gpatch, and afdko/fonttools in a venv.
font_tools=$(sed -n 's/^ *FONT_TOOLS: "\(.*\)"$/\1/p' .github/workflows/app.yml)
for tool in fontforge gpatch; do
	command -v "$tool" >/dev/null 2>&1 || [ -x "$(brew --prefix 2>/dev/null)/opt/$tool/bin/$tool" ] \
		|| { echo "==> $tool is missing, run: brew install fontforge gpatch" >&2; exit 1; }
done
if [ ! -x scratch/fontvenv/bin/makeotfexe ] || [ "$(cat scratch/fontvenv/.tools 2>/dev/null)" != "$font_tools" ]; then
	# A venv shared by worktree-seed.sh belongs to the other checkout: replace the link, not that venv.
	[ ! -L scratch/fontvenv ] || rm scratch/fontvenv
	python3 -m venv scratch/fontvenv
	# shellcheck disable=SC2086 # FONT_TOOLS is a space-separated requirement list
	scratch/fontvenv/bin/pip install -q $font_tools
	echo "$font_tools" >scratch/fontvenv/.tools
fi
PATH="$repo/scratch/fontvenv/bin:$(brew --prefix)/opt/gpatch/libexec/gnubin:$PATH"
export PATH
phase fonts make fonts

# --- app ---------------------------------------------------------------------------

phase app-payload make app-payload
phase app make app

app_out=build/Bridgeplay.app
zip_out=build/Bridgeplay.zip
rm -rf "$app_out" "$zip_out"
ditto out/Bridgeplay.app "$app_out"
ditto -c -k --keepParent "$app_out" "$zip_out"
codesign --verify --strict --deep "$app_out"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_out/Contents/Info.plist")
sha=$(shasum -a 256 "$zip_out" | cut -d' ' -f1)

# --- checks ------------------------------------------------------------------------

# The checks depend on the source, not on the version number, so a tree that already
# passed (a release right after its bump commit) skips them. Only a clean tree is stamped.
# BRIDGEPLAY_FORCE_CHECKS=1 runs them anyway.
checks_stamp=$repo/build/.checks-passed
source_fingerprint() {
	git -C "$repo" diff --quiet HEAD -- 2>/dev/null || return 1
	git -C "$repo" ls-files -s | grep -v '	dylib/version.h$' | shasum | cut -d' ' -f1
}
fingerprint=$(source_fingerprint || true)
if [ "$run_checks" -eq 1 ] && [ -n "$fingerprint" ] && [ "${BRIDGEPLAY_FORCE_CHECKS:-0}" != 1 ] \
	&& [ "$(cat "$checks_stamp" 2>/dev/null)" = "$fingerprint" ]; then
	echo "==> [check] skipped: these sources already passed make ci-checks (BRIDGEPLAY_FORCE_CHECKS=1 runs them)"
	run_checks=0
	checks_reused=1
fi

# The app workflow runs the same make ci-checks on every push to main and dev, so a release
# whose sources (version.h and docs aside) match a commit that workflow passed skips them
# too: push, let CI pass, bump, release. Needs gh; without it, or with no passing run, the
# checks run here. A docs-only run is green with its build and checks skipped, so a run
# counts only when both jobs ran and succeeded (scripts/ci-run-passed.sh).
ci_slug=${BRIDGEPLAY_CI_REPO:-raymondchins/Bridgeplay}
ci_passed() {
	command -v gh >/dev/null 2>&1 || return 1
	for sha in $(git -C "$repo" rev-list --max-count=5 HEAD); do
		# Only docs (.github/docs-only-paths) and version.h may differ from that commit.
		# A failing step means "can't tell", never "same".
		changed=$(git -C "$repo" -c core.quotePath=false diff --name-only --no-renames "$sha" HEAD) || continue
		code=$(printf '%s\n' "$changed" | sh "$repo/scripts/ci-code-paths.sh") || continue
		! printf '%s' "$code" | grep -vqx 'dylib/version.h' || continue
		sh "$repo/scripts/ci-run-passed.sh" "$ci_slug" "$sha" && { echo "$sha"; return 0; }
	done
	return 1
}
if [ "$run_checks" -eq 1 ] && [ -n "$fingerprint" ] && [ "${BRIDGEPLAY_FORCE_CHECKS:-0}" != 1 ] \
	&& ci_sha=$(ci_passed); then
	echo "==> [check] skipped: GitHub CI (app) passed make ci-checks on $(printf '%.7s' "$ci_sha"), same sources (BRIDGEPLAY_FORCE_CHECKS=1 runs them)"
	run_checks=0
	checks_reused=1
fi

check_failures=""
if [ "$run_checks" -eq 1 ]; then
	check_log=$LOG_DIR/checks.log
	: >"$check_log"
	start=$(date +%s)
	# make ci-checks is the list app.yml runs, JOBS checks at a time; each runs even after a failure
	echo "==> [check] make ci-checks, log: $check_log"
	if ! make ci-checks CHECK_JOBS="$JOBS" >>"$check_log" 2>&1; then
		check_failures=$(sed -n 's/^==> ci-checks failed://p' "$check_log")
		[ -n "$check_failures" ] || check_failures=" ci-checks"
	fi
	grep '^==> ' "$check_log" | sed 's/^/    /'
	timings="$timings
checks $(($(date +%s) - start))"
fi

# --- summary -----------------------------------------------------------------------

print_timings
echo "==> Bridgeplay $version"
echo "    app     $repo/$app_out (codesign --verify --strict ok)"
echo "    signed  $(codesign -d -r- "$app_out" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "    zip     $repo/$zip_out"
echo "    sha256  $sha"
if [ -n "$check_failures" ]; then
	echo "==> checks failed:$check_failures" >&2
	exit 1
fi
if [ "$run_checks" -eq 1 ]; then
	echo "==> all CI checks passed"
	[ -z "$fingerprint" ] || printf '%s\n' "$fingerprint" >"$checks_stamp"
elif [ "${checks_reused:-0}" -eq 1 ]; then
	echo "==> all CI checks passed (earlier run, same sources)"
fi
