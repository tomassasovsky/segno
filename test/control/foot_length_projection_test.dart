import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/foot_length_actions.dart';
import 'package:segno/control/model/foot_length.dart';
import 'package:segno/looper/model/interaction_mode.dart';

LooperState _state(List<Track> overrides) => LooperState(
  transport: const TransportState(
    isRunning: true,
    masterLengthFrames: 48000,
    loopBars: 2,
  ),
  tracks: [
    for (var i = 0; i < 8; i++)
      overrides.firstWhere(
        (t) => t.channel == i,
        orElse: () => Track(channel: i),
      ),
  ],
  status: const EngineStatus(sampleRate: 48000),
);

void main() {
  const overlay = ControlState(mode: InteractionMode.length, cursor: 1);

  test('a track LED is red only on the selected recorded track', () {
    final looper = _state(const [
      Track(state: TrackState.playing, lengthFrames: 48000),
      Track(channel: 1, state: TrackState.stopped, lengthFrames: 96000),
    ]);
    expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.off);
    expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.red);
    // A selected track that is empty has nothing to edit: dark.
    expect(
      projectTrackLed(looper, overlay.copyWith(cursor: 2), 2),
      PedalTrackLed.off,
    );
  });

  test('the wire frame carries the custom mode; the edit pedals light only '
      'for an accepted contact', () {
    final looper = _state(const [
      Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
    ]);
    final frame = projectFrame(looper, overlay);
    expect(frame.mode, PedalMode.custom);
    final mask = frame.activeButtonMask;
    expect(mask & (1 << PedalButton.track2.index), isNonZero);
    expect(mask & (1 << PedalButton.track1.index), 0);
    // Rec/Play does not report the transport here, nor Clear a clear fade.
    for (final button in [
      PedalButton.recPlay,
      PedalButton.undo,
      PedalButton.clear,
    ]) {
      expect(mask & (1 << button.index), 0, reason: button.name);
    }
    expect(
      projectFrame(looper, overlay, clearFadeActive: true).activeButtonMask &
          (1 << PedalButton.clear.index),
      0,
    );
    final pressed = projectFrame(
      looper,
      overlay,
      acceptedContacts: {PedalButton.undo},
    );
    expect(pressed.activeButtonMask & (1 << PedalButton.undo.index), isNonZero);
  });

  test('the projection reads content, busy, length and bars per track', () {
    final projection = projectFootLength(
      _state(const [
        Track(state: TrackState.playing, lengthFrames: 96000, multiple: 2),
        Track(channel: 1, state: TrackState.recording, lengthFrames: 400),
        Track(
          channel: 2,
          state: TrackState.playing,
          lengthFrames: 24000,
          syncDivisor: 2,
        ),
        Track(
          channel: 3,
          state: TrackState.overdubbing,
          lengthFrames: 48000,
        ),
        Track(
          channel: 4,
          state: TrackState.playing,
          lengthFrames: 48000,
          pending: true,
        ),
        Track(
          channel: 5,
          state: TrackState.playing,
          lengthFrames: 48000,
          layerInFlight: true,
        ),
        Track(
          channel: 6,
          state: TrackState.stopped,
          lengthFrames: 48000,
          pendingLaunch: PendingLaunchAction.play,
        ),
        Track(channel: 7, state: TrackState.stopped, lengthFrames: 12345),
      ]),
      bank: 1,
      cursor: 2,
    );
    expect(projection.trackAt(0).channel, 4);
    expect(projection.selected.channel, 2);
    final doubled = projection.tracks[0];
    expect(doubled.available, isTrue);
    expect((doubled.multiple, doubled.bars), (2, 4));
    final division = projection.tracks[2];
    expect((division.syncDivisor, division.bars), (2, 1));
    // A first take, an overdub, an arm, a landing layer and a Count-in
    // launch are busy; an absent track is empty.
    expect(
      projectFootLength(_state(const []), bank: 0, cursor: 0).selected,
      isA<FootLengthTrack>().having(
        (t) => t.refusal,
        'refusal',
        FootLengthRefusal.empty,
      ),
    );
    for (final channel in [1, 3, 4, 5, 6]) {
      final track = projection.tracks[channel];
      expect(track.hasContent, isTrue, reason: '$channel');
      expect(track.refusal, FootLengthRefusal.busy, reason: '$channel');
    }
    expect(projection.tracks[7].bars, isNull, reason: 'not whole bars');
    expect(projection.tracks[7].beats, isNull, reason: 'nor whole beats');
    // A sole 1-bar loop halved keeps 2 beats and no whole bar (#1168).
    final halved = projectFootLength(
      const LooperState(
        transport: TransportState(
          isRunning: true,
          masterLengthFrames: 48000,
          loopBeats: 2,
        ),
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 48000),
        ],
        status: EngineStatus(sampleRate: 48000),
      ),
      bank: 0,
      cursor: 0,
    ).tracks[0];
    expect((halved.bars, halved.beats), (null, 2));
  });

  test('each engine verdict names its refusal', () {
    expect(footLengthRefusalOf(EngineResult.ok), isNull);
    expect(
      footLengthRefusalOf(EngineResult.modeMismatch),
      FootLengthRefusal.incompatible,
    );
    expect(
      footLengthRefusalOf(EngineResult.capacity),
      FootLengthRefusal.capacity,
    );
    expect(footLengthRefusalOf(EngineResult.notReady), FootLengthRefusal.busy);
    expect(footLengthRefusalOf(EngineResult.invalid), FootLengthRefusal.failed);
  });
}
