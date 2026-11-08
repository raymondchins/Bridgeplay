#!/bin/sh
# Beta stamping: scripts/stamp-beta.sh, the version bump and the upstream sync, run on
# throwaway copies of the repo's scripts, so nothing in the checkout changes.
#
#   sh dylib/tests/versioncheck.sh
#
# The committed version stays X.Y.Z. A beta build stamps X.Y.Z-beta.N, its build number and
# the beta channel into the app at build time, and a normal build stamps nothing.
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/np-versioncheck.XXXXXX")
trap 'rm -rf "$work"' EXIT

unset BRIDGEPLAY_BETA BRIDGEPLAY_BETA_BUILD BRIDGEPLAY_BETA_PLANNED \
	BRIDGEPLAY_HIGHEST_BUILD BRIDGEPLAY_BETA_BRANCH PLISTBUDDY

checks=0
failures=0
pass() { checks=$((checks + 1)); }
fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	echo "FAIL: $*" >&2
}

expect_eq() { # name wanted got
	if [ "$2" = "$3" ]; then pass; else fail "$1: wanted '$2', got '$3'"; fi
}

# expect_ok NAME CMD...: succeeds, output in $out
expect_ok() {
	_name=$1
	shift
	if out=$("$@" 2>&1); then pass; else fail "$_name: $* failed: $out"; fi
}

# expect_refused NAME CMD...: fails
expect_refused() {
	_name=$1
	shift
	if out=$("$@" 2>&1); then fail "$_name: $* succeeded: $out"; else pass; fi
}

expect_same() { # name file copy
	if cmp -s "$2" "$3"; then pass; else fail "$1: $2 changed"; fi
}

write_header() { # file version build upstream
	cat >"$1" <<EOF
// Build version string
#ifndef NOTPROTON_VERSION_H
#define NOTPROTON_VERSION_H

#define NOTPROTON_VERSION "$4"

// Bridgeplay's own version.
//   BRIDGEPLAY_VERSION  semver people see
//   BRIDGEPLAY_BUILD    +1 on every release
#define BRIDGEPLAY_VERSION "$2"
#define BRIDGEPLAY_BUILD $3

#endif // NOTPROTON_VERSION_H
EOF
}

# fixture DIR VERSION BUILD: the version scripts around a header of our own.
fixture() {
	mkdir -p "$1/scripts" "$1/dylib" "$1/app"
	for s in version-lib stamp-beta bump-version sync-upstream ledger-lib build-ledger; do
		tr -d '\r' <"$repo/scripts/$s.sh" >"$1/scripts/$s.sh"
		chmod +x "$1/scripts/$s.sh"
	done
	write_header "$1/dylib/version.h" "$2" "$3" "1.2.0"
	tr -d '\r' <"$repo/app/Info.plist" >"$1/app/Info.plist"
}

define() { # file name
	sed -n 's/^#define '"$2"' "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$1"
}

# --- the template is a stable build -----------------------------------------------

channel_line=$(grep -A1 '<key>BridgeplayChannel</key>' "$repo/app/Info.plist" | tail -n 1 | tr -d '\r\t ')
expect_eq "app/Info.plist carries the stable channel" "<string>stable</string>" "$channel_line"

# The real header is committed as a plain X.Y.Z.
version=$(define "$repo/dylib/version.h" BRIDGEPLAY_VERSION)
case "$version" in
	*[!0-9.]*|''|.*|*.|*..*|*.*.*.*) fail "dylib/version.h BRIDGEPLAY_VERSION '$version' is not X.Y.Z" ;;
	*.*.*) pass ;;
	*) fail "dylib/version.h BRIDGEPLAY_VERSION '$version' is not X.Y.Z" ;;
esac

# --- stamp-beta.sh ----------------------------------------------------------------

fx=$work/stamp
fixture "$fx" 0.7.2 44
cp "$fx/dylib/version.h" "$work/version.h.orig"
cp "$fx/app/Info.plist" "$work/Info.plist.orig"
# stamp VAR=value... MODE [ARG]: the leading assignments go into the script's environment.
stamp() {
	(
		# shellcheck disable=SC2163 # the argument is NAME=value, which export takes
		while [ $# -gt 0 ]; do
			case $1 in
				[A-Za-z]*=*) export "$1"; shift ;;
				*) break ;;
			esac
		done
		sh "$fx/scripts/stamp-beta.sh" "$@"
	)
}

