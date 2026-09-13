import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/theme/theme.dart';

/// The accepted design's overflow indicator: a small centred arrow at the
/// bottom of a list that has more rows below the ones showing.
///
/// Nonfocusable and out of the accessibility tree on purpose. It says "there
/// is more", which a screen reader already knows from the list itself, and it
/// must never take a touch meant for the row under it.
class ScrollMoreHint extends StatefulWidget {
  /// Creates a [ScrollMoreHint] over the scrollable [child] driven by
  /// [controller].
  const ScrollMoreHint({
    required this.controller,
    required this.child,
    super.key,
  });

  /// The controller of the list the hint watches.
  final ScrollController controller;

  /// The list.
  final Widget child;

  @override
  State<ScrollMoreHint> createState() => _ScrollMoreHintState();
}

class _ScrollMoreHintState extends State<ScrollMoreHint> {
  bool _more = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
  }

  @override
  void didUpdateWidget(ScrollMoreHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_check);
    widget.controller.addListener(_check);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final controller = widget.controller;
    if (!mounted || !controller.hasClients) return;
    final position = controller.position;
    // Two pixels of slack, so a list that ends a rounding error short of its
    // viewport does not show an arrow pointing at nothing.
    final more = position.hasContentDimensions && position.extentAfter > 2;
    if (more != _more) setState(() => _more = more);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // A list's extent is only known after it lays out, and it changes when
    // rows are added or removed without any scrolling to report it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (_more)
          Positioned(
            left: 0,
            right: 0,
            bottom: 6,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Center(
                  child: Container(
                    key: const Key('scroll_more_hint'),
                    width: 48,
                    height: 38,
                    decoration: BoxDecoration(
                      color: surface.background.withValues(alpha: 0.93),
                      borderRadius: BorderRadius.circular(19),
                      border: Border.all(color: surface.borderSubtle),
                    ),
                    child: Icon(
                      LucideIcons.chevronDown,
                      size: 28,
                      color: surface.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
