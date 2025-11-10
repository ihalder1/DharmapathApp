import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../constants/app_colors.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));

    _fadeController.forward();
    _slideController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppColors.primaryGradient,
        ),
        child: Stack(
          children: [
            // Large Watermark Om Symbol
            Positioned.fill(
              child: Center(
                child: Text(
                  'ॐ',
                  style: TextStyle(
                    fontSize: 400,
                    color: AppColors.watermarkOm,
                    fontWeight: FontWeight.w100,
                    height: 0.8,
                  ),
                ),
              ),
            ),
            // Main Content
            SafeArea(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // App Logo and Title
                        _buildHeader(),
                        
                        const SizedBox(height: 60),
                        
                        // Login Options
                        _buildLoginOptions(),
                        
                        const SizedBox(height: 40),
                        
                        // Error Message
                        if (_errorMessage != null) _buildErrorMessage(),
                        
                        const SizedBox(height: 20),
                        
                        // Loading Indicator
                        if (_isLoading) _buildLoadingIndicator(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        // App Icon
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: AppColors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(
            Icons.music_note,
            size: 50,
            color: AppColors.goldenSaffron,
          ),
        ),
        
        const SizedBox(height: 24),
        
        // App Title
        const Text(
          'Dharmapath - धर्मपथ',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        
        const SizedBox(height: 8),
        
        // Tagline
        Text(
          'Turn your words into timeless chants.',
          style: TextStyle(
            fontSize: 18,
            color: AppColors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildLoginOptions() {
    return Column(
      children: [
        // Google Sign In Button
        _buildSocialButton(
          'Continue with Google',
          Icons.g_mobiledata,
          AppColors.white,
          AppColors.textPrimary,
          () => _handleGoogleSignIn(),
        ),
        
        const SizedBox(height: 16),
        
        // Facebook Sign In Button
        _buildSocialButton(
          'Continue with Facebook',
          Icons.facebook,
          const Color(0xFF1877F2),
          AppColors.white,
          () => _handleFacebookSignIn(),
        ),
        
        const SizedBox(height: 16),
        
        // Apple Sign In Button (iOS only)
        if (Theme.of(context).platform == TargetPlatform.iOS)
          _buildSocialButton(
            'Continue with Apple',
            Icons.apple,
            AppColors.black,
            AppColors.white,
            () => _handleAppleSignIn(),
          ),
      ],
    );
  }

  Widget _buildSocialButton(
    String text,
    IconData icon,
    Color backgroundColor,
    Color textColor,
    VoidCallback onPressed,
  ) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: textColor,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          shadowColor: Colors.black.withOpacity(0.2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 24,
              color: textColor,
            ),
            const SizedBox(width: 12),
            Text(
              text,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.errorRed.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.errorRed.withOpacity(0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: AppColors.errorRed,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: AppColors.errorRed,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return const Center(
      child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(AppColors.primarySaffron),
      ),
    );
  }

  Future<void> _handleGoogleSignIn() async {
    await _performSignIn(() => context.read<AuthService>().signInWithGoogle());
  }

  Future<void> _handleFacebookSignIn() async {
    await _performSignIn(() => context.read<AuthService>().signInWithFacebook());
  }

  Future<void> _handleAppleSignIn() async {
    await _performSignIn(() => context.read<AuthService>().signInWithApple());
  }

  Future<void> _performSignIn(Future<bool> Function() signInFunction) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await signInFunction();
      
      if (success) {
        // Navigation will be handled by AuthWrapper automatically
        // No need to show success message as user will see home screen
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _errorMessage = 'Sign in failed. Please try again.';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'An error occurred: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}
