#!/bin/sh
# Checks that the bridge holds exactly the files listed in payload.manifest.
#
#   ./verify.sh          lists missing and unexpected files
#   ./verify.sh --prune  also moves unexpected files to scratch/bridge-attic
#
# It also looks for old copies of the bridge next to it, and for bridge files left
# in Steam Play prefixes.
#
# The built files come from 'make bridge' and the Valve files from fetch-valve.sh. The app
# stages the patched ntdlls per build under wine/, so they are neither checked nor pruned.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/Library/Application Support/bridgeplay/bridge}"
ATTIC="${ATTIC:-$repo/scratch/bridge-attic}"
SUPPORT_DIR="${SUPPORT_DIR:-$(dirname "$BRIDGE_DIR")}"
BRIDGE_NAME="$(basename "$BRIDGE_DIR")"

prune=0
[ "${1:-}" = "--prune" ] && prune=1

# The same manifest the app installs from.
MANIFEST="${MANIFEST:-$repo/app/Sources/BridgeplayApp/Resources/payload.manifest}"
if [ ! -f "$MANIFEST" ]; then
    echo "==> no payload manifest at $MANIFEST" >&2
    exit 1
fi

origin() {
    awk -v want="$1" '$1 == want { print $2 }' "$MANIFEST"
}

built="$(origin built)"
valve="$(origin valve)"

if [ -z "$built" ] || [ -z "$valve" ]; then
    echo "==> payload manifest has no usable entries: $MANIFEST" >&2
    exit 1
fi

if [ ! -d "$BRIDGE_DIR" ]; then
    echo "==> no bridge at $BRIDGE_DIR" >&2
    exit 1
fi

expected="$(printf '%s\n%s\n' "$built" "$valve" | sed '/^$/d')"
missing=0
unexpected=0

report() {
    label="$1"
    list="$2"
    echo "==> $label"
    for rel in $list; do
        f="$BRIDGE_DIR/$rel"
        if [ -f "$f" ]; then
            printf '    %-42s %10s  %s\n' "$rel" "$(wc -c < "$f" | tr -d ' ')" \
                "$(shasum -a 256 "$f" | cut -c1-16)"
        else
            printf '    %-42s %s\n' "$rel" "MISSING"
            missing=$((missing + 1))
        fi
    done
}

report "built here" "$built"
report "from Valve" "$valve"

# grep exits 1 when there are no strays. wine/<build>/<arch>/ntdll.dll is live, and so is
# the wine/<arch> copy of 1.0 while a legacy tool still uses it.
strays="$(cd "$BRIDGE_DIR" && { find . -mindepth 1 -type f | sed 's|^\./||' \
    | grep -Fxv "$expected" | grep -Ev '^wine/.+/ntdll\.dll$' || true; })"

unexpected=0
[ -n "$strays" ] && unexpected="$(printf '%s\n' "$strays" | wc -l | tr -d ' ')"

echo "==> unexpected"
if [ "$unexpected" -eq 0 ]; then
    echo "    none"
else
    printf '%s\n' "$strays" | while read -r rel; do
        if [ "$prune" -eq 1 ]; then
            mkdir -p "$ATTIC/$(dirname "$rel")"
            mv "$BRIDGE_DIR/$rel" "$ATTIC/$rel"
            printf '    moved to attic: %s\n' "$rel"
        else
            printf '    %s\n' "$rel"
        fi
    done
fi

if [ "$prune" -eq 1 ] && [ "$unexpected" -gt 0 ]; then
    # Moving files leaves the directories that held them behind.
    ( cd "$BRIDGE_DIR" && find . -mindepth 1 -type d -empty -delete )
    unexpected=0
fi

# Old copies like bridge.old next to the bridge. Nothing reads or updates them.
copies="$(find "$SUPPORT_DIR" -maxdepth 1 -mindepth 1 -type d -name "$BRIDGE_NAME.*" \
    | sed "s|^$SUPPORT_DIR/||" | sort)"
stale=0
[ -n "$copies" ] && stale="$(printf '%s\n' "$copies" | wc -l | tr -d ' ')"

