import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';

/// Draws [art] in the space its parent gives it, keeping its proportions: a
/// rack's footswitch picture, or a pedal drawn in code.
///
/// Silent to a screen reader: every surface names the rack or effect beside
/// its picture.
///
/// A picture that fails to load, or a pedal with no look, draws [fallback]
/// in its space, empty unless given, so the names beside it stay where they
/// are.
class FxArtView extends StatelessWidget {
  /// Creates an [FxArtView].
  const FxArtView({
    required this.art,
    this.fallback = const SizedBox.shrink(),
    super.key,
  });

  /// What to draw.
  final FxArt art;

  /// What a picture that fails to load is replaced by.
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    switch (art) {
      case FxRackPicture(:final asset):
        return Image.asset(
          asset,
          package: FxCatalogueLoader.package,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => fallback,
        );
      case final FxPedalPicture pedal:
        final face = fxStompFace(context.l10n, pedal);
        return face == null
            ? fallback
            : Center(child: FxStompPedal(face: face));
    }
  }
}
