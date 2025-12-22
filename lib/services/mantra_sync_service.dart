import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../constants/api_config.dart';
import 'auth_service.dart';

class MantraSyncService {
  // Fetch songs from API
  static Future<Map<String, dynamic>?> fetchSongsFromAPI() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('🔄 FETCHING SONGS FROM API');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        return null;
      }

      final url = '${ApiConfig.baseUrl}${ApiConfig.songsEndpoint}';
      final headers = ApiConfig.getHeaders(accessToken: token);

      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   FULL TOKEN: $token');

      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      ).timeout(
        const Duration(seconds: 30),
      );

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        print('✅ FETCH SONGS SUCCESS');
        print('   Total Count: ${responseData['total_count']}');
        print('   Last Updated: ${responseData['last_updated']}');
        print('═══════════════════════════════════════════════════════════');
        return responseData;
      } else {
        print('❌ FETCH SONGS FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return null;
      }
    } catch (e, stackTrace) {
      print('❌ FETCH SONGS ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      return null;
    }
  }

  // Load local metadata.json (from writable location first, then assets)
  static Future<Map<String, dynamic>> loadLocalMetadata() async {
    try {
      print('📂 Loading local metadata.json...');
      
      // Skip file operations on web
      if (kIsWeb) {
        print('Web platform detected, loading from assets only');
        String jsonString;
        try {
          jsonString = await rootBundle.loadString('Media/metadata.json');
        } catch (e) {
          jsonString = await rootBundle.loadString('assets/Media/metadata.json');
        }
        final Map<String, dynamic> jsonData = json.decode(jsonString);
        print('✅ Loaded ${(jsonData['mantras'] as List).length} mantras from assets');
        return jsonData;
      }
      
      // First try to load from writable location (synced metadata)
      try {
        final Directory appDir = await getApplicationDocumentsDirectory();
        final String mediaPath = path.join(appDir.path, 'Media', 'metadata.json');
        final File metadataFile = File(mediaPath);
        
        if (await metadataFile.exists()) {
          print('Loading from synced metadata: $mediaPath');
          final String jsonString = await metadataFile.readAsString();
          final Map<String, dynamic> jsonData = json.decode(jsonString);
          print('✅ Loaded ${(jsonData['mantras'] as List).length} mantras from synced metadata');
          return jsonData;
        }
      } catch (e) {
        print('Could not load from synced metadata: $e');
      }
      
      // Fallback to assets - try multiple paths
      print('Falling back to assets metadata.json');
      String jsonString;
      try {
        jsonString = await rootBundle.loadString('Media/metadata.json');
      } catch (e1) {
        print('Failed to load from Media/metadata.json, trying assets/Media/metadata.json: $e1');
        try {
          jsonString = await rootBundle.loadString('assets/Media/metadata.json');
        } catch (e2) {
          print('Failed to load from assets/Media/metadata.json: $e2');
          rethrow;
        }
      }
      final Map<String, dynamic> jsonData = json.decode(jsonString);
      print('✅ Loaded ${(jsonData['mantras'] as List).length} mantras from assets');
      return jsonData;
    } catch (e) {
      print('❌ Error loading local metadata: $e');
      return {'mantras': []};
    }
  }

  // Save metadata.json to writable location (app documents directory)
  static Future<void> saveLocalMetadata(Map<String, dynamic> metadata) async {
    try {
      print('💾 Saving metadata.json...');
      
      // Skip file operations on web
      if (kIsWeb) {
        print('Web platform detected, skipping file save');
        print('Updated metadata (would be saved):');
        print(const JsonEncoder.withIndent('    ').convert(metadata));
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
      final String jsonString = const JsonEncoder.withIndent('    ').convert(metadata);
      await metadataFile.writeAsString(jsonString);
      
      print('✅ Saved metadata.json to: ${metadataFile.path}');
    } catch (e, stackTrace) {
      print('❌ Error saving metadata.json: $e');
      print('Stack trace: $stackTrace');
      print('Updated metadata (would be saved):');
      print(const JsonEncoder.withIndent('    ').convert(metadata));
    }
  }

  // Download icon image
  static Future<bool> downloadIcon(String iconUrl, String localIconName) async {
    try {
      print('📥 Downloading icon: $iconUrl -> $localIconName');
      
      // Skip file operations on web
      if (kIsWeb) {
        print('Web platform detected, skipping icon download');
        return false;
      }
      
      final response = await http.get(Uri.parse(iconUrl)).timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode == 200) {
        // Get the app's documents directory (writable location)
        final Directory appDir = await getApplicationDocumentsDirectory();
        final String mediaPath = path.join(appDir.path, 'Media');
        final Directory mediaDir = Directory(mediaPath);
        
        if (!await mediaDir.exists()) {
          await mediaDir.create(recursive: true);
        }
        
        final File iconFile = File(path.join(mediaPath, localIconName));
        await iconFile.writeAsBytes(response.bodyBytes);
        
        print('✅ Downloaded icon to: ${iconFile.path}');
        return true;
      } else {
        print('❌ Failed to download icon: Status ${response.statusCode}');
        return false;
      }
    } catch (e, stackTrace) {
      print('❌ Error downloading icon: $e');
      print('Stack trace: $stackTrace');
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
      print('❌ Error parsing date "$dateString": $e');
      return null;
    }
  }

  // Sync mantras from API with local metadata
  static Future<bool> syncMantras() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('🔄 STARTING MANTRA SYNC');
      print('═══════════════════════════════════════════════════════════');
      
      // 1. Fetch songs from API
      final apiResponse = await fetchSongsFromAPI();
      if (apiResponse == null || apiResponse['data'] == null) {
        print('❌ Failed to fetch songs from API');
        return false;
      }

      final List<dynamic> apiSongs = apiResponse['data']['songs'] ?? [];
      final String? globalLastUpdated = apiResponse['last_updated'];
      final DateTime? globalLastUpdatedDate = parseDate(globalLastUpdated);
      final DateTime defaultLastUpdated = parseDate('2025-01-01T07:42:24.648Z') ?? DateTime(2025, 1, 1);

      print('📊 API Response:');
      print('   Songs count: ${apiSongs.length}');
      print('   Global last_updated: $globalLastUpdated');

      // 2. Load local metadata
      final Map<String, dynamic> localMetadata = await loadLocalMetadata();
      final List<dynamic> localMantras = List.from(localMetadata['mantras'] ?? []);
      
      print('📊 Local Metadata:');
      print('   Mantras count: ${localMantras.length}');

      // 3. Create a map of local mantras by mantra_file for quick lookup
      final Map<String, Map<String, dynamic>> localMantrasMap = {};
      for (var mantra in localMantras) {
        final fileName = mantra['mantra_file'] as String?;
        if (fileName != null) {
          localMantrasMap[fileName] = Map<String, dynamic>.from(mantra);
        }
      }

      // 4. Process each API song
      final List<Map<String, dynamic>> updatedMantras = [];
      final Set<String> apiFileNames = {};

      for (var apiSong in apiSongs) {
        final String fileName = apiSong['file_name'] ?? '';
        final String id = apiSong['id'] ?? '';
        final String price = apiSong['price']?.toString() ?? '0';
        final String iconUrl = apiSong['icon'] ?? '';
        final String? songLastUpdated = apiSong['last_updated'];
        
        apiFileNames.add(fileName);

        // Get last_updated for this song (use song's last_updated or global or default)
        DateTime songLastUpdatedDate = parseDate(songLastUpdated) ?? 
                                      globalLastUpdatedDate ?? 
                                      defaultLastUpdated;

        print('\n📝 Processing: $fileName');
        print('   ID: $id');
        print('   Price: $price');
        print('   Icon URL: $iconUrl');
        print('   Last Updated: ${songLastUpdatedDate.toIso8601String()}');

        // Check if file exists in local list
        final localMantra = localMantrasMap[fileName];
        if (localMantra != null) {
          // Case A: File exists - check if needs update
          final String? localLastModified = localMantra['last_modified'];
          final DateTime? localLastModifiedDate = parseDate(localLastModified);

          print('   ✅ Found in local list');
          print('   Local last_modified: $localLastModified');
          if (localLastModifiedDate != null) {
            print('   Local last_modified (parsed): ${localLastModifiedDate.toIso8601String()}');
            print('   API last_updated (parsed): ${songLastUpdatedDate.toIso8601String()}');
            print('   Comparison: API isAfter Local = ${songLastUpdatedDate.isAfter(localLastModifiedDate)}');
            print('   Time difference: ${songLastUpdatedDate.difference(localLastModifiedDate).inSeconds} seconds');
          }

          bool needsUpdate = false;
          if (localLastModifiedDate == null) {
            needsUpdate = true;
            print('   ⚠️  Local has no last_modified, will update');
          } else {
            // Normalize both dates to UTC for accurate comparison
            final apiDateUtc = songLastUpdatedDate.toUtc();
            final localDateUtc = localLastModifiedDate.toUtc();
            
            // Only update if API date is significantly newer (more than 1 second difference)
            // This handles timezone and precision issues
            if (apiDateUtc.isAfter(localDateUtc.add(const Duration(seconds: 1)))) {
              needsUpdate = true;
              print('   ⚠️  API is newer, will update');
            } else {
              print('   ✓ Local is up to date (API: ${apiDateUtc.toIso8601String()}, Local: ${localDateUtc.toIso8601String()})');
            }
          }

          if (needsUpdate) {
            // Update the record
            final updatedMantra = Map<String, dynamic>.from(localMantra);
            updatedMantra['price'] = int.tryParse(price) ?? updatedMantra['price'];
            // Save in ISO 8601 format (UTC) for accurate comparison
            updatedMantra['last_modified'] = songLastUpdatedDate.toUtc().toIso8601String();
            
            // Extract icon name from URL or use existing
            String iconName = updatedMantra['icon'] as String? ?? '$id.jpg';
            if (iconUrl.isNotEmpty) {
              // Extract extension from URL or use .jpg
              final uri = Uri.parse(iconUrl);
              final urlPath = uri.path;
              final extension = path.extension(urlPath).isNotEmpty ? path.extension(urlPath) : '.jpg';
              iconName = '$id$extension';
              updatedMantra['icon'] = iconName;
            }

            updatedMantras.add(updatedMantra);

            // Download icon
            if (iconUrl.isNotEmpty) {
              await downloadIcon(iconUrl, iconName);
            }

            print('   ✅ Updated local record');
          } else {
            // Keep existing record as is
            updatedMantras.add(localMantra);
          }
        } else {
          // Case B: File not found - add new entry
          print('   ➕ Not found in local list, adding new entry');

          // Extract icon name from URL
          String iconName = '$id.jpg';
          if (iconUrl.isNotEmpty) {
            final uri = Uri.parse(iconUrl);
            final urlPath = uri.path;
            final extension = path.extension(urlPath).isNotEmpty ? path.extension(urlPath) : '.jpg';
            iconName = '$id$extension';
          }

          // Create new mantra entry
          final newMantra = {
            'name': _generateNameFromId(id),
            'mantra_file': fileName,
            'icon': iconName,
            'price': int.tryParse(price) ?? 0,
            // Save in ISO 8601 format (UTC) for accurate comparison
            'last_modified': songLastUpdatedDate.toUtc().toIso8601String(),
          };

          updatedMantras.add(newMantra);

          // Download icon
          if (iconUrl.isNotEmpty) {
            await downloadIcon(iconUrl, iconName);
          }

          print('   ✅ Added new entry');
        }
      }

      // Case C: Remove mantras not in API response
      final List<String> toRemove = [];
      for (var localMantra in localMantras) {
        final fileName = localMantra['mantra_file'] as String?;
        if (fileName != null && !apiFileNames.contains(fileName)) {
          toRemove.add(fileName);
          print('🗑️  Will remove: $fileName (not in API response)');
        }
      }

      // 5. Save updated metadata
      final updatedMetadata = {
        'mantras': updatedMantras,
      };

      await saveLocalMetadata(updatedMetadata);

      print('\n✅ SYNC COMPLETE');
      print('   Updated mantras: ${updatedMantras.length}');
      print('   Removed mantras: ${toRemove.length}');
      print('═══════════════════════════════════════════════════════════');

      return true;
    } catch (e, stackTrace) {
      print('❌ SYNC ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
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

