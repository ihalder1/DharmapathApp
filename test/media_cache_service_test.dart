import 'dart:io';

import 'package:colab_app_ui/services/media_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  final now = DateTime.utc(2026, 7, 26, 12);

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('media_cache_test_');
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  MediaCacheService service() => MediaCacheService(now: () => now);

  test('removes cache files older than seven days', () async {
    final cache = Directory('${sandbox.path}/colab_media_cache');
    await cache.create();
    final expired = File('${cache.path}/abandoned-upload.tmp');
    await expired.writeAsString('temporary');
    await expired.setLastModified(now.subtract(const Duration(days: 8)));

    final deleted = await service().removeExpiredFilesFrom(cache);

    expect(deleted, 1);
    expect(await expired.exists(), isFalse);
  });

  test('retains fresh cache files', () async {
    final cache = Directory('${sandbox.path}/colab_media_cache');
    await cache.create();
    final fresh = File('${cache.path}/active-download.tmp');
    await fresh.writeAsString('temporary');
    await fresh.setLastModified(now.subtract(const Duration(days: 2)));

    final deleted = await service().removeExpiredFilesFrom(cache);

    expect(deleted, 0);
    expect(await fresh.exists(), isTrue);
  });

  test(
    'never touches durable media outside the supplied cache directory',
    () async {
      final cache = Directory('${sandbox.path}/colab_media_cache');
      final recordings = Directory('${sandbox.path}/recordings');
      await cache.create();
      await recordings.create();
      final recording = File('${recordings.path}/user-recording.m4a');
      await recording.writeAsString('user content');
      await recording.setLastModified(now.subtract(const Duration(days: 30)));

      await service().removeExpiredFilesFrom(cache);

      expect(await recording.exists(), isTrue);
    },
  );
}
