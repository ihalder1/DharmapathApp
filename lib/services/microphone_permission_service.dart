import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

final MethodChannel _audioChannel = MethodChannel('app.channel.audio');

/// Authoritative check for microphone on iOS via native AVAudioSession.
/// On Android falls back to permission_handler.
Future<bool> isMicrophoneGranted() async {
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
      print('isMicrophoneGranted native read failed: $e');
    }
  }
  final status = await Permission.microphone.status;
  return status == PermissionStatus.granted;
}

/// Authoritative request for microphone on iOS via native AVAudioSession.
/// On Android uses permission_handler.
Future<bool> requestMicrophonePermissionCrossPlatform() async {
  if (Platform.isIOS) {
    try {
      final dynamic result = await _audioChannel.invokeMethod('requestMicrophoneNative');
      if (result is int) return result == 2; // expected
      if (result is bool) return result;
      if (result is String) return result == '2' || result.toLowerCase() == 'true';
      final res = await Permission.microphone.request();
      return res == PermissionStatus.granted;
    } catch (e) {
      print('requestMicrophonePermissionCrossPlatform native failed: $e');
      final res = await Permission.microphone.request();
      return res == PermissionStatus.granted;
    }
  } else {
    final res = await Permission.microphone.request();
    return res == PermissionStatus.granted;
  }
}

