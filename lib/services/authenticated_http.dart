import 'package:http/http.dart' as http;
import '../constants/api_config.dart';
import 'auth_service.dart';

/// Main API + payment API calls with one automatic token refresh on 401/403.
class AuthenticatedHttp {
  AuthenticatedHttp._();

  static final AuthService _auth = AuthService();

  static bool _isUnauthorized(int code) => code == 401 || code == 403;

  static Future<void> _logoutIfRefreshRejected() async {
    if (_auth.shouldLogoutAfterRefreshFailure) {
      await _auth.logout();
    }
  }

  static Future<http.Response> _withMainAuth(
    Future<http.Response> Function(Map<String, String> h) run,
  ) async {
    await _auth.ensureValidAccessToken();
    var h = ApiConfig.getHeaders(accessToken: _auth.accessToken);
    var resp = await run(h);
    if (!_isUnauthorized(resp.statusCode)) return resp;

    final refreshed = await _auth.refreshAccessToken();
    if (!refreshed) {
      await _logoutIfRefreshRejected();
      return resp;
    }

    h = ApiConfig.getHeaders(accessToken: _auth.accessToken);
    return run(h);
  }

  static Future<http.Response> _withPaymentAuth(
    Future<http.Response> Function(Map<String, String> h) run,
  ) async {
    await _auth.ensureValidAccessToken();
    var h = ApiConfig.getPaymentHeaders(accessToken: _auth.accessToken);
    var resp = await run(h);
    if (!_isUnauthorized(resp.statusCode)) return resp;

    final refreshed = await _auth.refreshAccessToken();
    if (!refreshed) {
      await _logoutIfRefreshRejected();
      return resp;
    }

    h = ApiConfig.getPaymentHeaders(accessToken: _auth.accessToken);
    return run(h);
  }

  static Duration _timeout([Duration? t]) => t ?? const Duration(seconds: 30);

  /// `PUT /payments/...`, etc.
  static Future<http.Response> paymentGet(Uri url, {Duration? timeout}) {
    return _withPaymentAuth(
      (headers) => http.get(url, headers: headers).timeout(_timeout(timeout)),
    );
  }

  static Future<http.Response> paymentPost(
    Uri url, {
    Object? body,
    Duration? timeout,
    Map<String, String>? mergeHeaders,
  }) {
    return _withPaymentAuth((headers) {
      final h = mergeHeaders != null ? {...headers, ...mergeHeaders} : headers;
      return http.post(url, headers: h, body: body).timeout(_timeout(timeout));
    });
  }

  /// Main API Gateway (`ApiConfig.baseUrl`).
  static Future<http.Response> get(Uri url, {Duration? timeout}) {
    return _withMainAuth(
      (headers) => http.get(url, headers: headers).timeout(_timeout(timeout)),
    );
  }

  static Future<http.Response> post(
    Uri url, {
    Object? body,
    Duration? timeout,
    Map<String, String>? mergeHeaders,
  }) {
    return _withMainAuth((headers) {
      final h = mergeHeaders != null ? {...headers, ...mergeHeaders} : headers;
      return http.post(url, headers: h, body: body).timeout(_timeout(timeout));
    });
  }

  static Future<http.Response> put(
    Uri url, {
    Object? body,
    Duration? timeout,
    Map<String, String>? mergeHeaders,
  }) {
    return _withMainAuth((headers) {
      final h = mergeHeaders != null ? {...headers, ...mergeHeaders} : headers;
      return http.put(url, headers: h, body: body).timeout(_timeout(timeout));
    });
  }

  static Future<http.Response> delete(
    Uri url, {
    Object? body,
    Duration? timeout,
  }) {
    return _withMainAuth(
      (headers) => http
          .delete(url, headers: headers, body: body)
          .timeout(_timeout(timeout)),
    );
  }

  /// Multipart POST (e.g. profile photo). Rebuilds the request on refresh so streams stay valid.
  static Future<http.StreamedResponse> sendMultipart(
    Future<http.MultipartRequest> Function(Map<String, String> headers)
    buildRequest,
  ) async {
    Future<http.StreamedResponse> send(Map<String, String> h) async {
      final req = await buildRequest(h);
      return req.send();
    }

    var resp = await send(ApiConfig.getHeaders(accessToken: _auth.accessToken));
    if (!_isUnauthorized(resp.statusCode)) return resp;

    await resp.stream.drain();

    final refreshed = await _auth.refreshAccessToken();
    if (!refreshed) {
      await _logoutIfRefreshRejected();
      return resp;
    }

    return send(ApiConfig.getHeaders(accessToken: _auth.accessToken));
  }
}
