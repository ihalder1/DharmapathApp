import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'permission_service.dart';

class VoiceRecordingService {
  static final VoiceRecordingService _instance = VoiceRecordingService._internal();
  factory VoiceRecordingService() => _instance;
  VoiceRecordingService._internal();

  final Uuid _uuid = const Uuid();
  final AudioRecorder _audioRecorder = AudioRecorder();
  
  bool _isRecording = false;
  String? _currentRecordingPath;
  List<VoiceRecording> _recordings = [];

  bool get isRecording => _isRecording;
  String? get currentRecordingPath => _currentRecordingPath;
  List<VoiceRecording> get recordings => _recordings;

  // Language content
  static const Map<String, String> languageContent = {
    'English': '''Hinduism is an ancient tradition of living, a continuous philosophy. Its greatest virtue is tolerance. Hindus have never harbored an aggressive attitude toward other religions. Hinduism has many Mantras. Regular chanting of these Mantras instills a sense of moral duty and makes people more responsible. Hindu Mantras are a profound spiritual science that establishes a connection between the mind and the cosmos. The regular recitation or chanting of Mantras has a far-reaching effect on an individual's life and Hindu religious culture. Chanting or even listening to these Mantras calms the mind and has a positive impact on the body's nervous system. Regular listening to Mantras brings control over the mind, increases concentration, and creates positive energy in the body. Beyond just the well-being of the body and mind, regular chanting of Hindu Mantras strengthens social bonds. When many people gather to chant Mantras or sing Kirtans, it creates a unified and peaceful environment that strengthens social and spiritual ties.

For this reason, it is the duty of every Hindu to incorporate this spiritual science of Mantras into their lives regularly. If chanting is not possible, one should at least listen to Mantras for some time every day. This will not only bring personal mental peace but also spread unity and positivity at the family and social levels. Through this regular practice, the eternal glory and the message of tolerance of Hinduism can easily reach far and wide.''',
    
    'Bengali': '''হিন্দু ধর্ম  জীবনযাপনের এক সুপ্রাচীন ধারা, এক নিরন্তর দর্শন। এর সবচেয়ে বড় মাহাত্ম্য হলো সহনশীলতা। হিন্দুরা অন্য ধর্মের প্রতি কোনদিন আগ্রাসী মনোভাব পোষণ করে না। হিন্দু ধর্মের অনেক মন্ত্র আছে। এই মন্ত্রগুলো নিয়মিত উচ্চারন করলে মানুষের মধ্যে নৈতিক কর্তব্যবোধের ধারণা তৈরি হয় ও  দায়িত্বশীল হয়ে ওঠে। হিন্দু ধর্মের মন্ত্রগুলো হল এক গভীর আধ্যাত্মিক বিজ্ঞান, যা মন ও ব্রহ্মাণ্ডের মধ্যে সংযোগ স্থাপন করে। মন্ত্রের নিয়মিত জপ বা উচ্চারণ একজন ব্যক্তির জীবন এবং হিন্দু ধর্মীয় সংস্কৃতিতে সুদূরপ্রসারী প্রভাব ফেলে। মন্ত্রগুলো জপ করলে অথবা শুনলেও মন শান্ত হয় এবং শরীরের স্নায়ুতন্ত্রে ইতিবাচক প্রভাব ফেলে। মন্ত্রগুলো নিয়মিত শ্রবনে মনের উপরে নিয়ন্ত্রণ আসে, একাগ্রতা বৃদ্ধি পায় এবং শরীরে ইতিবাচক শক্তি সৃষ্টি হয়। শুধু শরীর বা মনের সমৃদ্ধি নয়, হিন্দু ধর্মের মন্ত্রগুলো নিয়মিত জপ করলে সামাজিক বন্ধন দৃঢ় হয়। বহু মানুষ একসাথে বসে যখন মন্ত্র জপ করেন বা কীর্তন করেন, তখন একটি ঐক্যবদ্ধ ও শান্তিময় পরিবেশ সৃষ্টি হয়, যা সামাজিক ও আধ্যাত্মিক বন্ধনকে মজবুত করে। 

এই কারণে, প্রত্যেকটি হিন্দুর কর্তব্য হলো নিয়মিত মন্ত্রের এই আধ্যাত্মিক বিজ্ঞানকে নিজেদের জীবনে স্থান দেওয়া। যদি একান্ত জপ করা সম্ভব না হয়, তবে অন্তত প্রতিদিন কিছুক্ষণ মন্ত্র শ্রবণ করা উচিত। এটি কেবল ব্যক্তিগত মানসিক শান্তি দেবে না, বরং পারিবারিক ও সামাজিক স্তরে ঐক্য এবং ইতিবাচকতা ছড়িয়ে দেবে। নিয়মিত এই চর্চার মাধ্যমেই দিকে দিকে হিন্দু ধর্মের শাশ্বত মাহাত্ম্য এবং সহনশীলতার বার্তা সহজে পৌঁছে যেতে পারে।''',
    
    'Hindi': '''हिंदू धर्म जीवन जीने की एक प्राचीन धारा और एक निरंतर दर्शन है। इसका सबसे बड़ा महत्व सहिष्णुता है। हिंदुओं ने कभी भी अन्य धर्मों के प्रति आक्रामक रवैया नहीं रखा है। हिंदू धर्म में कई मंत्र हैं। इन मंत्रों का नियमित उच्चारण करने से लोगों में नैतिक कर्तव्यबोध की भावना पैदा होती है और वे जिम्मेदार बनते हैं। हिंदू धर्म के मंत्र एक गहन आध्यात्मिक विज्ञान हैं, जो मन और ब्रह्मांड के बीच संबंध स्थापित करते हैं। मंत्रों के नियमित जाप या उच्चारण का व्यक्ति के जीवन और हिंदू धार्मिक संस्कृति पर दूरगामी प्रभाव पड़ता है। मंत्रों का जाप करने या सुनने से भी मन शांत होता है और शरीर के तंत्रिका तंत्र पर सकारात्मक प्रभाव पड़ता है। नियमित श्रवण से मन पर नियंत्रण आता है, एकाग्रता बढ़ती है और शरीर में सकारात्मक ऊर्जा का संचार होता है।
केवल शरीर या मन की समृद्धि ही नहीं, हिंदू धर्म के मंत्रों का नियमित जाप सामाजिक बंधन को भी मजबूत करता है। जब बहुत से लोग एक साथ बैठकर मंत्रों का जाप या कीर्तन करते हैं, तो एक एकजुट और शांतिपूर्ण वातावरण बनता है, जो सामाजिक और आध्यात्मिक संबंधों को मजबूत करता है।

इसी कारण, प्रत्येक हिंदू का कर्तव्य है कि वह मंत्रों के इस आध्यात्मिक विज्ञान को नियमित रूप से अपने जीवन में स्थान दे। यदि जाप करना संभव न हो, तो कम से कम हर दिन कुछ देर के लिए मंत्रों को सुनना चाहिए। यह न केवल व्यक्तिगत मानसिक शांति देगा, बल्कि पारिवारिक और सामाजिक स्तर पर एकता और सकारात्मकता भी फैलाएगा। इस नियमित अभ्यास के माध्यम से ही हिंदू धर्म की शाश्वत महिमा और सहिष्णुता का संदेश चारों ओर आसानी से पहुँच सकता है।'''
  };

