import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_reverse.dart';
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
  const overlay = ControlState(mode: InteractionMode.reverse);

  test('a track LED is blue only while its recorded track plays reversed', () {
    final looper = _state(const [
      Track(state: TrackState.playing, lengthFrames: 48000),
      Track(
        channel: 1,
        state: TrackState.playing,
        lengthFrames: 48000,
        reversed: true,
      ),
      // A stopped reversed track still reports its direction.
      Track(
        channel: 2,
        state: TrackState.stopped,
        lengthFrames: 48000,
        reversed: true,
      ),
      // Clear publishes EMPTY with the direction reset; an empty track that
      // still read reversed stays dark.
      Track(channel: 3, reversed: true),
    ]);
    expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.off);
    expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.blue);
    expect(projectTrackLed(looper, overlay, 2), PedalTrackLed.blue);
    expect(projectTrackLed(looper, overlay, 3), PedalTrackLed.off);
  });

  test('the wire frame carries the custom mode and Undo/Clear stay dark', () {
    final looper = _state(const [
      Track(state: TrackState.playing, lengthFrames: 48000, reversed: true),
    ]);
    final frame = projectFrame(looper, overlay);
    expect(frame.mode, PedalMode.custom);
    final mask = frame.activeButtonMask;
    expect(mask & (1 << PedalButton.track1.index), isNonZero);
    expect(mask & (1 << PedalButton.track2.index), 0);
    expect(mask & (1 << PedalButton.undo.index), 0);
    expect(mask & (1 << PedalButton.clear.index), 0);
    // Slot-less pedals do not report the transport here: Rec/Play stays dark
    // while a loop plays, and Clear stays dark during a clear fade.
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

  test('the projection reads recorded, busy and direction per track', () {
    final projection = projectFootReverse(
      _state(const [
        Track(state: TrackState.playing, lengthFrames: 48000, reversed: true),
        Track(channel: 1, state: TrackState.recording),
        Track(
          channel: 3,
          state: TrackState.overdubbing,
          lengthFrames: 48000,
          reversed: true,
        ),
        Track(
          channel: 4,
          state: TrackState.playing,
          lengthFrames: 48000,
          pending: true,
        ),
        Track(channel: 5, state: TrackState.playing, lengthFrames: 48000),
      ]),
      bank: 1,
    );
    FootReverseTrack track(int channel) => projection.tracks[channel];
    expect(projection.trackAt(1).channel, 5);
    expect(track(5), _track(5, recorded: true, busy: false, reversed: false));
    expect(track(0), _track(0, recorded: true, busy: false, reversed: true));
    // A first take has no direction yet; an absent track is empty.
    expect(track(1).recorded, isFalse);
    expect(track(2), _track(2, recorded: false, busy: false, reversed: false));
    // Overdubbing and a pending arm keep the real direction, but are busy.
    expect(track(3), _track(3, recorded: true, busy: true, reversed: true));
    expect(track(4), _track(4, recorded: true, busy: true, reversed: false));
  });
}

FootReverseTrack _track(
  int channel, {
  required bool recorded,
  required bool busy,
  required bool reversed,
}) => FootReverseTrack(
  channel: channel,
  recorded: recorded,
  busy: busy,
  reversed: reversed,
);
