#!/bin/sh
# Script to apply patches and throw them into the CrossOver setup, testing tool
#
#   ./build-ntdll.sh            build and verify
#   ./build-ntdll.sh --install  also copy into the bridge
#
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

CX_ROOT="${CX_ROOT:-/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/Library/Application Support/bridgeplay/bridge}"
OUT="${OUT:-$here/build}"

ROSETTA_CLEAN_X86_64=04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377
ROSETTA_CLEAN_I386=94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b
ROSETTA_PATCHED_X86_64=b6a98622fb8f7e6a998bc038f442b17d257da3df5e9e135f0c35f7bbc46ea5d6
ROSETTA_PATCHED_I386=25bfde1f50ee96485763968ef10b9d9ad35e38214232f17ebdc009b098af44a0

CX26_CLEAN_X86_64=6dff64c00793ce92124f1316985c63783f539f26b392975c70f57637458d2387
CX26_CLEAN_I386=2c60ee6b00dd13b7f6cb11017778a041ba6a321eaea194f1fa0dca7eab8403e2
CX26_PATCHED_X86_64=c0e21a9a5250f0a97c08d3c3e1798566255387213e2553b1e555264fb9ded97e
CX26_PATCHED_I386=e641d7b2e81ee13877823494679ba2d87e0d61b8a87e8a1ce92b4fe73631ae74

FEX_CLEAN_X86_64=f4fa556a3dc20f6e966a803f5de554359227a61a24cd5b5a2ad88a427ceeec58
FEX_CLEAN_I386=09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7
FEX_CLEAN_AARCH64=7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071
FEX_PATCHED_X86_64=fa8cd8fe7c4c19effade92d55b00fa946b630ab13cbb6721076848238c1dcf6a
FEX_PATCHED_I386=e799ea02418294588ee353a90b967358be316a3044ff9515b28aa1ce07e63981
FEX_PATCHED_AARCH64=f40810193a5ef2520774288f354a8604f5ba91828315f643b3ee6688b873dc3f

ROSETTA41069_CLEAN_X86_64=5b388fd48823e905616432fba627eb48f68dc14383963bb213d55db3f691b1b9
ROSETTA41069_CLEAN_I386=e7da2a712870222942ef27a80b3bf4fa70fc8545dd1a64bdc7f2fa24a38debc3
ROSETTA41069_PATCHED_X86_64=9569625387cf179d306b004c556273e2ec15811b2cfd51f21d078e2a0aa06f7f
ROSETTA41069_PATCHED_I386=0d8e3ebb57b3173f675eef5e3a0950052c592efa10a7a10193b0beb811b55ea5

FEX41069_CLEAN_X86_64=1b02dcf6ad9d9490870f1127a421c4c0d1471c65ec1574e1e84c05d69801ac7e
FEX41069_CLEAN_I386=66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5
FEX41069_CLEAN_AARCH64=77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852
FEX41069_PATCHED_X86_64=7548abd874656f6a6455e7fac659020ed755d92f4e1929a33097bbde964699f5
FEX41069_PATCHED_I386=e16b0199db721a08201b1512476b9eff255624d2faf3696fa57ff74b1a54be5c
FEX41069_PATCHED_AARCH64=7623c0b33350f511b431d39c7ec0c0d4f5def4183acef0eee5d4a5c694898956

ROSETTA41073_CLEAN_X86_64=f489347e59d4e8b43c2b0d2abbff9ee31e2059d45fd75fc04e2f4c0d8b04464a
ROSETTA41073_CLEAN_I386=5249b95eea6df765257b2e5212831f511d8f66134abe3c231b8e73d8f5b4707e
ROSETTA41073_PATCHED_X86_64=901bff9138707d90efecc592bd9bd3062075a350add4b3a283b089c1da635a61
ROSETTA41073_PATCHED_I386=7d3df0ee9dd61693293ba74a8d2c588b4dce26fb7f7a78c0c5ed5bdc58869e14

FEX41073_CLEAN_X86_64=3d24426735defd222fd9518b094b738dc1c12afd13efc41a855013ed0f825129
FEX41073_CLEAN_I386=3ee764335e50709285361e2542731385f0b06e593a76aa84a3c328c278164c4f
FEX41073_CLEAN_AARCH64=a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408
FEX41073_PATCHED_X86_64=2b47ed8c19d1d15d0f82519d39d64bf34113b285c4ada325bb64c5e587326d33
FEX41073_PATCHED_I386=3f4b0d9589c1f374e3c2fd135263f2bf3c8300e09dd010fd778936dd71e894ad
FEX41073_PATCHED_AARCH64=2efb13f3303adc2c8ee61b93e027e4e94730a2e6b0162c7e6aebd4104200f07c

