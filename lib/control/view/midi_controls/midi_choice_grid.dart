import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// One option of a [MidiChoiceGrid].
class MidiChoice<T> {
  /// Creates a [MidiChoice].
  const MidiChoice({
    required this.value,
    required this.id,
    required this.label,
    this.detail,
  });

  /// What choosing it means.
  final T value;

  /// A stable key fragment.
  final String id;

  /// What it is called.
  final String label;

  /// A line under the name saying what it does, or `null`.
  final String? detail;
}

/// A whole-page grid of choices: the receive channel and the message format.
class MidiChoiceGrid<T> extends StatelessWidget {
  /// Creates a [MidiChoiceGrid].
  const MidiChoiceGrid({
    required this.choices,
    required this.selected,
    required this.onPick,
    this.keyPrefix = 'midi_choice',
    super.key,
  });

  /// The choices, in reading order.
  final List<MidiChoice<T>> choices;

  /// The current choice.
  final T selected;

  /// Makes a choice.
  final ValueChanged<T> onPick;

  /// Each choice's key is this prefix and its id.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 18,
        crossAxisSpacing: 18,
        mainAxisExtent: 100,
      ),
      itemCount: choices.length,
      itemBuilder: (context, index) {
        final choice = choices[index];
        final isSelected = choice.value == selected;
        final detail = choice.detail;
        return Semantics(
          button: true,
          selected: isSelected,
          label: choice.label,
          value: detail,
          onTap: () => onPick(choice.value),
          excludeSemantics: true,
          child: Material(
            key: Key('${keyPrefix}_${choice.id}'),
            color: isSelected ? surface.accentSurface : surface.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: isSelected ? surface.accent : surface.borderSubtle,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onPick(choice.value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      choice.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 25,
                        height: 1.2,
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 8),
                      AppText(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: surface.textSecondary,
                          fontSize: 19,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
