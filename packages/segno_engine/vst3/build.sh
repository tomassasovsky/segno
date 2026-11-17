#!/usr/bin/env bash
# Builds Segno.vst3 (Release) with its pedal-face editors into the build
# tree packages/segno_engine/build/vst3 (not tracked), with its null test
# and binding test beside it. install.sh installs the result for this
# user; Segno Transfer's build-app.sh bundles it inside the app.
#
#   bash packages/segno_engine/vst3/build.sh
#
# The editors' pictures are rendered first, from the console's own drawing
# code, by a Flutter test (test/vst3_faces/vst3_faces_render_test.dart);
# FLUTTER names the Flutter to run it with (default: flutter on the PATH),
# which must be the SDK the app builds with. Prints the bundle's path.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
build="$(cd "$here/.." && pwd)/build/vst3"
faces="$build/faces"
flutter="${FLUTTER:-flutter}"

rm -rf "$faces"
# The faces draw localized text; a fresh checkout has no generated
# localizations until gen-l10n runs.
(cd "$root" && "$flutter" gen-l10n && "$flutter" test --tags vst3-faces \
  --dart-define=SEGNO_VST3_FACES_OUT="$faces" \
  test/vst3_faces/vst3_faces_render_test.dart) >&2
cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release \
  -DSEGNO_VST3_FACES="$faces" >/dev/null
cmake --build "$build" --parallel >&2
echo "$build/Segno.vst3"
