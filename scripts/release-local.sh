#!/bin/sh
# Build Bridgeplay from this checkout and publish it as the latest GitHub release of
# raymondchins/Bridgeplay, which is what the app's updater (Sparkle, SUFeedURL in
# app/Info.plist) reads; or, with --beta, as a beta on the beta feed. See docs/RELEASING.md.
#
#   scripts/release-local.sh [--dry-run] [--legacy-feed] ["release notes"]
#   scripts/release-local.sh --beta [--dry-run] [--critical <reason>]
#                            [--waive-stable <tag> --reason <text>] "release notes"
#   scripts/release-local.sh --beta --rebuild-feeds [--dry-run] [--withdraw <tag> --reason <text>]
#
#   --dry-run        run the checks and write the zips and feeds to out/release/ without
#                    publishing or claiming, from the app already in build/ or out/; never
#                    reads the keychain (SPARKLE_KEY_FILE signs, else a throwaway key signs
#                    the feeds and a beta's zip, and a stable's zip stays unsigned)
#   --legacy-feed    also publish the update where NotProton builds up to 1.1.9-ray.31
#                    look for one (raymondchins/NotProton-WineHQ), as NotProton.zip
#   release notes    default: the commit subjects since the previous release; required for a beta
#   --beta           publish HEAD, the tip of develop or a release/* branch, as vX.Y.Z-beta.N
#   --critical       publish it on the beta-critical channel; the reason starts with
#                    "security:" or "data-loss:"
#   --waive-stable   publish a beta that lacks the newest stable, <tag>, recording why
#   --rebuild-feeds  regenerate the beta feed from the releases; --withdraw leaves a beta out
#
# The update and the feed are signed with the EdDSA key in this Mac's login keychain, created
# once with app/.build/artifacts/sparkle/Sparkle/bin/generate_keys; app/Info.plist's
# SUPublicEDKey must be its public half. The app is code signed with BRIDGEPLAY_SIGN_IDENTITY
# (default the maintainer's Developer ID in the login keychain) and notarized with the
# notarytool profile BRIDGEPLAY_NOTARY_PROFILE (default "bridgeplay-notary"). The version comes
# from dylib/version.h (scripts/bump-version.sh) and must not have been released yet.
# HEAD must already be pushed to the Bridgeplay repository's main.
#
# Before building it claims build/<build> for HEAD (scripts/build-ledger.sh claim). A stable
# that contains a beta the previous stable did not must ship that release candidate's tree
# (docs/RELEASING.md, Stable releases and betas). The release is created without Latest, its
# uploaded digests are checked, and only then is it marked Latest; a run that stopped in
# between is resumed by running this again. Then the beta feed, if there is one, is refreshed.
#
# A beta is labelled X.Y.Z-beta.N (X.Y.Z from release/X.Y.Z, or the next patch above the newest
# stable on develop), claims H+1, and is published as a prerelease carrying Bridgeplay.zip only;
# swapping the regenerated beta feed onto the beta-feed release exposes it (docs/RELEASING.md,
# Beta releases). It never touches the stable feed, the installer or the legacy feed.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
# shellcheck source=/dev/null
. "$repo/scripts/ledger-lib.sh"
# shellcheck source=/dev/null
. "$repo/scripts/release-lib.sh"
# shellcheck source=/dev/null
. "$repo/scripts/version-lib.sh"

usage() {
	sed -n '6,23p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 1
}

dry_run=0
legacy=0
beta=0
rebuild=0
critical=""
waive=""
reason=""
withdraw=""
notes=""
notes_given=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=1 ;;
		--legacy-feed) legacy=1 ;;
		--beta) beta=1 ;;
		--rebuild-feeds) rebuild=1 ;;
		--critical|--waive-stable|--reason|--withdraw)
			[ $# -ge 2 ] && [ -n "$2" ] || usage
			case $1 in
				--critical) critical=$2 ;;
				--waive-stable) waive=$2 ;;
				--reason) reason=$2 ;;
				*) withdraw=$2 ;;
			esac
			shift
			;;
		-h|--help) usage ;;
		# Notes may start with "- " (a list); an unknown option may not.
		--*|-[!\ ]*) usage ;;
		*) [ "$notes_given" -eq 0 ] || usage; notes=$1; notes_given=1 ;;
	esac
	shift
done

slug=raymondchins/Bridgeplay
legacy_slug=raymondchins/NotProton-WineHQ
# Bridgeplay needs macOS 26 (SetupChecks.minimumMacOS); older Macs are not offered updates.
min_macos=26.0

die() { echo "==> $*" >&2; exit 1; }

mode=stable
if [ "$beta" -eq 1 ]; then
	mode=beta
	# R6: a beta never reaches the feed NotProton builds read.
	[ "$legacy" -eq 0 ] || die "--legacy-feed is refused with --beta: a beta never publishes the legacy feed"
	if [ "$rebuild" -eq 1 ]; then
		mode=rebuild
		[ "$notes_given" -eq 0 ] && [ -z "$critical$waive" ] \
			|| die "--rebuild-feeds takes no release notes, --critical or --waive-stable"
		[ -z "$withdraw" ] || is_beta_tag "$withdraw" || die "--withdraw wants a vX.Y.Z-beta.N tag, got '$withdraw'"
		[ -n "$withdraw" ] || [ -z "$reason" ] || die "--reason goes with --waive-stable or --withdraw"
		[ -z "$withdraw" ] || [ -n "$reason" ] || die "--withdraw needs --reason <text>"
	else
		[ -z "$withdraw" ] || die "--withdraw goes with --rebuild-feeds"
		[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] || die "a beta needs release notes: what changed and what to test"
		[ -n "$waive" ] || [ -z "$reason" ] || die "--reason goes with --waive-stable or --withdraw"
		[ -z "$waive" ] || [ -n "$reason" ] || die "--waive-stable needs --reason <text>"
		if [ -n "$critical" ]; then
			# F0.6: beta-critical is only for a security or data-loss fix.
			printf '%s\n' "$critical" | grep -Eqi '^(security|data-loss): *[^ ]' \
				|| die "--critical is only for a security or data-loss fix: give the reason as \"security: ...\" or \"data-loss: ...\""
			ledger_render kind=beta build=1 "critical-reason=$critical" >/dev/null || die "--critical: the reason must fit the ledger (one line, no --)"
		fi
		[ -z "$waive" ] || ledger_render kind=beta build=1 "waived-stable=$waive" "waiver-reason=$reason" >/dev/null \
			|| die "--waive-stable: the tag and reason must fit the ledger (one line, no --)"
	fi
	[ -z "$reason" ] || [ "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" = 1 ] || die "--reason must be one line"
elif [ "$rebuild" -eq 1 ] || [ -n "$critical$waive$reason$withdraw" ]; then
	die "--rebuild-feeds, --critical, --waive-stable, --reason and --withdraw go with --beta"
