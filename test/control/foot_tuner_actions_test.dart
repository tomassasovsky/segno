import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/foot_tuner_actions.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _Repository extends Mock implements LooperRepository {}

class _Store extends FakeKeyValueStore {
  bool fail = false;

  @override
  Future<void> setInt(String key, int value) async {
    if (fail) throw StateError('disk full');
    return super.setInt(key, value);
  }
}

void main() {
  late _Repository repository;
  late _Store store;
  late TunerSettings settings;
  late FootTunerActions actions;

  setUpAll(() => registerFallbackValue(<int>{}));

  setUp(() {
    repository = _Repository();
    store = _Store();
    settings = TunerSettings(settings: SettingsRepository(store: store));
    actions = FootTunerActions(repository: repository, settings: settings);
    when(
      () => repository.setTunerInput(input: any(named: 'input')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setTunerMute(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() => settings.close());

  FootTunerProjection project(
    int inputs, {
    FootTunerSelection selection = const FootTunerSelection(),
    InputSetup? setup,
  }) => projectFootTuner(
    LooperState(
      status: EngineStatus(inputChannels: inputs),
      inputSetup: setup ?? const InputSetup.empty(),
    ),
    selection,
    settings.live,
  );

  test('arming moves the detector first, then mutes the input and its '
      'pair: the move clears the mute natively', () async {
    await settings.setInput(3);
    final projection = project(4, setup: InputSetup(pairs: const {2: 0}));
    expect(actions.arm(projection), isNull);
    verifyInOrder([
      () => repository.setTunerInput(input: 3),
      () => repository.setTunerMute({2, 3}),
    ]);
  });

  test('an audible source arms without a mute; nothing tunable disarms', () {
    expect(
      actions.arm(
        project(2, selection: const FootTunerSelection(muted: false)),
      ),
      isNull,
    );
    verify(() => repository.setTunerInput(input: 0)).called(1);
    verifyNever(() => repository.setTunerMute(any()));
    expect(actions.arm(project(0)), isNull);
    verify(() => repository.setTunerInput(input: -1)).called(1);
  });

  test('a refused arm or mute is reported', () {
    when(() => repository.setTunerMute(any())).thenReturn(EngineResult.invalid);
    expect(actions.arm(project(2)), FootTunerRefusal.armFailed);
    when(
      () => repository.setTunerInput(input: any(named: 'input')),
    ).thenReturn(EngineResult.notReady);
    expect(actions.arm(project(2)), FootTunerRefusal.armFailed);
  });

  test('disarm clears the detector', () {
    actions.disarm();
    verify(() => repository.setTunerInput(input: -1)).called(1);
  });

  test('the reference steps by 1 Hz, is refused at its limits, and resets '
      'to 440', () async {
    expect(await actions.stepReference(1), isNull);
    expect(settings.live.referenceHz, 441);
    await settings.setReference(460);
    expect(await actions.stepReference(1), FootTunerRefusal.limit);
    expect(settings.live.referenceHz, 460);
    expect(await actions.stepReference(-1), isNull);
    await settings.setReference(420);
    expect(await actions.stepReference(-1), FootTunerRefusal.limit);
    expect(await actions.resetReference(), isNull);
    expect(settings.live.referenceHz, 440);
  });

  test('a failed save is reported and keeps the previous value', () async {
    store.fail = true;
    expect(await actions.stepReference(1), FootTunerRefusal.saveFailed);
    expect(settings.live.referenceHz, 440);
    expect(await actions.select(3), FootTunerRefusal.saveFailed);
    expect(settings.live.input, -1);
  });

  test('select stores the input', () async {
    expect(await actions.select(3), isNull);
    expect(settings.live.input, 3);
  });

  test('Mute toggles the selection', () {
    expect(
      actions.toggleMute(const FootTunerSelection()).muted,
      isFalse,
    );
  });

  test('the next page wraps and tunes its first input', () {
    final first = project(18);
    var step = actions.nextPage(first, const FootTunerSelection());
    expect(step.selection.page, 1);
    expect(step.input, 4);
    step = actions.nextPage(
      project(18, selection: const FootTunerSelection(page: 4)),
      const FootTunerSelection(page: 4),
    );
    expect(step.selection.page, 0);
    expect(step.input, 0);
    // One page: nothing moves.
    step = actions.nextPage(project(4), const FootTunerSelection());
    expect(step.input, isNull);
    expect(step.selection.page, 0);
  });
}
