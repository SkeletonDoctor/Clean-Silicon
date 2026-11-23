#!/bin/zsh
# Builds "Clean Silicon.app" into ./build. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
swift build -c release
# Staged outside the project: synced folders (Desktop, iCloud) add attributes that break code signing.
STAGE="$(mktemp -d)"
APP="$STAGE/Clean Silicon.app"
mkdir -p build
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CleanSilicon "$APP/Contents/MacOS/CleanSilicon"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Scripts/icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Clean Silicon</string>
  <key>CFBundleDisplayName</key><string>Clean Silicon</string>
  <key>CFBundleIdentifier</key><string>com.cleansilicon.app</string>
  <key>CFBundleExecutable</key><string>CleanSilicon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION_OVERRIDE:-$VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION_OVERRIDE:-$VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$APP"
# A stable certificate keeps Full Disk Access granted across rebuilds and updates; ad-hoc signing resets it
# every time. Release builds use the self-signed "Clean Silicon" certificate in its own keychain when it
# exists (nothing personal in it); otherwise a developer certificate, otherwise ad-hoc.
KEYCHAIN="$HOME/Library/Keychains/cleansilicon-signing.keychain-db"
PASSFILE="$HOME/.config/cleansilicon/keychain_password"
if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
  codesign --force --sign "Clean Silicon" --keychain "$KEYCHAIN" "$APP"
else
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ {print $2; exit}')
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
rm -rf "build/Clean Silicon.app"
ditto "$APP" "build/Clean Silicon.app"
echo "Built build/Clean Silicon.app"
if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/Clean Silicon.app"
  ditto "$APP" "/Applications/Clean Silicon.app"
  echo "Installed to /Applications"
fi
rm -rf "$STAGE"
