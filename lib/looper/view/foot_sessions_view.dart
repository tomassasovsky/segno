import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/control/view/console_pedal_layout.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
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

/// The Sessions face (#1910), drawn as the Mixer and Fade faces are: the ten
/// pedals with their captions, and one unboxed readout above the track
/// switches.
///
/// Each track switch is named for the session in its position. A press on
/// it shows that session in the readout as a short labelled list, and
/// holding it opens the session while the drawn switch's LED bar fills from
/// the left, as the real one does (#1921). With nothing shown, the readout
/// names the folder and the page in view.
class FootSessionsView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const new({super.key});

  /// The frame every foot view draws its pedals in.
  static const double _frameWidth = 1800;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final projection = context.select<ControlCubit, FootSessionsProjection>(
      (cubit) => projectFootSessions(
        cubit.state.sessionCatalogue,
        cubit.state.footSessions,
      ),
    );
    // What an Open would end, said in the readout's last line (D3).
    final recording = context.select<PerformanceRecorderCubit, bool>(
      (cubit) => cubit.state is PerformanceRecorderArmed,
    );
    final interruption = context.select<LooperBloc, FootSessionsInterruption>(
      (bloc) => footSessionsInterruption(bloc.state, recording: recording),
    );
    final l10n = context.l10n;
    final surface = context.surface;
    FootSessionsPedal? shown;
    for (final button in kTrackSwitches) {
      if (projection[button].previewed) shown = projection[button];
    }
    // The readout spans the four track switches' drawn faces.
    final left = ConsolePedalLayout.left(
      kTrackSwitches.first,
      _frameWidth,
      _SessionsReadout.faceWidth,
    );
    final right =
        ConsolePedalLayout.left(
          kTrackSwitches.last,
          _frameWidth,
          _SessionsReadout.faceWidth,
        ) +
        _SessionsReadout.faceWidth;
    // Read when a session is first shown, so a face that shows none never
    // needs the repository.
    return BlocProvider(
      create: (context) =>
          SessionPreviewCubit(context.read<SessionRepository>()),
      child: _SessionPreviewLoader(
        id: projection.previewId,
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
                onExit: () =>
                    control.activateFootSessionsPedal(PedalButton.mode),
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
                          Positioned(
                            left: left,
                            top: 0,
                            width: right - left,
                            height: _SessionsReadout.height,
                            child: _SessionsReadout(
                              projection: projection,
                              shown: shown,
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
      ),
    );
  }
}

/// Asks the preview cubit for the session shown, and for none when there is
/// none or the face goes away. One place asks, so a session taking
/// another's place never has its read undone by the one that left.
class _SessionPreviewLoader extends StatefulWidget {
  const new({required this.id, required this.child});

  final String? id;
  final Widget child;

  @override
  State<_SessionPreviewLoader> createState() => _SessionPreviewLoaderState();
}

class _SessionPreviewLoaderState extends State<_SessionPreviewLoader> {
  /// The cubit, once a session has been asked for.
  SessionPreviewCubit? _cubit;

