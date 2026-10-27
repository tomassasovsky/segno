import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/backing/model/backing_state.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';

void main() {
  group('powerRefusal', () {
    test('a take in flight refuses', () {
      expect(
        powerRefusal(const PowerSnapshot(takeInFlight: true)),
        PowerRefusal.take,
      );
    });

    test('an update in flight refuses', () {
      expect(
        powerRefusal(const PowerSnapshot(updateInFlight: true)),
        PowerRefusal.update,
      );
    });

    test('a transfer in flight refuses', () {
      expect(
        powerRefusal(const PowerSnapshot(transferInFlight: true)),
        PowerRefusal.transfer,
      );
    });

    test('a take comes first, then an update, then a transfer', () {
      expect(
        powerRefusal(
          const PowerSnapshot(
            takeInFlight: true,
            updateInFlight: true,
            transferInFlight: true,
          ),
        ),
        PowerRefusal.take,
      );
      // A USB update package's copy holds a storage lease too.
      expect(
        powerRefusal(
          const PowerSnapshot(updateInFlight: true, transferInFlight: true),
        ),
        PowerRefusal.update,
      );
    });

    test('anything else proceeds, named or not', () {
      expect(powerRefusal(const PowerSnapshot()), isNull);
      expect(
        powerRefusal(const PowerSnapshot(currentSessionName: 'set')),
        isNull,
      );
    });
  });

  group('powerSnapshotOf', () {
    test('maps capturing from tracks', () {
      const looper = LooperState(
        tracks: [
          Track(
            state: TrackState.recording,
            lengthFrames: 48000,
          ),
        ],
      );
      final snapshot = powerSnapshotOf(
        looper: looper,
        recorder: const PerformanceRecorderIdle(),
        session: const SessionState(),
        backing: const BackingState(),
      );
      expect(snapshot.takeInFlight, isTrue);
    });

    test('maps pending, punch-tail, and count-in as in-flight', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(tracks: [Track(pending: true)]),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(
            tracks: [Track(layerInFlight: true)],
          ),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(
            transport: TransportState(countingIn: true),
          ),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
    });

    test('Armed / Finalizing / Rendering / recovering are in-flight', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(recovering: true),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderArmed(
            elapsed: Duration.zero,
            overrun: false,
          ),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderFinalizing(),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderRendering(percent: 10),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isTrue,
      );
    });

    test('Completed is not in-flight', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderCompleted.discardedShort(),
          session: const SessionState(),
          backing: const BackingState(),
        ).takeInFlight,
        isFalse,
      );
    });

    test('carries the storage transfer flag it is given, and none by '
        'default', () {
      PowerSnapshot read({bool? transfer}) => transfer == null
          ? powerSnapshotOf(
              looper: const LooperState(),
              recorder: const PerformanceRecorderIdle(),
              session: const SessionState(),
              backing: const BackingState(),
            )
          : powerSnapshotOf(
              looper: const LooperState(),
              recorder: const PerformanceRecorderIdle(),
              session: const SessionState(),
              backing: const BackingState(),
              transferInFlight: transfer,
            );
      expect(read().transferInFlight, isFalse);
      expect(read(transfer: true).transferInFlight, isTrue);
      expect(read(transfer: true).takeInFlight, isFalse);
    });

    test('carries the update flag it is given, and none by default', () {
      PowerSnapshot read({bool? update}) => update == null
          ? powerSnapshotOf(
              looper: const LooperState(),
              recorder: const PerformanceRecorderIdle(),
              session: const SessionState(),
              backing: const BackingState(),
            )
          : powerSnapshotOf(
              looper: const LooperState(),
              recorder: const PerformanceRecorderIdle(),
              session: const SessionState(),
              backing: const BackingState(),
              updateInFlight: update,
            );
      expect(read().updateInFlight, isFalse);
      expect(read(update: true).updateInFlight, isTrue);
      expect(read(update: true).takeInFlight, isFalse);
      expect(read(update: true).transferInFlight, isFalse);
    });

    test('sessionHasContent: recorded audio, or a prepared or loaded '
        'backing; an empty rig has none', () {
      PowerSnapshot read({
        LooperState looper = const LooperState(),
        BackingState backing = const BackingState(),
      }) => powerSnapshotOf(
        looper: looper,
        recorder: const PerformanceRecorderIdle(),
        session: const SessionState(),
        backing: backing,
      );
      const item = BackingItem(digest: 'abc', name: 'drums.wav');
      expect(read().sessionHasContent, isFalse);
      expect(
        read(
          looper: const LooperState(
            tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
          ),
        ).sessionHasContent,
        isTrue,
      );
      expect(
        read(
          backing: const BackingState(prepared: [item]),
        ).sessionHasContent,
        isTrue,
      );
      expect(
        read(backing: const BackingState(loaded: item)).sessionHasContent,
        isTrue,
      );
      expect(const PowerSnapshot().sessionHasContent, isTrue);
    });

    test('a cleared or zero-length track is not content', () {
      PowerSnapshot read(Track track) => powerSnapshotOf(
        looper: LooperState(tracks: [track]),
        recorder: const PerformanceRecorderIdle(),
        session: const SessionState(),
        backing: const BackingState(),
      );
      // Cleared: the state is empty again, whatever length it last had.
      expect(read(const Track(lengthFrames: 48000)).sessionHasContent, isFalse);
      // Zero length: never captured anything.
      expect(
        read(const Track(state: TrackState.playing)).sessionHasContent,
        isFalse,
      );
    });

    test('an unknown backing (no player mounted) counts as content', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
          backing: null,
        ).sessionHasContent,
        isTrue,
      );
    });

    test('maps currentSessionName', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(currentSessionName: 'live'),
          backing: const BackingState(),
        ).currentSessionName,
        'live',
      );
    });
  });
}
