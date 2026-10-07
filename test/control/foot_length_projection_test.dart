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
  const overlay = ControlState(mode: InteractionMode.multiply, cursor: 1);

  test('the two role tables follow pen 16', () {
    final multiply = FootLengthProjection.rolesFor(InteractionMode.multiply);
    final divide = FootLengthProjection.rolesFor(InteractionMode.divide);
    expect(multiply[PedalButton.recPlay]!.press, FootLengthAction.recordPlay);
    expect(multiply[PedalButton.undo]!.press, FootLengthAction.undo);
    expect(multiply[PedalButton.undo]!.hold, FootLengthAction.redo);
    expect(multiply[PedalButton.clear]!.press, FootLengthAction.doubleTrack);
    expect(divide[PedalButton.recPlay]!.press, FootLengthAction.recordPlay);
    expect(divide[PedalButton.undo]!.press, FootLengthAction.firstHalf);
    expect(divide[PedalButton.undo]!.hold, FootLengthAction.undo);
    expect(divide[PedalButton.clear]!.press, FootLengthAction.lastHalf);
    for (final roles in [multiply, divide]) {
      expect(roles.keys, unorderedEquals(PedalButton.values));
      expect(roles[PedalButton.stop]!.press, FootLengthAction.stop);
      expect(roles[PedalButton.mode]!.press, FootLengthAction.exit);
      expect(roles[PedalButton.bank]!.press, FootLengthAction.nextBank);
      expect(roles[PedalButton.track3]!.slot, 2);
    }
  });

  test('an outcome binds once both length and undo depth moved, and '
      'describes only that exact state', () {
    FootLengthTrack track(int frames, int depth) => FootLengthTrack(
      channel: 0,
      hasContent: true,
      busy: false,
      lengthFrames: frames,
      multiple: 1,
      syncDivisor: 0,
      undoDepth: depth,
    );
    const pending = FootLengthOutcome(
      channel: 0,
      edit: LengthEdit.doubled,
      fromFrames: 96000,
      fromUndoDepth: 1,
    );
    // Either half published alone does not bind it.
    expect(pending.bindTo(track(192000, 1)).bound, isFalse);
    expect(pending.bindTo(track(96000, 2)).bound, isFalse);
    expect(pending.describes(track(192000, 2)), isFalse);
    final bound = pending.bindTo(track(192000, 2));
    expect(bound.bound, isTrue);
    expect(bound.describes(track(192000, 2)), isTrue);
    // Undone once, then again past its start: never "Repeated to 1 bar".
    expect(bound.describes(track(96000, 1)), isFalse);
    expect(bound.describes(track(48000, 0)), isFalse);
    // An overdub on top keeps the length but not the depth.
    expect(bound.describes(track(192000, 3)), isFalse);
    // Another track never.
    expect(
      bound.describes(
        const FootLengthTrack(
          channel: 1,
          hasContent: true,
          busy: false,
          lengthFrames: 192000,
          multiple: 1,
          syncDivisor: 0,
          undoDepth: 2,
        ),
      ),
      isFalse,
    );
  });

  test('Divide halves count bars when each half is whole bars, else beats', () {
    FootLengthTrack track({int? bars, int? totalBeats}) => FootLengthTrack(
      channel: 0,
      hasContent: true,
      busy: false,
      lengthFrames: 1,
      multiple: 1,
      syncDivisor: 0,
      bars: bars,
      totalBeats: totalBeats,
    );
    // Pen 16: 2 bars -> Bar 1 / Bar 2; 1 bar of 4/4 -> Beats 1-2 / 3-4;
    // 3 bars -> Beats 1-6 / 7-12.
    expect(
      track(bars: 2, totalBeats: 8).halves,
      const FootLengthHalves(inBars: true, half: 1),
    );
    expect(
      track(bars: 1, totalBeats: 4).halves,
      const FootLengthHalves(inBars: false, half: 2),
    );
    expect(
      track(bars: 3, totalBeats: 12).halves,
      const FootLengthHalves(inBars: false, half: 6),
    );
    expect(track(totalBeats: 3).halves, isNull, reason: 'half a beat');
    expect(track().halves, isNull, reason: 'no grid');
  });

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
    expect(
      projectFrame(
        looper,
        overlay.copyWith(mode: InteractionMode.divide),
      ).mode,
      PedalMode.custom,
    );
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
