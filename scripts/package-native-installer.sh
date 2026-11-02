#!/bin/sh
# Build the small native bootstrap without Wine, GPTK or the product payload, as a ZIP with
# the app, LICENSE and NOTICE. A release build is notarized, so macOS only asks once whether
# to open an app downloaded from the internet; the app carries its own font licences.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
identity=${BRIDGEPLAY_SIGN_IDENTITY:--}
configuration=${CONFIGURATION:-release}
out="$repo/out/native-installer"
app="$out/Bridgeplay Installer.app"
zip="$repo/out/Bridgeplay-Setup.zip"

swift build --package-path app -c "$configuration" --product BridgeplayInstaller --arch arm64
bin=$(swift build --package-path app -c "$configuration" --show-bin-path --arch arm64)
[ -x "$bin/BridgeplayInstaller" ] || { echo 'Installer executable missing' >&2; exit 1; }
mkdir -p "$out"
stage=$(mktemp -d "$out/.package.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
bundle="$stage/Bridgeplay Installer.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/BridgeplayInstaller" "$bundle/Contents/MacOS/BridgeplayInstaller"
for resource in BridgeplayApp_BridgeplayUI.bundle BridgeplayApp_BridgeplayInstaller.bundle; do
    ditto "$bin/$resource" "$bundle/Contents/Resources/$resource"
done
python3 - "$repo/app/Sources/BridgeplayInstaller/Resources/Localization/Localizable.xcstrings" "$bundle/Contents/Resources/BridgeplayApp_BridgeplayInstaller.bundle" <<'PYTHON'
import json
import pathlib
import sys
catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
bundle = pathlib.Path(sys.argv[2])
root = bundle / "Contents" / "Resources" if (bundle / "Contents" / "Resources").is_dir() else bundle
for language in ("en", "it", "ru", "zh-Hans"):
    folder = root / (language + ".lproj")
    folder.mkdir(exist_ok=True)
    values = []
    for key, entry in sorted(catalog["strings"].items()):
        value = key if language == "en" else entry["localizations"][language]["stringUnit"]["value"]
        values.append(json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";")
    (folder / "Localizable.strings").write_text("\n".join(values) + "\n", encoding="utf-16")
(root / "Localizable.xcstrings").unlink(missing_ok=True)
PYTHON
"$bin/BridgeplayInstaller" --icon "$stage/icon.png"
mkdir "$stage/Bridgeplay.iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$stage/icon.png" --out "$stage/Bridgeplay.iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$stage/icon.png" --out "$stage/Bridgeplay.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Bridgeplay.iconset" -o "$bundle/Contents/Resources/Bridgeplay.icns"
rm -rf "$stage/icon.png" "$stage/Bridgeplay.iconset"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.bridgeplay.Installer</string>
<key>CFBundleName</key><string>Bridgeplay Installer</string>
<key>CFBundleDisplayName</key><string>Bridgeplay Installer</string>
<key>CFBundleExecutable</key><string>BridgeplayInstaller</string>
<key>CFBundleIconFile</key><string>Bridgeplay</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>it</string><string>ru</string><string>zh-Hans</string></array>
<key>NSDownloadsFolderUsageDescription</key><string>Moves this installer disk image to Trash after you choose Finish.</string>
</dict></plist>
PLIST
cp LICENSE "$bundle/Contents/Resources/LICENSE"
# A Developer ID build gets the hardened runtime and a timestamp and is notarized, so the
# downloaded installer opens without Open Anyway. Ad hoc and other identities stay as they were.
case "$identity" in
    "Developer ID Application: "*)
        codesign --force --sign "$identity" --options runtime --timestamp "$bundle"
        codesign --verify --strict --deep "$bundle"
        "$repo/scripts/notarize.sh" "$bundle"
        ;;
    *)
        codesign --force --sign "$identity" "$bundle"
        codesign --verify --strict --deep "$bundle"
        ;;
esac
# Only replace previous local packaging outputs after a complete bundle is available.
rm -rf "$app"
ditto "$bundle" "$app"
package="$stage/package"
mkdir -p "$package"
ditto "$app" "$package/Bridgeplay Installer.app"
cp LICENSE NOTICE "$package/"
rm -f "$zip"
(cd "$package" && ditto -c -k --norsrc --noextattr . "$zip")
size=$(stat -f '%z' "$zip")
limit=${BRIDGEPLAY_INSTALLER_MAX_BYTES:-5242880}
if [ "$size" -gt "$limit" ]; then
    echo "Installer ZIP exceeds size budget: $size > $limit bytes" >&2
    exit 1
fi
printf 'ZIP: %s\nSize: %s bytes (budget %s)\n' "$zip" "$size" "$limit"
shasum -a 256 "$zip"
