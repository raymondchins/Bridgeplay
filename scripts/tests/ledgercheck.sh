#!/bin/sh
# The build ledger: scripts/ledger-lib.sh, scripts/build-ledger.sh (highest, claim) and the bump
# reading the highest build online. The remote is a local bare repository and gh is a stub that
# answers from fixtures through jq, so nothing reaches GitHub.
#
#   sh scripts/tests/ledgercheck.sh
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)

if ! command -v jq >/dev/null 2>&1; then
	echo "==> ledgercheck: skipped, jq not found (the gh stub needs it)"
	exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/np-ledgercheck.XXXXXX")
trap 'rm -rf "$work"' EXIT

unset BRIDGEPLAY_HIGHEST_BUILD BRIDGEPLAY_LEDGER_REMOTE_URL BRIDGEPLAY_LEDGER_APPCASTS GH_STUB_FAIL

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
# expect_ok NAME CMD...: succeeds; stdout in $out, stderr in $err
expect_ok() {
	_name=$1
	shift
	if out=$("$@" 2>"$work/stderr"); then pass; else fail "$_name: $* failed: $out $(cat "$work/stderr")"; fi
	err=$(cat "$work/stderr")
}
# expect_code NAME CODE CMD...: exits with CODE; stdout in $out, stderr in $err
expect_code() {
	_name=$1
	_want=$2
	shift 2
	_rc=0
	out=$("$@" 2>"$work/stderr") || _rc=$?
	err=$(cat "$work/stderr")
	if [ "$_rc" -eq "$_want" ]; then pass; else fail "$_name: wanted exit $_want, got $_rc: $out $err"; fi
}
expect_has() { # name needle haystack
	case $3 in
		*"$2"*) pass ;;
		*) fail "$1: '$2' not in: $3" ;;
	esac
}

git_in() { # git_in DIR ARGS...
	_dir=$1
	shift
	git -C "$_dir" -c user.name=ledgercheck -c user.email=ledgercheck@example.invalid \
		-c commit.gpgsign=false -c tag.gpgsign=false -c core.autocrlf=false \
		-c init.defaultBranch=main -c advice.detachedHead=false "$@"
}

set_build() { # set_build DIR BUILD
	cat >"$1/dylib/version.h" <<EOF
#ifndef NOTPROTON_VERSION_H
#define NOTPROTON_VERSION_H
#define NOTPROTON_VERSION "1.2.0"
#define BRIDGEPLAY_VERSION "0.7.63"
#define BRIDGEPLAY_BUILD $2
#endif
EOF
}

# --- the parser (ledger-lib.sh) ------------------------------------------------------

# shellcheck source=/dev/null
. "$repo/scripts/ledger-lib.sh"

for t in v0.7.63 v0.8.0-beta.1 v3.5.0 v1.1.9-winehq.1-ray.31; do
	if is_app_release_tag "$t"; then pass; else fail "$t is an app release"; fi
done
for t in installer beta-feed dxmt-e94c312 fonts-cjk-29ba44d27134 wine-patch-sources-2d19f09dde5d build/82 vendor ""; do
	if is_app_release_tag "$t"; then fail "$t is not an app release"; else pass; fi
done

# The old line, v3.5.0's included (old scheme, build 43), with CRLF line ends.
expect_ok "old line" legacy_build <<'EOF'
- Fixed CrossOver version order

Build 43, based on NotProton 1.2.0.
EOF
expect_eq "v3.5.0 build" 43 "$out"
expect_ok "old line, CRLF" sh -c ". '$repo/scripts/ledger-lib.sh'; printf 'notes\r\n\r\nBuild 80, based on NotProton 1.2.0.\r\n' | legacy_build"
expect_eq "CRLF build" 80 "$out"
expect_code "no old line" 1 legacy_build <<'EOF'
Built with care. Build 12 of many.
EOF

expect_ok "appcast" appcast_build <<'EOF'
<rss><channel><item><sparkle:version>77</sparkle:version><sparkle:shortVersionString>0.7.60</sparkle:shortVersionString></item></channel></rss>
EOF
expect_eq "appcast build" 77 "$out"

expect_ok "render" ledger_render kind=beta build=82 label=0.8.0-beta.1 tag=v0.8.0-beta.1 \
	commit=0123456789abcdef0123456789abcdef01234567 source-branch=develop \
	zip-sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 zip-length=123456 \
	ed-signature=c2lnbmF0dXJlPT0= channel=beta-critical "critical-reason=data loss on update"
