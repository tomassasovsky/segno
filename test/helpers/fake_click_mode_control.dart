import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/click_mode.dart';

/// An unavailable Hear click owner for unrelated control tests.
/// Click behavior tests use the real owner instead.
class FakeClickModeControl implements ClickModeControl {
  @override
  ClickModeSnapshot? get clickModeSnapshot => null;

  @override
  ClickMode get durableClickMode => ClickMode.off;

  @override
  ClickModeLifetime get clickModeLifetime =>
      (sessionRevision: 0, mixGeneration: 0);

  @override
  int get clickModeRevision => 0;

  @override
  Stream<ClickMode> get ordinaryClickModeChanges => const Stream.empty();

  @override
  Future<ClickModeOutcome> setClickMode(ClickMode mode) async =>
      const ClickModeOutcome(ClickModeStatus.rejected);

  @override
  Future<ClickModeOutcome> setControllerClickMode(
    ClickMode mode, {
    required ClickModeLifetime lifetime,
    required int revision,
    ClickMode? releasedMode,
  }) async => const ClickModeOutcome(ClickModeStatus.rejected);
}