  void _show() {
    if (widget.id == null && _cubit == null) return;
    final cubit = _cubit ??= context.read<SessionPreviewCubit>();
    unawaited(cubit.show(widget.id));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cubit == null) _show();
  }

  @override
  void didUpdateWidget(_SessionPreviewLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _show();
  }

  @override
  void dispose() {
    unawaited(_cubit?.show(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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

/// A session's setup in a few words, for the caption under its switch: the
/// looper mode and the tempo, or what it holds when the manifest names
/// neither.
String _setupWords(AppLocalizations l10n, FootSessionEntry session) {
  final mode = session.looperMode;
  final words = [
    if (mode != null) looperModeLabels(l10n)[mode]!.label,
    if (session.tempoBpm > 0) l10n.footSessionsTempo(_bpm(session.tempoBpm)),
  ];
  return words.isEmpty
      ? l10n.footSessionsTracks(session.trackCount)
      : words.join(' · ');
}

/// The readout above the track switches: seven lines, evenly spaced, lined
/// up with the pedals drawn beside it. The first line's capitals sit on the
/// top of the Clear and Bank pedals' faces, and the last line sits on the
/// baseline of their captions.
///
/// With no session shown it names the folder and the page, and says what a
/// press and a Hold do. With one shown ([shown]) it is that session's name,
/// a labelled list of its setup, and what opening it would end.
class _SessionsReadout extends StatelessWidget {
  const new({
    required this.projection,
    required this.shown,
    required this.interruption,
  });

  final FootSessionsProjection projection;

  /// The switch of the session shown, or null for none.
  final FootSessionsPedal? shown;
  final FootSessionsInterruption interruption;

  /// A drawn pedal's face width.
  static const double faceWidth = PerformancePedal.faceWidth;

  /// The frame's height the readout may use: down to the track switches.
  static const double height = 460;

  /// Where a rear pedal's face starts below the frame's top: the row's
  /// top, its LED bar and the gap under it.
  static const double _faceTop =
      FootPedalRows.rearTop +
      PerformancePedal.ledHeight +
      PerformancePedal.ledGap;

  /// Where a rear pedal's caption starts: under its face and the gap the
  /// pedal leaves between the two. The last line starts here with the
  /// caption's own font size as its strut, so the two share a baseline
  /// whatever the font. A view test holds it there.
  static const double _captionTop =
      _faceTop +
      faceWidth / PedalHardwareFace.aspectRatio +
      PerformancePedal.captionGap;

  /// That caption's baseline in the app's display face, which the lines
  /// between the first and the last are spaced to.
  static const double _captionBaseline = _captionTop + 25.9;

  /// The capital height of the display face, as a share of the font size.
  static const double _capHeight = 0.727;

  static const double _nameSize = 30;
  static const int _lines = 7;

  /// How many effect names are written before it says how many more.
  static const int _effectNames = 4;

  /// The baseline of line [index], 0 to 6.
  static double _baseline(int index) {
    const first = _faceTop + _capHeight * _nameSize;
    return first + (_captionBaseline - first) * index / (_lines - 1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final pedal = shown;
    final session = pedal?.session;
    if (pedal == null || session == null) {
      final none = projection.sessions.isEmpty;
      return Stack(
        children: [
          if (!none)
            _ReadoutLine(
              _baseline(0),
              AppText(
                projection.folder ?? l10n.libraryFolderUnfiled,
                key: const Key('foot_sessions_folder'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: _nameSize),
              ),
            ),
          _ReadoutLine(
            _baseline(none ? 0 : 1),
            AppText(
              none
                  ? l10n.footSessionsNone
                  : l10n.footSessionsPage(
                      projection.page + 1,
                      projection.pageCount,
                      projection.sessions.length,
                    ),
              key: const Key('foot_sessions_page'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 24, color: surface.textSecondary),
            ),
          ),
          // Said before any press too: a hold gives little time to read.
          if (!none && _interruptionLine(l10n, interruption) != null)
            _ReadoutLine(
              _baseline(_lines - 2),
              AppText(
                _interruptionLine(l10n, interruption)!,
                key: const Key('foot_sessions_ends'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 22, color: surface.warning),
              ),
            ),
          if (!none)
            _ReadoutLastLine(
              AppText(
                l10n.footSessionsHint,
                key: const Key('foot_sessions_hint'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 22, color: surface.textSecondary),
              ),
            ),
        ],
      );
    }
    final state = context.watch<SessionPreviewCubit>().state;
    // The cubit may still hold the session shown before this one.
    final loaded = state.id == session.id;
    final preview = loaded ? state.preview : null;
    final unreadable =
        loaded && state.status == SessionPreviewStatus.unreadable;
    // One name per effect, however many places carry it.
    final effects = {
      if (loaded)
        for (final effect in state.effects) fxBlockName(l10n, effect),
    }.toList();
    final rows = <(String, Widget)>[
      if (preview != null) ...[
        (
          l10n.loopTabMode,
          _ReadoutValue(looperModeLabels(l10n)[preview.looperMode]!.label),
        ),
        (
          l10n.loopTempoSliderLabel,
          _ReadoutValue(
            preview.summary.tempoBpm > 0
                ? '${l10n.footSessionsTempo(_bpm(preview.summary.tempoBpm))}'
                      ' · ${preview.summary.tsNum}/${preview.summary.tsDen}'
                : l10n.footSessionsNoTempo,
          ),
        ),
        if (preview.loopBars > 0)
          (
            l10n.loopLengthLabel,
            _ReadoutValue(l10n.stageBarsFigure(preview.loopBars)),
          ),
        (l10n.signalSectionTracks, _ReadoutTracks(preview: preview)),
        (
          l10n.fxTitle,
          _ReadoutValue(
            effects.isEmpty
                ? l10n.footSessionsNoEffects
                : [
                    ...effects.take(_effectNames),
                    if (effects.length > _effectNames)
                      l10n.footSessionsMore(effects.length - _effectNames),
                  ].join(', '),
          ),
        ),
      ],
    ];
    final ends = pedal.opens ? _interruptionLine(l10n, interruption) : null;
    final (String? last, Color lastColor) = pedal.opening
        ? (l10n.footSessionsOpening, surface.textPrimary)
        : pedal.current
        ? (l10n.footSessionsOpenNow, surface.textPrimary)
        : pedal.failed
        ? (l10n.footSessionsCouldNotOpen, surface.warning)
        : (ends, surface.warning);
    return Stack(
      key: const Key('foot_sessions_preview'),
      children: [
        _ReadoutLine(
          _baseline(0),
          AppText(
            session.name,
            key: const Key('foot_sessions_preview_name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: _nameSize),
          ),
        ),
        if (unreadable)
          _ReadoutLine(
            _baseline(1),
            AppText(
              l10n.libraryPreviewUnreadable,
              key: const Key('foot_sessions_preview_unreadable'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 24, color: surface.warning),
            ),
          ),
        for (final (index, (label, value)) in rows.indexed)
          _ReadoutLine(
            _baseline(1 + index),
            Row(
              key: Key('foot_sessions_preview_row_$index'),
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SizedBox(
                  width: 190,
                  child: AppText(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      color: surface.textSecondary,
                    ),
                  ),
                ),
                Expanded(child: value),
              ],
            ),
          ),
        if (last != null)
          _ReadoutLastLine(
            AppText(
              last,
              key: const Key('foot_sessions_preview_ends'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 22, color: lastColor),
            ),
          ),
      ],
    );
  }
}

/// One line of the readout, with its text's baseline at [baseline] below
/// the frame's top.
class _ReadoutLine extends StatelessWidget {
  const new(this.baseline, this.child);

  final double baseline;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: 0,
    child: Baseline(
      baseline: baseline,
      baselineType: TextBaseline.alphabetic,
      child: child,
    ),
  );
}

/// The readout's last line: on the baseline of the captions under the
/// pedals beside it. It starts where a caption starts and carries an unseen
/// strut of a caption's size, so its text sits on the caption's baseline.
class _ReadoutLastLine extends StatelessWidget {
  const new(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: _SessionsReadout._captionTop,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        const AppText(
          '\u200B',
          style: TextStyle(fontSize: PerformancePedal.captionSize),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

/// A value of the readout in words.
class _ReadoutValue extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 24),
  );
}

/// The shown session's eight tracks as the Library's rows draw them: a
/// segment per track, lit where it holds a recording, then how many do.
class _ReadoutTracks extends StatelessWidget {
  const new({required this.preview});

  final SessionPreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final recorded = {for (final track in preview.tracks) track.channel};
    return Row(
      children: [
        for (var channel = 0; channel < kMaxTracks; channel++) ...[
          if (channel > 0) const SizedBox(width: 6),
          SizedBox(
            key: Key('foot_sessions_preview_track_$channel'),
            width: 26,
            height: 10,
            child: ColoredBox(
              color: recorded.contains(channel)
                  ? surface.textPrimary
                  : surface.controlStrong,
            ),
          ),
        ],
        const SizedBox(width: 20),
        Expanded(
          child: _ReadoutValue(l10n.footSessionsRecorded(recorded.length)),
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
        // A track switch is named for its session, as Mixer and Fade name
        // theirs for their track.
        FootSessionsRole.open => pedal.session?.name ?? l10n.readoutStateEmpty,
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
        FootSessionsRole.open => switch (pedal) {
          FootSessionsPedal(session: null) => '',
          FootSessionsPedal(opening: true) => l10n.footSessionsOpening,
          FootSessionsPedal(current: true) => l10n.footSessionsOpenNow,
          FootSessionsPedal(failed: true) => l10n.footSessionsCouldNotOpen,
          FootSessionsPedal(:final session?) => _setupWords(l10n, session),
        },
        _ => '',
      },
      // The session in the readout, the open one and the one being opened
      // read in the primary colour.
      detailHighlighted: pedal.previewed || pedal.opening || pedal.current,
      titleMaxLines: pedal.role == FootSessionsRole.open ? 2 : 1,
      // The Hold to open fills the switch's LED bar, as the real one fills.
      holdFillsLed: opens,
      hint: opens
          ? l10n.footFxHoldAction(l10n.footSessionsOpen)
          : newLoop || folderOnly
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
