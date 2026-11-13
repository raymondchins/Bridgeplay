#!/bin/sh
# Build numbers across releases, claims and branches. See docs/RELEASING.md.
#
#   scripts/build-ledger.sh highest [-q] | claim N [COMMIT] [--dry-run]
#
# highest prints the highest build each source records, then H, the highest of them all:
#   - app releases (v*): the ledger block, the `Build N, based on NotProton X.` line and, for the
#     newest few and any release whose body records none, the release's appcast.xml;
#   - build/<n> claim tags;
#   - the committed BRIDGEPLAY_BUILD on main, develop and every release/* branch.
# It reads all of them online and prints no number if any can't be read. -q prints H alone.
#
# claim pushes the lightweight tag build/N at COMMIT (default HEAD), before anything is built or
# signed. Exit 0: claimed, or already ours (the tag is at COMMIT: a resume). Exit 2: taken by
# another commit. Exit 3: the remote can't be reached. --dry-run only reports what would happen.
#
# The remote is found by URL (github.com/raymondchins/Bridgeplay), never by name. Tests point
# BRIDGEPLAY_LEDGER_REMOTE_URL at a local repository instead.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
# shellcheck source=/dev/null
. "$repo/scripts/ledger-lib.sh"

slug=raymondchins/Bridgeplay
# Releases whose appcast.xml is read even when the body records the build.
appcasts=${BRIDGEPLAY_LEDGER_APPCASTS:-5}

usage() {
	sed -n '4p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 1
}
die() { echo "==> $*" >&2; exit 1; }
warn() { echo "==> warning: $*" >&2; }

find_remote() {
	want=$(printf '%s' "${BRIDGEPLAY_LEDGER_REMOTE_URL:-}" | tr '[:upper:]' '[:lower:]')
	lslug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	for r in $(git remote); do
		url=$(git remote get-url "$r" | tr '[:upper:]' '[:lower:]')
		if [ -n "$want" ]; then
			[ "$url" = "$want" ] && { echo "$r"; return 0; }
			continue
		fi
		case $url in
			*github.com[:/]"$lslug"|*github.com[:/]"$lslug".git|*github.com[:/]"$lslug"/) echo "$r"; return 0 ;;
		esac
	done
	return 1
}

remote_or_die() {
	remote=$(find_remote) \
		|| die "no git remote points at ${BRIDGEPLAY_LEDGER_REMOTE_URL:-github.com/$slug}; git remote add bridgeplay https://github.com/$slug.git"
	remote_url=$(git remote get-url "$remote")
}

work=""
cleanup() { [ -z "$work" ] || rm -rf "$work"; }
trap cleanup EXIT

# max A B
max() { if [ "$2" -gt "$1" ]; then echo "$2"; else echo "$1"; fi; }

