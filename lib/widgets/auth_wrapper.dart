import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../screens/login_screen.dart';
import '../screens/home_screen.dart';
import 'voice_consent_gate.dart';
import '../services/ios_purchase_reconciler.dart';

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed && _isInitialized && mounted) {
      await context.read<AuthService>().ensureValidAccessToken();
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          await IosPurchaseReconciler().reconcile();
        } catch (_) {
          // A transient payment/backend failure keeps the durable context for
          // the next resume and must not disrupt application lifecycle work.
        }
      }
    }
  }

  Future<void> _initializeAuth() async {
    try {
      await context.read<AuthService>().initialize();
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Consumer<AuthService>(
      builder: (context, authService, child) {
        // Show login screen if not logged in
        if (!authService.isLoggedIn) {
          return const LoginScreen();
        }

        // Consent is a root-level gate: HomeScreen is not created until the
        // authenticated user accepts the current consent version.
        return VoiceConsentGate(
          userId: authService.currentUser!.id,
          child: const HomeScreen(),
        );
      },
    );
  }
}
