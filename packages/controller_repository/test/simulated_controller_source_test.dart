import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_controller_source.dart';

/// The push seam behind "Simulate input" (#519): a synthetic input entering
/// through [SimulatedControllerSource] is INDISTINGUISHABLE downstream from one
/// off the wire — same resolved events, same learn capture — which is the
/// feature's core claim. Nothing here reaches into the repository's private
/// dispatch; it only asserts the seam.
void main() {
  const expression = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 11,
  );

  group('SimulatedControllerSource', () {
    test('a push produces the SAME binding events a real input does', () async {
      // Two repositories, identical bindings: one fed from a real source, one
      // from the simulated source. The event streams must match exactly.
      final real = FakeControllerSource();
      final simulated = SimulatedControllerSource();
      final bindings = ControllerBindingSet(const [
        ContinuousBinding(
          trigger: expression,
          target: 'volume:0',
          lo: 0.25,
          hi: 0.75,
        ),
      ]);
      final realRepo = ControllerRepository(
        sources: [real],
        bindings: bindings,
      );
      final simRepo = ControllerRepository(
        sources: [simulated],
        bindings: bindings,
      );
      addTearDown(realRepo.dispose);
      addTearDown(simRepo.dispose);

      final realEvents = <ControllerBindingEvent>[];
      final simEvents = <ControllerBindingEvent>[];
      realRepo.bindingEvents.listen(realEvents.add);
      simRepo.bindingEvents.listen(simEvents.add);

      const input = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 11,
        value: 127,
      );
      real.emit(input);
      simulated.push(input);
      await Future<void>.delayed(Duration.zero);

      expect(simEvents, isNotEmpty);
      expect(simEvents, realEvents);
      expect(
        simEvents.single,
        isA<ControllerValueEvent>().having(
          (e) => e.value,
          'value',
          closeTo(0.75, 1e-9),
        ),
      );
    });

    test(
      'a discrete push fires the same on/off edge a real one does',
      () async {
        final simulated = SimulatedControllerSource();
        final repo = ControllerRepository(
          sources: [simulated],
          bindings: ControllerBindingSet(const [
            DiscreteBinding(trigger: expression, target: 'chain:track'),
          ]),
        );
        addTearDown(repo.dispose);
        final events = <ControllerBindingEvent>[];
        repo.bindingEvents.listen(events.add);

        simulated
          ..push(
            const RawControllerInput(
              kind: ControllerSourceKind.midiCc,
              id: 11,
              value: 127,
            ),
          )
          ..push(
            const RawControllerInput(
              kind: ControllerSourceKind.midiCc,
              id: 11,
              value: 0,
            ),
          );
        await Future<void>.delayed(Duration.zero);

        expect(events, [
          isA<ControllerSwitchEvent>().having(
            (e) => e.pressed,
            'pressed',
            true,
          ),
          isA<ControllerSwitchEvent>().having(
            (e) => e.pressed,
            'pressed',
            false,
          ),
        ]);
      },
    );

    test('a push mid-learn is captured, exactly as a real input is', () async {
      final simulated = SimulatedControllerSource();
      final repo = ControllerRepository(sources: [simulated]);
      addTearDown(repo.dispose);

      final capture = repo.learnNext();
      expect(repo.isLearning, isTrue);

      simulated.push(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 42,
          value: 100,
        ),
      );

      final caught = await capture;
      expect(caught, isNotNull);
      expect(caught!.id, 42);
      expect(repo.isLearning, isFalse);
    });

    test('push after dispose is a silent no-op', () async {
      final simulated = SimulatedControllerSource();
      await simulated.dispose();

      expect(
        () => simulated.push(
          const RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 1,
            value: 1,
          ),
        ),
        returnsNormally,
      );
    });

    test('the repository disposes a simulated source in its sources', () async {
      // It rides the same list as the real source, so the repository owns its
      // lifecycle — bootstrap adds it and never disposes it by hand.
      final real = FakeControllerSource();
      final simulated = SimulatedControllerSource();
      final repo = ControllerRepository(sources: [real, simulated]);

      await repo.dispose();

      expect(real.disposed, isTrue);
      expect(
        () => simulated.push(
          const RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 1,
            value: 1,
          ),
        ),
        returnsNormally, // closed stream: swallowed, not thrown
      );
    });
  });
}