fi

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

# create_release ARGS...: gh release create for $tag. An upload that breaks off inside it leaves
# a draft; that draft was never public, so it is deleted and a rerun starts clean.
create_release() {
	run gh release create "$tag" "$@" && return 0
	_draft=$(gh release view "$tag" -R "$slug" --json isDraft -q .isDraft 2>/dev/null || true)
	[ "$_draft" = true ] || die "creating $tag failed (above)"
	gh release delete "$tag" -R "$slug" -y >/dev/null 2>&1 \
		|| die "creating $tag failed (above) and left a draft; delete it on GitHub (it was never public), then run again"
	die "creating $tag failed (above); deleted the draft it left (it was never public), run again"
}

remote=""
remote_url=""
release_remote || die "no git remote points at github.com/$slug; git remote add bridgeplay https://github.com/$slug.git"

# Temporary files; a real release's out/ is one of them. The lock is shared with every release
# mode, so two runs in this clone never build or publish at once.
work=""
real_out=""
cleanup() {
	[ -z "$work" ] || rm -rf "$work"
	[ -z "$real_out" ] || rm -rf "$real_out"
	release_unlock
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
release_lock || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/bridgeplay-release.XXXXXX")


[ "$mode" = rebuild ] || [ -z "$(git status --porcelain --untracked-files=no)" ] || check "the tree has uncommitted changes"
head=$(git rev-parse HEAD)
upstream=$(sed -n 's/^#define NOTPROTON_VERSION "\(.*\)"$/\1/p' dylib/version.h)
tab=$(printf '\t')

if [ "$mode" = stable ]; then
	git fetch -q "$remote"
	[ "$head" = "$(git rev-parse "$remote/main")" ] || check "HEAD is not $remote/main; push first"

	version=$(sed -n 's/^#define BRIDGEPLAY_VERSION "\(.*\)"$/\1/p' dylib/version.h)
	build=$(sed -n 's/^#define BRIDGEPLAY_BUILD \([0-9][0-9]*\)$/\1/p' dylib/version.h)
	[ -n "$version" ] && [ -n "$build" ] || die "dylib/version.h has no BRIDGEPLAY_VERSION/BRIDGEPLAY_BUILD"
	tag="v$version"
	zip_url="https://github.com/$slug/releases/download/$tag/Bridgeplay.zip"
	# "" when there is no release for the tag yet, else whether it is still a draft.
	existing=$(gh release view "$tag" -R "$slug" --json isDraft -q '.isDraft' 2>/dev/null || true)

	# SUFeedURL is releases/latest/download/appcast.xml, so the Latest release is the update
	# feed of every installed app. If it is not an app release (no appcast.xml, say a DXMT
	# build marked Latest), that feed is already down; stop rather than publish over a state
	# nobody has looked at. Fix which release is Latest on GitHub, then run this again.
	latest=$(gh release view -R "$slug" --json tagName,assets \
		-q '.tagName + " " + ([.assets[].name] | join(" "))' 2>/dev/null || true)
	latest_tag=""
	if [ -n "$latest" ]; then
		latest_tag=${latest%% *}
		case " ${latest#* } " in
			*" appcast.xml "*) ;;
			*) check "the Latest release $latest_tag has no appcast.xml, so the update feed is down; mark an app release Latest first" ;;
		esac
		is_stable_tag "$latest_tag" \
			|| check "the Latest release $latest_tag is not a vX.Y.Z app release; mark an app release Latest first"
	fi

	# A release for this tag that is not Latest is one a run created and then stopped before
	# exposing: this run checks it and marks it Latest, uploading nothing.
	resume=0
	case $existing in
		"") ;;
		true) check "$tag is an unfinished draft (a run stopped while uploading); delete it on GitHub, it was never public, and run again" ;;
		*)
			if [ "$latest_tag" = "$tag" ]; then
				check "$tag is already released; run scripts/bump-version.sh patch|minor|major"
			else
				resume=1
			fi
			;;
	esac

	# Release notes: the commits since the previous app release, unless given. Other releases
	# in the repository (DXMT builds) have tags that are not vX.Y.Z and are skipped.
	previous=$(gh release list -R "$slug" --limit 100 --json tagName -q '.[].tagName' 2>/dev/null \
		| grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "$tag" | head -n 1 || true)
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

	# Betas: which published ones this stable contains (the feed's containsBetas and the ledger)
	# and, when it contains one the previous stable did not, whether it ships that release
	# candidate's tree (R4). Skipped on a resume, which publishes what the first run checked.
	gate_contains=""
	gate_promoted=none
	gate_data=""
	if [ "$resume" -eq 0 ]; then
		release_published_betas "$work/betas" || die "can't tell which betas are published (above); nothing was claimed or built"
		previous_commit=""
		if [ -s "$work/betas" ] && is_stable_tag "$previous"; then
			previous_commit=$(release_tag_commit "$previous") \
				|| die "can't find the commit of the previous stable $previous on $remote ($remote_url)"
		fi
		release_gate "$head" "$previous_commit" "$work/betas" "$build" \
			|| check "this stable may not ship as it is (above)"
		echo "==> contains betas: ${gate_contains:-none}; promoted from: $gate_promoted"
		if [ -n "$gate_data" ]; then
			echo "==> data changed since $gate_promoted (compat/** may differ from the beta):"
			printf '%s\n' "$gate_data" | sed 's/^/    /'
		fi
	fi
fi