rendered=$out
expect_eq "render output" "<!-- bridgeplay-ledger v1
kind: beta
build: 82
label: 0.8.0-beta.1
tag: v0.8.0-beta.1
commit: 0123456789abcdef0123456789abcdef01234567
source-branch: develop
zip-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
zip-length: 123456
ed-signature: c2lnbmF0dXJlPT0=
channel: beta-critical
critical-reason: data loss on update
-->" "$rendered"
body="What's new: things.

Build 82, based on NotProton 1.2.0.

$rendered"
for kv in kind:beta build:82 source-branch:develop "critical-reason:data loss on update" ed-signature:c2lnbmF0dXJlPT0=; do
	expect_ok "read ${kv%%:*}" ledger_field "${kv%%:*}" <<EOF
$body
EOF
	expect_eq "read ${kv%%:*}" "${kv#*:}" "$out"
done
expect_code "absent key" 1 ledger_field promoted-from <<EOF
$body
EOF
expect_code "no block" 1 ledger_field build <<'EOF'
Build 80, based on NotProton 1.2.0.
EOF
expect_ok "stable render" ledger_render kind=stable build=83 promoted-from=none contains-betas=none
expect_ok "CRLF block" sh -c ". '$repo/scripts/ledger-lib.sh'; printf 'x\r\n<!-- bridgeplay-ledger v1\r\nkind: stable\r\nbuild: 83\r\n-->\r\n' | ledger_field build"
expect_eq "CRLF block build" 83 "$out"

for bad in "kind=nightly build=1" "kind=beta build=0" "kind=beta build=08" "build=5" "kind=beta" \
	"kind=beta build=5 colour=red" "kind=beta build=5 label=a--b" "kind=beta build=5 label=" \
	"kind=beta build=5 build=6" "kind=beta build=5 label= x" "kind=beta build=5 nokey"; do
	# shellcheck disable=SC2086 # each case is a list of words
	expect_code "render refuses '$bad'" 1 ledger_render $bad
done
expect_code "render refuses a newline" 1 ledger_render kind=beta build=5 "label=a
b"

block() { printf 'notes\n\n%s\n' "$1"; }
for bad in "<!-- bridgeplay-ledger v1
kind: beta
build: 5" "<!-- bridgeplay-ledger v1
kind: beta
build: 5
build: 6
-->" "<!-- bridgeplay-ledger v1
kind: beta

build: 5
-->" "<!-- bridgeplay-ledger v1
Kind: beta
build: 5
-->" "<!-- bridgeplay-ledger v1
kind:beta
build: 5
-->" "<!-- bridgeplay-ledger v1
kind: beta
-->" "<!-- bridgeplay-ledger v1
kind: beta
build: 5
-->
<!-- bridgeplay-ledger v1
kind: beta
build: 6
-->" "<!-- bridgeplay-ledger v1
kind: beta
build: 5 --> sneaky
-->"; do
	expect_code "malformed block" 2 ledger_field build <<EOF
$(block "$bad")
EOF
done
expect_code "a newer version" 3 ledger_field build <<'EOF'
<!-- bridgeplay-ledger v2
kind: beta
build: 5
-->
EOF
expect_ok "unknown keys are ignored" ledger_field build <<'EOF'
<!-- bridgeplay-ledger v1
kind: stable
future-thing: yes
build: 7
-->
EOF
expect_eq "unknown keys are ignored" 7 "$out"

# --- fixtures: a bare remote, clones, a stub gh -------------------------------------

origin=$work/origin.git
decoy=$work/decoy.git
git_in "$work" init -q --bare "$origin"
git_in "$work" init -q --bare "$decoy"

seed=$work/seed
mkdir -p "$seed/scripts" "$seed/dylib"
for s in version-lib bump-version ledger-lib build-ledger; do
	tr -d '\r' <"$repo/scripts/$s.sh" >"$seed/scripts/$s.sh"
done
git_in "$work" init -q "$seed"
set_build "$seed" 80
git_in "$seed" add -A
git_in "$seed" commit -q -m "release 80"
git_in "$seed" push -q "$decoy" HEAD:refs/heads/main
# main is bumped to 81 and not released yet.
set_build "$seed" 81
git_in "$seed" commit -q -am "chore(release): 81"
git_in "$seed" push -q "$origin" HEAD:refs/heads/main
# The decoy, named like a real remote, carries a much higher build; it must not count.
set_build "$seed" 999
git_in "$seed" commit -q -am "decoy"
git_in "$seed" push -q "$decoy" HEAD:refs/heads/main
git_in "$seed" push -q "$decoy" HEAD:refs/tags/build/999

clone() { # clone DIR: the remote named mirror, with a decoy named upstream
	git_in "$work" clone -q -o mirror "$origin" "$1"
	git_in "$1" remote add upstream "$decoy"
}
c1=$work/c1
c2=$work/c2
clone "$c1"
clone "$c2"

