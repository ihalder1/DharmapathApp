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

  /// QA/testing helper: take an existing audio file, copy it into our
  /// app recordings directory, and set it as the current recording.
  ///
  /// This allows the rest of the flow (playback, saveRecording -> backend upload)
  /// to stay identical to a freshly recorded file.
  Future<String?> setCurrentRecordingFromFile({
    required String sourcePath,
  }) async {
    try {
      if (_isRecording) {
        print('Cannot import file while recording');
        return null;
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        print('Import failed: source file does not exist: $sourcePath');
        return null;
      }

      final sourceSize = await sourceFile.length();
      if (sourceSize == 0) {
        print('Import failed: source file is empty (0 bytes): $sourcePath');
        return null;
      }

      // Quick header sniff to avoid importing non-audio (e.g., text files)
      try {
        final raf = await sourceFile.open();
        final headerBytes = await raf.read(16);
        await raf.close();

        bool looksLikeAudio = false;
        // WAV: "RIFF....WAVE"
        if (headerBytes.length >= 12) {
          final riff = String.fromCharCodes(headerBytes.take(4));
          final wave = String.fromCharCodes(headerBytes.skip(8).take(4));
          if (riff == 'RIFF' && wave == 'WAVE') {
            looksLikeAudio = true;
          }
        }
        // MP3: "ID3" tag or 0xFF 0xFB frame sync
        if (!looksLikeAudio && headerBytes.length >= 3) {
          final id3 = String.fromCharCodes(headerBytes.take(3));
          if (id3 == 'ID3') {
            looksLikeAudio = true;
          }
        }
        if (!looksLikeAudio && headerBytes.length >= 2) {
          if (headerBytes[0] == 0xFF && (headerBytes[1] & 0xE0) == 0xE0) {
            looksLikeAudio = true;
          }
        }
        // MP4/M4A: contains "ftyp" at bytes 4-7
        if (!looksLikeAudio && headerBytes.length >= 8) {
          final ftyp = String.fromCharCodes(headerBytes.skip(4).take(4));
          if (ftyp == 'ftyp') {
            looksLikeAudio = true;
          }
        }
        // AMR: "#!AMR"
        if (!looksLikeAudio && headerBytes.length >= 5) {
          final amr = String.fromCharCodes(headerBytes.take(5));
          if (amr == '#!AMR') {
            looksLikeAudio = true;
          }
        }

        if (!looksLikeAudio) {
          print('Import failed: file header does not look like audio');
          return null;
        }
      } catch (e) {
        // If header sniff fails, don't block import, but log it
        print('Warning: could not sniff file header: $e');
      }

      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final srcName = sourceFile.path.split('/').last;
      String ext = '';
      final dotIdx = srcName.lastIndexOf('.');
      if (dotIdx != -1 && dotIdx < srcName.length - 1) {
        ext = srcName.substring(dotIdx).toLowerCase();
      }
      // Only allow known audio extensions; otherwise fail fast
      const allowed = <String>{'.m4a', '.mp4', '.mp3', '.wav', '.aac', '.amr'};
      if (ext.isEmpty || !allowed.contains(ext)) {
        print('Import failed: unsupported extension "$ext" for $srcName');
        return null;
      }

      final destPath = '${recordingsDir.path}/import_$timestamp$ext';
      final destFile = await sourceFile.copy(destPath);

      final destSize = await destFile.length();
      print('Imported recording file: $destPath ($destSize bytes)');

      _currentRecordingPath = destPath;
      return _currentRecordingPath;
    } catch (e, stackTrace) {
      print('Error importing recording file: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  // Language content
  static const Map<String, String> languageContent = {
    'English': '''The sacred practice of meditation quickly brings a calm joy to every human mind. Just by vocalizing ‘Om’, one can feel a bright, vivid resonance that zaps away all stress and anxiety. We must realize that big, quiet breaths help us excel in finding our inner peace. Every rhythmic hymn is a unique gift, providing a zest for life that few other things can match''',
    
    'Bengali': '''ঋষিদের মতে, বৈদিক মন্ত্রের গুঞ্জন আমাদের অন্তরাত্মাকে জাগ্রত করে। যখন কেউ শুদ্ধ উচ্চারণে ‘ওঁ’ কার ধ্বনি উচ্চারণ করে, তখন তার মস্তিষ্কের স্নায়ুতন্ত্রে এক অলৌকিক প্রশান্তি ছড়িয়ে পড়ে। এই পবিত্র শব্দতরঙ্গ কেবল আধ্যাত্মিক উন্নতির পথ দেখায় না, বরং রক্তচাপ নিয়ন্ত্রণ ও স্মৃতিশক্তি বৃদ্ধিতেও অভাবনীয় সাহায্য করে। মন্ত্রের প্রতিটি অক্ষর বা বর্ণ এমনভাবে বিন্যস্ত থাকে যা আমাদের শরীরের সূক্ষ্ম চক্রগুলোকে সক্রিয় করে তোলে। তাই প্রতিদিন নিয়ম করে স্তোত্র পাঠ করলে মানুষের জীবনে শৃঙ্খলা ও অখণ্ড আনন্দ ফিরে আসে। এটি প্রাচীন ধ্বনি বিজ্ঞানের এক সার্থক প্রয়োগ যা আজও বিস্ময়করভাবে কার্যকর''',
    
    'Hindi': '''मंत्रों की पवित्र शक्ति हमारे अंतर्मन को जागृत करती है। ऋषि-मुनियों के अनुसार, शुद्ध उच्चारण के साथ किया गया जप मस्तिष्क की कोशिकाओं में एक अद्भुत स्पंदन पैदा करता है। जब हम पूर्ण एकाग्रता से 'ॐ' का उच्चारण करते हैं, तो यह मानसिक तनाव को क्षण भर में दूर कर देता है। यह प्राचीन विज्ञान न केवल हृदय की गति को संतुलित रखता है, बल्कि व्यक्ति के आत्मज्ञान और बौद्धिक क्षमता को भी प्रखर बनाता है। मंत्र साधना जीवन में शांति, स्वास्थ्य और अटूट आनंद का संचार करने वाला एक अद्वितीय मार्ग है''',

    'Telugu': '''మంత్రం యొక్క పవిత్రమైన ధ్వని మనస్సును ఉత్తేజపరుస్తుంది. ప్రతి మంత్రంలో ఒక ప్రత్యేకమైన శక్తి ఉంది, ఇది మన నాడీ వ్యవస్థను శాంతపరుస్తుంది. ఓంకార నాదం మనలోని ఒత్తిడిని తొలగించి, ఏకాగ్రతను పెంచుతుంది. రోజువారీ మంత్ర పఠనం వల్ల శారీరక ఆరోగ్యం మరియు మానసిక ప్రశాంతత లభిస్తాయి. ఇది పురాతన ధ్వని శాస్త్రం యొక్క గొప్ప అద్భుతం. క్రమం తప్పకుండా మంత్ర జపం చేయడం వల్ల జీవితంలో ఒక కొత్త ఉత్సాహం మరియు దివ్యమైన ఆనందం కలుగుతుంది''',

    'Tamil': '''மந்திரங்களின் புனிதமான ஓசை நம் ஆன்மாவைத் தட்டி எழுப்புகிறது. மந்திரங்களைச் சுத்தமான உச்சரிப்புடன் சொல்வது, நம் மூளையின் அலைகளைச் சீராக்கி அமைதியைத் தருகிறது. 'ஓம்' என்ற பிரணவ மந்திரம் மன அழுத்தத்தைப் போக்கி, கவனத்தை ஒருமுகப்படுத்த உதவுகிறது. இந்தத் தொன்மையான ஒலி அறிவியல், உடலையும் மனதையும் ஆரோக்கியமாக வைக்கிறது. தினமும் மந்திரங்களைச் சொல்வது, வாழ்க்கையில் புதிய ஆற்றலையும், தெளிவான சிந்தனையையும், உண்மையான மகிழ்ச்சியையும் கொண்டு வரும்.''',

    'Malayalam': '''മന്ത്രങ്ങളുടെ പരിശുദ്ധമായ ശബ്ദം നമ്മുടെ ആത്മാവിനെ ഉണർത്തുന്നു. മന്ത്രങ്ങൾ ശരിയായ ഉച്ചാരണത്തോടെ ജപിക്കുന്നത് തലച്ചോറിലെ നാഡീവ്യവസ്ഥയിൽ അത്ഭുതകരമായ മാറ്റങ്ങൾ വരുത്തുന്നു. ‘ഓം’ എന്ന മന്ത്രം മനസ്സിന്റെ സമ്മർദ്ദം കുറയ്ക്കാനും ഏകാഗ്രത വർദ്ധിപ്പിക്കാനും സഹായിക്കുന്നു. ഈ പുരാതന ശബ്ദശാസ്ത്രം നമ്മുടെ ശരീരത്തെയും മനസ്സിനെയും ആരോഗ്യകരമായി നിലനിർത്താൻ സഹായിക്കുന്നു. ദിവസവും മന്ത്രങ്ങൾ ജപിക്കുന്നത് നമ്മുടെ ജീവിതത്തിൽ സമാധാനവും, പുതിയ ഊർജ്ജവും, സന്തോഷവും നിറയ്ക്കുന്നു.''',

    'Kannada': '''ಮಂತ್ರಗಳ ಪವಿತ್ರ ಧ್ವನಿಯು ನಮ್ಮ ಆತ್ಮವನ್ನು ಜಾಗೃತಗೊಳಿಸುತ್ತದೆ. ಶುದ್ಧ ಉಚ್ಚಾರಣೆಯೊಂದಿಗೆ ಮಂತ್ರಗಳನ್ನು ಪಠಿಸುವುದರಿಂದ ನಮ್ಮ ಮಿದುಳಿನ ನರಮಂಡಲದಲ್ಲಿ ಅಪೂರ್ವವಾದ ಕಂಪನ ಉಂಟಾಗುತ್ತದೆ. ‘ಓಂ’ಕಾರದ ನಾದವು ಮನಸ್ಸಿನ ಒತ್ತಡವನ್ನು ಕಡಿಮೆ ಮಾಡಿ, ಏಕಾಗ್ರತೆಯನ್ನು ಹೆಚ್ಚಿಸಲು ಸಹಕಾರಿಯಾಗಿದೆ. ಈ ಪ್ರಾಚೀನ ಧ್ವನಿ ವಿಜ್ಞಾನವು ನಮ್ಮ ಶರೀರ ಮತ್ತು ಮನಸ್ಸಿನ ಸಮತೋಲನವನ್ನು ಕಾಪಾಡುತ್ತದೆ. ಪ್ರತಿದಿನ ಮಂತ್ರಗಳನ್ನು ಪಠಿಸುವುದರಿಂದ ಜೀವನದಲ್ಲಿ ಶಾಂತಿ, ಆರೋಗ್ಯ ಮತ್ತು ಅಖಂಡ ಆನಂದವು ಲಭಿಸುತ್ತದೆ. ಇದು ಆಧ್ಯಾತ್ಮಿಕ ಶಕ್ತಿಯನ್ನು ವೃದ್ಧಿಸುವ ಒಂದು ಅದ್ಭುತ ಮಾರ್ಗವಾಗಿದೆ.''',

    'Gujarati': '''મંત્રોની પવિત્ર ધ્વનિ આપણા આત્માને જાગૃત કરે છે. ઋષિ-મુનિઓના જણાવ્યા અનુસાર, શુદ્ધ ઉચ્ચારણ સાથે કરવામાં આવેલો મંત્રોચ્ચાર મગજની કોશિકાઓમાં એક અદભૂત સ્પંદન પેદા કરે છે. જ્યારે આપણે પૂરી એકાગ્રતાથી 'ૐ' નો ઉચ્ચાર કરીએ છીએ, ત્યારે તે માનસિક તણાવને ક્ષણવારમાં દૂર કરી દે છે. આ પ્રાચીન વિજ્ઞાન માત્ર હૃદયના ધબકારાને સંતુલિત નથી રાખતું, પરંતુ વ્યક્તિના આત્મજ્ઞાન અને બૌદ્ધિક ક્ષમતાને પણ પ્રખર બનાવે છે. મંત્ર સાધના જીવનમાં શાંતિ, સ્વાસ્થ્ય અને અખંડ આનંદનો સંચાર કરનારો એક અદ્વિતીય માર્ગ છે''',

    'Punjabi': '''ਮੰਤਰਾਂ ਦੀ ਪਵਿੱਤਰ ਆਵਾਜ਼ ਸਾਡੀ ਆਤਮਾ ਨੂੰ ਜਾਗ੍ਰਿਤ ਕਰਦੀ ਹੈ। ਰਿਸ਼ੀਆਂ-ਮੁਨੀਆਂ ਅਨੁਸਾਰ, ਸ਼ੁੱਧ ਉਚਾਰਨ ਨਾਲ ਕੀਤਾ ਗਿਆ ਜਾਪ ਸਾਡੇ ਦਿਮਾਗ ਦੀਆਂ ਨਸਾਂ ਵਿੱਚ ਇੱਕ ਅਦਭੁਤ ਕੰਬਣੀ ਪੈਦਾ ਕਰਦਾ ਹੈ। ਜਦੋਂ ਅਸੀਂ ਪੂਰੀ ਇਕਾਗਰਤਾ ਨਾਲ 'ਓਂਕਾਰ' ਦਾ ਉਚਾਰਨ ਕਰਦੇ ਹਾਂ, ਤਾਂ ਇਹ ਸਾਡੇ ਮਾਨਸਿਕ ਤਣਾਅ ਨੂੰ ਤੁਰੰਤ ਦੂਰ ਕਰ ਦਿੰਦਾ ਹੈ। ਇਹ ਪ੍ਰਾਚੀਨ ਵਿਗਿਆਨ ਨਾ ਕੇਵਲ ਸਾਡੇ ਦਿਲ ਦੀ ਧੜਕਣ ਨੂੰ ਸੰਤੁਲਿਤ ਰੱਖਦਾ ਹੈ, ਸਗੋਂ ਸਾਡੀ ਆਤਮ-ਗਿਆਨ ਅਤੇ ਬੌਧਿਕ ਸਮਰੱਥਾ ਨੂੰ ਵੀ ਵਧਾਉਂਦਾ ਹੈ। ਮੰਤਰ ਸਾਧਨਾ ਜੀਵਨ ਵਿੱਚ ਸ਼ਾਂਤੀ, ਸਿਹਤ ਅਤੇ ਅਖੰਡ ਆਨੰਦ ਦਾ ਸੰਚਾਰ ਕਰਨ ਵਾਲਾ ਇੱਕ ਅਦੁੱਤੀ ਮਾਰਗ ਹੈ।''',

    'Nepali': '''मन्त्रहरूको पवित्र ध्वनिले हाम्रो आत्मालाई जागृत गर्छ। ऋषि-मुनिहरूका अनुसार, शुद्ध उच्चारणका साथ जप गर्दा मस्तिष्कको स्नायु प्रणालीमा एक अद्भुत कम्पन पैदा हुन्छ। जब हामी पूर्ण एकाग्रताका साथ ‘ॐ’ को उच्चारण गर्छौँ, तब यसले मानसिक तनावलाई तुरुन्तै कम गर्छ। यो प्राचीन ध्वनि विज्ञानले हाम्रो शरीर र मनलाई स्वस्थ राख्न मद्दत गर्दछ। दैनिक मन्त्र जप गर्नाले जीवनमा शान्ति, शक्ति र असीम आनन्दको सञ्चार हुन्छ। यो आध्यात्मिक उन्नति र बौद्धिक क्षमता बढाउने एक अनुपम मार्ग हो''',

    'Rajasthani': '''मंत्रां री पवित्र धूणी आपणा मन ने जागृत करै। ऋषि-मुनियां रै अनुसार, शुद्ध उचारण स्यूं जप करण स्यूं आपणा मस्तिष्क री नस-नस्यां में एक अनोखो स्पंदन पैदा होवै। जद आपां पूरै ध्यान स्यूं 'ॐ' रो उचारण करां, तो इण स्यूं मानसिक तनाव झटपट दूर हो जावै। यो प्राचीन विज्ञान आपणा शरीर अर मन नै स्वस्थ राखन रो घणो बड़ो साध्य अर मार्ग है। रोज मन्त्रां रो जाप करण स्यूं जीवन में शांति, शक्ति अर अटूट आनंद रो संचार होवै। यो एक असली ज्ञान है, जो आपणी एकाग्रता नै बढ़ावण में पूरी मदद करै'''
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
        // Android configuration - use AAC with optimized settings
        // Note: Android emulators don't have microphone input, so recordings will be blank
        extension = 'm4a';
        config = const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100, // 44.1kHz for good quality
          numChannels: 1, // Mono for voice recording
          autoGain: true, // Enable auto gain for better volume consistency
          echoCancel: true, // Enable echo cancellation
          noiseSuppress: true, // Enable noise suppression
        );
        print('Starting Android recording with AAC encoder (autoGain enabled)');
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
        await Future.delayed(const Duration(milliseconds: 200));
        
        // Verify file exists and has content
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          final fileSize = await file.length();
          print('Recording file size: $fileSize bytes');
          
          // Minimum file size check (very small files are likely empty/noise)
          // For a 1-second recording at 44.1kHz mono AAC, expect at least ~5KB
          const minFileSize = 5000; // 5KB minimum
          
          if (fileSize == 0) {
            print('❌ Error: Recording file is empty (0 bytes)');
            // Delete the empty file
            try {
              await file.delete();
            } catch (e) {
              print('Warning: Could not delete empty file: $e');
            }
            _currentRecordingPath = null;
            _isRecording = false;
            return null;
          } else if (fileSize < minFileSize) {
            print('⚠️  Warning: Recording file is very small ($fileSize bytes < $minFileSize bytes)');
            print('   This might indicate a recording issue (emulator/no mic)');
            // Still return the path, but log the warning
          }
          
          // Verify file is readable
          final canRead = await file.exists();
          print('File exists and is readable: $canRead');
          _isRecording = false;
          return _currentRecordingPath;
        } else {
          print('❌ Error: Recording file does not exist at path: $_currentRecordingPath');
          _currentRecordingPath = null;
        }
      } else {
        print('❌ Error: Audio recorder returned null or empty path');
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
      
      // Verify original file exists and is not empty before copying
      if (!await originalFile.exists()) {
        throw Exception('Original recording file does not exist');
      }
      final originalFileSize = await originalFile.length();
      if (originalFileSize == 0) {
        throw Exception('Recording file is empty (0 bytes) - recording may have failed');
      }
      print('Original recording file size: $originalFileSize bytes');
      
      // Copy/rename the file to final location - ALWAYS keep local copy
      await originalFile.copy(finalFile.path);
      print('Recording file copied to: ${finalFile.path}');
      
      // Verify the file was copied successfully and is not empty
      final copiedFile = File(finalFile.path);
      if (!await copiedFile.exists()) {
        throw Exception('Failed to copy recording file to final location');
      }
      final fileSize = await copiedFile.length();
      if (fileSize == 0) {
        throw Exception('Copied recording file is empty (0 bytes)');
      }
      if (fileSize != originalFileSize) {
        print('Warning: File size mismatch after copy (original: $originalFileSize, copied: $fileSize)');
      }
      print('Local file saved: ${finalFile.path} (${fileSize} bytes)');

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

      // Try to save to backend (but don't delete local file if it fails)
      String? backendErrorMessage;
      bool backendSuccess = false;
      try {
        await _saveToBackend(recording).timeout(
          const Duration(seconds: 35), // Increased to allow for file upload
        );
        print('Recording saved to backend successfully');
        backendSuccess = true;
      } on TimeoutException {
        print('Backend save timeout - local file will still be kept');
        backendErrorMessage = 'Backend save timed out';
      } catch (e) {
        print('Backend save failed: $e');
        // Simple error message extraction - just get the message part
        backendErrorMessage = e.toString().replaceAll('Exception: ', '');
      }

      // ALWAYS keep local file - delete original temporary file only
      try {
        if (await originalFile.exists()) {
          await originalFile.delete();
          print('Deleted original temporary file: ${originalFile.path}');
        }
      } catch (e) {
        print('Warning: Could not delete original file: $e');
        // Continue anyway - the new file is saved
      }

      // Add to local list - ALWAYS add, regardless of backend success
      _recordings.add(recording);
      print('Recording added to local list: ${recording.name}');

      // Clear current recording
      _currentRecordingPath = null;
      
      if (backendSuccess) {
        print('Recording saved successfully (both local and backend): $name');
        return {
          'success': true,
          'backendSuccess': true,
          'errorMessage': null,
        };
      } else {
        print('Recording saved locally but backend save failed: $name');
        return {
          'success': true, // Still success because local save worked
          'backendSuccess': false,
          'errorMessage': backendErrorMessage ?? 'Failed to save recording to backend',
        };
      }
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
      case 'telugu':
        return 'te-IN';
      case 'tamil':
        return 'ta-IN';
      case 'malayalam':
        return 'ml-IN';
      case 'kannada':
        return 'kn-IN';
      case 'gujarati':
        return 'gu-IN';
      case 'punjabi':
        return 'pa-IN';
      case 'nepali':
        return 'ne-NP';
      case 'rajasthani':
        // No widely used BCP-47 tag supported across services; use Hindi as closest fallback.
        return 'hi-IN';
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
      case 'te-in':
        return 'Telugu';
      case 'ta-in':
        return 'Tamil';
      case 'ml-in':
        return 'Malayalam';
      case 'kn-in':
        return 'Kannada';
      case 'gu-in':
        return 'Gujarati';
      case 'pa-in':
        return 'Punjabi';
      case 'ne-np':
        return 'Nepali';
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
      
      // Normalize extension (some pickers may give .aac etc)
      fileExtension = fileExtension.trim().toLowerCase();
      if (!fileExtension.startsWith('.')) {
        fileExtension = '.$fileExtension';
      }

      // Map extension to MIME type (backend expects a valid type/subtype)
      switch (fileExtension.toLowerCase()) {
        case '.m4a':
          // Many backends accept audio/mp4 for m4a; some prefer audio/m4a.
          // Prefer audio/mp4 to match existing recording flow in this app.
          mimeType = 'audio/mp4';
          break;
        case '.mp4':
          mimeType = 'audio/mp4';
          break;
        case '.aac':
          mimeType = 'audio/aac';
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

      // Defensive: ensure mimeType is always valid "type/subtype"
      final mimeParts = mimeType.split('/');
      if (mimeParts.length != 2 || mimeParts[0].isEmpty || mimeParts[1].isEmpty) {
        print('⚠️  Invalid mimeType computed ($mimeType), forcing audio/mp4');
        mimeType = 'audio/mp4';
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

  // Download recording file from backend URL (pre-signed URL)
  Future<bool> _downloadRecordingFromUrl({
    required String recordingUrl,
    required String localFilePath,
  }) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('📥 DOWNLOAD RECORDING FROM BACKEND (PRE-SIGNED URL)');
      print('═══════════════════════════════════════════════════════════');
      print('   URL: $recordingUrl');
      print('   Local Path: $localFilePath');
      print('═══════════════════════════════════════════════════════════');
      
      // Ensure the directory exists
      final file = File(localFilePath);
      final directory = file.parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        print('   📁 Created directory: ${directory.path}');
      }

      // Download from pre-signed URL (no auth headers needed for pre-signed URLs)
      final response = await http.get(
        Uri.parse(recordingUrl),
      ).timeout(
        const Duration(seconds: 60),
      );

      print('📥 DOWNLOAD RESPONSE:');
      print('   Status Code: ${response.statusCode}');
      print('   Content Length: ${response.bodyBytes.length} bytes');

      if (response.statusCode == 200) {
        // Write the file
        await file.writeAsBytes(response.bodyBytes);
        print('✅ Recording downloaded successfully: $localFilePath');
        print('   File size: ${await file.length()} bytes');
        print('═══════════════════════════════════════════════════════════');
        return true;
      } else {
        print('❌ Failed to download recording: ${response.statusCode}');
        print('   Response: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return false;
      }
    } on TimeoutException {
      print('❌ Download request timed out');
      print('═══════════════════════════════════════════════════════════');
      return false;
    } catch (e, stackTrace) {
      print('❌ ERROR downloading recording: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
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
          bool localFileExists = await localFile.exists();
          
          // Also check for files with .m4a extension (in case extension mismatch)
          String actualLocalPath = localFilePath;
          if (!localFileExists && fileExtension != '.m4a') {
            final m4aPath = '${recordingsDir.path}/$sanitizedName.m4a';
            final m4aFile = File(m4aPath);
            if (await m4aFile.exists()) {
              actualLocalPath = m4aPath;
              localFileExists = true;
            }
          }

          print('\n📝 Processing backend recording: $name');
          print('   ID: $recordingId');
          print('   Language: $language ($languageCode)');
          print('   Created: $createdAt');
          print('   Local file exists: $localFileExists');
          print('   Local path: $actualLocalPath');

          if (localFileExists) {
            // Verify file is not empty and is valid
            final actualFile = File(actualLocalPath);
            final fileSize = await actualFile.length();
            if (fileSize == 0) {
              print('   ⚠️  Local file exists but is empty - skipping');
              continue;
            }
            
            // Local file exists and is valid - use it
            print('   ✅ Using existing local file (${fileSize} bytes)');
            final recording = VoiceRecording(
              id: recordingId, // Use recording_id as id for backend recordings
              recordingId: recordingId, // Store recording_id separately
              name: name,
              language: language,
              filePath: actualLocalPath,
              createdAt: createdAt,
            );
            _recordings.add(recording);
          } else {
            // Local file doesn't exist - try to download
            print('   ⬇️  Local file not found, attempting download...');
            final downloadSuccess = await _downloadRecordingFromUrl(
              recordingUrl: recordingUrl,
              localFilePath: localFilePath,
            );
            
            // Only add to list if download succeeded and file exists
            if (downloadSuccess && await localFile.exists()) {
              print('   ✅ Downloaded successfully');
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
              print('   ⚠️  Download failed or file not available - skipping (will not add to list)');
              print('   ⚠️  Recording exists on backend but local file is not available');
              // Don't add to list - file doesn't exist locally and can't be downloaded
            }
          }
        } catch (e) {
          print('❌ Error processing backend recording: $e');
          // Continue with other recordings
        }
      }

      // 7. Process local-only files (files that exist locally but aren't in backend)
      print('\n📂 Processing local-only files...');
      final Set<String> processedFilePaths = {};
      final Set<String> processedNames = {}; // Track by name to avoid duplicates
      for (final recording in _recordings) {
        processedFilePaths.add(recording.filePath);
        processedNames.add(recording.name.toLowerCase());
      }
      
      for (final fileEntity in files) {
        if (fileEntity is File) {
          final filePath = fileEntity.path;
          
          // Skip if already processed (matched with backend recording by exact path)
          if (processedFilePaths.contains(filePath)) {
            print('   ⏭️  Skipping already processed file: ${filePath.split('/').last}');
            continue;
          }
          
          // Skip if it's a temporary or invalid file
          final filename = filePath.split('/').last;
          if (_isTemporaryOrInvalidFile(filename)) {
            print('   ⏭️  Skipping temporary/invalid file: $filename');
            continue;
          }
          
          try {
            // Extract name from filename
            final name = _extractNameFromPath(filePath);
            if (name.isEmpty) {
              print('   ⏭️  Skipping file with empty name: $filename');
              continue;
            }
            
            // Check for duplicate by name (case-insensitive)
            if (processedNames.contains(name.toLowerCase())) {
              print('   ⏭️  Skipping duplicate by name: $name (already processed)');
              continue;
            }
            
            // Verify file is not empty
            final fileSize = await fileEntity.length();
            if (fileSize == 0) {
              print('   ⏭️  Skipping empty file: $filename (0 bytes)');
              continue;
            }
            
            // Get file metadata
            final stat = await fileEntity.stat();
            final createdAt = stat.modified;
            
            // Determine language from file (default to English if unknown)
            final language = 'English'; // Default, could be enhanced to detect from metadata
            
            print('   📝 Found local-only recording: $name');
            print('      Path: $filePath');
            print('      Size: $fileSize bytes');
            print('      Created: $createdAt');
            
            // Create recording object for local-only file
            final recording = VoiceRecording(
              id: _uuid.v4(), // Generate new UUID for local-only recording
              name: name,
              language: language,
              filePath: filePath,
              createdAt: createdAt,
            );
            
            _recordings.add(recording);
            processedFilePaths.add(filePath); // Track path
            processedNames.add(name.toLowerCase()); // Track name to avoid duplicates
            print('   ✅ Added local-only recording to list');
          } catch (e) {
            print('   ❌ Error processing local file $filename: $e');
            // Continue with other files
          }
        }
      }
      
      // 8. Sort by creation date (newest first)
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

  // Check if file is temporary or invalid (should be skipped)
  bool _isTemporaryOrInvalidFile(String filename) {
    // Skip hidden files
    if (filename.startsWith('.')) {
      return true;
    }
    // Skip files without audio extensions
    final validExtensions = ['.m4a', '.mp4', '.mp3', '.wav', '.amr'];
    final hasValidExtension = validExtensions.any((ext) => filename.toLowerCase().endsWith(ext));
    if (!hasValidExtension) {
      return true;
    }
    // Skip files that are clearly temporary (e.g., .tmp, .temp)
    if (filename.toLowerCase().contains('.tmp') || filename.toLowerCase().contains('.temp')) {
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

