import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/mantra.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';

class SongService {
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
        final List<dynamic> songs = responseData['data']?['songs'] ?? [];
        
        print('✅ FETCH SONGS SUCCESS');
        print('   Songs count: ${songs.length}');
        print('═══════════════════════════════════════════════════════════');
        
        // Convert API response to Mantra objects
        final List<Mantra> mantras = songs.map((song) {
          // Map API response to Mantra format
          return Mantra(
            name: _generateNameFromId(song['id'] ?? ''),
            mantraFile: song['file_name'] ?? '',
            icon: song['icon'] ?? '',
            // playtime: 0, // COMMENTED OUT
            price: int.tryParse(song['price']?.toString() ?? '0') ?? 0,
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
      final headers = {
        'x-api-key': ApiConfig.apiKey,
        'Authorization': 'Bearer $token',
      };

      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('═══════════════════════════════════════════════════════════');

      final response = await http.get(
        url,
        headers: headers,
      ).timeout(
        const Duration(seconds: 30),
      );

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('═══════════════════════════════════════════════════════════');

      if (response.statusCode == 200) {
        final List<dynamic> purchasedSongsData = json.decode(response.body);
        
        print('✅ FETCH PURCHASED SONGS SUCCESS');
        print('   Purchased songs records count: ${purchasedSongsData.length}');
        
        // Extract mantra_ids from each object in the response
        // Response structure: [{ "recording_id": "...", "mantra_ids": ["M-RAM-001.mp3"], ... }]
        final List<String> purchasedIdentifiers = [];
        for (var record in purchasedSongsData) {
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
        
        print('   Total purchased mantra IDs: ${purchasedIdentifiers.length}');
        print('═══════════════════════════════════════════════════════════');
        return purchasedIdentifiers;
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
}
