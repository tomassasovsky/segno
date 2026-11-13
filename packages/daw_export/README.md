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
- The set's tracks, in order (#1799):
  - each looper track over its wet stem (`stems/wet/`), named as the player
    named it at arm or `Track N`, with its lane loops as Session clips;
  - right after it, its dry stem (`stems/dry/`) on a track named
    `<name> dry`, switched off so the set does not play the take twice;
    switch it on (and the wet one off) to process the take again. A track
    whose wet render is missing plays its dry stem on its own track;
  - each captured input, named as the player named it or `Input N`. The
    engine records an input after its monitor chain, volume and pan, so this
    is the input as heard, and it plays beside the loops;
  - `Master (as heard)`: the captured output, which holds all of the above,
    switched off.
  An input or the master recorded in several part files has one clip per
  part, end to end.
- Arrangement clips are unwarped and as long as their files. Each lane's
  loop is a Session clip in the scene of the lane's number, warped in
  Re-Pitch and looping over the whole file at the set's tempo, so at that
  tempo it plays the file unchanged. Lengths and rates come from the WAV
  headers.
- The dry track carries the logged volume and mute as volume automation
  (the track gain times lane 0's level, silent while muted or under another
  track's solo), shown in Automation Mode. The wet render already applies
  them, so the wet track carries none.
- Each track's info text (Live's Info View) lists the effect chains it
  started with; `fx-chains.txt` holds the same for the whole take. Effects
  reach Live only as audio: the set carries no devices.
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
