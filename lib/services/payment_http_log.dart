import 'dart:convert';

/// Shared verbose HTTP logging for payment and post-payment purchase APIs.
/// Uses [print] so everything appears in the **console** (stdout), not throttled like [debugPrint].
/// Request/response bodies are logged **exactly** as sent/received. Sensitive
/// header values are redacted (`Authorization`).
class PaymentHttpLog {
  static const String _sep =
      '═══════════════════════════════════════════════════════════';

  static Map<String, String> redactedHeaders(Map<String, String> headers) {
    final out = <String, String>{};
    for (final e in headers.entries) {
      final k = e.key;
      if (k.toLowerCase() == 'authorization') {
        out[k] = 'Bearer <REDACTED>';
      } else {
        out[k] = e.value;
      }
    }
    return out;
  }

  static void log({
    required String operation,
    required String method,
    required String urlExact,
    Map<String, String>? requestHeaders,
    String? requestBodyExact,
    required int responseStatus,
    Map<String, String>? responseHeaders,
    required String responseBodyExact,
  }) {
    final headersJson = requestHeaders != null
        ? json.encode(redactedHeaders(requestHeaders))
        : '{}';
    final respHeadersJson =
        responseHeaders != null ? json.encode(responseHeaders) : '{}';

    print(_sep);
    print('[PaymentHttpLog] $operation');
    print('METHOD: $method');
    print('URL (exact): $urlExact');
    print('REQUEST_HEADERS_JSON: $headersJson');
    if (requestBodyExact != null) {
      print('REQUEST_BODY_JSON (exact): $requestBodyExact');
    } else {
      print('REQUEST_BODY_JSON (exact): <none>');
    }
    print('RESPONSE_STATUS (exact): $responseStatus');
    print('RESPONSE_HEADERS_JSON (exact): $respHeadersJson');
    print('RESPONSE_BODY (exact): $responseBodyExact');
    print(_sep);
  }

  static void logError({
    required String operation,
    required String method,
    required String urlExact,
    Map<String, String>? requestHeaders,
    String? requestBodyExact,
    required Object error,
    required StackTrace stackTrace,
  }) {
    final headersJson = requestHeaders != null
        ? json.encode(redactedHeaders(requestHeaders))
        : '{}';
    print(_sep);
    print('[PaymentHttpLog] $operation — ERROR (no response or pre-request)');
    print('METHOD: $method');
    print('URL (exact): $urlExact');
    print('REQUEST_HEADERS_JSON: $headersJson');
    if (requestBodyExact != null) {
      print('REQUEST_BODY_JSON (exact): $requestBodyExact');
    } else {
      print('REQUEST_BODY_JSON (exact): <none>');
    }
    print('ERROR (exact): $error');
    print('STACK_TRACE (exact): $stackTrace');
    print(_sep);
  }
}
