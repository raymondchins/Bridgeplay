#!/bin/sh
# cicheck: the always-running gate of .github/workflows/app.yml and the reuse of its runs.
#   - ci-code-paths.sh: which changed paths are docs (.github/docs-only-paths)
#   - ci-scope.sh: docs-only decision for push and pull_request events, on real git repos
#   - ci-gate.sh: every combination of job results, green only when it should be
#   - ci-run-passed.sh and build-local.sh's ci_passed: a run counts only if its heavy jobs ran
#   - the workflow files: triggers, job names, the gate's `if: always()`, concurrency
# No network and no gh: gh is a stub.
# shellcheck disable=SC2016 # the workflow lines checked below contain literal ${{ }} and $VAR
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); }
bad() {
	echo "FAIL: $*"
	failed=$((failed + 1))
}
eq() { # eq <what> <expected> <actual>
	if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi
}
yes() { # yes <what> <command...>: the command succeeds
	what=$1
	shift
	if "$@" >/dev/null 2>&1; then ok; else bad "$what: expected success"; fi
}
no() { # no <what> <command...>: the command fails
	what=$1
	shift
	if "$@" >/dev/null 2>&1; then bad "$what: expected failure"; else ok; fi
}

# --- ci-code-paths.sh --------------------------------------------------------------

codes() { printf '%s\n' "$@" | sh "$root/scripts/ci-code-paths.sh"; }

eq "docs only" "" "$(codes README.md docs/a/b.png compat/README.md a/b/c.md docs/x.md)"
eq "code" "app/Sources/x.swift" "$(codes app/Sources/x.swift)"
eq "mixed" "app/x.swift" "$(codes README.md app/x.swift docs/y.md)"
eq "near misses are code" "docs
docs.swift
notes.mdx
.github/docs-only-paths
.github/workflows/app.yml
dylib/version.h" "$(codes docs docs.swift notes.mdx .github/docs-only-paths .github/workflows/app.yml dylib/version.h)"
eq "no input" "" "$(printf '' | sh "$root/scripts/ci-code-paths.sh")"
eq "last line without a newline" "a.c" "$(printf 'x.md\na.c' | sh "$root/scripts/ci-code-paths.sh")"

printf '# comment\n\n*.txt\n' >"$work/patterns"
eq "other list: its pattern" "" "$(printf 'a.txt\n' | BRIDGEPLAY_DOCS_ONLY_FILE=$work/patterns sh "$root/scripts/ci-code-paths.sh")"
eq "other list: the default is gone" "b.md" "$(printf 'b.md\n' | BRIDGEPLAY_DOCS_ONLY_FILE=$work/patterns sh "$root/scripts/ci-code-paths.sh")"
eq "other list: comments are not patterns" "# comment" "$(printf '# comment\n' | BRIDGEPLAY_DOCS_ONLY_FILE=$work/patterns sh "$root/scripts/ci-code-paths.sh")"
no "missing list is an error" sh -c "printf 'a.md\n' | BRIDGEPLAY_DOCS_ONLY_FILE=$work/none sh '$root/scripts/ci-code-paths.sh'"

# --- ci-scope.sh -------------------------------------------------------------------

gitq() { git -c user.name=cicheck -c user.email=cicheck@example.invalid -c commit.gpgsign=false -c core.autocrlf=false "$@"; }
new_repo() {
	rm -rf "$work/r"
	mkdir "$work/r"
	cd "$work/r" || exit 1
	git init -q
	git config core.autocrlf false
	git symbolic-ref HEAD refs/heads/main
	mkdir app docs
	echo a >app/a.c
	echo r >README.md
	echo d >docs/d.txt
	git add -A
	gitq commit -q -m base
}
commit() { # commit <msg> <file>...: change the files and commit
	msg=$1
	shift
	for f in "$@"; do
		mkdir -p "$(dirname "$f")"
		echo "$msg" >>"$f"
	done
	git add -A
	gitq commit -q -m "$msg"
}
scope() { # scope <event> [before]
	(cd "$work/r" && EVENT=$1 BEFORE=${2:-} sh "$root/scripts/ci-scope.sh" 2>/dev/null)
}

