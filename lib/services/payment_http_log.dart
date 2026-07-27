import '../utils/safe_log.dart';

/// Safe operational logging for payment and post-payment purchase APIs.
///
/// The body/header parameters remain in the API to avoid changing networking
/// call sites, but their values are intentionally never logged.
class PaymentHttpLog {
  static Map<String, String> redactedHeaders(Map<String, String> headers) =>
      SafeLog.sanitizeHeaders(headers);

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
    SafeLog.debug(
      operation,
      metadata: {
        'method': method,
        'statusCode': responseStatus,
        'success': responseStatus >= 200 && responseStatus < 400,
        'url': SafeLog.sanitizeUri(Uri.parse(urlExact)).toString(),
      },
    );
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
    SafeLog.error(
      operation,
      error: error,
      metadata: {
        'method': method,
        'success': false,
        'url': SafeLog.sanitizeUri(Uri.parse(urlExact)).toString(),
      },
    );
  }
}
