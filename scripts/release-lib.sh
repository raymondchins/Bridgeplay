# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154 # the gate_* results are read, and slug, sparkle and key_args set, by the caller
# Shared by the release modes of scripts/release-local.sh. Source it after scripts/ledger-lib.sh,
# from the repository root; don't run it. See docs/RELEASING.md.
#
# The caller sets: slug (owner/repo), remote and remote_url (release_remote sets them), sparkle
# (the Sparkle bin folder) and key_args (empty, or `--ed-key-file FILE`).

SPARKLE_NS=http://www.andymatuschak.org/xml-namespaces/sparkle
# F0.7: the betas a stable contains, on every stable item.
BRIDGEPLAY_NS=https://bridgeplay.dev/ns/appcast/1

# release_remote: sets remote and remote_url to the remote whose URL is github.com/$slug, or
# BRIDGEPLAY_LEDGER_REMOTE_URL exactly (tests). Never by name.
release_remote() {
	_want=$(printf '%s' "${BRIDGEPLAY_LEDGER_REMOTE_URL:-}" | tr '[:upper:]' '[:lower:]')
	_lslug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	for _r in $(git remote); do
		_url=$(git remote get-url "$_r" | tr '[:upper:]' '[:lower:]')
		if [ -n "$_want" ]; then
			[ "$_url" = "$_want" ] || continue
		else
			case $_url in
				*github.com[:/]"$_lslug"|*github.com[:/]"$_lslug".git|*github.com[:/]"$_lslug"/) ;;
				*) continue ;;
			esac
		fi
		remote=$_r
		remote_url=$(git remote get-url "$_r")
		return 0
	done
	return 1
}

# --- the local lock, one for every release mode ------------------------------------------

release_lock_dir=""
# release_lock: takes the lock all release modes share in this clone (worktrees included).
# A lock whose process is gone is taken over. Returns 1, saying who holds it, otherwise.
release_lock() {
	_dir=$(git rev-parse --git-common-dir) || return 1
	_lock=$(cd "$_dir" && pwd)/bridgeplay-release.lock
	if ! mkdir "$_lock" 2>/dev/null; then
		_pid=$(cat "$_lock/pid" 2>/dev/null || true)
		if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
			echo "==> another release (pid $_pid) holds $_lock; wait for it to finish" >&2
			return 1
		fi
		echo "==> taking over $_lock from a release that is gone (pid ${_pid:-unknown})" >&2
		rm -rf "$_lock"
		mkdir "$_lock" 2>/dev/null || { echo "==> another release took $_lock just now" >&2; return 1; }
	fi
	echo "$$" >"$_lock/pid"
	release_lock_dir=$_lock
}
release_unlock() {
	[ -z "$release_lock_dir" ] || rm -rf "$release_lock_dir"
	release_lock_dir=""
}

# --- tags, betas and trees -----------------------------------------------------------------

release_refs=""
# release_tag_commit TAG: the commit TAG points at on the remote, fetched so it is here too.
# Returns 1 if the remote has no such tag, 2 if it can't be read or fetched.
release_tag_commit() {
	if [ -z "$release_refs" ]; then
		release_refs=$(git ls-remote --tags "$remote" 2>/dev/null) || { release_refs=""; return 2; }
		[ -n "$release_refs" ] || release_refs=" "
	fi
	_sha=$(printf '%s\n' "$release_refs" | awk -v t="refs/tags/$1" '$2 == t { c = $1 } $2 == t "^{}" { p = $1 } END { print (p != "" ? p : c) }')
	[ -n "$_sha" ] || return 1
	if ! git cat-file -e "$_sha^{commit}" 2>/dev/null; then
		git fetch -q --no-tags "$remote" "refs/tags/$1" 2>/dev/null || return 2
		git cat-file -e "$_sha^{commit}" 2>/dev/null || return 2
	fi
	printf '%s\n' "$_sha"
}

