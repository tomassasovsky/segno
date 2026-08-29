import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/console_volume_overlay.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';
import 'package:segno/visualizer/waveform_window_args.dart';
import 'package:segno/visualizer/waveform_window_channel.dart';
import 'package:segno/visualizer/widgets/waveform_view.dart';
import 'package:segno/window/window_chrome.dart';
import 'package:window_manager/window_manager.dart';

/// Where the output-waveform window should sit: **full-bleed on a secondary
/// display** when one is present (the intended second-screen setup), else the
/// windowed fallback from [args]. Pure over the screen list so it can be
/// unit-tested without a real multi-monitor desktop.
///
/// Each screen's `position`/`size` arrive in that display's **own** logical
/// pixels (how `screen_retriever` reports them) with its DPI `scale`. The
/// result is returned in the **primary window's** logical space — what
/// `window_manager.setBounds` expects for the primary-hosted sub-window — by
/// rescaling with `scale / primaryScale`. Skipping this drops a secondary at a
/// different DPI than the primary onto the wrong place: e.g. a 4K@175% display
/// whose physical origin is x=2560 is reported at own-logical x=1463, a point
/// *inside* a 100%-scaled primary, so the window lands mid-primary.
///
/// The secondary is found by id — macOS/Windows report distinct display ids.
/// On Linux `screen_retriever_linux` hardcodes every display's id to `""`
/// (its plugin.cc), so the loop never matches and the window opens with the
/// windowed fallback — **deliberately**. On the appliance that is correct:
/// weston's kiosk-shell fullscreens every surface and routes it to the output
/// whose `app-ids` list names it (the embedder tags this window
/// `<APPLICATION_ID>.waveform`, weston.ini pins that to HDMI-A-2), overriding
/// whatever geometry the window asks for. And on a non-kiosk Linux desktop
/// there is no trustworthy signal to place by: GDK's "primary" is just
/// monitor 0, arbitrary under Wayland, so guessing a secondary from geometry
/// can full-bleed the readout over the *main* display.
@visibleForTesting
({Offset position, Size size, bool fullscreen}) waveformWindowPlacement({
  required List<({String id, Offset position, Size size, double scale})>
  screens,
  required String primaryId,
  required double primaryScale,
  required WaveformWindowArgs args,
}) {
  for (final screen in screens) {
    if (screen.id != primaryId) {
      final k = screen.scale / primaryScale;
      return (
        position: screen.position * k,
        size: screen.size * k,
        fullscreen: true,
      );
    }
  }
  return (
    position: Offset(args.x, args.y),
    size: Size(args.width, args.height),
    fullscreen: false,
  );
}

/// Resolves [waveformWindowPlacement] against the live displays, falling back
/// to the windowed layout if the display query fails (never leave the output
/// window unplaced).
Future<({Offset position, Size size, bool fullscreen})> _resolvePlacement(
  WaveformWindowArgs args,
) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();
    return waveformWindowPlacement(
      screens: [
        for (final d in displays)
          (
            id: d.id,
            position: d.visiblePosition ?? Offset.zero,
            size: d.size,
            scale: d.scaleFactor?.toDouble() ?? 1.0,
          ),
      ],
      primaryId: primary.id,
      primaryScale: primary.scaleFactor?.toDouble() ?? 1.0,
      args: args,
    );
  } on Object {
    return (
      position: Offset(args.x, args.y),
      size: Size(args.width, args.height),
      fullscreen: false,
    );
  }
}

/// A loop waveform frame pushed from the main window: the loop peaks plus the
/// playhead position.
typedef WaveformFrame = ({
  Float32List samples,
  double progress,
  String selectedTrack,
});

