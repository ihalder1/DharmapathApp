import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../services/profile_service.dart';
import '../services/mantra_service.dart';
import '../services/voice_recording_service.dart';
import '../services/notification_service.dart';
import '../services/inferred_mantras_service.dart';
import '../models/mantra.dart';
import '../models/inferred_song.dart';
import 'permission_test_screen.dart';
import 'notification_screen.dart';
import 'login_screen.dart';
import 'payment_screen.dart';
import 'contact_us_screen.dart';

/// Synced mantra icons are stored under Documents/Media; resolve once per filename.
final Map<String, Future<String?>> _mantraLocalIconPathFutures = {};

Future<String?> _mantraLocalIconPathIfExists(String iconName) {
  if (kIsWeb) return Future<String?>.value(null);
  return _mantraLocalIconPathFutures.putIfAbsent(iconName, () async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = '${appDir.path}/Media';
      final primary = '$mediaDir/$iconName';
      if (await File(primary).exists()) return primary;
      if (iconName.endsWith('.png')) {
        final alt =
            '$mediaDir/${iconName.substring(0, iconName.length - 4)}.jpg';
        if (await File(alt).exists()) return alt;
      } else if (iconName.endsWith('.jpg')) {
        final alt =
            '$mediaDir/${iconName.substring(0, iconName.length - 4)}.png';
        if (await File(alt).exists()) return alt;
      }
    } catch (_) {
      // Fall back to assets
    }
    return null;
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentStep = 0;
  bool _isEditingPersonalInfo = false;
  bool _isLoading = false;
  bool _isMantraSelectionExpanded = false;
  bool _isRecordingsExpanded = false;
  bool _isMyMantrasExpanded = false;

  // Notifications
  int _unreadNotificationCount = 0;

  String? _photoUrl;

  // Mantra System
  List<Mantra> _mantras = [];
  List<Mantra> _filteredMantras = [];
  bool _isLoadingMantras = false;

  final InferredMantrasService _inferredMantrasService =
      InferredMantrasService();
  List<InferredSong> _inferredSongs = [];
  final Map<String, String> _inferredLocalPaths = {};
  bool _loadingInferredSongs = false;
  String? _inferredSongsError;
  final Set<String> _inferredDownloadingIds = {};
  InferredSong? _currentInferredPlaying;
  final AudioPlayer _audioPlayer = AudioPlayer();
  Mantra? _currentlyPlaying;
  bool _isPlaying = false;
  final TextEditingController _searchController = TextEditingController();

  // Voice Recording System
  final VoiceRecordingService _voiceService = VoiceRecordingService();
  String _selectedLanguage = 'English';
  bool _isRecording = false;
  bool _isPlayingRecording = false;
  String? _currentlyPlayingPath; // Track which file is currently playing
  String? _currentRecordingPath;
  final AudioPlayer _recordingPlayer = AudioPlayer();

  /// Tracks step transitions so we refresh GET voice/recordings when entering Record Voice.
  int? _prevStepForVoiceRefresh;

  int? _profileTotalRecordings;
  int? _profileTotalInferredSongs;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;
  static const int _maxRecordingSeconds = 60;

  // Personal Info Data - Initialize with default values
  Map<String, dynamic> _personalInfo = {
    'fullName': '',
    'email': '',
    'location': 'Add Location',
    'mobile': 'Add Phone Number',
    'gender': 'Prefer not to say',
  };

  final List<Map<String, dynamic>> _steps = [
    {
      'title': 'Select Mantras',
      'icon': Icons.music_note_outlined,
      'description': 'Choose your Mantras',
    },
    {
      'title': 'Cart',
      'icon': Icons.shopping_cart_outlined,
      'description': 'Complete your purchase',
    },
    {
      'title': 'Record Voice',
      'icon': Icons.mic_outlined,
      'description': 'Record your voice',
    },
    {
      'title': 'My Mantra',
      'icon': Icons.person_outline,
      'description': 'View your mantras',
    },
  ];

  @override
  void initState() {
    super.initState();

    // Check if user is authenticated before loading data
    final authService = Provider.of<AuthService>(context, listen: false);
    if (!authService.isLoggedIn || authService.accessToken == null) {
      // If not authenticated, redirect to login
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const LoginScreen()),
        );
      });
      return;
    }

    // Initialize with authenticated user data immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePersonalInfo();
    });
    _loadProfileData();
    _loadMantras();
    _searchController.addListener(_filterMantras);
    _loadRecordings();
    _loadRecordingAndSongTotals();
    _loadUnreadNotificationCount();
    // Don't request permission on startup - request when user actually tries to record
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _audioPlayer.dispose();
    _recordingPlayer.dispose();
    _searchController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  Future<void> _loadRecordingAndSongTotals() async {
    final totals = await ProfileService.fetchRecordingAndSongTotals();
    if (!mounted) return;
    setState(() {
      if (totals != null) {
        _profileTotalRecordings = totals.totalRecordings;
        _profileTotalInferredSongs = totals.totalInferredSongs;
      }
    });
  }

  // Initialize personal info with authenticated user data
  void _initializePersonalInfo() {
    final authService = Provider.of<AuthService>(context, listen: false);
    final user = authService.currentUser;

    if (user != null) {
      setState(() {
        _personalInfo = {
          'fullName': user.name,
          'email': user.email,
          'location': _personalInfo['location'] ?? 'Add Location',
          'mobile': _personalInfo['mobile'] ?? 'Add Phone Number',
          'gender': _personalInfo['gender'] ?? 'Prefer not to say',
        };
        _photoUrl = user.photoUrl ?? _photoUrl;
      });
    }
  }

  // Load profile data from API
  Future<void> _loadProfileData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // First, initialize with authenticated user data
      final authService = Provider.of<AuthService>(context, listen: false);
      final currentUser = authService.currentUser;

      if (currentUser != null) {
        setState(() {
          _personalInfo['fullName'] =
              _personalInfo['fullName']?.isNotEmpty == true
              ? _personalInfo['fullName']
              : currentUser.name;
          _personalInfo['email'] = _personalInfo['email']?.isNotEmpty == true
              ? _personalInfo['email']
              : currentUser.email;
          _photoUrl = _photoUrl ?? currentUser.photoUrl;
        });
      }

      // Then try to get full profile from API
      final profileData = await ProfileService.getProfile();
      if (profileData != null) {
        setState(() {
          _personalInfo = {
            'fullName': (profileData['fullName']?.toString().isNotEmpty == true)
                ? profileData['fullName']
                : (_personalInfo['fullName']?.toString().isNotEmpty == true
                      ? _personalInfo['fullName']
                      : ''),
            'email': (profileData['email']?.toString().isNotEmpty == true)
                ? profileData['email']
                : (_personalInfo['email']?.toString().isNotEmpty == true
                      ? _personalInfo['email']
                      : ''),
            'location':
                (profileData['location'] != null &&
                    profileData['location'].toString().trim().isNotEmpty)
                ? profileData['location']
                : 'Add Location',
            'mobile':
                (profileData['mobile'] != null &&
                    profileData['mobile'].toString().trim().isNotEmpty)
                ? profileData['mobile']
                : 'Add Phone Number',
            'gender':
                (profileData['gender'] != null &&
                    profileData['gender'].toString().trim().isNotEmpty)
                ? profileData['gender']
                : 'Prefer not to say',
          };
          _photoUrl = profileData['photoUrl'] ?? _photoUrl;
        });
      } else {
        // If profile API fails, ensure we at least have authenticated user data and default values
        if (currentUser != null) {
          setState(() {
            _personalInfo['fullName'] =
                _personalInfo['fullName']?.isNotEmpty == true
                ? _personalInfo['fullName']
                : currentUser.name;
            _personalInfo['email'] = _personalInfo['email']?.isNotEmpty == true
                ? _personalInfo['email']
                : currentUser.email;
            _personalInfo['location'] =
                _personalInfo['location']?.isNotEmpty == true
                ? _personalInfo['location']
                : 'Add Location';
            _personalInfo['mobile'] =
                _personalInfo['mobile']?.isNotEmpty == true
                ? _personalInfo['mobile']
                : 'Add Phone Number';
            _personalInfo['gender'] =
                _personalInfo['gender']?.isNotEmpty == true
                ? _personalInfo['gender']
                : 'Prefer not to say';
            _photoUrl = _photoUrl ?? currentUser.photoUrl;
          });
        }
      }
    } catch (e) {
      // Fallback to authenticated user data with default values
      final authService = Provider.of<AuthService>(context, listen: false);
      final currentUser = authService.currentUser;
      if (currentUser != null) {
        setState(() {
          _personalInfo['fullName'] =
              _personalInfo['fullName']?.isNotEmpty == true
              ? _personalInfo['fullName']
              : currentUser.name;
          _personalInfo['email'] = _personalInfo['email']?.isNotEmpty == true
              ? _personalInfo['email']
              : currentUser.email;
          _personalInfo['location'] =
              _personalInfo['location']?.isNotEmpty == true
              ? _personalInfo['location']
              : 'Add Location';
          _personalInfo['mobile'] = _personalInfo['mobile']?.isNotEmpty == true
              ? _personalInfo['mobile']
              : 'Add Phone Number';
          _personalInfo['gender'] = _personalInfo['gender']?.isNotEmpty == true
              ? _personalInfo['gender']
              : 'Prefer not to say';
          _photoUrl = _photoUrl ?? currentUser.photoUrl;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Load mantras from JSON metadata (full: parallel catalog sync + purchased counts).
  Future<void> _loadMantras({bool syncCatalog = true}) async {
    if (syncCatalog) {
      setState(() {
        _isLoadingMantras = true;
      });
    }

    try {
      final mantras = await MantraService.loadMantras(syncCatalog: syncCatalog);
      if (syncCatalog) {
        // Allow icons written during sync to be resolved on disk (avoid stale memoized misses).
        _mantraLocalIconPathFutures.clear();
      }

      if (!mounted) return;
      setState(() {
        _applyMantraList(mantras);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load mantras: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted && syncCatalog) {
        setState(() {
          _isLoadingMantras = false;
        });
      }
    }
  }

  // Filter mantras based on search query
  void _filterMantras() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredMantras = _mantras;
      } else {
        _filteredMantras = _mantras.where((mantra) {
          return mantra.name.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  List<Mantra> _sortMantrasByPurchase(List<Mantra> mantras) {
    final sorted = List<Mantra>.from(mantras);
    sorted.sort((a, b) {
      if (a.isBought != b.isBought) {
        return a.isBought ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  void _applyMantraList(List<Mantra> mantras) {
    final sorted = _sortMantrasByPurchase(mantras);
    _mantras = sorted;

    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      _filteredMantras = sorted;
    } else {
      _filteredMantras = sorted.where((mantra) {
        return mantra.name.toLowerCase().contains(query);
      }).toList();
    }
  }

  // Helper widget to load mantra icon (network URL with disk cache, Documents/Media,
  // or bundled assets/Media).
  Widget _buildMantraIcon({
    required String iconName,
    required double size,
    required Color iconColor,
    BoxFit fit = BoxFit.cover,
    BorderRadius? borderRadius,
  }) {
    final trimmed = iconName.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final px = (size * dpr).round().clamp(48, 1024);
      return CachedNetworkImage(
        imageUrl: trimmed,
        width: size,
        height: size,
        fit: fit,
        memCacheWidth: px,
        memCacheHeight: px,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) => Icon(
          Icons.music_note,
          size: size * 0.85,
          color: iconColor.withValues(alpha: 0.35),
        ),
        errorWidget: (context, url, error) =>
            Icon(Icons.music_note, size: size, color: iconColor),
      );
    }

    // Try to get base name without extension
    String baseName = iconName;
    if (iconName.contains('.')) {
      baseName = iconName.substring(0, iconName.lastIndexOf('.'));
    }

    Widget assetIcon() {
      return Image.asset(
        'assets/Media/$iconName',
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          if (iconName.endsWith('.png')) {
            final jpgName = '$baseName.jpg';
            return Image.asset(
              'assets/Media/$jpgName',
              fit: fit,
              errorBuilder: (context, error2, stackTrace2) {
                return Icon(Icons.music_note, size: size, color: iconColor);
              },
            );
          } else if (iconName.endsWith('.jpg')) {
            final pngName = '$baseName.png';
            return Image.asset(
              'assets/Media/$pngName',
              fit: fit,
              errorBuilder: (context, error2, stackTrace2) {
                return Icon(Icons.music_note, size: size, color: iconColor);
              },
            );
          }
          return Icon(Icons.music_note, size: size, color: iconColor);
        },
      );
    }

    return FutureBuilder<String?>(
      future: _mantraLocalIconPathIfExists(iconName),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Icon(
            Icons.music_note,
            size: size * 0.85,
            color: iconColor.withValues(alpha: 0.35),
          );
        }
        final path = snapshot.data;
        if (path != null) {
          return Image.file(
            File(path),
            width: size,
            height: size,
            fit: fit,
            errorBuilder: (context, error, stackTrace) => assetIcon(),
          );
        }
        return assetIcon();
      },
    );
  }

  // Load recordings from local storage and sync with backend
  Future<void> _loadRecordings() async {
    await _voiceService.loadRecordings();
    setState(() {});
  }

  // Load unread notification count (GET /auth/profile/notifications).
  Future<void> _loadUnreadNotificationCount() async {
    try {
      await NotificationService.refresh();
      final count = NotificationService.unreadCount;
      if (mounted) {
        setState(() {
          _unreadNotificationCount = count;
        });
      }
    } catch (e) {}
  }

  // Voice recording methods
  // Check if user has purchased at least one mantra
  bool _hasPurchasedMantras() {
    return _mantras.any((mantra) => mantra.isBought);
  }

  Future<void> _startRecording() async {
    // Check if user has purchased at least one mantra
    if (!_hasPurchasedMantras()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'You have to purchase at least one song first to start recording your voice',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // startRecording() handles permission checking internally, so we don't need to check here
    final success = await _voiceService.startRecording();
    if (success) {
      setState(() {
        _isRecording = true;
        _currentRecordingPath = null; // Clear previous recording
        _recordingSeconds = 0;
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() {
          _recordingSeconds += 1;
        });
        if (_recordingSeconds >= _maxRecordingSeconds) {
          _recordingTimer?.cancel();
          _recordingTimer = null;
          _stopRecording();
        }
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to start recording. Please check microphone permissions.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showPermissionDialog() {
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
                openAppSettings();
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

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    final path = await _voiceService.stopRecording();
    if (path != null) {
      setState(() {
        _isRecording = false;
        _currentRecordingPath = path;
        _recordingSeconds = 0;
      });
    } else {
      setState(() {
        _isRecording = false;
        _recordingSeconds = 0;
      });
    }
  }

  String _formatRecordingTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(1)}:${s.toString().padLeft(2, '0')}';
  }

  // Cleanup unsaved recording when leaving the step
  Future<void> _cleanupUnsavedRecording() async {
    if (_currentRecordingPath != null) {
      // Cancel the recording (this will delete the temporary file)
      await _voiceService.cancelRecording();
      setState(() {
        _currentRecordingPath = null;
      });
    }
  }

  Future<void> _playRecording(String path) async {
    if (path.isEmpty) return;
    try {
      // If already playing this file, stop it
      if (_isPlayingRecording && _currentlyPlayingPath == path) {
        await _recordingPlayer.stop();
        setState(() {
          _isPlayingRecording = false;
          _currentlyPlayingPath = null;
        });
        return;
      }

      // If playing a different file, stop it first
      if (_isPlayingRecording && _currentlyPlayingPath != path) {
        await _recordingPlayer.stop();
      }

      // Validate file exists
      final file = File(path);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Recording file not found at:\n${path.split('/').last}\n\nFile may need to be re-downloaded from backend.',
              ),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Check file size (should not be empty)
      final fileSize = await file.length();
      if (fileSize == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Recording file is empty (0 bytes). Please record again.',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Configure audio session for playback on iOS
      if (Platform.isIOS) {
        try {
          const MethodChannel audioChannel = MethodChannel('app.channel.audio');
          await audioChannel.invokeMethod('configureAudioSessionForPlayback');
        } catch (e) {
          // Continue anyway - audioplayers might handle it
        }
      }

      // Play the actual recording file
      await _recordingPlayer.play(DeviceFileSource(path));
      setState(() {
        _isPlayingRecording = true;
        _currentlyPlayingPath = path;
      });

      // Listen for playback completion
      _recordingPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _isPlayingRecording = false;
            _currentlyPlayingPath = null;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPlayingRecording = false;
          _currentlyPlayingPath = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play recording: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteRecording(VoiceRecording recording) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Recording'),
        content: Text(
          'Are you sure you want to delete "${recording.name}"? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Stop playback if this recording is playing
    if (_isPlayingRecording && _currentlyPlayingPath == recording.filePath) {
      await _recordingPlayer.stop();
      setState(() {
        _isPlayingRecording = false;
        _currentlyPlayingPath = null;
      });
    }

    // Delete the recording
    final success = await _voiceService.deleteRecording(recording);

    if (success) {
      setState(() {
        // Reload recordings to update the list
        _loadRecordings();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording deleted successfully'),
            backgroundColor: AppColors.successGreen,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to delete recording'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showSaveDialog() async {
    if (_currentRecordingPath == null) return;

    final nameController = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Save Recording'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Recording Name',
                  hintText: 'Enter a unique name for your recording',
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) {
                  if (errorText != null) {
                    setDialogState(() {
                      errorText = null;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              Text(
                'Language: $_selectedLanguage',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _currentRecordingPath = null;
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  setDialogState(() {
                    errorText = 'Please enter a name';
                  });
                  return;
                }

                if (!_voiceService.isNameUnique(name)) {
                  setDialogState(() {
                    errorText =
                        'This name already exists. Please choose a different name.';
                  });
                  return;
                }

                Navigator.pop(dialogContext);

                // Show loading - use the main context, not dialog context
                if (!mounted) return;

                // Store ScaffoldMessenger BEFORE async operation
                final scaffoldMessenger = ScaffoldMessenger.of(context);

                BuildContext? loadingContext;
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (dialogCtx) {
                    loadingContext = dialogCtx;
                    return const Center(child: CircularProgressIndicator());
                  },
                );

                final result = await _voiceService.saveRecording(
                  name,
                  _selectedLanguage,
                );
                final success = result['success'] as bool? ?? false;
                final backendSuccess =
                    result['backendSuccess'] as bool? ?? false;
                final errorMessage = result['errorMessage'] as String?;

                // Close loading dialog safely
                if (mounted && loadingContext != null) {
                  try {
                    Navigator.of(loadingContext!, rootNavigator: true).pop();
                  } catch (e) {}
                }

                // Only show messages if widget is still mounted
                if (!mounted) return;

                if (success) {
                  // Local save succeeded (backend may or may not have succeeded).
                  // Reload recordings to ensure list is up to date.
                  await _voiceService.loadRecordings();

                  if (mounted) {
                    setState(() {
                      _currentRecordingPath = null;
                      _isPlayingRecording = false; // Reset playback state
                    });

                    if (backendSuccess) {
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                          content: Text('Recording saved successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    } else {
                      scaffoldMessenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            'Saved locally. Upload failed: ${errorMessage ?? "unknown error"}',
                          ),
                          backgroundColor: Colors.orange,
                          duration: const Duration(seconds: 5),
                        ),
                      );
                    }
                  }
                } else {
                  // Local save failed
                  scaffoldMessenger.showSnackBar(
                    SnackBar(
                      content: Text(errorMessage ?? 'Failed to save recording'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Whenever user switches to "Record your voice" (step 2), refresh list from GET .../voice/recordings
    if (_currentStep == 2) {
      if (_prevStepForVoiceRefresh != 2) {
        _prevStepForVoiceRefresh = 2;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await _voiceService.processPendingUploadsInBackground();
          await _loadRecordings();
          if (mounted) setState(() {});
        });
      }
    } else {
      _prevStepForVoiceRefresh = _currentStep;
    }

    // If recordings is expanded, show it as full screen (check first, regardless of step)
    if (_isRecordingsExpanded) {
      return _buildExpandedRecordingsStep();
    }

    // If My Mantras is expanded, show it as full screen
    if (_isMyMantrasExpanded) {
      return _buildExpandedMyMantrasStep();
    }

    // If mantra selection is expanded, show it as full screen
    if (_currentStep == 0 && _isMantraSelectionExpanded) {
      return _buildExpandedMantraSelectionStep();
    }

    // If we're on the voice recording step, return it as a full screen
    if (_currentStep == 2) {
      return _buildVoiceRecordingStep();
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // flex: 0 = only intrinsic height; Expanded below gets the rest (avoids 50/50 split)
            Flexible(
              flex: 0,
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(),
                    _buildPersonalInfoCard(),
                    const SizedBox(height: 4),
                    _buildStepIndicator(),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),

            // Content Area - Scrollable
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: (_isLoading && _currentStep != 0)
                    ? const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.primarySaffron,
                          ),
                        ),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: _buildStepContent(),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Column(
        children: [
          // User Info Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // App logo — tap for About (notifications: profile photo in card below)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _showAboutAppDialog,
                  borderRadius: BorderRadius.circular(8),
                  child: Tooltip(
                    message: 'About this app',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/icon/app_icon.png',
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Welcome, email, Contact Us
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Welcome, ${_personalInfo['fullName']}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        height: 1.2,
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            _personalInfo['email'],
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              height: 1.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const ContactUsScreen(),
                              ),
                            );
                          },
                          child: const Text(
                            'Contact Us',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.primarySaffron,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _showLogoutDialog(context),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(
                  Icons.logout,
                  color: AppColors.textSecondary,
                  size: 22,
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // App title
          const Text(
            'MantraSutra - मन्त्रसूत्र',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
              height: 1.15,
            ),
          ),
          Text(
            'The Science of Sacred Sounds',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _steps.asMap().entries.map((entry) {
          int index = entry.key;
          Map<String, dynamic> step = entry.value;
          bool isActive = index <= _currentStep;
          bool isCompleted = index < _currentStep;

          return Expanded(
            child: GestureDetector(
              onTap: () {
                final prevStep = _currentStep;
                setState(() {
                  _currentStep = index;
                });
                if (index == 3) {
                  _loadInferredSongs();
                }
                if (index == 0 && prevStep != 0) {
                  _loadRecordingAndSongTotals();
                }
              },
              child: Column(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.primarySaffron
                          : AppColors.lightSaffron,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primarySaffron,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      step['icon'],
                      color: isActive
                          ? AppColors.white
                          : AppColors.textSecondary,
                      size: 17,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    step['title'],
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isActive
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPersonalInfoCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(child: _buildProfilePictureSection()),
          const SizedBox(height: 4),
          _buildNestedPersonalInfoCard(),
          const SizedBox(height: 4),
          _buildStatisticsRow(),
        ],
      ),
    );
  }

  Widget _buildProfilePictureSection() {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const NotificationScreen()),
        );
        if (mounted) _loadUnreadNotificationCount();
      },
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.primarySaffron, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.lightSaffron,
              backgroundImage: (_photoUrl != null && _photoUrl!.isNotEmpty)
                  ? NetworkImage(_photoUrl!)
                  : null,
              child: (_photoUrl == null || _photoUrl!.isEmpty)
                  ? Icon(
                      _personalInfo['gender'] == 'Female'
                          ? Icons.person_2
                          : Icons.person,
                      size: 24,
                      color: AppColors.primarySaffron,
                    )
                  : null,
            ),
          ),
          if (_unreadNotificationCount > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                child: Text(
                  _unreadNotificationCount > 9
                      ? '9+'
                      : '$_unreadNotificationCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatisticsRow() {
    final recordings = _profileTotalRecordings;
    final songs = _profileTotalInferredSongs;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildStatisticItem(
          'RECORDINGS',
          recordings == null ? '—' : '$recordings',
        ),
        _buildStatisticItem('SONGS', songs == null ? '—' : '$songs'),
      ],
    );
  }

  Widget _buildStatisticItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildNestedPersonalInfoCard() {
    return Column(
      children: [
        // Row 1: Steps 1 and 2
        Row(
          children: [
            Expanded(
              child: _buildStepBox(
                1,
                'Select & Add',
                'Pick your mantra and add it to the cart.',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStepBox(
                2,
                'Checkout',
                'Complete your payment in the Cart tab.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Row 2: Steps 3 and 4
        Row(
          children: [
            Expanded(
              child: _buildStepBox(
                3,
                'Record Voice',
                'Submit your voice sample in the Record Voice tab.',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStepBox(
                4,
                'Download',
                'Access your file from the \'My Mantras\' section.',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepBox(int number, String title, String description) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.primarySaffron,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.5),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(
              fontSize: 10,
              color: Colors.black.withOpacity(0.8),
              height: 1.25,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  void _showEditPersonalInfoDialog() {
    final nameController = TextEditingController(
      text: _personalInfo['fullName'],
    );
    final locationController = TextEditingController(
      text: _personalInfo['location'],
    );
    final mobileController = TextEditingController(
      text: _personalInfo['mobile'],
    );
    String initialGender = _personalInfo['gender'] ?? 'Prefer not to say';
    // Normalize gender value to match dropdown options
    if (initialGender != 'Male' &&
        initialGender != 'Female' &&
        initialGender != 'Prefer not to say') {
      initialGender = 'Prefer not to say';
    }

    showDialog(
      context: context,
      builder: (context) {
        String selectedGender = initialGender;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Edit Personal Information'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: locationController,
                    decoration: const InputDecoration(
                      labelText: 'Location',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: mobileController,
                    decoration: const InputDecoration(
                      labelText: 'Mobile',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedGender,
                    decoration: const InputDecoration(
                      labelText: 'Gender',
                      border: OutlineInputBorder(),
                    ),
                    items: const ['Male', 'Female', 'Prefer not to say'].map((
                      String value,
                    ) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setDialogState(() {
                          selectedGender = newValue;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  // Store the selected gender before closing dialog
                  final finalGender = selectedGender;
                  Navigator.pop(context);

                  setState(() {
                    _isLoading = true;
                  });

                  try {
                    // Update profile via API
                    final success = await ProfileService.updateProfile(
                      fullName: nameController.text,
                      location: locationController.text,
                      mobile: mobileController.text,
                      gender: finalGender,
                    );

                    if (success) {
                      // Update local state with the values we just saved
                      final updatedLocation = locationController.text.trim();
                      final updatedMobile = mobileController.text.trim();

                      setState(() {
                        _personalInfo['fullName'] = nameController.text.trim();
                        _personalInfo['location'] = updatedLocation.isEmpty
                            ? 'Add Location'
                            : updatedLocation;
                        _personalInfo['mobile'] = updatedMobile.isEmpty
                            ? 'Add Phone Number'
                            : updatedMobile;
                        _personalInfo['gender'] = finalGender;
                      });

                      // Don't reload from API immediately - preserve the values we just saved
                      // The API might not return them immediately, so we keep our updated values

                      // Show success message
                      if (mounted && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Personal information updated successfully',
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    } else {
                      // Show error message
                      if (mounted && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Failed to update profile. Please check your connection and try again.',
                            ),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  } catch (e) {
                    if (mounted && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error updating profile: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } finally {
                    setState(() {
                      _isLoading = false;
                    });
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _loadInferredSongs() async {
    setState(() {
      _loadingInferredSongs = true;
      _inferredSongsError = null;
    });
    try {
      final list = await _inferredMantrasService.fetchInferredSongs();
      final paths = <String, String>{};
      for (final s in list) {
        final p = await _inferredMantrasService.localPathIfExists(s.inferredId);
        if (p != null) paths[s.inferredId] = p;
      }
      if (!mounted) return;
      setState(() {
        _inferredSongs = list;
        _inferredLocalPaths
          ..clear()
          ..addAll(paths);
        _loadingInferredSongs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _inferredSongsError = e.toString();
        _loadingInferredSongs = false;
      });
    }
  }

  Future<void> _downloadInferredSong(InferredSong song) async {
    if (_inferredDownloadingIds.contains(song.inferredId)) return;
    setState(() => _inferredDownloadingIds.add(song.inferredId));
    try {
      var path =
          _inferredLocalPaths[song.inferredId] ??
          await _inferredMantrasService.localPathIfExists(song.inferredId);
      if (path != null) {
        if (mounted) {
          setState(() => _inferredLocalPaths[song.inferredId] = path!);
        }
        return;
      }

      final url = await _inferredMantrasService.fetchDownloadUrl(
        song.inferredId,
      );
      if (url == null || url.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not get a download link for this mantra.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      path = await _inferredMantrasService.downloadInferredMp3(
        inferredId: song.inferredId,
        downloadUrl: url,
      );

      if (!mounted) return;
      if (path != null) {
        setState(() => _inferredLocalPaths[song.inferredId] = path!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved "${song.displayTitle}" for playback.'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download failed. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _inferredDownloadingIds.remove(song.inferredId));
      }
    }
  }

  String _inferredSongExportFileName(InferredSong song) {
    final base = song.songId.trim().isNotEmpty
        ? song.songId.trim()
        : song.inferredId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-.]'), '_');
    return base.toLowerCase().endsWith('.mp3') ? base : '$base.mp3';
  }

  Future<String?> _resolveInferredSongLocalPath(InferredSong song) async {
    final path =
        _inferredLocalPaths[song.inferredId] ??
        await _inferredMantrasService.localPathIfExists(song.inferredId);
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) return null;
    return path;
  }

  Future<void> _saveInferredSongToDevice(InferredSong song, String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final fileName = _inferredSongExportFileName(song);
      final dialogTitle = Platform.isIOS
          ? 'Save to Files'
          : 'Save mantra to device';

      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['mp3'],
        bytes: bytes,
      );

      if (!mounted) return;
      if (savedPath != null && savedPath.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Platform.isIOS
                  ? 'Mantra saved to Files.'
                  : 'Mantra saved to your device.',
            ),
            backgroundColor: AppColors.successGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _openSystemShareForInferredSong(
    InferredSong song,
    String path,
  ) async {
    try {
      await Share.shareXFiles([
        XFile(
          path,
          mimeType: 'audio/mpeg',
          name: _inferredSongExportFileName(song),
        ),
      ], text: song.displayTitle);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Share failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _shareInferredSong(InferredSong song) async {
    final path = await _resolveInferredSongLocalPath(song);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Download the mantra in the app first, then use Share.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    final saveTitle = Platform.isIOS ? 'Save to Files' : 'Save to device';
    final saveSubtitle = Platform.isIOS
        ? 'Save this mantra in the Files app'
        : 'Save this mantra to your phone storage';

    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  song.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  Platform.isIOS ? Icons.folder_outlined : Icons.save_alt,
                  color: AppColors.primarySaffron,
                ),
                title: Text(
                  saveTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(saveSubtitle),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _saveInferredSongToDevice(song, path);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.share_outlined,
                  color: AppColors.primarySaffron,
                ),
                title: const Text(
                  'Share to other apps',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text('Google Drive, Messages, Bluetooth, etc.'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _openSystemShareForInferredSong(song, path);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteInferredSong(InferredSong song) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Mantra'),
        content: Text(
          'Are you sure you want to delete "${song.myMantrasCardTitle}"? '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    if (_currentInferredPlaying == song && _isPlaying) {
      await _audioPlayer.stop();
      setState(() {
        _isPlaying = false;
        _currentInferredPlaying = null;
      });
    }

    try {
      final success = await _inferredMantrasService.deleteInferredSong(
        transactionId: song.transactionId,
        songId: song.songId,
      );

      if (!success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to delete mantra'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      await _inferredMantrasService.removeLocalCache(song.inferredId);

      if (!mounted) return;
      setState(() {
        _inferredSongs.removeWhere((s) => s.inferredId == song.inferredId);
        _inferredLocalPaths.remove(song.inferredId);
        _inferredDownloadingIds.remove(song.inferredId);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mantra deleted successfully'),
          backgroundColor: AppColors.successGreen,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete mantra: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _playInferredMantra(InferredSong song) async {
    final path = _inferredLocalPaths[song.inferredId];
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) return;

    try {
      if (_currentInferredPlaying == song && _isPlaying) {
        await _audioPlayer.pause();
        setState(() {
          _isPlaying = false;
        });
      } else {
        if (_isPlaying) {
          await _audioPlayer.stop();
        }

        if (Platform.isIOS) {
          try {
            const MethodChannel audioChannel = MethodChannel(
              'app.channel.audio',
            );
            await audioChannel.invokeMethod('configureAudioSessionForPlayback');
          } catch (_) {}
        }

        await _audioPlayer.play(DeviceFileSource(path));
        setState(() {
          _currentlyPlaying = null;
          _currentInferredPlaying = song;
          _isPlaying = true;
        });

        _audioPlayer.onPlayerComplete.listen((_) {
          if (mounted) {
            setState(() {
              _isPlaying = false;
              _currentInferredPlaying = null;
            });
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playback error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Audio playback methods
  Future<void> _playMantra(Mantra mantra) async {
    try {
      if (_currentlyPlaying == mantra && _isPlaying) {
        // Pause current mantra
        await _audioPlayer.pause();
        setState(() {
          _isPlaying = false;
        });
      } else {
        // Stop current mantra if playing
        if (_isPlaying) {
          await _audioPlayer.stop();
        }

        setState(() {
          _currentInferredPlaying = null;
        });

        // Play new mantra
        String assetPath = 'Media/${mantra.mantraFile}';

        try {
          await _audioPlayer.play(AssetSource(assetPath));
          setState(() {
            _currentlyPlaying = mantra;
            _isPlaying = true;
          });

          // Listen for completion
          _audioPlayer.onPlayerComplete.listen((_) {
            setState(() {
              _isPlaying = false;
              _currentlyPlaying = null;
            });
          });
        } catch (e) {
          // Show error to user
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Unable to play ${mantra.name}. Audio file not found.',
                ),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error playing mantra: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopAudio() async {
    try {
      await _audioPlayer.stop();
      setState(() {
        _isPlaying = false;
        _currentlyPlaying = null;
      });
    } catch (e) {}
  }

  void _showCartLimitSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'You can add up to ${MantraService.maxCartTotalQuantity} mantras to your cart.',
        ),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _addToCart(Mantra mantra) async {
    final added = await MantraService.addToCart(mantra);
    if (!added) {
      _showCartLimitSnackBar();
      return;
    }
    setState(() {
      // Update the mantra in our local list
      final index = _mantras.indexWhere((m) => m.name == mantra.name);
      if (index != -1) {
        _mantras[index] = _mantras[index].copyWith(isInCart: true);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${mantra.name} added to cart'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _removeFromCart(Mantra mantra) async {
    await MantraService.removeFromCart(mantra);
    setState(() {
      // Update the mantra in our local list
      final index = _mantras.indexWhere((m) => m.name == mantra.name);
      if (index != -1) {
        _mantras[index] = _mantras[index].copyWith(isInCart: false);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${mantra.name} removed from cart'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _incrementCartQuantity(Mantra mantra) async {
    final incremented = await MantraService.incrementCartQuantity(mantra);
    if (!incremented) {
      _showCartLimitSnackBar();
      return;
    }
    setState(() {
      final index = _mantras.indexWhere((m) => m.name == mantra.name);
      if (index != -1 && !_mantras[index].isInCart) {
        _mantras[index] = _mantras[index].copyWith(isInCart: true);
      }
    });
  }

  Future<void> _decrementCartQuantity(Mantra mantra) async {
    final wasInCart = MantraService.isInCart(mantra);
    await MantraService.decrementCartQuantity(mantra);
    setState(() {
      final index = _mantras.indexWhere((m) => m.name == mantra.name);
      if (index != -1 && wasInCart && !MantraService.isInCart(mantra)) {
        _mantras[index] = _mantras[index].copyWith(isInCart: false);
      }
    });
  }

  Widget _buildCartLimitNote() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'Note: You can add up to ${MantraService.maxCartTotalQuantity} items to your cart.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          height: 1.3,
          color: AppColors.white.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _buildCartQuantityStepper(Mantra mantra, int quantity) {
    final atCartLimit =
        MantraService.getCartTotalQuantity() >=
        MantraService.maxCartTotalQuantity;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _decrementCartQuantity(mantra),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Icon(Icons.remove, size: 18, color: AppColors.errorRed),
              ),
            ),
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 24),
            alignment: Alignment.center,
            child: Text(
              '$quantity',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: atCartLimit ? null : () => _incrementCartQuantity(mantra),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Icon(
                  Icons.add,
                  size: 18,
                  color: atCartLimit
                      ? AppColors.textSecondary.withValues(alpha: 0.4)
                      : AppColors.successGreen,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addAllNonPurchasedToCart() async {
    final notInCart = _filteredMantras.where((m) => !m.isInCart).toList();

    if (notInCart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All visible mantras are already in cart'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    int addedCount = 0;
    var hitLimit = false;
    for (var mantra in notInCart) {
      final added = await MantraService.addToCart(mantra);
      if (!added) {
        hitLimit = true;
        break;
      }
      final index = _mantras.indexWhere((m) => m.name == mantra.name);
      if (index != -1) {
        _mantras[index] = _mantras[index].copyWith(isInCart: true);
      }
      addedCount++;
    }

    setState(() {});

    if (hitLimit && addedCount == 0) {
      _showCartLimitSnackBar();
      return;
    }
    if (hitLimit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$addedCount mantra(s) added. Cart limit is '
            '${MantraService.maxCartTotalQuantity} items.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$addedCount mantra(s) added to cart'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_currentStep) {
      case 0:
        return _buildSongSelectionStep();
      case 1:
        return _buildCartStep();
      case 2:
        return _buildVoiceRecordingStep();
      case 3:
        return _buildMyMantraStep();
      default:
        return _buildSongSelectionStep();
    }
  }

  /// Shown on mantra rows when the purchase API reports `available_count` > 0.
  Widget _buildPurchasedCountHint(
    Mantra mantra, {
    double fontSize = 12,
    bool compact = false,

    /// When [compact] is true, grid cards center the row; set false for list/dialog rows.
    bool centerCompactRow = true,

    /// Inline with price/actions row — no extra top padding.
    bool inline = false,
  }) {
    if (mantra.purchasedCount <= 0) return const SizedBox.shrink();
    final n = mantra.purchasedCount;
    final circleSize = inline ? 20.0 : (compact ? 24.0 : 30.0);
    final cartSize = inline ? 16.0 : (compact ? 20.0 : 24.0);

    final countBadge = Container(
      width: circleSize,
      height: circleSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.green.shade700,
        boxShadow: [
          BoxShadow(
            color: Colors.green.withValues(alpha: 0.35),
            blurRadius: compact ? 4 : 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '$n',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 11 : 14,
              height: 1,
            ),
          ),
        ),
      ),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Icons.shopping_cart_rounded,
          size: cartSize,
          color: Colors.green.shade800,
        ),
        SizedBox(width: compact ? 6 : 8),
        countBadge,
      ],
    );

    final child = (compact && centerCompactRow && !inline)
        ? Center(child: row)
        : Align(alignment: Alignment.centerLeft, child: row);

    if (inline) return child;

    return Padding(padding: const EdgeInsets.only(top: 4), child: child);
  }

  Widget _buildMantraListTile(Mantra mantra) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.primarySaffron.withOpacity(0.1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _buildMantraIcon(
                iconName: mantra.icon,
                size: 26,
                iconColor: AppColors.primarySaffron,
                fit: BoxFit.cover,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mantra.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      mantra.formattedPrice,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primarySaffron,
                        height: 1.2,
                      ),
                    ),
                    if (mantra.purchasedCount > 0) const SizedBox(width: 6),
                    _buildPurchasedCountHint(
                      mantra,
                      compact: true,
                      inline: true,
                      centerCompactRow: false,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => _playMantra(mantra),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                      icon: Icon(
                        _currentlyPlaying == mantra && _isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: AppColors.primarySaffron,
                        size: 26,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => mantra.isInCart
                          ? _removeFromCart(mantra)
                          : _addToCart(mantra),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: mantra.isInCart
                            ? Colors.red
                            : AppColors.primarySaffron,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        mantra.isInCart ? 'Remove' : 'Add',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongSelectionStep() {
    if (_isLoadingMantras) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Choose Your Mantras',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _isMantraSelectionExpanded = true;
                      });
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: const Icon(
                      Icons.fullscreen,
                      color: Colors.black,
                      size: 22,
                    ),
                    tooltip: 'Expand to full screen',
                  ),
                ],
              ),
              Container(
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search mantras...',
                    prefixIcon: Icon(Icons.search, size: 15),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 0,
                    ),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _addAllNonPurchasedToCart,
                  icon: const Icon(Icons.shopping_cart, size: 15),
                  label: const Text(
                    'Purchase All',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primarySaffron,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Showing ${_filteredMantras.length} of ${_mantras.length} mantras',
                  style: const TextStyle(fontSize: 11, color: Colors.blue),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            itemCount: _filteredMantras.length,
            itemBuilder: (context, index) =>
                _buildMantraListTile(_filteredMantras[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildExpandedMantraSelectionStep() {
    if (_isLoadingMantras) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black),
            onPressed: () {
              setState(() {
                _isMantraSelectionExpanded = false;
              });
            },
          ),
          title: const Text(
            'Choose Your Mantras',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          centerTitle: true,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () {
            setState(() {
              _isMantraSelectionExpanded = false;
            });
          },
        ),
        title: const Text(
          'Choose Your Mantras',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Search Bar
              Container(
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search mantras...',
                    prefixIcon: Icon(Icons.search, size: 16),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 0,
                    ),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 6),

              // Purchase All Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _addAllNonPurchasedToCart,
                  icon: const Icon(Icons.shopping_cart, size: 16),
                  label: const Text(
                    'Purchase All',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primarySaffron,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    minimumSize: const Size(0, 36),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // Mantra count info
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Showing ${_filteredMantras.length} of ${_mantras.length} mantras',
                  style: const TextStyle(fontSize: 12, color: Colors.blue),
                ),
              ),
              const SizedBox(height: 20),

              // Mantras List
              ..._filteredMantras
                  .map(
                    (mantra) => Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        children: [
                          // Icon
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: AppColors.primarySaffron.withOpacity(0.1),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _buildMantraIcon(
                                iconName: mantra.icon,
                                size: 30,
                                iconColor: AppColors.primarySaffron,
                                fit: BoxFit.cover,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),

                          // Details
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  mantra.name,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Text(
                                //   mantra.formattedPlaytime, // COMMENTED OUT
                                //   style: const TextStyle(
                                //     fontSize: 12,
                                //     color: AppColors.textSecondary,
                                //   ),
                                // ),
                                // const SizedBox(height: 4),
                                Text(
                                  mantra.formattedPrice,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primarySaffron,
                                  ),
                                ),
                                _buildPurchasedCountHint(mantra),
                              ],
                            ),
                          ),

                          // Play Button
                          IconButton(
                            onPressed: () => _playMantra(mantra),
                            icon: Icon(
                              _currentlyPlaying == mantra && _isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              color: AppColors.primarySaffron,
                              size: 32,
                            ),
                          ),

                          ElevatedButton(
                            onPressed: () => mantra.isInCart
                                ? _removeFromCart(mantra)
                                : _addToCart(mantra),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: mantra.isInCart
                                  ? Colors.red
                                  : AppColors.primarySaffron,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            child: Text(
                              mantra.isInCart ? 'Remove' : 'Add',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMantraCard(Mantra mantra) {
    final isPlaying = _currentlyPlaying == mantra && _isPlaying;
    final isInCart = mantra.isInCart;

    return GestureDetector(
      onTap: () => _playMantra(mantra),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isPlaying ? AppColors.primarySaffron : Colors.grey.shade300,
            width: isPlaying ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isPlaying
              ? AppColors.primarySaffron.withOpacity(0.1)
              : Colors.white,
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Mantra Icon/Image
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: AppColors.primarySaffron.withOpacity(0.1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _buildMantraIcon(
                    iconName: mantra.icon,
                    size: 24,
                    iconColor: AppColors.primarySaffron,
                    fit: BoxFit.cover,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // Mantra Name
              Text(
                mantra.name,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              const SizedBox(height: 4),

              // Playtime - COMMENTED OUT
              // Text(
              //   mantra.formattedPlaytime, // COMMENTED OUT
              //   style: const TextStyle(
              //     fontSize: 9,
              //     color: AppColors.textSecondary,
              //   ),
              // ),
              const SizedBox(height: 4),

              // Price
              Text(
                mantra.formattedPrice,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primarySaffron,
                ),
              ),
              _buildPurchasedCountHint(mantra, fontSize: 9, compact: true),

              const SizedBox(height: 6),

              SizedBox(
                width: double.infinity,
                child: isInCart
                    ? OutlinedButton(
                        onPressed: () => _removeFromCart(mantra),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          side: const BorderSide(color: Colors.red),
                          minimumSize: const Size(0, 24),
                        ),
                        child: const Text(
                          'Remove',
                          style: TextStyle(fontSize: 9),
                        ),
                      )
                    : ElevatedButton(
                        onPressed: () => _addToCart(mantra),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          backgroundColor: AppColors.primarySaffron,
                          minimumSize: const Size(0, 24),
                        ),
                        child: const Text(
                          'Add to Cart',
                          style: TextStyle(fontSize: 9),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceRecordingStep() {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () async {
            // Cleanup unsaved recording before leaving
            await _cleanupUnsavedRecording();
            setState(() {
              _currentStep--;
            });
          },
        ),
        title: const Text(
          'Record Your Voice',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                children: [
                  // Instructions
                  const Text(
                    'Read the text clearly in a quiet environment',
                    style: TextStyle(fontSize: 16, color: Colors.black87),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 6),

                  // Language Selection
                  Row(
                    children: [
                      const Text(
                        'Language:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey[300]!),
                          ),
                          child: DropdownButton<String>(
                            value: _selectedLanguage,
                            isExpanded: true,
                            underline: const SizedBox(),
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 13,
                            ),
                            dropdownColor: Colors.white,
                            items: VoiceRecordingService.languageContent.keys
                                .map((String language) {
                                  return DropdownMenuItem<String>(
                                    value: language,
                                    child: Text(
                                      language,
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontSize: 13,
                                      ),
                                    ),
                                  );
                                })
                                .toList(),
                            onChanged: (String? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedLanguage = newValue;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 6),

                  // Text Display Box
                  Expanded(
                    flex: 1,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[300]!, width: 1),
                      ),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.zero,
                        child: Text(
                          VoiceRecordingService
                                  .languageContent[_selectedLanguage] ??
                              '',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Recording Controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // When recording: show timer + stop button. When not: show record button
                      if (_isRecording)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _formatRecordingTime(_recordingSeconds),
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primarySaffron,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${_recordingSeconds >= _maxRecordingSeconds ? "Stopping..." : "Tap stop or wait 1 min"}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _buildRecordingButton(
                              icon: Icons.stop,
                              onPressed: _stopRecording,
                              isPrimary: true,
                              isRecording: true,
                              enabled: true,
                            ),
                          ],
                        )
                      else
                        _buildRecordingButton(
                          icon: Icons.mic,
                          onPressed: () {
                            if (!_hasPurchasedMantras()) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'You have to purchase at least one song first to start recording your voice',
                                  ),
                                  backgroundColor: Colors.orange,
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            } else {
                              _startRecording();
                            }
                          },
                          isPrimary: true,
                          isRecording: false,
                          enabled: _hasPurchasedMantras(),
                        ),

                      // Preview / Save (only show if recording exists)
                      if (_currentRecordingPath != null) ...[
                        const SizedBox(width: 16),
                        _buildRecordingButton(
                          icon:
                              (_isPlayingRecording &&
                                  _currentlyPlayingPath ==
                                      _currentRecordingPath)
                              ? Icons.pause
                              : Icons.play_arrow,
                          onPressed: () =>
                              _playRecording(_currentRecordingPath!),
                          isPrimary: false,
                          label:
                              (_isPlayingRecording &&
                                  _currentlyPlayingPath ==
                                      _currentRecordingPath)
                              ? 'Pause'
                              : 'Play',
                        ),
                        const SizedBox(width: 12),
                        _buildRecordingButton(
                          icon: Icons.save,
                          onPressed: _showSaveDialog,
                          isPrimary: false,
                          label: 'Save',
                        ),
                      ],
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Existing Recordings Section - Made larger to show at least 2 recordings
                  Expanded(
                    flex: 1,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[300]!, width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Expanded(
                                child: Text(
                                  'Your Recordings',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    _isRecordingsExpanded = true;
                                  });
                                },
                                icon: const Icon(
                                  Icons.fullscreen,
                                  color: AppColors.primarySaffron,
                                  size: 18,
                                ),
                                tooltip: 'Expand to full screen',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: _voiceService.recordings.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No recordings yet',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    shrinkWrap: false,
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    itemCount: _voiceService.recordings.length,
                                    itemBuilder: (context, index) {
                                      final recording =
                                          _voiceService.recordings[index];
                                      final greyedOut = !recording.hasLocalFile;
                                      final titleStyle = TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: greyedOut
                                            ? Colors.grey[600]!
                                            : Colors.black,
                                      );
                                      final subStyle = TextStyle(
                                        fontSize: 11,
                                        color: greyedOut
                                            ? Colors.grey[600]!
                                            : Colors.black54,
                                      );
                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: greyedOut
                                              ? Colors.grey[200]!
                                              : Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: Colors.grey[300]!,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    recording.name,
                                                    style: titleStyle,
                                                  ),
                                                  Text(
                                                    greyedOut
                                                        ? 'Not on this device${recording.trainingStatus != null && recording.trainingStatus!.isNotEmpty ? ' • ${recording.trainingStatus}' : ''}'
                                                        : '${recording.language} • ${_formatDate(recording.createdAt)}',
                                                    style: subStyle,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (recording.hasLocalFile) ...[
                                              IconButton(
                                                onPressed: () => _playRecording(
                                                  recording.filePath,
                                                ),
                                                icon: Icon(
                                                  (_isPlayingRecording &&
                                                          _currentlyPlayingPath ==
                                                              recording
                                                                  .filePath)
                                                      ? Icons.pause
                                                      : Icons.play_arrow,
                                                  color: Colors.black,
                                                  size: 20,
                                                ),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                              ),
                                              Tooltip(
                                                message: 'Create your Mantra',
                                                child: IconButton(
                                                  onPressed: () {
                                                    _showCreateMantraDialog(
                                                      recording,
                                                    );
                                                  },
                                                  icon: const Text(
                                                    'ॐ',
                                                    style: TextStyle(
                                                      fontSize: 18,
                                                      color: AppColors
                                                          .primarySaffron,
                                                    ),
                                                  ),
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(),
                                                ),
                                              ),
                                            ],
                                            IconButton(
                                              onPressed: () =>
                                                  _deleteRecording(recording),
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.red,
                                                size: 20,
                                              ),
                                              tooltip: 'Delete recording',
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildExpandedRecordingsStep() {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () {
            setState(() {
              _isRecordingsExpanded = false;
            });
          },
        ),
        title: const Text(
          'Your Recordings',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _voiceService.recordings.isEmpty
              ? const Center(
                  child: Text(
                    'No recordings yet',
                    style: TextStyle(fontSize: 16, color: Colors.black54),
                  ),
                )
              : ListView.builder(
                  itemCount: _voiceService.recordings.length,
                  itemBuilder: (context, index) {
                    final recording = _voiceService.recordings[index];
                    final greyedOut = !recording.hasLocalFile;
                    final titleStyle = TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: greyedOut ? Colors.grey[600]! : Colors.black,
                    );
                    final subStyle = TextStyle(
                      fontSize: 14,
                      color: greyedOut ? Colors.grey[600]! : Colors.black54,
                    );
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: greyedOut ? Colors.grey[200]! : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[300]!),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(recording.name, style: titleStyle),
                                const SizedBox(height: 4),
                                Text(
                                  greyedOut
                                      ? 'Not on this device${recording.trainingStatus != null && recording.trainingStatus!.isNotEmpty ? ' • ${recording.trainingStatus}' : ''}'
                                      : '${recording.language} • ${_formatDate(recording.createdAt)}',
                                  style: subStyle,
                                ),
                              ],
                            ),
                          ),
                          if (recording.hasLocalFile) ...[
                            IconButton(
                              onPressed: () =>
                                  _playRecording(recording.filePath),
                              icon: Icon(
                                (_isPlayingRecording &&
                                        _currentlyPlayingPath ==
                                            recording.filePath)
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: AppColors.primarySaffron,
                                size: 32,
                              ),
                            ),
                            Tooltip(
                              message: 'Create your Mantra',
                              child: IconButton(
                                onPressed: () {
                                  _showCreateMantraDialog(recording);
                                },
                                icon: const Text(
                                  'ॐ',
                                  style: TextStyle(
                                    fontSize: 28,
                                    color: AppColors.primarySaffron,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          IconButton(
                            onPressed: () => _deleteRecording(recording),
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.red,
                              size: 28,
                            ),
                            tooltip: 'Delete recording',
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildRecordingButton({
    required IconData icon,
    required VoidCallback onPressed,
    required bool isPrimary,
    bool isRecording = false,
    bool enabled = true,
    String? label,
  }) {
    final button = Container(
      width: isPrimary ? 60 : 40,
      height: isPrimary ? 60 : 40,
      decoration: BoxDecoration(
        color: isRecording
            ? Colors.red
            : (enabled ? AppColors.white : Colors.grey[300]),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(enabled ? 0.2 : 0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed, // Always allow click to show message
        icon: Icon(
          icon,
          color: isRecording
              ? AppColors.white
              : (enabled ? AppColors.primarySaffron : Colors.grey[600]),
          size: isPrimary ? 24 : 20,
        ),
      ),
    );

    if (label == null || label.isEmpty) return button;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: enabled ? AppColors.textPrimary : Colors.grey[600],
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Widget _buildControlButton(
    IconData icon,
    VoidCallback onPressed, {
    bool isPrimary = false,
  }) {
    return Container(
      width: isPrimary ? 60 : 40,
      height: isPrimary ? 60 : 40,
      decoration: BoxDecoration(
        color: AppColors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(
          icon,
          color: AppColors.primarySaffron,
          size: isPrimary ? 24 : 20,
        ),
      ),
    );
  }

  /// My Mantras list row: line 1 name, line 2 thumbnail + actions, line 3 status (tight vertical spacing).
  Widget _buildInferredSongCardContent({
    required InferredSong song,
    required bool hasLocal,
    required bool downloading,
    required bool compact,
  }) {
    final thumb = compact ? 36.0 : 42.0;
    final innerIcon = compact ? 22.0 : 26.0;
    final actionIcon = compact ? 20.0 : 22.0;
    final playIcon = compact ? 24.0 : 28.0;
    final deleteIcon = compact ? 20.0 : 22.0;
    final btnConstraints = BoxConstraints(
      minWidth: compact ? 30 : 32,
      minHeight: compact ? 30 : 32,
    );

    final nameStyle = TextStyle(
      fontSize: compact ? 14 : 15,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
      height: 1.05,
    );
    final statusStyle = TextStyle(
      fontSize: compact ? 10.5 : 11,
      fontWeight: FontWeight.w600,
      height: 1.05,
      color: hasLocal ? AppColors.successGreen : AppColors.textSecondary,
    );
    final statusText = hasLocal ? 'On device' : 'Tap to download';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          song.myMantrasCardTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: nameStyle,
        ),
        SizedBox(height: compact ? 2 : 3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: thumb,
              height: thumb,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.white.withOpacity(0.55),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _buildMantraIcon(
                  iconName: song.iconAssetFileName,
                  size: innerIcon,
                  iconColor: AppColors.textPrimary,
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (downloading)
              SizedBox(
                width: compact ? 28 : 30,
                height: compact ? 28 : 30,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primarySaffron,
                  ),
                ),
              )
            else
              IconButton(
                onPressed: () => _downloadInferredSong(song),
                icon: Icon(
                  Icons.download,
                  color: AppColors.textPrimary,
                  size: actionIcon,
                ),
                tooltip: 'Download to app',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: btnConstraints,
              ),
            IconButton(
              onPressed: hasLocal ? () => _shareInferredSong(song) : null,
              icon: Icon(
                Icons.share,
                color: hasLocal
                    ? AppColors.textPrimary
                    : AppColors.textPrimary.withOpacity(0.3),
                size: actionIcon,
              ),
              tooltip: 'Save or share (Files, Drive…)',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: btnConstraints,
            ),
            IconButton(
              onPressed: hasLocal ? () => _playInferredMantra(song) : null,
              icon: Icon(
                _currentInferredPlaying == song && _isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: hasLocal
                    ? AppColors.primarySaffron
                    : AppColors.textPrimary.withOpacity(0.3),
                size: playIcon,
              ),
              tooltip: 'Play',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: btnConstraints,
            ),
            IconButton(
              onPressed: () => _deleteInferredSong(song),
              icon: Icon(
                Icons.delete_outline,
                color: AppColors.errorRed,
                size: deleteIcon,
              ),
              tooltip: 'Delete',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: btnConstraints,
            ),
          ],
        ),
        SizedBox(height: compact ? 2 : 3),
        Text(
          statusText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: statusStyle,
        ),
      ],
    );
  }

  Widget _buildMyMantraStep() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: AppColors.voiceGradient,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'My Mantras',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your purchased mantras collection',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _isMyMantrasExpanded = true;
                    });
                    _loadInferredSongs();
                  },
                  icon: const Icon(
                    Icons.fullscreen,
                    color: AppColors.textPrimary,
                    size: 18,
                  ),
                  tooltip: 'Expand to full screen',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Mantras List - Use Expanded to fill available space
            Expanded(
              child: _loadingInferredSongs
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primarySaffron,
                      ),
                    )
                  : _inferredSongsError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _inferredSongsError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    )
                  : _inferredSongs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.music_note_outlined,
                            size: 56,
                            color: AppColors.textSecondary.withOpacity(0.6),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No mantras ready yet',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Completed voice mantras appear here',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary.withOpacity(0.85),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _inferredSongs.length,
                      itemBuilder: (context, index) {
                        final song = _inferredSongs[index];
                        final hasLocal = _inferredLocalPaths.containsKey(
                          song.inferredId,
                        );
                        final downloading = _inferredDownloadingIds.contains(
                          song.inferredId,
                        );
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.white.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: _buildInferredSongCardContent(
                            song: song,
                            hasLocal: hasLocal,
                            downloading: downloading,
                            compact: true,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandedMyMantrasStep() {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () {
            setState(() {
              _isMyMantrasExpanded = false;
            });
          },
        ),
        title: const Text(
          'My Mantras',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.voiceGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  'Your purchased mantras collection',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: _loadingInferredSongs
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primarySaffron,
                        ),
                      )
                    : _inferredSongsError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _inferredSongsError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 15,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      )
                    : _inferredSongs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.music_note_outlined,
                              size: 64,
                              color: AppColors.textSecondary.withOpacity(0.6),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No mantras ready yet',
                              style: TextStyle(
                                fontSize: 18,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Completed voice mantras appear here',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary.withOpacity(
                                  0.85,
                                ),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _inferredSongs.length,
                        itemBuilder: (context, index) {
                          final song = _inferredSongs[index];
                          final hasLocal = _inferredLocalPaths.containsKey(
                            song.inferredId,
                          );
                          final downloading = _inferredDownloadingIds.contains(
                            song.inferredId,
                          );
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.white.withOpacity(0.4),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: _buildInferredSongCardContent(
                              song: song,
                              hasLocal: hasLocal,
                              downloading: downloading,
                              compact: false,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCartStep() {
    final cartItems = MantraService.getCart();
    final cartUnitCount = MantraService.getCartTotalQuantity();
    final total = MantraService.getCartTotal();
    final cartCurrencyCode = MantraService.getCartCurrencyCode();
    final totalDisplay = Mantra.formatMoney(total, cartCurrencyCode);

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: AppColors.paymentGradient,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your Cart',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.white,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              cartUnitCount == 0
                  ? 'No mantras selected'
                  : '$cartUnitCount / ${MantraService.maxCartTotalQuantity} '
                        'mantra${cartUnitCount != 1 ? 's' : ''} selected',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.white.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 1),

            // Cart Items List - Make scrollable when items are present
            if (cartItems.isEmpty)
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.shopping_cart_outlined,
                                    size: 64,
                                    color: AppColors.white.withOpacity(0.5),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'Your cart is empty',
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: AppColors.white.withOpacity(0.7),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Add mantras to get started',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.white.withOpacity(0.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    _buildCartLimitNote(),
                  ],
                ),
              )
            else
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Scrollable cart items list - takes remaining space
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: cartItems.length,
                        itemBuilder: (context, index) {
                          final mantra = cartItems[index];
                          final quantity = mantra.cartQuantity;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppColors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                // Mantra Icon
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: AppColors.white.withOpacity(0.2),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: _buildMantraIcon(
                                      iconName: mantra.icon,
                                      size: 16,
                                      iconColor: AppColors.white,
                                      fit: BoxFit.cover,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // Mantra Details
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        mantra.name,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.white,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (quantity > 1)
                                        Text(
                                          '${mantra.formattedPrice} each',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: AppColors.white.withOpacity(
                                              0.75,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),

                                _buildCartQuantityStepper(mantra, quantity),

                                const SizedBox(width: 6),

                                // Line total
                                Text(
                                  mantra.formattedLineTotal(),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.white,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),

                    // Total and Checkout - Fixed at bottom
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Total:',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: AppColors.white,
                            ),
                          ),
                          Text(
                            totalDisplay,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.white,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 1),

                    // Checkout Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          // Navigate to payment screen
                          final paymentSuccess = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (context) => PaymentScreen(
                                totalAmount: total,
                                currencyCode: cartCurrencyCode,
                                cartItems:
                                    MantraService.expandCartForCheckout(),
                              ),
                            ),
                          );

                          // If payment was successful, update mantras and go to Select Mantra screen
                          if (paymentSuccess == true && mounted) {
                            setState(() {
                              _currentStep = 0; // Go to Select Mantra screen
                            });
                            await _loadMantras(syncCatalog: false);
                            await _loadUnreadNotificationCount();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.white,
                          foregroundColor: AppColors.primarySaffron,
                          padding: const EdgeInsets.symmetric(vertical: 5),
                        ),
                        child: const Text(
                          'Proceed to Checkout',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    _buildCartLimitNote(),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showAboutAppDialog() {
    const bodyStyle = TextStyle(
      fontSize: 14,
      height: 1.45,
      color: AppColors.textSecondary,
    );
    const headingStyle = TextStyle(
      fontSize: 14,
      height: 1.45,
      fontWeight: FontWeight.bold,
      color: AppColors.textPrimary,
    );
    const brandStyle = TextStyle(
      fontSize: 16,
      height: 1.45,
      fontWeight: FontWeight.bold,
      color: AppColors.textPrimary,
    );

    Widget sectionHeading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(text, style: headingStyle),
    );

    Widget sectionBody(String text) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, style: bodyStyle),
    );

    Widget benefitItem(String label, String description) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text.rich(
        TextSpan(
          style: bodyStyle,
          children: [
            TextSpan(text: label, style: headingStyle),
            TextSpan(text: description),
          ],
        ),
      ),
    );

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final dialogWidth = MediaQuery.sizeOf(ctx).width - 24;

        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 20,
          ),
          constraints: BoxConstraints(maxWidth: dialogWidth),
          title: const Text('About MantraSutra'),
          content: SizedBox(
            width: dialogWidth,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MantraSutra', style: brandStyle),
                  sectionHeading('What is MantraSutra?'),
                  sectionBody(
                    'MantraSutra is an innovative digital platform that allows you to '
                    'chant—even without any prior experience—and record sacred Hindu '
                    'mantras in your very own voice.',
                  ),
                  sectionHeading('Why MantraSutra?'),
                  sectionBody(
                    'Ever wondered how a powerful mantra resonates when spoken by you? '
                    'MantraSutra bridges the gap between technology and spirituality, '
                    'giving you a deeply personal experience of hearing divine verses in '
                    'your unique voice.',
                  ),
                  sectionHeading('Key Benefits:'),
                  benefitItem(
                    'Learn & Practice: ',
                    'It doesn\'t just inspire you to chant; it guides you on how to '
                        'pronounce and recite mantras correctly.',
                  ),
                  benefitItem(
                    'Personalized Spiritual Ringtone: ',
                    'Save your recorded mantras as your mobile ringtone. Every time your '
                        'phone rings, your own voice chanting a sacred mantra will purify the '
                        'ambiance, inspire those around you, and bring positivity to your day.',
                  ),
                  sectionHeading('Important Note:'),
                  sectionBody(
                    'This AI-driven tool depends entirely on your voice quality. For best '
                    'results, please record in a completely quiet room, speaking at a '
                    'normal pace with clear pronunciation. Accuracy may vary based on '
                    'your input.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to logout?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await context.read<AuthService>().logout();
                if (mounted) {
                  // Navigate to login screen after logout
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (context) => const LoginScreen(),
                    ),
                    (route) => false,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Successfully logged out'),
                      backgroundColor: AppColors.successGreen,
                    ),
                  );
                }
              },
              child: const Text('Logout'),
            ),
          ],
        );
      },
    );
  }

  void _showCreateMantraDialog(VoiceRecording recording) {
    if (!recording.hasLocalFile) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Audio file is not on this device.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Get purchased mantras
    final purchasedMantras = _mantras
        .where((mantra) => mantra.isBought)
        .toList();

    if (purchasedMantras.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No purchased mantras available. Please purchase a mantra first.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Track selected mantras
    final Set<String> selectedMantraIds = <String>{};

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final allSelected =
                selectedMantraIds.length == purchasedMantras.length;

            return AlertDialog(
              title: const Text(
                'Create Mantra in Your Voice',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Select All checkbox
                      Row(
                        children: [
                          Checkbox(
                            value: allSelected,
                            onChanged: (value) {
                              setDialogState(() {
                                if (value == true) {
                                  selectedMantraIds.addAll(
                                    purchasedMantras.map((m) => m.mantraFile),
                                  );
                                } else {
                                  selectedMantraIds.clear();
                                }
                              });
                            },
                          ),
                          const Text(
                            'Select All',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const Divider(),
                      const SizedBox(height: 8),

                      // Mantras list
                      Expanded(
                        child: ListView.builder(
                          shrinkWrap: false,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: purchasedMantras.length,
                          itemBuilder: (context, index) {
                            final mantra = purchasedMantras[index];
                            final isSelected = selectedMantraIds.contains(
                              mantra.mantraFile,
                            );

                            return CheckboxListTile(
                              value: isSelected,
                              onChanged: (value) {
                                setDialogState(() {
                                  if (value == true) {
                                    selectedMantraIds.add(mantra.mantraFile);
                                  } else {
                                    selectedMantraIds.remove(mantra.mantraFile);
                                  }
                                });
                              },
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              title: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    mantra.name,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  _buildPurchasedCountHint(
                                    mantra,
                                    compact: true,
                                    centerCompactRow: false,
                                  ),
                                ],
                              ),
                              // subtitle: Text(
                              //   mantra.formattedPlaytime, // COMMENTED OUT
                              //   style: const TextStyle(fontSize: 12),
                              // ),
                              secondary: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: AppColors.primarySaffron.withOpacity(
                                    0.1,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: _buildMantraIcon(
                                    iconName: mantra.icon,
                                    size: 20,
                                    iconColor: AppColors.primarySaffron,
                                    fit: BoxFit.cover,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selectedMantraIds.isEmpty
                      ? null
                      : () async {
                          Navigator.of(dialogContext).pop();
                          // Use backend recording_id if available, otherwise fall back to local id
                          final recordingIdToUse =
                              recording.recordingId ?? recording.id;
                          await _generateMantraInVoice(
                            recordingId: recordingIdToUse,
                            mantraIds: selectedMantraIds.toList(),
                          );
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primarySaffron,
                    foregroundColor: AppColors.white,
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  child: const SizedBox(
                    width: double.infinity,
                    child: Text(
                      'Generate Mantra in Your Voice',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _generateMantraInVoice({
    required String recordingId,
    required List<String> mantraIds,
  }) async {
    if (!mounted) return;

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Call API
      final success = await MantraService.generateMantraInVoice(
        recordingId: recordingId,
        mantraIds: mantraIds,
      );

      // Close loading dialog
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      if (success) {
        await _loadMantras(syncCatalog: false);
        await NotificationService.refresh();
        if (mounted) {
          _loadUnreadNotificationCount();
          await showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Request Submitted'),
              content: const Text(
                'Your mantra generation request has been submitted and it may take 5 minutes to 24 hours depending on the request traffic.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to generate mantra. Please try again.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      // Close loading dialog
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
