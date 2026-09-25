import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/model/interaction_mode.dart';

LooperState _stateWith(
  List<Track> tracks, {
  int masterLengthFrames = 48000,
  int sampleRate = 48000,
  LooperMode looperMode = LooperMode.multi,
  int? songQueuedTrack,
  double songQueueProgress = 0,
}) => LooperState(
  transport: TransportState(
    isRunning: true,
    masterLengthFrames: masterLengthFrames,
    looperMode: looperMode,
    songQueuedTrack: songQueuedTrack,
    songQueueProgress: songQueueProgress,
  ),
  tracks: tracks,
  status: EngineStatus(sampleRate: sampleRate),
);

List<Track> _tracksWith(List<Track> overrides) => [
  for (var i = 0; i < 8; i++)
    overrides.firstWhere(
      (t) => t.channel == i,
      orElse: () => Track(channel: i),
    ),
];

void main() {
  group('isParked', () {
    test('false with no content at all', () {
      expect(isParked(_stateWith(_tracksWith(const []))), isFalse);
    });

    test('true when content exists but nothing runs', () {
      expect(
        isParked(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.stopped, lengthFrames: 48000),
            ]),
          ),
        ),
        isTrue,
      );
    });

    test('false while any content track runs — even muted', () {
      // Mute-ignored: keyboard-muting every track does NOT park.
      expect(
        isParked(
          _stateWith(
            _tracksWith(const [
              Track(
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
            ]),
          ),
        ),
        isFalse,
      );
    });
  });

  group('isSounding', () {
    test('requires content, unmuted, and a running playhead', () {
      expect(
        isSounding(const Track(state: TrackState.playing, lengthFrames: 100)),
        isTrue,
      );
      expect(
        isSounding(
          const Track(state: TrackState.overdubbing, lengthFrames: 100),
        ),
        isTrue,
      );
      expect(
        isSounding(
          const Track(
            state: TrackState.playing,
            muted: true,
            lengthFrames: 100,
          ),
        ),
        isFalse,
      );
      expect(
        isSounding(const Track(state: TrackState.stopped, lengthFrames: 100)),
        isFalse,
      );
      expect(isSounding(const Track()), isFalse);
    });
  });

  group('armedTracks', () {
    test('while parked, the parked-resume set IS the armed set', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.stopped, lengthFrames: 48000),
          Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
        ]),
      );
      const overlay = ControlState(
        mode: InteractionMode.mute,
        parkedResume: {1},
      );
      expect(armedTracks(looper, overlay), {1});
    });

    test('while running, armed = sounding minus excluded — derived fresh', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.playing, lengthFrames: 48000),
          Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          Track(
            channel: 2,
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
        ]),
      );
      const overlay = ControlState(
        mode: InteractionMode.mute,
        excluded: {1},
      );
      expect(armedTracks(looper, overlay), {0});
    });
  });

  group('projectTrackLed', () {
    test('Mute mode: armed and audible reads green, muted reads off', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.playing, lengthFrames: 48000),
          Track(
            channel: 1,
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
        ]),
      );
      const overlay = ControlState(mode: InteractionMode.mute);
      expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.green);
      expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.off);
      expect(projectTrackLed(looper, overlay, 2), PedalTrackLed.off);
    });

    test('Rec mode: the cursor and any capturing track read red', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(channel: 3, state: TrackState.recording),
        ]),
        masterLengthFrames: 0,
      );
      const overlay = ControlState(cursor: 1);
      expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.red);
      expect(projectTrackLed(looper, overlay, 3), PedalTrackLed.red);
      expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.off);
    });

    test(
      'FX mode: blue when the Track chain is engaged, dark when bypassed',
      () {
        final looper = _stateWith(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 48000,
              chainEnabled: false,
            ),
          ]),
        );
        const overlay = ControlState(mode: InteractionMode.fx, cursor: 1);
        expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.blue);
        expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.off);
        // Neither the cursor nor mute/record state leaks into the FX reading:
        // channel 1 is the cursor and still reads dark.
        expect(projectTrackLed(looper, overlay, 2), PedalTrackLed.blue);
      },
    );

    test('FX mode: an EMPTY track with an engaged chain still reads blue', () {
      // The LED reports the flag the stomp toggles, so every stomp gives
      // feedback — a lit LED promises "in circuit", not "has effects".
      final looper = _stateWith(_tracksWith(const []), masterLengthFrames: 0);
      const overlay = ControlState(mode: InteractionMode.fx);
      expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.blue);
    });

    test('FX mode: a channel the engine does not expose reads dark', () {
      final looper = _stateWith(const [Track()], masterLengthFrames: 0);
      const overlay = ControlState(mode: InteractionMode.fx);
      expect(projectTrackLed(looper, overlay, 7), PedalTrackLed.off);
    });

    test('redo after undo-to-empty relights with NO stored set to update', () {
      // The original bug class, retired by derivation: an undone-to-empty
      // track (dark) that redo resurrects reads green off the very next
      // snapshot — nothing stored needs reconciling.
      const overlay = ControlState(mode: InteractionMode.mute);
      final empty = _stateWith(
        _tracksWith(const [Track(redoDepth: 2)]),
      );
      expect(projectTrackLed(empty, overlay, 0), PedalTrackLed.off);

      final resurrected = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.playing, lengthFrames: 48000, redoDepth: 1),
        ]),
      );
      expect(projectTrackLed(resurrected, overlay, 0), PedalTrackLed.green);
    });
  });

  group('Song queued section projection', () {
    LooperState song({
      int? queued = 5,
      double progress = 0,
      bool committed = false,
      LooperMode mode = LooperMode.song,
    }) => _stateWith(
      _tracksWith([
        Track(
          state: committed ? TrackState.stopped : TrackState.playing,
          lengthFrames: 48000,
        ),
        Track(
          channel: 5,
          state: committed ? TrackState.playing : TrackState.stopped,
          muted: !committed,
          lengthFrames: 48000,
        ),
      ]),
      looperMode: mode,
      songQueuedTrack: queued,
      songQueueProgress: progress,
    );
    const mute = ControlState(mode: InteractionMode.mute);

    test('projects measured wait in either bank while source stays green', () {
      for (final bank in [0, 1]) {
        for (final pair in [(0.0, 0), (0.5, 127), (0.999, 254), (1.0, 254)]) {
          final frame = projectFrame(
            song(progress: pair.$1),
            ControlState(mode: InteractionMode.mute, activeBank: bank),
          );
          expect(frame.looperMode, PedalLooperMode.song);
          expect(frame.queuedTrack, 5);
          expect(frame.queuedProgress, pair.$2);
          expect(frame.trackLeds[0], PedalTrackLed.green);
          expect(frame.trackLeds[5], PedalTrackLed.green);
          expect(frame.activeBank, bank);
        }
      }
    });

    test(
      'cancellation clears queued target; handoff extinguishes old source',
      () {
        final cancelled = projectFrame(song(queued: null), mute);
        expect(cancelled.queuedTrack, isNull);
        expect(cancelled.queuedProgress, 0);
        expect(cancelled.trackLeds[0], PedalTrackLed.green);
        expect(cancelled.trackLeds[5], PedalTrackLed.off);
        final committed = projectFrame(
          song(queued: null, committed: true),
          mute,
        );
        expect(committed.queuedTrack, isNull);
        expect(committed.trackLeds[0], PedalTrackLed.off);
        expect(committed.trackLeds[5], PedalTrackLed.green);
      },
    );

    test('queue is hidden outside Song/Mute and for cleared targets', () {
      for (final mode in InteractionMode.values) {
        if (mode == InteractionMode.mute) continue;
        final frame = projectFrame(
          song(progress: 0.5),
          ControlState(mode: mode),
        );
        expect(frame.queuedTrack, isNull);
        expect(frame.queuedProgress, 0);
      }
      for (final mode in LooperMode.values) {
        if (mode == LooperMode.song) continue;
        final frame = projectFrame(song(mode: mode, progress: 0.5), mute);
        expect(frame.queuedTrack, isNull);
        expect(frame.queuedProgress, 0);
        expect(frame.looperMode.index, mode.code);
      }
      final emptyTarget = projectFrame(song(queued: 2), mute);
      expect(emptyTarget.queuedTrack, isNull);
      expect(emptyTarget.trackLeds[2], PedalTrackLed.off);
    });

    test('Song ignores Multi exclusion and parked-resume membership', () {
      final frame = projectFrame(
        song(),
        const ControlState(
          mode: InteractionMode.mute,
          excluded: {0, 5},
          parkedResume: {0},
        ),
      );
      expect(frame.trackLeds[0], PedalTrackLed.green);
      expect(frame.trackLeds[5], PedalTrackLed.green);
    });
  });

  group('projectFrame', () {
    test('carries the overlay cursor / bank / mode onto the wire', () {
      final looper = _stateWith(_tracksWith(const []), masterLengthFrames: 0);
      const overlay = ControlState(cursor: 5, activeBank: 1);
      final frame = projectFrame(looper, overlay);
      expect(frame.selectedTrack, 5);
      expect(frame.activeBank, 1);
      expect(frame.mode, PedalMode.rec);
      expect(frame.clearFadeActive, isFalse);
    });

    test('the mode indicator distinguishes all three modes on the wire', () {
      final looper = _stateWith(_tracksWith(const []), masterLengthFrames: 0);
      // From the frame alone — its MODE field plus the trackLeds meaning it
      // selects — the live mode is identifiable (SC-1).
      const modes = {
        InteractionMode.record: PedalMode.rec,
        InteractionMode.mute: PedalMode.play,
        InteractionMode.fx: PedalMode.fx,
      };
      for (final entry in modes.entries) {
        expect(
          projectFrame(looper, ControlState(mode: entry.key)).mode,
          entry.value,
          reason: '${entry.key.name} must project its own wire mode',
        );
      }
      expect(modes.values.toSet(), hasLength(3)); // no two modes collide
    });

    test('global color: recording red, overdub amber, playing green', () {
      const overlay = ControlState();
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [Track(state: TrackState.recording)]),
            masterLengthFrames: 0,
          ),
          overlay,
        ).globalColor,
        GlobalColor.red,
      );
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.overdubbing, lengthFrames: 48000),
            ]),
          ),
          overlay,
        ).globalColor,
        GlobalColor.amber,
      );
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          ),
          overlay,
        ).globalColor,
        GlobalColor.green,
      );
      // Recording while another loop plays: amber (the blend).
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.recording),
              Track(
                channel: 1,
                state: TrackState.playing,
                lengthFrames: 48000,
              ),
            ]),
          ),
          overlay,
        ).globalColor,
        GlobalColor.amber,
      );
    });

    test('ring length renders only while something holds a loop', () {
      const overlay = ControlState();
      // A loop: one second at 48 kHz reads one million micros.
      final playing = projectFrame(
        _stateWith(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        ),
        overlay,
      );
      expect(playing.loopLengthMicros, 1000000);

      // Undone-to-empty ghost grid: master survives engine-side, but with no
      // content anywhere the ring must go dark.
      final ghost = projectFrame(
        _stateWith(_tracksWith(const [Track(redoDepth: 1)])),
        overlay,
      );
      expect(ghost.loopLengthMicros, 0);
    });

    test('flags the held Clear footswitch', () {
      final frame = projectFrame(
        _stateWith(_tracksWith(const []), masterLengthFrames: 0),
        const ControlState(),
        clearFadeActive: true,
      );
      expect(frame.clearFadeActive, isTrue);
    });

    test('performanceArmed defaults to false when omitted', () {
      final frame = projectFrame(
        _stateWith(_tracksWith(const []), masterLengthFrames: 0),
        const ControlState(),
      );
      expect(frame.performanceArmed, isFalse);
    });

    test('carries performanceArmed: true onto the wire (D-PEDAL)', () {
      final frame = projectFrame(
        _stateWith(_tracksWith(const []), masterLengthFrames: 0),
        const ControlState(),
        performanceArmed: true,
      );
      expect(frame.performanceArmed, isTrue);
    });

    test('asserts the invariant spec on an inconsistent projection input', () {
      // A stored resume set referencing an empty track violates
      // stored-intent-playable — the projection-time assert catches it.
      expect(
        () => projectFrame(
          _stateWith(_tracksWith(const []), masterLengthFrames: 0),
          const ControlState(parkedResume: {3}),
        ),
        throwsA(isA<Error>()),
      );
    });
  });
}
