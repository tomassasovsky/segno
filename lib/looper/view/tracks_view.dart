import 'dart:async';

import 'package:brightness_client/brightness_client.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/cache_telemetry_scope.dart';
import 'package:segno/looper/view/connectivity_banners.dart';
import 'package:segno/looper/view/mixer_column.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/stage_db_scale.dart';
import 'package:segno/looper/view/stage_footer.dart';
import 'package:segno/looper/view/stage_top_bar.dart';
import 'package:segno/looper/view/track_column.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/looper/view/wave_track_row.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

/// The main display's Tracks view (the accepted stage): the top bar, then
/// the active bank's four tracks — tall level columns between the shared dBFS
/// scales, or one waveform row each in the Wave view — and the session strip
/// under them. The smaller display follows the selected track on its own.
///
/// The chrome ([StageTopBar], [StageFooter], [AudioNotRunningBanner]) and each
/// [TrackColumn] / [WaveTrackRow] are their own widgets; the tracks keyboard
/// map and the shared dispatch/announce helpers live in [TracksCommands]. This
/// view is just the layout that wires them together.
class TracksView extends StatefulWidget {
  /// Creates a [TracksView].
  const TracksView({super.key});

  @override
  State<TracksView> createState() => _TracksViewState();
}

class _TracksViewState extends State<TracksView> {
  @override
  void dispose() {
    dismissAppToast(AppToastId.undoClearAll);
    super.dispose();
  }

