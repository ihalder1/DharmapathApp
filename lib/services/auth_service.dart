import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'notification_service.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../constants/api_config.dart';
import '../utils/device_info.dart';
import 'secure_session_storage.dart';

/// Decodes the JWT access token payload (middle segment). Does not verify the signature.
Map<String, dynamic>? decodeJwtPayload(String jwt) {
  try {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    var payload = parts[1];
    final pad = payload.length % 4;
    if (pad > 0) payload += '=' * (4 - pad);
    payload = payload.replaceAll('-', '+').replaceAll('_', '/');
    final decoded = json.decode(utf8.decode(base64.decode(payload)));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  } catch (_) {
    return null;
  }
}

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal() : _secureSessionStorage = SecureSessionStorage();

  @visibleForTesting
  AuthService.forTesting(SecureSessionStorage secureSessionStorage)
    : _secureSessionStorage = secureSessionStorage;

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
  final SecureSessionStorage _secureSessionStorage;
  Future<bool>? _refreshInFlight;
  bool _lastRefreshWasAuthRejection = false;

  static const Duration _accessRefreshLeeway = Duration(minutes: 2);

  // Getters
  User? get currentUser => _currentUser;
  String? get accessToken => _accessToken;
  bool get isLoggedIn => _currentUser != null && _accessToken != null;

  @visibleForTesting
  Future<void> restoreSessionForTesting() => _loadSession();

  @visibleForTesting
  Future<void> persistSessionForTesting({
    required User user,
    required String accessToken,
    String? refreshToken,
    DateTime? expiry,
  }) async {
    _currentUser = user;
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _tokenExpiry = expiry;
    await _saveSession();
  }

  /// True when `/auth/refresh` returned 401/403 — safe to clear session.
  bool get shouldLogoutAfterRefreshFailure => _lastRefreshWasAuthRejection;

  // Initialize auth service
  Future<void> initialize() async {
    try {
      await _loadSession();
      await _refreshTokenIfNeeded();
      if (isLoggedIn && _currentUser != null && _currentUser!.id.isNotEmpty) {
        FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
      }
    } catch (e) {
      // Continue with empty state
    }
  }

  // Google Sign In
  Future<bool> signInWithGoogle() async {
    // TEMPORARY GOOGLE AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
    final configuredClientId = kIsWeb ? ApiConfig.googleClientId : null;
    final configuredServerClientId = ApiConfig.googleClientId;
    debugPrint(
      '[GOOGLE_AUTH_DEBUG] Sign-in started; platform='
      '${kIsWeb ? 'web' : defaultTargetPlatform.name}; '
      'clientId=${_clientIdDiagnostic(configuredClientId)}; '
      'serverClientId=${_clientIdDiagnostic(configuredServerClientId)}',
    );
    try {
      // Sign out first to ensure a fresh sign-in
      await _googleSignIn.signOut();

      // Trigger the authentication flow
      debugPrint('[GOOGLE_AUTH_DEBUG] Opening native Google account chooser');
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      debugPrint(
        '[GOOGLE_AUTH_DEBUG] Google account object returned='
        '${googleUser != null}',
      );

      if (googleUser == null) {
        debugPrint('[GOOGLE_AUTH_DEBUG] User cancelled Google Sign-In');
        return false;
      }

      // Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      debugPrint(
        '[GOOGLE_AUTH_DEBUG] Google authentication received; '
        'idTokenPresent=${googleAuth.idToken != null}; '
        'idTokenLength=${googleAuth.idToken?.length ?? 0}; '
        'accessTokenPresent=${googleAuth.accessToken != null}; '
        'accessTokenLength=${googleAuth.accessToken?.length ?? 0}',
      );

      if (googleAuth.idToken == null) {
        debugPrint(
          '[GOOGLE_AUTH_DEBUG] Cannot call backend: idToken is absent',
        );
        return false;
      }

      // Send ID token to backend
      final success = await _sendTokenToBackend(
        googleAuth.accessToken ?? '',
        googleAuth.idToken!,
        'google',
      );

      if (success) {
        // Verify that access token was set by backend
        if (_accessToken == null || _accessToken!.isEmpty) {
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

        try {
          await _saveSession();
          debugPrint(
            '[GOOGLE_AUTH_DEBUG] Application token storage succeeded=true',
          );
        } catch (_) {
          debugPrint(
            '[GOOGLE_AUTH_DEBUG] Application token storage succeeded=false',
          );
          rethrow;
        }

        // Verify final state before notifying
        final finalIsLoggedIn = _currentUser != null && _accessToken != null;

        FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
        notifyListeners();
        return true;
      } else {
        _currentUser = null;
        _accessToken = null;
        return false;
      }
    } catch (error, stackTrace) {
      if (error is PlatformException &&
          const {
            'canceled',
            'cancelled',
            'sign_in_canceled',
            'sign_in_cancelled',
          }.contains(error.code.toLowerCase())) {
        debugPrint('[GOOGLE_AUTH_DEBUG] User cancelled Google Sign-In');
        _currentUser = null;
        return false;
      }
      debugPrint(
        '[GOOGLE_AUTH_DEBUG] Google Sign-In exception; '
        'type=${error.runtimeType}; '
        'message=${_sanitizeDiagnosticMessage(error.toString())}',
      );
      if (error is PlatformException) {
        debugPrint(
          '[GOOGLE_AUTH_DEBUG] PlatformException; code=${error.code}; '
          'message=${_sanitizeDiagnosticMessage(error.message)}',
        );
      }
      debugPrint('[GOOGLE_AUTH_DEBUG] Stack trace:\n$stackTrace');
      _currentUser = null;
      return false;
    }
  }

  // TEMPORARY GOOGLE AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
  String _clientIdDiagnostic(String? clientId) {
    if (clientId == null) return 'null';
    final suffix = clientId.length <= 8
        ? clientId
        : clientId.substring(clientId.length - 8);
    return 'configured(last8=$suffix)';
  }

  // TEMPORARY GOOGLE AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
  String _sanitizeDiagnosticMessage(Object? message) {
    if (message == null) return 'null';
    var sanitized = message.toString();
    sanitized = sanitized.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(
        r'(access[_-]?token|refresh[_-]?token|token|authorization|cookie|secret)\s*[:=]\s*[^\s,;}]+',
        caseSensitive: false,
      ),
      '[REDACTED_SENSITIVE_FIELD]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      '[REDACTED_TOKEN]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\b[A-Za-z0-9_+\-/=]{40,}\b'),
      '[REDACTED_LONG_VALUE]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\b[^\s@]+@[^\s@]+\.[^\s@]+\b'),
      '[REDACTED_EMAIL]',
    );
    return sanitized.length <= 500
        ? sanitized
        : '${sanitized.substring(0, 500)}...[TRUNCATED]';
  }

  // TEMPORARY GOOGLE AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
  Map<String, dynamic> _sanitizedGoogleAuthResponse(String responseBody) {
    try {
      final decoded = json.decode(responseBody);
      if (decoded is! Map) {
        return {'error': true, 'errorCode': 'non_object_response'};
      }
      final body = Map<String, dynamic>.from(decoded);
      final nestedError = body['error'];
      final errorMap = nestedError is Map
          ? Map<String, dynamic>.from(nestedError)
          : const <String, dynamic>{};
      final rawErrorMessage =
          body['errorMessage'] ?? body['message'] ?? errorMap['message'];
      final rawErrorCode =
          body['errorCode'] ?? body['code'] ?? errorMap['code'];
      return {
        'success': body['success'],
        'error': nestedError is bool ? nestedError : body['error'] != null,
        'errorCode': rawErrorCode == null
            ? null
            : _sanitizeDiagnosticMessage(rawErrorCode),
        'errorMessage': rawErrorMessage == null
            ? null
            : _sanitizeDiagnosticMessage(rawErrorMessage),
      }..removeWhere((_, value) => value == null);
    } catch (_) {
      return {'error': true, 'errorCode': 'unparseable_response'};
    }
  }

  // Facebook Sign In
  Future<bool> signInWithFacebook() async {
    // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
    const configuredAppId = ApiConfig.facebookAppId;
    final appIdSuffix = configuredAppId.length <= 6
        ? configuredAppId
        : configuredAppId.substring(configuredAppId.length - 6);
    final clientTokenConfigured =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    debugPrint(
      '[FACEBOOK_AUTH_DEBUG] Sign-in started; '
      'platform=${kIsWeb ? 'web' : defaultTargetPlatform.name}; '
      'appIdConfigured=${configuredAppId.isNotEmpty}; '
      'appIdLast6=$appIdSuffix; '
      'clientTokenConfigured=$clientTokenConfigured',
    );
    try {
      const requestedPermissions = ['email', 'public_profile'];
      // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint(
        '[FACEBOOK_AUTH_DEBUG] Opening native/web Facebook login flow; '
        'requestedPermissions=$requestedPermissions',
      );
      final LoginResult result = await FacebookAuth.instance.login(
        permissions: requestedPermissions,
      );

      // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint(
        '[FACEBOOK_AUTH_DEBUG] Facebook login result; '
        'status=${result.status.name}; '
        'accessTokenPresent=${result.accessToken != null}; '
        'accessTokenLength=${result.accessToken?.tokenString.length ?? 0}; '
        'message=${_sanitizeDiagnosticMessage(result.message)}; '
        'errorCodeUnavailable=true',
      );
      switch (result.status) {
        case LoginStatus.success:
          debugPrint('[FACEBOOK_AUTH_DEBUG] Login status branch=success');
          break;
        case LoginStatus.cancelled:
          debugPrint('[FACEBOOK_AUTH_DEBUG] Login status branch=cancelled');
          break;
        case LoginStatus.failed:
          debugPrint('[FACEBOOK_AUTH_DEBUG] Login status branch=failed');
          break;
        case LoginStatus.operationInProgress:
          debugPrint(
            '[FACEBOOK_AUTH_DEBUG] Login status branch=operationInProgress',
          );
          break;
      }

      if (result.status == LoginStatus.success && result.accessToken != null) {
        final String? facebookAccessToken = result.accessToken!.tokenString;
        if (facebookAccessToken == null || facebookAccessToken.isEmpty) {
          return false;
        }

        // Get user data from Graph API (fallback if backend does not return user)
        Map<String, dynamic>? userData;
        try {
          userData = await FacebookAuth.instance.getUserData(
            fields: 'name,email,picture.width(200)',
          );
        } catch (e) {}

        final String userId = userData != null
            ? (userData['id']?.toString() ??
                  'facebook_${DateTime.now().millisecondsSinceEpoch}')
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
            _currentUser = null;
            return false;
          }
          await _saveSession();
          FirebaseMessagingService.registerDeviceAfterLogin(_currentUser!.id);
          notifyListeners();
          return true;
        } else {
          _currentUser = null;
          _accessToken = null;
          return false;
        }
      } else if (result.status == LoginStatus.cancelled) {
        return false;
      } else {
        return false;
      }
    } catch (error, stackTrace) {
      // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint(
        '[FACEBOOK_AUTH_DEBUG] Facebook Sign-In exception; '
        'type=${error.runtimeType}; '
        'message=${_sanitizeDiagnosticMessage(error.toString())}',
      );
      if (error is PlatformException) {
        debugPrint(
          '[FACEBOOK_AUTH_DEBUG] PlatformException; code=${error.code}; '
          'message=${_sanitizeDiagnosticMessage(error.message)}',
        );
      }
      debugPrint('[FACEBOOK_AUTH_DEBUG] Stack trace:\n$stackTrace');
      _currentUser = null;
      return false;
    }
  }

  // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
  Map<String, dynamic> _sanitizedFacebookAuthResponse(String responseBody) {
    try {
      final decoded = json.decode(responseBody);
      if (decoded is! Map) {
        return {'error': true, 'errorCode': 'non_object_response'};
      }
      final body = Map<String, dynamic>.from(decoded);
      final nestedError = body['error'];
      final errorMap = nestedError is Map
          ? Map<String, dynamic>.from(nestedError)
          : const <String, dynamic>{};
      final rawErrorCode =
          body['errorCode'] ?? body['code'] ?? errorMap['code'];
      final rawErrorMessage =
          body['errorMessage'] ?? body['message'] ?? errorMap['message'];
      return {
        'success': body['success'],
        'error': nestedError is bool ? nestedError : body['error'] != null,
        'errorCode': rawErrorCode == null
            ? null
            : _sanitizeDiagnosticMessage(rawErrorCode),
        'errorMessage': rawErrorMessage == null
            ? null
            : _sanitizeDiagnosticMessage(rawErrorMessage),
      }..removeWhere((_, value) => value == null);
    } catch (_) {
      return {'error': true, 'errorCode': 'unparseable_response'};
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

      // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      final baseUri = Uri.parse(ApiConfig.baseUrl);
      debugPrint(
        '[FACEBOOK_AUTH_DEBUG] Calling backend; '
        'endpoint=${ApiConfig.facebookSignInEndpoint}; '
        'baseUrlHost=${baseUri.host}; '
        'requestTokenNonEmpty=${facebookAccessToken.isNotEmpty}',
      );
      final response = await http
          .post(
            Uri.parse(
              '${ApiConfig.baseUrl}${ApiConfig.facebookSignInEndpoint}',
            ),
            headers: ApiConfig.getHeaders(accessToken: facebookAccessToken),
            body: requestBody,
          )
          .timeout(const Duration(seconds: 60));

      // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint(
        '[FACEBOOK_AUTH_DEBUG] Backend response; status=${response.statusCode}; '
        'sanitizedBody=${_sanitizedFacebookAuthResponse(response.body)}',
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final Map<String, dynamic> responseData;
        try {
          final decoded = json.decode(response.body);
          responseData = decoded is Map<String, dynamic>
              ? decoded
              : <String, dynamic>{};
        } catch (e) {
          return false;
        }
        final tokens = responseData['tokens'];
        final Map<String, dynamic>? dataMap = responseData['data'] is Map
            ? responseData['data'] as Map<String, dynamic>?
            : null;
        if (tokens != null && tokens is Map) {
          _accessToken =
              tokens['accessToken'] ??
              tokens['access_token'] ??
              tokens['token'];
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
          _accessToken =
              dataMap['accessToken'] ??
              dataMap['access_token'] ??
              dataMap['token'];
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
          _accessToken =
              responseData['accessToken'] ??
              responseData['access_token'] ??
              responseData['token'] ??
              responseData['authToken'];
          _refreshToken =
              responseData['refreshToken'] ?? responseData['refresh_token'];
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
          return false;
        }

        if (responseData['user'] != null) {
          final userData = responseData['user'];
          _currentUser = User(
            id:
                userData['userId']?.toString() ??
                userData['user_id']?.toString() ??
                userData['id']?.toString() ??
                _currentUser?.id ??
                '',
            name: userData['name']?.toString() ?? _currentUser?.name ?? '',
            email: userData['email']?.toString() ?? _currentUser?.email ?? '',
            photoUrl:
                userData['photoUrl']?.toString() ??
                userData['photo_url']?.toString() ??
                _currentUser?.photoUrl,
            provider: 'facebook',
          );
        }

        return true;
      } else {
        return false;
      }
    } catch (error, stackTrace) {
      // TEMPORARY FACEBOOK AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint(
        '[FACEBOOK_AUTH_DEBUG] Backend request exception; '
        'type=${error.runtimeType}; '
        'message=${_sanitizeDiagnosticMessage(error.toString())}; '
        'endpoint=${ApiConfig.facebookSignInEndpoint}',
      );
      if (error is PlatformException) {
        debugPrint(
          '[FACEBOOK_AUTH_DEBUG] PlatformException; code=${error.code}; '
          'message=${_sanitizeDiagnosticMessage(error.message)}',
        );
      }
      debugPrint('[FACEBOOK_AUTH_DEBUG] Stack trace:\n$stackTrace');
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
      _currentUser = null;
      return false;
    }
  }

  // Send token to backend
  Future<bool> _sendTokenToBackend(
    String accessToken,
    String idToken,
    String provider,
  ) async {
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

      // Make API call to backend
      // TEMPORARY GOOGLE AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      if (provider == 'google') {
        final baseUri = Uri.parse(ApiConfig.baseUrl);
        debugPrint(
          '[GOOGLE_AUTH_DEBUG] Calling backend; '
          'endpoint=${ApiConfig.googleSignInEndpoint}; '
          'baseUrlHost=${baseUri.host}; requestTokenNonEmpty=${idToken.isNotEmpty}',
        );
      }
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}${ApiConfig.googleSignInEndpoint}'),
            headers: ApiConfig.getHeaders(accessToken: idToken),
            body: requestBody,
          )
          .timeout(const Duration(seconds: 30));

      if (provider == 'google') {
        debugPrint(
          '[GOOGLE_AUTH_DEBUG] Backend response; status=${response.statusCode}; '
          'sanitizedBody=${_sanitizedGoogleAuthResponse(response.body)}',
        );
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);

        // Extract tokens from response
        // Backend returns tokens nested in a "tokens" object
        final tokens = responseData['tokens'];
        if (tokens != null && tokens is Map) {
          _accessToken =
              tokens['accessToken'] ??
              tokens['access_token'] ??
              tokens['token'];
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
          _accessToken =
              responseData['accessToken'] ??
              responseData['access_token'] ??
              responseData['token'] ??
              responseData['authToken'];
          _refreshToken =
              responseData['refreshToken'] ?? responseData['refresh_token'];

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
          return false;
        }

        // Update user info if provided in response
        if (responseData['user'] != null) {
          final userData = responseData['user'];
          _currentUser = User(
            id:
                userData['userId'] ??
                userData['user_id'] ??
                userData['id'] ??
                _currentUser?.id ??
                '',
            name: userData['name'] ?? _currentUser?.name ?? '',
            email: userData['email'] ?? _currentUser?.email ?? '',
            photoUrl:
                userData['photoUrl'] ??
                userData['photo_url'] ??
                _currentUser?.photoUrl,
            provider: provider,
          );
        }

        return true;
      } else {
        return false;
      }
    } catch (error, stackTrace) {
      // TEMPORARY GOOGLE AUTH DIAGNOSTICS — REMOVE BEFORE RELEASE
      if (provider == 'google') {
        debugPrint(
          '[GOOGLE_AUTH_DEBUG] Backend request exception; '
          'type=${error.runtimeType}; '
          'message=${_sanitizeDiagnosticMessage(error.toString())}; '
          'endpoint=${ApiConfig.googleSignInEndpoint}',
        );
        if (error is PlatformException) {
          debugPrint(
            '[GOOGLE_AUTH_DEBUG] PlatformException; code=${error.code}; '
            'message=${_sanitizeDiagnosticMessage(error.message)}',
          );
        }
        debugPrint('[GOOGLE_AUTH_DEBUG] Stack trace:\n$stackTrace');
      }
      return false;
    }
  }

  bool _statusUnauthorized(int code) => code == 401 || code == 403;

  void _syncTokenExpiryFromJwtIfNeeded() {
    if (_tokenExpiry != null || _accessToken == null || _accessToken!.isEmpty) {
      return;
    }
    final claims = decodeJwtPayload(_accessToken!);
    final exp = claims?['exp'];
    if (exp == null) return;
    final expSec = exp is int ? exp : int.tryParse(exp.toString());
    if (expSec == null) return;
    _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(expSec * 1000);
  }

  void _updateAccessTokenExpiry({int? expiresInSeconds}) {
    if (expiresInSeconds != null && expiresInSeconds > 0) {
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresInSeconds));
      return;
    }
    _tokenExpiry = null;
    _syncTokenExpiryFromJwtIfNeeded();
    _tokenExpiry ??= DateTime.now().add(const Duration(minutes: 15));
  }

  bool _isAccessTokenNearExpiry() {
    _syncTokenExpiryFromJwtIfNeeded();
    if (_tokenExpiry == null) return true;
    return DateTime.now().isAfter(_tokenExpiry!.subtract(_accessRefreshLeeway));
  }

  bool _applyTokensFromAuthResponse(Map<String, dynamic> root) {
    Map<String, dynamic> payload = root;
    if (root['data'] is Map<String, dynamic>) {
      payload = Map<String, dynamic>.from(root['data'] as Map);
    }
    if (root['tokens'] is Map) {
      payload = Map<String, dynamic>.from(root['tokens'] as Map);
    }

    final newAccess =
        payload['access_token'] ??
        payload['accessToken'] ??
        root['access_token'] ??
        root['accessToken'];
    final newRefresh =
        payload['refresh_token'] ??
        payload['refreshToken'] ??
        root['refresh_token'] ??
        root['refreshToken'];

    if (newAccess == null || newAccess.toString().isEmpty) {
      return false;
    }

    _accessToken = newAccess.toString();
    if (newRefresh != null && newRefresh.toString().isNotEmpty) {
      _refreshToken = newRefresh.toString();
    }

    final expRaw =
        payload['expires_in'] ??
        payload['expiresIn'] ??
        root['expires_in'] ??
        root['expiresIn'];
    if (expRaw != null) {
      final sec = expRaw is int ? expRaw : int.tryParse(expRaw.toString()) ?? 0;
      _updateAccessTokenExpiry(expiresInSeconds: sec > 0 ? sec : null);
    } else {
      _updateAccessTokenExpiry();
    }
    return true;
  }

  /// Refreshes the access token when it is near expiry. Keeps the user signed in
  /// across multi-day sessions as long as the refresh token remains valid.
  Future<bool> ensureValidAccessToken() async {
    if (_accessToken == null || _accessToken!.isEmpty) return false;
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      return !_isAccessTokenNearExpiry();
    }
    if (!_isAccessTokenNearExpiry()) return true;
    return refreshAccessToken();
  }

  /// POST `/auth/refresh` with `Authorization: Bearer <refresh_token>` (Postman).
  Future<bool> refreshAccessToken() async {
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      return false;
    }
    if (_refreshInFlight != null) return _refreshInFlight!;

    final future = _performRefreshAccessToken();
    _refreshInFlight = future;
    try {
      return await future;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<bool> _performRefreshAccessToken() async {
    _lastRefreshWasAuthRejection = false;
    final url = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.refreshTokenEndpoint}',
    );

    Future<http.Response> post(Map<String, String> headers, [String? body]) =>
        http
            .post(url, headers: headers, body: body)
            .timeout(const Duration(seconds: 30));

    try {
      // Primary: Bearer refresh_token (matches Postman collection).
      var response = await post(
        ApiConfig.getHeaders(accessToken: _refreshToken),
        json.encode({}),
      );

      if (!(response.statusCode == 200 || response.statusCode == 201)) {
        response = await post(ApiConfig.getHeaders(accessToken: _refreshToken));
      }

      // Fallbacks for older API shapes.
      if (!(response.statusCode == 200 || response.statusCode == 201)) {
        response = await post(
          ApiConfig.getHeaders(),
          json.encode({'refresh_token': _refreshToken}),
        );
      }
      if (!(response.statusCode == 200 || response.statusCode == 201)) {
        response = await post(
          ApiConfig.getHeaders(),
          json.encode({'refreshToken': _refreshToken}),
        );
      }

      if (!(response.statusCode == 200 || response.statusCode == 201)) {
        if (_statusUnauthorized(response.statusCode)) {
          _lastRefreshWasAuthRejection = true;
        }
        return false;
      }

      final decoded = json.decode(response.body);
      final root = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
      if (!_applyTokensFromAuthResponse(root)) {
        return false;
      }

      await _saveSession();
      notifyListeners();
      return true;
    } catch (e, st) {
      return false;
    }
  }

  Future<void> _refreshTokenIfNeeded() async {
    if (_accessToken == null || _accessToken!.isEmpty) return;

    if (_refreshToken == null || _refreshToken!.isEmpty) {
      if (_isAccessTokenNearExpiry()) {
        await logout();
      }
      return;
    }

    final ok = await ensureValidAccessToken();
    if (!ok && shouldLogoutAfterRefreshFailure) {
      await logout();
    }
  }

  Future<http.Response> _authorizedMainGet(
    Uri url, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await ensureValidAccessToken();
    var headers = ApiConfig.getHeaders(accessToken: _accessToken);
    var resp = await http.get(url, headers: headers).timeout(timeout);
    if (!_statusUnauthorized(resp.statusCode)) return resp;

    final ok = await refreshAccessToken();
    if (!ok) {
      if (shouldLogoutAfterRefreshFailure) {
        await logout();
      }
      return resp;
    }

    headers = ApiConfig.getHeaders(accessToken: _accessToken);
    return http.get(url, headers: headers).timeout(timeout);
  }

  // Get user profile from backend
  Future<Map<String, dynamic>?> getUserProfile() async {
    if (_accessToken == null) {
      return null;
    }

    try {
      final url = '${ApiConfig.baseUrl}${ApiConfig.profileEndpoint}';

      final response = await _authorizedMainGet(Uri.parse(url));

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        return responseData;
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }

  /// `userId` and `email` for async mantra job APIs — prefers JWT [`sub`], [`email`], then [currentUser].
  Map<String, String>? getCreateJobUserFields() {
    String userId = '';
    String email = '';

    final token = _accessToken;
    if (token != null && token.isNotEmpty) {
      final claims = decodeJwtPayload(token);
      if (claims != null) {
        final sub = claims['sub'];
        if (sub != null && sub.toString().isNotEmpty) {
          userId = sub.toString();
        }
        final em = claims['email'];
        if (em != null && em.toString().isNotEmpty) {
          email = em.toString();
        }
        if (userId.isEmpty) {
          final uid = claims['userId'] ?? claims['user_id'] ?? claims['id'];
          if (uid != null && uid.toString().isNotEmpty) {
            userId = uid.toString();
          }
        }
      }
    }

    if (userId.isEmpty && _currentUser != null) userId = _currentUser!.id;
    if (email.isEmpty && _currentUser != null) email = _currentUser!.email;

    if (userId.isEmpty) return null;
    return {'userId': userId, 'email': email};
  }

  // Save session to local storage
  Future<void> _saveSession() async {
    if (_refreshToken == null || _refreshToken!.isEmpty) {}
    if (_accessToken == null || _accessToken!.isEmpty) {
      throw StateError(
        'Cannot persist an authenticated session without a token',
      );
    }

    await _secureSessionStorage.saveAccessToken(_accessToken!);
    if (_refreshToken != null && _refreshToken!.isNotEmpty) {
      await _secureSessionStorage.saveRefreshToken(_refreshToken!);
    } else {
      await _secureSessionStorage.deleteRefreshToken();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', _currentUser?.id ?? '');
    await prefs.setString('user_name', _currentUser?.name ?? '');
    await prefs.setString('user_email', _currentUser?.email ?? '');
    await prefs.setString('user_photo_url', _currentUser?.photoUrl ?? '');
    await prefs.setString('user_provider', _currentUser?.provider ?? '');
    await prefs.setString(
      'token_expiry',
      _tokenExpiry?.toIso8601String() ?? '',
    );
    await SecureSessionStorage.removeLegacyTokenKeys(prefs);
  }

  // Load session from local storage
  Future<void> _loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final migration = await _secureSessionStorage.migrateLegacyTokens(prefs);
      if (migration == LegacyTokenMigrationResult.failed) {
        _currentUser = null;
        _accessToken = null;
        _refreshToken = null;
        _tokenExpiry = null;
        return;
      }

      final userId = prefs.getString('user_id');
      final secureAccessToken = await _secureSessionStorage.readAccessToken();
      final secureRefreshToken = await _secureSessionStorage.readRefreshToken();
      if (userId != null &&
          userId.isNotEmpty &&
          secureAccessToken != null &&
          secureAccessToken.isNotEmpty) {
        _currentUser = User(
          id: userId,
          name: prefs.getString('user_name') ?? '',
          email: prefs.getString('user_email') ?? '',
          photoUrl: prefs.getString('user_photo_url'),
          provider: prefs.getString('user_provider') ?? '',
        );

        _accessToken = secureAccessToken;
        _refreshToken = secureRefreshToken;

        final expiryString = prefs.getString('token_expiry');
        if (expiryString != null && expiryString.isNotEmpty) {
          _tokenExpiry = DateTime.parse(expiryString);
        }
        _syncTokenExpiryFromJwtIfNeeded();
      }
    } catch (e) {
      // Continue with empty state
    }
  }

  // Logout
  Future<void> logout() async {
    try {
      // Call backend logout endpoint if we have an access token
      if (_accessToken != null) {
        try {
          await http
              .post(
                Uri.parse('${ApiConfig.baseUrl}${ApiConfig.logoutEndpoint}'),
                headers: ApiConfig.getHeaders(accessToken: _accessToken),
                body: json.encode({'test': 'data'}),
              )
              .timeout(const Duration(seconds: 10));
        } catch (e) {}
      }

      try {
        await _googleSignIn.signOut();
      } catch (_) {}
    } catch (e) {
    } finally {
      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;
      try {
        await _clearPersistedSessionPreservingCart();
      } finally {
        notifyListeners();
      }
    }
  }

  /// Clears the local authenticated session after the backend has deleted the
  /// application account. This intentionally does not call `/auth/logout`.
  Future<void> clearLocalSessionAfterAccountDeletion() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Local credential cleanup must continue if provider sign-out fails.
    } finally {
      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;
      try {
        await _clearPersistedSessionPreservingCart();
      } finally {
        notifyListeners();
      }
    }
  }

  // Clear all session data (for testing)
  Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _secureSessionStorage.clearSessionSecrets();
      await SecureSessionStorage.removeLegacyTokenKeys(prefs);
      await prefs.clear();

      _currentUser = null;
      _accessToken = null;
      _refreshToken = null;
      _tokenExpiry = null;

      notifyListeners();
    } catch (e) {}
  }

  Future<void> _clearPersistedSessionPreservingCart() async {
    final prefs = await SharedPreferences.getInstance();
    final cartItems = prefs.getStringList('cart_items') ?? [];
    final cartQuantities = prefs.getString('cart_quantities');

    Object? secureStorageError;
    try {
      await _secureSessionStorage.clearSessionSecrets();
    } catch (error) {
      secureStorageError = error;
    }

    await SecureSessionStorage.removeLegacyTokenKeys(prefs);
    await prefs.clear();

    if (cartItems.isNotEmpty) {
      await prefs.setStringList('cart_items', cartItems);
      if (cartQuantities != null && cartQuantities.isNotEmpty) {
        await prefs.setString('cart_quantities', cartQuantities);
      }
    }

    if (secureStorageError != null) {
      throw StateError('Secure session cleanup failed');
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
