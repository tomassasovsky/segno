import 'package:flutter/material.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/theme/theme.dart';

/// The plate, to scale, with the switch being edited marked on it.
///
/// The map stays on screen the whole time the setup is open, which is the
/// whole point of the accepted layout: the question a performer is answering
/// is "what should THAT switch do", and that switch is a position under a
/// foot, not a row in a list.
///
/// Drawn in the pen's own coordinates inside a 1720 x 480 box: the rear row
/// (Clear and Bank) sits ABOVE the box, which is why the stack does not clip.
class PedalSetupMap extends StatelessWidget {
  /// Creates a [PedalSetupMap].
  const PedalSetupMap({
    required this.selected,
    required this.editable,
    required this.onSelect,
    required this.bank,
    required this.bankSelectable,
    required this.onToggleBank,
    super.key,
  });

  /// The switches drawn as a group with the selected one — the four track
  /// caps, when Track controls is editing them as one.
  final Set<PedalButton> selected;

  /// The switches that can be edited in this context; everything else is
  /// drawn dimmed and refuses the tap.
  final Set<PedalButton> editable;

  /// Selects a switch.
  final ValueChanged<PedalButton> onSelect;

  /// The bank the track caps are showing.
  final int bank;

  /// Whether BANK pages the map here. It does in Custom controls, where the
  /// four track caps carry a pair per bank; it does not in Track controls,
  /// where the one track hold covers both.
  final bool bankSelectable;

  /// Pages the bank.
  final VoidCallback onToggleBank;

  /// The pen's box for the whole map.
  static const Size penSize = Size(1720, 480);

  /// The pen's front-row cap slot.
  static const Size _frontSlot = Size(201, 216);

  /// The pen's rear-row cap slot — narrower, because the rear row has only
  /// two caps and the plate spaces them by the screens between them.
  static const Size _rearSlot = Size(168, 216);

  /// The pen's front-row pitch.
  static const double _frontPitch = 217;

  /// Where the rear row sits, relative to the box. Negative on purpose: the
  /// pen hangs it above the front row's band.
  static const double _rearTop = -56;

  /// Where the front row sits.
  static const double _frontTop = 264;

  /// The pen's front-row order, left to right.
  static const List<PedalButton> _frontRow = [
    PedalButton.recPlay,
    PedalButton.stop,
    PedalButton.undo,
    PedalButton.mode,
    ...kTrackSwitches,
  ];

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
    size: penSize,
    child: Stack(
      // The rear row hangs above the box (see [_rearTop]).
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 451,
          top: _rearTop,
          child: _cap(context, PedalButton.clear, _rearSlot),
        ),
        Positioned(
          left: 668,
          top: _rearTop,
          child: _cap(context, PedalButton.bank, _rearSlot),
        ),
        for (final (index, button) in _frontRow.indexed)
          Positioned(
            left: index * _frontPitch,
            top: _frontTop,
            child: _cap(context, button, _frontSlot),
          ),
      ],
    ),
  );

  Widget _cap(BuildContext context, PedalButton button, Size slot) {
    final channel = pedalTrackChannel(button, bank);
    final live =
        editable.contains(button) ||
        (button == PedalButton.bank && bankSelectable);
    return PedalSetupCap(
      key: Key('pedal_setup_cap_${button.name}'),
      // The cap's own silkscreen. A track cap prints the channel its bank
      // drives, so the map says 5 6 7 8 while bank B is being edited — the
      // same thing the plate under the foot says.
      legend: channel == null
          ? pedalButtonLegend(button)
          : 'TRACK ${channel + 1}',
      badge: button == PedalButton.bank ? _bankLetter : null,
      slot: slot,
      selected: selected.contains(button),
      enabled: live,
      onTap: !live
          ? null
          : button == PedalButton.bank
          ? onToggleBank
          : () => onSelect(button),
    );
  }

  String get _bankLetter => String.fromCharCode(65 + bank);
}

/// One footswitch on the map: the metal cap, its nameplate legend, and the
/// LED pill behind it.
///
/// Shapes, not an illustration. The cap is a tapered slab with a rubber pad
/// and a nameplate, which is what the real switch is; drawing the plate's
/// photoreal rendering by hand would look worse than the geometry it stands
/// for, and would still have to be redrawn every time the hardware moves.
class PedalSetupCap extends StatelessWidget {
  /// Creates a [PedalSetupCap].
  const PedalSetupCap({
    required this.legend,
    required this.slot,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.badge,
    super.key,
  });

  /// The silkscreen on the cap.
  final String legend;

  /// A short mark in the cap's corner — the bank letter, and nothing else so
  /// far.
  final String? badge;

  /// The pen's box for this cap.
  final Size slot;

  /// Whether this is the switch being edited.
  final bool selected;

  /// Whether this switch can be edited in the current context.
  final bool enabled;

  /// Selects it; `null` while it cannot be edited.
  final VoidCallback? onTap;

  /// The pen's LED pill: 114 x 11, sitting 30 above the cap.
  static const Size _ledSize = Size(114, 11);
  static const double _ledGap = 30;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final pad = (slot.width - _ledSize.width) / 2;
    return SizedBox(
      width: slot.width,
      height: slot.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: pad,
            top: -_ledGap,
            width: _ledSize.width,
            height: _ledSize.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // Dark, always: this is the plate's LED, and the setup screen
                // must not light one. A lit pill here would read as a saved
                // performance latch rather than as the switch being edited.
                color: enabled ? surface.cardHigh : surface.card,
                borderRadius: BorderRadius.circular(_ledSize.height / 2),
              ),
            ),
          ),
          Positioned.fill(
            child: Opacity(
              opacity: enabled ? 1 : surface.disabledOpacity,
              child: FocusableTapTarget(
                onTap: onTap,
                selected: selected,
                semanticLabel: legend,
                borderRadius: 14,
                child: Material(
                  color: selected ? surface.accentSurface : surface.cardHigh,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: selected ? surface.accent : surface.borderStrong,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onTap,
                    child: Stack(
                      children: [
                        // The rubber pad: the part a foot actually lands on.
                        Positioned(
                          left: 20,
                          right: 20,
                          top: 22,
                          bottom: 62,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: surface.background,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: surface.line),
                            ),
                          ),
                        ),
                        // The nameplate, and the legend raised on it.
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 16,
                          height: 38,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: surface.control,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AppText(
                                    legend,
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: surface.textPrimary,
                                      fontFamily: SurfaceTheme.monoFont,
                                      fontSize: 18,
                                      height: 1,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (badge != null)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: surface.accentSurface,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                child: AppText(
                                  badge!,
                                  style: TextStyle(
                                    color: surface.textPrimary,
                                    fontSize: 20,
                                    height: 1,
                                  ),
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
        ],
      ),
    );
  }
}
