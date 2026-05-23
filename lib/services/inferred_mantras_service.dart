import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/api_config.dart';
import '../models/inferred_song.dart';
import 'authenticated_http.dart';

/// Lists inferred songs from the API and caches downloaded MP3s under app documents.
class InferredMantrasService {
  InferredMantrasService._();
  static final InferredMantrasService _instance = InferredMantrasService._();
  factory InferredMantrasService() => _instance;

  static const String _prefsPathsKey = 'inferred_mantra_local_paths_v1';

  Future<Map<String, String>> _loadPathMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsPathsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistPathMap(Map<String, String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsPathsKey, json.encode(paths));
  }

  String _safeFileStem(String inferredId) {
    return inferredId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-.]'), '_');
  }

  /// Returns a path to a non-empty file, or null if missing or stale.
  Future<String?> localPathIfExists(String inferredId) async {
    if (inferredId.isEmpty) return null;
    final m = await _loadPathMap();
    final p = m[inferredId];
    if (p == null || p.isEmpty) return null;
    final f = File(p);
    if (!await f.exists() || await f.length() == 0) {
      m.remove(inferredId);
      await _persistPathMap(m);
      return null;
    }
    return p;
  }

  Future<void> _rememberPath(String inferredId, String path) async {
    final m = await _loadPathMap();
    m[inferredId] = path;
    await _persistPathMap(m);
  }

  Future<List<InferredSong>> fetchInferredSongs() async {
    final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.inferredSongsEndpoint}');
    final response = await AuthenticatedHttp.get(
      url,
      timeout: const Duration(seconds: 45),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load inferred songs (${response.statusCode})');
    }
    final decoded = json.decode(response.body);
    if (decoded is! Map<String, dynamic>) return [];
    final raw = decoded['inferred_songs'];
    if (raw is! List) return [];
    final out = <InferredSong>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final song = InferredSong.fromJson(Map<String, dynamic>.from(e));
      if (song.inferredId.isEmpty ||
          song.transactionId.isEmpty ||
          song.songId.isEmpty) {
        continue;
      }
      out.add(song);
    }
    out.sort((a, b) {
      int ms(String iso) {
        if (iso.isEmpty) return 0;
        try {
          return DateTime.parse(iso).millisecondsSinceEpoch;
        } catch (_) {
          return 0;
        }
      }

      return ms(b.completedAt).compareTo(ms(a.completedAt));
    });
    return out;
  }

  Future<String?> fetchDownloadUrl(String inferredId) async {
    if (inferredId.isEmpty) return null;
    final encoded = Uri.encodeComponent(inferredId);
    final url = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.inferredSongsEndpoint}/$encoded',
    );
    final response = await AuthenticatedHttp.get(
      url,
      timeout: const Duration(seconds: 45),
    );
    if (response.statusCode != 200) return null;
    final decoded = json.decode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final u = decoded['download_url']?.toString();
    if (u == null || u.isEmpty) return null;
    return u;
  }

  /// Downloads from [downloadUrl] (typically CloudFront, no Bearer) into app storage.
  Future<String?> downloadInferredMp3({
    required String inferredId,
    required String downloadUrl,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/inferred_mantras');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final path = '${folder.path}/${_safeFileStem(inferredId)}.mp3';
    final uri = Uri.parse(downloadUrl);
    final response = await http.get(uri).timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) return null;
    final file = File(path);
    await file.writeAsBytes(response.bodyBytes, flush: true);
    if (!await file.exists() || await file.length() == 0) return null;
    await _rememberPath(inferredId, path);
    return path;
  }

  /// DELETE `/auth/profile/inferred/songs/{transactionId}?song_id=...`
  Future<bool> deleteInferredSong({
    required String transactionId,
    required String songId,
  }) async {
    if (transactionId.isEmpty || songId.isEmpty) return false;

    final url = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.inferredSongsEndpoint}/'
      '${Uri.encodeComponent(transactionId)}',
    ).replace(queryParameters: {'song_id': songId});

    final response = await AuthenticatedHttp.delete(
      url,
      timeout: const Duration(seconds: 45),
    );
    return response.statusCode == 200 || response.statusCode == 204;
  }

  /// Removes cached MP3 and prefs entry for [inferredId].
  Future<void> removeLocalCache(String inferredId) async {
    if (inferredId.isEmpty) return;
    final m = await _loadPathMap();
    final path = m.remove(inferredId);
    await _persistPathMap(m);
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }
}
