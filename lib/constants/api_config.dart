class ApiConfig {
  // Base API URL
  static const String baseUrl = 'https://d2d52ldvp3fzee.cloudfront.net/v1';

  // Payment Base URL
  static const String paymentBaseUrl =
      'https://d2d52ldvp3fzee.cloudfront.net/v1';

  // Auth endpoints
  static const String googleSignInEndpoint = '/auth/google-signin';
  static const String facebookSignInEndpoint = '/auth/facebook-signin';
  static const String refreshTokenEndpoint = '/auth/refresh';
  static const String profileEndpoint = '/auth/profile';
  static const String notificationsEndpoint = '/auth/profile/notifications';
  static String notificationByIdEndpoint(String notificationId) =>
      '/auth/profile/notifications/$notificationId';
  static const String listRecordingAndSongsEndpoint =
      '/auth/profile/list-recording-and-songs';
  static const String logoutEndpoint = '/auth/logout';
  static const String consentEndpoint = '/auth/consent';
  static const String putDeviceInfoEndpoint = '/auth/put-device-info';

  // Songs endpoint
  static const String songsEndpoint = '/songs';

  // Generate Mantra endpoint (legacy; voice job uses [createJobBaseUrl])
  static const String generateMantraEndpoint = '/auth/profile/generate-mantra';

  /// Async mantra generation job (prod).
  static const String createJobBaseUrl =
      'https://d2d52ldvp3fzee.cloudfront.net/prod';
  static const String createJobEndpoint = '/create-job';

  // Voice Recording endpoint
  static const String voiceRecordingsEndpoint =
      '/auth/profile/voice/recordings';

  /// User-specific inferred / generated mantra audio (list + per-id download URL).
  static const String inferredSongsEndpoint = '/auth/profile/inferred/songs';

  // Purchased Songs endpoint
  static const String purchasedSongsEndpoint = '/auth/profile/purchase/songs';

  // Payment endpoints
  static const String createPaymentIntentEndpoint = '/payments/create-intent';
  static const String confirmPaymentEndpoint = '/payments/confirm';
  static const String getPaymentStatusEndpoint = '/payments/status';

  /// Stripe Checkout Session (UPI / hosted checkout) — opened in WebView, not PaymentSheet.
  static const String createCheckoutSessionEndpoint =
      '/payments/create-checkout-session';
  static const String verifyCheckoutSessionEndpoint =
      '/payments/verify-session';

  // Google OAuth Configuration
  static const String googleClientId =
      '333289829093-pg9e6o14ulmqflanirvosu9qgpjdbt3p.apps.googleusercontent.com';

  // Facebook App Configuration (for native SDK)
  static const String facebookAppId = '25154563447566829';

  // Stripe Configuration
  static const String stripePublishableKey =
      'pk_test_51SYdd7RAucXK6Yre6JYajbvLMAN1XDV0CPZeg6mhHbc1T8ho0xRGabKUmj03NqEypK0anKga8puVJb8nWePzrVN600NJ7Tv81s';

  // Headers
  static Map<String, String> getHeaders({String? accessToken}) {
    final headers = <String, String>{'Content-Type': 'application/json'};

    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }

    return headers;
  }

  // Payment Headers
  static Map<String, String> getPaymentHeaders({String? accessToken}) {
    final headers = <String, String>{'Content-Type': 'application/json'};

    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }

    return headers;
  }
}
