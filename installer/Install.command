#!/bin/bash
# Bridgeplay one-click installer.
# Downloads the latest Bridgeplay from GitHub, copies Apple's Game Porting Toolkit
# (D3DMetal), the DXMT and DXVK archives and the default configs, installs Steam from
# Valve's CDN when it is missing, then opens Bridgeplay, whose Setup Assistant does the
# rest: Rosetta, sign-in, the App Management permission, the WineCX engine (downloaded
# from dappermint/winecx-gptk, see NOTICE) and the Steam setup. Assembled into a zip by scripts/package-installer.sh.
set -uo pipefail

# Bridgeplay Installer.app runs this script too, after it has installed the app itself:
# BRIDGEPLAY_INSTALL_APP=0 skips the app, BRIDGEPLAY_NONINTERACTIVE=1 never waits for Enter
# and leaves opening Bridgeplay and the Terminal window to the caller.
install_app=${BRIDGEPLAY_INSTALL_APP:-1}
noninteractive=${BRIDGEPLAY_NONINTERACTIVE:-0}

here="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/bridgeplay"
caches="$HOME/Library/Caches/bridgeplay"
# Bridgeplay before 3.0.0 kept its files under "notproton". The app moves them to
# "bridgeplay" itself on first launch (with a backup), so the installer never moves them.
# While only the old folders exist, it writes into them so that move carries the new
# files along; a bridgeplay folder made next to them would get in the migration's way.
legacy_support="$HOME/Library/Application Support/notproton"
legacy_caches="$HOME/Library/Caches/notproton"
migrate_later=0
if [ ! -d "$support" ] && [ -d "$legacy_support" ]; then
    support="$legacy_support"
    migrate_later=1
fi
if [ ! -d "$caches" ] && [ -d "$legacy_caches" ]; then
    caches="$legacy_caches"
    migrate_later=1
fi

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die()  {
    printf '\n\033[1;31mGagal:\033[0m %s\n' "$*" >&2
    [ "$noninteractive" = 1 ] || read -r -p "Tekan Enter untuk menutup..." _
    exit 1
}

# Valve's official macOS Steam installer, and the Team ID Valve signs Steam.app with.
steam_url="https://cdn.cloudflare.steamstatic.com/client/installer/steam.dmg"
valve_team="MXGJJ98X76"
steam_identifier="com.valvesoftware.steam"
# A grep -q pipe can SIGPIPE codesign under pipefail; let codesign check the trust chain,
# Valve's Team ID and Steam's bundle identifier as one requirement.
steam_requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$valve_team\" and identifier \"$steam_identifier\""
steam_tmp=""
steam_mnt=""
# The installer carries no app, so it never goes stale: it installs the Latest release.
app_url="https://github.com/raymondchins/Bridgeplay/releases/latest/download/Bridgeplay.zip"
# Release builds are signed with the self-signed "Bridgeplay Release" identity; pin its leaf
# so an ad-hoc or other-signed zip on the release fails.
app_requirement='=identifier "com.bridgeplay.Bridgeplay" and certificate leaf = H"63cd686b8e4c1123ef885e90e1127fefd5bd42b1"'
app_tmp=""
# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
    if [ -n "$steam_mnt" ]; then hdiutil detach -quiet "$steam_mnt" >/dev/null 2>&1; fi
    if [ -n "$steam_tmp" ]; then rm -rf "$steam_tmp"; fi
    if [ -n "$app_tmp" ]; then rm -rf "$app_tmp"; fi
    return 0
}
trap cleanup EXIT

xattr -dr com.apple.quarantine "$here" 2>/dev/null || true

[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || die "Mac ini bukan Apple Silicon (M1/M2/M3/...). Bridgeplay tidak jalan di Mac Intel."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || die "Butuh macOS 26 atau lebih baru (sekarang $(sw_vers -productVersion)). Update macOS dulu."
[ -w /Applications ] || die "Akun ini tidak bisa menulis ke folder Applications. Login dengan akun admin, lalu jalankan Install.command lagi."
# An installer from before the app was left out still carries Bridgeplay.app; use it.
app_src="$here/Bridgeplay.app"
if [ "$install_app" = 1 ] && [ ! -d "$app_src" ]; then
    say "Mengunduh Bridgeplay versi terbaru..."
    app_tmp="$(mktemp -d)"
    curl -fL --retry 3 --connect-timeout 20 -o "$app_tmp/Bridgeplay.zip" "$app_url" \
        || die "Bridgeplay gagal diunduh. Cek koneksi internet, lalu jalankan Install.command lagi."
    ditto -x -k "$app_tmp/Bridgeplay.zip" "$app_tmp" || die "File Bridgeplay yang diunduh rusak. Jalankan Install.command lagi."
    app_src="$app_tmp/Bridgeplay.app"
    [ -d "$app_src" ] || die "File Bridgeplay yang diunduh tidak berisi Bridgeplay.app. Jalankan Install.command lagi."
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_src/Contents/Info.plist" 2>/dev/null)" = "com.bridgeplay.Bridgeplay" ] \
        || die "File yang diunduh bukan Bridgeplay. Jalankan Install.command lagi."
    codesign --verify --strict -R "$app_requirement" "$app_src" 2>/dev/null \
        || die "Tanda tangan Bridgeplay yang diunduh tidak valid. Jalankan Install.command lagi."
fi

