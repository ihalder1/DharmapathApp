import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/notification.dart';

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

