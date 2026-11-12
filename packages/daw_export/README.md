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
  // Live cannot open a set without tracks, and buildAls refuses one.
  if (project != null && project.tracks.isNotEmpty) {
    File('$captureDir/project.als').writeAsBytesSync(buildAls(project));
  }
  final chains = FxChainsWriter.render(captureDir);
  if (chains != null) {
    File('$captureDir/fx-chains.txt').writeAsBytesSync(utf8.encode(chains));
  }
}
```

## Notes

- The set is generated from a set Live 12.2.7 saved
  (`lib/src/live_set_template.dart`, from `test/corpus/automation.als`): its
  one audio track is copied once per recorded channel, so every element and
  default is one Live wrote. `test/corpus/README.md` lists the reference sets
  and what Live checks when it opens a set.
- Each recorded channel becomes one audio track. Its Arrangement clip is the
  channel's rendered stem from `stems/wet/` (or `stems/dry/` when the wet
  render is missing), unwarped, at the start of the capture and as long as
  the file. Each lane's loop becomes a Session clip in the scene of the
  lane's number, warped in Re-Pitch and looping over the whole file at the
  set's tempo, so at that tempo it plays the file unchanged. Clip lengths and
  rates come from the WAV headers.
- Volume and mute gestures from `events.log` become volume and activator
  envelopes, shown in Automation Mode when the set opens. They are written
  only over a dry clip: the wet render already applies them, and Live would
  apply them a second time. Volume is the track gain times lane 0's level,
  as the renderer applies it, and is thinned (`thinVolumeAutomation`); mute
  steps are kept as logged.
- Effects reach Live only as audio, in the wet stem. The set carries no
  devices; `fx-chains.txt` records each lane's chain as text.
- The tempo comes from the manifest; `kFallbackTempoBpm` (120) is used when
  it has none. A missing or corrupt manifest makes `read` and `render` return
  null instead of throwing. A capture with no recorded channel gets no set,
  since Live cannot open a set without tracks.
- The set opens in the Arrangement, zoomed to show the whole capture.

## Testing

```sh
dart test
```

After replacing `test/corpus/automation.als` with a set saved by a newer
Live, regenerate the template:

```sh
dart run tool/generate_live_set_template.dart
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
