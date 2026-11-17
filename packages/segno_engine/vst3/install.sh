#!/usr/bin/env bash
# Builds Segno.vst3 (Release) with its pedal-face editors (build.sh) and
# installs it for this user, where Live and every other VST3 host on the
# Mac looks: ~/Library/Audio/Plug-Ins/VST3.
#
#   bash packages/segno_engine/vst3/install.sh          # build and install
#   bash packages/segno_engine/vst3/install.sh --test   # and run the tests
#
# FLUTTER names the Flutter that renders the pedal faces (build.sh). --test
# runs the null test and the binding test against the installed bundle.
#
# After an install, Live sees the plugins on its next plug-in scan (on
# start, or Settings > Plug-Ins > Rescan).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/Library/Audio/Plug-Ins/VST3"

bundle="$(bash "$here/build.sh")"
build="$(dirname "$bundle")"
mkdir -p "$dest"
rm -rf "$dest/Segno.vst3"
cp -R "$bundle" "$dest/"
echo "installed $dest/Segno.vst3"

if [ "${1:-}" = "--test" ]; then
  bash "$here/test/run_bundle_tests.sh" "$build" "$dest/Segno.vst3"
fi