if [ "$mode" = beta ]; then
	# HEAD must be the tip of develop or a release/* branch on the remote found by URL; the
	# label comes from that branch.
	branches=$(git ls-remote --heads "$remote" 2>/dev/null) || die "can't read the branches of $remote ($remote_url)"
	tips=$(printf '%s\n' "$branches" | awk -v h="$head" '$1 == h { b = substr($2, 12); if (b == "develop" || b ~ /^release\/./) print b }')
	source_branch=$(printf '%s\n' "$tips" | grep '^release/' || true)
	if [ "$(printf '%s\n' "$source_branch" | grep -c .)" -gt 1 ]; then
		check "HEAD is the tip of several release branches ($(printf '%s\n' "$source_branch" | tr '\n' ' ')); its label comes from one, so keep HEAD on one"
		source_branch=$(printf '%s\n' "$source_branch" | head -n 1)
	fi
	[ -n "$source_branch" ] || source_branch=$(printf '%s\n' "$tips" | grep -x develop || true)
	if [ -z "$source_branch" ]; then
		source_branch=$(git symbolic-ref -q --short HEAD || echo detached)
		check "HEAD ($source_branch) is not the tip of develop or a release/* branch on $remote ($remote_url); betas are built from those, so push it there first"
	fi
	committed=$(header_string dylib/version.h BRIDGEPLAY_VERSION)
	committed_build=$(header_number dylib/version.h BRIDGEPLAY_BUILD)
	if ! is_semver "$committed" || ! is_posint "$committed_build"; then
		die "dylib/version.h has no plain BRIDGEPLAY_VERSION/BRIDGEPLAY_BUILD"
	fi
	channel=beta
	[ -z "$critical" ] || channel="beta-critical"

	release_list "$work/releases" || die "can't read the releases (above); nothing was claimed or built"
	# A beta of HEAD that is already published (a run stopped before exposing it): resumed.
	resume_tag=""
	while IFS=$tab read -r t draft _pre _pub _dig _size _names b64; do
		is_beta_tag "$t" || continue
		c=$(printf '%s' "$b64" | b64_body | ledger_field commit 2>/dev/null || true)
		[ "$c" = "$head" ] || continue
		if [ "$draft" = true ]; then
			check "$t, a beta of HEAD, is an unfinished draft (a run stopped while uploading); delete it on GitHub, it was never public, and run again"
			continue
		fi
		[ -z "$resume_tag" ] || check "HEAD is published as both $resume_tag and $t; look at the releases on GitHub"
		resume_tag=$t
	done <"$work/releases"

	if [ -z "$resume_tag" ]; then
		# I-2: the beta contains the newest stable, unless that is waived and recorded.
		stable_tag=$(release_newest_stable "$work/releases") || die "can't tell the newest stable (above)"
		rc=0
		stable_commit=$(release_tag_commit "$stable_tag") || rc=$?
		[ "$rc" -eq 0 ] || die "can't find the commit of the newest stable $stable_tag on $remote ($remote_url)"
		if git merge-base --is-ancestor "$stable_commit" "$head"; then
			if [ -n "$waive" ]; then
				check "--waive-stable $waive is not needed: HEAD contains $stable_tag; drop it"
				waive=""
				reason=""
			fi
		elif [ -z "$waive" ]; then
			check "I-2: HEAD does not contain $stable_tag, the newest stable: merge main into $source_branch and push, or, if it must ship without it, --waive-stable $stable_tag --reason <why>"
		elif [ "$waive" != "$stable_tag" ]; then
			check "--waive-stable $waive does not name the newest stable, $stable_tag, which HEAD lacks"
		else
			echo "==> !!! I-2 WAIVED: this beta does not contain $stable_tag, the newest stable."
			echo "==> !!! Beta users get it without that stable's fixes. Reason: $reason"
			echo "==> !!! The ledger records waived-stable: $waive."
		fi

		# The label: X.Y.Z from release/X.Y.Z, else the next patch above the newest stable; N one
		# above the highest beta of X.Y.Z, published, draft or only tagged.
		case $source_branch in
			release/*)
				planned=${source_branch#release/}
				is_semver "$planned" || die "$source_branch is not named release/X.Y.Z, so it names no release"
				;;
			*) planned=$(semver_next patch "${stable_tag#v}") ;;
		esac
		remote_tags=$(git ls-remote --tags "$remote" 2>/dev/null) || die "can't read the tags of $remote ($remote_url)"
		if awk -F '\t' -v t="v$planned" '$1 == t { f = 1 } END { exit !f }' "$work/releases" \
			|| printf '%s\n' "$remote_tags" | awk -v t="refs/tags/v$planned" '$2 == t { f = 1 } END { exit !f }'; then
			check "v$planned is already a stable release, so betas can't be named after it; rename $source_branch to the next version"
		fi
		# Equal once main's bump for this release is merged into its release branch (R4).
		semver_ge "$planned" "$committed" \
			|| check "the beta's release $planned is below the committed version $committed (dylib/version.h)"
		planned_re=$(printf '%s' "$planned" | sed 's/\./\\./g')
		n=$({ cut -f1 "$work/releases"; printf '%s\n' "$remote_tags" | awk '{ sub(/^refs\/tags\//, "", $2); sub(/\^\{\}$/, "", $2); print $2 }'; } \
			| sed -n "s/^v$planned_re-beta\.\([1-9][0-9]*\)\$/\1/p" | sort -n | tail -n 1)
		n=$((${n:-0} + 1))
		version=$planned-beta.$n
		tag=v$version
		echo "==> beta $version from $source_branch, channel $channel"
	fi
fi

if [ "$mode" != rebuild ]; then
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
	wine_src_sha=$(sed -n '/^  wine-patch-sources-[0-9a-f]*\.tar\.gz, sha256$/{n;s/^  \([0-9a-f]\{64\}\),.*/\1/p;}' NOTICE)
	[ -n "$wine_src_sha" ] || die "no wine-patch-sources sha256 pinned in NOTICE"
	wine_src_tag=${wine_src_archive%.tar.gz}
	gh release view "$wine_src_tag" -R "$slug" --json assets -q ".assets[] | select(.name == \"$wine_src_archive\") | .digest" 2>/dev/null \
		| grep -qx "sha256:$wine_src_sha" \
		|| check "$wine_src_tag has no $wine_src_archive matching NOTICE's sha256 on GitHub; run scripts/package-wine-patch-sources.sh --publish"
fi

sparkle=app/.build/artifacts/sparkle/Sparkle/bin
[ -x "$sparkle/generate_appcast" ] || swift build --package-path app >/dev/null
[ -x "$sparkle/generate_appcast" ] || die "no Sparkle tools at $sparkle"

if [ "$mode" != rebuild ]; then
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
fi

if [ "$dry_run" -eq 1 ]; then
	# Never the keychain. SPARKLE_KEY_FILE (generate_keys -x) signs for real; otherwise a
	# throwaway key (32 random bytes, an Ed25519 seed) stands in, and since it is not
	# SUPublicEDKey's pair generate_appcast leaves the enclosure unsigned; the feed is still
	# signed with it. The key copy lives in the temp folder, removed on any exit, never under out/.
	keydir=$work/key
	mkdir -m 700 "$keydir"
	if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
		cp "$SPARKLE_KEY_FILE" "$keydir/throwaway.key"
	else
		head -c 32 /dev/urandom | base64 >"$keydir/throwaway.key"
	fi
	key_args="--ed-key-file $keydir/throwaway.key"
