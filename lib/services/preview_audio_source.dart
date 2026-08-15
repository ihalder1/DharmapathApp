import 'dart:io';

import '../models/mantra.dart';

enum PreviewAudioSourceType { flutterAsset, deviceFile }

class PreviewAudioSource {
  const PreviewAudioSource({required this.type, required this.path});

  final PreviewAudioSourceType type;
  final String path;
}

Future<String?> resolveCompletedLocalAudioPath({
  required String? currentPath,
  required String? downloadedPath,
  Future<bool> Function(String path)? fileExists,
}) async {
  final exists = fileExists ?? _isNonEmptyFile;
  for (final candidate in [downloadedPath, currentPath]) {
    final path = candidate?.trim() ?? '';
    if (path.isNotEmpty && await exists(path)) return path;
  }
  return null;
}

Future<PreviewAudioSource> resolvePreviewAudioSource({
  required Mantra mantra,
  required bool isBundled,
  Future<bool> Function(String path)? fileExists,
}) async {
  final localPath = mantra.localAudioPath?.trim() ?? '';
  final exists = fileExists ?? _isNonEmptyFile;
  if (localPath.isNotEmpty && await exists(localPath)) {
    return PreviewAudioSource(
      type: PreviewAudioSourceType.deviceFile,
      path: localPath,
    );
  }

  final mantraFile = mantra.mantraFile.trim();
  if (isBundled && mantraFile.isNotEmpty) {
    return PreviewAudioSource(
      type: PreviewAudioSourceType.flutterAsset,
      path: 'Media/$mantraFile',
    );
  }

  throw StateError('preview audio is not available');
}

Future<bool> _isNonEmptyFile(String path) async {
  final file = File(path);
  return await file.exists() && await file.length() > 0;
}
