import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/loop_settings_feedback_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/record_options_view_state.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';

/// The most bars a fixed length preset can hold (the engine's 1..64).
const int kMaxLengthPresetBars = 64;

/// The later-track lengths the Defaults scope offers: `0` is Auto (round up
/// to whole base loops), the rest fixed multiples of the base loop. Three,
/// because a longer multiple is a length set on the track itself.
const List<int> kDefaultMultiples = [0, 1, 2, 3];

/// What the Recording tab reads off the looper.
typedef _RecordingValues = ({int count, bool capturing});

_RecordingValues _recordingValues(LooperState state) => (
  count: state.tracks.length,
  capturing: state.tracks.any((t) => t.isCapturing),
);

/// The Recording tab (#1659): everything about when a take starts and ends.
///
/// Every take's two settings sit side by side above the track selector:
/// Start recording (Pedal or Sound) with the one-line note naming the
/// count-in in effect, and Second pedal press (Play or Overdub). Under the
/// selector, for the selected scope: Loop length (Auto or a bar count), Later
/// tracks directly under it in the Defaults scope, and Record timing, each
/// scoped field with its origin tag and a Use default when a track overrides
/// it. In Multi a track's length is the shared default.
///
/// One lock rule: a capture in progress locks the whole tab behind one
/// banner, which moves the layout down under it.
class LoopRecordingPage extends StatefulWidget {
  /// Creates a [LoopRecordingPage] showing [track]'s fields.
  const LoopRecordingPage({
    required this.track,
    required this.onTrack,
    super.key,
  });

  /// The selected channel, or `null` for the defaults; shared with the
  /// Playback tab for the visit.
  final int? track;

  /// Selects a channel, or `null` for the defaults.
  final ValueChanged<int?> onTrack;

  /// How far a capture's banner moves the layout down: its 68 and the gap
  /// a heading keeps over its row.
  static const double lockShift = 68 + 12;

  /// Where the layout starts under the title row, and the banner with it.
  static const double top = kLoopTabContentTop;

  /// The choices' height, Playback's (#1672: one choice size on Recording
  /// and Playback).
  static const double choiceHeight = 120;

  /// The choices' label size, Playback's.
  static const double choiceFontSize = 28;

  /// Every take's choice rows, 12 under their 28 high headings.
  static const double globalRowTop = top + 28 + 12;

  /// The start note, under the start row.
  static const double noteTop = globalRowTop + choiceHeight + 16;

  /// The track selector.
  static const double selectorTop = noteTop + 29 + 16;

  /// The length row: Auto and Bars, with the stepper centred on it.
  static const double lengthTop = selectorTop + 64 + 16;

  /// The length note, under the length row.
  static const double lengthNoteTop = lengthTop + choiceHeight + 16;

  /// The later-tracks row, under the length note.
  static const double multipleTop = lengthNoteTop + 29 + 16;

  /// The later-tracks choices' height: compact, so the locked layout still
  /// ends inside the frame.
  static const double multipleHeight = 60;

  /// The record timing heading, 16 under the later-tracks row.
  static const double timingTop = multipleTop + multipleHeight + 16;

  /// The record timing choices, 16 under the heading. Use default ends on
  /// the same line as the heading (#1672); on a track scope it rises into
  /// the band the later-tracks row leaves empty.
  static const double timingRowTop = timingTop + 28 + 16;

  @override
  State<LoopRecordingPage> createState() => _LoopRecordingPageState();
}

class _LoopRecordingPageState extends State<LoopRecordingPage> {
  /// Where the scoped fields' choices start, after their labels.
  static const double _controlsLeft = 328;

  /// The later-tracks choices' width: four tokens, leaving the rest of the
  /// row to the note that says what they are multiples of.
  static const double _multipleWidth = 592;

  /// The last Bars choice for each scope, including the defaults (`null`).
  /// Visiting a different track must not rewrite another scope's Auto memory.
  final Map<int?, int> _lastBars = {null: 4};

  /// A requested count stays editable until the confirmed value catches up.
  int? _candidateBars;
  int? _lengthAttemptId;
  int? _confirmedBarsAtAttempt;
  bool _candidateRefused = false;
  bool _candidateCapacityFailure = false;
  int? _sessionRevision;

  void _discardCandidate() {
    _candidateBars = null;
    _lengthAttemptId = null;
    _confirmedBarsAtAttempt = null;
    _candidateRefused = false;
    _candidateCapacityFailure = false;
  }

