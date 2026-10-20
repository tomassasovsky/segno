import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/widgets/waveform_view.dart';

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
WaveformFrame waveformFrameFrom(
  Map<Object?, Object?> payload,
  WaveformFrame previous,
) {
  final progress = payload['progress'];
  final selectedTrack = payload['selectedTrack'];
  final samples = payload['samples'];
  return (
    // `is Float32List` covers the absent key and the garbled value in one
    // test: a frame with no `samples` is the ordinary progress-only push, and
    // one carrying something that is not a buffer is a frame that arrived
    // damaged. Both hold what is on screen.
    samples: samples is Float32List ? samples : previous.samples,
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

/// The root widget of the waveform window: the selected-track readout
/// ([ConsoleReadoutView]) over a [WaveformView] driven by frames pushed from
/// the main window — stage-sized type legible from the floor, full-bleed
/// because the 7" panel is a panel, not a window.
class WaveformWindowApp extends StatelessWidget {
  /// Creates a [WaveformWindowApp] rendering [frame].
  const WaveformWindowApp({
    required this.frame,
    required this.readout,
    this.onActivity = _noActivity,
    super.key,
  });

  /// Default [onActivity]: drops the touch, for hosts that wire nothing.
  static void _noActivity() {}

  /// The latest waveform frame, updated as the main window pushes new data.
  final ValueListenable<WaveformFrame> frame;

  /// The latest performance readout, pushed only when it changes.
  final ValueListenable<PerformanceReadout> readout;

  /// Called when a player touches the readout; the readout screen sends it to
  /// the main screen over the screen link.
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    // Real localization delegates, not a one-off `lookupAppLocalizations`
    // against the platform locale: the readout has real copy in it now, and a
    // second engine is still an app.
    // A touch on the Track display is activity: it wakes an idle-dimmed
    // console. Nothing here is pressable, so the waking touch needs no
    // barrier of its own.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onActivity(),
      child: _app(),
    );
  }

  Widget _app() {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppTextDefaults(child: child ?? const SizedBox.shrink()),
      // The Scaffold supplies the Material ancestor (the same job TracksView's
      // Scaffold does in the main window): without it the readout renders
      // bare, in the unthemed fallback style (yellow double-underlined text)
      // once seen live on the appliance's 7".
      home: Scaffold(
        body: ValueListenableBuilder<PerformanceReadout>(
          valueListenable: readout,
          builder: (context, readoutData, _) {
            final selected = readoutData.selected;
            final waveform = ValueListenableBuilder<WaveformFrame>(
              valueListenable: frame,
              builder: (context, data, _) => WaveformView(
                samples: data.samples,
                progress: data.progress,
                bars: selected?.bars ?? 0,
                state: readoutMeterStateOf(selected),
                semanticLabel: selected == null
                    ? context.l10n.a11yReadoutNoTrack
                    : context.l10n.a11ySelectedTrackWaveform(
                        data.selectedTrack,
                      ),
              ),
            );
            // Full-bleed: the console view carries its own inset. Dimmed
            // as its panel is set when the panel cannot dim itself.
            final face = SoftwareBrightness(
              brightness: readoutData.brightness,
              child: ConsoleReadoutView(
                readout: readoutData,
                waveform: waveform,
              ),
            );
            if (readoutData.goodbye != ReadoutGoodbye.mark) return face;
            return Stack(
              fit: StackFit.expand,
              children: [
                face,
                const PowerGoodbye(face: ReadoutGoodbye.mark),
              ],
            );
          },
        ),
      ),
    );
  }
}
