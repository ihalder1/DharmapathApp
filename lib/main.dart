import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import 'services/media_cache_service.dart';
import 'services/voice_recording_service.dart';
import 'utils/safe_log.dart';

Future<void> main() {
  return SafeLog.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Remove only abandoned files from our disposable media-cache namespace.
    // Durable recordings and intentionally downloaded media live in Documents.
    try {
      await const MediaCacheService().removeExpiredFiles();
    } catch (_) {
      SafeLog.warning('media_cache_cleanup_failed');
    }

    // iOS requires ios/Runner/GoogleService-Info.plist (download from Firebase Console).
    // Without it, Firebase.initializeApp throws — still run the app without push.
    var firebaseReady = false;
    try {
      await Firebase.initializeApp();
      firebaseReady = true;
    } catch (_) {}

    if (firebaseReady) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      try {
        await FirebaseMessagingService.initialize();
      } catch (error, stackTrace) {
        // Push notifications are optional at startup. A transient native-token
        // failure must not prevent the Flutter UI from being mounted.
        SafeLog.error(
          'firebase_messaging_initialization_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // Lock orientation to portrait only
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Android mantra checkout uses Google Play Billing. Keep the existing
    // Stripe setup unchanged for the other platforms (including iOS).
    if (defaultTargetPlatform != TargetPlatform.android) {
      const stripeUrlScheme = 'mantrasutra';
      try {
        Stripe.publishableKey = ApiConfig.stripePublishableKey;
        Stripe.merchantIdentifier = 'merchant.com.example.colab_app_ui';
        Stripe.urlScheme = stripeUrlScheme;
        Stripe.setReturnUrlSchemeOnAndroid = true;
        await Stripe.instance.applySettings();
      } catch (error, stackTrace) {
        SafeLog.error(
          'stripe_initialization_failed',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }

    // Request microphone permission at startup
    await Permission.microphone.request();

    runApp(const ColabApp());
  });
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
