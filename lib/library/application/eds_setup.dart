import 'package:flutter/services.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/session/session.dart';

/// One track of a built-in loop template: the channel (0-based) it sets up,
/// the name it gives it and the factory preset it puts on it.
typedef NewLoopTemplateTrack = ({int channel, String name, String preset});

/// The family Ed's setup takes its sounds from.
const String edsSetupFamily = "Ed's Rack";

/// Ed's setup (#1513): the track roles of a published breakdown of Ed
/// Sheeran's pedal, each with an Ed's Rack sound we chose for it. The sounds
/// are our inference, not his settings.
const List<NewLoopTemplateTrack> edsSetup = [
  (channel: 0, name: 'Guitar', preset: 'Acoustic Rhythm 1'),
  (channel: 1, name: 'Boom', preset: 'Boom Dry'),
  (channel: 2, name: 'RC20', preset: 'Bass Octave 1'),
  (channel: 3, name: 'Vox', preset: 'Vocal Close'),
];

/// Reads Ed's setup's presets from [bundle] (the app's assets when omitted)
/// and builds its template, or returns null when one of them is missing or
/// unreadable.
///
/// Reads the four preset files directly rather than the whole catalogue.
/// Each track gets the rack the Effects library adds for its preset, with
/// only the pedals the preset turns on (#1513 Q1), Post, the chain on.
Future<NewLoopTemplate?> loadEdsSetup({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final Set<String> present;
  try {
    present = (await AssetManifest.loadFromAssetBundle(
      assets,
    )).listAssets().toSet();
  } on Exception {
    return null;
  }
  final chains = <int, FxChainEnvelope>{};
  for (final track in edsSetup) {
    final key = FxCatalogueLoader.assetKey(
      'assets/presets/$edsSetupFamily/${track.preset}.fxpreset',
    );
    // A missing key is checked first: `loadString` raises an Error for it.
    if (!present.contains(key)) return null;
    final preset = FxPreset.tryParse(
      edsSetupFamily,
      await assets.loadString(key),
    );
    if (preset == null) return null;
    final rack = withFreshSlotIds(
      fxFactoryRack(preset, placement: FxPlacement.post, onlyEnabled: true),
    );
    if (rack.isEmpty) return null;
    chains[track.channel] = FxChainEnvelope(entries: rack);
  }
  return NewLoopTemplate(
    trackChains: chains,
    names: {for (final track in edsSetup) track.channel: track.name},
  );
}
