import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';
import 'location_pricing_service.dart';

class MantraSyncService {
  static List<DynamicAssetDownload> _pendingDownloads = const [];
  static Future<void> _metadataUpdate = Future<void>.value();
  static Set<String>? _bundledSongKeys;
  static List<DynamicAssetDownload> get pendingDownloads =>
      List.unmodifiable(_pendingDownloads);

  /// Unwrap metadata where `mantras` is nested like `[ [ {...}, {...} ] ]`.
  static List<Map<String, dynamic>> flattenMantrasToMaps(dynamic raw) {
    final result = <Map<String, dynamic>>[];
    void walk(dynamic node) {
      if (node == null) return;
      if (node is Map<String, dynamic>) {
        result.add(Map<String, dynamic>.from(node));
      } else if (node is Map) {
        result.add(
          Map<String, dynamic>.from(
            node.map((k, v) => MapEntry(k.toString(), v)),
          ),
        );
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(raw);
    return result;
  }

  /// Normalize decoded metadata so `mantras` is always a flat list of maps.
  static Map<String, dynamic> normalizeMetadataMantras(
    Map<String, dynamic> jsonData,
  ) {
    final flat = flattenMantrasToMaps(jsonData['mantras']);
    return Map<String, dynamic>.from(jsonData)..['mantras'] = flat;
  }

  /// Songs list may be at `data.songs`, top-level `songs`, or `data` as a bare list.
  static List<dynamic> songsFromApiResponse(Map<String, dynamic> apiResponse) {
    final data = apiResponse['data'];
    if (data is Map<String, dynamic>) {
      final songs = data['songs'];
      if (songs is List) return List<dynamic>.from(songs);
    }
    if (data is List) return List<dynamic>.from(data);
    final top = apiResponse['songs'];
    if (top is List) return List<dynamic>.from(top);
    return [];
  }

  // Fetch songs from API
  static Future<Map<String, dynamic>?> fetchSongsFromAPI() async {
    try {
      final authService = AuthService();
      final token = authService.accessToken;

      if (token == null) {
        return null;
      }

      final url = '${ApiConfig.baseUrl}${ApiConfig.songsEndpoint}';
      final headers = ApiConfig.getHeaders(accessToken: token);

      final response = await AuthenticatedHttp.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        return responseData;
      } else {
        return null;
      }
    } catch (e, stackTrace) {
      return null;
    }
  }

  // Load local metadata.json (from writable location first, then assets)
  static Future<Map<String, dynamic>> loadLocalMetadata() async {
    try {
      // Skip file operations on web
      if (kIsWeb) {
        String jsonString;
        try {
          jsonString = await rootBundle.loadString('Media/metadata.json');
        } catch (e) {
          jsonString = await rootBundle.loadString(
            'assets/Media/metadata.json',
          );
        }
        final Map<String, dynamic> jsonData = normalizeMetadataMantras(
          json.decode(jsonString) as Map<String, dynamic>,
        );
        return jsonData;
      }

      // First try to load from writable location (synced metadata)
      try {
        final Directory appDir = await getApplicationDocumentsDirectory();
        final String mediaPath = path.join(
          appDir.path,
          'Media',
          'metadata.json',
        );
        final File metadataFile = File(mediaPath);

        if (await metadataFile.exists()) {
          final String jsonString = await metadataFile.readAsString();
          final Map<String, dynamic> jsonData = normalizeMetadataMantras(
            json.decode(jsonString) as Map<String, dynamic>,
          );
          return jsonData;
        }
      } catch (e) {}

      // Fallback to assets - try multiple paths
      String jsonString;
      try {
        jsonString = await rootBundle.loadString('Media/metadata.json');
      } catch (e1) {
        try {
          jsonString = await rootBundle.loadString(
            'assets/Media/metadata.json',
          );
        } catch (e2) {
          rethrow;
        }
      }
      final Map<String, dynamic> jsonData = normalizeMetadataMantras(
        json.decode(jsonString) as Map<String, dynamic>,
      );
      return jsonData;
    } catch (e) {
      return {'mantras': []};
    }
  }

  /// Load the bundled catalogue used as the canonical source for display names.
  static Future<Map<String, dynamic>> _loadBundledMetadata() async {
    String jsonString;
    try {
      jsonString = await rootBundle.loadString('Media/metadata.json');
    } catch (_) {
      jsonString = await rootBundle.loadString('assets/Media/metadata.json');
    }
    return normalizeMetadataMantras(
      json.decode(jsonString) as Map<String, dynamic>,
    );
  }

  static String _catalogueFileKey(Object? value) {
    final fileName = value?.toString().trim() ?? '';
    return path.basename(fileName).toLowerCase();
  }

  // Save metadata.json to writable location (app documents directory)
  static Future<void> saveLocalMetadata(Map<String, dynamic> metadata) async {
    try {
      // Skip file operations on web
      if (kIsWeb) {
        return;
      }

      // Save to app's documents directory (writable location)
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String mediaPath = path.join(appDir.path, 'Media');
      final Directory mediaDir = Directory(mediaPath);

      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      final File metadataFile = File(path.join(mediaPath, 'metadata.json'));
      final String jsonString = const JsonEncoder.withIndent(
        '    ',
      ).convert(metadata);
      await metadataFile.writeAsString(jsonString);
    } catch (e, stackTrace) {}
  }

  // Download icon image (only if not already present under Documents/Media).
  static Future<bool> downloadIcon(String iconUrl, String localIconName) async {
    try {
      // Skip file operations on web
      if (kIsWeb) {
        return false;
      }

      final Directory appDir = await getApplicationDocumentsDirectory();
      final String mediaPath = path.join(appDir.path, 'Media');
      final Directory mediaDir = Directory(mediaPath);

      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      final File iconFile = File(path.join(mediaPath, localIconName));
      if (await iconFile.exists()) {
        return true;
      }

      final response = await http
          .get(Uri.parse(iconUrl))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        await iconFile.writeAsBytes(response.bodyBytes);

        return true;
      } else {
        return false;
      }
    } catch (e, stackTrace) {
      return false;
    }
  }

