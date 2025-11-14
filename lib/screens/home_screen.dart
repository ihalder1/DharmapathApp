import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../services/profile_service.dart';
import '../services/mantra_service.dart';
import '../services/voice_recording_service.dart';
import '../models/mantra.dart';
import 'permission_test_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentStep = 0;
  bool _isEditingPersonalInfo = false;
  bool _isLoading = false;
  
  // Profile Image
  File? _profileImage;
  String? _photoUrl;
  final ImagePicker _picker = ImagePicker();
  
  // Mantra System
  List<Mantra> _mantras = [];
  List<Mantra> _filteredMantras = [];
  bool _isLoadingMantras = false;
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
  bool _hasSyncedRecordings = false;
  
  // Personal Info Data
  Map<String, dynamic> _personalInfo = {
    'fullName': 'John Doe',
    'email': 'john.doe@example.com',
    'location': 'New Delhi, India',
    'mobile': '+91 9876543210',
    'gender': 'Male',
  };
  
  final List<Map<String, dynamic>> _steps = [
    {
      'title': 'Select Mantras',
      'icon': Icons.music_note_outlined,
      'description': 'Choose your Mantras'
    },
    {
      'title': 'Record Voice',
      'icon': Icons.mic_outlined,
      'description': 'Record your voice'
    },
    {
      'title': 'My Mantra',
      'icon': Icons.person_outline,
      'description': 'View your mantras'
    },
    {
      'title': 'Cart',
      'icon': Icons.shopping_cart_outlined,
      'description': 'Complete your purchase'
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadProfileData();
    _loadMantras();
    _searchController.addListener(_filterMantras);
    _loadRecordings();
    // Don't request permission on startup - request when user actually tries to record
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _recordingPlayer.dispose();
    _searchController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  // Load profile data from API
  Future<void> _loadProfileData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final profileData = await ProfileService.getProfile();
      if (profileData != null) {
        setState(() {
          _personalInfo = {
            'fullName': profileData['fullName'] ?? 'John Doe',
            'email': profileData['email'] ?? 'john.doe@example.com',
            'location': profileData['location'] ?? 'New Delhi, India',
            'mobile': profileData['mobile'] ?? '+91 9876543210',
            'gender': profileData['gender'] ?? 'Male',
          };
          _photoUrl = profileData['photoUrl'];
        });
      }
    } catch (e) {
      print('Error loading profile: $e');
      // Show error message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load profile: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Load mantras from JSON metadata
  Future<void> _loadMantras() async {
    setState(() {
      _isLoadingMantras = true;
    });

    try {
      print('Loading mantras...');
      final mantras = await MantraService.loadMantras();
      print('Loaded ${mantras.length} mantras');
      setState(() {
        _mantras = mantras;
        _filteredMantras = mantras;
      });
    } catch (e) {
      print('Error loading mantras: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load mantras: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
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

  // Load recordings from local storage and sync with backend
  Future<void> _loadRecordings() async {
    await _voiceService.loadRecordings();
    setState(() {});
  }

  // Sync recordings when voice recording step is loaded
  Future<void> _syncRecordings() async {
    try {
      await _voiceService.syncRecordings();
      // Reload recordings after sync to ensure UI is updated
      await _voiceService.loadRecordings();
      setState(() {});
    } catch (e) {
      print('Error syncing recordings: $e');
      // Don't show error to user - sync is background operation
    }
  }

  // Voice recording methods
  Future<void> _startRecording() async {
    // Request microphone permission first
    final hasPermission = await _voiceService.requestPermission();
    if (!hasPermission) {
      if (mounted) {
        // Check if permission is permanently denied
        final isPermanentlyDenied = await _voiceService.isPermissionPermanentlyDenied();
        if (isPermanentlyDenied) {
          _showPermissionDialog();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission is required to record audio. Please grant permission.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
      return;
    }

    final success = await _voiceService.startRecording();
    if (success) {
      setState(() {
        _isRecording = true;
        _currentRecordingPath = null; // Clear previous recording
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start recording. Please check microphone permissions.'),
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
    final path = await _voiceService.stopRecording();
    if (path != null) {
      setState(() {
        _isRecording = false;
        _currentRecordingPath = path;
      });
    }
  }

  Future<void> _playRecording(String path) async {
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
      print('Error playing recording: $e');
      print('Path: $path');
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

  Future<void> _showSaveDialog() async {
    if (_currentRecordingPath == null) return;

    final nameController = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
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
                Navigator.pop(context);
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
                    errorText = 'This name already exists. Please choose a different name.';
                  });
                  return;
                }

                Navigator.pop(context);
                
                // Show loading
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const Center(
                    child: CircularProgressIndicator(),
                  ),
                );

                final success = await _voiceService.saveRecording(name, _selectedLanguage);
                
                Navigator.pop(context); // Close loading dialog
                
                if (success) {
                  // Reload recordings to ensure list is up to date
                  await _voiceService.loadRecordings();
                  
                  setState(() {
                    _currentRecordingPath = null;
                    _isPlayingRecording = false; // Reset playback state
                  });
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Recording saved successfully!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Failed to save recording'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
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
    // If we're on the voice recording step, return it as a full screen
    if (_currentStep == 1) {
      return _buildVoiceRecordingStep();
    }
    
    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => PermissionTestScreen()),
          );
        },
        child: Icon(Icons.bug_report),
        backgroundColor: Colors.red,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(),
            
            // Personal Info Card
            _buildPersonalInfoCard(),
            
            const SizedBox(height: 8),
            
            // Step Indicator
            _buildStepIndicator(),
            
            const SizedBox(height: 12),
            
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
                child: _isLoading 
                    ? const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(AppColors.primarySaffron),
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
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          const SizedBox(height: 8),
          
          // User Info Row
          Consumer<AuthService>(
            builder: (context, authService, child) {
              final user = authService.currentUser;
              return Row(
                children: [
                  // User Avatar
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: AppColors.primarySaffron,
                    backgroundImage: user?.photoUrl != null && user!.photoUrl!.isNotEmpty
                        ? NetworkImage(user!.photoUrl!) 
                        : null,
                    child: user?.photoUrl == null || user!.photoUrl!.isEmpty
                        ? const Icon(
                            Icons.person,
                            color: AppColors.white,
                            size: 30,
                          )
                        : null,
                  ),
                  
                  const SizedBox(width: 12),
                  
                  // User Details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome, ${_personalInfo['fullName']}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          _personalInfo['email'],
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Logout Button
                  IconButton(
                    onPressed: () => _showLogoutDialog(context),
                    icon: const Icon(
                      Icons.logout,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              );
            },
          ),
          
          const SizedBox(height: 20),
          
          // App title
          const Text(
            'Dharmapath - धर्मपथ',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Turn your words into timeless chants.',
            style: TextStyle(
              fontSize: 18,
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
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
                setState(() {
                  _currentStep = index;
                });
              },
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.primarySaffron : AppColors.lightSaffron,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primarySaffron,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      step['icon'],
                      color: isActive ? AppColors.white : AppColors.textSecondary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    step['title'],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
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
      padding: const EdgeInsets.all(8),
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
          // Profile Picture Section - Compact
          _buildProfilePictureSection(),
          
          const SizedBox(height: 4),
          
          // Nested Personal Info Card - Compact
          _buildNestedPersonalInfoCard(),
          
          const SizedBox(height: 4),
          
          // Statistics Row
          _buildStatisticsRow(),
        ],
      ),
    );
  }

  Widget _buildProfilePictureSection() {
    return Stack(
      children: [
        // Profile Picture - Smaller
        GestureDetector(
          onTap: _pickProfileImage,
          child: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.primarySaffron,
                width: 1.5,
              ),
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
            backgroundImage: _profileImage != null 
                ? FileImage(_profileImage!) 
                : (_photoUrl != null && _photoUrl!.isNotEmpty)
                    ? NetworkImage(_photoUrl!)
                    : null,
            child: _profileImage == null && (_photoUrl == null || _photoUrl!.isEmpty)
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
        ),
        
        // Edit Icon
        Positioned(
          bottom: 0,
          right: 0,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.primarySaffron,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.white,
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.camera_alt,
              color: AppColors.white,
              size: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatisticsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildStatisticItem('RECORDINGS', '12'),
        _buildStatisticItem('SONGS', '8'),
      ],
    );
  }

  Widget _buildStatisticItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.primarySaffron,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Personal Info Content - Center aligned
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // User Name - Larger
              Text(
                _personalInfo['fullName'],
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 3),
              
              // Location - Larger
              Text(
                _personalInfo['location'],
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 2),
              
              // Mobile - Larger
              Text(
                _personalInfo['mobile'],
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 2),
              
              // Gender - Larger
              Text(
                _personalInfo['gender'],
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          
          const SizedBox(height: 8),
          
          // Edit Button Row
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: _showEditPersonalInfoDialog,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.edit,
                    color: AppColors.white,
                    size: 10,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showEditPersonalInfoDialog() {
    final nameController = TextEditingController(text: _personalInfo['fullName']);
    final locationController = TextEditingController(text: _personalInfo['location']);
    final mobileController = TextEditingController(text: _personalInfo['mobile']);
    final genderController = TextEditingController(text: _personalInfo['gender']);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
              TextField(
                controller: genderController,
                decoration: const InputDecoration(
                  labelText: 'Gender',
                  border: OutlineInputBorder(),
                ),
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
              // Show loading
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
                  gender: genderController.text,
                );

                if (success) {
                  // Update local state
                  setState(() {
                    _personalInfo['fullName'] = nameController.text;
                    _personalInfo['location'] = locationController.text;
                    _personalInfo['mobile'] = mobileController.text;
                    _personalInfo['gender'] = genderController.text;
                  });
                  
                  // Show success message
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Personal information updated successfully'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } else {
                  // Show error message
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Failed to update profile'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              } catch (e) {
                print('Error updating profile: $e');
                if (mounted) {
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
  }


  Future<void> _pickProfileImage() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );
      
      if (image != null) {
        setState(() {
          _isLoading = true;
        });

        final imageFile = File(image.path);
        
        // Upload to backend
        final photoUrl = await ProfileService.uploadProfilePhoto(imageFile);
        
        if (photoUrl != null) {
          setState(() {
            _profileImage = imageFile;
            _photoUrl = photoUrl;
          });
          
          // Show success message
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Profile photo updated successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          // Show error message
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to upload photo'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } catch (e) {
      print('Error picking image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
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
        
        // Play new mantra
        String assetPath = 'Media/${mantra.mantraFile}';
        print('Attempting to play: $assetPath');
        
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
          
          print('Successfully started playing: ${mantra.name}');
        } catch (e) {
          print('Error playing mantra: $e');
          // Show error to user
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Unable to play ${mantra.name}. Audio file not found.'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } catch (e) {
      print('Error playing mantra: $e');
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
    } catch (e) {
      print('Error stopping audio: $e');
    }
  }

  void _addToCart(Mantra mantra) {
    MantraService.addToCart(mantra);
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

  void _removeFromCart(Mantra mantra) {
    MantraService.removeFromCart(mantra);
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

  Widget _buildStepContent() {
    switch (_currentStep) {
      case 0:
        return _buildSongSelectionStep();
      case 1:
        return _buildVoiceRecordingStep();
      case 2:
        return _buildMyMantraStep();
      case 3:
        return _buildCartStep();
      default:
        return _buildSongSelectionStep();
    }
  }


  Widget _buildSongSelectionStep() {
    if (_isLoadingMantras) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose Your Mantras',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 20),
          
          // Search Bar
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search mantras...',
                prefixIcon: Icon(Icons.search, size: 20),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(height: 20),
          
          // Debug info
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Showing ${_filteredMantras.length} of ${_mantras.length} mantras',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.blue,
              ),
            ),
          ),
          const SizedBox(height: 20),
          
          // Mantras List
          ..._filteredMantras.map((mantra) => Container(
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
                    child: Image.asset(
                      'assets/Media/${mantra.icon}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        print('Image loading error for ${mantra.icon}: $error');
                        return Icon(
                          Icons.music_note,
                          size: 30,
                          color: AppColors.primarySaffron,
                        );
                      },
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
                      Text(
                        mantra.formattedPlaytime,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        mantra.formattedPrice,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primarySaffron,
                        ),
                      ),
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
                
                // Add to Cart Button (only show if not bought)
                if (!mantra.isBought)
                  ElevatedButton(
                    onPressed: () => mantra.isInCart 
                        ? _removeFromCart(mantra) 
                        : _addToCart(mantra),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: mantra.isInCart ? Colors.red : AppColors.primarySaffron,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    child: Text(
                      mantra.isInCart ? 'Remove' : 'Add',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                
                // Show "Purchased" indicator if bought
                if (mantra.isBought)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.green, width: 1),
                    ),
                    child: const Text(
                      'Purchased',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          )).toList(),
          
          const SizedBox(height: 20),
        ],
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
          color: isPlaying ? AppColors.primarySaffron.withOpacity(0.1) : Colors.white,
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
                    child: Image.asset(
                      'assets/Media/${mantra.icon}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        print('Image loading error for ${mantra.icon}: $error');
                        return Icon(
                          Icons.music_note,
                          size: 24,
                          color: AppColors.primarySaffron,
                        );
                      },
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
              
              // Playtime
              Text(
                mantra.formattedPlaytime,
                style: const TextStyle(
                  fontSize: 9,
                  color: AppColors.textSecondary,
                ),
              ),
              
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
              
              const SizedBox(height: 6),
              
              // Add to Cart Button (only show if not bought)
              if (!mantra.isBought)
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
              
              // Show "Purchased" indicator if bought
              if (mantra.isBought)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.green, width: 1),
                  ),
                  child: const Text(
                    'Purchased',
                    style: TextStyle(
                      fontSize: 9,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceRecordingStep() {
    // Load and sync recordings when this step is first loaded (only once)
    if (!_hasSyncedRecordings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _hasSyncedRecordings = true;
        // Load recordings first to show existing ones
        _loadRecordings();
        // Then sync with backend
        _syncRecordings();
      });
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
              _currentStep--;
              // Reset sync flag when leaving this step
              if (_currentStep != 1) {
                _hasSyncedRecordings = false;
              }
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
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // Instructions
              const Text(
                'Read the text clearly in a quiet environment',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 20),
              
              // Language Selection
              Row(
                children: [
                  const Text(
                    'Language:',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: DropdownButton<String>(
                        value: _selectedLanguage,
                        isExpanded: true,
                        underline: const SizedBox(),
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 14,
                        ),
                        dropdownColor: Colors.white,
                        items: VoiceRecordingService.languageContent.keys.map((String language) {
                          return DropdownMenuItem<String>(
                            value: language,
                            child: Text(
                              language,
                              style: const TextStyle(color: Colors.black),
                            ),
                          );
                        }).toList(),
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
              
              const SizedBox(height: 20),
              
              // Text Display Box
              Expanded(
                    flex: 1,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.grey[300]!,
                      width: 1,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      VoiceRecordingService.languageContent[_selectedLanguage] ?? '',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Recording Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Record Button
                  _buildRecordingButton(
                    icon: _isRecording ? Icons.stop : Icons.mic,
                    onPressed: _isRecording ? _stopRecording : _startRecording,
                    isPrimary: true,
                    isRecording: _isRecording,
                  ),
                  
                  // Preview Button (only show if recording exists)
                  if (_currentRecordingPath != null)
                    _buildRecordingButton(
                          icon: (_isPlayingRecording && _currentlyPlayingPath == _currentRecordingPath) 
                              ? Icons.pause 
                              : Icons.play_arrow,
                      onPressed: () => _playRecording(_currentRecordingPath!),
                      isPrimary: false,
                    ),
                  
                  // Save Button (only show if recording exists)
                  if (_currentRecordingPath != null)
                    _buildRecordingButton(
                      icon: Icons.save,
                      onPressed: _showSaveDialog,
                      isPrimary: false,
                    ),
                ],
              ),
              
              const SizedBox(height: 20),
              
                  // Existing Recordings Section - Made larger to show at least 2 recordings
              Expanded(
                    flex: 2,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.grey[300]!,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your Recordings',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 12),
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
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _voiceService.recordings.length,
                                itemBuilder: (context, index) {
                                  final recording = _voiceService.recordings[index];
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.grey[300]!),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                recording.name,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              Text(
                                                '${recording.language} • ${_formatDate(recording.createdAt)}',
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.black54,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () => _playRecording(recording.filePath),
                                          icon: Icon(
                                            (_isPlayingRecording && _currentlyPlayingPath == recording.filePath)
                                                ? Icons.pause 
                                                : Icons.play_arrow,
                                            color: Colors.black,
                                          ),
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

  Widget _buildRecordingButton({
    required IconData icon,
    required VoidCallback onPressed,
    required bool isPrimary,
    bool isRecording = false,
  }) {
    return Container(
      width: isPrimary ? 60 : 40,
      height: isPrimary ? 60 : 40,
      decoration: BoxDecoration(
        color: isRecording ? Colors.red : AppColors.white,
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
          color: isRecording ? AppColors.white : AppColors.primarySaffron,
          size: isPrimary ? 24 : 20,
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Widget _buildControlButton(IconData icon, VoidCallback onPressed, {bool isPrimary = false}) {
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

  Widget _buildMyMantraStep() {
    // Get purchased mantras
    final purchasedMantras = _mantras.where((mantra) => mantra.isBought).toList();
    
    return Container(
      decoration: const BoxDecoration(
        gradient: AppColors.voiceGradient,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text(
              'My Mantras',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your purchased mantras collection',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.white.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 20),
            
            // Mantras List
            Expanded(
              child: purchasedMantras.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.music_note_outlined,
                            size: 64,
                            color: AppColors.white.withOpacity(0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No mantras purchased yet',
                            style: TextStyle(
                              fontSize: 18,
                              color: AppColors.white.withOpacity(0.7),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Purchase mantras to see them here',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.white.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: purchasedMantras.length,
                      itemBuilder: (context, index) {
                        final mantra = purchasedMantras[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              // Icon
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: AppColors.white.withOpacity(0.2),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.asset(
                                    'assets/Media/${mantra.icon}',
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      print('Image loading error for ${mantra.icon}: $error');
                                      return Icon(
                                        Icons.music_note,
                                        size: 30,
                                        color: AppColors.white,
                                      );
                                    },
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
                                        color: AppColors.white,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      mantra.formattedPlaytime,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.white.withOpacity(0.7),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Purchased',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.green.withOpacity(0.8),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
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
                                  color: AppColors.white,
                                  size: 32,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            
            const SizedBox(height: 20),
            
            // Navigation Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _currentStep--;
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.white),
                      foregroundColor: AppColors.white,
                    ),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _currentStep++;
                      });
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.white,
                      foregroundColor: AppColors.primarySaffron,
                    ),
                    child: const Text('Next'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartStep() {
    final cartItems = MantraService.getCart();
    final total = MantraService.getCartTotal();
    
    return Container(
      decoration: const BoxDecoration(
        gradient: AppColors.paymentGradient,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Your Cart',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${cartItems.length} mantra${cartItems.length != 1 ? 's' : ''} selected',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.white.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 12),
            
            // Cart Items List - Make scrollable when items are present
            Expanded(
              child: cartItems.isEmpty
                  ? LayoutBuilder(
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
                    )
                  : Column(
                      children: [
                        // Scrollable cart items list
                        Expanded(
                          child: ListView.builder(
                            itemCount: cartItems.length,
                            itemBuilder: (context, index) {
                              final mantra = cartItems[index];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    // Mantra Icon
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(6),
                                        color: AppColors.white.withOpacity(0.2),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.asset(
                                          'assets/Media/${mantra.icon}',
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) {
                                            print('Image loading error for ${mantra.icon}: $error');
                                            return Icon(
                                              Icons.music_note,
                                              size: 20,
                                              color: AppColors.white,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    
                                    // Mantra Details
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            mantra.name,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.white,
                                            ),
                                          ),
                                          Text(
                                            mantra.formattedPlaytime,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.white.withOpacity(0.7),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    
                                    // Price
                                    Text(
                                      mantra.formattedPrice,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.white,
                                      ),
                                    ),
                                    
                                    const SizedBox(width: 8),
                                    
                                    // Remove Button
                                    IconButton(
                                      onPressed: () => _removeFromCart(mantra),
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        
                        // Total and Checkout - Fixed at bottom (NOT in Expanded)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.white,
                                ),
                              ),
                              Text(
                                '₹$total',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 4),
                        
                        // Checkout Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              // Handle checkout
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Proceeding to checkout...'),
                                  backgroundColor: AppColors.successGreen,
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.white,
                              foregroundColor: AppColors.primarySaffron,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                            ),
                            child: const Text(
                              'Proceed to Checkout',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        
                        const SizedBox(height: 0),
                        
                        // Back Button
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _currentStep--;
                              });
                            },
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: AppColors.white),
                              foregroundColor: AppColors.white,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              minimumSize: const Size(0, 30),
                            ),
                            child: const Text('Back'),
                          ),
                        ),
                      ],
                    ),
            ),
            
            // Back Button (only show when cart is empty)
            if (cartItems.isEmpty) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _currentStep--;
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.white),
                    foregroundColor: AppColors.white,
                  ),
                  child: const Text('Back'),
                ),
              ),
            ],
          ],
        ),
      ),
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
}
