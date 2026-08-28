import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

enum SongExportPlatform { android, ios, unsupported }

enum SongExportStatus { saved, cancelled }

String generatedSongExportFileName({
  required String songId,
  required String fallbackId,
}) {
  var base = songId.trim().isNotEmpty
      ? songId.trim()
      : fallbackId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-.]'), '_');
  base = base
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty) base = 'mantra';
  return base.toLowerCase().endsWith('.mp3') ? base : '$base.mp3';
}

class SongExportException implements Exception {
  const SongExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef AndroidSongExporter =
    Future<Map<Object?, Object?>?> Function(
      String sourcePath,
      String fileName,
      String mimeType,
    );
typedef IosSongExporter =
    Future<bool> Function(String sourcePath, String fileName, String mimeType);

class GeneratedSongExportService {
  GeneratedSongExportService({
    SongExportPlatform? platform,
    AndroidSongExporter? androidExporter,
    IosSongExporter? iosExporter,
  }) : _platform = platform ?? _currentPlatform(),
       _androidExporter = androidExporter ?? _exportOnAndroid,
       _iosExporter = iosExporter ?? _exportOnIos;

  static const _channel = MethodChannel(
    'com.idsai.mantrasutra/generated_song_export',
  );

  final SongExportPlatform _platform;
  final AndroidSongExporter _androidExporter;
  final IosSongExporter _iosExporter;

  Future<SongExportStatus> export({
    required String sourcePath,
    required String fileName,
    String mimeType = 'audio/mpeg',
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const SongExportException('The downloaded mantra is missing.');
    }
    try {
      if (await source.length() == 0) {
        throw const SongExportException('The downloaded mantra is unreadable.');
      }
    } on SongExportException {
      rethrow;
    } on FileSystemException {
      throw const SongExportException('The downloaded mantra is unreadable.');
    }

    switch (_platform) {
      case SongExportPlatform.android:
        final response = await _androidExporter(sourcePath, fileName, mimeType);
        return response?['status'] == 'saved'
            ? SongExportStatus.saved
            : SongExportStatus.cancelled;
      case SongExportPlatform.ios:
        return await _iosExporter(sourcePath, fileName, mimeType)
            ? SongExportStatus.saved
            : SongExportStatus.cancelled;
      case SongExportPlatform.unsupported:
        throw const SongExportException(
          'Saving to this device is not supported.',
        );
    }
  }

  static SongExportPlatform _currentPlatform() {
    if (Platform.isAndroid) return SongExportPlatform.android;
    if (Platform.isIOS) return SongExportPlatform.ios;
    return SongExportPlatform.unsupported;
  }

  static Future<Map<Object?, Object?>?> _exportOnAndroid(
    String sourcePath,
    String fileName,
    String mimeType,
  ) async {
    try {
      return await _channel.invokeMapMethod<Object?, Object?>('saveAudio', {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
      });
    } on PlatformException {
      throw const SongExportException('Could not save the mantra.');
    } on MissingPluginException {
      throw const SongExportException(
        'Saving to this device is not supported.',
      );
    }
  }

  static Future<bool> _exportOnIos(
    String sourcePath,
    String fileName,
    String mimeType,
  ) async {
    const mp3Type = XTypeGroup(
      label: 'MP3 audio',
      extensions: <String>['mp3'],
      mimeTypes: <String>['audio/mpeg'],
    );
    final location = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const <XTypeGroup>[mp3Type],
    );
    if (location == null) return false;
    await XFile(
      sourcePath,
      mimeType: mimeType,
      name: fileName,
    ).saveTo(location.path);
    return true;
  }
}
