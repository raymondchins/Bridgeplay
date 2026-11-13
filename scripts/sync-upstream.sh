#!/bin/sh
# Merge new work from the projects this fork follows, keeping every local patch.
#
#   scripts/sync-upstream.sh            merge, then print what came in
#   scripts/sync-upstream.sh --check    only report whether anything new is upstream
#
# Source: NotProtonNot/NotProton (remote upstream). The fork this one started from,
# leonseemann/NotProton-WineHQ, was deleted in October 2026. Upstream is merged with a merge commit, never
# rebased or taken with -X theirs, so local commits stay as they are. The only conflict
# resolved automatically is dylib/version.h: Bridgeplay's lines are kept and
# NOTPROTON_VERSION takes upstream's value. Any other conflict aborts that merge and
# leaves the tree untouched. After a merge on main, scripts/bump-version.sh patch is committed;
# on develop (BRIDGEPLAY_BETA_BRANCH, default develop), where betas are built, nothing is bumped.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

check_only=0
case "${1:-}" in
	--check) check_only=1 ;;
	"") ;;
	*) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

ensure_remote() {
	url=$(git remote get-url "$1" 2>/dev/null || true)
	[ -n "$url" ] || git remote add "$1" "$2"
}
ensure_remote upstream https://github.com/NotProtonNot/NotProton

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "==> the tree has uncommitted changes, commit them first" >&2
	exit 1
fi

git fetch -q upstream

version_of() {
	sed -n 's/^#define NOTPROTON_VERSION "\(.*\)"/\1/p'
}

product_of() {
	sed -n 's/^#define BRIDGEPLAY_VERSION "\(.*\)"/\1/p'
}

pending=""
count=$(git rev-list --count "HEAD..upstream/main")
[ "$count" -eq 0 ] || pending=" upstream/main:$count"

if [ -z "$pending" ]; then
	echo "==> up to date with upstream/main"
	exit 0
fi
echo "==> new upstream commits:$pending"
[ "$check_only" -eq 0 ] || exit 2

# A merge on main is bumped below, and the bump needs the highest build. Read it before merging,
# so being offline stops the sync instead of leaving a merge without its bump.
branch=$(git symbolic-ref -q --short HEAD || true)
if [ "$branch" != "${BRIDGEPLAY_BETA_BRANCH:-develop}" ] && [ -z "${BRIDGEPLAY_HIGHEST_BUILD:-}" ]; then
	BRIDGEPLAY_HIGHEST_BUILD=$(sh scripts/build-ledger.sh highest -q) || {
		echo "==> can't read the highest build online; set BRIDGEPLAY_HIGHEST_BUILD and run again" >&2
		exit 1
	}
	export BRIDGEPLAY_HIGHEST_BUILD
fi

ours_before=$(product_of <dylib/version.h)
for entry in $pending; do
	ref=${entry%%:*}
	echo "==> merging $ref"
	if git merge --no-ff --no-edit "$ref" >/dev/null 2>&1; then
		continue
	fi
	conflicts=$(git diff --name-only --diff-filter=U)
	if [ "$conflicts" != "dylib/version.h" ]; then
		git merge --abort
		echo "==> $ref conflicts with local patches in:" >&2
		# shellcheck disable=SC2086 # one path per line
		printf '    %s\n' $conflicts >&2
		echo "    nothing was merged from $ref; resolve it by hand" >&2
		exit 1
	fi
	theirs=$(git show "$ref:dylib/version.h" | version_of)
	# It goes into a sed replacement below, so only a plain dotted version gets that far.
	if ! printf '%s\n' "$theirs" | grep -Eqx '[0-9.]+'; then
		git merge --abort
		echo "==> $ref has NOTPROTON_VERSION \"$theirs\", not a dotted version; nothing was merged" >&2
		exit 1
	fi
	git checkout -q --ours dylib/version.h
	sed "s/^#define NOTPROTON_VERSION \".*\"/#define NOTPROTON_VERSION \"$theirs\"/" dylib/version.h >dylib/version.h.tmp
	cat dylib/version.h.tmp >dylib/version.h
	rm dylib/version.h.tmp
	git add dylib/version.h
	git commit -q --no-edit
	echo "==> kept Bridgeplay's version.h, NotProton $theirs"
done

# On develop nothing is bumped: the committed version stays X.Y.Z there, and the stable that
# ships the beta takes the bump. On main (a security or crash hotfix from upstream) an upstream
# merge is a patch: versions move slowly, see docs/RELEASING.md.
if [ "$branch" = "${BRIDGEPLAY_BETA_BRANCH:-develop}" ]; then
	echo "==> on $branch: no version bump committed; the stable that ships this beta gets it"
elif [ "$(product_of <dylib/version.h)" = "$ours_before" ]; then
	scripts/bump-version.sh patch
	git commit -q -m "chore(release): bump Bridgeplay to $(product_of <dylib/version.h) after upstream merge" dylib/version.h
fi

echo "==> merged. Build and test, then publish with scripts/release-local.sh"
