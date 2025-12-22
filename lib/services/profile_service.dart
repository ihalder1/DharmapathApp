import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/api_config.dart';
import 'auth_service.dart';

class ProfileService {
  // Get user profile data - uses AuthService to get profile from correct API
  static Future<Map<String, dynamic>?> getProfile() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('📥 GET PROFILE API CALL START');
      print('═══════════════════════════════════════════════════════════');
      
      // Use AuthService to get profile (uses correct API config)
      final authService = AuthService();
      final token = authService.accessToken;
      
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        print('═══════════════════════════════════════════════════════════');
        return null;
      }
      
      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: ${ApiConfig.baseUrl}${ApiConfig.profileEndpoint}');
      print('   FULL TOKEN: $token');
      
      final profileData = await authService.getUserProfile();
      
      if (profileData != null) {
        print('📥 RESPONSE RECEIVED:');
        print('   Data: ${json.encode(profileData)}');
        print('✅ GET PROFILE SUCCESS');
        print('═══════════════════════════════════════════════════════════');
        debugPrint('ProfileService: Got profile from API');
        
        // Handle nested data structure: response.data.data or response.data
        Map<String, dynamic>? userData;
        if (profileData['data'] != null && profileData['data'] is Map) {
          userData = profileData['data'] as Map<String, dynamic>;
        } else {
          userData = profileData;
        }
        
        // Use fullName if available, else use name
        final fullName = userData?['fullName']?.toString().trim();
        final name = userData?['name']?.toString().trim();
        final finalName = (fullName != null && fullName.isNotEmpty) ? fullName : (name ?? '');
        
        // Use gender if available, else default
        final gender = userData?['gender']?.toString().trim();
        final finalGender = (gender != null && gender.isNotEmpty) ? gender : 'Prefer not to say';
        
        // Use location if available, else default
        final location = userData?['location']?.toString().trim();
        final finalLocation = (location != null && location.isNotEmpty) ? location : 'Add Location';
        
        // Use mobile if available, else default
        final mobile = userData?['mobile']?.toString().trim();
        final phone = userData?['phone']?.toString().trim();
        final finalMobile = (mobile != null && mobile.isNotEmpty) ? mobile : ((phone != null && phone.isNotEmpty) ? phone : 'Add Phone Number');
        
        return {
          'fullName': finalName,
          'email': userData?['email']?.toString().trim() ?? '',
          'location': finalLocation,
          'mobile': finalMobile,
          'gender': finalGender,
          'photoUrl': userData?['photoUrl'] ?? userData?['photo_url'],
        };
      }
      
      // Fallback: Use AuthService current user data
      final currentUser = authService.currentUser;
      if (currentUser != null) {
        print('⚠️  GET PROFILE: Using fallback - current user from AuthService');
        print('═══════════════════════════════════════════════════════════');
        debugPrint('ProfileService: Using current user from AuthService');
        return {
          'fullName': currentUser.name,
          'email': currentUser.email,
          'location': '',
          'mobile': '',
          'gender': '',
          'photoUrl': currentUser.photoUrl,
        };
      }
      
      print('❌ GET PROFILE: No profile data available');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('ProfileService: No profile data available');
      return null;
    } catch (e, stackTrace) {
      print('❌ GET PROFILE ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('Error getting profile: $e');
      
      // Fallback: Try to get user from AuthService
      try {
        final authService = AuthService();
        final currentUser = authService.currentUser;
        if (currentUser != null) {
          print('⚠️  GET PROFILE: Using fallback - current user from AuthService (error recovery)');
          print('═══════════════════════════════════════════════════════════');
          debugPrint('ProfileService: Fallback to current user');
          return {
            'fullName': currentUser.name,
            'email': currentUser.email,
            'location': '',
            'mobile': '',
            'gender': '',
            'photoUrl': currentUser.photoUrl,
          };
        }
      } catch (e2) {
        print('❌ GET PROFILE: Error getting user from AuthService: $e2');
        debugPrint('Error getting user from AuthService: $e2');
      }
      
      // Return null instead of mock data
      return null;
    }
  }

  // Upload profile photo
  static Future<String?> uploadProfilePhoto(File imageFile) async {
    try {
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        throw Exception('No authentication token found');
      }

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}${ApiConfig.profileEndpoint}/photo'),
      );

      final headers = ApiConfig.getHeaders(accessToken: token);
      request.headers.addAll(headers);
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
      print('═══════════════════════════════════════════════════════════');
      print('🔄 PROFILE UPDATE API CALL START');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        debugPrint('ProfileService.updateProfile: No authentication token found');
        throw Exception('No authentication token found');
      }

      final url = '${ApiConfig.baseUrl}${ApiConfig.profileEndpoint}';
      final headers = ApiConfig.getHeaders(accessToken: token);
      final requestBody = {
        'fullName': fullName,
        'location': location,
        'mobile': mobile,
        'gender': gender,
      };

      print('📤 REQUEST DETAILS:');
      print('   Method: PUT');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   Body: ${json.encode(requestBody)}');
      print('   FULL TOKEN: $token');

      debugPrint('ProfileService.updateProfile: Calling PUT $url');
      debugPrint('ProfileService.updateProfile: Data - name: $fullName, location: $location, phone: $mobile, gender: $gender');

      final response = await http.put(
        Uri.parse(url),
        headers: headers,
        body: json.encode(requestBody),
      ).timeout(
        const Duration(seconds: 30),
      );

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');
      
      debugPrint('ProfileService.updateProfile: Response status: ${response.statusCode}');
      debugPrint('ProfileService.updateProfile: Response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        print('✅ PROFILE UPDATE SUCCESS');
        print('═══════════════════════════════════════════════════════════');
        debugPrint('ProfileService.updateProfile: Success');
        return true;
      } else {
        print('❌ PROFILE UPDATE FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        debugPrint('ProfileService.updateProfile: Failed with status ${response.statusCode}');
        throw Exception('Failed to update profile: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('❌ PROFILE UPDATE ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('ProfileService.updateProfile: Error - $e');
      return false;
    }
  }
}
