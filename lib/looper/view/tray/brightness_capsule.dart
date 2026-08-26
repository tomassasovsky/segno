import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/theme/theme.dart';

/// One arrow-key press: `+1` up, `-1` down.
class _NudgeIntent extends Intent {
  const _NudgeIntent(this.direction);

  final int direction;
}

/// The brightness control from `SYSTEM / brightness`, drawn as the pen draws
/// it: a capsule whose LIT PART is the value.
///
/// `c/brightness` — "Control-Center capsule: the fill is the control". There
/// is no handle, no track-and-thumb: the white area is the brightness, and
/// you push its top edge up and down. A thumb would be a second thing to aim
/// at on a control whose whole surface is already the target, and at 79px
/// wide on a floor console the surface is the point.
///
/// A double tap — the same spot twice, inside the window — snaps back to
/// [kDefaultDisplayBrightness], the gesture every other console control with
/// a default got in #617 and this one missed (#623). It missed because the
/// old widget wrapped a Material `Slider`, whose drag recognizer resolves the
/// arena on pointer-DOWN and forced the reset onto a raw `Listener` that
/// reported no faithful position. This capsule owns its gestures outright, so
/// its `onTapDown` positions come from its own render box and the shared
/// [ConsoleResetTap] window works here unmodified — dy where the bars use dx.
class BrightnessCapsule extends StatefulWidget {
  /// Creates a [BrightnessCapsule].
  const BrightnessCapsule({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    super.key,
  });

  /// Current brightness, `kMinDisplayBrightness..1`.
  final double value;

  /// Called with the new brightness as the finger moves.
  final ValueChanged<double> onChanged;

  /// What a screen reader calls it.
  final String semanticLabel;

  /// Capsule size, from the pen's `FQgZF`.
  static const Size size = Size(79, 235);

  /// Corner radius, from the same node. Larger than half the width, so it
  /// clamps to a full semicircle at each end.
  static const double radius = 40;

  /// The sun glyph's box, from `na1CY`.
  static const double glyphSize = 26;

  /// How far the glyph sits above the capsule's bottom edge.
  static const double _glyphInset = 17;

  /// Inset of the fill inside the track, from `vwHwY` (x=1 in a 79 box).
  static const double _fillInset = 1;

  /// One arrow-key step: 5% of the USABLE range, not of the raw value. The
  /// floor is [kMinDisplayBrightness], so the two differ.
  static const double _step = 0.05;

  /// [_step] as a change in the value itself.
  static const double _valueStep = _step * (1 - kMinDisplayBrightness);

  @override
  State<BrightnessCapsule> createState() => _BrightnessCapsuleState();
}

class _BrightnessCapsuleState extends State<BrightnessCapsule>
    with ConsoleResetTap<BrightnessCapsule> {
  final _focus = FocusNode(debugLabel: 'BrightnessCapsule');

  @override
  bool get hasReset => true;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  double get _fraction {
    const span = 1 - kMinDisplayBrightness;
    return ((widget.value - kMinDisplayBrightness) / span).clamp(0.0, 1.0);
  }

  void _setFromLocal(double dy, double height) {
    // Up is more, so the fraction is measured from the BOTTOM edge.
    final fraction = (1 - dy / height).clamp(0.0, 1.0);
    widget.onChanged(
      kMinDisplayBrightness + (1 - kMinDisplayBrightness) * fraction,
    );
  }

  static String _percent(double v) =>
      '${(v.clamp(kMinDisplayBrightness, 1.0) * 100).round()}%';

  void _nudge(double by) => widget.onChanged(
    (widget.value + by).clamp(kMinDisplayBrightness, 1.0),
  );

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      // The brightness itself, not its position in the usable range: "80%"
      // has to mean the same number the rest of the app persists and the
      // helper applies, or the readout and the setting disagree.
      value: _percent(widget.value),
      increasedValue: _percent(widget.value + BrightnessCapsule._valueStep),
      decreasedValue: _percent(widget.value - BrightnessCapsule._valueStep),
      onIncrease: () => _nudge(BrightnessCapsule._valueStep),
      onDecrease: () => _nudge(-BrightnessCapsule._valueStep),
      child: ExcludeSemantics(
        // Focusable and arrow-driven: on a desktop build this is reachable by
        // keyboard, and a control that can be focused and not moved is worse
        // than one that cannot be focused at all.
        child: FocusableActionDetector(
          focusNode: _focus,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowUp): _NudgeIntent(1),
            SingleActivator(LogicalKeyboardKey.arrowDown): _NudgeIntent(-1),
          },
          actions: {
            _NudgeIntent: CallbackAction<_NudgeIntent>(
              onInvoke: (intent) {
                _nudge(BrightnessCapsule._valueStep * intent.direction);
                return null;
              },
            ),
          },
          child: SizedBox(
            width: BrightnessCapsule.size.width,
            height: BrightnessCapsule.size.height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    // Focus on tap, so the arrow keys reach it without a
                    // Tab-hunt on a desktop build.
                    _focus.requestFocus();
                    // The second tap of a pair means "put it back", not "put
                    // it here" — arming skips the tap's own position.
                    if (armReset(d.localPosition.dy)) return;
                    _setFromLocal(d.localPosition.dy, height);
                  },
                  onTapUp: (_) {
                    if (spendReset()) {
                      // A snap toward 0.8 can be a small visible move on a
                      // screen someone is squinting at BECAUSE it is too dim
                      // or too bright. The same confirmation the value bars
                      // give.
                      unawaited(HapticFeedback.selectionClick());
                      widget.onChanged(kDefaultDisplayBrightness);
                    }
                  },
                  onTapCancel: dropReset,
                  onVerticalDragStart: (d) {
                    // A drag is not the first half of a double tap.
                    closeResetWindow();
                    _setFromLocal(d.localPosition.dy, height);
                  },
                  onVerticalDragUpdate: (d) =>
                      _setFromLocal(d.localPosition.dy, height),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: surface.control,
                      borderRadius: BorderRadius.circular(
                        BrightnessCapsule.radius,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        BrightnessCapsule.radius,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(
                          BrightnessCapsule._fillInset,
                        ),
                        child: Stack(
                          children: [
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: _fraction,
                                widthFactor: 1,
                                child: ColoredBox(color: surface.textPrimary),
                              ),
                            ),
                            // Inside the capsule and always visible, as the pen
                            // places it — it rides low enough to sit within the
                            // lit area at any usable brightness, and it is the
                            // only thing saying what the capsule is for.
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: BrightnessCapsule._glyphInset,
                              child: Icon(
                                // The pen draws the sun outright — `na1CY` is
                                // a stroked circle with rays, which is lucide
                                // `sun`. The half-lit disc that shipped here
                                // is Material's idea of brightness, not this
                                // design's.
                                LucideIcons.sun,
                                size: BrightnessCapsule.glyphSize,
                                color: surface.background,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
