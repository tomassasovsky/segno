import 'package:backing_repository/backing_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:settings_repository/settings_repository.dart';

/// The backing mix (level, pan, outputs, End) and the click pan as #1159
/// owners (#1200 Part 5): stored, restored at start, captured and replaced
/// by a Session, and applied through the backing repository.
class BackingSettings {
  /// Builds both owners over [repository]'s lifetime, [settings]' records
  /// and the [backing] repository they drive.
  BackingSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
    required BackingRepository backing,
  }) : mixOwner = SettingsOwner(
         repository: repository,
         family: BackingMixFamily(settings: settings, backing: backing),
       ),
       clickPanOwner = SettingsOwner(
         repository: repository,
         family: ClickPanFamily(settings: settings, backing: backing),
       );

  /// The backing mix transaction.
  final SettingsOwner<BackingMix, String?> mixOwner;

  /// The click pan transaction.
  final SettingsOwner<double, double?> clickPanOwner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [mixOwner, clickPanOwner];

  /// The durable mix: what is stored and what Session Save captures.
  BackingMix get mix => mixOwner.durable;

  /// The durable click pan.
  double get clickPan => clickPanOwner.durable;

  /// Restores both stored values; an unreadable one makes only that owner
  /// unavailable.
  Future<void> load() => Future.wait([mixOwner.load(), clickPanOwner.load()]);

  /// Sets the backing gain, `0..2`.
  Future<SettingOutcome> setLevel(double level) =>
      _edit(BackingMixField.level, (mix) => mix.copyWith(level: level));

  /// Sets the backing balance, `-1..1`.
  Future<SettingOutcome> setPan(double pan) =>
      _edit(BackingMixField.pan, (mix) => mix.copyWith(pan: pan));

  /// Sets the output channels the backing sounds on.
  Future<SettingOutcome> setOutput(int mask) =>
      _edit(BackingMixField.output, (mix) => mix.copyWith(outputMask: mask));

  /// Sets what happens at the loaded file's end.
  Future<SettingOutcome> setEnd(BackingEnd end) =>
      _edit(BackingMixField.end, (mix) => mix.copyWith(end: end));

  /// Sets the click pan, `-1..1`.
  Future<SettingOutcome> setClickPan(double pan) {
    if (!pan.isFinite || pan < -1 || pan > 1) {
      throw RangeError.range(pan, -1, 1, 'pan');
    }
    return clickPanOwner.set(pan);
  }

  Future<SettingOutcome> _edit(
    BackingMixField field,
    BackingMix Function(BackingMix live) change,
  ) {
    if (!change(mixOwner.live).isValid) {
      throw RangeError('backing ${field.name} out of range');
    }
    return mixOwner.update(change, address: field);
  }

  /// Installs a recalled Session's mix and click pan inside the registry's
  /// Session exclusion.
  Future<void> installSession(BackingMix mix, double clickPan) async {
    await mixOwner.installSession(mix);
    await clickPanOwner.installSession(clickPan);
  }

  /// Lets admitted work finish, then disposes both owners.
  Future<void> close() async {
    await mixOwner.close();
    await clickPanOwner.close();
  }
}
