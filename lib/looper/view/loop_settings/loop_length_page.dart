import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/loop_settings_feedback_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/model/record_options_view_state.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';

/// The most bars a fixed length preset can hold (the engine's 1..64).
const int kMaxLengthPresetBars = 64;

/// The later-track lengths the Defaults scope offers: `0` is Auto (round up
/// to whole base loops), the rest fixed multiples of the base loop. Three,
/// because a longer multiple is a length set on the track itself.
const List<int> kDefaultMultiples = [0, 1, 2, 3];

/// What the Length & quantize page reads off the looper for one scope.
typedef _LengthValues = ({
  int count,
  LooperMode mode,
  bool capturing,
});

_LengthValues _lengthValues(LooperState state) {
  return (
    count: state.tracks.length,
    mode: state.transport.looperMode,
    capturing: state.tracks.any((t) => t.isCapturing),
  );
}

/// The Length & quantize page: the Tracks / Defaults / 1-8 selector, then
/// Loop length (Auto or a bar count) and Record timing for that scope, each
/// with its origin tag and a Use default when a track overrides it (the pen's
/// `length-timing`, 1720 x 474 at (100, 349)). In Multi a track's length is
/// the shared default; a capture in progress locks the page behind a banner.
///
/// The Defaults scope adds one row the pen does not draw: how long later
/// tracks record, as a multiple of the base loop (#1199, D3). It was the
/// settings tray's Recording tab. It sits under Record timing, compact
/// enough that the locked layout still ends inside the frame.
class LoopLengthPage extends StatefulWidget {
  /// Creates a [LoopLengthPage].
  const LoopLengthPage({super.key});

  @override
  State<LoopLengthPage> createState() => _LoopLengthPageState();
}

class _LoopLengthPageState extends State<LoopLengthPage> {
  /// Where the later-tracks row starts below the section top, under the
  /// record timing note (one 24 px line at `top + 439`): a section's gap when
  /// there is room, and closer while a capture's banner pushes the page down.
  static double _multipleTop({required bool locked}) => locked ? 480 : 528;

  /// The later-tracks choices' width: four tokens, leaving the rest of the
  /// row to the note that says what they are multiples of.
  static const double _multipleWidth = 592;

  /// The later-tracks row's height. Shorter than the pen's 96 so the locked
  /// layout (section top 441) ends at 981, inside the 984 high frame.
  static const double _multipleHeight = 60;

  /// The selected channel, or `null` for the defaults.
  int? _scope;

  /// The last Bars choice for each scope, including the defaults (`null`).
  /// Visiting a different track must not rewrite another scope's Auto memory.
  final Map<int?, int> _lastBars = {null: 4};

  /// A requested count stays editable until the confirmed value catches up.
  int? _candidateBars;
  int? _lengthAttemptId;
  int? _confirmedBarsAtAttempt;
  bool _candidateRefused = false;
  int? _sessionRevision;

  void _discardCandidate() {
    _candidateBars = null;
    _lengthAttemptId = null;
    _confirmedBarsAtAttempt = null;
    _candidateRefused = false;
  }

  void _setBars(int? bars) {
    final scope = _scope;
    final record = context.read<RecordOptionsCubit>();
    if (!record.state.options.recordLengthReady ||
        record.state.options.recordLengthCaptureLocked ||
        (scope != null &&
            record.state.options.recordLengthMode == LooperMode.multi)) {
      return;
    }
    if (bars == null || bars == 0) {
      setState(_discardCandidate);
    } else {
      setState(() {
        _candidateBars = bars;
        _confirmedBarsAtAttempt = _confirmedBars();
        _candidateRefused = false;
      });
    }
    final command = scope == null
        ? record.setDefaultLengthBars(bars ?? 0)
        : record.setTrackRecordLength(channel: scope, bars: bars);
    _lengthAttemptId = record.state.lengthAttempt?.id;
    unawaited(command);
  }

  int _confirmedBars() {
    final record = context.read<RecordOptionsCubit>().state.options;
    if (_scope == null || record.recordLengthMode == LooperMode.multi) {
      return record.defaultLengthBars;
    }
    return record.trackLengthPresetOverrides[_scope] ??
        record.defaultLengthBars;
  }