new_repo
base=$(git rev-parse HEAD)
commit docs README.md docs/new.md
eq "push, docs only" "docs_only=true" "$(scope push "$base")"
commit code app/a.c
eq "push, docs then code in one push" "docs_only=false" "$(scope push "$base")"
second=$(git rev-parse HEAD)
commit docs2 README.md
eq "push, docs after code" "docs_only=true" "$(scope push "$second")"
eq "push, the whole range has code" "docs_only=false" "$(scope push "$base")"
commit mixed README.md app/b.c
eq "push, docs and code in one commit" "docs_only=false" "$(scope push "$(git rev-parse HEAD~1)")"
eq "push, new branch" "docs_only=false" "$(scope push 0000000000000000000000000000000000000000)"
eq "push, no before" "docs_only=false" "$(scope push)"
eq "push, before not in the repo" "docs_only=false" "$(scope push aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
eq "manual run" "docs_only=false" "$(scope workflow_dispatch "$base")"
eq "no event" "docs_only=false" "$(scope '' "$base")"
before=$(git rev-parse HEAD)
gitq commit -q --allow-empty -m empty
eq "push, nothing changed" "docs_only=false" "$(scope push "$before")"

new_repo
base=$(git rev-parse HEAD)
git mv app/a.c app/a.md
gitq commit -q -m rename
eq "push, code renamed to a doc name" "docs_only=false" "$(scope push "$base")"
new_repo
base=$(git rev-parse HEAD)
git rm -q app/a.c
gitq commit -q -m delete
eq "push, code deleted" "docs_only=false" "$(scope push "$base")"
new_repo
base=$(git rev-parse HEAD)
commit docs README.md
eq "push, list missing" "docs_only=false" \
	"$(cd "$work/r" && BRIDGEPLAY_DOCS_ONLY_FILE=$work/none EVENT=push BEFORE=$base sh "$root/scripts/ci-scope.sh" 2>/dev/null)"
new_repo
base=$(git rev-parse HEAD)
commit c app/a.c
printf '*.c\n' >"$work/c-list"
eq "push, other list" "docs_only=true" \
	"$(cd "$work/r" && BRIDGEPLAY_DOCS_ONLY_FILE=$work/c-list EVENT=push BEFORE=$base sh "$root/scripts/ci-scope.sh" 2>/dev/null)"

# A pull_request run checks out the merge commit: base first, PR head second.
pr_merge() { # pr_merge <base-ref> <pr-branch>: leave HEAD on a merge of the PR into the base
	git checkout -q -B merge "$1"
	gitq merge -q --no-ff -m merge "$2"
}
new_repo
git checkout -q -b pr
commit docs README.md docs/x.md
git checkout -q main
pr_merge main pr
eq "pull request, docs only" "docs_only=true" "$(scope pull_request)"
new_repo
git checkout -q -b pr
commit code app/a.c
pr_merge main pr
eq "pull request, code" "docs_only=false" "$(scope pull_request)"
new_repo
git checkout -q -b pr
commit docs README.md
commit code app/b.c
pr_merge main pr
eq "pull request, docs and code" "docs_only=false" "$(scope pull_request)"
new_repo
git checkout -q -b pr
commit docs README.md
git checkout -q main
commit "code on the base" app/a.c
pr_merge main pr
eq "pull request, the base moved on with code" "docs_only=true" "$(scope pull_request)"
new_repo
eq "pull request, HEAD is not a merge" "docs_only=false" "$(scope pull_request)"

# --- ci-gate.sh --------------------------------------------------------------------

gate() { SCOPE_RESULT=$1 DOCS_ONLY=$2 BUILD_RESULT=$3 CHECKS_RESULT=$4 sh "$root/scripts/ci-gate.sh"; }

