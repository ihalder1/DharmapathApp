import 'package:colab_app_ui/models/mantra.dart';
import 'package:colab_app_ui/services/preview_audio_source.dart';
import 'package:colab_app_ui/services/mantra_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

Mantra mantra({String? localAudioPath}) => Mantra(
  songId: 'M-HANUMAN-001',
  name: 'Hanuman Mantra',
  mantraFile: 'M-HANUMAN-001.mp3',
  icon: 'M-HANUMAN-001.png',
  price: 99,
  localAudioPath: localAudioPath,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clean bundled mantra uses its Flutter asset', () async {
    final source = await resolvePreviewAudioSource(
      mantra: mantra(),
      isBundled: true,
      fileExists: (_) async => false,
    );

    expect(source.type, PreviewAudioSourceType.flutterAsset);
    expect(source.path, 'Media/M-HANUMAN-001.mp3');
  });

  test('icon-only completion does not manufacture an audio path', () async {
    final path = await resolveCompletedLocalAudioPath(
      currentPath: null,
      downloadedPath: null,
      fileExists: (_) async => false,
    );

    expect(path, isNull);
  });

  test('stale bundled local path falls back to its Flutter asset', () async {
    final source = await resolvePreviewAudioSource(
      mantra: mantra(localAudioPath: '/documents/Media/M-HANUMAN-001.mp3'),
      isBundled: true,
      fileExists: (_) async => false,
    );

    expect(source.type, PreviewAudioSourceType.flutterAsset);
    expect(source.path, 'Media/M-HANUMAN-001.mp3');
  });

  test('valid downloaded override uses the device file', () async {
    const downloaded = '/documents/Media/M-HANUMAN-001.mp3';
    final source = await resolvePreviewAudioSource(
      mantra: mantra(localAudioPath: downloaded),
      isBundled: true,
      fileExists: (path) async => path == downloaded,
    );

    expect(source.type, PreviewAudioSourceType.deviceFile);
    expect(source.path, downloaded);
  });

  test('completion adopts only a verified downloaded audio file', () async {
    const downloaded = '/documents/Media/NEW-001.mp3';
    final path = await resolveCompletedLocalAudioPath(
      currentPath: null,
      downloadedPath: downloaded,
      fileExists: (path) async => path == downloaded,
    );

    expect(path, downloaded);
  });

  test('dynamic-only song uses a valid downloaded device file', () async {
    const downloaded = '/documents/Media/NEW-001.mp3';
    final source = await resolvePreviewAudioSource(
      mantra: mantra(localAudioPath: downloaded),
      isBundled: false,
      fileExists: (path) async => path == downloaded,
    );

    expect(source.type, PreviewAudioSourceType.deviceFile);
  });

  test(
    'dynamic-only song without downloaded audio remains unavailable',
    () async {
      await expectLater(
        resolvePreviewAudioSource(
          mantra: mantra(localAudioPath: '/documents/Media/NEW-001.mp3'),
          isBundled: false,
          fileExists: (_) async => false,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('bundled membership comes from packaged catalogue metadata', () async {
    expect(
      await MantraSyncService.isBundledMantra(
        songId: 'M-HANUMAN-001',
        mantraFile: 'M-HANUMAN-001.mp3',
      ),
      isTrue,
    );
    expect(
      await MantraSyncService.isBundledMantra(
        songId: 'API-ONLY-001',
        mantraFile: 'API-ONLY-001.mp3',
      ),
      isFalse,
    );
  });
}
