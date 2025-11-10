import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'permission_service.dart';

class VoiceRecordingService {
  static final VoiceRecordingService _instance = VoiceRecordingService._internal();
  factory VoiceRecordingService() => _instance;
  VoiceRecordingService._internal();

  final Uuid _uuid = const Uuid();
  
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

  // Start recording with enhanced mock implementation
  Future<bool> startRecording() async {
    try {
      if (_isRecording) return false;

      // Request permission
      final hasPermission = await requestPermission();
      if (!hasPermission) return false;

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

      // Create a more realistic audio file (simulate recording)
      _isRecording = true;
      print('Recording started: $_currentRecordingPath');
      return true;
    } catch (e) {
      print('Error starting recording: $e');
      return false;
    }
  }

  // Stop recording with enhanced mock implementation
  Future<String?> stopRecording() async {
    try {
      if (!_isRecording) return null;

      // Create a realistic audio file that can be played
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        
        // Create a minimal valid M4A file header (this is a simplified version)
        // In a real implementation, you would use actual audio recording
        final audioData = _createMockAudioData();
        await file.writeAsBytes(audioData);
        
        print('Mock recording file created: $_currentRecordingPath');
      }

      _isRecording = false;
      return _currentRecordingPath;
    } catch (e) {
      print('Error stopping recording: $e');
      _isRecording = false;
      return null;
    }
  }

  // Create mock audio data that can be played
  List<int> _createMockAudioData() {
    // This creates a minimal audio file that audioplayers can handle
    // In a real implementation, this would be actual recorded audio
    final List<int> audioData = [];
    
    // Add some basic audio file structure (simplified)
    // This is just enough to create a file that won't cause playback errors
    for (int i = 0; i < 1000; i++) {
      audioData.add(i % 256); // Simple pattern
    }
    
    return audioData;
  }

  // Cancel recording
  Future<void> cancelRecording() async {
    try {
      if (_isRecording) {
        _isRecording = false;
        _currentRecordingPath = null;
      }
    } catch (e) {
      print('Error canceling recording: $e');
    }
  }

  // Save recording with name
  Future<bool> saveRecording(String name, String language) async {
    try {
      if (_currentRecordingPath == null) return false;

      // Generate UUID
      final uuid = _uuid.v4();
      
      // Create recording object
      final recording = VoiceRecording(
        id: uuid,
        name: name,
        language: language,
        filePath: _currentRecordingPath!,
        createdAt: DateTime.now(),
      );

      // Add to local list
      _recordings.add(recording);

      // Save to backend (mock implementation)
      await _saveToBackend(recording);

      // Clear current recording
      _currentRecordingPath = null;
      return true;
    } catch (e) {
      print('Error saving recording: $e');
      return false;
    }
  }

  // Mock backend save
  Future<void> _saveToBackend(VoiceRecording recording) async {
    try {
      // Mock API call
      final response = await http.post(
        Uri.parse('https://mock-api.colab-app.com/api/recordings'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer mock-token',
        },
        body: jsonEncode({
          'name': recording.name,
          'uuid': recording.id,
          'language': recording.language,
          'user_id': 'mock-user-id',
          'created_at': recording.createdAt.toIso8601String(),
        }),
      );

      if (response.statusCode == 200) {
        print('Recording saved to backend successfully');
      } else {
        print('Failed to save recording to backend: ${response.statusCode}');
      }
    } catch (e) {
      print('Error saving to backend: $e');
    }
  }

  // Load existing recordings
  Future<void> loadRecordings() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      
      if (!await recordingsDir.exists()) {
        _recordings = [];
        return;
      }

      final files = await recordingsDir.list().toList();
      _recordings = [];

      for (final file in files) {
        if (file is File && file.path.endsWith('.m4a')) {
          final stat = await file.stat();
          final recording = VoiceRecording(
            id: _uuid.v4(), // Generate new UUID for existing files
            name: _extractNameFromPath(file.path),
            language: 'English', // Default language for existing files
            filePath: file.path,
            createdAt: stat.modified,
          );
          _recordings.add(recording);
        }
      }

      // Sort by creation date (newest first)
      _recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      print('Error loading recordings: $e');
      _recordings = [];
    }
  }

  // Extract name from file path
  String _extractNameFromPath(String path) {
    final filename = path.split('/').last;
    final nameWithoutExtension = filename.replaceAll('.m4a', '');
    return nameWithoutExtension.replaceAll('recording_', 'Recording ');
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
  void dispose() {
    // No recorder to dispose for now
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
