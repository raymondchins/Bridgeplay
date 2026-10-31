#!/bin/sh
# shellcheck disable=SC2016 # the sh -c programs expand their own arguments
# Runs scripts/compat-reported-commit.sh against local bare repos standing in for GitHub:
# main plus a beta that is ahead of it and is the default branch.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="$repo/scripts/compat-reported-commit.sh"
workflow_src="$repo/.github/workflows/compat-reported.yml"
[ -f "$script" ] || { echo "==> compat-reported-commit: $script not present, skipped"; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { # check <description> <command...>
	d=$1; shift
	if "$@"; then ok "$d"; else bad "$d"; fi
}
refs() { git -C "$origin" for-each-ref --format='%(refname) %(objectname)'; }

# $origin has main, beta (HEAD, two commits ahead of main) and a tag.
mkorigin() {
	origin="$work/origin.git"
	rm -rf "$origin" "$work/seed"
	git init -q --bare -b beta "$origin"
	git init -q -b main "$work/seed"
	(
		cd "$work/seed"
		mkdir compat
		printf '{"fetched":"2026-01-01","games":[{"id":1}]}\n' > compat/reported.json
		git add . && git commit -q -m "main: reported"
		git tag v-main
		git checkout -q -b beta
		echo beta1 > beta.txt && git add beta.txt && git commit -q -m "beta 1"
		echo beta2 >> beta.txt && git commit -q -am "beta 2"
		git push -q "$origin" main beta v-main
	)
}

# What actions/checkout does with `ref: main`; $1 is the ref to check out.
clone() {
	rm -rf "$work/ci"
	git clone -q "$origin" "$work/ci"
	git -C "$work/ci" fetch -q origin "$1"
	git -C "$work/ci" checkout -q -B "$1" "refs/remotes/origin/$1"
}

# Stands in for compat-reported.py: new games list, new "fetched".
refresh() {
	printf '{"fetched":"2026-02-02","games":%s}\n' "$1" > "$work/ci/compat/reported.json"
}

run() { (cd "$work/ci" && bash "$script" 2>"$work/err" >"$work/out"); }

echo "== changed list, default branch is beta"
mkorigin
before=$(refs)
beta_tip=$(git -C "$origin" rev-parse beta)
main_tip=$(git -C "$origin" rev-parse main)
clone main
refresh '[{"id":1},{"id":2}]'
check "script succeeds" run
check "main moved by exactly one commit" \
	test "$(git -C "$origin" rev-list --count "$main_tip..main")" = 1
check "the new commit's parent is main's old tip" \
	test "$(git -C "$origin" rev-parse main^)" = "$main_tip"
check "the commit touches only compat/reported.json" \
	test "$(git -C "$origin" diff-tree --no-commit-id --name-only -r main)" = compat/reported.json
check "the commit message is the refresh message" \
	test "$(git -C "$origin" log -1 --format=%s main)" = "chore(compat): refresh AppleGamingWiki ratings"
check "main does not contain beta" sh -c '! git -C "$1" merge-base --is-ancestor "$2" main' _ "$origin" "$beta_tip"
check "beta is untouched" test "$(git -C "$origin" rev-parse beta)" = "$beta_tip"
check "beta.txt is not on main" test -z "$(git -C "$origin" ls-tree --name-only main beta.txt)"
check "the default branch is still beta" test "$(git -C "$origin" symbolic-ref HEAD)" = refs/heads/beta
check "nothing but main changed on the remote" \
	test "$(refs | grep -v '^refs/heads/main ')" = "$(echo "$before" | grep -v '^refs/heads/main ')"

echo "== unchanged list"
mkorigin
before=$(refs)
clone main
printf '{"fetched":"2026-03-03","games":[{"id":1}]}\n' > "$work/ci/compat/reported.json"
check "script succeeds" run
check "it says there is no change" grep -q "no change in the game list" "$work/out"
check "the remote is unchanged" test "$(refs)" = "$before"
check "no local commit was made" test "$(git -C "$work/ci" rev-parse HEAD)" = "$(git -C "$origin" rev-parse main)"

echo "== checkout is on the default branch (checkout ref missing)"
mkorigin
before=$(refs)
clone beta
refresh '[{"id":1},{"id":2}]'
check "script fails" sh -c '! ( cd "$1" && bash "$2" ) >/dev/null 2>&1' _ "$work/ci" "$script"
check "the remote is unchanged" test "$(refs)" = "$before"
check "no commit was made" test "$(git -C "$work/ci" rev-parse HEAD)" = "$(git -C "$origin" rev-parse beta)"

echo "== checkout is a detached HEAD at main's tip"
mkorigin
before=$(refs)
clone main
git -C "$work/ci" checkout -q --detach
refresh '[{"id":1},{"id":2}]'
check "script fails" sh -c '! ( cd "$1" && bash "$2" ) >/dev/null 2>&1' _ "$work/ci" "$script"
check "the remote is unchanged" test "$(refs)" = "$before"

echo "== main moved after the checkout (rejected push)"
mkorigin
clone main
refresh '[{"id":1},{"id":2}]'
(
	cd "$work/seed"
	git checkout -q main
	echo race > race.txt && git add race.txt && git commit -q -m "race"
	git push -q "$origin" main
)
before=$(refs)
check "script fails" sh -c '! ( cd "$1" && bash "$2" ) >/dev/null 2>"$3"' _ "$work/ci" "$script" "$work/err"
check "the error says the push was rejected" grep -q "push to main was rejected" "$work/err"
check "the remote is unchanged" test "$(refs)" = "$before"

echo "== a push the remote refuses"
mkorigin
clone main
refresh '[{"id":1},{"id":2}]'
printf '#!/bin/sh\necho no >&2\nexit 1\n' > "$origin/hooks/pre-receive"
chmod +x "$origin/hooks/pre-receive"
before=$(refs)
check "script fails" sh -c '! ( cd "$1" && bash "$2" ) >/dev/null 2>"$3"' _ "$work/ci" "$script" "$work/err"
check "the error says the push was rejected" grep -q "push to main was rejected" "$work/err"
check "the remote is unchanged" test "$(refs)" = "$before"

echo "== TARGET_BRANCH is honoured"
mkorigin
main_tip=$(git -C "$origin" rev-parse main)
clone beta
refresh '[{"id":1},{"id":2}]'
check "script succeeds with TARGET_BRANCH=beta" sh -c 'cd "$1" && TARGET_BRANCH=beta bash "$2" >/dev/null 2>&1' _ "$work/ci" "$script"
check "beta gained the commit" test "$(git -C "$origin" log -1 --format=%s beta)" = "chore(compat): refresh AppleGamingWiki ratings"
check "main is untouched" test "$(git -C "$origin" rev-parse main)" = "$main_tip"

echo "== the workflow"
workflow="$work/workflow.yml"
tr -d '\r' < "$workflow_src" > "$workflow"
check "TARGET_BRANCH is main" grep -qx '  TARGET_BRANCH: main' "$workflow"
check "the checkout step names the target branch" \
	sh -c 'grep -A1 "uses: actions/checkout@" "$1" | grep -qx "        with:" && grep -qx "          ref: \${{ env.TARGET_BRANCH }}" "$1"' _ "$workflow"
check "the commit step runs the script" grep -q 'run: bash scripts/compat-reported-commit.sh' "$workflow"
check "the workflow pushes nothing itself" test -z "$(grep -n 'git push' "$workflow" || true)"
check "the job has no ref other than the target branch" \
	test "$(grep -c '^ *ref:' "$workflow")" = 1

if [ "$fails" -ne 0 ]; then
	echo "compat-reported-commit: $fails check(s) failed"
	exit 1
fi
echo "==> compat-reported-commit: all checks passed"