  // Parse date string to DateTime
  static DateTime? parseDate(String? dateString) {
    if (dateString == null || dateString.isEmpty) {
      return null;
    }

    try {
      // Try ISO 8601 format first (2025-12-22T07:42:24.648Z)
      if (dateString.contains('T')) {
        return DateTime.parse(dateString);
      }

      // Try YYYY-MM-DD HH:MM:SS format
      if (dateString.contains(' ')) {
        final parts = dateString.split(' ');
        if (parts.length == 2) {
          final datePart = parts[0];
          final timePart = parts[1];
          return DateTime.parse('${datePart}T$timePart');
        }
      }

      return DateTime.parse(dateString);
    } catch (e) {
      return null;
    }
  }

  /// Reconciles the backend-authoritative catalogue without performing network
  /// asset downloads. `song_id` is primary; the filename fallback migrates old
  /// installed metadata that predates the stable ID field.
  static CatalogReconciliation reconcileCatalog({
    required List<dynamic> apiSongs,
    required List<dynamic> localMantras,
    required List<dynamic> bundledMantras,
    required PricingRegion pricingRegion,
    DateTime? globalLastUpdated,
  }) {
    String stableId(Map<String, dynamic> row) {
      final explicit = (row['song_id'] ?? row['id'])?.toString().trim() ?? '';
      if (explicit.isNotEmpty) return explicit.toLowerCase();
      return _catalogueFileKey(
        row['mantra_file'] ?? row['file_name'],
      ).replaceFirst(RegExp(r'\.mp3$'), '');
    }

    Map<String, Map<String, dynamic>> index(List<dynamic> rows) {
      final result = <String, Map<String, dynamic>>{};
      for (final raw in flattenMantrasToMaps(rows)) {
        final id = stableId(raw);
        if (id.isNotEmpty) result[id] = raw;
      }
      return result;
    }

    final localById = index(localMantras);
    final bundledById = index(bundledMantras);
    final visible = <Map<String, dynamic>>[];
    final downloads = <DynamicAssetDownload>[];

    for (final raw in flattenMantrasToMaps(apiSongs)) {
      final id = stableId(raw);
      if (id.isEmpty) continue;
      final bundled = bundledById[id];
      final persisted = localById[id];
      final existing = persisted ?? bundled;
      final serverDate =
          parseDate(
            raw['last_updated']?.toString() ?? raw['created_at']?.toString(),
          ) ??
          globalLastUpdated;
      final localDate = parseDate(existing?['last_modified']?.toString());
      final isNew = existing == null;
      final isUpdated =
          !isNew &&
          serverDate != null &&
          (localDate == null ||
              serverDate.toUtc().isAfter(
                localDate.toUtc().add(const Duration(seconds: 1)),
              ));
      final wasPending = existing?['dynamic_assets_pending'] == true;

      final row = Map<String, dynamic>.from(existing ?? const {});
      row['song_id'] = raw['id']?.toString().trim().isNotEmpty == true
          ? raw['id'].toString().trim()
          : raw['song_id'].toString().trim();
      row['mantra_file'] = row['mantra_file'] ?? raw['file_name'] ?? '';
      row['name'] = (bundled?['name']?.toString().trim().isNotEmpty ?? false)
          ? bundled!['name']
          : (raw['name'] ?? row['name'] ?? _generateNameFromId(row['song_id']));
      final storeId = raw['store_product_id_android']?.toString().trim();
      if (storeId != null && storeId.isNotEmpty) {
        row['store_product_id_android'] = storeId;
      }
      LocationPricingService.applyApiPricingToMetadata(row, raw, pricingRegion);

      final iconUrl = _firstHttpUrl(raw, const [
        'icon',
        'icon_url',
        'image_url',
      ]);
      final audioUrl = _firstHttpUrl(raw, const [
        'audio_url',
        'mp3_url',
        'file_url',
        'download_url',
        'url',
        'file_name',
      ]);
      final needsAssets = isNew || isUpdated || wasPending;
      if (needsAssets) {
        final safeStem = _safeFileStem(row['song_id'].toString());
        final iconExtension = iconUrl == null
            ? '.png'
            : (path.extension(Uri.parse(iconUrl).path).isEmpty
                  ? '.png'
                  : path.extension(Uri.parse(iconUrl).path));
        row['icon'] = row['icon'] ?? '$safeStem$iconExtension';
        row['mantra_file'] =
            row['mantra_file']?.toString().trim().isNotEmpty == true
            ? path.basename(row['mantra_file'].toString())
            : '$safeStem.mp3';
        row['dynamic_assets_pending'] = audioUrl != null || iconUrl != null;
        downloads.add(
          DynamicAssetDownload(
            songId: row['song_id'].toString(),
            audioRequired: isNew,
            audioUrl: audioUrl,
            iconUrl: iconUrl,
            audioFileName: path.basename(row['mantra_file'].toString()),
            iconFileName: path.basename(row['icon'].toString()),
          ),
        );
      }
      if (serverDate != null) {
        row['last_modified'] = serverDate.toUtc().toIso8601String();
      }
      visible.add(row);
    }
    return CatalogReconciliation(
      metadata: {'mantras': visible},
      downloads: downloads,
    );
  }

