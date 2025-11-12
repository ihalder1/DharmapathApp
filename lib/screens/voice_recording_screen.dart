import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/permission_service.dart';
import '../constants/app_colors.dart';
import '../services/voice_recording_service.dart';

class VoiceRecordingScreen extends StatefulWidget {
  final String songTitle;
  final String songArtist;
  
  const VoiceRecordingScreen({
    super.key,
    required this.songTitle,
    required this.songArtist,
  });

  @override
  State<VoiceRecordingScreen> createState() => _VoiceRecordingScreenState();
}

class _VoiceRecordingScreenState extends State<VoiceRecordingScreen>
    with TickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final VoiceRecordingService _voiceService = VoiceRecordingService();
  
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _hasRecording = false;
  String? _recordingPath;
  Duration _recordingDuration = Duration.zero;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;
  
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  
  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _requestPermissions();
  }
  
  void _setupAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));
  }
  
  Future<void> _requestPermissions() async {
    await PermissionService.requestMicrophonePermission();
  }
  
  Future<void> _startRecording() async {
    try {
      // Request microphone permission first using PermissionService
      final granted = await PermissionService.requestMicrophonePermission();
      
      if (granted) {
        // Start real recording using VoiceRecordingService
        final success = await _voiceService.startRecording();
        if (success) {
          setState(() {
            _isRecording = true;
            _recordingDuration = Duration.zero;
          });
          _pulseController.repeat(reverse: true);
          _startTimer();
        } else {
          _showErrorSnackBar('Failed to start recording. Please check microphone permissions.');
        }
      } else {
        // Authoritative check
        final nowGranted = await PermissionService.isMicrophoneGranted();
        if (!nowGranted) {
          // On non-iOS, consult permission_handler for permanentlyDenied
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
            _showPermissionDialog();
          } else {
            _showErrorSnackBar('Microphone permission denied. Cannot record.');
          }
        }
      }
    } catch (e) {
      _showErrorSnackBar('Failed to start recording: $e');
    }
  }
  
  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Microphone Permission Required'),
          content: const Text(
            'This app needs access to your microphone to record voice mantras. '
            'Please enable microphone permission in your device settings.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _stopRecording() async {
    try {
      // Stop real recording using VoiceRecordingService
      final path = await _voiceService.stopRecording();
      if (path != null) {
        _recordingPath = path;
        setState(() {
          _isRecording = false;
          _hasRecording = true;
        });
        _pulseController.stop();
        _pulseController.reset();
      } else {
        _showErrorSnackBar('Failed to stop recording.');
      }
    } catch (e) {
      _showErrorSnackBar('Failed to stop recording: $e');
    }
  }
  
  void _startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (_isRecording) {
        setState(() {
          _recordingDuration = Duration(seconds: _recordingDuration.inSeconds + 1);
        });
        _startTimer();
      }
    });
  }
  
  Future<void> _playRecording() async {
    if (_recordingPath != null) {
      try {
        // Validate file exists
        final file = File(_recordingPath!);
        if (!await file.exists()) {
          _showErrorSnackBar('Recording file not found. Please record again.');
          return;
        }
        
        // Check file size (should not be empty)
        final fileSize = await file.length();
        if (fileSize == 0) {
          _showErrorSnackBar('Recording file is empty. Please record again.');
          return;
        }
        
        // Configure audio session for playback on iOS
        if (Platform.isIOS) {
          try {
            const MethodChannel audioChannel = MethodChannel('app.channel.audio');
            await audioChannel.invokeMethod('configureAudioSessionForPlayback');
          } catch (e) {
            print('Warning: Could not configure audio session for playback: $e');
            // Continue anyway - audioplayers might handle it
          }
        }
        
        // Stop any current playback first
        await _audioPlayer.stop();
        
        // Play the recording
        await _audioPlayer.play(DeviceFileSource(_recordingPath!));
        setState(() {
          _isPlaying = true;
        });
        
        _audioPlayer.onDurationChanged.listen((duration) {
          if (mounted) {
            setState(() {
              _playbackDuration = duration;
            });
          }
        });
        
        _audioPlayer.onPositionChanged.listen((position) {
          if (mounted) {
            setState(() {
              _playbackPosition = position;
            });
          }
        });
        
        _audioPlayer.onPlayerComplete.listen((_) {
          if (mounted) {
            setState(() {
              _isPlaying = false;
              _playbackPosition = Duration.zero;
            });
          }
        });
      } catch (e) {
        print('Error playing recording: $e');
        if (mounted) {
          _showErrorSnackBar('Failed to play recording. The file may be corrupted. Please record again.');
        }
      }
    }
  }
  
  Future<void> _stopPlayback() async {
    await _audioPlayer.stop();
    setState(() {
      _isPlaying = false;
      _playbackPosition = Duration.zero;
    });
  }
  
  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.errorRed,
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _audioPlayer.dispose();
    _voiceService.dispose();
    super.dispose();
  }
  
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '$twoDigitMinutes:$twoDigitSeconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppColors.voiceGradient,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                // Header
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, color: AppColors.white),
                    ),
                    Expanded(
                      child: Text(
                        'Record Your Voice',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: AppColors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48), // Balance the back button
                  ],
                ),
                
                const SizedBox(height: 40),
                
                // Song Info
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.white.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        widget.songTitle,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'by ${widget.songArtist}',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.white.withOpacity(0.8),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 60),
                
                // Recording Visual
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _isRecording ? _pulseAnimation.value : 1.0,
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording 
                              ? AppColors.errorRed.withOpacity(0.3)
                              : AppColors.white.withOpacity(0.2),
                          border: Border.all(
                            color: _isRecording ? AppColors.errorRed : AppColors.white,
                            width: 4,
                          ),
                        ),
                        child: Icon(
                          _isRecording ? Icons.stop : Icons.mic,
                          size: 80,
                          color: _isRecording ? AppColors.errorRed : AppColors.white,
                        ),
                      ),
                    );
                  },
                ),
                
                const SizedBox(height: 40),
                
                // Recording Status
                Text(
                  _isRecording ? 'Recording...' : 'Tap to start recording',
                  style: TextStyle(
                    fontSize: 18,
                    color: AppColors.white.withOpacity(0.9),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Duration Display
                Text(
                  _formatDuration(_recordingDuration),
                  style: const TextStyle(
                    fontSize: 32,
                    color: AppColors.white,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                
                const SizedBox(height: 60),
                
                // Control Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Record/Stop Button
                    ElevatedButton(
                      onPressed: _isRecording ? _stopRecording : _startRecording,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isRecording ? AppColors.errorRed : AppColors.white,
                        foregroundColor: _isRecording ? AppColors.white : AppColors.primarySaffron,
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(20),
                      ),
                      child: Icon(
                        _isRecording ? Icons.stop : Icons.mic,
                        size: 32,
                      ),
                    ),
                    
                    // Play/Pause Button
                    if (_hasRecording)
                      ElevatedButton(
                        onPressed: _isPlaying ? _stopPlayback : _playRecording,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.white,
                          foregroundColor: AppColors.primarySaffron,
                          shape: const CircleBorder(),
                          padding: const EdgeInsets.all(20),
                        ),
                        child: Icon(
                          _isPlaying ? Icons.stop : Icons.play_arrow,
                          size: 32,
                        ),
                      ),
                  ],
                ),
                
                const SizedBox(height: 40),
                
                // Instructions
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: AppColors.white,
                        size: 24,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Recording Tips:',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.white.withOpacity(0.9),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '• Find a quiet environment\n• Speak clearly and at normal volume\n• Hold the device 6-8 inches from your mouth\n• Record for at least 30 seconds',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.white.withOpacity(0.8),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                
                const Spacer(),
                
                // Continue Button
                if (_hasRecording)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        // Navigate to next screen
                        Navigator.pushNamed(context, '/payment');
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.white,
                        foregroundColor: AppColors.primarySaffron,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Continue to Payment',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
