import 'package:flutter/material.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// A picture of the pedal plugged into a jack, with a hit target over each of
/// its switches.
///
/// The artwork is generated and unbranded: it depicts a CATEGORY of pedal, not
/// a product anyone can buy and not the Segno faceplate. What has to be exact
/// is where the switches are, because the performer picks one by pointing at
/// it — so the centres below are measured in the source raster and the
/// markers are placed as fractions of it, which survives any rescale.
class ExternalPedalArt extends StatelessWidget {
  /// Creates an [ExternalPedalArt].
  const ExternalPedalArt({
    required this.type,
    required this.selected,
    required this.onSelect,
    required this.contacts,
    super.key,
  });

  /// Which pedal to draw.
  final ExternalJackType type;

  /// Which switch is being edited.
  final int selected;

  /// Selects a switch.
  final ValueChanged<int> onSelect;

  /// The switches whose contact is closed right now, as the jack reports it.
  final Set<int> contacts;

  /// The pen's box for the picture and its markers.
  static const Size penSize = Size(580, 722);

  /// Where each artwork's switches and indicators are, measured in the source
  /// raster and expressed in its own pixels.
  static const Map<ExternalJackType, ExternalPedalArtwork> artwork = {
    ExternalJackType.singleSwitch: ExternalPedalArtwork(
      asset: 'assets/hardware/external_single.webp',
      size: Size(1024, 1536),
      switches: [Offset(511.5, 775.5)],
      indicators: [Offset(512, 468)],
    ),
    ExternalJackType.dualSwitch: ExternalPedalArtwork(
      asset: 'assets/hardware/external_dual.webp',
      size: Size(1672, 941),
      switches: [Offset(402.5, 485.5), Offset(1265.5, 485.5)],
      indicators: [Offset(405, 285)],
    ),
  };

  /// The pen's hit target: a circle over the switch, with its name under it.
  static const double _targetSize = 108;
  static const double _markerSize = 12;

  @override
  Widget build(BuildContext context) {
    final art = artwork[type];
    if (art == null) return const SizedBox(width: 580, height: 722);
    // The picture is fitted rather than stretched, and everything else is
    // placed inside the rect it actually landed in — the two artworks have
    // different aspects, so a marker positioned against the BOX would sit off
    // the switch on one of them.
    final fitted = _fit(art.size, penSize);
    return SizedBox.fromSize(
      size: penSize,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: fitted,
            child: Image.asset(art.asset, fit: BoxFit.fill),
          ),
          for (final (index, centre) in art.switches.indexed)
            Positioned(
              left:
                  fitted.left +
                  centre.dx / art.size.width * fitted.width -
                  _targetSize / 2,
              top:
                  fitted.top +
                  centre.dy / art.size.height * fitted.height -
                  _targetSize / 2,
              width: _targetSize,
              height: _targetSize,
              child: _Target(
                key: Key('external_switch_$index'),
                index: index,
                selected: index == selected,
                onTap: () => onSelect(index),
              ),
            ),
          for (final (index, centre) in art.indicators.indexed)
            Positioned(
              left:
                  fitted.left +
                  centre.dx / art.size.width * fitted.width -
                  _markerSize / 2,
              top:
                  fitted.top +
                  centre.dy / art.size.height * fitted.height -
                  _markerSize / 2,
              width: _markerSize,
              height: _markerSize,
              child: _Contact(
                key: Key('external_contact_$index'),
                closed: contacts.contains(index),
              ),
            ),
        ],
      ),
    );
  }

  /// [source] scaled to sit inside [box] without distortion, centred.
  static Rect _fit(Size source, Size box) {
    final scale = (box.width / source.width) < (box.height / source.height)
        ? box.width / source.width
        : box.height / source.height;
    final size = Size(source.width * scale, source.height * scale);
    return Rect.fromLTWH(
      (box.width - size.width) / 2,
      (box.height - size.height) / 2,
      size.width,
      size.height,
    );
  }
}

/// One artwork and the geometry measured in it.
class ExternalPedalArtwork {
  /// Creates an [ExternalPedalArtwork].
  const ExternalPedalArtwork({
    required this.asset,
    required this.size,
    required this.switches,
    required this.indicators,
  });

  /// The bundled picture.
  final String asset;

  /// The source raster's own size; every offset below is in its pixels.
  final Size size;

  /// The centre of each switch, left to right.
  final List<Offset> switches;

  /// The centre of each contact indicator.
  final List<Offset> indicators;
}

/// A hit target over one switch, with its name under it.
class _Target extends StatelessWidget {
  const _Target({
    required this.index,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final label = l10n.externalButton(index + 1);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    // The ring is the selection. The artwork never moves and
                    // never recolours: it is a photograph of hardware, and a
                    // highlighted switch in it would be a photograph of
                    // hardware that does not exist.
                    color: selected ? surface.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: ExternalPedalArt._targetSize - 2,
              child: ExcludeSemantics(
                child: AppText(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected
                        ? surface.textPrimary
                        : surface.textSecondary,
                    fontSize: 26,
                    height: 1,
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

/// The dot that reports a switch's received contact state.
///
/// The contact, not the effect: a latching switch that is closed shows a lit
/// dot whether or not the action it runs left anything turned on.
class _Contact extends StatelessWidget {
  const _Contact({required this.closed, super.key});

  final bool closed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      label: context.l10n.externalContact,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: closed ? surface.ledGreen : surface.ledOff,
        ),
      ),
    );
  }
}
