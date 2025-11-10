import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
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
    } catch (e) {
      debugPrint('Auth initialization error: $e');
      // Continue with empty state
    }
  }

  // Google Sign In
  Future<bool> signInWithGoogle() async {
    try {
      // For now, use mock authentication to prevent crashes
      // TODO: Implement real Google Sign-In when configuration is ready
      
      // Simulate a successful login
      await Future.delayed(const Duration(seconds: 1));
      
      _currentUser = User(
        id: 'google_user_123',
        name: 'Google User',
        email: 'user@gmail.com',
        photoUrl: null,
        provider: 'google',
      );

      // Mock backend call
      final success = await _sendTokenToBackend(
        'mock_google_access_token',
        'mock_google_id_token',
        'google',
      );

      if (success) {
        await _saveSession();
        // Small delay to ensure state is properly saved
        await Future.delayed(const Duration(milliseconds: 100));
        notifyListeners();
        return true;
      } else {
        _currentUser = null;
        return false;
      }
    } catch (e) {
      debugPrint('Google Sign In Error: $e');
      _currentUser = null;
      return false;
    }
  }

  // Facebook Sign In (placeholder - will be implemented when Facebook SDK is added)
  Future<bool> signInWithFacebook() async {
    try {
      // TODO: Implement Facebook Sign In
      // This is a placeholder for now
      await Future.delayed(const Duration(seconds: 1));
      
      _currentUser = User(
        id: 'facebook_user_123',
        name: 'Facebook User',
        email: 'user@facebook.com',
        photoUrl: null,
        provider: 'facebook',
      );

      // Mock backend call
      final success = await _sendTokenToBackend(
        'facebook_access_token',
        'facebook_id_token',
        'facebook',
      );

      if (success) {
        await _saveSession();
        notifyListeners();
        return true;
      } else {
        _currentUser = null;
        return false;
      }
    } catch (e) {
      debugPrint('Facebook Sign In Error: $e');
      _currentUser = null;
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
      // For now, simulate successful backend response without actual network call
      // TODO: Replace with real backend when ready
      
      await Future.delayed(const Duration(milliseconds: 500)); // Simulate network delay
      
      _accessToken = 'mock_access_token_${DateTime.now().millisecondsSinceEpoch}';
      _refreshToken = 'mock_refresh_token_${DateTime.now().millisecondsSinceEpoch}';
      _tokenExpiry = DateTime.now().add(const Duration(days: 30)); // 1 month expiry
      
      debugPrint('Mock backend authentication successful for $provider');
      return true;
    } catch (e) {
      debugPrint('Backend communication error: $e');
      return false;
    }
  }

  // Refresh token if needed
  Future<void> _refreshTokenIfNeeded() async {
    if (_refreshToken == null || _tokenExpiry == null) return;
    
    if (DateTime.now().isAfter(_tokenExpiry!.subtract(const Duration(minutes: 5)))) {
      try {
        // Mock token refresh - no actual network call
        await Future.delayed(const Duration(milliseconds: 200));
        
        _accessToken = 'mock_refreshed_access_token_${DateTime.now().millisecondsSinceEpoch}';
        _tokenExpiry = DateTime.now().add(const Duration(days: 30));
        await _saveSession();
        
        debugPrint('Mock token refresh successful');
      } catch (e) {
        debugPrint('Token refresh error: $e');
      }
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
      // Sign out from Google
      await _googleSignIn.signOut();
      
      // Clear local data
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      
      // Reset state
      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;
      
      notifyListeners();
    } catch (e) {
      debugPrint('Logout error: $e');
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
