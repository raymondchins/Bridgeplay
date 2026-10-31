#!/bin/bash
# Build DXMT from a pinned commit and package it the way the upstream v0.80 release
# tarball is laid out, so FreeEngine can consume it in place of that release.
#
#   scripts/build-dxmt.sh [--publish] <commit>
#
# Output: scratch/dxmt-out/dxmt-<shortsha>.tar.gz holding
#   <shortsha>/x86_64-unix/winemetal.so
#   <shortsha>/x86_64-windows/{d3d10core,d3d11,dxgi,winemetal,nvapi64,nvngx}.dll
#   <shortsha>/i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll
#   <shortsha>/x86_64-windows-d3d12/d3d12.dll   (WIP backend, kept apart on purpose)
#   <shortsha>/{COPYING.LIB,LICENSE,LICENSE-0.80-and-earlier.txt}
# and scratch/dxmt-out/dxmt-<shortsha>-source.tar.gz: the Corresponding Source
# (LGPL-2.1-or-later), the exact DXMT worktree this build ran from, submodules
# included, as <shortsha>/. --publish also creates the dxmt-<shortsha> GitHub release
# carrying both tarballs and the sha256 manifest.
#
# The toolchain follows DXMT's CI (.github/workflows/ci.yml, the gcc-release jobs that
# feed its package step): LLVM 15.0.7 built for x86_64-apple-darwin, Homebrew mingw-w64,
# meson 1.10.0. CI links against 3Shain's prebuilt Wine 8.16; this links against the
# Wine Bridgeplay actually runs instead: winebuild and the PE import libraries come from
# a wine-11.15 source tree, and winemac.so/ntdll.so are the binaries out of the pinned
# Gcenx 11.15 archive FreeEngine downloads.
#
# Everything lands in scratch/ (gitignored). Finished stages are skipped on a rerun;
# delete the matching directory under scratch/dxmt-build to redo one.
set -euo pipefail

PUBLISH=0
COMMIT_ARG=""
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        *)
            if [ -n "$COMMIT_ARG" ]; then echo "usage: $0 [--publish] <dxmt commit>" >&2; exit 2; fi
            COMMIT_ARG="$arg"
            ;;
    esac
done
if [ -z "$COMMIT_ARG" ]; then
    echo "usage: $0 [--publish] <dxmt commit>" >&2
    exit 2
fi
# A commit, never a branch or tag that can move: 7 to 40 hex digits, checked below to be
# a prefix of what it resolves to.
case "$COMMIT_ARG" in
    *[!0-9a-f]*) echo "$0: $COMMIT_ARG is not a commit SHA (lowercase hex)" >&2; exit 2 ;;
esac
if [ "${#COMMIT_ARG}" -lt 7 ] || [ "${#COMMIT_ARG}" -gt 40 ]; then
    echo "$0: $COMMIT_ARG is not a commit SHA (7 to 40 hex digits)" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${DXMT_WORK:-$repo/scratch/dxmt-build}"
OUT="${DXMT_OUT:-$repo/scratch/dxmt-out}"

DXMT_URL="${DXMT_URL:-https://github.com/3Shain/dxmt.git}"
# ci.yml: LLVM_VERSION. The tag is an annotated tag, so the commit is pinned as well.
LLVM_TAG="llvmorg-15.0.7"
LLVM_COMMIT="8dfdcc7b7bf66834a761bd8de445840ef68e4d1a"
# Same pin as bridge/setup-wine-tree.sh. The GitHub mirror, because a shallow clone
# from gitlab.winehq.org can crawl for many minutes; the commit check below holds either way.
WINE_URL="${WINE_URL:-https://github.com/wine-mirror/wine.git}"
WINE_TAG="wine-11.15"
WINE_COMMIT="2df1ee28039cf84776eb1421ed90bd154cebb65f"
# Same pin as FreeEngine.current.
GCENX_ARCHIVE_NAME="wine-devel-11.15-osx64.tar.xz"
GCENX_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.15/$GCENX_ARCHIVE_NAME"
GCENX_SHA256="3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2"
GCENX_UNIX="Wine Devel.app/Contents/Resources/wine/lib/wine/x86_64-unix"
# ci.yml: "pip3 install meson==1.10.0".
MESON_VERSION="1.10.0"
NINJA_VERSION="1.13.0"

