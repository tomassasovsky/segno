import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'package:pedal_repository/testing.dart';

void main() {
  group('PedalRepository', () {
    late FakePedalLink link;
    late PedalRepository repo;
    late Duration now;

    setUp(() {
      link = FakePedalLink();
      now = Duration.zero;
      repo = PedalRepository(link, clock: () => now);
    });

    tearDown(() => repo.dispose());

    test('button messages become timestamped press / release events', () async {
      final events = <PedalEvent>[];
      repo.events.listen(events.add);
      now = const Duration(milliseconds: 10);
      link.press(PedalButton.track2, down: true);
      await pumpEventQueue();
      now = const Duration(milliseconds: 250);
      link.press(PedalButton.track2, down: false);
      await pumpEventQueue();
      expect(events, const [
        ButtonPressed(
          PedalButton.track2,
          timestamp: Duration(milliseconds: 10),
        ),
        ButtonReleased(
          PedalButton.track2,
          timestamp: Duration(milliseconds: 250),
        ),
      ]);
    });

    test('encoder messages become deltas', () async {
      final events = <PedalEvent>[];
      repo.events.listen(events.add);
      link
        ..turn(1)
        ..turn(-2);
      await pumpEventQueue();
      expect(events, const [EncoderDelta(1), EncoderDelta(-2)]);
    });

    test('pushState goes out as a link message', () {
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.red,
      );
      repo.pushState(frame);
      expect(link.sent, [StateMessage(frame)]);
    });

    test('a frame identical to the last push is not sent again', () {
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.red,
      );
      repo
        ..pushState(frame)
        ..pushState(frame.copyWith())
        ..pushState(frame.copyWith(globalColor: GlobalColor.green));
      expect(link.sent, hasLength(2));
    });

    test('goodbye darkens the board and holds the mark', () async {
      final events = <PedalEvent>[];
      repo.events.listen(events.add);
      link.hello();
      await pumpEventQueue();
      repo
        ..pushState(PedalStateFrame.blank().copyWith(activeBank: 1))
        ..goodbye();
      expect(link.lastFrame?.isGoodbye, isTrue);
      link.sent.clear();

      // Nothing re-lights a halting console: every later frame is dropped and
      // a hello is answered with the goodbye frame. Stomps still come through
      // — a goodbye that turns out to be wrong must not look like a dead link.
      repo
        ..pushState(PedalStateFrame.blank().copyWith(activeBank: 1))
        ..goodbye();
      link
        ..press(PedalButton.recPlay, down: true)
        ..turn(1)
        ..hello();
      await pumpEventQueue();
      expect(events, hasLength(2));
      expect(
        link.sent.whereType<StateMessage>().map((m) => m.frame.isGoodbye),
        everyElement(isTrue),
      );
    });

    test(
      'a hello connects the link and records the firmware version',
      () async {
        final statuses = <PedalLinkStatus>[];
        repo.statusChanges.listen(statuses.add);
        expect(repo.status, PedalLinkStatus.disconnected);
        expect(repo.firmwareVersion, isNull);
        link.hello(firmwareMinor: 4);
        await pumpEventQueue();
        expect(repo.status, PedalLinkStatus.connected);
        expect(repo.firmwareVersion, '1.4');
        link.hello(firmwareMinor: 4);
        await pumpEventQueue();
        expect(statuses, [PedalLinkStatus.connected]); // dedups repeats
      },
    );

    test('silence past helloTimeout disconnects; a hello reconnects', () {
      fakeAsync((async) {
        final quietLink = FakePedalLink();
        final quiet = PedalRepository(quietLink);
        final statuses = <PedalLinkStatus>[];
        quiet.statusChanges.listen(statuses.add);
        final mostOfTheTimeout = quiet.helloTimeout * 0.7;

        quietLink.hello(firmwareMinor: 7);
        async.flushMicrotasks();
        expect(quiet.status, PedalLinkStatus.connected);
        expect(quiet.firmwareVersion, '1.7');

        async.elapse(mostOfTheTimeout);
        quietLink.hello(firmwareMinor: 7); // keeps it alive
        async
          ..flushMicrotasks()
          ..elapse(mostOfTheTimeout);
        expect(quiet.status, PedalLinkStatus.connected);

        async.elapse(mostOfTheTimeout);
        expect(quiet.status, PedalLinkStatus.disconnected);
        expect(quiet.firmwareVersion, isNull);

        quietLink.hello(firmwareMinor: 7);
        async.flushMicrotasks();
        expect(quiet.status, PedalLinkStatus.connected);
        expect(statuses, [
          PedalLinkStatus.connected,
          PedalLinkStatus.disconnected,
          PedalLinkStatus.connected,
        ]);
        unawaited(quiet.dispose());
        async.flushTimers();
      });
    });

    test('a hello with another link protocol reads as incompatible', () async {
      final lines = <String>[];
      final logged = PedalRepository(link, log: lines.add);
      link.emit(
        const HelloMessage(
          protocolVersion: PedalLinkCodec.protocolVersion + 1,
          firmwareMajor: 2,
          firmwareMinor: 0,
        ),
      );
      await pumpEventQueue();
      expect(logged.status, PedalLinkStatus.incompatible);
      expect(logged.firmwareVersion, '2.0');
      expect(lines.single, contains('incompatible'));
      expect(
        lines.single,
        contains('protocol ${PedalLinkCodec.protocolVersion + 1}'),
      );

      // Its stomps are dropped and it is sent nothing: a reordered button
      // table on the other side must not reach the looper.
      final events = <PedalEvent>[];
      logged.events.listen(events.add);
      link
        ..press(PedalButton.clear, down: true)
        ..turn(1);
      await pumpEventQueue();
      expect(events, isEmpty);
      final before = link.sent.length;
      logged.pushState(PedalStateFrame.blank());
      expect(link.sent.length, before);
      await logged.dispose();
    });

    test('every hello is answered with the last pushed frame', () async {
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.green,
      );
      link.hello();
      await pumpEventQueue();
      expect(link.sent.whereType<StateMessage>(), isEmpty); // nothing yet
      repo.pushState(frame);
      link.sent.clear();
      link.hello();
      await pumpEventQueue();
      expect(link.sent, [StateMessage(frame)]);
    });

    test('a hello with a new firmware version re-emits the status', () async {
      final statuses = <PedalLinkStatus>[];
      repo.statusChanges.listen(statuses.add);
      link.hello();
      await pumpEventQueue();
      link.hello(firmwareMinor: 1); // reflashed under a running app
      await pumpEventQueue();
      expect(repo.firmwareVersion, '1.1');
      expect(statuses, [
        PedalLinkStatus.connected,
        PedalLinkStatus.connected,
      ]);
    });

    test('dispose reports the link as disconnected', () async {
      final statuses = <PedalLinkStatus>[];
      repo.statusChanges.listen(statuses.add);
      link.hello();
      await pumpEventQueue();
      expect(repo.status, PedalLinkStatus.connected);
      await repo.dispose();
      expect(repo.status, PedalLinkStatus.disconnected);
      expect(repo.firmwareVersion, isNull);
      expect(statuses, [
        PedalLinkStatus.connected,
        PedalLinkStatus.disconnected,
      ]);
    });

    test('outbound message types arriving inbound are ignored', () async {
      final events = <PedalEvent>[];
      repo.events.listen(events.add);
      link.emit(StateMessage(PedalStateFrame.blank()));
      await pumpEventQueue();
      expect(events, isEmpty);
      expect(repo.status, PedalLinkStatus.disconnected);
    });

    test('dispose releases the link and is idempotent', () async {
      await repo.dispose();
      await repo.dispose();
      expect(link.disposed, isTrue);
      repo.pushState(PedalStateFrame.blank());
      expect(link.sent, isEmpty);
    });
  });

  group('PedalRepository CTRL calibration', () {
    CtrlMessage raw(int value, {PedalCtrlJack jack = PedalCtrlJack.ctrl1}) =>
        CtrlMessage(jack: jack, kind: PedalCtrlKind.expression, value: value);

    test('an explicit calibration maps every reading onto the travel', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((e) => seen.add(e as CtrlChanged));
        repo.setCtrlCalibration(
          PedalCtrlJack.ctrl1,
          const PedalCtrlCalibration(min: 24, max: 255),
        );

        link
          ..emit(raw(24))
          ..emit(raw(255));
        async.flushMicrotasks();

        expect(seen.map((e) => e.value), [0, 255]);
        expect(seen.map((e) => e.raw), [24, 255]);
        expect(repo.ctrlCalibration(PedalCtrlJack.ctrl1), isNotNull);
      });
    });

    test('with no calibration the ends are learned from readings the pedal '
        'holds, and the reading is re-reported once they move', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((e) => seen.add(e as CtrlChanged));

        // Heel, held: learned. Toe (a pedal whose range knob stops at 200),
        // held: learned. The span is now trusted, so the toe reading that
        // was passed through raw is re-reported as a hard 255 — the pedal
        // did not move, the ends did.
        link.emit(raw(24));
        async
          ..flushMicrotasks()
          ..elapse(PedalRepository.settleTime);
        link.emit(raw(200));
        async
          ..flushMicrotasks()
          ..elapse(PedalRepository.settleTime);

        expect(seen.map((e) => e.raw), [24, 200, 200]);
        expect(seen.map((e) => e.value), [24, 200, 255]);

        // Back to heel: mapped under the learned ends straight away.
        link.emit(raw(24));
        async.flushMicrotasks();
        expect(seen.last.value, 0);
        expect(seen.last.raw, 24);
      });
    });

    test('a reading that does not hold is not learned from', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((e) => seen.add(e as CtrlChanged));

        // A plug on its way in: 0 for a moment, then the real heel.
        link.emit(raw(0));
        async
          ..flushMicrotasks()
          ..elapse(PedalRepository.settleTime ~/ 2);
        link.emit(raw(24));
        async
          ..flushMicrotasks()
          ..elapse(PedalRepository.settleTime);
        link.emit(raw(255));
        async
          ..flushMicrotasks()
          ..elapse(PedalRepository.settleTime);

        // Heel is 24, not 0: the transient never became an end.
        link.emit(raw(24));
        async.flushMicrotasks();
        expect(seen.last.value, 0);
      });
    });

    test('an explicit calibration is not widened by what the pedal does', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((e) => seen.add(e as CtrlChanged));
        repo.setCtrlCalibration(
          PedalCtrlJack.ctrl1,
          const PedalCtrlCalibration(min: 50, max: 200),
        );

        link.emit(raw(0));
        async
          ..flushMicrotasks()
          ..elapse(PedalRepository.settleTime);
        link.emit(raw(50));
        async.flushMicrotasks();

        expect(seen.map((e) => e.value), [0, 0]);
      });
    });

    test(
      'clearing a calibration re-reports the position under learned ends',
      () {
        fakeAsync((async) {
          final link = FakePedalLink();
          final repo = PedalRepository(link);
          final seen = <CtrlChanged>[];
          repo.events.listen((e) => seen.add(e as CtrlChanged));
          repo.setCtrlCalibration(
            PedalCtrlJack.ctrl1,
            const PedalCtrlCalibration(min: 0, max: 255),
          );
          link.emit(raw(128));
          async.flushMicrotasks();
          expect(seen.last.value, closeTo(128, 3));

          repo.setCtrlCalibration(PedalCtrlJack.ctrl1, null);
          async.flushMicrotasks();
          expect(repo.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
          // Nothing learned yet: raw passes through.
          expect(seen.last.raw, 128);
          expect(seen.last.value, 128);
        });
      },
    );

    test('learned ends are forgotten when the board goes quiet', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((e) => seen.add(e as CtrlChanged));
        link.hello();
        for (final v in [24, 255]) {
          link.emit(raw(v));
          async
            ..flushMicrotasks()
            ..elapse(PedalRepository.settleTime);
        }
        async.elapse(repo.helloTimeout + const Duration(seconds: 1));
        expect(repo.status, PedalLinkStatus.disconnected);

        link
          ..hello()
          ..emit(raw(100));
        async.flushMicrotasks();
        // Whatever comes back may be another pedal: back to raw until it
        // has been swept again.
        expect(seen.last.value, 100);
        async.elapse(repo.helloTimeout + const Duration(seconds: 1));
      });
    });

    test('an empty jack forgets the learned ends, keeps a set calibration', () {
      fakeAsync((async) {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((e) => seen.add(e as CtrlChanged));
        for (final v in [24, 200]) {
          link.emit(raw(v));
          async
            ..flushMicrotasks()
            ..elapse(PedalRepository.settleTime);
        }
        expect(seen.last.value, 255); // learned: 200 is the toe

        link.emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.none,
            value: 0,
          ),
        );
        async.flushMicrotasks();
        expect(seen.last.kind, PedalCtrlKind.none);

        // The next pedal starts from raw: the old pedal's ends are gone.
        link.emit(raw(200));
        async.flushMicrotasks();
        expect(seen.last.value, 200);

        // ...unless the user calibrated this jack, which survives the plug.
        repo.setCtrlCalibration(
          PedalCtrlJack.ctrl1,
          const PedalCtrlCalibration(min: 24, max: 200),
        );
        link.emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.none,
            value: 0,
          ),
        );
        link.emit(raw(200));
        async.flushMicrotasks();
        expect(seen.last.value, 255);
      });
    });

    test('a switch, on either contact, passes through untouched', () async {
      final link = FakePedalLink();
      final repo = PedalRepository(link);
      final seen = <CtrlChanged>[];
      repo.events.listen((e) => seen.add(e as CtrlChanged));
      link.emit(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl2,
          contact: PedalCtrlContact.ring,
          kind: PedalCtrlKind.switchPedal,
          value: 255,
        ),
      );
      await pumpEventQueue();
      expect(seen.single.contact, PedalCtrlContact.ring);
      expect(seen.single.value, 255);
      expect(seen.single.raw, 255);
      expect(
        seen.single.input,
        const PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.ring),
      );
      await repo.dispose();
    });
  });
}
