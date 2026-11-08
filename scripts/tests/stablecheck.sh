#!/bin/sh
# The stable release mode: scripts/release-lib.sh (the beta list, the R4 gate, the catch-up list,
# the I-6 feed guard, the lock) and scripts/release-local.sh run end to end in a fixture: a local
# bare remote, a gh stub that answers from JSON through jq, stubs for codesign, notarytool and the
# packaging scripts, a fake app, and Sparkle's real generate_appcast and sign_update with a
# throwaway key. Nothing reaches GitHub or the keychain.
#
#   sh scripts/tests/stablecheck.sh      # SPARKLE_BIN=<Sparkle bin folder> to use other tools
# shellcheck disable=SC2034,SC2154 # remote, remote_url, sparkle and key_args feed release-lib.sh; gate_* come back from it
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)

for tool in jq xmllint ditto shasum /usr/libexec/PlistBuddy; do
	command -v "$tool" >/dev/null 2>&1 || { echo "==> stablecheck: skipped, $tool not found"; exit 0; }
done
real_sparkle=${SPARKLE_BIN:-$repo/app/.build/artifacts/sparkle/Sparkle/bin}
if [ ! -x "$real_sparkle/generate_appcast" ] || [ ! -x "$real_sparkle/sign_update" ]; then
	echo "==> stablecheck: skipped, no Sparkle tools at $real_sparkle (swift build --package-path app, or set SPARKLE_BIN)"
	exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/np-stablecheck.XXXXXX")
trap 'rm -rf "$work"' EXIT
unset BRIDGEPLAY_LEDGER_REMOTE_URL SPARKLE_KEY_FILE GH_STUB_FAIL GH_STUB_FAIL_LATEST GH_STUB_CORRUPT \
	BRIDGEPLAY_SIGN_IDENTITY BRIDGEPLAY_NOTARY_PROFILE CX_ROOT

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
expect_has() { # name needle haystack
	case $3 in
		*"$2"*) pass ;;
		*) fail "$1: '$2' not in: $3" ;;
	esac
}
expect_not() { # name needle haystack
	case $3 in
		*"$2"*) fail "$1: '$2' should not be in: $3" ;;
		*) pass ;;
	esac
}
# expect_code NAME CODE CMD...: exits with CODE; stdout and stderr together in $out
expect_code() {
	_name=$1
	_want=$2
	shift 2
	_rc=0
	out=$("$@" 2>&1) || _rc=$?
	if [ "$_rc" -eq "$_want" ]; then pass; else fail "$_name: wanted exit $_want, got $_rc: $out"; fi
}

git_in() { # git_in DIR ARGS...
	_dir=$1
	shift
	git -C "$_dir" -c user.name=stablecheck -c user.email=stablecheck@example.invalid \
		-c commit.gpgsign=false -c tag.gpgsign=false -c core.autocrlf=false \
		-c init.defaultBranch=main -c advice.detachedHead=false "$@"
}

# A throwaway Ed25519 pair (Sparkle's base64 seed and public key), made for this test only.
test_key=$work/test.key
echo 'QSwdH3rZ00ArpTWqPuvvLALHVWAFegYV2Hqu+ULpnCY=' >"$test_key"
test_pub='sb7TAGhHP4p0j/IZiFyDGyjo8dhcK6YkemO6cYyJbGM='
other_key=$work/other.key
head -c 32 /dev/urandom | base64 >"$other_key"

# --- release_ranges ------------------------------------------------------------------------

# shellcheck source=/dev/null
. "$repo/scripts/ledger-lib.sh"
# shellcheck source=/dev/null
. "$repo/scripts/release-lib.sh"

ranges() { printf '%s\n' "$@" | release_ranges; }
expect_eq "no betas" "" "$(printf '' | release_ranges)"
expect_eq "one beta" 81 "$(ranges 81)"
expect_eq "runs" "81-85,87" "$(ranges 81 82 83 84 85 87)"
expect_eq "unsorted with repeats" "79,81-83,90-91" "$(ranges 90 81 83 82 91 79 81)"

# --- the I-6 guard -------------------------------------------------------------------------

sparkle=$real_sparkle
key_args="--ed-key-file $test_key"
slug=raymondchins/Bridgeplay
url=https://github.com/$slug/releases/download/v0.7.64/Bridgeplay.zip

# make_app DIR VERSION BUILD [MIN]: a fake Bridgeplay.app Sparkle can index. A script, so the
# fixture's build stand-in can call it too.
cat >"$work/make-app.sh" <<EOF
#!/bin/sh
set -eu
mkdir -p "\$1/Contents/MacOS" "\$1/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload"
cat >"\$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.bridgeplay.Bridgeplay</string>
<key>CFBundleExecutable</key><string>Bridgeplay</string>
<key>CFBundleName</key><string>Bridgeplay</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>\$2</string>
<key>CFBundleVersion</key><string>\$3</string>
<key>LSMinimumSystemVersion</key><string>\${4:-26.0}</string>
<key>SUPublicEDKey</key><string>$test_pub</string>
</dict></plist>
PLIST
printf '#!/bin/sh\\n' >"\$1/Contents/MacOS/Bridgeplay"
chmod +x "\$1/Contents/MacOS/Bridgeplay"
echo helper >"\$1/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload/helper"
EOF
STABLECHECK_MAKE_APP=$work/make-app.sh
export STABLECHECK_MAKE_APP
make_app() { sh "$STABLECHECK_MAKE_APP" "$@"; }

