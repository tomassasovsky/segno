import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/peaks_painter.dart';
import 'package:segno/common/saved_date_label.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/control/view/console_pedal_layout.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_names.dart';
import 'package:segno/looper/view/foot_pedal_rows.dart';
import 'package:segno/looper/view/foot_top_bar.dart';
import 'package:segno/looper/view/looper_mode_change.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// The Sessions face (#1910): the ten pedals, with the four sessions of the
/// page in view drawn above the four track switches. A tap on a switch
/// previews its session in the panel above the cards, and a Hold opens it
/// (#1921). Driven by the shared Control owner.
class FootSessionsView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const new({super.key});

  /// The frame every foot view draws its pedals in.
  static const double _frameWidth = 1800;

  /// A card's width: the pedal pitch less the gap between two cards.
  static const double _cardWidth = ConsolePedalLayout.pitch - 16;

  /// The cards sit under the preview panel and over their switches.
  static const double _cardTop = 262;
  static const double _cardHeight = 196;

  /// The preview panel: above the cards, as wide as the four of them.
  static const double _panelTop = 4;
  static const double _panelHeight = 250;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final projection = context.select<ControlCubit, FootSessionsProjection>(
      (cubit) => projectFootSessions(
        cubit.state.sessionCatalogue,
        cubit.state.footSessions,
      ),
    );
    // What an Open would end, said on every card it applies to (D3).
    final recording = context.select<PerformanceRecorderCubit, bool>(
      (cubit) => cubit.state is PerformanceRecorderArmed,
    );
    final interruption = context.select<LooperBloc, FootSessionsInterruption>(
      (bloc) => footSessionsInterruption(bloc.state, recording: recording),
    );
    final l10n = context.l10n;
    final surface = context.surface;
    final previewed = projection.previewed;
    final panelLeft = ConsolePedalLayout.left(
      kTrackSwitches.first,
      _frameWidth,
      _cardWidth,
    );
    final panelRight =
        ConsolePedalLayout.left(kTrackSwitches.last, _frameWidth, _cardWidth) +
        _cardWidth;
    // Read when a preview is first asked for, so a face that never previews
    // never needs the repository.
    return BlocProvider(
      create: (context) =>
          SessionPreviewCubit(context.read<SessionRepository>()),
      child: DefaultTextStyle.merge(
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
                        // The folder in view, once there is a session to be in
                        // one: a held Bank goes through them.
                        if (projection.sessions.isNotEmpty)
                          PositionedDirectional(
                            start: 40,
                            top: 84,
                            width: 480,
                            child: AppText(
                              projection.folder ?? l10n.libraryFolderUnfiled,
                              key: const Key('foot_sessions_folder'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 30),
                            ),
                          ),
                        PositionedDirectional(
                          start: 40,
                          top: projection.sessions.isEmpty ? 84 : 128,
                          width: 480,
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
                        if (projection.sessions.isNotEmpty)
                          PositionedDirectional(
                            start: 40,
                            top: 172,
                            width: 480,
                            child: AppText(
                              l10n.footSessionsHint,
                              key: const Key('foot_sessions_hint'),
                              style: TextStyle(
                                fontSize: 22,
                                color: surface.textMuted,
                              ),
                            ),
                          ),
                        if (previewed != null)
                          Positioned(
                            left: panelLeft,
                            top: _panelTop,
                            width: panelRight - panelLeft,
                            height: _panelHeight,
                            child: _SessionPreviewPanel(
                              session: previewed,
                              current: previewed.id == projection.openId,
                              interruption: interruption,
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
                            top: _cardTop,
                            width: _cardWidth,
                            height: _cardHeight,
                            child: _SessionCard(
                              pedal: projection[button],
                              interruption: interruption,
                            ),
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
      ),
    );
  }
}

/// The line that says what an Open would end, or null when it ends nothing.
String? _interruptionLine(
  AppLocalizations l10n,
  FootSessionsInterruption interruption,
) => switch (interruption) {
  FootSessionsInterruption.none => null,
  FootSessionsInterruption.playback => l10n.footSessionsStopsPlayback,
  FootSessionsInterruption.take => l10n.footSessionsEndsTake,
  FootSessionsInterruption.recording => l10n.footSessionsEndsRecording,
};

String _bpm(double bpm) => bpm == bpm.roundToDouble()
    ? bpm.round().toString()
    : bpm.toStringAsFixed(1);

/// One session above its switch: its name, its looper mode and tempo, what
/// it holds, and one line of state: the open one, the one being opened, the
/// one that could not be opened, or what opening it would end. An empty
/// position says so. The card the panel previews is outlined. A tap on the
/// card previews it, and a long press opens it.
class _SessionCard extends StatelessWidget {
  const new({required this.pedal, required this.interruption});

  final FootSessionsPedal pedal;
  final FootSessionsInterruption interruption;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final session = pedal.session;
    // The outline is the panel's: the session it previews or is opening.
    final marked = pedal.previewed || pedal.opening;
    // One line, the most pressing first. The warnings read in the warning
    // colour; the open and opening lines in the accent.
    final (String? line, Color lineColor) = pedal.opening
        ? (l10n.footSessionsOpening, surface.accent)
        : pedal.current
        ? (l10n.footSessionsOpenNow, surface.accent)
        : pedal.failed
        ? (l10n.footSessionsCouldNotOpen, surface.warning)
        : (
            // Only where a hold is taken: not while an Open is in flight.
            pedal.opens ? _interruptionLine(l10n, interruption) : null,
            surface.warning,
          );
    final mode = session?.looperMode;
    final card = DecoratedBox(
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 26, height: 1.15),
                  ),
                  const SizedBox(height: 8),
                  // The setup first: a session can hold one and nothing
                  // recorded.
                  if (mode != null || session.tempoBpm > 0)
                    AppText(
                      [
                        if (mode != null) looperModeLabels(l10n)[mode]!.label,
                        if (session.tempoBpm > 0)
                          l10n.footSessionsTempo(_bpm(session.tempoBpm)),
                      ].join(' · '),
                      key: Key('foot_sessions_card_setup_${pedal.button.name}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        color: surface.textSecondary,
                      ),
                    ),
                  AppText(
                    l10n.footSessionsTracks(session.trackCount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      color: surface.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  if (line != null)
                    AppText(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 20, color: lineColor),
                    ),
                ],
              ),
      ),
    );
    if (session == null || !pedal.available) return card;
    final control = context.read<ControlCubit>();
    return GestureDetector(
      key: Key('foot_sessions_card_tap_${pedal.button.name}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => control.activateFootSessionsPedal(pedal.button),
      onLongPress: pedal.opens
          ? () => control.activateFootSessionsPedal(pedal.button, hold: true)
          : null,
      child: card,
    );
  }
}

