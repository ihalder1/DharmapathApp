import 'dart:convert';
import '../models/mantra.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';
import 'payment_http_log.dart';

class SongService {
  static double _parsePrice(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  // Fetch songs from API
  static Future<List<Mantra>> getSongs() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('🎵 FETCHING SONGS FROM API');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        print('═══════════════════════════════════════════════════════════');
        return [];
      }

      final url = '${ApiConfig.baseUrl}${ApiConfig.songsEndpoint}';
      final headers = ApiConfig.getHeaders(accessToken: token);

      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   FULL TOKEN: $token');

      final response = await AuthenticatedHttp.get(Uri.parse(url));

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final List<dynamic> songs = responseData['data']?['songs'] ?? [];
        
        print('✅ FETCH SONGS SUCCESS');
        print('   Songs count: ${songs.length}');
        print('═══════════════════════════════════════════════════════════');
        
        // Temporarily always use API `price_in` (Indian list price) + INR for display/checkout.
        const String currencyCode = 'INR';

        // Convert API response to Mantra objects
        final List<Mantra> mantras = songs.map((song) {
          final double selectedPrice = _parsePrice(song['price_in']);

          // Map API response to Mantra format
          return Mantra(
            name: _generateNameFromId(song['id'] ?? ''),
            mantraFile: song['file_name'] ?? '',
            icon: song['icon'] ?? '',
            // playtime: 0, // COMMENTED OUT
            price: selectedPrice,
            currencyCode: currencyCode,
            isBought: false, // API doesn't provide this, will be set from local state
          );
        }).toList();
        
