#!/bin/sh
# The beta release mode and the beta feed: scripts/release-local.sh --beta and the stable mode's
# refresh of the beta feed, run end to end through a scripted history (betas, a beta-critical, a
# hotfix stable, a waiver, a promotion, a withdrawal) in a fixture built like stablecheck's: a
# local bare remote, a gh stub that answers from JSON through jq, stubs for codesign, notarytool
# and the packaging scripts, the real stamp-beta.sh, and Sparkle's real sign_update and
# generate_appcast with a throwaway key. Nothing reaches GitHub or the keychain.
#
#   sh scripts/tests/betacheck.sh      # SPARKLE_BIN=<Sparkle bin folder> to use other tools
# shellcheck disable=SC2034 # sparkle, slug and key_args feed release-lib.sh
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)

for tool in jq xmllint ditto shasum /usr/libexec/PlistBuddy; do
	command -v "$tool" >/dev/null 2>&1 || { echo "==> betacheck: skipped, $tool not found"; exit 0; }
done
real_sparkle=${SPARKLE_BIN:-$repo/app/.build/artifacts/sparkle/Sparkle/bin}
if [ ! -x "$real_sparkle/generate_appcast" ] || [ ! -x "$real_sparkle/sign_update" ]; then
	echo "==> betacheck: skipped, no Sparkle tools at $real_sparkle (swift build --package-path app, or set SPARKLE_BIN)"
	exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/np-betacheck.XXXXXX")
trap 'rm -rf "$work"' EXIT
unset BRIDGEPLAY_LEDGER_REMOTE_URL SPARKLE_KEY_FILE GH_STUB_FAIL GH_STUB_FAIL_LATEST GH_STUB_CORRUPT GH_STUB_BREAK_CREATE \
	GH_STUB_FAIL_UPLOAD BRIDGEPLAY_SIGN_IDENTITY BRIDGEPLAY_NOTARY_PROFILE CX_ROOT BRIDGEPLAY_BETA \
	BRIDGEPLAY_BETA_BUILD BRIDGEPLAY_BETA_PLANNED BRIDGEPLAY_HIGHEST_BUILD BETACHECK_RACE

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
	git -C "$_dir" -c user.name=betacheck -c user.email=betacheck@example.invalid \
		-c commit.gpgsign=false -c tag.gpgsign=false -c core.autocrlf=false \
		-c init.defaultBranch=main -c advice.detachedHead=false "$@"
}

# A throwaway Ed25519 pair (Sparkle's base64 seed and public key), made for these tests only.
test_key=$work/test.key
echo 'QSwdH3rZ00ArpTWqPuvvLALHVWAFegYV2Hqu+ULpnCY=' >"$test_key"
test_pub='sb7TAGhHP4p0j/IZiFyDGyjo8dhcK6YkemO6cYyJbGM='
other_key=$work/other.key
head -c 32 /dev/urandom | base64 >"$other_key"

# shellcheck source=/dev/null
. "$repo/scripts/ledger-lib.sh"
# shellcheck source=/dev/null
. "$repo/scripts/release-lib.sh"
sparkle=$real_sparkle
key_args="--ed-key-file $test_key"
slug=raymondchins/Bridgeplay

# make-app.sh DIR VERSION BUILD [CHANNEL]: a fake Bridgeplay.app Sparkle can index.
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
<key>BridgeplayChannel</key><string>\${4:-stable}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>SUPublicEDKey</key><string>$test_pub</string>
</dict></plist>
PLIST
printf '#!/bin/sh\\n' >"\$1/Contents/MacOS/Bridgeplay"
chmod +x "\$1/Contents/MacOS/Bridgeplay"
echo "helper \$2" >"\$1/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload/helper"
EOF
BETACHECK_MAKE_APP=$work/make-app.sh
export BETACHECK_MAKE_APP
make_app() { sh "$BETACHECK_MAKE_APP" "$@"; }

# --- fixture: a bare remote, a clone with the release scripts, stubs ---------------------

origin=$work/origin.git
git_in "$work" init -q --bare "$origin"
fx=$work/fx
mkdir -p "$fx/scripts" "$fx/dylib" "$fx/compat" "$fx/src" "$fx/app/Sources/BridgeplayApp/Model"
for s in release-local release-lib ledger-lib version-lib stamp-beta; do
	tr -d '\r' <"$repo/scripts/$s.sh" >"$fx/scripts/$s.sh"
done
tr -d '\r' <"$repo/scripts/build-ledger.sh" >"$fx/scripts/build-ledger-real.sh"
# The race: before claiming a build listed in BETACHECK_RACE, a rival release takes it.
cat >"$fx/scripts/build-ledger.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = claim ] && [ -n "${BETACHECK_RACE:-}" ]; then
	case " $BETACHECK_RACE " in
		*" $2 "*) git push -q "$BRIDGEPLAY_LEDGER_REMOTE_URL" "$BETACHECK_RIVAL:refs/tags/build/$2" 2>/dev/null || true ;;
	esac
fi
exec sh "$(dirname "$0")/build-ledger-real.sh" "$@"
EOF
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
# The build stand-in stamps the app as the real build does, through stamp-beta.sh.
cat >"$fx/scripts/build-local.sh" <<'EOF'
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
stamp=$(sh scripts/stamp-beta.sh print)
v=$(printf '%s\n' "$stamp" | sed -n 's/^version=//p')
b=$(printf '%s\n' "$stamp" | sed -n 's/^build=//p')
c=$(printf '%s\n' "$stamp" | sed -n 's/^channel=//p')
rm -rf build/Bridgeplay.app
sh "$BETACHECK_MAKE_APP" build/Bridgeplay.app "$v" "$b" "$c"
echo "built $v ($b) on $c"
EOF
# shellcheck disable=SC2016 # expanded by the stand-ins
printf '#!/bin/sh\necho "notarized $1"\n' >"$fx/scripts/notarize.sh"
printf '#!/bin/sh\nmkdir -p out && echo setup >out/Bridgeplay-Setup.zip\necho packaged-setup\n' >"$fx/scripts/package-native-installer.sh"
# shellcheck disable=SC2016 # expanded by the stand-in
printf '#!/bin/sh\necho dmg >"$2"\necho packaged-dmg\n' >"$fx/scripts/package-dmg.sh"
cat >"$fx/scripts/package-installer.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --fingerprint-only ]; then echo fp-old; exit 0; fi
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
# GH_STUB_FAIL=1: no network. GH_STUB_CORRUPT=NAME: that asset is stored damaged on upload.
# GH_STUB_BREAK_CREATE=NAME: release create breaks off before uploading that asset, leaving a draft.
# GH_STUB_FAIL_UPLOAD=NAME: uploading that asset to an existing release fails.
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
method=GET
field=""
accept=""
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
		-D) dir=$2; shift 2 ;;
		-X) method=$2; shift 2 ;;
		-f) field=$2; shift 2 ;;
		-H) accept=$2; shift 2 ;;
		--limit) shift 2 ;;
		--paginate|--clobber|-y|--cleanup-tag) shift ;;
		-*) die "unexpected flag $1" ;;
		*) pos="$pos$1
