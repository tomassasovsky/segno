import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';

void main() {
  group('powerOffGate', () {
    test('in-flight take → refuse', () {
      expect(
        powerOffGate(
          const PowerOffSnapshot(takeInFlight: true, anyHasContent: true),
        ),
        PowerOffDisposition.refuse,
      );
    });

    test('hasContent and idle → confirm', () {
      expect(
        powerOffGate(const PowerOffSnapshot(anyHasContent: true)),
        PowerOffDisposition.confirm,
      );
    });

    test('empty → skip confirm', () {
      expect(powerOffGate(const PowerOffSnapshot()), PowerOffDisposition.skip);
    });

    test('named session with empty tracks still skips', () {
      expect(
        powerOffGate(const PowerOffSnapshot(currentSessionName: 'set')),
        PowerOffDisposition.skip,
      );
    });
  });

  group('powerOffSnapshotOf', () {
    test('maps capturing and hasContent from tracks', () {
      const looper = LooperState(
        tracks: [
          Track(
            state: TrackState.recording,
            lengthFrames: 48000,
          ),
        ],
      );
      final snapshot = powerOffSnapshotOf(
        looper: looper,
        recorder: const PerformanceRecorderIdle(),
        session: const SessionState(),
      );
      expect(snapshot.takeInFlight, isTrue);
      expect(snapshot.anyHasContent, isTrue);
    });

    test('maps pending, punch-tail, and count-in as in-flight', () {
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(tracks: [Track(pending: true)]),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(
            tracks: [Track(layerInFlight: true)],
          ),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
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
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(recovering: true),
          session: const SessionState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
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
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderFinalizing(),
          session: const SessionState(),
        ).takeInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderRendering(percent: 10),
          session: const SessionState(),
        ).takeInFlight,
        isTrue,
      );
    });

    test('Completed is not in-flight', () {
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderCompleted.discardedShort(),
          session: const SessionState(),
        ).takeInFlight,
        isFalse,
      );
    });

    test('maps currentSessionName', () {
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(currentSessionName: 'live'),
        ).currentSessionName,
        'live',
      );
    });
  });
}