highest() {
	quiet=0
	case "${1:-}" in
		-q) quiet=1; shift ;;
		"") ;;
		*) usage ;;
	esac
	[ $# -eq 0 ] || usage
	remote_or_die
	work=$(mktemp -d "${TMPDIR:-/tmp}/bridgeplay-ledger.XXXXXX")

	git ls-remote "$remote" >"$work/refs" 2>"$work/err" \
		|| die "can't read the branches and tags of $remote ($remote_url): $(cat "$work/err")"

	# Claim tags. An annotated one counts too; its ^{} line names the same build.
	claims=0
	claim_tag=""
	while read -r _sha ref; do
		case $ref in refs/tags/build/*) ;; *) continue ;; esac
		n=${ref#refs/tags/build/}
		n=${n%^\{\}}
		ledger_posint "$n" || continue
		if [ "$n" -gt "$claims" ]; then claims=$n; claim_tag=build/$n; fi
	done <"$work/refs"

	# Committed builds. main must exist; develop and release/* count when they do.
	branches=$(awk '{ b = substr($2, 12) } $2 ~ /^refs\/heads\// && (b == "main" || b == "develop" || b ~ /^release\/./) { print b }' "$work/refs")
	case " $(echo "$branches" | tr '\n' ' ') " in
		*" main "*) ;;
		*) die "$remote ($remote_url) has no main branch" ;;
	esac
	specs=""
	for b in $branches; do specs="$specs +refs/heads/$b:refs/remotes/$remote/$b"; done
	# shellcheck disable=SC2086 # one refspec per word; branch names have no spaces
	git fetch -q --no-tags "$remote" $specs 2>"$work/err" \
		|| die "can't fetch the branches of $remote ($remote_url): $(cat "$work/err")"
	committed=0
	branch_lines=""
	for b in $branches; do
		n=$(git show "refs/remotes/$remote/$b:dylib/version.h" 2>/dev/null \
			| sed -n 's/^#define BRIDGEPLAY_BUILD \([0-9][0-9]*\)$/\1/p')
		ledger_posint "$n" || die "$b on $remote has no numeric BRIDGEPLAY_BUILD in dylib/version.h"
		committed=$(max "$committed" "$n")
		branch_lines="$branch_lines$b: $n
"
	done

	# Releases, newest first: tag, appcast.xml asset id, body (base64). "-" stands for none.
	gh api --paginate "repos/$slug/releases?per_page=100" --jq '.[] | [
		.tag_name,
		((.assets // []) | map(select(.name == "appcast.xml")) | (.[0].id // "-") | tostring),
		(if (.body // "") == "" then "-" else (.body | @base64) end)
	] | @tsv' >"$work/releases" 2>"$work/err" \
		|| die "can't read the releases of $slug: $(cat "$work/err")"

	released=0
	release_tag=""
	seen=0
	tab=$(printf '\t')
	while IFS=$tab read -r tag asset body64; do
		[ -n "$tag" ] || continue
		is_app_release_tag "$tag" || continue
		seen=$((seen + 1))
		if [ "$body64" = "-" ]; then
			: >"$work/body"
		else
			printf '%s' "$body64" | base64 -d >"$work/body" 2>/dev/null \
				|| die "can't decode the body of release $tag"
		fi
		from_ledger=""
		rc=0
		from_ledger=$(ledger_field build <"$work/body") || rc=$?
		case $rc in
			0) ledger_posint "$from_ledger" || die "release $tag: the ledger's build '$from_ledger' is not a number" ;;
			1) from_ledger="" ;;
			3) die "release $tag has a ledger newer than v1; update this checkout" ;;
			*) die "release $tag has a malformed ledger block" ;;
		esac
		from_line=$(legacy_build <"$work/body") || from_line=""
		from_appcast=""
		if [ "$asset" != "-" ] && { [ "$seen" -le "$appcasts" ] || [ -z "$from_ledger$from_line" ]; }; then
			gh api -H 'Accept: application/octet-stream' "repos/$slug/releases/assets/$asset" \
				>"$work/appcast.xml" 2>"$work/err" \
				|| die "can't read appcast.xml of release $tag: $(cat "$work/err")"
			from_appcast=$(appcast_build <"$work/appcast.xml") || from_appcast=""
		fi
		best=0
		found=""
		for n in $from_ledger $from_line $from_appcast; do
			best=$(max "$best" "$n")
			case " $found " in *" $n "*) ;; *) found="$found $n" ;; esac
		done
		[ "$best" -gt 0 ] || die "release $tag records no build (no ledger, no Build line, no appcast build)"
		# shellcheck disable=SC2086 # numbers only
		set -- $found
		[ $# -eq 1 ] || warn "release $tag records builds$found (ledger ${from_ledger:--}, body ${from_line:--}, appcast ${from_appcast:--}); taking $best"
		if [ "$best" -gt "$released" ]; then released=$best; release_tag=$tag; fi
	done <"$work/releases"

	h=$(max "$(max "$released" "$claims")" "$committed")
	if [ "$quiet" -eq 1 ]; then
		echo "$h"
		return 0
	fi
	if [ "$released" -gt 0 ]; then echo "releases: $released ($release_tag)"; else echo "releases: none"; fi
	if [ "$claims" -gt 0 ]; then echo "claims: $claims ($claim_tag)"; else echo "claims: none"; fi
	printf '%s' "$branch_lines"
	echo "H: $h"
}

# holder_of N: the commit build/N points at on the remote, empty if none. Fails offline.
holder_of() {
	_out=$(git ls-remote "$remote" "refs/tags/build/$1" "refs/tags/build/$1^{}" 2>/dev/null) || return 1
	# A peeled line, if any, names the commit; it comes after the tag's own line.
	printf '%s\n' "$_out" | awk -v t="refs/tags/build/$1" '$2 == t { c = $1 } $2 == t "^{}" { p = $1 } END { print (p != "" ? p : c) }'
}

claim() {
	dry=0
	n=""
	commit=""
	for arg in "$@"; do
		case $arg in
			--dry-run) dry=1 ;;
			-*) usage ;;
			*)
				if [ -z "$n" ]; then n=$arg
				elif [ -z "$commit" ]; then commit=$arg
				else usage; fi
				;;
		esac
	done
	ledger_posint "$n" || die "claim wants a build number, got '$n'"
	sha=$(git rev-parse -q --verify "${commit:-HEAD}^{commit}") || die "no commit '${commit:-HEAD}' here"
	remote_or_die
	tag=build/$n

	if [ "$dry" -eq 0 ]; then
		if out=$(git push --porcelain "$remote" "$sha:refs/tags/$tag" 2>&1); then
			# --porcelain marks an unchanged ref with "=".
			if printf '%s\n' "$out" | grep -q '^='; then
				echo "already ours: $tag is at $sha; resuming"
			else
				echo "claimed $tag at $sha"
			fi
			return 0
		fi
	fi
	holder=$(holder_of "$n") || {
		echo "==> network: can't reach $remote ($remote_url) to claim $tag" >&2
		exit 3
	}
	if [ -z "$holder" ]; then
		[ "$dry" -eq 1 ] && { echo "dry run: would claim $tag at $sha"; return 0; }
		die "pushing $tag to $remote ($remote_url) failed: $out"
	fi
	if [ "$holder" = "$sha" ]; then
		echo "already ours: $tag is at $sha; resuming"
		return 0
	fi
	echo "==> taken: $tag is held by $holder, not $sha; claim a higher build" >&2
	exit 2
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case $cmd in
	highest) highest "$@" ;;
	claim) claim "$@" ;;
	*) usage ;;
esac
