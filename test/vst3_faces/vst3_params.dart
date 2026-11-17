/// A Segno plugin's parameters (`packages/segno_engine/vst3/params.h`) as
/// the console's controls hold and print them (#1815): the editors draw
/// them, and the plugins' own value text is checked against
/// [vst3ValueText].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno_engine/segno_engine.dart' show kFxLevelMax;

/// The repository root, from the test's working directory (the app's root).
Directory get repoRoot => Directory.current;

/// The fixed parameter ids in `params.h`, by name (`kInputId`, ...).
final Map<String, int> vst3FixedIds = () {
  final header = File('${repoRoot.path}/packages/segno_engine/vst3/params.h')
      .readAsStringSync();
  return {
    for (final m in RegExp(r'(k\w+Id) = (\d+),').allMatches(header))
      m[1]!: int.parse(m[2]!),
  };
}();

/// The entry's input (`kInputId`), output, balance or pan, and level.
int get kVst3InputId => vst3FixedIds['kInputId']!;
int get kVst3OutputId => vst3FixedIds['kOutputId']!;
int get kVst3PlacementId => vst3FixedIds['kPlacementId']!;
int get kVst3LevelId => vst3FixedIds['kLevelId']!;

/// The bypass (`kBypassId`), which the footswitch switches.
int get kVst3BypassId => vst3FixedIds['kBypassId']!;

/// The highest level, which a level of 1 stands for.
const double kVst3LevelMax = kFxLevelMax;

/// The entry's channel handling at the normalized values of [values] (by
/// parameter id), as `params.h` maps them; an id left out is the default's.
FxChannels vst3Channels(Map<int, double> values) {
  final input = values[kVst3InputId];
  final output = values[kVst3OutputId];
  final placement = values[kVst3PlacementId];
  final level = values[kVst3LevelId];
  return FxChannels(
    input: input == null
        ? FxChannelInput.stereo
        : FxChannelInput.values[(input * 3).round().clamp(0, 3)],
    output: output != null && output >= 0.5
        ? FxChannelOutput.mono
        : FxChannelOutput.stereo,
    placement: placement == null ? 0 : placement * 2 - 1,
    level: level == null ? 1 : level * kVst3LevelMax,
  );
}

/// The names of the input's positions, as the console's input select names
/// them.
List<String> vst3InputNames(AppLocalizations l10n) => [
  for (final input in FxChannelInput.values)
    switch (input) {
      FxChannelInput.stereo => l10n.fxChannelStereo,
      FxChannelInput.left => l10n.fxChannelLeft,
      FxChannelInput.right => l10n.fxChannelRight,
      FxChannelInput.monoSum => l10n.fxChannelMonoSum,
    },
];

/// The entry's level as the editor prints it: in dB, Off at none.
String vst3LevelText(AppLocalizations l10n, double level) {
  if (level <= 0) return l10n.fxValueOff;
  final db = 20 * math.log(level) / math.ln10;
  return l10n.fxValueDb((db * 10).round() / 10);
}

/// Parameter [id] of a plugin of [type] at normalized [value], as the
/// console prints it: a setting as the effect page's controls do, the input
/// and output by the names of their choices, the balance as its readout, the
/// level in dB.
String vst3ValueText(
  AppLocalizations l10n,
  TrackEffectType type,
  int id,
  double value,
) {
  if (id < type.params.length) {
    return l10n.fxParamValueText(type.params[id], value);
  }
  final channels = vst3Channels({id: value});
  if (id == kVst3InputId) {
    return vst3InputNames(l10n)[channels.input.index];
  }
  if (id == kVst3OutputId) {
    return channels.output == FxChannelOutput.mono
        ? l10n.fxChannelMono
        : l10n.fxChannelStereo;
  }
  if (id == kVst3PlacementId) return fxBalanceText(l10n, channels.placement);
  if (id == kVst3LevelId) return vst3LevelText(l10n, channels.level);
  throw ArgumentError.value(id, 'id', 'not a parameter with a value text');
}

/// The committed value texts, which `binding_test.cpp` reads, relative to the
/// repository root.
const String kVst3ValueTexts =
    'packages/segno_engine/vst3/test/value_texts.json';

/// [texts] ([vst3ValueTexts]) as the committed file holds it: one
/// parameter's texts a line.
String encodeVst3ValueTexts(Map<String, Object> texts) {
  final kinds = (texts['kinds']! as List<Object>).cast<Map<String, Object>>();
  String kindText(Map<String, Object> kind) {
    final params = [
      for (final p in kind['params']! as List<Object>) '  ${jsonEncode(p)}',
    ];
    return ' {"type": ${kind['type']}, "params": [\n'
        '${params.join(',\n')}\n ]}';
  }

  final body = [for (final kind in kinds) kindText(kind)].join(',\n');
  return '{"samples": ${texts['samples']}, "kinds": [\n$body\n]}\n';
}

/// The settings [vst3ValueTexts] samples every parameter at: 0 to 1 in
/// fortieths.
const int kVst3TextSamples = 40;

/// Every plugin's value texts, which `binding_test.cpp` checks each plugin's
/// own against: for each kind, each parameter but the bypass at
/// k / [kVst3TextSamples], and a stepped one also at each position.
Map<String, Object> vst3ValueTexts(AppLocalizations l10n) => {
  'samples': kVst3TextSamples,
  'kinds': [
    for (final type in TrackEffectType.values)
      if (type != TrackEffectType.none)
        {
          'type': type.code,
          'params': [
            for (final id in [
              for (var p = 0; p < type.params.length; p++) p,
              kVst3InputId,
              kVst3OutputId,
              kVst3PlacementId,
              kVst3LevelId,
            ])
              {
                'param': id,
                'texts': [
                  for (var k = 0; k <= kVst3TextSamples; k++)
                    vst3ValueText(l10n, type, id, k / kVst3TextSamples),
                ],
                if (vst3Positions(type, id) case final n when n > 1)
                  'positions': [
                    for (var k = 0; k < n; k++)
                      vst3ValueText(l10n, type, id, k / (n - 1)),
                  ],
              },
          ],
        },
  ],
};

/// How many positions parameter [id] of a plugin of [type] snaps to, or 0
/// for a continuous one.
int vst3Positions(TrackEffectType type, int id) {
  if (id < type.params.length) {
    final steps = type.params[id].steps;
    return steps > 1 ? steps : 0;
  }
  if (id == kVst3InputId) return FxChannelInput.values.length;
  if (id == kVst3OutputId) return FxChannelOutput.values.length;
  return 0;
}
