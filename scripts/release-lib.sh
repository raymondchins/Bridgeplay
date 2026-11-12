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
		# No pid yet: its holder may be between the mkdir and writing it. Only a lock that has
		# stayed without one for a minute is taken as abandoned.
		if [ -z "$_pid" ] && [ -z "$(find "$_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
			echo "==> another release is taking $_lock; wait for it to finish" >&2
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
	# One ls-remote for the whole loop (release_tag_commit runs in subshells, so it can't keep its
	# own); cleared after it, since later lookups may be of tags this run creates.
	if _refs=$(git ls-remote --tags "$remote" 2>/dev/null); then release_refs=${_refs:- }; fi
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
	release_refs=""
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

# release_gate HEAD PREVIOUS BETAS [BUILD]: decides what the stable at commit HEAD is (R4). PREVIOUS
# is the previous stable's commit, empty for none; BETAS is release_published_betas' file; BUILD,
# the stable's build, must be above every beta it contains. Sets:
#   gate_contains   the builds of every published beta HEAD contains, as release_ranges prints
#   gate_promoted   the beta tag this stable ships the tree of, or none (a hotfix or plain stable)
#   gate_data       compat/** paths that differ from that beta's tree, one per line
# Returns 1 with the reason on stderr when the stable must not ship.
release_gate() {
	gate_contains=""
	gate_promoted=none
	gate_data=""
	_max=0
	_contained=""
	_new=""
	_others=""
	while read -r _b _t _c _s; do
		[ -n "$_b" ] || continue
		if git merge-base --is-ancestor "$_c" "$1" 2>/dev/null; then
			_contained="$_contained$_b
"
			[ "$_b" -le "$_max" ] || _max=$_b
			if [ -z "$2" ] || ! git merge-base --is-ancestor "$_c" "$2" 2>/dev/null; then
				_new="$_b $_t $_c $_s"
			fi
		else
			_others="$_others$_b $_t $_c $_s
"
		fi
	done <"$3"
	gate_contains=$(printf '%s' "$_contained" | release_ranges)
	# A beta app takes only a higher build, so a lower one would never reach its testers.
	_low=0
	if [ -n "${4:-}" ] && [ "$4" -le "$_max" ]; then
		echo "==> build $4 is not above build $_max, a beta this stable contains, so that beta's testers would never" >&2
		echo "    get it; run scripts/bump-version.sh build, commit, push and release again." >&2
		_low=1
	fi

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
		return "$_low"
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
		echo "    $_branch into main, run scripts/bump-version.sh build, commit, push and release again." >&2
		return 1
	fi
	gate_promoted=$_tag
	gate_data=$(printf '%s\n' "$_diff" | grep '^compat/' || true)
	return "$_low"
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
		is_build_list "$_v" \
			|| _no "has containsBetas '$_v', not a list like 81-85,87"
	fi
	_p=$(feed_signature_problem "$_f")
	[ -z "$_p" ] || _no "$_p"
	return "$_bad"
}

# --- the beta feed (F0.5) ----------------------------------------------------------------

# The fixed prerelease that carries the beta feed, and the line --withdraw puts at the top of a
# beta's release body (outside the ledger) to keep it off that feed.
BETA_FEED_TAG=beta-feed
WITHDRAWN_LINE='Withdrawn from the beta feed:'

is_stable_tag() { printf '%s\n' "$1" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+'; }
is_beta_tag() { printf '%s\n' "$1" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]*'; }
# is_build_list TEXT: beta builds as release_ranges prints them (81-85,87), or empty.
is_build_list() { printf '%s\n' "$1" | grep -Eqx '([0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)?'; }

# feed_signature_problem FILE: what is wrong with FILE's feed signature, or nothing.
feed_signature_problem() {
	grep -q 'sparkle-signatures:' "$1" || { echo "is not signed (no sparkle-signatures block)"; return 0; }
	# shellcheck disable=SC2086 # key_args is empty or two words
	"$sparkle/sign_update" --verify $key_args "$1" >/dev/null 2>&1 \
		|| echo "has a feed signature that does not verify; it changed after signing or another key signed it"
}

# release_list FILE: every release of $slug, drafts included, one per line, tab-separated: tag,
# draft, prerelease, published_at, Bridgeplay.zip's digest and size, the asset names joined
# with commas, and the body in base64. "-" stands for none.
release_list() {
	# shellcheck disable=SC2016 # $z is jq's
	gh api --paginate "repos/$slug/releases?per_page=100" --jq '.[]
		| ((.assets // []) | map(select(.name == "Bridgeplay.zip")) | .[0]) as $z
		| [.tag_name, (.draft | tostring), (.prerelease | tostring), (.published_at // "-"),
			($z.digest // "-"), (($z.size // "-") | tostring),
			((.assets // []) | map(.name) | join(",") | if . == "" then "-" else . end),
			(if (.body // "") == "" then "-" else (.body | @base64) end)] | @tsv' >"$1" 2>"$1.err" \
		|| { echo "==> can't read the releases of $slug: $(cat "$1.err")" >&2; rm -f "$1.err"; return 1; }
	rm -f "$1.err"
}

# b64_body: a base64 body (or "-") on stdin; prints it decoded.
b64_body() {
	_b=$(cat)
	[ "$_b" = "-" ] || printf '%s' "$_b" | base64 -d
}

# release_notes: a release body on stdin; prints its human notes, the lines before the
# `Build N, based on NotProton X.` line or the ledger, without a withdrawal line or trailing
# blank lines.
release_notes() {
	awk -v w="$WITHDRAWN_LINE" '
	{ sub(/\r$/, "") }
	/^Build [0-9]+, based on NotProton / || /^<!-- bridgeplay-ledger/ { exit }
	index($0, w) == 1 { next }
	{ lines[++n] = $0; if ($0 !~ /^[ \t]*$/) last = n }
	END { for (i = 1; i <= last; i++) print lines[i] }'
}

# is_withdrawn: a release body on stdin; true when --withdraw marked it.
is_withdrawn() {
	awk -v w="$WITHDRAWN_LINE" '/^<!-- bridgeplay-ledger/ { exit } index($0, w) == 1 { found = 1 } END { exit !found }'
}

# feed_record KIND BUILD LABEL TAG CHANNEL LENGTH SIGNATURE CONTAINS PUBLISHED NOTES: one item of
# the beta feed as a tab-separated line, "-" for an empty field, the notes in base64.
feed_record() {
	_notes=-
	[ -z "${10}" ] || _notes=$(printf '%s\n' "${10}" | base64 | tr -d '\n')
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:--}" "$6" "$7" \
		"${8:--}" "${9:--}" "$_notes"
}

# release_record TAG PUBLISHED DIGEST SIZE BODY64: the feed record of a published release, from
# its ledger. Its Bridgeplay.zip must be the one the ledger records. Returns 1 with the reason
# on stderr; 2 when the body has no ledger at all.
release_record() {
	_body=$(printf '%s' "$5" | b64_body) || { echo "==> can't decode the body of $1" >&2; return 1; }
	_rc=0
	printf '%s\n' "$_body" | ledger_lines >/dev/null 2>&1 || _rc=$?
	case $_rc in
		0) ;;
		1) return 2 ;;
		*) echo "==> $1 has a malformed or unknown ledger block" >&2; return 1 ;;
	esac
	_rf() { printf '%s\n' "$_body" | ledger_field "$1" 2>/dev/null || true; }
	_kind=$(_rf kind)
	_build=$(_rf build)
	_label=$(_rf label)
	_len=$(_rf zip-length)
	_sig=$(_rf ed-signature)
	_channel=-
	_contains=-
	if is_beta_tag "$1"; then
		[ "$_kind" = beta ] || { echo "==> $1's ledger says kind '$_kind', not beta" >&2; return 1; }
		_channel=$(_rf channel)
		case $_channel in
			beta|beta-critical) ;;
			*) echo "==> $1's ledger has channel '$_channel', not beta or beta-critical" >&2; return 1 ;;
		esac
	else
		[ "$_kind" = stable ] || { echo "==> $1's ledger says kind '$_kind', not stable" >&2; return 1; }
		_contains=$(_rf contains-betas)
		[ "$_contains" != none ] || _contains=""
		is_build_list "$_contains" \
			|| { echo "==> $1's ledger has contains-betas '$_contains', not a list like 81-85,87" >&2; return 1; }
	fi
	[ "$(_rf tag)" = "$1" ] && [ "v$_label" = "$1" ] \
		|| { echo "==> $1's ledger names tag '$(_rf tag)' and label '$_label'" >&2; return 1; }
	if ! ledger_posint "$_build" || ! ledger_posint "$_len"; then
		echo "==> $1's ledger has no build or zip-length" >&2
		return 1
	fi
	case $_sig in
		''|unsigned) echo "==> $1's ledger has no ed-signature" >&2; return 1 ;;
	esac
	[ "$3" = "sha256:$(_rf zip-sha256)" ] && [ "$4" = "$_len" ] \
		|| { echo "==> $1's Bridgeplay.zip ($3, $4 bytes) is not the one its ledger records" >&2; return 1; }
	feed_record "$_kind" "$_build" "$_label" "$1" "$_channel" "$_len" "$_sig" "$_contains" "$2" \
		"$(printf '%s\n' "$_body" | release_notes)"
}

# appcast_record TAG PUBLISHED: the feed record of a stable released before the ledger, from
# the item of its own appcast.xml. Such a stable lists no betas.
appcast_record() {
	_d=$(mktemp -d "${TMPDIR:-/tmp}/bridgeplay-appcast.XXXXXX")
	if ! gh release download "$1" -R "$slug" -p appcast.xml -D "$_d" --clobber >/dev/null 2>&1; then
		rm -rf "$_d"
		echo "==> $1 has no ledger and its appcast.xml can't be read" >&2
		return 1
	fi
	_f=$_d/appcast.xml
	_i="(//*[local-name()='item'])[1]"
	_enc="$_i/*[local-name()='enclosure']"
	_build=$(xp "$_f" "string($_i/*[local-name()='version'])")
	_label=$(xp "$_f" "string($_i/*[local-name()='shortVersionString'])")
	_len=$(xp "$_f" "string($_enc/@length)")
	_sig=$(xp "$_f" "string($_enc/@*[local-name()='edSignature'])")
	rm -rf "$_d"
	if ! ledger_posint "$_build" || ! ledger_posint "$_len" || [ -z "$_sig" ] || [ "v$_label" != "$1" ]; then
		echo "==> $1 has no ledger and its appcast.xml has no complete item for it" >&2
		return 1
	fi
	feed_record stable "$_build" "$_label" "$1" - "$_len" "$_sig" - "$2" ""
}

# release_newest_stable LIST: the tag of the newest stable, the vX.Y.Z release marked Latest. If
# Latest is not one (the stable feed is down), the published vX.Y.Z with the highest build.
release_newest_stable() {
	_latest=$(gh release view -R "$slug" --json tagName -q .tagName 2>/dev/null || true)
	if is_stable_tag "$_latest" && awk -F '\t' -v t="$_latest" '$1 == t && $2 == "false" { ok = 1 } END { exit !ok }' "$1"; then
		printf '%s\n' "$_latest"
		return 0
	fi
	_best=0
	_tag=""
	_tab=$(printf '\t')
	while IFS=$_tab read -r _t _draft _pre _pub _dig _size _names _b64; do
		is_stable_tag "$_t" && [ "$_draft" = false ] && [ "$_pre" = false ] || continue
		_body=$(printf '%s' "$_b64" | b64_body) || continue
		_n=$(printf '%s\n' "$_body" | ledger_field build 2>/dev/null) \
			|| _n=$(printf '%s\n' "$_body" | legacy_build) || continue
		if [ "$_n" -gt "$_best" ]; then _best=$_n; _tag=$_t; fi
	done <"$1"
	[ -n "$_tag" ] || { echo "==> no published vX.Y.Z stable to head the beta feed" >&2; return 1; }
	echo "==> warning: the Latest release '${_latest:-none}' is not a vX.Y.Z stable; the beta feed uses $_tag" >&2
	printf '%s\n' "$_tag"
}

# beta_feed_items LIST STABLE WITHDRAW OUT [EXTRA]: the items of the beta feed into OUT, as
# feed records: the newest stable (the release tagged STABLE), the newest beta above it, and the
# newest beta-critical above it unless that is the newest beta. LIST is release_list's file.
# Betas withdrawn on GitHub or named in WITHDRAW (space-separated tags) are left out. EXTRA is a
# file of records not published yet (a dry run's); a stable in it stands for the newest stable.
# Fails closed: a beta whose ledger can't be read, or a candidate whose zip doesn't match it.
beta_feed_items() {
	_tab=$(printf '\t')
	_stable=""
	if [ -n "${5:-}" ]; then
		_stable=$(awk -F '\t' '$1 == "stable"' "$5" | head -n 1)
	fi
	: >"$4.betas"
	while IFS=$_tab read -r _t _draft _pre _pub _dig _size _names _b64; do
		[ "$_draft" = false ] || continue
		if is_beta_tag "$_t"; then
			_body=$(printf '%s' "$_b64" | b64_body) || { echo "==> can't decode the body of $_t" >&2; return 1; }
			_n=$(printf '%s\n' "$_body" | ledger_field build 2>/dev/null) || _n=""
			ledger_posint "$_n" || { echo "==> beta $_t has no readable v1 ledger, so its build is unknown" >&2; return 1; }
			case " $3 " in *" $_t "*) continue ;; esac
			! printf '%s\n' "$_body" | is_withdrawn || continue
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_n" "$_t" "$_pub" "$_dig" "$_size" "$_b64" >>"$4.betas"
		elif [ -z "$_stable" ] && [ "$_t" = "$2" ]; then
			_rc=0
			_stable=$(release_record "$_t" "$_pub" "$_dig" "$_size" "$_b64") || _rc=$?
			case $_rc in
				0) ;;
				2) _stable=$(appcast_record "$_t" "$_pub") || return 1 ;;
				*) return 1 ;;
			esac
		fi
	done <"$1"
	[ -n "$_stable" ] || { echo "==> the newest stable $2 is not a published release" >&2; return 1; }
	_sbuild=$(printf '%s\n' "$_stable" | cut -f2)
	printf '%s\n' "$_stable" >"$4"
	# Every beta above the stable is a candidate: its record must check out.
	: >"$4.cand"
	while IFS=$_tab read -r _n _t _pub _dig _size _b64; do
		[ "$_n" -gt "$_sbuild" ] || continue
		release_record "$_t" "$_pub" "$_dig" "$_size" "$_b64" >>"$4.cand" || return 1
	done <"$4.betas"
	[ -z "${5:-}" ] || awk -F '\t' -v s="$_sbuild" '$1 == "beta" && $2 > s + 0' "$5" >>"$4.cand"
	_dup=$(cut -f2 "$4.cand" | sort | uniq -d | tr '\n' ' ')
	[ -z "$_dup" ] || { echo "==> more than one beta records build $_dup" >&2; return 1; }
	# The newest beta, then the newest beta-critical unless the newest beta is one.
	sort -t "$_tab" -k2,2nr "$4.cand" | awk -F '\t' '
		NR == 1 { print; if ($5 == "beta-critical") exit; next }
		$5 == "beta-critical" { print; exit }' >>"$4"
	rm -f "$4.betas" "$4.cand"
}

