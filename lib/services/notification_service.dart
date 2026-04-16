import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../constants/api_config.dart';
import '../models/notification.dart';

// --- Firebase Cloud Messaging (FCM) -----------------------------------------
// Native config: android/app/google-services.json, ios/Runner/GoogleService-Info.plist
// Xcode: Push Notifications + Background Modes → Remote notifications

const String _prefsFcmDeviceIdKey = 'fcm_device_id';

void _logFcmDeviceRegistrationBody(Map<String, String> payload, {required String trigger}) {
  const line = '════════════════════════════════════════════════════════════';
  final prettyJson = const JsonEncoder.withIndent('  ').convert(payload);

  debugPrint(line);
  debugPrint('FCM DEVICE REGISTRATION — request body (for backend developer)');
  debugPrint('Trigger: $trigger');
  debugPrint(line);
  debugPrint('HTTP: PUT ${ApiConfig.baseUrl}${ApiConfig.putDeviceInfoEndpoint}');
  debugPrint('Content-Type: application/json');
  debugPrint('');
  debugPrint('--- Fields (copy-friendly) ---');
  debugPrint('user_id:   ${payload['user_id']}');
  debugPrint('device_id: ${payload['device_id']}');
  debugPrint('platform:  ${payload['platform']}');
  debugPrint('fcm_token: ${payload['fcm_token']}');
  debugPrint('');
  debugPrint('--- JSON body (exact payload to send) ---');
  for (final chunk in _chunkForLog(prettyJson)) {
    debugPrint(chunk);
  }
  debugPrint(line);
}

Iterable<String> _chunkForLog(String text, {int chunkSize = 800}) sync* {
  if (text.length <= chunkSize) {
    yield text;
    return;
  }
  for (var i = 0; i < text.length; i += chunkSize) {
    final end = (i + chunkSize > text.length) ? text.length : i + chunkSize;
    yield text.substring(i, end);
  }
}

/// Top-level; registered in [main] before other FCM use.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint(
    '[FCM background] id=${message.messageId} title=${message.notification?.title} data=${message.data}',
  );
}

/// All Firebase Messaging setup and device registration (separate from in-app [NotificationService] API).
class FirebaseMessagingService {
  FirebaseMessagingService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static StreamSubscription<RemoteMessage>? _onMessageSub;
  static StreamSubscription<RemoteMessage>? _onOpenedAppSub;
  static StreamSubscription<String>? _tokenRefreshSub;

  /// Context for [onTokenRefresh] — set only via [initTokenRefreshListener] after login.
  static String? _tokenRefreshUserId;
  static String? _tokenRefreshDeviceId;

  /// Call after [Firebase.initializeApp]. Does **not** attach [onTokenRefresh] (requires logged-in user).
  static Future<void> initialize() async {
    await _requestPermission();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    final token = await _messaging.getToken();
    if (token != null && token.isNotEmpty) {
      debugPrint('[FCM] device token (startup, not registered until login): $token');
    } else {
      debugPrint('[FCM] device token not available yet at startup');
    }

    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      debugPrint(
        '[FCM] app opened from terminated state via notification: id=${initial.messageId} data=${initial.data}',
      );
    }