else
	key=$("$sparkle/generate_keys" -p 2>/dev/null) || die "no Sparkle key in the keychain; run $sparkle/generate_keys"
	[ "$key" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' app/Info.plist)" ] \
		|| die "app/Info.plist SUPublicEDKey is not this keychain's Sparkle key"
	key_args=""
fi

# bridgeplay.dev's Download (vercel.json /download) points at the fixed "installer"
# release. The installer carries no app (Install.command downloads the Bridgeplay.zip of
# the Latest release), so it is uploaded only when its fingerprint, every file it ships,
# differs from the one on that release.
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
	gh release upload "$swap_tag" "$staged" -R "$slug" || die "could not upload next-$name to the $swap_tag release"
	id=$(gh api "repos/$slug/releases/tags/$swap_tag" --jq ".assets[] | select(.name == \"next-$name\") | .id") \
		&& [ -n "$id" ] || die "uploaded next-$name is missing from the $swap_tag release"
	gh release delete-asset "$swap_tag" "$name" -R "$slug" -y >/dev/null 2>&1 || true
	gh api -X PATCH "repos/$slug/releases/assets/$id" -f name="$name" >/dev/null \
		|| die "could not rename next-$name to $name on the $swap_tag release; rename it on GitHub now"
	rm -f "$staged"
}
# $1: the folder the installer zip goes to.
installer_step() {
	installer_fp=$(scripts/package-installer.sh --fingerprint-only | tail -n 1)
	published_fp=$(gh release view "$installer_tag" -R "$slug" --json body -q .body 2>/dev/null \
		| sed -n 's/^Fingerprint: //p' || true)
	if [ -n "$installer_fp" ] && [ "$installer_fp" = "$published_fp" ]; then
		echo "==> installer unchanged ($installer_fp), not uploaded"
		return 0
	fi
	mkdir -p "$1"
	scripts/package-installer.sh
	mv out/Bridgeplay-Installer.zip "$1/Bridgeplay-Installer.zip"
	# Bridgeplay Installer.app downloads this zip for GPTK, the engine and the configs and
	# checks it against "<EdDSA signature> <length>" in the .sig beside it (InstallerComponents).
	# A dry run doesn't read the keychain, so it writes no signature.
	if [ "$dry_run" -eq 0 ]; then
		installer_signed=$("$sparkle/sign_update" "$1/Bridgeplay-Installer.zip") \
			|| die "could not sign the installer zip"
		installer_sig=$(printf '%s\n' "$installer_signed" | sed -nE 's/.*edSignature="([^"]+)".*length="([0-9]+)".*/\1 \2/p')
		[ -n "$installer_sig" ] || die "sign_update printed no signature for the installer zip"
		printf '%s\n' "$installer_sig" >"$1/Bridgeplay-Installer.zip.sig"
	fi
	installer_body=$(printf 'The one-click installer behind bridgeplay.dev/download. It downloads the latest Bridgeplay when it runs.\n\nFingerprint: %s\n' "$installer_fp")
	if gh release view "$installer_tag" -R "$slug" >/dev/null 2>&1; then
		# The zip first, then its .sig: an installer that reads the new .sig before the new
		# zip is in place fails its check and retries (InstallerComponents).
		swap_asset "$installer_tag" "$1/Bridgeplay-Installer.zip"
		swap_asset "$installer_tag" "$1/Bridgeplay-Installer.zip.sig"
		run gh release edit "$installer_tag" -R "$slug" --notes "$installer_body"
	else
		run gh release create "$installer_tag" "$1/Bridgeplay-Installer.zip" \
			"$1/Bridgeplay-Installer.zip.sig" -R "$slug" \
			--target "$head" --title "Bridgeplay Installer" --notes "$installer_body" \
			--prerelease --latest=false
	fi
}

# claim_build: claims build/$build for HEAD before anything is built (F0.1); a dry run only
# reports. Already ours is a resume.
claim_build() {
	claim_rc=0
	if [ "$dry_run" -eq 1 ]; then
		sh scripts/build-ledger.sh claim "$build" "$head" --dry-run || claim_rc=$?
	else
		sh scripts/build-ledger.sh claim "$build" "$head" || claim_rc=$?
	fi
	case $claim_rc in
		0) ;;
		2) check "build/$build is taken by another commit; bump again with the current H (scripts/bump-version.sh reads it), commit, push and release" ;;
		*) check "can't claim build/$build (above); nothing was built" ;;
	esac
}

# The release's assets as "name digest size" lines, or nothing.
release_assets() {
	gh release view "$tag" -R "$slug" --json assets \
		-q '.assets[] | .name + " " + (.digest // "-") + " " + (.size | tostring)' 2>/dev/null || true
}

# expose: marks $tag Latest, the one step that offers the update to every installed app.
expose() {
	run gh release edit "$tag" -R "$slug" --latest
	[ "$dry_run" -eq 1 ] && return 0
	now=$(gh release view -R "$slug" --json tagName -q .tagName 2>/dev/null || true)
	[ "$now" = "$tag" ] || die "marked $tag Latest, but GitHub's Latest is '$now'; mark $tag Latest on GitHub"
}

# resume_release: $tag exists and is not Latest. Checks that it is this commit's complete,
# verified release, then exposes it.
resume_release() {
	echo "==> $tag exists but is not Latest: a run stopped before exposing it; checking it, then marking it Latest"
	rbody=$(gh release view "$tag" -R "$slug" --json body -q .body 2>/dev/null || true)
	rled() { printf '%s\n' "$rbody" | ledger_field "$1" 2>/dev/null || true; }
	[ "$(rled kind)" = stable ] && [ "$(rled build)" = "$build" ] && [ "$(rled tag)" = "$tag" ] \
		&& [ "$(rled commit)" = "$head" ] \
		|| check "$tag's ledger is not this commit's stable build $build; look at the release on GitHub"
	at=$(release_tag_commit "$tag" || true)
	[ "$at" = "$head" ] || check "tag $tag is at '${at:-nothing}', not HEAD ($head)"
	assets=$(release_assets)
	for name in Bridgeplay.zip appcast.xml Bridgeplay-Setup.zip Bridgeplay.dmg; do
		printf '%s\n' "$assets" | awk -v n="$name" '$1 == n && $2 ~ /^sha256:/ && $3 > 0 { ok = 1 } END { exit !ok }' \
			|| check "$tag has no complete $name; delete the release on GitHub (it was never Latest) and run again"
	done
	zip_digest=$(printf '%s\n' "$assets" | awk '$1 == "Bridgeplay.zip" { print $2 }')
	zip_size=$(printf '%s\n' "$assets" | awk '$1 == "Bridgeplay.zip" { print $3 }')
	[ "$zip_digest" = "sha256:$(rled zip-sha256)" ] && [ "$zip_size" = "$(rled zip-length)" ] \
		|| check "$tag's Bridgeplay.zip is not the one its ledger records; delete the release on GitHub (it was never Latest) and run again"
	mkdir -p "$work/resume"
	gh release download "$tag" -R "$slug" -p appcast.xml -D "$work/resume" --clobber >/dev/null 2>&1 \
		|| check "can't download $tag's appcast.xml"
	feed_guard "$work/resume/appcast.xml" "$version" "$build" "$zip_url" "$min_macos" \
		|| check "$tag's uploaded appcast.xml fails I-6 (above); delete the release on GitHub (it was never Latest) and run again"
	enc="//*[local-name()='enclosure']"
	[ "$(xp "$work/resume/appcast.xml" "string($enc/@*[local-name()='edSignature'])")" = "$(rled ed-signature)" ] \
		&& [ "$(xp "$work/resume/appcast.xml" "string($enc/@length)")" = "$(rled zip-length)" ] \
		|| check "$tag's appcast.xml does not match its ledger; delete the release on GitHub (it was never Latest) and run again"
	claim_build
	expose
	echo "==> $tag is Latest; nothing was uploaded again"
}