# release_published_betas FILE: writes `build tag commit source-branch` for every published
# (not draft) vX.Y.Z-beta.N release, by build. The ledger names the build, commit and branch;
# the tag must point at that commit. Fails closed: any release, ledger or tag that can't be
# read stops it with a message.
release_published_betas() {
	_tab=$(printf '\t')
	_list=$(gh api --paginate "repos/$slug/releases?per_page=100" --jq '.[]
		| select(.draft | not)
		| select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-beta\\.[0-9]+$"))
		| [.tag_name, (if (.body // "") == "" then "-" else (.body | @base64) end)] | @tsv' 2>&1) \
		|| { echo "==> can't read the releases of $slug: $_list" >&2; return 1; }
	: >"$1.tmp"
	while IFS=$_tab read -r _tag _body64; do
		[ -n "$_tag" ] || continue
		_body=""
		[ "$_body64" = "-" ] || _body=$(printf '%s' "$_body64" | base64 -d 2>/dev/null) \
			|| { echo "==> can't decode the body of $_tag" >&2; return 1; }
		_kind=$(printf '%s\n' "$_body" | ledger_field kind) || _kind=""
		_build=$(printf '%s\n' "$_body" | ledger_field build) || _build=""
		_commit=$(printf '%s\n' "$_body" | ledger_field commit) || _commit=""
		_branch=$(printf '%s\n' "$_body" | ledger_field source-branch) || _branch=""
		if [ "$_kind" != beta ] || ! ledger_posint "$_build" || [ -z "$_branch" ] \
			|| ! printf '%s\n' "$_commit" | grep -Eqx '[0-9a-f]{40}'; then
			echo "==> beta release $_tag has no complete v1 ledger (kind beta, build, commit, source-branch); can't tell what it contains" >&2
			return 1
		fi
		_rc=0
		_at=$(release_tag_commit "$_tag") || _rc=$?
		case $_rc in
			0) ;;
			1) echo "==> beta release $_tag has no tag $_tag on $remote ($remote_url)" >&2; return 1 ;;
			*) echo "==> can't read or fetch tag $_tag from $remote ($remote_url)" >&2; return 1 ;;
		esac
		[ "$_at" = "$_commit" ] \
			|| { echo "==> tag $_tag is at $_at but its ledger says $_commit; fix the release before releasing" >&2; return 1; }
		printf '%s %s %s %s\n' "$_build" "$_tag" "$_commit" "$_branch" >>"$1.tmp"
	done <<EOF
$_list
EOF
	sort -n "$1.tmp" >"$1"
	rm -f "$1.tmp"
}

# release_ranges: beta builds, one per line, on stdin; prints them ascending with runs folded
# into inclusive ranges (81-85,87). Nothing for none.
release_ranges() {
	sort -n -u | awk '
	function flush() { out = out sep (s == e ? s : s "-" e); sep = "," }
	NF == 0 { next }
	!started { s = e = $1; started = 1; next }
	$1 == e + 1 { e = $1; next }
	{ flush(); s = e = $1 }
	END { if (started) flush(); print out }'
}

# release_tree_diff A B: the paths whose content differs between commits A and B, apart from
# the BRIDGEPLAY_VERSION and BRIDGEPLAY_BUILD lines of dylib/version.h (the version header a
# stable bump changes).
release_tree_diff() {
	_paths=$(git -c core.quotePath=false diff --no-renames --name-only "$1" "$2" --) || return 1
	_re='^#define BRIDGEPLAY_(VERSION|BUILD) '
	printf '%s\n' "$_paths" | while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		if [ "$_p" = dylib/version.h ] \
			&& [ "$(git show "$1:$_p" 2>/dev/null | grep -Ev "$_re")" = "$(git show "$2:$_p" 2>/dev/null | grep -Ev "$_re")" ]; then
			continue
		fi
		printf '%s\n' "$_p"
	done
}

# release_gate HEAD PREVIOUS BETAS: decides what the stable at commit HEAD is (R4). PREVIOUS is
# the previous stable's commit, empty for none; BETAS is release_published_betas' file. Sets:
#   gate_contains   the builds of every published beta HEAD contains, as release_ranges prints
#   gate_promoted   the beta tag this stable ships the tree of, or none (a hotfix or plain stable)
#   gate_data       compat/** paths that differ from that beta's tree, one per line
# Returns 1 with the reason on stderr when the stable must not ship.
release_gate() {
	gate_contains=""
	gate_promoted=none
	gate_data=""
	_contained=""
	_new=""
	_others=""
	while read -r _b _t _c _s; do
		[ -n "$_b" ] || continue
		if git merge-base --is-ancestor "$_c" "$1" 2>/dev/null; then
			_contained="$_contained$_b
"
			if [ -z "$2" ] || ! git merge-base --is-ancestor "$_c" "$2" 2>/dev/null; then
				_new="$_b $_t $_c $_s"
			fi
		else
			_others="$_others$_b $_t $_c $_s
"
		fi
	done <"$3"
	gate_contains=$(printf '%s' "$_contained" | release_ranges)

	if [ -z "$_new" ]; then
		# A hotfix or plain stable, unless it ships a beta's tree without containing it.
		_lost=$(printf '%s' "$_others" | while read -r _b _t _c _s; do
			[ -n "$_b" ] || continue
			_d=$(release_tree_diff "$_c" "$1") || continue
			printf '%s\n' "$_d" | grep -q -v -e '^compat/' -e '^$' || echo "$_t"
		done)
		if [ -n "$_lost" ]; then
			echo "==> HEAD ships the tree of beta $(echo "$_lost" | tr '\n' ' ')but does not contain its commit," >&2
			echo "    so the release branch reached main squashed or rebased. A stable must contain the" >&2
			echo "    beta it promotes: merge the release branch into main with a merge commit (no squash," >&2
			echo "    no rebase), then bump and release again." >&2
			return 1
		fi
		return 0
	fi

	# A promotion: the newest new beta (the last one read, by build) is the one it ships.
	# shellcheck disable=SC2086 # build, tag, commit and branch: one word each
	set -- "$1" $_new
	_tag=$3
	_commit=$4
	_branch=$5
	case $_branch in
		release/?*) ;;
		*)
			echo "==> HEAD promotes beta $_tag (build $2), which was built from $_branch, not a release/*" >&2
			echo "    branch. Cut release/x.y.z from develop, publish a release-candidate beta from it," >&2
			echo "    merge that branch into main and release again." >&2
			return 1
			;;
	esac
	_diff=$(release_tree_diff "$_commit" "$1") \
		|| { echo "==> can't compare HEAD with beta $_tag ($_commit)" >&2; return 1; }
	_other=$(printf '%s\n' "$_diff" | grep -v '^compat/' || true)
	if [ -n "$_other" ]; then
		echo "==> HEAD differs from beta $_tag, the release candidate it promotes, outside the version" >&2
		echo "    header, so this stable would ship code no beta tested:" >&2
		printf '%s\n' "$_other" | sed 's/^/      /' >&2
		echo "    Merge main into $_branch, publish a new release-candidate beta from it, merge" >&2
		echo "    $_branch into main and release again." >&2
		return 1
	fi
	gate_promoted=$_tag
	gate_data=$(printf '%s\n' "$_diff" | grep '^compat/' || true)
}

