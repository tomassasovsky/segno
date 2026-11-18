// Builds the native engine (src/CMakeLists.txt) as this package's code asset.
//
// The Dart side binds it with `@Native` externals (lib/src/generated/), so
// every build that compiles Dart code which uses this package also builds the
// library from the same tree: `flutter run`, `flutter test`, `flutter build`
// and the appliance's `flutter assemble`. The library is bundled with the app
// (DynamicLoadingBundled) and the VM resolves the bindings through the
// native-assets mapping the Flutter tool writes.
//
// CMake stays the one description of the shipped library: the same project
// builds it for the appliance (Linux, plugin hosting off) and the
// development host (macOS, plugin hosting on).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// The asset's name inside this package; the bindings name the full id,
/// `package:segno_engine/segno_engine`.
const assetName = 'segno_engine';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    if (os != OS.linux && os != OS.macOS) {
      throw UnsupportedError(
        'segno_engine builds for Linux and macOS, not $os',
      );
    }
    // CMake builds for the host compiler's target. macOS passes the
    // architecture through CMAKE_OSX_ARCHITECTURES; Linux builds natively
    // only (the appliance bundle builds in an arm64 container).
    if (os != OS.current ||
        (os == OS.linux && code.targetArchitecture != Architecture.current)) {
      throw UnsupportedError(
        'segno_engine does not cross-compile: the host is '
        '${OS.current}/${Architecture.current}, the target '
        '$os/${code.targetArchitecture}',
      );
    }

    final packageRoot = input.packageRoot;
    final source = packageRoot.resolve('src/');
    final generator = await _generator();
    // One build tree per generator: CMake refuses to switch one.
    final buildDir = input.outputDirectory.resolve(
      'cmake-${generator.split(' ').first.toLowerCase()}/',
    );
    final compiler = code.cCompiler?.compiler;

    await _run('cmake', [
      '-G',
      generator,
      '-S',
      source.toFilePath(),
      '-B',
      buildDir.toFilePath(),
      '-DCMAKE_BUILD_TYPE=Release',
      // Plugin hosting is macOS-only (#920): no arm64 Linux plugins exist.
      '-DSEGNO_ENABLE_PLUGINS=${os == OS.macOS ? 'ON' : 'OFF'}',
      // Flutter names a compiler only for an app with a CMake runner, which
      // the appliance bundle has not; the appliance engine has always been
      // built with clang.
      if (compiler != null) ...[
        '-DCMAKE_C_COMPILER=${compiler.toFilePath()}',
        '-DCMAKE_CXX_COMPILER=${_cxxFor(compiler).toFilePath()}',
      ] else if (os == OS.linux) ...[
        '-DCMAKE_C_COMPILER=clang',
        '-DCMAKE_CXX_COMPILER=clang++',
      ],
      if (os == OS.macOS) ...[
        '-DCMAKE_OSX_ARCHITECTURES=${_appleArch(code.targetArchitecture)}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${_appleVersion(code.macOS)}',
      ],
    ]);
    await _run('cmake', [
      '--build',
      buildDir.toFilePath(),
      '--target',
      'segno_engine',
      '--parallel',
      '${Platform.numberOfProcessors}',
    ]);

    final library = buildDir.resolve(os.dylibFileName('segno_engine'));
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: assetName,
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
    output.dependencies.addAll([
      ..._files(source, skip: 'test'),
      ..._files(packageRoot.resolve('third_party/')),
    ]);
  });
}

/// Ninja when a working one is on the PATH (the appliance's build image has
/// no make), otherwise make.
Future<String> _generator() async {
  try {
    final result = await Process.run('ninja', ['--version']);
    if (result.exitCode == 0) return 'Ninja';
  } on ProcessException {
    // No ninja.
  }
  return 'Unix Makefiles';
}

/// clang++ (or g++) next to the C compiler Flutter picked.
Uri _cxxFor(Uri cc) {
  final name = cc.pathSegments.last;
  final cxx = name.contains('clang')
      ? name.replaceFirst('clang', 'clang++')
      : name.contains('gcc')
      ? name.replaceFirst('gcc', 'g++')
      : throw UnsupportedError(
          'segno_engine: no C++ compiler known for the C compiler $cc',
        );
  return cc.resolve(cxx);
}

String _appleVersion(MacOSCodeConfig macOS) {
  final version = macOS.deploymentVersion;
  return '${version.major}.${version.minor}';
}

String _appleArch(Architecture architecture) => switch (architecture) {
  Architecture.arm64 => 'arm64',
  Architecture.x64 => 'x86_64',
  _ => throw UnsupportedError('macOS architecture $architecture'),
};

/// Every file under [directory], except the top-level directory [skip]: the
/// inputs that decide whether the library is built again.
Iterable<Uri> _files(Uri directory, {String? skip}) sync* {
  final root = Directory.fromUri(directory);
  final skipped = skip == null ? null : root.uri.resolve('$skip/').toFilePath();
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (skipped != null && entity.path.startsWith(skipped)) continue;
    yield entity.uri;
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}
