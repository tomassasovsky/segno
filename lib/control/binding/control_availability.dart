import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/owned_value_control.dart';

/// A present target can be temporarily locked without losing its identity.
enum ControlEditBlock {
  clickCapture,
  lengthCapture,
  sharedLength,
  timingCapture,
  recordStartCapture,
}

/// Ephemeral read projection shared by MIDI, external controls and catalogues.
/// Create it for each render or intent; it owns no saved or mutable state.
class ControlAvailability {
  const ControlAvailability({
    required this.looper,
    this.owned = const OwnedValueSnapshots(),
  });

  final LooperRepository looper;

  /// The owned families' read models; a null field leaves that family out.
  final OwnedValueSnapshots owned;

  List<ControlValueTarget> get targets =>
      looper.availableValueTargets(owned: owned);

  bool resolves(Object? target) => switch (target) {
    ControlValueTarget() => looper.valueTargetResolves(target, owned: owned),
    FxBindingTarget() => looper.bindingResolves(target),
    _ => false,
  };

  bool resolvesKey(String key) => resolves(
    ControlValueTarget.tryParse(key) ?? FxBindingTarget.tryParse(key),
  );

  ControlEditBlock? blockedBy(Object? target) => switch (target) {
    ClickModeValueTarget() when owned.clickModeSnapshot?.canEdit == false =>
      ControlEditBlock.clickCapture,
    CountInValueTarget() when owned.recordStartSnapshot?.canEdit == false =>
      ControlEditBlock.recordStartCapture,
    RecordLengthValueTarget(:final address)
        when owned.recordLengthSnapshot?.canEdit(address) == false =>
      owned.recordLengthSnapshot!.captureLocked
          ? ControlEditBlock.lengthCapture
          : ControlEditBlock.sharedLength,
    RecordTimingValueTarget(:final address)
        when owned.recordTimingSnapshot?.canEdit(address) == false =>
      ControlEditBlock.timingCapture,
    _ => null,
  };

  bool canAssign(Object target) =>
      resolves(target) && blockedBy(target) == null;

  double? value(ControlValueTarget target) =>
      looper.readValueTarget(target, owned: owned);
}