  // Request recording permission - Uses PermissionService (native iOS, permission_handler on Android)
  Future<bool> requestPermission() async {
    try {
      print('=== MICROPHONE PERMISSION REQUEST START ===');
      
      // Use PermissionService: native on iOS, permission_handler on Android
      final granted = await PermissionService.requestMicrophonePermission();
      
      print('=== PERMISSION REQUEST RESULT ===');
      print('Granted: $granted');
      print('=== MICROPHONE PERMISSION REQUEST END ===');
      
      return granted;
    } catch (e, stackTrace) {
      print('=== ERROR REQUESTING MICROPHONE PERMISSION ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }

  // Check if permission is permanently denied (safe fallback)
  Future<bool> isPermissionPermanentlyDenied() async {
    // Check native authoritative status first
    final grantedNative = await PermissionService.isMicrophoneGranted();
    if (grantedNative) {
      return false; // Not denied at all
    }

    // Native says not granted — now consult permission_handler only for "permanentlyDenied" info
    // But only use permission_handler when it's meaningful (Android or if native denies)
    try {
      // import dart:io at top if not already present
      if (!Platform.isIOS) {
        final phStatus = await Permission.microphone.status;
        return phStatus == PermissionStatus.permanentlyDenied;
      } else {
        // On iOS: plugin has shown mismatch previously. We assume native denial is not necessarily permanent.
        // Best behavior: ask user to open Settings if they repeatedly deny.
        return false;
      }
    } catch (e) {
      // Conservative default: not permanently denied
      return false;
    }
  }

  // Start recording with real audio recording
  Future<bool> startRecording() async {
    try {
      if (_isRecording) return false;

      // Request permission
      final hasPermission = await requestPermission();
      if (!hasPermission) {
        print('Permission denied, cannot start recording');
        return false;
      }

      // Check if recorder is available
      if (!await _audioRecorder.hasPermission()) {
        print('Audio recorder does not have permission');
        return false;
      }

      // Get app directory
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      // Generate unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'recording_$timestamp.m4a';
      _currentRecordingPath = '${recordingsDir.path}/$filename';

      // Start real audio recording
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _currentRecordingPath!,
      );

      _isRecording = true;
      print('Recording started: $_currentRecordingPath');
      return true;
    } catch (e, stackTrace) {
      print('Error starting recording: $e');
      print('Stack trace: $stackTrace');
      _isRecording = false;
      return false;
    }
  }

  // Stop recording with real audio recording
  Future<String?> stopRecording() async {
    try {
      if (!_isRecording) return null;

      // Stop the real audio recording
      final path = await _audioRecorder.stop();
      
      if (path != null && path.isNotEmpty) {
        _currentRecordingPath = path;
        print('Recording stopped and saved: $_currentRecordingPath');
        
        // Wait a moment for file system to sync
        await Future.delayed(const Duration(milliseconds: 100));
        
        // Verify file exists and has content
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          final fileSize = await file.length();
          print('Recording file size: $fileSize bytes');
          if (fileSize > 0) {
            // Verify file is readable
            final canRead = await file.exists();
            print('File exists and is readable: $canRead');
            _isRecording = false;
            return _currentRecordingPath;
          } else {
            print('Warning: Recording file is empty');
          }
        } else {
          print('Error: Recording file does not exist at path: $_currentRecordingPath');
        }
      } else {
        print('Error: Audio recorder returned null or empty path');
      }

      _isRecording = false;
      return _currentRecordingPath;
    } catch (e, stackTrace) {
      print('Error stopping recording: $e');
      print('Stack trace: $stackTrace');
      _isRecording = false;
      return null;
    }
  }

  // Cancel recording
  Future<void> cancelRecording() async {
    try {
      if (_isRecording) {
        // Stop recording and delete the file
        await _audioRecorder.stop();
        
        // Delete the file if it exists
        if (_currentRecordingPath != null) {
          final file = File(_currentRecordingPath!);
          if (await file.exists()) {
            await file.delete();
            print('Cancelled recording and deleted file: $_currentRecordingPath');
          }
        }
        
        _isRecording = false;
        _currentRecordingPath = null;
      }
    } catch (e) {
      print('Error canceling recording: $e');
      _isRecording = false;
      _currentRecordingPath = null;
    }
  }

  // Save recording with name
  Future<bool> saveRecording(String name, String language) async {
    try {
      if (_currentRecordingPath == null) {
        print('Error: No recording path to save');
        return false;
      }

      // Get app directory
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      // Rename file to match the user's name (sanitize name for filename)
      final sanitizedName = name.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
      final newFilePath = '${recordingsDir.path}/$sanitizedName.m4a';
      
      // If file with same name exists, add timestamp
      final originalFile = File(_currentRecordingPath!);
      File finalFile = File(newFilePath);
      if (await finalFile.exists()) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        finalFile = File('${recordingsDir.path}/$sanitizedName\_$timestamp.m4a');
      }
      
      // Copy/rename the file
      await originalFile.copy(finalFile.path);
      print('Recording file saved to: ${finalFile.path}');

      // Generate UUID
      final uuid = _uuid.v4();
      
      // Create recording object with new file path
      final recording = VoiceRecording(
        id: uuid,
        name: name,
        language: language,
        filePath: finalFile.path,
        createdAt: DateTime.now(),
      );

      // Add to local list
      _recordings.add(recording);
      print('Recording added to local list: ${recording.name}');

      // Save to backend (with timeout, but await it)
      try {
        await _saveToBackend(recording).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            print('Backend save timeout (continuing with local save)');
            return;
          },
        );
        print('Recording saved to backend successfully');
      } catch (e) {
        print('Backend save failed (non-critical): $e');
        // Continue - local save is successful
      }

