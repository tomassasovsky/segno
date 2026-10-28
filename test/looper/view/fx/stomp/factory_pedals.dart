import 'dart:io';

import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';

/// Every factory preset the catalogue ships, read off disk.
List<FxPreset> factoryPresets() {
  final root = Directory('packages/fx_catalogue/assets/presets');
  return [
    for (final family in root.listSync().whereType<Directory>())
      for (final file in family.listSync().whereType<File>())
        ?FxPreset.tryParse(
          family.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
          file.readAsStringSync(),
        ),
  ]..sort((a, b) => '${a.family}/${a.name}'.compareTo('${b.family}/${b.name}'));
}

/// One pedal of [module] as [preset]'s rack loads it, on that rack.
BuiltInEffect factoryPedal(FxModule module, FxPreset preset) =>
    fxModuleEntry(module, preset).copyWith(
      rack: FxRack(
        id: preset.id,
        name: preset.name,
        art: kFxFamilySlugs[preset.family],
      ),
    );
