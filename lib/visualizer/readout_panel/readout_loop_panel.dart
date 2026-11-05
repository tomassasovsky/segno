import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart'
    show RecordTiming, TempoFollowState;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/looper/view/track_column.dart' show PrimaryCrown;
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_command.dart';
import 'package:segno/visualizer/readout_panel/readout_button.dart';
import 'package:segno/visualizer/readout_panel/readout_labels.dart';
import 'package:segno/visualizer/readout_panel/readout_tempo_keypad.dart';
import 'package:segno/visualizer/waveform_window.dart';
import 'package:segno/visualizer/widgets/waveform_view.dart';

/// The signatures the panel offers in one touch; More shows all 17.
const List<(int, int)> kReadoutQuickSignatures = [(3, 4), (4, 4), (6, 8)];

/// The readout's Loop panel (#1654, layout B): every tempo, signature,
/// length and record timing control on one screen of the 7", with the
/// track, its state and a small waveform kept in view at the top.
///
/// It only asks: each control sends a [ReadoutCommand] and shows what the
/// next readout push says the rig accepted. Locks dim a control and say why
/// rather than hide it.
class ReadoutLoopPanel extends StatefulWidget {
  /// Creates a [ReadoutLoopPanel].
  const ReadoutLoopPanel({
    required this.readout,
    required this.frame,
    required this.onCommand,
    required this.onDone,
    super.key,
  });

  /// What the main screen last pushed.
  final PerformanceReadout readout;

  /// The selected track's waveform and playhead.
  final ValueListenable<WaveformFrame> frame;

  /// Sends a change to the main screen.
  final ValueChanged<ReadoutCommand> onCommand;

  /// Closes the panel.
  final VoidCallback onDone;

  /// How long a length the panel sent stands in for the pushed one: the
  /// push that carries it is a few frames behind a fast second press.
  static const Duration lengthDraftFor = Duration(seconds: 1);

  @override
  State<ReadoutLoopPanel> createState() => _ReadoutLoopPanelState();
}

class _ReadoutLoopPanelState extends State<ReadoutLoopPanel> {
  bool _allSignatures = false;
  bool _keypad = false;
  int? _lengthDraft;
  Timer? _lengthDraftTimer;

