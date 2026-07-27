import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Owns only disposable, application-created media cache.
///
/// User recordings, purchased/offline media, and synchronized artwork are
/// deliberately stored elsewhere and are never candidates for this cleanup.
final class MediaCacheService {
  const MediaCacheService({
    this.retention = const Duration(days: 7),
    DateTime Function()? now,
  }) : _now = now;

  static const String directoryName = 'colab_media_cache';

  final Duration retention;
  final DateTime Function()? _now;

  Future<Directory> cacheDirectory() async {
    final temporaryDirectory = await getTemporaryDirectory();
    return Directory('${temporaryDirectory.path}/$directoryName');
  }

  Future<int> removeExpiredFiles() async {
    return removeExpiredFilesFrom(await cacheDirectory());
  }

  /// Deletes expired entries strictly within [cacheDirectory].
  ///
  /// Symbolic links are deleted as links and are never followed.
  Future<int> removeExpiredFilesFrom(Directory cacheDirectory) async {
    if (!await cacheDirectory.exists()) return 0;

    final cutoff = (_now?.call() ?? DateTime.now()).subtract(retention);
    var deleted = 0;
    final directories = <Directory>[];

    await for (final entity in cacheDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) {
        directories.add(entity);
        continue;
      }

      if (entity is Link) {
        final modified = await entity.stat().then((stat) => stat.modified);
        if (modified.isBefore(cutoff)) {
          await entity.delete();
          deleted++;
        }
        continue;
      }

      if (entity is File) {
        final modified = await entity.lastModified();
        if (modified.isBefore(cutoff)) {
          await entity.delete();
          deleted++;
        }
      }
    }

    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      if (await directory.exists() && await directory.list().isEmpty) {
        await directory.delete();
      }
    }

    return deleted;
  }
}
