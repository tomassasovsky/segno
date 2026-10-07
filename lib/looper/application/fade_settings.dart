import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:settings_repository/settings_repository.dart';

/// Presents the Fade duration owner to the Fade surfaces and ControlCubit.
/// The transaction is the owner's; Fade has no native command.
///
/// A held controller value applies to the next gesture without becoming
/// durable: [live] carries it, while [confirmed], the stored and Session
/// image, keeps the controller's authored Released value.
class FadeSettings {
  /// Builds the owner over [repository]'s lifetime and [settings]' record.
  FadeSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
    required bool Function() blocked,
    required bool Function() sessionBlocked,
  }) : _blocked = blocked,
       _sessionBlocked = sessionBlocked,
       owner = SettingsOwner(
         repository: repository,
         family: FadeFamily(settings: settings),
       );

  final bool Function() _blocked;
  final bool Function() _sessionBlocked;
  bool _closing = false;

  /// The Fade duration transaction.
  final SettingsOwner<FadeDurations, String?> owner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [owner];

  /// Fires whenever the durations or their availability change.
  Stream<void> get changes => owner.changes;

  /// Whether Retry is needed before the durations can be read or edited.
  bool get needsRecovery => !owner.ready;

  /// The durable durations: what is stored and what Session Save captures.
  FadeDurations get confirmed => owner.durable;

  /// What the next gesture uses: [confirmed] plus any temporary held
  /// controller value.
  FadeDurations get live => owner.live;

  /// Session and device identity; controller work captured before a change
  /// is superseded.
  SettingLifetime get lifetime => owner.lifetime;

  /// Ordinary intent revision of Default (null) or one track.
  int revision(int? channel) => owner.revisionOf(channel);

  /// Accepted ordinary edits; a null track duration means Use default.
  Stream<({int? channel, int? milliseconds})> get ordinaryChanges =>
      owner.ordinaryChanges.map((change) {
        final channel = change.address as int?;
        return (
          channel: channel,
          milliseconds: channel == null
              ? change.value.defaultMs
              : change.value.overrides[channel],
        );
      });

  /// Restores the stored record once; an unreadable record makes only Fade
  /// unavailable.
  Future<void> load() => owner.load();

  /// Changes Default for subsequent gestures, keeping Custom memberships.
  Future<void> setDefault(int milliseconds) =>
      _edit(null, (_) => (milliseconds: milliseconds));

  /// Sets Custom, or removes it to inherit Default. Equality stays Custom.
  Future<void> setOverride(int channel, int? milliseconds) =>
      _edit(channel, (_) => (milliseconds: milliseconds));

  /// Moves Default, or one track's effective time ([channel] non-null), by
  /// [deltaMs] within 0.5–30 s. Applied to the live value when the edit runs,
  /// so rapid steps queued behind a write each count. Stepping an inherited
  /// track time creates its override; an edge step is a no-op.
  Future<void> step({required int deltaMs, int? channel}) => _edit(
    channel,
    relative: true,
    (live) {
      final current = channel == null
          ? live.defaultMs
          : live.effectiveMs(channel);
      final next = (current + deltaMs).clamp(500, 30000);
      return next == current ? null : (milliseconds: next);
    },
  );

  /// Accepts one controller value for Default ([channel] null) or a track,
  /// with an optional authored durable Released value. Completes false,
  /// without writing, once a Session, a device change or an ordinary edit of
  /// the same address replaced the captured [lifetime] or [revision].
  Future<bool> setControllerDuration(
    int? channel,
    int milliseconds, {
    required SettingLifetime lifetime,
    required int revision,
    int? releasedMilliseconds,
  }) async {
    if (_closing) return false;
    final outcome = await owner.updateController(
      (live) => fadeWith(live, channel, milliseconds),
      address: channel,
      lifetime: lifetime,
      revision: revision,
      released: releasedMilliseconds == null
          ? null
          : (held) => fadeWith(held, channel, releasedMilliseconds),
    );
    return outcome.isOk;
  }

  /// [edit] returns the new explicit value at [channel] (null removes a
  /// track's override), or null itself for no change.
  ///
  /// A [relative] edit is never replaced by a later one while it waits: each
  /// step counts.
  Future<void> _edit(
    int? channel,
    ({int? milliseconds})? Function(FadeDurations live) edit, {
    bool relative = false,
  }) async {
    if (_closing || _blocked()) {
      throw StateError('Fade duration edit is unavailable');
    }
    final change = edit(owner.live);
    if (owner.ready && change == null) return;
    // An invalid duration or track is refused before it is queued.
    if (change != null) fadeWith(owner.live, channel, change.milliseconds);
    final outcome = await owner.update(
      (live) {
        final change = edit(live);
        return change == null
            ? live
            : fadeWith(live, channel, change.milliseconds);
      },
      address: channel,
      edit: relative ? Object() : null,
    );
    if (!outcome.isOk && outcome.status != SettingStatus.superseded) {
      throw StateError('Fade duration edit was not applied: ${outcome.status}');
    }
  }

  /// Retry; refused while a Session transition holds the durations.
  Future<bool> recover() async {
    if (_closing || _sessionBlocked()) return false;
    return (await owner.recover()).isOk;
  }

  /// Installs the accepted Session durations inside the registry's Session
  /// exclusion.
  Future<void> installSession(FadeDurations incoming) =>
      owner.installSession(incoming);

  /// Lets admitted work finish, then disposes the owner.
  Future<void> close() {
    _closing = true;
    return owner.close();
  }
}