  @override
  void didUpdateWidget(ReadoutLoopPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.readout.loop.lengthBars == _lengthDraft) _clearLengthDraft();
    // A lock that lands while the keypad is up takes it down: Set could
    // only be refused.
    if (_keypad && !readoutTempoEditable(widget.readout)) _keypad = false;
  }

  @override
  void dispose() {
    _lengthDraftTimer?.cancel();
    super.dispose();
  }

  void _clearLengthDraft() {
    _lengthDraftTimer?.cancel();
    _lengthDraftTimer = null;
    _lengthDraft = null;
  }

  void _setLength(int bars) {
    widget.onCommand(LengthSet(bars));
    setState(() => _lengthDraft = bars);
    _lengthDraftTimer?.cancel();
    _lengthDraftTimer = Timer(ReadoutLoopPanel.lengthDraftFor, () {
      if (mounted) setState(_clearLengthDraft);
    });
  }

  void _setSignature(int num, int den) {
    widget.onCommand(SignatureSet(num, den));
    if (_allSignatures) setState(() => _allSignatures = false);
  }

  @override
  Widget build(BuildContext context) {
    final readout = widget.readout;
    final surface = context.surface;
    final recording = readout.loop.captureLocked;
    final spacing = context.spacing;
    final panel = ColoredBox(
      key: const Key('readout_panel'),
      color: surface.background,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          spacing.lg,
          spacing.sm,
          spacing.lg,
          spacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelHeader(
              readout: readout,
              frame: widget.frame,
              onDone: widget.onDone,
            ),
            if (recording) ...[
              SizedBox(height: spacing.sm),
              const _RecordingBand(),
            ],
            SizedBox(height: spacing.sm),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 292,
                    child: _TempoCard(
                      readout: readout,
                      frame: widget.frame,
                      onCommand: widget.onCommand,
                      onTypeTempo: () => setState(() => _keypad = true),
                      recordingBand: recording,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 308,
                    child: _allSignatures
                        ? _SignatureGrid(
                            readout: readout,
                            onChosen: _setSignature,
                            onBack: () =>
                                setState(() => _allSignatures = false),
                          )
                        : _Choices(
                            readout: readout,
                            lengthBars: _lengthDraft ?? readout.loop.lengthBars,
                            onSignature: _setSignature,
                            onMoreSignatures: () =>
                                setState(() => _allSignatures = true),
                            onLength: _setLength,
                            onTiming: (timing) =>
                                widget.onCommand(TimingSet(timing)),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!_keypad) return panel;
    return Stack(
      fit: StackFit.expand,
      children: [
        panel,
        // The panel stays in view; a touch on it backs out of the keypad.
        ModalBarrier(
          color: surface.scrim.withValues(alpha: 0.5),
          onDismiss: () => setState(() => _keypad = false),
        ),
        Positioned(
          // The panel's own padding, so the keypad covers its content.
          top: spacing.sm,
          right: spacing.lg,
          bottom: spacing.sm,
          width: 424,
          child: ReadoutTempoKeypad(
            onSet: (bpm) {
              widget.onCommand(TempoSet(bpm));
              setState(() => _keypad = false);
            },
            onCancel: () => setState(() => _keypad = false),
          ),
        ),
      ],
    );
  }
}

/// Whether the tempo and Tap take a change now: not while a clock sets the
/// tempo, and not while the engine's tempo lock holds.
bool readoutTempoEditable(PerformanceReadout readout) =>
    !readout.clockOwnsTempo &&
    // A take holds the tempo as well; the owners can say so a push before
    // the engine does.
    !readout.loop.captureLocked &&
    (readout.tempoFollow == TempoFollowState.free ||
        readout.tempoFollow == TempoFollowState.retimes);

/// Whether the time signature takes a change now: only before the first
/// take, as on the RC-600.
bool readoutSignatureEditable(PerformanceReadout readout) =>
    !readout.loop.captureLocked && readout.tempoFollow == TempoFollowState.free;

/// `1 ♛ GUITAR`, then the state, the bars, a small waveform and Done.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.readout,
    required this.frame,
    required this.onDone,
  });

  final PerformanceReadout readout;
  final ValueListenable<WaveformFrame> frame;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final looper = Theme.of(context).extension<LooperTheme>()!;
    final l10n = context.l10n;
    final track = readout.selected;
    final state = readoutMeterStateOf(track);
    final title = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textPrimary,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      height: 1,
    );
    final word = switch (state) {
      LooperMeterState.empty => l10n.readoutStateEmpty,
      LooperMeterState.recording => l10n.readoutStateRecording,
      LooperMeterState.overdubbing => l10n.readoutStateOverdubbing,
      LooperMeterState.playing => l10n.readoutStatePlaying,
      LooperMeterState.stopped => l10n.readoutStateStopped,
      LooperMeterState.muted => l10n.readoutStateMuted,
    };
    final wordColor = switch (state) {
      LooperMeterState.recording ||
      LooperMeterState.overdubbing ||
      LooperMeterState.playing => looper.waveformColor(state),
      LooperMeterState.stopped ||
      LooperMeterState.muted => surface.textSecondary,
      LooperMeterState.empty => surface.textMuted,
    };
    final bars = track?.bars ?? 0;
    final spacing = context.spacing;
    return SizedBox(
      height: kReadoutMinTarget,
      child: Row(
        children: [
          if (track == null)
            Expanded(
              child: AppText(
                l10n.a11yReadoutNoTrack,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: title.copyWith(color: surface.textMuted),
              ),
            )
          else ...[
            AppText(
              '${track.channel + 1}',
              style: title.copyWith(
                color: surface.textSecondary,
                fontWeight: FontWeight.w400,
              ),
            ),
            SizedBox(width: spacing.sm),
            if (track.primary) ...[
              const PrimaryCrown(size: 18),
              SizedBox(width: spacing.sm),
            ],
            Expanded(
              child: AppText(
                track.defaultName
                    ? l10n.defaultTrackName(track.channel + 1)
                    : track.name,
                key: const Key('readout_panel_name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: title,
              ),
            ),
            SizedBox(width: spacing.sm),
            AppText(
              word,
              style: TextStyle(color: wordColor, fontSize: 15, height: 1),
            ),
            if (bars > 0) ...[
              SizedBox(width: spacing.sm),
              AppText(
                l10n.stageBarsFigure(bars),
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 15,
                  height: 1,
                ),
              ),
            ],
            SizedBox(width: spacing.md),
            SizedBox(
              width: 140,
              height: 28,
              child: ValueListenableBuilder<WaveformFrame>(
                valueListenable: frame,
                builder: (context, data, _) => WaveformView(
                  samples: data.samples,
                  progress: data.progress,
                  state: state,
                ),
              ),
            ),
          ],
          SizedBox(width: spacing.md),
          SizedBox(
            width: 88,
            child: ReadoutButton(
              key: const Key('readout_panel_done'),
              label: l10n.done,
              style: ReadoutButtonStyle.filled,
              fontSize: 18,
              onPressed: onDone,
            ),
          ),
        ],
      ),
    );
  }
}

