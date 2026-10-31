#!/bin/sh
# Pack the Corresponding Source (LGPL-2.1-or-later) of the patched WineCX binaries listed
# in NOTICE under "Patched Wine (WineCX) binaries": a full source tree of winecx at each
# pinned commit, plus every patch directory in this repository and the recipe docs, into
# out/wine-patch-sources-<id>.tar.gz. The id is derived from the pinned commits and the
# patch files, so it only changes when one of those does.
#
#   scripts/package-wine-patch-sources.sh            pack, then print the pin for NOTICE
#   scripts/package-wine-patch-sources.sh --publish  also create the GitHub release that hosts it
#
# The source for these binaries is winecx (https://github.com/dappermint/winecx) at the
# exact commits patched, plus the patches here. LGPL-2.1-or-later asks whoever distributes
# the binaries to also provide that source, so Bridgeplay publishes it alongside its own
# releases, crediting winecx as the source. Run it again whenever docs/WINECX.md's winecx
# pins change, then run with --publish and update NOTICE's pin.
set -eu

die() { echo "==> $*" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
publish=0
case "${1:-}" in
	--publish) publish=1 ;;
	"") ;;
	*) die "usage: $0 [--publish]" ;;
esac

# Keep this list in step with the "Patched Wine (WineCX) binaries" section of NOTICE.
patch_dirs="win32u-patch winemac-patch winebus-patch winecoreaudio-patch wined3d-patch ws2_32-patch d3dx11-patch ngx-signer-patch hide-wine-exports-patch"
for d in $patch_dirs; do
	[ -d "$d" ] || die "missing $d; update patch_dirs in $0 to match NOTICE"
done

winecx_url=https://github.com/dappermint/winecx.git
sha_1117=$(sed -n 's/^  WineCX 11\.17 (winecx \([0-9a-f]\{40\}\), runtime.*/\1/p' NOTICE)
sha_1115=$(sed -n 's/^  WineCX 11\.15 (winecx \([0-9a-f]\{40\}\), runtime.*/\1/p' NOTICE)
[ -n "$sha_1117" ] && [ -n "$sha_1115" ] || die "could not read the winecx pins from NOTICE"

# The id covers every input that determines the archive's bytes (except the generated
# README.md, whose only variables -- $id and the two short shas -- are themselves already
# hashed below): the two commits, every patch file's content and executable bit, the two
# recipe/license files copied in below, and this script itself (its README template and
# winecx_url are otherwise invisible to the hash). So any of them changing gives a new id,
# and --publish never mistakes stale content for what's already published under an
# unchanged name.
id=$(
	{
		printf '%s\n%s\n' "$sha_1117" "$sha_1115"
		for d in $patch_dirs; do
			find "$d" -type f | LC_ALL=C sort | while read -r f; do
				stat -f '%Lp' "$f"
				shasum -a 256 "$f"
			done
		done
		shasum -a 256 docs/WINECX.md LICENSE.wine scripts/package-wine-patch-sources.sh
	} | shasum -a 256 | cut -c1-12
)
name=wine-patch-sources-$id

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mirror="$repo/scratch/wine-patch-sources-build/winecx.git"
mkdir -p "$(dirname "$mirror")"
if [ ! -d "$mirror" ]; then
	echo "==> cloning winecx (bare, shared by both pins)"
	git clone --quiet --bare "$winecx_url" "$mirror"
fi
for sha in "$sha_1117" "$sha_1115"; do
	git -C "$mirror" cat-file -e "$sha^{commit}" 2>/dev/null \
		|| git -C "$mirror" fetch --quiet origin "$sha"
	git -C "$mirror" cat-file -e "$sha^{commit}" 2>/dev/null || die "winecx $sha not found"
done

stage="$work/$name"
mkdir -p "$stage/patches"
for d in $patch_dirs; do
	cp -R "$d" "$stage/patches/$d"