# The bison macOS ships is too old for wine's configure.
export PATH="$WORK/venv/bin:/opt/homebrew/bin:/opt/homebrew/opt/bison/bin:$PATH"
# Xcode, not the command line tools: DXMT compiles .metal shaders.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
fi
export DEVELOPER_DIR

# The upstream release targets macOS 15 (LC_BUILD_VERSION minos 15.0). Left to the
# Xcode 27 default, winemetal.so would be minos 27.0 and its embedded metallib AIR v29,
# neither of which loads on the macOS 26 Bridgeplay supports. clang, cmake and the metal
# compiler all take this variable.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

missing=""
for tool in git cmake make bison flex xxd python3 curl \
            x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -z "$missing" ] || die "missing tools:$missing (brew install cmake bison flex mingw-w64)"
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
    || die "no Metal compiler under $DEVELOPER_DIR (xcodebuild -downloadComponent MetalToolchain)"

mkdir -p "$WORK" "$OUT"
start=$(date +%s)

# --- meson + ninja, the versions CI uses ------------------------------------------------
if [ "$("$WORK/venv/bin/meson" --version 2>/dev/null || true)" != "$MESON_VERSION" ] \
    || [ "$("$WORK/venv/bin/ninja" --version 2>/dev/null || true)" != "$NINJA_VERSION" ]; then
    log "creating python venv with meson $MESON_VERSION and ninja $NINJA_VERSION"
    python3 -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install --quiet "meson==$MESON_VERSION" "ninja==$NINJA_VERSION"
fi

# --- DXMT source -----------------------------------------------------------------------
SRC="$WORK/dxmt"
if [ ! -d "$SRC/.git" ]; then
    log "cloning DXMT"
    git clone --quiet "$DXMT_URL" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$COMMIT_ARG^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --quiet origin
fi
COMMIT="$(git -C "$SRC" rev-parse --verify "$COMMIT_ARG^{commit}")"
case "$COMMIT" in "$COMMIT_ARG"*) ;; *) die "$COMMIT_ARG resolved to $COMMIT, a ref rather than that commit" ;; esac
SHORT="$(git -C "$SRC" rev-parse --short=7 "$COMMIT")"
git -C "$SRC" -c advice.detachedHead=false checkout --quiet --detach "$COMMIT"
git -C "$SRC" submodule update --quiet --init --recursive
[ -z "$(git -C "$SRC" status --porcelain)" ] || die "$SRC has local changes"
log "DXMT $COMMIT ($(git -C "$SRC" describe --always))"

# --- LLVM 15 for x86_64-apple-darwin (ci.yml: setup-llvm-darwin) -----------------------
LLVM="$WORK/llvm"
LLVM_STAMP="$LLVM/.done-$LLVM_COMMIT-macos$MACOSX_DEPLOYMENT_TARGET"
if [ ! -f "$LLVM_STAMP" ]; then
    if [ ! -d "$WORK/llvm-project/.git" ]; then
        log "cloning $LLVM_TAG"
        git clone --quiet --depth 1 --branch "$LLVM_TAG" \
            https://github.com/llvm/llvm-project.git "$WORK/llvm-project"
    fi
    [ "$(git -C "$WORK/llvm-project" rev-parse HEAD)" = "$LLVM_COMMIT" ] \
        || die "$WORK/llvm-project is not at $LLVM_COMMIT"
    log "building LLVM $LLVM_TAG (x86_64)"
    rm -rf "$LLVM"
    # Same flags as CI, plus CMAKE_POLICY_VERSION_MINIMUM so CMake 4 accepts LLVM 15.
    cmake -B "$WORK/llvm-build" -S "$WORK/llvm-project/llvm" \
        -DCMAKE_INSTALL_PREFIX="$LLVM" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
        -DLLVM_ENABLE_ASSERTIONS=On \
        -DLLVM_ENABLE_ZSTD=Off \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" \
        -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_BUILD_TOOLS=Off \
        -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" \
        -DPACKAGE_VENDOR="DXMT" \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -G Ninja > "$WORK/llvm-configure.log"
    cmake --build "$WORK/llvm-build"
    cmake --install "$WORK/llvm-build" > /dev/null
    touch "$LLVM_STAMP"
