#!/bin/sh
# Build Bridgeplay from this checkout and publish it as the latest GitHub release of
# raymondchins/Bridgeplay, which is what the app's updater (Sparkle, SUFeedURL in
# app/Info.plist) reads. See docs/RELEASING.md.
#
#   scripts/release-local.sh [--dry-run] [--legacy-feed] ["release notes"]
#
#   --dry-run      run the checks and write the zips and appcasts to out/release/ without
#                  publishing, from the app already in build/ or out/; never reads the
#                  keychain (SPARKLE_KEY_FILE signs, else the appcast stays unsigned)
#   --legacy-feed  also publish the update where NotProton builds up to 1.1.9-ray.31
#                  look for one (raymondchins/NotProton-WineHQ), as NotProton.zip
#   release notes  default: the commit subjects since the previous release
#
# The update is signed with the EdDSA key in this Mac's login keychain, created once with
# app/.build/artifacts/sparkle/Sparkle/bin/generate_keys; app/Info.plist's SUPublicEDKey
# must be its public half. The app is code signed with BRIDGEPLAY_SIGN_IDENTITY (default the
# maintainer's Developer ID in the login keychain) and notarized with the notarytool profile
# BRIDGEPLAY_NOTARY_PROFILE (default "bridgeplay-notary"). The version comes
# from dylib/version.h (scripts/bump-version.sh) and must not have been released yet.
# HEAD must already be pushed to the Bridgeplay repository's main.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

usage() {
	sed -n '6,13p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 1
}

dry_run=0
legacy=0
notes=""
for arg in "$@"; do
	case "$arg" in
		--dry-run) dry_run=1 ;;
		--legacy-feed) legacy=1 ;;
		-h|--help) usage ;;
		-*) usage ;;
		*) [ -z "$notes" ] || usage; notes=$arg ;;
	esac
done

slug=raymondchins/Bridgeplay
legacy_slug=raymondchins/NotProton-WineHQ
# Bridgeplay needs macOS 26 (SetupChecks.minimumMacOS); older Macs are not offered updates.
min_macos=26.0

die() { echo "==> $*" >&2; exit 1; }
# A failed safety check stops a release; a dry run reports it and carries on.
check() {
	if [ "$dry_run" -eq 1 ]; then echo "==> dry run, would stop here: $*" >&2; else die "$*"; fi
}
run() {
	if [ "$dry_run" -eq 1 ]; then
		printf '==> would run:'; printf ' %s' "$@"; echo
	else
		"$@"
	fi
}

remote=""
for r in $(git remote); do
	case "$(git remote get-url "$r")" in
		*github.com[:/]"$slug"|*github.com[:/]"$slug".git) remote=$r ;;
	esac
done
[ -n "$remote" ] || die "no git remote points at github.com/$slug; git remote add bridgeplay https://github.com/$slug.git"

[ -z "$(git status --porcelain --untracked-files=no)" ] || check "the tree has uncommitted changes"
git fetch -q "$remote"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$remote/main")" ] || check "HEAD is not $remote/main; push first"

version=$(sed -n 's/^#define BRIDGEPLAY_VERSION "\(.*\)"$/\1/p' dylib/version.h)
build=$(sed -n 's/^#define BRIDGEPLAY_BUILD \([0-9][0-9]*\)$/\1/p' dylib/version.h)
upstream=$(sed -n 's/^#define NOTPROTON_VERSION "\(.*\)"$/\1/p' dylib/version.h)
[ -n "$version" ] && [ -n "$build" ] || die "dylib/version.h has no BRIDGEPLAY_VERSION/BRIDGEPLAY_BUILD"
tag="v$version"
if gh release view "$tag" -R "$slug" >/dev/null 2>&1; then
	check "$tag is already released; run scripts/bump-version.sh patch|minor|major"
fi

