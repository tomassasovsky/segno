import 'dart:io';

import 'package:backing_repository/backing_repository.dart';
import 'package:segno_engine/segno_engine.dart';

/// A backing repository for app tests that do not exercise the backing: a
/// mock engine and decoder of its own, and a store under a temp directory
/// that refuses copies.
BackingRepository testBackingRepository({AudioEngine? engine}) {
  final decoder = MockAudioDecoder();
  return BackingRepository.forEngine(
    engine ?? MockAudioEngine(),
    decoder: decoder,
    store: BackingAssetStore(
      root: () async => '${Directory.systemTemp.path}/segno_test_backing',
      decoder: decoder,
      copier: (source, relative) async =>
          throw UnsupportedError('no backing copies in this test'),
      digester: (path) async => null,
      syncDirectory: (_) {},
    ),
  );
}