  void _setTiming(RecordTiming? timing) {
    final scope = _scope;
    final owner = context.read<RecordTimingCubit>();
    if (!owner.state.recordTimingReady || owner.state.captureLocked) return;
    if (scope == null) {
      unawaited(owner.setTiming(timing!));
    } else {
      unawaited(owner.setTrackTiming(channel: scope, timing: timing));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final v = context.select<LooperBloc, _LengthValues>(
      (bloc) => _lengthValues(bloc.state),
    );
    // Length defaults and exact Custom membership share the confirmed owner.
    final record = context.watch<RecordOptionsCubit>().state.options;
    final defaultBars = record.defaultLengthBars;
    final sessionRevision = context.select<LoopSettingsFeedbackCubit, int>(
      (cubit) => cubit.state.sessionRevision,
    );
    final timingState = context.watch<RecordTimingCubit>().state;
    final scope = _scope;
    final shared = scope != null && record.recordLengthMode == LooperMode.multi;
    final barsCustom =
        scope != null &&
        !shared &&
        record.trackLengthPresetOverrides[scope] != null;
    final bars = shared || scope == null
        ? defaultBars
        : record.trackLengthPresetOverrides[scope] ?? defaultBars;
    final timingCustom =
        scope != null && timingState.trackOverrides.containsKey(scope);
    final timing = timingState.recordTimingReady
        ? timingState.trackOverrides[scope] ?? timingState.defaultTiming
        : null;
    if (_sessionRevision != null && _sessionRevision != sessionRevision) {
      _discardCandidate();
    }
    _sessionRevision = sessionRevision;
    if (v.capturing ||
        shared ||
        (_candidateBars != null &&
            (bars == _candidateBars || bars != _confirmedBarsAtAttempt))) {
      _discardCandidate();
    }
    if (bars > 0 && !shared) _lastBars[scope] = bars;
    final shownBars = _candidateBars ?? bars;
    final locked =
        v.capturing ||
        record.recordLengthCaptureLocked ||
        timingState.captureLocked;
    final lengthEnabled = record.recordLengthReady && !locked && !shared;
    final timingEnabled = timingState.recordTimingReady && !locked;
    final top = locked ? 441.0 : 349.0;
    return MultiBlocListener(
      listeners: [
        BlocListener<RecordOptionsCubit, RecordOptionsViewState>(
          listenWhen: (before, after) =>
              before.lengthAttempt != after.lengthAttempt,
          listener: (context, state) {
            final attempt = state.lengthAttempt;
            if (attempt == null ||
                attempt.id != _lengthAttemptId ||
                attempt.phase == LengthEditPhase.pending ||
                attempt.channel != _scope ||
                attempt.bars != _candidateBars) {
              return;
            }
            setState(() {
              _candidateRefused = attempt.phase == LengthEditPhase.refused;
            });
          },
        ),
        BlocListener<LoopSettingsFeedbackCubit, LoopSettingsFeedback>(
          listenWhen: (before, after) => before.refused != after.refused,
          listener: (context, _) {
            if (_candidateBars != null) {
              setState(() => _candidateRefused = true);
            }
          },
        ),
      ],
      child: Positioned.fill(
        child: Stack(
          children: [
            Positioned(
              left: 100,
              top: 124,
              child: LoopScopeSelector(
                trackNames: trackDisplayNames(context, v.count),
                selected: scope,
                onSelected: (channel) => setState(() {
                  _discardCandidate();
                  _scope = channel;
                }),
              ),
            ),
            if (locked)
              Positioned(
                left: 100,
                top: 213,
                child: LoopLockBanner(text: l10n.loopLengthLocked, width: 1720),
              ),
            // ---- loop length
            Positioned(
              left: 100,
              top: top + (scope == null ? 40 : 24),
              child: LoopFieldLabel(
                title: l10n.loopLengthLabel,
                origin: scopedOrigin(
                  scoped: scope != null,
                  custom: barsCustom,
                  shared: shared,
                ),
              ),
            ),
            Positioned(
              left: 100 + 328,
              top: top + 8,
              child: LoopChoiceRow<bool>(
                values: const [false, true],
                labelOf: (fixed) =>
                    fixed ? l10n.loopLengthBars : l10n.loopLengthAuto,
                keyOf: (fixed) =>
                    Key(fixed ? 'loop_length_bars' : 'loop_length_auto'),
                selected: bars > 0,
                enabled: lengthEnabled,
                onSelected: (fixed) => _setBars(
                  fixed ? (_lastBars[scope] ?? 4) : 0,
                ),
                width: 392,
              ),
            ),
            if (shownBars > 0)
              Positioned(
                left: 100 + 328 + 424,
                top: top,
                child: LoopStepper(
                  key: ValueKey((sessionRevision, scope, locked, shared)),
                  value: shownBars,
                  unit: l10n.loopLengthUnit,
                  enabled: lengthEnabled,
                  decrementLabel: l10n.loopLengthShorter,
                  incrementLabel: l10n.loopLengthLonger,
                  onDecrement: shownBars > 1
                      ? () => _setBars(shownBars - 1)
                      : null,
                  onIncrement: shownBars < kMaxLengthPresetBars
                      ? () => _setBars(shownBars + 1)
                      : null,
                  onCommit: _setBars,
                ),
              ),
            if (barsCustom && !locked)
              Positioned(
                left: 100 + 328 + 1221,
                top: top + 24,
                child: LoopUseDefaultButton(
                  key: const Key('loop_length_use_default'),
                  onTap: () => _setBars(null),
                ),
              ),
            Positioned(
              left: 100 + 328,
              top: top + 132,
              child: LoopNote(
                _candidateRefused
                    ? l10n.loopLengthNotApplied(lengthPresetLabel(l10n, bars))
                    : lengthPresetNote(l10n, shownBars),
                key: const Key('loop_length_note'),
              ),
            ),
            // ---- record timing
            Positioned(
              left: 100,
              top: top + 231 + 16,
              child: LoopFieldLabel(
                title: l10n.loopTimingLabel,
                originBeside: true,
                origin: scopedOrigin(
                  scoped: scope != null,
                  custom: timingCustom,
                ),
              ),
            ),
            if (timingCustom && timingEnabled)
              Positioned(
                left: 100 + 1549,
                top: top + 231,
                child: LoopUseDefaultButton(
                  key: const Key('loop_timing_use_default'),
                  onTap: () => _setTiming(null),
                ),
              ),
            Positioned(
              left: 100,
              top: top + 231 + 88,
              child: LoopChoiceRow<RecordTiming>(
                values: RecordTiming.values,
                labelOf: (t) => recordTimingLabels(l10n)[t]!,
                keyOf: (t) => Key('loop_timing_${t.name}'),
                selected: timing,
                enabled: timingEnabled,
                onSelected: _setTiming,
                width: 1720,
                gap: 16,
              ),
            ),
            Positioned(
              left: 100,
              top: top + 231 + 208,
              child: LoopNote(
                timing == null
                    ? l10n.recordTimingUnavailable
                    : recordTimingNote(l10n, timing),
                key: const Key('loop_timing_note'),
              ),
            ),
            // ---- later tracks (defaults only)
            if (scope == null) ...[
              Positioned(
                left: 100,
                top: top + _multipleTop(locked: locked) + 13,
                child: LoopFieldLabel(title: l10n.loopDefaultMultipleLabel),
              ),
              Positioned(
                left: 100 + 328,
                top: top + _multipleTop(locked: locked),
                child: LoopChoiceRow<int>(
                  key: const Key('loop_default_multiple'),
                  values: kDefaultMultiples,
                  labelOf: (multiple) => multiple == 0
                      ? l10n.auto
                      : l10n.loopMultipleLabel(multiple),
                  keyOf: (multiple) => Key('loop_default_multiple_$multiple'),
                  selected: record.defaultMultiple,
                  enabled: !locked,
                  onSelected: (multiple) => unawaited(
                    context.read<RecordOptionsCubit>().setDefaultMultiple(
                      multiple,
                    ),
                  ),
                  width: _multipleWidth,
                  height: _multipleHeight,
                ),
              ),
              Positioned(
                left: 100 + 328 + _multipleWidth + 32,
                top: top + _multipleTop(locked: locked),
                right: 100,
                height: _multipleHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LoopNote(
                    l10n.loopDefaultMultipleNote,
                    key: const Key('loop_default_multiple_note'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
