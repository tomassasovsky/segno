import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/control/view/console_pedal_layout.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/foot_pedal_rows.dart';
import 'package:segno/looper/view/foot_top_bar.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';

/// The Sessions face (#1910): the ten pedals, with the four sessions of the
/// page in view drawn above the four track switches that open them. Driven
/// by the shared Control owner.
class FootSessionsView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const new({super.key});

  /// The frame every foot view draws its pedals in.
  static const double _frameWidth = 1800;

  /// A card's width: the pedal pitch less the gap between two cards.
  static const double _cardWidth = ConsolePedalLayout.pitch - 16;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final projection = context.select<ControlCubit, FootSessionsProjection>(
      (cubit) => projectFootSessions(
        cubit.state.sessionCatalogue,
        cubit.state.footSessions,
      ),
    );
    final l10n = context.l10n;
    final surface = context.surface;
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontWeight: FontWeight.w400,
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
      ),
      child: Column(
        key: const Key('foot_sessions_view'),
        children: [
          FootTopBar(
            exitKey: const Key('foot_sessions_exit'),
            onExit: () => control.activateFootSessionsPedal(PedalButton.mode),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(60, 24, 60, 24),
              child: FittedBox(
                child: SizedBox(
                  width: _frameWidth,
                  height: 880,
                  child: Stack(
                    children: [
                      PositionedDirectional(
                        start: 40,
                        top: 16,
                        child: AppText(
                          l10n.actionModeSessions,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 40,
                        top: 84,
                        width: 760,
                        child: AppText(
                          projection.sessions.isEmpty
                              ? l10n.footSessionsNone
                              : l10n.footSessionsPage(
                                  projection.page + 1,
                                  projection.pageCount,
                                  projection.sessions.length,
                                ),
                          key: const Key('foot_sessions_page'),
                          style: TextStyle(
                            fontSize: 26,
                            color: surface.textSecondary,
                          ),
                        ),
                      ),
                      // Each card over its switch, wherever the plate puts
                      // it: the plate never mirrors.
                      for (final button in kTrackSwitches)
                        Positioned(
                          left: ConsolePedalLayout.left(
                            button,
                            _frameWidth,
                            _cardWidth,
                          ),
                          top: 196,
                          width: _cardWidth,
                          height: 250,
                          child: _SessionCard(pedal: projection[button]),
                        ),
                      Positioned.fill(
                        child: FootPedalRows(
                          pedal: (button) => _FootSessionsPedal(
                            button: button,
                            projection: projection,
                          ),
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

/// One session above its switch: its name, what it holds, and whether it is
/// the open one or the one being opened. An empty position says so.
class _SessionCard extends StatelessWidget {
  const new({required this.pedal});

  final FootSessionsPedal pedal;

  static String _bpm(double bpm) => bpm == bpm.roundToDouble()
      ? bpm.round().toString()
      : bpm.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final session = pedal.session;
    final marked = pedal.lit || pedal.opening;
    return DecoratedBox(
      key: Key('foot_sessions_card_${pedal.button.name}'),
      decoration: ShapeDecoration(
        color: surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: marked ? surface.accent : surface.borderStrong,
            width: marked ? 2 : 1,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: session == null
            ? AppText(
                l10n.readoutStateEmpty,
                style: TextStyle(fontSize: 24, color: surface.textMuted),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    session.name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 26, height: 1.15),
                  ),
                  const SizedBox(height: 10),
                  AppText(
                    [
                      l10n.footSessionsTracks(session.trackCount),
                      if (session.tempoBpm > 0)
                        l10n.footSessionsTempo(_bpm(session.tempoBpm)),
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      color: surface.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  if (marked)
                    AppText(
                      pedal.opening
                          ? l10n.footSessionsOpening
                          : l10n.footSessionsOpenNow,
                      style: TextStyle(fontSize: 20, color: surface.accent),
                    ),
                ],
              ),
      ),
    );
  }
}

class _FootSessionsPedal extends StatelessWidget {
  const new({required this.button, required this.projection});

  final PedalButton button;
  final FootSessionsProjection projection;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final cursor = context.select<ControlCubit, int>(
      (cubit) => cubit.state.cursor,
    );
    final hold = context.select<ControlCubit, ({bool pending, Duration after})>(
      (cubit) => (
        pending: cubit.state.pendingHolds.contains(button),
        after: cubit.state.holdThreshold,
      ),
    );
    final l10n = context.l10n;
    final pedal = projection[button];
    final isHold = pedal.role == FootSessionsRole.newLoop;
    return PerformancePedal(
      keyPrefix: 'foot_sessions_pedal',
      button: button,
      holdPending: hold.pending,
      holdThreshold: hold.after,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${button.index - PedalButton.track1.index + 1}',
      },
      title: switch (pedal.role) {
        FootSessionsRole.open =>
          pedal.session == null ? '' : l10n.footSessionsOpen,
        FootSessionsRole.save => l10n.footSessionsSave,
        FootSessionsRole.newLoop => l10n.actionNewLoop,
        FootSessionsRole.nextPage => l10n.footSessionsNextPage,
        // The short foot name: the catalogue's wraps in Spanish.
        FootSessionsRole.recordPlay => l10n.footCustomRecordPlay,
        FootSessionsRole.stop => l10n.actionStop,
        FootSessionsRole.exit => l10n.actionModeExit,
      },
      detail: switch (pedal.role) {
        FootSessionsRole.nextPage => l10n.footSessionsPageOf(
          projection.page + 1,
          projection.pageCount,
        ),
        FootSessionsRole.recordPlay => l10n.displayTrackName(
          tracks.nameOf(cursor),
          cursor,
        ),
        FootSessionsRole.stop => l10n.actionScopeAllTracks,
        _ => '',
      },
      hint: isHold ? l10n.footFxHold : '',
      enabled: pedal.available,
      // The selection bar mirrors the physical LED: the open session's
      // switch, Bank past the first page, and Exit.
      selected: pedal.lit,
      onPressed: control.footSessionsPressed,
      onReleased: control.footSessionsReleased,
      onCancelled: control.footSessionsCancelled,
      // New loop acts on its Hold alone, so a tap on it does nothing.
      onActivate: () => control.activateFootSessionsPedal(button),
      onHold: isHold
          ? () => control.activateFootSessionsPedal(button, hold: true)
          : null,
    );
  }
}
