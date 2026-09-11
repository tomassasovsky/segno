import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// One offered choice.
class PedalChoice<T> {
  /// Creates a [PedalChoice].
  const PedalChoice({
    required this.value,
    required this.label,
    required this.id,
  });

  /// What choosing this resolves to.
  final T value;

  /// What the button says.
  final String label;

  /// The widget-key fragment for this choice, so a test can aim at a row
  /// without depending on its localized label.
  final String id;
}

/// A heading and the choices under it.
class PedalChoiceGroup<T> {
  /// Creates a [PedalChoiceGroup].
  const PedalChoiceGroup({
    required this.label,
    required this.id,
    required this.choices,
  });

  /// The heading. A picker with one group never draws it.
  final String label;

  /// The widget-key fragment for the heading's tab.
  final String id;

  /// The choices, in catalogue order.
  final List<PedalChoice<T>> choices;
}

/// What [showPedalChoicePicker] resolves to: a choice, or nothing when it was
/// dismissed.
///
/// A wrapper rather than a bare `T?`, because `null` is a legitimate choice
/// here — it is how "None" is spelled — and a picker that could not tell
/// "the user picked None" from "the user backed out" would clear an
/// assignment every time someone changed their mind.
class PedalChoiceResult<T> {
  /// Creates a [PedalChoiceResult].
  const PedalChoiceResult(this.value);

  /// The chosen value.
  final T value;
}

/// The accepted action chooser: a titled panel of choices over the page, with
/// a heading tab per group when there is more than one.
///
/// Drawn inside the pen's own 1920 x 1080 canvas and scaled with it, like
/// every other modal on this console, so the panel keeps the page's
/// proportions on whatever screen it runs on.
Future<PedalChoiceResult<T>?> showPedalChoicePicker<T>(
  BuildContext context, {
  required String title,
  required List<PedalChoiceGroup<T>> groups,
  required T current,
}) {
  final surface = context.surface;
  return showDialog<PedalChoiceResult<T>>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.86),
    builder: (context) => _PedalChoicePicker<T>(
      title: title,
      groups: groups,
      current: current,
    ),
  );
}

class _PedalChoicePicker<T> extends StatefulWidget {
  const _PedalChoicePicker({
    required this.title,
    required this.groups,
    required this.current,
  });

  final String title;
  final List<PedalChoiceGroup<T>> groups;
  final T current;

  @override
  State<_PedalChoicePicker<T>> createState() => _PedalChoicePickerState<T>();
}

class _PedalChoicePickerState<T> extends State<_PedalChoicePicker<T>> {
  /// The open group. Seeded to the one holding the current choice, so a
  /// picker opens showing what the control already does rather than on a
  /// heading the user then has to leave.
  late int _group = widget.groups.indexWhere(
    (group) => group.choices.any((choice) => choice.value == widget.current),
  );

  /// The pen's panel.
  static const double _panelWidth = 1400;
  static const double _panelHeight = 840;
  static const double _pad = 40;
  static const double _columns = 3;
  static const double _rowHeight = 96;
  static const double _gap = 16;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final tabbed = widget.groups.length > 1;
    final index = _group < 0 ? 0 : _group;
    final choices = widget.groups[index].choices;
    const cellWidth =
        (_panelWidth - 2 * _pad - (_columns - 1) * _gap) / _columns;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: kLoopPenSize,
          child: Center(
            child: Material(
              key: const Key('pedal_choice_picker'),
              color: surface.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: surface.borderStrong),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: _panelWidth,
                height: _panelHeight,
                child: Padding(
                  padding: const EdgeInsets.all(_pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: AppText(
                              widget.title,
                              key: const Key('pedal_choice_title'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: surface.textPrimary,
                                fontSize: 38,
                                height: 1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 24),
                          LoopOutlinedButton(
                            key: const Key('pedal_choice_close'),
                            width: 64,
                            icon: LucideIcons.x,
                            semanticLabel: l10n.pedalSetupCancel,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      if (tabbed) ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 64,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: widget.groups.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: _gap),
                            itemBuilder: (context, i) => LoopChoiceButton(
                              key: Key(
                                'pedal_choice_group_${widget.groups[i].id}',
                              ),
                              label: widget.groups[i].label,
                              selected: i == index,
                              onTap: () => setState(() => _group = i),
                              width: 260,
                              height: 64,
                              fontSize: 22,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Expanded(
                        child: Scrollbar(
                          thumbVisibility: true,
                          child: GridView.builder(
                            padding: const EdgeInsets.only(right: 16),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _columns.toInt(),
                                  mainAxisSpacing: _gap,
                                  crossAxisSpacing: _gap,
                                  mainAxisExtent: _rowHeight,
                                ),
                            itemCount: choices.length,
                            itemBuilder: (context, i) => LoopChoiceButton(
                              key: Key('pedal_choice_${choices[i].id}'),
                              label: choices[i].label,
                              selected: choices[i].value == widget.current,
                              onTap: () => Navigator.of(context).pop(
                                PedalChoiceResult<T>(choices[i].value),
                              ),
                              width: cellWidth,
                              fontSize: 22,
                            ),
                          ),
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
    );
  }
}