# A normal build keeps the committed version and build, and the stable channel.
expect_ok "normal check" stamp x=1 check
expect_ok "normal print" stamp x=1 print
expect_eq "normal print" "version=0.7.2
build=44
channel=stable" "$out"
# apply must not even start PlistBuddy: the template is already what a normal build ships.
cp "$fx/app/Info.plist" "$work/Info.plist"
expect_ok "normal apply" stamp PLISTBUDDY=/nonexistent/PlistBuddy apply "$work/Info.plist"
expect_same "normal apply leaves the plist alone" "$work/Info.plist.orig" "$work/Info.plist"

# A beta takes N from the build command; the planned release defaults to the next patch.
expect_ok "beta default" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 print
expect_eq "beta default" "version=0.7.3-beta.1
build=50
channel=beta" "$out"
expect_ok "beta 12" stamp BRIDGEPLAY_BETA=12 BRIDGEPLAY_BETA_BUILD=50 print
expect_eq "beta 12" "version=0.7.3-beta.12
build=50
channel=beta" "$out"

# A milestone minor works the same way.
expect_ok "milestone" stamp BRIDGEPLAY_BETA=2 BRIDGEPLAY_BETA_BUILD=51 BRIDGEPLAY_BETA_PLANNED=0.8.0 print
expect_eq "milestone" "version=0.8.0-beta.2
build=51
channel=beta" "$out"
expect_ok "planned patch" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 BRIDGEPLAY_BETA_PLANNED=0.7.3 print
expect_eq "planned patch" "version=0.7.3-beta.1
build=50
channel=beta" "$out"
expect_ok "planned further patch" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 BRIDGEPLAY_BETA_PLANNED=0.7.10 print
expect_eq "planned further patch" "version=0.7.10-beta.1
build=50
channel=beta" "$out"
# An empty planned release is the default.
expect_ok "planned empty" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 BRIDGEPLAY_BETA_PLANNED= print
expect_eq "planned empty" "version=0.7.3-beta.1
build=50
channel=beta" "$out"

# A planned release not above the committed version fails the build.
for planned in 0.7.2 0.7.1 0.6.9 0.1.0 0.7 0.7.3.1 0.07.3 v0.8.0 0.7.3-beta.1 0.8.0-beta.1 " 0.8.0" 0.8.x; do
	expect_refused "planned '$planned'" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 BRIDGEPLAY_BETA_PLANNED="$planned" check
done

# The beta number is a positive integer.
for n in 0 00 01 -1 +1 1.5 abc "1 2" "" " 1" "1
2" 1234567890; do
	expect_refused "beta number '$n'" stamp BRIDGEPLAY_BETA="$n" BRIDGEPLAY_BETA_BUILD=50 check
	expect_refused "beta number '$n' print" stamp BRIDGEPLAY_BETA="$n" BRIDGEPLAY_BETA_BUILD=50 print
done
# A missing number fails, whatever else is set.
expect_refused "no beta number, build given" stamp BRIDGEPLAY_BETA_BUILD=50 check
expect_refused "no beta number, planned given" stamp BRIDGEPLAY_BETA_PLANNED=0.8.0 check
# Empty values count as set: a wrapper that exports them empty must not get a stable build.
expect_refused "empty beta build, no beta number" stamp BRIDGEPLAY_BETA_BUILD= check
expect_refused "empty planned, no beta number" stamp BRIDGEPLAY_BETA_PLANNED= check
expect_refused "both empty, no beta number" stamp BRIDGEPLAY_BETA_BUILD= BRIDGEPLAY_BETA_PLANNED= check

# The build number is given, a positive integer and above the committed build.
expect_refused "no beta build" stamp BRIDGEPLAY_BETA=1 check
for b in 0 -5 abc 4.5 "" 44 43 1 044; do
	expect_refused "beta build '$b'" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD="$b" check
done
expect_ok "beta build 45" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=45 check

# A failed or successful beta build commits nothing.
expect_same "beta builds leave version.h alone" "$work/version.h.orig" "$fx/dylib/version.h"

