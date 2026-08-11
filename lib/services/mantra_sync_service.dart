import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';
import 'location_pricing_service.dart';

class MantraSyncService {
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

  // Sync mantras from API with local metadata
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
      final String? globalLastUpdated = apiResponse['last_updated'];
      final DateTime? globalLastUpdatedDate = parseDate(globalLastUpdated);
      final DateTime defaultLastUpdated =
          parseDate('2025-01-01T07:42:24.648Z') ?? DateTime(2025, 1, 1);

      // 2. Load local metadata
      final Map<String, dynamic> localMetadata = await loadLocalMetadata();
      final List<dynamic> localMantras = List.from(
        localMetadata['mantras'] ?? [],
      );
      final bundledMetadata = await _loadBundledMetadata();
      final bundledMantras = List<dynamic>.from(
        bundledMetadata['mantras'] ?? [],
      );

      // 3. Create a map of local mantras by mantra_file for quick lookup
      final Map<String, Map<String, dynamic>> localMantrasMap = {};
      for (var mantra in localMantras) {
        final fileKey = _catalogueFileKey(mantra['mantra_file']);
        if (fileKey.isNotEmpty) {
          localMantrasMap[fileKey] = Map<String, dynamic>.from(mantra);
        }
      }
      final Map<String, Map<String, dynamic>> bundledMantrasMap = {};
      for (var mantra in bundledMantras) {
        final fileKey = _catalogueFileKey(mantra['mantra_file']);
        if (fileKey.isNotEmpty) {
          bundledMantrasMap[fileKey] = Map<String, dynamic>.from(mantra);
        }
      }

      final pricingRegion = await LocationPricingService.getPricingRegion();
      final currencyCode = LocationPricingService.currencyCodeForRegion(
        pricingRegion,
      );

      // 4. Process each API song
      final List<Map<String, dynamic>> updatedMantras = [];
      final Set<String> apiFileNames = {};

      for (var apiSong in apiSongs) {
        final Map<String, dynamic> apiMap = Map<String, dynamic>.from(
          apiSong as Map,
        );
        final String fileName = apiMap['file_name'] ?? '';
        final String id = apiMap['id'] ?? '';
        final resolved = LocationPricingService.resolveSongPricing(
          apiMap,
          pricingRegion,
        );
        final double selectedPrice = resolved.price;
        final String iconUrl = apiMap['icon'] ?? '';
        final String? songLastUpdated =
            apiMap['last_updated'] ?? apiMap['created_at'];

        apiFileNames.add(fileName);

        // Get last_updated for this song (use song's last_updated or global or default)
        DateTime songLastUpdatedDate =
            parseDate(songLastUpdated) ??
            globalLastUpdatedDate ??
            defaultLastUpdated;

        // Check if file exists in local list
        final fileKey = _catalogueFileKey(fileName);
        final bundledMantra = bundledMantrasMap[fileKey];
        final localMantra = localMantrasMap[fileKey] ?? bundledMantra;
        if (localMantra != null) {
          // Case A: File exists - check if needs update
          final String? localLastModified = localMantra['last_modified'];
          final DateTime? localLastModifiedDate = parseDate(localLastModified);

          if (localLastModifiedDate != null) {}

          bool needsUpdate = false;
          if (localLastModifiedDate == null) {
            needsUpdate = true;
          } else {
            // Normalize both dates to UTC for accurate comparison
            final apiDateUtc = songLastUpdatedDate.toUtc();
            final localDateUtc = localLastModifiedDate.toUtc();

            // Only update if API date is significantly newer (more than 1 second difference)
            // This handles timezone and precision issues
            if (apiDateUtc.isAfter(
              localDateUtc.add(const Duration(seconds: 1)),
            )) {
              needsUpdate = true;
            } else {}
          }

          if (needsUpdate) {
            // Update the record
            final updatedMantra = Map<String, dynamic>.from(localMantra);
            if (bundledMantra?['name'] is String &&
                (bundledMantra!['name'] as String).trim().isNotEmpty) {
              updatedMantra['name'] = bundledMantra['name'];
            }
            LocationPricingService.applyApiPricingToMetadata(
              updatedMantra,
              apiMap,
              pricingRegion,
            );
            // Save in ISO 8601 format (UTC) for accurate comparison
            updatedMantra['last_modified'] = songLastUpdatedDate
                .toUtc()
                .toIso8601String();

            // Extract icon name from URL or use existing
            String iconName = updatedMantra['icon'] as String? ?? '$id.jpg';
            if (iconUrl.isNotEmpty) {
              // Extract extension from URL or use .jpg
              final uri = Uri.parse(iconUrl);
              final urlPath = uri.path;
              final extension = path.extension(urlPath).isNotEmpty
                  ? path.extension(urlPath)
                  : '.jpg';
              iconName = '$id$extension';
              updatedMantra['icon'] = iconName;
            }

            updatedMantras.add(updatedMantra);

            // Download icon
            if (iconUrl.isNotEmpty) {
              await downloadIcon(iconUrl, iconName);
            }
          } else {
            // Keep existing record but always refresh price/currency fields.
            final updatedMantra = Map<String, dynamic>.from(localMantra);
            if (bundledMantra?['name'] is String &&
                (bundledMantra!['name'] as String).trim().isNotEmpty) {
              updatedMantra['name'] = bundledMantra['name'];
            }
            LocationPricingService.applyApiPricingToMetadata(
              updatedMantra,
              apiMap,
              pricingRegion,
            );
            updatedMantras.add(updatedMantra);
          }
        } else {
          // Case B: File not found - add new entry

          // Extract icon name from URL
          String iconName = '$id.jpg';
          if (iconUrl.isNotEmpty) {
            final uri = Uri.parse(iconUrl);
            final urlPath = uri.path;
            final extension = path.extension(urlPath).isNotEmpty
                ? path.extension(urlPath)
                : '.jpg';
            iconName = '$id$extension';
          }

          // Create new mantra entry
          final newMantra = <String, dynamic>{
            'name': _generateNameFromId(id),
            'mantra_file': fileName,
            'icon': iconName,
            'last_modified': songLastUpdatedDate.toUtc().toIso8601String(),
          };
          LocationPricingService.applyApiPricingToMetadata(
            newMantra,
            apiMap,
            pricingRegion,
          );

          updatedMantras.add(newMantra);

          // Download icon
          if (iconUrl.isNotEmpty) {
            await downloadIcon(iconUrl, iconName);
          }
        }
      }

      // Case C: Remove mantras not in API response
      final List<String> toRemove = [];
      for (var localMantra in localMantras) {
        final fileName = localMantra['mantra_file'] as String?;
        if (fileName != null && !apiFileNames.contains(fileName)) {
          toRemove.add(fileName);
        }
      }

      // 5. Save updated metadata
      final updatedMetadata = {'mantras': updatedMantras};

      await saveLocalMetadata(updatedMetadata);

      return true;
    } catch (e, stackTrace) {
      return false;
    }
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
