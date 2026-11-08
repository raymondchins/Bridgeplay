# shellcheck shell=sh
# The release ledger and build numbers recorded on app releases. Source it, don't run it.
# Used by scripts/build-ledger.sh; release scripts that write a ledger use ledger_render.
#
# Ledger format v1 (frozen). It follows the human notes and the `Build N, based on NotProton X.`
# line of an app release body:
#
#   <!-- bridgeplay-ledger v1
#   kind: beta
#   build: 82
#   ...
#   -->
#
# The first and last lines are exactly as shown. Between them, one `key: value` per line: the key
# is lowercase with dashes, then a colon and one space, then a non-empty value to the end of the
# line. No blank lines, no repeated keys, one block per body, and no value contains `--`.
# Readers ignore keys they don't know. The keys are LEDGER_KEYS; `kind` and `build` are required.
# The publish time is GitHub's own published_at and is not in the block.

LEDGER_KEYS="kind build label tag commit source-branch zip-sha256 zip-length ed-signature"
LEDGER_KEYS="$LEDGER_KEYS channel critical-reason waived-stable waiver-reason promoted-from contains-betas"

# A positive integer of up to nine digits, no sign and no leading zero.
ledger_posint() {
	case $1 in
		''|*[!0-9]*|0*) return 1 ;;
	esac
	[ "${#1}" -le 9 ]
}

# App releases are vX.Y.Z, vX.Y.Z-beta.N and the old-scheme v*. installer, beta-feed,
# fonts-cjk-*, dxmt-* and wine-patch-sources-* are not.
is_app_release_tag() {
	case $1 in
		v[0-9]*) return 0 ;;
	esac
	return 1
}

# ledger_lines: a release body on stdin; prints the v1 block's `key: value` lines.
# Returns 1 with no block, 2 when the block is malformed, 3 when it is not v1.
ledger_lines() {
	awk '
	{ sub(/\r$/, ""); sub(/[ \t]+$/, "") }
	!inb && /^<!-- bridgeplay-ledger([ \t]|$)/ {
		if (seen) bad = 1
		seen = 1
		inb = 1
		if ($0 != "<!-- bridgeplay-ledger v1") other = 1
		next
	}
	inb && $0 == "-->" { inb = 0; next }
	inb {
		if ($0 !~ /^[a-z][a-z0-9-]*: [^ \t]/ || index($0, "--")) { bad = 1; next }
		k = substr($0, 1, index($0, ":") - 1)
		if (k in keys) bad = 1
		keys[k] = 1
		out = out $0 "\n"
	}
	END {
		if (!seen) exit 1
		if (other) exit 3
		if (inb || bad || !("kind" in keys) || !("build" in keys)) exit 2
		printf "%s", out
	}'
}

# ledger_field KEY: a release body on stdin; prints KEY from the v1 block.
# Returns 1 with no block or no such key, 2 malformed, 3 not v1.
ledger_field() {
	_lines=$(ledger_lines) || return
	_value=$(printf '%s\n' "$_lines" | sed -n "s/^$1: //p")
	[ -n "$_value" ] || return 1
	printf '%s\n' "$_value"
}

# legacy_build: a release body on stdin; prints N from the last `Build N, based on NotProton X.`
# line (every release since build 32, old-scheme v3.x included). Returns 1 without one.
legacy_build() {
	_n=$(tr -d '\r' | sed -n 's/^Build \([1-9][0-9]*\), based on NotProton [^ ]*\.[ \t]*$/\1/p' | tail -n 1)
	[ -n "$_n" ] || return 1
	printf '%s\n' "$_n"
}

# appcast_build: an appcast.xml on stdin; prints its highest numeric sparkle:version.
# Returns 1 without one.
appcast_build() {
	_n=$(tr -d '\r' | sed -n 's/.*<sparkle:version>[ \t]*\([1-9][0-9]*\)[ \t]*<\/sparkle:version>.*/\1/p' \
		| sort -n | tail -n 1)
	[ -n "$_n" ] || return 1
	printf '%s\n' "$_n"
}

# ledger_render KEY=VALUE...: prints a v1 block, in the order given. Fails on an unknown key,
# a repeated one, an empty value or one with a newline or `--`, a kind other than stable or
# beta, a build that is not a positive integer, or a missing kind or build.
ledger_render() {
	_seen=" "
	_body="<!-- bridgeplay-ledger v1"
	for _pair in "$@"; do
		_key=${_pair%%=*}
		_value=${_pair#*=}
		[ "$_key" != "$_pair" ] || { echo "ledger: '$_pair' is not KEY=VALUE" >&2; return 1; }
		case " $LEDGER_KEYS " in
			*" $_key "*) ;;
			*) echo "ledger: unknown key '$_key'" >&2; return 1 ;;
		esac
		case $_seen in
			*" $_key "*) echo "ledger: '$_key' given twice" >&2; return 1 ;;
		esac
		case $_value in
			''|' '*|*'--'*|*'
'*) echo "ledger: bad value for $_key: '$_value'" >&2; return 1 ;;
		esac
		case $_key in
			kind) case $_value in stable|beta) ;; *) echo "ledger: kind is stable or beta, got '$_value'" >&2; return 1 ;; esac ;;
			build) ledger_posint "$_value" || { echo "ledger: build wants a positive integer, got '$_value'" >&2; return 1; } ;;
		esac
		_seen="$_seen$_key "
		_body="$_body
$_key: $_value"
	done
	case $_seen in *" kind "*) ;; *) echo "ledger: kind is required" >&2; return 1 ;; esac
	case $_seen in *" build "*) ;; *) echo "ledger: build is required" >&2; return 1 ;; esac
	printf '%s\n%s\n' "$_body" "-->"
}
