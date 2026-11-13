#!/usr/bin/env bash
# Builds Segno.vst3 (Release) and installs it for this user, where Live and
# every other VST3 host on the Mac looks: ~/Library/Audio/Plug-Ins/VST3.
#
#   bash packages/segno_engine/vst3/install.sh          # build and install
#   bash packages/segno_engine/vst3/install.sh --test   # and run the null test
#
# The build tree is packages/segno_engine/build/vst3 (not tracked). After an
# install, Live sees the plugins on its next plug-in scan (on start, or
# Settings > Plug-Ins > Rescan).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$here/../build/vst3"
dest="$HOME/Library/Audio/Plug-Ins/VST3"

cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$build" --parallel
mkdir -p "$dest"
rm -rf "$dest/Segno.vst3"
cp -R "$build/Segno.vst3" "$dest/"
echo "installed $dest/Segno.vst3"

if [ "${1:-}" = "--test" ]; then
  "$build/segno_vst3_null_test" "$dest/Segno.vst3"
fi
