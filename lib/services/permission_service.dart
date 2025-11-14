// lib/services/permission_service.dart
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

final MethodChannel _audioChannel = MethodChannel('app.channel.audio');

class PermissionService {
  /// On iOS uses native AVAudioSession as authoritative.
  /// On Android falls back to permission_handler.
  static Future<bool> isMicrophoneGranted() async {
    if (Platform.isIOS) {
      try {
        final dynamic statusMap = await _audioChannel.invokeMethod('readMicrophoneNativeStatus');
        if (statusMap is Map) {
          final int rp = (statusMap['recordPermission'] is int)
              ? statusMap['recordPermission'] as int
              : int.tryParse('${statusMap['recordPermission']}') ?? -1;
          return rp == 2;
        }
      } catch (e) {
        // Native read failed; fallback to permission_handler
        print('isMicrophoneGranted native read failed: $e');
      }
    }

    final status = await Permission.microphone.status;
    return status == PermissionStatus.granted;
  }

  /// Requests microphone permission cross-platform.
  /// On iOS uses native request that also activates audio session.
  static Future<bool> requestMicrophonePermission() async {
    if (Platform.isIOS) {
      try {
        final dynamic result = await _audioChannel.invokeMethod('requestMicrophoneNative');
        if (result is int) return result == 2;
        if (result is bool) return result;
        if (result is String) return result == '2' || result.toLowerCase() == 'true';
        // fallback
        final res = await Permission.microphone.request();
        return res == PermissionStatus.granted;
      } catch (e) {
        print('requestMicrophonePermission native failed: $e');
        final res = await Permission.microphone.request();
        return res == PermissionStatus.granted;
      }
    } else {
      final res = await Permission.microphone.request();
      return res == PermissionStatus.granted;
    }
  }
}








