import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The Device page's dialog (pen 28/03 and 28/04): a 960-wide panel, 41 in
/// from its edge, with a 32 px title, a 24 px body, the page's own content,
/// and its actions at the right.
///
/// The page is drawn at the pen's scale, so its dialogs are too: the
/// console's 744-wide shell, drawn for the tray, would sit on this page at
/// two thirds of the size of everything around it.
class DeviceDialog extends StatelessWidget {
  /// Creates a [DeviceDialog].
  const DeviceDialog({
    required this.title,
    required this.actions,
    this.body,
    this.content = const [],
    super.key,
  });

  /// The question or the task.
  final String title;

  /// What it does, under the title, when it says more than the title.
  final String? body;

  /// What sits between the body and the actions.
  final List<Widget> content;

  /// The buttons, in reading order.
  final List<Widget> actions;

  /// The panel's width.
  static const double width = 960;

  /// The panel's inset.
  static const double padding = 41;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            width: width,
            padding: const EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: surface.frameControlFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: surface.frameControlLine),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  title,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 32,
                    height: 1.15,
                  ),
                ),
                if (body case final body?) ...[
                  const SizedBox(height: 24),
                  AppText(
                    body,
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 24,
                      height: 1.5,
                    ),
                  ),
                ],
                ...content,
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (final (index, action) in actions.indexed) ...[
                      if (index > 0) const SizedBox(width: 16),
                      action,
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Apply audio settings?" (pen 28/04): true for [confirmLabel], false for
/// Cancel, where the encoder starts.
Future<bool> showDeviceConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (dialogContext) => DeviceDialog(
      key: const Key('device_confirm_dialog'),
      title: title,
      body: body,
      actions: [
        LoopOutlinedButton(
          key: const Key('device_confirm_cancel'),
          width: 125,
          label: l10n.cancel,
          autofocus: true,
          onTap: () => Navigator.of(dialogContext).pop(false),
        ),
        LoopOutlinedButton(
          key: const Key('device_confirm_confirm'),
          width: 293,
          label: confirmLabel,
          tone: LoopButtonTone.accent,
          onTap: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
