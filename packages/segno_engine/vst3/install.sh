#!/usr/bin/env bash
# Builds Segno.vst3 (Release) with its pedal-face editors and installs it
# for this user, where Live and every other VST3 host on the Mac looks:
# ~/Library/Audio/Plug-Ins/VST3.
#
#   bash packages/segno_engine/vst3/install.sh          # build and install
#   bash packages/segno_engine/vst3/install.sh --test   # and run the tests
#
# The editors' pictures are rendered first, from the console's own drawing
# code, by a Flutter test (test/vst3_faces/vst3_faces_render_test.dart);
# FLUTTER names the Flutter to run it with (default: flutter on the PATH),
# which must be the SDK the app builds with. --test runs the null test and
# the binding test against the installed bundle.
#
# The build tree is packages/segno_engine/build/vst3 (not tracked). After an
# install, Live sees the plugins on its next plug-in scan (on start, or
# Settings > Plug-Ins > Rescan).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
build="$here/../build/vst3"
faces="$build/faces"
dest="$HOME/Library/Audio/Plug-Ins/VST3"
flutter="${FLUTTER:-flutter}"

rm -rf "$faces"
(cd "$root" && "$flutter" test --tags vst3-faces \
  --dart-define=SEGNO_VST3_FACES_OUT="$faces" \
  test/vst3_faces/vst3_faces_render_test.dart)
cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release \
  -DSEGNO_VST3_FACES="$faces" >/dev/null
cmake --build "$build" --parallel
mkdir -p "$dest"
rm -rf "$dest/Segno.vst3"
cp -R "$build/Segno.vst3" "$dest/"
echo "installed $dest/Segno.vst3"

if [ "${1:-}" = "--test" ]; then
  "$build/segno_vst3_null_test" "$dest/Segno.vst3"
  "$build/segno_vst3_binding_test" "$dest/Segno.vst3" "$here/faces/faces.json" \
    --editors
fi
