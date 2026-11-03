import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/console_leds/ambient_brightness.dart';
import 'package:segno/console_leds/cubit/console_leds_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _RefusingStore extends FakeKeyValueStore {
  @override
  Future<void> setBool(String key, {required bool value}) async =>
      throw StateError('storage unavailable');
}

PedalAmbientLight _reading(int level) =>
    PedalAmbientLight(sensor: PedalLightSensor.reading, level: level);

void main() {
  late FakeKeyValueStore store;
  late SettingsRepository settings;
  late FakePedalLink link;
  late PedalRepository pedal;
  late ConsoleLedsCubit cubit;

  setUp(() async {
    store = FakeKeyValueStore();
    settings = SettingsRepository(store: store);
    link = FakePedalLink();
    pedal = PedalRepository(link);
    cubit = ConsoleLedsCubit(settings: settings, pedal: pedal);
    link.hello();
    await pumpEventQueue();
    pedal.pushState(PedalStateFrame.blank());
  });

  tearDown(() async {
    await cubit.close();
    await pedal.dispose();
  });

  Iterable<LedLevelMessage> levelsSent() => link.sent.whereType();

  group('ConsoleLedsCubit', () {
    test(
      'a console never set is full and manual, and sends no level',
      () async {
        await cubit.load();
        expect(cubit.state.settings, const ConsoleLedSettings());
        expect(cubit.state.ledLevel, PedalLinkCodec.ledLevelFull);
        // The board shows full by itself: nothing changes on the wire, not
        // even on the next hello.
        link.hello();
        await pumpEventQueue();
        expect(levelsSent(), isEmpty);
      },
    );

    test('a manual brightness goes to the board and is saved', () async {
      await cubit.setBrightness(0.5);
      expect(levelsSent().last, LedLevelMessage(ledLevelOf(0.5)));
      expect((await settings.loadConsoleLeds()).brightness, 0.5);
      // Clamped to the range.
      await cubit.setBrightness(0);
      expect(cubit.state.settings.brightness, ConsoleLedSettings.minBrightness);
    });

    test('load restores the saved settings and their level', () async {
      await settings.saveConsoleLeds(
        const ConsoleLedSettings(brightness: 0.6),
      );
      await cubit.load();
      expect(cubit.state.settings.brightness, 0.6);
      expect(pedal.ledLevel, ledLevelOf(0.6));
    });

    group('without a sensor', () {
      test('Automatic is refused when the board reports none', () async {
        link.emit(const AmbientLightMessage(PedalAmbientLight.none));
        await pumpEventQueue();
        expect(cubit.state.light, PedalAmbientLight.none);
        await cubit.setAutomatic(automatic: true);
        expect(cubit.state.settings.automatic, isFalse);
        expect(store.values, isEmpty);
      });

      test('Automatic is refused when the board says nothing', () async {
        expect(cubit.state.light, isNull);
        await cubit.setAutomatic(automatic: true);
        expect(cubit.state.settings.automatic, isFalse);
      });

      test('a saved Automatic holds the manual brightness', () async {
        await settings.saveConsoleLeds(
          const ConsoleLedSettings(brightness: 0.7, automatic: true),
        );
        await cubit.load();
        expect(cubit.state.followingLight, isFalse);
        expect(pedal.ledLevel, ledLevelOf(0.7));
        // And can be turned off.
        await cubit.setAutomatic(automatic: false);
        expect(cubit.state.settings.automatic, isFalse);
      });
    });

    group('with a sensor', () {
      setUp(() async {
        link.emit(AmbientLightMessage(_reading(100)));
        await pumpEventQueue();
        await cubit.setAutomatic(automatic: true);
      });

      test('the LEDs follow the reading on the curve', () async {
        expect(cubit.state.followingLight, isTrue);
        final expected = consoleLedCurve.brightnessAt(
          100,
          dark: ConsoleLedSettings.defaultDarkReading,
          bright: ConsoleLedSettings.defaultBrightReading,
        );
        expect(cubit.state.brightness, expected);
        expect(pedal.ledLevel, ledLevelOf(expected));
        link.emit(AmbientLightMessage(_reading(170)));
        await pumpEventQueue();
        expect(pedal.ledLevel, PedalLinkCodec.ledLevelFull);
        link.emit(AmbientLightMessage(_reading(10)));
        await pumpEventQueue();
        expect(pedal.ledLevel, ledLevelOf(consoleLedCurve.floor));
      });

      test('the offset makes them brighter or darker', () async {
        final before = cubit.state.brightness;
        await cubit.setOffset(-0.5);
        expect(cubit.state.brightness, closeTo(before - 0.15, 1e-9));
        await cubit.setOffset(5);
        expect(cubit.state.settings.offset, 1);
        expect((await settings.loadConsoleLeds()).offset, 1);
      });

      test('a sensor that goes away leaves the manual brightness', () async {
        await cubit.setAutomatic(automatic: false);
        await cubit.setBrightness(0.4);
        await cubit.setAutomatic(automatic: true);
        link.emit(const AmbientLightMessage(PedalAmbientLight.none));
        await pumpEventQueue();
        expect(cubit.state.followingLight, isFalse);
        expect(pedal.ledLevel, ledLevelOf(0.4));
        // The choice itself survives, and follows again when it returns.
        expect(cubit.state.settings.automatic, isTrue);
        link.emit(AmbientLightMessage(_reading(170)));
        await pumpEventQueue();
        expect(pedal.ledLevel, PedalLinkCodec.ledLevelFull);
      });

      test('calibration takes the current reading as each point', () async {
        link.emit(AmbientLightMessage(_reading(20)));
        await pumpEventQueue();
        expect(cubit.state.canSetDark, isTrue);
        expect(cubit.state.canSetBright, isFalse);
        await cubit.setDarkReading();
        expect(cubit.state.settings.darkReading, 20);
        await cubit.setBrightReading(); // refused: too close
        expect(
          cubit.state.settings.brightReading,
          ConsoleLedSettings.defaultBrightReading,
        );
        link.emit(AmbientLightMessage(_reading(120)));
        await pumpEventQueue();
        await cubit.setBrightReading();
        expect(cubit.state.settings.brightReading, 120);
        final saved = await settings.loadConsoleLeds();
        expect((saved.darkReading, saved.brightReading), (20, 120));
        // The curve now runs between the owner's points.
        expect(pedal.ledLevel, PedalLinkCodec.ledLevelFull);
      });
    });

    test('a failed save throws, and the change applies anyway', () async {
      final refusing = ConsoleLedsCubit(
        settings: SettingsRepository(store: _RefusingStore()),
        pedal: pedal,
      );
      addTearDown(refusing.close);
      link.emit(AmbientLightMessage(_reading(100)));
      await pumpEventQueue();
      await expectLater(
        refusing.setAutomatic(automatic: true),
        throwsStateError,
      );
      expect(refusing.state.settings.automatic, isTrue);
    });
  });
}
