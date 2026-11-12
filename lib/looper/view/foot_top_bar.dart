import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/top_bar_layout.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

/// The performance views' top bar (Mixer, Fade, Reverse, Peel, Tuner, FX,
/// Custom, Multiply and Divide): Exit at the leading edge, Settings at the
/// trailing edge, and the app's messages in the centre (#1562), so a
/// must-act message such as a lost audio interface is on every screen, not
/// only on the stage.
///
/// These views draw no track cards, so a message a track caused is said
/// here too.
class FootTopBar extends StatelessWidget {
  /// Creates a [FootTopBar].
  const FootTopBar({
    required this.exitKey,
    required this.onExit,
    this.status,
    super.key,
  });

  /// The bar's height, the stage top bar's.
  static const double height = 96;

  /// The bar's inset from the screen edges.
  static const double sideInset = 36;

  /// Exit's key.
  final Key exitKey;

  /// What Exit does.
  final VoidCallback onExit;

  /// A status shown before Settings (Custom's recording pill).
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = this.status;
    return SizedBox(
      height: height,
      child: NoticeBar(
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: sideInset,
          ),
          child: TopBarLayout(
            leading: IconButton.outlined(
              key: exitKey,
              tooltip: l10n.actionModeExit,
              onPressed: onExit,
              style: IconButton.styleFrom(
                minimumSize: const Size(64, 64),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.chevron_left),
            ),
            centre: const NoticeBarMessage(),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (status != null) ...[
                  status,
                  SizedBox(width: context.spacing.xl),
                ],
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(136, 64),
                    textStyle: const TextStyle(
                      fontFamily: SurfaceTheme.displayFont,
                      fontSize: 24,
                      fontWeight: FontWeight.w400,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => unawaited(openSegnoSettings()),
                  child: AppText(l10n.stageSettings),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