  static String? _firstHttpUrl(Map<String, dynamic> row, List<String> fields) {
    for (final field in fields) {
      final value = row[field]?.toString().trim() ?? '';
      if (value.startsWith('https://') || value.startsWith('http://')) {
        return value;
      }
    }
    return null;
  }

  static String _safeFileStem(String value) =>
      value
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
          .replaceAll(RegExp(r'^\.+'), '')
          .isEmpty
      ? 'song'
      : value
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
            .replaceAll(RegExp(r'^\.+'), '');

  // Sync catalogue identity/metadata only. Asset downloads are deliberately queued.
  static Future<bool> syncMantras() async {
    try {
      // 1. Fetch songs from API
      final apiResponse = await fetchSongsFromAPI();
      if (apiResponse == null) {
        return false;
      }

      final List<dynamic> apiSongs = songsFromApiResponse(apiResponse);
      if (apiSongs.isEmpty) {
        return false;
      }
      final DateTime? globalLastUpdatedDate = parseDate(
        apiResponse['last_updated']?.toString(),
      );

      // 2. Load local metadata
      final Map<String, dynamic> localMetadata = await loadLocalMetadata();
      final List<dynamic> localMantras = List.from(
        localMetadata['mantras'] ?? [],
      );
      final bundledMetadata = await _loadBundledMetadata();
      final bundledMantras = List<dynamic>.from(
        bundledMetadata['mantras'] ?? [],
      );

      final pricingRegion = defaultTargetPlatform == TargetPlatform.android
          ? (LocationPricingService.cachedRegion ?? PricingRegion.other)
          : await LocationPricingService.getPricingRegion();
      final reconciliation = reconcileCatalog(
        apiSongs: apiSongs,
        localMantras: localMantras,
        bundledMantras: bundledMantras,
        pricingRegion: pricingRegion,
        globalLastUpdated: globalLastUpdatedDate,
      );
      _pendingDownloads = reconciliation.downloads;
      await saveLocalMetadata(reconciliation.metadata);

      return true;
    } catch (e, stackTrace) {
      return false;
    }
  }

