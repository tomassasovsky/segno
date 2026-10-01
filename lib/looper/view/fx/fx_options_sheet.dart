import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// One row of an [showFxOptionsSheet].
class FxOption {
  /// Creates an [FxOption].
  const FxOption({required this.id, required this.label, this.enabled = true});

  /// What the sheet resolves to when this row is chosen.
  final String id;

  /// The row's label.
  final String label;

  /// Whether the row can be chosen. A disabled row is drawn dimmed rather
  /// than hidden, so the list does not change shape between two racks.
  final bool enabled;
}

/// The pen's options overlay (`06 Rack options`): a titled panel of rows over
/// the page, with Cancel and nothing else.
///
/// Drawn inside the pen's own 1920 x 1080 canvas and scaled with it, so the
/// panel keeps the page's proportions on every screen this console runs on.
/// Resolves to the chosen [FxOption.id], or null when it was cancelled.
Future<String?> showFxOptionsSheet(
  BuildContext context, {
  required String title,
  required List<FxOption> options,
  String? body,
}) {
  final surface = context.surface;
  return showDialog<String>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.86),
    builder: (context) => _FxOptionsSheet(
      title: title,
      body: body,
      options: options,
    ),
  );
}

class _FxOptionsSheet extends StatelessWidget {
  const _FxOptionsSheet({
    required this.title,
    required this.body,
    required this.options,
  });

  final String title;
  final String? body;
  final List<FxOption> options;

  /// The pen's panel: 960 wide, rows 96 tall with a 12 gap, and the Cancel
  /// row 24 under the last of them.
  static const double _panelWidth = 960;
  static const double _rowHeight = 96;
  static const double _rowGap = 12;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final head = body == null ? 102.0 : 162.0;
    final rows = options.length * _rowHeight + (options.length - 1) * _rowGap;
    final height = head + rows + 24 + 64 + 41;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: kLoopPenSize,
          child: Center(
            child: Material(
              key: const Key('fx_options_sheet'),
              color: surface.card,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: _panelWidth,
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: surface.borderStrong),
                ),
                padding: const EdgeInsets.fromLTRB(41, 41, 41, 41),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      title,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 32,
                        height: 1,
                      ),
                    ),
                    if (body case final body?) ...[
                      const SizedBox(height: 27),
                      AppText(
                        body,
                        style: TextStyle(
                          color: surface.textSecondary,
                          fontSize: 24,
                          height: 1.2,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    for (var i = 0; i < options.length; i++) ...[
                      if (i > 0) const SizedBox(height: _rowGap),
                      _OptionRow(option: options[i]),
                    ],
                    const Spacer(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: LoopOutlinedButton(
                        key: const Key('fx_options_cancel'),
                        width: 125,
                        label: l10n.cancel,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option});

  final FxOption option;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: option.enabled ? 1 : surface.disabledOpacity,
      child: Semantics(
        button: true,
        enabled: option.enabled,
        child: Material(
          color: surface.card,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            key: Key('fx_option_${option.id}'),
            onTap: option.enabled
                ? () => Navigator.of(context).pop(option.id)
                : null,
            borderRadius: BorderRadius.circular(7),
            child: Container(
              height: _FxOptionsSheet._rowHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: surface.borderSubtle),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: Row(
                children: [
                  Expanded(
                    child: AppText(
                      option.label,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 24,
                        height: 1,
                      ),
                    ),
                  ),
                  Icon(
                    LucideIcons.chevronRight,
                    size: 28,
                    color: surface.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