# apply writes the label, the build and the channel through PlistBuddy, and only for a beta.
cat >"$work/fake-plistbuddy" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_PLISTBUDDY_LOG"
EOF
chmod +x "$work/fake-plistbuddy"
FAKE_PLISTBUDDY_LOG=$work/plistbuddy.log
export FAKE_PLISTBUDDY_LOG
expect_ok "beta apply" stamp BRIDGEPLAY_BETA=3 BRIDGEPLAY_BETA_BUILD=52 BRIDGEPLAY_BETA_PLANNED=0.8.0 \
	PLISTBUDDY="$work/fake-plistbuddy" apply "$work/Info.plist"
expect_eq "beta apply arguments" "-c
Set :CFBundleShortVersionString 0.8.0-beta.3
-c
Set :CFBundleVersion 52
-c
Set :BridgeplayChannel beta
$work/Info.plist" "$(cat "$work/plistbuddy.log")"
expect_refused "apply without a plist" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 \
	PLISTBUDDY="$work/fake-plistbuddy" apply "$work/missing.plist"

# With the real PlistBuddy, the plist reads back as a beta, and the template is untouched.
if [ -x /usr/libexec/PlistBuddy ]; then
	cp "$work/Info.plist.orig" "$work/Info.plist"
	expect_ok "real apply" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 apply "$work/Info.plist"
	for key_value in CFBundleShortVersionString:0.7.3-beta.1 CFBundleVersion:50 BridgeplayChannel:beta \
		NotProtonVersion:0.0.0; do
		got=$(/usr/libexec/PlistBuddy -c "Print :${key_value%%:*}" "$work/Info.plist")
		expect_eq "real apply ${key_value%%:*}" "${key_value#*:}" "$got"
	done
	expect_same "the beta stamp leaves the template alone" "$work/Info.plist.orig" "$fx/app/Info.plist"
else
	echo "==> versioncheck: PlistBuddy not present, the real plist round trip is skipped"
fi

# A beta label is never accepted as the committed version.
for bad in 0.7.3-beta.1 0.7.3-beta 0.7 0.7.3.1 v0.7.3 0.07.3 1.2.x ""; do
	badfx=$work/bad
	rm -rf "$badfx"
	fixture "$badfx" "$bad" 44
	expect_refused "committed '$bad' (check)" env x=1 sh "$badfx/scripts/stamp-beta.sh" check
	expect_refused "committed '$bad' (beta)" env BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=50 \
		sh "$badfx/scripts/stamp-beta.sh" check
	expect_refused "committed '$bad' (bump)" env x=1 sh "$badfx/scripts/bump-version.sh" patch
done

# --- bump-version.sh --------------------------------------------------------------

bumpfx=$work/bump
# The highest build is given here; scripts/tests/ledgercheck.sh covers reading it online.
bump() { # bump PART [ARGS]: from 0.7.2 build 44
	rm -rf "$bumpfx"
	fixture "$bumpfx" 0.7.2 44
	env "${bump_env:-BRIDGEPLAY_HIGHEST_BUILD=44}" sh "$bumpfx/scripts/bump-version.sh" "$@"
}
bumped() { # bumped VERSION BUILD: what the header says now
	expect_eq "bumped version" "$1" "$(define "$bumpfx/dylib/version.h" BRIDGEPLAY_VERSION)"
	expect_eq "bumped build" "$2" "$(define "$bumpfx/dylib/version.h" BRIDGEPLAY_BUILD)"
}

expect_ok "patch" bump patch
bumped 0.7.3 45
expect_ok "minor" bump minor
bumped 0.8.0 45
expect_ok "major" bump major
bumped 1.0.0 45
expect_eq "upstream stays" 1.2.0 "$(define "$bumpfx/dylib/version.h" NOTPROTON_VERSION)"

# The stable that ships a beta outranks every published build, beta ones included.
expect_ok "highest build" bump patch --highest-build 50
bumped 0.7.3 51
expect_ok "highest build below the committed one" bump patch --highest-build 30
bumped 0.7.3 45
expect_ok "highest build equal to the committed one" bump patch --highest-build 44
bumped 0.7.3 45
bump_env=BRIDGEPLAY_HIGHEST_BUILD=60
expect_ok "highest build from the environment" bump patch
bumped 0.7.3 61
bump_env=""
for b in 0 abc -3 4.5 ""; do
	expect_refused "highest build '$b'" bump patch --highest-build "$b"
done

