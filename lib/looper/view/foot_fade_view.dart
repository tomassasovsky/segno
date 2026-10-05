import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

/// The accepted ten-pedal Fade surface, driven by the shared Control owner.
/// Bars show each envelope relative to the saved Mixer volume; they never
/// claim a stopped or muted track is audible.
class FootFadeView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootFadeView({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<FadeSettings>();
    return StreamBuilder<Object?>(
      stream: settings.results,
      builder: (context, _) => _FootFadeContent(
        durations: settings.needsRecovery ? null : settings.live,
      ),
    );
  }
}

/// Reads one track's envelope as a short state word.
String _fadeStatus(AppLocalizations l10n, FootFadeTrack track) {
  if (!track.available) return l10n.readoutStateEmpty;
  if (track.moving) {
    return track.target > track.amount
        ? l10n.footFadeFadingIn
        : l10n.footFadeFadingOut;
  }
  if (track.amount >= 1) return l10n.footFadeFullLevel;
  if (track.amount <= 0) return l10n.footFadeFadedOut;
  return l10n.footMixerPercent((track.amount * 100).round());
}

String _seconds(int? milliseconds) =>
    milliseconds == null ? '—' : (milliseconds / 1000).toStringAsFixed(1);

class _FootFadeContent extends StatelessWidget {
  const _FootFadeContent({required this.durations});

