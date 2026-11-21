#!/bin/bash
# Builds and signs dist/Segno Transfer.app, with the Segno plugins
# (Segno.vst3, packages/segno_engine/vst3/build.sh) in Contents/PlugIns for
# the app to install on request. FLUTTER names the Flutter 3.50 SDK that
# renders the plugins' pedal faces (default: flutter on the PATH).
set -euo pipefail
cd "$(dirname "$0")"
plugins=$(bash ../../packages/segno_engine/vst3/build.sh)
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app="$PWD/dist/Segno Transfer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SegnoTransfer" "$app/Contents/MacOS/SegnoTransfer"
cp -R "$binary_dir/SegnoTransfer_TransferCore.bundle" "$app/Contents/Resources/"
# AppIcon.icon is an Icon Composer file (Xcode 26). actool compiles it into
# Assets.car, which macOS 26 draws, and AppIcon.icns for macOS 14 and 15.
# actool reports its errors on stdout, so show them when the icon is missing.
if ! icon_log=$(xcrun actool AppIcon.icon --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist /dev/null --output-format human-readable-text 2>&1) ||
  [[ ! -f "$app/Contents/Resources/Assets.car" ||
    ! -f "$app/Contents/Resources/AppIcon.icns" ]]; then
  printf '%s\n' "$icon_log" >&2
  echo "Compiling AppIcon.icon failed; it needs Xcode 26 or newer." >&2
  exit 1
fi
# Nested code goes in a code location (PlugIns), signed before the app.
mkdir -p "$app/Contents/PlugIns"
cp -R "$plugins" "$app/Contents/PlugIns/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SegnoTransfer</string>
<key>CFBundleIdentifier</key><string>dev.segno.transfer</string>
<key>CFBundleName</key><string>Segno Transfer</string>
<key>CFBundleDisplayName</key><string>Segno Transfer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your Segno appliance and download your performance recordings.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