/// Merges an incoming `waveform` [payload] onto the [previous] frame.
///
/// A payload with no `samples` key is a **progress-only push**: the main
/// window sends the peaks only when they change (see `waveformFramePayload`),
/// because through steady playback the loop-indexed buffer stands still and
/// only the playhead moves. Carrying [previous]'s samples forward is what
/// makes that safe — reading an absent key as an empty buffer would blank the
/// waveform on every frame the peaks did not change, which is most of them.
///
/// Pure so the hold can be proven without a second engine.
@visibleForTesting
WaveformFrame waveformFrameFrom(
  Map<Object?, Object?> payload,
  WaveformFrame previous,
) {
  final progress = payload['progress'];
  final selectedTrack = payload['selectedTrack'];
  return (
    samples: payload.containsKey('samples')
        ? _toFloat32List(payload['samples'])
        : previous.samples,
    // Every field degrades to what is already on screen rather than throwing
    // OR resetting: this crosses an engine boundary as a loose map, and a
    // malformed frame must neither take the second screen down mid-set nor
    // snap the playhead back to the loop start. Hence `is num` / `is String`
    // rather than casts — a present-but-wrong value is the shape a garbled
    // frame actually takes; an absent key is the easy case.
    progress: progress is num ? progress.toDouble() : previous.progress,
    selectedTrack: selectedTrack is String
        ? selectedTrack
        : previous.selectedTrack,
  );
}

/// Entrypoint for the secondary waveform window — a separate Flutter engine
/// spawned by `desktop_multi_window`. It owns no audio engine; the main window
/// pushes `waveform` frames to it over [waveformWindowChannel].
Future<void> runWaveformWindow(WindowController controller) async {
  WidgetsFlutterBinding.ensureInitialized();

  final args = WaveformWindowArgs.parse(controller.arguments);
  final title = args.title ?? 'Segno — Output';
  final frame = ValueNotifier<WaveformFrame>(
    (samples: Float32List(0), progress: 0, selectedTrack: ''),
  );
  final readout = ValueNotifier<PerformanceReadout>(
    const PerformanceReadout(),
  );

  // Register the shared channel before any slow init so the main window can
  // reach us as soon as [WindowController.create] returns.
  await waveformWindowChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'waveform':
        if (call.arguments is Map) {
          frame.value = waveformFrameFrom(call.arguments as Map, frame.value);
        }
        return null;
      case 'readout':
        if (call.arguments is Map) {
          readout.value = PerformanceReadout.fromMap(
            call.arguments as Map<Object?, Object?>,
          );
        }
        return null;
      case 'window_close':
        await windowManager.close();
        return null;
      default:
        return null;
    }
  });

  // Tell the main window the channel handler is live.
  await waveformWindowChannel
      .invokeMethod(waveformWindowReadyMethod)
      .catchError((Object _) => null);

  await windowManager.ensureInitialized();
  await configureSegnoDesktopWindow(title: title);

  // Full-bleed on a second monitor when there is one; otherwise the windowed
  // fallback. Two ordering rules make this land on the *second* display:
  //   1. Move the window onto the target display only *after* it is realized
  //      (`show`). A `setBounds` issued while the sub-window is still hidden is
  //      dropped by the Windows layer, so the later `setFullScreen` would fill
  //      whichever monitor the window defaulted to (the primary).
  //   2. `setFullScreen` *after* the move: the OS then fills the monitor the
  //      window is on at its native resolution — which also sidesteps
  //      window_manager scaling the size by the target display's DPI.
  final placement = await _resolvePlacement(args);
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: placement.size,
      title: title,
      // The OS window's pre-paint colour. Matches AppTheme.neon's scaffold
      // background so opening the window does not flash a different dark —
      // it cannot read the theme, since it is set before runApp.
      backgroundColor: const Color(0xFF060607),
    ),
    () async {
      await windowManager.show();
      await windowManager.setBounds(
        null,
        position: placement.position,
        size: placement.size,
      );
      if (placement.fullscreen) {
        await windowManager.setFullScreen(true);
      }
    },
  );

  runApp(
    WaveformWindowApp(
      frame: frame,
      readout: readout,
      title: title,
      // The overlay's commands go straight back over the shared channel —
      // fire-and-forget like every push in the other direction, because a
      // dropped fader move is corrected by the next one.
      onControl: (control) => unawaited(
        waveformWindowChannel
            .invokeMethod(waveformWindowControlMethod, control.toMap())
            .catchError((Object _) => null),
      ),
    ),
  );
}

