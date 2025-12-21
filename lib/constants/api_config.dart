class ApiConfig {
  // Base API URL
  static const String baseUrl = 'https://288k0b3tlh.execute-api.ap-south-1.amazonaws.com/stage';
  
  // API Key
  static const String apiKey = 'UWVdx2LDoX7xK4ue7u6oOalK0qDT0YY91CAlwOoS';
  
  // Auth endpoints
  static const String googleSignInEndpoint = '/auth/google-signin';
  static const String refreshTokenEndpoint = '/auth/refresh';
  static const String profileEndpoint = '/auth/profile';
  static const String logoutEndpoint = '/auth/logout';
  
  // Google OAuth Configuration
  static const String googleClientId = '333289829093-pg9e6o14ulmqflanirvosu9qgpjdbt3p.apps.googleusercontent.com';
  
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
}


