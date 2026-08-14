import 'dart:async';

import 'package:brightness_client/brightness_client.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/track_column.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

/// The full-screen Tracks view (Chewie-Monsta style): a row
/// of tall colored track columns, each a level meter with an editable name.
/// Tapping a column selects it (white highlight) and toggles record/overdub;
/// long-press stops. The master output waveform is in a separate window.
///
/// The chrome ([TracksToolbar], [AudioNotRunningBanner]) and each
/// [TrackColumn] are their own widgets; the tracks keyboard map and the
/// shared dispatch/announce helpers live in [TracksCommands]. This view is
/// just the layout that wires them together.
class TracksView extends StatefulWidget {
  /// Creates a [TracksView].
  const TracksView({super.key});

  @override
  State<TracksView> createState() => _TracksViewState();
}

class _TracksViewState extends State<TracksView> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tracksState = context.watch<TracksCubit>().state;
    // Mode / cursor / bank are the shared control overlay — the single owner
    // every surface (keyboard, tiles, pedal) reads and writes.
    final overlay = context.watch<ControlCubit>().state;
    final mode = overlay.mode;
    final commands = TracksCommands(context);
    // NOT `context.watch<LooperBloc>()`: `LooperState` carries live audio —
    // per-track `rms`/`peak`/`playheadFrames` and `transport
    // .masterPositionFrames` — so it changes on every poll tick while audio
    // flows, and watching it here rebuilt this whole method: the theme, the
    // listeners, the tray provider, the Scaffold, the tray, and all eight
    // columns. Measured at 10.98ms p50 in the build phase on the Pi against a
    // 16.7ms frame (#638). This selector holds only values a moving meter
    // cannot change, so a level tick no longer reaches the chrome; the live
    // per-track data is subscribed one level down, in [_TrackSlot].
    final chrome = context.select<LooperBloc, _ChromeState>(
      (bloc) => _ChromeState.of(bloc.state, commands),
    );

    // Settings are reachable from the Tracks view by right-clicking
    // anywhere or pressing `S` (and from the macOS menu bar). Kept chromeless
    // and minimal otherwise.
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
            // its rendering face and morphs in place), once on entering
            // `Completed` (a rename afterwards re-emits `Completed` with a
            // different result, which must not reopen the dialog — and the
            // show function refuses to double-open while it is already up),
            // and once on the boot-recovery prompt appearing. Percent ticks
            // are Rendering-to-Rendering and do not re-fire.
            listenWhen: (previous, current) =>
                (current is PerformanceRecorderRendering &&
                    previous is! PerformanceRecorderRendering) ||
                (current is PerformanceRecorderCompleted &&
                    previous is! PerformanceRecorderCompleted) ||
                (current is PerformanceRecorderIdle &&
                    current.recoveryDirectory != null &&
                    !(previous is PerformanceRecorderIdle &&
                        previous.recoveryDirectory != null)),
            listener: onPerformanceRecorderState,
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
                      body: SafeArea(
                        child: Padding(
                          // Console/kiosk mode hides the on-screen toolbar (the
                          // foot pedals drive transport/mode/clear) and tightens
                          // the layout for the fixed panel; desktop builds keep
                          // the full chrome.
                          // Console: the pen's `STAGE / stage` insets the run
                          // 10 from the left, right and bottom, under a status
                          // bar that starts at 24. Desktop keeps its own
                          // chrome and its own 18.
                          padding: kConsoleMode
                              ? const EdgeInsets.fromLTRB(10, 8, 10, 10)
                              : const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!kConsoleMode) ...[
                                TracksToolbar(
                                  mode: mode,
                                  activeBank: overlay.activeBank,
                                  anyActive: chrome.anyActive,
                                  playStopEnabled: chrome.playStopEnabled,
                                  transportEnabled: chrome.transportEnabled,
                                  onToggleMode: commands.toggleMode,
                                  onPlayStopAll: () => commands.togglePlayAll(
                                    playing: chrome.anyActive,
                                  ),
                                  onClearAll: commands.clearAll,
                                ),
                                const SizedBox(height: 14),
                              ],
                              // With no first-run gate, a stopped engine lands
                              // here; a full-width affordance opens settings to
                              // (re)start it.
                              if (!chrome.isConnected) ...[
                                const AudioNotRunningBanner(),
                                const SizedBox(height: 14),
                              ],
                              Expanded(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  // The pen's four columns sit 10 apart, and
                                  // the run's own inset holds it off the
                                  // screen edges. Padding each column instead
                                  // doubled the inner gap to 16 and put half
                                  // of it outside the run as well.
                                  spacing: kConsoleMode ? 10 : 16,
                                  children: [
                                    // _TrackSlot supplies its own Expanded, so
                                    // a slot with no track takes no flex and
                                    // its siblings widen -- matching what the
                                    // old `for (track in state.tracks)` did by
                                    // simply emitting fewer children.
                                    for (final channel in chrome.channels)
                                      if (overlay.bankContains(channel))
                                        _TrackSlot(
                                          channel: channel,
                                          name: l10n.displayTrackName(
                                            tracksState.nameOf(channel),
                                            channel,
                                          ),
                                          selected: channel == overlay.cursor,
                                          mode: mode,
                                          onUndo: commands.undo,
                                          onRedo: commands.redo,
                                          looperMode: chrome.looperMode,
                                          isPrimary:
                                              channel == chrome.primaryTrack,
                                          onCrownPrimary: commands.crownPrimary,
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
                ),
              ),
              const SettingsTray(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The slice of [LooperState] that [TracksView]'s own chrome depends on.
///
/// Deliberately excludes everything a moving meter touches — `rms`, `peak`,
/// `playheadFrames`, `masterPositionFrames`. Those change on every poll tick
/// while audio flows, and including any of them here would put the whole
/// console back on the rebuild path this class exists to keep it off (#646).
///
/// [channels] is every track's channel, not just the active bank's: the bank
/// filter lives on [ControlCubit], so filtering here would rebuild the chrome
/// whenever the bank changed for no benefit. It is compared element-wise, so a
/// fresh list of equal channels is still equal.
class _ChromeState extends Equatable {
  const _ChromeState({
    required this.channels,
    required this.isConnected,
    required this.looperMode,
    required this.primaryTrack,
    required this.anyActive,
    required this.transportEnabled,
    required this.playStopEnabled,
  });

  factory _ChromeState.of(LooperState state, TracksCommands commands) {
    final anyActive = commands.anyActive(state);
    // Both global transport buttons are no-ops with no recorded audio or a
    // stopped engine; disabling them avoids dead-feeling controls.
    final transportEnabled = state.status.isConnected && state.hasContent;
    return _ChromeState(
      channels: [for (final track in state.tracks) track.channel],
      isConnected: state.status.isConnected,
      looperMode: state.transport.looperMode,
      primaryTrack: state.transport.primaryTrack,
      anyActive: anyActive,
      transportEnabled: transportEnabled,
      // The Play direction is additionally blocked when nothing would sound —
      // every loaded track is muted (or none holds a loop). Stopping stays
      // available whenever something is active.
      playStopEnabled: anyActive
          ? transportEnabled
          : state.status.isConnected && commands.anyPlayable(state),
    );
  }

  final List<int> channels;
  final bool isConnected;
  final LooperMode looperMode;
  final int primaryTrack;
  final bool anyActive;
  final bool transportEnabled;
  final bool playStopEnabled;

  @override
  List<Object?> get props => [
    channels,
    isConnected,
    looperMode,
    primaryTrack,
    anyActive,
    transportEnabled,
    playStopEnabled,
  ];
}

/// One [TrackColumn], subscribed to nothing but its own [channel]'s [Track].
///
/// This is where the live audio data is allowed back in. Selecting per channel
/// means track 0's meter moving rebuilds track 0's column and nothing else —
/// where watching [LooperBloc] in [TracksView] rebuilt all eight columns plus
/// the entire console around them on every tick (#646).
class _TrackSlot extends StatelessWidget {
  const _TrackSlot({
    required this.channel,
    required this.name,
    required this.selected,
    required this.mode,
    required this.onUndo,
    required this.onRedo,
    required this.looperMode,
    required this.isPrimary,
    required this.onCrownPrimary,
  });

  final int channel;
  final String name;
  final bool selected;
  final InteractionMode mode;
  final void Function(int channel) onUndo;
  final void Function(int channel) onRedo;
  final LooperMode looperMode;
  final bool isPrimary;
  final void Function(int channel)? onCrownPrimary;

  @override
  Widget build(BuildContext context) {
    final track = context.select<LooperBloc, Track?>(
      (bloc) => bloc.state.tracks.cast<Track?>().firstWhere(
        (t) => t?.channel == channel,
        orElse: () => null,
      ),
    );
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
      child: Align(
        alignment: Alignment.bottomCenter,
        child: TrackColumn(
          track: track,
          name: name,
          selected: selected,
          mode: mode,
          onUndo: onUndo,
          onRedo: onRedo,
          looperMode: looperMode,
          isPrimary: isPrimary,
          onCrownPrimary: onCrownPrimary,
        ),
      ),
    );
  }
}
