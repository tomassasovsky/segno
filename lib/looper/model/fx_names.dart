import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// The display name for chain entry [effect], the one every surface names it
/// by: a rack pedal's catalogue module (the Lo-Fi Rack's Distortion, whatever
/// kind it is built on, #1750), a single built-in's type label, or a hosted
/// plugin's resolved name (its id, then a generic label, as fallbacks).
String fxBlockName(AppLocalizations l10n, TrackEffect effect) {
  if (effect.module case final module?) return module;
  return switch (effect) {
    BuiltInEffect(:final type) => l10n.effectTypeLabel(type),
    PluginEffect(:final name, :final ref) =>
      name.isNotEmpty
          ? name
          : (ref.id.isEmpty ? l10n.signalPluginUnknownName : ref.id),
  };
}