  static Future<void> downloadPendingAssets({
    int concurrency = 3,
    void Function(DynamicAssetCompletion completion)? onComplete,
  }) async {
    final queue = List<DynamicAssetDownload>.from(_pendingDownloads);
    _pendingDownloads = const [];
    var next = 0;
    Future<void> worker() async {
      while (next < queue.length) {
        final task = queue[next++];
        var success = !task.audioRequired || task.audioUrl != null;
        String? downloadedAudioPath;
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final mediaDir = Directory(path.join(appDir.path, 'Media'));
          if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
          if (task.audioUrl != null) {
            final audioFile = File(
              path.join(mediaDir.path, task.audioFileName),
            );
            final audioSucceeded = await _downloadToFile(
              task.audioUrl!,
              audioFile,
            );
            success = audioSucceeded && success;
            if (audioSucceeded &&
                await audioFile.exists() &&
                await audioFile.length() > 0) {
              downloadedAudioPath = audioFile.path;
            }
          }
          if (task.iconUrl != null) {
            success =
                await _downloadToFile(
                  task.iconUrl!,
                  File(path.join(mediaDir.path, task.iconFileName)),
                ) &&
                success;
          }
          if (success) {
            final update = _metadataUpdate.then(
              (_) => _markAssetsComplete(task, mediaDir.path),
            );
            _metadataUpdate = update.catchError((_) {});
            await update;
          }
        } catch (_) {
          success = false;
          downloadedAudioPath = null;
        }
        onComplete?.call(
          DynamicAssetCompletion(
            songId: task.songId,
            succeeded: success,
            downloadedAudioPath: downloadedAudioPath,
          ),
        );
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 4), (_) => worker()));
  }

  static Future<bool> _downloadToFile(String url, File destination) async {
    if (await destination.exists() && await destination.length() > 0)
      return true;
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) return false;
    await destination.writeAsBytes(response.bodyBytes, flush: true);
    return true;
  }

  static Future<void> _markAssetsComplete(
    DynamicAssetDownload task,
    String mediaPath,
  ) async {
    final metadata = await loadLocalMetadata();
    final rows = flattenMantrasToMaps(metadata['mantras']);
    for (final row in rows) {
      if ((row['song_id']?.toString() ?? '').toLowerCase() ==
          task.songId.toLowerCase()) {
        row['dynamic_assets_pending'] = false;
        if (task.audioUrl != null) {
          row['local_audio_path'] = path.join(mediaPath, task.audioFileName);
        }
      }
    }
    await saveLocalMetadata({'mantras': rows});
  }

  /// Uses the packaged catalogue as the single source of truth for whether a
  /// preview can fall back to a Flutter asset.
  static Future<bool> isBundledMantra({
    required String songId,
    required String mantraFile,
  }) async {
    var keys = _bundledSongKeys;
    if (keys == null) {
      final bundled = await _loadBundledMetadata();
      keys = <String>{};
      for (final row in flattenMantrasToMaps(bundled['mantras'])) {
        final bundledId = (row['song_id'] ?? row['id'])?.toString().trim();
        final bundledFile = row['mantra_file']?.toString().trim();
        if (bundledId != null && bundledId.isNotEmpty) {
          keys.add('id:${bundledId.toLowerCase()}');
        }
        if (bundledFile != null && bundledFile.isNotEmpty) {
          keys.add('file:${_catalogueFileKey(bundledFile)}');
        }
      }
      _bundledSongKeys = keys;
    }

    final normalizedId = songId.trim().toLowerCase();
    if (normalizedId.isNotEmpty && keys.contains('id:$normalizedId')) {
      return true;
    }
    final normalizedFile = _catalogueFileKey(mantraFile);
    return normalizedFile.isNotEmpty && keys.contains('file:$normalizedFile');
  }

  // Generate name from ID (e.g., M-RAM-001 -> Shri Rama Mantra)
  static String _generateNameFromId(String id) {
    // Simple mapping - can be enhanced
    final nameMap = {
      'M-RAM-001': 'Shri Rama Mantra',
      'M-SARASWATI-001': 'Maa Saraswati Mantra',
      'M-SURYA-001': 'Surya Dev Mantra',
      'M-DURGA-001': 'Maa Durga Mantra',
      'M-MAHAKALI-001': 'Maa MahaKali Mantra',
      'M-GANESH-001': 'Ganesh Mantra',
      'M-SHANI-001': 'Shani Dev Mantra',
    };

    return nameMap[id] ?? id.replaceAll('M-', '').replaceAll('-001', ' Mantra');
  }
}

class CatalogReconciliation {
  const CatalogReconciliation({
    required this.metadata,
    required this.downloads,
  });

  final Map<String, dynamic> metadata;
  final List<DynamicAssetDownload> downloads;
}

class DynamicAssetDownload {
  const DynamicAssetDownload({
    required this.songId,
    required this.audioRequired,
    required this.audioUrl,
    required this.iconUrl,
    required this.audioFileName,
    required this.iconFileName,
  });

  final String songId;
  final bool audioRequired;
  final String? audioUrl;
  final String? iconUrl;
  final String audioFileName;
  final String iconFileName;
}

class DynamicAssetCompletion {
  const DynamicAssetCompletion({
    required this.songId,
    required this.succeeded,
    this.downloadedAudioPath,
  });

  final String songId;
  final bool succeeded;
  final String? downloadedAudioPath;
}
