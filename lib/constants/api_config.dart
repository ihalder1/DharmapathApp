class ApiConfig {
  // Base API URL
  static const String baseUrl = 'https://288k0b3tlh.execute-api.ap-south-1.amazonaws.com/stage';
  
  // Payment Base URL
  static const String paymentBaseUrl = 'https://fmnyguo7ch.execute-api.ap-south-1.amazonaws.com/stage';
  
  // API Key
  static const String apiKey = 'UWVdx2LDoX7xK4ue7u6oOalK0qDT0YY91CAlwOoS';
  
  // Payment API Key
  static const String paymentApiKey = 'UPOQ0Vkmnz8ig4GgMwavL1V06b3i2WzZ5rQygFfV';
  
  // Auth endpoints
  static const String googleSignInEndpoint = '/auth/google-signin';
  static const String refreshTokenEndpoint = '/auth/refresh';
  static const String profileEndpoint = '/auth/profile';
  static const String logoutEndpoint = '/auth/logout';
  
  // Songs endpoint
  static const String songsEndpoint = '/songs';
  
  // Payment endpoints
  static const String createPaymentIntentEndpoint = '/payments/create-intent';
  static const String confirmPaymentEndpoint = '/payments/confirm';
  static const String getPaymentStatusEndpoint = '/payments/status';
  
  // Google OAuth Configuration
  static const String googleClientId = '333289829093-pg9e6o14ulmqflanirvosu9qgpjdbt3p.apps.googleusercontent.com';
  
  // Stripe Configuration
  static const String stripePublishableKey = 'pk_test_51SYdd7RAucXK6Yre6JYajbvLMAN1XDV0CPZeg6mhHbc1T8ho0xRGabKUmj03NqEypK0anKga8puVJb8nWePzrVN600NJ7Tv81s';
  
  // Headers
  static Map<String, String> getHeaders({String? accessToken}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
    };
    
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    
    return headers;
  }
  
  // Payment Headers
  static Map<String, String> getPaymentHeaders({String? accessToken}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'x-api-key': paymentApiKey,
    };
    
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    
    return headers;
  }
}


