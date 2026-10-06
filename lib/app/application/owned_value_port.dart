import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/owned_value_control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';

/// The origin of a family with ordinary revisions; Click volume's origin is
/// its lifetime alone.
typedef _Origin = ({SettingLifetime lifetime, int revision});

/// Every family's lifetime, in the order the targets are retired.
typedef _Lifetimes = ({
  SettingLifetime decay,
  SettingLifetime oneShot,
  SettingLifetime recordLength,
  SettingLifetime recordTiming,
  SettingLifetime clickMode,
  SettingLifetime recordStart,
  SettingLifetime fade,
  SettingLifetime clickVolume,
});

/// [OwnedValueControl] over the owned families' controller ports: the one
/// place that converts an owned target to its family's owner.
class OwnedValuePort implements OwnedValueControl {
  /// Joins the owned families' ports for `ControlCubit`.
  OwnedValuePort({
    required LooperRepository looper,
    required ClickVolumeControl clickVolume,
    required ClickModeControl clickMode,
    required RecordStartControl recordStart,
    required DecayControl decay,
    required OneShotControl oneShot,
    required RecordLengthControl recordLength,
    required RecordTimingControl recordTiming,
    required FadeSettings fade,
  }) : _looper = looper,
       _clickVolume = clickVolume,
       _clickMode = clickMode,
       _recordStart = recordStart,
       _decay = decay,
       _oneShot = oneShot,
       _recordLength = recordLength,
       _recordTiming = recordTiming,
       _fade = fade;

  final LooperRepository _looper;
  final ClickVolumeControl _clickVolume;
  final ClickModeControl _clickMode;
  final RecordStartControl _recordStart;
  final DecayControl _decay;
  final OneShotControl _oneShot;
  final RecordLengthControl _recordLength;
  final RecordTimingControl _recordTiming;
  final FadeSettings _fade;

  /// The families' accepted read models now.
  OwnedValueSnapshots get snapshots => OwnedValueSnapshots(
    clickVolume: _clickVolume.clickVolume,
    clickModeSnapshot: _clickMode.clickModeSnapshot,
    recordStartSnapshot: _recordStart.recordStartSnapshot,
    decaySnapshot: _decay.decaySnapshot,
    oneShotSnapshot: _oneShot.oneShotSnapshot,
    recordLengthSnapshot: _recordLength.recordLengthSnapshot,
    recordTimingSnapshot: _recordTiming.recordTimingSnapshot,
    fadeDurations: _fade.needsRecovery ? null : _fade.live,
  );

  @override
  double? read(OwnedValueTarget target) => snapshots.read(target);

  /// Fixed scopes stay structurally present during owner recovery: their
  /// refused release stays owed, while new acquisitions still need
  /// readiness.
  @override
  bool resolves(OwnedValueTarget target, {bool cleanup = false}) =>
      (cleanup &&
          switch (target) {
            ClickModeValueTarget() ||
            CountInValueTarget() ||
            FadeValueTarget() => true,
            RecordTimingValueTarget(:final address) => address.isValid,
            _ => false,
          }) ||
      snapshots.resolves(target);

  @override
  Object origin(OwnedValueTarget target) => switch (target) {
    ClickVolumeTarget() => _clickVolume.clickVolumeLifetime,
    ClickModeValueTarget() => (
      lifetime: _clickMode.clickModeLifetime,
      revision: _clickMode.clickModeRevision,
    ),
    CountInValueTarget() => (
      lifetime: _recordStart.recordStartLifetime,
      revision: _recordStart.recordStartRevision,
    ),
    DecayValueTarget(:final address) => (
      lifetime: _decay.decayLifetime,
      revision: _decay.decayRevision(address),
    ),
    OneShotValueTarget(:final address) => (
      lifetime: _oneShot.oneShotLifetime,
      revision: _oneShot.oneShotRevision(address),
    ),
    RecordLengthValueTarget(:final address) => (
      lifetime: _recordLength.recordLengthLifetime,
      revision: _recordLength.recordLengthRevision(address),
    ),
    RecordTimingValueTarget(:final address) => (
      lifetime: _recordTiming.recordTimingLifetime,
      revision: _recordTiming.recordTimingRevision(address),
    ),
    FadeValueTarget(:final channel) => (
      lifetime: _fade.lifetime,
      revision: _fade.revision(channel),
    ),
  };

