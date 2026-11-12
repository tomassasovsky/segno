// Generates lib/src/generated/segno_engine_bindings.dart from the engine's C
// API header. Run it after touching src/core/segno_engine_api.h:
//
//   dart run tool/ffigen.dart
//
// ffigen formats its output with this package's formatter settings, so the
// file needs no separate `dart format` pass. It needs libclang, which ships
// with Xcode or the Command Line Tools on macOS.
import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// The structs the Dart API reads or fills; ffigen also emits the ones these
/// reach.
const _structs = {
  'le_config',
  'le_snapshot',
  'le_record_timing_settings',
  'le_track_snapshot',
  'le_loopback_info',
  'le_device_info',
  'le_midi_info',
  'le_plugin_desc',
  'le_plugin_param_info',
  'le_lane_cache_info',
  'le_perf_target',
  'le_audition_state',
  'le_backing_decode_info',
  'le_synth_patch_desc',
  'le_synth_param_desc',
  'le_interface_input',
  'le_interface_phantom',
  'le_interface_inputs',
};

const _enums = {
  'le_result',
  'le_latency_state',
  'le_track_state',
  'le_command_code',
  'le_loopback_kind',
  'le_plugin_format',
  'le_plugin_param_flags',
  'le_cache_state',
  'le_cache_reason',
  'le_xrun_kind',
  'le_reopen_outcome',
  'le_perf_stop_reason',
  'le_synth_family',
  'le_synth_param_unit',
  'le_interface_state',
  'le_interface_control',
};

Future<void> main() async {
  final root = Platform.script.resolve('../');
  final header = root.resolve('src/core/segno_engine_api.h');
  await FfiGenerator(
    input: Input(
      entryPoints: [header],
      include: (uri) => uri == header,
      compilerOptions: ['-I${root.resolve('src/core').toFilePath()}'],
      appendCompilerOptions: true,
    ),
    output: Output(
      dart: DartOutput(
        path: root.resolve('lib/src/generated/segno_engine_bindings.dart'),
      ),
      style: const DynamicLibraryBindings(
        wrapperName: 'SegnoEngineBindings',
        wrapperDocComment:
            'Generated low-level FFI bindings for the segno_engine native '
            'audio engine.\n'
            'Do not edit by hand — see lib/src/audio_engine.dart for the '
            'typed Dart API.',
      ),
      commentType: const CommentType(CommentStyle.any, CommentLength.full),
      preamble: '''
// ignore_for_file: type=lint, doc_directive_unknown
// coverage:ignore-file
''',
    ),
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = node.originalName.startsWith('le_'),
        struct: (node) {
          node.isIncluded = _structs.contains(node.originalName);
          // A struct these reach by pointer is generated in full, so the Dart
          // side can read its fields.
          node.dependencies = CompoundDependencies.full;
        },
        enumClass: (node) => node.isIncluded = _enums.contains(
          node.originalName,
        ),
        macroConstant: (node) => node.isIncluded = true,
        typealias: (node) => node.isIncluded = TypealiasInclude.ifUsed,
        unnamedEnumConstant: (node) => node.isIncluded = true,
      ),
    ],
  ).generate();
}
