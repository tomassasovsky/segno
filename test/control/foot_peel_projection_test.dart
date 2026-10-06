import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_peel.dart';
import 'package:segno/looper/model/interaction_mode.dart';

LooperState _state(List<Track> overrides) => LooperState(
  transport: const TransportState(isRunning: true, masterLengthFrames: 48000),
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
  const overlay = ControlState(mode: InteractionMode.peel);

  test('a track LED is blue only while a press would peel', () {
    final looper = _state(const [
      Track(state: TrackState.playing, lengthFrames: 48000, peelDepth: 2),
      // The original only: nothing to peel.
      Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
      // A stopped track still peels.
      Track(
        channel: 2,
        state: TrackState.stopped,
        lengthFrames: 48000,
        peelDepth: 1,
      ),
      Track(channel: 3),
      Track(
        channel: 4,
        state: TrackState.overdubbing,
        lengthFrames: 48000,
        peelDepth: 1,
      ),
      Track(
        channel: 5,
        state: TrackState.playing,
        lengthFrames: 48000,
        peelDepth: 1,
        layerInFlight: true,
      ),
      Track(
        channel: 6,
        state: TrackState.playing,
        lengthFrames: 48000,
        peelDepth: 1,
        pendingLaunch: PendingLaunchAction.play,
      ),
    ]);
    expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.blue);
    expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.off);
    expect(projectTrackLed(looper, overlay, 2), PedalTrackLed.blue);
    expect(projectTrackLed(looper, overlay, 3), PedalTrackLed.off);
    expect(projectTrackLed(looper, overlay, 4), PedalTrackLed.off);
    expect(projectTrackLed(looper, overlay, 5), PedalTrackLed.off);
    expect(projectTrackLed(looper, overlay, 6), PedalTrackLed.off);
  });

  test('the wire frame carries the custom mode and Undo/Clear stay dark', () {
    final looper = _state(const [
      Track(state: TrackState.playing, lengthFrames: 48000, peelDepth: 1),
    ]);
    final frame = projectFrame(looper, overlay);
    expect(frame.mode, PedalMode.custom);
    final mask = frame.activeButtonMask;
    expect(mask & (1 << PedalButton.track1.index), isNonZero);
    expect(mask & (1 << PedalButton.track2.index), 0);
    expect(mask & (1 << PedalButton.undo.index), 0);
    expect(mask & (1 << PedalButton.clear.index), 0);
    // Slot-less pedals do not report the transport here.
    expect(mask & (1 << PedalButton.recPlay.index), 0);
    expect(
      projectFrame(looper, overlay, clearFadeActive: true).activeButtonMask &
          (1 << PedalButton.clear.index),
      0,
    );
    // A slot-less pedal lights only for its accepted contact.
    final pressed = projectFrame(
      looper,
      overlay,
      acceptedContacts: {PedalButton.stop},
    );
    expect(pressed.activeButtonMask & (1 << PedalButton.stop.index), isNonZero);
  });

  test('a busy recorded track keeps its layers and says why it waits', () {
    final projection = projectFootPeel(
      _state(const [
        Track(state: TrackState.playing, lengthFrames: 48000, peelDepth: 2),
        Track(
          channel: 1,
          state: TrackState.overdubbing,
          lengthFrames: 48000,
          peelDepth: 1,
        ),
        Track(channel: 2, state: TrackState.playing, lengthFrames: 48000),
        Track(channel: 5, state: TrackState.playing, lengthFrames: 48000),
      ]),
      bank: 1,
    );
    expect(projection.trackAt(1).channel, 5);
    final [peelable, busy, original, empty, ...] = projection.tracks;
    expect(peelable.layers, 3);
    expect(peelable.available, isTrue);
    expect(peelable.refusal, isNull);
    expect(busy.hasContent, isTrue, reason: 'never reads Empty');
    expect(busy.layers, 2);
    expect(busy.available, isFalse);
    expect(busy.refusal, FootPeelRefusal.busy);
    expect(original.layers, 1);
    expect(original.refusal, FootPeelRefusal.originalOnly);
    expect(empty.hasContent, isFalse);
    expect(empty.refusal, FootPeelRefusal.empty);
  });
}
