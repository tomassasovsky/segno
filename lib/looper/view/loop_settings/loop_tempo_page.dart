import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// What the Tempo & click page reads off the transport.
typedef _TempoValues = ({
  double bpm,
  int tsNum,
  int tsDen,
  int beat,
  bool running,
});

_TempoValues _tempoValues(LooperState state) => (
  bpm: state.transport.tempoBpm,
  tsNum: state.transport.tsNum,
  tsDen: state.transport.tsDen,
  beat: state.transport.currentBeat,
  running: state.transport.isRunning && state.hasContent,
);

/// The Tempo & click page: the tempo readout with its beat lights, the
/// tempo slider with whole and fine steps and Tap tempo, the time signature
/// (a button to its own page), and the Hear click and Count-in rows (the
/// pen's `timing-layout`, 1720 x 458 at (100, 313)).
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

  static const double _minBpm = 30;
  static const double _maxBpm = 300;

  void _setTempo(double fraction) {
    var bpm = _minBpm + fraction * (_maxBpm - _minBpm);
    bpm = _fine ? (bpm * 100).round() / 100 : bpm.roundToDouble();
    unawaited(context.read<TempoCubit>().setTempo(bpm));
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
    // The live tempo when the engine has one (a tap or a derived tempo
    // moves it without this page), else the cubit's own intent.
    final bpm = transport.bpm > 0 ? transport.bpm : settings.bpm;
    final fraction = bpm <= 0
        ? 0.0
        : ((bpm - _minBpm) / (_maxBpm - _minBpm)).clamp(0.0, 1.0);
    return Positioned(
      left: 100,
      top: 313,
      child: SizedBox(
        width: 1720,
        height: 458,
        child: Stack(
          children: [
            // ---- tempo readout
            Positioned(
              left: 0,
              top: 0,
              child: AppText(
                bpm > 0 ? bpm.toStringAsFixed(2) : l10n.loopTempoUnset,
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
              top: 94,
              child: AppText(
                l10n.loopTempoBpmUnit,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  height: 1,
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 142,
              child: _BeatStrip(
                beats: transport.tsNum,
                lit: transport.running ? transport.beat : -1,
              ),
            ),
            // ---- tempo slider and tools
            Positioned(
              left: 328,
              top: 1,
              child: LoopSlider(
                key: const Key('loop_tempo_slider'),
                value: fraction,
                onChanged: _setTempo,
                width: 1064,
                semanticLabel: l10n.loopTempoSliderLabel,
              ),
            ),
            Positioned(
              left: 328,
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
            Positioned(
              left: 328 + 851,
              top: 81,
              child: LoopOutlinedButton(
                key: const Key('loop_tempo_tap'),
                width: 213,
                height: 80,
                fontSize: 28,
                label: l10n.loopTempoTap,
                onTap: tempo.tapTempo,
              ),
            ),
            // ---- time signature
            Positioned(
              left: 1440 + 48,
              top: 21,
              child: LoopSectionLabel(l10n.loopTempoSignature),
            ),
            Positioned(
              left: 1440 + 80,
              top: 77,
              child: Semantics(
                button: true,
                label: l10n.loopTempoSignature,
                value: timeSignatureLabel(transport.tsNum, transport.tsDen),
                child: Material(
                  color: surface.card,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: surface.borderSubtle),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const Key('loop_tempo_signature'),
                    onTap: widget.onOpenSignature,
                    child: SizedBox(
                      width: 120,
                      height: 64,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AppText(
                            timeSignatureLabel(
                              transport.tsNum,
                              transport.tsDen,
                            ),
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontSize: 24,
                              height: 1,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            LucideIcons.chevronRight,
                            size: 28,
                            color: surface.textPrimary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // ---- hear click
            Positioned(
              left: 0,
              top: 226 + 32,
              child: LoopSectionLabel(l10n.loopTempoHearClick),
            ),
            Positioned(
              left: 328,
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
                selected: settings.clickMode,
                onSelected: (mode) => unawaited(tempo.setClickMode(mode)),
                width: 1392,
              ),
            ),
            // ---- count-in
            Positioned(
              left: 0,
              top: 362 + 32,
              child: LoopSectionLabel(l10n.loopTempoCountIn),
            ),
            Positioned(
              left: 328,
              top: 362,
              child: LoopChoiceRow<int>(
                values: kCountInBarOptions,
                labelOf: (bars) => countInLabels(l10n)[bars]!,
                keyOf: (bars) => Key('loop_count_in_$bars'),
                selected: settings.countInBars,
                onSelected: (bars) => unawaited(tempo.setCountInBars(bars)),
                width: 1392,
              ),
            ),
          ],
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

/// The Time signature page: the 17 signatures as a five-wide grid (the
/// pen's `signature-grid`, 1848 x 424 at (36, 124)).
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
    return Positioned(
      left: 36,
      top: 124,
      child: SizedBox(
        width: 1848,
        height: 424,
        child: Stack(
          children: [
            for (final (i, signature) in kValidTimeSignatures.indexed)
              Positioned(
                left: (i % 5) * 374.25,
                top: (i ~/ 5) * 112.0,
                child: LoopChoiceButton(
                  key: Key('loop_signature_${signature.$1}_${signature.$2}'),
                  label: timeSignatureLabel(signature.$1, signature.$2),
                  selected: current == signature,
                  width: 351,
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
