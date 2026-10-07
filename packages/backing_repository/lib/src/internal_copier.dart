import 'dart:io';

import 'package:backing_repository/src/backing_asset_store.dart';

/// A [BackingCopier] that writes under [root] (the Internal root) itself:
/// `<name>.part`, flushed to disk, then renamed into place, and the part
/// file deleted on any failure, so nothing half-written is ever named like
/// an asset. The store makes the directory durable afterwards.
///
/// Until the storage service's `copyFile` stands behind the app's volumes
/// port for Internal (#1177), this is the app's copier; it reads a USB
/// source the same way, without the read hold Part 9 adds.
BackingCopier internalBackingCopier(Future<String> Function() root) =>
    (source, relative) async {
      final segments = relative.split('/');
      if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
        throw ArgumentError.value(relative, 'relative', 'not inside the root');
      }
      final target = File('${await root()}/$relative');
      await target.parent.create(recursive: true);
      final part = File('${target.path}.part');
      try {
        final out = await part.open(mode: FileMode.write);
        try {
          await for (final chunk in File(source).openRead()) {
            await out.writeFrom(chunk);
          }
          await out.flush();
        } finally {
          await out.close();
        }
        await part.rename(target.path);
        return target.path;
      } on Object {
        if (part.existsSync()) part.deleteSync();
        rethrow;
      }
    };
