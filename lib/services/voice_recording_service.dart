import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'permission_service.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';

String _stripDataUrlBase64(String raw) {
  final t = raw.trim();
  const marker = 'base64,';
  final idx = t.indexOf(marker);
  if (idx >= 0) return t.substring(idx + marker.length);
  return t;
}

class VoiceRecordingService {
  static final VoiceRecordingService _instance =
      VoiceRecordingService._internal();
  factory VoiceRecordingService() => _instance;
  VoiceRecordingService._internal();

  static const String _prefsRecordingIdPaths = 'voice_recording_id_paths_v1';
  static const String _prefsPendingUploads = 'voice_pending_uploads_v1';

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

  static String sanitizeRecordingBaseName(String name) {
    return name.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
  }

  Future<Map<String, String>> _loadRecordingIdPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsRecordingIdPaths);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistRecordingIdPaths(Map<String, String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsRecordingIdPaths, json.encode(paths));
  }

  Future<void> _rememberPathForRecordingId(
    String recordingId,
    String path,
  ) async {
    final m = await _loadRecordingIdPaths();
    m[recordingId] = path;
    await _persistRecordingIdPaths(m);
  }

  Future<void> _removePathForRecordingId(String? recordingId) async {
    if (recordingId == null || recordingId.isEmpty) return;
    final m = await _loadRecordingIdPaths();
    m.remove(recordingId);
    await _persistRecordingIdPaths(m);
  }

  Future<List<Map<String, dynamic>>> _loadPendingUploads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsPendingUploads);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persistPendingUploads(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsPendingUploads, json.encode(items));
  }

  Future<void> _addPendingUpload({
    required String localPath,
    required String displayName,
    required String language,
  }) async {
    final list = await _loadPendingUploads();
    list.removeWhere((e) => e['localPath'] == localPath);
    list.add({
      'localPath': localPath,
      'displayName': displayName,
      'language': language,
    });
    await _persistPendingUploads(list);
  }

  Future<void> _removePendingUpload(String localPath) async {
    final list = await _loadPendingUploads();
    list.removeWhere((e) => e['localPath'] == localPath);
    await _persistPendingUploads(list);
  }

  /// Called when the Record Your Voice tab loads — retries queued uploads silently.
  Future<void> processPendingUploadsInBackground() async {
    final pending = await _loadPendingUploads();
    if (pending.isEmpty) return;

    for (final item in List<Map<String, dynamic>>.from(pending)) {
      final path = item['localPath']?.toString() ?? '';
      final name = item['displayName']?.toString() ?? '';
      final language = item['language']?.toString() ?? 'English';
      if (path.isEmpty || name.isEmpty) continue;

      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        await _removePendingUpload(path);
        continue;
      }

      final rec = VoiceRecording(
        id: _uuid.v4(),
        recordingId: null,
        name: name,
        language: language,
        filePath: path,
        createdAt: DateTime.now(),
      );

      final outcome = await _uploadRecordingWithRetries(
        recording: rec,
        showLogs: false,
      );
      if (outcome.ok) {
        await _removePendingUpload(path);
        if (outcome.recordingId != null && outcome.recordingId!.isNotEmpty) {
          await _rememberPathForRecordingId(outcome.recordingId!, path);
        }
      }
    }
  }

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
        return null;
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return null;
      }

      final sourceSize = await sourceFile.length();
      if (sourceSize == 0) {
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
          return null;
        }
      } catch (e) {
        // If header sniff fails, don't block import, but log it
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
        return null;
      }

      final destPath = '${recordingsDir.path}/import_$timestamp$ext';
      final destFile = await sourceFile.copy(destPath);

      final destSize = await destFile.length();

      _currentRecordingPath = destPath;
      return _currentRecordingPath;
    } catch (e, stackTrace) {
      return null;
    }
  }

  // Language content
  static const Map<String, String> languageContent = {
    'English':
        '''Every morning, spending a few minutes in prayer brings real peace to the mind. Saying God's name, lighting a lamp, or just sitting quietly brings a different kind of calm from within. Have you ever noticed that even on a bad day, you feel lighter after praying? This small habit can bring great peace into your life. Even five minutes a day is enough, and over time, you will feel more happiness and strength within yourself. So start today, and you'll feel the difference!''',

    'Bengali':
        '''প্রতিদিন সকালে একটু সময় বের করে প্রার্থনা করলে মন অনেক শান্ত হয়ে যায়। ঠাকুরের নাম নিলে, প্রদীপ জ্বালালে, কিংবা একটু ধ্যান করলে ভেতর থেকে এক অন্যরকম ভালো লাগা আসে। আপনি কি কখনো লক্ষ্য করেছেন, মন খারাপ থাকলেও প্রার্থনার পর কিছুটা হালকা লাগে? এই ছোট্ট অভ্যাসটাই আসলে জীবনে অনেক বড় শান্তি নিয়ে আসে। দিনে মাত্র পাঁচ মিনিটই যথেষ্ট, আর কিছুদিন পর দেখবেন নিজের মধ্যে অনেক বেশি আনন্দ আর শক্তি অনুভব করছেন। তাই আজ থেকেই শুরু করুন, দেখবেন ভালো লাগবে!''',

    'Hindi':
        '''रोज़ सुबह थोड़ा समय निकालकर प्रार्थना करने से मन बहुत शांत हो जाता है। भगवान का नाम लेने से, दीया जलाने से, या थोड़ा ध्यान करने से अंदर से एक अलग तरह की अच्छी अनुभूति होती है। क्या आपने कभी महसूस किया है कि मन खराब होने पर भी प्रार्थना के बाद थोड़ा हल्का लगता है? यह छोटी सी आदत असल में जीवन में बहुत बड़ी शांति लेकर आती है। दिन में सिर्फ पांच मिनट ही काफी है, और कुछ समय बाद आप खुद में ज्यादा खुशी और ताकत महसूस करेंगे। तो आज से ही शुरू करें, देखिएगा अच्छा लगेगा!''',

    'Telugu':
        '''ప్రతిరోజు ఉదయం కొంత సమయం ప్రార్థనలో గడిపితే మనసుకు చాలా ప్రశాంతత వస్తుంది. దేవుని పేరు చెప్పడం, దీపం వెలిగించడం, లేదా కొంచెం ధ్యానం చేయడం వల్ల లోపల నుండి ఒక విభిన్నమైన మంచి అనుభూతి కలుగుతుంది. మీరు ఎప్పుడైనా గమనించారా, మనసు బాగలేకపోయినా ప్రార్థన తర్వాత కొంచెం తేలికగా అనిపిస్తుందని? ఈ చిన్న అలవాటు నిజానికి జీవితంలో గొప్ప శాంతిని తీసుకువస్తుంది. రోజుకు కేవలం ఐదు నిమిషాలు చాలు, కొన్ని రోజుల తర్వాత మీలో ఎక్కువ సంతోషం మరియు శక్తి అనుభవమవుతుంది. కాబట్టి ఈరోజు నుంచే మొదలుపెట్టండి, మంచిగా అనిపిస్తుంది!''',

    'Tamil':
        '''தினமும் காலையில் கொஞ்சம் நேரம் பிரார்த்தனையில் செலவிட்டால் மனதிற்கு மிகுந்த அமைதி கிடைக்கும். கடவுளின் பெயரைச் சொல்வது, விளக்கேற்றுவது, அல்லது கொஞ்சம் தியானம் செய்வது உள்ளிருந்து ஒரு வித்தியாசமான நல்ல உணர்வைத் தரும். மனம் சரியில்லாத நேரத்திலும் பிரார்த்தனைக்குப் பிறகு கொஞ்சம் இலகுவாக உணர்கிறீர்களா என்பதை நீங்கள் கவனித்திருக்கிறீர்களா? இந்தச் சிறிய பழக்கம் வாழ்க்கையில் பெரிய அமைதியைக் கொண்டு வரும். நாளொன்றுக்கு வெறும் ஐந்து நிமிடங்கள் போதும், சில நாட்களில் உங்களுக்குள் அதிக மகிழ்ச்சியும் சக்தியும் உணரத் தொடங்குவீர்கள். எனவே இன்றே தொடங்குங்கள், நல்லா இருக்கும்!''',

    'Malayalam':
        '''എല്ലാ ദിവസവും രാവിലെ അൽപ്പം സമയം പ്രാർത്ഥനയ്ക്കായി ചെലവഴിച്ചാൽ മനസ്സിന് വലിയ ശാന്തി ലഭിക്കും. ദൈവത്തിന്റെ പേര് ചൊല്ലുന്നതും, വിളക്ക് കത്തിക്കുന്നതും, അല്ലെങ്കിൽ അൽപ്പം ധ്യാനം ചെയ്യുന്നതും ഉള്ളിൽ നിന്ന് ഒരു വ്യത്യസ്തമായ നല്ല അനുഭൂതി തരും. മനസ്സ് മോശമായിരിക്കുമ്പോഴും പ്രാർത്ഥനയ്ക്ക് ശേഷം അൽപ്പം ലഘുവായി തോന്നുന്നത് നിങ്ങൾ ശ്രദ്ധിച്ചിട്ടുണ്ടോ? ഈ ചെറിയ ശീലം ജീവിതത്തിൽ വലിയ സമാധാനം കൊണ്ടുവരും. ഒരു ദിവസം വെറും അഞ്ച് മിനിറ്റ് മതി, കുറച്ച് ദിവസങ്ങൾക്കുള്ളിൽ നിങ്ങളിൽ കൂടുതൽ സന്തോഷവും ശക്തിയും അനുഭവപ്പെടും. അതിനാൽ ഇന്ന് മുതൽ തുടങ്ങൂ, നല്ലതായി തോന്നും!''',

    'Kannada':
        '''ಪ್ರತಿದಿನ ಬೆಳಿಗ್ಗೆ ಸ್ವಲ್ಪ ಸಮಯವನ್ನು ಪ್ರಾರ್ಥನೆಗೆ ಮೀಸಲಿಟ್ಟರೆ ಮನಸ್ಸಿಗೆ ಬಹಳ ಶಾಂತಿ ಸಿಗುತ್ತದೆ. ದೇವರ ಹೆಸರು ಹೇಳುವುದು, ದೀಪ ಹಚ್ಚುವುದು, ಅಥವಾ ಸ್ವಲ್ಪ ಧ್ಯಾನ ಮಾಡುವುದರಿಂದ ಒಳಗಿನಿಂದ ಒಂದು ವಿಭಿನ್ನವಾದ ಒಳ್ಳೆಯ ಅನುಭವ ಸಿಗುತ್ತದೆ. ಮನಸ್ಸು ಕೆಟ್ಟಿದ್ದರೂ ಪ್ರಾರ್ಥನೆಯ ನಂತರ ಸ್ವಲ್ಪ ಹಗುರ ಅನಿಸುತ್ತದೆ ಎಂದು ನೀವು ಎಂದಾದರೂ ಗಮನಿಸಿದ್ದೀರಾ? ಈ ಚಿಕ್ಕ ಅಭ್ಯಾಸ ನಿಜವಾಗಿಯೂ ಜೀವನದಲ್ಲಿ ದೊಡ್ಡ ಶಾಂತಿಯನ್ನು ತರುತ್ತದೆ. ದಿನಕ್ಕೆ ಕೇವಲ ಐದು ನಿಮಿಷ ಸಾಕು, ಕೆಲವು ದಿನಗಳ ನಂತರ ನಿಮ್ಮಲ್ಲಿ ಹೆಚ್ಚು ಸಂತೋಷ ಮತ್ತು ಶಕ್ತಿ ಅನುಭವಕ್ಕೆ ಬರುತ್ತದೆ. ಹಾಗಾಗಿ ಇಂದಿನಿಂದಲೇ ಶುರು ಮಾಡಿ, ಚೆನ್ನಾಗಿ ಅನಿಸುತ್ತದೆ!''',

    'Gujarati':
        '''દરરોજ સવારે થોડો સમય પ્રાર્થનામાં વિતાવવાથી મનને ઘણી શાંતિ મળે છે. ભગવાનનું નામ લેવાથી, દીવો પ્રગટાવવાથી, અથવા થોડું ધ્યાન કરવાથી અંદરથી એક અલગ પ્રકારની સારી લાગણી આવે છે. શું તમે ક્યારેય ધ્યાન આપ્યું છે કે મન ખરાબ હોય તો પણ પ્રાર્થના પછી થોડું હળવું લાગે છે? આ નાની આદત ખરેખર જીવનમાં મોટી શાંતિ લાવે છે. દિવસમાં ફક્ત પાંચ મિનિટ પૂરતી છે, અને થોડા સમય પછી તમને તમારામાં વધુ ખુશી અને શક્તિનો અનુભવ થશે. તો આજથી જ શરૂ કરો, સારું લાગશે!''',

    'Punjabi':
        '''ਹਰ ਰੋਜ਼ ਸਵੇਰੇ ਥੋੜ੍ਹਾ ਸਮਾਂ ਕੱਢ ਕੇ ਪ੍ਰਾਰਥਨਾ ਕਰਨ ਨਾਲ ਮਨ ਨੂੰ ਬਹੁਤ ਸ਼ਾਂਤੀ ਮਿਲਦੀ ਹੈ। ਰੱਬ ਦਾ ਨਾਮ ਲੈਣ ਨਾਲ, ਦੀਵਾ ਜਗਾਉਣ ਨਾਲ, ਜਾਂ ਥੋੜ੍ਹਾ ਧਿਆਨ ਕਰਨ ਨਾਲ ਅੰਦਰੋਂ ਇੱਕ ਵੱਖਰੀ ਤਰ੍ਹਾਂ ਦੀ ਚੰਗੀ ਭਾਵਨਾ ਆਉਂਦੀ ਹੈ। ਕੀ ਤੁਸੀਂ ਕਦੇ ਦੇਖਿਆ ਹੈ ਕਿ ਮਨ ਖਰਾਬ ਹੋਣ ਤੇ ਵੀ ਪ੍ਰਾਰਥਨਾ ਤੋਂ ਬਾਅਦ ਥੋੜ੍ਹਾ ਹਲਕਾ ਲੱਗਦਾ ਹੈ? ਇਹ ਛੋਟੀ ਜਿਹੀ ਆਦਤ ਅਸਲ ਵਿੱਚ ਜ਼ਿੰਦਗੀ ਵਿੱਚ ਵੱਡੀ ਸ਼ਾਂਤੀ ਲਿਆਉਂਦੀ ਹੈ। ਦਿਨ ਵਿੱਚ ਸਿਰਫ਼ ਪੰਜ ਮਿੰਟ ਹੀ ਕਾਫ਼ੀ ਹਨ, ਅਤੇ ਕੁਝ ਦਿਨਾਂ ਬਾਅਦ ਤੁਸੀਂ ਆਪਣੇ ਵਿੱਚ ਜ਼ਿਆਦਾ ਖੁਸ਼ੀ ਅਤੇ ਤਾਕਤ ਮਹਿਸੂਸ ਕਰੋਗੇ। ਇਸ ਲਈ ਅੱਜ ਤੋਂ ਹੀ ਸ਼ੁਰੂ ਕਰੋ, ਚੰਗਾ ਲੱਗੇਗਾ!''',

    'Nepali':
        '''हरेक दिन बिहान अलिकति समय निकालेर प्रार्थना गर्दा मनलाई धेरै शान्ति मिल्छ। भगवानको नाम लिंदा, बत्ती बाल्दा, वा अलिकति ध्यान गर्दा भित्रबाट एउटा फरक किसिमको राम्रो अनुभूति आउँछ। के तपाईंले कहिल्यै याद गर्नुभएको छ, मन नराम्रो हुँदा पनि प्रार्थना पछि अलि हल्का महसुस हुन्छ भनेर? यो सानो बानीले वास्तवमा जीवनमा ठूलो शान्ति ल्याउँछ। दिनको जम्मा पाँच मिनेट नै पुग्छ, र केही दिनपछि तपाईंले आफूभित्र बढी खुशी र शक्ति महसुस गर्नुहुनेछ। त्यसैले आजैबाट सुरु गर्नुहोस्, राम्रो महसुस हुनेछ!''',

    'Marathi':
        '''रोज सकाळी थोडा वेळ प्रार्थनेत घालवला तर मनाला खूप शांती मिळते. देवाचे नाव घेणे, दिवा लावणे, किंवा थोडे ध्यान करणे यामुळे आतून एक वेगळीच चांगली भावना येते. तुम्ही कधी लक्षात घेतले आहे का, मन वाईट असतानाही प्रार्थनेनंतर थोडे हलके वाटते? ही छोटीशी सवय खरोखर आयुष्यात मोठी शांती घेऊन येते. दिवसातून फक्त पाच मिनिटे पुरेशी आहेत, आणि काही दिवसांनी तुम्हाला स्वतःमध्ये जास्त आनंद आणि शक्ती जाणवेल. म्हणून आजपासूनच सुरुवात करा, बरं वाटेल!''',

    'Odia':
        '''ପ୍ରତିଦିନ ସକାଳେ ଟିକିଏ ସମୟ ପ୍ରାର୍ଥନାରେ ବିତାଇଲେ ମନକୁ ବହୁତ ଶାନ୍ତି ମିଳେ। ଭଗବାନଙ୍କ ନାମ ନେବା, ଦୀପ ଜଳାଇବା, କିମ୍ବା ଟିକିଏ ଧ୍ୟାନ କରିବା ଦ୍ୱାରା ଭିତରୁ ଏକ ଅଲଗା ଭଲ ଅନୁଭବ ଆସେ। ଆପଣ କେବେ ଲକ୍ଷ୍ୟ କରିଛନ୍ତି କି, ମନ ଖରାପ ଥିଲେ ବି ପ୍ରାର୍ଥନା ପରେ ଟିକିଏ ହାଲୁକା ଲାଗେ? ଏହି ଛୋଟ ଅଭ୍ୟାସଟି ପ୍ରକୃତରେ ଜୀବନରେ ବଡ଼ ଶାନ୍ତି ଆଣିଥାଏ। ଦିନକୁ କେବଳ ପାଞ୍ଚ ମିନିଟ୍ ଯଥେଷ୍ଟ, ଆଉ କିଛି ଦିନ ପରେ ଆପଣ ନିଜ ଭିତରେ ଅଧିକ ଆନନ୍ଦ ଓ ଶକ୍ତି ଅନୁଭବ କରିବେ। ତେଣୁ ଆଜିଠାରୁ ଆରମ୍ଭ କରନ୍ତୁ, ଭଲ ଲାଗିବ!''',

    'Rajasthani':
        '''रोज सवेरे थोड़ो वखत काढ़'र प्रार्थना करबा सूं मन घणो शान्त हो जावै। भगवान रो नाम लेबा सूं, दीवो बाळबा सूं, या थोड़ो ध्यान करबा सूं अंदर सूं एक न्यारी किसम री अच्छी अनुभूति होवै। कांई थें कदैई महसूस करी है के मन खराब होवै तो भी प्रार्थना पछै थोड़ो हल्को लागै? आ छोटी सी आदत सही में जिनगी में बड़ी शान्ति ल्यावै। दिन में बस पांच मिनट ई काफी है, अर कुछ दिन पछै थें अपणे मांय ज्यादा खुशी अर ताकत महसूस करोला। तो आज सूं ई शुरू करो, देख्यो अच्छो लागैला!''',
  };

  // Request recording permission - Uses PermissionService (native iOS, permission_handler on Android)
  Future<bool> requestPermission() async {
    try {
      // Use PermissionService: native on iOS, permission_handler on Android
      final granted = await PermissionService.requestMicrophonePermission();

      return granted;
    } catch (e, stackTrace) {
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
        return false;
      }

      // Request permission (only once)
      final hasPermission = await requestPermission();
      if (!hasPermission) {
        // Check if permission is permanently denied for better error handling
        final isPermanentlyDenied = await isPermissionPermanentlyDenied();
        if (isPermanentlyDenied) {}
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

      // AAC in M4A container (no conversion; same as before WAV experiment).
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      const extension = 'm4a';
      RecordConfig config;

      if (Platform.isAndroid) {
        config = const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        );
      } else {
        config = const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
        );
      }

      final filename = 'recording_$timestamp.$extension';
      _currentRecordingPath = '${recordingsDir.path}/$filename';

      // Ensure recorder is initialized (recreate if needed)
      try {
        await _recorder.start(config, path: _currentRecordingPath!);
      } catch (e) {
        // If recorder is disposed or not initialized, recreate it
        _audioRecorder?.dispose();
        _audioRecorder = AudioRecorder();
        await _recorder.start(config, path: _currentRecordingPath!);
      }

      _isRecording = true;
      return true;
    } catch (e, stackTrace) {
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

        // Wait a moment for file system to sync
        await Future.delayed(const Duration(milliseconds: 200));

        // Verify file exists and has content
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          final fileSize = await file.length();

          // Minimum file size check (very small files are likely empty/noise)
          // For a 1-second recording at 44.1kHz mono AAC, expect at least ~5KB
          const minFileSize = 5000; // 5KB minimum

          if (fileSize == 0) {
            // Delete the empty file
            try {
              await file.delete();
            } catch (e) {}
            _currentRecordingPath = null;
            _isRecording = false;
            return null;
          } else if (fileSize < minFileSize) {
            // Still return the path, but log the warning
          }

          // Verify file is readable
          final canRead = await file.exists();
          _isRecording = false;
          return _currentRecordingPath;
        } else {
          _currentRecordingPath = null;
        }
      } else {}

      _isRecording = false;
      return _currentRecordingPath;
    } catch (e, stackTrace) {
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
        } catch (e) {}
        _isRecording = false;
      }

      // Delete the file if it exists (whether currently recording or just unsaved)
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
        _currentRecordingPath = null;
      }
    } catch (e) {
      _isRecording = false;
      _currentRecordingPath = null;
    }
  }

  // Save recording with name
  // Returns a map with 'success' (bool) and 'errorMessage' (String?) keys
  Future<Map<String, dynamic>> saveRecording(
    String name,
    String language,
  ) async {
    try {
      if (_currentRecordingPath == null) {
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
      final sanitizedName = name
          .replaceAll(RegExp(r'[^\w\s-]'), '')
          .replaceAll(' ', '_');
      const extension = 'm4a';
      final newFilePath = '${recordingsDir.path}/$sanitizedName.$extension';

      // If file with same name exists, add timestamp
      final originalFile = File(_currentRecordingPath!);
      File finalFile = File(newFilePath);
      if (await finalFile.exists()) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        finalFile = File(
          '${recordingsDir.path}/$sanitizedName\_$timestamp.$extension',
        );
      }

      // Verify original file exists and is not empty before copying
      if (!await originalFile.exists()) {
        throw Exception('Original recording file does not exist');
      }
      final originalFileSize = await originalFile.length();
      if (originalFileSize == 0) {
        throw Exception(
          'Recording file is empty (0 bytes) - recording may have failed',
        );
      }

      // Copy/rename the file to final location - ALWAYS keep local copy
      await originalFile.copy(finalFile.path);

      // Verify the file was copied successfully and is not empty
      final copiedFile = File(finalFile.path);
      if (!await copiedFile.exists()) {
        throw Exception('Failed to copy recording file to final location');
      }
      final fileSize = await copiedFile.length();
      if (fileSize == 0) {
        throw Exception('Copied recording file is empty (0 bytes)');
      }
      if (fileSize != originalFileSize) {}

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

      // Upload to backend: 3 retries, 3s apart (silent); queue for later if all fail
      String? backendErrorMessage;
      bool backendSuccess = false;
      final outcome = await _uploadRecordingWithRetries(
        recording: recording,
        showLogs: true,
      );
      if (outcome.ok) {
        backendSuccess = true;
        if (outcome.recordingId != null && outcome.recordingId!.isNotEmpty) {
          await _rememberPathForRecordingId(
            outcome.recordingId!,
            recording.filePath,
          );
        }
      } else {
        await _addPendingUpload(
          localPath: recording.filePath,
          displayName: name,
          language: language,
        );
        backendErrorMessage =
            'Saved on device; server sync will retry when you open Record Your Voice again.';
      }

      // ALWAYS keep local file - delete original temporary file only
      try {
        if (await originalFile.exists()) {
          await originalFile.delete();
        }
      } catch (e) {
        // Continue anyway - the new file is saved
      }

      // Add to local list - ALWAYS add, regardless of backend success
      _recordings.add(recording);

      // Clear current recording
      _currentRecordingPath = null;

      if (backendSuccess) {
        return {'success': true, 'backendSuccess': true, 'errorMessage': null};
      } else {
        return {
          'success': true, // Still success because local save worked
          'backendSuccess': false,
          'errorMessage':
              backendErrorMessage ?? 'Failed to save recording to backend',
        };
      }
    } catch (e, stackTrace) {
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
      case 'marathi':
        return 'mr-IN';
      case 'odia':
        return 'or-IN';
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
      case 'mr-in':
        return 'Marathi';
      case 'or-in':
        return 'Odia';
      default:
        return 'English'; // Default to English
    }
  }

  String? _parseRecordingIdFromUploadResponse(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final d = json.decode(body);
      if (d is Map<String, dynamic>) {
        final rid = d['recording_id'] ?? d['recordingId'];
        if (rid != null) return rid.toString();
        final data = d['data'];
        if (data is Map<String, dynamic>) {
          final rid2 = data['recording_id'] ?? data['recordingId'];
          if (rid2 != null) return rid2.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  /// Single PUT — returns server [recording_id] when present.
  Future<String?> _uploadRecordingPutOnce(
    VoiceRecording recording, {
    required bool verbose,
  }) async {
    final authService = AuthService();
    final accessToken = authService.accessToken;

    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('No authentication token found');
    }

    final file = File(recording.filePath);
    if (!await file.exists()) {
      throw Exception('Recording file does not exist');
    }

    final fileSize = await file.length();
    final filename = recording.filePath.split('/').last;

    String dottedExt = '.m4a';
    if (filename.contains('.')) {
      dottedExt = filename
          .substring(filename.lastIndexOf('.'))
          .trim()
          .toLowerCase();
    }
    if (!dottedExt.startsWith('.')) {
      dottedExt = '.$dottedExt';
    }

    String mimeType = 'audio/mp4';
    switch (dottedExt) {
      case '.m4a':
        mimeType = 'audio/m4a';
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
        mimeType = 'audio/m4a';
    }

    final extForApi = dottedExt.startsWith('.')
        ? dottedExt.substring(1)
        : dottedExt;

    final fileStem = filename.contains('.')
        ? filename.substring(0, filename.lastIndexOf('.'))
        : filename;

    final fileBytes = await file.readAsBytes();
    final base64Encoded = base64Encode(fileBytes);
    final languageCode = _mapLanguageToCode(recording.language);

    final requestBody = json.encode({
      'fileName': fileStem,
      'recordingName': recording.name,
      'fileExtension': extForApi,
      'mimeType': mimeType,
      'language': languageCode,
      'recordingBase64': base64Encoded,
    });

    final url = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}',
    );

    if (verbose) {}

    final response = await AuthenticatedHttp.put(
      url,
      body: requestBody,
      timeout: const Duration(seconds: 90),
    );

    if (verbose) {}

    if (response.statusCode == 200 || response.statusCode == 201) {
      return _parseRecordingIdFromUploadResponse(response.body);
    }

    String errorMessage = 'Failed to save recording to backend';
    try {
      final responseData = json.decode(response.body);
      if (responseData is Map && responseData.containsKey('error')) {
        errorMessage = responseData['error'].toString();
      } else if (responseData is Map && responseData.containsKey('message')) {
        errorMessage = responseData['message'].toString();
      }
    } catch (_) {
      if (response.body.isNotEmpty) errorMessage = response.body;
    }
    throw Exception(errorMessage);
  }

  /// Up to 3 attempts, 3 seconds apart.
  Future<_VoiceUploadOutcome> _uploadRecordingWithRetries({
    required VoiceRecording recording,
    required bool showLogs,
  }) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final id = await _uploadRecordingPutOnce(recording, verbose: showLogs);
        return _VoiceUploadOutcome(ok: true, recordingId: id);
      } catch (e) {
        if (showLogs) {}
        if (attempt < 3) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
    }
    return const _VoiceUploadOutcome(ok: false, recordingId: null);
  }

  Future<String?> _resolveLocalAudioPath({
    required String recordingId,
    required String displayName,
    required String fileExtensionRaw,
    required Directory recordingsDir,
    required Map<String, String> idPaths,
  }) async {
    final mapped = idPaths[recordingId];
    if (mapped != null && mapped.isNotEmpty) {
      final f = File(mapped);
      if (await f.exists() && await f.length() > 0) return mapped;
    }

    var ext = fileExtensionRaw.trim();
    if (ext.isEmpty) ext = '.m4a';
    if (!ext.startsWith('.')) ext = '.$ext';

    final base = sanitizeRecordingBaseName(displayName);
    final candidates = <String>[
      '${recordingsDir.path}/$base$ext',
      '${recordingsDir.path}/$base.m4a',
      '${recordingsDir.path}/$base.wav',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (await f.exists() && await f.length() > 0) return p;
    }
    return null;
  }

  // Download recording file from backend URL (pre-signed URL)
  Future<bool> _downloadRecordingFromUrl({
    required String recordingUrl,
    required String localFilePath,
  }) async {
    try {
      // Ensure the directory exists
      final file = File(localFilePath);
      final directory = file.parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      // Download from pre-signed URL (no auth headers needed for pre-signed URLs)
      final response = await http
          .get(Uri.parse(recordingUrl))
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        // Write the file
        await file.writeAsBytes(response.bodyBytes);
        return true;
      } else {
        return false;
      }
    } on TimeoutException {
      return false;
    } catch (e, stackTrace) {
      return false;
    }
  }

  /// When the list API has a row but no local file, GET the recording payload
  /// (base64 `file` field), write bytes under [recordingsDir], and persist id→path.
  /// Returns the saved path on success; null if the file could not be obtained
  /// (missing/empty payload, HTTP error, decode/write failure, etc.).
  Future<String?> _tryRestoreRecordingFromBackend({
    required String recordingId,
    required String displayName,
    required String fileExtensionRaw,
    required Directory recordingsDir,
    required Map<String, String> idPaths,
  }) async {
    try {
      final url = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}/$recordingId',
      );

      final response = await AuthenticatedHttp.get(
        url,
        timeout: const Duration(seconds: 120),
      );

      if (response.statusCode == 404 || response.statusCode == 410) {
        return null;
      }

      if (response.statusCode != 200) {
        return null;
      }

      final Map<String, dynamic> map;
      try {
        final decoded = json.decode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return null;
        }
        map = decoded;
      } catch (e) {
        return null;
      }

      final err = map['error']?.toString() ?? map['message']?.toString() ?? '';
      final errLower = err.toLowerCase();
      if (err.isNotEmpty &&
          (errLower.contains('not found') ||
              errLower.contains('no file') ||
              errLower.contains('file not available') ||
              errLower.contains('unavailable'))) {
        return null;
      }

      final fileStr = map['file']?.toString();
      if (fileStr == null || fileStr.trim().isEmpty) {
        return null;
      }

      late final List<int> bytes;
      try {
        final cleaned = fileStr.replaceAll(RegExp(r'\s'), '');
        bytes = base64Decode(_stripDataUrlBase64(cleaned));
      } catch (e) {
        return null;
      }

      if (bytes.isEmpty) {
        return null;
      }

      var ext = (map['file_extension'] ?? fileExtensionRaw).toString().trim();
      if (ext.isEmpty) ext = 'm4a';
      if (ext.startsWith('.')) ext = ext.substring(1);

      final base = sanitizeRecordingBaseName(displayName);
      final localPath = '${recordingsDir.path}/$base.$ext';
      final file = File(localPath);
      await file.writeAsBytes(bytes, flush: true);

      if (!await file.exists() || await file.length() == 0) {
        return null;
      }

      idPaths[recordingId] = localPath;
      await _rememberPathForRecordingId(recordingId, localPath);
      return localPath;
    } catch (e, st) {
      return null;
    }
  }

  // Load recordings from backend and sync with local storage
  Future<void> loadRecordings() async {
    try {
      await processPendingUploadsInBackground();

      // 1. Fetch recordings from backend (GET .../voice/recordings → { recordings: [...] })
      final backendRecordings = await _fetchRecordingsFromBackend();

      // 2. App documents directory
      final directory = await getApplicationDocumentsDirectory();
      final recordingsDir = Directory('${directory.path}/recordings');

      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      final idPaths = await _loadRecordingIdPaths();

      // List is API-authoritative only: local orphan files are not shown as extra rows.
      _recordings = [];

      // Each server row — resolve local file by recording_id map + name/extension,
      // then restore from GET .../recordings/{id} if missing; grey card if still no file.
      for (final backendRec in backendRecordings) {
        try {
          final recordingId = backendRec['recording_id']?.toString() ?? '';
          if (recordingId.isEmpty) continue;

          final name = backendRec['name']?.toString() ?? '';
          if (name.isEmpty) continue;

          final languageCode = backendRec['language']?.toString() ?? 'en-US';
          final language = _mapCodeToLanguage(languageCode);
          final createdAtStr = backendRec['created_at']?.toString() ?? '';
          final fileExtension =
              backendRec['file_extension']?.toString() ?? '.m4a';
          final trainingStatus = backendRec['training_status']?.toString();

          DateTime createdAt;
          try {
            createdAt = DateTime.parse(createdAtStr).toLocal();
          } catch (e) {
            createdAt = DateTime.now();
          }

          String? localPath = await _resolveLocalAudioPath(
            recordingId: recordingId,
            displayName: name,
            fileExtensionRaw: fileExtension,
            recordingsDir: recordingsDir,
            idPaths: idPaths,
          );

          var hasLocal = localPath != null && localPath.isNotEmpty;

          if (!hasLocal) {
            final restoredPath = await _tryRestoreRecordingFromBackend(
              recordingId: recordingId,
              displayName: name,
              fileExtensionRaw: fileExtension,
              recordingsDir: recordingsDir,
              idPaths: idPaths,
            );
            if (restoredPath != null) {
              localPath = restoredPath;
              hasLocal = true;
            }
          }

          _recordings.add(
            VoiceRecording(
              id: recordingId,
              recordingId: recordingId,
              name: name,
              language: language,
              filePath: localPath ?? '',
              createdAt: createdAt,
              hasLocalFile: hasLocal,
              trainingStatus: trainingStatus,
            ),
          );
        } catch (e) {}
      }

      // Sort by creation date (newest first)
      _recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e, stackTrace) {
      // Don't clear recordings on error - keep what we have
    }
  }

  // Fetch recordings list from backend
  Future<List<Map<String, dynamic>>> _fetchRecordingsFromBackend() async {
    try {
      final authService = AuthService();
      final accessToken = authService.accessToken;

      if (accessToken == null || accessToken.isEmpty) {
        return [];
      }

      final url = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}',
      );

      final response = await AuthenticatedHttp.get(url);

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        List<dynamic> recordingsList = [];
        if (decoded is Map<String, dynamic>) {
          final raw = decoded['recordings'];
          if (raw is List) {
            recordingsList = raw;
          }
        } else if (decoded is List) {
          recordingsList = decoded;
        }
        return recordingsList
            .map((rec) => Map<String, dynamic>.from(rec as Map))
            .toList();
      } else {
        return [];
      }
    } on TimeoutException {
      return [];
    } catch (e, stackTrace) {
      return [];
    }
  }

  // Sync recordings between local storage and backend
  // Note: loadRecordings() now automatically syncs with backend
  // This method is kept for backward compatibility
  Future<void> syncRecordings() async {
    try {
      // The new loadRecordings() method already handles backend sync
      await loadRecordings();
    } catch (e, stackTrace) {}
  }

  // Delete recording — local file first, then DELETE on server when [recordingId] exists.
  Future<bool> deleteRecording(VoiceRecording recording) async {
    try {
      final backendId = recording.recordingId;

      if (recording.filePath.isNotEmpty) {
        final file = File(recording.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }

      await _removePathForRecordingId(backendId);

      if (backendId != null && backendId.isNotEmpty) {
        final backendSuccess = await _deleteFromBackend(recording);
        if (!backendSuccess) {
          _recordings.remove(recording);
          return false;
        }
      }

      _recordings.remove(recording);
      return true;
    } catch (e, stackTrace) {
      return false;
    }
  }

  // Delete recording from backend
  Future<bool> _deleteFromBackend(VoiceRecording recording) async {
    try {
      final authService = AuthService();
      final accessToken = authService.accessToken;

      if (accessToken == null || accessToken.isEmpty) {
        return false;
      }

      // Use recordingId from backend
      final recordingId = recording.recordingId!;
      final url = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.voiceRecordingsEndpoint}/$recordingId',
      );

      final response = await AuthenticatedHttp.delete(url);

      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      } else {
        return false;
      }
    } on TimeoutException {
      return false;
    } catch (e, stackTrace) {
      return false;
    }
  }

  // Check if name is unique
  bool isNameUnique(String name) {
    return !_recordings.any(
      (recording) => recording.name.toLowerCase() == name.toLowerCase(),
    );
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
    } catch (e) {}
  }
}

