import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// How one saved mapping reads in the list.
class MidiMappingRow {
  /// Creates a [MidiMappingRow].
  const MidiMappingRow({
    required this.mapping,
    required this.name,
    required this.targets,
    this.warning,
  });

  /// The mapping.
  final MidiMapping mapping;

  /// The control it reads, named.
  final String name;

  /// Everything it drives, named and joined.
  final String targets;

  /// Why it may not do what it says — a control the rig lost, or a controller
  /// that is not connected — or `null`.
  final String? warning;
}

/// The saved mappings of the input in use, with what each last received.
class MidiMappingRows extends StatefulWidget {
  /// Creates a [MidiMappingRows].
  const MidiMappingRows({
    required this.rows,
    required this.levels,
    required this.onEdit,
    required this.onEnabled,
    super.key,
  });

  /// The rows, in the order the mappings were added.
  final List<MidiMappingRow> rows;

  /// The last reading a control sent, or `null` before it sent one.
  final Map<MidiSource, MidiControlEvent> levels;

  /// Opens a mapping in the editor.
  final ValueChanged<MidiMapping> onEdit;

  /// Turns a mapping on or off.
  final void Function(MidiMapping mapping, {required bool enabled}) onEnabled;

  @override
  State<MidiMappingRows> createState() => _MidiMappingRowsState();
}

class _MidiMappingRowsState extends State<MidiMappingRows> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scroll,
    thumbVisibility: true,
    trackVisibility: true,
    child: ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.zero,
      itemCount: widget.rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final row = widget.rows[index];
        return _Row(
          row: row,
          reading: widget.levels[row.mapping.source],
          onEdit: () => widget.onEdit(row.mapping),
          onEnabled: () =>
              widget.onEnabled(row.mapping, enabled: !row.mapping.enabled),
        );
      },
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.reading,
    required this.onEdit,
    required this.onEnabled,
  });

  final MidiMappingRow row;
  final MidiControlEvent? reading;
  final VoidCallback onEdit;
  final VoidCallback onEnabled;

  static const double _height = 106;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final id = row.mapping.id;
    final enabled = row.mapping.enabled;
    final warning = row.warning;
    return Opacity(
      // A disabled mapping keeps its row, drawn back, so it can be turned on
      // again where it was.
      opacity: enabled ? 1 : surface.disabledOpacity,
      child: Container(
        key: Key('midi_row_$id'),
        height: _height,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: surface.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: surface.borderSubtle),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: row.name,
                value: row.targets,
                onTap: onEdit,
                excludeSemantics: true,
                child: LoopFocusable(
                  onActivate: onEdit,
                  child: InkWell(
                    key: Key('midi_row_edit_$id'),
                    onTap: onEdit,
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          row.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 26,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        AppText(
                          row.targets,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 20,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 28),
            _Meter(
              key: Key('midi_row_meter_$id'),
              reading: reading,
            ),
            if (warning != null) ...[
              const SizedBox(width: 28),
              AppText(
                warning,
                key: Key('midi_row_warning_$id'),
                style: TextStyle(color: surface.warning, fontSize: 22),
              ),
            ],
            const SizedBox(width: 28),
            _PowerButton(
              key: Key('midi_row_enable_$id'),
              on: enabled,
              semanticLabel: enabled
                  ? l10n.a11yMidiDisableMapping(row.name)
                  : l10n.a11yMidiEnableMapping(row.name),
              onTap: onEnabled,
            ),
          ],
        ),
      ),
    );
  }
}

/// The last value a mapping received, as a bar.
class _Meter extends StatelessWidget {
  const _Meter({required this.reading, super.key});

  final MidiControlEvent? reading;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final reading = this.reading;
    final level = reading == null ? 0.0 : reading.value / reading.maximum;
    return Semantics(
      label: l10n.a11yMidiLastReceived(reading?.value ?? 0),
      excludeSemantics: true,
      child: Container(
        width: 120,
        height: 7,
        decoration: BoxDecoration(
          color: surface.control,
          borderRadius: BorderRadius.circular(3),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: level.clamp(0.0, 1.0),
          heightFactor: 1,
          child: ColoredBox(color: surface.textPrimary),
        ),
      ),
    );
  }
}

/// A mapping's power button: filled while the mapping dispatches.
class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.on,
    required this.semanticLabel,
    required this.onTap,
    super.key,
  });

  final bool on;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      toggled: on,
      label: semanticLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          color: on ? surface.accentSurface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: on ? surface.accent : surface.borderStrong),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.square(
              dimension: 64,
              child: Icon(
                LucideIcons.power,
                size: 28,
                color: surface.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
