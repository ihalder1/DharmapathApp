import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/api_config.dart';
import '../security/payment_identifiers.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';
import 'payment_http_log.dart';

class PaymentService {
  static const String _createIntentInstructions =
      'Set currency to: usd, aud, eur, or gbp. unitAmount in smallest unit (cents). Each song is one product. Minimum: usd/aud/eur = 50 cents, gbp = 30p, inr = 5000 paise.';

  static const String _checkoutSessionInstructions =
      'UPI is INR only. Minimum 5000 paise (\u20b950). Open checkout_url in '
      'Flutter WebView. Set success_url to '
      'mantrasutra://payment/success?session_id={CHECKOUT_SESSION_ID} and '
      'cancel_url to mantrasutra://payment/cancel.';

  // TEMPORARY STRIPE UPI DIAGNOSTICS — REMOVE BEFORE RELEASE
  static String _sanitizeUpiDiagnosticText(Object? value) {
    if (value == null) return 'null';
    var sanitized = value.toString();
    sanitized = sanitized.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(
        r'(authorization|access[_-]?token|refresh[_-]?token|token|cookie|secret|email|phone|address)\s*[:=]\s*[^\s,;}]+',
        caseSensitive: false,
      ),
      '[REDACTED_SENSITIVE_FIELD]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\b(?:pk|sk)_(?:live|test)_[A-Za-z0-9_]+\b'),
      '[REDACTED_STRIPE_KEY]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'https?://[^\s,;}]+', caseSensitive: false),
      '[REDACTED_URL]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\b[^\s@]+@[^\s@]+\.[^\s@]+\b'),
      '[REDACTED_EMAIL]',
    );
    return sanitized.length <= 500
        ? sanitized
        : '${sanitized.substring(0, 500)}...[TRUNCATED]';
  }

  // TEMPORARY STRIPE UPI DIAGNOSTICS — REMOVE BEFORE RELEASE
  static Map<String, dynamic> _sanitizedCheckoutSessionResponse(
    String responseBody,
    Map<String, String> responseHeaders,
  ) {
    try {
      final decoded = json.decode(responseBody);
      if (decoded is! Map) {
        return {
          'success': false,
          'errorCode': 'non_object_response',
          'checkoutSessionIdPresent': false,
          'checkoutUrlPresent': false,
        };
      }
      final root = Map<String, dynamic>.from(decoded);
      final data = root['data'] is Map
          ? Map<String, dynamic>.from(root['data'] as Map)
          : const <String, dynamic>{};
      final nestedError = root['error'];
      final error = nestedError is Map
          ? Map<String, dynamic>.from(nestedError)
          : const <String, dynamic>{};
      final errorCode =
          root['errorCode'] ??
          root['error_code'] ??
          root['code'] ??
          error['code'];
      final errorType =
          root['errorType'] ?? root['error_type'] ?? error['type'];
      final errorMessage =
          root['errorMessage'] ??
          root['error_message'] ??
          root['message'] ??
          error['message'];
      final stripeRequestId =
          root['stripeRequestId'] ??
          root['stripe_request_id'] ??
          root['requestId'] ??
          root['request_id'] ??
          data['stripeRequestId'] ??
          data['stripe_request_id'] ??
          responseHeaders['stripe-request-id'] ??
          responseHeaders['request-id'];
      final checkoutSessionId =
          root['checkoutSessionId'] ??
          root['checkout_session_id'] ??
          root['sessionId'] ??
          root['session_id'] ??
          data['checkoutSessionId'] ??
          data['checkout_session_id'] ??
          data['sessionId'] ??
          data['session_id'];
      final checkoutUrl =
          root['checkoutUrl'] ??
          root['checkout_url'] ??
          root['url'] ??
          data['checkoutUrl'] ??
          data['checkout_url'] ??
          data['url'];
      return {
        'success': root['success'],
        'error': nestedError is bool ? nestedError : nestedError != null,
        'errorCode': errorCode == null
            ? null
            : _sanitizeUpiDiagnosticText(errorCode),
        'errorType': errorType == null
            ? null
            : _sanitizeUpiDiagnosticText(errorType),
        'errorMessage': errorMessage == null
            ? null
            : _sanitizeUpiDiagnosticText(errorMessage),
        'stripeRequestId': stripeRequestId == null
            ? null
            : _sanitizeUpiDiagnosticText(stripeRequestId),
        'checkoutSessionIdPresent':
            checkoutSessionId != null &&
            checkoutSessionId.toString().isNotEmpty,
        'checkoutUrlPresent':
            checkoutUrl != null && checkoutUrl.toString().isNotEmpty,
      }..removeWhere((_, value) => value == null);
    } catch (_) {
      return {
        'success': false,
        'errorCode': 'unparseable_response',
        'checkoutSessionIdPresent': false,
        'checkoutUrlPresent': false,
      };
    }
  }

  /// Create Payment Intent (card).
  /// Body: `{ "_instructions", "currency", "products": [ { "productId", "productName", "unitAmount" } ] }`.
  static Future<Map<String, dynamic>?> createPaymentIntent({
    required String currency,
    required List<Map<String, dynamic>> products,
    required String idempotencyKey,

    /// When set (e.g. `['card']`), the server should create the Stripe PaymentIntent
    /// with only these `payment_method_types` so PaymentSheet does not list UPI, etc.
    List<String>? paymentMethodTypes,
  }) async {
    if (!PaymentIdentifierPolicy.isValidClientAttemptId(idempotencyKey)) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'Invalid payment attempt identifier',
      );
    }
    final url =
        '${ApiConfig.paymentBaseUrl}${ApiConfig.createPaymentIntentEndpoint}';
    Map<String, String>? headers;
    String? bodyExact;

    try {
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        return null;
      }

      headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final requestBody = <String, dynamic>{
        '_instructions': _createIntentInstructions,
        'currency': currency.toLowerCase(),
        'products': products,
        if (paymentMethodTypes != null && paymentMethodTypes.isNotEmpty) ...{
          'paymentMethodTypes': paymentMethodTypes,
          'payment_method_types': paymentMethodTypes,
        },
      };
      bodyExact = json.encode(requestBody);

      final response = await AuthenticatedHttp.paymentPost(
        Uri.parse(url),
        body: bodyExact,
        mergeHeaders: {'Idempotency-Key': idempotencyKey},
      );

      PaymentHttpLog.log(
        operation: 'createPaymentIntent',
        method: 'POST',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        responseStatus: response.statusCode,
        responseHeaders: response.headers,
        responseBodyExact: response.body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e, stackTrace) {
      PaymentHttpLog.logError(
        operation: 'createPaymentIntent',
        method: 'POST',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  // Confirm Payment (Backend Verification)
  static Future<bool> confirmPayment({required String paymentIntentId}) async {
    final url =
        '${ApiConfig.paymentBaseUrl}${ApiConfig.confirmPaymentEndpoint}';
    Map<String, String>? headers;
    String? bodyExact;

    try {
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        return false;
      }

      headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final requestBody = <String, dynamic>{'paymentIntentId': paymentIntentId};
      bodyExact = json.encode(requestBody);

      final response = await AuthenticatedHttp.paymentPost(
        Uri.parse(url),
        body: bodyExact,
      );

      PaymentHttpLog.log(
        operation: 'confirmPayment',
        method: 'POST',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        responseStatus: response.statusCode,
        responseHeaders: response.headers,
        responseBodyExact: response.body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      }
      return false;
    } catch (e, stackTrace) {
      PaymentHttpLog.logError(
        operation: 'confirmPayment',
        method: 'POST',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  // Get Payment Status
  static Future<Map<String, dynamic>?> getPaymentStatus({
    required String paymentIntentId,
  }) async {
    final url =
        '${ApiConfig.paymentBaseUrl}${ApiConfig.getPaymentStatusEndpoint}/$paymentIntentId';
    Map<String, String>? headers;

    try {
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        return null;
      }

      headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final response = await AuthenticatedHttp.paymentGet(Uri.parse(url));

      PaymentHttpLog.log(
        operation: 'getPaymentStatus',
        method: 'GET',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: null,
        responseStatus: response.statusCode,
        responseHeaders: response.headers,
        responseBodyExact: response.body,
      );

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e, stackTrace) {
      PaymentHttpLog.logError(
        operation: 'getPaymentStatus',
        method: 'GET',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: null,
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Stripe Checkout Session for UPI (hosted Checkout URL in WebView).
  /// Body: `{ "_instructions", "currency", "products": [ { "productId", "productName", "unitAmount" } ] }`.
  static Future<Map<String, dynamic>?> createCheckoutSession({
    required String currency,
    required List<Map<String, dynamic>> products,
    required String idempotencyKey,
  }) async {
    if (!PaymentIdentifierPolicy.isValidClientAttemptId(idempotencyKey)) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'Invalid payment attempt identifier',
      );
    }
    final url =
        '${ApiConfig.paymentBaseUrl}${ApiConfig.createCheckoutSessionEndpoint}';
    Map<String, String>? headers;
    String? bodyExact;

    try {
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        return null;
      }

      headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final requestBody = <String, dynamic>{
        '_instructions': _checkoutSessionInstructions,
        'currency': currency.toLowerCase(),
        'products': products,
      };
      bodyExact = json.encode(requestBody);

      // TEMPORARY STRIPE UPI DIAGNOSTICS — REMOVE BEFORE RELEASE
      final endpointUri = Uri.parse(url);
      final productIds = products
          .map((product) => product['productId'])
          .whereType<String>()
          .toList(growable: false);
      final amountSmallestUnit = products.fold<int>(0, (sum, product) {
        final unitAmount = product['unitAmount'];
        return sum + (unitAmount is int ? unitAmount : 0);
      });
      debugPrint(
        '[STRIPE_UPI_DEBUG] Checkout-session request prepared; method=POST; '
        'endpoint=${ApiConfig.createCheckoutSessionEndpoint}; '
        'backendHost=${endpointUri.host}; '
        'requestFieldNames=${requestBody.keys.toList(growable: false)}; '
        'productFieldNames=${products.isEmpty ? const <String>[] : products.first.keys.toList(growable: false)}; '
        'amountSmallestUnit=$amountSmallestUnit; '
        'currency=${currency.toLowerCase()}; quantity=${products.length}; '
        'paymentMethodType=upi; productIds=$productIds; '
        'orderId=$idempotencyKey',
      );
      debugPrint('[STRIPE_UPI_DEBUG] Stage backend request sent=true');

      final response = await AuthenticatedHttp.paymentPost(
        Uri.parse(url),
        body: bodyExact,
        mergeHeaders: {'Idempotency-Key': idempotencyKey},
      );
      // TEMPORARY STRIPE UPI DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint('[STRIPE_UPI_DEBUG] Stage backend response received=true');
      final sanitizedResponse = _sanitizedCheckoutSessionResponse(
        response.body,
        response.headers,
      );
      debugPrint(
        '[STRIPE_UPI_DEBUG] Checkout-session backend response; '
        'statusCode=${response.statusCode}; sanitizedBody=$sanitizedResponse',
      );
      PaymentHttpLog.log(
        operation: 'createCheckoutSession',
        method: 'POST',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        responseStatus: response.statusCode,
        responseHeaders: response.headers,
        responseBodyExact: response.body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (error, stackTrace) {
      // TEMPORARY STRIPE UPI DIAGNOSTICS — REMOVE BEFORE RELEASE
      debugPrint(
        '[STRIPE_UPI_DEBUG] Checkout-session exception; '
        'runtimeType=${error.runtimeType}; '
        'httpExceptionType=${error is http.ClientException ? error.runtimeType : 'not_http_client_exception'}; '
        'statusCode=unavailable; '
        'endpoint=${ApiConfig.createCheckoutSessionEndpoint}; '
        'message=${_sanitizeUpiDiagnosticText(error)}; '
        'sanitizedResponse=unavailable',
      );
      debugPrint('[STRIPE_UPI_DEBUG] Stack trace:\n$stackTrace');
      PaymentHttpLog.logError(
        operation: 'createCheckoutSession',
        method: 'POST',
        urlExact: url,
        requestHeaders: headers,
        requestBodyExact: bodyExact,
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// GET `/payments/verify-session?session_id=...` — UI feedback only; webhook is source of truth.
  static Future<Map<String, dynamic>?> verifyCheckoutSession({
    required String sessionId,
  }) async {
    final url = Uri.parse(
      '${ApiConfig.paymentBaseUrl}${ApiConfig.verifyCheckoutSessionEndpoint}',
    ).replace(queryParameters: {'session_id': sessionId});
    final urlExact = url.toString();
    Map<String, String>? headers;

    try {
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        return null;
      }

      headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final response = await AuthenticatedHttp.paymentGet(url);

      PaymentHttpLog.log(
        operation: 'verifyCheckoutSession',
        method: 'GET',
        urlExact: urlExact,
        requestHeaders: headers,
        requestBodyExact: null,
        responseStatus: response.statusCode,
        responseHeaders: response.headers,
        responseBodyExact: response.body,
      );

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e, stackTrace) {
      PaymentHttpLog.logError(
        operation: 'verifyCheckoutSession',
        method: 'GET',
        urlExact: urlExact,
        requestHeaders: headers,
        requestBodyExact: null,
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Poll until backend reports paid (webhook may lag) or a terminal non-paid state / timeout.
  static Future<CheckoutSessionVerifyOutcome> verifyCheckoutSessionUntilPaid({
    required String sessionId,
    int maxAttempts = 30,
    Duration interval = const Duration(seconds: 2),
  }) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final data = await verifyCheckoutSession(sessionId: sessionId);
      final parsed = parseCheckoutVerifyResponse(data);
      switch (parsed) {
        case CheckoutSessionVerifyOutcome.paid:
        case CheckoutSessionVerifyOutcome.failed:
        case CheckoutSessionVerifyOutcome.unpaid:
          return parsed;
        case CheckoutSessionVerifyOutcome.pending:
        case CheckoutSessionVerifyOutcome.unknown:
        case CheckoutSessionVerifyOutcome.timeout:
          break;
      }
      await Future<void>.delayed(interval);
    }
    return CheckoutSessionVerifyOutcome.timeout;
  }

  static CheckoutSessionVerifyOutcome parseCheckoutVerifyResponse(
    Map<String, dynamic>? body,
  ) {
    if (body == null) return CheckoutSessionVerifyOutcome.unknown;

    bool? asBool(dynamic v) {
      if (v is bool) return v;
      if (v is String) {
        final s = v.toLowerCase();
        if (s == 'true') return true;
        if (s == 'false') return false;
      }
      return null;
    }

    String? str(dynamic v) => v?.toString();

    final paid = asBool(body['paid'] ?? body['isPaid']);
    if (paid == true) return CheckoutSessionVerifyOutcome.paid;
    if (paid == false &&
        (body.containsKey('paid') || body.containsKey('isPaid'))) {
      return CheckoutSessionVerifyOutcome.unpaid;
    }

    final paymentStatus =
        str(body['payment_status'] ?? body['paymentStatus'])?.toLowerCase() ??
        '';
    final status = str(body['status'])?.toLowerCase() ?? '';

    if (paymentStatus == 'paid' ||
        paymentStatus == 'succeeded' ||
        (status == 'complete' && paymentStatus == 'paid')) {
      return CheckoutSessionVerifyOutcome.paid;
    }
    if (paymentStatus == 'canceled' ||
        paymentStatus == 'cancelled' ||
        status == 'expired') {
      return CheckoutSessionVerifyOutcome.failed;
    }
    if (paymentStatus == 'unpaid' && status == 'complete') {
      return CheckoutSessionVerifyOutcome.pending;
    }
    if (status == 'open' || paymentStatus == 'unpaid') {
      return CheckoutSessionVerifyOutcome.pending;
    }

    return CheckoutSessionVerifyOutcome.unknown;
  }
}

/// Result of interpreting [verifyCheckoutSession] JSON (until webhook, may stay pending).
enum CheckoutSessionVerifyOutcome {
  paid,
  pending,
  unpaid,
  failed,
  unknown,
  timeout,
}
