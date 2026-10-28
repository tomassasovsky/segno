# fx_catalogue

Standalone data package for Segno's factory effects catalogue: the nine rack
families, their presets and the parameter values each preset carries, plus
the artwork the screens draw them with. It holds the bundled assets and their
loader, and the table of pedal modules (`kFxModules`) that says which
parameters belong to which pedal. It knows nothing about the engine, an
effect chain or a screen. `looper_repository` builds effect chains from its
presets, and the app's FX library, rack editor and pedal setup screens load
it and draw its images.

## Usage

```dart
import 'package:flutter/widgets.dart';
import 'package:fx_catalogue/fx_catalogue.dart';

Future<Widget?> guitarRackBanner() async {
  final catalogue = await const FxCatalogueLoader().load();
  final family = catalogue.family('Guitar Rack');
  if (family == null) return null;

  for (final preset in family.presets) {
    final modules = fxPresetModules(preset).map((m) => m.name);
    print('${preset.name}: ${modules.join(', ')}');
  }
  return Image.asset(family.stripAsset, package: FxCatalogueLoader.package);
}
```

## Notes

- The loader reads `assets/manifest.json` and only the files Flutter's asset
  manifest says are bundled. A build without the assets loads
  `FxCatalogue.empty`, and a missing or malformed preset file is skipped.
- `FxPreset` keeps the source file's values as they are: `params` maps each
  parameter name to its number, with no scaling or defaults applied.
- `kFxModules` is a hand-written reading of the presets, because a preset is
  a flat parameter map that does not name its pedals. Tests check it against
  the bundled data.
- Image paths such as `FxFamily.stripAsset` are relative to this package;
  pass `package: FxCatalogueLoader.package` when drawing them. The images are
  our own; `assets/images/PROVENANCE.md` says how they were made.
- Pedals have no image. The app draws each one in code, in the module's
  `FxModule.colour`.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
