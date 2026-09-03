import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/fake_pedal_link.dart';

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

    test('pushState and sendLoopTop go out as link messages', () {
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.red,
      );
      repo
        ..pushState(frame)
        ..sendLoopTop();
      expect(link.sent, [StateMessage(frame), const LoopTopMessage()]);
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

        quietLink.hello();
        async.flushMicrotasks();
        expect(quiet.status, PedalLinkStatus.connected);

        async.elapse(const Duration(seconds: 2));
        quietLink.hello(); // keeps it alive
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2));
        expect(quiet.status, PedalLinkStatus.connected);

        async.elapse(const Duration(seconds: 2));
        expect(quiet.status, PedalLinkStatus.disconnected);

        quietLink.hello();
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

    test('outbound message types arriving inbound are ignored', () async {
      final events = <PedalEvent>[];
      repo.events.listen(events.add);
      link
        ..emit(StateMessage(PedalStateFrame.blank()))
        ..emit(const LoopTopMessage());
      await pumpEventQueue();
      expect(events, isEmpty);
      expect(repo.status, PedalLinkStatus.disconnected);
    });

    test('dispose releases the link and is idempotent', () async {
      await repo.dispose();
      await repo.dispose();
      expect(link.disposed, isTrue);
      repo
        ..pushState(PedalStateFrame.blank())
        ..sendLoopTop();
      expect(link.sent, isEmpty);
    });
  });
}
