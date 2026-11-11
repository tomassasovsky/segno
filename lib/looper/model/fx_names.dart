import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// The display name for chain entry [effect], the one every surface names it
/// by: a rack pedal's catalogue module, localized (the Lo-Fi Rack's
/// Distortion, whatever kind it is built on, #1750, #1752; a module the
/// catalogue no longer has keeps the name it was saved with, never its kind's,
/// so two pedals on one kind stay apart), a single built-in's type label, or
/// a hosted
/// plugin's resolved name (its id, then a generic label, as fallbacks). A
/// plugin is always named as itself, so a missing one says what to install.
String fxBlockName(AppLocalizations l10n, TrackEffect effect) =>
    switch (effect) {
      BuiltInEffect(:final module?) => l10n.fxModuleLabel(module) ?? module,
      BuiltInEffect(:final type) => l10n.effectTypeLabel(type),
      PluginEffect(:final name, :final ref) =>
        name.isNotEmpty
            ? name
            : (ref.id.isEmpty ? l10n.signalPluginUnknownName : ref.id),
    };