  @override
  bool originCurrent(OwnedValueTarget target, Object origin) =>
      origin == this.origin(target);

  @override
  Future<bool> writeController(
    OwnedValueTarget target,
    double value, {
    required Object origin,
    double? released,
  }) async {
    if (!value.isFinite || !originCurrent(target, origin)) return false;
    final accepted = switch (target) {
      ClickVolumeTarget() =>
        _clickVolume
            .setControllerClickVolume(
              target.toDomain(value),
              lifetime: origin as SettingLifetime,
              releasedVolume: released == null
                  ? null
                  : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      ClickModeValueTarget() =>
        _clickMode
            .setControllerClickMode(
              target.toDomain(value),
              lifetime: (origin as _Origin).lifetime,
              revision: origin.revision,
              releasedMode: released == null ? null : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      CountInValueTarget() =>
        _recordStart
            .setControllerCountIn(
              target.toDomain(value),
              lifetime: (origin as _Origin).lifetime,
              revision: origin.revision,
              releasedBars: released == null ? null : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      DecayValueTarget() =>
        _decay
            .setControllerDecay(
              target.address,
              target.toDomain(value),
              lifetime: (origin as _Origin).lifetime,
              revision: origin.revision,
              releasedPercent: released == null
                  ? null
                  : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      OneShotValueTarget() =>
        _oneShot
            .setControllerOneShot(
              target.address,
              oneShot: target.toDomain(value),
              lifetime: (origin as _Origin).lifetime,
              revision: origin.revision,
              releasedOneShot: released == null
                  ? null
                  : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      RecordLengthValueTarget() =>
        _recordLength
            .setControllerRecordLength(
              target.address,
              target.toDomain(value),
              lifetime: (origin as _Origin).lifetime,
              revision: origin.revision,
              releasedBars: released == null ? null : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      RecordTimingValueTarget() =>
        _recordTiming
            .setControllerTiming(
              target.address,
              target.toDomain(value),
              lifetime: (origin as _Origin).lifetime,
              revision: origin.revision,
              releasedTiming: released == null
                  ? null
                  : target.toDomain(released),
            )
            .then((outcome) => outcome.isOk),
      FadeValueTarget() => _fade.setControllerDuration(
        target.channel,
        target.toDomain(value),
        lifetime: (origin as _Origin).lifetime,
        revision: origin.revision,
        releasedMilliseconds: released == null
            ? null
            : target.toDomain(released),
      ),
    };
    return await accepted && originCurrent(target, origin);
  }

  @override
  late final Stream<OwnedValueChange> ordinaryChanges = _ordinaryChanges();

  Stream<OwnedValueChange> _ordinaryChanges() {
    final subscriptions = <StreamSubscription<Object?>>[];
    late final StreamController<OwnedValueChange> controller;
    void add(
      OwnedValueTarget target,
      double? value, {
      bool superseded = false,
    }) => controller.add((
      target: target,
      value: value,
      superseded: superseded || value == null,
    ));
    controller = StreamController<OwnedValueChange>.broadcast(
      sync: true,
      onListen: () => subscriptions.addAll([
        _clickVolume.ordinaryClickVolumeChanges.listen(
          (gain) => add(
            const ClickVolumeTarget(),
            const ClickVolumeTarget().fromDomain(gain),
          ),
        ),
        _decay.ordinaryDecayChanges.listen((change) {
          final target = change.address.channel == null
              ? const DefaultDecayTarget()
              : TrackDecayTarget(change.address.channel!);
          add(
            target,
            change.percent == null ? null : target.fromDomain(change.percent!),
          );
        }),
        _oneShot.ordinaryOneShotChanges.listen((change) {
          final target = change.address.channel == null
              ? const DefaultOneShotTarget()
              : TrackOneShotTarget(change.address.channel!);
          add(
            target,
            change.oneShot == null
                ? null
                : target.fromDomain(oneShot: change.oneShot!),
          );
        }),
        _recordLength.ordinaryRecordLengthChanges.listen((change) {
          final target = change.address.channel == null
              ? const DefaultRecordLengthTarget()
              : TrackRecordLengthTarget(change.address.channel!);
          add(
            target,
            change.bars == null ? null : target.fromDomain(change.bars!),
          );
        }),
        _recordTiming.ordinaryRecordTimingChanges.listen((change) {
          final target = change.address.channel == null
              ? const DefaultRecordTimingTarget()
              : TrackRecordTimingTarget(change.address.channel!);
          add(
            target,
            change.timing == null ? null : target.fromDomain(change.timing!),
          );
        }),
        _clickMode.ordinaryClickModeChanges.listen(
          (mode) => add(
            const ClickModeValueTarget(),
            const ClickModeValueTarget().fromDomain(mode),
          ),
        ),
        // Sound and Count-in share one authority, even when Count-in stays
        // Off, so every change supersedes before it records.
        _recordStart.ordinaryRecordStartChanges.listen(
          (pair) => add(
            const CountInValueTarget(),
            const CountInValueTarget().fromDomain(pair.countInBars),
            superseded: true,
          ),
        ),
        _fade.ordinaryChanges.listen((change) {
          final target = change.channel == null
              ? const DefaultFadeTarget()
              : TrackFadeTarget(change.channel!);
          add(
            target,
            change.milliseconds == null
                ? null
                : target.fromDomain(change.milliseconds!),
          );
        }),
      ]),
      onCancel: () async {
        final active = List.of(subscriptions);
        subscriptions.clear();
        for (final subscription in active) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  @override
  Object get eligibilityKey => (
    _looper.recordLengthCaptureLocked,
    _looper.sessionTransport.looperMode,
    _looper.lengthSettingsSettled,
    _looper.recordTimingCaptureLocked,
    _looper.recordTimingSettingsSettled,
    _looper.clickModeCaptureLocked,
    _looper.clickModeSettled,
    _clickMode.clickModeSnapshot != null,
    _looper.recordStartCaptureLocked,
    _looper.recordStartSettingsSettled,
    _recordStart.recordStartSnapshot != null,
  );

  @override
  Object get lifetimes => (
    decay: _decay.decayLifetime,
    oneShot: _oneShot.oneShotLifetime,
    recordLength: _recordLength.recordLengthLifetime,
    recordTiming: _recordTiming.recordTimingLifetime,
    clickMode: _clickMode.clickModeLifetime,
    recordStart: _recordStart.recordStartLifetime,
    fade: _fade.lifetime,
    clickVolume: _clickVolume.clickVolumeLifetime,
  );

  /// Click volume's sources are reset as well, as before the port; the
  /// other families only retire their claims.
  @override
  OwnedLifetimeChanges lifetimeChanges(Object since) {
    final before = since as _Lifetimes;
    final now = lifetimes as _Lifetimes;
    return (
      superseded: [
        if (before.decay != now.decay)
          ...ownedValueTargets.whereType<DecayValueTarget>(),
        if (before.oneShot != now.oneShot)
          ...ownedValueTargets.whereType<OneShotValueTarget>(),
        if (before.recordLength != now.recordLength)
          ...ownedValueTargets.whereType<RecordLengthValueTarget>(),
        if (before.recordTiming != now.recordTiming)
          ...ownedValueTargets.whereType<RecordTimingValueTarget>(),
        if (before.clickMode != now.clickMode) const ClickModeValueTarget(),
        if (before.recordStart != now.recordStart) const CountInValueTarget(),
        if (before.fade != now.fade)
          ...ownedValueTargets.whereType<FadeValueTarget>(),
      ],
      invalidated: {
        if (before.clickVolume != now.clickVolume) const ClickVolumeTarget(),
      },
    );
  }
}