gfeed=$work/guard
mkdir -p "$gfeed/archive" "$gfeed/stage"
make_app "$gfeed/stage/Bridgeplay.app" 0.7.64 81
ditto -c -k --keepParent "$gfeed/stage/Bridgeplay.app" "$gfeed/archive/Bridgeplay.zip"
# Notes that mention an item and a channel must not count as either.
printf -- '- feat(release): drop sparkle:channel from <item> elements\n' >"$gfeed/archive/Bridgeplay.txt"
# shellcheck disable=SC2086 # key_args is two words
CFFIXED_USER_HOME=$work/home "$sparkle/generate_appcast" $key_args --embed-release-notes --maximum-versions 1 \
	--download-url-prefix "https://github.com/$slug/releases/download/v0.7.64/" "$gfeed/archive" >/dev/null
zipf=$gfeed/archive/Bridgeplay.zip
base=$gfeed/base.xml
cp "$gfeed/archive/appcast.xml" "$base"
if feed_add_contains "$base" "81-85,87" 2>"$work/err"; then pass; else fail "feed_add_contains: $(cat "$work/err")"; fi
expect_eq "the element is in the item" "81-85,87" \
	"$(xp "$base" "string(//*[local-name()='item']/*[local-name()='containsBetas' and namespace-uri()='$BRIDGEPLAY_NS'])")"

# variant NAME SED [KEY]: the base feed edited with SED, then signed (with KEY, default the test key).
variant() {
	sed "$2" "$base" >"$gfeed/$1.xml"
	"$sparkle/sign_update" --ed-key-file "${3:-$test_key}" "$gfeed/$1.xml" >/dev/null
	printf '%s\n' "$gfeed/$1.xml"
}
guard() { feed_guard "$1" 0.7.64 81 "$url" 26.0 "$zipf"; }

f=$(variant good 's/x/x/')
expect_code "a good feed passes" 0 guard "$f"
expect_eq "a good feed passes quietly" "" "$out"

f=$(variant channel 's#<sparkle:version>#<sparkle:channel>beta</sparkle:channel><sparkle:version>#')
expect_code "a channel item is refused" 1 guard "$f"
expect_has "the channel is named" "1 sparkle:channel elements" "$out"

f=$(variant twoitems 's#</channel>#<item><title>0.7.63</title><sparkle:version>80</sparkle:version></item></channel>#')
expect_code "two items are refused" 1 guard "$f"
expect_has "the items are counted" "has 2 items" "$out"

f=$(variant betalabel 's#<sparkle:shortVersionString>0.7.64<#<sparkle:shortVersionString>0.7.64-beta.1<#')
expect_code "a beta label is refused" 1 guard "$f"
expect_has "the label is named" "'0.7.64-beta.1', not a plain X.Y.Z" "$out"

f=$(variant wrongbuild 's#<sparkle:version>81<#<sparkle:version>79<#')
expect_code "a wrong build is refused" 1 guard "$f"
expect_has "the build is named" "carries build '79', not 81" "$out"

f=$(variant good2 's/x/x/')
sed 's/81-85,87/81-86/' "$f" >"$gfeed/tampered.xml"
expect_code "an edit after signing is refused" 1 guard "$gfeed/tampered.xml"
expect_has "the signature is blamed" "feed signature that does not verify" "$out"

f=$(variant otherkey 's/x/x/' "$other_key")
expect_code "another key's signature is refused" 1 guard "$f"
expect_has "another key's signature is blamed" "feed signature that does not verify" "$out"

expect_code "an unsigned feed is refused" 1 guard "$base"
expect_has "unsigned is named" "is not signed" "$out"

f=$(variant nosig 's/ sparkle:edSignature="[^"]*"//')
expect_code "an unsigned enclosure is refused" 1 guard "$f"
expect_has "the enclosure is named" "no enclosure signature" "$out"

f=$(variant elsewhere 's#/v0.7.64/Bridgeplay.zip#/v0.7.63/Bridgeplay.zip#')
expect_code "an enclosure on another tag is refused" 1 guard "$f"
expect_has "the URL is named" "/v0.7.63/Bridgeplay.zip" "$out"

f=$(variant badsig 's#sparkle:edSignature="[A-Za-z0-9+/]\{10\}#sparkle:edSignature="AAAAAAAAAA#')
expect_code "a wrong enclosure signature is refused" 1 guard "$f"
expect_has "the enclosure signature is blamed" "does not match Bridgeplay.zip" "$out"

f=$(variant nocontains 's#<bridgeplay:containsBetas>[^<]*</bridgeplay:containsBetas>##')
expect_code "a missing containsBetas is refused" 1 guard "$f"
expect_has "containsBetas is named" "0 containsBetas elements" "$out"

f=$(variant oldmac 's#<sparkle:minimumSystemVersion>26.0<#<sparkle:minimumSystemVersion>15.0<#')
expect_code "another minimum macOS is refused" 1 guard "$f"
expect_has "the minimum is named" "asks for macOS '15.0'" "$out"

# --- fixture: a bare remote, a clone with the release scripts, stubs ---------------------

origin=$work/origin.git
git_in "$work" init -q --bare "$origin"
fx=$work/fx
mkdir -p "$fx/scripts" "$fx/dylib" "$fx/compat" "$fx/src" "$fx/app/Sources/BridgeplayApp/Model"
for s in release-local release-lib ledger-lib build-ledger version-lib; do
	tr -d '\r' <"$repo/scripts/$s.sh" >"$fx/scripts/$s.sh"
done
printf 'build/\nout/\n.build/\n' >"$fx/.gitignore"
cat >"$fx/NOTICE" <<'EOF'
  wine-patch-sources-2d19f09dde5d.tar.gz, sha256
  193b33d111f9bac6e3f544a219f9fdc8921c2cf4862f5a70d8b12cc78b1c09d2, published on
EOF
echo '    static let archive = "fonts-cjk-29ba44d27134.tar.xz"' >"$fx/app/Sources/BridgeplayApp/Model/CJKFonts.swift"
cat >"$fx/app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>SUPublicEDKey</key><string>$test_pub</string></dict></plist>
EOF
echo '{"games": []}' >"$fx/compat/games.json"
echo 'int main(void) { return 0; }' >"$fx/src/main.c"
# The packaging scripts the release calls: stand-ins that write small files.
cat >"$fx/scripts/build-local.sh" <<'EOF'
#!/bin/sh
# Stand-in: "builds" the app from dylib/version.h.
cd "$(dirname "$0")/.."
v=$(sed -n 's/^#define BRIDGEPLAY_VERSION "\(.*\)"$/\1/p' dylib/version.h)
b=$(sed -n 's/^#define BRIDGEPLAY_BUILD \([0-9]*\)$/\1/p' dylib/version.h)
rm -rf build/Bridgeplay.app
sh "$STABLECHECK_MAKE_APP" build/Bridgeplay.app "$v" "$b"
EOF
# shellcheck disable=SC2016 # expanded by the stand-ins
printf '#!/bin/sh\necho "notarized $1"\n' >"$fx/scripts/notarize.sh"
printf '#!/bin/sh\nmkdir -p out && echo setup >out/Bridgeplay-Setup.zip\n' >"$fx/scripts/package-native-installer.sh"
# shellcheck disable=SC2016 # expanded by the stand-in
printf '#!/bin/sh\necho dmg >"$2"\n' >"$fx/scripts/package-dmg.sh"
cat >"$fx/scripts/package-installer.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --fingerprint-only ]; then echo "${STABLECHECK_INSTALLER_FP:-fp-new}"; exit 0; fi
mkdir -p out && echo installer >out/Bridgeplay-Installer.zip
EOF
chmod +x "$fx"/scripts/*.sh

# Sparkle as the release finds it, with the test key standing in for the keychain.
sb=$fx/app/.build/artifacts/sparkle/Sparkle/bin
mkdir -p "$sb"
for t in generate_appcast sign_update; do
	cat >"$sb/$t" <<EOF
#!/bin/sh
case " \$* " in *" --ed-key-file "*|*" -f "*) exec "$real_sparkle/$t" "\$@" ;; esac
exec "$real_sparkle/$t" --ed-key-file "$test_key" "\$@"
EOF
done
printf '#!/bin/sh\necho "%s"\n' "$test_pub" >"$sb/generate_keys"
chmod +x "$sb"/*

stub=$work/stub
mkdir -p "$stub/bin" "$stub/assets"
cat >"$stub/bin/codesign" <<'EOF'
#!/bin/sh
case " $* " in
	*" --verify "*) exit 0 ;;
	*" -r- "*) echo 'designated => identifier "com.bridgeplay.Bridgeplay" and anchor apple generic and certificate leaf[subject.OU] = AF38EA29BA' >&2 ;;
	*" --verbose=1 "*) echo 'flags=0x10000(runtime)' >&2 ;;
	*" -dvv "*) printf 'Authority=%s\nTimestamp=Nov 9, 2026\n' "$BRIDGEPLAY_SIGN_IDENTITY" >&2 ;;
esac
EOF
cat >"$stub/bin/file" <<'EOF'
#!/bin/sh
case $2 in */helper|*/MacOS/Bridgeplay) echo "Mach-O 64-bit executable arm64" ;; *) echo "ASCII text" ;; esac
EOF
printf '#!/bin/sh\necho '\''  1) ABCDEF "Developer ID Application: Raymond Chin (AF38EA29BA)"'\''\n' >"$stub/bin/security"
printf '#!/bin/sh\nexit 0\n' >"$stub/bin/xcrun"
cat >"$stub/bin/gh" <<'EOF'
#!/bin/sh
# gh stub. Releases live in $GH_STUB/<owner>_<repo>.json in the API's shape, newest first, with
# "latest" marking the Latest one; assets in $GH_STUB/assets/<id>. Every call goes to $GH_STUB/log.
# GH_STUB_FAIL=1: no network. GH_STUB_FAIL_LATEST=1: marking a release Latest fails.
# GH_STUB_CORRUPT=NAME: that asset is stored damaged on upload.
set -eu
printf '%s\n' "$*" >>"$GH_STUB/log"
die() { echo "gh stub: $*" >&2; exit 1; }
[ -z "${GH_STUB_FAIL:-}" ] || die "error connecting to api.github.com"
cmd=$1
shift
sub=""
if [ "$cmd" = release ]; then sub=$1; shift; fi
repo=raymondchins/Bridgeplay
json=""
expr=.
target=""
title=""
notes=""
notes_set=0
latest=""
prerelease=false
pattern=""
dir=""
pos=""
while [ $# -gt 0 ]; do
	case $1 in
		-R) repo=$2; shift 2 ;;
		--json) json=$2; shift 2 ;;
		-q|--jq) expr=$2; shift 2 ;;
		--target) target=$2; shift 2 ;;
		--title) title=$2; shift 2 ;;
		--notes) notes=$2; notes_set=1; shift 2 ;;
		--latest) latest=true; shift ;;
		--latest=false) latest=false; shift ;;
		--prerelease) prerelease=true; shift ;;
		-p) pattern=$2; shift 2 ;;
		--cleanup-tag) shift ;;
		-D) dir=$2; shift 2 ;;
		--limit|-H) shift 2 ;;
		--paginate|--clobber|-y) shift ;;
		-*) die "unexpected flag $1" ;;
		*) pos="$pos$1