# SUFeedURL is releases/latest/download/appcast.xml, so the Latest release is the update
# feed of every installed app. If it is not an app release (no appcast.xml, say a DXMT
# build marked Latest), that feed is already down; stop rather than publish over a state
# nobody has looked at. Fix which release is Latest on GitHub, then run this again.
latest=$(gh release view -R "$slug" --json tagName,assets \
	-q '.tagName + " " + ([.assets[].name] | join(" "))' 2>/dev/null || true)
if [ -n "$latest" ]; then
	latest_tag=${latest%% *}
	case " ${latest#* } " in
		*" appcast.xml "*) ;;
		*) check "the Latest release $latest_tag has no appcast.xml, so the update feed is down; mark an app release Latest first" ;;
	esac
	echo "$latest_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' \
		|| check "the Latest release $latest_tag is not a vX.Y.Z app release; mark an app release Latest first"
fi

# Release notes: the commits since the previous app release, unless given. Other releases
# in the repository (DXMT builds) have tags that are not vX.Y.Z and are skipped.
previous=$(gh release list -R "$slug" --limit 100 --json tagName -q '.[].tagName' 2>/dev/null \
	| grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
if [ -z "$previous" ] || ! git rev-parse -q --verify "refs/tags/$previous" >/dev/null; then
	git fetch -q --tags "$remote" 2>/dev/null || true
fi
if [ -z "$previous" ] || ! git rev-parse -q --verify "refs/tags/$previous" >/dev/null; then
	# Before the first Bridgeplay release: the last release of the old scheme.
	previous=$(git tag --list 'v*-ray.*' --sort=-v:refname | head -n 1)
fi
if [ -z "$notes" ]; then
	if [ -n "$previous" ]; then
		notes=$(git log --no-merges --format='- %s' "$previous..HEAD")
	fi
	[ -n "$notes" ] || notes="Bridgeplay $version"
fi

# The app downloads its CJK fonts from the release CJKFonts.swift pins (scripts/package-fonts.sh
# --publish); a release without it would leave new installs without them.
fonts_archive=$(sed -n 's/.*static let archive = "\(fonts-cjk-[0-9a-f]*\.tar\.xz\)".*/\1/p' app/Sources/BridgeplayApp/Model/CJKFonts.swift)
[ -n "$fonts_archive" ] || die "no fonts archive pinned in CJKFonts.swift"
fonts_tag=${fonts_archive%.tar.xz}
gh release view "$fonts_tag" -R "$slug" --json assets -q '.assets[].name' 2>/dev/null | grep -qx "$fonts_archive" \
	|| check "$fonts_tag has no $fonts_archive on GitHub; run scripts/package-fonts.sh --publish"

# This release ships the patched WineCX binaries in Resources/; the license asks Bridgeplay
# to also provide their source, which NOTICE's written offer points at wine-patch-sources-*
# (scripts/package-wine-patch-sources.sh).
wine_src_archive=$(sed -n 's/^  \(wine-patch-sources-[0-9a-f]*\.tar\.gz\), sha256$/\1/p' NOTICE)
[ -n "$wine_src_archive" ] || die "no wine-patch-sources archive pinned in NOTICE"
wine_src_tag=${wine_src_archive%.tar.gz}
gh release view "$wine_src_tag" -R "$slug" --json assets -q '.assets[].name' 2>/dev/null | grep -qx "$wine_src_archive" \
	|| check "$wine_src_tag has no $wine_src_archive on GitHub; run scripts/package-wine-patch-sources.sh --publish"

sparkle=app/.build/artifacts/sparkle/Sparkle/bin
[ -x "$sparkle/generate_appcast" ] || swift build --package-path app >/dev/null
[ -x "$sparkle/generate_appcast" ] || die "no Sparkle tools at $sparkle"

# The app is signed with the maintainer's Developer ID, so its designated requirement (and
# the macOS permissions keyed to it, such as App Management) stays the same across updates,
# and notarized, so Gatekeeper opens a downloaded copy without Open Anyway. An ad hoc
# signature is the cdhash, new with every build. See docs/RELEASING.md (Signing).
team_id=AF38EA29BA
sign_identity=${BRIDGEPLAY_SIGN_IDENTITY:-Developer ID Application: Raymond Chin ($team_id)}
case "$sign_identity" in
	"Developer ID Application: "*"($team_id)") ;;
	*) check "BRIDGEPLAY_SIGN_IDENTITY \"$sign_identity\" is not the Developer ID of team $team_id; Apple notarizes only that" ;;
