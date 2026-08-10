/// The console's shared row/card vocabulary, drawn to the `NETWORK / *` and
/// `CONTROL / *` screens in `segno-ui.pen`.
///
/// Started life as `lib/network/network_surface.dart`, beside the one domain
/// that had it, so the two tabs of that domain could not drift apart the way
/// the two former tray panels had — one had a wrapping card and the other
/// deliberately did not, one used `SetupGroupLabel` and the other a bare
/// `Row`, and nothing but attention held them together. It moved here, and
/// dropped its `Network` prefix, the moment a second domain read from it: a
/// primitive named after one caller invites the next caller to copy it
/// instead.
///
/// **The rule this promotion set:** a primitive lives here once a second
/// domain reads it, and keeps no domain in its name.
///
/// Everything here is layout with two exceptions, [ConsoleSwitch] and
/// [ConsoleCard]'s inset; both carry their reasoning on the class.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Height of one list row.
///
/// Fixed rather than intrinsic: a row is a touch target on a console operated
/// while standing over it, and a row that shrinks when its subtitle is absent
/// makes the target depend on the data.
const double kConsoleRowHeight = 70;

/// Horizontal inset of a row's content — also the left edge every title,
/// banner and switch in a card lines up on.
const double kConsoleRowInset = 20;

/// Width reserved for a row's disclosure marker.
const double kConsoleDisclosureWidth = 11;

/// The gap between a row's content and its trailing marks.
const double kConsoleRowGap = 14;

/// The gap above a group caption — the space that separates one group from
/// the last thing of the group before it.
///
/// The three gaps below are one rhythm, and the mockups set it the same way on
/// every face: **a caption belongs to what is under it**, so the gap below one
/// ([kConsoleLabelGap]) is smaller than the gap above it, and two blocks
/// inside one group sit at [kConsoleBlockGap] — between the two.
const double kConsoleGroupGap = 19;

/// The gap between a group caption and the card under it.
const double kConsoleLabelGap = 9;

/// The gap between two cards of the same group.
const double kConsoleBlockGap = 14;

/// How long a row takes to open or shut.
///
/// One duration for every transition on this surface — the row growing, its
/// tint arriving, the marker turning — so a single tap reads as one movement
/// instead of three that happen to start together.
const Duration kConsoleMotion = Duration(milliseconds: 180);

/// [kConsoleMotion], or nothing where the platform asks for no motion.
Duration consoleMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : kConsoleMotion;

/// Grows [child] in from nothing and shrinks it away again.
///
/// Height only: the width is the row's, and animating that too would drag the
/// card's edge around. The content is clipped while it moves, so the action
/// strip slides out from under the row it belongs to rather than overflowing
/// it.
///
/// Stateful rather than an [AnimatedSize] over a swapped child, because
/// closing has to animate too: a caller that stops building its actions the
/// moment a row shuts would leave this shrinking an empty box, which reads as
/// the chips vanishing and the gap collapsing afterwards. The last child is
/// held for exactly as long as the close takes, then dropped — so a shut row
/// has nothing of its own in the tree, and nothing tappable.
class ConsoleExpansion extends StatefulWidget {
  /// Creates a [ConsoleExpansion].
  const ConsoleExpansion({
    required this.expanded,
    required this.child,
    super.key,
  });

  /// Whether [child] is showing.
  final bool expanded;

  /// The block that grows and shrinks.
  final Widget child;

  @override
  State<ConsoleExpansion> createState() => _ConsoleExpansionState();
}

class _ConsoleExpansionState extends State<ConsoleExpansion>
    with SingleTickerProviderStateMixin {
  /// Built in [initState], not as a `late final` initialiser: a lazy field is
  /// created on first TOUCH, and a row that closes without ever having opened
  /// touches it first in [dispose] — where creating a ticker looks up
  /// `TickerMode` on an element that is already going away.
  late final AnimationController _controller;

  /// Opens fast and settles; closes without the overshooting ease-out, which
  /// on the way back looks like the strip hesitating before it goes.
  late final CurvedAnimation _size;

  /// The content fades over the back half of the growth and the front half of
  /// the shrink, so it is never fully lit while the box is still short.
  late final CurvedAnimation _fade;

  /// The child to keep drawing while closing. Null once the close finishes.
  Widget? _closing;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kConsoleMotion,
      value: widget.expanded ? 1 : 0,
    );
    _size = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.35, 1),
      reverseCurve: const Interval(0.45, 1),
    );
  }

  @override
  void didUpdateWidget(ConsoleExpansion old) {
    super.didUpdateWidget(old);
    if (widget.expanded == old.expanded) return;
    if (widget.expanded) {
      _closing = null;
      unawaited(_controller.forward());
    } else {
      // Hold what was showing so the close has something to shrink.
      _closing = old.child;
      unawaited(
        _controller.reverse().whenComplete(() {
          if (mounted) setState(() => _closing = null);
        }),
      );
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.expanded ? 1 : 0;
    }
    final child = widget.expanded ? widget.child : _closing;
    if (child == null) return const SizedBox(width: double.infinity);
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _size,
        // Anchored to the top: the strip slides out from under its row rather
        // than growing from the middle.
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: _fade, child: child),
      ),
    );
  }
}

/// A group of rows: one rounded, bordered card with hairlines between rows.
///
/// The 1px inset is load-bearing rather than decorative. Rows paint their
/// own hairline edge to edge, and without the inset that hairline crosses the
/// rounded corner instead of stopping inside it.
class ConsoleCard extends StatelessWidget {
  /// Creates a [ConsoleCard].
  const ConsoleCard({required this.children, this.fill, super.key});

  /// The rows, in display order.
  final List<Widget> children;

  /// The card's own fill; defaults to [SurfaceTheme.cardHigh].
  ///
  /// Only one caller overrides it, and for one reason: a list inside a panel
  /// that is *itself* a card has to recede, and a card the same tone as the
  /// panel behind it reads as no card at all. The per-track routing dialog
  /// passes [SurfaceTheme.background] so its two lists sit *in* the panel
  /// rather than beside it, which is how the mockups draw them.
  final Color? fill;

  /// Corner radius of the card.
  static const double radius = 12;

  /// What the card's own border adds to the height of the rows inside it.
  ///
  /// Public because every face that tells [ConsoleFace] how tall its last
  /// group is has to add it, and four copies of one widget's border width is
  /// four places to miss when it changes.
  static const double borderExtent = 2;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill ?? surface.cardHigh,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// The marker at a row's trailing edge saying the row does something.
///
/// `false` draws `▸` and `true` draws `▾`; **null** draws nothing and keeps
/// the space. The gutter is reserved **per group** rather than per row, so a
/// row without a marker still lines its trailing edge up with the rows that
/// have one — reserving per row instead makes a list's edge move as its
/// contents change state.
class ConsoleDisclosure extends StatelessWidget {
  /// Creates a [ConsoleDisclosure].
  ///
  /// [expanded] null draws nothing and keeps the space.
  const ConsoleDisclosure({this.expanded, super.key});

  /// Whether the row this marks is open; null when the row does not open.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final open = expanded;
    return SizedBox(
      width: kConsoleDisclosureWidth,
      child: open == null
          ? const SizedBox.shrink()
          : Text(
              open ? '▾' : '▸',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: surface.textMuted,
                fontFamily: SurfaceTheme.monoFont,
                fontSize: 13,
                height: 1.15,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
    );
  }
}

/// One row: `title / subtitle` on the left, an optional readout and a
/// disclosure marker on the right.
///
/// Two kinds of readout, because the mockups set them in two faces and mean
/// two things by them. [state] is a single lower-case word (`connected`,
/// `saved`, `sweep`, `switch`) in the mono face — a machine readout ABOUT the
/// row. [value] is a name the user recognises (`Dirty rhythm`, `Nektar
/// Pacer`) and is set in the text face like everything else they typed.
class ConsoleRow extends StatelessWidget {
  /// Creates a [ConsoleRow].
  const ConsoleRow({
    required this.title,
    this.subtitle,
    this.state,
    this.value,
    this.valueColor,
    this.titleColor,
    this.leading,
    this.mark,
    this.expanded,
    this.showDisclosure = true,
    this.trailing,
    this.fill,
    this.indented = false,
    this.onTap,
    this.showDivider = true,
    this.semanticLabel,
    this.customSemanticsActions,
    super.key,
  });

  /// Left-hand primary line.
  final String title;

  /// Left-hand secondary line. Omitted entirely when null — an unknown fact
  /// is not drawn as a blank one.
  final String? subtitle;

  /// The mono readout word at the trailing edge, if the row has one.
  final String? state;

  /// The proportional readout at the trailing edge — a name rather than a
  /// state word. Drawn after [state] when a row carries both.
  final String? value;

  /// Tint for [state] and [value]; defaults to [SurfaceTheme.textSecondary].
  /// A binding whose target is gone passes the warning tone here — rendering
  /// it in the muted grey of "unassigned" would state a different and wrong
  /// fact.
  final Color? valueColor;

  /// Tint for [title]; defaults to [SurfaceTheme.textPrimary].
  final Color? titleColor;

  /// A glyph ahead of the title.
  final Widget? leading;

  /// A glyph after the readout — the check on the target a switch is already
  /// bound to. A **check, not a tint**: tint already means "the row you
  /// opened" on this surface, and one mark cannot carry two meanings.
  final Widget? mark;

  /// Disclosure state; null for a row that shows no marker at all. See
  /// [ConsoleDisclosure] for why every row in a group passes one.
  final bool? expanded;

  /// Whether to reserve the disclosure gutter at all. False for a list where
  /// **no** row opens — the assign list acts on the tap — so its readouts sit
  /// against the card edge instead of against an empty column.
  final bool showDisclosure;

  /// A control that replaces the readouts and the marker — a [ConsoleSwitch],
  /// for a row that IS a setting rather than a thing that opens.
  final Widget? trailing;

  /// The row's own fill: [SurfaceTheme.accentSurface] for the switch being
  /// assigned, [SurfaceTheme.control] for a mapping opened in place. Animated,
  /// so a tap tints the row rather than repainting it between two frames.
  final Color? fill;

  /// Whether this row is one step in — an effect slot listed under the chain
  /// it belongs to.
  final bool indented;

  /// Tap action, or null for a row that is only a readout.
  final VoidCallback? onTap;

  /// Whether to paint the hairline below. False on the last row of a card.
  final bool showDivider;

  /// Overrides the announced label; defaults to title + subtitle + readouts.
  final String? semanticLabel;

  /// Extra actions announced on the row's own node — what a [leading] or
  /// [trailing] control does, when the row holds one.
  ///
  /// The row announces itself as ONE labelled control, which means the widgets
  /// it holds are excluded from semantics: their text would otherwise repeat
  /// the label. That is right for a glyph and wrong for a tap target, which
  /// disappears with it. A row that hands out a second action names it here.
  final Map<CustomSemanticsAction, VoidCallback>? customSemanticsActions;

