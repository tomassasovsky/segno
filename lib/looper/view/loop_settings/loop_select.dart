import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/theme/theme.dart';

/// One choice in a [LoopSelect] or [LoopMenu].
class LoopSelectItem<T> {
  /// Creates a choice. [key] lands on the menu row so tests can tap it.
  const LoopSelectItem({
    required this.value,
    required this.label,
    this.enabled = true,
    this.key,
  });

  /// What choosing this row selects.
  final T value;

  /// The row's name.
  final String label;

  /// Whether the row can be chosen right now.
  final bool enabled;

  /// The menu row's key.
  final Key? key;
}

/// Builds the control that opens a [LoopMenu]: toggle the menu, and read
/// whether it is showing, through [controller].
typedef LoopMenuAnchorBuilder =
    Widget Function(BuildContext context, MenuController controller);

/// The app's one pick-one menu: Flutter's [MenuAnchor] drawn in the surface
/// tokens, anchored below whatever [builder] draws.
///
/// Rows are 64 tall with 24 px labels; the current value is filled blue with
/// a check, and the focused or hovered row carries the amber encoder outline.
/// Opening focuses the current row, so arrows move, Enter chooses and Escape
/// closes — the traversal the physical encoder will drive.
class LoopMenu<T> extends StatefulWidget {
  /// Creates a menu anchored on [builder].
  const LoopMenu({
    required this.value,
    required this.items,
    required this.onSelected,
    required this.builder,
    this.width = 240,
    this.childFocusNode,
    super.key,
  });

  /// The current choice: its row is marked.
  final T value;

  /// The choices, top to bottom.
  final List<LoopSelectItem<T>> items;

  /// Called with the chosen value; the menu closes itself.
  final ValueChanged<T> onSelected;

  /// Draws the anchor.
  final LoopMenuAnchorBuilder builder;

  /// The menu's minimum width.
  final double width;

  /// The anchor's focus node, so focus returns to it when the menu closes.
  final FocusNode? childFocusNode;

  @override
  State<LoopMenu<T>> createState() => _LoopMenuState<T>();
}

class _LoopMenuState<T> extends State<LoopMenu<T>> {
  final _controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return MenuAnchor(
      controller: _controller,
      childFocusNode: widget.childFocusNode,
      alignmentOffset: const Offset(0, 8),
      // Rebuilds the anchor so it can draw itself open or closed.
      onOpen: () => setState(() {}),
      onClose: () => setState(() {}),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface.cardHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(surface.dropShadow),
        elevation: const WidgetStatePropertyAll(8),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        minimumSize: WidgetStatePropertyAll(Size(widget.width, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: surface.borderSubtle),
          ),
        ),
      ),
      menuChildren: [
        for (final item in widget.items) _row(context, item),
      ],
      builder: (context, controller, _) => widget.builder(context, controller),
    );
  }

  Widget _row(BuildContext context, LoopSelectItem<T> item) {
    final surface = context.surface;
    final selected = item.value == widget.value;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: MenuItemButton(
        key: item.key,
        autofocus: selected,
        onPressed: item.enabled ? () => widget.onSelected(item.value) : null,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size.fromHeight(64)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 20),
          ),
          backgroundColor: WidgetStatePropertyAll(
            selected ? surface.accentSurface : Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? surface.textPrimary.withValues(alpha: surface.disabledOpacity)
                : surface.textPrimary,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.hovered)
                ? BorderSide(color: surface.encoderFocus, width: 2)
                : BorderSide.none,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        trailingIcon: selected
            ? Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Icon(LucideIcons.check, size: 24, color: surface.accent),
              )
            : null,
        child: AppText(
          item.label,
          style: const TextStyle(fontSize: 24, height: 1),
        ),
      ),
    );
  }
}

/// The app's dropdown: a card showing the current choice's label and a
/// chevron, opening a [LoopMenu] of the choices below itself.
class LoopSelect<T> extends StatefulWidget {
  /// Creates a select showing [value]'s label.
  const LoopSelect({
    required this.value,
    required this.items,
    required this.onSelected,
    this.width = 240,
    this.height = 64,
    this.enabled = true,
    super.key,
  });

  /// The current choice.
  final T value;

  /// The choices, top to bottom; one of them carries [value].
  final List<LoopSelectItem<T>> items;

  /// Called with the chosen value.
  final ValueChanged<T> onSelected;

  /// The trigger's width, and the menu's minimum.
  final double width;

  /// The trigger's height.
  final double height;

  /// Whether the select opens.
  final bool enabled;

  @override
  State<LoopSelect<T>> createState() => _LoopSelectState<T>();
}

class _LoopSelectState<T> extends State<LoopSelect<T>> {
  final _focus = FocusNode(debugLabel: 'LoopSelect');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final label = widget.items
        .firstWhere((item) => item.value == widget.value)
        .label;
    return LoopMenu<T>(
      value: widget.value,
      items: widget.items,
      onSelected: widget.onSelected,
      width: widget.width,
      childFocusNode: _focus,
      builder: (context, controller) {
        final open = controller.isOpen;
        return Semantics(
          button: true,
          enabled: widget.enabled,
          expanded: open,
          label: label,
          excludeSemantics: true,
          child: Opacity(
            opacity: widget.enabled ? 1 : surface.disabledOpacity,
            child: ListenableBuilder(
              listenable: _focus,
              builder: (context, child) => Material(
                color: surface.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: _focus.hasFocus
                      ? BorderSide(color: surface.encoderFocus, width: 2)
                      : BorderSide(
                          color: open ? surface.accent : surface.borderSubtle,
                        ),
                ),
                clipBehavior: Clip.antiAlias,
                child: child,
              ),
              child: InkWell(
                focusNode: _focus,
                canRequestFocus: widget.enabled,
                onTap: widget.enabled
                    ? () => open ? controller.close() : controller.open()
                    : null,
                child: SizedBox(
                  width: widget.width,
                  height: widget.height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          // A translation longer than the box scales down
                          // rather than overflowing.
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: AppText(
                              label,
                              style: TextStyle(
                                color: surface.textPrimary,
                                fontSize: 24,
                                height: 1,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          open
                              ? LucideIcons.chevronUp
                              : LucideIcons.chevronDown,
                          size: 28,
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
      },
    );
  }
}
