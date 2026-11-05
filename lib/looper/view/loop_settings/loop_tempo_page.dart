import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/tempo_entry_sheet.dart';
import 'package:segno/looper/view/tempo_labels.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

/// What the Tempo & click page reads off the transport.
typedef _TempoValues = ({
  double bpm,
  int tsNum,
  int tsDen,
  int beat,
  bool playing,
});

_TempoValues _tempoValues(LooperState state) => (
  bpm: state.transport.tempoBpm,
  tsNum: state.transport.tsNum,
  tsDen: state.transport.tsDen,
  beat: state.transport.currentBeat,
  playing: state.isPlaying,
);

/// The Tempo & click page: the tempo readout with its beat lights (a tap
/// types an exact tempo on the keypad), the tempo slider with whole and fine
/// steps, Clear tempo and Tap tempo, the time signature (a button to its own
/// page), and the Hear click and Count-in rows (the pen's `timing-layout`,
/// 458 high at y 313, across the content width).
class LoopTempoPage extends StatefulWidget {
  /// Creates a [LoopTempoPage].
  const LoopTempoPage({required this.onOpenSignature, super.key});

  /// Opens the Time signature page.
  final VoidCallback onOpenSignature;

  @override
  State<LoopTempoPage> createState() => _LoopTempoPageState();
}

class _LoopTempoPageState extends State<LoopTempoPage> {
  /// Whether the slider moves in hundredths rather than whole beats.
  bool _fine = false;
  double? _draftBpm;
  double? _openingBpm;

  /// Where the controls column starts, after the readout.
  static const double _controlsLeft = 328;

  /// The room right of the slider, where the time signature sits.
  static const double _sliderEndInset = 328;

  /// Where the time signature's column starts, from the right edge.
  static const double _signatureInset = 280;

  /// The Tap and Clear tempo buttons' width.
  static const double _tapWidth = 213;

  /// The readout's height: the figure and its unit under it.
  static const double _readoutHeight = 118;

  static final double _minBpm = kTempoRange.$1;
  static final double _maxBpm = kTempoRange.$2;

  double _bpmOf(double fraction) {
    final bpm = _minBpm + fraction * (_maxBpm - _minBpm);
    return _fine ? (bpm * 100).round() / 100 : bpm.roundToDouble();
  }

  /// A draft changes the readout; release or Enter applies and persists it.
  void _previewTempo(double fraction) =>
      setState(() => _draftBpm = _bpmOf(fraction));

  void _commitTempo(double fraction) {
    setState(() => _draftBpm = null);
    unawaited(context.read<TempoCubit>().setTempo(_bpmOf(fraction)));
  }

  /// The keypad's exact tempo, applied as typed.
  Future<void> _enterTempo(double current) async {
    final tempo = context.read<TempoCubit>();
    final bpm = await showTempoEntrySheet(context, current: current);
    if (bpm == null || !mounted) return;
    setState(() => _draftBpm = null);
    await tempo.setTempo(bpm);
  }