    await _listenForegroundAndOpenedApp();
  }

  static Future<void> _requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );
    debugPrint('[FCM] notification permission: ${settings.authorizationStatus}');
  }

  static Future<void> _listenForegroundAndOpenedApp() async {
    await _onMessageSub?.cancel();
    await _onOpenedAppSub?.cancel();

    _onMessageSub = FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint(
        '[FCM foreground] id=${message.messageId} title=${message.notification?.title} body=${message.notification?.body} data=${message.data}',
      );
    });

    _onOpenedAppSub = FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint(
        '[FCM opened from notification] id=${message.messageId} data=${message.data}',
      );
    });
  }

  static String _platformLabel() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return defaultTargetPlatform.name;
    }
  }

  static Future<String?> _getAuthBearerToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token') ?? prefs.getString('access_token');
  }

  /// Registers device with backend: `PUT /auth/put-device-info` (Bearer + x-api-key).
  /// [payload] keys: user_id, device_id, platform, fcm_token.
  static Future<void> sendDeviceToBackend(Map payload) async {
    try {
      String str(dynamic v) => v?.toString() ?? '';
      final normalized = <String, String>{
        'user_id': str(payload['user_id']),
        'device_id': str(payload['device_id']),
        'platform': str(payload['platform']),
        'fcm_token': str(payload['fcm_token']),
      };
      _logFcmDeviceRegistrationBody(normalized, trigger: 'sendDeviceToBackend → PUT');

      if (normalized['user_id']!.isEmpty || normalized['fcm_token']!.isEmpty) {
        debugPrint('[FCM] sendDeviceToBackend skipped: missing user_id or fcm_token');
        return;
      }

      final bearer = await _getAuthBearerToken();
      if (bearer == null || bearer.isEmpty) {
        debugPrint('[FCM] sendDeviceToBackend skipped: no auth token (user not logged in)');
        return;
      }

      final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.putDeviceInfoEndpoint}');
      final response = await http
          .put(
            uri,
            headers: ApiConfig.getHeaders(accessToken: bearer),
            body: json.encode(normalized),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint('[FCM] put-device-info success: ${response.statusCode}');
        if (response.body.isNotEmpty) {
          debugPrint('[FCM] put-device-info body: ${response.body}');
        }
      } else {
        debugPrint(
          '[FCM] put-device-info failed: ${response.statusCode} ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('[FCM] sendDeviceToBackend error (non-fatal): $e');
    }
  }

  /// Attach [FirebaseMessaging.instance.onTokenRefresh] once the user is known. Safe to call again on re-login (replaces listener).
  static Future<void> initTokenRefreshListener(String userId, String deviceId) async {
    try {
      if (userId.isEmpty || deviceId.isEmpty) {
        debugPrint('[FCM] initTokenRefreshListener skipped: empty userId or deviceId');
        return;
      }

      await _tokenRefreshSub?.cancel();
      _tokenRefreshUserId = userId;
      _tokenRefreshDeviceId = deviceId;

      _tokenRefreshSub = _messaging.onTokenRefresh.listen(
        (String newToken) {
          try {
            print('FCM Token Refreshed: $newToken');
            final uid = _tokenRefreshUserId;
            final did = _tokenRefreshDeviceId;
            if (uid == null || did == null || uid.isEmpty || did.isEmpty) {
              debugPrint('[FCM] token refresh: missing stored user/device context, skipping sendDeviceToBackend');
              return;
            }
            unawaited(
              sendDeviceToBackend(<String, dynamic>{
                'user_id': uid,
                'device_id': did,
                'platform': _platformLabel(),
                'fcm_token': newToken,
              }),
            );
          } catch (e) {
            debugPrint('[FCM] token refresh callback error (non-fatal): $e');
          }
        },
        onError: (Object e, StackTrace st) {
          debugPrint('[FCM] onTokenRefresh stream error (non-fatal): $e');
        },
      );
      debugPrint('[FCM] Token refresh listener attached (user_id=$userId device_id=$deviceId)');
    } catch (e) {
      debugPrint('[FCM] initTokenRefreshListener failed (non-fatal): $e');
    }
  }

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsFcmDeviceIdKey);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_prefsFcmDeviceIdKey, id);
      debugPrint('[FCM] generated new device_id: $id');
    }
    return id;
  }

  static Future<void> sendTokenToBackend(String token) async {
    if (token.isEmpty) return;
    debugPrint('[FCM] sendTokenToBackend (placeholder) — token=$token');
  }

  /// Fire-and-forget after login. Registers device payload, then attaches token refresh listener.
  static void registerDeviceAfterLogin(String userId) {
    if (userId.isEmpty) return;
    unawaited(_registerDeviceAfterLoginSafe(userId));
  }

  static Future<void> _registerDeviceAfterLoginSafe(String userId) async {
    try {
      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('[FCM] registerDeviceAfterLogin: no token');
        return;
      }
      debugPrint('[FCM] device token (post-login): $token');
      await sendTokenToBackend(token);

      final deviceId = await getOrCreateDeviceId();
      await sendDeviceToBackend(<String, dynamic>{
        'user_id': userId,
        'device_id': deviceId,
        'platform': _platformLabel(),
        'fcm_token': token,
      });
      await initTokenRefreshListener(userId, deviceId);
    } catch (e) {
      debugPrint('[FCM] registerDeviceAfterLogin failed (non-blocking): $e');
    }
  }
}

// --- In-app notification feed (REST API) ------------------------------------

class NotificationService {
  static const String baseUrl = 'https://api.dharmapath.com'; // Replace with actual backend URL

  // Shared state for notifications (for development/mock mode)
  static List<NotificationItem> _cachedNotifications = [];