# --- the stable feed -----------------------------------------------------------------------

# xp FILE XPATH: an XPath value of FILE; empty when it has none.
xp() { xmllint --xpath "$2" "$1" 2>/dev/null || true; }

# feed_add_contains FILE LIST: declares the bridgeplay namespace and adds
# <bridgeplay:containsBetas>LIST</bridgeplay:containsBetas> to the feed's one item.
feed_add_contains() {
	[ "$(xp "$1" "count(//*[local-name()='item'])")" = 1 ] || { echo "==> $1 does not have exactly one item" >&2; return 1; }
	_last=$(grep -n '^[[:space:]]*</item>[[:space:]]*$' "$1" | tail -n 1 | cut -d: -f1)
	[ -n "$_last" ] || { echo "==> $1 has no </item> line" >&2; return 1; }
	awk -v last="$_last" -v list="$2" -v ns="$BRIDGEPLAY_NS" '
	!done_ns && /^<rss / { sub(/^<rss /, "<rss xmlns:bridgeplay=\"" ns "\" "); done_ns = 1 }
	NR == last {
		indent = $0; sub(/<.*/, "", indent)
		print indent "    <bridgeplay:containsBetas>" list "</bridgeplay:containsBetas>"
	}
	{ print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
	[ "$(xp "$1" "string(//*[local-name()='item']/*[local-name()='containsBetas' and namespace-uri()='$BRIDGEPLAY_NS'])")" = "$2" ] \
		&& [ "$(xp "$1" "count(//*[local-name()='containsBetas'])")" = 1 ] \
		|| { echo "==> could not add the containsBetas element to $1" >&2; return 1; }
}

# feed_guard FILE VERSION BUILD URL MIN_MACOS [ZIP]: I-6. The stable feed must have exactly one
# item, no sparkle:channel anywhere, a plain X.Y.Z short version equal to VERSION, build BUILD,
# its enclosure at URL with an EdDSA signature (checked against ZIP when given), the minimum
# macOS, one containsBetas element and a valid feed signature. Prints every failure; returns 1
# if there is any.
feed_guard() {
	_f=$1
	_bad=0
	_no() { echo "==> I-6: $_f $*" >&2; _bad=1; }
	if ! xmllint --noout "$_f" 2>/dev/null; then
		_no "is not well-formed XML"
		return 1
	fi
	_item="//*[local-name()='item']"
	_sp() { printf "%s/*[local-name()='%s' and namespace-uri()='%s']" "$_item" "$1" "$SPARKLE_NS"; }
	_n=$(xp "$_f" "count($_item)")
	[ "$_n" = 1 ] || _no "has $_n items, not exactly one"
	_n=$(xp "$_f" "count(//*[local-name()='channel' and namespace-uri()='$SPARKLE_NS'])")
	[ "$_n" = 0 ] || _no "has $_n sparkle:channel elements; the stable feed carries none"
	_v=$(xp "$_f" "string($(_sp shortVersionString))")
	if ! printf '%s\n' "$_v" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+'; then
		_no "has short version '$_v', not a plain X.Y.Z"
	elif [ "$_v" != "$2" ]; then
		_no "has short version $_v, not $2"
	fi
	_v=$(xp "$_f" "string($(_sp version))")
	[ "$_v" = "$3" ] || _no "carries build '$_v', not $3"
	_enc="$_item/*[local-name()='enclosure']"
	_n=$(xp "$_f" "count($_enc)")
	[ "$_n" = 1 ] || _no "has $_n enclosures, not one"
	_v=$(xp "$_f" "string($_enc/@url)")
	[ "$_v" = "$4" ] || _no "points at '$_v', not $4"
	_sig=$(xp "$_f" "string($_enc/@*[local-name()='edSignature' and namespace-uri()='$SPARKLE_NS'])")
	if [ -z "$_sig" ]; then
		_no "has no enclosure signature (sparkle:edSignature)"
	elif [ -n "${6:-}" ]; then
		# shellcheck disable=SC2086 # key_args is empty or two words
		"$sparkle/sign_update" --verify $key_args "$6" "$_sig" >/dev/null 2>&1 \
			|| _no "has an enclosure signature that does not match $(basename "$6")"
		_len=$(xp "$_f" "string($_enc/@length)")
		[ "$_len" = "$(wc -c <"$6" | tr -d ' ')" ] || _no "gives length '$_len', not the size of $(basename "$6")"
	fi
	_v=$(xp "$_f" "string($(_sp minimumSystemVersion))")
	[ "$_v" = "$5" ] || _no "asks for macOS '$_v', not $5"
	_n=$(xp "$_f" "count(//*[local-name()='containsBetas' and namespace-uri()='$BRIDGEPLAY_NS'])")
	if [ "$_n" != 1 ]; then
		_no "has $_n containsBetas elements, not one"
	else
		_v=$(xp "$_f" "string($_item/*[local-name()='containsBetas' and namespace-uri()='$BRIDGEPLAY_NS'])")
		printf '%s\n' "$_v" | grep -Eqx '([0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)?' \
			|| _no "has containsBetas '$_v', not a list like 81-85,87"
	fi
	if ! grep -q 'sparkle-signatures:' "$_f"; then
		_no "is not signed (no sparkle-signatures block)"
	else
		# shellcheck disable=SC2086 # key_args is empty or two words
		"$sparkle/sign_update" --verify $key_args "$_f" >/dev/null 2>&1 \
			|| _no "has a feed signature that does not verify; it changed after signing or another key signed it"
	fi
	return "$_bad"
}