  final FadeDurations? durations;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final selection = context.select<ControlCubit, FootFadeSelection>(
      (cubit) => cubit.state.footFade,
    );
    final bank = context.select<ControlCubit, int>(
      (cubit) => cubit.state.activeBank,
    );
    final projection = context.select<LooperBloc, FootFadeProjection>(
      (bloc) => projectFootFade(
        bloc.state,
        selection,
        bank: bank,
        durations: durations,
      ),
    );
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final surface = context.surface;
    String name(int channel) =>
        l10n.displayTrackName(tracks.nameOf(channel), channel);
    final timeChannel = projection.selection.timeChannel;
    final timeTrack = timeChannel == null
        ? null
        : projection.tracks[timeChannel];

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
        key: const Key('foot_fade_view'),
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
                  key: const Key('foot_fade_exit'),
                  tooltip: l10n.actionModeExit,
                  onPressed: () => control.setMode(InteractionMode.record),
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
                  onPressed: () => context.read<SettingsTrayCubit>().open(),
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
                          l10n.actionModeFade,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootFadePedal(
                          button: PedalButton.clear,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootFadePedal(
                          button: PedalButton.bank,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 940,
                        top: 150,
                        width: 820,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                AppText(
                                  timeTrack == null
                                      ? l10n.footFadeDefaultTime
                                      : l10n.footFadeTrackTime(
                                          name(timeTrack.channel),
                                        ),
                                  style: TextStyle(
                                    fontSize: 26,
                                    color: surface.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 28),
                                AppText(
                                  _seconds(projection.selectedMs),
                                  key: const Key('foot_fade_selected_time'),
                                  style: const TextStyle(
                                    fontSize: 52,
                                    fontFamily: SurfaceTheme.monoFont,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                AppText(
                                  's',
                                  style: TextStyle(
                                    fontSize: 22,
                                    color: surface.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                            if (timeTrack != null)
                              AppText(
                                timeTrack.custom
                                    ? l10n.footFadeCustom
                                    : l10n.footFadeUsesDefault,
                                key: const Key('foot_fade_time_source'),
                                style: TextStyle(
                                  fontSize: 20,
                                  color: surface.textSecondary,
                                ),
                              ),
                            const SizedBox(height: 20),
                            for (final row in [0, 4])
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  bottom: 20,
                                ),
                                child: Row(
                                  children: [
                                    for (var i = 0; i < 4; i++) ...[
                                      if (i > 0) const SizedBox(width: 24),
                                      Expanded(
                                        child: _FadeOverviewCell(
                                          track: projection.tracks[row + i],
                                          name: name(row + i),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                        ),
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
                                child: _FootFadePedal(
                                  button: button,
                                  projection: projection,
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

/// One track in the all-eight overview: name, effective time, level, state.
class _FadeOverviewCell extends StatelessWidget {
  const _FadeOverviewCell({required this.track, required this.name});

  final FootFadeTrack track;
  final String name;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Opacity(
      key: Key('foot_fade_overview_${track.channel}'),
      opacity: track.available ? 1 : surface.disabledOpacity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
              AppText(
                l10n.footFadeSeconds(_seconds(track.milliseconds)),
                style: TextStyle(fontSize: 18, color: surface.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: track.available ? track.amount.clamp(0, 1) : 0,
            minHeight: 6,
            color: surface.textPrimary,
            backgroundColor: surface.controlStrong,
          ),
          const SizedBox(height: 10),
          AppText(
            _fadeStatus(l10n, track),
            style: TextStyle(fontSize: 18, color: surface.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _FootFadePedal extends StatelessWidget {
  const _FootFadePedal({required this.button, required this.projection});

  final PedalButton button;
  final FootFadeProjection projection;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final cursor = context.select<ControlCubit, int>(
      (cubit) => cubit.state.cursor,
    );
    final l10n = context.l10n;
    final role = FootFadeProjection.pedalRoles[button]!;
    final track = role.slot == null ? null : projection.trackAt(role.slot!);
    final timeIsDefault = projection.selection.timeChannel == null;
    final title = switch (role.press) {
      FootFadeAction.recordPlay => l10n.actionRecordPlay,
      FootFadeAction.stop => l10n.actionStop,
      FootFadeAction.exit => l10n.actionModeExit,
      FootFadeAction.shorten => l10n.footFadeTimeDown,
      FootFadeAction.lengthen => l10n.footFadeTimeUp,
      FootFadeAction.nextBank => l10n.footFadeBank(
        projection.bank == 0 ? 'A' : 'B',
      ),
      FootFadeAction.toggleTrack => l10n.displayTrackName(
        tracks.nameOf(track!.channel),
        track.channel,
      ),
      FootFadeAction.selectTrackTime ||
      FootFadeAction.resetTime ||
      FootFadeAction.selectDefault => '',
    };
    final hint = switch (role.hold) {
      FootFadeAction.resetTime =>
        timeIsDefault ? l10n.footMixerHoldReset : l10n.footFadeHoldUseDefault,
      FootFadeAction.selectDefault => l10n.footFadeHoldDefaultTime,
      FootFadeAction.selectTrackTime when track!.available =>
        l10n.footFadeHoldTime,
      _ => '',
    };
    final detail = track != null
        ? _fadeStatus(l10n, track)
        : switch (role.press) {
            FootFadeAction.recordPlay => l10n.displayTrackName(
              tracks.nameOf(cursor),
              cursor,
            ),
            FootFadeAction.stop => l10n.actionScopeAllTracks,
            _ => '',
          };
    final timeEditable = projection.durations != null;
    return PerformancePedal(
      keyPrefix: 'foot_fade_pedal',
      button: button,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${role.slot! + 1}',
      },
      title: title,
      detail: detail,
      hint: hint,
      level: track == null ? null : (track.available ? track.amount : 0),
      enabled:
          track?.available ??
          (role.hold != FootFadeAction.resetTime || timeEditable),
      // The selection bar mirrors the physical LED: a track while fading or
      // faded out, Bank on bank B, and Exit, the way back to Tracks.
      selected:
          role.press == FootFadeAction.exit ||
          (role.press == FootFadeAction.nextBank && projection.bank == 1) ||
          (track != null && track.available && track.attenuated),
      onPressed: control.footFadePressed,
      onReleased: control.footFadeReleased,
      onCancelled: control.footFadeCancelled,
      onActivate: () => control.activateFootFadePedal(button),
      onHold: role.hold == null
          ? null
          : () => control.activateFootFadePedal(button, hold: true),
    );
  }
}
