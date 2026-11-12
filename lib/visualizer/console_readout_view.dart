import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/track_column.dart' show PrimaryCrown;
import 'package:segno/notices/model/notice.dart' show NoticeTone;
import 'package:segno/notices/view/notice_palette.dart';
import 'package:segno/notices/view/notice_sentence.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_panel/readout_button.dart';
import 'package:segno/visualizer/readout_panel/readout_labels.dart';

/// The console's 7" second screen (the accepted design): it follows the
/// selected track — number, crown, name, then the state word and the bar
/// count over the track's own waveform — with the tempo, the length and
/// start of the next take and the current function · bank in a footer strip.
/// The strip is the one thing here that takes a touch: it opens the Loop
/// panel (#1654). Encoder focus stays on the main display.
///
/// **Proportional, not absolute.** The prototype draws the screen at 1280×720,
/// but the view's logical size depends on its `pixel_ratio` in
/// homescreen.toml.
/// Every dimension here is the prototype's figure times the limiting-axis
/// scale against that reference, so the layout is the design's at any logical
/// size — the proportions are the contract, not the pixels.
class ConsoleReadoutView extends StatelessWidget {
  /// Creates a [ConsoleReadoutView].
  const ConsoleReadoutView({
    required this.readout,
    required this.waveform,
    this.onOpenControls,
    super.key,
  });

  /// Live state pushed from the main window.
  final PerformanceReadout readout;

  /// The selected track's waveform region, injected so this widget stays pure
  /// presentation (the window wires the frame stream into it).
  final Widget waveform;

  /// Opens the Loop panel; null leaves the footer strip inert.
  final VoidCallback? onOpenControls;

  /// The reference frame's size — what every dimension is drawn against.
  static const Size referenceSize = Size(1280, 720);

  /// The reference's inset at the sides.
  static const double sideInset = 49;

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
        final content = Padding(
          // The reference insets the screen 49 at the sides and 45 above.
          padding: EdgeInsets.fromLTRB(
            sideInset * s,
            45 * s,
            sideInset * s,
            40 * s,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(selected: selected, s: s),
              SizedBox(height: 26 * s),
              _StateLine(selected: selected, s: s),
              SizedBox(height: 24 * s),
              Expanded(
                child: KeyedSubtree(
                  key: const Key('console_readout_waveform'),
                  child: waveform,
                ),
              ),
              SizedBox(height: 28 * s),
              _Footer(readout: readout, s: s, onTap: onOpenControls),
            ],
          ),
        );
        final notice = readout.notice;
        if (notice == null) return content;
        return Stack(
          children: [
            content,
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: _NoticeBand(notice: notice, s: s),
            ),
          ],
        );
      },
    );
  }
}

/// The main screen's message across the readout's top margin (#1562): the
/// tone's tint and rule, the dot or icon, and the sentence. A one-line
/// sentence fills the margin and no more; a longer one, whose detail the top
/// bar had no room for, is said whole over the readout below. Nothing on the
/// readout moves for it, and it takes no touch: the readout stays inert.
class _NoticeBand extends StatelessWidget {
  const _NoticeBand({required this.notice, required this.s});

