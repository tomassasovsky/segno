#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="$PWD/dist/Segno Transfer.app"
codesign --verify --deep --strict "$app"
architecture=$(lipo -archs "$app/Contents/MacOS/SegnoTransfer")
if [[ "$architecture" != arm64 ]]; then
  echo "Release packages currently require an Apple Silicon build." >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The app version must have three numeric components." >&2
  exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/segno-transfer-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Segno Transfer.app"
ln -s /Applications "$staging/Applications"
cp INSTALL.txt "$staging/Read Me.txt"
cp ../../LICENSE "$staging/LICENSE.txt"

filename="Segno-Transfer-$version-macos-arm64.dmg"
hdiutil create -quiet -ov -volname 'Segno Transfer' -fs HFS+ -format UDZO \
  -srcfolder "$staging" "$PWD/dist/$filename"
hdiutil verify "$PWD/dist/$filename"
(cd dist && shasum -a 256 "$filename" > SHA256SUMS)
printf '%s\n' "$PWD/dist/$filename"
