import 'package:flutter_test/flutter_test.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

/// Refuses writes while [fail] is set.
class _Store extends FakeKeyValueStore {
  bool fail = false;

  @override
  Future<void> setInt(String key, int value) async {
    if (fail) throw StateError('disk full');
    return super.setInt(key, value);
  }
}

void main() {
  late _Store store;
  late TunerSettings settings;

  setUp(() {
    store = _Store();
    settings = TunerSettings(settings: SettingsRepository(store: store));
  });

  tearDown(() => settings.close());

  test('defaults to A4 = 440 Hz and the first available input', () async {
    await settings.load();
    expect(settings.live, const TunerPreferences());
    expect(settings.live.referenceHz, 440);
    expect(settings.live.input, -1);
  });

  test('loads the stored preferences, so they survive a restart', () async {
    store.values
      ..['tuner.reference_hz'] = 432
      ..['tuner.input'] = 2;
    await settings.load();
    expect(
      settings.live,
      const TunerPreferences(referenceHz: 432, input: 2),
    );
  });

  test('the reference clamps to 420-460 Hz and resets to 440', () async {
    expect(await settings.setReference(470), isTrue);
    expect(settings.live.referenceHz, 460);
    expect(store.values['tuner.reference_hz'], 460);
    expect(await settings.setReference(400), isTrue);
    expect(settings.live.referenceHz, 420);
    expect(
      await settings.setReference(SettingsRepository.tunerReferenceDefaultHz),
      isTrue,
    );
    expect(settings.live.referenceHz, 440);
    expect(settings.live.atLimit(21), isTrue);
    expect(settings.live.atLimit(20), isFalse);
    expect(settings.live.atLimit(-21), isTrue);
  });

  test('a failed write restores the previous value and says so', () async {
    await settings.setReference(432);
    await settings.setInput(1);
    final seen = <TunerPreferences>[];
    final subscription = settings.changes.listen(seen.add);
    addTearDown(subscription.cancel);
    store.fail = true;

    expect(await settings.setReference(433), isFalse);
    expect(settings.live.referenceHz, 432);
    expect(await settings.setInput(3), isFalse);
    expect(settings.live.input, 1);
    // Each failed write showed its value, then took it back.
    expect(seen.map((p) => p.referenceHz), [433, 432, 432, 432]);
    expect(store.values['tuner.reference_hz'], 432);
  });

  test('a negative input stores the first available', () async {
    expect(await settings.setInput(-5), isTrue);
    expect(settings.live.input, -1);
  });
}
