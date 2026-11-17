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
  one audio track is copied once per track, so every element and default is
  one Live wrote. Group tracks are copied from
  `lib/src/live_group_track_template.dart` (from `test/corpus/group.als`,
  whose Live save is owed: see the corpus README). `test/corpus/README.md` lists the reference sets
  and what Live checks when it opens a set.
- The set's tracks, in order (#1799, #1824):
  - each looper track as a Group track, named as the player named it at arm
    or `Track N`, holding a pair of tracks for each lane `n` (from 1), read
    from the render's index `stems/stems.json`:
    - `<name> L<n>`: the lane's dry stem (`stems/dry/`), at unity and before
      its effects, with the lane's clean loop as its Session clip. It plays.
    - `<name> L<n> (as heard)`: the lane's wet stem (`stems/wet/`), after its
      effects and mix, with the loop as it played. Switched off, so the set
      does not play the lane twice; it plays when the lane has no dry stem.
    A lane with loops but no rendered stems gets its `L<n>` track with the
    loop alone. The lane tracks carry no devices yet: the lane's chain is
    told in their info text, and placing it as Segno's plugins is #1804's;
  - each captured input, named as the player named it or `Input N`. The
    engine records an input after its monitor chain, volume and pan, so this
    is the input as heard, and it plays beside the loops;
  - `Master (as heard)`: the captured output, which holds all of the above,
    switched off.
  An input or the master recorded in several part files has one clip per
  part, end to end.
- Arrangement clips are unwarped and as long as their files. Each lane's
  loop is a Session clip in the first scene, so launching it plays every
  lane together, warped in Re-Pitch and looping over the whole file at the
  set's tempo, so at that tempo it plays the file unchanged. Lengths and
  rates come from the WAV headers.
- A lane's dry track carries the logged volume and mute as volume
  automation (the track gain times the lane's level, silent while the lane
  is muted or under another track's solo), shown in Automation Mode. The wet
  render already applies them, so the as-heard track carries none.
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

After replacing the corpus with sets saved by a newer Live, regenerate the
templates:

```sh
dart run tool/generate_live_set_template.dart
dart run tool/generate_live_group_track_template.dart
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