/// The band under the header while a take holds the settings.
class _RecordingBand extends StatelessWidget {
  const _RecordingBand();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('readout_panel_recording'),
        padding: EdgeInsets.symmetric(
          horizontal: context.spacing.md,
          vertical: context.spacing.xs,
        ),
        decoration: BoxDecoration(
          color: surface.recTint,
          border: Border.all(color: surface.recLine),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.lock, size: 14, color: surface.rec),
            const SizedBox(width: 8),
            Flexible(
              child: AppText(
                context.l10n.readoutPanelRecording,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section's title, its subtitle, the lock mark and a note.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.title,
    this.subtitle,
    this.locked = false,
    this.note,
    this.noteKey,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final bool locked;
  final String? note;
  final Key? noteKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final style = TextStyle(
      color: surface.textMuted,
      fontSize: 11,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 1,
    );
    final subtitleText = subtitle;
    final noteText = note;
    final gap = context.spacing.sm;
    return SizedBox(
      height: 16,
      child: Row(
        children: [
          AppText(title.toUpperCase(), style: style),
          if (subtitleText != null) ...[
            SizedBox(width: gap),
            AppText(
              '· $subtitleText',
              style: style.copyWith(
                fontWeight: FontWeight.w400,
                letterSpacing: 0.4,
              ),
            ),
          ],
          if (locked) ...[
            SizedBox(width: gap),
            Icon(LucideIcons.lock, size: 12, color: surface.textMuted),
          ],
          if (noteText != null) ...[
            SizedBox(width: gap),
            Flexible(
              child: AppText(
                noteText,
                key: noteKey,
                maxLines: 1,
                style: style.copyWith(
                  color: surface.textSecondary,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
          // The beat lights give way at a long signature on a narrow card.
          if (trailing != null) ...[
            SizedBox(width: gap),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(fit: BoxFit.scaleDown, child: trailing),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The tempo, its beat lights, the steps and Tap.
class _TempoCard extends StatelessWidget {
  const _TempoCard({
    required this.readout,
    required this.frame,
    required this.onCommand,
    required this.onTypeTempo,
    required this.recordingBand,
  });

  final PerformanceReadout readout;
  final ValueListenable<WaveformFrame> frame;
  final ValueChanged<ReadoutCommand> onCommand;

  /// Opens the keypad for an exact tempo.
  final VoidCallback onTypeTempo;

  /// The band above already says why everything is locked.
  final bool recordingBand;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final editable = readoutTempoEditable(readout);
    final (note, warns) = _tempoNote(l10n);
    Widget step(String label, double delta) => Expanded(
      child: ReadoutPressButton(
        key: Key('readout_panel_nudge_$label'),
        label: label,
        semanticLabel: '$label ${l10n.stageBpmUnit}',
        enabled: editable,
        repeat: true,
        fontSize: 17,
        onPressed: () => onCommand(TempoNudge(delta)),
      ),
    );
    return Container(
      key: const Key('readout_panel_tempo'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface.card,
        border: Border.all(color: surface.borderSubtle),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel(
            title: l10n.readoutPanelTempo,
            locked: !editable,
            trailing: _BeatLights(readout: readout, frame: frame),
          ),
          const SizedBox(height: 4),
          Semantics(
            button: true,
            enabled: editable,
            label: l10n.loopTempoEdit,
            onTap: editable ? onTypeTempo : null,
            child: GestureDetector(
              key: const Key('readout_panel_bpm_button'),
              behavior: HitTestBehavior.opaque,
              onTap: editable ? onTypeTempo : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kReadoutMinTarget,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Opacity(
                    opacity: editable ? 1 : surface.disabledOpacity,
                    // As wide as the figure, so the rule underlines it.
                    child: IntrinsicWidth(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              AppText(
                                readoutExactTempo(
                                  hasTempo: readout.hasTempo,
                                  bpm: readout.tempoBpm,
                                ),
                                key: const Key('readout_panel_bpm'),
                                style: TextStyle(
                                  fontFamily: SurfaceTheme.monoFont,
                                  color: surface.textPrimary,
                                  fontSize: 44,
                                  height: 1,
                                ),
                              ),
                              const SizedBox(width: 8),
                              AppText(
                                l10n.stageBpmUnit,
                                style: TextStyle(
                                  color: surface.textSecondary,
                                  fontSize: 15,
                                  height: 1,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // The keypad's affordance, as on the mockup.
                          if (editable) const _DottedRule(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (note != null)
            AppText(
              note,
              key: const Key('readout_panel_tempo_note'),
              maxLines: 2,
              style: TextStyle(
                color: warns ? surface.warning : surface.textSecondary,
                fontSize: 13,
                height: 1.25,
              ),
            ),
          const Spacer(),
          Row(
            children: [
              step('-1', -1),
              const SizedBox(width: 8),
              step('-0.1', -0.1),
              const SizedBox(width: 8),
              step('+0.1', 0.1),
              const SizedBox(width: 8),
              step('+1', 1),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 52,
            child: ReadoutPressButton(
              key: const Key('readout_panel_tap'),
              label: l10n.readoutPanelTap.toUpperCase(),
              semanticLabel: l10n.loopTempoTap,
              enabled: editable,
              style: ReadoutButtonStyle.outlined,
              fontSize: 22,
              onPressed: () => onCommand(const TempoTap()),
            ),
          ),
        ],
      ),
    );
  }

  /// What the card says under the tempo, and whether it is a warning: the
  /// retime before it happens, or why the tempo is locked.
  (String?, bool) _tempoNote(AppLocalizations l10n) {
    if (readout.clockOwnsTempo) return (l10n.readoutPanelClock, false);
    // The band above says why everything is locked.
    if (recordingBand) return (null, false);
    return switch (readout.tempoFollow) {
      TempoFollowState.free => (l10n.readoutPanelTypeHint, false),
      TempoFollowState.retimes => (l10n.readoutPanelRetimes, true),
      TempoFollowState.noGrid => (l10n.readoutPanelNoGrid, false),
      TempoFollowState.noFollower => (l10n.readoutPanelNoFollower, false),
      TempoFollowState.busy => (l10n.readoutPanelBusy, false),
    };
  }
}

/// One light per beat of the bar, the sounding one lit while the selected
/// track plays, worked out from its playhead, its bars and the signature.
class _BeatLights extends StatelessWidget {
  const _BeatLights({required this.readout, required this.frame});

  final PerformanceReadout readout;
  final ValueListenable<WaveformFrame> frame;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final beats = readout.tsNum.clamp(1, 15);
    final bars = readout.selected?.bars ?? 0;
    final state = readoutMeterStateOf(readout.selected);
    final sounding =
        bars > 0 &&
        (state == LooperMeterState.playing ||
            state == LooperMeterState.overdubbing);
    final gap = context.spacing.xs;
    return ValueListenableBuilder<WaveformFrame>(
      valueListenable: frame,
      builder: (context, data, _) {
        final lit = sounding
            ? (data.progress.clamp(0.0, 0.999999) * bars * beats).floor() %
                  beats
            : -1;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < beats; i++) ...[
              if (i > 0) SizedBox(width: gap),
              DecoratedBox(
                key: Key('readout_panel_beat_$i'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == lit ? surface.accent : surface.control,
                  border: i == 0
                      ? Border.all(color: surface.warning, width: 1.5)
                      : null,
                ),
                child: const SizedBox.square(dimension: 9),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The signature, length and record timing sections.
class _Choices extends StatelessWidget {
  const _Choices({
    required this.readout,
    required this.lengthBars,
    required this.onSignature,
    required this.onMoreSignatures,
    required this.onLength,
    required this.onTiming,
  });

  final PerformanceReadout readout;

  /// The length shown: the one the panel just sent, until the push has it.
  final int lengthBars;
  final void Function(int num, int den) onSignature;
  final VoidCallback onMoreSignatures;
  final ValueChanged<int> onLength;
  final ValueChanged<RecordTiming> onTiming;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final loop = readout.loop;
    final signatureEditable = readoutSignatureEditable(readout);
    final editable = loop.editable;
    final current = (readout.tsNum, readout.tsDen);
    final quick = kReadoutQuickSignatures.contains(current);
    final channel = readout.selected?.channel;
    final trackLength = loop.trackLengthBars;
    final trackTiming = loop.trackTiming;
    // One gap across and down the grid (#1672): the rows are xs apart,
    // since the right column has only a few px to spare while a take records.
    final gap = context.spacing.xs;
    List<Widget> spaced(List<Widget> children) => [
      for (final (i, child) in children.indexed) ...[
        if (i > 0) SizedBox(width: gap),
        child,
      ],
    ];
    Widget timing(RecordTiming value) => Expanded(
      child: ReadoutButton(
        key: Key('readout_panel_timing_${value.name}'),
        label: readoutTimingLabel(l10n, value),
        selected: loop.timing == value,
        enabled: editable,
        fontSize: 14,
        onPressed: () => onTiming(value),
      ),
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          gap: gap,
          label: _SectionLabel(
            title: l10n.loopTempoSignature,
            locked: !signatureEditable,
            note: readout.tempoFollow == TempoFollowState.retimes
                ? l10n.readoutPanelSignatureLocked
                : null,
            noteKey: const Key('readout_panel_signature_note'),
          ),
          rows: [
            spaced([
              for (final (num, den) in kReadoutQuickSignatures)
                Expanded(
                  child: ReadoutButton(
                    key: Key('readout_panel_signature_${num}_$den'),
                    label: '$num/$den',
                    selected: current == (num, den),
                    enabled: signatureEditable,
                    fontSize: 18,
                    onPressed: () => onSignature(num, den),
                  ),
                ),
              Expanded(
                child: ReadoutButton(
                  key: const Key('readout_panel_signature_more'),
                  // Off the short list, the current signature takes More's
                  // place, so it is always on screen.
                  label: quick
                      ? l10n.readoutPanelMore
                      : '${readout.tsNum}/${readout.tsDen}',
                  semanticLabel: l10n.readoutPanelMore,
                  selected: !quick,
                  enabled: signatureEditable,
                  fontSize: quick ? 15 : 18,
                  onPressed: onMoreSignatures,
                ),
              ),
            ]),
          ],
        ),
        _section(
          gap: gap,
          label: _SectionLabel(
            title: l10n.readoutPanelLength,
            subtitle: trackLength == null || channel == null
                ? l10n.readoutPanelNextTake
                : null,
            locked: !editable,
            note: trackLength == null || channel == null
                ? null
                : l10n.readoutPanelTrackOwn(
                    channel + 1,
                    readoutLengthLabel(l10n, trackLength),
                  ),
            noteKey: const Key('readout_panel_length_note'),
          ),
          rows: [
            spaced([
              SizedBox(
                width: 52,
                child: ReadoutButton(
                  key: const Key('readout_panel_length_less'),
                  icon: LucideIcons.minus,
                  semanticLabel: l10n.readoutPanelShorter,
                  enabled: editable && lengthBars > 1,
                  onPressed: () => onLength(lengthBars - 1),
                ),
              ),
              Expanded(
                child: Center(
                  child: AppText(
                    readoutLengthLabel(l10n, lengthBars),
                    key: const Key('readout_panel_length'),
                    style: TextStyle(
                      color: editable
                          ? context.surface.textPrimary
                          : context.surface.textMuted,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      height: 1,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: ReadoutButton(
                  key: const Key('readout_panel_length_more'),
                  icon: LucideIcons.plus,
                  semanticLabel: l10n.readoutPanelLonger,
                  enabled: editable && lengthBars < 64,
                  onPressed: () => onLength(lengthBars + 1),
                ),
              ),
              SizedBox(
                width: 72,
                child: ReadoutButton(
                  key: const Key('readout_panel_length_auto'),
                  label: l10n.loopLengthAuto,
                  selected: lengthBars == 0,
                  enabled: editable,
                  onPressed: () => onLength(0),
                ),
              ),
            ]),
          ],
        ),
        _section(
          gap: gap,
          label: _SectionLabel(
            title: l10n.readoutPanelStart,
            subtitle: trackTiming == null || channel == null
                ? l10n.readoutPanelRecordTiming
                : null,
            locked: !editable,
            note: trackTiming == null || channel == null
                ? null
                : l10n.readoutPanelTrackOwn(
                    channel + 1,
                    readoutTimingLabel(l10n, trackTiming),
                  ),
            noteKey: const Key('readout_panel_timing_note'),
          ),
          rows: [
            spaced([
              for (final value in RecordTiming.values.take(4)) timing(value),
            ]),
            spaced([
              for (final value in RecordTiming.values.skip(4)) timing(value),
              // The second row's fourth cell stays empty.
              const Expanded(child: SizedBox.shrink()),
            ]),
          ],
        ),
      ],
    );
  }

  Widget _section({
    required Widget label,
    required List<List<Widget>> rows,
    required double gap,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      label,
      for (final row in rows) ...[
        SizedBox(height: gap),
        SizedBox(
          height: kReadoutMinTarget,
          child: Row(children: row),
        ),
      ],
    ],
  );
}

/// Every valid signature, four across, with Back.
class _SignatureGrid extends StatelessWidget {
  const _SignatureGrid({
    required this.readout,
    required this.onChosen,
    required this.onBack,
  });

  final PerformanceReadout readout;
  final void Function(int num, int den) onChosen;
  final VoidCallback onBack;

  static const int _columns = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = readoutSignatureEditable(readout);
    final cells = <Widget>[
      for (final (num, den) in kValidTimeSignatures)
        ReadoutButton(
          key: Key('readout_panel_all_signature_${num}_$den'),
          label: '$num/$den',
          selected: (readout.tsNum, readout.tsDen) == (num, den),
          enabled: enabled,
          fontSize: 17,
          onPressed: () => onChosen(num, den),
        ),
      ReadoutButton(
        key: const Key('readout_panel_signature_back'),
        icon: LucideIcons.arrowLeft,
        label: l10n.readoutPanelBack,
        fontSize: 14,
        onPressed: onBack,
      ),
    ];
    final rows = (cells.length / _columns).ceil();
    final gap = context.spacing.xs;
    // One fixed gap across and down (#1672), the grid at the top of the
    // column rather than spread to the tempo card's height.
    return Column(
      key: const Key('readout_panel_signatures'),
      spacing: gap,
      children: [
        for (var row = 0; row < rows; row++)
          SizedBox(
            height: kReadoutMinTarget,
            child: Row(
              children: [
                for (var col = 0; col < _columns; col++) ...[
                  if (col > 0) SizedBox(width: gap),
                  Expanded(
                    child: row * _columns + col < cells.length
                        ? cells[row * _columns + col]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The dotted line under the tempo that says it can be typed.
class _DottedRule extends StatelessWidget {
  const _DottedRule();

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('readout_panel_bpm_rule'),
    height: 2,
    child: CustomPaint(painter: _DotsPainter(context.surface.textMuted)),
  );
}

/// 3 px dashes, 3 px apart, across the width.
class _DotsPainter extends CustomPainter {
  const _DotsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 0.0; x + 3 <= size.width; x += 6) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 3, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.color != color;
}
