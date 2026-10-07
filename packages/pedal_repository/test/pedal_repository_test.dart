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
      link.hello();
      await pumpEventQueue();
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
      link.hello();
      await pumpEventQueue();
      final events = <PedalEvent>[];
      repo.events.listen(events.add);
      link
        ..turn(1)
        ..turn(-2);
      await pumpEventQueue();
      expect(events, const [EncoderDelta(1), EncoderDelta(-2)]);
    });

    test('publishes frames without hardware and holds goodbye', () async {
      final frames = <PedalStateFrame>[];
      final subscription = repo.frames.listen(frames.add);
      expect(repo.lastFrame, isNull);
      final frame = PedalStateFrame.blank().copyWith(activeButtonMask: 256);
      repo
        ..pushState(frame)
        ..pushState(frame.copyWith());
      await pumpEventQueue();
      expect(repo.lastFrame, frame);
      expect(frames, [frame]);
      expect(link.sent, isEmpty);
      repo
        ..goodbye()
        ..pushState(frame);
      await pumpEventQueue();
      expect(frames, hasLength(2));
      expect(repo.lastFrame!.isGoodbye, isTrue);
      expect(frames.last, repo.lastFrame);
      await subscription.cancel();
    });

    test('pushState goes out as a link message', () async {
      link.hello();
      await pumpEventQueue();
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.red,
      );
      repo.pushState(frame);
      expect(link.sent, [StateMessage(frame)]);
    });

    test('a frame identical to the last push is not sent again', () async {
      link.hello();
      await pumpEventQueue();
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.red,
      );
      repo
        ..pushState(frame)
        ..pushState(frame.copyWith())
        ..pushState(frame.copyWith(globalColor: GlobalColor.green));
      expect(link.sent, hasLength(2));
    });

    test(
      'hue-only and activity-only changes send; equal snapshots deduplicate',
      () async {
        link.hello();
        await pumpEventQueue();
        final colors = List<PedalColor>.of(defaultPedalColors);
        final initial = PedalStateFrame.blank().copyWith(pedalColors: colors);
        repo.pushState(initial);
        colors[9] = const PedalColor(128, 165, 255);
        final hue = initial.copyWith(pedalColors: colors);
        repo
          ..pushState(hue)
          ..pushState(hue.copyWith());
        final active = hue.copyWith(activeButtonMask: 512);
        repo
          ..pushState(active)
          ..pushState(active.copyWith());
        expect(link.sent, [
          StateMessage(initial),
          StateMessage(hue),
          StateMessage(active),
        ]);
        expect(initial.colorFor(PedalButton.bank), PedalColor.defaultColor);
        expect(link.lastFrame!.isLit(PedalButton.bank), isTrue);
      },
    );

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
        expect(repo.protocolVersion, PedalLinkCodec.protocolVersion);
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
      expect(logged.protocolVersion, PedalLinkCodec.protocolVersion + 1);
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
      link
        ..sent.clear()
        ..hello();
      await pumpEventQueue();
      expect(link.sent, [StateMessage(frame)]);
    });

    for (final protocol in [
      6,
      PedalLinkCodec.protocolVersion - 1,
      PedalLinkCodec.protocolVersion,
      PedalLinkCodec.protocolVersion + 1,
    ]) {
      test(
        'only a live compatible hello enables traffic (protocol $protocol)',
        () {
          fakeAsync((async) {
            final guardedLink = FakePedalLink();
            final guarded = PedalRepository(guardedLink);
            final events = <PedalEvent>[];
            guarded.events.listen(events.add);
            final frame = PedalStateFrame.blank();

            // Unknown boards cannot send controls or receive cached state.
            guarded.pushState(frame);
            guardedLink
              ..press(PedalButton.clear, down: true)
              ..turn(1);
            async.flushMicrotasks();
            expect(events, isEmpty);
            expect(guardedLink.sent, isEmpty);

            guardedLink.emit(
              HelloMessage(
                protocolVersion: protocol,
                firmwareMajor: 1,
                firmwareMinor: 0,
              ),
            );
            async.flushMicrotasks();
            expect(
              guarded.status,
              protocol == PedalLinkCodec.protocolVersion
                  ? PedalLinkStatus.connected
                  : PedalLinkStatus.incompatible,
            );
            async.elapse(guarded.helloTimeout);
            expect(guarded.status, PedalLinkStatus.disconnected);
            guardedLink.sent.clear();

            final latest = frame.copyWith(globalColor: GlobalColor.red);
            guarded.pushState(latest);
            guardedLink
              ..press(PedalButton.clear, down: true)
              ..turn(1);
            async.flushMicrotasks();
            expect(events, isEmpty);
            expect(guardedLink.sent, isEmpty);

            guardedLink
              ..hello()
              ..press(PedalButton.clear, down: true)
              ..turn(1);
            async.flushMicrotasks();
            expect(guarded.status, PedalLinkStatus.connected);
            expect(events, hasLength(2));
            expect(guardedLink.sent, [StateMessage(latest)]);
            unawaited(guarded.dispose());
            async.flushMicrotasks();
          });
        },
      );
    }

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
      expect(repo.protocolVersion, isNull);
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

  group('PedalRepository raw CTRL readings', () {
    test(
      'delivers exact byte samples without learning or delayed synthesis',
      () {
        fakeAsync((async) {
          final link = FakePedalLink();
          final repo = PedalRepository(link);
          final seen = <CtrlChanged>[];
          repo.events.listen((event) => seen.add(event as CtrlChanged));
          link.hello();
          for (final value in [24, 200, 201, 255]) {
            link.emit(
              CtrlMessage(
                jack: PedalCtrlJack.ctrl1,
                kind: PedalCtrlKind.expression,
                value: value,
              ),
            );
            async
              ..flushMicrotasks()
              ..elapse(const Duration(milliseconds: 100));
          }
          expect(seen.map((event) => event.raw), [24, 200, 201, 255]);
          expect(seen.map((event) => event.value), [24, 200, 201, 255]);
          async.elapse(const Duration(milliseconds: 400));
          expect(seen, hasLength(4));
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'mismatch drops samples and a fresh hello does not replay them',
      () async {
        final link = FakePedalLink();
        final repo = PedalRepository(link);
        final seen = <CtrlChanged>[];
        repo.events.listen((event) => seen.add(event as CtrlChanged));
        link
          ..hello()
          ..emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl2,
              contact: PedalCtrlContact.ring,
              kind: PedalCtrlKind.switchPedal,
              value: 255,
            ),
          );
        await pumpEventQueue();
        expect(
          seen.single.input,
          const PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.ring),
        );
        link
          ..emit(
            const HelloMessage(
              protocolVersion: PedalLinkCodec.protocolVersion + 1,
              firmwareMajor: 2,
              firmwareMinor: 0,
            ),
          )
          ..emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.expression,
              value: 73,
            ),
          );
        await pumpEventQueue();
        expect(seen, hasLength(1));
        link.hello();
        await pumpEventQueue();
        expect(seen, hasLength(1));
        link.emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.expression,
            value: 74,
          ),
        );
        await pumpEventQueue();
        expect(seen.last.raw, 74);
        await repo.dispose();
      },
    );
  });
}
