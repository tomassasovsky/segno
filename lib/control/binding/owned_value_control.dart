import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

/// Every owned value target, in catalogue order: Click volume, Hear click,
/// Count-in, then each per-track family's Default before its eight tracks.
final List<OwnedValueTarget> ownedValueTargets = List.unmodifiable([
  const ClickVolumeTarget(),
  const ClickModeValueTarget(),
  const CountInValueTarget(),
  const DefaultDecayTarget(),
  for (var channel = 0; channel < 8; channel++) TrackDecayTarget(channel),
  const DefaultOneShotTarget(),
  for (var channel = 0; channel < 8; channel++) TrackOneShotTarget(channel),
  const DefaultRecordLengthTarget(),
  for (var channel = 0; channel < 8; channel++)
    TrackRecordLengthTarget(channel),
  const DefaultRecordTimingTarget(),
  for (var channel = 0; channel < 8; channel++)
    TrackRecordTimingTarget(channel),
  const DefaultFadeTarget(),
  for (var channel = 0; channel < 8; channel++) TrackFadeTarget(channel),
  const BackingLevelTarget(),
  const BackingPanTarget(),
  const ClickPanTarget(),
]);

/// What an owned value holds now and whether it can be offered.
abstract interface class OwnedValueReadout {
  /// [target]'s normalized value, or null while it does not resolve.
  double? read(OwnedValueTarget target);

  /// Whether [target] names a value its owner can read and write now.
  bool resolves(OwnedValueTarget target);
}

/// One accepted change of ordinary intent. `superseded` retires older
/// controller claims on `target`; a non-null `value` is then the accepted
/// ordinary value.
typedef OwnedValueChange = ({
  OwnedValueTarget target,
  double? value,
  bool superseded,
});

/// The targets whose owner lifetime moved on: `superseded` retire their
/// controller claims; `invalidated` also reset the sources mapping them.
typedef OwnedLifetimeChanges = ({
  List<OwnedValueTarget> superseded,
  Set<OwnedValueTarget> invalidated,
});

/// The one port `ControlCubit` dispatches owned values through. The
/// conversion from a target to its family's owner lives in the
/// implementation, so dispatch never names a family.
abstract interface class OwnedValueControl implements OwnedValueReadout {
  /// [cleanup] also accepts a fixed address whose owner is recovering, so a
  /// refused release stays owed instead of being dropped.
  @override
  bool resolves(OwnedValueTarget target, {bool cleanup = false});

  /// [target]'s owner lifetime and ordinary revision, captured before
  /// controller work queues.
  Object origin(OwnedValueTarget target);

  /// Whether [origin] still holds for [target].
  bool originCurrent(OwnedValueTarget target, Object origin);

  /// Writes a controller [value] with its optional authored durable
  /// [released] value. True only when the owner accepted it and [origin]
  /// still holds.
  Future<bool> writeController(
    OwnedValueTarget target,
    double value, {
    required Object origin,
    double? released,
  });

  /// Accepted ordinary intent of every owned family.
  Stream<OwnedValueChange> get ordinaryChanges;

  /// The owned part of the release-retry eligibility: changes whenever a
  /// refused owned release could now succeed.
  Object get eligibilityKey;

  /// Every family's owner lifetime, compared to see whether one moved on.
  Object get lifetimes;

  /// The targets whose family lifetime differs from [since].
  OwnedLifetimeChanges lifetimeChanges(Object since);
}

/// The owned families' accepted read models, for a page or catalogue that
/// renders from Bloc state. A null field means that family is unavailable.
final class OwnedValueSnapshots implements OwnedValueReadout {
  /// Collects the read models a page already holds.
  const OwnedValueSnapshots({
    this.clickVolume,
    this.clickModeSnapshot,
    this.recordStartSnapshot,
    this.decaySnapshot,
    this.oneShotSnapshot,
    this.recordLengthSnapshot,
    this.recordTimingSnapshot,
    this.fadeDurations,
    this.backingMix,
    this.clickPan,
  });

  /// Accepted Click volume gain.
  final double? clickVolume;

  /// Accepted Hear click mode and its capture lock.
  final ClickModeSnapshot? clickModeSnapshot;

  /// Accepted Count-in and Sound pair and its capture lock.
  final RecordStartSnapshot? recordStartSnapshot;

  /// Accepted Decay values.
  final DecaySnapshot? decaySnapshot;

  /// Accepted Loop/Once values.
  final OneShotSnapshot? oneShotSnapshot;

  /// Accepted Record length values and their locks.
  final RecordLengthSnapshot? recordLengthSnapshot;

  /// Accepted Record timing values and their locks.
  final RecordTimingSnapshot? recordTimingSnapshot;

  /// Live Fade durations.
  final FadeDurations? fadeDurations;

  /// The live backing level, pan, outputs and End (#1200).
  final BackingMix? backingMix;

  /// The live click pan (#1200).
  final double? clickPan;

  @override
  bool resolves(OwnedValueTarget target) => switch (target) {
    ClickVolumeTarget() => clickVolume != null,
    ClickModeValueTarget() => clickModeSnapshot != null,
    CountInValueTarget() => recordStartSnapshot != null,
    DecayValueTarget() => decaySnapshot != null && target.isStructurallyValid,
    OneShotValueTarget() =>
      oneShotSnapshot != null && target.isStructurallyValid,
    RecordLengthValueTarget() =>
      recordLengthSnapshot != null && target.isStructurallyValid,
    RecordTimingValueTarget() =>
      recordTimingSnapshot != null && target.isStructurallyValid,
    FadeValueTarget() => fadeDurations != null && target.isStructurallyValid,
    BackingLevelTarget() || BackingPanTarget() => backingMix != null,
    ClickPanTarget() => clickPan != null,
  };

  @override
  double? read(OwnedValueTarget target) {
    if (!resolves(target)) return null;
    return switch (target) {
      ClickVolumeTarget() => target.fromDomain(clickVolume!),
      ClickModeValueTarget() => target.fromDomain(clickModeSnapshot!.mode),
      CountInValueTarget() => target.fromDomain(
        recordStartSnapshot!.settings.countInBars,
      ),
      DecayValueTarget() => target.fromDomain(
        decaySnapshot!.effectivePercent(target.address),
      ),
      OneShotValueTarget() => target.fromDomain(
        oneShot: oneShotSnapshot!.effectiveOneShot(target.address),
      ),
      RecordLengthValueTarget() => target.fromDomain(
        recordLengthSnapshot!.effectiveBars(target.address),
      ),
      RecordTimingValueTarget() => target.fromDomain(
        recordTimingSnapshot!.effectiveTiming(target.address),
      ),
      FadeValueTarget(:final channel) => target.fromDomain(
        channel == null
            ? fadeDurations!.defaultMs
            : fadeDurations!.effectiveMs(channel),
      ),
      BackingLevelTarget() => target.fromDomain(backingMix!.level),
      BackingPanTarget() => target.fromDomain(backingMix!.pan),
      ClickPanTarget() => target.fromDomain(clickPan!),
    };
  }
}