BRIDGEPLAY_LEDGER_REMOTE_URL=$origin
export BRIDGEPLAY_LEDGER_REMOTE_URL

stub=$work/gh-stub
mkdir -p "$stub/bin" "$stub/assets"
cat >"$stub/bin/gh" <<'EOF'
#!/bin/sh
# gh stub: `api .../releases?...` runs --jq over $GH_STUB/releases.json; `api .../assets/ID`
# prints $GH_STUB/assets/ID. GH_STUB_FAIL=1 stands for no network.
if [ -n "${GH_STUB_FAIL:-}" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
[ "${1:-}" = api ] || { echo "gh stub: unexpected $*" >&2; exit 1; }
shift
expr=.
path=""
while [ $# -gt 0 ]; do
	case $1 in
		--paginate) shift ;;
		--jq) expr=$2; shift 2 ;;
		-H) shift 2 ;;
		*) path=$1; shift ;;
	esac
done
case $path in
	repos/raymondchins/Bridgeplay/releases/assets/*)
		f=$GH_STUB/assets/${path##*/}
		[ -f "$f" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
		cat "$f"
		;;
	repos/raymondchins/Bridgeplay/releases\?per_page=100)
		[ -f "$GH_STUB/releases.json" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
		jq -r "$expr" "$GH_STUB/releases.json"
		;;
	*) echo "gh stub: unexpected path $path" >&2; exit 1 ;;
esac
EOF
chmod +x "$stub/bin/gh"
GH_STUB=$stub
PATH=$stub/bin:$PATH
export GH_STUB PATH

asset_id=1000
no_releases() { echo '[]' >"$stub/releases.json"; }
# add_release TAG BODY [APPCAST_BUILD|missing]: newest last, as the API lists newest first.
add_release() {
	_asset=null
	if [ -n "${3:-}" ]; then
		asset_id=$((asset_id + 1))
		_asset=$asset_id
		[ "$3" = missing ] || printf '<rss><channel><item><title>x</title><sparkle:version>%s</sparkle:version></item></channel></rss>\n' \
			"$3" >"$stub/assets/$asset_id"
	fi
	jq --arg tag "$1" --arg body "$2" --argjson id "$_asset" \
		'[{tag_name: $tag, body: $body, draft: false,
		   assets: (if $id == null then [{name: "Bridgeplay.zip", id: 1}] else [{name: "Bridgeplay.zip", id: 1}, {name: "appcast.xml", id: $id}] end)}] + .' \
		"$stub/releases.json" >"$stub/releases.new"
	mv "$stub/releases.new" "$stub/releases.json"
}
line() { printf 'Notes.\n\nBuild %s, based on NotProton 1.2.0.\n' "$1"; }

ledger() { sh "$c1/scripts/build-ledger.sh" "$@"; }
ledger2() { sh "$c2/scripts/build-ledger.sh" "$@"; }
h() { expect_ok "$1" ledger highest -q; expect_eq "$1" "$2" "$out"; }

# --- highest ---------------------------------------------------------------------------

# An empty repository with no releases: H is the highest committed build.
no_releases
h "no releases" 81

# The old releases and the published 80.
add_release v2.0.0 "$(line 32)" 32
add_release installer "Installer fingerprint abc. Build 900, based on NotProton 1.2.0." ""
add_release v3.5.0 "$(line 43)" 43
add_release v0.7.0 "$(line 44)" 44
add_release dxmt-e94c312 "Build 901, based on NotProton 1.2.0.
<!-- bridgeplay-ledger v1
broken" ""
add_release fonts-cjk-29ba44d27134 "<!-- bridgeplay-ledger v9
kind: beta
build: 902
-->" ""
add_release wine-patch-sources-2d19f09dde5d "" ""
add_release beta-feed "$(printf 'Build 903, based on NotProton 1.2.0.\n<!-- bridgeplay-ledger v1\nkind: beta\nbuild: 903\n-->')" 903
add_release v0.7.63 "$(line 80)" 80

# R1: published 80, main committed at 81 (bumped, unreleased): H is 81, so a beta takes 82.
expect_ok "R1 sources" ledger highest
expect_eq "R1 sources" "releases: 80 (v0.7.63)
claims: none
main: 81
H: 81" "$out"
expect_eq "R1 no warnings" "" "$err"
h "R1 -q" 81

