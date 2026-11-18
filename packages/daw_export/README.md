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
  whose Live save is owed: see the corpus README). Devices come from a set
  Live saved with Segno's plugins in it (`lib/src/live_device_template.dart`,
  from `test/corpus/segno_vst3.als`): a plugin device and an Audio Effect
  Rack. `test/corpus/README.md` lists the reference sets and what Live
  checks when it opens a set.
- The set's tracks, in order (#1799, #1824):
  - each looper track as a Group track, named as the player named it at arm
    or `Track N`, carrying the track's Track stage chain as Segno's plugins
    (the chain the lanes sum into), and holding a pair of tracks for each
    lane `n` (from 1), read from the render's index `stems/stems.json`:
    - `<name> L<n>`: the lane's dry stem (`stems/dry/`), through the lane's
      chain at arm as Segno's VST3 plugins (`packages/segno_engine/vst3`,
      #1804), with the lane's clean loop as its Session clip. It plays.
    - `<name> L<n> (as heard)`: the lane's wet stem (`stems/wet/`), after its
      effects and mix, with the loop as it played. Switched off, so the set
      does not play the lane twice: it is the reference the plugins are
      checked against. It plays when the lane has no dry stem.
    A lane with loops but no rendered stems gets its `L<n>` track with the
    loop alone;
  - each input, named as the player named it or `Input N`. One recorded
    raw (#1805) plays its raw recording on `<name> raw`, through its
    monitor chain at arm as Segno's plugins, with the input as heard
    (after its monitor chain, volume and pan) on `<name> (as heard)`,
    switched off. A take from before #1805 has only the input as heard,
    which plays;
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
- The plugins hold the chains as the take started (`devicesOfChain`): each
  lane's chain on its lane track, and the track's Track stage on its Group.
  Each built-in effect is its plugin, with its settings, channel handling
  and enable bit, the chain slot it held, the owner's hop seed and the
  take's FX clock and beat (`SegnoPluginState`, the plugin's own state
  format), so it renders what the console rendered. A rack is an Audio
  Effect Rack named as the rack, always on: a switched-off rack's entries
  are off by their own Enabled, as the engine runs them. A Dub Rack's
  parallel Amb and Dub paths are a rack of two chains at the gains the
  Amb-Dub Mix gives them. A hosted plugin is left out, as the offline render
  passes it through dry.
- What changed in a chain during the take is automation of its devices
  (#1836, `ChainTimeline`): `events.log`'s switches, settings, types and
  chain lengths for each lane's chain and each input's monitor chain,
  replayed as the offline render replays them for the wet stem. An
  entry's switch, a rack switch or an A/B press included (they arrive as
  the entries' switches), is the plugin's Enabled parameter (1100), which
  ramps and drains as the engine's switch does; Live's Device On stays on,
  as it stops the plugin and cuts its tail. A setting is its parameter. Each
  change is a step, two events at its frame's beat (the value before, then
  after), with every change kept: the console logs a setting once a block
  at most, when it moves. A slot whose effect changed holds one plugin per
  effect, each on while the slot held it. Racks stay on; a Dub Rack's
  Amb / Dub section is on while any entry of the rack runs. The track shows
  its volume lane, or its first device envelope's.
- Each track's info text (Live's Info View) lists the effect chains it
  started with; `fx-chains.txt` holds the same for the whole take.
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
