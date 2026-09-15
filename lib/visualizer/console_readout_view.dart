import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/track_column.dart' show PrimaryCrown;
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// The console's 7" second screen (the accepted design): it follows the
/// selected track — number, crown, name, then the state word and the bar
/// count over the track's own waveform — with the tempo and the current
/// function · bank as a secondary footer. A readout: nothing here takes a
/// tap, and encoder focus stays on the main display.
///
/// **Proportional, not absolute.** The prototype draws the screen at 1280×720,
/// but the device window's logical size depends on the compositor scale.
/// Every dimension here is the prototype's figure times the limiting-axis
/// scale against that reference, so the layout is the design's at any logical
/// size — the proportions are the contract, not the pixels.
class ConsoleReadoutView extends StatelessWidget {
  /// Creates a [ConsoleReadoutView].
  const ConsoleReadoutView({
    required this.readout,
    required this.waveform,
    super.key,
  });

  /// Live state pushed from the main window.
  final PerformanceReadout readout;

  /// The selected track's waveform region, injected so this widget stays pure
  /// presentation (the window wires the frame stream into it).
  final Widget waveform;

  /// The reference frame's size — what every dimension is drawn against.
  static const Size referenceSize = Size(1280, 720);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : referenceSize.width;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : referenceSize.height;
        // The limiting axis sets the scale: the 7" panel is a touch narrower
        // than 16:9 (1024x600 is 1.71:1), so a height-only scale would run
        // the header off the right edge. The freed height on such a panel
        // goes to the waveform, which is elastic by design.
        final s = (width / referenceSize.width < height / referenceSize.height)
            ? width / referenceSize.width
            : height / referenceSize.height;
        final selected = readout.selected;
        return Padding(
          // The reference insets the screen 49 at the sides and 45 above.
          padding: EdgeInsets.fromLTRB(49 * s, 45 * s, 49 * s, 40 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(selected: selected, s: s),
              SizedBox(height: 26 * s),
              _StateLine(selected: selected, s: s),
              // The stage's one standing loss condition — the audio interface
              // is gone — echoed here because the performer is looking down,
              // not at the main screen (`c/device-lost`, #453).
              if (readout.deviceLost) ...[
                SizedBox(height: 16 * s),
                _ConnectivityEcho(
                  key: const Key('console_readout_deviceLost'),
                  s: s,
                ),
              ],
              SizedBox(height: 24 * s),
              Expanded(
                child: KeyedSubtree(
                  key: const Key('console_readout_waveform'),
                  child: waveform,
                ),
              ),
              SizedBox(height: 28 * s),
              _Footer(readout: readout, s: s),
            ],
          ),
        );
      },
    );
  }
}

/// `1  ♛  Acoustic rhythm guitar` — the number in the muted blue-grey, the
/// crown only when the selected track is primary, the name in the display
/// face.
class _Header extends StatelessWidget {
  const _Header({required this.selected, required this.s});

  final ReadoutTrack? selected;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final track = selected;
    if (track == null) {
      return SizedBox(
        height: 64 * s,
        child: AppText(
          l10n.a11yReadoutNoTrack,
          key: const Key('console_readout_noTrack'),
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textMuted,
            fontSize: 40 * s,
            height: 1,
          ),
        ),
      );
    }
    final name = track.defaultName
        ? l10n.defaultTrackName(track.channel + 1)
        : track.name;
    return Row(
      children: [
        AppText(
          '${track.channel + 1}',
          key: const Key('console_readout_number'),
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textSecondary,
            fontSize: 64 * s,
            height: 1,
          ),
        ),
        SizedBox(width: 24 * s),
        if (track.primary) ...[
          PrimaryCrown(key: const Key('console_readout_crown'), size: 42 * s),
          SizedBox(width: 24 * s),
        ],
        Expanded(
          child: AppText(
            name,
            key: const Key('console_readout_name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textPrimary,
              fontSize: 48 * s,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

/// `Playing` in the state's colour at the leading edge, `2 bars` at the
/// trailing edge — the one place a routine state word is shown, because the
/// small display has no meter fill to carry the state by colour alone.
class _StateLine extends StatelessWidget {
  const _StateLine({required this.selected, required this.s});

  final ReadoutTrack? selected;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final looper = Theme.of(context).extension<LooperTheme>()!;
    final l10n = context.l10n;
    final track = selected;
    final state = readoutMeterStateOf(track);
    final word = switch (state) {
      LooperMeterState.empty => l10n.readoutStateEmpty,
      LooperMeterState.recording => l10n.readoutStateRecording,
      LooperMeterState.overdubbing => l10n.readoutStateOverdubbing,
      LooperMeterState.playing => l10n.readoutStatePlaying,
      LooperMeterState.stopped => l10n.readoutStateStopped,
      LooperMeterState.muted => l10n.readoutStateMuted,
    };
    // The sounding states take the transport legend's colour; the quiet ones
    // the secondary text tone, never the meter's white, which is a fill
    // colour and not a text colour.
    final color = switch (state) {
      LooperMeterState.recording ||
      LooperMeterState.overdubbing ||
      LooperMeterState.playing => looper.waveformColor(state),
      LooperMeterState.stopped ||
      LooperMeterState.muted => surface.textSecondary,
      LooperMeterState.empty => surface.textMuted,
    };
    final bars = track?.bars ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        AppText(
          track == null ? '' : word,
          key: const Key('console_readout_state'),
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: color,
            fontSize: 32 * s,
            height: 1,
          ),
        ),
        const Spacer(),
        if (bars > 0)
          AppText(
            l10n.stageBarsFigure(bars),
            key: const Key('console_readout_bars'),
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textSecondary,
              fontSize: 32 * s,
              height: 1,
            ),
          ),
      ],
    );
  }
}