# build_app: builds the app for $version ($build) and notarizes it; a dry run takes the app
# already in build/ or out/. Sets app and out (out/release in a dry run, else a temp folder).
build_app() {
	if [ "$dry_run" -eq 1 ]; then
		out=out/release
		rm -rf "$out"
		mkdir -p "$out"
		# generate_appcast's cache goes under out/, not ~/Library.
		CFFIXED_USER_HOME=$repo/$out/home
		export CFFIXED_USER_HOME
		app=""
		for candidate in build/Bridgeplay.app out/Bridgeplay.app; do
			[ -d "$candidate" ] && { app=$candidate; break; }
		done
		[ -n "$app" ] || die "--dry-run needs a built app: make app (or scripts/build-local.sh)"
	else
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
		real_out=$out
	fi

	plist=$app/Contents/Info.plist
	built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
	built_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
	[ "$built" = "$version" ] && [ "$built_build" = "$build" ] \
		|| check "built $built ($built_build), expected $version ($build) from dylib/version.h"
	if [ "$mode" = beta ]; then
		built_channel=$(/usr/libexec/PlistBuddy -c 'Print :BridgeplayChannel' "$plist" 2>/dev/null || true)
		[ "$built_channel" = beta ] || check "the app's BridgeplayChannel is '$built_channel', not beta (scripts/stamp-beta.sh)"
	fi
	# generate_appcast takes the feed's minimumSystemVersion from LSMinimumSystemVersion, and the
	# signed feed can't be edited afterwards, so the app must already ask for min_macos.
	built_min=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || true)
	[ "$built_min" = "$min_macos" ] \
		|| check "the app's LSMinimumSystemVersion is '$built_min', not $min_macos, the macOS the feed must ask for (app/Info.plist)"
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
}

# --- the beta feed: built from the releases' ledgers, swapped onto the beta-feed release ---

# Where the beta feed is written: out/release/beta-feed in a dry run.
beta_feed_dir() {
	if [ "$dry_run" -eq 1 ]; then echo out/release/beta-feed; else echo "$work/beta-feed"; fi
}

# carrier_state: "none" when there is no beta-feed release, "ok" when it is a published
# prerelease. Returns 1, saying why, when it can't be read or is anything else.
carrier_state() {
	_rc=0
	_st=$(gh release view "$BETA_FEED_TAG" -R "$slug" --json isDraft,isPrerelease \
		-q '(.isDraft | tostring) + " " + (.isPrerelease | tostring)' 2>&1) || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		case $_st in *"not found"*) echo none; return 0 ;; esac
		echo "==> can't read the $BETA_FEED_TAG release: $_st" >&2
		return 1
	fi
	[ "$_st" = "false true" ] \
		|| { echo "==> the $BETA_FEED_TAG release is not a published prerelease (draft, prerelease: $_st); make it one on GitHub" >&2; return 1; }
	echo ok
}

# make_beta_feed DIR [EXTRA [BUILD]]: regenerates the beta feed into DIR/appcast.xml from the
# releases (F0.5) plus EXTRA's records (a dry run's unpublished release), signs it after that
# last edit and checks it; BUILD must be in it. Returns 1 with the reason on stderr.
make_beta_feed() {
	rm -rf "$1"
	mkdir -p "$1"
	release_list "$work/feed-releases" || return 1
	feed_stable=$(release_newest_stable "$work/feed-releases") || return 1
	beta_feed_items "$work/feed-releases" "$feed_stable" "$withdraw" "$1/items" "${2:-}" || return 1
	beta_feed_render "$1/items" "$1/appcast.xml" "$min_macos"
	# shellcheck disable=SC2086 # key_args is empty or two words
	"$sparkle/sign_update" $key_args "$1/appcast.xml" >/dev/null || { echo "==> could not sign the beta feed" >&2; return 1; }
	echo "==> beta feed:"
	awk -F '\t' '{ printf "    %s (build %s), %s\n", $3, $2, ($1 == "stable" ? "stable, contains betas " ($8 == "-" ? "none" : $8) : $5) }' "$1/items"
	rm -f "$1/items"
	beta_feed_guard "$1/appcast.xml" "$min_macos" "${3:-}" || return 1
	echo "==> beta feed signed and checked"
}

# expose_beta_feed DIR CREATE [BUILD TAG]: puts DIR/appcast.xml on the beta-feed release, the one
# step that offers a beta, by upload, rename and delete. With CREATE "create" a missing release
# is created (prerelease, never Latest, at the newest stable's commit); otherwise there is
# nothing to refresh. A real run then downloads the feed and checks it, and with BUILD the
# signature and length of TAG's zip against its item. Returns 1 with the reason on stderr.
expose_beta_feed() {
	_state=$(carrier_state) || return 1
	if [ "$_state" = ok ]; then
		swap_asset "$BETA_FEED_TAG" "$1/appcast.xml"
	elif [ "$2" = create ]; then
		_target=$(release_tag_commit "$feed_stable") || { echo "==> can't find the commit of $feed_stable" >&2; return 1; }
		[ "$dry_run" -eq 0 ] || echo "==> dry run: there is no $BETA_FEED_TAG release; a real run creates it"
		run gh release create "$BETA_FEED_TAG" "$1/appcast.xml" -R "$slug" --target "$_target" \
			--title "Bridgeplay beta feed" \
			--notes "The beta update feed: the newest stable and the newest betas above it. Not an app release." \
			--prerelease --latest=false || return 1
	else
		echo "==> no $BETA_FEED_TAG release: no beta feed to refresh"
		return 0
	fi
	[ "$dry_run" -eq 0 ] || return 0
	_chk=$work/published-feed
	rm -rf "$_chk"
	mkdir -p "$_chk"
	gh release download "$BETA_FEED_TAG" -R "$slug" -p appcast.xml -D "$_chk" --clobber >/dev/null 2>&1 \
		|| { echo "==> can't download the published beta feed back" >&2; return 1; }
	cmp -s "$_chk/appcast.xml" "$1/appcast.xml" \
		|| { echo "==> the published beta feed is not the one uploaded" >&2; return 1; }
	beta_feed_guard "$_chk/appcast.xml" "$min_macos" "${3:-}" || return 1
	if [ -n "${3:-}" ]; then
		gh release download "$4" -R "$slug" -p Bridgeplay.zip -D "$_chk" --clobber >/dev/null 2>&1 \
			|| { echo "==> can't download $4's Bridgeplay.zip back" >&2; return 1; }
		_len=$(beta_feed_item "$_chk/appcast.xml" "$3" length)
		_sig=$(beta_feed_item "$_chk/appcast.xml" "$3" edSignature)
		[ "$_len" = "$(wc -c <"$_chk/Bridgeplay.zip" | tr -d ' ')" ] \
			|| { echo "==> the beta feed gives build $3 length '$_len', not the size of $4's zip" >&2; return 1; }
		# shellcheck disable=SC2086 # key_args is empty or two words
		"$sparkle/sign_update" --verify $key_args "$_chk/Bridgeplay.zip" "$_sig" >/dev/null 2>&1 \
			|| { echo "==> the beta feed's signature for build $3 does not match $4's zip" >&2; return 1; }
	fi
	echo "==> the published beta feed was read back and checked"
}