  // Get auth token from SharedPreferences
  static Future<String?> _getAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  // Get all notifications
  static Future<List<NotificationItem>> getNotifications() async {
    try {
      final token = await _getAuthToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http.get(
        Uri.parse('$baseUrl/api/notifications'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> notificationsJson = data['notifications'] ?? data['data'] ?? [];

        _cachedNotifications = notificationsJson
            .map((json) => NotificationItem.fromJson(json))
            .toList();
        return _cachedNotifications;
      } else {
        print('Failed to load notifications: ${response.statusCode}');
        // Return mock data for development
        if (_cachedNotifications.isEmpty) {
          _cachedNotifications = _getMockNotifications();
        }
        return _cachedNotifications;
      }
    } catch (e) {
      print('Error loading notifications: $e');
      // Return mock data for development
      if (_cachedNotifications.isEmpty) {
        _cachedNotifications = _getMockNotifications();
      }
      return _cachedNotifications;
    }
  }

  // Get unread notification count
  static Future<int> getUnreadCount() async {
    try {
      final token = await _getAuthToken();
      if (token == null) {
        // Use cached notifications or load mock data
        if (_cachedNotifications.isEmpty) {
          _cachedNotifications = _getMockNotifications();
        }
        return _cachedNotifications.where((n) => !n.isRead).length;
      }

      final response = await http.get(
        Uri.parse('$baseUrl/api/notifications/unread-count'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['count'] ?? data['unread_count'] ?? 0;
      } else {
        // Use cached notifications or load mock data
        if (_cachedNotifications.isEmpty) {
          _cachedNotifications = _getMockNotifications();
        }
        return _cachedNotifications.where((n) => !n.isRead).length;
      }
    } catch (e) {
      print('Error getting unread count: $e');
      // Use cached notifications or load mock data
      if (_cachedNotifications.isEmpty) {
        _cachedNotifications = _getMockNotifications();
      }
      return _cachedNotifications.where((n) => !n.isRead).length;
    }
  }

  // Mark notification as read
  static Future<bool> markAsRead(String notificationId) async {
    try {
      // Update local cache first
      final index = _cachedNotifications.indexWhere((n) => n.id == notificationId);
      if (index != -1) {
        _cachedNotifications[index] = _cachedNotifications[index].copyWith(isRead: true);
      }

      final token = await _getAuthToken();
      if (token == null) {
        // For development, return true even without token
        print('No auth token - marking as read locally (development mode)');
        return true;
      }

      final response = await http.put(
        Uri.parse('$baseUrl/api/notifications/$notificationId/read'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      } else {
        print('Failed to mark notification as read: ${response.statusCode}');
        // For development, return true even if API fails
        return true;
      }
    } catch (e) {
      print('Error marking notification as read: $e');
      // For development, return true even if API fails
      return true;
    }
  }

  // Mark all notifications as read
  static Future<bool> markAllAsRead() async {
    try {
      // Update local cache first
      _cachedNotifications = _cachedNotifications.map((n) => n.copyWith(isRead: true)).toList();

      final token = await _getAuthToken();
      if (token == null) {
        // For development, return true even without token
        print('No auth token - marking all as read locally (development mode)');
        return true;
      }

      final response = await http.put(
        Uri.parse('$baseUrl/api/notifications/read-all'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      } else {
        print('Failed to mark all notifications as read: ${response.statusCode}');
        // For development, return true even if API fails
        return true;
      }
    } catch (e) {
      print('Error marking all notifications as read: $e');
      // For development, return true even if API fails
      return true;
    }
  }

  // Delete notification
  static Future<bool> deleteNotification(String notificationId) async {
    try {
      // Update local cache first
      _cachedNotifications.removeWhere((n) => n.id == notificationId);

      final token = await _getAuthToken();
      if (token == null) {
        // For development, return true even without token
        print('No auth token - deleting locally (development mode)');
        return true;
      }

      final response = await http.delete(
        Uri.parse('$baseUrl/api/notifications/$notificationId'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      } else {
        print('Failed to delete notification: ${response.statusCode}');
        // For development, return true even if API fails
        return true;
      }
    } catch (e) {
      print('Error deleting notification: $e');
      // For development, return true even if API fails
      return true;
    }
  }

  // Mock notifications for development
  static List<NotificationItem> _getMockNotifications() {
    return [
      NotificationItem(
        id: '1',
        title: 'Mantra Generated Successfully',
        message: 'Your personalized Maa Durga Mantra has been generated in your voice.',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        isRead: false,
        type: 'mantra_generated',
      ),
      NotificationItem(
        id: '2',
        title: 'Purchase Confirmed',
        message: 'Your purchase of Ganesh Mantra has been confirmed.',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
        isRead: false,
        type: 'purchase',
      ),
      NotificationItem(
        id: '3',
        title: 'Welcome to Dharmapath',
        message: 'Thank you for joining us on your spiritual journey.',
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
        isRead: true,
        type: 'system',
      ),
      NotificationItem(
        id: '4',
        title: 'Mantra Generation Complete',
        message: 'Your Shri Rama Mantra is ready to play.',
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
        isRead: true,
        type: 'mantra_generated',
      ),
    ];
  }
}
