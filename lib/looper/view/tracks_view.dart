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
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/stage_status_bar.dart';
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
/// The chrome ([StageStatusBar], [AudioNotRunningBanner]) and each
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

    // When the engine is stopped *because* the pinned interface is gone, the
    // device-lost banner below is the one true statement of it — so the
    // generic "engine stopped" affordance is suppressed while the loss
    // condition holds, and the stage never says it twice (#453). A stopped
    // engine with a device still present keeps the generic banner.
    final deviceLost = context.select<AudioSetupCubit, bool>(
      (cubit) => cubit.state.deviceConnectivity == DeviceConnectivity.lost,
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
                          child: Padding(
                            // Console/kiosk mode hides the on-screen toolbar
                            // (the foot pedals drive transport/mode/clear) and
                            // tightens the layout for the fixed panel; desktop
                            // builds keep the full chrome.
                            // The pen's `STAGE / stage` insets the run 10 from
                            // the left, right and bottom. The status bar's own
                            // 8 from the top now sits on the shadow Container
                            // below, so the shadow is cast from the stage edge
                            // rather than from 8 inside it.
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  // `dropShadow`, not the hex it happens to
                                  // equal in neon: the high-contrast variant
                                  // deepens it to 0xCC so the status bar keeps
                                  // separating from the stage, exactly as the
                                  // tray sheet's shadow does.
                                  decoration: BoxDecoration(
                                    boxShadow: [
                                      BoxShadow(
                                        color: context.surface.dropShadow,
                                        offset: const Offset(0, -19),
                                        blurRadius: 48,
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.only(top: 8),
                                  child: const StageStatusBar(),
                                ),
                                const SizedBox(height: 10),
                                // Standing loss conditions hold the stage
                                // for as long as they are true — the pen's
                                // `STAGE / device-lost`, at the run's top. The
                                // widget
                                // carries its own bottom gap, so an empty
                                // stack adds no space here.
                                const ConnectivityBanners(),
                                // With no first-run gate, a stopped engine
                                // lands here; a full-width affordance opens
                                // settings to (re)start it. Suppressed while
                                // the device-lost banner above already states
                                // the stop, so the two never stack (#453).
                                if (!chrome.isConnected && !deviceLost) ...[
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
                                    spacing: 10,
                                    children: [
                                      // _TrackSlot supplies its own Expanded,
                                      // so a slot with no track takes no flex
                                      // and its siblings widen -- matching what
                                      // the old `for (track in state.tracks)`
                                      // did by simply emitting fewer children.
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
                                            looperMode: chrome.looperMode,
                                            isPrimary:
                                                channel == chrome.primaryTrack,
                                            onCrownPrimary:
                                                commands.crownPrimary,
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
    required this.looperMode,
    required this.isPrimary,
    required this.onCrownPrimary,
  });

  final int channel;
  final String name;
  final bool selected;
  final InteractionMode mode;
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
          looperMode: looperMode,
          isPrimary: isPrimary,
          onCrownPrimary: onCrownPrimary,
        ),
      ),
    );
  }
}
