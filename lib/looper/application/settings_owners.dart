import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';

/// A family that did not reach applied, with the outcome it reported.
typedef OwnedSettingFailure = ({OwnedSetting key, SettingOutcome outcome});

/// Every owned setting family in one fixed order, for Session exclusion,
/// shutdown flush and Retry.
class SettingsOwners {
  /// Registers [all] in the order every caller acquires them.
  const SettingsOwners(this.all);

  /// The owners, in their fixed order.
  final List<SettingsOwner<Object, Object?>> all;

  /// Acquires every family in order, then runs [operation] while none can
  /// admit a write.
  Future<T> runExclusive<T>(Future<T> Function() operation) =>
      _exclusive(0, operation);

  Future<T> _exclusive<T>(int index, Future<T> Function() operation) =>
      index == all.length
      ? operation()
      : all[index].runExclusive(() => _exclusive(index + 1, operation));

  /// Drains and settles every family; the first that is not applied, if any.
  Future<OwnedSettingFailure?> flush() => _first((owner) => owner.flush());

  /// Retries every family; the first that still needs recovery, if any.
  Future<OwnedSettingFailure?> recover() => _first((owner) => owner.recover());

  Future<OwnedSettingFailure?> _first(
    Future<SettingOutcome> Function(SettingsOwner<Object, Object?>) run,
  ) async {
    for (final owner in all) {
      final outcome = await run(owner);
      if (!outcome.isOk) return (key: owner.key, outcome: outcome);
    }
    return null;
  }
}