if [ "$install_app" = 1 ]; then
    say "Memasang Bridgeplay..."
    # quit is asynchronous: wait until the app has gone before its bundle is removed.
    osascript -e 'tell application id "com.bridgeplay.Bridgeplay" to quit' >/dev/null 2>&1 || true
    waited=0
    while pgrep -qx BridgeplayApp; do
        [ "$waited" -lt 30 ] || die "Bridgeplay masih berjalan. Tutup Bridgeplay dulu, lalu jalankan Install.command lagi."
        sleep 1
        waited=$((waited + 1))
    done
    rm -rf /Applications/Bridgeplay.app || die "Bridgeplay lama tidak bisa dihapus dari Applications."
    ditto "$app_src" /Applications/Bridgeplay.app || die "Bridgeplay gagal disalin ke Applications."
    xattr -dr com.apple.quarantine /Applications/Bridgeplay.app 2>/dev/null || true
fi

if [ ! -d /Applications/Steam.app ]; then
    say "Steam belum terpasang. Mengunduh installer Steam resmi dari Valve..."
    steam_tmp="$(mktemp -d)" || die "Folder sementara tidak bisa dibuat."
    dmg="$steam_tmp/steam.dmg"
    curl -fL --retry 3 --connect-timeout 20 -o "$dmg" "$steam_url" \
        || die "Steam gagal diunduh. Pastikan Mac tersambung ke internet, lalu jalankan Install.command lagi."
    # A UDIF disk image ends with a 512-byte trailer that starts with "koly".
    [ "$(tail -c 512 "$dmg" | head -c 4)" = "koly" ] \
        || die "File yang diunduh bukan installer Steam (bukan DMG). Coba lagi nanti."
    say "Memasang Steam..."
    steam_mnt="$steam_tmp/mnt"
    mkdir "$steam_mnt" || die "Folder sementara tidak bisa dibuat."
    hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$steam_mnt" "$dmg" </dev/null \
        || { steam_mnt=""; die "Installer Steam tidak bisa dibuka."; }
    if ! codesign --verify --strict -R "$steam_requirement" "$steam_mnt/Steam.app" 2>/dev/null; then
        die "Steam yang diunduh tidak ditandatangani Valve. Instalasi dibatalkan."
    fi
    ditto "$steam_mnt/Steam.app" /Applications/Steam.app || die "Steam gagal disalin ke Applications."
    hdiutil detach -quiet "$steam_mnt" >/dev/null 2>&1
    steam_mnt=""
    xattr -dr com.apple.quarantine /Applications/Steam.app 2>/dev/null || true
fi

say "Menyalin Game Porting Toolkit, DXMT, DXVK dan config..."
if [ "$migrate_later" -eq 1 ]; then
    say "Data Bridgeplay lama ditemukan di folder notproton. File baru ditaruh di sana dulu; Bridgeplay memindahkannya ke folder bridgeplay saat pertama dibuka (tutup Steam dan game dulu)."
fi
mkdir -p "$support/gamefixes" "$support/gamefixes-default" "$support/.installer" "$caches" \
    || die "Folder Bridgeplay di Library tidak bisa dibuat."
rm -rf "$support/gptk" || die "Game Porting Toolkit lama tidak bisa dihapus."
ditto "$here/gptk" "$support/gptk" || die "Game Porting Toolkit gagal disalin."
# Bridgeplay reuses any cached file whose hash matches its pin, so DXMT and DXVK are not
# downloaded again. The WineCX runtime is not in the zip; the app downloads it.
ditto "$here/cache" "$caches" || die "File engine gagal disalin."

# Per-game confs are Bridgeplay's shipped defaults (gamefixes/ in the repository). They go
# to gamefixes-default/, which the app owns and refreshes on every update, so a newer
# default is never hidden behind an old copy. The user's gamefixes/ holds only overrides.
for conf in "$here/config/gamefixes-default/"*.conf; do
    [ -f "$conf" ] || continue
    cp -f "$conf" "$support/gamefixes-default/" || die "Config game gagal disalin."
done
# Installers up to 3.0.1 copied their own per-game confs into the user's gamefixes/,
# where they override the shipped defaults. A copy still byte-identical to one of those
# was never edited, so it goes; an edited one stays.
for old in 1422450:3ec703897532711d09717384333bce001642c16e9b33875e20f685af8fd09279 \
           3669870:e5aa727e1f42de9db3a0975a1837974334dd3691fab13138b299902a68737f02 \
           3764200:fef67384fb54b17d0f9818273f09548b699186e320eeae933b388f3b0aeda02f; do
    f="$support/gamefixes/${old%%:*}.conf"
    [ -f "$f" ] || continue
    [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "${old#*:}" ] || continue
    rm -f "$f" || die "Config game lama tidak bisa dihapus: $f"
done

# Bridgeplay's defaults for every game are gamefixes-default/default.conf, copied above with
# the per-game confs. The user's gamefixes/default.conf holds only their own changes and is
# never written here. On its next start the app trims a copy earlier installers wrote there,
# using .installer/default.conf, the record of that copy, which therefore stays as it is.

# The user's own controller mappings: only seeded when there are none yet.
if [ ! -f "$support/gamecontrollerdb.txt" ]; then
    cp "$here/config/gamecontrollerdb.txt" "$support/" || die "gamecontrollerdb.txt gagal disalin."
fi
xattr -dr com.apple.quarantine "$support" 2>/dev/null || true
# Show the Setup Assistant again even if an earlier Bridgeplay was dismissed.
defaults delete com.bridgeplay.Bridgeplay setupAssistantFinished >/dev/null 2>&1 || true

say "Selesai. Bridgeplay terbuka, ikuti Setup Assistant-nya."
[ "$noninteractive" = 1 ] && exit 0
open /Applications/Bridgeplay.app
sleep 2
osascript -e 'tell application "Terminal" to close (every window whose name contains "Install.command")' >/dev/null 2>&1 &
exit 0