"; shift ;;
	esac
done
first=$(printf '%s' "$pos" | sed -n 1p)
if [ "$cmd" = api ]; then
	repo=$(printf '%s\n' "$first" | cut -d/ -f2-3)
fi
st=$GH_STUB/$(printf '%s' "$repo" | tr / _).json
[ -f "$st" ] || echo '[]' >"$st"
save() { mv "$st.new" "$st"; }
shape='{tagName: .tag_name, isDraft: .draft, isPrerelease: .prerelease, body: .body,
	assets: [.assets[] | {name, digest, size}]}'
case "$cmd $sub" in
	"api ")
		case $first in
			repos/*/releases\?per_page=100) jq -r "$expr" "$st" ;;
			*) die "unexpected api path $first" ;;
		esac
		;;
	"release view")
		if [ -n "$first" ]; then
			rel=$(jq --arg t "$first" 'map(select(.tag_name == $t))[0] // empty' "$st")
		else
			rel=$(jq 'map(select(.latest))[0] // empty' "$st")
		fi
		[ -n "$rel" ] || die "release not found"
		if [ -n "$json" ]; then printf '%s' "$rel" | jq -r "$shape | $expr"; else printf '%s' "$rel" | jq -r .tag_name; fi
		;;
	"release list") jq -r "map({tagName: .tag_name}) | $expr" "$st" ;;
	"release create")
		[ "$(jq --arg t "$first" 'map(select(.tag_name == $t)) | length' "$st")" = 0 ] || die "a release with tag $first already exists"
		assets='[]'
		for f in $(printf '%s' "$pos" | sed 1d); do
			n=$(($(cat "$GH_STUB/next-id" 2>/dev/null || echo 100) + 1))
			echo "$n" >"$GH_STUB/next-id"
			cp "$f" "$GH_STUB/assets/$n"
			[ "$(basename "$f")" != "${GH_STUB_CORRUPT:-}" ] || echo damage >>"$GH_STUB/assets/$n"
			d=sha256:$(shasum -a 256 "$GH_STUB/assets/$n" | cut -d' ' -f1)
			s=$(wc -c <"$GH_STUB/assets/$n" | tr -d ' ')
			assets=$(printf '%s' "$assets" | jq --arg n "$(basename "$f")" --arg d "$d" --argjson id "$n" --argjson s "$s" \
				'. + [{name: $n, id: $id, digest: $d, size: $s}]')
		done
		if [ -n "$target" ] && [ -n "${GH_STUB_REMOTE:-}" ]; then
			git -C "$GH_STUB_REMOTE" tag "$first" "$target"
		fi
		[ "$latest" = true ] && jq 'map(.latest = false)' "$st" >"$st.new" && save
		jq --arg t "$first" --arg title "$title" --arg body "$notes" --arg target "$target" \
			--argjson latest "$([ "$latest" = true ] && echo true || echo false)" --argjson pre "$prerelease" \
			--argjson assets "$assets" \
			'[{tag_name: $t, name: $title, body: $body, draft: false, prerelease: $pre, latest: $latest,
			   target_commitish: $target, assets: $assets}] + .' "$st" >"$st.new"
		save
		echo "https://github.com/$repo/releases/tag/$first"
		;;
	"release edit")
		[ "$(jq --arg t "$first" 'map(select(.tag_name == $t)) | length' "$st")" = 1 ] || die "release not found"
		if [ "$latest" = true ]; then
			[ -z "${GH_STUB_FAIL_LATEST:-}" ] || die "HTTP 502: Bad Gateway (PATCH make_latest)"
			jq --arg t "$first" 'map(.latest = (.tag_name == $t))' "$st" >"$st.new"
			save
		fi
		if [ "$notes_set" -eq 1 ]; then
			jq --arg t "$first" --arg b "$notes" 'map(if .tag_name == $t then .body = $b else . end)' "$st" >"$st.new"
			save
		fi
		;;
	"release delete")
		jq --arg t "$first" 'map(select(.tag_name != $t))' "$st" >"$st.new"
		save
		[ -z "${GH_STUB_REMOTE:-}" ] || git -C "$GH_STUB_REMOTE" tag -d "$first" >/dev/null 2>&1 || true
		;;
	"release download")
		id=$(jq -r --arg t "$first" --arg n "$pattern" 'map(select(.tag_name == $t))[0].assets[] | select(.name == $n) | .id' "$st")
		[ -n "$id" ] || die "no asset $pattern on $first"
		mkdir -p "$dir"
		cp "$GH_STUB/assets/$id" "$dir/$pattern"
		;;
	*) die "unexpected: $cmd $sub" ;;
esac
EOF
chmod +x "$stub/bin"/*
GH_STUB=$stub
GH_STUB_REMOTE=$origin
BRIDGEPLAY_LEDGER_REMOTE_URL=$origin
PATH=$stub/bin:$PATH
export GH_STUB GH_STUB_REMOTE BRIDGEPLAY_LEDGER_REMOTE_URL PATH
rel=$stub/raymondchins_Bridgeplay.json

# add_release TAG BODY [latest] [ASSET...]: newest first, as the API lists them.
add_release() {
	_tag=$1
	_body=$2
	_latest=false
	shift 2
	if [ "${1:-}" = latest ]; then _latest=true; shift; jq 'map(.latest = false)' "$rel" >"$rel.new"; mv "$rel.new" "$rel"; fi
	_assets='[]'
	for _a in "$@"; do
		_assets=$(printf '%s' "$_assets" | jq --arg n "${_a%%=*}" --arg d "${_a#*=}" '. + [{name: $n, id: 1, digest: $d, size: 1}]')
	done
	jq --arg t "$_tag" --arg b "$_body" --argjson l "$_latest" --argjson a "$_assets" \
		'[{tag_name: $t, name: $t, body: $b, draft: false, prerelease: ($t | test("beta")), latest: $l, assets: $a}] + .' \
		"$rel" >"$rel.new"
	mv "$rel.new" "$rel"
}
echo '[]' >"$rel"
add_release v0.7.63 "$(printf -- '- things\n\nBuild 80, based on NotProton 1.2.0.')" latest appcast.xml=x Bridgeplay.zip=x
add_release fonts-cjk-29ba44d27134 "fonts" fonts-cjk-29ba44d27134.tar.xz=x
add_release wine-patch-sources-2d19f09dde5d "sources" \
	wine-patch-sources-2d19f09dde5d.tar.gz=sha256:193b33d111f9bac6e3f544a219f9fdc8921c2cf4862f5a70d8b12cc78b1c09d2
add_release installer "$(printf 'The installer.\n\nFingerprint: fp-old')"

set_version() { # set_version VERSION BUILD: in the fixture
	cat >"$fx/dylib/version.h" <<EOF
#ifndef NOTPROTON_VERSION_H
#define NOTPROTON_VERSION_H
#define NOTPROTON_VERSION "1.2.0"
#define BRIDGEPLAY_VERSION "$1"
#define BRIDGEPLAY_BUILD $2
#endif
EOF
}
change() { # change PATH TEXT MESSAGE: one commit in the fixture
	mkdir -p "$(dirname "$fx/$1")"
	echo "$2" >>"$fx/$1"
	git_in "$fx" add -A
	git_in "$fx" commit -q -m "$3"
}
bump() { # bump VERSION BUILD
	set_version "$1" "$2"
	git_in "$fx" commit -q -am "chore(release): Bridgeplay $1"
}
sha() { git_in "$fx" rev-parse "${1:-HEAD}"; }

git_in "$work" init -q "$fx"
set_version 0.7.63 80
git_in "$fx" add -A
git_in "$fx" commit -q -m "release 0.7.63"
git_in "$fx" remote add mirror "$origin"
git_in "$fx" tag v0.7.63
m0=$(sha)
bump 0.7.64 81
p0=$(sha)
git_in "$fx" push -q mirror HEAD:refs/heads/main v0.7.63

release() { (cd "$fx" && sh scripts/release-local.sh "$@"); }
# run_env VAR=VALUE ARGS...: a run with one more variable; SPARKLE_KEY_FILE is the test key.
run_env() {
	_e=$1
	shift
	(cd "$fx" && env SPARKLE_KEY_FILE="$test_key" "$_e" sh scripts/release-local.sh "$@")
}
# The installer on GitHub is current unless a test says otherwise.
STABLECHECK_INSTALLER_FP=fp-old
CFFIXED_USER_HOME=$work/home
export STABLECHECK_INSTALLER_FP CFFIXED_USER_HOME
dry() { SPARKLE_KEY_FILE=$test_key release --dry-run "$@"; }
appcast=$fx/out/release/bridgeplay/appcast.xml

# --- today's flow: no betas, a dry run --------------------------------------------------

make_app "$fx/build/Bridgeplay.app" 0.7.64 81

expect_code "today's dry run" 0 run_env STABLECHECK_INSTALLER_FP=fp-new --dry-run --legacy-feed
today=$out
expect_not "today: nothing would stop" "would stop here" "$today"
expect_has "today: claims its build" "dry run: would claim build/81 at $p0" "$today"
expect_has "today: signs and checks the feed" "stable feed signed and checked (I-6): build 81, contains betas none" "$today"
expect_has "today: no betas" "contains betas: none; promoted from: none" "$today"
# The publishing steps, in order: as before, except the release is created without Latest and
# then marked Latest.
heads=$(printf '%s\n' "$today" | sed -n 's/^==> would run: \(gh release [a-z]* [^ ]*\).*/\1/p')
expect_eq "today: the steps" "gh release create v0.7.64
gh release edit v0.7.64
gh release create v0.7.64
gh release upload installer
gh release upload installer
gh release edit installer" "$heads"
expect_has "today: created without Latest" "--> --latest=false" "$today"
expect_has "today: then marked Latest" "==> would run: gh release edit v0.7.64 -R raymondchins/Bridgeplay --latest" "$today"
expect_has "today: the legacy feed" "-R raymondchins/NotProton-WineHQ --title Bridgeplay 0.7.64 --notes NotProton is now Bridgeplay." "$today"
expect_has "today: the installer zip" "next-Bridgeplay-Installer.zip -R raymondchins/Bridgeplay" "$today"
expect_has "today: the installer signature" "next-Bridgeplay-Installer.zip.sig -R raymondchins/Bridgeplay" "$today"
expect_has "today: the assets" "gh release create v0.7.64 out/release/bridgeplay/Bridgeplay.zip out/release/bridgeplay/appcast.xml out/release/bridgeplay/Bridgeplay-Setup.zip out/release/bridgeplay/Bridgeplay.dmg -R raymondchins/Bridgeplay --target $p0 --title Bridgeplay 0.7.64 --notes" "$today"
expect_has "today: the ledger" "<!-- bridgeplay-ledger v1
kind: stable
build: 81
label: 0.7.64
tag: v0.7.64
commit: $p0
source-branch: main
zip-sha256: $(shasum -a 256 "$fx/out/release/bridgeplay/Bridgeplay.zip" | cut -d' ' -f1)" "$today"
expect_has "today: ledger tail" "promoted-from: none
contains-betas: none
-->" "$today"
expect_has "today: the Build line stays" "Build 81, based on NotProton 1.2.0." "$today"
expect_code "today: the feed passes I-6" 0 feed_guard "$appcast" 0.7.64 81 "$url" 26.0 "$fx/out/release/bridgeplay/Bridgeplay.zip"
expect_eq "today: an empty containsBetas" "" "$(xp "$appcast" "string(//*[local-name()='containsBetas'])")"
expect_eq "today: one containsBetas" 1 "$(xp "$appcast" "count(//*[local-name()='containsBetas'])")"
legacy_feed=$fx/out/release/legacy/appcast.xml
expect_eq "today: the legacy feed is unsigned" 0 "$(grep -c 'sparkle-signatures' "$legacy_feed" || true)"
expect_eq "today: the legacy feed has no containsBetas" 0 "$(xp "$legacy_feed" "count(//*[local-name()='containsBetas'])")"
expect_eq "today: the lock is released" "" "$(ls -d "$fx/.git/bridgeplay-release.lock" 2>/dev/null || true)"
expect_eq "today: the dry run claimed nothing" "" "$(git_in "$origin" tag -l 'build/*')"

# The installer unchanged: not uploaded. No legacy feed asked for: none.
expect_code "dry run, installer unchanged" 0 dry
expect_has "installer unchanged" "installer unchanged (fp-old), not uploaded" "$out"
expect_not "no legacy feed" "NotProton-WineHQ" "$out"

# Without SPARKLE_KEY_FILE the throwaway key signs the feed but not the enclosure.
expect_code "throwaway key dry run" 0 release --dry-run
expect_has "throwaway: the enclosure is unsigned" "I-6: out/release/bridgeplay/appcast.xml has no enclosure signature" "$out"
expect_has "throwaway: a release would stop" "dry run, would stop here: the stable feed fails I-6" "$out"
expect_not "throwaway: the feed itself verifies" "feed signature that does not verify" "$out"
expect_eq "throwaway: the feed is signed" 1 "$(grep -c 'sparkle-signatures:' "$appcast")"

# An app asking for another macOS stops the release instead of a feed edit.
make_app "$fx/build/Bridgeplay.app" 0.7.64 81 15.0
expect_code "another LSMinimumSystemVersion" 1 dry
expect_has "the minimum macOS is checked" "would stop here: the app's LSMinimumSystemVersion is '15.0', not 26.0" "$out"
expect_has "and the feed is not edited to fit" "does not ask for macOS 26.0" "$out"
rm -rf "$fx/build"

# --- claims -----------------------------------------------------------------------------

make_app "$fx/build/Bridgeplay.app" 0.7.64 81
git_in "$fx" push -q mirror "$m0:refs/tags/build/81"
expect_code "claim taken" 0 dry
expect_has "taken is reported" "taken: build/81 is held by $m0" "$out"
expect_has "taken would stop" "would stop here: build/81 is taken by another commit; bump again with the current H" "$out"
git_in "$origin" tag -d build/81 >/dev/null
git_in "$fx" push -q mirror "$p0:refs/tags/build/81"
expect_code "claim already ours" 0 dry
expect_has "already ours resumes" "already ours: build/81 is at $p0; resuming" "$out"
expect_not "already ours goes on" "would stop here" "$out"
git_in "$origin" tag -d build/81 >/dev/null

# A real run stops at a taken claim before building anything.
git_in "$fx" push -q mirror "$m0:refs/tags/build/81"
rm -rf "$fx/build"
: >"$stub/log"
expect_code "a real run with the claim taken" 1 release
expect_has "a real run stops at the claim" "build/81 is taken by another commit" "$out"
expect_eq "nothing was built" "" "$(ls -d "$fx/build/Bridgeplay.app" 2>/dev/null || true)"
expect_not "nothing was created" "release create" "$(cat "$stub/log")"
git_in "$origin" tag -d build/81 >/dev/null

# --- publication: create without Latest, check the digests, expose; a crash in between ----

# A damaged upload is caught before Latest; the release is deleted so a rerun starts clean.
: >"$stub/log"
expect_code "a damaged upload" 1 run_env GH_STUB_CORRUPT=Bridgeplay.dmg
expect_has "the damage is named" "uploaded Bridgeplay.dmg has digest" "$out"
expect_has "the damaged release is deleted" "deleted v0.7.64 (it was never Latest), run again" "$out"
expect_eq "its tag is gone" "" "$(git_in "$origin" tag -l v0.7.64)"
expect_eq "the damaged release is gone" 0 "$(jq 'map(select(.tag_name == "v0.7.64")) | length' "$rel")"
expect_eq "Latest did not move" v0.7.63 "$(jq -r 'map(select(.latest))[0].tag_name' "$rel")"
expect_eq "the claim stays" "$p0" "$(git_in "$origin" rev-parse refs/tags/build/81)"

# Marking Latest fails: the release stays, not Latest.
: >"$stub/log"
expect_code "a crash before exposure" 1 run_env GH_STUB_FAIL_LATEST=1
expect_has "the failure is shown" "HTTP 502" "$out"
expect_has "the digests were checked first" "uploaded digests match: Bridgeplay.zip appcast.xml Bridgeplay-Setup.zip Bridgeplay.dmg" "$out"
expect_eq "created once" 1 "$(grep -c '^release create v0.7.64 ' "$stub/log")"
expect_eq "not Latest" false "$(jq -r 'map(select(.tag_name == "v0.7.64"))[0].latest' "$rel")"
expect_eq "Latest is still the old one" v0.7.63 "$(jq -r 'map(select(.latest))[0].tag_name' "$rel")"
expect_eq "the tag is at HEAD" "$p0" "$(git_in "$origin" rev-parse refs/tags/v0.7.64)"
# The rerun goes straight to exposure and uploads nothing.
: >"$stub/log"
expect_code "the rerun" 0 release
expect_has "the rerun resumes" "v0.7.64 exists but is not Latest" "$out"
expect_has "the rerun says so" "nothing was uploaded again" "$out"
expect_eq "the rerun created nothing" 0 "$(grep -c -e '^release create' -e '^release upload' "$stub/log" || true)"
expect_not "the rerun built nothing" "notarized" "$out"
expect_eq "now Latest" v0.7.64 "$(jq -r 'map(select(.latest))[0].tag_name' "$rel")"
body=$(jq -r 'map(select(.tag_name == "v0.7.64"))[0].body' "$rel")
expect_eq "the ledger build" 81 "$(printf '%s\n' "$body" | ledger_field build)"
expect_eq "the ledger kind" stable "$(printf '%s\n' "$body" | ledger_field kind)"
expect_eq "the ledger commit" "$p0" "$(printf '%s\n' "$body" | ledger_field commit)"
expect_eq "the ledger zip" "$(jq -r 'map(select(.tag_name == "v0.7.64"))[0].assets[] | select(.name == "Bridgeplay.zip") | .digest' "$rel")" \
	"sha256:$(printf '%s\n' "$body" | ledger_field zip-sha256)"
expect_eq "the old Build line" 81 "$(printf '%s\n' "$body" | legacy_build)"
mkdir -p "$work/published"
gh release download v0.7.64 -p appcast.xml -D "$work/published" --clobber
expect_code "the published feed passes I-6" 0 feed_guard "$work/published/appcast.xml" 0.7.64 81 "$url" 26.0
expect_eq "the published feed's signature is the ledger's" "$(printf '%s\n' "$body" | ledger_field ed-signature)" \
	"$(xp "$work/published/appcast.xml" "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])")"
expect_code "a third run" 1 release
expect_has "a third run stops" "v0.7.64 is already released" "$out"

# --- betas and the R4 gate ----------------------------------------------------------------

# beta TAG BUILD BRANCH [COMMIT]: tags COMMIT (default HEAD) and publishes it as a beta.
beta() {
	_c=${4:-$(sha)}
	git_in "$fx" push -q mirror "$_c:refs/tags/$1"
	add_release "$1" "$(printf -- '- beta notes\n\nBuild %s, based on NotProton 1.2.0.\n\n%s' "$2" \
		"$(ledger_render kind=beta "build=$2" "label=${1#v}" "tag=$1" "commit=$_c" "source-branch=$3" channel=beta)")"
}

# develop: a feature and beta 82. release/0.7.65 from it: a fix and RC beta 83. develop goes on:
# beta 84, which no stable here contains. main: a hotfix during the soak.
git_in "$fx" checkout -q -b develop "$p0"
change src/feature.c feature "feat: a feature"
d1=$(sha)
beta v0.7.65-beta.1 82 develop
git_in "$fx" checkout -q -b release/0.7.65 "$d1"
change src/fix.c fix "fix: an RC fix"
beta v0.7.65-beta.2 83 release/0.7.65
git_in "$fx" checkout -q develop
change src/later.c later "feat: for later"
beta v0.7.66-beta.1 84 develop
git_in "$fx" checkout -q -B main "$p0"
change src/hotfix.c hotfix "fix: a hotfix during the soak"
h1=$(sha)

gate() { # gate HEAD [PREVIOUS]: release_gate in the fixture, previous v0.7.64
	(
		cd "$fx"
		remote=mirror
		remote_url=$origin
		release_published_betas "$work/betas" || exit 9
		release_gate "$1" "${2-$p0}" "$work/betas" || exit 1
		printf 'contains=%s\npromoted=%s\ndata=%s\n' "$gate_contains" "$gate_promoted" "$(printf '%s' "$gate_data" | tr '\n' ' ')"
	)
}

# The release branch merged into main and bumped, but main has the hotfix the RC never had.
git_in "$fx" checkout -q -b cand-a "$h1"
git_in "$fx" merge -q --no-ff --no-edit release/0.7.65
bump 0.7.65 85
expect_code "R4: a hotfix the RC lacks is refused" 1 gate "$(sha)"
expect_has "R4: the hotfix path is listed" "      src/hotfix.c" "$out"
expect_not "R4: the version header is not" "dylib/version.h" "$out"
expect_has "R4: the remedy" "Merge main into release/0.7.65, publish a new release-candidate beta" "$out"

# The remedy: main merged into the release branch, a new RC beta 86, merged, data changed by the
# compat bot, bumped: accepted, with the stray beta 84 left out of the list.
git_in "$fx" checkout -q release/0.7.65
git_in "$fx" merge -q --no-ff --no-edit "$h1"
beta v0.7.65-beta.3 86 release/0.7.65
git_in "$fx" checkout -q -b cand-b "$h1"
git_in "$fx" merge -q --no-ff --no-edit release/0.7.65
change compat/games.json '{"games": ["new"]}' "chore(compat): weekly"
bump 0.7.65 87
b3=$(sha)
expect_code "R4: the merged RC is accepted" 0 gate "$b3"
expect_has "R4: it contains its betas, not the stray one" "contains=82-83,86" "$out"
expect_has "R4: promoted from the RC" "promoted=v0.7.65-beta.3" "$out"
expect_has "R4: the compat data is listed" "data=compat/games.json" "$out"

# Anything else after the RC is refused, the compat data is not blamed.
git_in "$fx" checkout -q -b cand-b2 "$b3"
change src/sneak.c sneak "fix: after the RC"
expect_code "R4: a change after the RC is refused" 1 gate "$(sha)"
expect_has "R4: the change is listed" "      src/sneak.c" "$out"
expect_not "R4: compat is allowed" "      compat/games.json" "$out"

# A beta built from develop is not a release candidate.
git_in "$fx" checkout -q -b cand-c "$p0"
git_in "$fx" merge -q --no-ff --no-edit "$d1"
bump 0.7.65 85
expect_code "R4: a develop beta is refused" 1 gate "$(sha)"
expect_has "R4: develop is named" "built from develop, not a release/*" "$out"

# Squash promotion: the RC's tree without its commits (X-18).
git_in "$fx" checkout -q -b cand-d "$h1"
git_in "$fx" merge -q --squash release/0.7.65 >/dev/null
git_in "$fx" commit -q -m "Release 0.7.65 (#99)"
bump 0.7.65 85
expect_code "X-18: a squash promotion is refused" 1 gate "$(sha)"
expect_has "X-18: the beta is named" "ships the tree of beta v0.7.65-beta.3" "$out"
expect_has "X-18: the remedy" "merge commit (no squash" "$out"

# A plain hotfix contains no beta: no gate.
git_in "$fx" checkout -q -b cand-e "$h1"
bump 0.7.65 85
expect_code "a hotfix passes" 0 gate "$(sha)"
expect_has "a hotfix contains nothing" "contains=
promoted=none" "$out"

# After the promotion ships, a hotfix on it contains its betas but promotes none.
git_in "$fx" checkout -q -b cand-f "$b3"
change src/hotfix2.c hotfix2 "fix: after 0.7.65"
bump 0.7.66 88
expect_code "a hotfix after a promotion" 0 gate "$(sha)" "$b3"
expect_has "a hotfix after a promotion lists the betas" "contains=82-83,86
promoted=none" "$out"

# The beta list fails closed.
saved=$stub/saved.json
cp "$rel" "$saved"
add_release v0.7.66-beta.2 "No ledger here."
expect_code "a beta without a ledger" 9 gate "$b3"
expect_has "a beta without a ledger says so" "v0.7.66-beta.2 has no complete v1 ledger" "$out"
cp "$saved" "$rel"
git_in "$fx" push -q mirror "$p0:refs/tags/v0.7.66-beta.2"
add_release v0.7.66-beta.2 "$(ledger_render kind=beta build=89 label=0.7.66-beta.2 tag=v0.7.66-beta.2 commit="$d1" source-branch=develop)"
expect_code "a ledger that disagrees with its tag" 9 gate "$b3"
expect_has "the disagreement is named" "tag v0.7.66-beta.2 is at $p0 but its ledger says $d1" "$out"
cp "$saved" "$rel"
add_release v0.7.66-beta.3 "$(ledger_render kind=beta build=90 label=0.7.66-beta.3 tag=v0.7.66-beta.3 commit="$d1" source-branch=develop)"
expect_code "a beta with no tag" 9 gate "$b3"
expect_has "the missing tag is named" "has no tag v0.7.66-beta.3" "$out"
cp "$saved" "$rel"
jq 'map(if .tag_name == "v0.7.65-beta.1" then .draft = true else . end)' "$saved" >"$rel"
expect_code "a draft beta does not count" 0 gate "$b3"
expect_has "a draft beta does not count" "contains=83,86" "$out"
cp "$saved" "$rel"
GH_STUB_FAIL=1
export GH_STUB_FAIL
expect_code "the release list can't be read" 9 gate "$b3"
expect_has "the release list can't be read" "can't read the releases" "$out"
unset GH_STUB_FAIL

# --- the promotion end to end ------------------------------------------------------------

git_in "$fx" checkout -q main
git_in "$fx" reset -q --hard "$b3"
git_in "$fx" push -q -f mirror HEAD:refs/heads/main
make_app "$fx/build/Bridgeplay.app" 0.7.65 87
expect_code "promotion dry run" 0 dry
expect_not "promotion: nothing would stop" "would stop here" "$out"
expect_has "promotion: what it contains" "contains betas: 82-83,86; promoted from: v0.7.65-beta.3" "$out"
expect_has "promotion: the data is printed" "    compat/games.json" "$out"
expect_has "promotion: the body lists the data" "Data changed since the beta (v0.7.65-beta.3):
- compat/games.json

Build 87, based on NotProton 1.2.0." "$out"
expect_has "promotion: the ledger" "promoted-from: v0.7.65-beta.3
contains-betas: 82-83,86
-->" "$out"
expect_eq "promotion: the feed lists the betas" "82-83,86" "$(xp "$appcast" "string(//*[local-name()='containsBetas'])")"

git_in "$fx" reset -q --hard cand-a
git_in "$fx" push -q -f mirror HEAD:refs/heads/main
make_app "$fx/build/Bridgeplay.app" 0.7.65 85
expect_code "refused promotion dry run" 0 dry
expect_has "refused promotion: would stop" "would stop here: this stable may not ship as it is" "$out"
expect_has "refused promotion: the path" "      src/hotfix.c" "$out"

# --- the lock -----------------------------------------------------------------------------

lockdir=$fx/.git/bridgeplay-release.lock
(cd "$fx" && exec sh -c ". '$repo/scripts/release-lib.sh'; release_lock && sleep 3") &
holder=$!
i=0
while [ ! -f "$lockdir/pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
expect_code "a held lock" 1 release --dry-run
expect_has "the holder is named" "another release (pid $holder) holds" "$out"
wait "$holder"
expect_code "a stale lock is taken over" 0 sh -c "cd '$fx' && . '$repo/scripts/release-lib.sh' && release_lock && release_unlock"
expect_has "taking over says so" "from a release that is gone (pid $holder)" "$out"

if [ "$failures" -ne 0 ]; then
	echo "==> stablecheck: $failures of $checks checks failed" >&2
	exit 1
fi
echo "==> stablecheck: $checks checks passed"