"; shift ;;
	esac
done
first=$(printf '%s' "$pos" | sed -n 1p)
second=$(printf '%s' "$pos" | sed -n 2p)
if [ "$cmd" = api ]; then
	repo=$(printf '%s\n' "$first" | cut -d/ -f2-3)
fi
st=$GH_STUB/$(printf '%s' "$repo" | tr / _).json
[ -f "$st" ] || echo '[]' >"$st"
save() { mv "$st.new" "$st"; }
has() { [ "$(jq --arg t "$1" 'map(select(.tag_name == $t)) | length' "$st")" = 1 ]; }
# store FILE: stores an asset, prints its JSON.
store() {
	n=$(($(cat "$GH_STUB/next-id" 2>/dev/null || echo 100) + 1))
	echo "$n" >"$GH_STUB/next-id"
	cp "$1" "$GH_STUB/assets/$n"
	[ "$(basename "$1")" != "${GH_STUB_CORRUPT:-}" ] || echo damage >>"$GH_STUB/assets/$n"
	d=sha256:$(shasum -a 256 "$GH_STUB/assets/$n" | cut -d' ' -f1)
	s=$(wc -c <"$GH_STUB/assets/$n" | tr -d ' ')
	jq -n --arg n "$(basename "$1")" --arg d "$d" --argjson id "$n" --argjson s "$s" '{name: $n, id: $id, digest: $d, size: $s}'
}
shape='{tagName: .tag_name, isDraft: .draft, isPrerelease: .prerelease, body: .body,
	assets: [.assets[] | {name, digest, size}]}'
case "$cmd $sub" in
	"api ")
		case $first in
			repos/*/releases\?per_page=100) jq -r "$expr" "$st" ;;
			repos/*/releases/tags/*)
				t=${first##*/releases/tags/}
				has "$t" || die "HTTP 404: Not Found"
				jq -r --arg t "$t" "map(select(.tag_name == \$t))[0] | $expr" "$st"
				;;
			repos/*/releases/assets/*)
				id=${first##*/}
				[ -f "$GH_STUB/assets/$id" ] || die "HTTP 404: Not Found"
				if [ "$method" = PATCH ]; then
					jq --argjson id "$id" --arg n "${field#name=}" \
						'map(.assets = [.assets[] | if .id == $id then .name = $n else . end])' "$st" >"$st.new"
					save
				else
					[ -n "$accept" ] || die "an asset without Accept"
					cat "$GH_STUB/assets/$id"
				fi
				;;
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
		has "$first" && die "a release with tag $first already exists"
		assets='[]'
		for f in $(printf '%s' "$pos" | sed 1d); do
			if [ "$(basename "$f")" = "${GH_STUB_BREAK_CREATE:-}" ]; then
			jq --arg t "$first" --arg title "$title" --arg body "$notes" --arg target "$target" --argjson pre "$prerelease" \
				--argjson assets "$assets" \
				'[{tag_name: $t, name: $title, body: $body, draft: true, prerelease: $pre, latest: false,
				   target_commitish: $target, assets: $assets}] + .' "$st" >"$st.new"
			save
			die "HTTP 502: Bad Gateway (upload $(basename "$f"))"
			fi
			assets=$(printf '%s' "$assets" | jq --argjson a "$(store "$f")" '. + [$a]')
		done
		if [ -n "$target" ] && [ -n "${GH_STUB_REMOTE:-}" ]; then
			git -C "$GH_STUB_REMOTE" tag "$first" "$target"
		fi
		[ "$latest" = true ] && jq 'map(.latest = false)' "$st" >"$st.new" && save
		jq --arg t "$first" --arg title "$title" --arg body "$notes" --arg target "$target" \
			--argjson latest "$([ "$latest" = true ] && echo true || echo false)" --argjson pre "$prerelease" \
			--argjson assets "$assets" \
			'[{tag_name: $t, name: $title, body: $body, draft: false, prerelease: $pre, latest: $latest,
			   published_at: (now | todate), target_commitish: $target, assets: $assets}] + .' "$st" >"$st.new"
		save
		echo "https://github.com/$repo/releases/tag/$first"
		;;
	"release upload")
		has "$first" || die "release not found"
		[ "$(basename "$second")" != "${GH_STUB_FAIL_UPLOAD:-}" ] || die "HTTP 502: Bad Gateway (upload $(basename "$second"))"
		[ "$(jq -r --arg t "$first" --arg n "$(basename "$second")" 'map(select(.tag_name == $t))[0].assets | map(select(.name == $n)) | length' "$st")" = 0 ] \
			|| die "asset $(basename "$second") already exists"
		jq --arg t "$first" --argjson a "$(store "$second")" 'map(if .tag_name == $t then .assets += [$a] else . end)' "$st" >"$st.new"
		save
		;;
	"release delete-asset")
		[ "$(jq -r --arg t "$first" --arg n "$second" 'map(select(.tag_name == $t))[0].assets // [] | map(select(.name == $n)) | length' "$st")" = 1 ] \
			|| die "asset $second not found"
		jq --arg t "$first" --arg n "$second" 'map(if .tag_name == $t then .assets = [.assets[] | select(.name != $n)] else . end)' "$st" >"$st.new"
		save
		;;
	"release edit")
		has "$first" || die "release not found"
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
		id=$(jq -r --arg t "$first" --arg n "$pattern" 'map(select(.tag_name == $t))[0].assets // [] | .[] | select(.name == $n) | .id' "$st")
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
CFFIXED_USER_HOME=$work/home
export GH_STUB GH_STUB_REMOTE BRIDGEPLAY_LEDGER_REMOTE_URL PATH CFFIXED_USER_HOME
rel=$stub/raymondchins_Bridgeplay.json
log=$stub/log