# Two claims racing for build/82 from different commits: exactly one wins.
echo one >"$c1/race"
git_in "$c1" add race
git_in "$c1" commit -q -m "beta one"
sha1=$(git_in "$c1" rev-parse HEAD)
echo two >"$c2/race"
git_in "$c2" add race
git_in "$c2" commit -q -m "beta two"
sha2=$(git_in "$c2" rev-parse HEAD)
(rc=0; ledger claim 82 "$sha1" >"$work/r1.out" 2>&1 || rc=$?; echo "$rc" >"$work/r1.rc") &
(rc=0; ledger2 claim 82 "$sha2" >"$work/r2.out" 2>&1 || rc=$?; echo "$rc" >"$work/r2.rc") &
wait
rcs="$(cat "$work/r1.rc") $(cat "$work/r2.rc")"
case $rcs in
	"0 2") winner=$sha1; loser_out=$(cat "$work/r2.out"); pass ;;
	"2 0") winner=$sha2; loser_out=$(cat "$work/r1.out"); pass ;;
	*) winner=""; loser_out=""; fail "race: wanted one 0 and one 2, got $rcs: $(cat "$work/r1.out" "$work/r2.out")" ;;
esac
expect_has "the loser reports taken" "taken" "$loser_out"
expect_has "the loser names the holder" "$winner" "$loser_out"
expect_eq "build/82 is the winner's" "$winner" "$(git_in "$origin" rev-parse refs/tags/build/82)"
expect_eq "build/82 is lightweight" commit "$(git_in "$origin" cat-file -t refs/tags/build/82)"
h "a claim counts" 82

# Claiming again for the same commit is a resume.
if [ "$winner" = "$sha2" ]; then mine=$c2; else mine=$c1; fi
git_in "$mine" commit -q --allow-empty -m "another commit"
other=$(git_in "$mine" rev-parse HEAD)
git_in "$mine" reset -q --hard HEAD~1
expect_ok "again, same commit" sh "$mine/scripts/build-ledger.sh" claim 82 "$winner"
expect_has "already ours" "already ours" "$out"
expect_ok "again, dry run" sh "$mine/scripts/build-ledger.sh" claim 82 "$winner" --dry-run
expect_has "already ours, dry run" "already ours" "$out"
expect_code "taken, dry run" 2 sh "$mine/scripts/build-ledger.sh" claim 82 "$other" --dry-run
expect_has "taken, dry run" "taken" "$err"
# A dry run never pushes.
expect_ok "free, dry run" ledger claim 83 "$sha1" --dry-run
expect_has "free, dry run" "would claim build/83" "$out"
expect_eq "the dry run pushed nothing" "" "$(git_in "$origin" tag -l build/83)"
# A plain claim of HEAD.
expect_ok "claim HEAD" ledger claim 83
expect_has "claimed" "claimed build/83 at $sha1" "$out"
for n in 0 -1 abc 08 ""; do
	expect_code "claim '$n'" 1 ledger claim "$n" "$sha1"
done
expect_code "claim an unknown commit" 1 ledger claim 84 0000000000000000000000000000000000000000

# A claim tag above everything else wins.
git_in "$c1" push -q mirror "$sha1:refs/tags/build/200"
expect_ok "claim 200" ledger highest
expect_has "claim 200 named" "claims: 200 (build/200)" "$out"
expect_has "claim 200 wins" "H: 200" "$out"
git_in "$origin" tag -d build/200 >/dev/null

# Committed builds on develop and release/* count.
set_build "$c1" 84
git_in "$c1" commit -q -am "develop at 84"
git_in "$c1" push -q mirror HEAD:refs/heads/develop
h "develop counts" 84
set_build "$c1" 86
git_in "$c1" commit -q -am "release at 86"
git_in "$c1" push -q mirror HEAD:refs/heads/release/0.8.0
expect_ok "release branch" ledger highest
expect_has "develop listed" "develop: 84" "$out"
expect_has "release listed" "release/0.8.0: 86" "$out"
expect_has "release counts" "H: 86" "$out"
# Other branches don't.
set_build "$c1" 500
git_in "$c1" commit -q -am "a feature branch"
git_in "$c1" push -q mirror HEAD:refs/heads/feature/x HEAD:refs/heads/releases
h "other branches don't count" 86
git_in "$origin" branch -D release/0.8.0 develop feature/x releases >/dev/null

# The ledger is read; when body and appcast disagree, the higher wins with a warning.
add_release v0.8.0-beta.1 "$(line 90)

$(ledger_render kind=beta build=90 channel=beta)" 90
h "ledger and line agree" 90
add_release v0.8.0-beta.2 "$(line 91)" 95
expect_ok "body and appcast disagree" ledger highest -q
expect_eq "the higher wins" 95 "$out"
expect_has "and warns" "warning: release v0.8.0-beta.2" "$err"
add_release v0.8.0-beta.3 "Notes.

