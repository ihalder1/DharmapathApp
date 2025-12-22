import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mantra.dart';
import 'song_service.dart';
import 'mantra_sync_service.dart';

class MantraService {
  static List<Mantra> _mantras = [];
  static List<Mantra> _cart = [];

  // Load mantras: Always sync with API first, then load from local metadata.json
  static Future<List<Mantra>> loadMantras({bool syncFirst = true}) async {
    try {
      // Always sync with API first to update local metadata.json
      print('═══════════════════════════════════════════════════════════');
      print('🔄 MANTRA SERVICE: Starting load process');
      print('═══════════════════════════════════════════════════════════');
      print('🔄 Syncing mantras with API first...');
      
      final syncResult = await MantraSyncService.syncMantras();
      print('🔄 Sync completed. Result: $syncResult');
      
      // Always load from local JSON after sync (never load directly from API)
      print('═══════════════════════════════════════════════════════════');
      print('📂 Loading mantras from local metadata.json...');
      print('═══════════════════════════════════════════════════════════');
      final mantras = await _loadFromLocalJson();
      print('✅ Successfully loaded ${mantras.length} mantras from LOCAL metadata.json');
      print('═══════════════════════════════════════════════════════════');
      return mantras;
    } catch (e, stackTrace) {
      print('❌ Error during sync or loading: $e');
      print('Stack trace: $stackTrace');
      print('Falling back to local JSON...');
      // Even if sync fails, try to load from local
      return await _loadFromLocalJson();
    }
  }

  // Load mantras from local JSON metadata
  static Future<List<Mantra>> _loadFromLocalJson() async {
    try {
      print('Attempting to load mantras from metadata.json');
      
      // First try to load from writable location (where sync saves updated metadata)
      try {
        final Directory appDir = await getApplicationDocumentsDirectory();
        final String mediaPath = path.join(appDir.path, 'Media', 'metadata.json');
        final File metadataFile = File(mediaPath);
        
        if (await metadataFile.exists()) {
          print('Loading from synced metadata: $mediaPath');
          final String jsonString = await metadataFile.readAsString();
          final Map<String, dynamic> jsonData = json.decode(jsonString);
          print('Successfully loaded ${(jsonData['mantras'] as List).length} mantras from synced metadata');
          
          _mantras = (jsonData['mantras'] as List)
              .map((json) => Mantra.fromJson(json))
              .toList();
          
          print('Successfully created ${_mantras.length} mantra objects');
          for (var mantra in _mantras) {
            print('Mantra: ${mantra.name} - ${mantra.mantraFile} - ${mantra.icon}');
          }
          return _mantras;
        }
      } catch (e) {
        print('Could not load from synced metadata: $e');
      }
      
      // Fallback to assets if writable location doesn't exist
      print('Falling back to assets metadata.json');
      String jsonString;
      try {
        jsonString = await rootBundle.loadString('Media/metadata.json');
      } catch (e) {
        print('Failed to load from Media/metadata.json, trying assets/Media/metadata.json: $e');
        jsonString = await rootBundle.loadString('assets/Media/metadata.json');
      }
      print('Successfully loaded JSON string: ${jsonString.length} characters');
      print('First 200 characters: ${jsonString.substring(0, jsonString.length > 200 ? 200 : jsonString.length)}');
      
      final Map<String, dynamic> jsonData = json.decode(jsonString);
      print('Successfully parsed JSON data');
      
      _mantras = (jsonData['mantras'] as List)
          .map((json) => Mantra.fromJson(json))
          .toList();
      
      print('Successfully created ${_mantras.length} mantra objects');
      for (var mantra in _mantras) {
        print('Mantra: ${mantra.name} - ${mantra.mantraFile} - ${mantra.icon}');
      }
      return _mantras;
    } catch (e) {
      print('Error loading mantras from local JSON: $e');
      print('Error type: ${e.runtimeType}');
      
      // Return some mock data for testing
      print('Returning mock data for testing');
      _mantras = [
        Mantra(
          name: 'Test Mantra 1',
          mantraFile: 'test1.mp3',
          icon: 'test1.jpg',
          // playtime: 300, // COMMENTED OUT
          price: 299,
        ),
        Mantra(
          name: 'Test Mantra 2',
          mantraFile: 'test2.mp3',
          icon: 'test2.jpg',
          // playtime: 240, // COMMENTED OUT
          price: 249,
        ),
      ];
      return _mantras;
    }
  }

  // Get all mantras
  static List<Mantra> getMantras() {
    return _mantras;
  }

  // Get cart items
  static List<Mantra> getCart() {
    return _cart;
  }

