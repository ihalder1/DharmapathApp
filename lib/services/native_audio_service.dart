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
      print('=== NATIVE MICROPHONE PERMISSION REQUEST ===');
      print('Calling native iOS AVAudioSession.requestRecordPermission...');
      
      final dynamic result = await _channel.invokeMethod('requestMicrophoneNative');
      
      print('Native request result (raw): $result (type: ${result.runtimeType})');
      
      // Handle int (2 = granted, 1 = denied) or bool
      bool granted;
      if (result is int) {
        granted = result == 2;
        print('Native request result (int): $result -> granted: $granted');
      } else if (result is bool) {
        granted = result;
        print('Native request result (bool): $granted');
      } else if (result is String) {
        granted = result == '2' || result.toLowerCase() == 'true';
        print('Native request result (string): $result -> granted: $granted');
      } else {
        print('Native request returned unexpected type: ${result.runtimeType}');
        return false;
      }
      
      return granted;
    } on PlatformException catch (e) {
      print('=== NATIVE REQUEST FAILED ===');
      print('Error: ${e.message}');
      print('Details: ${e.details}');
      print('Code: ${e.code}');
      return false;
    } catch (e, stackTrace) {
      print('=== UNEXPECTED ERROR IN NATIVE REQUEST ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }

  /// Read detailed native AVAudioSession status
  /// Returns a map with recordPermission, isInputAvailable, category, mode, sampleRate
  static Future<Map<String, dynamic>?> readMicrophoneNativeStatus() async {
    try {
      print('=== READING NATIVE MICROPHONE STATUS ===');
      
      final Map<dynamic, dynamic>? statusMap = await _channel.invokeMethod<Map<dynamic, dynamic>>('readMicrophoneNativeStatus');
      
      if (statusMap == null) {
        print('Native status read returned null');
        return null;
      }
      
      // Convert to String keys for easier access
      final Map<String, dynamic> result = {};
      statusMap.forEach((key, value) {
        result[key.toString()] = value;
      });
      
      print('Native status map: $result');
      return result;
    } on PlatformException catch (e) {
      print('=== NATIVE STATUS READ FAILED ===');
      print('Error: ${e.message}');
      print('Details: ${e.details}');
      print('Code: ${e.code}');
      return null;
    } catch (e, stackTrace) {
      print('=== UNEXPECTED ERROR READING NATIVE STATUS ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  /// Debug function to compare permission_handler vs native status
  /// This helps identify discrepancies between Flutter plugin and iOS native state
  static Future<void> debugMicrophonePermissions() async {
    print('\n');
    print('========================================');
    print('=== DEBUG MICROPHONE PERMISSIONS ===');
    print('========================================\n');
    
    // 1) permission_handler status
    final status = await Permission.microphone.status;
    print('DART: permission_handler status = $status');
    print('DART: permission_handler isGranted = ${status.isGranted}');
    print('DART: permission_handler isDenied = ${status.isDenied}');
    print('DART: permission_handler isPermanentlyDenied = ${status.isPermanentlyDenied}');
    
    // 2) call permission_handler.request() and print the result
    print('\n--- Calling permission_handler.request() ---');
    final requested = await Permission.microphone.request();
    print('DART: permission_handler request() -> $requested');
    print('DART: permission_handler request() isGranted = ${requested.isGranted}');
    
    // 3) call native AVAudioSession request via MethodChannel
    print('\n--- Calling native AVAudioSession.requestRecordPermission() ---');
    try {
      final dynamic nativeResult = await _channel.invokeMethod('requestMicrophoneNative');
      
      bool nativeGranted;
      if (nativeResult is int) {
        nativeGranted = nativeResult == 2;
      } else if (nativeResult is bool) {
        nativeGranted = nativeResult;
      } else {
        nativeGranted = '$nativeResult'.toLowerCase() == 'true' || '$nativeResult' == '2';
      }
      
      print('DART: native requestRecordPermission -> $nativeResult (interpreted: $nativeGranted)');
    } on PlatformException catch (e) {
      print('DART: native method failed: $e');
      print('DART: native method error code: ${e.code}');
      print('DART: native method error message: ${e.message}');
      print('DART: native method error details: ${e.details}');
    }
    
    // 4) if on iOS, call an extra native status read
    if (Platform.isIOS) {
      print('\n--- Reading native AVAudioSession status ---');
      try {
        final Map<dynamic, dynamic>? statusMap = await _channel.invokeMethod<Map<dynamic, dynamic>>('readMicrophoneNativeStatus');
        print('DART: native statusMap -> $statusMap');
        
        if (statusMap != null) {
          print('\n--- Native Status Breakdown ---');
          print('recordPermission (0=undetermined, 1=denied, 2=granted): ${statusMap['recordPermission']}');
          print('isInputAvailable: ${statusMap['isInputAvailable']}');
          print('category: ${statusMap['category']}');
          print('mode: ${statusMap['mode']}');
          print('sampleRate: ${statusMap['sampleRate']}');
          
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
            print('Native recordPermission interpretation: $permissionStatus');
          }
        }
      } on PlatformException catch (e) {
        print('DART: native status read failed: $e');
        print('DART: native status read error code: ${e.code}');
        print('DART: native status read error message: ${e.message}');
      }
    }
    
    // 5) Final comparison
    print('\n--- FINAL COMPARISON ---');
    final finalStatus = await Permission.microphone.status;
    print('permission_handler final status: $finalStatus (isGranted: ${finalStatus.isGranted})');
    
    if (Platform.isIOS) {
      try {
        final Map<dynamic, dynamic>? finalStatusMap = await _channel.invokeMethod<Map<dynamic, dynamic>>('readMicrophoneNativeStatus');
        if (finalStatusMap != null) {
          final nativePermission = finalStatusMap['recordPermission'] as int?;
          print('Native final recordPermission: $nativePermission (2=granted, 1=denied, 0=undetermined)');
          
          // Check for mismatch
          if (finalStatus.isGranted && nativePermission != 2) {
            print('⚠️ MISMATCH: permission_handler says GRANTED but native says ${nativePermission == 1 ? "DENIED" : "UNDETERMINED"}');
          } else if (!finalStatus.isGranted && nativePermission == 2) {
            print('⚠️ MISMATCH: permission_handler says DENIED but native says GRANTED');
          } else if (finalStatus.isGranted && nativePermission == 2) {
            print('✅ MATCH: Both permission_handler and native say GRANTED');
          }
          
          // Check audio input availability
          final isInputAvailable = finalStatusMap['isInputAvailable'] as bool?;
          if (isInputAvailable == false) {
            print('⚠️ WARNING: isInputAvailable is FALSE - Simulator may not have audio input enabled!');
            print('   Fix: Simulator menu → Device → Audio Input → Connect Hardware');
          }
        }
      } catch (e) {
        print('Could not read final native status: $e');
      }
    }
    
    print('\n========================================\n');
  }
}

