class ApiConfig {
  // Base API URL
  // Development: https://api-online.prod.mantrasutra.ids-ai.net/v1
  static const String baseUrl = 'https://api-online.mantrasutra.ids-ai.net/v1';

  // Payment Base URL
  // Development: https://api-online.prod.mantrasutra.ids-ai.net/v1
  static const String paymentBaseUrl =
      'https://api-online.mantrasutra.ids-ai.net/v1';

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
  // Development: https://api-online.prod.mantrasutra.ids-ai.net/prod
  static const String createJobBaseUrl =
      'https://api-online.mantrasutra.ids-ai.net/prod';
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
  static const String prepareAndroidPurchaseEndpoint =
      '/payments/prepare-purchase';
  static const String verifyAndroidPurchaseEndpoint =
      '/payments/verify-purchase';
  static String androidPurchaseOrderEndpoint(String orderId) =>
      '/payments/orders/${Uri.encodeComponent(orderId)}';
  static const String restoreAndroidPurchasesEndpoint = '/payments/restore';

  // Google OAuth Configuration
  static const String googleClientId =
      '305683539721-g6t0uenf1tnqla74j4e04g2q3cm2r1ct.apps.googleusercontent.com';

  // Facebook App Configuration (for native SDK)
  static const String facebookAppId = '1682167649562322';

  // Stripe Configuration
  static const String stripePublishableKey =
      'pk_live_51Th7j07TBSV3YzcAwVE7AkIr1XrhgR4bxPEhTkHq7w1dIwXaR274C9fsbztvEoLkuNkCiiZazRtEDa91shaWT2ZC007ORUXb6s';

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
