import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'widgets/auth_wrapper.dart';
import 'constants/app_theme.dart';
import 'constants/api_config.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/profile_service.dart';
import 'services/mantra_service.dart';
import 'services/voice_recording_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // iOS requires ios/Runner/GoogleService-Info.plist (download from Firebase Console).
  // Without it, Firebase.initializeApp throws — still run the app without push.
  var firebaseReady = false;
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (e, st) {
    debugPrint(
      'Firebase.initializeApp failed — add ios/Runner/GoogleService-Info.plist '
      '(Firebase Console → Project settings → Your apps → iOS). Push disabled. Error: $e',
    );
    debugPrint('$st');
  }

  if (firebaseReady) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await FirebaseMessagingService.initialize();
  }

  // Lock orientation to portrait only
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize Stripe (publishable key, url scheme + Android return URL for 3DS / redirects)
  Stripe.publishableKey = ApiConfig.stripePublishableKey;
  Stripe.merchantIdentifier = 'merchant.com.example.colab_app_ui';
  Stripe.urlScheme = 'mantrasutra';
  Stripe.setReturnUrlSchemeOnAndroid = true;
  await Stripe.instance.applySettings();
  print('Stripe initialized with publishable key: ${ApiConfig.stripePublishableKey}');
  
  // Request microphone permission at startup
  await Permission.microphone.request();
  print('Microphone permission requested on iOS startup');
  
  runApp(const ColabApp());
}

class ColabApp extends StatelessWidget {
  const ColabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        Provider(create: (_) => ProfileService()),
        Provider(create: (_) => MantraService()),
        Provider(create: (_) => VoiceRecordingService()),
      ],
      child: MaterialApp(
        title: 'Colab Voice Conversion',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const AuthWrapper(),
      ),
    );
  }
}