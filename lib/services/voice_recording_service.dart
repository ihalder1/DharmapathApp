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
import '../constants/api_config.dart';
import 'auth_service.dart';

class VoiceRecordingService {
  static final VoiceRecordingService _instance = VoiceRecordingService._internal();
  factory VoiceRecordingService() => _instance;
  VoiceRecordingService._internal();

  final Uuid _uuid = const Uuid();
  AudioRecorder? _audioRecorder;
  
  bool _isRecording = false;
  String? _currentRecordingPath;
  List<VoiceRecording> _recordings = [];

  // Get or create audio recorder instance
  AudioRecorder get _recorder {
    _audioRecorder ??= AudioRecorder();
    return _audioRecorder!;
  }

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
      if (_isRecording) {
        print('Already recording, cannot start again');
        return false;
      }

      // Request permission (only once)
      final hasPermission = await requestPermission();
      if (!hasPermission) {
        print('Permission denied, cannot start recording');
        // Check if permission is permanently denied for better error handling
        final isPermanentlyDenied = await isPermissionPermanentlyDenied();
        if (isPermanentlyDenied) {
          print('Permission is permanently denied - user needs to enable in Settings');
        }
        return false;
      }

      // Note: We don't call _audioRecorder.hasPermission() here because:
      // 1. We already checked permission via PermissionService (native iOS check)
      // 2. On iOS, calling hasPermission() before the recorder is initialized can cause errors
      // 3. The start() method will handle initialization and permission validation

      // Get app directory
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      // Generate unique filename - use platform-appropriate extension
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      String extension;
      RecordConfig config;
      
