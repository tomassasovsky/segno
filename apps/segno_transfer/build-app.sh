#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app="$PWD/dist/Segno Transfer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SegnoTransfer" "$app/Contents/MacOS/SegnoTransfer"
cp -R "$binary_dir/SegnoTransfer_TransferCore.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SegnoTransfer</string>
<key>CFBundleIdentifier</key><string>dev.segno.transfer</string>
<key>CFBundleName</key><string>Segno Transfer</string>
<key>CFBundleDisplayName</key><string>Segno Transfer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your Segno appliance and download your performance recordings.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