yes "gate: docs-only, heavy jobs skipped" gate success true skipped skipped
yes "gate: code, heavy jobs passed" gate success false success success
no "gate: code, build failed" gate success false failure success
no "gate: code, checks failed" gate success false success failure
no "gate: code, build cancelled" gate success false cancelled success
no "gate: code, checks cancelled" gate success false success cancelled
no "gate: code, heavy jobs skipped" gate success false skipped skipped
no "gate: scope failed" gate failure '' skipped skipped
no "gate: no results at all" env -u SCOPE_RESULT -u DOCS_ONLY -u BUILD_RESULT -u CHECKS_RESULT sh "$root/scripts/ci-gate.sh"

# Every combination: green exactly for the two good ones.
for s in success failure cancelled skipped; do
	for d in true false ''; do
		for b in success failure cancelled skipped; do
			for c in success failure cancelled skipped; do
				want=1
				if [ "$s" = success ]; then
					[ "$d $b $c" = "true skipped skipped" ] && want=0
					[ "$d $b $c" = "false success success" ] && want=0
				fi
				gate "$s" "$d" "$b" "$c" >/dev/null 2>&1
				eq "gate scope=$s docs_only=$d build=$b checks=$c" "$want" "$?"
			done
		done
	done
done

# --- ci-run-passed.sh and ci_passed ------------------------------------------------

mkdir "$work/bin" "$work/fake"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
# Stub: `gh run list` answers with fake/runs.<sha>, `gh run view <id>` with fake/jobs.<id>.
echo "$*" >>"$FAKE_DIR/calls"
case "$1 $2" in
"run list")
	sha=""
	prev=""
	for a in "$@"; do
		[ "$prev" = --commit ] && sha=$a
		prev=$a
	done
	[ ! -f "$FAKE_DIR/list-fails" ] || exit 1
	cat "$FAKE_DIR/runs.$sha" 2>/dev/null
	;;
"run view") cat "$FAKE_DIR/jobs.$3" 2>/dev/null || exit 1 ;;
*) exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
FAKE_DIR=$work/fake
export FAKE_DIR
tab=$(printf '\t')
jobs_file() { # jobs_file <id> <scope> <build> <checks> <gate>
	printf 'change scope%s%s\nfull app build%s%s\nsource checks%s%s\napp gate%s%s\n' \
		"$tab" "$2" "$tab" "$3" "$tab" "$4" "$tab" "$5" >"$FAKE_DIR/jobs.$1"
}
runs_file() { # runs_file <sha> <id>...: push runs on main, newest first
	sha=$1
	shift
	for id in "$@"; do printf '%s\tpush\tmain\n' "$id"; done >"$FAKE_DIR/runs.$sha"
}
reset_fake() { rm -f "$FAKE_DIR"/runs.* "$FAKE_DIR"/jobs.* "$FAKE_DIR/calls" "$FAKE_DIR/list-fails"; }
passed_run() { PATH="$work/bin:$PATH" sh "$root/scripts/ci-run-passed.sh" owner/repo abc123; }

reset_fake
jobs_file 20 success success success success
runs_file abc123 20
yes "run: both heavy jobs succeeded" passed_run
if grep -q 'run list -R owner/repo -w app --commit abc123 --status success' "$FAKE_DIR/calls"; then ok; else bad "run: wrong gh run list query: $(cat "$FAKE_DIR/calls")"; fi

reset_fake
jobs_file 30 success skipped skipped success
runs_file abc123 30
no "run: docs-only run, gate green but nothing built" passed_run

jobs_file 20 success success success success
runs_file abc123 30 20
yes "run: newest is docs-only, an older full run counts" passed_run

