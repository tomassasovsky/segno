import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

void main() {
  group('fingerprint', () {
    late FakeSessionEngine engine;
    late SessionRepository repository;

    setUp(() {
      engine = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      repository = SessionRepository(
        engine: engine,
        guards: GuardRegistry(),
      );
    });

    String fingerprint({
      SessionSettings settings = const SessionSettings(),
      SessionChains chains = const SessionChains(),
      String pedalBindings = '',
    }) => repository.fingerprint(
      settings: settings,
      chains: chains,
      pedalBindings: pedalBindings,
    );

    test('is the same for an unchanged rig and exports no audio', () {
      final before = fingerprint();
      expect(fingerprint(), before);
      expect(engine.exportedLayers, 0);
    });

    test('changes when a track is written', () {
      final before = fingerprint();
      engine.seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      expect(fingerprint(), isNot(before));
    });

    test('changes when another track holds audio', () {
      final before = fingerprint();
      engine.seedTrack(3, Float32List.fromList([2, 2, 2, 2]));
      expect(fingerprint(), isNot(before));
    });

    test('changes with the mix in the engine', () {
      final before = fingerprint();
      engine.setLaneMute(muted: true);
      expect(fingerprint(), isNot(before));
    });

    test('changes with a setting, an effect chain or the pedal remap', () {
      final before = fingerprint();
      expect(
        fingerprint(
          settings: const SessionSettings(defaultFadeDurationMs: 1000),
        ),
        isNot(before),
      );
      expect(
        fingerprint(
          chains: const SessionChains(
            trackChains: [SessionTrackChain(channel: 0, encoded: '[]')],
          ),
        ),
        isNot(before),
      );
      expect(fingerprint(pedalBindings: 'remap'), isNot(before));
    });
  });
}
