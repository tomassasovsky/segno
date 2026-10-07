import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

/// The notice for a foot Tuner press that changed nothing.
String footTunerRefusalText(AppLocalizations l10n, FootTunerRefusal refusal) =>
    switch (refusal) {
      FootTunerRefusal.limit => l10n.footTunerAtLimit,
      FootTunerRefusal.saveFailed => l10n.footTunerSaveFailed,
      FootTunerRefusal.armFailed => l10n.footTunerStartFailed,
    };

/// The foot Tuner face (pen 23/x, #1229): the A4 reference, the reading for
/// the tuned input, and the pedal map. Driven by the shared Control owner;
/// the reading comes from the app-wide [TunerCubit].
class FootTunerView extends StatelessWidget {
  /// Creates the surface within the real Tracks hierarchy.
  const FootTunerView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final selection = context.select<ControlCubit, FootTunerSelection>(
      (cubit) => cubit.state.footTuner,
    );
    final preferences = context.select<ControlCubit, TunerPreferences>(
      (cubit) => cubit.state.tunerPreferences,
    );
    final projection = context.select<LooperBloc, FootTunerProjection>(
      (bloc) => projectFootTuner(bloc.state, selection, preferences),
    );
    final l10n = context.l10n;
    final surface = context.surface;

    const front = [
      PedalButton.recPlay,
      PedalButton.stop,
      PedalButton.undo,
      PedalButton.mode,
      PedalButton.track1,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ];
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontWeight: FontWeight.w400,
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
      ),
      child: Column(
        key: const Key('foot_tuner_view'),
        children: [
          Container(
            height: 96,
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 36),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.line)),
            ),
            child: Row(
              children: [
                IconButton.outlined(
                  key: const Key('foot_tuner_exit'),
                  tooltip: l10n.actionModeExit,
                  onPressed: () =>
                      control.activateFootTunerPedal(PedalButton.mode),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(64, 64),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
                const Spacer(),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(136, 64),
                    textStyle: const TextStyle(
                      fontFamily: SurfaceTheme.displayFont,
                      fontSize: 24,
                      fontWeight: FontWeight.w400,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => unawaited(openSegnoSettings()),
                  child: AppText(l10n.stageSettings),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(60, 24, 60, 24),
              child: FittedBox(
                child: SizedBox(
                  width: 1800,
                  height: 880,
                  child: Stack(
                    children: [
                      PositionedDirectional(
                        start: 40,
                        top: 16,
                        child: AppText(
                          l10n.actionModeTuner,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 40,
                        top: 176,
                        width: 418,
                        child: _ReferenceBlock(hz: projection.referenceHz),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootTunerPedal(
                          projection: projection,
                          button: PedalButton.clear,
                        ),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootTunerPedal(
                          projection: projection,
                          button: PedalButton.bank,
                        ),
                      ),
                      PositionedDirectional(
                        start: 908,
                        top: 70,
                        width: 852,
                        child: _ReadingBlock(projection: projection),
                      ),
                      PositionedDirectional(
                        start: 40,
                        end: 40,
                        top: 472,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            for (final button in front)
                              SizedBox(
                                width: 180,
                                child: _FootTunerPedal(
                                  projection: projection,
                                  button: button,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `A4 reference`, then the value and its unit.
class _ReferenceBlock extends StatelessWidget {
  const _ReferenceBlock({required this.hz});

  final int hz;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Semantics(
      key: const Key('foot_tuner_reference'),
      label: '${l10n.footTunerReference} $hz ${l10n.footTunerHzUnit}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              l10n.footTunerReference,
              style: TextStyle(fontSize: 24, color: surface.textSecondary),
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                AppText('$hz', style: const TextStyle(fontSize: 56)),
                const SizedBox(width: 12),
                AppText(
                  l10n.footTunerHzUnit,
                  style: TextStyle(fontSize: 24, color: surface.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The tuned input, the note with its direction and cents, and the meter.
class _ReadingBlock extends StatelessWidget {
  const _ReadingBlock({required this.projection});

  final FootTunerProjection projection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final names = context.select<InputsCubit, Map<int, String>>(
      (cubit) => cubit.state.names,
    );
    final tuner = context.watch<TunerCubit>().state;
    // Only a reading for the tuned input is drawn.
    final pitch = projection.hasSource && tuner.input == projection.source
        ? tuner.pitch
        : null;
    final name = projection.hasSource
        ? l10n.inputName(names, projection.source)
        : l10n.tunerNoTunableInput;
    final direction = pitch == null
        ? (projection.hasSource ? l10n.footTunerPlayOneNote : '')
        : pitch.isInTune
        ? l10n.footTunerInTune
        : pitch.cents < 0
        ? l10n.footTunerFlat
        : l10n.footTunerSharp;
    final cents = pitch == null
        ? ''
        : l10n.footTunerCents(
            pitch.cents.abs() < 0.05
                ? '0.0'
                : '${pitch.cents > 0 ? '+' : ''}'
                      '${pitch.cents.toStringAsFixed(1)}',
          );
    final noteColor = pitch != null && tuner.isStale
        ? surface.textSecondary
        : surface.textPrimary;
    return Column(
      key: const Key('foot_tuner_reading'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: AppText(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 27),
                ),
              ),
              if (projection.hasSource) ...[
                const SizedBox(width: 24),
                AppText(
                  projection.muted
                      ? l10n.footTunerInputMuted
                      : l10n.footTunerInputAudible,
                  key: const Key('foot_tuner_source_status'),
                  style: TextStyle(fontSize: 20, color: surface.textSecondary),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 138,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 32),
            child: Row(
              children: [
                SizedBox(
                  width: 170,
                  child: AppText(
                    pitch?.note ?? '—',
                    key: const Key('foot_tuner_note'),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 120,
                      height: 1,
                      color: noteColor,
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      direction,
                      key: const Key('foot_tuner_direction'),
                      style: const TextStyle(fontSize: 27),
                    ),
                    if (cents.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      AppText(
                        cents,
                        style: TextStyle(
                          fontSize: 21,
                          color: surface.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 40),
          child: _CentsMeter(cents: pitch?.cents),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 32),
          child: SizedBox(
            width: 820,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final label in const ['−50', '0', '+50'])
                  AppText(
                    label,
                    style: TextStyle(
                      fontSize: 18,
                      color: surface.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The −50..+50 cents scale: 21 ticks, a centre box, and the needle when
/// there is a reading.
class _CentsMeter extends StatelessWidget {
  const _CentsMeter({required this.cents});

  final double? cents;

  static const double width = 804;
  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final cents = this.cents;
    return SizedBox(
      key: const Key('foot_tuner_meter'),
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PositionedDirectional(
            start: width / 2 - height / 2,
            top: 0,
            width: height,
            height: height,
            child: ColoredBox(color: surface.cardHigh),
          ),
          for (var tick = 0; tick <= 20; tick++)
            PositionedDirectional(
              start: tick * width / 20 - 1,
              top: tick % 5 == 0 ? 18 : 31,
              width: 2,
              height: tick % 5 == 0 ? 28 : 15,
              child: ColoredBox(color: surface.controlStrong),
            ),
          if (cents != null)
            PositionedDirectional(
              key: const Key('foot_tuner_needle'),
              start: (cents.clamp(-50, 50) + 50) / 100 * width - 2.5,
              top: -2,
              width: 5,
              height: height,
              child: ColoredBox(color: surface.warning),
            ),
        ],
      ),
    );
  }
}

class _FootTunerPedal extends StatelessWidget {
  const _FootTunerPedal({required this.projection, required this.button});

  final FootTunerProjection projection;
  final PedalButton button;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final names = context.select<InputsCubit, Map<int, String>>(
      (cubit) => cubit.state.names,
    );
    final l10n = context.l10n;
    final pedal = projection[button];
    final resetHint = l10n.footTunerHoldReset(
      SettingsRepository.tunerReferenceDefaultHz,
    );
    final pageInputs = projection.pageInputs;
    final (title, hint) = switch (pedal.role) {
      FootTunerRole.input => switch (pedal.input) {
        final input? => (
          l10n.inputName(names, input),
          l10n.routingInputOrdinal(input + 1),
        ),
        null => ('—', ''),
      },
      FootTunerRole.mute =>
        projection.muted
            ? (l10n.footTunerUnmuteInput, l10n.footTunerInputMuted)
            : (l10n.footTunerMuteInput, l10n.footTunerInputAudible),
      FootTunerRole.referenceDown => (l10n.footTunerReferenceDown, resetHint),
      FootTunerRole.referenceUp => (l10n.footTunerReferenceUp, resetHint),
      FootTunerRole.nextPage => (
        pageInputs.isEmpty
            ? l10n.footTunerInputs(1, 4)
            : pageInputs.length == 1
            ? l10n.footTunerInputsOne(pageInputs.single + 1)
            : l10n.footTunerInputs(pageInputs.first + 1, pageInputs.last + 1),
        projection.pageCount > 1 ? l10n.footTunerNextInputs : '',
      ),
      FootTunerRole.exit => (l10n.actionModeExit, ''),
      FootTunerRole.none => (l10n.actionRecordPlay, ''),
    };
    final holds =
        pedal.role == FootTunerRole.referenceDown ||
        pedal.role == FootTunerRole.referenceUp;
    return PerformancePedal(
      keyPrefix: 'foot_tuner_pedal',
      button: button,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${button.index - PedalButton.track1.index + 1}',
      },
      title: title,
      titleMaxLines: 2,
      detail: '',
      hint: hint,
      enabled: pedal.available,
      selected: pedal.lit,
      onPressed: control.footTunerPressed,
      onReleased: control.footTunerReleased,
      onCancelled: control.footTunerCancelled,
      onActivate: () => control.activateFootTunerPedal(button),
      onHold: holds
          ? () => control.activateFootTunerPedal(button, hold: true)
          : null,
    );
  }
}