  void _selectTrack(int? channel) {
    setState(_discardCandidate);
    widget.onTrack(channel);
  }

  void _setBars(int? bars) {
    final scope = widget.track;
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
        _candidateCapacityFailure = false;
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
    final scope = widget.track;
    if (scope == null || record.recordLengthMode == LooperMode.multi) {
      return record.defaultLengthBars;
    }
    return record.trackLengthPresetOverrides[scope] ?? record.defaultLengthBars;
  }

  void _setTiming(RecordTiming? timing) {
    final scope = widget.track;
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
    final v = context.select<LooperBloc, _RecordingValues>(
      (bloc) => _recordingValues(bloc.state),
    );
    // Length defaults and exact Custom membership share the confirmed owner.
    final record = context.watch<RecordOptionsCubit>().state.options;
    final defaultBars = record.defaultLengthBars;
    final sessionRevision = context.select<LoopSettingsFeedbackCubit, int>(
      (cubit) => cubit.state.sessionRevision,
    );
    final timingState = context.watch<RecordTimingCubit>().state;
    final tempo = context.watch<TempoCubit>().state;
    final confirmedStart = tempo.confirmedRecordStart;
    final recordStart = tempo.recordStartSnapshot;
    final scope = widget.track;
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
    // One lock for the tab: whichever owner reports the capture first.
    final locked =
        v.capturing ||
        record.recordLengthCaptureLocked ||
        timingState.captureLocked;
    final lengthEnabled = record.recordLengthReady && !locked && !shared;
    final timingEnabled = timingState.recordTimingReady && !locked;
    final startNote = recordStart == null || confirmedStart == null
        ? l10n.recordStartUnavailable
        : confirmedStart.soundStart
        ? l10n.loopRecordingNoteSound
        : confirmedStart.countInBars > 0
        ? l10n.loopRecordingNoteCountIn(confirmedStart.countInBars)
        : l10n.loopRecordingNotePedal;
    final width = LoopSettingsFrame.contentWidthOf(context);
    final half = LoopSettingsFrame.halfWidthOf(context);
    final secondLeft = width - half;
    final shift = locked ? LoopRecordingPage.lockShift : 0.0;
    const top = LoopRecordingPage.top;
    final lengthTop = LoopRecordingPage.lengthTop + shift;
    final multipleTop = LoopRecordingPage.multipleTop + shift;
    final timingTop = LoopRecordingPage.timingTop + shift;
    final timingRowTop = LoopRecordingPage.timingRowTop + shift;
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
                attempt.channel != widget.track ||
                attempt.bars != _candidateBars) {
              return;
            }
            setState(() {
              _candidateRefused = attempt.phase == LengthEditPhase.refused;
              _candidateCapacityFailure =
                  _candidateRefused && attempt.capacityFailure;
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
            if (locked)
              Positioned(
                left: 0,
                top: top,
                child: LoopLockBanner(
                  text: l10n.loopRecordingLocked,
                  width: width,
                ),
              ),
            // ---- every take: start and second press, side by side
            Positioned(
              left: 0,
              top: top + shift,
              child: LoopSectionLabel(l10n.loopRecordingStart),
            ),
            Positioned(
              left: 0,
              top: LoopRecordingPage.globalRowTop + shift,
              child: LoopChoiceRow<bool>(
                values: const [false, true],
                labelOf: (sound) => sound
                    ? l10n.loopRecordingStartSound
                    : l10n.loopRecordingStartPedal,
                keyOf: (sound) => Key(
                  sound ? 'loop_recording_sound' : 'loop_recording_pedal',
                ),
                selected: confirmedStart?.soundStart,
                enabled: (recordStart?.canEdit ?? false) && !locked,
                onSelected: (sound) => unawaited(
                  context.read<TempoCubit>().setSoundStart(enabled: sound),
                ),
                width: half,
                height: LoopRecordingPage.choiceHeight,
                fontSize: LoopRecordingPage.choiceFontSize,
              ),
            ),
            Positioned(
              left: 0,
              top: LoopRecordingPage.noteTop + shift,
              width: half,
              child: LoopNote(
                startNote,
                key: const Key('loop_recording_note'),
              ),
            ),
            Positioned(
              left: secondLeft,
              top: top + shift,
              child: LoopSectionLabel(l10n.loopRecordingSecondPress),
            ),
            Positioned(
              left: secondLeft,
              top: LoopRecordingPage.globalRowTop + shift,
              child: LoopChoiceRow<bool>(
                values: const [false, true],
                labelOf: (overdub) => overdub
                    ? l10n.loopRecordingSecondOverdub
                    : l10n.loopRecordingSecondPlay,
                keyOf: (overdub) => Key(
                  overdub ? 'loop_recording_overdub' : 'loop_recording_play',
                ),
                selected: record.recDub,
                enabled: !locked,
                onSelected: (overdub) => unawaited(
                  context.read<RecordOptionsCubit>().setRecDub(value: overdub),
                ),
                width: half,
                height: LoopRecordingPage.choiceHeight,
                fontSize: LoopRecordingPage.choiceFontSize,
              ),
            ),
            // ---- the track selector, over the fields it scopes
            Positioned(
              left: 0,
              top: LoopRecordingPage.selectorTop + shift,
              child: LoopScopeSelector(
                trackNames: trackDisplayNames(context, v.count),
                selected: scope,
                onSelected: _selectTrack,
              ),
            ),
            // ---- loop length
            // The label centred on the row.
            Positioned(
              left: 0,
              top: lengthTop,
              height: LoopRecordingPage.choiceHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: LoopFieldLabel(
                  title: l10n.loopLengthLabel,
                  origin: scopedOrigin(
                    scoped: scope != null,
                    custom: barsCustom,
                    shared: shared,
                  ),
                ),
              ),
            ),
            Positioned(
              left: _controlsLeft,
              top: lengthTop,
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
                height: LoopRecordingPage.choiceHeight,
                fontSize: LoopRecordingPage.choiceFontSize,
              ),
            ),
            if (shownBars > 0)
              Positioned(
                left: _controlsLeft + 424,
                // The 112 high stepper centred on the row.
                top: lengthTop + 4,
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
                right: 0,
                top: lengthTop + (LoopRecordingPage.choiceHeight - 64) / 2,
                child: LoopUseDefaultButton(
                  key: const Key('loop_length_use_default'),
                  onTap: () => _setBars(null),
                ),
              ),
            Positioned(
              left: _controlsLeft,
              top: LoopRecordingPage.lengthNoteTop + shift,
              child: LoopNote(
                _candidateRefused
                    ? _candidateCapacityFailure
                          ? l10n.loopLengthCapacityNotApplied(
                              lengthPresetLabel(l10n, bars),
                            )
                          : l10n.loopLengthNotApplied(
                              lengthPresetLabel(l10n, bars),
                            )
                    : lengthPresetNote(l10n, shownBars),
                key: const Key('loop_length_note'),
              ),
            ),
            // ---- later tracks (defaults only), the length of every take
            // after the first: directly under Loop length.
            if (scope == null) ...[
              Positioned(
                left: 0,
                top: multipleTop,
                height: LoopRecordingPage.multipleHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LoopFieldLabel(title: l10n.loopDefaultMultipleLabel),
                ),
              ),
              Positioned(
                left: _controlsLeft,
                top: multipleTop,
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
                  height: LoopRecordingPage.multipleHeight,
                ),
              ),
              Positioned(
                left: _controlsLeft + _multipleWidth + 32,
                top: multipleTop,
                right: 0,
                height: LoopRecordingPage.multipleHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LoopNote(
                    l10n.loopDefaultMultipleNote,
                    key: const Key('loop_default_multiple_note'),
                  ),
                ),
              ),
            ],
            // ---- record timing: the heading and Use default end on one
            // line, 16 above the choices.
            Positioned(
              left: 0,
              top: timingTop,
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
                right: 0,
                top: timingRowTop - 16 - 64,
                child: LoopUseDefaultButton(
                  key: const Key('loop_timing_use_default'),
                  onTap: () => _setTiming(null),
                ),
              ),
            Positioned(
              left: 0,
              top: timingRowTop,
              child: LoopChoiceRow<RecordTiming>(
                values: RecordTiming.values,
                labelOf: (t) => recordTimingLabels(l10n)[t]!,
                keyOf: (t) => Key('loop_timing_${t.name}'),
                selected: timing,
                enabled: timingEnabled,
                onSelected: _setTiming,
                width: width,
                height: LoopRecordingPage.choiceHeight,
                fontSize: LoopRecordingPage.choiceFontSize,
                gap: 16,
              ),
            ),
            Positioned(
              left: 0,
              top: timingRowTop + LoopRecordingPage.choiceHeight + 16,
              child: LoopNote(
                timing == null
                    ? l10n.recordTimingUnavailable
                    : recordTimingNote(l10n, timing),
                key: const Key('loop_timing_note'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
