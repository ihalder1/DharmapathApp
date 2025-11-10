import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/mantra.dart';

class SongService {
  static const String _baseUrl = 'https://mock-api.colab-app.com/api';
  
  // Mock API for song selection - replace with actual backend URL
  static Future<List<Mantra>> getSongs() async {
    try {
      print('Fetching songs from API...');
      
      // In a real scenario, you would make an HTTP request here
      // For now, returning mock data with new format
      await Future.delayed(const Duration(seconds: 1)); // Simulate network delay

      // Mock API response with new format (including name and icon for frontend)
      final List<Map<String, dynamic>> mockApiResponse = [
        {
          "song_id": "M-DURGA-001.mp3",
          "name": "Maa Durga Mantra",
          "icon": "M-DURGA-001.jpg",
          "runtime": 300,
          "price": 299,
          "bought": "Y"
        },
        {
          "song_id": "M-GANESH-001.mp3",
          "name": "Ganesh Mantra",
          "icon": "M-GANESH-001.jpg",
          "runtime": 240,
          "price": 249,
          "bought": "N"
        },
        {
          "song_id": "M-MAHAKALI-001.mp3",
          "name": "Maa MahaKali Mantra",
          "icon": "M-MAHAKALI-001.jpg",
          "runtime": 180,
          "price": 199,
          "bought": "N"
        },
        {
          "song_id": "M-RAM-001.mp3",
          "name": "Shri Rama Mantra",
          "icon": "M-RAM-001.jpg",
          "runtime": 220,
          "price": 219,
          "bought": "N"
        },
        {
          "song_id": "M-SARASWATI-001.mp3",
          "name": "Maa Saraswati Mantra",
          "icon": "M-SARASWATI-001.jpg",
          "runtime": 280,
          "price": 279,
          "bought": "N"
        },
        {
          "song_id": "M-SHANI-001.mp3",
          "name": "Shani Dev Mantra",
          "icon": "M-SHANI-001.jpg",
          "runtime": 350,
          "price": 349,
          "bought": "N"
        },
        {
          "song_id": "M-SURYA-001.mp3",
          "name": "Surya Dev Mantra",
          "icon": "M-SURYA-001.jpg",
          "runtime": 260,
          "price": 259,
          "bought": "N"
        },
      ];

      List<Mantra> mantras = mockApiResponse.map((song) => Mantra.fromApiJson(song)).toList();
      print('Successfully loaded ${mantras.length} songs from API');
      return mantras;
    } catch (e) {
      print('Error fetching songs from API: $e');
      // Fallback to local JSON if API fails
      return await _loadFromLocalJson();
    }
  }
  
  // Fallback method to load from local JSON
  static Future<List<Mantra>> _loadFromLocalJson() async {
    try {
      print('Loading songs from local JSON as fallback...');
      // This will be handled by MantraService.loadMantras()
      return [];
    } catch (e) {
      print('Error loading from local JSON: $e');
      return [];
    }
  }
}