  /// Left inset of an [indented] row.
  static const double indentedInset = 40;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final label =
        semanticLabel ??
        [title, subtitle, state, value].whereType<String>().join(', ');
    final readout = valueColor ?? surface.textSecondary;
    // [label] already SAYS the row's text, so announcing the visible words
    // again would read every one of them twice. On the tappable path
    // [FocusableTapTarget] silences the whole subtree for us; here it is done
    // PIECE BY PIECE, and never to [leading] or [trailing] — a row with no tap
    // of its own is exactly the row whose only control is one of those two,
    // and silencing it would take the control away rather than the echo.
    Widget quiet(Widget child) =>
        onTap == null ? ExcludeSemantics(child: child) : child;

    final row = AnimatedContainer(
      duration: consoleMotion(context),
      curve: Curves.easeOut,
      height: kConsoleRowHeight,
      padding: EdgeInsets.only(
        left: indented ? indentedInset : kConsoleRowInset,
        right: kConsoleRowInset,
      ),
      // Transparent rather than absent while untinted, so the colour lerps
      // instead of the box being rebuilt without one.
      decoration: BoxDecoration(color: fill ?? surface.control.withAlpha(0)),
      // The hairline is painted OVER the row, not around it: a border in
      // `decoration` insets what it wraps, so a divider that comes and goes
      // with an open row would step the content half a pixel each way.
      foregroundDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: showDivider ? surface.borderHairline : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        children: [
          if (leading case final glyph?) ...[
            glyph,
            const SizedBox(width: kConsoleRowGap),
          ],
          Expanded(
            child: quiet(
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor ?? surface.textPrimary,
                      fontSize: 17,
                      height: 1.18,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                  if (subtitle case final sub?) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textMuted,
                        fontSize: 14,
                        height: 1.21,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (trailing case final control?) ...[
            const SizedBox(width: kConsoleRowGap),
            control,
          ] else ...[
            if (state case final word?) ...[
              const SizedBox(width: kConsoleRowGap),
              quiet(
                Text(
                  word,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: readout,
                    fontFamily: SurfaceTheme.monoFont,
                    fontSize: 14,
                    height: 1.14,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ),
            ],
            if (value case final name?) ...[
              const SizedBox(width: kConsoleRowGap),
              Expanded(
                child: quiet(
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: readout,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ),
              ),
            ],
            if (mark case final glyph?) ...[
              const SizedBox(width: kConsoleRowGap),
              quiet(glyph),
            ],
            if (showDisclosure) ...[
              const SizedBox(width: kConsoleRowGap),
              quiet(ConsoleDisclosure(expanded: expanded)),
            ],
          ],
        ],
      ),
    );

    if (onTap == null) {
      // The actions come along here too: a row whose ONLY interactive part is
      // its [leading] or [trailing] control is exactly the row that has no tap
      // of its own, so dropping them on this path would strand them in the
      // case the parameter exists for.
      //
      // The row goes in as it is: `quiet` has already silenced the text that
      // would echo [label], and what is left is the controls this path exists
      // to carry.
      return Semantics(
        label: label,
        customSemanticsActions: customSemanticsActions,
        child: row,
      );
    }
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      customSemanticsActions: customSemanticsActions,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// The caption over a group of rows — `TRANSPORT SWITCHES`, `MIDI FOOT
/// CONTROLLER`.
///
/// Upper-cased by the caller through its own string, not by this widget: a
/// locale where the group name is not upper-cased must be able to say so, and
/// `toUpperCase()` here would take that away.
class ConsoleGroupLabel extends StatelessWidget {
  /// Creates a [ConsoleGroupLabel].
  const ConsoleGroupLabel(this.label, {super.key});

  /// The caption.
  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Text(
      label,
      style: TextStyle(
        color: surface.textMuted,
        fontSize: 13,
        height: 1.23,
        // The mockups set these captions at 1.2 on one tab and 0.91 on the
        // other. One value, since a caption is one thing: the wider tracking
        // is what three of the five screens carry.
        letterSpacing: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// A sentence of explanation under a group label — what the group is for, or
/// what the protocol below it says.
class ConsoleProse extends StatelessWidget {
  /// Creates a [ConsoleProse].
  const ConsoleProse(this.text, {super.key});

  /// The sentence.
  final String text;

  /// The width the mockups wrap this prose at. Left free rather than
  /// stretched to the pane: a 1700px measure is unreadable, and the mockups
  /// wrap it well short of the edge.
  static const double maxWidth = 923;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: Text(
        text,
        style: TextStyle(
          color: surface.textMuted,
          fontSize: 14,
          height: 1.5,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

/// A group caption that can explain what its controls do.
///
/// The console names its controls accurately and explains them nowhere. "In
/// the mix", "hear while playing" — someone who built this knows what they
/// mean; nobody else does, and there is no manual, no hover and no tooltip on
/// a screen operated with a foot.
///
/// **Per GROUP, not per control.** A `?` on every switch would litter a dense
/// face, and one help page per screen makes you hunt for the control you were
/// confused about. A caption already names a group, so it is where the
/// question belongs.
///
/// **A floating answer, not inline prose.** It began inline, under the
/// caption, on the argument that an overlay covers the control it explains.
/// What inline actually did was push every control below it down by a
/// paragraph's height — on a face with four captions that is most of a 600px
/// console, and the shove lands under the finger that just tapped. The
/// overlay opens under the caption, over the face, and closes on the next
/// touch anywhere; the control it describes is one tap away, unmoved.
class ConsoleCaption extends StatefulWidget {
  /// Creates a [ConsoleCaption].
  const ConsoleCaption(
    this.label, {
    this.explain,
    this.explainLabel,
    this.trailing,
    super.key,
  }) : assert(
         (explain == null) == (explainLabel == null),
         'explain and explainLabel travel together: an explanation with no '
         'label is an unnamed button, and a label with no explanation is a '
         'button that does nothing.',
       );

  /// The caption itself.
  final String label;

  /// What the group's controls do, in plain language — or null for a caption
  /// whose own word is the whole answer.
  final String? explain;

  /// What a screen reader calls the button that opens [explain]. A row of
  /// identical "?" buttons says nothing about which control each belongs to.
  final String? explainLabel;

  /// Controls that belong beside the caption, at the trailing edge of its
  /// row — a chain's power switch, say.
  ///
  /// Here rather than in a `Row` around this widget, because the explanation
  /// has to escape that row: a paragraph sharing a row with controls gets a
  /// fraction of the width and stacks into a narrow column with the panel
  /// blank beside it, and without a `Flexible` it overflows them off screen
  /// instead. Given the row, the caption can put its controls IN it and its
  /// prose UNDER it, at the full width the panel has.
  final Widget? trailing;

  /// The glyph's drawn size.
  static const double _glyphSize = 18;

  /// Gap between the caption's question mark and whatever rides beside it.
  static const double _captionGap = 16;

  /// Minimum height of the tappable caption row. 48, not the 44 of Apple's
  /// guideline: Android's is the stricter of the two and this is a console
  /// people stand over, where the finger arrives at a worse angle than either
  /// guideline assumes.
  static const double _targetHeight = 48;

  @override
  State<ConsoleCaption> createState() => _ConsoleCaptionState();
}

class _ConsoleCaptionState extends State<ConsoleCaption> {
  final GlobalKey _anchorKey = GlobalKey();
  final _portal = OverlayPortalController();
  bool _open = false;

  /// Where the caption sits in the overlay.
  ///
  /// Measured rather than followed: a `CompositedTransformFollower` moves the
  /// answer with the caption but cannot see the screen, so it will happily
  /// place a paragraph past the bottom edge — which on the 1024x600 console is
  /// exactly what the lowest caption on the panel did. Positioning from a rect
  /// lets the layout flip the answer above the caption when there is no room
  /// under it.
  ///
  /// Re-measured after every frame it is open, which is what the follower gave
  /// for free. The barrier stops a FINGER reaching the face, not the face
  /// changing under it: this panel grows an overdub-mismatch notice on its own,
  /// the rig can add a lane while you read, and a desktop window resizes. Any
  /// of those moved the caption and left the answer hanging off nothing.
  Rect? _anchor;

  /// Whether a re-measuring chain is already running. See [_watchAnchor].
  bool _watching = false;

  @override
  void didUpdateWidget(ConsoleCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A caption that loses its explanation while the answer is up takes the
    // overlay out of the tree without closing it, and `_open` stays true — so
    // the next tap toggles the state SHUT and the one after it opens, which
    // from the outside is a `?` that ignores you. Rare, but the null-explain
    // caption is a supported shape of this widget, not a hypothetical.
    //
    // The FLAG only, not [_close]: this runs inside the build that is about to
    // drop the portal, and `hide()` asserts when it is called during one. The
    // rebuild takes the overlay away by itself; all that is left is to stop
    // believing it is up.
    if (widget.explain == null) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final explain = widget.explain;
    final caption = Text(
      widget.label,
      style: TextStyle(
        color: surface.textSecondary,
        fontSize: 14,
        height: 1.21,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    final trailing = widget.trailing;
    if (explain == null) {
      if (trailing == null) return caption;
      // The same row the explaining caption builds, minus the question — same
      // gap included. Two shapes of one widget that differ by a spacer is how
      // a group with a `?` and a group without stop looking like siblings.
      return Row(
        children: [
          caption,
          const SizedBox(width: ConsoleCaption._captionGap),
          Expanded(child: trailing),
        ],
      );
    }

    // One row, whatever happens. The explanation is an OVERLAY, so opening it
    // moves nothing: as inline prose it pushed every control on the card down
    // by its own height, which on a face with four captions is most of a
    // small console's screen, and it did it under the reader's finger.
    final button = OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => _Explanation(
        anchor: _anchor ?? Rect.zero,
        text: explain,
        surface: surface,
        onDismiss: _close,
        // Flutter's own word for this, not one of ours: every barrier in the
        // app should say the same thing to a reader, and this one is already
        // translated into every locale the framework ships.
        dismissLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
      ),
      child: _button(surface, caption),
    );
    if (trailing == null) return button;
    // `Expanded`, so [trailing]'s own flex children get a bounded width: this
    // row shrink-wraps otherwise, and a `Flexible` inside an unbounded row is
    // a layout assertion.
    return Row(
      children: [
        button,
        // The controls do not butt against the question mark.
        const SizedBox(width: ConsoleCaption._captionGap),
        Expanded(child: trailing),
      ],
    );
  }

  /// The caption and its glyph, which together ARE the button.
  ///
  /// The whole caption and not just the glyph, and a real 48px of it: an
  /// `OverflowBox` around an 18px child grows what is PAINTED and not what is
  /// hit — every ancestor's `hitTest` rejects a pointer outside its own size
  /// before the larger child is consulted — so the earlier version drew a
  /// 48px affordance you had to hit within 18px of centre. On a floor unit
  /// aimed at with a foot-height finger that is the difference between a
  /// control and a decoration.
  ///
  /// The label opens it too. A `?` that only answers when struck dead centre
  /// teaches people it is broken; the words beside it are the same question.
  Widget _button(SurfaceTheme surface, Widget caption) => Semantics(
    key: _anchorKey,
    button: true,
    expanded: _open,
    label: widget.explainLabel,
    child: InkWell(
      key: const Key('console_caption_explain'),
      onTap: _toggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: ConsoleCaption._targetHeight,
        ),
        // Inside the InkWell, not around it: outside, the exclusion swallows
        // the tap action too, and the node a reader lands on is a button it
        // cannot press. Inside, the gesture survives and only the words go —
        // the label already says them, and the bare "?" was being read out.
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [caption, const SizedBox(width: 8), _glyph(surface)],
          ),
        ),
      ),
    ),
  );

  /// The `?` itself. Drawn, never hit — [_button] is the target.
  Widget _glyph(SurfaceTheme surface) => Container(
    width: ConsoleCaption._glyphSize,
    height: ConsoleCaption._glyphSize,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: _open ? surface.accent : surface.borderStrong),
      color: _open ? surface.accent : null,
    ),
    child: Center(
      child: Text(
        '?',
        style: TextStyle(
          color: _open ? surface.onAccent : surface.textSecondary,
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w600,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    ),
  );

  /// Catches the caption up with wherever each frame put it, until it closes.
  ///
  /// After every frame rather than on every build, because the caption is not
  /// what rebuilds when it moves: a notice appearing above it, or a window
  /// resize, leaves this widget untouched and its position different. Cheap
  /// and self-limiting — it schedules no frame of its own (so it costs nothing
  /// on a still screen), and a measurement equal to the one held does not
  /// `setState`, so it cannot spin.
  ///
  /// Both its guards are pinned by tests: dropping `mounted` fails seven of
  /// them, and dropping the arming call fails the one that moves the face.
  /// That it stops on CLOSE is deliberately NOT claimed as proven — a chain
  /// that kept running would measure, find nothing changed and be invisible
  /// from outside the widget.
  ///
  /// [_watching] holds it to one chain. The barrier does NOT: `show()` only
  /// marks this state dirty, so the barrier is not in the render tree until
  /// the next frame is built, and every touch arriving in that gap lands on
  /// the `?` itself. Taps inside one frame interval — a bouncing panel, a
  /// double-tap — arm a chain each, and each is a `findRenderObject` plus a
  /// `localToGlobal` on every frame until the answer closes. Bounded, since
  /// they all die at the first post-frame after `_open` goes false, and still
  /// work nobody asked for on an appliance.
  ///
  /// Not pinned by a test, and it cannot be: chain count is invisible from
  /// outside the widget — two chains measure the same rect and produce the
  /// same one rebuild as one. It stays because the state is reproducible with
  /// an instrumented chain id, not because it might happen.
  void _watchAnchor() {
    if (_watching) return;
    _watching = true;
    void tick() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_open) {
          _watching = false;
          return;
        }
        final now = _measure();
        if (now != null && now != _anchor) setState(() => _anchor = now);
        tick();
      });
    }

    tick();
  }

  /// The caption's rect in the overlay's own coordinates, or null if either
  /// render object is missing — which only happens before the first layout,
  /// and a caption cannot be tapped before then.
  Rect? _measure() {
    final box = _anchorKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return null;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    return topLeft & box.size;
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _portal.hide();
  }

  /// Opens or closes, and SAYS which.
  ///
  /// Focus stays on the button, so without this a reader hears nothing at all
  /// — the paragraph it just summoned is only found by swiping forward, which
  /// is a poor result for a control whose entire job is answering a question.
  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    setState(() {
      _open = true;
      _anchor = _measure();
    });
    _portal.show();
    _watchAnchor();
    final explain = widget.explain;
    if (explain != null) {
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          explain,
          Directionality.of(context),
        ),
      );
    }
  }
}