reset_fake
jobs_file 20 success success failure failure
runs_file abc123 20
no "run: checks failed" passed_run
jobs_file 20 success skipped success success
no "run: build skipped" passed_run
jobs_file 20 success cancelled success success
no "run: build cancelled" passed_run
printf 'change scope\tsuccess\napp gate\tsuccess\n' >"$FAKE_DIR/jobs.20"
no "run: heavy jobs absent" passed_run
printf '' >"$FAKE_DIR/jobs.20"
no "run: no job list" passed_run
rm -f "$FAKE_DIR/jobs.20"
no "run: job list unreadable" passed_run
reset_fake
no "run: no run for the commit" passed_run
jobs_file 20 success success success success
runs_file abc123 20
: >"$FAKE_DIR/list-fails"
no "run: gh run list fails" passed_run
no "run: wrong arguments" sh "$root/scripts/ci-run-passed.sh" owner/repo

# Which runs count: a push on main, develop, dev or release/*, nothing else (review R10).
one_run() { # one_run <event> <branch>: a single run with both heavy jobs green
	reset_fake
	jobs_file 40 success success success success
	printf '40\t%s\t%s\n' "$1" "$2" >"$FAKE_DIR/runs.abc123"
}
for b in main develop dev release/0.7.70 release/0.7/rc1; do
	one_run push "$b"
	yes "run: push on $b counts" passed_run
done
one_run pull_request main
no "run: pull request run with the right job names is ignored" passed_run
one_run pull_request develop
no "run: pull request run from a branch named develop is ignored" passed_run
one_run workflow_dispatch main
no "run: manual run on main is ignored" passed_run
one_run workflow_dispatch release/0.7.70
no "run: manual run on a release branch is ignored" passed_run
for b in feat/x main2 developer devx releases/1 release/ xrelease/1 ''; do
	one_run push "$b"
	no "run: push on '$b' is ignored" passed_run
done
reset_fake
jobs_file 40 success success success success
jobs_file 41 success success success success
printf '41\tpull_request\tmain\n40\tpush\tdevelop\n' >"$FAKE_DIR/runs.abc123"
yes "run: an ignored run is skipped for a counting one behind it" passed_run
if grep -q 'run view 41' "$FAKE_DIR/calls"; then bad "run: the ignored run's jobs were read"; else ok; fi
if grep -q -- '--event push' "$FAKE_DIR/calls"; then ok; else bad "run: the query is not limited to push runs"; fi
no "run: gh missing" env PATH="/nonexistent" /bin/sh "$root/scripts/ci-run-passed.sh" owner/repo abc123

# ci_passed, the release's walk back over the last commits. Its helpers are the repo's own
# scripts, copied beside a scratch history: c1 code, c2 docs, c3 the version bump.
body=$(sed -n '/^ci_passed() {$/,/^}$/p' "$root/scripts/build-local.sh")
if [ -z "$body" ]; then
	bad "ci_passed not found in scripts/build-local.sh"