/// `84 BPM  4/4` at the leading edge; `Tracks · Bank A` at the trailing
/// edge — tempo and the current function/bank stay secondary here.
class _Footer extends StatelessWidget {
  const _Footer({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final bpm = readout.hasTempo ? readoutTempo(readout.tempoBpm) : '—';
    final function = switch (readout.mode) {
      'mute' => l10n.readoutFunctionMute,
      'fx' => l10n.readoutFunctionFx,
      _ => l10n.readoutFunctionTracks,
    };
    final bank = String.fromCharCode(0x41 + readout.activeBank);
    final secondary = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textSecondary,
      fontSize: 28 * s,
      height: 1,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        AppText(
          bpm,
          key: const Key('console_readout_tempo'),
          style: TextStyle(
            fontFamily: SurfaceTheme.monoFont,
            color: surface.textPrimary,
            fontSize: 40 * s,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
        SizedBox(width: 10 * s),
        AppText(
          l10n.stageBpmUnit,
          style: secondary.copyWith(fontSize: 22 * s),
        ),
        SizedBox(width: 30 * s),
        AppText(
          '${readout.tsNum}/${readout.tsDen}',
          key: const Key('console_readout_signature'),
          style: secondary,
        ),
        const Spacer(),
        AppText(
          l10n.readoutFunctionBank(function, bank),
          key: const Key('console_readout_function'),
          style: secondary.copyWith(color: surface.textPrimary),
        ),
      ],
    );
  }
}

/// The device-lost line, in readout-scale type: the pen's `c/device-lost`
/// idiom echoed on the small display. No action — the readout stays inert.
class _ConnectivityEcho extends StatelessWidget {
  const _ConnectivityEcho({required this.s, super.key});

  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20 * s, vertical: 12 * s),
      decoration: BoxDecoration(
        color: surface.recSurface,
        borderRadius: BorderRadius.circular(10 * s),
        border: Border.all(color: surface.rec),
      ),
      child: AppText(
        context.l10n.deviceLostBanner,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: SurfaceTheme.displayFont,
          color: surface.textPrimary,
          fontSize: 24 * s,
          height: 1.2,
        ),
      ),
    );
  }
}

/// The tempo figure the readout prints: whole when the tempo is whole,
/// otherwise one decimal — `84` and `84.5`, never `84.0`.
String readoutTempo(double bpm) {
  final rounded = bpm.roundToDouble();
  return (bpm - rounded).abs() < 0.05
      ? rounded.toInt().toString()
      : bpm.toStringAsFixed(1);
}

/// The transport legend state of [track] — its `TrackState` token with muted
/// overlaying it — or `empty` when nothing is selected or the token is one
/// this build does not know: the readout crosses an engine boundary as
/// strings, and an unrecognised one must degrade to the quiet "nothing to
/// show" tone rather than throw on a render.
LooperMeterState readoutMeterStateOf(ReadoutTrack? track) {
  if (track == null) return LooperMeterState.empty;
  final state = _trackStatesByName[track.state];
  if (state == null) return LooperMeterState.empty;
  return LooperMeterState.of(state, muted: track.muted);
}

/// `TrackState` by its wire token. Hoisted because [readoutMeterStateOf] runs
/// once per pushed frame — rebuilding the map there would allocate at frame
/// rate to answer a five-entry lookup.
final Map<String, TrackState> _trackStatesByName = TrackState.values
    .asNameMap();
