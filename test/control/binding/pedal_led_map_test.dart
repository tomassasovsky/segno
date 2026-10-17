import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
import 'package:segno/looper/model/interaction_mode.dart';

const _magenta = PedalColor(200, 0, 200);
const _stop = PedalBindingKey(button: PedalButton.stop);

void main() {
  test('a colour equal to its default is not stored', () {
    final leds = const PedalLedMap().withColor(
      InteractionMode.record,
      PedalLedGroup.mode,
      PedalLedState.current,
      ledRed,
    );
    expect(leds.isEmpty, isTrue);
    expect(leds, const PedalLedMap());
    expect(
      const PedalLedMap()
          .withCustomColor(_stop, PedalLedState.lit, ledWhite)
          .isEmpty,
      isTrue,
    );
  });

  test('a slot the mode does not have is refused', () {
    expect(
      () => const PedalLedMap().withColor(
        InteractionMode.mute,
        PedalLedGroup.tracks,
        PedalLedState.recording,
        _magenta,
      ),
      throwsFormatException,
    );
    expect(
      () => const PedalLedMap().withCustomColor(
        const PedalBindingKey(button: PedalButton.mode),
        PedalLedState.lit,
        _magenta,
      ),
      throwsFormatException,
    );
    expect(
      () => const PedalLedMap().withCustomColor(
        _stop,
        PedalLedState.armed,
        _magenta,
      ),
      throwsFormatException,
    );
  });

  test('reset puts one mode back and keeps the rest', () {
    final leds = const PedalLedMap()
        .withColor(
          InteractionMode.record,
          PedalLedGroup.tracks,
          PedalLedState.playing,
          _magenta,
        )
        .withColor(
          InteractionMode.mute,
          PedalLedGroup.bank,
          PedalLedState.pressed,
          _magenta,
        )
        .withCustomColor(_stop, PedalLedState.lit, _magenta);
    expect(leds.isEdited(InteractionMode.record), isTrue);
    final reset = leds.resetMode(InteractionMode.record);
    expect(reset.isEdited(InteractionMode.record), isFalse);
    expect(
      reset.colorFor(
        InteractionMode.record,
        PedalLedGroup.tracks,
        PedalLedState.playing,
      ),
      ledGreen,
    );
    expect(
      reset.colorFor(
        InteractionMode.mute,
        PedalLedGroup.bank,
        PedalLedState.pressed,
      ),
      _magenta,
    );
    expect(reset.customColorFor(_stop, PedalLedState.lit), _magenta);
  });

  test('every slot of every mode round-trips through JSON', () {
    var leds = const PedalLedMap();
    var n = 1;
    for (final mode in InteractionMode.values) {
      for (final MapEntry(key: group, value: states) in PedalLedMap.schema(
        mode,
      ).entries) {
        for (final state in states.keys) {
          leds = leds.withColor(
            mode,
            group,
            state,
            PedalColor(1, 2, n++ % 256),
          );
        }
      }
    }
    for (final button in PedalButton.values) {
      if (PedalBindingKey.unbindable.contains(button)) continue;
      final banks = PedalBindingKey.isBankKeyed(button) ? [0, 1] : [null];
      for (final bank in banks) {
        for (final state in PedalLedMap.customStates) {
          leds = leds.withCustomColor(
            PedalBindingKey(button: button, bank: bank),
            state,
            PedalColor(3, 4, n++ % 256),
          );
        }
      }
    }
    final decoded = PedalLedMap.fromJson(leds.toJson());
    expect(decoded, leds);
    expect(decoded.toJson(), leds.toJson());
  });

  test('equality ignores insertion order', () {
    final a = const PedalLedMap()
        .withColor(
          InteractionMode.fx,
          PedalLedGroup.stop,
          PedalLedState.engaged,
          _magenta,
        )
        .withCustomColor(_stop, PedalLedState.pressed, _magenta);
    final b = const PedalLedMap()
        .withCustomColor(_stop, PedalLedState.pressed, _magenta)
        .withColor(
          InteractionMode.fx,
          PedalLedGroup.stop,
          PedalLedState.engaged,
          _magenta,
        );
    expect(a, b);
    expect(a.toJson(), b.toJson());
  });
}
