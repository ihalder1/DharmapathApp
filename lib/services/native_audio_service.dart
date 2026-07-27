import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Native iOS audio permission service
/// Uses MethodChannel to call native AVAudioSession.requestRecordPermission
/// This bypasses the Flutter plugin layer and directly requests iOS permission
class NativeAudioService {
  static const MethodChannel _channel = MethodChannel('app.channel.audio');

  /// Request microphone permission using native iOS AVAudioSession
  /// This is the definitive way to ensure iOS registers the permission
  /// and shows the system dialog
  /// Returns true if granted (native returns 2), false otherwise
  static Future<bool> requestMicrophoneNative() async {
    try {
      final dynamic result = await _channel.invokeMethod(
        'requestMicrophoneNative',
      );

      // Handle int (2 = granted, 1 = denied) or bool
      bool granted;
      if (result is int) {
        granted = result == 2;
      } else if (result is bool) {
        granted = result;
      } else if (result is String) {
        granted = result == '2' || result.toLowerCase() == 'true';
      } else {
        return false;
      }

      return granted;
    } on PlatformException catch (e) {
      return false;
    } catch (e, stackTrace) {
      return false;
    }
  }

  /// Read detailed native AVAudioSession status
  /// Returns a map with recordPermission, isInputAvailable, category, mode, sampleRate
  static Future<Map<String, dynamic>?> readMicrophoneNativeStatus() async {
    try {
      final Map<dynamic, dynamic>? statusMap = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('readMicrophoneNativeStatus');

      if (statusMap == null) {
        return null;
      }

      // Convert to String keys for easier access
      final Map<String, dynamic> result = {};
      statusMap.forEach((key, value) {
        result[key.toString()] = value;
      });

      return result;
    } on PlatformException catch (e) {
      return null;
    } catch (e, stackTrace) {
      return null;
    }
  }

  /// Debug function to compare permission_handler vs native status
  /// This helps identify discrepancies between Flutter plugin and iOS native state
  static Future<void> debugMicrophonePermissions() async {
    // 1) permission_handler status
    final status = await Permission.microphone.status;

    // 2) call permission_handler.request() and print the result
    final requested = await Permission.microphone.request();

    // 3) call native AVAudioSession request via MethodChannel
    try {
      final dynamic nativeResult = await _channel.invokeMethod(
        'requestMicrophoneNative',
      );

      bool nativeGranted;
      if (nativeResult is int) {
        nativeGranted = nativeResult == 2;
      } else if (nativeResult is bool) {
        nativeGranted = nativeResult;
      } else {
        nativeGranted =
            '$nativeResult'.toLowerCase() == 'true' || '$nativeResult' == '2';
      }
    } on PlatformException catch (e) {}

    // 4) if on iOS, call an extra native status read
    if (Platform.isIOS) {
      try {
        final Map<dynamic, dynamic>? statusMap = await _channel
            .invokeMethod<Map<dynamic, dynamic>>('readMicrophoneNativeStatus');

        if (statusMap != null) {
          // Interpret recordPermission
          final recordPermissionValue = statusMap['recordPermission'] as int?;
          if (recordPermissionValue != null) {
            String permissionStatus;
            switch (recordPermissionValue) {
              case 0:
                permissionStatus = 'UNDETERMINED';
                break;
              case 1:
                permissionStatus = 'DENIED';
                break;
              case 2:
                permissionStatus = 'GRANTED';
                break;
              default:
                permissionStatus = 'UNKNOWN';
            }
          }
        }
      } on PlatformException catch (e) {}
    }

    // 5) Final comparison
    final finalStatus = await Permission.microphone.status;

    if (Platform.isIOS) {
      try {
        final Map<dynamic, dynamic>? finalStatusMap = await _channel
            .invokeMethod<Map<dynamic, dynamic>>('readMicrophoneNativeStatus');
        if (finalStatusMap != null) {
          final nativePermission = finalStatusMap['recordPermission'] as int?;

          // Check for mismatch
          if (finalStatus.isGranted && nativePermission != 2) {
          } else if (!finalStatus.isGranted && nativePermission == 2) {
          } else if (finalStatus.isGranted && nativePermission == 2) {}

          // Check audio input availability
          final isInputAvailable = finalStatusMap['isInputAvailable'] as bool?;
          if (isInputAvailable == false) {}
        }
      } catch (e) {}
    }
  }
}