  // Add mantra to cart
  static void addToCart(Mantra mantra) {
    if (!_cart.any((item) => item.name == mantra.name)) {
      _cart.add(mantra.copyWith(isInCart: true));
      // Update the main list to reflect cart status
      final index = _mantras.indexWhere((item) => item.name == mantra.name);
      if (index != -1) {
        _mantras[index] = _mantras[index].copyWith(isInCart: true);
      }
    }
  }

  // Remove mantra from cart
  static void removeFromCart(Mantra mantra) {
    _cart.removeWhere((item) => item.name == mantra.name);
    // Update the main list to reflect cart status
    final index = _mantras.indexWhere((item) => item.name == mantra.name);
    if (index != -1) {
      _mantras[index] = _mantras[index].copyWith(isInCart: false);
    }
  }

  // Get cart total
  static int getCartTotal() {
    return _cart.fold(0, (total, mantra) => total + mantra.price);
  }

  // Clear cart
  static void clearCart() {
    _cart.clear();
    // Update the main list to reflect cart status
    for (int i = 0; i < _mantras.length; i++) {
      _mantras[i] = _mantras[i].copyWith(isInCart: false);
    }
  }

  // Mark mantra as purchased
  static void markAsPurchased(Mantra mantra) {
    print('═══════════════════════════════════════════════════════════');
    print('🛒 MARKING MANTRA AS PURCHASED');
    print('═══════════════════════════════════════════════════════════');
    print('Mantra to mark: ${mantra.name}');
    print('Mantra file: ${mantra.mantraFile}');
    print('Current isBought: ${mantra.isBought}');
    print('Total mantras in list: ${_mantras.length}');
    
    // First try exact match by mantraFile (case-insensitive)
    int index = _mantras.indexWhere((m) => 
      m.mantraFile.toLowerCase().trim() == mantra.mantraFile.toLowerCase().trim()
    );
    
    // If not found, try matching by name
    if (index == -1) {
      print('Not found by mantraFile, trying name match...');
      index = _mantras.indexWhere((m) => 
        m.name.toLowerCase().trim() == mantra.name.toLowerCase().trim()
      );
    }
    
    // If still not found, try partial match on mantraFile
    if (index == -1) {
      print('Not found by name, trying partial mantraFile match...');
      final searchFile = mantra.mantraFile.toLowerCase().trim();
      index = _mantras.indexWhere((m) => 
        m.mantraFile.toLowerCase().trim().contains(searchFile) ||
        searchFile.contains(m.mantraFile.toLowerCase().trim())
      );
    }
    
    if (index != -1) {
      print('✅ Found mantra at index $index');
      print('   Before: ${_mantras[index].name} - isBought: ${_mantras[index].isBought}');
      _mantras[index] = _mantras[index].copyWith(
        isBought: true,
        isInCart: false,
      );
      print('   After: ${_mantras[index].name} - isBought: ${_mantras[index].isBought}');
      print('═══════════════════════════════════════════════════════════');
    } else {
      print('❌ WARNING: Could not find mantra to mark as purchased!');
      print('   Searching for: ${mantra.name} (${mantra.mantraFile})');
      print('   Available mantras:');
      for (int i = 0; i < _mantras.length; i++) {
        print('     [$i] ${_mantras[i].name} (${_mantras[i].mantraFile}) - isBought: ${_mantras[i].isBought}');
      }
      print('═══════════════════════════════════════════════════════════');
    }
  }

  // Check if mantra is in cart
  static bool isInCart(Mantra mantra) {
    return _cart.any((item) => item.name == mantra.name);
  }

  // Generate mantra in user's voice
  static Future<bool> generateMantraInVoice({
    required String recordingId,
    required List<String> mantraIds,
  }) async {
    try {
      // Get auth token
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token') ?? 'mock-token';

      // API endpoint - replace with actual backend URL
      const String baseUrl = 'https://api.dharmapath.com'; // Replace with actual backend URL
      final url = Uri.parse('$baseUrl/api/generate-mantra');

      // Prepare request body
      final requestBody = json.encode({
        'recording_id': recordingId,
        'mantra_ids': mantraIds,
      });

      print('Generating mantra in voice...');
      print('Recording ID: $recordingId');
      print('Mantra IDs: $mantraIds');

      // Make API call
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: requestBody,
      ).timeout(
        const Duration(seconds: 30),
      );

      print('API Response Status: ${response.statusCode}');
      print('API Response Body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        print('Mantra generation started successfully');
        return true;
      } else {
        print('Failed to generate mantra: ${response.statusCode}');
        print('Response: ${response.body}');
        return false;
      }
    } catch (e) {
      print('Error generating mantra in voice: $e');
      // For now, return true for mock/development
      // In production, this should return false
      return true; // Mock success for development
    }
  }
}
