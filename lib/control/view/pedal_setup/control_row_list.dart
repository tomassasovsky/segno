import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/control/view/pedal_setup/scroll_more_hint.dart';
import 'package:segno/theme/theme.dart';

/// One row naming a control: where it lives, over what it is, with what it
/// is doing on the right.
///
/// The one row the External pedals screen lists every kind of control with —
/// an expression pedal's sweeps, a button's effects and parameters, and the
/// choices offered when adding either — so the three read as one list.
class ControlRowTile extends StatelessWidget {
  /// Creates a [ControlRowTile].
  const ControlRowTile({
    required this.destination,
    required this.name,
    required this.onTap,
    this.value,
    this.valueKey,
    this.selected = false,
    this.available = true,
    this.taken = false,
    super.key,
  });

  /// Where the control lives.
  final String destination;

  /// What it is.
  final String name;

  /// What it is doing, on the right — or nothing.
  final String? value;

  /// The key of the value text, for a test to read it by.
  final Key? valueKey;

  /// Whether this row's rule is open.
  final bool selected;

  /// Whether the rig still has the control. An unavailable row keeps its
  /// place and dims its value; it is never repointed.
  final bool available;

  /// Whether this is an offered choice the list already carries: shown with a
  /// check and refused, not hidden, so a control does not vanish from a rig
  /// that has it.
  final bool taken;

  /// Opens or chooses the row.
  final VoidCallback onTap;

  /// The pen's row height.
  static const double height = 96;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final shown = value;
    return Semantics(
      button: true,
      selected: selected,
      enabled: !taken,
      label: '$destination $name',
      child: GestureDetector(
        onTap: taken ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: taken ? surface.disabledOpacity : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? surface.accentSurface : surface.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? surface.accent : surface.borderSubtle,
              ),
            ),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: Row(
                  children: [
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppText(
                              destination,
                              maxLines: 1,
                              style: TextStyle(
                                color: surface.textSecondary,
                                fontSize: 20,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 6),
                            AppText(
                              name,
                              maxLines: 1,
                              style: TextStyle(
                                color: surface.textPrimary,
                                fontSize: 27,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (shown != null) ...[
                      const SizedBox(width: 24),
                      AppText(
                        shown,
                        key: valueKey,
                        style: TextStyle(
                          color: available
                              ? surface.textPrimary
                              : surface.textTertiary,
                          fontSize: 27,
                          height: 1.15,
                        ),
                      ),
                    ],
                    if (taken)
                      Icon(
                        LucideIcons.check,
                        size: 24,
                        color: surface.textSecondary,
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

/// A scrolling list of [ControlRowTile]s at the pen's spacing, with the
/// overflow arrow, keeping the [selectedIndex] row in view.
///
/// Keeping it in view is not decoration: the list shrinks when a parameter's
/// two values open below it, and a selected row left scrolled out of sight
/// would have its values edited with nothing on screen saying whose they are.
class ControlRowList extends StatefulWidget {
  /// Creates a [ControlRowList].
  const ControlRowList({
    required this.itemCount,
    required this.itemBuilder,
    this.selectedIndex,
    super.key,
  });

  /// How many rows.
  final int itemCount;

  /// Builds one row.
  final IndexedWidgetBuilder itemBuilder;

  /// The row to keep in view, or `null`.
  final int? selectedIndex;

  /// The pen's spacing.
  static const double gap = 12;

  /// The inset around the rows.
  static const double padding = 4;

  @override
  State<ControlRowList> createState() => _ControlRowListState();
}

class _ControlRowListState extends State<ControlRowList> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(ControlRowList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only when WHICH row is selected, or how many there are, changed. A list
    // that re-revealed on every rebuild would snap back under a performer
    // scrolling it — and the expression pedal's list rebuilds each time the
    // pedal reports a position.
    if (oldWidget.selectedIndex == widget.selectedIndex &&
        oldWidget.itemCount == widget.itemCount) {
      return;
    }
    _revealSelected();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Scrolls just far enough to show the selected row, after layout — the
  /// viewport's height is not known before it.
  void _revealSelected() {
    final index = widget.selectedIndex;
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      final top = index * (ControlRowTile.height + ControlRowList.gap);
      final bottom = top + ControlRowTile.height + ControlRowList.padding * 2;
      final viewport = position.viewportDimension;
      final offset = position.pixels;
      final next = top < offset
          ? top
          : bottom > offset + viewport
          ? bottom - viewport
          : offset;
      final clamped = next.clamp(0.0, position.maxScrollExtent);
      if (clamped != offset) _controller.jumpTo(clamped);
    });
  }

  @override
  Widget build(BuildContext context) => ScrollMoreHint(
    controller: _controller,
    child: ListView.separated(
      controller: _controller,
      padding: const EdgeInsets.all(ControlRowList.padding),
      itemCount: widget.itemCount,
      separatorBuilder: (_, _) => const SizedBox(height: ControlRowList.gap),
      itemBuilder: widget.itemBuilder,
    ),
  );
}
