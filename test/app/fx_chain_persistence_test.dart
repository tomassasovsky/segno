import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _Looper extends Mock implements LooperRepository {}

void main() {
  const address = FxAddress(stage: FxStage.track);
  const target = FxParamTarget(address: address, slotId: 'drive', param: 0);
  late _Looper looper;
  late FxChainPersistence projection;
  late SettingsRepository settings;
  late BuiltInEffect held;
  setUp(() {
    looper = _Looper();
    when(() => looper.sessionRevision).thenReturn(1);
    held = BuiltInEffect(
      type: TrackEffectType.drive,
      slotId: 'drive',
      params: const [.8, .4, .5],
    );
    when(() => looper.trackEffects(0)).thenReturn([held]);
    when(() => looper.trackChainEnabled(0)).thenReturn(true);
    projection = FxChainPersistence(looper: looper);
    settings = SettingsRepository(store: FakeKeyValueStore());
  });

  test(
    'settings wait for accepted projection and retain unrelated fields',
    () async {
      final ticket = projection.beginPending();
      final saving = saveTrackFxChain(
        settings: settings,
        looper: looper,
        projection: projection,
        channel: 0,
      );
      await Future<void>.delayed(Duration.zero);
      expect(await settings.loadTrackFxChain(0), isNull);
      projection
        ..replace(
          powers: {const FxChainTarget(address): false},
          parameters: {target: .2},
        )
        ..finishPending(ticket);
      await saving;
      final saved = decodeFxChain(await settings.loadTrackFxChain(0));
      expect(saved.chainEnabled, isFalse);
      final effect = saved.entries.single as BuiltInEffect;
      expect(effect.params, [.2, .4, .5, 0]);
      expect(effect.slotId, 'drive');
      expect(held.params.first, .8);
    },
  );

  test('refused pending recipe leaves accepted projection intact', () async {
    projection.replace(powers: const {}, parameters: {target: .2});
    final ticket = projection.beginPending();
    final saving = saveTrackFxChain(
      settings: settings,
      looper: looper,
      projection: projection,
      channel: 0,
    );
    projection.finishPending(ticket);
    await saving;
    expect(
      (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
              as BuiltInEffect)
          .params
          .first,
      .2,
    );
  });

  test('ordinary equal target supersedes only its explicit override', () {
    projection
      ..replace(
        powers: {const FxChainTarget(address): false},
        parameters: {target: .2},
      )
      ..ordinaryWrite(target, .8);
    final result = projection.project(
      address,
      FxChainEnvelope(entries: [held]),
    );
    expect(result.chainEnabled, isFalse);
    expect((result.entries.single as BuiltInEffect).params.first, .8);
  });

  test('session replacement cancels stale awaited settings capture', () async {
    final ticket = projection.beginPending();
    final saving = saveTrackFxChain(
      settings: settings,
      looper: looper,
      projection: projection,
      channel: 0,
    );
    when(() => looper.sessionRevision).thenReturn(2);
    projection.finishPending(ticket);
    await saving;
    expect(await settings.loadTrackFxChain(0), isNull);
  });

  test('shutdown waits for projection and delayed durable save', () async {
    final ticket = projection.beginPending();
    final storage = Completer<void>();
    final save = projection.trackSave(() async {
      await projection.settlePending();
      await storage.future;
    }());
    var halted = false;
    final flush = projection.flush().then((_) => halted = true);
    await Future<void>.delayed(Duration.zero);
    expect(halted, isFalse);
    projection.finishPending(ticket);
    await Future<void>.delayed(Duration.zero);
    expect(halted, isFalse);
    storage.complete();
    await save;
    await flush;
    expect(halted, isTrue);
  });
}