echo "==> stale bridge copies"
if [ "$stale" -eq 0 ]; then
    echo "    none"
else
    printf '%s\n' "$copies" | while read -r c; do
        sz="$(du -sh "$SUPPORT_DIR/$c" | awk '{print $1}')"
        if [ "$prune" -eq 1 ]; then
            mkdir -p "$ATTIC"
            rm -rf "${ATTIC:?}/${c:?}"
            mv "$SUPPORT_DIR/$c" "$ATTIC/$c"
            printf '    moved to attic: %-42s %s\n' "$c" "$sz"
        else
            printf '    %-42s %s\n' "$c" "$sz"
        fi
    done
    [ "$prune" -eq 1 ] && stale=0
fi

# Every launch rewrites the bridge files in a prefix's Steam folder and
# syswow64/lsteamclient.dll, so old copies there are only counted. A copy anywhere
# else, system32 included, stays until removed, so it's listed as a stray.
PREFIX_ROOT="${PREFIX_ROOT:-$HOME/Library/Application Support/Steam/steamapps/compatdata}"

prefix_strays=""
prefixes=0
prefix_stale=0
if [ -d "$PREFIX_ROOT" ]; then
    for pfx in "$PREFIX_ROOT"/*/pfx; do
        [ -d "$pfx" ] || continue
        prefixes=$((prefixes + 1))
        appid="$(basename "$(dirname "$pfx")")"

        staged="$pfx/drive_c/Program Files (x86)/Steam/lsteamclient.dll"
        trigger="$pfx/drive_c/windows/syswow64/lsteamclient.dll"
        for pair in "$staged:$BRIDGE_DIR/lsteamclient.dll" \
                    "$trigger:$BRIDGE_DIR/i386-windows/lsteamclient.dll"; do
            have="${pair%:*}"
            want="${pair##*:}"
            [ -f "$have" ] || continue
            cmp -s "$have" "$want" || prefix_stale=$((prefix_stale + 1))
        done

        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rel="${f#"$pfx"/}"
            case "$rel" in
                "drive_c/Program Files (x86)/Steam/"*) continue ;;
                "drive_c/windows/syswow64/lsteamclient.dll") continue ;;
            esac
            prefix_strays="$prefix_strays$appid/$rel
"
        done <<STRAYS
$(find "$pfx" -type f \
    \( -name lsteamclient.dll -o -name lsteamclient.so \
    -o -name steamclient.dll -o -name steamclient64.dll \
    -o -name tier0_s64.dll -o -name vstdlib_s64.dll \
    -o -name tier0_s.dll -o -name vstdlib_s.dll \
    -o -name steam.exe \) 2>/dev/null)
STRAYS
    done
fi

prefix_strays="$(printf '%s' "$prefix_strays" | sed '/^$/d')"
stray_count=0
[ -n "$prefix_strays" ] && stray_count="$(printf '%s\n' "$prefix_strays" | wc -l | tr -d ' ')"

echo "==> prefix strays ($prefixes prefixes, $prefix_stale staged copies stale, heal next launch)"
if [ "$stray_count" -eq 0 ]; then
    echo "    none"
else
    printf '%s\n' "$prefix_strays" | while read -r rel; do
        appid="${rel%%/*}"
        sub="${rel#*/}"
        src="$PREFIX_ROOT/$appid/pfx/$sub"
        if [ "$prune" -eq 1 ]; then
            mkdir -p "$ATTIC/prefix-strays/$appid/$(dirname "$sub")"
            mv "$src" "$ATTIC/prefix-strays/$appid/$sub"
            printf '    moved to attic: %s\n' "$rel"
        else
            printf '    %s\n' "$rel"
        fi
    done
    [ "$prune" -eq 1 ] && stray_count=0
fi

[ "$prune" -eq 1 ] && echo "==> attic: $ATTIC"
echo "==> $missing missing, $unexpected unexpected, $stale stale copies, $stray_count prefix strays"
[ "$missing" -eq 0 ] && [ "$unexpected" -eq 0 ] && [ "$stale" -eq 0 ] && [ "$stray_count" -eq 0 ]