  final ReadoutNotice notice;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final colors = NoticePalette.of(surface, notice.tone);
    final text = theme.readoutText.copyWith(
      fontSize: theme.readoutText.fontSize! * s,
    );
    final icon = noticeToneIcon(notice.tone);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('console_readout_notice'),
        // The top margin's height for one line; a sentence too long for one
        // line grows the band over the readout below, for as long as the
        // message is up, so it is said whole (#1562).
        constraints: BoxConstraints(minHeight: theme.readoutBandHeight * s),
        padding: EdgeInsets.symmetric(
          horizontal: ConsoleReadoutView.sideInset * s,
          vertical: context.spacing.xs * s,
        ),
        decoration: BoxDecoration(
          color: colors.tint,
          border: Border(
            bottom: BorderSide(
              color: colors.line,
              width: theme.ruleThickness * s,
            ),
          ),
        ),
        child: AppTextOptics(
          opticalOffset: Offset.zero,
          child: Row(
            children: [
              // The tone's marks: its icon, the dot for a critical message,
              // nothing for the rest. A notice's own icon stays on the main
              // bar; the screen link carries the tone, not glyphs.
              if (icon != null) ...[
                Icon(icon, size: text.fontSize, color: colors.mark),
                SizedBox(width: spacing.lg * s),
              ] else if (notice.tone == NoticeTone.critical) ...[
                DecoratedBox(
                  key: const Key('console_readout_notice_dot'),
                  decoration: BoxDecoration(
                    color: colors.mark,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(dimension: theme.readoutDotSize * s),
                ),
                SizedBox(width: spacing.lg * s),
              ],
              Flexible(
                child: NoticeSentence(
                  key: const Key('console_readout_notice_text'),
                  scale: s,
                  wraps: true,
                  title: notice.title,
                  titleStyle: text.copyWith(color: surface.textPrimary),
                  body: notice.body,
                  bodyStyle: text.copyWith(
                    color: surface.textSecondary,
                    fontWeight: FontWeight.w400,
                  ),
                  source: notice.track,
                  sourceStyle: text.copyWith(color: surface.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
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

/// `84 BPM  4/4 · 4 bars · Start 1 bar` at the leading edge, `Tracks ·
/// Bank A` at the trailing edge, in a strip that is one touch target: it
/// opens the Loop panel (#1654). The facts stay secondary here, sized to the
/// reference like the rest of the readout; the strip never goes under the
/// 48 px a finger needs.
class _Footer extends StatelessWidget {
  const _Footer({required this.readout, required this.s, this.onTap});

  final PerformanceReadout readout;
  final double s;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final bpm = readout.hasTempo ? readoutTempo(readout.tempoBpm) : '—';
    final function = switch (readout.mode) {
      'mute' => l10n.readoutFunctionMute,
      'fx' => l10n.readoutFunctionFx,
      'custom' => l10n.readoutFunctionCustom,
      _ => l10n.readoutFunctionTracks,
    };
    final bank = String.fromCharCode(0x41 + readout.activeBank);
    final secondary = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textSecondary,
      fontSize: 28 * s,
      height: 1,
    );
    final loop = readout.loop;
    final dot = AppText(
      ' · ',
      style: secondary.copyWith(color: surface.textMuted),
    );
    final facts = Row(
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
        // What the selected track's next take uses: its own value when it
        // has one. Nothing until the owners have loaded, rather than the
        // fallbacks.
        if (loop.ready) ...[
          dot,
          AppText(
            readoutLengthLabel(l10n, loop.trackLengthBars ?? loop.lengthBars),
            key: const Key('console_readout_length'),
            style: secondary,
          ),
          dot,
          AppText(
            l10n.readoutStripStart(
              readoutTimingLabel(l10n, loop.trackTiming ?? loop.timing),
            ),
            key: const Key('console_readout_start'),
            style: secondary,
          ),
        ],
      ],
    );
    // The facts give way first: on a narrow panel they scale down rather
    // than run under the function and bank, which keep the trailing edge
    // and scale down only past two fifths of the strip.
    final content = LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(fit: BoxFit.scaleDown, child: facts),
            ),
          ),
          SizedBox(width: 24 * s),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AppText(
                l10n.readoutFunctionBank(function, bank),
                key: const Key('console_readout_function'),
                style: secondary.copyWith(color: surface.textPrimary),
              ),
            ),
          ),
          SizedBox(width: 20 * s),
          Icon(
            LucideIcons.slidersHorizontal,
            size: 32 * s,
            color: surface.textSecondary,
          ),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: onTap == null ? null : l10n.readoutPanelOpen,
      onTap: onTap,
      child: Material(
        key: const Key('console_readout_strip'),
        color: surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16 * s),
          side: BorderSide(color: surface.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: math.max(kReadoutMinTarget, 110 * s),
            padding: EdgeInsets.symmetric(horizontal: 24 * s),
            alignment: Alignment.centerLeft,
            child: content,
          ),
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