# --named is the release the beta was named after: the bump must land exactly there.
expect_ok "named patch" bump patch --named 0.7.3 --highest-build 50
bumped 0.7.3 51
expect_ok "named milestone" bump minor --named 0.8.0 --highest-build 50
bumped 0.8.0 51
expect_refused "named differs from the patch" bump patch --named 0.8.0
expect_same "a refused bump leaves version.h alone" "$work/version.h.orig" "$bumpfx/dylib/version.h"
expect_refused "named differs from the minor" bump minor --named 0.7.3
expect_refused "named is malformed" bump patch --named 0.7.3-beta.1
expect_refused "named is empty" bump patch --named "" --highest-build 50
# set picks any version above the committed one; the build still goes up by one.
expect_ok "set a finer patch" bump set 0.7.31
bumped 0.7.31 45
expect_ok "set with the highest build" bump set 0.7.31 --highest-build 50
bumped 0.7.31 51
expect_ok "set a named release" bump set 0.7.31 --named 0.7.31
bumped 0.7.31 45
expect_refused "set to the committed version" bump set 0.7.2
expect_refused "set below the committed version" bump set 0.6.9
expect_same "a refused set leaves version.h alone" "$work/version.h.orig" "$bumpfx/dylib/version.h"
expect_refused "set without a version" bump set
for v in 0.7 0.7.31-beta.1 v0.7.31 0.7.3.1; do
	expect_refused "set '$v'" bump set "$v"
done
expect_refused "set named elsewhere" bump set 0.7.31 --named 0.7.3
expect_refused "no part" bump
expect_refused "unknown part" bump beta

# Without --highest-build the bump reads it online; a fixture with no Bridgeplay remote can't.
bump_env=x=1
expect_refused "no highest build offline" bump patch
case $out in
	*"--highest-build N"*) pass ;;
	*) fail "the offline bump does not ask for --highest-build: $out" ;;
esac
expect_same "an offline bump leaves version.h alone" "$work/version.h.orig" "$bumpfx/dylib/version.h"
bump_env=""

# A beta, then the stable it was named after: the beta is above the stable it branched from,
# and the next stable is above the beta.
stable_build=44
expect_ok "beta over the last stable" stamp BRIDGEPLAY_BETA=1 BRIDGEPLAY_BETA_BUILD=45 print
expect_eq "beta label" "version=0.7.3-beta.1
build=45
channel=beta" "$out"
beta_build=45
expect_ok "next stable" bump patch --named 0.7.3 --highest-build "$beta_build"
next_build=$(define "$bumpfx/dylib/version.h" BRIDGEPLAY_BUILD)
if [ "$beta_build" -gt "$stable_build" ] && [ "$next_build" -gt "$beta_build" ]; then pass; else
	fail "build order: stable $stable_build, beta $beta_build, next stable $next_build"
fi

# --- sync-upstream.sh -------------------------------------------------------------

git_in() { # git_in DIR ARGS...
	_dir=$1
	shift
	git -C "$_dir" -c user.name=versioncheck -c user.email=versioncheck@example.invalid \
		-c commit.gpgsign=false -c core.autocrlf=false -c init.defaultBranch=main "$@"
}

# sync_fixture NAME: an upstream repo and a clone of it that follows it as `upstream`.
sync_fixture() {
	up=$work/$1-upstream
	wk=$work/$1
	fixture "$up" 0.7.2 44
	git_in "$work" init -q "$up"
	git_in "$up" symbolic-ref HEAD refs/heads/main
	echo base >"$up/file.txt"
	git_in "$up" add -A
	git_in "$up" commit -q -m base
	git_in "$work" clone -q "$up" "$wk"
	git_in "$wk" config user.name versioncheck
	git_in "$wk" config user.email versioncheck@example.invalid
	git_in "$wk" config commit.gpgsign false
	git_in "$wk" config core.autocrlf false
	git_in "$wk" remote rename origin upstream
}

sync_upstream() { # sync_upstream: run it in $wk
	(cd "$wk" && env "$@" sh scripts/sync-upstream.sh)
}

version_in() { define "$wk/dylib/version.h" "$1"; }

# On main an upstream merge still bumps the patch, as before.
sync_fixture onmain
echo more >"$up/file.txt"
git_in "$up" commit -q -am "upstream change"
git_in "$wk" checkout -q -B main
expect_ok "sync on main" sync_upstream BRIDGEPLAY_HIGHEST_BUILD=44
expect_eq "main version" 0.7.3 "$(version_in BRIDGEPLAY_VERSION)"
expect_eq "main build" 45 "$(version_in BRIDGEPLAY_BUILD)"
expect_eq "main commits the bump" "chore(release): bump Bridgeplay to 0.7.3 after upstream merge" \
	"$(git_in "$wk" log -1 --format=%s)"

