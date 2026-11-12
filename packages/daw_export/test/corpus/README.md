# Corpus: sets saved by Ableton Live

Reference sets saved by **Ableton Live 12.2.7 Suite** (macOS, build
2025-11-03_828a8aa814; in the files, `MinorVersion="12.0_12203"`,
`Creator="Ableton Live 12.2.7"`). `buildAls` generates sets from
`automation.als`, and `test/als_builder_test.dart` compares what it writes
with all of them (#1791).

| File | What it holds |
|------|---------------|
| `empty.als` | Live's new set as it ships (`DefaultLiveSet.als`): two MIDI tracks, two audio tracks, two return tracks. |
| `audio_clips.als` | One audio track, `tone.wav` as an unwarped clip at bar 2 of the Arrangement and in the first Session slot. |
| `automation.als` | `audio_clips.als` plus a volume envelope (1 at beat 0, 0.25 at beat 4, 0.708 at beat 8) and an activator envelope (off at beat 2, on at beat 6). The template: `lib/src/live_set_template.dart` is this file, decompressed. |
| `tempo.als` | `audio_clips.als` at 93.5 BPM. |
| `session_loop_warped.als` | `audio_clips.als` with the Session clip warped and looping, the form `buildAls` gives lane loops. |
| `vst3.als` | One audio track with a VST3 effect (TAL-Filter-2 3.1.2) as Live stores it: a `PluginDevice` whose `Vst3PluginInfo` names the plugin's class id as four signed 32-bit `Uid` fields, with the plugin's own state in a `Vst3Preset`. Nothing generates devices today (#1587); this is the shape a device chain would need. |
| `tone.wav` | 2400 frames of a 440 Hz sine, 48 kHz, 16-bit mono (4.8 KB), which the sets reference. |

## How they were made

The sets were saved by Live itself, so every element and default is Live's
own. The session that made them could not drive Live's interface in the
foreground, so each set started as a file and Live finished it:

1. A script built each input from Live's bundled
   `Contents/App-Resources/Builtin/Templates/DefaultLiveSet.als`, removing
   tracks and adding clips, envelopes, the tempo or the device, with an
   `AudioClip` copied from a lesson set Live ships.
2. Live 12.2.7 opened the input from a folder marked as a Live Project (an
   empty `Ableton Project Info` folder), a reversible change (a track
   switched off and on, or armed and disarmed) marked it edited, and Live
   saved it with Save As over the input.

Live rewrote every element on save: the 12.2 header, elements a 12.1 set
lacks (`ArrangementClipsListWrapper`, `TakeLanesListWrapper`,
`MpePitchBendUsesTuning`), file sizes and checksums, and for the VST3 set the
full device. To refresh the corpus for a newer Live, open each set in it, save
it, copy it back here, and run `dart run tool/generate_live_set_template.dart`.

## What Live checks

Found by opening generated sets in Live 12.2.7:

- Every member of a list carries an `Id`, automation events included. A
  `FloatEvent` without one makes Live refuse the whole set ("Not all list
  members have Ids").
- A set needs at least one track ("Set has no player tracks").
- A set claiming an older Live opens, but Live will only save it as a new
  file.
- Live saves a set only inside a Live Project folder. Segno's capture folder
  is not one, so saving an opened export asks where to put the project.
- An unwarped clip's `Loop` markers are seconds of its file, and
  `CurrentStart`/`CurrentEnd` beats on the timeline. Live loops only a warped
  clip.
- A `FileRef` with `RelativePathType` 1 resolves its `RelativePath` against
  the set's folder when its `Path` does not exist, so a capture folder can be
  moved anywhere.
- In the Arrangement lane chooser of an audio track with no devices or sends,
  `SelectedDevice` 1 is the Mixer, and its `SelectedEnvelope` 0 is the
  activator ("Speaker On") and 2 the volume.