else
	eval "$body"
	# shellcheck disable=SC2034 # read by the ci_passed body evaluated above
	ci_slug=owner/repo
	make_history() {
		new_repo
		repo=$work/r
		# the copied helpers stay out of the history, or they would count as changes
		printf 'scripts/\n.github/\n' >"$repo/.git/info/exclude"
		mkdir -p "$repo/scripts" "$repo/.github" "$repo/dylib"
		cp "$root"/scripts/ci-code-paths.sh "$root"/scripts/ci-run-passed.sh "$repo/scripts/"
		cp "$root/.github/docs-only-paths" "$repo/.github/"
		echo '#define V "0.7.0"' >"$repo/dylib/version.h"
		git -C "$repo" add dylib/version.h
		gitq -C "$repo" commit -q -m c1
		c1=$(git -C "$repo" rev-parse HEAD)
		cd "$repo" && commit "$1" "$2" && c2=$(git rev-parse HEAD)
		echo '#define V "0.7.1"' >"$repo/dylib/version.h"
		git -C "$repo" add dylib/version.h
		gitq -C "$repo" commit -q -m c3
		c3=$(git -C "$repo" rev-parse HEAD)
	}
	walk() { (PATH="$work/bin:$PATH" && ci_passed); }

	reset_fake
	jobs_file 11 success success success success
	jobs_file 22 success skipped skipped success
	make_history docs README.md
	runs_file "$c1" 11
	runs_file "$c2" 22
	eq "ci_passed: the docs-only run is passed over for the full run behind it" "$c1" "$(walk)"

	reset_fake
	jobs_file 22 success skipped skipped success
	jobs_file 11 success skipped skipped success
	runs_file "$c1" 11
	runs_file "$c2" 22
	no "ci_passed: only docs-only runs, so the checks run locally" walk

	reset_fake
	jobs_file 33 success success success success
	runs_file "$c3" 33
	eq "ci_passed: a full run on the bump commit itself" "$c3" "$(walk)"

	reset_fake
	make_history code app/a.c
	jobs_file 11 success success success success
	runs_file "$c1" 11
	no "ci_passed: code changed after the full run" walk

	reset_fake
	make_history docs README.md
	jobs_file 11 success success success success
	runs_file "$c1" 11
	rm "$repo/.github/docs-only-paths"
	no "ci_passed: no docs list means can't tell, not same" walk

	# R10: HEAD is a merge commit and only its second parent, a fork's PR head, has a green run.
	merge_history() {
		new_repo
		repo=$work/r
		printf 'scripts/\n.github/\n' >"$repo/.git/info/exclude"
		mkdir -p "$repo/scripts" "$repo/.github"
		cp "$root"/scripts/ci-code-paths.sh "$root"/scripts/ci-run-passed.sh "$repo/scripts/"
		cp "$root/.github/docs-only-paths" "$repo/.github/"
		git checkout -q -b fork-pr
		commit "pr code" app/a.c
		pr_head=$(git rev-parse HEAD)
		git checkout -q main
		gitq merge -q --no-ff -m merge fork-pr
		merge_head=$(git rev-parse HEAD)
	}
	reset_fake
	merge_history
	jobs_file 50 success success success success
	printf '50\tpull_request\tmain\n' >"$FAKE_DIR/runs.$pr_head"
	no "ci_passed: a merge whose second parent has a green pull request run runs the checks" walk
	printf '50\tpush\tfeat/x\n' >"$FAKE_DIR/runs.$pr_head"
	no "ci_passed: a merge whose second parent has a green push run on a feature branch runs the checks" walk
	printf '50\tpush\tdevelop\n' >"$FAKE_DIR/runs.$pr_head"
	eq "ci_passed: the same run as a push on develop is reused" "$pr_head" "$(walk)"
	printf '50\tworkflow_dispatch\tmain\n' >"$FAKE_DIR/runs.$merge_head"
	rm "$FAKE_DIR/runs.$pr_head"
	no "ci_passed: a manual run on the merge commit runs the checks" walk

	# no gh: reuse is skipped and the checks run
	make_history docs README.md
	jobs_file 11 success success success success
	runs_file "$c1" 11
	# shellcheck disable=SC2123 # the walk must not find any gh, stub or real
	no_gh_walk() { (PATH=/usr/bin:/bin && ci_passed); }
	no "ci_passed: skipped without gh" no_gh_walk
fi
cd "$root" || exit 1

# --- the workflow files ------------------------------------------------------------

app=$work/app.yml
lint=$work/lint.yml
tr -d '\r' <"$root/.github/workflows/app.yml" >"$app"
tr -d '\r' <"$root/.github/workflows/lint.yml" >"$lint"
job() { awk -v j="  $1:" '$0 == j { p = 1; next } p && /^  [a-z_-]+:$/ { exit } p' "$app"; }
has() { printf '%s\n' "$2" | grep -Fxq -- "$1"; }