# On main without the highest build, and no way to read it, the sync stops before merging.
sync_fixture offline
echo more >"$up/file.txt"
git_in "$up" commit -q -am "upstream change"
git_in "$wk" checkout -q -B main
offline_head=$(git_in "$wk" rev-parse HEAD)
expect_refused "sync on main offline" sync_upstream x=1
expect_eq "an offline sync merges nothing" "$offline_head" "$(git_in "$wk" rev-parse HEAD)"

# On develop it merges and commits no version change.
sync_fixture ondevelop
echo more >"$up/file.txt"
git_in "$up" commit -q -am "upstream change"
git_in "$wk" checkout -q -B develop
expect_ok "sync on develop" sync_upstream x=1
expect_eq "develop version" 0.7.2 "$(version_in BRIDGEPLAY_VERSION)"
expect_eq "develop build" 44 "$(version_in BRIDGEPLAY_BUILD)"
expect_eq "develop merged upstream" more "$(cat "$wk/file.txt")"
case $(git_in "$wk" log --format=%s) in
	*chore\(release\)*) fail "a version bump was committed on develop" ;;
	*) pass ;;
esac
expect_eq "develop tree is clean" "" "$(git_in "$wk" status --porcelain --untracked-files=no)"

# The beta branch name can be changed; any other branch bumps as on main, dev included.
sync_fixture named
echo more >"$up/file.txt"
git_in "$up" commit -q -am "upstream change"
git_in "$wk" checkout -q -B next
expect_ok "sync on a named beta branch" sync_upstream BRIDGEPLAY_BETA_BRANCH=next
expect_eq "named branch version" 0.7.2 "$(version_in BRIDGEPLAY_VERSION)"
sync_fixture other
echo more >"$up/file.txt"
git_in "$up" commit -q -am "upstream change"
git_in "$wk" checkout -q -B feature
expect_ok "sync on another branch" sync_upstream BRIDGEPLAY_HIGHEST_BUILD=44
expect_eq "other branch version" 0.7.3 "$(version_in BRIDGEPLAY_VERSION)"
sync_fixture olddev
echo more >"$up/file.txt"
git_in "$up" commit -q -am "upstream change"
git_in "$wk" checkout -q -B dev
expect_ok "sync on dev, no longer special" sync_upstream BRIDGEPLAY_HIGHEST_BUILD=44
expect_eq "dev version bumps like any branch" 0.7.3 "$(version_in BRIDGEPLAY_VERSION)"

# A version.h conflict is still resolved: Bridgeplay's lines stay, NotProton takes upstream's.
for branch in main develop; do
	sync_fixture "conflict-$branch"
	sed 's/^#define NOTPROTON_VERSION ".*"$/#define NOTPROTON_VERSION "1.3.0"/' "$up/dylib/version.h" >"$up/version.h.new"
	cat "$up/version.h.new" >"$up/dylib/version.h"
	rm "$up/version.h.new"
	git_in "$up" commit -q -am "upstream 1.3.0"
	git_in "$wk" checkout -q -B "$branch"
	sed 's/^#define NOTPROTON_VERSION ".*"$/#define NOTPROTON_VERSION "1.2.9-local"/' "$wk/dylib/version.h" >"$wk/version.h.new"
	cat "$wk/version.h.new" >"$wk/dylib/version.h"
	rm "$wk/version.h.new"
	git_in "$wk" commit -q -am "local change"
	expect_ok "conflicting sync on $branch" sync_upstream BRIDGEPLAY_HIGHEST_BUILD=44
	expect_eq "$branch upstream version" 1.3.0 "$(version_in NOTPROTON_VERSION)"
done
expect_eq "conflict on main bumps the patch" 0.7.3 "$(define "$work/conflict-main/dylib/version.h" BRIDGEPLAY_VERSION)"
expect_eq "conflict on develop keeps the version" 0.7.2 "$(define "$work/conflict-develop/dylib/version.h" BRIDGEPLAY_VERSION)"

if [ "$failures" -ne 0 ]; then
	echo "==> versioncheck: $failures of $checks checks failed" >&2
	exit 1
fi
echo "==> versioncheck: $checks checks passed"
