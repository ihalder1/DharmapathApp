import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/voice_recording_service.dart';
import '../services/native_audio_service.dart';
import '../services/permission_service.dart';
import '../constants/app_colors.dart';

class PermissionTestScreen extends StatefulWidget {
  @override
  _PermissionTestScreenState createState() => _PermissionTestScreenState();
}

class _PermissionTestScreenState extends State<PermissionTestScreen> {
  String _status = 'Not checked';
  PermissionStatus _permissionStatus = PermissionStatus.denied;
  bool _isLoading = false;
  
  @override
  void initState() {
    super.initState();
    _checkPermission();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Permission Test'),
        backgroundColor: AppColors.primarySaffron,
        foregroundColor: AppColors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _getStatusColor().withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _getStatusColor(),
                    width: 2,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      _getStatusIcon(),
                      size: 48,
                      color: _getStatusColor(),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Microphone Permission Status',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _getStatusText(),
                      style: TextStyle(
                        fontSize: 16,
                        color: _getStatusColor(),
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 30),
              
              // Action Buttons
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _checkPermission,
                icon: const Icon(Icons.refresh),
                label: const Text('Check Permission'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primarySaffron,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              
              const SizedBox(height: 12),
              
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _requestPermission,
                icon: const Icon(Icons.lock_open),
                label: const Text('Request Permission'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primarySaffron,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              
              const SizedBox(height: 12),
              
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _testRecording,
                icon: const Icon(Icons.mic),
                label: const Text('Test Recording'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primarySaffron,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              
              const SizedBox(height: 12),
              
              // Native iOS Request Button (ChatGPT's guaranteed solution)
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _requestNativePermission,
                icon: const Icon(Icons.phone_iphone),
                label: const Text('Request Native (iOS Direct)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              
              const SizedBox(height: 12),
              
              // Debug Button (ChatGPT's diagnostic tool)
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _debugPermissions,
                icon: const Icon(Icons.bug_report),
                label: const Text('Debug Permissions (Full Diagnostic)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              
              // Show Open Settings button if permanently denied
              if (_permissionStatus == PermissionStatus.permanentlyDenied) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.settings,
                        size: 32,
                        color: Colors.orange,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Permission Permanently Denied',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'You need to enable microphone permission in iOS Settings.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Open Settings'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: AppColors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              
              if (_isLoading) ...[
                const SizedBox(height: 20),
                const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.primarySaffron),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  Color _getStatusColor() {
    switch (_permissionStatus) {
      case PermissionStatus.granted:
        return Colors.green;
      case PermissionStatus.denied:
        return Colors.orange;
      case PermissionStatus.permanentlyDenied:
        return Colors.red;
      case PermissionStatus.restricted:
        return Colors.grey;
      default:
        return AppColors.textSecondary;
    }
  }
  
  IconData _getStatusIcon() {
    switch (_permissionStatus) {
      case PermissionStatus.granted:
        return Icons.check_circle;
      case PermissionStatus.denied:
        return Icons.warning;
      case PermissionStatus.permanentlyDenied:
        return Icons.error;
      case PermissionStatus.restricted:
        return Icons.block;
      default:
        return Icons.help;
    }
  }
  
  String _getStatusText() {
    switch (_permissionStatus) {
      case PermissionStatus.granted:
        return 'Granted ✓';
      case PermissionStatus.denied:
        return 'Denied';
      case PermissionStatus.permanentlyDenied:
        return 'Permanently Denied';
      case PermissionStatus.restricted:
        return 'Restricted';
      default:
        return 'Unknown';
    }
  }
  
Future<void> _checkPermission() async {
  setState(() {
    _isLoading = true;
  });

  try {
    // Use authoritative wrapper
    final granted = await PermissionService.isMicrophoneGranted();

    setState(() {
      _permissionStatus = granted ? PermissionStatus.granted : PermissionStatus.denied;
      _status = granted ? 'Status: Granted ✓' : 'Status: Denied';
      _isLoading = false;
    });

    if (!granted) {
      // Only consult permission_handler for permanentlyDenied on non-iOS
      bool permanentlyDenied = false;
      try {
        if (!Platform.isIOS) {
          final phStatus = await Permission.microphone.status;
          permanentlyDenied = phStatus == PermissionStatus.permanentlyDenied;
        } else {
          permanentlyDenied = false;
        }
      } catch (e) {
        permanentlyDenied = false;
      }

      if (permanentlyDenied) _showPermanentlyDeniedDialog();
    }
  } catch (e) {
    setState(() {
      _status = 'Error: $e';
      _isLoading = false;
    });
  }
}
  
Future<void> _requestPermission() async {
  setState(() {
    _isLoading = true;
  });

  print('=== REQUESTING MICROPHONE PERMISSION (PermissionService) ===');

  try {
    // Use PermissionService for authoritative request
    final requested = await PermissionService.requestMicrophonePermission();
    final nowGranted = await PermissionService.isMicrophoneGranted();

    print('Permission request result: $requested');
    print('Permission check after request: $nowGranted');

    setState(() {
      _permissionStatus = nowGranted ? PermissionStatus.granted : PermissionStatus.denied;
      _status = nowGranted ? 'Granted ✓' : 'Denied';
      _isLoading = false;
    });

    if (nowGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Permission granted! ✓'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      // Only consult permission_handler for permanentlyDenied on non-iOS
      bool permanentlyDenied = false;
      try {
        if (!Platform.isIOS) {
          final phStatus = await Permission.microphone.status;
          permanentlyDenied = phStatus == PermissionStatus.permanentlyDenied;
        } else {
          permanentlyDenied = false;
        }
      } catch (e) {
        permanentlyDenied = false;
      }
      if (permanentlyDenied) _showPermanentlyDeniedDialog();
    }
  } catch (e) {
    setState(() {
      _status = 'Error requesting permission: $e';
      _isLoading = false;
    });
  }
}
  
  // Debug permissions (ChatGPT's diagnostic function)
  Future<void> _debugPermissions() async {
    setState(() {
      _isLoading = true;
      _status = 'Running debug diagnostics...';
    });
    
    try {
      // Call the comprehensive debug function
      await NativeAudioService.debugMicrophonePermissions();
      
      // Refresh status after debug using authoritative check
      final granted = await PermissionService.isMicrophoneGranted();
      setState(() {
        _permissionStatus = granted ? PermissionStatus.granted : PermissionStatus.denied;
        _status = 'Debug complete. Check console for full details.';
        _isLoading = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Debug complete! Check console for detailed logs.'),
          backgroundColor: Colors.purple,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _status = 'Debug error: $e';
        _isLoading = false;
      });
    }
  }
  
  // Native iOS permission request (ChatGPT's guaranteed solution)
  Future<void> _requestNativePermission() async {
    setState(() {
      _isLoading = true;
    });
    
    print('=== REQUESTING NATIVE iOS PERMISSION ===');
    
    try {
      // Use native AVAudioSession directly - this is guaranteed to work
      final granted = await NativeAudioService.requestMicrophoneNative();
      
      print('Native permission result: $granted');
      
      // Check status after native request via authoritative wrapper
      final nowGranted = await PermissionService.isMicrophoneGranted();
      print('Status after native request (authoritative): $nowGranted');

      setState(() {
        _permissionStatus = nowGranted ? PermissionStatus.granted : PermissionStatus.denied;
        _status = nowGranted ? 'Native request: GRANTED ✓' : 'Native request: DENIED';
        _isLoading = false;
      });
      
      if (granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Native permission granted! ✓ App should now appear in Settings.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Native permission denied. Check Settings > Privacy > Microphone.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _status = 'Native request error: $e';
        _isLoading = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Native request failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  Future<void> _testRecording() async {
    setState(() {
      _isLoading = true;
    });
    
    print('=== TESTING RECORDING ===');
    
    try {
      // Check permission first using authoritative check
      final granted = await PermissionService.isMicrophoneGranted();
      if (!granted) {
        // Check if permanently denied (only on non-iOS)
        bool permanentlyDenied = false;
        try {
          if (!Platform.isIOS) {
            final phStatus = await Permission.microphone.status;
            permanentlyDenied = phStatus == PermissionStatus.permanentlyDenied;
          } else {
            permanentlyDenied = false;
          }
        } catch (e) {
          permanentlyDenied = false;
        }
        
        if (permanentlyDenied) {
          setState(() {
            _permissionStatus = PermissionStatus.permanentlyDenied;
            _status = 'Cannot test: Permission permanently denied';
            _isLoading = false;
          });
          _showPermanentlyDeniedDialog();
          return;
        }
      }
      
      // Import the voice service
      final voiceService = VoiceRecordingService();
      
      // Request permission first
      final hasPermission = await voiceService.requestPermission();
      print('Has permission: $hasPermission');
      
      if (hasPermission) {
        // Try to start recording
        final success = await voiceService.startRecording();
        print('Recording started: $success');
        
        if (success) {
          // Wait a bit then stop
          await Future.delayed(const Duration(seconds: 2));
          final path = await voiceService.stopRecording();
          print('Recording stopped, path: $path');
          
          setState(() {
            _status = 'Recording test: ${path != null ? "SUCCESS ✓" : "FAILED"}';
            _isLoading = false;
          });
          
          if (path != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Recording test successful! ✓'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          setState(() {
            _status = 'Failed to start recording';
            _isLoading = false;
          });
        }
      } else {
        // Check status using authoritative check
        final nowGranted = await PermissionService.isMicrophoneGranted();
        setState(() {
          _permissionStatus = nowGranted ? PermissionStatus.granted : PermissionStatus.denied;
          _status = 'No permission for recording';
          _isLoading = false;
        });
        
        if (!nowGranted) {
          // Check if permanently denied (only on non-iOS)
          bool permanentlyDenied = false;
          try {
            if (!Platform.isIOS) {
              final phStatus = await Permission.microphone.status;
              permanentlyDenied = phStatus == PermissionStatus.permanentlyDenied;
            } else {
              permanentlyDenied = false;
            }
          } catch (e) {
            permanentlyDenied = false;
          }
          
          if (permanentlyDenied) {
            _showPermanentlyDeniedDialog();
          }
        }
      }
    } catch (e) {
      setState(() {
        _status = 'Error testing recording: $e';
        _isLoading = false;
      });
    }
  }
  
  void _showPermanentlyDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Microphone Permission Required'),
          content: const SingleChildScrollView(
            child: Text(
              'This app needs access to your microphone to record voice mantras. '
              'The permission has been permanently denied. Please enable microphone permission in your device settings.\n\n'
              'Steps to Enable Microphone:\n'
              '1. Tap "Open Settings" below\n'
              '2. Go to "Privacy & Security" → "Microphone"\n'
              '3. Find "Colab App Ui" in the list\n'
              '4. Enable the "Microphone" toggle\n'
              '5. Return to this app and try again\n\n'
              'Note: The microphone setting is in Privacy settings, not in the app-specific settings page.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openSettings();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primarySaffron,
                foregroundColor: AppColors.white,
              ),
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _openSettings() async {
    try {
      final opened = await openAppSettings();
      if (opened) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Opening Settings... Please enable microphone permission and return to the app.'),
            duration: Duration(seconds: 3),
            backgroundColor: Colors.blue,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open settings. Please manually go to Settings > Privacy > Microphone'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening settings: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