      if (Platform.isAndroid) {
        // Android configuration - try AAC first (better compression, works on most devices)
        // If AAC doesn't work, fall back to WAV
        // Note: Android emulators don't have microphone input, so recordings will be blank
        extension = 'm4a';
        config = const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100, // 44.1kHz for good quality
          numChannels: 1, // Mono for voice recording
          autoGain: false, // Disable auto gain to prevent noise
          echoCancel: true, // Enable echo cancellation
          noiseSuppress: true, // Enable noise suppression
        );
        print('Starting Android recording with AAC encoder');
      } else {
        // iOS configuration - use AAC
        extension = 'm4a';
        config = const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1, // Mono for voice recording
        );
        print('Starting iOS recording with AAC encoder');
      }
      
      final filename = 'recording_$timestamp.$extension';
      _currentRecordingPath = '${recordingsDir.path}/$filename';

      // Ensure recorder is initialized (recreate if needed)
      try {
        await _recorder.start(
          config,
          path: _currentRecordingPath!,
        );
      } catch (e) {
        // If recorder is disposed or not initialized, recreate it
        print('Recorder error, recreating: $e');
        _audioRecorder?.dispose();
        _audioRecorder = AudioRecorder();
        await _recorder.start(
          config,
          path: _currentRecordingPath!,
        );
      }

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
      final path = await _recorder.stop();
      
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

  // Cancel recording (also handles cleanup of unsaved recordings)
  Future<void> cancelRecording() async {
    try {
      if (_isRecording) {
        // Stop recording first
        try {
          await _recorder.stop();
        } catch (e) {
          print('Error stopping recorder during cancel: $e');
        }
        _isRecording = false;
      }
      
      // Delete the file if it exists (whether currently recording or just unsaved)
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
          print('Cancelled recording and deleted file: $_currentRecordingPath');
        }
        _currentRecordingPath = null;
      }
    } catch (e) {
      print('Error canceling recording: $e');
      _isRecording = false;
      _currentRecordingPath = null;
    }
  }

  // Save recording with name
  // Returns a map with 'success' (bool) and 'errorMessage' (String?) keys
  Future<Map<String, dynamic>> saveRecording(String name, String language) async {
    try {
      if (_currentRecordingPath == null) {
        print('Error: No recording path to save');
        return {
          'success': false,
          'backendSuccess': false,
          'errorMessage': 'No recording path to save',
        };
      }

      // Get app directory
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      // Rename file to match the user's name (sanitize name for filename)
      final sanitizedName = name.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
      // Use platform-appropriate extension (both use m4a now)
      final extension = Platform.isAndroid ? 'm4a' : 'm4a';
      final newFilePath = '${recordingsDir.path}/$sanitizedName.$extension';
      
      // If file with same name exists, add timestamp
      final originalFile = File(_currentRecordingPath!);
      File finalFile = File(newFilePath);
      if (await finalFile.exists()) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        finalFile = File('${recordingsDir.path}/$sanitizedName\_$timestamp.$extension');
      }
      
      // Copy/rename the file (temporarily, will delete if backend fails)
      await originalFile.copy(finalFile.path);
      print('Recording file copied to: ${finalFile.path}');

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

      // Try to save to backend FIRST - if this fails, we won't save locally
      String? backendErrorMessage;
      bool backendSuccess = false;
      try {
        await _saveToBackend(recording).timeout(
          const Duration(seconds: 35), // Increased to allow for file upload
        );
        print('Recording saved to backend successfully');
        backendSuccess = true;
      } on TimeoutException {
        print('Backend save timeout - will not save locally');
        backendErrorMessage = 'Backend save timed out';
      } catch (e) {
        print('Backend save failed: $e');
        // Simple error message extraction - just get the message part
        backendErrorMessage = e.toString().replaceAll('Exception: ', '');
      }

      // If backend save failed, delete the local file and return error
      if (!backendSuccess) {
        try {
          if (await finalFile.exists()) {
            await finalFile.delete();
            print('Deleted local file because backend save failed: ${finalFile.path}');
          }
        } catch (e) {
          print('Warning: Could not delete local file: $e');
        }
        
        // Delete the original temporary file
        try {
          if (await originalFile.exists()) {
            await originalFile.delete();
            print('Deleted original temporary file: ${originalFile.path}');
          }
        } catch (e) {
          print('Warning: Could not delete original file: $e');
        }
        
        // Clear current recording
        _currentRecordingPath = null;
        
        return {
          'success': false,
          'backendSuccess': false,
          'errorMessage': backendErrorMessage ?? 'Failed to save recording to backend',
        };
      }

      // Backend save succeeded - now finalize local save
      // Delete the original temporary file
      try {
        if (await originalFile.exists()) {
          await originalFile.delete();
          print('Deleted original temporary file: ${originalFile.path}');
        }
      } catch (e) {
        print('Warning: Could not delete original file: $e');
        // Continue anyway - the new file is saved
      }

      // Add to local list only after backend success
      _recordings.add(recording);
      print('Recording added to local list: ${recording.name}');

      // Clear current recording
      _currentRecordingPath = null;
      print('Recording saved successfully (both local and backend): $name');
      
      // Return success
      return {
        'success': true,
        'backendSuccess': true,
        'errorMessage': null,
      };
    } catch (e, stackTrace) {
      print('Error saving recording: $e');
      print('Stack trace: $stackTrace');
      return {
        'success': false,
        'backendSuccess': false,
        'errorMessage': 'Failed to save recording: ${e.toString()}',
      };
    }
  }

  // Map language name to language code
  String _mapLanguageToCode(String language) {
    switch (language.toLowerCase()) {
      case 'english':
        return 'en-US';
      case 'bengali':
        return 'bn-IN'; // Bengali (India)
      case 'hindi':
        return 'hi-IN'; // Hindi (India)
      default:
        return 'en-US'; // Default to English
    }
  }

  // Map language code to language name
  String _mapCodeToLanguage(String code) {
    switch (code.toLowerCase()) {
      case 'en-us':
        return 'English';
      case 'bn-in':
        return 'Bengali';
      case 'hi-in':
        return 'Hindi';
      default:
        return 'English'; // Default to English
    }
  }

  // Save recording to backend (with base64 JSON body)
  Future<void> _saveToBackend(VoiceRecording recording) async {
    try {
      // Get auth token from AuthService
      final authService = AuthService();
      final accessToken = authService.accessToken;

      if (accessToken == null || accessToken.isEmpty) {
        print('❌ ERROR: No access token available for recording upload API');
        throw Exception('No authentication token found');
      }

      // Read the audio file
      final file = File(recording.filePath);
      if (!await file.exists()) {
        print('Error: Recording file does not exist: ${recording.filePath}');
        throw Exception('Recording file does not exist');
      }

      // Get file size and details
      final fileSize = await file.length();
      final filename = recording.filePath.split('/').last;
      print('✅ File verified: $fileSize bytes');
      print('📝 Filename: $filename');

      // Determine file extension and MIME type
      String fileExtension = '';
      String mimeType = 'audio/mp4'; // Default for m4a files
      
      if (filename.contains('.')) {
        fileExtension = filename.substring(filename.lastIndexOf('.'));
      } else {
        // Default to .m4a if no extension found
        fileExtension = '.m4a';
      }
      
      // Map extension to MIME type
      switch (fileExtension.toLowerCase()) {
        case '.m4a':
          mimeType = 'audio/mp4';
          break;
        case '.mp4':
          mimeType = 'audio/mp4';
          break;
        case '.mp3':
          mimeType = 'audio/mpeg';
          break;
        case '.wav':
          mimeType = 'audio/wav';
          break;
        case '.amr':
          mimeType = 'audio/amr';
          break;
        default:
          mimeType = 'audio/mp4'; // Default
      }

      // Read file as bytes and encode to base64
      final fileBytes = await file.readAsBytes();
      final base64Encoded = base64Encode(fileBytes);
      print('📦 Base64 encoded size: ${base64Encoded.length} characters');

      // Map language to code (e.g., "English" -> "en-US")
      final languageCode = _mapLanguageToCode(recording.language);
      
      // Create JSON body
      // fileName and recordingName are the same for now (as per user request)
      final requestBody = json.encode({
        'fileName': recording.name,
        'recordingName': recording.name,
        'fileExtension': fileExtension,
        'mimeType': mimeType,
        'language': languageCode,
        'recordingBase64': base64Encoded,
      });

      // Create PUT request with JSON body
      final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}');
      final headers = {
        'Content-Type': 'application/json',
        'x-api-key': ApiConfig.apiKey,
        'Authorization': 'Bearer $accessToken',
      };

      // Log detailed request information
      print('═══════════════════════════════════════════════════════════');
      print('🎤 UPLOAD RECORDING TO BACKEND API CALL (Base64 JSON)');
      print('═══════════════════════════════════════════════════════════');
      print('📤 REQUEST:');
      print('   URL: $url');
      print('   Method: PUT');
      print('   Recording Name: ${recording.name}');
      print('   Language: ${recording.language} -> $languageCode');
      print('   File: $filename ($fileSize bytes)');
      print('   File Extension: $fileExtension');
      print('   MIME Type: $mimeType');
      print('   Base64 Length: ${base64Encoded.length} characters');
      print('   File Path: ${recording.filePath}');
      print('   Headers: ${json.encode(headers)}');
      print('   Request Body (first 200 chars): ${requestBody.substring(0, requestBody.length > 200 ? 200 : requestBody.length)}...');
      print('   FULL TOKEN: $accessToken');
      print('═══════════════════════════════════════════════════════════');

      // Send PUT request
      final response = await http.put(
        url,
        headers: headers,
        body: requestBody,
      ).timeout(
        const Duration(seconds: 30),
      );

      print('📥 RESPONSE:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('═══════════════════════════════════════════════════════════');

      if (response.statusCode == 200 || response.statusCode == 201) {
        print('✅ Recording saved to backend successfully: ${recording.name}');
      } else {
        print('❌ Failed to save recording to backend: ${response.statusCode}');
        print('   Response: ${response.body}');
        
        // Try to extract error message from response body
        String errorMessage = 'Failed to save recording to backend';
        try {
          final responseData = json.decode(response.body);
          if (responseData is Map && responseData.containsKey('error')) {
            errorMessage = responseData['error'].toString();
          } else if (responseData is Map && responseData.containsKey('message')) {
            errorMessage = responseData['message'].toString();
          } else {
            errorMessage = 'Failed to save recording (Status: ${response.statusCode})';
          }
        } catch (e) {
          // If JSON parsing fails, use the raw response or default message
          if (response.body.isNotEmpty) {
            errorMessage = 'Failed to save recording: ${response.body}';
          } else {
            errorMessage = 'Failed to save recording (Status: ${response.statusCode})';
          }
        }
        
        throw Exception(errorMessage);
      }
    } on TimeoutException {
      print('❌ Backend save timed out');
      rethrow; // Re-throw so caller can handle timeout
    } catch (e, stackTrace) {
      print('❌ ERROR saving to backend: $e');
      print('   StackTrace: $stackTrace');
      rethrow; // Re-throw so caller can handle error
    }
  }

  // Download recording file from backend URL (dummy implementation for now)
  Future<bool> _downloadRecordingFromUrl({
    required String recordingUrl,
    required String localFilePath,
  }) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('📥 DOWNLOAD RECORDING FROM BACKEND');
      print('═══════════════════════════════════════════════════════════');
      print('   URL: $recordingUrl');
      print('   Local Path: $localFilePath');
      print('   ⚠️  NOTE: Download not implemented yet (URL not pre-signed)');
      print('═══════════════════════════════════════════════════════════');
      
      // TODO: Implement actual download when URLs are pre-signed
      // For now, just create a placeholder
      /*
      final response = await http.get(
        Uri.parse(recordingUrl),
        headers: {
          'x-api-key': ApiConfig.apiKey,
        },
      ).timeout(
        const Duration(seconds: 60),
      );

      if (response.statusCode == 200) {
        final file = File(localFilePath);
        await file.writeAsBytes(response.bodyBytes);
        print('✅ Recording downloaded successfully: $localFilePath');
        return true;
      } else {
        print('❌ Failed to download recording: ${response.statusCode}');
        return false;
      }
      */
      
      return false; // Return false for now since download is not implemented
    } catch (e, stackTrace) {
      print('❌ ERROR downloading recording: $e');
      print('   StackTrace: $stackTrace');
      return false;
    }
  }

  // Load recordings from backend and sync with local storage
  Future<void> loadRecordings() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('🔄 LOADING RECORDINGS (Backend + Local Sync)');
      print('═══════════════════════════════════════════════════════════');

      // 1. Fetch recordings from backend
      final backendRecordings = await _fetchRecordingsFromBackend();
      
      // 2. Get app directory
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      print('📂 Local recordings directory: ${recordingsDir.path}');

      // 3. Create a map of backend recordings by name for quick lookup
      final Map<String, Map<String, dynamic>> backendRecordingsMap = {};
      for (var backendRec in backendRecordings) {
        final name = backendRec['name']?.toString() ?? '';
        if (name.isNotEmpty) {
          backendRecordingsMap[name] = backendRec;
        }
      }

      // 4. Load local files
      final files = await recordingsDir.list().toList();
      print('📁 Found ${files.length} files in local directory');

      // 5. Clear and rebuild recordings list
      _recordings = [];

      // 6. Process backend recordings first
      for (var backendRec in backendRecordings) {
        try {
          final recordingId = backendRec['recording_id']?.toString() ?? _uuid.v4();
          final name = backendRec['name']?.toString() ?? '';
          final languageCode = backendRec['language']?.toString() ?? 'en-US';
          final language = _mapCodeToLanguage(languageCode);
          final createdAtStr = backendRec['created_at']?.toString() ?? '';
          final recordingUrl = backendRec['recording_url']?.toString() ?? '';
          final fileExtension = backendRec['file_extension']?.toString() ?? '.mp4';
          
          // Parse created_at date
          DateTime createdAt;
          try {
            createdAt = DateTime.parse(createdAtStr).toLocal();
          } catch (e) {
            print('⚠️  Could not parse date: $createdAtStr, using current time');
            createdAt = DateTime.now();
          }

          // Check if local file exists
          final sanitizedName = name.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
          final localFilePath = '${recordingsDir.path}/$sanitizedName$fileExtension';
          final localFile = File(localFilePath);
          final localFileExists = await localFile.exists();

          print('\n📝 Processing backend recording: $name');
          print('   ID: $recordingId');
          print('   Language: $language ($languageCode)');
          print('   Created: $createdAt');
          print('   Local file exists: $localFileExists');
          print('   Local path: $localFilePath');

          if (localFileExists) {
            // Local file exists - use it
            print('   ✅ Using existing local file');
            final recording = VoiceRecording(
              id: recordingId, // Use recording_id as id for backend recordings
              recordingId: recordingId, // Store recording_id separately
              name: name,
              language: language,
              filePath: localFilePath,
              createdAt: createdAt,
            );
            _recordings.add(recording);
          } else {
            // Local file doesn't exist - try to download (dummy for now)
            print('   ⬇️  Local file not found, attempting download...');
            final downloadSuccess = await _downloadRecordingFromUrl(
              recordingUrl: recordingUrl,
              localFilePath: localFilePath,
            );
            
            // Always add recording to list (even if download failed)
            // Use local file path if download succeeded, otherwise use a placeholder
            String finalFilePath = localFilePath;
            if (!downloadSuccess || !await localFile.exists()) {
              print('   ⚠️  Download not available (URL not pre-signed), adding to list anyway');
              // Still use the expected local path - file will be downloaded later when URLs are pre-signed
              finalFilePath = localFilePath;
            } else {
              print('   ✅ Downloaded successfully');
            }
            
            final recording = VoiceRecording(
              id: recordingId, // Use recording_id as id for backend recordings
              recordingId: recordingId, // Store recording_id separately
              name: name,
              language: language,
              filePath: finalFilePath,
              createdAt: createdAt,
            );
            _recordings.add(recording);
          }
        } catch (e) {
          print('❌ Error processing backend recording: $e');
          // Continue with other recordings
        }
      }

      // 7. Sort by creation date (newest first)
      _recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      print('\n✅ Loaded ${_recordings.length} recordings total');
      for (final recording in _recordings) {
        print('  - ${recording.name} (${recording.language}) - ${recording.filePath}');
      }
      print('═══════════════════════════════════════════════════════════');
    } catch (e, stackTrace) {
      print('❌ ERROR loading recordings: $e');
      print('Stack trace: $stackTrace');
      // Don't clear recordings on error - keep what we have
    }
  }

  // Fetch recordings list from backend
  Future<List<Map<String, dynamic>>> _fetchRecordingsFromBackend() async {
    try {
      final authService = AuthService();
      final accessToken = authService.accessToken;

      if (accessToken == null || accessToken.isEmpty) {
        print('❌ ERROR: No access token available for fetching recordings');
        return [];
      }

      final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}');
      final headers = {
        'x-api-key': ApiConfig.apiKey,
        'Authorization': 'Bearer $accessToken',
      };

      print('═══════════════════════════════════════════════════════════');
      print('📥 FETCH RECORDINGS FROM BACKEND API CALL');
      print('═══════════════════════════════════════════════════════════');
      print('📤 REQUEST:');
      print('   URL: $url');
      print('   Method: GET');
      print('   Headers: ${json.encode(headers)}');
      print('═══════════════════════════════════════════════════════════');

      final response = await http.get(
        url,
        headers: headers,
      ).timeout(
        const Duration(seconds: 30),
      );

      print('📥 RESPONSE:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('═══════════════════════════════════════════════════════════');

      if (response.statusCode == 200) {
        final List<dynamic> recordingsList = json.decode(response.body);
        print('✅ Successfully fetched ${recordingsList.length} recordings from backend');
        return recordingsList.map((rec) => rec as Map<String, dynamic>).toList();
      } else {
        print('❌ Failed to fetch recordings: ${response.statusCode}');
        print('   Response: ${response.body}');
        return [];
      }
    } on TimeoutException {
      print('❌ Backend fetch timed out');
      return [];
    } catch (e, stackTrace) {
      print('❌ ERROR fetching recordings from backend: $e');
      print('   StackTrace: $stackTrace');
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

        // Save file with platform-appropriate extension (both use m4a now)
        final extension = Platform.isAndroid ? 'm4a' : 'm4a';
        final file = File('${recordingsDir.path}/$name.$extension');
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
  // Note: loadRecordings() now automatically syncs with backend
  // This method is kept for backward compatibility
  Future<void> syncRecordings() async {
    try {
      print('=== Starting recording sync ===');
      // The new loadRecordings() method already handles backend sync
      await loadRecordings();
      print('=== Recording sync completed ===');
    } catch (e, stackTrace) {
      print('Error syncing recordings: $e');
      print('Stack trace: $stackTrace');
    }
  }

  // Check if file is a temporary/unsaved recording
  bool _isTemporaryFile(String nameWithoutExt) {
    // Check if it matches timestamp pattern (recording_1234567890 or just numbers)
    if (RegExp(r'^recording_\d+$').hasMatch(nameWithoutExt)) {
      return true;
    }
    // Check if it's just numbers (timestamp only)
    if (RegExp(r'^\d+$').hasMatch(nameWithoutExt)) {
      return true;
    }
    return false;
  }

  // Extract name from file path
  String _extractNameFromPath(String path) {
    final filename = path.split('/').last;
    // Remove .m4a, .mp4, .amr, and .wav extensions (all supported formats)
    String nameWithoutExtension = filename
        .replaceAll('.m4a', '')
        .replaceAll('.mp4', '')
        .replaceAll('.amr', '')
        .replaceAll('.wav', '');
    
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
      // Check if recording has recordingId (from backend)
      if (recording.recordingId == null || recording.recordingId!.isEmpty) {
        print('⚠️  Recording does not have recordingId, cannot delete from backend');
        print('   Recording name: ${recording.name}');
        // For old recordings without recordingId, just delete locally
        final file = File(recording.filePath);
        if (await file.exists()) {
          await file.delete();
          print('Deleted local recording file: ${recording.filePath}');
        }
        _recordings.remove(recording);
        return true;
      }

      // Delete from backend FIRST
      final backendSuccess = await _deleteFromBackend(recording);
      
      if (!backendSuccess) {
        print('❌ Backend delete failed, not deleting locally');
        return false;
      }

      // Backend delete succeeded - now delete locally
      final file = File(recording.filePath);
      if (await file.exists()) {
        await file.delete();
        print('✅ Deleted local recording file: ${recording.filePath}');
      }
      
      // Remove from local list
      _recordings.remove(recording);
      print('✅ Recording deleted successfully: ${recording.name}');
      
      return true;
    } catch (e, stackTrace) {
      print('❌ Error deleting recording: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }

  // Delete recording from backend
  Future<bool> _deleteFromBackend(VoiceRecording recording) async {
    try {
      final authService = AuthService();
      final accessToken = authService.accessToken;

      if (accessToken == null || accessToken.isEmpty) {
        print('❌ ERROR: No access token available for delete API');
        return false;
      }

      // Use recordingId from backend
      final recordingId = recording.recordingId!;
      final url = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}/$recordingId');
      final headers = {
        'x-api-key': ApiConfig.apiKey,
        'Authorization': 'Bearer $accessToken',
      };

      print('═══════════════════════════════════════════════════════════');
      print('🗑️  DELETE RECORDING FROM BACKEND API CALL');
      print('═══════════════════════════════════════════════════════════');
      print('📤 REQUEST:');
      print('   URL: $url');
      print('   Method: DELETE');
      print('   Recording ID: $recordingId');
      print('   Recording Name: ${recording.name}');
      print('   Headers: ${json.encode(headers)}');
      print('═══════════════════════════════════════════════════════════');

      final response = await http.delete(
        url,
        headers: headers,
      ).timeout(
        const Duration(seconds: 30),
      );

      print('📥 RESPONSE:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('═══════════════════════════════════════════════════════════');

      if (response.statusCode == 200 || response.statusCode == 204) {
        print('✅ Recording deleted from backend successfully: ${recording.name}');
        return true;
      } else {
        print('❌ Failed to delete recording from backend: ${response.statusCode}');
        print('   Response: ${response.body}');
        return false;
      }
    } on TimeoutException {
      print('❌ Backend delete timed out');
      return false;
    } catch (e, stackTrace) {
      print('❌ ERROR deleting from backend: $e');
      print('   StackTrace: $stackTrace');
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
      if (_isRecording && _audioRecorder != null) {
        await _recorder.stop();
      }
      if (_audioRecorder != null) {
        await _audioRecorder!.dispose();
        _audioRecorder = null;
      }
    } catch (e) {
      print('Error disposing audio recorder: $e');
    }
  }
}

class VoiceRecording {
  final String id;
  final String? recordingId; // Backend recording_id from API
  final String name;
  final String language;
  final String filePath;
  final DateTime createdAt;

  VoiceRecording({
    required this.id,
    this.recordingId, // Optional - only available for backend recordings
    required this.name,
    required this.language,
    required this.filePath,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'recordingId': recordingId,
      'name': name,
      'language': language,
      'filePath': filePath,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory VoiceRecording.fromJson(Map<String, dynamic> json) {
    return VoiceRecording(
      id: json['id'],
      recordingId: json['recordingId'],
      name: json['name'],
      language: json['language'],
      filePath: json['filePath'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

