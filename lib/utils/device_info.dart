import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceInfo {
  static const String _deviceIdKey = 'device_id';
  
  /// Get device platform (android, ios, etc.)
  static String getPlatform() {
    if (Platform.isAndroid) {
      return 'android';
    } else if (Platform.isIOS) {
      return 'ios';
    } else {
      return 'unknown';
    }
  }
  
  /// Get or generate a unique device ID
  static Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? deviceId = prefs.getString(_deviceIdKey);
      
      if (deviceId != null && deviceId.isNotEmpty) {
        return deviceId;
      }
      
      // Generate a new device ID based on device info
      String newDeviceId;
      final deviceInfo = DeviceInfoPlugin();
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        newDeviceId = androidInfo.id; // Android ID
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        newDeviceId = iosInfo.identifierForVendor ?? 'ios-${DateTime.now().millisecondsSinceEpoch}';
      } else {
        newDeviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
      }
      
      // Save the device ID
      await prefs.setString(_deviceIdKey, newDeviceId);
      return newDeviceId;
    } catch (e) {
      // Fallback to timestamp-based ID
      final fallbackId = 'device-${DateTime.now().millisecondsSinceEpoch}';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deviceIdKey, fallbackId);
      return fallbackId;
    }
  }
  
  /// Get app version
  static Future<String> getAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version;
    } catch (e) {
      return '1.0.0';
    }
  }
  
  /// Get device info map for API requests
  static Future<Map<String, String>> getDeviceInfoMap() async {
    return {
      'platform': getPlatform(),
      'deviceId': await getDeviceId(),
      'appVersion': await getAppVersion(),
    };
  }
}