  /// Back to no tempo, or the notice saying why the lock keeps it.
  Future<void> _clearTempo() async {
    final notices = context.read<NoticesCubit>();
    setState(() => _draftBpm = null);
    final result = await context.read<TempoCubit>().clearTempo();
    if (result.isOk) return;
    notices.show(
      Notice(
        id: AppNoticeId.tempoClearRefused,
        tone: NoticeTone.warning,
        title: (l10n) => l10n.loopTempoClearRefused,
        body: switch (result) {
          EngineResult.notReady => (l10n) => l10n.loopTempoClearRefusedBody,
          EngineResult.notRunning => (l10n) => l10n.loopTempoClearStopped,
          _ => null,
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final transport = context.select<LooperBloc, _TempoValues>(
      (bloc) => _tempoValues(bloc.state),
    );
    final settings = context.watch<TempoCubit>().state;
    final tempo = context.read<TempoCubit>();
    final clickModeSnapshot = context
        .watch<TempoCubit>()
        .state
        .clickModeSnapshot;
    final recordStartSnapshot = tempo.state.recordStartSnapshot;
    final confirmedRecordStart = tempo.state.confirmedRecordStart;
    // The live tempo when the engine has one (a tap or a derived tempo
    // moves it without this page), else the cubit's own intent.
    final liveBpm = transport.bpm > 0 ? transport.bpm : settings.bpm;
    _openingBpm ??= liveBpm > 0 ? liveBpm : 120;
    final bpm = _draftBpm ?? liveBpm;
    final fraction = bpm <= 0
        ? 0.0
        : ((bpm - _minBpm) / (_maxBpm - _minBpm)).clamp(0.0, 1.0);
    // Across the content width under the title (#1590): the controls column
    // starts at 328, the slider and the click and count-in rows stretch to
    // the width, and the time signature keeps its place at the right end.
    final width = LoopSettingsFrame.contentWidthOf(context);
    final sliderWidth = width - _controlsLeft - _sliderEndInset;
    final tapLeft = _controlsLeft + sliderWidth - _tapWidth;
    return Positioned(
      left: 0,
      top: 313,
      child: SizedBox(
        width: width,
        height: 458,
        child: Stack(
          children: [
            // ---- tempo readout, a tap from the keypad
            Positioned(
              left: 0,
              top: 0,
              child: _TempoReadout(
                bpm: bpm,
                // Its column, short of the controls by the page's gap.
                size: Size(
                  _controlsLeft - context.spacing.xxl,
                  _readoutHeight,
                ),
                onTap: () => unawaited(_enterTempo(bpm)),
              ),
            ),
            Positioned(
              left: 0,
              top: 142,
              child: _BeatStrip(
                beats: transport.tsNum,
                lit: transport.playing ? transport.beat : -1,
              ),
            ),
            // ---- tempo slider and tools
            Positioned(
              left: _controlsLeft,
              top: 1,
              child: LoopSlider(
                key: const Key('loop_tempo_slider'),
                value: fraction,
                onChanged: _previewTempo,
                onChangeEnd: _commitTempo,
                onDoubleTap: () => unawaited(
                  tempo.setTempo(_openingBpm!),
                ),
                onEditCancel: (_) => setState(() => _draftBpm = null),
                keyboardStep: (_fine ? 0.01 : 1) / (_maxBpm - _minBpm),
                width: sliderWidth,
                semanticLabel: l10n.loopTempoSliderLabel,
              ),
            ),
            Positioned(
              left: _controlsLeft,
              top: 81,
              child: Row(
                children: [
                  LoopChoiceButton(
                    key: const Key('loop_tempo_step_whole'),
                    label: l10n.loopTempoStepWhole,
                    selected: !_fine,
                    onTap: () => setState(() => _fine = false),
                    width: 104,
                    height: 56,
                    fontSize: 20,
                  ),
                  const SizedBox(width: 8),
                  LoopChoiceButton(
                    key: const Key('loop_tempo_step_fine'),
                    label: l10n.loopTempoStepFine,
                    selected: _fine,
                    onTap: () => setState(() => _fine = true),
                    width: 131,
                    height: 56,
                    fontSize: 20,
                  ),
                ],
              ),
            ),
            // Clear tempo, then Tap, which ends where the slider ends.
            Positioned(
              left: tapLeft - context.spacing.lg - _tapWidth,
              top: 81,
              child: Opacity(
                opacity: bpm > 0 ? 1 : surface.disabledOpacity,
                child: LoopOutlinedButton(
                  key: const Key('loop_tempo_clear'),
                  width: _tapWidth,
                  height: 80,
                  fontSize: 28,
                  label: l10n.loopTempoClear,
                  onTap: bpm > 0 ? () => unawaited(_clearTempo()) : null,
                ),
              ),
            ),
            Positioned(
              left: tapLeft,
              top: 81,
              child: LoopOutlinedButton(
                key: const Key('loop_tempo_tap'),
                width: _tapWidth,
                height: 80,
                fontSize: 28,
                label: l10n.loopTempoTap,
                onTap: tempo.tapTempo,
              ),
            ),
            // ---- time signature
            Positioned(
              left: width - _signatureInset + 48,
              top: 21,
              child: LoopSectionLabel(l10n.loopTempoSignature),
            ),
            Positioned(
              left: width - _signatureInset + 80,
              top: 77,
              child: LoopOutlinedButton(
                key: const Key('loop_tempo_signature'),
                width: 120,
                radius: 8,
                tone: LoopButtonTone.card,
                label: timeSignatureLabel(transport.tsNum, transport.tsDen),
                trailingIcon: LucideIcons.chevronRight,
                semanticLabel: l10n.loopTempoSignature,
                semanticValue: timeSignatureLabel(
                  transport.tsNum,
                  transport.tsDen,
                ),
                onTap: widget.onOpenSignature,
              ),
            ),
            // ---- hear click
            Positioned(
              left: 0,
              top: 226 + 32,
              child: LoopSectionLabel(l10n.loopTempoHearClick),
            ),
            Positioned(
              left: _controlsLeft,
              top: 226,
              child: LoopChoiceRow<ClickMode>(
                values: const [
                  ClickMode.off,
                  ClickMode.recFirst,
                  ClickMode.rec,
                  ClickMode.playRec,
                ],
                labelOf: (mode) => switch (mode) {
                  ClickMode.off => l10n.loopClickOff,
                  ClickMode.recFirst => l10n.loopClickFirst,
                  ClickMode.rec => l10n.loopClickRecording,
                  ClickMode.playRec => l10n.loopClickAlways,
                },
                keyOf: (mode) => Key('loop_click_${mode.name}'),
                selected: tempo.state.confirmedClickMode,
                enabled: clickModeSnapshot?.canEdit ?? false,
                onSelected: (mode) => unawaited(tempo.setClickMode(mode)),
                width: width - _controlsLeft,
              ),
            ),
            if (clickModeSnapshot?.canEdit != true)
              Positioned(
                left: _controlsLeft,
                top: 326,
                child: AppText(
                  clickModeSnapshot == null
                      ? l10n.clickModeUnavailable
                      : l10n.clickModeCaptureLocked,
                  key: const Key('loop_click_disabled_reason'),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 18,
                    height: 1,
                  ),
                ),
              ),
            // ---- count-in
            Positioned(
              left: 0,
              top: 362 + 32,
              child: LoopSectionLabel(l10n.loopTempoCountIn),
            ),
            Positioned(
              left: _controlsLeft,
              top: 362,
              child: LoopChoiceRow<int>(
                values: kCountInBarOptions,
                labelOf: (bars) => countInLabels(l10n)[bars]!,
                keyOf: (bars) => Key('loop_count_in_$bars'),
                selected: confirmedRecordStart?.countInBars,
                enabled: recordStartSnapshot?.canEdit ?? false,
                onSelected: (bars) => unawaited(tempo.setCountInBars(bars)),
                width: width - _controlsLeft,
              ),
            ),
            if (recordStartSnapshot?.canEdit != true)
              Positioned(
                left: 0,
                top: 430,
                child: AppText(
                  recordStartSnapshot == null
                      ? l10n.recordStartUnavailable
                      : l10n.recordStartCaptureLocked,
                  key: const Key('loop_count_in_disabled_reason'),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 14,
                    height: 1,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The tempo in large figures over its unit, or `not set`: a button that
/// opens the keypad, with the console's pressed and encoder-focus states.
class _TempoReadout extends StatelessWidget {
  const _TempoReadout({
    required this.bpm,
    required this.size,
    required this.onTap,
  });

  final double bpm;
  final Size size;
  final VoidCallback onTap;

  /// Where the unit sits under the figure.
  static const double _unitTop = 94;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final value = bpm > 0 ? bpm.toStringAsFixed(2) : l10n.loopTempoUnset;
    return Semantics(
      button: true,
      label: l10n.loopTempoEdit,
      value: bpm > 0 ? '$value ${l10n.loopTempoBpmUnit}' : value,
      onTap: onTap,
      excludeSemantics: true,
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('loop_tempo_entry'),
            canRequestFocus: false,
            // The focus outline's corner (LoopFocusable's).
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox.fromSize(
              size: size,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    child: AppText(
                      value,
                      key: const Key('loop_tempo_readout'),
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: bpm > 0 ? 78 : 40,
                        fontFamily: SurfaceTheme.monoFont,
                        height: 1,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: _unitTop,
                    child: AppText(
                      l10n.loopTempoBpmUnit,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 24,
                        height: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The beat lights under the tempo: one 20 px cell per beat of the bar, the
/// downbeat ringed, the sounding beat lit while the transport runs.
class _BeatStrip extends StatelessWidget {
  const _BeatStrip({required this.beats, required this.lit});

  final int beats;
  final int lit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final count = beats.clamp(1, 15);
    final gap = count > 8 ? 4.0 : 12.0;
    return Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Container(
            key: Key('loop_beat_$i'),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: i == lit ? surface.accent : surface.control,
              shape: BoxShape.circle,
              border: Border.all(
                color: i == 0 ? surface.warning : surface.borderStrong,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The Time signature page: the 17 signatures as a five-wide grid across
/// the content width (the pen's `signature-grid`, 424 high at y 124).
class LoopTimeSignaturePage extends StatelessWidget {
  /// Creates a [LoopTimeSignaturePage].
  const LoopTimeSignaturePage({required this.onChosen, super.key});

  /// Called after a signature is taken.
  final VoidCallback onChosen;

  @override
  Widget build(BuildContext context) {
    final current = context.select<LooperBloc, (int, int)>(
      (bloc) => (bloc.state.transport.tsNum, bloc.state.transport.tsDen),
    );
    // Five across the content width, 23.25 apart as the pen spaces them.
    final width = LoopSettingsFrame.contentWidthOf(context);
    const gap = 23.25;
    final cell = (width - 4 * gap) / 5;
    return Positioned(
      left: 0,
      top: 124,
      child: SizedBox(
        width: width,
        height: 424,
        child: Stack(
          children: [
            for (final (i, signature) in kValidTimeSignatures.indexed)
              Positioned(
                left: (i % 5) * (cell + gap),
                top: (i ~/ 5) * 112.0,
                child: LoopChoiceButton(
                  key: Key('loop_signature_${signature.$1}_${signature.$2}'),
                  label: timeSignatureLabel(signature.$1, signature.$2),
                  selected: current == signature,
                  width: cell,
                  height: 88,
                  onTap: () {
                    unawaited(
                      context.read<TempoCubit>().setTimeSignature(
                        signature.$1,
                        signature.$2,
                      ),
                    );
                    onChosen();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
