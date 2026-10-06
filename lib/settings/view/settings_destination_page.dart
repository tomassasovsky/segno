import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/theme/theme.dart';

/// One Settings destination that does not have its accepted page yet: the
/// shared Settings frame (Back, the `SETTINGS / <title>` crumb, Stage and the
/// title) around the body the settings tray used to show.
///
/// The body sits on a card-toned panel rather than on the page background.
/// The tray bodies were drawn for the tray sheet, whose tone is
/// [SurfaceTheme.card], and their pinned group captions paint that tone; on
/// the darker page background each caption would draw a band across the
/// face. When a destination's redesign lands it replaces this page's body,
/// not the route or the tile that opens it.
class SettingsDestinationPage extends StatelessWidget {
  /// Creates a [SettingsDestinationPage] titled [title] around [body].
  const SettingsDestinationPage({
    required this.title,
    required this.body,
    super.key,
  });

  /// The page title, also the last part of the breadcrumb.
  final String title;

  /// What the page shows on its panel.
  final Widget body;

  /// The panel's inset in the frame's main area: the pen's 100 px page
  /// margins, starting under the title row.
  static const EdgeInsets panelInset = EdgeInsets.fromLTRB(100, 120, 100, 40);

  /// The body's inset inside the panel, as the tray sheet set its faces.
  static const EdgeInsets bodyInset = EdgeInsets.fromLTRB(20, 18, 20, 0);

  /// The panel's corner radius.
  static const double radius = 12;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Scaffold(
      body: LoopSettingsFrame(
        crumb: context.l10n.settingsCrumb(title),
        title: title,
        titleLeft: 100,
        onBack: () => Navigator.maybePop(context),
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            left: panelInset.left,
            top: panelInset.top,
            right: panelInset.right,
            bottom: panelInset.bottom,
            child: DecoratedBox(
              key: const Key('settings_destination_panel'),
              decoration: BoxDecoration(
                color: surface.card,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: surface.line),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Padding(padding: bodyInset, child: body),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
