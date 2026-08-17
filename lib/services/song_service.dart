import 'dart:convert';
import '../models/mantra.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';
import 'payment_http_log.dart';
import 'location_pricing_service.dart';

class SongService {
  static bool _lastPurchaseCountFetchSucceeded = false;
  // Fetch songs from API
  static Future<List<Mantra>> getSongs() async {
    try {
      final authService = AuthService();
      final token = authService.accessToken;

      if (token == null) {
        return [];
      }

      final url = '${ApiConfig.baseUrl}${ApiConfig.songsEndpoint}';
      final headers = ApiConfig.getHeaders(accessToken: token);

      final response = await AuthenticatedHttp.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final List<dynamic> songs = responseData['data']?['songs'] ?? [];

        final pricingRegion = await LocationPricingService.getPricingRegion();

        // Convert API response to Mantra objects
        final List<Mantra> mantras = songs.map((song) {
          final songMap = Map<String, dynamic>.from(song as Map);
          final resolved = LocationPricingService.resolveSongPricing(
            songMap,
            pricingRegion,
          );

          // Map API response to Mantra format
          return Mantra(
            name: _generateNameFromId(song['id'] ?? ''),
            mantraFile: song['file_name'] ?? '',
            icon: song['icon'] ?? '',
            // playtime: 0, // COMMENTED OUT
            price: resolved.price,
            currencyCode: resolved.currencyCode,
            isBought: false,
            purchasedCount: 0,
          );
        }).toList();

        return mantras;
      } else {
        return [];
      }
    } catch (e, stackTrace) {
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

  static String _normalizeSongIdKey(String id) {
    return id.toLowerCase().trim().replaceAll('.mp3', '');
  }

  /// Per-song owned license count from GET purchase/songs (`available_count`, etc.).
  static Future<Map<String, int>> getPurchasedSongCounts() async {
    _lastPurchaseCountFetchSucceeded = false;
    try {
      final authService = AuthService();
      final token = authService.accessToken;

      if (token == null) {
        return {};
      }

      final url = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.purchasedSongsEndpoint}',
      );

      final response = await AuthenticatedHttp.get(url);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        final Map<String, int> counts = {};

        void addCount(String rawId, int delta) {
          final k = _normalizeSongIdKey(rawId);
          if (k.isEmpty || delta <= 0) return;
          counts[k] = (counts[k] ?? 0) + delta;
        }

        // Handle different response formats:
        // - available_songs: [{"song_id":"F-AARATI-001","available_count":2}, ...]
        // - songs_ids / song_ids on root or nested under `data`
        // - List of objects with mantra_ids (legacy)

        if (responseData is Map<String, dynamic>) {
          void addFromAvailableSongs(Map<String, dynamic> m) {
            if (!m.containsKey('available_songs')) return;
            final list = m['available_songs'] as List<dynamic>? ?? [];
            for (final item in list) {
              if (item is! Map) continue;
              final row = Map<String, dynamic>.from(item);
              final songId =
                  (row['song_id'] ?? row['songId'])?.toString().trim() ?? '';
              if (songId.isEmpty) continue;
              final dynamic ac = row['available_count'];
              int n = 1;
              if (ac is int) {
                n = ac;
              } else if (ac != null) {
                n = int.tryParse(ac.toString()) ?? 1;
              }
              if (n < 1) n = 1;
              addCount(songId, n);
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
            for (var songId in songsIds) {
              final songIdString = songId.toString().trim();
              if (songIdString.isNotEmpty) {
                addCount(songIdString, 1);
              }
            }
          } else if (responseData.containsKey('song_ids')) {
            // Also check for song_ids (without 's')
            final songsIds = responseData['song_ids'] as List<dynamic>? ?? [];
            for (var songId in songsIds) {
              final songIdString = songId.toString().trim();
              if (songIdString.isNotEmpty) {
                addCount(songIdString, 1);
              }
            }
          }
        } else if (responseData is List) {
          // Format 2: List of objects with mantra_ids
          for (var record in responseData) {
            if (record is Map<String, dynamic>) {
              // Get mantra_ids array from each record
              final mantraIds = record['mantra_ids'] as List<dynamic>? ?? [];

              // Add each mantra_id to the list
              for (var mantraId in mantraIds) {
                final mantraIdString = mantraId.toString().trim();
                if (mantraIdString.isNotEmpty) {
                  addCount(mantraIdString, 1);
                }
              }
            }
          }
        }

        _lastPurchaseCountFetchSucceeded = true;
        return counts;
      } else if (response.statusCode == 404) {
        // 404 means no songs have been purchased yet - this is a normal case, not an error
        _lastPurchaseCountFetchSucceeded = true;
        return {};
      } else {
        return {};
      }
    } catch (e, stackTrace) {
      return {};
    }
  }

  static Future<Map<String, int>> getPurchasedSongCountsStrict() async {
    final result = await getPurchasedSongCounts();
    if (!_lastPurchaseCountFetchSucceeded) {
      throw StateError('purchase_credit_refresh_failed');
    }
    return result;
  }

  /// Resolves [Mantra.mantraFile] / name to an entry in [counts] (normalized keys).
  static int resolvePurchasedCount(Mantra mantra, Map<String, int> counts) {
    if (counts.isEmpty) return 0;

    String normalizeId(String id) {
      return id.toLowerCase().trim().replaceAll('.mp3', '');
    }

    final mantraSongId = normalizeId(extractSongId(mantra.mantraFile));
    if (mantraSongId.isNotEmpty && counts.containsKey(mantraSongId)) {
      return counts[mantraSongId]!;
    }

    final mantraFileNorm = normalizeId(mantra.mantraFile);
    if (mantraFileNorm.isNotEmpty && counts.containsKey(mantraFileNorm)) {
      return counts[mantraFileNorm]!;
    }

    for (final e in counts.entries) {
      final purchasedIdNormalized = e.key;
      if (mantraFileNorm.contains(purchasedIdNormalized) ||
          purchasedIdNormalized.contains(mantraFileNorm)) {
        return e.value;
      }
      final mantraName = mantra.name.toLowerCase().trim();
      if (mantraName == purchasedIdNormalized ||
          mantraName.contains(purchasedIdNormalized) ||
          purchasedIdNormalized.contains(mantraName)) {
        return e.value;
      }
    }
    return 0;
  }

  /// PUT purchase after payment — logged with [PaymentHttpLog] (same shape as payment APIs).
  static Future<bool> sendPurchaseData({
    required String transactionId,
    required String transactionTime,
    required String amount,
    required String currency,
    required List<String> songIds,
  }) async {
    final url = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.purchasedSongsEndpoint}',
    );
    final urlExact = url.toString();
    Map<String, String>? headers;
    String? bodyExact;

    try {
      final authService = AuthService();
      final token = authService.accessToken;

      if (token == null) {
        return false;
      }

      headers = {
        'Content-Type': 'application/json',
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