# refresh_beta_feed: after a stable is Latest, the beta feed, if there is one, gets that stable
# and keeps the betas above it. A failure leaves the stable as it is, says how to recover and
# sets feed_failed. Call it as a plain command: after || or in an if, set -e would not stop the
# steps below at the first failure.
refresh_beta_feed() {
	_extra=""
	if [ "$dry_run" -eq 1 ] && [ "$resume" -eq 0 ]; then
		_extra=$work/stable-record
		feed_record stable "$build" "$version" "$tag" - "$zip_len" "$ed_sig" "$gate_contains" - "$notes" >"$_extra"
	fi
	set +e
	(
		set -e
		[ "$(carrier_state)" != none ] || { echo "==> no $BETA_FEED_TAG release: no beta feed to refresh"; exit 0; }
		make_beta_feed "$(beta_feed_dir)" "$_extra"
		expose_beta_feed "$(beta_feed_dir)" refresh
	)
	_rc=$?
	set -e
	[ "$_rc" -ne 0 ] || return 0
	echo "==> $tag is released, but the beta feed was not refreshed (above); the stable is fine. Recover with:" >&2
	echo "    scripts/release-local.sh --beta --rebuild-feeds" >&2
	feed_failed=1
}

# beta_claim: build is H+1, claimed for HEAD. Another release claiming it first makes this read
# H and try once more, then stop.
beta_claim() {
	tries=0
	while :; do
		h=$(sh scripts/build-ledger.sh highest -q) || { check "can't read H, the highest build (above); nothing was claimed or built"; h=$committed_build; }
		build=$((h + 1))
		claim_rc=0
		if [ "$dry_run" -eq 1 ]; then
			sh scripts/build-ledger.sh claim "$build" "$head" --dry-run || claim_rc=$?
		else
			sh scripts/build-ledger.sh claim "$build" "$head" || claim_rc=$?
		fi
		case $claim_rc in
			0) return 0 ;;
			2)
				tries=$((tries + 1))
				if [ "$tries" -ge 2 ]; then
					check "build/$build was taken too: other releases are claiming builds right now; run again when they are done"
					return 0
				fi
				echo "==> build/$build was claimed by another release just now; reading H again"
				;;
			*)
				check "can't claim build/$build (above); nothing was built"
				return 0
				;;
		esac
	done
}

# beta_expose [EXTRA]: regenerates the beta feed with $tag ($build) in it and swaps it in.
beta_expose() {
	if ! make_beta_feed "$(beta_feed_dir)" "${1:-}" "$build"; then
		[ "$dry_run" -eq 1 ] || die "the beta feed could not be made (above); $tag is published but not offered yet: fix that and run this again"
		check "the beta feed could not be made (above)"
		return 0
	fi
	set +e
	(
		set -e
		expose_beta_feed "$(beta_feed_dir)" create "$build" "$tag"
	)
	_rc=$?
	set -e
	[ "$_rc" -eq 0 ] || die "the beta feed was not exposed (above); $tag is published but may not be offered: run this again"
}

# beta_publish: claims, builds, signs and publishes $tag as a prerelease carrying Bridgeplay.zip
# and the ledger, checks the upload, then exposes it on the beta feed.
beta_publish() {
	beta_claim
	echo "==> $tag: build $build, channel $channel"
	BRIDGEPLAY_BETA=$n
	BRIDGEPLAY_BETA_BUILD=$build
	BRIDGEPLAY_BETA_PLANNED=$planned
	export BRIDGEPLAY_BETA BRIDGEPLAY_BETA_BUILD BRIDGEPLAY_BETA_PLANNED
	build_app
	mkdir -p "$out/beta"
	staging=$(mktemp -d)
	ditto "$app" "$staging/Bridgeplay.app"
	ditto -c -k --keepParent "$staging/Bridgeplay.app" "$out/beta/Bridgeplay.zip"
	rm -rf "$staging"
	zip=$out/beta/Bridgeplay.zip
	zip_sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
	zip_len=$(wc -c <"$zip" | tr -d ' ')
	# shellcheck disable=SC2086 # key_args is empty or two words
	ed_sig=$("$sparkle/sign_update" $key_args -p "$zip") && [ -n "$ed_sig" ] || die "could not sign $zip"
	if [ "$dry_run" -eq 1 ] && [ -z "${SPARKLE_KEY_FILE:-}" ]; then
		echo "==> dry run: the zip and the feed are signed with a throwaway key, which installed apps refuse"
	fi

	set -- kind=beta "build=$build" "label=$version" "tag=$tag" "commit=$head" "source-branch=$source_branch" \
		"zip-sha256=$zip_sha" "zip-length=$zip_len" "ed-signature=$ed_sig" "channel=$channel"
	[ -z "$critical" ] || set -- "$@" "critical-reason=$critical"
	[ -z "$waive" ] || set -- "$@" "waived-stable=$waive" "waiver-reason=$reason"
	ledger=$(ledger_render "$@") || die "could not write the ledger"
	body=$(printf '%s\n\nBuild %s, based on NotProton %s.\n\n%s\n' "$notes" "$build" "$upstream" "$ledger")
	[ "$(printf '%s\n' "$body" | ledger_field build 2>/dev/null)" = "$build" ] \
		&& [ "$(printf '%s\n' "$body" | ledger_field commit 2>/dev/null)" = "$head" ] \
		|| die "the release body's ledger does not read back as build $build; check the notes for a ledger block"
	echo "==> Bridgeplay $version (build $build) from $source_branch:"
	printf '%s\n' "$notes" | sed 's/^/    /'
	printf '%s\n' "$ledger" | sed 's/^/    /'

	# A prerelease, never Latest, carrying the zip only (F0.4). It is offered to no one until the
	# beta feed lists it.
	create_release "$zip" -R "$slug" --target "$head" --title "Bridgeplay $version" \
		--notes "$body" --prerelease --latest=false
	extra=""
	if [ "$dry_run" -eq 1 ]; then
		echo "==> dry run: would check the uploaded digest of Bridgeplay.zip against $zip"
		extra=$work/beta-record
		feed_record beta "$build" "$version" "$tag" "$channel" "$zip_len" "$ed_sig" - - "$notes" >"$extra"
	else
		uploaded=$(release_assets)
		got=$(printf '%s\n' "$uploaded" | awk '$1 == "Bridgeplay.zip" { print $2 " " $3 }')
		if [ "$got" != "sha256:$zip_sha $zip_len" ] || [ "$(printf '%s\n' "$uploaded" | grep -c .)" != 1 ]; then
			# In no feed, so no one was offered it: remove it and its tag, so a rerun starts clean.
			gh release delete "$tag" -R "$slug" --cleanup-tag -y >/dev/null 2>&1 \
				|| die "uploaded Bridgeplay.zip is '${got:-missing}', not sha256:$zip_sha $zip_len, and deleting $tag failed; delete the release and its tag on GitHub (no feed lists it), then run again"
			die "uploaded Bridgeplay.zip is '${got:-missing}', not sha256:$zip_sha $zip_len; deleted $tag (no feed listed it), run again"
		fi
		echo "==> uploaded digest matches: Bridgeplay.zip"
	fi
	beta_expose "$extra"
}

