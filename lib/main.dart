import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'constants/app_theme.dart';
import 'services/auth_service.dart';
import 'services/profile_service.dart';
import 'services/mantra_service.dart';
import 'services/voice_recording_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Don't request microphone permission at startup - request when user actually tries to record
  // This prevents iOS from silently denying the permission
  
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
        home: const HomeScreen(),
      ),
    );
  }
}