# add_release TAG BODY [latest] [NAME=DIGEST | NAME@FILE ...]: newest first, as the API lists them.
add_release() {
	_tag=$1
	_body=$2
	_latest=false
	shift 2
	if [ "${1:-}" = latest ]; then _latest=true; shift; jq 'map(.latest = false)' "$rel" >"$rel.new"; mv "$rel.new" "$rel"; fi
	_assets='[]'
	for _a in "$@"; do
		case $_a in
			*@*)
				_n=$(($(cat "$stub/next-id" 2>/dev/null || echo 100) + 1))
				echo "$_n" >"$stub/next-id"
				cp "${_a#*@}" "$stub/assets/$_n"
				_assets=$(printf '%s' "$_assets" | jq --arg n "${_a%%@*}" --argjson id "$_n" \
					--arg d "sha256:$(shasum -a 256 "${_a#*@}" | cut -d' ' -f1)" --argjson s "$(wc -c <"${_a#*@}" | tr -d ' ')" \
					'. + [{name: $n, id: $id, digest: $d, size: $s}]')
				;;
			*) _assets=$(printf '%s' "$_assets" | jq --arg n "${_a%%=*}" --arg d "${_a#*=}" '. + [{name: $n, id: 1, digest: $d, size: 1}]') ;;
		esac
	done
	jq --arg t "$_tag" --arg b "$_body" --argjson l "$_latest" --argjson a "$_assets" \
		'[{tag_name: $t, name: $t, body: $b, draft: false, prerelease: ($t | test("beta")), latest: $l,
		   published_at: "2026-11-01T10:00:00Z", assets: $a}] + .' "$rel" >"$rel.new"
	mv "$rel.new" "$rel"
}
echo '[]' >"$rel"
# A stable from before the ledger: its own appcast.xml is all there is.
cat >"$work/old-appcast.xml" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Bridgeplay</title>
<item><title>0.7.63</title><sparkle:version>80</sparkle:version><sparkle:shortVersionString>0.7.63</sparkle:shortVersionString>
<enclosure url="https://github.com/$slug/releases/download/v0.7.63/Bridgeplay.zip" length="1234" type="application/octet-stream" sparkle:edSignature="b2xkIHNpZ25hdHVyZQ=="/></item>
</channel></rss>
EOF
add_release v0.7.63 "$(printf -- '- things\n\nBuild 80, based on NotProton 1.2.0.')" latest "appcast.xml@$work/old-appcast.xml"
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
push() { git_in "$fx" push -q -f mirror "HEAD:refs/heads/$1"; }
checkout() { git_in "$fx" checkout -q "$@"; }
merge() { git_in "$fx" merge -q --no-ff --no-edit "$@"; }

release() { (cd "$fx" && sh scripts/release-local.sh "$@"); }
dry() { (cd "$fx" && SPARKLE_KEY_FILE=$test_key sh scripts/release-local.sh --dry-run "$@"); }
# with VAR=VALUE ARGS...: a run with one more variable.
with() {
	_e=$1
	shift
	(cd "$fx" && env "$_e" sh scripts/release-local.sh "$@")
}
ledger_of() { jq -r --arg t "$1" 'map(select(.tag_name == $t))[0].body' "$rel" | ledger_field "$2" 2>/dev/null || true; }
claim_at() { git_in "$origin" rev-parse -q --verify "refs/tags/build/$1" 2>/dev/null || true; }
latest() { jq -r 'map(select(.latest))[0].tag_name' "$rel"; }