FEX41303_CLEAN_X86_64=ef878e75661de8d955a42dc2fc76a84ca95574d48923dfc7f3f7db04a4d4f2b6
FEX41303_CLEAN_I386=4e8d8b4b54da99252423c7967d779d34976620a56bedaec38529d1f4b710f26a
FEX41303_CLEAN_AARCH64=3c2d6459113d4418a1135d7d5afe3a47c4a8c017aec389a987efa991bfeceda8
FEX41303_PATCHED_X86_64=503c4a6f71822b212bcfaaf210ba76e838998fa2c61957a64e5c0da3f9b3a6e9
FEX41303_PATCHED_I386=c35063d7fda866cd019a8ed1f6014c022a34a74d17037fc5c7f0732f58701f64
FEX41303_PATCHED_AARCH64=deb1e2dec774ae0b9504f88edd17f02c682d1f78e4839d874d62408a80cf3167

install=0
[ "${1:-}" = "--install" ] && install=1

die() { echo "error: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

command -v python3 >/dev/null || die "python3 not found"

OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy

flavor_of() {
    for cand in "$CX_ROOT/lib/wine/aarch64-windows/ntdll.dll.notproton-orig" \
                "$CX_ROOT/lib/wine/aarch64-windows/ntdll.dll"; do
        [ -f "$cand" ] || continue
        case "$(sha "$cand")" in
            "$FEX_CLEAN_AARCH64")      echo fex; return 0 ;;
            "$FEX41069_CLEAN_AARCH64") echo fex-41069; return 0 ;;
            "$FEX41073_CLEAN_AARCH64") echo fex-41073; return 0 ;;
            "$FEX41303_CLEAN_AARCH64") echo fex-41303; return 0 ;;
        esac
    done
    for cand in "$CX_ROOT/lib/wine/x86_64-windows/ntdll.dll.notproton-orig" \
                "$CX_ROOT/lib/wine/x86_64-windows/ntdll.dll"; do
        [ -f "$cand" ] || continue
        case "$(sha "$cand")" in
            "$ROSETTA_CLEAN_X86_64")      echo rosetta; return 0 ;;
            "$ROSETTA41069_CLEAN_X86_64") echo rosetta-41069; return 0 ;;
            "$ROSETTA41073_CLEAN_X86_64") echo rosetta-41073; return 0 ;;
            "$CX26_CLEAN_X86_64")         echo cx26; return 0 ;;
        esac
    done
    die "no ntdll under $CX_ROOT/lib/wine matches a pinned build
       pass FLAVOR=rosetta, rosetta-41069, rosetta-41073, cx26, fex, fex-41069, fex-41073 or fex-41303 to choose the pins anyway"
}

if [ -z "${FLAVOR:-}" ]; then
    FLAVOR="$(flavor_of)"
fi

case "$FLAVOR" in
    rosetta)       tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc"; BUILD=27.0.0.40921 ;;
    rosetta-41069) tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc"; BUILD=27.0.0.41069 ;;
    rosetta-41073) tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc"; BUILD=27.0.0.41073 ;;
    cx26)          tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc"; BUILD=26.3.0.39832 ;;
    fex)           tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc clang ld.lld"
                   BUILD=27.0.0.40921-fex ;;
    fex-41069)     tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc clang ld.lld"
                   BUILD=27.0.0.41069-fex ;;
    fex-41073)     tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc clang ld.lld"
                   BUILD=27.0.0.41073-fex ;;
    fex-41303)     tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc clang ld.lld"
                   BUILD=27.0.0.41303-fex ;;
    *)             die "unknown flavor $FLAVOR, expected rosetta, rosetta-41069, rosetta-41073, cx26, fex, fex-41069, fex-41073 or fex-41303" ;;
esac

for t in $tools; do
    command -v "$t" >/dev/null || die "$t not found (brew install mingw-w64 llvm)"
done

if [ "${FLAVOR%%-*}" = fex ] && [ ! -x "$OBJCOPY" ]; then
    die "$OBJCOPY not found (brew install llvm)"
fi

echo "==> $FLAVOR flavor, reading $CX_ROOT/lib/wine"

clean_for() {
    arch="$1"; want="$2"
    for cand in "$CX_ROOT/lib/wine/$arch/ntdll.dll.notproton-orig" \
                "$CX_ROOT/lib/wine/$arch/ntdll.dll"; do
        [ -f "$cand" ] || continue
        [ "$(sha "$cand")" = "$want" ] || continue
        echo "$cand"
        return 0
    done
    die "no clean $arch ntdll.dll found under $CX_ROOT/lib/wine/$arch
       expected sha256 $want
       extract a clean ntdll.dll from the CrossOver installer and point CX_ROOT at it"
}

mkdir -p "$OUT"

patch_one() {
    arch="$1"; builder="$2"; variant="$3"; payload="$4"; want_in="$5"; want_out="$6"
    src="$(clean_for "$arch" "$want_in")"
    dst="$OUT/$arch/ntdll.dll"
    mkdir -p "$OUT/$arch"
    echo "==> building $arch payload from ${src##*/}"
    ./"$builder" "$src" "$variant" >/dev/null
    echo "==> patching $arch"
    python3 apply.py "$src" "$dst" "$payload" >/dev/null
    got="$(sha "$dst")"
    [ "$got" = "$want_out" ] || die "$arch output hash $got, expected $want_out
       the patch no longer reproduces the known-good binary, do not ship this"
    echo "==> built $arch ntdll.dll  $(stat -f %z "$dst") bytes  $(echo "$got" | cut -c1-16)"
}

