import 'dart:convert';
import 'package:flutter/services.dart';
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

  // Check if mantra is in cart
  static bool isInCart(Mantra mantra) {
    return _cart.any((item) => item.name == mantra.name);
  }
}