/// The floating answer, anchored under the `?` that summoned it.
///
/// A barrier under it rather than beside it: an explanation that stays up
/// while you go and use the control it describes is a panel, not an answer,
/// and this surface already has one thing at a time everywhere else.
class _Explanation extends StatelessWidget {
  const _Explanation({
    required this.anchor,
    required this.text,
    required this.surface,
    required this.onDismiss,
    required this.dismissLabel,
  });

  /// The caption's rect, in the overlay's coordinates.
  final Rect anchor;
  final String text;
  final SurfaceTheme surface;
  final VoidCallback onDismiss;
  final String dismissLabel;

  /// Wide enough for a sentence to breathe, narrow enough to read as a note
  /// about one control rather than as the face's own body text.
  static const double _width = 460;

  /// Keeps the answer off the screen edge on every side.
  static const double _margin = 12;

  /// How far the answer rides up into the caption's own row, so it reads as
  /// hanging off the `?` rather than floating loose under it. The row is 48px
  /// tall around a 17px line, so this eats slack, not the caption.
  static const double _overlap = 6;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // Dismiss on a tap anywhere else, INCLUDING on another caption's `?`:
      // that tap closes this one and the next tap opens that one, which is
      // one tap more than it looks like it should be, and still better than
      // two explanations open over each other.
      //
      // A real barrier, not a GestureDetector: the face underneath must not
      // take a drag either. A bare tap-only detector absorbs the touch and
      // then nothing recognises the gesture, so a scroll under an open answer
      // silently does nothing — which reads as the console having frozen.
      // `ModalBarrier` blocks POINTERS on every platform, and brings its own
      // `BlockSemantics` for readers — but it only offers the DISMISS action
      // where the host platform has a back gesture, which it reads as Android,
      // iOS and macOS. On Linux, Windows and Fuchsia it excludes itself from
      // semantics entirely, and since the face behind is blocked either way, a
      // reader was left holding one paragraph and no way out. This console
      // SHIPS on Linux.
      Positioned.fill(
        child: ModalBarrier(
          key: const Key('console_caption_scrim'),
          semanticsLabel: dismissLabel,
          onDismiss: onDismiss,
        ),
      ),
      // And a keyboard is the third way in, which the barrier does not cover
      // at all: tab walked straight through it to the control the answer was
      // describing, and space operated it with the answer still up — the
      // "panel, not an answer" state the class doc rejects. The scope keeps
      // traversal in here; `DismissIntent` is what Escape already means
      // everywhere else in the app.
      Positioned.fill(
        child: FocusScope(
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) => onDismiss(),
              ),
            },
            child: Focus(
              autofocus: true,
              child: CustomSingleChildLayout(
                delegate: _ExplanationLayout(anchor),
                // So the answer itself carries the way out, on every platform
                // — and carries it on the SAME node as the words. Split across
                // two, the node that answers the question announces nothing
                // and the node that announces it cannot be closed, so a reader
                // has to swipe back to silence to get out.
                child: Semantics(
                  container: true,
                  label: text,
                  onDismiss: onDismiss,
                  child: Material(
                    key: const Key('console_caption_explanation'),
                    color: surface.cardHigh,
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                      // Scrolls only when the answer is taller than the room
                      // on either side of the caption — which the longest of
                      // them is, on the short console, with the tallest
                      // caption open. Clipping instead would drop the last
                      // sentence, and the last sentence is where these
                      // paragraphs put the consequence.
                      //
                      // The prose is excluded because the label above already
                      // IS it: left in, the same paragraph is a second node,
                      // and which one a reader lands on decides whether they
                      // can close it.
                      child: SingleChildScrollView(
                        child: ExcludeSemantics(child: ConsoleProse(text)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Puts the answer under its caption, or above it when the screen is out of
/// room, and never past an edge.
///
/// Left-anchored, not leading-anchored: the app ships `en` and `es`, and a
/// direction this delegate never receives would be a parameter nothing could
/// exercise. An RTL locale would want [getPositionForChild] to hang the answer
/// off `anchor.right` instead.
class _ExplanationLayout extends SingleChildLayoutDelegate {
  const _ExplanationLayout(this.anchor);

  /// The caption's rect, in the same coordinates as the laid-out box.
  final Rect anchor;

  /// The taller of the two gaps the answer could occupy.
  double _room(BoxConstraints constraints) => math.max(
    constraints.maxHeight - anchor.bottom - _Explanation._margin,
    anchor.top - _Explanation._margin,
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(
          _Explanation._width,
          math.max(0, constraints.maxWidth - _Explanation._margin * 2),
        ),
        // Plus the overlap, which is room the answer gets back by sitting in
        // the caption's own row.
        maxHeight: math.max(0, _room(constraints) + _Explanation._overlap),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = anchor.bottom - _Explanation._overlap;
    final fitsBelow =
        below + childSize.height <= size.height - _Explanation._margin;
    final top = fitsBelow
        ? below
        : anchor.top + _Explanation._overlap - childSize.height;
    // Leading edge of the caption, where the eye already is — pulled back
    // only by however much of the answer would otherwise leave the screen.
    return Offset(
      _clamp(anchor.left, size.width, childSize.width),
      _clamp(top, size.height, childSize.height),
    );
  }

  /// Keeps `start` inside a [span] with a margin at both ends, preferring the
  /// near edge when the child is too big for the span at all.
  static double _clamp(double start, double span, double extent) => start.clamp(
    _Explanation._margin,
    math.max(_Explanation._margin, span - extent - _Explanation._margin),
  );

  @override
  bool shouldRelayout(_ExplanationLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

/// A row that can open in place: the row itself over a tinted, bordered card
/// of its actions.
///
/// Rows open **in place**, one at a time. A tap that pushes a sheet loses the
/// list it came from, and on a console the list is the context for the action.
///
/// Always in the tree, open or shut, so opening is a transition rather than a
/// swap. Building the shut state as a bare row and the open state as this
/// widget makes the tint, the border and the whole action strip appear between
/// two frames, which on a 70px row reads as the list jolting.
class ConsoleExpandedRow extends StatelessWidget {
  /// Creates a [ConsoleExpandedRow].
  const ConsoleExpandedRow({
    required this.row,
    required this.actions,
    this.expanded = true,
    super.key,
  });

  /// The row, drawn with `expanded: true` when this is open.
  final Widget row;

  /// The action chips, laid out at the trailing edge.
  final List<Widget> actions;

  /// Whether the actions are showing.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return AnimatedContainer(
      duration: consoleMotion(context),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        // Transparent rather than absent while shut: a null decoration would
        // rebuild the box on every open and lose the colour lerp.
        color: expanded ? surface.control : surface.control.withAlpha(0),
        borderRadius: BorderRadius.circular(ConsoleCard.radius),
        border: Border.all(
          color: expanded ? surface.borderSubtle : Colors.transparent,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          ConsoleExpansion(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                kConsoleRowInset,
                0,
                kConsoleRowInset,
                14,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (index, action) in actions.indexed) ...[
                    if (index > 0) const SizedBox(width: 10),
                    action,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One action inside an opened row: a pill with an icon and a label.
///
/// [destructive] recolours the outline and the label rather than filling the
/// pill — a filled red chip inside a list row reads as a state the row is in.
class ConsoleActionChip extends StatelessWidget {
  /// Creates a [ConsoleActionChip].
  const ConsoleActionChip({
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    super.key,
  });

  /// Visible caption.
  final String label;

  /// Leading glyph, or null for a chip that is only a word — the mapping
  /// editor's Relearn / Remove, where the pair sits under a control the row
  /// already names and a second glyph adds nothing to read.
  final IconData? icon;

  /// Tap action; null disables the chip.
  final VoidCallback? onPressed;

  /// Whether this action destroys something.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = destructive ? surface.rec : surface.textSecondary;
    final edge = destructive ? surface.recLine : surface.line;
    return Opacity(
      opacity: onPressed == null ? surface.disabledOpacity : 1,
      child: FocusableTapTarget(
        onTap: onPressed,
        semanticLabel: label,
        borderRadius: 999,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: edge),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon case final glyph?) ...[
                  Icon(glyph, size: 17, color: tint),
                  const SizedBox(width: 10),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: tint,
                    fontSize: 14,
                    height: 1.21,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A domain's whole face: its name, its tab strip, and the tab's body.
///
/// **The title sits above the strip.** A tab that carries a per-tab control (a
/// radio's power switch, a rescan) needs a title row to hang it on and puts
/// its tabs first; a domain whose tabs carry no such control says its name
/// once, at the top. That is the mockups' own distinction, and Control and
/// Loop are both on the second side of it — which is why they were the same
/// widget written twice before this existed.
class ConsoleDomainPanel<T> extends StatelessWidget {
  /// Creates a [ConsoleDomainPanel].
  const ConsoleDomainPanel({
    required this.title,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.body,
    this.tabsKey,
    super.key,
  });

  /// The domain's name.
  final String title;

  /// The tabs, in display order.
  final List<PillTab<T>> tabs;

  /// The showing tab.
  final T selected;

  /// Called with the newly chosen tab.
  final ValueChanged<T> onChanged;

  /// The showing tab's body; fills the rest of the sheet.
  final Widget body;

  /// Key for the strip, so a test can find one domain's tabs.
  final Key? tabsKey;

  /// Gap between the title and the strip, as the mockups set it.
  static const double titleGap = 14;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            color: surface.textPrimary,
            fontSize: 20,
            height: 1.15,
            leadingDistribution: TextLeadingDistribution.even,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: titleGap),
        Align(
          alignment: Alignment.centerLeft,
          child: PillTabs<T>(
            key: tabsKey,
            selected: selected,
            onChanged: onChanged,
            tabs: tabs,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

/// A domain face's title row: its name, an optional live-state line, and that
/// surface's own controls.
///
/// The domain says its name **here**, not in a chrome bar above the tab strip.
/// The rail is always on screen, so a chrome bar would be a second navigation
/// surface, and a per-tab control (a rescan, a power switch) belongs to the
/// tab rather than to the domain — which puts the tabs first and the title
/// under them.
class ConsoleFaceHeader extends StatelessWidget {
  /// Creates a [ConsoleFaceHeader].
  const ConsoleFaceHeader({
    required this.title,
    this.status,
    this.actions = const [],
    super.key,
  });

  /// The face's name.
  final String title;

  /// A live-state line beside the title — "joining Studio 5G", "could not
  /// pair with AirTurn BT-200". Echoes what the banner says, at the one place
  /// the eye is already on.
  final String? status;

  /// The face's own controls, at the trailing edge.
  final List<Widget> actions;

  /// Height of the row; the rescan button's own height, so the title's
  /// baseline does not move when the button appears.
  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              height: 1.15,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: status == null
                ? const SizedBox.shrink()
                : Text(
                    status!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
          ),
          for (final (index, action) in actions.indexed) ...[
            if (index > 0) const SizedBox(width: 10),
            action,
          ],
        ],
      ),
    );
  }
}

/// A square icon button for a face header — the rescan control.
///
/// Spins the glyph rather than swapping in a `CircularProgressIndicator`: the
/// control and its own busy state are the same object, so the button does not
/// move or resize when a scan starts.
class ConsoleIconButton extends StatefulWidget {
  /// Creates a [ConsoleIconButton].
  const ConsoleIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.spinning = false,
    super.key,
  });

  /// The glyph.
  final IconData icon;

  /// Tap action; null disables the button.
  final VoidCallback? onPressed;

  /// Hover/long-press explanation, and the announced label.
  final String tooltip;

  /// Whether the glyph should turn.
  final bool spinning;

  @override
  State<ConsoleIconButton> createState() => _ConsoleIconButtonState();
}

class _ConsoleIconButtonState extends State<ConsoleIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) unawaited(_spin.repeat());
  }

  @override
  void didUpdateWidget(ConsoleIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning == oldWidget.spinning) return;
    if (widget.spinning) {
      unawaited(_spin.repeat());
    } else {
      _spin
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Tooltip(
      message: widget.tooltip,
      child: Opacity(
        opacity: widget.onPressed == null ? surface.disabledOpacity : 1,
        child: FocusableTapTarget(
          onTap: widget.onPressed,
          semanticLabel: widget.tooltip,
          borderRadius: 10,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: surface.line),
              ),
              child: RotationTransition(
                turns: _spin,
                child: Icon(
                  widget.icon,
                  size: 19,
                  color: surface.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The console's switch: a 53x31 pill with a 25px knob.
///
/// Hand-drawn rather than Material's [Switch], which brings its own 40x24
/// geometry, ripple and thumb elevation — none of which the mockups have, and
/// all of which read as borrowed once the switch is sitting in a list row
/// beside a hand-drawn card. #498 also settles that a boolean is a switch and
/// never the words "on" and "off".
class ConsoleSwitch extends StatelessWidget {
  /// Creates a [ConsoleSwitch].
  const ConsoleSwitch({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.small = false,
    super.key,
  });

  /// Whether the switch is on.
  final bool value;

  /// Called with the new value; null disables the switch.
  final ValueChanged<bool>? onChanged;

  /// The announced label.
  final String? semanticLabel;

  /// The pen's `ToggleSm` rather than its `Toggle` — the size the FX
  /// parameter grid uses, where a full-size switch would be wider than the
  /// 78px tile that holds it.
  final bool small;

  /// Track size for a row switch.
  static const Size trackSize = Size(53, 31);

  /// Track size inside a parameter tile.
  static const Size smallTrackSize = Size(37, 22);

  /// Knob diameter for a row switch.
  static const double knobSize = 25;

  /// Knob diameter inside a parameter tile.
  static const double smallKnobSize = 18;

  static const double _inset = 3;

  Size get _track => small ? smallTrackSize : trackSize;

  double get _knob => small ? smallKnobSize : knobSize;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final changed = onChanged;
    final pill = Opacity(
      opacity: changed == null ? surface.disabledOpacity : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: _track.width,
        height: _track.height,
        decoration: BoxDecoration(
          color: value ? surface.accent : surface.control,
          borderRadius: BorderRadius.circular(_track.height),
          border: Border.all(color: value ? surface.accent : surface.line),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              top: _inset - 1,
              left: value ? _track.width - _knob - _inset - 1 : _inset - 1,
              child: Container(
                width: _knob,
                height: _knob,
                decoration: BoxDecoration(
                  color: value ? surface.onAccent : surface.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: FocusableTapTarget(
        onTap: changed == null ? null : () => changed(!value),
        borderRadius: _track.height,
        semanticLabel: semanticLabel,
        child: GestureDetector(
          onTap: changed == null ? null : () => changed(!value),
          child: pill,
        ),
      ),
    );
  }
}

/// The phase of whatever the list is currently doing.
enum ConsoleBannerTone {
  /// Something is in flight — amber.
  pending,

  /// Something just failed, or nothing is there to do it with — red.
  failure,

  /// A plain, settled fact about the list — green. The link is up.
  steady,
}

/// A strip at the top of a list saying what is in flight or what just failed.
///
/// A banner and not a dialog: the flow it describes is *about* the list, so it
/// belongs in the list rather than over it — and the rows stay live behind it,
/// which a modal would not allow. One banner carries a whole flow; its dot and
/// its action change with the phase.
class ConsoleBanner extends StatelessWidget {
  /// Creates a [ConsoleBanner].
  const ConsoleBanner({
    required this.message,
    required this.tone,
    this.actions = const [],
    this.progress,
    super.key,
  });

  /// What is happening, in the words a toast would have used.
  final String message;

  /// Which phase this is.
  final ConsoleBannerTone tone;

  /// What the banner offers, if anything — Cancel while listening, Keep and
  /// Replace once a control that is already mapped has been caught. A banner
  /// that only explains (the idle notice at the head of the mapping list)
  /// carries none.
  final List<Widget> actions;

  /// How far along the thing described is, `0..1`, or null when it is not the
  /// kind of thing that has a "how far".
  ///
  /// Under the message rather than beside it, because the message already
  /// carries the percentage in words and the bar is the same fact drawn — a
  /// bar in the action slot would read as a control. `SYSTEM /
  /// update-downloading` is the one screen that draws it, and it is the one
  /// phase on this console with a genuinely long, genuinely observable middle:
  /// `UpdateCubit` emits a fresh progress on every chunk the repository yields.
  final double? progress;

  /// The dot's diameter — also the reason the banner is 46px tall with no
  /// action and 61px with one: the button is taller than the sentence.
  static const double dotSize = 11;

  /// Thickness of the [progress] track.
  static const double progressHeight = 7;

  /// The gap between the message and the [progress] track under it.
  static const double progressGap = 10;

  /// The track's own key: a bar has no text to assert on, and "the banner
  /// rendered" is not the same claim as "the banner drew a bar".
  static const Key progressKey = Key('console_banner_progress');

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final dot = switch (tone) {
      ConsoleBannerTone.pending => surface.warning,
      ConsoleBannerTone.failure => surface.rec,
      ConsoleBannerTone.steady => surface.success,
    };
    return Container(
      color: surface.background,
      // Indented past a row's own inset: the banner belongs to the list
      // rather than being one of its rows, and the mockups step it in on both
      // the Network and the Control faces to say so.
      padding: const EdgeInsets.fromLTRB(
        ConsoleRow.indentedInset,
        14,
        kConsoleRowInset,
        14,
      ),
      child: Row(
        children: [
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: kConsoleRowGap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 16,
                    height: 1.13,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
                if (progress case final fraction?) ...[
                  const SizedBox(height: progressGap),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(progressHeight / 2),
                    child: LinearProgressIndicator(
                      key: progressKey,
                      value: fraction.clamp(0.0, 1.0),
                      minHeight: progressHeight,
                      backgroundColor: surface.control,
                      valueColor: AlwaysStoppedAnimation(surface.accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final action in actions) ...[const SizedBox(width: 10), action],
        ],
      ),
    );
  }
}

/// A short, low-emphasis button — the banner's Cancel / Try again.
class ConsoleSmallButton extends StatelessWidget {
  /// Creates a [ConsoleSmallButton].
  const ConsoleSmallButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  /// Visible caption, and the announced label.
  final String label;

  /// Tap action; null disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: onPressed == null ? surface.disabledOpacity : 1,
      child: FocusableTapTarget(
        onTap: onPressed,
        semanticLabel: label,
        borderRadius: 10,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 33,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: surface.borderStrong),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 14,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a face draws where a list would be, when there is nothing to list.
///
/// Bordered and empty rather than a bare line of text: the shape of the list
/// stays, so an empty list reads as "nothing here" rather than as a face that
/// failed to draw.
class ConsoleEmptyCard extends StatelessWidget {
  /// Creates a [ConsoleEmptyCard].
  const ConsoleEmptyCard({required this.message, super.key});

  /// The sentence to show.
  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: 78,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ConsoleCard.radius),
        border: Border.all(color: surface.borderStrong),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: surface.textMuted,
          fontSize: 16,
          height: 1.13,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

/// The double-tap-to-default window, for a console control with a default
/// worth snapping back to.
///
/// Wired into four callbacks: [armReset] from `onTapDown`, [spendReset] from
/// `onTapUp`, [dropReset] from `onTapCancel`, and [closeResetWindow] when a
/// drag starts. Miss the last one and the tap that ends a drag becomes half a
/// pair.
///
/// Not every reset in the app comes through here: `SignalKnob` has its own on
/// `onDoubleTap`, which it can afford because its single tap only takes focus
/// — there is no immediate action for the recognizer's latency to delay.
///
/// **Not** `GestureDetector.onDoubleTap`: a disambiguating recognizer charges
/// its latency to the common path, so every single tap would wait out
/// `kDoubleTapTimeout` — a third of a second of nothing on a control people
/// drag. The first tap applies immediately and opens a window; a second tap
/// inside it overrides with the default.
///
/// It has to be the same tap twice, and both halves are measured off the
/// RELEASE, the way Flutter's own recognizer measures them:
/// - **the window opens on tap-UP.** A tap-down is not yet a tap: the pointer
///   can still be stolen by the scroll view the face sits in, and a cancelled
///   press must not leave a live window for the next real tap to fall into.
///   Anchoring on the release also gives the second tap the whole
///   `kDoubleTapTimeout` rather than what a slow first press left of it.
/// - **near the first**, within `kDoubleTapSlop` — the gate Flutter's own
///   recognizer applies. Two taps at opposite ends of a bar are two
///   adjustments, and reading them as a reset throws away the second one's
///   position.
/// - **spent on tap-UP too.** A press that becomes a drag still fires
///   `onTapDown` once it outlives `kPressTimeout`, so writing on the way down
///   would send the default to the engine every time someone tapped and then
///   dragged.
///
/// Drags bypass the window entirely.
mixin ConsoleResetTap<T extends StatefulWidget> on State<T> {
  Timer? _resetWindow;
  double? _resetTapAt;
  bool _resetPending = false;

  /// Whether the control has a default to snap back to at all.
  bool get hasReset;

  /// Call from `onTapDown`. Returns true when this tap is the SECOND of a
  /// pair and has armed a reset — the caller must then not apply the tap's own
  /// position, because this tap means "put it back", not "put it here".
  bool armReset(double dx) {
    final first = _resetTapAt;
    if (hasReset &&
        _resetWindow != null &&
        first != null &&
        (dx - first).abs() <= kDoubleTapSlop) {
      _resetWindow!.cancel();
      _resetWindow = null;
      _resetPending = true;
      return true;
    }
    _resetTapAt = dx;
    return false;
  }

  /// Call from `onTapUp`. Returns true when an armed reset should now be
  /// applied; otherwise opens the window for a second tap.
  bool spendReset() {
    var apply = false;
    if (hasReset) {
      if (_resetPending) {
        apply = true;
        // No fresh window: a third tap starts its own pair rather than
        // resetting again.
      } else {
        _resetWindow?.cancel();
        _resetWindow = Timer(kDoubleTapTimeout, () => _resetWindow = null);
      }
    }
    _resetPending = false;
    return apply;
  }

  /// Call from `onTapCancel` and from the drag ends: an armed reset must not
  /// survive a press that was stolen or became a drag. The WINDOW survives —
  /// closing it is [closeResetWindow], which a drag start does.
  void dropReset() => _resetPending = false;

  /// Call when a drag STARTS. A drag is not the first half of a double tap,
  /// and leaving the window open would let the tap that ends the drag be read
  /// as one.
  void closeResetWindow() {
    _resetWindow?.cancel();
    _resetWindow = null;
    _resetTapAt = null;
    _resetPending = false;
  }

  @override
  void dispose() {
    _resetWindow?.cancel();
    super.dispose();
  }
}

/// A labelled bar that both reads and sets one `0..1` value — a mapping's LO,
/// HI, or threshold.
///
/// A bar rather than a knob: this sits in a list of 70px rows on a console
/// operated with a finger, and a knob is a mouse control that answers "which
/// way is up?" with a convention. The bar's leading edge IS the value, the
/// whole width is the target, and the readout is beside it in its own column
/// so the numbers under one another line up.
///
/// Stateful only for the duration of a drag: the value shown while a finger is
/// down is the finger's, so the bar tracks it at frame rate without waiting
/// for the write to come back through the cubit.
class ConsoleValueBar extends StatefulWidget {
  /// Creates a [ConsoleValueBar].
  const ConsoleValueBar({
    required this.label,
    required this.value,
    required this.readout,
    required this.onChanged,
    this.resetValue,
    this.semanticLabel,
    super.key,
  });

  /// The caption at the leading edge.
  final String label;

  /// The current value, `0..1`.
  final double value;

  /// The value as the user's own units — `0..127` for a MIDI travel end.
  final String readout;

  /// Called with each new value during and at the end of a drag.
  /// Called with the new value while a finger is on the bar, or null when
  /// the bar only READS.
  ///
  /// A null one is a meter: a plugin can mark a parameter non-automatable —
  /// a mode selector, a gain-reduction readout — and hiding those said the
  /// effect exposed no controls when it plainly did.
  final ValueChanged<double>? onChanged;

  /// What a double tap snaps back to, or null for a bar with no default.
  ///
  /// A bar has no numbers to aim at, so landing back on unity by dragging is
  /// luck. The gesture itself — and why it is hand-rolled rather than
  /// `onDoubleTap` — is [ConsoleResetTap].
  final double? resetValue;

  /// The announced label; defaults to [label].
  final String? semanticLabel;

  /// Height of the bar.
  static const double height = 53;

  /// Width of the caption column. Fixed so the bars of a stacked pair start
  /// on the same line whatever their captions are.
  static const double labelWidth = 106;

  /// Width of the readout column, on the same reasoning.
  static const double readoutWidth = 94;

  /// The filled part of the track. Keyed so a test can measure it against the
  /// bar: a fill is the one thing here with no text to assert on, and "the
  /// bar rendered" is not the same claim as "the bar drew a fill".
  static const Key fillKey = Key('console_value_bar_fill');

  @override
  State<ConsoleValueBar> createState() => _ConsoleValueBarState();
}

class _ConsoleValueBarState extends State<ConsoleValueBar>
    with ConsoleResetTap<ConsoleValueBar> {
  /// The value the finger is on, or null when nothing is dragging.
  double? _dragging;

  @override
  bool get hasReset => widget.resetValue != null;

  @override
  void didUpdateWidget(ConsoleValueBar old) {
    super.didUpdateWidget(old);
    // A bar that goes read-only under a finger keeps no fraction. Only the
    // release handlers clear one, and they are wired only while the bar is
    // live — so the fill stayed pinned where the finger left it and stopped
    // reading the value it is supposed to be showing, for good. Reachable
    // because these bars are keyed by POSITION: row N of the next entry
    // reuses this state, and row N there may be a meter.
    if (widget.onChanged == null && _dragging != null) {
      _release();
    }
  }

  void _report(double width, double dx) {
    final next = (dx / width).clamp(0.0, 1.0);
    setState(() => _dragging = next);
    // Null on a read-only bar. The gestures are already gated on that, so
    // this is the second lock on the same door rather than a branch of its
    // own.
    widget.onChanged?.call(next);
  }

  /// A tap: applies where it landed, unless it is the second of a pair —
  /// close enough to the first to be the same tap twice — and this bar has a
  /// default to snap to. That case only ARMS the reset; [_release] spends it,
  /// because a tap-down is not yet proof the gesture stayed a tap.
  void _tap(double width, double dx) {
    if (armReset(dx)) return;
    _report(width, dx);
  }

  /// Hands the bar back to [ConsoleValueBar.value] — what the finger reported
  /// is only the truth while the finger is down.
  ///
  /// [applyReset] marks the tap-UP path — the only one that spends an armed
  /// reset, and the only one that opens a window for the next tap. The same
  /// call arrives from `onTapCancel` (the press was stolen by the scroll view
  /// or turned into a drag) and from the drag ends, where a pending reset has
  /// to be dropped and no window may be left behind.
  void _release({bool applyReset = false}) {
    final reset = widget.resetValue;
    if (applyReset) {
      if (spendReset() && reset != null) {
        unawaited(HapticFeedback.selectionClick());
        widget.onChanged?.call(reset.clamp(0.0, 1.0));
      }
    } else {
      dropReset();
    }
    if (_dragging == null) return;
    setState(() => _dragging = null);
  }

  /// Cancels a pending double-tap window: a drag is not the first half of a
  /// double tap, and leaving the window open would let the tap that ends the
  /// drag get read as one.
  void _dragStart(double width, double dx) {
    closeResetWindow();
    _report(width, dx);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final live = widget.onChanged != null;
    final value = (_dragging ?? widget.value).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: ConsoleValueBar.labelWidth,
          child: Text(
            widget.label,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 13,
              height: 1.23,
              letterSpacing: 0.78,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
        const SizedBox(width: kConsoleRowGap),
        Expanded(
          child: Semantics(
            // A read-only bar is not a slider: announcing one invites an
            // adjust gesture that does nothing.
            slider: live,
            readOnly: !live,
            label: widget.semanticLabel ?? widget.label,
            value: widget.readout,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: live
                      ? (d) => _tap(width, d.localPosition.dx)
                      : null,
                  // A tap ends a touch as much as a drag does. Without these
                  // the bar stayed pinned to the last tapped fraction for the
                  // rest of its life, and stopped redrawing the value it is
                  // supposed to be reading — visible the moment a write is
                  // clamped, as the threshold's own floor clamps it.
                  onTapUp: live ? (_) => _release(applyReset: true) : null,
                  onTapCancel: live ? _release : null,
                  onHorizontalDragStart: live
                      ? (d) => _dragStart(width, d.localPosition.dx)
                      : null,
                  onHorizontalDragUpdate: live
                      ? (d) => _report(width, d.localPosition.dx)
                      : null,
                  onHorizontalDragEnd: live ? (_) => _release() : null,
                  onHorizontalDragCancel: live ? _release : null,
                  child: Container(
                    height: ConsoleValueBar.height,
                    decoration: BoxDecoration(
                      color: surface.surface,
                      borderRadius: BorderRadius.circular(ConsoleCard.radius),
                      border: Border.all(color: surface.borderSubtle),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        ConsoleCard.radius - 1,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedContainer(
                          key: ConsoleValueBar.fillKey,
                          duration: _dragging == null
                              ? consoleMotion(context)
                              : Duration.zero,
                          curve: Curves.easeOut,
                          width: (width - 2) * value,
                          decoration: BoxDecoration(
                            // A meter reads in the muted pair, so a bar you
                            // cannot move does not look like one you can.
                            color: live
                                ? surface.accentSurface
                                : surface.control,
                            border: Border(
                              right: BorderSide(
                                color: live
                                    ? surface.accent
                                    : surface.textMuted,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: kConsoleRowGap),
        SizedBox(
          width: ConsoleValueBar.readoutWidth,
          child: Text(
            widget.readout,
            style: TextStyle(
              color: surface.textSecondary,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 14,
              height: 1.14,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ],
    );
  }
}

/// One choice in a [ConsoleSegmented] or a [ConsoleChipGrid].
@immutable
class ConsoleSegment<T> {
  /// Creates a [ConsoleSegment].
  const ConsoleSegment({
    required this.value,
    required this.label,
    this.sublabel,
    this.optionKey,
  });

  /// The value reported when this segment is chosen.
  final T value;

  /// The visible caption.
  ///
  /// May be **empty**, which promotes [sublabel] to the primary tone — see
  /// there for the one case that needs it.
  final String label;

  /// A second line under [label], in the mono face: the thing's own machine
  /// fact, where [label] is what a person calls it. `guitar` over `input 1`.
  ///
  /// Ignored by [ConsoleSegmented] and [ConsoleMiniToggle], which are single
  /// short words by construction.
  ///
  /// **An empty [label] promotes this line to the primary tone.** The Audio
  /// face's input chips are why: a named socket reads `guitar` over a grey
  /// `input 1`, and an unnamed one is the bare ordinal — which must not stay
  /// grey, because a rig where nothing is named would be a grid of entirely
  /// grey chips, reading as disabled rather than as nothing having been said
  /// about them yet.
  final String? sublabel;

  /// The cell's own key, for a grid whose cells are otherwise identified only
  /// by a two-character label.
  final Key? optionKey;
}

/// A pick-one control for a short, symmetric pair — Toggle vs Momentary.
///
/// Not a `PillTabs` strip: those are the face's tabs, and a second strip in
/// the same shape, inside a row, would read as a second set of them.
class ConsoleSegmented<T> extends StatelessWidget {
  /// Creates a [ConsoleSegmented].
  const ConsoleSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.stretch = false,
    super.key,
  });

  /// Whether the strip fills its parent instead of shrink-wrapping.
  ///
  /// Shrink-wrapped is right where the strip sits beside the thing it
  /// qualifies. The Signal panel's two strips are **rows in a stack of rows**,
  /// each under its own caption, and a stack whose rows end at different
  /// x-positions reads as a ragged edge rather than as a column of settings —
  /// so there the segments divide the panel's full width.
  final bool stretch;

  /// The choices, in display order.
  final List<ConsoleSegment<T>> segments;

  /// The current choice.
  final T selected;

  /// Called with the newly chosen value.
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final strip = Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final (index, segment) in segments.indexed) ...[
            if (index > 0) const SizedBox(width: 5),
            Expanded(
              child: Semantics(
                button: true,
                selected: segment.value == selected,
                label: segment.label,
                child: InkWell(
                  // Re-tapping the chosen segment is a no-op, as on
                  // [PillTabs]: this is a pick-one and there is no "none".
                  // Load-bearing beyond tidiness — a caller whose handler
                  // TOGGLES would otherwise invert the rig from the very
                  // segment that says what the rig is currently doing.
                  //
                  // Guarded INSIDE the callback, exactly as [PillTabs] does
                  // it: a null `onTap` would also drop the chosen segment's
                  // tap action and take it out of focus traversal, so a
                  // screen reader could no longer reach the segment that
                  // says what the setting currently is.
                  onTap: () {
                    if (segment.value == selected) return;
                    onChanged(segment.value);
                  },
                  borderRadius: BorderRadius.circular(7),
                  child: AnimatedContainer(
                    duration: consoleMotion(context),
                    curve: Curves.easeOut,
                    height: 42,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: segment.value == selected
                          ? surface.accent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      segment.label,
                      style: TextStyle(
                        color: segment.value == selected
                            ? surface.onAccent
                            : surface.textSecondary,
                        fontSize: 16,
                        height: 1.13,
                        leadingDistribution: TextLeadingDistribution.even,
                        // One weight for both states, as everywhere on this
                        // surface: a weight change re-measures the label and
                        // the pair either side of it moves.
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    // Shrink-wrapped by default; a stretched strip takes the width its parent
    // offers, which is what makes the segments divide it evenly.
    return stretch ? strip : IntrinsicWidth(child: strip);
  }
}

/// The small pick-one that sits beside a caption it qualifies — the pedal's
/// A/B bank selector.
///
/// Smaller than [ConsoleSegmented] and outlined rather than filled, because it
/// is a *qualifier* on the list below it, not a setting of its own. It sits
/// next to the caption rather than at the far edge of the pane: floating it
/// right on a 1920px surface puts it a screen away from the words it changes.
class ConsoleMiniToggle<T> extends StatelessWidget {
  /// Creates a [ConsoleMiniToggle].
  const ConsoleMiniToggle({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// The choices, in display order.
  final List<ConsoleSegment<T>> segments;

  /// The current choice.
  final T selected;

  /// Called with the newly chosen value.
  final ValueChanged<T> onChanged;

  /// Height of the control.
  static const double height = 33;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: height,
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final segment in segments)
              Semantics(
                button: true,
                selected: segment.value == selected,
                label: segment.label,
                child: InkWell(
                  onTap: () => onChanged(segment.value),
                  child: AnimatedContainer(
                    duration: consoleMotion(context),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    color: segment.value == selected
                        ? surface.control
                        : Colors.transparent,
                    child: Text(
                      segment.label,
                      style: TextStyle(
                        color: segment.value == selected
                            ? surface.textPrimary
                            : surface.textMuted,
                        fontSize: 14,
                        height: 1.21,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What an opened row reveals: a full-bleed block on the sheet's own
/// background, under a rule.
///
/// Darker than the card it sits in rather than lighter, which is what makes it
/// read as *inside* the row rather than as another row. Its own contents keep
/// the 40px inset an opened row's children take, so the block lines up with
/// the marker that opened it instead of with the list.
class ConsoleDrawer extends StatelessWidget {
  /// Creates a [ConsoleDrawer].
  const ConsoleDrawer({required this.child, super.key});

  /// The revealed block.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.background,
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Padding(padding: const EdgeInsets.only(top: 1), child: child),
    );
  }
}

/// One choice inside a [ConsoleDrawer]: a check slot, a name, and the thing's
/// own facts at the trailing edge.
///
/// **The check leads here and trails in the pedal assign list**, and that is
/// the mockups' own distinction rather than an inconsistency. A chooser is a
/// column of alternatives, and a leading column of checks is what lets the eye
/// run down it and find the current one without reading; the assign list is a
/// list of *targets in the rig*, read left to right as a name, so its mark
/// belongs with the other trailing marks.
///
/// The slot is reserved whether or not this row is the chosen one — a check
/// that pushes the names sideways when the choice moves makes the list twitch
/// on every pick.
class ConsolePickRow extends StatelessWidget {
  /// Creates a [ConsolePickRow].
  const ConsolePickRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.state,
    this.dimmed = false,
    this.showDivider = true,
    super.key,
  });

  /// The choice's name.
  final String title;

  /// Whether this is the current choice.
  final bool selected;

  /// Choose this one.
  final VoidCallback? onTap;

  /// A mono readout at the trailing edge — the thing's own facts (`18 in · 20
  /// out`, `unplugged`, where a target sits).
  final String? state;

  /// Whether this choice is present but not currently usable — an unplugged
  /// device. Still listed, and still choosable: the selection is what survives
  /// the cable being found again.
  final bool dimmed;

  /// Whether to paint the hairline below. False on the last row.
  final bool showDivider;

  /// Width of the check column.
  static const double checkWidth = 13;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final row = Container(
      height: kConsoleRowHeight,
      padding: const EdgeInsets.only(
        left: ConsoleRow.indentedInset,
        right: kConsoleRowInset,
      ),
      foregroundDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: showDivider ? surface.borderHairline : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: checkWidth,
            child: selected
                ? Text(
                    '✓',
                    // Set in the bundled mono face, like the disclosure
                    // markers: the check is a glyph the text face is not
                    // guaranteed to carry, and a tofu box is a worse mark than
                    // none.
                    style: TextStyle(
                      color: surface.accent,
                      fontFamily: SurfaceTheme.monoFont,
                      fontSize: 14,
                      height: 1.2,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: kConsoleRowGap),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: dimmed ? surface.textMuted : surface.textPrimary,
                fontSize: 17,
                height: 1.18,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
          if (state case final word?) ...[
            const SizedBox(width: kConsoleRowGap),
            Text(
              word,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: surface.textMuted,
                fontFamily: SurfaceTheme.monoFont,
                fontSize: 14,
                height: 1.14,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ],
        ],
      ),
    );

    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      semanticLabel: [title, state].whereType<String>().join(', '),
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// A row's chooser: the [ConsolePickRow] list it grows open and shut.
///
/// The console's pick-one, and the shape four screens draw for it —
/// `AUDIO / settings-device`, `settings-rate`, `settings-maxloop` and
/// `LOOP / settings-mode-confirm`. A row turns its marker, tints, and the
/// alternatives slide out from under it; the rest of the face stays lit, which
/// is the whole point — on a console the list is the context for the choice.
///
/// Always in the tree, so opening is a transition rather than a swap.
/// [ConsoleExpansion] mounts nothing while this is shut — so a shut chooser
/// has nothing tappable — and holds the last children for exactly as long as
/// the close takes.
class ConsoleChooser extends StatelessWidget {
  /// Creates a [ConsoleChooser].
  const ConsoleChooser({required this.open, required this.children, super.key});

  /// A chooser holding one [ConsoleChipGrid], inset the way a drawer's
  /// contents always are.
  ///
  /// The inset was being re-stated by every face that opened a grid; it
  /// belongs to the drawer, which is the thing that knows how far in its
  /// contents sit.
  factory ConsoleChooser.grid({
    required bool open,
    required Widget grid,
    Key? key,
  }) => ConsoleChooser(
    key: key,
    open: open,
    children: [Padding(padding: gridInset, child: grid)],
  );

  /// Whether the chooser is showing.
  final bool open;

  /// The alternatives, in display order.
  final List<Widget> children;

  /// What a grid inside a drawer is inset by — the 40px an opened row's
  /// children take on the leading edge, a row's own inset on the trailing
  /// one. Public so a chooser holding several captioned grids can apply it
  /// per group.
  static const EdgeInsets gridInset = EdgeInsets.fromLTRB(
    ConsoleRow.indentedInset,
    kConsoleBlockGap,
    kConsoleRowInset,
    kConsoleBlockGap,
  );

  @override
  Widget build(BuildContext context) => ConsoleExpansion(
    expanded: open,
    child: ConsoleDrawer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// A caption that splits one drawer into named sub-groups.
///
/// `AUDIO / settings-rate` draws it: one chooser holding SAMPLE RATE and
/// BUFFER, because those are two questions the row asks at once. The Loop
/// face's time signatures use it for the same reason — seventeen of them are
/// two families, not one list, and the note value is the thing you narrow by
/// first.
///
/// Stepped in to the 40px inset an opened row's children take, so it lines up
/// with the choices under it rather than with the list outside.
class ConsoleDrawerLabel extends StatelessWidget {
  /// Creates a [ConsoleDrawerLabel].
  const ConsoleDrawerLabel(this.label, {super.key});

  /// The caption. Upper-cased by the caller, as [ConsoleGroupLabel]'s is.
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      ConsoleRow.indentedInset,
      14,
      kConsoleRowInset,
      7,
    ),
    child: ConsoleGroupLabel(label),
  );
}

/// A wrapping grid of equal cells — the console's pick-one for options that
/// are **bare tokens**: `3/4`, `1/8`, `x2`, `Out 3`.
///
/// [ConsolePickRow] is the other half of the same control, and the split is
/// about what an option has to say for itself. A row earns its width when the
/// choice carries a second fact — a mode and its one-liner, a device and its
/// channel counts, a buffer size and its latency. A token has nothing to put
/// in that width, so a column of rows spends 70px of height and 1,600px of
/// width on four characters, and seventeen time signatures become a
/// 1,200px scroll inside a sheet that is 830px tall.
///
/// The cell is `LOOP / loop-quantise`'s: 166x48 at an 11px radius on a 10px
/// gutter, accent-surface and accent-outlined when lit. That screen drew the
/// grid inside a centred modal; this puts the same grid inside the drawer the
/// rest of the file opens rows into, which is the half each of the two
/// drawings got right.
///
/// [selected] is a set rather than one value, so the same control serves a
/// pick-one (`{current}`) and a bitmask (`{every lit bit}`) without a second
/// widget. What a tap MEANS — replace, or toggle — is the caller's, since only
/// the caller knows whether the question has one answer.
class ConsoleChipGrid<T> extends StatelessWidget {
  /// Creates a [ConsoleChipGrid].
  const ConsoleChipGrid({
    required this.options,
    required this.selected,
    required this.onTap,
    super.key,
  });

  /// The choices, in display order.
  final List<ConsoleSegment<T>> options;

  /// Every value currently lit.
  final Set<T> selected;

  /// Called with the tapped value.
  final ValueChanged<T> onTap;

  /// The cell width the mockup draws, and the width the grid aims at.
  ///
  /// A *target*, not a column count: four across is right on that screen's
  /// 694px measure and absurd on the drawer's 1,600, where it would waste the
  /// width the row layout was already wasting. The grid fits as many cells of
  /// about this size as it can and shares out the remainder, so the cells stay
  /// equal and the run stays flush to both edges.
  static const double cellWidth = 166;

  /// Gap between cells, both ways.
  static const double gutter = 10;

  /// Cell height, for a grid of single-line cells.
  static const double cellHeight = 48;

  /// Cell height once any option carries a [ConsoleSegment.sublabel]. Uniform
  /// across the grid — cells of two heights in one run read as two controls.
  static const double twoLineCellHeight = 56;

  /// How many cells to put across, given the room and how many there are.
  ///
  /// Not simply "as many as fit": seventeen options across a nine-wide measure
  /// is 9 + 8, which is fine, but the same rule on a narrower sheet gives
  /// 4 + 4 + 4 + 4 + **1**, and a last row holding one cell reads as a
  /// mistake. So it takes the widest count that fits, then tries narrower ones
  /// and keeps whichever strands the fewest cells on the last row — ties going
  /// to the wider one, since fewer rows is better when the raggedness is the
  /// same.
  ///
  /// The search stops at half the fitting width. Below that a perfect division
  /// is always reachable (one column divides everything) and the cells would
  /// grow to absurd widths to reach it — the cure being worse than the ragged
  /// row it fixes.
  static int columnsFor(double width, int count) {
    final fits = math.max(1, ((width + gutter) / (cellWidth + gutter)).floor());
    if (count <= fits) return count;
    var best = fits;
    var least = fits * (count / fits).ceil() - count;
    for (var columns = fits - 1; columns >= (fits / 2).ceil(); columns--) {
      final stranded = columns * (count / columns).ceil() - count;
      if (stranded < least) {
        best = columns;
        least = stranded;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = columnsFor(width, options.length);
      final cell = (width - gutter * (columns - 1)) / columns;
      final twoLine = options.any((option) => option.sublabel != null);
      return Wrap(
        spacing: gutter,
        runSpacing: gutter,
        children: [
          for (final option in options)
            SizedBox(
              width: cell,
              child: _ConsoleChip(
                key: option.optionKey,
                label: option.label,
                sublabel: option.sublabel,
                height: twoLine ? twoLineCellHeight : cellHeight,
                selected: selected.contains(option.value),
                onTap: () => onTap(option.value),
              ),
            ),
        ],
      );
    },
  );
}

class _ConsoleChip extends StatelessWidget {
  const _ConsoleChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.sublabel,
    this.height = ConsoleChipGrid.cellHeight,
    super.key,
  });

  final String label;
  final String? sublabel;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // No outer Semantics: FocusableTapTarget already emits a merged
    // button/selected/label node, and wrapping a second one round it gives a
    // screen reader two nested labelled buttons for one chip. ConsolePickRow
    // makes the same call.
    final sub = sublabel;
    // An empty label leaves the second line as the chip's only content, so it
    // takes the primary ink; under a label it is the muted secondary fact.
    final subTint = label.isEmpty ? surface.textPrimary : surface.textMuted;
    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      borderRadius: 11,
      semanticLabel: [label, ?sub].where((text) => text.isNotEmpty).join(', '),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: consoleMotion(context),
          curve: Curves.easeOut,
          height: height,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? surface.accentSurface : surface.cardHigh,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: selected ? surface.accent : surface.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label.isNotEmpty)
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? surface.accent : surface.textPrimary,
                    fontSize: 16,
                    height: 1.13,
                    leadingDistribution: TextLeadingDistribution.even,
                    // One weight for both states, as everywhere here.
                  ),
                ),
              if (sub != null) ...[
                if (label.isNotEmpty) const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? surface.accent : subTint,
                    fontFamily: SurfaceTheme.monoFont,
                    fontSize: 14,
                    height: 1.14,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The check that marks the target something is already pointed at.
class ConsoleCheck extends StatelessWidget {
  /// Creates a [ConsoleCheck].
  const ConsoleCheck({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      '✓',
      // Mono, for the same reason [ConsolePickRow]'s check is: the glyph is
      // not in every text face, and a tofu box marks nothing.
      style: TextStyle(
        color: context.surface.accent,
        fontFamily: SurfaceTheme.monoFont,
        fontSize: 15,
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// Confirms the destructive thing [title] asks about; resolves true when the
/// user goes through with it.
///
/// **Destructive confirms; reversible does not.** Forgetting a network deletes
/// a credential nothing else holds, and switching looper mode clears every
/// track, so both ask. Disconnecting is undone by tapping the row again, so it
/// does not — a confirm on a reversible action teaches people to dismiss
/// confirms.
///
/// The one modal on this console that is not an editor. Everything a row can
/// answer, a row answers in place; this interrupts because the thing behind it
/// is about to stop existing.
///
/// Drawn to `NETWORK / wifi-forget` and `LOOP / settings-mode-confirm`, which
/// are the same 528px dialog with different words.
///
/// The dismissive label is fixed rather than a parameter: "keep it" is the
/// same answer on every one of these, and a per-caller override only invited
/// each surface to invent its own word for "no".
Future<bool> showConsoleConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final l10n = context.l10n;
  final surface = context.surface;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: surface.scrim,
    builder: (dialogContext) => Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 528,
          padding: const EdgeInsets.all(25),
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: surface.borderStrong),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 16,
                  height: 1.4,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
              const SizedBox(height: 19),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ConsoleDialogButton(
                    key: const Key('console_confirm_cancel'),
                    label: l10n.consoleKeepIt,
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  ),
                  const SizedBox(width: 10),
                  ConsoleDialogButton(
                    key: const Key('console_confirm_confirm'),
                    label: confirmLabel,
                    tone: ConsoleDialogTone.destructive,
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return confirmed ?? false;
}

/// A group caption that stays overhead while its own list scrolls under it.
///
/// Pinned rather than scrolling away, because on a surface long enough to
/// scroll the caption is the only thing that says which question a row answers.
/// It carries its container's own [fill] so the rows pass *behind* it rather
/// than through it, and it reserves [kConsoleLabelGap] under itself — a caption
/// belongs to what is beneath it, so that gap travels with the caption rather
/// than staying behind with the list.
///
/// Built for the per-track routing panel and lifted here the moment the Audio
/// face's device list needed the same shape: a rig with eighteen inputs
/// outgrows the tray sheet exactly as an eight-input one outgrew the panel.
class ConsolePinnedGroupLabel extends StatelessWidget {
  /// Creates a [ConsolePinnedGroupLabel].
  const ConsolePinnedGroupLabel(this.label, {this.fill, super.key});

  /// The caption. Upper-cased by the caller, as [ConsoleGroupLabel]'s is.
  final String label;

  /// What the caption paints over; defaults to [SurfaceTheme.card], the
  /// centred panel's own tone. A face that sits directly on the tray sheet
  /// passes [SurfaceTheme.background].
  final Color? fill;

  /// The caption's own line, at [ConsoleGroupLabel]'s 13px × 1.23.
  static const double lineHeight = 16;

  /// What one caption occupies: its line, plus the gap it carries with it.
  static const double extent = lineHeight + kConsoleLabelGap;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(
    pinned: true,
    delegate: _PinnedGroupLabelDelegate(
      label: label,
      fill: fill ?? context.surface.card,
    ),
  );
}

class _PinnedGroupLabelDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedGroupLabelDelegate({required this.label, required this.fill});

  final String label;
  final Color fill;

  @override
  double get minExtent => ConsolePinnedGroupLabel.extent;

  @override
  double get maxExtent => ConsolePinnedGroupLabel.extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    color: fill,
    alignment: Alignment.topLeft,
    child: ConsoleGroupLabel(label),
  );

  @override
  bool shouldRebuild(_PinnedGroupLabelDelegate oldDelegate) =>
      oldDelegate.label != label || oldDelegate.fill != fill;
}

/// A scrolling column of captioned groups: sticky captions, plus an optional
/// preview of the group you have not reached yet, pinned to the bottom edge.
///
/// Two captions and one viewport is the problem this solves. Pinning both at
/// the top stacks them, which says nothing — a caption belongs to what is
/// under it, and two of them overhead belong to nothing. Pinning only the
/// current one is honest but leaves the second question invisible until you
/// have scrolled the whole first list to find out it exists.
///
/// So the *current* caption pins overhead (each group is its own
/// [SliverMainAxisGroup], so it is pushed out by the next rather than stacking
/// under it), and the *next* one waits at the bottom edge. It is dropped the
/// moment the real one rises into view, so the two are never on screen at once
/// and the handover has no seam.
///
/// [upcoming] is null for a surface with only one group — there is nothing to
/// preview, and a strip previewing the caption already overhead would be a
/// second copy of it.
class ConsoleStickyGroups extends StatefulWidget {
  /// Creates a [ConsoleStickyGroups].
  const ConsoleStickyGroups({
    required this.slivers,
    this.upcoming,
    this.upcomingExtent = 0,
    this.fill,
    this.previewKey,
    super.key,
  });

  /// The groups, in display order.
  final List<Widget> slivers;

  /// The last group's caption — the one previewed at the bottom, or null when
  /// there is only one group.
  final String? upcoming;

  /// How tall the last group is, caption included.
  final double upcomingExtent;

  /// What the preview strip paints over; defaults to [SurfaceTheme.card].
  final Color? fill;

  /// Key for the preview strip, so a test can find it.
  final Key? previewKey;

  @override
  State<ConsoleStickyGroups> createState() => _ConsoleStickyGroupsState();
}

class _ConsoleStickyGroupsState extends State<ConsoleStickyGroups> {
  /// Whether the last group's real caption is still below the bottom edge.
  bool _upcomingBelow = false;

  /// True while the last caption is still below the bottom edge.
  ///
  /// The last group ends the content, so what remains to scroll is the
  /// distance from the bottom edge to the end of that group. Its caption is
  /// exactly [ConsoleStickyGroups.upcomingExtent] above that end — so the
  /// caption is still off the bottom while the remaining scroll exceeds the
  /// group's own height, and reaches the edge precisely when it does not.
  bool _below(ScrollMetrics m) =>
      m.hasContentDimensions &&
      (m.maxScrollExtent - m.pixels) > widget.upcomingExtent;

  bool _update(ScrollMetrics metrics) {
    final below = _below(metrics);
    if (below != _upcomingBelow) setState(() => _upcomingBelow = below);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.upcoming;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _update(n.metrics),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) => _update(n.metrics),
            child: CustomScrollView(shrinkWrap: true, slivers: widget.slivers),
          ),
        ),
        if (preview != null)
          // Ignores pointers: it is a label, and the list under it must stay
          // draggable through the strip it occupies.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: widget.previewKey,
                duration: consoleMotion(context),
                curve: Curves.easeOut,
                opacity: _upcomingBelow ? 1 : 0,
                child: Container(
                  color: widget.fill ?? context.surface.card,
                  padding: const EdgeInsets.only(top: kConsoleLabelGap),
                  child: ConsoleGroupLabel(preview),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One captioned group of a domain face: its caption, and the blocks under it.
@immutable
class ConsoleGroup {
  /// Creates a [ConsoleGroup].
  const ConsoleGroup({required this.blocks, this.caption});

  /// The caption over the group, upper-cased by the caller as every
  /// [ConsoleGroupLabel] is — or **null** for a group that has none.
  ///
  /// Nullable because `SYSTEM / update` opens on two rows (installed version
  /// and channel) with no caption at all, and a group forced to invent one
  /// would be captioning a fact that needs no heading. An uncaptioned group
  /// also sits [kConsoleBlockGap] from what is above it rather than
  /// [kConsoleGroupGap] — the wider gap exists to hold a caption off the
  /// thing before it, so with no caption there is nothing to hold off.
  final String? caption;

  /// The cards and banners under the caption, in display order. Separated by
  /// [kConsoleBlockGap] — two blocks of one group sit closer together than two
  /// groups do.
  final List<Widget> blocks;

  /// The gap above this group.
  double get gapAbove => caption == null ? kConsoleBlockGap : kConsoleGroupGap;
}

/// The shape every domain tab shares: captioned groups that scroll under their
/// own sticky captions.
///
/// Scrolling is not defensive, it is the common case. An 18-in interface with
/// the device row open is a list of every device the host reports plus three
/// settings rows; the Storage breakdown plus its housekeeping actions is
/// another; and both are taller than the tray sheet. It is the same problem the
/// per-track routing panel had at eight inputs, so it takes the same answer
/// rather than a second one: each group is its own [SliverMainAxisGroup], so
/// the current caption is pinned overhead and pushed out by the next rather
/// than stacking under it, and the group you have not reached waits at the
/// bottom edge.
///
/// The captions carry [SurfaceTheme.card] — the TRAY SHEET's own tone, which
/// is what these faces sit directly on. Not the page background: the sheet is
/// opaque and card-toned, so a caption painting the page's fill draws a darker
/// band across the width of a face it is supposed to be part of.
///
/// Started as `AudioFace`, beside the one domain that had it, and moved here
/// under this file's own promotion rule the moment System read it too.
class ConsoleFace extends StatelessWidget {
  /// Creates a [ConsoleFace].
  const ConsoleFace({
    required this.groups,
    this.lastGroupExtent = 0,
    this.previewKey,
    super.key,
  });

  /// The groups, in display order.
  final List<ConsoleGroup> groups;

  /// How tall the LAST group is, caption included — 0 when there is only one.
  ///
  /// Stated by the caller rather than measured, because [ConsoleStickyGroups]
  /// needs that height before the group has been laid out, to know when its
  /// real caption has risen far enough to take the bottom preview's place.
  final double lastGroupExtent;

  /// Key for the bottom preview strip, so a test can find it.
  final Key? previewKey;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final last = groups.length > 1 ? groups.last : null;
    return Padding(
      // The gap between the tab strip and the first group. On the face rather
      // than inside the scroll view: a caption that pins flush against the
      // strip is what this space exists to prevent.
      padding: EdgeInsets.only(
        top: groups.isEmpty ? kConsoleGroupGap : groups.first.gapAbove,
      ),
      child: ConsoleStickyGroups(
        fill: surface.card,
        // Null when the last group has no caption of its own: there is
        // nothing to preview, and a blank strip at the bottom edge previews
        // nothing while still taking the room.
        upcoming: last?.caption,
        // Plus the sheet's own bottom inset below: what [ConsoleStickyGroups]
        // measures is the distance from the bottom edge to the END of the
        // content, and this face puts a [kConsoleGroupGap] spacer after the
        // last group. Leaving it out drops the preview a gap early, with the
        // real caption already risen — the two on screen at once, which is the
        // one thing the handover exists to prevent.
        upcomingExtent: lastGroupExtent + kConsoleGroupGap,
        previewKey: previewKey,
        slivers: [
          for (final (index, group) in groups.indexed) ...[
            if (index > 0)
              SliverToBoxAdapter(child: SizedBox(height: group.gapAbove)),
            SliverMainAxisGroup(
              slivers: [
                if (group.caption case final caption?)
                  ConsolePinnedGroupLabel(caption, fill: surface.card),
                for (final (position, block) in group.blocks.indexed)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: position > 0 ? kConsoleBlockGap : 0,
                      ),
                      child: block,
                    ),
                  ),
              ],
            ),
          ],
          // The sheet's own bottom inset, so the last row can be scrolled clear
          // of the drag handle that rides at the panel's bottom edge.
          const SliverToBoxAdapter(child: SizedBox(height: kConsoleGroupGap)),
        ],
      ),
    );
  }
}

/// What a [ConsoleDialogButton] is for.
enum ConsoleDialogTone {
  /// The way out — Cancel, Keep it. Card-toned, quietly outlined.
  neutral,

  /// The button that ENDS the editor it sits in — Done, Save. Outlined and
  /// lettered in the accent over its own surface: it is the affirmative
  /// action, but it commits nothing (everything applied as it was tapped), so
  /// filling it solid would promise a decision the panel already made.
  accent,

  /// The one that destroys something. Solid, because it is the only control
  /// on this console that cannot be undone by tapping again.
  destructive,
}

/// A 40px button at the foot of a panel or sheet.
///
/// Taller and larger-lettered than [ConsoleSmallButton], which is the *inline*
/// button — a banner's Cancel, sitting inside a 61px strip. This one closes a
/// panel, and the mockups draw the two at different sizes because they end
/// different things.
class ConsoleDialogButton extends StatelessWidget {
  /// Creates a [ConsoleDialogButton].
  const ConsoleDialogButton({
    required this.label,
    required this.onPressed,
    this.tone = ConsoleDialogTone.neutral,
    super.key,
  });

  /// Visible caption, and the announced label.
  final String label;

  /// Tap action.
  final VoidCallback onPressed;

  /// What this button is for.
  final ConsoleDialogTone tone;

  /// Height of the button, as every mockup that draws one sets it.
  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final (background, edge, ink) = switch (tone) {
      ConsoleDialogTone.neutral => (
        surface.cardHigh,
        surface.borderStrong,
        surface.textPrimary,
      ),
      ConsoleDialogTone.accent => (
        surface.accentSurface,
        surface.accent,
        surface.accent,
      ),
      ConsoleDialogTone.destructive => (
        surface.rec,
        surface.rec,
        surface.onAccent,
      ),
    };
    return FocusableTapTarget(
      onTap: onPressed,
      semanticLabel: label,
      borderRadius: 10,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: height,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: edge),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: ink,
              fontSize: 15,
              height: 1.2,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: tone == ConsoleDialogTone.destructive
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