fi

# --- Wine 11.15 SDK: winebuild, PE import libs, Gcenx's unix modules -------------------
# DXMT's -Dwine_install_path wants bin/winebuild, lib/wine/<arch>-windows/lib{winecrt0,
# ntdll,dbghelp}.a and lib/wine/x86_64-unix/{winemac,ntdll}.so. Gcenx ships a runtime-only
# Wine, so the first two come from a source tree; the .so files winemetal.so links
# against are Gcenx's own.
SDK="$WORK/wine-sdk"
if [ ! -f "$SDK/.done-$WINE_COMMIT-$GCENX_SHA256" ]; then
    WSRC="$WORK/wine"
    WBUILD="$WORK/wine-build"
    if [ ! -d "$WSRC/.git" ]; then
        log "cloning $WINE_TAG"
        git clone --quiet --depth 1 --branch "$WINE_TAG" "$WINE_URL" "$WSRC"
    fi
    [ "$(git -C "$WSRC" rev-parse HEAD)" = "$WINE_COMMIT" ] \
        || die "$WSRC is not at $WINE_COMMIT"
    if [ ! -f "$WBUILD/Makefile" ]; then
        log "configuring $WINE_TAG (x86_64 host, i386+x86_64 PE)"
        mkdir -p "$WBUILD"
        ( cd "$WBUILD" && "$WSRC/configure" --enable-archs=i386,x86_64 \
            --without-freetype --without-x --host=x86_64-apple-darwin \
            CC="clang -arch x86_64" CXX="clang++ -arch x86_64" ) > "$WORK/wine-configure.log"
    fi
    targets="tools/winebuild/winebuild"
    for arch in x86_64 i386; do
        targets="$targets libs/winecrt0/$arch-windows/libwinecrt0.a"
        targets="$targets dlls/ntdll/$arch-windows/libntdll.a"
        targets="$targets dlls/dbghelp/$arch-windows/libdbghelp.a"
    done
    log "building winebuild and import libraries"
    # shellcheck disable=SC2086
    make -C "$WBUILD" -j"$(sysctl -n hw.ncpu)" $targets > "$WORK/wine-make.log"

    archive="$WORK/downloads/$GCENX_ARCHIVE_NAME"
    if [ ! -f "$archive" ] || [ "$(sha "$archive")" != "$GCENX_SHA256" ]; then
        log "downloading $GCENX_ARCHIVE_NAME"
        mkdir -p "$WORK/downloads"
        curl -fsSL -o "$archive" "$GCENX_URL"
    fi
    [ "$(sha "$archive")" = "$GCENX_SHA256" ] || die "$archive does not match $GCENX_SHA256"

    rm -rf "$SDK" "$WORK/gcenx"
    mkdir -p "$SDK/bin" "$SDK/lib/wine/x86_64-unix" "$WORK/gcenx"
    cp "$WBUILD/tools/winebuild/winebuild" "$SDK/bin/"
    for arch in x86_64 i386; do
        mkdir -p "$SDK/lib/wine/$arch-windows"
        cp "$WBUILD/libs/winecrt0/$arch-windows/libwinecrt0.a" \
           "$WBUILD/dlls/ntdll/$arch-windows/libntdll.a" \
           "$WBUILD/dlls/dbghelp/$arch-windows/libdbghelp.a" "$SDK/lib/wine/$arch-windows/"
    done
    tar -xJf "$archive" -C "$WORK/gcenx" "$GCENX_UNIX/winemac.so" "$GCENX_UNIX/ntdll.so"
    for so in winemac.so ntdll.so; do
        cp "$WORK/gcenx/$GCENX_UNIX/$so" "$SDK/lib/wine/x86_64-unix/$so"
        # Gcenx builds these with a bare install name. The upstream release records
        # @rpath/<name>, which its LC_RPATH @loader_path/ resolves next to winemetal.so;
        # renaming the link inputs makes ours record the same. They are never shipped.
        install_name_tool -id "@rpath/$so" "$SDK/lib/wine/x86_64-unix/$so" 2>/dev/null
    done
    touch "$SDK/.done-$WINE_COMMIT-$GCENX_SHA256"
fi

