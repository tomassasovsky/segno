import 'package:ableton_preset/src/ableton_preset.dart';
import 'package:meta/meta.dart';

/// How one device parameter is typed.
sealed class ParameterSpec {
  const new(this.name);

  /// The parameter's element name in the preset (`Filter_Frequency`).
  final String name;

  /// Types [stored], clamped to its range; null when [stored] cannot be
  /// read as this parameter.
  ParameterValue? read(StoredValue stored);
}

/// A continuous parameter in its own unit (Hz, seconds, linear gain, 0..1).
final class NumberSpec extends ParameterSpec {
  /// A continuous parameter over [min]..[max].
  const new(super.name, this.min, this.max);

  /// The device's minimum.
  final double min;

  /// The device's maximum.
  final double max;

  /// The range a value is clamped to: the preset's own stored range when it
  /// lies within the device's (a preset can store a narrower one, as Drift's
  /// mixer gains at 0..1 in some presets and 0..+6 dB in others), else the
  /// device's.
  (double, double) range(StoredValue stored) {
    final lo = stored.min;
    final hi = stored.max;
    // Live stores ranges as computed floats (19.9999981 for 20 Hz).
    final slack = (max - min) * 1e-5;
    if (lo == null || hi == null || lo > hi) return (min, max);
    if (lo < min - slack || hi > max + slack) return (min, max);
    return (lo, hi);
  }

  @override
  NumberValue? read(StoredValue stored) {
    final value = double.tryParse(stored.raw);
    if (value == null || !value.isFinite) return null;
    final (lo, hi) = range(stored);
    return NumberValue(value.clamp(lo, hi));
  }
}

/// A stepped parameter: octaves, semitones, a synced-rate step, a count.
final class IntegerSpec extends ParameterSpec {
  /// A stepped parameter over [min]..[max].
  const new(super.name, this.min, this.max);

  /// The device's minimum.
  final int min;

  /// The device's maximum.
  final int max;

  @override
  IntegerValue? read(StoredValue stored) {
    final value = double.tryParse(stored.raw);
    if (value == null || !value.isFinite) return null;
    return IntegerValue(value.round().clamp(min, max));
  }
}

/// An on/off parameter, stored as `true` or `false`.
final class SwitchSpec extends ParameterSpec {
  /// An on/off parameter.
  const new(super.name);

  @override
  SwitchValue? read(StoredValue stored) => switch (stored.raw) {
    'true' => const SwitchValue(true),
    'false' => const SwitchValue(false),
    _ => null,
  };
}

/// A choice among named options, stored as a bare index into [options].
final class ChoiceSpec extends ParameterSpec {
  /// A choice whose stored index `i` means `options[i]`.
  const new(super.name, this.options);

  /// The options' names in stored order.
  final List<String> options;

  @override
  ChoiceValue? read(StoredValue stored) {
    final value = double.tryParse(stored.raw);
    if (value == null || !value.isFinite || value != value.roundToDouble()) {
      return null;
    }
    final index = value.toInt();
    if (index < 0 || index >= options.length) return null;
    return ChoiceValue(index, options[index]);
  }
}

/// A typed parameter value.
@immutable
sealed class ParameterValue {
  const new();
}

/// A continuous value, clamped to its range.
final class NumberValue extends ParameterValue {
  /// A continuous value.
  const new(this.value);

  /// The value in the parameter's own unit.
  final double value;

  @override
  bool operator ==(Object other) =>
      other is NumberValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'NumberValue($value)';
}

/// A stepped value, rounded and clamped to its range.
final class IntegerValue extends ParameterValue {
  /// A stepped value.
  const new(this.value);

  /// The step.
  final int value;

  @override
  bool operator ==(Object other) =>
      other is IntegerValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'IntegerValue($value)';
}

/// An on/off value.
final class SwitchValue extends ParameterValue {
  /// An on/off value.
  const new(this.on);

  /// Whether the switch is on.
  final bool on;

  @override
  bool operator ==(Object other) => other is SwitchValue && other.on == on;

  @override
  int get hashCode => on.hashCode;

  @override
  String toString() => 'SwitchValue($on)';
}

/// One of a choice's options.
final class ChoiceValue extends ParameterValue {
  /// The option at [index], called [name].
  const new(this.index, this.name);

  /// The stored index.
  final int index;

  /// The option's name. A device's DSP may order its options differently
  /// from the stored order, so engines map by name.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is ChoiceValue && other.index == index && other.name == name;

  @override
  int get hashCode => Object.hash(index, name);

  @override
  String toString() => 'ChoiceValue($index, $name)';
}

/// A preset's values as one device's schema types them.
final class DeviceValues {
  /// Typed values and what could not be typed.
  const new({
    required this.values,
    required this.unmapped,
    required this.missing,
  });

  /// Every parameter the schema typed, by name, in the schema's order.
  final Map<String, ParameterValue> values;

  /// Parameters in the preset that the schema does not know, or whose
  /// stored value it could not read (an enum index out of range, a number
  /// that does not parse).
  final List<String> unmapped;

  /// Parameters of the schema the preset does not store.
  final List<String> missing;
}

/// The parameters of one Live device, typed.
class DeviceSchema {
  /// The schema of [device] (its element name in a preset).
  const new({required this.device, required this.parameters});

  /// The device's element name (`Drift`).
  final String device;

  /// Every parameter the device stores.
  final List<ParameterSpec> parameters;

  /// Types [preset]'s values. [preset] must be a preset of [device].
  DeviceValues read(AbletonPreset preset) {
    if (preset.kind != PresetKind.device || preset.device != device) {
      throw ArgumentError.value(
        preset.device,
        'preset',
        'not a $device device preset',
      );
    }
    final values = <String, ParameterValue>{};
    final unmapped = <String>[];
    final missing = <String>[];
    final known = <String>{};
    for (final spec in parameters) {
      known.add(spec.name);
      final stored = preset.values[spec.name];
      if (stored == null) {
        missing.add(spec.name);
        continue;
      }
      final value = spec.read(stored);
      if (value == null) {
        unmapped.add(spec.name);
      } else {
        values[spec.name] = value;
      }
    }
    unmapped.addAll(preset.values.keys.where((name) => !known.contains(name)));
    return DeviceValues(values: values, unmapped: unmapped, missing: missing);
  }
}