class _VoiceUploadOutcome {
  final bool ok;
  final String? recordingId;
  const _VoiceUploadOutcome({required this.ok, this.recordingId});
}

class VoiceRecording {
  final String id;
  final String? recordingId; // Backend recording_id from API
  final String name;
  final String language;

  /// Local file path; empty when [hasLocalFile] is false (remote-only row).
  final String filePath;
  final DateTime createdAt;

  /// False when the server lists the recording but there is no local audio file.
  final bool hasLocalFile;
  final String? trainingStatus;

  VoiceRecording({
    required this.id,
    this.recordingId,
    required this.name,
    required this.language,
    required this.filePath,
    required this.createdAt,
    this.hasLocalFile = true,
    this.trainingStatus,
  });

  VoiceRecording copyWith({
    String? id,
    String? recordingId,
    String? name,
    String? language,
    String? filePath,
    DateTime? createdAt,
    bool? hasLocalFile,
    String? trainingStatus,
  }) {
    return VoiceRecording(
      id: id ?? this.id,
      recordingId: recordingId ?? this.recordingId,
      name: name ?? this.name,
      language: language ?? this.language,
      filePath: filePath ?? this.filePath,
      createdAt: createdAt ?? this.createdAt,
      hasLocalFile: hasLocalFile ?? this.hasLocalFile,
      trainingStatus: trainingStatus ?? this.trainingStatus,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'recordingId': recordingId,
      'name': name,
      'language': language,
      'filePath': filePath,
      'createdAt': createdAt.toIso8601String(),
      'hasLocalFile': hasLocalFile,
      'trainingStatus': trainingStatus,
    };
  }

  factory VoiceRecording.fromJson(Map<String, dynamic> json) {
    return VoiceRecording(
      id: json['id'] as String,
      recordingId: json['recordingId'] as String?,
      name: json['name'] as String,
      language: json['language'] as String,
      filePath: json['filePath'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      hasLocalFile: json['hasLocalFile'] as bool? ?? true,
      trainingStatus: json['trainingStatus'] as String?,
    );
  }
}
