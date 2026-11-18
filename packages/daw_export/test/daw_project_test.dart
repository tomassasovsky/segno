import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

void main() {
  group('DawProject', () {
    test('defaults tempoBpm to 120', () {
      expect(const DawProject(tracks: []).tempoBpm, kFallbackTempoBpm);
      expect(kFallbackTempoBpm, 120);
    });

    test('normalizes a non-positive tempoBpm (a manifest\'s "unset") to the '
        'fallback', () {
      expect(const DawProject(tracks: [], tempoBpm: 0).tempoBpm, 120);
      expect(const DawProject(tracks: [], tempoBpm: -5).tempoBpm, 120);
    });

    test('carries an explicit tempo and its tracks', () {
      const track = DawTrack(name: 'Track 0');
      const project = DawProject(tracks: [track], tempoBpm: 93.5);
      expect(project.tempoBpm, 93.5);
      expect(project.tracks, [track]);
    });
  });

  group('DawTrack', () {
    test('defaults to an active track with nothing in it', () {
      const track = DawTrack(name: 'Track 1');
      expect(track.active, isTrue);
      expect(track.kind, DawTrackKind.lane);
      expect(track.group, isNull);
      expect(track.arrangementClips, isEmpty);
      expect(track.loop, isNull);
      expect(track.volume, isNull);
      expect(track.info, '');
    });

    test('may have no Arrangement clip, only its loop', () {
      const loop = DawAudioFile(
        fileRef: 'loops/track0-lane0.wav',
        sampleRate: 48000,
        frames: 96000,
      );
      const track = DawTrack(name: 'Track 0', loop: loop);
      expect(track.arrangementClips, isEmpty);
      expect(track.loop, loop);
    });

    test('sits in the Group it names', () {
      const group = DawGroup(name: 'Rhythm', info: 'Lane 1: Delay');
      const track = DawTrack(name: 'Rhythm L1', group: group);
      expect(track.group, same(group));
      expect((group.name, group.info), ('Rhythm', 'Lane 1: Delay'));
      expect(const DawGroup(name: 'Bass').info, '');
    });
  });

  group('DawAudioFile', () {
    test('its length in seconds is frames over rate', () {
      const audio = DawAudioFile(
        fileRef: 'stems/wet/track0.wav',
        sampleRate: 96000,
        frames: 144000,
      );
      expect(audio.seconds, 1.5);
    });
  });

  group('DawClip', () {
    test('carry their file and placement verbatim', () {
      const audio = DawAudioFile(
        fileRef: 'stems/wet/track0.wav',
        sampleRate: 48000,
        frames: 48000,
      );
      const clip = DawClip(audio: audio, startSeconds: 2);
      expect(clip.audio, audio);
      expect(clip.startSeconds, 2);
    });
  });

  group('AutomationLane', () {
    test('carries its initial value and breakpoints', () {
      const lane = AutomationLane(
        initialValue: 0.5,
        breakpoints: [AutomationBreakpoint(beat: 4, value: 1)],
      );
      expect(lane.initialValue, 0.5);
      expect(lane.breakpoints.single.beat, 4);
      expect(lane.breakpoints.single.value, 1);
    });
  });
}
