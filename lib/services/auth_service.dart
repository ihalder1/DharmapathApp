import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../constants/api_config.dart';
import '../utils/device_info.dart';

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile', 'openid'],
    // Use the web client ID only when running on web; mobile platforms should
    // rely on their native client IDs from GoogleService-Info.plist /
    // google-services.json to avoid "WEB client type" errors.
    clientId: kIsWeb ? ApiConfig.googleClientId : null,
    // Always provide serverClientId (your Web client ID) so idTokens are issued
    // for backend verification on both Android and iOS.
    serverClientId: ApiConfig.googleClientId,
  );

  User? _currentUser;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;

  // Getters
  User? get currentUser => _currentUser;
  String? get accessToken => _accessToken;
  bool get isLoggedIn => _currentUser != null && _accessToken != null;

  // Initialize auth service
  Future<void> initialize() async {
    try {
      await _loadSession();
      await _refreshTokenIfNeeded();
      if (isLoggedIn && _currentUser != null && _currentUser!.id.isNotEmpty) {
        FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
      }
    } catch (e) {
      debugPrint('Auth initialization error: $e');
      // Continue with empty state
    }
  }

  // Google Sign In
  Future<bool> signInWithGoogle() async {
    try {
      debugPrint('Starting Google Sign-In...');
      
      // Sign out first to ensure a fresh sign-in
      await _googleSignIn.signOut();
      
      // Trigger the authentication flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      
      if (googleUser == null) {
        debugPrint('Google Sign-In cancelled by user');
        return false;
      }

      debugPrint('Google Sign-In successful: ${googleUser.email}');
      
      // Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      
      if (googleAuth.idToken == null) {
        debugPrint('Google ID token is null');
        return false;
      }

      // Log the ID token for backend debugging (user requested)
      debugPrint('=== GOOGLE ID TOKEN START ===');
      debugPrint(googleAuth.idToken);
      debugPrint('=== GOOGLE ID TOKEN END ===');
      
      debugPrint('Google ID token obtained, sending to backend...');
      
      // Send ID token to backend
      final success = await _sendTokenToBackend(
        googleAuth.accessToken ?? '',
        googleAuth.idToken!,
        'google',
      );

      if (success) {
        // Verify that access token was set by backend
        if (_accessToken == null || _accessToken!.isEmpty) {
          debugPrint('ERROR: Backend returned success but access token is null/empty');
          _currentUser = null;
          return false;
        }
        
        // Update user info from Google account (if not already set by backend)
        if (_currentUser == null) {
          _currentUser = User(
            id: googleUser.id,
            name: googleUser.displayName ?? '',
            email: googleUser.email,
            photoUrl: googleUser.photoUrl,
            provider: 'google',
          );
        }
        
        await _saveSession();
        
        // Verify final state before notifying
        final finalIsLoggedIn = _currentUser != null && _accessToken != null;
        debugPrint('Final auth state - User: ${_currentUser?.email}, Token: ${_accessToken != null ? "SET (${_accessToken!.length} chars)" : "NULL"}, isLoggedIn: $finalIsLoggedIn');
        
        FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
        notifyListeners();
        debugPrint('Google Sign-In completed successfully, notifying listeners');
        return true;
      } else {
        _currentUser = null;
        _accessToken = null;
        debugPrint('Backend authentication failed');
        return false;
      }
    } catch (e) {
      debugPrint('Google Sign In Error: $e');
      _currentUser = null;
      return false;
    }
  }

  // Facebook Sign In
  Future<bool> signInWithFacebook() async {
    try {
      debugPrint('Starting Facebook Sign-In...');

      final LoginResult result = await FacebookAuth.instance.login(
        permissions: ['email', 'public_profile'],
      );

      if (result.status == LoginStatus.success && result.accessToken != null) {
        final String? facebookAccessToken = result.accessToken!.tokenString;
        if (facebookAccessToken == null || facebookAccessToken.isEmpty) {
          debugPrint('Facebook access token is null or empty');
          return false;
        }

        debugPrint('Facebook Sign-In successful, got access token');
        debugPrint('=== FACEBOOK ACCESS TOKEN (full) ===');
        debugPrint(facebookAccessToken);
        debugPrint('=== END FACEBOOK ACCESS TOKEN ===');

        // Get user data from Graph API (fallback if backend does not return user)
        Map<String, dynamic>? userData;
        try {
          userData = await FacebookAuth.instance.getUserData(
            fields: 'name,email,picture.width(200)',
          );
        } catch (e) {
          debugPrint('Could not get Facebook user data: $e');
        }

        final String userId = userData != null
            ? (userData['id']?.toString() ?? 'facebook_${DateTime.now().millisecondsSinceEpoch}')
            : 'facebook_${DateTime.now().millisecondsSinceEpoch}';

        if (userData != null) {
          final String? name = userData['name'] as String?;
          final String? email = userData['email'] as String?;
          String? photoUrl;
          if (userData['picture'] != null &&
              userData['picture'] is Map &&
              (userData['picture'] as Map)['data'] != null) {
            final data = (userData['picture'] as Map)['data'] as Map?;
            photoUrl = data?['url'] as String?;
          }
          _currentUser = User(
            id: userId,
            name: name ?? 'Facebook User',
            email: email ?? '',
            photoUrl: photoUrl,
            provider: 'facebook',
          );
        } else {
          _currentUser = User(
            id: userId,
            name: 'Facebook User',
            email: '',
            photoUrl: null,
            provider: 'facebook',
          );
        }

        final success = await _sendFacebookTokenToBackend(facebookAccessToken);

        if (success) {
          if (_accessToken == null || _accessToken!.isEmpty) {
            debugPrint('ERROR: Backend returned success but access token is null/empty');
            _currentUser = null;
            return false;
          }
          await _saveSession();
          debugPrint('Facebook Sign-In completed successfully');
          FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
          notifyListeners();
          return true;
        } else {
          _currentUser = null;
          _accessToken = null;
          debugPrint('Backend Facebook authentication failed');
          return false;
        }
      } else if (result.status == LoginStatus.cancelled) {
        debugPrint('Facebook Sign-In cancelled by user');
        return false;
      } else {
        debugPrint('Facebook Sign-In failed: ${result.status}');
        return false;
      }
    } catch (e) {
      debugPrint('Facebook Sign In Error: $e');
      _currentUser = null;
      return false;
    }
  }

  /// Sends Facebook access token to backend /auth/facebook-signin as Bearer token.
  /// Backend returns JWT; we store it and follow the same flow as Google login.
  Future<bool> _sendFacebookTokenToBackend(String facebookAccessToken) async {
    try {
      final deviceInfo = await DeviceInfo.getDeviceInfoMap();
      final requestBody = json.encode({
        'deviceInfo': {
          'platform': deviceInfo['platform'],
          'deviceId': deviceInfo['deviceId'],
          'appVersion': deviceInfo['appVersion'],
        },
      });

      debugPrint('Sending Facebook access token to backend...');
      debugPrint('Device Info: $deviceInfo');

      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}${ApiConfig.facebookSignInEndpoint}'),
        headers: ApiConfig.getHeaders(accessToken: facebookAccessToken),
        body: requestBody,
      ).timeout(
        const Duration(seconds: 60),
      );

      debugPrint('Backend Facebook signin response status: ${response.statusCode}');
      debugPrint('Backend response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final Map<String, dynamic> responseData;
        try {
          final decoded = json.decode(response.body);
          responseData = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
        } catch (e) {
          debugPrint('Backend Facebook signin JSON parse error: $e');
          return false;
        }
        final tokens = responseData['tokens'];
        final Map<String, dynamic>? dataMap = responseData['data'] is Map ? responseData['data'] as Map<String, dynamic>? : null;
        if (tokens != null && tokens is Map) {
          _accessToken = tokens['accessToken'] ?? tokens['access_token'] ?? tokens['token'];
          _refreshToken = tokens['refreshToken'] ?? tokens['refresh_token'];
          if (tokens['expiresIn'] != null) {
            final expiresIn = tokens['expiresIn'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (tokens['expires_in'] != null) {
            final expiresIn = tokens['expires_in'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (tokens['expiry'] != null) {
            _tokenExpiry = DateTime.parse(tokens['expiry'].toString());
          } else {
            _tokenExpiry = DateTime.now().add(const Duration(days: 30));
          }
        } else if (dataMap != null) {
          _accessToken = dataMap['accessToken'] ?? dataMap['access_token'] ?? dataMap['token'];
          _refreshToken = dataMap['refreshToken'] ?? dataMap['refresh_token'];
          if (dataMap['expiresIn'] != null) {
            final expiresIn = dataMap['expiresIn'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (dataMap['expires_in'] != null) {
            final expiresIn = dataMap['expires_in'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else {
            _tokenExpiry = DateTime.now().add(const Duration(days: 30));
          }
        } else {
          _accessToken = responseData['accessToken'] ?? responseData['access_token'] ?? responseData['token'] ?? responseData['authToken'];
          _refreshToken = responseData['refreshToken'] ?? responseData['refresh_token'];
          if (responseData['expiresIn'] != null) {
            final expiresIn = responseData['expiresIn'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (responseData['expires_in'] != null) {
            final expiresIn = responseData['expires_in'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (responseData['expiry'] != null) {
            _tokenExpiry = DateTime.parse(responseData['expiry'].toString());
          } else {
            _tokenExpiry = DateTime.now().add(const Duration(days: 30));
          }
        }

        if (_accessToken == null || _accessToken!.isEmpty) {
          debugPrint('ERROR: Backend returned success but no access token in response. Keys: ${responseData.keys.toList()}');
          return false;
        }

        if (responseData['user'] != null) {
          final userData = responseData['user'];
          _currentUser = User(
            id: userData['userId']?.toString() ?? userData['user_id']?.toString() ?? userData['id']?.toString() ?? _currentUser?.id ?? '',
            name: userData['name']?.toString() ?? _currentUser?.name ?? '',
            email: userData['email']?.toString() ?? _currentUser?.email ?? '',
            photoUrl: userData['photoUrl']?.toString() ?? userData['photo_url']?.toString() ?? _currentUser?.photoUrl,
            provider: 'facebook',
          );
        }

        debugPrint('Backend Facebook authentication successful');
        return true;
      } else {
        debugPrint('Backend Facebook signin failed: ${response.statusCode}');
        debugPrint('Response: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Backend Facebook communication error: $e');
      return false;
    }
  }

  // Apple Sign In (placeholder - will be implemented when Apple SDK is added)
  Future<bool> signInWithApple() async {
    try {
      // TODO: Implement Apple Sign In
      // This is a placeholder for now
      await Future.delayed(const Duration(seconds: 1));
      
      _currentUser = User(
        id: 'apple_user_123',
        name: 'Apple User',
        email: 'user@apple.com',
        photoUrl: null,
        provider: 'apple',
      );

      // Mock backend call
      final success = await _sendTokenToBackend(
        'apple_access_token',
        'apple_identity_token',
        'apple',
      );

      if (success) {
        await _saveSession();
        if (_currentUser != null && _currentUser!.id.isNotEmpty) {
          FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
        }
        notifyListeners();
        return true;
      } else {
        _currentUser = null;
        return false;
      }
    } catch (e) {
      debugPrint('Apple Sign In Error: $e');
      _currentUser = null;
      return false;
    }
  }

  // Send token to backend
  Future<bool> _sendTokenToBackend(String accessToken, String idToken, String provider) async {
    try {
      // Get device info
      final deviceInfo = await DeviceInfo.getDeviceInfoMap();
      
      // Prepare request body
      final requestBody = json.encode({
        'deviceInfo': {
          'platform': deviceInfo['platform'],
          'deviceId': deviceInfo['deviceId'],
          'appVersion': deviceInfo['appVersion'],
        },
      });

      debugPrint('Sending Google ID token to backend...');
      debugPrint('Device Info: $deviceInfo');
      
      // Make API call to backend
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}${ApiConfig.googleSignInEndpoint}'),
        headers: ApiConfig.getHeaders(accessToken: idToken),
        body: requestBody,
      ).timeout(
        const Duration(seconds: 30),
      );

      debugPrint('Backend response status: ${response.statusCode}');
      debugPrint('Backend response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);
        
        debugPrint('Backend response data keys: ${responseData.keys.toList()}');
        
        // Extract tokens from response
        // Backend returns tokens nested in a "tokens" object
        final tokens = responseData['tokens'];
        if (tokens != null && tokens is Map) {
          _accessToken = tokens['accessToken'] ?? tokens['access_token'] ?? tokens['token'];
          _refreshToken = tokens['refreshToken'] ?? tokens['refresh_token'];
          
          // Extract token expiry from tokens object
          if (tokens['expiresIn'] != null) {
            final expiresIn = tokens['expiresIn'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (tokens['expires_in'] != null) {
            final expiresIn = tokens['expires_in'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (tokens['expiry'] != null) {
            _tokenExpiry = DateTime.parse(tokens['expiry']);
          } else {
            // Default to 30 days if not specified
            _tokenExpiry = DateTime.now().add(const Duration(days: 30));
          }
        } else {
          // Fallback: try root level (for backward compatibility)
          _accessToken = responseData['accessToken'] ?? responseData['access_token'] ?? responseData['token'] ?? responseData['authToken'];
          _refreshToken = responseData['refreshToken'] ?? responseData['refresh_token'];
          
          // Extract token expiry (adjust based on your API response)
          if (responseData['expiresIn'] != null) {
            final expiresIn = responseData['expiresIn'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (responseData['expires_in'] != null) {
            final expiresIn = responseData['expires_in'] as int;
            _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
          } else if (responseData['expiry'] != null) {
            _tokenExpiry = DateTime.parse(responseData['expiry']);
          } else {
            // Default to 30 days if not specified
            _tokenExpiry = DateTime.now().add(const Duration(days: 30));
          }
        }
        
        // CRITICAL: Verify that access token was actually set
        if (_accessToken == null || _accessToken!.isEmpty) {
          debugPrint('ERROR: Backend returned success but no access token found in response');
          debugPrint('Response data: $responseData');
          debugPrint('Tokens object: $tokens');
          return false;
        }
        
        debugPrint('Access token extracted successfully (length: ${_accessToken!.length})');
        
        // Update user info if provided in response
        if (responseData['user'] != null) {
          final userData = responseData['user'];
          _currentUser = User(
            id: userData['userId'] ?? userData['user_id'] ?? userData['id'] ?? _currentUser?.id ?? '',
            name: userData['name'] ?? _currentUser?.name ?? '',
            email: userData['email'] ?? _currentUser?.email ?? '',
            photoUrl: userData['photoUrl'] ?? userData['photo_url'] ?? _currentUser?.photoUrl,
            provider: provider,
          );
        }
        
        debugPrint('Backend authentication successful');
        debugPrint('isLoggedIn will be: ${_currentUser != null && _accessToken != null}');
        return true;
      } else {
        debugPrint('Backend authentication failed: ${response.statusCode}');
        debugPrint('Response: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Backend communication error: $e');
      return false;
    }
  }

  bool _statusUnauthorized(int code) => code == 401 || code == 403;

  /// Exchange [refresh_token] for a new access token (same path as `/auth/refresh`).
  /// Returns false if refresh token is missing or server rejects — caller may [logout].
  Future<bool> refreshAccessToken() async {
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      debugPrint('refreshAccessToken: no refresh token stored');
      return false;
    }

    final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.refreshTokenEndpoint}');
    final headers = ApiConfig.getHeaders();

    Future<http.Response> postBody(String jsonBody) =>
        http.post(url, headers: headers, body: jsonBody).timeout(const Duration(seconds: 30));

    try {
      http.Response response =
          await postBody(json.encode({'refresh_token': _refreshToken}));
      if (!(response.statusCode == 200 || response.statusCode == 201)) {
        response =
            await postBody(json.encode({'refreshToken': _refreshToken}));
      }

      if (!(response.statusCode == 200 || response.statusCode == 201)) {
        debugPrint(
          'refreshAccessToken failed: ${response.statusCode} ${response.body}',
        );
        return false;
      }

      final decoded = json.decode(response.body);
      Map<String, dynamic> root =
          decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      Map<String, dynamic> payload = root;
      if (root['data'] is Map<String, dynamic>) {
        payload = Map<String, dynamic>.from(root['data'] as Map);
      }

      final newAccess = payload['access_token'] ??
          payload['accessToken'] ??
          root['access_token'] ??
          root['accessToken'];
      final newRefresh = payload['refresh_token'] ??
          payload['refreshToken'] ??
          root['refresh_token'] ??
          root['refreshToken'];

      if (newAccess == null || newAccess.toString().isEmpty) {
        debugPrint('refreshAccessToken: response had no access token');
        return false;
      }

      _accessToken = newAccess.toString();
      if (newRefresh != null && newRefresh.toString().isNotEmpty) {
        _refreshToken = newRefresh.toString();
      }

      final expRaw =
          payload['expires_in'] ?? payload['expiresIn'] ?? root['expires_in'];
      if (expRaw != null) {
        final sec = expRaw is int
            ? expRaw
            : int.tryParse(expRaw.toString()) ?? 3600;
        _tokenExpiry = DateTime.now().add(Duration(seconds: sec));
      } else {
        _tokenExpiry = DateTime.now().add(const Duration(days: 30));
      }

      await _saveSession();
      notifyListeners();
      debugPrint('refreshAccessToken: success');
      return true;
    } catch (e, st) {
      debugPrint('refreshAccessToken error: $e\n$st');
      return false;
    }
  }

  Future<void> _refreshTokenIfNeeded() async {
    if (_refreshToken == null || _tokenExpiry == null) return;

    if (DateTime.now().isAfter(_tokenExpiry!.subtract(const Duration(minutes: 5)))) {
      final ok = await refreshAccessToken();
      if (!ok) {
        await logout();
      }
    }
  }

  Future<http.Response> _authorizedMainGet(
    Uri url, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    var headers = ApiConfig.getHeaders(accessToken: _accessToken);
    var resp = await http.get(url, headers: headers).timeout(timeout);
    if (!_statusUnauthorized(resp.statusCode)) return resp;

    final ok = await refreshAccessToken();
    if (!ok) {
      await logout();
      return resp;
    }

    headers = ApiConfig.getHeaders(accessToken: _accessToken);
    return http.get(url, headers: headers).timeout(timeout);
  }
  
  // Get user profile from backend
  Future<Map<String, dynamic>?> getUserProfile() async {
    if (_accessToken == null) {
      print('❌ ERROR: No access token available for profile request');
      debugPrint('No access token available for profile request');
      return null;
    }
    
    try {
      print('═══════════════════════════════════════════════════════════');
      print('📥 GET USER PROFILE API CALL START');
      print('═══════════════════════════════════════════════════════════');
      
      final url = '${ApiConfig.baseUrl}${ApiConfig.profileEndpoint}';
      final headers = ApiConfig.getHeaders(accessToken: _accessToken);
      
      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   FULL TOKEN: $_accessToken');
      
      debugPrint('Fetching user profile...');

      final response = await _authorizedMainGet(Uri.parse(url));

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        print('✅ GET USER PROFILE SUCCESS');
        print('   Data: ${json.encode(responseData)}');
        print('═══════════════════════════════════════════════════════════');
        debugPrint('Profile fetched successfully');
        return responseData;
      } else {
        print('❌ GET USER PROFILE FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        debugPrint('Failed to fetch profile: ${response.statusCode}');
        return null;
      }
    } catch (e, stackTrace) {
      print('❌ GET USER PROFILE ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('Error fetching profile: $e');
      return null;
    }
  }

  // Save session to local storage
  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', _currentUser?.id ?? '');
    await prefs.setString('user_name', _currentUser?.name ?? '');
    await prefs.setString('user_email', _currentUser?.email ?? '');
    await prefs.setString('user_photo_url', _currentUser?.photoUrl ?? '');
    await prefs.setString('user_provider', _currentUser?.provider ?? '');
    await prefs.setString('access_token', _accessToken ?? '');
    // Also save as 'auth_token' for compatibility with other services
    await prefs.setString('auth_token', _accessToken ?? '');
    await prefs.setString('refresh_token', _refreshToken ?? '');
    await prefs.setString('token_expiry', _tokenExpiry?.toIso8601String() ?? '');
  }

  // Load session from local storage
  Future<void> _loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final userId = prefs.getString('user_id');
      if (userId != null && userId.isNotEmpty) {
        _currentUser = User(
          id: userId,
          name: prefs.getString('user_name') ?? '',
          email: prefs.getString('user_email') ?? '',
          photoUrl: prefs.getString('user_photo_url'),
          provider: prefs.getString('user_provider') ?? '',
        );
        
        _accessToken = prefs.getString('access_token');
        _refreshToken = prefs.getString('refresh_token');
        
        final expiryString = prefs.getString('token_expiry');
        if (expiryString != null && expiryString.isNotEmpty) {
          _tokenExpiry = DateTime.parse(expiryString);
        }
      }
    } catch (e) {
      debugPrint('Load session error: $e');
      // Continue with empty state
    }
  }

  // Logout
  Future<void> logout() async {
    try {
      // Call backend logout endpoint if we have an access token
      if (_accessToken != null) {
        try {
          await http.post(
            Uri.parse('${ApiConfig.baseUrl}${ApiConfig.logoutEndpoint}'),
            headers: ApiConfig.getHeaders(accessToken: _accessToken),
            body: json.encode({'test': 'data'}),
          ).timeout(
            const Duration(seconds: 10),
          );
          debugPrint('Backend logout successful');
        } catch (e) {
          debugPrint('Backend logout error (continuing with local logout): $e');
        }
      }
      
      // Sign out from Google
      await _googleSignIn.signOut();
      
      // Save cart before clearing SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final cartItems = prefs.getStringList('cart_items') ?? [];
      
      // Clear local data (but preserve cart)
      await prefs.clear();
      
      // Restore cart after clearing
      if (cartItems.isNotEmpty) {
        await prefs.setStringList('cart_items', cartItems);
        debugPrint('Cart preserved after logout: ${cartItems.length} items');
      }
      
      // Reset state
      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;
      
      notifyListeners();
      debugPrint('Logout completed');
    } catch (e) {
      debugPrint('Logout error: $e');
      // Even if logout fails, clear local state (but preserve cart)
      final prefs = await SharedPreferences.getInstance();
      final cartItems = prefs.getStringList('cart_items') ?? [];
      await prefs.clear();
      
      // Restore cart after clearing
      if (cartItems.isNotEmpty) {
        await prefs.setStringList('cart_items', cartItems);
        debugPrint('Cart preserved after logout error: ${cartItems.length} items');
      }
      
      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;
      notifyListeners();
    }
  }

  // Clear all session data (for testing)
  Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      
      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;
      
      notifyListeners();
    } catch (e) {
      debugPrint('Clear session error: $e');
    }
  }
}

// User model
class User {
  final String id;
  final String name;
  final String email;
  final String? photoUrl;
  final String provider;

  User({
    required this.id,
    required this.name,
    required this.email,
    this.photoUrl,
    required this.provider,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      photoUrl: json['photo_url'],
      provider: json['provider'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'photo_url': photoUrl,
      'provider': provider,
    };
  }
}
