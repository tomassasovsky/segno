import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';

/// Draws [art] in the space its parent gives it, keeping its proportions: a
/// rack's footswitch picture, or a pedal drawn in code.
///
/// A picture that fails to load leaves its space empty, so the names beside
/// it stay where they are.
class FxArtView extends StatelessWidget {
  /// Creates an [FxArtView].
  const FxArtView({required this.art, super.key});

  /// What to draw.
  final FxArt art;

  @override
  Widget build(BuildContext context) {
    switch (art) {
      case FxRackPicture(:final asset):
        return Image.asset(
          asset,
          package: FxCatalogueLoader.package,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
      case FxPedalPicture(:final effect):
        final face = fxStompFace(context.l10n, effect);
        return face == null
            ? const SizedBox.shrink()
            : Center(child: FxStompPedal(face: face));
    }
  }
}