esac
if [ "$dry_run" -eq 0 ] && ! security find-identity -v -p codesigning | grep -Fq "\"$sign_identity\""; then
	die "no valid code signing identity \"$sign_identity\" in the keychain; install it once (docs/RELEASING.md, Signing)"
fi
BRIDGEPLAY_SIGN_IDENTITY=$sign_identity
export BRIDGEPLAY_SIGN_IDENTITY
notary_profile=${BRIDGEPLAY_NOTARY_PROFILE:-bridgeplay-notary}
BRIDGEPLAY_NOTARY_PROFILE=$notary_profile
export BRIDGEPLAY_NOTARY_PROFILE
if [ "$dry_run" -eq 0 ]; then
	# history makes one authenticated call, so a missing or revoked profile stops here, not
	# after the build.
	xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
		|| die "notarytool profile \"$notary_profile\" missing or rejected; xcrun notarytool store-credentials $notary_profile --apple-id <id> --team-id $team_id"
fi

if [ "$dry_run" -eq 1 ]; then
	out=out/release
	rm -rf "$out"
	mkdir -p "$out"
	# Never the keychain. SPARKLE_KEY_FILE (generate_keys -x) signs for real; otherwise a
	# throwaway key stands in, and since it is not SUPublicEDKey's pair generate_appcast
	# leaves the enclosure unsigned. generate_appcast's cache goes under out/, not ~/Library.
	# The key copy lives in its own temp folder, removed on any exit, never under out/.
	keydir=$(mktemp -d)
	trap 'rm -rf "$keydir"' EXIT
	if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
		cp "$SPARKLE_KEY_FILE" "$keydir/throwaway.key"
	else
		openssl genpkey -algorithm ed25519 -outform DER 2>/dev/null | tail -c 32 | base64 >"$keydir/throwaway.key"
	fi
	key_args="--ed-key-file $keydir/throwaway.key"
	CFFIXED_USER_HOME=$repo/$out/home
	export CFFIXED_USER_HOME
	app=""
	for candidate in build/Bridgeplay.app out/Bridgeplay.app; do
		[ -d "$candidate" ] && { app=$candidate; break; }
	done
	[ -n "$app" ] || die "--dry-run needs a built app: make app (or scripts/build-local.sh)"
else
	key=$("$sparkle/generate_keys" -p 2>/dev/null) || die "no Sparkle key in the keychain; run $sparkle/generate_keys"
	[ "$key" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' app/Info.plist)" ] \
		|| die "app/Info.plist SUPublicEDKey is not this keychain's Sparkle key"
	key_args=""

	if [ -z "${CX_ROOT:-}" ]; then
		# The support folder moved to bridgeplay in 3.0.0; a Mac the app has not migrated yet
		# still has it under notproton.
		CX_ROOT="$HOME/Library/Application Support/bridgeplay/runners/crossover-winehq-11.15/CrossOver"
		legacy_cx="$HOME/Library/Application Support/notproton/runners/crossover-winehq-11.15/CrossOver"
		[ -d "$CX_ROOT" ] || [ ! -d "$legacy_cx" ] || CX_ROOT=$legacy_cx
		export CX_ROOT
	fi
	scripts/build-local.sh --checks
	app=build/Bridgeplay.app
	out=$(mktemp -d)
	trap 'rm -rf "$out"' EXIT
fi

plist=$app/Contents/Info.plist
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
built_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[ "$built" = "$version" ] && [ "$built_build" = "$build" ] \
	|| check "built $built ($built_build), expected $version ($build) from dylib/version.h"
codesign --verify --strict --deep "$app" || die "$app is not validly signed; Sparkle rejects that"
requirement=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^#* *designated => //p')
echo "==> designated requirement: $requirement"
case "$requirement" in
	'identifier "com.bridgeplay.Bridgeplay" and anchor apple generic and '*"certificate leaf[subject.OU] = $team_id") ;;
	*) check "$app is not signed with the Developer ID of team $team_id, so macOS would forget its permissions on update" ;;
