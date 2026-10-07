import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';

void main() {
  group('powerRefused', () {
    test('a take in flight refuses', () {
      expect(powerRefused(const PowerSnapshot(takeInFlight: true)), isTrue);
    });

    test('a transfer in flight refuses', () {
      expect(powerRefused(const PowerSnapshot(transferInFlight: true)), isTrue);
    });

    test('anything else proceeds, named or not', () {
      expect(powerRefused(const PowerSnapshot()), isFalse);
      expect(
        powerRefused(const PowerSnapshot(currentSessionName: 'set')),
        isFalse,
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
      );
      expect(snapshot.takeInFlight, isTrue);
    });

    test('maps pending, punch-tail, and count-in as in-flight', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(tracks: [Track(pending: true)]),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
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
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderFinalizing(),
          session: const SessionState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderRendering(percent: 10),
          session: const SessionState(),
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
        ).takeInFlight,
        isFalse,
      );
    });

    test('maps currentSessionName', () {
      expect(
        powerSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(currentSessionName: 'live'),
        ).currentSessionName,
        'live',
      );
    });
  });
}
