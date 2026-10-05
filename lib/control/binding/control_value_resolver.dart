import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

/// Resolves a typed [ControlValueTarget] against the live rig — the app-side
/// half of the continuous binding model, and the twin of part 6b's
/// [FxBindingResolver] for values rather than `enabled` flags (VGV).
///
/// This is the ONLY place a continuous mapping meets `looper_repository`, which
/// is what keeps `controller_repository` free of a looper dependency: it
/// carries mappings as opaque strings, `ControlCubit` decodes them, and this
/// resolver reads whether the named control exists and what value it holds.
///
/// ## Unresolvable targets go inert (A9)
///
/// Every method returns `null` / `false` rather than guessing when the target
/// does not name something that exists — a chain the rig has not configured, a
/// `slotId` no longer in the chain, a parameter index past the effect type's
/// own list. It NEVER falls back to the containing chain or to whatever now
/// sits at the old position: an expression pedal bound to a filter cutoff must
/// not start sweeping the delay that replaced it. A stale mapping is a no-op,
/// and its row says so.
extension ControlValueResolver on LooperRepository {
  /// Every value target the live rig can currently offer, in signal order:
  /// each configured chain's built-in effects with one entry per parameter,
  /// then the Mixer controls, then master gain.
  ///
  /// Only slots carrying a stable `slotId` are offered — an entry without one
  /// cannot be re-found after a reorder (A9). Hosted plugins are not offered:
  /// their parameters are addressed by plugin-assigned id rather than position
  /// and have no setter at every stage, so v1 leaves them to the on-screen
  /// controls.
  List<ControlValueTarget> availableValueTargets({
    ClickModeSnapshot? clickModeSnapshot,
    double? clickVolume,
    DecaySnapshot? decaySnapshot,
    FadeDurations? fadeDurations,
    OneShotSnapshot? oneShotSnapshot,
    RecordLengthSnapshot? recordLengthSnapshot,
    RecordStartSnapshot? recordStartSnapshot,
    RecordTimingSnapshot? recordTimingSnapshot,
  }) {
    final targets = <ControlValueTarget>[];
    void add(FxAddress address, List<TrackEffect> entries) {
      for (final fx in entries) {
        final slotId = fx.slotId;
        if (slotId == null || fx is! BuiltInEffect) continue;
        for (var param = 0; param < fx.type.params.length; param++) {
          targets.add(
            FxParamTarget(address: address, slotId: slotId, param: param),
          );
        }
      }
    }

    for (final input in allMonitors().keys.toList()..sort()) {
      add(FxAddress(stage: FxStage.input, index: input), monitorEffects(input));
    }
    final laneKeys = allLaneChains().keys.toList()
      ..sort(
        (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
      );
    for (final key in laneKeys) {
      add(
        FxAddress(stage: FxStage.loop, index: key.$1, lane: key.$2),
        laneEffects(key.$1, key.$2),
      );
    }
    for (final channel in allTrackChains().keys.toList()..sort()) {
      add(
        FxAddress(stage: FxStage.track, index: channel),
        trackEffects(channel),
      );
    }
    add(const FxAddress(stage: FxStage.allTracks), allTracksEffects);
    // Every destination the OPEN DEVICE has, not only the ones already
    // carrying a chain: a destination exists because the interface has the
    // jacks, and a picker that hid the empty ones would have nowhere to point
    // a binding at the chain the player is about to build there.
    for (var bus = 0; bus < state.outputBusCount; bus++) {
      add(FxAddress(stage: FxStage.output, index: bus), outputEffects(bus));
    }
    targets.addAll(availableMixValueTargets());
    if (clickVolume != null) targets.add(const ClickVolumeTarget());
    if (clickModeSnapshot != null) targets.add(const ClickModeValueTarget());
    if (recordStartSnapshot != null) targets.add(const CountInValueTarget());
    if (decaySnapshot != null) {
      targets.add(const DefaultDecayTarget());
      for (var channel = 0; channel < 8; channel++) {
        targets.add(TrackDecayTarget(channel));
      }
    }
    if (oneShotSnapshot != null) {
      targets.add(const DefaultOneShotTarget());
      for (var channel = 0; channel < 8; channel++) {
        targets.add(TrackOneShotTarget(channel));
      }
    }
    if (recordLengthSnapshot != null) {
      targets.add(const DefaultRecordLengthTarget());
      for (var channel = 0; channel < 8; channel++) {
        targets.add(TrackRecordLengthTarget(channel));
      }
    }
    if (recordTimingSnapshot != null) {
      targets.add(const DefaultRecordTimingTarget());
      for (var channel = 0; channel < 8; channel++) {
        targets.add(TrackRecordTimingTarget(channel));
      }
    }
    if (fadeDurations != null) {
      targets.add(const DefaultFadeTarget());
      for (var channel = 0; channel < 8; channel++) {
        targets.add(TrackFadeTarget(channel));
      }
    }
    // The master output always exists, so it is always offerable.
    targets.add(const MasterGainTarget());
    return targets;
  }

  /// Mixer controls alone, in the same signal order as the full catalogue.
  /// Topology watchers use this without enumerating every FX parameter.
  List<MixValueTarget> availableMixValueTargets() {
    final targets = <MixValueTarget>[];
    final rig = state;
    final inputs = rig.status.inputChannels;
    final excluded = rig.status.excludedInputMask;
    final setup = inputSetup;
    for (final track in rig.tracks) {
      targets
        ..add(TrackVolumeTarget(track.channel))
        ..add(TrackPanTarget(track.channel));
      for (var lane = 0; lane < laneCount(track.channel); lane++) {
        targets.add(LaneVolumeTarget(track.channel, lane));
      }
    }
    for (var input = 0; input < inputs; input++) {
      if ((excluded & (1 << input)) != 0) continue;
      targets.add(MonitorVolumeTarget(input));
      if (setup.pairOf(input) == null) {
        targets.add(InputPanTarget(input));
      } else if (input.isEven &&
          input + 1 < inputs &&
          (excluded & (1 << (input + 1))) == 0) {
        targets.add(PairBalanceTarget(input));
      }
    }
    for (var bus = 0; bus < rig.outputBusCount; bus++) {
      targets
        ..add(OutputLevelTarget(bus))
        ..add(OutputBalanceTarget(bus));
    }
    return targets;
  }

  /// Whether [target] names something that exists in the live rig.
  bool valueTargetResolves(
    ControlValueTarget target, {
    ClickModeSnapshot? clickModeSnapshot,
    double? clickVolume,
    DecaySnapshot? decaySnapshot,
    FadeDurations? fadeDurations,
    OneShotSnapshot? oneShotSnapshot,
    RecordLengthSnapshot? recordLengthSnapshot,
    RecordStartSnapshot? recordStartSnapshot,
    RecordTimingSnapshot? recordTimingSnapshot,
  }) => switch (target) {
    FxParamTarget() => _paramSlot(target) != null,
    TrackVolumeTarget(:final channel) ||
    TrackPanTarget(:final channel) => _trackExists(channel),
    LaneVolumeTarget(:final channel, :final lane) =>
      _trackExists(channel) && lane >= 0 && lane < laneCount(channel),
    MonitorVolumeTarget(:final input) => _inputExists(input),
    InputPanTarget(:final input) =>
      _inputExists(input) && inputSetup.pairOf(input) == null,
    PairBalanceTarget(:final input) =>
      input.isEven &&
          _inputExists(input) &&
          _inputExists(input + 1) &&
          inputSetup.pairs.containsKey(input),
    OutputLevelTarget(:final bus) ||
    OutputBalanceTarget(:final bus) => bus >= 0 && bus < state.outputBusCount,
    MasterGainTarget() => true,
    ClickModeValueTarget() => clickModeSnapshot != null,
    CountInValueTarget() => recordStartSnapshot != null,
    ClickVolumeTarget() => clickVolume != null,
    DecayValueTarget() => decaySnapshot != null && target.isStructurallyValid,
    OneShotValueTarget() =>
      oneShotSnapshot != null && target.isStructurallyValid,
    RecordLengthValueTarget() =>
      recordLengthSnapshot != null && target.isStructurallyValid,
    RecordTimingValueTarget() =>
      recordTimingSnapshot != null && target.isStructurallyValid,
    FadeValueTarget() => fadeDurations != null && target.isStructurallyValid,
  };

  /// The value [target] holds now (normalized `0..1`), or `null` when it does
  /// not resolve.
  ///
  /// What a newly added button parameter starts from on BOTH of its values, so
  /// adding the mapping invents no sound change.
  double? readValueTarget(
    ControlValueTarget target, {
    ClickModeSnapshot? clickModeSnapshot,
    double? clickVolume,
    DecaySnapshot? decaySnapshot,
    FadeDurations? fadeDurations,
    OneShotSnapshot? oneShotSnapshot,
    RecordLengthSnapshot? recordLengthSnapshot,
    RecordStartSnapshot? recordStartSnapshot,
    RecordTimingSnapshot? recordTimingSnapshot,
  }) => switch (target) {
    FxParamTarget(:final param) => _paramSlot(target)?.effect.params[param],
    MixValueTarget() => _readMixValue(target),
    MasterGainTarget() => masterGain,
    ClickModeValueTarget() =>
      clickModeSnapshot == null
          ? null
          : target.fromDomain(clickModeSnapshot.mode),
    CountInValueTarget() =>
      recordStartSnapshot == null
          ? null
          : target.fromDomain(recordStartSnapshot.settings.countInBars),
    ClickVolumeTarget() =>
      clickVolume == null ? null : target.fromDomain(clickVolume),
    DecayValueTarget() =>
      decaySnapshot == null || !target.isStructurallyValid
          ? null
          : target.fromDomain(decaySnapshot.effectivePercent(target.address)),
    OneShotValueTarget() =>
      oneShotSnapshot == null || !target.isStructurallyValid
          ? null
          : target.fromDomain(
              oneShot: oneShotSnapshot.effectiveOneShot(target.address),
            ),
    RecordLengthValueTarget() =>
      recordLengthSnapshot == null || !target.isStructurallyValid
          ? null
          : target.fromDomain(
              recordLengthSnapshot.effectiveBars(target.address),
            ),
    RecordTimingValueTarget() =>
      recordTimingSnapshot == null || !target.isStructurallyValid
          ? null
          : target.fromDomain(
              recordTimingSnapshot.effectiveTiming(target.address),
            ),
    FadeValueTarget(:final channel) =>
      fadeDurations == null || !target.isStructurallyValid
          ? null
          : target.fromDomain(
              channel == null
                  ? fadeDurations.defaultMs
                  : fadeDurations.effectiveMs(channel),
            ),
  };

  bool _trackExists(int channel) =>
      channel >= 0 && state.tracks.any((track) => track.channel == channel);

  bool _inputExists(int input) =>
      input >= 0 &&
      input < state.status.inputChannels &&
      (state.status.excludedInputMask & (1 << input)) == 0;

  double? _readMixValue(MixValueTarget target) {
    if (!valueTargetResolves(target)) return null;
    final mix = mixSettingsSnapshot;
    final value = switch (target) {
      TrackVolumeTarget(:final channel) => mix.trackLevels[channel] ?? 1,
      LaneVolumeTarget(:final channel, :final lane) =>
        mix.laneLevels[(channel, lane)] ?? 1,
      MonitorVolumeTarget(:final input) => mix.monitorLevels[input] ?? 1,
      TrackPanTarget(:final channel) => mix.trackPans[channel] ?? 0,
      InputPanTarget(:final input) => mix.inputSetup.panOf(input),
      PairBalanceTarget(:final input) => mix.inputSetup.balanceOf(input),
      OutputLevelTarget(:final bus) => mix.outputSetup.of(bus).level,
      OutputBalanceTarget(:final bus) => mix.outputSetup.of(bus).balance,
    };
    return target.fromDomain(value);
  }

  /// The CURRENT position and entry [target] names, or `null` when the chain,
  /// the slot, or the parameter index is gone (A9).
  ({int index, BuiltInEffect effect})? _paramSlot(FxParamTarget target) {
    final entries = chainEntriesAt(target.address);
    if (entries == null) return null;
    for (var i = 0; i < entries.length; i++) {
      final fx = entries[i];
      if (fx.slotId != target.slotId) continue;
      if (fx is! BuiltInEffect) return null;
      if (target.param < 0 || target.param >= fx.type.params.length) {
        return null;
      }
      return (index: i, effect: fx);
    }
    return null;
  }
}
