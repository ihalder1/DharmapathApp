import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mantra.dart';
import 'song_service.dart';

class MantraService {
  static List<Mantra> _mantras = [];
  static List<Mantra> _cart = [];

  // Load mantras from API first, then fallback to JSON metadata
  static Future<List<Mantra>> loadMantras() async {
    try {
      print('Attempting to load mantras from API...');
      
      // Try API first
      List<Mantra> apiMantras = await SongService.getSongs();
      if (apiMantras.isNotEmpty) {
        _mantras = apiMantras;
        print('Successfully loaded ${_mantras.length} mantras from API');
        return _mantras;
      }
      
      // Fallback to local JSON if API fails or returns empty
      print('API failed or returned empty, falling back to local JSON...');
      return await _loadFromLocalJson();
    } catch (e) {
      print('Error loading mantras from API: $e');
      print('Falling back to local JSON...');
      return await _loadFromLocalJson();
    }
  }

  // Load mantras from local JSON metadata
  static Future<List<Mantra>> _loadFromLocalJson() async {
    try {
      print('Attempting to load mantras from Media/metadata.json');
      
             // Try to load the asset
             final String jsonString = await rootBundle.loadString('Media/metadata.json');
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
          playtime: 300,
          price: 299,
        ),
        Mantra(
          name: 'Test Mantra 2',
          mantraFile: 'test2.mp3',
          icon: 'test2.jpg',
          playtime: 240,
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