esac
codesign -d --verbose=1 "$app" 2>&1 | grep -q 'flags=.*runtime' || check "$app does not have the hardened runtime"
codesign -dvv "$app" 2>&1 | grep -q '^Timestamp=' || check "$app has no secure timestamp"
codesign -dvv "$app" 2>&1 | grep -Fqx "Authority=$sign_identity" \
	|| check "$app is not signed by \"$sign_identity\""
# The helpers in the payload (Makefile PAYLOAD_SIGN_IDS) carry the same identity.
payload=$app/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload
machos=$(mktemp)
find "$payload" -type f -exec sh -c 'file -b "$1" | grep -q "^Mach-O" && printf "%s\n" "$1"' sh {} \; >"$machos"
[ -s "$machos" ] || check "no Mach-O helpers in $payload"
while IFS= read -r helper; do
	codesign -dvv "$helper" 2>&1 | grep -Fqx "Authority=$sign_identity" \
		|| check "${helper#"$payload"/} in the payload is not signed by \"$sign_identity\""
done <"$machos"
echo "==> payload: checked $(wc -l <"$machos" | tr -d ' ') helpers for \"$sign_identity\""
rm -f "$machos"

# Apple rejects the whole app for one Mach-O file without the Developer ID or a timestamp.
unsigned=$(find "$app" -type f -exec sh -c 'file -b "$1" | grep -q "^Mach-O" || exit 0
	info=$(codesign -dvv "$1" 2>&1)
	printf "%s\n" "$info" | grep -Fqx "Authority=$2" && printf "%s\n" "$info" | grep -q "^Timestamp=" || echo "$1"' \
	sh {} "$sign_identity" \;)
[ -z "$unsigned" ] || check "not signed with \"$sign_identity\" and a timestamp, so notarization would fail: $(printf '%s\n' "$unsigned" | sed "s#^$app/##" | tr '\n' ' ')"

# Notarize before the archives are made, so the stapled ticket is inside every zip.
if [ "$dry_run" -eq 1 ]; then
	echo "==> dry run: would notarize and staple $app (profile $notary_profile)"
else
	scripts/notarize.sh "$app"
fi

# One archive and one appcast per feed. The appcast attached to the latest release is the
# feed, so each only needs the newest item; its enclosure points at this tag's zip.
# $1 directory, $2 archive name, $3 app name inside it, $4 repository
feed() {
	mkdir -p "$1"
	staging=$(mktemp -d)
	ditto "$app" "$staging/$3"
	ditto -c -k --keepParent "$staging/$3" "$1/$2"
	rm -rf "$staging"
	printf '%s\n' "$notes" >"$1/${2%.zip}.txt"
	# shellcheck disable=SC2086 # key_args is empty or two words
	"$sparkle/generate_appcast" $key_args --embed-release-notes --maximum-versions 1 \
		--download-url-prefix "https://github.com/$4/releases/download/$tag/" "$1"
	rm -f "$1/${2%.zip}.txt"
	# generate_appcast takes the minimum from LSMinimumSystemVersion; the feed asks for the
	# macOS Bridgeplay supports. The feed is not signed (only the archive is), so this edit
	# keeps every signature valid.
	sed -i '' "s#<sparkle:minimumSystemVersion>[^<]*</sparkle:minimumSystemVersion>#<sparkle:minimumSystemVersion>$min_macos</sparkle:minimumSystemVersion>#" "$1/appcast.xml"
	grep -q "<sparkle:minimumSystemVersion>$min_macos<" "$1/appcast.xml" || die "$1/appcast.xml has no minimumSystemVersion"
	grep -q "<sparkle:version>$build</sparkle:version>" "$1/appcast.xml" || die "$1/appcast.xml does not carry build $build"
	grep -q "url=\"https://github.com/$4/releases/download/$tag/$2\"" "$1/appcast.xml" \
		|| die "$1/appcast.xml does not point at $4 $tag/$2"
	if grep -q 'sparkle-signatures' "$1/appcast.xml"; then die "$1/appcast.xml is signed; the minimum OS edit would break it"; fi
	# SUVerifyUpdateBeforeExtraction: an update without a valid EdDSA signature is refused.
	if ! grep -q 'sparkle:edSignature="' "$1/appcast.xml"; then
		if [ "$dry_run" -eq 1 ]; then
			echo "==> dry run: $1/appcast.xml is unsigned (no SPARKLE_KEY_FILE); a release stops here instead"
		else
			die "$1/appcast.xml has no sparkle:edSignature; users would refuse this update"
		fi
	fi
}

feed "$out/bridgeplay" Bridgeplay.zip Bridgeplay.app "$slug"
# NotProton builds look for NotProton.app or com.notproton.NotProton in the archive
# (Sparkle's SUInstaller), so the legacy feed ships the same app under that name. It
# installs over /Applications/NotProton.app; later updates match by bundle identifier.
[ "$legacy" -eq 0 ] || feed "$out/legacy" NotProton.zip NotProton.app "$legacy_slug"

# Add the bootstrap after appcast generation so Sparkle only indexes the product archive.
if [ "$dry_run" -eq 1 ]; then
    BRIDGEPLAY_SIGN_IDENTITY=- scripts/package-native-installer.sh
else
    scripts/package-native-installer.sh
fi
cp out/Bridgeplay-Setup.zip "$out/bridgeplay/Bridgeplay-Setup.zip"
# The download bridgeplay.dev links to: the app in a disk image people drag to Applications.
# Notarized and stapled on its own; a dry run builds it unsigned.
if [ "$dry_run" -eq 1 ]; then
	BRIDGEPLAY_SIGN_IDENTITY=- scripts/package-dmg.sh "$app" "$out/bridgeplay/Bridgeplay.dmg"
else
	scripts/package-dmg.sh "$app" "$out/bridgeplay/Bridgeplay.dmg"
fi

title="Bridgeplay $version"
body=$(printf '%s\n\nBuild %s, based on NotProton %s.\n' "$notes" "$build" "$upstream")
echo "==> $title (build $build), notes since ${previous:-the beginning}:"
printf '%s\n' "$notes" | sed 's/^/    /'
run gh release create "$tag" "$out/bridgeplay/Bridgeplay.zip" "$out/bridgeplay/appcast.xml" \
    "$out/bridgeplay/Bridgeplay-Setup.zip" "$out/bridgeplay/Bridgeplay.dmg" \
	-R "$slug" --target "$(git rev-parse HEAD)" --title "$title" --notes "$body" --latest
if [ "$legacy" -eq 1 ]; then
	# Only a carrier for the feed: the tag goes on that repository's default branch, since
	# this commit need not exist there. --latest is what moves its feed.
	run gh release create "$tag" "$out/legacy/NotProton.zip" "$out/legacy/appcast.xml" -R "$legacy_slug" \
		--title "$title" --notes "NotProton is now Bridgeplay. $body" --latest
fi

# bridgeplay.dev's Download (vercel.json /download) points at the fixed "installer"
# release. The installer carries no app (Install.command downloads the Bridgeplay.zip of
# the Latest release, published just above), so it is uploaded only when its fingerprint,
# every file it ships, differs from the one on that release.
installer_tag=installer
# Replace one asset of an existing release with a gap of about a second. --clobber deletes
# the old asset before uploading the new one, and installers got 404s for the two minutes
# the 500 MB zip took (#166). So: upload under a temporary name, delete, rename.
swap_asset() {
	swap_tag=$1
	name=$(basename "$2")
	staged="$(dirname "$2")/next-$name"
	# A dry run writes no .sig.
	[ "$dry_run" -eq 1 ] && { run gh release upload "$swap_tag" "$staged" -R "$slug"; return 0; }
	cp "$2" "$staged"
	# A swap interrupted earlier leaves next-<name> behind.
	gh release delete-asset "$swap_tag" "next-$name" -R "$slug" -y >/dev/null 2>&1 || true
	gh release upload "$swap_tag" "$staged" -R "$slug"
	id=$(gh api "repos/$slug/releases/tags/$swap_tag" --jq ".assets[] | select(.name == \"next-$name\") | .id") \
		&& [ -n "$id" ] || die "uploaded next-$name is missing from the $swap_tag release"
	gh release delete-asset "$swap_tag" "$name" -R "$slug" -y >/dev/null 2>&1 || true
	gh api -X PATCH "repos/$slug/releases/assets/$id" -f name="$name" >/dev/null \
		|| die "could not rename next-$name to $name on the $swap_tag release; rename it on GitHub now"
	rm -f "$staged"
}
installer_fp=$(scripts/package-installer.sh --fingerprint-only | tail -n 1)
published_fp=$(gh release view "$installer_tag" -R "$slug" --json body -q .body 2>/dev/null \
	| sed -n 's/^Fingerprint: //p' || true)
if [ -n "$installer_fp" ] && [ "$installer_fp" = "$published_fp" ]; then
	echo "==> installer unchanged ($installer_fp), not uploaded"
else
	scripts/package-installer.sh
	mv out/Bridgeplay-Installer.zip "$out/bridgeplay/Bridgeplay-Installer.zip"
	# Bridgeplay Installer.app downloads this zip for GPTK, the engine and the configs and
	# checks it against "<EdDSA signature> <length>" in the .sig beside it (InstallerComponents).
	# A dry run doesn't read the keychain, so it writes no signature.
	if [ "$dry_run" -eq 0 ]; then
		installer_signed=$("$sparkle/sign_update" "$out/bridgeplay/Bridgeplay-Installer.zip") \
			|| die "could not sign the installer zip"
		installer_sig=$(printf '%s\n' "$installer_signed" | sed -nE 's/.*edSignature="([^"]+)".*length="([0-9]+)".*/\1 \2/p')
		[ -n "$installer_sig" ] || die "sign_update printed no signature for the installer zip"
		printf '%s\n' "$installer_sig" >"$out/bridgeplay/Bridgeplay-Installer.zip.sig"
	fi
	installer_body=$(printf 'The one-click installer behind bridgeplay.dev/download. It downloads the latest Bridgeplay when it runs.\n\nFingerprint: %s\n' "$installer_fp")
	if gh release view "$installer_tag" -R "$slug" >/dev/null 2>&1; then
		# The zip first, then its .sig: an installer that reads the new .sig before the new
		# zip is in place fails its check and retries (InstallerComponents).
		swap_asset "$installer_tag" "$out/bridgeplay/Bridgeplay-Installer.zip"
		swap_asset "$installer_tag" "$out/bridgeplay/Bridgeplay-Installer.zip.sig"
		run gh release edit "$installer_tag" -R "$slug" --notes "$installer_body"
	else
		run gh release create "$installer_tag" "$out/bridgeplay/Bridgeplay-Installer.zip" \
			"$out/bridgeplay/Bridgeplay-Installer.zip.sig" -R "$slug" \
			--target "$(git rev-parse HEAD)" --title "Bridgeplay Installer" --notes "$installer_body" \
			--prerelease --latest=false
	fi
fi

if [ "$dry_run" -eq 1 ]; then
	echo "==> dry run: nothing published; zips and appcasts in $out"
	exit 0
fi
echo "==> released $tag: https://github.com/$slug/releases/tag/$tag"
# The release is the zip; the built app copies would only show up in Spotlight next to
# /Applications/Bridgeplay.app.
rm -rf build/Bridgeplay.app out/Bridgeplay.app