# beta_resume: HEAD is already published as $resume_tag. Checks it against its ledger and the
# options of this run, then exposes it on the beta feed, uploading nothing.
beta_resume() {
	tag=$resume_tag
	version=${tag#v}
	echo "==> HEAD is already published as $tag: checking it, then putting it on the beta feed"
	line=$(awk -F '\t' -v t="$tag" '$1 == t' "$work/releases")
	rbody=$(printf '%s\n' "$line" | cut -f8 | b64_body)
	rled() { printf '%s\n' "$rbody" | ledger_field "$1" 2>/dev/null || true; }
	build=$(rled build)
	[ "$(rled kind)" = beta ] && ledger_posint "$build" && [ "$(rled tag)" = "$tag" ] && [ "$(rled label)" = "$version" ] \
		|| check "$tag's ledger is not a complete beta ledger for it; look at the release on GitHub"
	[ "$(rled channel)" = "$channel" ] && [ "$(rled critical-reason)" = "$critical" ] \
		&& [ "$(rled waived-stable)" = "$waive" ] && [ "$(rled waiver-reason)" = "$reason" ] \
		&& [ "$(rled source-branch)" = "$source_branch" ] \
		|| check "$tag was published from $(rled source-branch) on channel $(rled channel) (critical: $(rled critical-reason), waived: $(rled waived-stable)); this run asks for something else, and a rerun publishes nothing new: run it with the same options, or make a new commit"
	! printf '%s\n' "$rbody" | is_withdrawn || check "$tag was withdrawn from the beta feed; a new beta needs a new commit"
	at=$(release_tag_commit "$tag" || true)
	[ "$at" = "$head" ] || check "tag $tag is at '${at:-nothing}', not HEAD ($head)"
	[ "$(printf '%s\n' "$line" | cut -f7)" = Bridgeplay.zip ] \
		|| check "$tag carries $(printf '%s\n' "$line" | cut -f7); a beta carries Bridgeplay.zip only"
	[ "$(printf '%s\n' "$line" | cut -f5)" = "sha256:$(rled zip-sha256)" ] && [ "$(printf '%s\n' "$line" | cut -f6)" = "$(rled zip-length)" ] \
		|| check "$tag's Bridgeplay.zip is not the one its ledger records; nothing is overwritten: look at the release on GitHub"
	claim_build
	beta_expose
	[ "$dry_run" -eq 1 ] || echo "==> $tag is on the beta feed; nothing was uploaded again"
}

# rebuild_feeds: the beta feed regenerated from the releases, leaving out --withdraw's beta,
# which is marked withdrawn on GitHub so later feeds leave it out too. The stable feed is not
# touched.
rebuild_feeds() {
	if [ -n "$withdraw" ]; then
		release_list "$work/releases" || die "can't read the releases (above)"
		line=$(awk -F '\t' -v t="$withdraw" '$1 == t && $2 == "false"' "$work/releases")
		[ -n "$line" ] || die "$withdraw is not a published release"
		wbody=$(printf '%s\n' "$line" | cut -f8 | b64_body)
		if printf '%s\n' "$wbody" | is_withdrawn; then
			echo "==> $withdraw is already marked withdrawn"
		else
			new_body=$(printf '%s %s\n\n%s\n' "$WITHDRAWN_LINE" "$reason" "$wbody")
			[ "$(printf '%s\n' "$new_body" | ledger_field build 2>/dev/null)" = "$(printf '%s\n' "$wbody" | ledger_field build 2>/dev/null)" ] \
				|| die "$withdraw's ledger would not read back after marking it withdrawn"
			echo "==> withdrawing $withdraw from the beta feed: $reason"
			run gh release edit "$withdraw" -R "$slug" --notes "$new_body"
		fi
	fi
	make_beta_feed "$(beta_feed_dir)" || die "the beta feed could not be made (above); nothing was published"
	expose_beta_feed "$(beta_feed_dir)" create || die "the beta feed was not exposed (above)"
	if [ "$dry_run" -eq 1 ]; then
		echo "==> dry run: nothing published; the beta feed is in $(beta_feed_dir)"
	else
		echo "==> beta feed rebuilt: https://github.com/$slug/releases/download/$BETA_FEED_TAG/appcast.xml"
	fi
}

if [ "$mode" = rebuild ]; then
	rebuild_feeds
	exit 0
fi
if [ "$mode" = beta ]; then
	if [ -n "$resume_tag" ]; then
		beta_resume
	else
		beta_publish
	fi
	if [ "$dry_run" -eq 1 ]; then
		echo "==> dry run: nothing published; the zip and the beta feed are in out/release"
		exit 0
	fi
	echo "==> released $tag to the beta feed: https://github.com/$slug/releases/tag/$tag"
	rm -rf build/Bridgeplay.app out/Bridgeplay.app
	exit 0
fi

feed_failed=0
if [ "$resume" -eq 1 ]; then
	resume_release
	installer_step "$work/installer"
	[ "$legacy" -eq 0 ] || echo "==> --legacy-feed: not published on a resumed run, which has no app to zip; the next release's --legacy-feed carries it"
	refresh_beta_feed
	[ "$dry_run" -eq 0 ] || { echo "==> dry run: nothing published"; exit 0; }
	echo "==> released $tag: https://github.com/$slug/releases/tag/$tag"
	[ "$feed_failed" -eq 0 ] || exit 1
	exit 0
fi

claim_build
build_app

# One archive and one appcast per feed. The appcast attached to the latest release is the
# feed, so each only needs the newest item; its enclosure points at this tag's zip.
# $1 directory, $2 archive name, $3 app name inside it, $4 repository, $5 stable or legacy
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
	grep -q "<sparkle:minimumSystemVersion>$min_macos<" "$1/appcast.xml" || die "$1/appcast.xml does not ask for macOS $min_macos"
	grep -q "<sparkle:version>$build</sparkle:version>" "$1/appcast.xml" || die "$1/appcast.xml does not carry build $build"
	grep -q "url=\"https://github.com/$4/releases/download/$tag/$2\"" "$1/appcast.xml" \
		|| die "$1/appcast.xml does not point at $4 $tag/$2"
	# SUVerifyUpdateBeforeExtraction: an update without a valid EdDSA signature is refused.
	if ! grep -q 'sparkle:edSignature="' "$1/appcast.xml"; then
		if [ "$dry_run" -eq 1 ]; then
			echo "==> dry run: $1/appcast.xml is unsigned (no SPARKLE_KEY_FILE); a release stops here instead"
		else
			die "$1/appcast.xml has no sparkle:edSignature; users would refuse this update"
		fi
	fi
	[ "$5" = stable ] || return 0
	# The stable feed lists the betas it contains (F0.7), then is signed after that last edit.
	feed_add_contains "$1/appcast.xml" "$gate_contains" || die "could not add containsBetas to $1/appcast.xml"
	# shellcheck disable=SC2086 # key_args is empty or two words
	"$sparkle/sign_update" $key_args "$1/appcast.xml" >/dev/null || die "could not sign $1/appcast.xml"
	if feed_guard "$1/appcast.xml" "$version" "$build" "$zip_url" "$min_macos" "$1/$2"; then
		echo "==> stable feed signed and checked (I-6): build $build, contains betas ${gate_contains:-none}"
	else
		check "the stable feed fails I-6 (above); nothing was published"
	fi
}

