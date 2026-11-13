# shellcheck shell=sh
# Version helpers shared by bump-version.sh, stamp-beta.sh and sync-upstream.sh. Source it, don't run it.
#
# The committed version in dylib/version.h is always a plain X.Y.Z. Only a beta build carries
# a label like X.Y.Z-beta.N, stamped in at build time by stamp-beta.sh and never committed.

# A positive integer of up to nine digits, no sign and no leading zero.
is_posint() {
	case $1 in
		''|*[!0-9]*|0*) return 1 ;;
	esac
	[ "${#1}" -le 9 ]
}

# X.Y.Z with plain numeric parts. A beta label, a v prefix or a fourth part is not one.
is_semver() {
	case $1 in
		''|*[!0-9.]*|.*|*.|*..*|*.*.*.*) return 1 ;;
		*.*.*) ;;
		*) return 1 ;;
	esac
	_old_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086 # only digits and dots got this far
	set -- $1
	IFS=$_old_ifs
	for _part in "$@"; do
		case $_part in
			0) ;;
			0*) return 1 ;;
		esac
		[ "${#_part}" -le 9 ] || return 1
	done
}

# semver_gt A B: A is above B. Both must pass is_semver.
semver_gt() {
	_old_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086 # only digits and dots, checked by the caller
	set -- $1 $2
	IFS=$_old_ifs
	[ "$1" -gt "$4" ] && return 0
	[ "$1" -lt "$4" ] && return 1
	[ "$2" -gt "$5" ] && return 0
	[ "$2" -lt "$5" ] && return 1
	[ "$3" -gt "$6" ]
}

# semver_ge A B: A is B or above it.
semver_ge() { [ "$1" = "$2" ] || semver_gt "$1" "$2"; }

# semver_next PART VERSION: the next patch, minor or major of VERSION.
semver_next() {
	_old_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086 # only digits and dots, checked by the caller
	set -- $2 "$1"
	IFS=$_old_ifs
	case $4 in
		major) echo "$(($1 + 1)).0.0" ;;
		minor) echo "$1.$(($2 + 1)).0" ;;
		patch) echo "$1.$2.$(($3 + 1))" ;;
		*) return 1 ;;
	esac
}

# header_string FILE NAME, header_number FILE NAME: a #define from dylib/version.h.
header_string() {
	sed -n 's/^#define '"$2"' "\(.*\)"$/\1/p' "$1"
}

header_number() {
	sed -n 's/^#define '"$2"' \([0-9][0-9]*\)$/\1/p' "$1"
}
