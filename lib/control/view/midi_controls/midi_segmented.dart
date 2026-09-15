import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// One option of a [MidiSegmented].
class MidiSegment<T> {
  /// Creates a [MidiSegment].
  const MidiSegment({required this.value, required this.label});

  /// What choosing it means.
  final T value;

  /// What it says.
  final String label;
}

/// The MIDI editor's segmented choice: a bordered group of options with the
/// current one filled — Knob / fader or Button, Momentary or Toggle, Pressed
/// or Released.
class MidiSegmented<T> extends StatelessWidget {
  /// Creates a [MidiSegmented].
  const MidiSegmented({
    required this.segments,
    required this.selected,
    required this.onSelected,
    required this.segmentWidth,
    required this.semanticLabel,
    this.segmentHeight = 64,
    this.keyPrefix = 'midi_segment',
    super.key,
  });

  /// The options, in reading order.
  final List<MidiSegment<T>> segments;

  /// The current option.
  final T selected;

  /// Chooses an option.
  final ValueChanged<T> onSelected;

  /// The width of each option.
  final double segmentWidth;

  /// The height of each option.
  final double segmentHeight;

  /// What the group is, for a screen reader.
  final String semanticLabel;

  /// Each option's key is this prefix and its value's name.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: surface.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final segment in segments)
              _Segment(
                key: Key('${keyPrefix}_${_name(segment.value)}'),
                label: segment.label,
                selected: segment.value == selected,
                width: segmentWidth,
                height: segmentHeight,
                // Choosing what is already chosen changes nothing: Button
                // tapped again must not turn a Toggle button Momentary.
                onTap: () {
                  if (segment.value != selected) onSelected(segment.value);
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _name(Object? value) => value is Enum ? value.name : '$value';
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.width,
    required this.height,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? surface.accentSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: height,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: AppText(
                    label,
                    style: TextStyle(
                      color: selected
                          ? surface.textPrimary
                          : surface.textSecondary,
                      fontSize: 21,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