      // Clear current recording
      _currentRecordingPath = null;
      print('Recording saved successfully: $name');
      return true;
    } catch (e, stackTrace) {
      print('Error saving recording: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }

  // Save recording to backend (with file upload)
  Future<void> _saveToBackend(VoiceRecording recording) async {
    try {
      // Read the audio file
      final file = File(recording.filePath);
      if (!await file.exists()) {
        print('Error: Recording file does not exist: ${recording.filePath}');
        return;
      }

      final fileBytes = await file.readAsBytes();
      
      // Create multipart request for file upload
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://mock-api.colab-app.com/api/recordings'),
      );
      
      // Add headers
      request.headers['Authorization'] = 'Bearer mock-token';
      
      // Add fields
      request.fields['name'] = recording.name;
      request.fields['uuid'] = recording.id;
      request.fields['language'] = recording.language;
      request.fields['user_id'] = 'mock-user-id';
      request.fields['created_at'] = recording.createdAt.toIso8601String();
      
      // Add file
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          fileBytes,
          filename: '${recording.name}.m4a',
        ),
      );

      // Send request
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 10),
      );
      
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        print('Recording saved to backend successfully: ${recording.name}');
      } else {
        print('Failed to save recording to backend: ${response.statusCode}');
        print('Response: ${response.body}');
      }
    } on TimeoutException {
      print('Backend save timed out (mock API not available - this is expected)');
      rethrow; // Re-throw so caller can handle timeout
    } catch (e) {
      print('Error saving to backend: $e');
      rethrow; // Re-throw so caller can handle error
    }
  }

  // Load existing recordings from local storage
  Future<void> loadRecordings() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      
      print('Loading recordings from: ${recordingsDir.path}');
      
      if (!await recordingsDir.exists()) {
        print('Recordings directory does not exist, creating it...');
        await recordingsDir.create(recursive: true);
        // Don't clear existing recordings if directory doesn't exist
        // They might be in memory from recent saves
        return;
      }

      final files = await recordingsDir.list().toList();
      print('Found ${files.length} files in recordings directory');
      
      // Create a map of existing recordings by file path to preserve names
      final existingRecordingsMap = <String, VoiceRecording>{};
      for (final recording in _recordings) {
        existingRecordingsMap[recording.filePath] = recording;
      }

      // Clear and rebuild list
      _recordings = [];

      for (final file in files) {
        if (file is File && file.path.endsWith('.m4a')) {
          try {
            final stat = await file.stat();
            print('Loading recording file: ${file.path}');
            
            // If we already have this recording in memory, preserve its name
            final existingRecording = existingRecordingsMap[file.path];
            final name = existingRecording?.name ?? _extractNameFromPath(file.path);
            final language = existingRecording?.language ?? 'English';
            final id = existingRecording?.id ?? _uuid.v4();
            final createdAt = existingRecording?.createdAt ?? stat.modified;
            
            final recording = VoiceRecording(
              id: id,
              name: name,
              language: language,
              filePath: file.path,
              createdAt: createdAt,
            );
            _recordings.add(recording);
            print('Added recording: $name (${file.path})');
          } catch (e) {
            print('Error processing file ${file.path}: $e');
            // Continue with other files
          }
        }
      }

      // Sort by creation date (newest first)
      _recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      print('Loaded ${_recordings.length} recordings from local storage');
      for (final recording in _recordings) {
        print('  - ${recording.name} (${recording.filePath})');
      }
    } catch (e, stackTrace) {
      print('Error loading recordings: $e');
      print('Stack trace: $stackTrace');
      // Don't clear recordings on error - keep what we have
    }
  }

  // Get list of recording names from backend
  Future<List<String>> _getBackendRecordingNames() async {
    try {
      final response = await http.get(
        Uri.parse('https://mock-api.colab-app.com/api/recordings/names'),
        headers: {
          'Authorization': 'Bearer mock-token',
        },
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['names'] is List) {
          final names = (data['names'] as List).map((e) => e.toString()).toList();
          print('Backend recording names: $names');
          return names;
        } else if (data is List) {
          final names = data.map((e) => e.toString()).toList();
          print('Backend recording names: $names');
          return names;
        }
      }
      print('Failed to get backend recording names: ${response.statusCode}');
      return [];
    } on TimeoutException {
      print('Backend names request timed out (mock API not available)');
      return [];
    } catch (e) {
      print('Error getting backend recording names: $e');
      return [];
    }
  }

  // Download recording file from backend by name
  Future<bool> _downloadRecordingFromBackend(String name) async {
    try {
      print('Downloading recording from backend: $name');
      
      final response = await http.get(
        Uri.parse('https://mock-api.colab-app.com/api/recordings/download?name=$name'),
        headers: {
          'Authorization': 'Bearer mock-token',
        },
      ).timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode == 200) {
        // Get app directory
        final directory = await getApplicationDocumentsDirectory();
        final recordingsDir = Directory('${directory.path}/recordings');
        if (!await recordingsDir.exists()) {
          await recordingsDir.create(recursive: true);
        }

        // Save file
        final file = File('${recordingsDir.path}/$name.m4a');
        await file.writeAsBytes(response.bodyBytes);
        
        // Add to local recordings list
        final recording = VoiceRecording(
          id: _uuid.v4(),
          name: name,
          language: 'English', // Default, could be enhanced
          filePath: file.path,
          createdAt: DateTime.now(),
        );
        _recordings.add(recording);
        
        print('Recording downloaded successfully: $name');
        return true;
      } else {
        print('Failed to download recording: ${response.statusCode}');
        return false;
      }
    } on TimeoutException {
      print('Download request timed out for: $name');
      return false;
    } catch (e) {
      print('Error downloading recording $name: $e');
      return false;
    }
  }

  // Sync recordings between local storage and backend
  Future<void> syncRecordings() async {
    try {
      print('=== Starting recording sync ===');
      
      // Load local recordings first
      await loadRecordings();
      final localNames = _recordings.map((r) => r.name).toSet();
      print('Local recording names: $localNames');

      // Get backend recording names
      final backendNames = await _getBackendRecordingNames();
      final backendNamesSet = backendNames.toSet();
      print('Backend recording names: $backendNamesSet');

      // Find recordings that exist in backend but not locally
      final missingInLocal = backendNamesSet.difference(localNames);
      print('Recordings missing in local: $missingInLocal');

      // Download missing recordings
      for (final name in missingInLocal) {
        await _downloadRecordingFromBackend(name);
      }

      // Find recordings that exist locally but not in backend
      final missingInBackend = localNames.difference(backendNamesSet);
      print('Recordings missing in backend: $missingInBackend');

      // Upload missing recordings
      for (final name in missingInBackend) {
        final recording = _recordings.firstWhere(
          (r) => r.name == name,
          orElse: () => throw Exception('Recording not found: $name'),
        );
        try {
          await _saveToBackend(recording).timeout(
            const Duration(seconds: 10),
          );
          print('Uploaded missing recording to backend: $name');
        } catch (e) {
          print('Failed to upload recording $name: $e');
          // Continue with other recordings
        }
      }

      // Reload recordings to ensure consistency
      await loadRecordings();
      print('=== Recording sync completed ===');
    } catch (e, stackTrace) {
      print('Error syncing recordings: $e');
      print('Stack trace: $stackTrace');
    }
  }

  // Extract name from file path
  String _extractNameFromPath(String path) {
    final filename = path.split('/').last;
    final nameWithoutExtension = filename.replaceAll('.m4a', '');
    
    // If it's a timestamp-based name (old format), format it nicely
    if (nameWithoutExtension.startsWith('recording_')) {
      return nameWithoutExtension.replaceAll('recording_', 'Recording ');
    }
    
    // If it has timestamp suffix (name_timestamp), remove the timestamp
    if (nameWithoutExtension.contains('_') && 
        RegExp(r'_\d+$').hasMatch(nameWithoutExtension)) {
      final parts = nameWithoutExtension.split('_');
      parts.removeLast(); // Remove timestamp
      return parts.join('_').replaceAll('_', ' ');
    }
    
    // Otherwise, just replace underscores with spaces
    return nameWithoutExtension.replaceAll('_', ' ');
  }

  // Delete recording
  Future<bool> deleteRecording(VoiceRecording recording) async {
    try {
      final file = File(recording.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      
      _recordings.remove(recording);
      return true;
    } catch (e) {
      print('Error deleting recording: $e');
      return false;
    }
  }

  // Check if name is unique
  bool isNameUnique(String name) {
    return !_recordings.any((recording) => recording.name.toLowerCase() == name.toLowerCase());
  }

  // Dispose
  Future<void> dispose() async {
    try {
      if (_isRecording) {
        await _audioRecorder.stop();
      }
      await _audioRecorder.dispose();
    } catch (e) {
      print('Error disposing audio recorder: $e');
    }
  }
}

class VoiceRecording {
  final String id;
  final String name;
  final String language;
  final String filePath;
  final DateTime createdAt;

  VoiceRecording({
    required this.id,
    required this.name,
    required this.language,
    required this.filePath,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'language': language,
      'filePath': filePath,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory VoiceRecording.fromJson(Map<String, dynamic> json) {
    return VoiceRecording(
      id: json['id'],
      name: json['name'],
      language: json['language'],
      filePath: json['filePath'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}