$(ledger_render kind=beta build=97 channel=beta)" 96
expect_ok "ledger above appcast" ledger highest -q
expect_eq "ledger above appcast" 97 "$out"
expect_has "and warns" "warning: release v0.8.0-beta.3" "$err"
# A body that records no build falls back to the appcast.
add_release v0.8.0-beta.4 "Notes only." 98
h "appcast fallback" 98

# --- failing closed --------------------------------------------------------------------

saved=$stub/releases.saved
cp "$stub/releases.json" "$saved"
fails_closed() { # NAME: highest fails and prints no number
	expect_code "$1" 1 ledger highest
	expect_eq "$1: no number" "" "$out"
	expect_code "$1 (-q)" 1 ledger highest -q
	expect_eq "$1: no number (-q)" "" "$out"
}

GH_STUB_FAIL=1
export GH_STUB_FAIL
fails_closed "the release list can't be read"
unset GH_STUB_FAIL
rm "$stub/releases.json"
fails_closed "the release API errors"
cp "$saved" "$stub/releases.json"
add_release v0.8.0-beta.5 "Notes only." missing
fails_closed "an appcast can't be read"
cp "$saved" "$stub/releases.json"
add_release v0.8.0-beta.5 "Notes only."
fails_closed "a release records no build"
cp "$saved" "$stub/releases.json"
add_release v0.8.0-beta.5 "$(line 99)
<!-- bridgeplay-ledger v1
kind: beta
build: 99" 99
fails_closed "a malformed ledger"
cp "$saved" "$stub/releases.json"
add_release v0.8.0-beta.5 "$(line 99)
<!-- bridgeplay-ledger v2
kind: beta
build: 99
-->" 99
fails_closed "a newer ledger"
expect_has "a newer ledger says why" "newer than v1" "$err"
cp "$saved" "$stub/releases.json"
h "back to normal" 98

# A missing remote, an unreachable one, and one without main.
BRIDGEPLAY_LEDGER_REMOTE_URL=$work/nowhere.git
fails_closed "no remote with that URL"
expect_has "no remote says so" "no git remote points at" "$err"
git_in "$c1" remote add gone "$work/nowhere.git"
fails_closed "the remote can't be reached"
expect_code "claim offline" 3 ledger claim 85 "$sha1"
expect_has "claim offline says network" "network" "$err"
expect_code "claim offline, dry run" 3 ledger claim 85 "$sha1" --dry-run
empty=$work/empty.git
git_in "$work" init -q --bare "$empty"
git_in "$c1" remote add empty "$empty"
BRIDGEPLAY_LEDGER_REMOTE_URL=$empty
fails_closed "a remote without main"
BRIDGEPLAY_LEDGER_REMOTE_URL=$origin

# --- the bump --------------------------------------------------------------------------

# With no flags it uses H: committed 81, H 98, so the stable takes 99.
git_in "$c1" checkout -q -B main mirror/main
expect_ok "bump with H" sh "$c1/scripts/bump-version.sh" patch
expect_has "bump says H" "highest build online: 98" "$out"
expect_eq "bump build" "#define BRIDGEPLAY_BUILD 99" "$(grep BRIDGEPLAY_BUILD "$c1/dylib/version.h")"
git_in "$c1" checkout -q -- dylib/version.h
# --named behaves as before.
expect_ok "bump named" sh "$c1/scripts/bump-version.sh" patch --named 0.7.64
expect_eq "bump named build" "#define BRIDGEPLAY_BUILD 99" "$(grep BRIDGEPLAY_BUILD "$c1/dylib/version.h")"
git_in "$c1" checkout -q -- dylib/version.h
# With the network down it stops and asks for --highest-build, and changes nothing.
GH_STUB_FAIL=1
export GH_STUB_FAIL
before=$(cat "$c1/dylib/version.h")
expect_code "bump offline" 1 sh "$c1/scripts/bump-version.sh" patch
expect_has "bump offline asks for the flag" "--highest-build N" "$err"
expect_eq "bump offline changes nothing" "$before" "$(cat "$c1/dylib/version.h")"
expect_ok "bump offline with the flag" sh "$c1/scripts/bump-version.sh" patch --highest-build 98
expect_eq "bump flag build" "#define BRIDGEPLAY_BUILD 99" "$(grep BRIDGEPLAY_BUILD "$c1/dylib/version.h")"
unset GH_STUB_FAIL

if [ "$failures" -ne 0 ]; then
	echo "==> ledgercheck: $failures of $checks checks failed" >&2
	exit 1
fi
echo "==> ledgercheck: $checks checks passed"
