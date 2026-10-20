/// The factory effects catalogue: the rack families, their presets and the
/// parameter values each carries, plus the artwork the surfaces draw them
/// with.
///
/// Data and its loader only. Nothing here knows about a chain, an engine or a
/// screen — what a preset MEANS to this engine is the repository's business,
/// and every value here is the source's own, uninterpreted.
library;

export 'src/fx_catalogue_loader.dart';
export 'src/fx_family.dart';
export 'src/fx_module.dart';
export 'src/fx_preset.dart';
