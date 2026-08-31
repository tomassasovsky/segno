import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';

void main() {
  group('powerOffGate', () {
    test('in-flight capturing → refuse', () {
      expect(
        powerOffGate(
          const PowerOffSnapshot(
            anyCapturingOrPending: true,
            anyHasContent: true,
          ),
        ),
        PowerOffDisposition.refuse,
      );
    });

    test('pending quantized arm → refuse', () {
      expect(
        powerOffGate(const PowerOffSnapshot(anyCapturingOrPending: true)),
        PowerOffDisposition.refuse,
      );
    });

    test('layerInFlight punch-tail → refuse', () {
      expect(
        powerOffGate(const PowerOffSnapshot(layerInFlight: true)),
        PowerOffDisposition.refuse,
      );
    });

    test('count-in sounding → refuse', () {
      expect(
        powerOffGate(const PowerOffSnapshot(countingIn: true)),
        PowerOffDisposition.refuse,
      );
    });

    test('performance Armed / Finalizing / Rendering → refuse', () {
      expect(
        powerOffGate(const PowerOffSnapshot(performanceInFlight: true)),
        PowerOffDisposition.refuse,
      );
    });

    test('boot salvage recovering → refuse', () {
      expect(
        powerOffGate(const PowerOffSnapshot(performanceRecovering: true)),
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
      expect(snapshot.anyCapturingOrPending, isTrue);
      expect(snapshot.anyHasContent, isTrue);
      expect(snapshot.takeInFlight, isTrue);
    });

    test('maps recovering idle, not completed', () {
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderIdle(recovering: true),
          session: const SessionState(),
        ).performanceRecovering,
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
        ).performanceInFlight,
        isTrue,
      );
    });

    test('maps pending, punch-tail, and count-in', () {
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(tracks: [Track(pending: true)]),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
        ).anyCapturingOrPending,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(
            tracks: [Track(layerInFlight: true)],
          ),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
        ).layerInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(
            transport: TransportState(countingIn: true),
          ),
          recorder: const PerformanceRecorderIdle(),
          session: const SessionState(),
        ).countingIn,
        isTrue,
      );
    });

    test('Finalizing and Rendering are in-flight; Completed is not', () {
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderFinalizing(),
          session: const SessionState(),
        ).performanceInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderRendering(percent: 10),
          session: const SessionState(),
        ).performanceInFlight,
        isTrue,
      );
      expect(
        powerOffSnapshotOf(
          looper: const LooperState(),
          recorder: const PerformanceRecorderCompleted.discardedShort(),
          session: const SessionState(),
        ).performanceInFlight,
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
