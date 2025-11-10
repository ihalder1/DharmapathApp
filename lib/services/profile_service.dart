import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ProfileService {
  static const String baseUrl = 'https://api.dharmapath.com'; // Replace with actual backend URL
  
  // Get auth token from SharedPreferences
  static Future<String?> _getAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  // Get user profile data
  static Future<Map<String, dynamic>?> getProfile() async {
    try {
      final token = await _getAuthToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http.get(
        Uri.parse('$baseUrl/api/profile'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'fullName': data['name'] ?? 'John Doe',
          'email': data['email'] ?? 'john.doe@example.com',
          'location': data['location'] ?? 'New Delhi, India',
          'mobile': data['phone'] ?? '+91 9876543210',
          'gender': data['gender'] ?? 'Male',
          'photoUrl': data['photo_url'],
        };
      } else {
        throw Exception('Failed to load profile: ${response.statusCode}');
      }
    } catch (e) {
      print('Error getting profile: $e');
      // Return mock data for now
      return {
        'fullName': 'John Doe',
        'email': 'john.doe@example.com',
        'location': 'New Delhi, India',
        'mobile': '+91 9876543210',
        'gender': 'Male',
        'photoUrl': null,
      };
    }
  }

  // Upload profile photo
  static Future<String?> uploadProfilePhoto(File imageFile) async {
    try {
      final token = await _getAuthToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/profile/photo'),
      );

      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(
        await http.MultipartFile.fromPath(
          'photo',
          imageFile.path,
        ),
      );

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = json.decode(responseBody);
        return data['photo_url'];
      } else {
        throw Exception('Failed to upload photo: ${response.statusCode}');
      }
    } catch (e) {
      print('Error uploading photo: $e');
      return null;
    }
  }

  // Update profile information
  static Future<bool> updateProfile({
    required String fullName,
    required String location,
    required String mobile,
    required String gender,
  }) async {
    try {
      final token = await _getAuthToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http.put(
        Uri.parse('$baseUrl/api/profile'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'name': fullName,
          'location': location,
          'phone': mobile,
          'gender': gender,
        }),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        throw Exception('Failed to update profile: ${response.statusCode}');
      }
    } catch (e) {
      print('Error updating profile: $e');
      return false;
    }
  }
}
