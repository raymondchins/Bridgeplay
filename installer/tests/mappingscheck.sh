#!/bin/sh
# mappingscheck: how Install.command seeds and updates the user's gamecontrollerdb.txt.
# The merge_mappings function and the seeding block are cut out of the script and run here.
set -eu
SRC="${1:-$(dirname "$0")/../Install.command}"
work=$(mktemp -d "${TMPDIR:-/tmp}/np-mappingscheck.XXXXXX")
trap 'rm -rf "$work"' EXIT
failed=0
is() { # is <what> <expected> <actual>
	if [ "$2" = "$3" ]; then return; fi
	printf 'FAIL: %s\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
	failed=1
}
cut_block() { from="$1" to="$2" awk 'BEGIN { from = ENVIRON["from"]; to = ENVIRON["to"] } $0 ~ from { on = 1 } on { print } on && $0 ~ to { exit }' "$SRC"; }
cut_block '^merge_mappings\(\) \{' '^\}$' >"$work/block.sh"
cut_block "^# The user's own controller mappings" '^fi$' >>"$work/block.sh"
[ "$(grep -c . "$work/block.sh")" -gt 5 ] || { echo "FAIL: no mappings block in $SRC" >&2; exit 1; }

here="$work/here"
support="$work/support"
mkdir -p "$here/config" "$support"
die() { echo "die: $*" >&2; exit 1; }
say() { echo "say: $*" >&2; }
# shellcheck disable=SC1091 # block.sh is cut out of Install.command above
run() { . "$work/block.sh"; }

g1=03000000aaaa0000000000000000a1b1
g2=03000000bbbb0000000000000000a2b2
g3=03000000cccc0000000000000000a3b3
shipped="$here/config/gamecontrollerdb.txt"
mine="$support/gamecontrollerdb.txt"
printf '# header\n%s,Pad A,a:b0\n# about B\n# second line\n%s,Pad B,a:b1\n' "$g1" "$g2" >"$shipped"

run
is "fresh install copies the file" "$(cat "$shipped")" "$(cat "$mine")"

printf '# header\n%s,Pad A (shipped),a:b0\n# about B\n# second line\n%s,Pad B,a:b1\n# about C\n%s,Pad C,a:b2\n' "$g1" "$g2" "$g3" >"$shipped"
run
is "upgrade appends only the missing GUID, with its comment" "$(printf '# header\n%s,Pad A,a:b0\n# about B\n# second line\n%s,Pad B,a:b1\n# about C\n%s,Pad C,a:b2' "$g1" "$g2" "$g3")" "$(cat "$mine")"

before=$(cat "$mine")
run
is "running twice changes nothing" "$before" "$(cat "$mine")"

# the user's own edits, an extra line of theirs and a file without a final newline
printf '%s,My own Pad A,a:b9\n%s,Mine,a:b3' "$g1" "030000000000000000000000000000ff" >"$mine"
run
is "edited lines and own lines stay, only missing GUIDs are added" "$(printf '%s,My own Pad A,a:b9\n%s,Mine,a:b3\n# about B\n# second line\n%s,Pad B,a:b1\n# about C\n%s,Pad C,a:b2' "$g1" "030000000000000000000000000000ff" "$g2" "$g3")" "$(cat "$mine")"
before=$(cat "$mine")
run
is "running twice changes nothing after an edit" "$before" "$(cat "$mine")"

# a GUID in another case is the same pad
printf '%s,Pad A,a:b0\n' "$(printf '%s' "$g1" | tr a-f A-F)" >"$mine"
run
is "GUIDs match in any case" "$(printf '%s,Pad A,a:b0' "$(printf '%s' "$g1" | tr a-f A-F)")" "$(grep -i "^$g1" "$mine" | tr -d '\n')"

[ "$failed" = 0 ] || exit 1
echo "mappingscheck: ok"
