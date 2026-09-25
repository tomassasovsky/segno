import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';

void main() {
  group('PedalRepository inlet status', () {
    const contract = PedalPdStatus.contract(currentMilliamps: 5000);

    test(
      'trusts status only after a compatible hello and logs unknown voltage',
      () {
        fakeAsync((async) {
          final link = FakePedalLink();
          final logs = <String>[];
          final repo = PedalRepository(link, log: logs.add);
          final changes = <PedalPdStatus>[];
          repo.pdStatusChanges.listen(changes.add);
          link.emit(const PdStatusMessage(contract));
          async.flushMicrotasks();
          expect(repo.pdStatus.state, PedalPdState.unknown);
          link
            ..emit(
              const HelloMessage(
                protocolVersion: PedalLinkCodec.protocolVersion - 1,
                firmwareMajor: 1,
                firmwareMinor: 6,
              ),
            )
            ..emit(const PdStatusMessage(contract));
          async.flushMicrotasks();
          expect(repo.pdStatus.state, PedalPdState.stale);
          expect(repo.pdStatus.currentMilliamps, isNull);
          link
            ..hello()
            ..emit(const PdStatusMessage(contract));
          async.flushMicrotasks();
          expect(repo.pdStatus, contract);
          expect(changes.last, contract);
          const expected =
              'pedal power: requested 5000 mA; voltage unknown; '
              'capability mismatch false';
          expect(
            logs.where((line) => line.startsWith('pedal power: requested')),
            [expected],
          );
          expect(logs.any((line) => line.contains('20 V')), isFalse);
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test('expires power reports even while ordinary hellos remain healthy', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        link
          ..hello()
          ..emit(const PdStatusMessage(contract));
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2));
        link.hello();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1));
        expect(repo.status, PedalLinkStatus.connected);
        expect(repo.pdStatus.state, PedalPdState.stale);
        expect(repo.pdStatus.currentMilliamps, isNull);
        expect(repo.pdStatus.voltageMillivolts, isNull);
        link.emit(const PdStatusMessage(contract));
        async.flushMicrotasks();
        expect(repo.pdStatus, contract);
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test(
      'duplicate reports refresh freshness without repeating changes or logs',
      () {
        fakeAsync((async) {
          final link = FakePedalLink();
          final logs = <String>[];
          final repo = PedalRepository(link, log: logs.add);
          final changes = <PedalPdStatus>[];
          repo.pdStatusChanges.listen(changes.add);
          link
            ..hello()
            ..emit(const PdStatusMessage(contract));
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 2));
          link
            ..hello()
            ..emit(const PdStatusMessage(contract));
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 2));
          link.hello();
          async.flushMicrotasks();
          expect(repo.pdStatus, contract);
          expect(changes, [contract]);
          expect(
            logs.where((line) => line.startsWith('pedal power:')),
            hasLength(1),
          );
          async.elapse(const Duration(seconds: 1));
          expect(repo.pdStatus.state, PedalPdState.stale);
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'errors, disconnects and firmware changes clear prior electrical values',
      () {
        fakeAsync((async) {
          final link = FakePedalLink();
          final logs = <String>[];
          final repo = PedalRepository(link, log: logs.add);
          const known = PedalPdStatus.contract(
            currentMilliamps: 3000,
            voltageMillivolts: 20000,
            capabilityMismatch: true,
          );
          link
            ..hello()
            ..emit(const PdStatusMessage(known));
          async.flushMicrotasks();
          expect(
            logs.last,
            contains('voltage 20000 mV; capability mismatch true'),
          );
          link.emit(
            const PdStatusMessage(
              PedalPdStatus.unavailable(PedalPdState.readError),
            ),
          );
          async.flushMicrotasks();
          expect(repo.pdStatus.currentMilliamps, isNull);
          expect(repo.pdStatus.voltageMillivolts, isNull);
          expect(repo.pdStatus.capabilityMismatch, isFalse);
          link.emit(const PdStatusMessage(known));
          async.flushMicrotasks();
          link.hello(firmwareMinor: 7);
          async.flushMicrotasks();
          expect(repo.pdStatus.state, PedalPdState.unknown);
          link.emit(const PdStatusMessage(known));
          async
            ..flushMicrotasks()
            ..elapse(repo.helloTimeout);
          expect(repo.status, PedalLinkStatus.disconnected);
          expect(repo.pdStatus.state, PedalPdState.stale);
          expect(repo.pdStatus.currentMilliamps, isNull);
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'missing first report becomes stale and disposal cancels timers',
      () {
        fakeAsync((async) {
          final link = FakePedalLink();
          final repo = PedalRepository(link);
          link.hello();
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 2));
          link.hello();
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 1));
          expect(repo.pdStatus.state, PedalPdState.stale);
          unawaited(repo.dispose());
          async
            ..flushMicrotasks()
            ..elapse(Duration.zero);
          expect(async.nonPeriodicTimerCount, 0);
        });
      },
    );
    test('disposal completes the inlet stream', () async {
      final link = FakePedalLink();
      final repo = PedalRepository(link);
      var closed = false;
      repo.pdStatusChanges.listen((_) {}, onDone: () => closed = true);
      link
        ..hello()
        ..emit(const PdStatusMessage(contract));
      await pumpEventQueue();
      await repo.dispose();
      expect(closed, isTrue);
      expect(repo.pdStatus.currentMilliamps, isNull);
    });
  });
}
