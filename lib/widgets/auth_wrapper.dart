import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../screens/login_screen.dart';
import '../screens/home_screen.dart';

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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isInitialized && mounted) {
      context.read<AuthService>().ensureValidAccessToken();
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
      debugPrint('Auth initialization error: $e');
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
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Consumer<AuthService>(
      builder: (context, authService, child) {
        debugPrint('AuthWrapper rebuild - isLoggedIn: ${authService.isLoggedIn}, user: ${authService.currentUser?.email}, token: ${authService.accessToken != null ? "SET" : "NULL"}');
        
        // Show login screen if not logged in
        if (!authService.isLoggedIn) {
          debugPrint('AuthWrapper: Showing LoginScreen');
          return const LoginScreen();
        }
        
        // Show home screen if logged in
        debugPrint('AuthWrapper: Showing HomeScreen');
        return const HomeScreen();
      },
    );
  }
}




