  /// Shows the post-clear-all toast whose action restores the whole rig. The
  /// action routes through the shared [TracksCommands.undoClearAll] so the
  /// toast and `⌘⇧C` can never drift, and dismisses the toast on tap. Short
  /// auto-close: the toast is the discoverable moment, `⌘⇧C` the permanence.
  void _showUndoClearAllToast() {
    if (!mounted) return;
    final l10n = context.l10n;
    showAppToast(
      id: AppToastId.undoClearAll,
      autoCloseDuration: const Duration(seconds: 6),
      title: Text(l10n.undoClearAllToast),
      actions: [
        TextButton(
          key: const Key(AppToastId.undoClearAllAction),
          onPressed: () {
            TracksCommands(context).undoClearAll();
            dismissAppToast(AppToastId.undoClearAll);
          },
          child: Text(l10n.undoClearAllAction),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tracksState = context.watch<TracksCubit>().state;
    // Mode / cursor / bank are the shared control overlay — the single owner
    // every surface (keyboard, tiles, pedal) reads and writes.
    final overlay = context.watch<ControlCubit>().state;
    final mode = overlay.mode;
    // NOT `context.watch<LooperBloc>()`: `LooperState` carries live audio —
    // per-track `peak` / `positionFrames` and the transport's position and
    // output peak — so it changes on every poll tick while audio flows, and
    // watching it here rebuilt this whole method: the theme, the listeners,
    // the tray provider, the Scaffold, the tray, and all eight columns.
    // Measured at 10.98ms p50 in the build phase on the Pi against a 16.7ms
    // frame (#638). This selector holds only values a moving meter cannot
    // change, so a level tick no longer reaches the chrome; the per-track
    // data is subscribed one level down, in [_TrackSlot], and the moving
    // level one level below THAT, in [TrackPeakMeter].
    final chrome = context.select<LooperBloc, _ChromeState>(
      (bloc) => _ChromeState.of(bloc.state),
    );

    // When the engine is stopped *because* the pinned interface is gone, the
    // device-lost banner below is the one true statement of it — so the
    // generic "engine stopped" affordance is suppressed while the loss
    // condition holds, and the stage never says it twice (#453). A stopped
    // engine with a device still present keeps the generic banner.
    final deviceLost = context.select<AudioSetupCubit, bool>(
      (cubit) => cubit.state.deviceConnectivity == DeviceConnectivity.lost,
    );

    final bankTracks = [
      for (final channel in chrome.channels)
        if (overlay.bankContains(channel)) channel,
    ];
    int? barsOf(int channel) => chrome.bars[channel];

    // Settings are reachable from the top bar's gear and the tray handle,
    // and on the desktop by right-clicking anywhere or pressing `S` (and from
    // the macOS menu bar).
    return LooperScreenTheme(
      child: MultiBlocListener(
        listeners: [
          BlocListener<SessionCubit, SessionState>(
            // React to a settled action — a save/load/export that finished or
            // failed — never the transient `working` tick; plus the
            // save-with-no-session signal that asks the UI to open Save-As.
            listenWhen: (previous, current) =>
                (current.status != previous.status &&
                    (current.status == SessionStatus.success ||
                        current.status == SessionStatus.failure)) ||
                (current.outcome == SessionOutcome.saveAsRequested &&
                    previous.outcome != SessionOutcome.saveAsRequested),
            listener: onSessionState,
          ),
          BlocListener<PerformanceRecorderCubit, PerformanceRecorderState>(
            // Fire once on entering `Rendering` (the capture dialog opens on
            // its rendering face and morphs in place), and once on entering
            // `Completed` (a rename afterwards re-emits `Completed` with a
            // different result, which must not reopen the dialog — and the
            // show function refuses to double-open while it is already up).
            // Percent ticks are Rendering-to-Rendering and do not re-fire.
            listenWhen: (previous, current) =>
                (current is PerformanceRecorderRendering &&
                    previous is! PerformanceRecorderRendering) ||
                (current is PerformanceRecorderCompleted &&
                    previous is! PerformanceRecorderCompleted),
            listener: onPerformanceRecorderState,
          ),
          BlocListener<ControlCubit, ControlState>(
            // Any surface that clears the rig — the pedal's CLEAR, the `C`
            // key, the chrome button — lands in `ControlCubit.clearAll`, which
            // bumps `clearAllPulse` when a cleared take can come back. Fire the
            // undo toast on that pulse; a clear with nothing to restore never
            // bumps it, so the toast stays silent for an empty-rig CLEAR.
            listenWhen: (previous, current) =>
                current.clearAllPulse != previous.clearAllPulse,
            listener: (context, state) => _showUndoClearAllToast(),
          ),
        ],
        child: BlocProvider(
          create: (context) {
            BrightnessClient brightness;
            try {
              brightness = context.read<BrightnessClient>();
            } on ProviderNotFoundException {
              brightness = const UnsupportedBrightnessClient();
            }
            DisplayBrightnessCubit? displayBrightness;
            try {
              displayBrightness = context.read<DisplayBrightnessCubit>();
            } on ProviderNotFoundException {
              displayBrightness = null;
            }
            final cubit = SettingsTrayCubit(
              settings: context.read<SettingsRepository>(),
              brightnessClient: brightness,
              displayBrightness: displayBrightness,
            );
            unawaited(cubit.load());
            return cubit;
          },
          // The scope wraps the whole stack (tray included): it listens to
          // the SettingsTrayCubit created just above, and its dispose bounds
          // the wet-cache telemetry to this screen's lifetime (#418).
          child: CacheTelemetryScope(
            child: Stack(
              children: [
                // Its own commands, built from a context UNDER the tray cubit
                // just created: the outer `commands` predates the provider, and
                // `G` reads the cubit to open the tray at Signal.
                Builder(
                  builder: (context) => Focus(
                    autofocus: true,
                    onKeyEvent: TracksCommands(context).handleKey,
                    child: GestureDetector(
                      key: const Key('tracks_settings_secondaryTap'),
                      behavior: HitTestBehavior.translucent,
                      onSecondaryTapUp: (_) => unawaited(openSegnoSettings()),
                      child: Scaffold(
                        // #692: FX is a performance MODE, so the whole stage
                        // takes the FX surface — the mode reads from the
                        // gutters and chrome around the tiles, not from one
                        // pill. Other modes keep the default stage black.
                        backgroundColor: mode == InteractionMode.fx
                            ? context.surface.fxSurface
                            : null,
                        body: SafeArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const StageTopBar(),
                              // Standing loss conditions hold the stage for
                              // as long as they are true — the pen's
                              // `STAGE / device-lost`, at the run's top. The
                              // widget carries its own bottom gap, so an
                              // empty stack adds no space here.
                              const Padding(
                                padding: EdgeInsets.fromLTRB(
                                  StageTopBar.sideInset,
                                  10,
                                  StageTopBar.sideInset,
                                  0,
                                ),
                                child: ConnectivityBanners(),
                              ),
                              // With no first-run gate, a stopped engine
                              // lands here; a full-width affordance opens
                              // settings to (re)start it. Suppressed while
                              // the device-lost banner above already states
                              // the stop, so the two never stack (#453).
                              if (!chrome.isConnected && !deviceLost)
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    StageTopBar.sideInset,
                                    10,
                                    StageTopBar.sideInset,
                                    4,
                                  ),
                                  child: AudioNotRunningBanner(),
                                ),
                              Expanded(
                                child: Padding(
                                  // The pen's instrument: 24 under the bar,
                                  // 60 off each edge.
                                  padding: const EdgeInsets.fromLTRB(
                                    StageTopBar.sideInset,
                                    24,
                                    StageTopBar.sideInset,
                                    0,
                                  ),
                                  child: switch (tracksState.stageView) {
                                    StageView.track => Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const StageDbScale(trailing: false),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Row(
                                            key: const Key('stage_track_run'),
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            // The pen's four columns sit 22
                                            // apart.
                                            spacing: 22,
                                            children: [
                                              // _TrackSlot supplies its own
                                              // Expanded, so a slot with no
                                              // track takes no flex and its
                                              // siblings widen.
                                              for (final channel in bankTracks)
                                                _TrackSlot(
                                                  channel: channel,
                                                  name: l10n.displayTrackName(
                                                    tracksState.nameOf(channel),
                                                    channel,
                                                  ),
                                                  selected:
                                                      channel == overlay.cursor,
                                                  mode: mode,
                                                  isPrimary:
                                                      channel ==
                                                      chrome.primaryTrack,
                                                  bars: barsOf(channel),
                                                  quantizeDiv:
                                                      chrome.quantizeDiv,
                                                  recDub: chrome.recDub,
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        const StageDbScale(trailing: true),
                                      ],
                                    ),
                                    StageView.wave => Column(
                                      key: const Key('stage_wave_run'),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      spacing: 22,
                                      children: [
                                        for (final channel in bankTracks)
                                          _WaveSlot(
                                            channel: channel,
                                            name: l10n.displayTrackName(
                                              tracksState.nameOf(channel),
                                              channel,
                                            ),
                                            selected: channel == overlay.cursor,
                                            mode: mode,
                                            isPrimary:
                                                channel == chrome.primaryTrack,
                                            bars: barsOf(channel),
                                          ),
                                      ],
                                    ),
                                    // The Mixer wears the Track view's own
                                    // chrome: the same two dB scales, because
                                    // its meters print the same scale.
                                    StageView.mixer => Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const StageDbScale(
                                          trailing: false,
                                          topInset: MixerColumn.meterTopInset,
                                          bottomInset:
                                              MixerColumn.meterBottomInset,
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Row(
                                            key: const Key('stage_mixer_run'),
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            spacing: 22,
                                            children: [
                                              for (final channel in bankTracks)
                                                _MixerSlot(
                                                  channel: channel,
                                                  name: l10n.displayTrackName(
                                                    tracksState.nameOf(channel),
                                                    channel,
                                                  ),
                                                  selected:
                                                      channel == overlay.cursor,
                                                  mode: mode,
                                                  isPrimary:
                                                      channel ==
                                                      chrome.primaryTrack,
                                                  bars: barsOf(channel),
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        const StageDbScale(
                                          trailing: true,
                                          topInset: MixerColumn.meterTopInset,
                                          bottomInset:
                                              MixerColumn.meterBottomInset,
                                        ),
                                      ],
                                    ),
                                  },
                                ),
                              ),
                              const StageFooter(),
                              const SizedBox(height: 22),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SettingsTray(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The slice of [LooperState] that [TracksView]'s own chrome depends on.
///
/// Deliberately excludes everything a moving meter touches — per-track
/// `peak` and `positionFrames`, the master position and the output peak.
/// Those change on every poll tick while audio flows, and including any here
/// would put the whole console back on the rebuild path this class exists to
/// keep it off (#646).
///
/// [channels] is every track's channel, not just the active bank's: the bank
/// filter lives on [ControlCubit], so filtering here would rebuild the chrome
/// whenever the bank changed for no benefit. It is compared element-wise, so a
/// fresh list of equal channels is still equal.
class _ChromeState extends Equatable {
  const _ChromeState({
    required this.channels,
    required this.bars,
    required this.isConnected,
    required this.primaryTrack,
    required this.quantizeDiv,
    required this.recDub,
  });

  factory _ChromeState.of(LooperState state) {
    final loopBars = state.transport.loopBars;
    return _ChromeState(
      channels: [for (final track in state.tracks) track.channel],
      // A track's bars: the master loop's whole bars times its multiple —
      // only once a take exists and a tempo grid counts bars at all.
      bars: [for (final track in state.tracks) _barsOf(track, loopBars)],
      isConnected: state.status.isConnected,
      primaryTrack: state.transport.primaryTrack,
      quantizeDiv: state.transport.quantizeDiv,
      recDub: state.transport.recDub,
    );
  }

  final List<int> channels;
  final List<int?> bars;
  final bool isConnected;
  final int primaryTrack;
  final GridDivision quantizeDiv;
  final bool recDub;

  @override
  List<Object?> get props => [
    channels,
    bars,
    isConnected,
    primaryTrack,
    quantizeDiv,
    recDub,
  ];
}

/// [track]'s length in bars under a master loop of [loopBars] whole bars, or
/// `null` while nothing counts them (no take, or no tempo grid).
int? _barsOf(Track track, int loopBars) =>
    track.hasContent && loopBars > 0 ? loopBars * track.multiple : null;

/// One [TrackColumn], subscribed to nothing but its own [channel]'s [Track] —
/// and to that track's STEADY fields only ([Track.steadyProps]).
///
/// Selecting per channel means only track 0's column can follow track 0, where
/// watching [LooperBloc] in [TracksView] rebuilt all eight columns plus the
/// entire console around them on every tick (#646). Comparing on the steady
/// slice means a moving level does not rebuild even that column: the level is
/// subscribed one level further down, in the [TrackPeakMeter] leaf, so a meter
/// tick redraws a bar instead of ~250 lines of tile with its l10n lookups,
/// theme-extension reads and FX stage label.
class _TrackSlot extends StatelessWidget {
  const _TrackSlot({
    required this.channel,
    required this.name,
    required this.selected,
    required this.mode,
    required this.isPrimary,
    required this.bars,
    required this.quantizeDiv,
    required this.recDub,
  });

  final int channel;
  final String name;
  final bool selected;
  final InteractionMode mode;
  final bool isPrimary;
  final int? bars;
  final GridDivision quantizeDiv;
  final bool recDub;

  @override
  Widget build(BuildContext context) {
    final steady = context.select<LooperBloc, SteadyTrack?>(
      (bloc) => steadyTrackOf(bloc.state, channel),
    );
    final track = steady?.track;
    // Defence only: `channels` is derived from the same `tracks` list, and any
    // change to it changes [_ChromeState], so the row rebuilds in the same
    // frame and this should be unreachable. Returning a bare SizedBox rather
    // than an Expanded matters if it ever is reached -- an empty Expanded would
    // hold its flex share and leave a gap instead of letting the surviving
    // columns widen.
    if (track == null) return const SizedBox.shrink();
    // The Expanded lives here, not at the call site, so the null case above can
    // opt out of the row's flex entirely.
    return Expanded(
      child: TrackColumn(
        track: track,
        name: name,
        selected: selected,
        mode: mode,
        isPrimary: isPrimary,
        bars: bars,
        quantizeDiv: quantizeDiv,
        recDub: recDub,
      ),
    );
  }
}

/// [_TrackSlot]'s twin for the Mixer view: one [MixerColumn] per channel, on
/// the same steady-slice subscription. The strip's meter and playhead
/// subscribe to their own live values one level down.
class _MixerSlot extends StatelessWidget {
  const _MixerSlot({
    required this.channel,
    required this.name,
    required this.selected,
    required this.mode,
    required this.isPrimary,
    required this.bars,
  });

  final int channel;
  final String name;
  final bool selected;
  final InteractionMode mode;
  final bool isPrimary;
  final int? bars;

  @override
  Widget build(BuildContext context) {
    final steady = context.select<LooperBloc, SteadyTrack?>(
      (bloc) => steadyTrackOf(bloc.state, channel),
    );
    final track = steady?.track;
    if (track == null) return const SizedBox.shrink();
    return Expanded(
      child: MixerColumn(
        track: track,
        name: name,
        selected: selected,
        mode: mode,
        isPrimary: isPrimary,
        bars: bars,
      ),
    );
  }
}

/// [_TrackSlot]'s twin for the Wave view: one [WaveTrackRow] per channel, on
/// the same steady-slice subscription.
class _WaveSlot extends StatelessWidget {
  const _WaveSlot({
    required this.channel,
    required this.name,
    required this.selected,
    required this.mode,
    required this.isPrimary,
    required this.bars,
  });

  final int channel;
  final String name;
  final bool selected;
  final InteractionMode mode;
  final bool isPrimary;
  final int? bars;

  @override
  Widget build(BuildContext context) {
    final steady = context.select<LooperBloc, SteadyTrack?>(
      (bloc) => steadyTrackOf(bloc.state, channel),
    );
    final track = steady?.track;
    if (track == null) return const SizedBox.shrink();
    return Expanded(
      child: WaveTrackRow(
        track: track,
        name: name,
        selected: selected,
        mode: mode,
        isPrimary: isPrimary,
        bars: bars,
      ),
    );
  }
}
