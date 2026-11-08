#!/bin/sh
# Stamp a beta build's label, build number and channel at build time, committing nothing.
#
#   BRIDGEPLAY_BETA=N BRIDGEPLAY_BETA_BUILD=B [BRIDGEPLAY_BETA_PLANNED=X.Y.Z] make app
#   scripts/stamp-beta.sh check | print | apply Info.plist
#
# dylib/version.h always holds the plain X.Y.Z, on main and on develop. A beta build is named
# after the release it leads to: label X.Y.Z-beta.N with X.Y.Z the planned release, which
# defaults to the next patch of the committed version; name a milestone minor to override it.
# It must be above the committed version. The build number B is "the highest build ever
# published, stable or beta, plus one", so it is higher than every build before it; it must be
# above the committed build. N is a positive integer. Anything else fails the build.
#
#   check    validate dylib/version.h and the BRIDGEPLAY_BETA* variables; changes nothing
#   print    the stamped label, build and channel as version=, build= and channel= lines
#   apply    write them into an Info.plist; a normal build (no BRIDGEPLAY_BETA) changes nothing
#
# A normal build keeps the committed version, the committed build and the stable channel
# that app/Info.plist already carries. See docs/RELEASING.md.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
header=$repo/dylib/version.h
# shellcheck source=/dev/null
. "$repo/scripts/version-lib.sh"

die() { echo "==> $*" >&2; exit 1; }

mode=${1:-}
case "$mode" in
	check|print) [ $# -eq 1 ] || die "usage: stamp-beta.sh check | print | apply Info.plist" ;;
	apply) [ $# -eq 2 ] || die "usage: stamp-beta.sh apply Info.plist" ;;
	*) die "usage: stamp-beta.sh check | print | apply Info.plist" ;;
esac

committed=$(header_string "$header" BRIDGEPLAY_VERSION)
committed_build=$(header_number "$header" BRIDGEPLAY_BUILD)
is_semver "$committed" || die "BRIDGEPLAY_VERSION '$committed' in $header is not X.Y.Z; a beta label is stamped at build time, never committed"
is_posint "$committed_build" || die "no numeric BRIDGEPLAY_BUILD in $header"

version=$committed
build=$committed_build
channel=stable

# BRIDGEPLAY_BETA set at all, even empty, asks for a beta, so a malformed number fails
# rather than quietly building a stable app.
if [ -n "${BRIDGEPLAY_BETA+set}" ]; then
	is_posint "$BRIDGEPLAY_BETA" || die "BRIDGEPLAY_BETA '$BRIDGEPLAY_BETA' is not a positive integer (the beta number N)"
	beta_build=${BRIDGEPLAY_BETA_BUILD:-}
	is_posint "$beta_build" || die "BRIDGEPLAY_BETA_BUILD '$beta_build' is not a positive integer (the highest published build plus one)"
	[ "$beta_build" -gt "$committed_build" ] \
		|| die "BRIDGEPLAY_BETA_BUILD $beta_build is not above the committed build $committed_build, so the beta would not order above the stable it branched from"
	planned=${BRIDGEPLAY_BETA_PLANNED:-}
	if [ -z "$planned" ]; then
		planned=$(semver_next patch "$committed")
	else
		is_semver "$planned" || die "BRIDGEPLAY_BETA_PLANNED '$planned' is not X.Y.Z"
		semver_gt "$planned" "$committed" \
			|| die "BRIDGEPLAY_BETA_PLANNED $planned is not above the committed version $committed"
	fi
	version=$planned-beta.$BRIDGEPLAY_BETA
	build=$beta_build
	channel=beta
elif [ -n "${BRIDGEPLAY_BETA_BUILD+set}" ] || [ -n "${BRIDGEPLAY_BETA_PLANNED+set}" ]; then
	die "BRIDGEPLAY_BETA_BUILD or BRIDGEPLAY_BETA_PLANNED is set without BRIDGEPLAY_BETA (the beta number N)"
fi

case "$mode" in
	check) ;;
	print)
		echo "version=$version"
		echo "build=$build"
		echo "channel=$channel"
		;;
	apply)
		[ "$channel" = beta ] || exit 0
		plist=$2
		[ -f "$plist" ] || die "$plist does not exist"
		"${PLISTBUDDY:-/usr/libexec/PlistBuddy}" \
			-c "Set :CFBundleShortVersionString $version" \
			-c "Set :CFBundleVersion $build" \
			-c "Set :BridgeplayChannel $channel" \
			"$plist"
		echo "==> Stamped beta $version (build $build) into $plist"
		;;
esac
