import 'dart:io';

import 'package:colab_app_ui/services/generated_song_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File source;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('song_export_test_');
    source = File('${directory.path}/cached.mp3');
    await source.writeAsBytes(<int>[0x49, 0x44, 0x33, 0x04]);
  });

  tearDown(() => directory.delete(recursive: true));

  test('Android save uses the native exporter and succeeds', () async {
    var called = false;
    final service = GeneratedSongExportService(
      platform: SongExportPlatform.android,
      androidExporter: (path, name, mime) async {
        called = true;
        expect(path, source.path);
        expect(name, 'mantra.mp3');
        expect(mime, 'audio/mpeg');
        return <Object?, Object?>{'status': 'saved'};
      },
    );

    expect(
      await service.export(sourcePath: source.path, fileName: 'mantra.mp3'),
      SongExportStatus.saved,
    );
    expect(called, isTrue);
  });

  test('Android cancellation is not an error', () async {
    final service = GeneratedSongExportService(
      platform: SongExportPlatform.android,
      androidExporter: (_, _, _) async => <Object?, Object?>{
        'status': 'cancelled',
      },
    );
    expect(
      await service.export(sourcePath: source.path, fileName: 'mantra.mp3'),
      SongExportStatus.cancelled,
    );
  });

  test('missing source is reported before opening the picker', () async {
    var called = false;
    final service = GeneratedSongExportService(
      platform: SongExportPlatform.android,
      androidExporter: (_, _, _) async {
        called = true;
        return <Object?, Object?>{'status': 'saved'};
      },
    );
    await expectLater(
      service.export(
        sourcePath: '${directory.path}/missing.mp3',
        fileName: 'mantra.mp3',
      ),
      throwsA(isA<SongExportException>()),
    );
    expect(called, isFalse);
  });

  test('Android write failure becomes a concise export error', () async {
    final service = GeneratedSongExportService(
      platform: SongExportPlatform.android,
      androidExporter: (_, _, _) async =>
          throw const SongExportException('Could not save the mantra.'),
    );
    await expectLater(
      service.export(sourcePath: source.path, fileName: 'mantra.mp3'),
      throwsA(
        isA<SongExportException>().having(
          (error) => error.message,
          'message',
          'Could not save the mantra.',
        ),
      ),
    );
  });

  test('iOS keeps its existing exporter path', () async {
    var called = false;
    final service = GeneratedSongExportService(
      platform: SongExportPlatform.ios,
      iosExporter: (path, name, mime) async {
        called = true;
        expect(name, 'देवी.mp3');
        return true;
      },
    );
    expect(
      await service.export(sourcePath: source.path, fileName: 'देवी.mp3'),
      SongExportStatus.saved,
    );
    expect(called, isTrue);
  });

  test('iOS cancellation remains cancellation', () async {
    final service = GeneratedSongExportService(
      platform: SongExportPlatform.ios,
      iosExporter: (_, _, _) async => false,
    );
    expect(
      await service.export(sourcePath: source.path, fileName: 'mantra.mp3'),
      SongExportStatus.cancelled,
    );
  });

  test('export filename preserves Unicode and uses the MP3 extension', () {
    expect(
      generatedSongExportFileName(songId: 'देवी मंत्र', fallbackId: 'ignored'),
      'देवी मंत्र.mp3',
    );
    expect(
      generatedSongExportFileName(songId: 'song.MP3', fallbackId: 'ignored'),
      'song.MP3',
    );
    expect(
      generatedSongExportFileName(songId: 'folder/song', fallbackId: 'ignored'),
      'folder_song.mp3',
    );
  });
}