# feed: the published beta feed, downloaded.
feed() {
	rm -rf "$work/pf"
	gh release download beta-feed -p appcast.xml -D "$work/pf" --clobber
	echo "$work/pf/appcast.xml"
}
# items FILE: label:channel:build of every item, newest first; the stable's channel is "stable".
items() {
	_n=$(xp "$1" "count(//*[local-name()='item'])")
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_i=$((_i + 1))
		_it="(//*[local-name()='item'])[$_i]"
		_c=$(xp "$1" "string($_it/*[local-name()='channel'])")
		printf '%s:%s:%s\n' "$(xp "$1" "string($_it/*[local-name()='shortVersionString'])")" "${_c:-stable}" \
			"$(xp "$1" "string($_it/*[local-name()='version'])")"
	done
}
# feed_is NAME EXPECTED [FILE]: the published feed (or FILE) passes the guard and has these items.
feed_is() {
	_f=${3:-$(feed)}
	if beta_feed_guard "$_f" 26.0 2>"$work/err"; then pass; else fail "$1: the feed fails its guard: $(cat "$work/err")"; fi
	expect_eq "$1" "$2" "$(items "$_f")"
	expect_eq "$1: one containsBetas, on the stable" 1 \
		"$(xp "$_f" "count(//*[local-name()='item'][not(*[local-name()='channel'])]/*[local-name()='containsBetas' and namespace-uri()='$BRIDGEPLAY_NS'])")"
}
contains_of() { xp "$1" "string(//*[local-name()='containsBetas'])"; }
# r6 NAME OUTPUT: nothing in a beta run's output or the stub log since $1 touches the stable
# side (R6).
r6() {
	_lines=$(printf '%s\n' "$2" | grep '^==> would run:' || true)
	expect_not "$1: no installer" installer "$_lines"
	expect_not "$1: no legacy feed" NotProton-WineHQ "$2"
	expect_eq "$1: --latest only as --latest=false" "" "$(printf '%s\n' "$2" | grep -E -e '--latest( |$)' || true)"
	expect_eq "$1: no appcast.xml on a beta tag" "" "$(printf '%s\n' "$_lines" | grep -E 'v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+ .*appcast\.xml' || true)"
	expect_eq "$1: no stable release touched" "" \
		"$(printf '%s\n' "$_lines" | grep -E 'gh release (edit|upload|delete-asset|delete) v[0-9]+\.[0-9]+\.[0-9]+ ' || true)"
	expect_eq "$1: no Setup or DMG" "" "$(printf '%s\n' "$2" | grep -e packaged-setup -e packaged-dmg || true)"
}
# r6_log NAME: the same for what a real run sent to gh.
r6_log() {
	expect_eq "$1: gh: no installer" "" "$(grep -e ' installer ' -e 'Installer' "$log" || true)"
	expect_eq "$1: gh: no legacy feed" "" "$(grep NotProton-WineHQ "$log" || true)"
	expect_eq "$1: gh: --latest only as --latest=false" "" "$(grep -E -e '--latest( |$)' "$log" || true)"
	expect_eq "$1: gh: no appcast.xml on a beta tag" "" \
		"$(grep -E '^release (create|upload) v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+ .*appcast\.xml' "$log" || true)"
	expect_eq "$1: gh: no stable release touched" "" \
		"$(grep -E '^release (edit|upload|delete-asset|delete) v[0-9]+\.[0-9]+\.[0-9]+ ' "$log" || true)"
}

git_in "$work" init -q "$fx"
set_version 0.7.63 80
git_in "$fx" add -A
git_in "$fx" commit -q -m "release 0.7.63"
git_in "$fx" remote add mirror "$origin"
git_in "$fx" tag v0.7.63
git_in "$fx" push -q mirror HEAD:refs/heads/main v0.7.63
bump 0.7.64 81
p0=$(sha)
push main

# --- a stable from before the ledger heads the feed, from its appcast.xml -------------------

expect_code "a pre-ledger stable" 0 dry --beta --rebuild-feeds
expect_has "a pre-ledger stable: no carrier yet" "there is no beta-feed release; a real run creates it" "$out"
feed_is "a pre-ledger stable: its item" "0.7.63:stable:80" "$fx/out/release/beta-feed/appcast.xml"
expect_eq "a pre-ledger stable: no betas listed" "" "$(contains_of "$fx/out/release/beta-feed/appcast.xml")"
expect_eq "a pre-ledger stable: its signature kept" "b2xkIHNpZ25hdHVyZQ==" "$(beta_feed_item "$fx/out/release/beta-feed/appcast.xml" 80 edSignature)"

# --- the stable before any beta: no beta feed to refresh ----------------------------------

expect_code "stable 0.7.64" 0 release
expect_has "stable: no carrier yet" "no beta-feed release: no beta feed to refresh" "$out"
expect_eq "stable: Latest" v0.7.64 "$(latest)"
expect_eq "stable: its ledger" stable "$(ledger_of v0.7.64 kind)"

# --- arguments ------------------------------------------------------------------------------

expect_code "R6: --legacy-feed with --beta" 1 release --beta --legacy-feed "notes"
expect_has "R6: --legacy-feed is refused" "--legacy-feed is refused with --beta" "$out"
expect_code "a beta without notes" 1 release --beta
expect_has "notes are required" "a beta needs release notes" "$out"
expect_code "a critical without a reason that counts" 1 release --beta --critical "it is urgent" "notes"
expect_has "critical wants security or data loss" "only for a security or data-loss fix" "$out"
expect_code "a waiver without a reason" 1 release --beta --waive-stable v0.7.64 "notes"
expect_has "a waiver needs a reason" "--waive-stable needs --reason" "$out"
expect_code "--critical without --beta" 1 release --critical "security: x"
expect_has "beta options need --beta" "go with --beta" "$out"
expect_code "--withdraw without --rebuild-feeds" 1 release --beta --withdraw v0.7.65-beta.1 --reason x "notes"
expect_code "--withdraw of a stable" 1 release --beta --rebuild-feeds --withdraw v0.7.64 --reason x
expect_has "--withdraw wants a beta" "wants a vX.Y.Z-beta.N tag" "$out"

# --- the first beta: a dry run (R6), then for real ---------------------------------------

git_in "$fx" checkout -q -b develop "$p0"
change src/feature.c feature "feat: a feature"
d1=$(sha)
push develop
make_app "$fx/build/Bridgeplay.app" 0.7.65-beta.1 82 beta
notes1='- feat: a feature
- the notes keep "quotes", <tags> & ]]> as they are'
: >"$log"
expect_code "R6: the beta dry run" 0 dry --beta "$notes1"
first=$out
expect_not "dry run: nothing would stop" "would stop here" "$first"
expect_has "dry run: claims H+1" "dry run: would claim build/82 at $d1" "$first"
expect_has "dry run: the label" "beta 0.7.65-beta.1 from develop, channel beta" "$first"
expect_has "dry run: a prerelease, never Latest" "--prerelease --latest=false" "$first"
expect_has "dry run: the zip only" "==> would run: gh release create v0.7.65-beta.1 out/release/beta/Bridgeplay.zip -R raymondchins/Bridgeplay --target $d1" "$first"
expect_has "dry run: the carrier would be made" "there is no beta-feed release; a real run creates it" "$first"
expect_has "dry run: as a prerelease" "==> would run: gh release create beta-feed out/release/beta-feed/appcast.xml -R raymondchins/Bridgeplay --target $p0" "$first"
r6 "R6 dry run" "$first"
expect_eq "R6 dry run: nothing sent but reads" "" "$(grep -E '^release (create|upload|edit|delete|delete-asset) |-X PATCH' "$log" || true)"
expect_eq "dry run: no claim pushed" "" "$(claim_at 82)"
feed_is "dry run: the feed" "0.7.65-beta.1:beta:82
0.7.64:stable:81" "$fx/out/release/beta-feed/appcast.xml"
expect_has "dry run: the ledger" "<!-- bridgeplay-ledger v1
kind: beta
build: 82
label: 0.7.65-beta.1
tag: v0.7.65-beta.1
commit: $d1
source-branch: develop
zip-sha256: $(shasum -a 256 "$fx/out/release/beta/Bridgeplay.zip" | cut -d' ' -f1)" "$first"
expect_has "dry run: the ledger's channel" "channel: beta
-->" "$first"
expect_eq "dry run: no Setup or DMG made" "Bridgeplay.zip" "$(ls "$fx/out/release/beta")"

# Without SPARKLE_KEY_FILE a throwaway key signs, and says so.
expect_code "throwaway key" 0 release --beta --dry-run "$notes1"
expect_has "throwaway: said" "signed with a throwaway key, which installed apps refuse" "$out"

rm -rf "$fx/build"
: >"$log"
expect_code "beta 1" 0 release --beta "$notes1"
expect_has "beta 1: stamped by the build" "built 0.7.65-beta.1 (82) on beta" "$out"
expect_has "beta 1: digest checked" "uploaded digest matches: Bridgeplay.zip" "$out"
expect_has "beta 1: feed read back" "published beta feed was read back and checked" "$out"
expect_eq "beta 1: claimed" "$d1" "$(claim_at 82)"
expect_eq "beta 1: tag at HEAD" "$d1" "$(git_in "$origin" rev-parse refs/tags/v0.7.65-beta.1)"
expect_eq "beta 1: a prerelease" "true false" "$(jq -r 'map(select(.tag_name == "v0.7.65-beta.1"))[0] | "\(.prerelease) \(.latest)"' "$rel")"
expect_eq "beta 1: the zip only" Bridgeplay.zip "$(jq -r 'map(select(.tag_name == "v0.7.65-beta.1"))[0].assets | map(.name) | join(",")' "$rel")"
expect_eq "beta 1: Latest stays" v0.7.64 "$(latest)"
expect_eq "beta 1: the ledger build" 82 "$(ledger_of v0.7.65-beta.1 build)"
expect_eq "beta 1: the ledger channel" beta "$(ledger_of v0.7.65-beta.1 channel)"
expect_eq "beta 1: the Build line" 82 "$(jq -r 'map(select(.tag_name == "v0.7.65-beta.1"))[0].body' "$rel" | legacy_build)"
expect_eq "beta 1: the carrier" "true false appcast.xml" \
	"$(jq -r 'map(select(.tag_name == "beta-feed"))[0] | "\(.prerelease) \(.latest) \(.assets | map(.name) | join(","))"' "$rel")"
expect_eq "beta 1: the carrier's target" "$p0" "$(git_in "$origin" rev-parse refs/tags/beta-feed)"
r6_log "beta 1"
f=$(feed)
feed_is "beta 1: the feed" "0.7.65-beta.1:beta:82
0.7.64:stable:81" "$f"
expect_eq "beta 1: the stable lists no betas" "" "$(contains_of "$f")"
expect_eq "beta 1: the notes survive" "$notes1" "$(xp "$f" "string(//*[local-name()='item'][1]/*[local-name()='description'])")"
expect_has "beta 1: a pubDate" "<pubDate>" "$(cat "$f")"
expect_has "beta 1: the namespace as T6 needs it" 'xmlns:bridgeplay="https://bridgeplay.dev/ns/appcast/1"' "$(cat "$f")"
gh release download v0.7.65-beta.1 -p Bridgeplay.zip -D "$work/z1" --clobber
expect_code "beta 1: the item's signature is the zip's" 0 "$real_sparkle/sign_update" --verify --ed-key-file "$test_key" \
	"$work/z1/Bridgeplay.zip" "$(beta_feed_item "$f" 82 edSignature)"

# --- the guard -------------------------------------------------------------------------------

base=$work/guard.xml
sed '/sparkle-signatures/,$d' "$f" | sed '$d' >"$base"
tail -n 1 "$f" | grep -q '^</rss>' || sed '/sparkle-signatures/,$d' "$f" >"$base"
grep -q '</rss>' "$base" || echo '</rss>' >>"$base"
variant() { # variant NAME SED [KEY]: the feed edited with SED, signed again
	sed "$2" "$base" >"$work/$1.xml"
	"$real_sparkle/sign_update" --ed-key-file "${3:-$test_key}" "$work/$1.xml" >/dev/null
	printf '%s\n' "$work/$1.xml"
}
g=$(variant good 's/x/x/')
expect_code "guard: a good feed" 0 beta_feed_guard "$g" 26.0 82
expect_code "guard: a build not in it" 1 beta_feed_guard "$g" 26.0 99
expect_has "guard: the build is named" "does not carry build 99" "$out"
g=$(variant nochannel 's#<sparkle:channel>beta</sparkle:channel>##')
expect_code "guard: two stables" 1 beta_feed_guard "$g" 26.0
expect_has "guard: two stables named" "2 stable items" "$out"
g=$(variant critical 's#<sparkle:channel>beta<#<sparkle:channel>alpha<#')
expect_code "guard: an unknown channel" 1 beta_feed_guard "$g" 26.0
expect_has "guard: the channel named" "channel 'alpha'" "$out"
g=$(variant below 's#<sparkle:version>82<#<sparkle:version>80<#')
expect_code "guard: a beta below the stable" 1 beta_feed_guard "$g" 26.0
expect_has "guard: below named" "not above the stable's build 81" "$out"
g=$(variant noprefix 's#xmlns:bridgeplay=#xmlns:bp=#; s#bridgeplay:containsBetas#bp:containsBetas#g')
expect_code "guard: another prefix" 1 beta_feed_guard "$g" 26.0
expect_has "guard: the spelling named" "spelled bridgeplay:containsBetas" "$out"
g=$(variant label 's#<sparkle:shortVersionString>0.7.65-beta.1<#<sparkle:shortVersionString>0.7.65<#')
expect_code "guard: a beta with a stable label" 1 beta_feed_guard "$g" 26.0
expect_has "guard: the label named" "not X.Y.Z-beta.N" "$out"
g=$(variant url 's#/v0.7.65-beta.1/Bridgeplay.zip#/v0.7.64/Bridgeplay.zip#')
expect_code "guard: an enclosure on another tag" 1 beta_feed_guard "$g" 26.0
g=$(variant otherkey 's/x/x/' "$other_key")
expect_code "guard: another key" 1 beta_feed_guard "$g" 26.0
expect_has "guard: the signature named" "feed signature that does not verify" "$out"
expect_code "guard: unsigned" 1 beta_feed_guard "$base" 26.0
sed 's#<sparkle:version>82<#<sparkle:version>83<#' "$(variant good2 's/x/x/')" >"$work/tampered.xml"
expect_code "guard: edited after signing" 1 beta_feed_guard "$work/tampered.xml" 26.0

# --- R1: main bumped and unreleased; a race on the claim -----------------------------------

checkout main
change src/hotfix.c hotfix "fix: a hotfix"
bump 0.7.65 84
h84=$(sha)
push main
checkout develop
change src/feature2.c feature2 "feat: another"
d2=$(sha)
push develop
expect_code "R1: the next beta" 0 release --beta "- feat: another"
expect_has "R1: it stamps above main's unreleased build" "built 0.7.65-beta.2 (85) on beta" "$out"
expect_eq "R1: build 85 claimed" "$d2" "$(claim_at 85)"
feed_is "R1: the feed" "0.7.65-beta.2:beta:85
0.7.64:stable:81"

change src/feature3.c feature3 "feat: a third"
d3=$(sha)
push develop
make_app "$fx/build/Bridgeplay.app" 0.7.65-beta.3 87 beta
BETACHECK_RIVAL=$h84
export BETACHECK_RIVAL
expect_code "a race: a rival takes the build first" 0 with BETACHECK_RACE=86 --beta --dry-run "- feat: a third"
expect_has "a race: said" "build/86 was claimed by another release just now; reading H again" "$out"
expect_has "a race: the retry claims the next" "dry run: would claim build/87 at $d3" "$out"
expect_not "a race: nothing would stop" "would stop here" "$out"
rm -rf "$fx/build"
: >"$log"
expect_code "X-16: the second run stops on the claim" 1 with BETACHECK_RACE="87 88" --beta "- feat: a third"
expect_has "X-16: one retry, then stop" "build/88 was taken too" "$out"
expect_not "X-16: nothing built" "built 0.7.65" "$out"
expect_eq "X-16: nothing created" "" "$(grep '^release create' "$log" || true)"
expect_eq "X-16: no claim at HEAD" "" "$(for b in 86 87 88 89; do [ "$(claim_at "$b")" != "$d3" ] || echo "$b"; done)"

# --- beta-critical, then a beta: the three-item rule ------------------------------------------

expect_code "critical" 0 release --beta --critical "security: a prefix escape" "- fix: a prefix escape"
expect_has "critical: the build" "built 0.7.65-beta.3 (89) on beta" "$out"
expect_eq "critical: the ledger channel" beta-critical "$(ledger_of v0.7.65-beta.3 channel)"
expect_eq "critical: the reason" "security: a prefix escape" "$(ledger_of v0.7.65-beta.3 critical-reason)"
feed_is "critical: newest is critical, two items" "0.7.65-beta.3:beta-critical:89
0.7.64:stable:81"

change src/feature4.c feature4 "feat: a fourth"
push develop
expect_code "beta 4" 0 release --beta "- feat: a fourth"
feed_is "beta 4: three items" "0.7.65-beta.4:beta:90
0.7.65-beta.3:beta-critical:89
0.7.64:stable:81"

# --- resume: stopped after the upload, before the feed (X-15) ---------------------------------

change src/feature5.c feature5 "feat: a fifth"
d5=$(sha)
push develop
: >"$log"
expect_code "X-15: stopped before exposure" 1 with GH_STUB_FAIL_UPLOAD=next-appcast.xml --beta "- feat: a fifth"
expect_has "X-15: the failure says it is not offered" "is published but may not be offered" "$out"
expect_eq "X-15: published" 91 "$(ledger_of v0.7.65-beta.5 build)"
feed_is "X-15: the feed did not move" "0.7.65-beta.4:beta:90
0.7.65-beta.3:beta-critical:89
0.7.64:stable:81"
expect_code "X-15: a rerun asking for other options" 1 release --beta --critical "data-loss: x" "- feat: a fifth"
expect_has "X-15: other options stop" "this run asks for something else" "$out"
cp "$rel" "$work/saved.json"
jq 'map(if .tag_name == "v0.7.65-beta.5" then .assets[0].digest = "sha256:00" else . end)' "$work/saved.json" >"$rel"
expect_code "X-15: a rerun over a changed asset" 1 release --beta "- feat: a fifth"
expect_has "X-15: a changed asset stops" "is not the one its ledger records; nothing is overwritten" "$out"
cp "$work/saved.json" "$rel"
expect_eq "X-15: created once" 1 "$(grep -c '^release create v0.7.65-beta.5 ' "$log")"
: >"$log"
expect_code "X-15: the rerun" 0 release --beta "- feat: a fifth"
expect_has "X-15: it resumes" "HEAD is already published as v0.7.65-beta.5" "$out"
expect_has "X-15: uploads nothing again" "nothing was uploaded again" "$out"
expect_not "X-15: builds nothing" "built 0.7.65" "$out"
expect_eq "X-15: not created again" 0 "$(grep -c '^release create' "$log" || true)"
expect_eq "X-15: exposed once" 1 "$(grep -c '^release upload beta-feed ' "$log")"
expect_eq "X-15: build 91 claimed once" "$d5" "$(claim_at 91)"
expect_eq "X-15: no other build claimed" "" "$(claim_at 92)"
feed_is "X-15: exposed" "0.7.65-beta.5:beta:91
0.7.65-beta.3:beta-critical:89
0.7.64:stable:81"

# --- --rebuild-feeds and a withdrawn beta ---------------------------------------------------

expect_code "withdraw: dry run" 0 dry --beta --rebuild-feeds --withdraw v0.7.65-beta.5 --reason "crashes at launch"
expect_has "withdraw: dry run would mark it" "==> would run: gh release edit v0.7.65-beta.5 -R raymondchins/Bridgeplay --notes Withdrawn from the beta feed: crashes at launch" "$out"
feed_is "withdraw: dry run's feed" "0.7.65-beta.4:beta:90
0.7.65-beta.3:beta-critical:89
0.7.64:stable:81" "$fx/out/release/beta-feed/appcast.xml"
expect_eq "withdraw: dry run marks nothing" "" "$(jq -r 'map(select(.tag_name == "v0.7.65-beta.5"))[0].body' "$rel" | grep Withdrawn || true)"
: >"$log"
expect_code "withdraw" 0 release --beta --rebuild-feeds --withdraw v0.7.65-beta.5 --reason "crashes at launch"
r6_log "withdraw"
feed_is "withdraw: dropped" "0.7.65-beta.4:beta:90
0.7.65-beta.3:beta-critical:89
0.7.64:stable:81"
expect_eq "withdraw: the ledger stays" 91 "$(ledger_of v0.7.65-beta.5 build)"
expect_eq "withdraw: no stable feed touched" "" "$(grep -E '^release (upload|edit|create) v0\.7\.6[0-9] ' "$log" || true)"
expect_code "the rerun of a withdrawn beta" 1 release --beta "- feat: a fifth"
expect_has "a withdrawn beta is not exposed again" "was withdrawn from the beta feed" "$out"

# The feed fails closed on a beta it can't read.
cp "$rel" "$work/saved.json"
add_release v0.7.65-beta.9 "No ledger here."
expect_code "rebuild: a beta without a ledger" 1 release --beta --rebuild-feeds
expect_has "rebuild: it says which" "v0.7.65-beta.9 has no readable v1 ledger" "$out"
cp "$work/saved.json" "$rel"
jq 'map(if .tag_name == "v0.7.65-beta.4" then .assets[0].size = 5 else . end)' "$work/saved.json" >"$rel"
expect_code "rebuild: a zip that is not the ledger's" 1 release --beta --rebuild-feeds
expect_has "rebuild: it says so" "v0.7.65-beta.4's Bridgeplay.zip" "$out"
cp "$work/saved.json" "$rel"

# --- a hotfix stable refreshes the beta feed --------------------------------------------------

checkout main
: >"$log"
expect_code "hotfix stable 0.7.65" 0 release
expect_has "hotfix: contains no betas" "contains betas: none; promoted from: none" "$out"
expect_eq "hotfix: Latest" v0.7.65 "$(latest)"
expect_eq "hotfix: the beta feed refreshed" 1 "$(grep -c '^release upload beta-feed ' "$log")"
f=$(feed)
feed_is "hotfix: the new stable heads the beta feed" "0.7.65-beta.4:beta:90
0.7.65-beta.3:beta-critical:89
0.7.65:stable:84" "$f"
expect_eq "hotfix: it lists no betas" "" "$(contains_of "$f")"

# --- I-2 and its waiver ------------------------------------------------------------------------

checkout develop
change src/feature6.c feature6 "feat: a sixth"
d6=$(sha)
push develop
expect_code "I-2: a beta without the newest stable" 1 release --beta "- feat: a sixth"
expect_has "I-2: refused" "I-2: HEAD does not contain v0.7.65, the newest stable" "$out"
expect_eq "I-2: nothing claimed" "" "$(git_in "$origin" tag --points-at "$d6" -l 'build/*')"
expect_code "I-2: a waiver for another stable" 1 release --beta --waive-stable v0.7.64 --reason "x" "- feat: a sixth"
expect_has "I-2: the wrong tag is named" "does not name the newest stable, v0.7.65" "$out"
expect_code "I-2: waived" 0 release --beta --waive-stable v0.7.65 --reason "testers need the new engine today" "- feat: a sixth"
expect_has "I-2: said loudly" "!!! I-2 WAIVED: this beta does not contain v0.7.65" "$out"
expect_has "I-2: labelled above the new stable" "beta 0.7.66-beta.1 from develop" "$out"
expect_eq "I-2: the waiver in the ledger" "v0.7.65" "$(ledger_of v0.7.66-beta.1 waived-stable)"
expect_eq "I-2: its reason" "testers need the new engine today" "$(ledger_of v0.7.66-beta.1 waiver-reason)"
b6=$(ledger_of v0.7.66-beta.1 build)
feed_is "I-2: the feed" "0.7.66-beta.1:beta:$b6
0.7.65-beta.3:beta-critical:89
0.7.65:stable:84"

# --- branches and labels -----------------------------------------------------------------------

git_in "$fx" checkout -q -b feat/x
change src/x.c x "feat: x"
push feat/x
make_app "$fx/build/Bridgeplay.app" 0.7.66-beta.2 99 beta
expect_code "branch: a dry run from feat/x" 0 dry --beta "- x"
expect_has "branch: a dry run warns" "would stop here: HEAD (feat/x) is not the tip of develop or a release/* branch" "$out"
rm -rf "$fx/build"
: >"$log"
expect_code "branch: a real run from feat/x" 1 release --beta "- x"
expect_has "branch: refused" "HEAD (feat/x) is not the tip of develop or a release/* branch" "$out"
expect_eq "branch: nothing created" "" "$(grep '^release create' "$log" || true)"

checkout develop
merge main
push develop
git_in "$fx" checkout -q -b release/0.7.65
push release/0.7.65
expect_code "R15: a release branch named after a stable" 1 release --beta "- rc"
expect_has "R15: refused" "v0.7.65 is already a stable release, so betas can't be named after it; rename release/0.7.65" "$out"
git_in "$origin" branch -D release/0.7.65 >/dev/null

# --- a promotion: a release-candidate beta, merged and released --------------------------------

checkout develop
git_in "$fx" checkout -q -b release/0.7.66
push release/0.7.66
rc=$(sha)
expect_code "the release candidate" 0 release --beta "- the release candidate"
expect_has "the release candidate's label" "beta 0.7.66-beta.2 from release/0.7.66" "$out"
brc=$(ledger_of v0.7.66-beta.2 build)
expect_eq "the release candidate's branch" release/0.7.66 "$(ledger_of v0.7.66-beta.2 source-branch)"
feed_is "the release candidate in the feed" "0.7.66-beta.2:beta:$brc
0.7.65-beta.3:beta-critical:89
0.7.65:stable:84"

checkout main
merge release/0.7.66
h=$(cd "$fx" && sh scripts/build-ledger-real.sh highest -q)
bump 0.7.66 $((h + 1))
push main
# A stable dry run refreshes the beta feed in out/ only.
make_app "$fx/build/Bridgeplay.app" 0.7.66 $((h + 1))
: >"$log"
expect_code "promotion: a dry run" 0 dry
expect_not "promotion dry run: nothing would stop" "would stop here" "$out"
expect_has "promotion dry run: the beta feed would be swapped" "==> would run: gh release upload beta-feed out/release/beta-feed/next-appcast.xml -R raymondchins/Bridgeplay" "$out"
feed_is "promotion dry run: its beta feed" "0.7.66:stable:$((h + 1))" "$fx/out/release/beta-feed/appcast.xml"
expect_eq "promotion dry run: its stable lists the betas" "82,85,89-93" "$(contains_of "$fx/out/release/beta-feed/appcast.xml")"
expect_eq "promotion dry run: nothing sent" "" "$(grep -E '^release (create|upload|edit|delete|delete-asset) |-X PATCH' "$log" || true)"
rm -rf "$fx/build"
: >"$log"
expect_code "promotion: the beta feed upload fails" 1 with GH_STUB_FAIL_UPLOAD=next-appcast.xml
expect_has "promotion: promoted" "promoted from: v0.7.66-beta.2" "$out"
expect_has "promotion: the stable is fine" "v0.7.66 is released, but the beta feed was not refreshed (above); the stable is fine" "$out"
expect_has "promotion: the recovery command" "scripts/release-local.sh --beta --rebuild-feeds" "$out"
expect_eq "promotion: Latest anyway" v0.7.66 "$(latest)"
expect_code "promotion: recovered" 0 release --beta --rebuild-feeds
f=$(feed)
feed_is "promotion: the stable alone" "0.7.66:stable:$((h + 1))" "$f"
expect_eq "promotion: the builds as expected" "92 93 93" "$b6 $brc $h"
expect_eq "promotion: it lists every beta it contains" "82,85,89-93" "$(contains_of "$f")"
expect_eq "promotion: as its ledger does" "$(ledger_of v0.7.66 contains-betas)" "$(contains_of "$f")"

# --- a damaged upload is deleted, and the feed is left alone -----------------------------------

checkout develop
merge main
change src/feature7.c feature7 "feat: a seventh"
d7=$(sha)
push develop
: >"$log"
expect_code "a damaged upload" 1 with GH_STUB_CORRUPT=Bridgeplay.zip --beta "- feat: a seventh"
expect_has "a damaged upload is deleted" "deleted v0.7.67-beta.1 (no feed listed it), run again" "$out"
expect_eq "its tag is gone" "" "$(git_in "$origin" tag -l v0.7.67-beta.1)"
expect_eq "its claim stays" "$d7" "$(git_in "$origin" rev-parse "refs/tags/build/$((h + 2))")"
expect_eq "the feed was not touched" "" "$(grep 'beta-feed' "$log" | grep -v -e '^release view' -e '^release download' || true)"
expect_code "after a damaged upload, a clean run" 0 release --beta "- feat: a seventh"
feed_is "after a damaged upload" "0.7.67-beta.1:beta:$((h + 3))
0.7.66:stable:$((h + 1))"

# If Latest is not a stable (the stable feed is down), the feed still has the newest one.
cp "$rel" "$work/saved.json"
jq 'map(.latest = (.tag_name == "installer"))' "$work/saved.json" >"$rel"
expect_code "Latest is not a stable" 0 dry --beta --rebuild-feeds
expect_has "Latest is not a stable: said" "the Latest release 'installer' is not a vX.Y.Z stable; the beta feed uses v0.7.66" "$out"
feed_is "Latest is not a stable: the feed" "0.7.67-beta.1:beta:$((h + 3))
0.7.66:stable:$((h + 1))" "$fx/out/release/beta-feed/appcast.xml"
cp "$work/saved.json" "$rel"

# --- an upload that breaks off inside gh release create leaves no draft ----------------------

change src/feature8.c feature8 "feat: an eighth"
push develop
: >"$log"
expect_code "an upload that breaks off" 1 with GH_STUB_BREAK_CREATE=Bridgeplay.zip --beta "- feat: an eighth"
expect_has "the draft is deleted" "deleted the draft it left (it was never public), run again" "$out"
expect_eq "no draft is left" 0 "$(jq 'map(select(.draft)) | length' "$rel")"
expect_eq "the feed was not touched after the break" "" "$(grep 'beta-feed' "$log" | grep -v -e '^release view' -e '^release download' || true)"
expect_code "after the break, a clean run" 0 release --beta "- feat: an eighth"
expect_eq "after the break, the beta is published" false "$(jq -r 'map(select(.tag_name == "v0.7.67-beta.2"))[0].draft' "$rel")"

# --- the lock is the stable mode's ----------------------------------------------------------

lockdir=$fx/.git/bridgeplay-release.lock
(cd "$fx" && exec sh -c ". '$repo/scripts/release-lib.sh'; release_lock && sleep 3") &
holder=$!
i=0
while [ ! -f "$lockdir/pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
expect_code "a held lock stops a beta" 1 release --beta --dry-run "- x"
expect_has "the holder is named" "another release (pid $holder) holds" "$out"
wait "$holder"

# --- R4: main moved past the release candidate, and the documented recovery -------------------

highest() { (cd "$fx" && sh scripts/build-ledger-real.sh highest -q); }
checkout develop
git_in "$fx" checkout -q -b release/0.7.67
change src/rc.c rc "fix: last one for 0.7.67"
push release/0.7.67
expect_code "R4: the release candidate" 0 release --beta "- the release candidate"
expect_has "R4: its label" "beta 0.7.67-beta.3 from release/0.7.67" "$out"
checkout main
merge release/0.7.67
change src/hotfix9.c hotfix9 "fix: on main only"
h=$(highest)
bump 0.7.67 $((h + 1))
push main
expect_code "R4: main moved past the candidate" 1 release
expect_has "R4: refused" "HEAD differs from beta v0.7.67-beta.3" "$out"
expect_has "R4: the recovery bumps the build" "run scripts/bump-version.sh build" "$out"
expect_eq "R4: nothing claimed" "" "$(claim_at $((h + 1)))"

# The recovery: main, with its bump to 0.7.67, merged into release/0.7.67.
checkout release/0.7.67
merge main
push release/0.7.67
expect_code "R4: a candidate named after the committed version" 0 release --beta "- the second release candidate"
expect_has "R4: its label" "beta 0.7.67-beta.4 from release/0.7.67" "$out"
rc2=$(ledger_of v0.7.67-beta.4 build)
checkout main
merge release/0.7.67
push main
expect_code "R4: a stable below the candidate it contains" 1 release
expect_has "R4: refused below it" "build $((h + 1)) is not above build $rc2, a beta this stable contains" "$out"
expect_eq "R4: still nothing claimed" "" "$(claim_at $((h + 1)))"
h=$(highest)
bump 0.7.67 $((h + 1))
push main
expect_code "R4: released after the build bump" 0 release
expect_has "R4: promoted" "promoted from: v0.7.67-beta.4" "$out"
expect_eq "R4: Latest" v0.7.67 "$(latest)"
expect_eq "R4: above the candidate" 1 "$([ "$(ledger_of v0.7.67 build)" -gt "$rc2" ] && echo 1)"

if [ "$failures" -ne 0 ]; then
	echo "==> betacheck: $failures of $checks checks failed" >&2
	exit 1
fi
echo "==> betacheck: $checks checks passed"
