import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';

/// A present target can be temporarily locked without losing its identity.
enum ControlEditBlock {
  clickCapture,
  lengthCapture,
  sharedLength,
  timingCapture,
}

/// Ephemeral read projection shared by MIDI, external controls and catalogues.
/// Create it for each render or intent; it owns no saved or mutable state.
class ControlAvailability {
  const ControlAvailability({
    required this.looper,
    this.clickVolume,
    this.clickModeSnapshot,
    this.decaySnapshot,
    this.oneShotSnapshot,
    this.recordLengthSnapshot,
    this.recordTimingSnapshot,
  });

  final LooperRepository looper;
  final double? clickVolume;
  final ClickModeSnapshot? clickModeSnapshot;
  final DecaySnapshot? decaySnapshot;
  final OneShotSnapshot? oneShotSnapshot;
  final RecordLengthSnapshot? recordLengthSnapshot;
  final RecordTimingSnapshot? recordTimingSnapshot;

  List<ControlValueTarget> get targets => looper.availableValueTargets(
    clickVolume: clickVolume,
    clickModeSnapshot: clickModeSnapshot,
    decaySnapshot: decaySnapshot,
    oneShotSnapshot: oneShotSnapshot,
    recordLengthSnapshot: recordLengthSnapshot,
    recordTimingSnapshot: recordTimingSnapshot,
  );

  bool resolves(Object? target) => switch (target) {
    ControlValueTarget() => looper.valueTargetResolves(
      target,
      clickVolume: clickVolume,
      clickModeSnapshot: clickModeSnapshot,
      decaySnapshot: decaySnapshot,
      oneShotSnapshot: oneShotSnapshot,
      recordLengthSnapshot: recordLengthSnapshot,
      recordTimingSnapshot: recordTimingSnapshot,
    ),
    FxBindingTarget() => looper.bindingResolves(target),
    _ => false,
  };

  bool resolvesKey(String key) => resolves(
    ControlValueTarget.tryParse(key) ?? FxBindingTarget.tryParse(key),
  );

  ControlEditBlock? blockedBy(Object? target) => switch (target) {
    ClickModeValueTarget() when clickModeSnapshot?.canEdit == false =>
      ControlEditBlock.clickCapture,
    RecordLengthValueTarget(:final address)
        when recordLengthSnapshot?.canEdit(address) == false =>
      recordLengthSnapshot!.captureLocked
          ? ControlEditBlock.lengthCapture
          : ControlEditBlock.sharedLength,
    RecordTimingValueTarget(:final address)
        when recordTimingSnapshot?.canEdit(address) == false =>
      ControlEditBlock.timingCapture,
    _ => null,
  };

  bool canAssign(Object target) =>
      resolves(target) && blockedBy(target) == null;

  double? value(ControlValueTarget target) => looper.readValueTarget(
    target,
    clickVolume: clickVolume,
    clickModeSnapshot: clickModeSnapshot,
    decaySnapshot: decaySnapshot,
    oneShotSnapshot: oneShotSnapshot,
    recordLengthSnapshot: recordLengthSnapshot,
    recordTimingSnapshot: recordTimingSnapshot,
  );
}