        return mantras;
      } else {
        print('❌ FETCH SONGS FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return [];
      }
    } catch (e, stackTrace) {
      print('❌ FETCH SONGS ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      return [];
    }
  }
  
  // Generate name from ID (e.g., M-RAM-001 -> Shri Rama Mantra)
  static String _generateNameFromId(String id) {
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

  // Fetch purchased songs from API
  static Future<List<String>> getPurchasedSongs() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('🛒 FETCHING PURCHASED SONGS FROM API');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        print('═══════════════════════════════════════════════════════════');
        return [];
      }

      final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.purchasedSongsEndpoint}');

      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: $url');
      print('═══════════════════════════════════════════════════════════');

      final response = await AuthenticatedHttp.get(url);

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('═══════════════════════════════════════════════════════════');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        
        print('✅ FETCH PURCHASED SONGS SUCCESS');
        print('   Response data type: ${responseData.runtimeType}');
        print('   Response data: $responseData');
        
        final List<String> purchasedIdentifiers = [];
        
        // Handle different response formats:
        // - available_songs: [{"song_id":"F-AARATI-001","available_count":2}, ...] (ignore counts)
        // - songs_ids / song_ids on root or nested under `data`
        // - List of objects with mantra_ids (legacy)
        
        if (responseData is Map<String, dynamic>) {
          void addFromAvailableSongs(Map<String, dynamic> m) {
            if (!m.containsKey('available_songs')) return;
            final list = m['available_songs'] as List<dynamic>? ?? [];
            print('   Found available_songs with ${list.length} items');
            for (final item in list) {
              if (item is! Map) continue;
              final row = Map<String, dynamic>.from(item);
              final songId =
                  (row['song_id'] ?? row['songId'])?.toString().trim() ?? '';
              if (songId.isNotEmpty) {
                purchasedIdentifiers.add(songId);
                print('     → Purchased song_id: $songId');
              }
            }
          }

          addFromAvailableSongs(responseData);
          final nested = responseData['data'];
          if (nested is Map<String, dynamic>) {
            addFromAvailableSongs(nested);
          }

          // Format 1: Direct object with songs_ids
          if (responseData.containsKey('songs_ids')) {
            final songsIds = responseData['songs_ids'] as List<dynamic>? ?? [];
            print('   Found songs_ids field with ${songsIds.length} items');
            for (var songId in songsIds) {
              final songIdString = songId.toString().trim();
              if (songIdString.isNotEmpty) {
                purchasedIdentifiers.add(songIdString);
                print('     → Purchased song: $songIdString');
              }
            }
          } else if (responseData.containsKey('song_ids')) {
            // Also check for song_ids (without 's')
            final songsIds = responseData['song_ids'] as List<dynamic>? ?? [];
            print('   Found song_ids field with ${songsIds.length} items');
            for (var songId in songsIds) {
              final songIdString = songId.toString().trim();
              if (songIdString.isNotEmpty) {
                purchasedIdentifiers.add(songIdString);
                print('     → Purchased song: $songIdString');
              }
            }
          }
        } else if (responseData is List) {
          // Format 2: List of objects with mantra_ids
          print('   Purchased songs records count: ${responseData.length}');
          for (var record in responseData) {
            if (record is Map<String, dynamic>) {
              // Get mantra_ids array from each record
              final mantraIds = record['mantra_ids'] as List<dynamic>? ?? [];
              print('   - Record: recording_id=${record['recording_id']}, mantra_ids count=${mantraIds.length}');
              
              // Add each mantra_id to the list
              for (var mantraId in mantraIds) {
                final mantraIdString = mantraId.toString().trim();
                if (mantraIdString.isNotEmpty) {
                  purchasedIdentifiers.add(mantraIdString);
                  print('     → Purchased mantra: $mantraIdString');
                }
              }
            }
          }
        }
        
        final unique = purchasedIdentifiers.toSet().toList();
        print('   Total purchased song IDs (deduped): ${unique.length}');
        print('═══════════════════════════════════════════════════════════');
        return unique;
      } else if (response.statusCode == 404) {
        // 404 means no songs have been purchased yet - this is a normal case, not an error
        print('ℹ️  NO PURCHASED SONGS FOUND (404)');
        print('   Status: ${response.statusCode}');
        print('   Message: No songs have been purchased yet');
        print('═══════════════════════════════════════════════════════════');
        return [];
      } else {
        print('❌ FETCH PURCHASED SONGS FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return [];
      }
    } catch (e, stackTrace) {
      print('❌ FETCH PURCHASED SONGS ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      return [];
    }
  }

  /// PUT purchase after payment — logged with [PaymentHttpLog] (same shape as payment APIs).
  static Future<bool> sendPurchaseData({
    required String transactionId,
    required String transactionTime,
    required String amount,
    required String currency,
    required List<String> songIds,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.purchasedSongsEndpoint}');
    final urlExact = url.toString();
    Map<String, String>? headers;
    String? bodyExact;

    try {
      final authService = AuthService();
      final token = authService.accessToken;

      if (token == null) {
        print(
          '[SongService] sendPurchaseData — no access token; URL (exact): $urlExact',
        );
        return false;
      }

      headers = {
        'Content-Type': 'application/json',
        'x-api-key': ApiConfig.apiKey,
        'Authorization': 'Bearer $token',
      };

      bodyExact = json.encode({
        'transactionId': transactionId,
        'transactionTime': transactionTime,
        'amount': amount,
        'currency': currency,
        'song_ids': songIds,
      });

      final response = await AuthenticatedHttp.put(url, body: bodyExact);

      PaymentHttpLog.log(
        operation: 'sendPurchaseData (after payment)',
        method: 'PUT',
        urlExact: urlExact,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        responseStatus: response.statusCode,
        responseHeaders: response.headers,
        responseBodyExact: response.body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      }
      return false;
    } catch (e, stackTrace) {
      PaymentHttpLog.logError(
        operation: 'sendPurchaseData (after payment)',
        method: 'PUT',
        urlExact: urlExact,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  // Helper method to extract song ID from mantra file (remove .mp3 extension)
  static String extractSongId(String mantraFile) {
    String songId = mantraFile.trim();
    // Remove .mp3 extension if present
    if (songId.toLowerCase().endsWith('.mp3')) {
      songId = songId.substring(0, songId.length - 4);
    }
    return songId;
  }
}
