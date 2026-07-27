import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';

class ProfileService {
  // Get user profile data - uses AuthService to get profile from correct API
  static Future<Map<String, dynamic>?> getProfile() async {
    try {
      // Use AuthService to get profile (uses correct API config)
      final authService = AuthService();
      final token = authService.accessToken;

      if (token == null) {
        return null;
      }

      final profileData = await authService.getUserProfile();

      if (profileData != null) {
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
        final finalName = (fullName != null && fullName.isNotEmpty)
            ? fullName
            : (name ?? '');

        // Use gender if available, else default
        final gender = userData?['gender']?.toString().trim();
        final finalGender = (gender != null && gender.isNotEmpty)
            ? gender
            : 'Prefer not to say';

        // Use location if available, else default
        final location = userData?['location']?.toString().trim();
        final finalLocation = (location != null && location.isNotEmpty)
            ? location
            : 'Add Location';

        // Use mobile if available, else default
        final mobile = userData?['mobile']?.toString().trim();
        final phone = userData?['phone']?.toString().trim();
        final finalMobile = (mobile != null && mobile.isNotEmpty)
            ? mobile
            : ((phone != null && phone.isNotEmpty)
                  ? phone
                  : 'Add Phone Number');

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
        return {
          'fullName': currentUser.name,
          'email': currentUser.email,
          'location': '',
          'mobile': '',
          'gender': '',
          'photoUrl': currentUser.photoUrl,
        };
      }

      return null;
    } catch (e, stackTrace) {
      // Fallback: Try to get user from AuthService
      try {
        final authService = AuthService();
        final currentUser = authService.currentUser;
        if (currentUser != null) {
          return {
            'fullName': currentUser.name,
            'email': currentUser.email,
            'location': '',
            'mobile': '',
            'gender': '',
            'photoUrl': currentUser.photoUrl,
          };
        }
      } catch (e2) {}

      // Return null instead of mock data
      return null;
    }
  }

  /// GET `/auth/profile/list-recording-and-songs` — totals for profile stats row.
  static Future<({int totalRecordings, int totalInferredSongs})?>
  fetchRecordingAndSongTotals() async {
    try {
      final uri = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.listRecordingAndSongsEndpoint}',
      );
      final response = await AuthenticatedHttp.get(uri);
      if (response.statusCode != 200) {
        return null;
      }
      final decoded = json.decode(response.body) as Map<String, dynamic>;
      final Map<String, dynamic> root = decoded['data'] is Map<String, dynamic>
          ? decoded['data'] as Map<String, dynamic>
          : decoded;
      final tr = root['total_recordings'];
      final ts = root['total_inferred_songs'];
      final recordings = tr is int
          ? tr
          : int.tryParse(tr?.toString() ?? '') ?? 0;
      final songs = ts is int ? ts : int.tryParse(ts?.toString() ?? '') ?? 0;
      return (totalRecordings: recordings, totalInferredSongs: songs);
    } catch (e, st) {
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

      final response = await AuthenticatedHttp.sendMultipart((headers) async {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('${ApiConfig.baseUrl}${ApiConfig.profileEndpoint}/photo'),
        );
        request.headers.addAll(headers);
        request.files.add(
          await http.MultipartFile.fromPath('photo', imageFile.path),
        );
        return request;
      });
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = json.decode(responseBody);
        return data['photo_url'];
      } else {
        throw Exception('Failed to upload photo: ${response.statusCode}');
      }
    } catch (e) {
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
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
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

      final response = await AuthenticatedHttp.put(
        Uri.parse(url),
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      } else {
        throw Exception('Failed to update profile: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      return false;
    }
  }
}