feed "$out/bridgeplay" Bridgeplay.zip Bridgeplay.app "$slug" stable
# NotProton builds look for NotProton.app or com.notproton.NotProton in the archive
# (Sparkle's SUInstaller), so the legacy feed ships the same app under that name. It
# installs over /Applications/NotProton.app; later updates match by bundle identifier.
# That feed stays as it was: unsigned, with no containsBetas.
[ "$legacy" -eq 0 ] || feed "$out/legacy" NotProton.zip NotProton.app "$legacy_slug" legacy

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

# The body: the notes, the compat/** data that changed since the promoted beta (Q3), the Build
# line, and the ledger (F0.3), which must read back as this build.
zip=$out/bridgeplay/Bridgeplay.zip
zip_sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
zip_len=$(wc -c <"$zip" | tr -d ' ')
ed_sig=$(xp "$out/bridgeplay/appcast.xml" "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])")
# Only a dry run without SPARKLE_KEY_FILE gets this far unsigned.
[ -n "$ed_sig" ] || ed_sig=unsigned
ledger=$(ledger_render kind=stable "build=$build" "label=$version" "tag=$tag" "commit=$head" \
	source-branch=main "zip-sha256=$zip_sha" "zip-length=$zip_len" "ed-signature=$ed_sig" \
	"promoted-from=$gate_promoted" "contains-betas=${gate_contains:-none}") || die "could not write the ledger"
title="Bridgeplay $version"
plain_body=$(printf '%s\n\nBuild %s, based on NotProton %s.\n' "$notes" "$build" "$upstream")
if [ -n "$gate_data" ]; then
	body=$(printf '%s\n\nData changed since the beta (%s):\n%s\n\nBuild %s, based on NotProton %s.\n\n%s\n' \
		"$notes" "$gate_promoted" "$(printf '%s\n' "$gate_data" | sed 's/^/- /')" "$build" "$upstream" "$ledger")
else
	body=$(printf '%s\n\n%s\n' "$plain_body" "$ledger")
fi
[ "$(printf '%s\n' "$body" | ledger_field build 2>/dev/null)" = "$build" ] \
	|| die "the release body's ledger does not read back as build $build; check the notes for a ledger block"
echo "==> $title (build $build), notes since ${previous:-the beginning}:"
printf '%s\n' "$notes" | sed 's/^/    /'
printf '%s\n' "$ledger" | sed 's/^/    /'

# Created without Latest, so no installed app sees it until its uploads are checked; marking it
# Latest is the one step that exposes it. A run that stops in between resumes at that step.
assets="Bridgeplay.zip appcast.xml Bridgeplay-Setup.zip Bridgeplay.dmg"
create_release "$out/bridgeplay/Bridgeplay.zip" "$out/bridgeplay/appcast.xml" \
    "$out/bridgeplay/Bridgeplay-Setup.zip" "$out/bridgeplay/Bridgeplay.dmg" \
	-R "$slug" --target "$head" --title "$title" --notes "$body" --latest=false
if [ "$dry_run" -eq 1 ]; then
	echo "==> dry run: would check the uploaded digests of $assets against $out/bridgeplay"
else
	uploaded=$(release_assets)
	for name in $assets; do
		want="sha256:$(shasum -a 256 "$out/bridgeplay/$name" | cut -d' ' -f1)"
		got=$(printf '%s\n' "$uploaded" | awk -v n="$name" '$1 == n { print $2 }')
		if [ "$got" != "$want" ]; then
			# Never Latest, so no one was offered it: remove it and its tag, so a rerun starts clean.
			gh release delete "$tag" -R "$slug" --cleanup-tag -y >/dev/null 2>&1 \
				|| die "uploaded $name has digest '${got:-none}', not $want, and deleting $tag failed; delete the release and its tag on GitHub (it was never Latest), then run again"
			die "uploaded $name has digest '${got:-none}', not $want; deleted $tag (it was never Latest), run again"
		fi
	done
	echo "==> uploaded digests match: $assets"
fi
expose
if [ "$legacy" -eq 1 ]; then
	# Only a carrier for the feed: the tag goes on that repository's default branch, since
	# this commit need not exist there. --latest is what moves its feed.
	run gh release create "$tag" "$out/legacy/NotProton.zip" "$out/legacy/appcast.xml" -R "$legacy_slug" \
		--title "$title" --notes "NotProton is now Bridgeplay. $plain_body" --latest
fi

installer_step "$out/bridgeplay"
refresh_beta_feed

if [ "$dry_run" -eq 1 ]; then
	echo "==> dry run: nothing published; zips and appcasts in $out"
	exit 0
fi
echo "==> released $tag: https://github.com/$slug/releases/tag/$tag"
# The release is the zip; the built app copies would only show up in Spotlight next to
# /Applications/Bridgeplay.app.
rm -rf build/Bridgeplay.app out/Bridgeplay.app
[ "$feed_failed" -eq 0 ] || exit 1