# rfc822 ISO: GitHub's published_at as a feed pubDate; nothing if it can't be read.
rfc822() {
	LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%a, %d %b %Y %H:%M:%S +0000' 2>/dev/null || true
}

# beta_feed_render ITEMS OUT MIN_MACOS: writes the beta feed from beta_feed_items' records,
# newest build first, unsigned. Stable items carry no channel and a containsBetas element.
beta_feed_render() {
	_tab=$(printf '\t')
	{
		echo '<?xml version="1.0" standalone="yes"?>'
		echo "<rss xmlns:bridgeplay=\"$BRIDGEPLAY_NS\" xmlns:sparkle=\"$SPARKLE_NS\" version=\"2.0\">"
		echo '    <channel>'
		echo '        <title>Bridgeplay beta</title>'
		sort -t "$_tab" -k2,2nr "$1" | while IFS=$_tab read -r _kind _build _label _tag _channel _len _sig _contains _pub _notes; do
			echo '        <item>'
			echo "            <title>$_label</title>"
			_date=""
			[ "$_pub" = "-" ] || _date=$(rfc822 "$_pub")
			[ -z "$_date" ] || echo "            <pubDate>$_date</pubDate>"
			echo "            <sparkle:version>$_build</sparkle:version>"
			echo "            <sparkle:shortVersionString>$_label</sparkle:shortVersionString>"
			echo "            <sparkle:minimumSystemVersion>$3</sparkle:minimumSystemVersion>"
			[ "$_channel" = "-" ] || echo "            <sparkle:channel>$_channel</sparkle:channel>"
			if [ "$_notes" != "-" ]; then
				# CDATA can't hold "]]>": split it across two sections, as generate_appcast does.
				printf '            <description sparkle:format="plain-text"><![CDATA[%s\n]]></description>\n' \
					"$(printf '%s' "$_notes" | base64 -d | sed 's/]]>/]]]]><![CDATA[>/g')"
			fi
			echo "            <enclosure url=\"https://github.com/$slug/releases/download/$_tag/Bridgeplay.zip\" length=\"$_len\" type=\"application/octet-stream\" sparkle:edSignature=\"$_sig\"/>"
			if [ "$_kind" = stable ]; then
				[ "$_contains" != "-" ] || _contains=""
				echo "            <bridgeplay:containsBetas>$_contains</bridgeplay:containsBetas>"
			fi
			echo '        </item>'
		done
		echo '    </channel>'
		echo '</rss>'
	} >"$2"
}