case "$FLAVOR" in
    rosetta)
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh   rosetta detour2.bin \
            "$ROSETTA_CLEAN_X86_64" "$ROSETTA_PATCHED_X86_64"
        patch_one i386-windows   build32.sh rosetta detour32.bin \
            "$ROSETTA_CLEAN_I386"   "$ROSETTA_PATCHED_I386"
        ;;
    cx26)
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh   cx26 detour2-cx26.bin \
            "$CX26_CLEAN_X86_64" "$CX26_PATCHED_X86_64"
        patch_one i386-windows   build32.sh cx26 detour32-cx26.bin \
            "$CX26_CLEAN_I386"   "$CX26_PATCHED_I386"
        ;;
    fex)
        # The FEX build ships a version of Wine that runs through Rosetta as well as
        # the FEX/ARM version, so all three ntdlls need patching.
        ARCHES="x86_64-windows i386-windows aarch64-windows"
        patch_one x86_64-windows  build.sh   fex detour2-fex.bin \
            "$FEX_CLEAN_X86_64"  "$FEX_PATCHED_X86_64"
        patch_one i386-windows    build32.sh fex detour32-fex.bin \
            "$FEX_CLEAN_I386"    "$FEX_PATCHED_I386"
        patch_one aarch64-windows build64.sh fex detour64-fex.bin \
            "$FEX_CLEAN_AARCH64" "$FEX_PATCHED_AARCH64"
        ;;
    rosetta-41069)
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh   41069 detour2-41069.bin \
            "$ROSETTA41069_CLEAN_X86_64" "$ROSETTA41069_PATCHED_X86_64"
        patch_one i386-windows   build32.sh 41069 detour32-41069.bin \
            "$ROSETTA41069_CLEAN_I386"   "$ROSETTA41069_PATCHED_I386"
        ;;
    fex-41069)
        ARCHES="x86_64-windows i386-windows aarch64-windows"
        patch_one x86_64-windows  build.sh   fex-41069 detour2-fex-41069.bin \
            "$FEX41069_CLEAN_X86_64"  "$FEX41069_PATCHED_X86_64"
        patch_one i386-windows    build32.sh fex-41069 detour32-fex-41069.bin \
            "$FEX41069_CLEAN_I386"    "$FEX41069_PATCHED_I386"
        patch_one aarch64-windows build64.sh fex-41069 detour64-fex-41069.bin \
            "$FEX41069_CLEAN_AARCH64" "$FEX41069_PATCHED_AARCH64"
        ;;
    rosetta-41073)
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh   41073 detour2-41073.bin \
            "$ROSETTA41073_CLEAN_X86_64" "$ROSETTA41073_PATCHED_X86_64"
        patch_one i386-windows   build32.sh 41073 detour32-41073.bin \
            "$ROSETTA41073_CLEAN_I386"   "$ROSETTA41073_PATCHED_I386"
        ;;
    fex-41073)
        ARCHES="x86_64-windows i386-windows aarch64-windows"
        patch_one x86_64-windows  build.sh   fex-41073 detour2-fex-41073.bin \
            "$FEX41073_CLEAN_X86_64"  "$FEX41073_PATCHED_X86_64"
        patch_one i386-windows    build32.sh fex-41073 detour32-fex-41073.bin \
            "$FEX41073_CLEAN_I386"    "$FEX41073_PATCHED_I386"
        patch_one aarch64-windows build64.sh fex-41073 detour64-fex-41073.bin \
            "$FEX41073_CLEAN_AARCH64" "$FEX41073_PATCHED_AARCH64"
        ;;
    fex-41303)
        ARCHES="x86_64-windows i386-windows aarch64-windows"
        patch_one x86_64-windows  build.sh   fex-41303 detour2-fex-41303.bin \
            "$FEX41303_CLEAN_X86_64"  "$FEX41303_PATCHED_X86_64"
        patch_one i386-windows    build32.sh fex-41303 detour32-fex-41303.bin \
            "$FEX41303_CLEAN_I386"    "$FEX41303_PATCHED_I386"
        patch_one aarch64-windows build64.sh fex-41303 detour64-fex-41303.bin \
            "$FEX41303_CLEAN_AARCH64" "$FEX41303_PATCHED_AARCH64"
        ;;
esac

if [ "$install" -eq 0 ]; then
    echo "==> not installing, pass --install to stage into the bridge"
    exit 0
fi

for arch in $ARCHES; do
    d="$BRIDGE_DIR/wine/$BUILD/$arch"
    mkdir -p "$d"
    cp "$OUT/$arch/ntdll.dll" "$d/ntdll.dll"
    echo "==> installed $arch  $(sha "$d/ntdll.dll" | cut -c1-16)  $d/ntdll.dll"
done
echo "==> setting build $BUILD up in Bridgeplay copies these into its runner clone"
