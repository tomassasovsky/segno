import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:segno/control/binding/midi_labels.dart';
import 'package:segno/control/binding/midi_learn.dart';
import 'package:segno/control/binding/midi_mapping_draft.dart';
import 'package:segno/control/view/midi_controls/midi_segmented.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The editor's left column: which control the mapping reads, in which format
/// and on which channel, Learn, and how the control behaves.
class MidiSourcePanel extends StatefulWidget {
  /// Creates a [MidiSourcePanel].
  const MidiSourcePanel({
    required this.deviceName,
    required this.draft,
    required this.protocol,
    required this.learn,
    required this.connected,
    required this.conflicting,
    required this.onFormat,
    required this.onChannel,
    required this.onLearn,
    required this.onCancelLearn,
    required this.onEditExisting,
    required this.onBehavior,
    this.notice,
    super.key,
  });

  /// The controller the mapping listens to.
  final String deviceName;

  /// The edit in progress.
  final MidiMappingDraft draft;

  /// The format the next Learn reads in.
  final MidiProtocol protocol;

  /// The Learn in progress, or `null`.
  final MidiLearn? learn;

  /// Whether the controller is connected, which Learn needs.
  final bool connected;

  /// Whether the learned control overlaps a saved mapping.
  final bool conflicting;

  /// Opens the format picker.
  final VoidCallback onFormat;

  /// Opens the channel picker.
  final VoidCallback onChannel;

  /// Starts Learn.
  final VoidCallback onLearn;

  /// Stops Learn.
  final VoidCallback onCancelLearn;

  /// Opens the mapping the control overlaps.
  final VoidCallback onEditExisting;

  /// Chooses how the control behaves.
  final ValueChanged<MidiBehavior> onBehavior;

  /// What just happened, or what is in the way, or `null`.
  final String? notice;

  /// The pen's column.
  static const Size penSize = Size(480, 808);
  static const double _inner = 390;

  @override
  State<MidiSourcePanel> createState() => _MidiSourcePanelState();
}

class _MidiSourcePanelState extends State<MidiSourcePanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final source = widget.draft.source;
    final reading = widget.learn?.reading;
    final listening = widget.learn?.isListening ?? false;
    final notice = widget.notice;
    return Container(
      width: MidiSourcePanel.penSize.width,
      height: MidiSourcePanel.penSize.height,
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        trackVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(
            left: 36,
            right: 52,
            top: 36,
            bottom: 36,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                widget.deviceName,
                style: TextStyle(color: surface.textSecondary, fontSize: 22),
              ),
              const SizedBox(height: 22),
              AppText(
                source == null
                    ? l10n.midiNoControlSelected
                    : midiSourceName(l10n, source),
                key: const Key('midi_source_name'),
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 32,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 22),
              LoopOutlinedButton(
                key: const Key('midi_format'),
                width: MidiSourcePanel._inner,
                label: midiFormatLabel(l10n, widget.protocol),
                semanticLabel: l10n.midiMessageFormat,
                semanticValue: midiFormatLabel(l10n, widget.protocol),
                onTap: widget.onFormat,
              ),
              if (reading != null) ...[
                const SizedBox(height: 22),
                AppText(
                  midiReceivedLine(l10n, reading),
                  key: const Key('midi_received'),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 22,
                    fontFamily: SurfaceTheme.monoFont,
                  ),
                ),
              ],
              if (source != null) ...[
                const SizedBox(height: 22),
                LoopOutlinedButton(
                  key: const Key('midi_channel'),
                  width: MidiSourcePanel._inner,
                  label: midiReceiveLabel(l10n, source.channel),
                  onTap: widget.onChannel,
                ),
              ],
              const SizedBox(height: 22),
              if (listening) ...[
                _Listening(connected: widget.connected),
                const SizedBox(height: 22),
                LoopOutlinedButton(
                  key: const Key('midi_cancel_learn'),
                  width: MidiSourcePanel._inner,
                  label: l10n.midiCancelLearn,
                  onTap: widget.onCancelLearn,
                ),
              ] else
                LoopOutlinedButton(
                  key: const Key('midi_learn'),
                  width: MidiSourcePanel._inner,
                  tone: LoopButtonTone.accent,
                  label: source == null
                      ? l10n.midiLearn
                      : l10n.midiLearnAnother,
                  onTap: widget.connected ? widget.onLearn : null,
                ),
              if (widget.conflicting) ...[
                const SizedBox(height: 22),
                AppText(
                  l10n.midiOverlaps,
                  key: const Key('midi_conflict'),
                  style: TextStyle(color: surface.warning, fontSize: 22),
                ),
                const SizedBox(height: 22),
                LoopOutlinedButton(
                  key: const Key('midi_edit_existing'),
                  width: 279,
                  height: 68,
                  label: l10n.midiEditExisting,
                  onTap: widget.onEditExisting,
                ),
              ],
              if (widget.draft.offersKnobOrButton) ...[
                const SizedBox(height: 22),
                MidiSegmented<bool>(
                  keyPrefix: 'midi_knob',
                  semanticLabel: l10n.midiControlBehavior,
                  segmentWidth: 188,
                  selected: widget.draft.behavior == MidiBehavior.continuous,
                  segments: [
                    MidiSegment(value: true, label: l10n.midiKnobOrFader),
                    MidiSegment(value: false, label: l10n.midiButton),
                  ],
                  onSelected: (knob) => widget.onBehavior(
                    knob ? MidiBehavior.continuous : MidiBehavior.momentary,
                  ),
                ),
              ],
              if (widget.draft.offersButtonBehavior) ...[
                const SizedBox(height: 22),
                MidiSegmented<MidiBehavior>(
                  keyPrefix: 'midi_behavior',
                  semanticLabel: l10n.midiButtonBehavior,
                  segmentWidth: 188,
                  selected: widget.draft.behavior,
                  segments: [
                    MidiSegment(
                      value: MidiBehavior.momentary,
                      label: l10n.midiMomentary,
                    ),
                    MidiSegment(
                      value: MidiBehavior.toggle,
                      label: l10n.midiToggle,
                    ),
                  ],
                  onSelected: widget.onBehavior,
                ),
              ],
              if (notice != null) ...[
                const SizedBox(height: 22),
                Semantics(
                  liveRegion: true,
                  child: AppText(
                    notice,
                    key: const Key('midi_editor_notice'),
                    style: TextStyle(color: surface.warning, fontSize: 22),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Learn listening: the box that says to move a control, or to reconnect the
/// controller when it is not there to hear.
class _Listening extends StatelessWidget {
  const _Listening({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('midi_listening'),
        width: MidiSourcePanel._inner,
        height: 155,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: surface.borderStrong),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 6,
              decoration: BoxDecoration(
                color: surface.accent,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 24),
            AppText(
              connected ? l10n.midiMoveAControl : l10n.midiReconnectController,
              style: TextStyle(color: surface.textPrimary, fontSize: 25),
            ),
          ],
        ),
      ),
    );
  }
}