# beta_feed_guard FILE MIN_MACOS [BUILD]: the beta feed is well formed, declares the bridgeplay
# prefix, and has one to three items: one stable (no channel, a plain X.Y.Z, one containsBetas
# spelled bridgeplay:containsBetas), and at most one item per channel, beta or beta-critical,
# each an X.Y.Z-beta.N above the stable. Every item asks for MIN_MACOS and has one signed
# enclosure on its own tag. BUILD, when given, must be one of the items. The feed signature must
# verify. Prints every failure; returns 1 if there is any.
beta_feed_guard() {
	_f=$1
	_bad=0
	_no() { echo "==> beta feed: $_f $*" >&2; _bad=1; }
	if ! xmllint --noout "$_f" 2>/dev/null; then
		_no "is not well-formed XML"
		return 1
	fi
	grep -q "<rss [^>]*xmlns:bridgeplay=\"$BRIDGEPLAY_NS\"" "$_f" \
		|| _no "does not declare xmlns:bridgeplay=\"$BRIDGEPLAY_NS\""
	_n=$(xp "$_f" "count(//*[local-name()='item'])")
	case $_n in 1|2|3) ;; *) _no "has $_n items, not one to three" ;; esac
	_ch="*[local-name()='channel' and namespace-uri()='$SPARKLE_NS']"
	_cb="*[local-name()='containsBetas' and namespace-uri()='$BRIDGEPLAY_NS']"
	_k=$(xp "$_f" "count(//*[local-name()='item'][not($_ch)])")
	[ "$_k" = 1 ] || _no "has $_k stable items (no sparkle:channel), not one"
	_k=$(xp "$_f" "count(//*[local-name()='containsBetas'])")
	_w=$(grep -c '<bridgeplay:containsBetas>' "$_f" || true)
	[ "$_k" = 1 ] && [ "$_w" = 1 ] || _no "has $_k containsBetas elements ($_w spelled bridgeplay:containsBetas), not one"
	_sbuild=$(xp "$_f" "string(//*[local-name()='item'][not($_ch)]/*[local-name()='version' and namespace-uri()='$SPARKLE_NS'])")
	_seen=" "
	_chans=" "
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_i=$((_i + 1))
		_it="(//*[local-name()='item'])[$_i]"
		_sp() { printf "%s/*[local-name()='%s' and namespace-uri()='%s']" "$_it" "$1" "$SPARKLE_NS"; }
		_v=$(xp "$_f" "string($(_sp version))")
		_sv=$(xp "$_f" "string($(_sp shortVersionString))")
		_c=$(xp "$_f" "string($_it/$_ch)")
		[ "$(xp "$_f" "count($_it/$_ch)")" -le 1 ] || _no "item $_i has more than one sparkle:channel"
		if ! ledger_posint "$_v"; then
			_no "item $_i has build '$_v'"
		else
			case $_seen in *" $_v "*) _no "has build $_v twice" ;; esac
			_seen="$_seen$_v "
		fi
		if [ -z "$_c" ]; then
			is_stable_tag "v$_sv" || _no "has a stable item labelled '$_sv', not a plain X.Y.Z"
			_l=$(xp "$_f" "string($_it/$_cb)")
			if [ "$(xp "$_f" "count($_it/$_cb)")" != 1 ] || ! is_build_list "$_l"; then
				_no "has a stable item whose containsBetas is missing or not a list like 81-85,87"
			fi
		else
			case $_c in
				beta|beta-critical) ;;
				*) _no "item $_i has channel '$_c'" ;;
			esac
			case $_chans in *" $_c "*) _no "has two items on channel $_c" ;; esac
			_chans="$_chans$_c "
			is_beta_tag "v$_sv" || _no "has a $_c item labelled '$_sv', not X.Y.Z-beta.N"
			[ "$(xp "$_f" "count($_it/$_cb)")" = 0 ] || _no "has a $_c item with containsBetas"
			if ledger_posint "$_v" && ledger_posint "$_sbuild" && [ "$_v" -le "$_sbuild" ]; then
				_no "has a $_c item, build $_v, that is not above the stable's build $_sbuild"
			fi
		fi
		[ "$(xp "$_f" "string($(_sp minimumSystemVersion))")" = "$2" ] || _no "item $_i does not ask for macOS $2"
		_enc="$_it/*[local-name()='enclosure']"
		[ "$(xp "$_f" "count($_enc)")" = 1 ] || _no "item $_i does not have one enclosure"
		_u=$(xp "$_f" "string($_enc/@url)")
		[ "$_u" = "https://github.com/$slug/releases/download/v$_sv/Bridgeplay.zip" ] \
			|| _no "item $_i points at '$_u', not v$_sv's Bridgeplay.zip"
		ledger_posint "$(xp "$_f" "string($_enc/@length)")" || _no "item $_i has no enclosure length"
		case $(xp "$_f" "string($_enc/@*[local-name()='edSignature' and namespace-uri()='$SPARKLE_NS'])") in
			''|unsigned) _no "item $_i has no enclosure signature (sparkle:edSignature)" ;;
		esac
	done
	if [ -n "${3:-}" ]; then
		case $_seen in *" $3 "*) ;; *) _no "does not carry build $3" ;; esac
	fi
	_p=$(feed_signature_problem "$_f")
	[ -z "$_p" ] || _no "$_p"
	return "$_bad"
}

# beta_feed_labels FILE: the label of each beta item (one with a sparkle:channel), one per line.
beta_feed_labels() {
	_n=$(xp "$1" "count(//*[local-name()='item'])")
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_i=$((_i + 1))
		_it="(//*[local-name()='item'])[$_i]"
		[ -n "$(xp "$1" "string($_it/*[local-name()='channel'])")" ] || continue
		printf '%s\n' "$(xp "$1" "string($_it/*[local-name()='shortVersionString'])")"
	done
}

# beta_feed_item FILE BUILD ATTR: the enclosure's url, length or edSignature of the item with BUILD.
beta_feed_item() {
	_it="//*[local-name()='item'][*[local-name()='version' and namespace-uri()='$SPARKLE_NS'] = '$2']"
	case $3 in
		edSignature) xp "$1" "string($_it/*[local-name()='enclosure']/@*[local-name()='edSignature'])" ;;
		*) xp "$1" "string($_it/*[local-name()='enclosure']/@$3)" ;;
	esac
}
