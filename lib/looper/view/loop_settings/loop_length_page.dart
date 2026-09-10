import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';

/// The most bars a fixed length preset can hold (the engine's 1..64).
const int kMaxLengthPresetBars = 64;

/// What the Length & quantize page reads off the looper for one scope.
typedef _LengthValues = ({
  int count,
  LooperMode mode,
  bool capturing,
  int? trackBarsOverride,
  RecordTiming? trackTimingOverride,
});

_LengthValues _lengthValues(LooperState state, int? channel) {
  final track = channel == null || channel >= state.tracks.length
      ? null
      : state.tracks[channel];
  return (
    count: state.tracks.length,
    mode: state.transport.looperMode,
    capturing: state.tracks.any((t) => t.isCapturing),
    trackBarsOverride: track?.lengthPresetOverride,
    trackTimingOverride: track?.recordTimingOverride,
  );
}

/// The Length & quantize page: the Tracks / Defaults / 1-8 selector, then
/// Loop length (Auto or a bar count) and Record timing for that scope, each
/// with its origin tag and a Use default when a track overrides it (the pen's
/// `length-timing`, 1720 x 474 at (100, 349)). In Multi a track's length is
/// the shared default; a capture in progress locks the page behind a banner.
class LoopLengthPage extends StatefulWidget {
  /// Creates a [LoopLengthPage].
  const LoopLengthPage({super.key});

  @override
  State<LoopLengthPage> createState() => _LoopLengthPageState();
}

class _LoopLengthPageState extends State<LoopLengthPage> {
  /// The selected channel, or `null` for the defaults.
  int? _scope;

  /// The bar count the stepper returns to when Bars is chosen after Auto.
  int _lastBars = 4;

  void _setBars(int? bars) {
    if (bars != null && bars > 0) _lastBars = bars;
    final scope = _scope;
    if (scope == null) {
      unawaited(
        context.read<RecordOptionsCubit>().setDefaultLengthBars(bars ?? 0),
      );
    } else {
      context.read<LooperBloc>().add(
        LooperTrackLengthPresetChanged(scope, bars),
      );
    }
  }

  void _setTiming(RecordTiming? timing) {
    final scope = _scope;
    if (scope == null) {
      unawaited(context.read<RecordTimingCubit>().setTiming(timing!));
    } else {
      context.read<LooperBloc>().add(
        LooperTrackRecordTimingChanged(scope, timing: timing),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final v = context.select<LooperBloc, _LengthValues>(
      (bloc) => _lengthValues(bloc.state, _scope),
    );
    // The defaults are the cubits' own intent (what they persist and push);
    // the overrides are the repository's projection.
    final defaultBars = context.select<RecordOptionsCubit, int>(
      (cubit) => cubit.state.defaultLengthBars,
    );
    final defaultTiming = context.watch<RecordTimingCubit>().state;
    final scope = _scope;
    final shared = scope != null && v.mode == LooperMode.multi;
    final barsCustom = scope != null && !shared && v.trackBarsOverride != null;
    final bars = shared || scope == null
        ? defaultBars
        : v.trackBarsOverride ?? defaultBars;
    final timingCustom = scope != null && v.trackTimingOverride != null;
    final timing = scope == null
        ? defaultTiming
        : v.trackTimingOverride ?? defaultTiming;
    if (bars > 0) _lastBars = bars;
    final locked = v.capturing;
    final lengthEnabled = !locked && !shared;
    final top = locked ? 441.0 : 349.0;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 100,
            top: 124,
            child: LoopScopeSelector(
              trackNames: trackDisplayNames(context, v.count),
              selected: scope,
              onSelected: (channel) => setState(() => _scope = channel),
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
              onSelected: (fixed) => _setBars(fixed ? _lastBars : 0),
              width: 392,
            ),
          ),
          if (bars > 0)
            Positioned(
              left: 100 + 328 + 424,
              top: top,
              child: LoopStepper(
                value: bars,
                unit: l10n.loopLengthUnit,
                enabled: lengthEnabled,
                decrementLabel: l10n.loopLengthShorter,
                incrementLabel: l10n.loopLengthLonger,
                onDecrement: bars > 1 ? () => _setBars(bars - 1) : null,
                onIncrement: bars < kMaxLengthPresetBars
                    ? () => _setBars(bars + 1)
                    : null,
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
              lengthPresetNote(l10n, bars),
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
              origin: scopedOrigin(scoped: scope != null, custom: timingCustom),
            ),
          ),
          if (timingCustom && !locked)
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
              enabled: !locked,
              onSelected: _setTiming,
              width: 1720,
              gap: 16,
            ),
          ),
          Positioned(
            left: 100,
            top: top + 231 + 208,
            child: LoopNote(
              recordTimingNote(l10n, timing),
              key: const Key('loop_timing_note'),
            ),
          ),
        ],
      ),
    );
  }
}