no "app.yml: no path filters" grep -Eq '^[[:space:]]*paths(-ignore)?:' "$app"
eq "app.yml: push branches" "    branches: [main, develop, dev, 'release/**']" "$(grep -E '^    branches:' "$app")"
eq "lint.yml: push branches" "    branches: [main, develop, dev, 'release/**']" "$(grep -E '^    branches:' "$lint")"
yes "app.yml: runs on every pull request" grep -Fxq '  pull_request:' "$app"
no "app.yml: pull requests not limited to a branch" awk '/^  pull_request:/ { p = 1; next } p && /^    branches/ { f = 1 } p && /^  [a-z_]+:/ { p = 0 } END { exit !f }' "$app"
yes "lint.yml: runs on every pull request" grep -Fxq '  pull_request:' "$lint"
yes "app.yml: a newer run replaces an older one" grep -Fxq '  cancel-in-progress: true' "$app"
yes "app.yml: one group per branch or PR, manual runs alone" grep -Fxq '  group: app-${{ github.event_name == '"'workflow_dispatch'"' && github.run_id || github.ref }}' "$app"

build=$(job build)
checks=$(job checks)
gate_job=$(job gate)
scope_job=$(job scope)
yes "build job name" has "    name: full app build" "$build"
yes "checks job name" has "    name: source checks" "$checks"
yes "gate job name" has "    name: app gate" "$gate_job"
eq "ci-run-passed.sh knows the build job" "full app build" "$(sed -n 's/^build_job=\${BRIDGEPLAY_CI_BUILD_JOB:-\(.*\)}$/\1/p' "$root/scripts/ci-run-passed.sh")"
eq "ci-run-passed.sh knows the checks job" "source checks" "$(sed -n 's/^checks_job=\${BRIDGEPLAY_CI_CHECKS_JOB:-\(.*\)}$/\1/p' "$root/scripts/ci-run-passed.sh")"
for j in build checks; do
	body=$(job "$j")
	yes "$j: waits for scope" has "    needs: scope" "$body"
	yes "$j: skipped for docs-only" has "    if: needs.scope.outputs.docs_only != 'true'" "$body"
done
yes "gate: waits for every job" has "    needs: [scope, build, checks]" "$gate_job"
yes "gate: runs whatever the others did" has "    if: always()" "$gate_job"
yes "gate: on a Linux runner" has "    runs-on: ubuntu-latest" "$gate_job"
yes "gate: runs the verdict script" has "        run: sh scripts/ci-gate.sh" "$gate_job"
for v in 'SCOPE_RESULT: ${{ needs.scope.result }}' 'DOCS_ONLY: ${{ needs.scope.outputs.docs_only }}' \
	'BUILD_RESULT: ${{ needs.build.result }}' 'CHECKS_RESULT: ${{ needs.checks.result }}'; do
	yes "gate input $v" has "          $v" "$gate_job"
done
yes "scope: on a Linux runner" has "    runs-on: ubuntu-latest" "$scope_job"
yes "scope: sees the merge commit's parents" has "          fetch-depth: 2" "$scope_job"
yes "scope: runs the scope script into the job output" has '        run: sh scripts/ci-scope.sh | tee -a "$GITHUB_OUTPUT"' "$scope_job"
yes "scope: output is docs_only" has '      docs_only: ${{ steps.scope.outputs.docs_only }}' "$scope_job"
yes "build-local.sh reuses runs through ci-run-passed.sh" grep -q 'ci-run-passed.sh' "$root/scripts/build-local.sh"

# bridge-key.sh: the outputs build-local.sh and worktree-seed.sh reuse are the ones CI's bridge cache saves
ci_bridge=$(sed -n '/^          key: bridge-/q;/^          path: |$/,$p' "$app" | sed -n 's/^            \(scratch\/.*\)$/\1/p' | sort)
eq "bridge-key.sh --outputs = app.yml bridge cache" "$ci_bridge" "$(sh "$root/scripts/bridge-key.sh" --outputs | sort)"
yes "bridge key is a 16-digit hash" sh -c '[ "$(sh "$1/scripts/bridge-key.sh" | tr -d 0-9a-f)" = "" ] && [ "$(sh "$1/scripts/bridge-key.sh" | wc -c)" -eq 17 ]' _ "$root"

echo "cicheck: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