/// The preview of the session a tap chose (#1921): its name and when it was
/// saved, then the setup and the effects on one side and the recordings on
/// the other. It asks the preview cubit for [session] when it appears and
/// whenever the session changes, and for none when it goes away, so the
/// next preview of the same session is read again.
class _SessionPreviewPanel extends StatefulWidget {
  const new({
    required this.session,
    required this.current,
    required this.interruption,
  });

  final FootSessionEntry session;

  /// Whether [session] is the open one.
  final bool current;
  final FootSessionsInterruption interruption;

  @override
  State<_SessionPreviewPanel> createState() => _SessionPreviewPanelState();
}

class _SessionPreviewPanelState extends State<_SessionPreviewPanel> {
  late final SessionPreviewCubit _cubit = context.read<SessionPreviewCubit>();

  @override
  void initState() {
    super.initState();
    unawaited(_cubit.show(widget.session.id));
  }

  @override
  void didUpdateWidget(_SessionPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      unawaited(_cubit.show(widget.session.id));
    }
  }

  @override
  void dispose() {
    unawaited(_cubit.show(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<SessionPreviewCubit>().state;
    // The cubit may still hold the session shown before this one.
    final shown = state.id == widget.session.id;
    final preview = shown ? state.preview : null;
    final saved = savedDateLabel(context, preview?.summary.modifiedAt);
    return DecoratedBox(
      key: const Key('foot_sessions_preview'),
      decoration: ShapeDecoration(
        color: surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: surface.accent, width: 2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: AppText(
                    widget.session.name,
                    key: const Key('foot_sessions_preview_name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 26, height: 1.15),
                  ),
                ),
                if (saved.isNotEmpty)
                  AppText(
                    l10n.footSessionsSaved(saved),
                    style: TextStyle(fontSize: 20, color: surface.textMuted),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (shown && state.status == SessionPreviewStatus.unreadable)
              AppText(
                l10n.libraryPreviewUnreadable,
                key: const Key('foot_sessions_preview_unreadable'),
                style: TextStyle(fontSize: 20, color: surface.warning),
              ),
            if (preview != null)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _PreviewSetup(
                        preview: preview,
                        effects: state.effects,
                        current: widget.current,
                        interruption: widget.interruption,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: _PreviewRecordings(
                        preview: preview,
                        peaks: state.peaks,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The setup side of the preview: the looper mode, the tempo and the loop
/// length, the count-in and the click when they are on, the effects by
/// place, and what opening the session would end.
class _PreviewSetup extends StatelessWidget {
  const new({
    required this.preview,
    required this.effects,
    required this.current,
    required this.interruption,
  });

  final SessionPreview preview;
  final SessionPreviewEffects effects;
  final bool current;
  final FootSessionsInterruption interruption;

  /// How many effect names a line shows before it says how many more.
  static const int _namesPerLine = 3;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final summary = preview.summary;
    final setup = [
      looperModeLabels(l10n)[preview.looperMode]!.label,
      if (summary.tempoBpm > 0)
        '${l10n.footSessionsTempo(_bpm(summary.tempoBpm))} · '
            '${summary.tsNum}/${summary.tsDen}'
      else
        l10n.footSessionsNoTempo,
      if (preview.loopBars > 0) l10n.stageBarsFigure(preview.loopBars),
    ].join(' · ');
    // On a line of its own, so the first never ends in a separator.
    final start = [
      if (preview.countInBars > 0)
        l10n.footSessionsCountIn(l10n.stageBarsFigure(preview.countInBars)),
      if (preview.clickMode != ClickMode.off) l10n.footSessionsClickOn,
    ].join(' · ');
    final places = [
      (l10n.signalSectionInputs, effects.inputs),
      (l10n.signalSectionTracks, effects.tracks),
      (l10n.fxAllTracks, effects.allTracks),
      (l10n.signalSectionOutputs, effects.outputs),
    ];
    final ends = current
        ? l10n.footSessionsOpenNow
        : _interruptionLine(l10n, interruption);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PreviewLine(
          key: const Key('foot_sessions_preview_setup'),
          label: l10n.footSessionsSetup,
          text: setup,
        ),
        if (start.isNotEmpty)
          _PreviewLine(
            key: const Key('foot_sessions_preview_start'),
            label: '',
            text: start,
          ),
        for (final (label, entries) in places)
          if (entries.isNotEmpty)
            _PreviewLine(
              label: label,
              text: () {
                // One name per effect, however many tracks carry it.
                final names = {
                  for (final effect in entries) fxBlockName(l10n, effect),
                }.toList();
                final more = names.length - _namesPerLine;
                return [
                  ...names.take(_namesPerLine),
                  if (more > 0) l10n.footSessionsMore(more),
                ].join(', ');
              }(),
            ),
        const Spacer(),
        if (ends != null)
          AppText(
            ends,
            key: const Key('foot_sessions_preview_ends'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              height: 1.3,
              color: current ? surface.accent : surface.warning,
            ),
          ),
      ],
    );
  }
}

/// One labelled line of the preview's setup side.
class _PreviewLine extends StatelessWidget {
  const new({required this.label, required this.text, super.key});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 124,
          child: AppText(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              height: 1.3,
              color: surface.textMuted,
            ),
          ),
        ),
        Expanded(
          child: AppText(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              height: 1.3,
              color: surface.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The recordings side of the preview: one row per recorded track with its
/// waveform and its layers, or one line saying there are none.
class _PreviewRecordings extends StatelessWidget {
  const new({required this.preview, required this.peaks});

  final SessionPreview preview;
  final Map<int, List<double>> peaks;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (preview.tracks.isEmpty) {
      return AppText(
        l10n.footSessionsTracks(0),
        key: const Key('foot_sessions_preview_no_recordings'),
        style: TextStyle(fontSize: 20, height: 1.3, color: surface.textMuted),
      );
    }
    return Column(
      children: [
        for (final track in preview.tracks)
          SizedBox(
            height: 22,
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: AppText(
                    l10n.libraryTrackName(track.channel + 1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, color: surface.textMuted),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: surface.accentSurface),
                      child: SizedBox.expand(
                        child: peaks[track.channel] == null
                            ? null
                            : CustomPaint(
                                key: Key(
                                  'foot_sessions_preview_peaks_'
                                  '${track.channel}',
                                ),
                                painter: PeaksPainter(
                                  peaks: peaks[track.channel]!,
                                  color: surface.accent,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 104,
                  child: AppText(
                    track.muted
                        ? l10n.readoutStateMuted
                        : l10n.stageLayersFigure(track.layers),
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      color: surface.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
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
    // Clear acts on its Hold alone; Bank has one while another folder is
    // there to show; a track switch's Hold opens its session.
    final newLoop = pedal.role == FootSessionsRole.newLoop;
    final opens = pedal.role == FootSessionsRole.open && pedal.opens;
    final nextFolder =
        pedal.role == FootSessionsRole.nextPage && projection.hasOtherFolders;
    // With one page Bank's press does nothing, so it is named for its Hold.
    final folderOnly = nextFolder && projection.pageCount < 2;
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
        FootSessionsRole.nextPage =>
          folderOnly ? l10n.footSessionsFolder : l10n.footSessionsNextPage,
        // The short foot name: the catalogue's wraps in Spanish.
        FootSessionsRole.recordPlay => l10n.footCustomRecordPlay,
        FootSessionsRole.stop => l10n.actionStop,
        FootSessionsRole.exit => l10n.actionModeExit,
      },
      detail: switch (pedal.role) {
        FootSessionsRole.nextPage =>
          folderOnly
              ? ''
              : l10n.footSessionsPageOf(
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
      hint: newLoop || folderOnly || opens
          ? l10n.footFxHold
          : nextFolder
          ? l10n.footFxHoldAction(l10n.footSessionsFolder)
          : '',
      enabled: pedal.available,
      // The selection bar mirrors the physical LED: the open session's
      // switch, Bank past the first page, and Exit.
      selected: pedal.lit,
      onPressed: control.footSessionsPressed,
      onReleased: control.footSessionsReleased,
      onCancelled: control.footSessionsCancelled,
      // New loop acts on its Hold alone, so a tap on it does nothing.
      onActivate: () => control.activateFootSessionsPedal(button),
      onHold: newLoop || nextFolder || opens
          ? () => control.activateFootSessionsPedal(button, hold: true)
          : null,
    );
  }
}