# --- DXMT, the gcc-release jobs of ci.yml ----------------------------------------------
INSTALL="$WORK/install-$SHORT"
rm -rf "$INSTALL" "$WORK/build64-$SHORT" "$WORK/build32-$SHORT"
cd "$SRC"

log "building x86_64 PE + unixlib (d3d12 enabled)"
meson setup --cross-file build-win64.txt -Denable_nvapi=true -Denable_nvngx=true \
    -Denable_d3d12=true -Dnative_llvm_path="$LLVM" -Dwine_install_path="$SDK" \
    "$WORK/build64-$SHORT" --buildtype release --prefix "$INSTALL" --strip \
    > "$WORK/meson-setup64.log"
meson compile -C "$WORK/build64-$SHORT"
meson install -C "$WORK/build64-$SHORT" > /dev/null

log "building i386 PE"
meson setup --cross-file build-win32.txt -Dwine_install_path="$SDK" \
    "$WORK/build32-$SHORT" --buildtype release --prefix "$INSTALL" --strip \
    > "$WORK/meson-setup32.log"
meson compile -C "$WORK/build32-$SHORT"
meson install -C "$WORK/build32-$SHORT" > /dev/null

# --- package ---------------------------------------------------------------------------
STAGE="$OUT/stage"
TREE="$STAGE/$SHORT"
rm -rf "$STAGE"
mkdir -p "$TREE/x86_64-unix" "$TREE/x86_64-windows" "$TREE/i386-windows" \
         "$TREE/x86_64-windows-d3d12"

files="x86_64-unix/winemetal.so"
for dll in d3d10core d3d11 dxgi winemetal nvapi64 nvngx; do
    files="$files x86_64-windows/$dll.dll"
done
for dll in d3d10core d3d11 dxgi winemetal; do
    files="$files i386-windows/$dll.dll"
done
for f in $files; do
    [ -f "$INSTALL/$f" ] || die "build did not produce $f"
    cp "$INSTALL/$f" "$TREE/$f"
done
[ -f "$INSTALL/x86_64-windows/d3d12.dll" ] || die "build did not produce d3d12.dll"
cp "$INSTALL/x86_64-windows/d3d12.dll" "$TREE/x86_64-windows-d3d12/d3d12.dll"
files="$files x86_64-windows-d3d12/d3d12.dll"

