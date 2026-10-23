# daw_export

Standalone library that turns a finished performance recording into an
Ableton Live 12 set. `DawManifestReader` reads a capture directory's
`performance.json` and `events.log` into a `DawProject`, `buildAls` renders
that project as a gzipped `.als` file, and `FxChainsWriter` writes a
readable summary of each track's effect chain. It is pure Dart and depends on
neither `segno_engine` nor `performance_repository`: it reads only the
documented file formats. The app's `writeDawProject`
(`lib/performance/application/daw_project_export.dart`) calls it when a take's
render finishes and from the Library's DAW project action.

## Usage

```dart
import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';

void exportCapture(String captureDir) {
  final project = DawManifestReader.read(captureDir);
  if (project != null) {
    File('$captureDir/project.als').writeAsBytesSync(buildAls(project));
  }
  final chains = FxChainsWriter.render(captureDir);
  if (chains != null) {
    File('$captureDir/fx-chains.txt').writeAsBytesSync(utf8.encode(chains));
  }
}
```

## Notes

- Each recorded channel becomes one audio track. Its arrangement clip is the
  channel's rendered stem from `stems/wet/` (or `stems/dry/`), placed at the
  start of the capture; each lane's loop file becomes a session-view clip.
- Volume and mute gestures from `events.log` become automation lanes. Volume
  curves are thinned (`thinVolumeAutomation`); mute steps are kept as logged.
- When a channel's lanes share one chain of built-in effects, the track gets
  Segno VST3 devices and uses the dry stem, so effects are not applied twice.
  Otherwise `DawTrack.deviceChainFallbackReason` says why no chain was written.
- The tempo comes from the manifest; `kFallbackTempoBpm` (120) is used when
  it has none. A missing or corrupt manifest makes `read` and `render` return
  null instead of throwing.
- The `.als` XML is built from public knowledge of the Live set format and
  has not been checked against sets saved by Live 12. `test/corpus/README.md`
  tracks that work.

## Testing

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