/// The waveform's colour state for [readout]: the cursor track's transport
/// state, with muted overlaying it — the same legend the meters use, keyed off
/// the same track whose name the waveform already labels itself with.
///
/// Pure so the second screen's colouring can be tested without a window. Falls
/// back to [LooperMeterState.empty] when no track is selected, or when the
/// state token is one this build does not know: the readout crosses an engine
/// boundary as strings, and an unrecognised one must degrade to the quiet
/// "nothing to show" tone rather than throw on a render.
@visibleForTesting
LooperMeterState waveformStateOf(PerformanceReadout readout) {
  for (final track in readout.tracks) {
    if (!track.selected) continue;
    final state = _trackStatesByName[track.state];
    if (state == null) return LooperMeterState.empty;
    return LooperMeterState.of(state, muted: track.muted);
  }
  return LooperMeterState.empty;
}

/// [TrackState] by its wire token. Hoisted out of [waveformStateOf] because
/// that runs once per pushed frame — rebuilding the map there would allocate at
/// frame rate to answer a five-entry lookup.
final Map<String, TrackState> _trackStatesByName = TrackState.values
    .asNameMap();

/// Coerces a method-channel payload (a [Float32List], or a `List` of numbers
/// after the plugin re-serializes across engines) into a [Float32List].
Float32List _toFloat32List(Object? raw) {
  if (raw is Float32List) return raw;
  if (raw is List) {
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      out[i] = v is num ? v.toDouble() : 0.0;
    }
    return out;
  }
  return Float32List(0);
}

/// The root widget of the waveform window: a full-screen [WaveformView] driven
/// by frames pushed from the main window.
///
/// The waveform fills the fixed 7" panel with the pen's `STAGE / readout`
/// ([ConsoleReadoutView]) — stage-sized type legible from the floor,
/// full-bleed because the panel is a panel, not a window.
class WaveformWindowApp extends StatelessWidget {
  /// Creates a [WaveformWindowApp] rendering [frame].
  const WaveformWindowApp({
    required this.frame,
    required this.readout,
    required this.title,
    this.onControl = _dropControl,
    super.key,
  });

  /// Default [onControl]: drops the command, for hosts that wire nothing.
  static void _dropControl(ReadoutControl control) {}

  /// The latest waveform frame, updated as the main window pushes new data.
  final ValueListenable<WaveformFrame> frame;

  /// The latest performance readout, pushed only when it changes.
  final ValueListenable<PerformanceReadout> readout;

  /// OS window title.
  final String title;

  /// Sends a volume-overlay control command back to the main window (#698).
  /// The entrypoint wires this to the window channel; tests capture it.
  final ValueChanged<ReadoutControl> onControl;

  @override
  Widget build(BuildContext context) {
    // Real localization delegates, not a one-off `lookupAppLocalizations`
    // against the platform locale: the readout has real copy in it now, and a
    // second engine is still an app.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppTextDefaults(child: child ?? const SizedBox.shrink()),
      // The Scaffold supplies the Material ancestor (the same job TracksView's
      // Scaffold does in the main window): SegnoWindowChromeShell only mounts
      // its own Scaffold on the Windows title-bar path, so without this the
      // readout renders bare on Linux/macOS — the unthemed fallback style
      // (yellow double-underlined text) seen live on the appliance's 7".
      home: SegnoWindowChromeShell(
        title: title,
        body: Scaffold(
          body: ValueListenableBuilder<PerformanceReadout>(
            valueListenable: readout,
            builder: (context, readoutData, _) {
              final waveform = ValueListenableBuilder<WaveformFrame>(
                valueListenable: frame,
                builder: (context, data, _) => WaveformView(
                  selectedTrack: data.selectedTrack,
                  samples: data.samples,
                  progress: data.progress,
                  state: waveformStateOf(readoutData),
                  semanticLabel: context.l10n.a11yWaveform,
                ),
              );
              // Full-bleed: the console view carries the pen's own inset.
              // The overlay owns the pages; the readout face's MIX pill is the
              // only way into it (#698, entry reworked in #707).
              return ConsoleVolumeOverlay(
                readout: readoutData,
                onControl: onControl,
                builder: (context, openMixer) => ConsoleReadoutView(
                  readout: readoutData,
                  waveform: waveform,
                  onMix: openMixer,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