# Wine refuses to treat a PE as builtin without the marker winebuild --builtin writes.
for f in $files; do
    case "$f" in *.dll)
        [ "$(dd if="$TREE/$f" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ] \
            || die "$f is not marked as a Wine builtin";;
    esac
done
deps="$(otool -L "$TREE/x86_64-unix/winemetal.so")"
for so in winemac.so ntdll.so; do
    printf '%s\n' "$deps" | grep -q "@rpath/$so " || die "winemetal.so does not link @rpath/$so"
done
[ "$(lipo -archs "$TREE/x86_64-unix/winemetal.so")" = "x86_64" ] || die "winemetal.so is not x86_64"
minos="$(otool -l "$TREE/x86_64-unix/winemetal.so" | awk '$1 == "minos" { print $2; exit }')"
[ "$minos" = "$MACOSX_DEPLOYMENT_TARGET" ] || die "winemetal.so has minos $minos"
# d3d11.dll and d3d12.dll embed a metallib (src/dxmt/dxmt_command.metal); it has to
# target an OS no newer than that either, or Metal refuses it at device creation.
for f in $files; do
    { LC_ALL=C grep -aoE 'air64(_v[0-9]+)?-apple-macosx[0-9.]+' "$TREE/$f" || true; } \
        | sort -u | awk -F'macosx' -v max="$MACOSX_DEPLOYMENT_TARGET" \
            '$2 + 0 > max + 0 { print "embedded Metal code targets " $0; bad = 1 } END { exit bad }' \
        || die "$f embeds Metal code newer than macOS $MACOSX_DEPLOYMENT_TARGET"
done

# License texts beside the binaries, so a direct download (FreeEngine, not only the
# installer path) carries them too: LGPL-2.1-or-later since ec357fd (v0.80 was the last
# MIT release).
cp "$repo/installer/licenses/COPYING.LIB.dxmt" "$TREE/COPYING.LIB"
cp "$repo/installer/licenses/LICENSE.dxmt" "$TREE/LICENSE"
cp "$repo/installer/licenses/LICENSE.dxmt-old" "$TREE/LICENSE-0.80-and-earlier.txt"

# Same modes as the release, fixed owners and times, sorted entries and no macOS
# metadata, so the same binaries always give the same tarball.
epoch="$(git -C "$SRC" show -s --format=%ct "$COMMIT")"
stamp="$(TZ=UTC date -r "$epoch" +%Y%m%d%H%M.%S)"
find "$TREE" -type d -exec chmod 755 {} +
find "$TREE" -type f -exec chmod 644 {} +
find "$STAGE" -exec env TZ=UTC touch -h -t "$stamp" {} +
TARBALL="$OUT/dxmt-$SHORT.tar.gz"
( cd "$STAGE" && find "$SHORT" | LC_ALL=C sort ) > "$OUT/.filelist"
( cd "$STAGE" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname "" --gname "" \
    --no-xattrs --no-mac-metadata --no-acls --no-fflags -c -n -T "$OUT/.filelist" -f - ) \
    | gzip -n -9 > "$TARBALL"
rm -f "$OUT/.filelist"

MANIFEST="$OUT/dxmt-$SHORT.sha256"
{
    for f in $files; do
        printf '%s  %s\n' "$(sha "$TREE/$f")" "$f"
    done
    printf '%s  %s\n' "$(sha "$TARBALL")" "$(basename "$TARBALL")"
} > "$MANIFEST"

# --- source tarball ----------------------------------------------------------------
# Corresponding Source (LGPL-2.1-or-later): the exact worktree this build ran from,
# submodules included (DXMT vendors external/nvapi and include/native/directx that
# way), without git's own metadata. LGPL-2.1-or-later asks whoever distributes this
# build to also provide that source, so it ships beside the binaries.
SRC_STAGE="$OUT/stage-source"
SRC_TREE="$SRC_STAGE/$SHORT"
rm -rf "$SRC_STAGE"
mkdir -p "$SRC_TREE"
( cd "$SRC" && find . -name .git -prune -o -type f -print ) | sed 's#^\./##' > "$OUT/.srclist"
( cd "$SRC" && tar -cf - -T "$OUT/.srclist" ) | tar -x -C "$SRC_TREE"
rm -f "$OUT/.srclist"
find "$SRC_TREE" -type d -exec chmod 755 {} +
find "$SRC_TREE" -type f -exec chmod 644 {} +
find "$SRC_STAGE" -exec env TZ=UTC touch -h -t "$stamp" {} +
SOURCE_TARBALL="$OUT/dxmt-$SHORT-source.tar.gz"
( cd "$SRC_STAGE" && find "$SHORT" | LC_ALL=C sort ) > "$OUT/.srcfilelist"
( cd "$SRC_STAGE" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname "" --gname "" \
    --no-xattrs --no-mac-metadata --no-acls --no-fflags -c -n -T "$OUT/.srcfilelist" -f - ) \
    | gzip -n -9 > "$SOURCE_TARBALL"
rm -f "$OUT/.srcfilelist"
printf '%s  %s\n' "$(sha "$SOURCE_TARBALL")" "$(basename "$SOURCE_TARBALL")" >> "$MANIFEST"

log "DXMT $COMMIT built in $(( $(date +%s) - start ))s"
log "tarball: $TARBALL (tree: $SHORT)"
log "source tarball: $SOURCE_TARBALL"
cat "$MANIFEST"

if [ "$PUBLISH" -eq 1 ]; then
    slug=raymondchins/Bridgeplay
    tag="dxmt-$SHORT"
    if gh release view "$tag" -R "$slug" >/dev/null 2>&1; then
        log "$tag is already published"
    else
        gh release create "$tag" "$TARBALL" "$SOURCE_TARBALL" "$MANIFEST" -R "$slug" \
            --prerelease --latest=false --title "DXMT $SHORT" \
            --notes "DXMT built from https://github.com/3Shain/dxmt at $COMMIT ($(git -C "$SRC" describe --always)). LGPL-2.1-or-later since ec357fd (v0.80 was the last MIT release); license texts and the dxmt-$SHORT-source.tar.gz Corresponding Source (submodules included) ship alongside the binaries. See docs/DXMT.md."
        log "published https://github.com/$slug/releases/tag/$tag"
    fi
fi