done
# Not NOTICE: it names this archive's own sha256, so bundling it would make the archive's
# bytes, and so its sha256, depend on what was last pasted into NOTICE.
cp docs/WINECX.md LICENSE.wine "$stage/"
# Only their content is hashed into id above, not their mode; force a fixed mode so a
# stray +x in the working tree can't change the archive's bytes under an unchanged id.
chmod 644 "$stage/WINECX.md" "$stage/LICENSE.wine"

extract() {
	short=$(git -C "$mirror" rev-parse --short=12 "$1")
	dest="$stage/winecx-$2-$short"
	mkdir -p "$dest"
	# tar.umask defaults to the archiving user's git config (0002, or their umask if set to
	# "user"), so without pinning it here the modes git archive writes, and so what the
	# chmod pass below normalizes them to, would depend on whoever runs this script.
	# core.attributesFile defaults to a path under the user's home directory; export-ignore
	# or export-subst rules there would change which files or bytes come out of this archive
	# without changing winecx's pinned commit, so point it at nothing instead.
	git -c tar.umask=0022 -c core.attributesFile=/dev/null \
		-C "$mirror" archive --format=tar "$1" | tar -x -C "$dest"
}
extract "$sha_1117" 11.17
extract "$sha_1115" 11.15

cat >"$stage/README.md" <<EOF
# WineCX patch sources

The LGPL-2.1-or-later Corresponding Source for the patched Wine (WineCX) binaries that
NOTICE lists under "Patched Wine (WineCX) binaries" ($id):

- \`winecx-11.17-$(git -C "$mirror" rev-parse --short=12 "$sha_1117")/\` and
  \`winecx-11.15-$(git -C "$mirror" rev-parse --short=12 "$sha_1115")/\`: the unmodified
  winecx source at the commit each binary is built from (dappermint/winecx,
  $winecx_url).
- \`patches/\`: this repository's patches and build recipes, one directory per binary,
  copied as of this archive.
- \`WINECX.md\`: how Bridgeplay lays the binaries over the engine and the per-binary build
  recipes; \`LICENSE.wine\`: Wine's license notice and the LGPL-2.1 text. The full list
  mapping each shipped file to its source commit and patch is NOTICE, in the Bridgeplay
  repository (https://github.com/raymondchins/Bridgeplay/blob/main/NOTICE).

Built by \`scripts/package-wine-patch-sources.sh\`.
EOF

# Keep each file's executable bit: winecx's configure and its own build scripts need it
# to match the "Rebuilding" recipes in docs/WINECX.md and each patch's README.
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -perm -u+x -exec chmod 755 {} +
find "$stage" -type f ! -perm -u+x -exec chmod 644 {} +
find "$stage" -exec env TZ=UTC touch -h -t 202601010000 {} +
(cd "$work" && find "$name" -type f | LC_ALL=C sort) >"$work/list"
mkdir -p out
archive=out/$name.tar.gz
(cd "$work" && COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel --no-xattrs \
	--no-mac-metadata -cf - -T "$work/list") | gzip -n -9 >"$archive"
sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
echo "==> $archive ($(du -h "$archive" | cut -f1 | tr -d ' ')), sha256 $sha"

echo "==> pin for NOTICE (Patched Wine (WineCX) binaries):"
echo "    archive: $name.tar.gz"
echo "    sha256: $sha"
echo "    release tag: $name"

[ "$publish" -eq 1 ] || exit 0
slug=raymondchins/Bridgeplay
if gh release view "$name" -R "$slug" >/dev/null 2>&1; then
	echo "==> $name is already published"
	exit 0
fi
gh release create "$name" "$archive" -R "$slug" --prerelease --latest=false \
	--title "WineCX patch sources ($id)" \
	--notes "The LGPL-2.1-or-later Corresponding Source for the patched Wine (WineCX) binaries in NOTICE: winecx at the pinned commits plus this repository's patches and build recipes. Built by scripts/package-wine-patch-sources.sh."
echo "==> published https://github.com/$slug/releases/tag/$name"
