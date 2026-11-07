#!/bin/zsh
# Сборка «Карты диска». Нужны только Command Line Tools: xcode-select --install
set -e
cd "${0:A:h}"
APP="build/Карта диска.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/DiskMap"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$BIN"

if [ ! -f AppIcon.icns ]; then
  T=$(mktemp -d); mkdir "$T/i.iconset"
  "$BIN" --make-icon "$T/icon.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/icon.png" --out "$T/i.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/i.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$T/i.iconset" -o AppIcon.icns
  rm -rf "$T"
fi
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Карта диска</string>
  <key>CFBundleDisplayName</key><string>Карта диска</string>
  <key>CFBundleIdentifier</key><string>local.diskmap</string>
  <key>CFBundleExecutable</key><string>DiskMap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Чтобы показать, что занимает место на Рабочем столе.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Чтобы показать, что занимает место в Документах.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Чтобы показать, что занимает место в Загрузках.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Чтобы показать, что занимает место на внешних дисках.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Чтобы показать, что занимает место на сетевых дисках.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Папка</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
  </dict></array>
</dict></plist>
P
codesign --force --deep -s - "$APP"
echo "Собрано: $PWD/$APP"
