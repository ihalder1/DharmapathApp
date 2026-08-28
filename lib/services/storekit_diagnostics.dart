import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/ios_purchase.dart';

/// Compatibility boundary for StoreKit call sites. Production diagnostics
/// are intentionally disabled; sanitization helpers remain for safe errors.
final class StoreKitDiagnostics {
  StoreKitDiagnostics({this.checkoutInstance});

  final String? checkoutInstance;

  void log(String event, [Map<String, Object?> fields = const {}]) {
    if (!kDebugMode) return;
    final sessionBoundary =
        event == 'NEW_APPLE_CHECKOUT_SESSION' ||
        event == 'CHECKOUT_SESSION_END';
    if (sessionBoundary) {
      debugPrint(
        '[IOS_IAP_DIAG] ============================================================',
      );
    }
    final category = _categoryFor(event);
    final safeFields = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      if (checkoutInstance != null) 'instance': checkoutInstance,
      ...fields.map((key, value) => MapEntry(key, _sanitizeValue(key, value))),
    };
    debugPrint(
      '[IOS_IAP_DIAG][$category] event=$event ${jsonEncode(safeFields)}',
    );
    if (sessionBoundary) {
      debugPrint(
        '[IOS_IAP_DIAG] ============================================================',
      );
    }
  }

  void logProductLookup({
    required String internalProductId,
    required String metadataStoreProductId,
    required String queriedProductId,
    required bool found,
    String? price,
    double? rawPrice,
    String? currencyCode,
  }) => log('PRODUCT_LOOKUP', {
    'platform': 'ios',
    'internalSongId': internalProductId,
    'metadataStoreProductId': metadataStoreProductId,
    'queriedProductId': queriedProductId,
    'found': found,
    'price': price,
    'rawPrice': rawPrice,
    'currencyCode': currencyCode,
  });

  void logPrepareRequest({
    required String currency,
    required Iterable<IosCartProduct> products,
  }) => log('PREPARE_REQUEST', {
    'platform': 'ios',
    'currency': currency.toLowerCase(),
    'products': products
        .map(
          (item) => {
            'productId': item.internalProductId,
            'productName': item.productName,
          },
        )
        .toList(),
  });

  void logPrepareResponse({
    required int httpStatus,
    required bool orderIdPresent,
    String? orderId,
    required bool linkTokenPresent,
    bool? linkTokenValid,
    Object? storeProducts,
  }) => log('PREPARE_RESPONSE', {
    'httpStatus': httpStatus,
    'orderIdPresent': orderIdPresent,
    'orderId': redactIdentifier(orderId),
    'linkTokenPresent': linkTokenPresent,
    'linkTokenCanonicalUuid': linkTokenValid,
    'storeProducts': storeProducts,
  });

  void logPrepareHttpResponse({
    required int httpStatus,
    required String responseBody,
    required int durationMs,
  }) => log('BACKEND_PREPARE_HTTP_RESPONSE', {
    'httpStatus': httpStatus,
    'durationMs': durationMs,
    'responseBody': _sanitizeResponseBody(responseBody),
  });

  void logMapping({
    required String internalProductId,
    required String metadataStoreProductId,
    String? backendStoreProductId,
  }) {
    final matches = metadataStoreProductId == backendStoreProductId;
    log('MAPPING', {
      'internalSongId': internalProductId,
      'metadataAppleProductId': metadataStoreProductId,
      'backendAppleProductId': backendStoreProductId ?? '<missing>',
      'match': matches ? 'YES' : 'NO',
    });
    if (!matches) {
      log('MAPPING VALIDATION FAILED', {
        'Expected': metadataStoreProductId,
        'Backend returned': backendStoreProductId ?? '<missing>',
      });
    }
  }

  void logPurchase({
    required String event,
    required String storeProductId,
    String? status,
    String? transactionId,
  }) => log(event, {
    'storeProductId': storeProductId,
    'status': status,
    'transactionIdPresent': transactionId?.isNotEmpty == true,
    'transactionId': redactIdentifier(transactionId),
  });

  void logAppAccountTokenCorrelation({
    required String event,
    required String? persistedToken,
    String? suppliedToken,
    String? returnedToken,
  }) {
    String? suffix(String? value) {
      final trimmed = value?.trim() ?? '';
      return trimmed.length < 4 ? null : trimmed.substring(trimmed.length - 4);
    }

    final expected = normalizeCanonicalUuid(persistedToken);
    final supplied = suppliedToken == null
        ? null
        : normalizeCanonicalUuid(suppliedToken);
    final returned = returnedToken == null
        ? null
        : normalizeCanonicalUuid(returnedToken);
    log(event, {
      'linkTokenPresent': persistedToken?.trim().isNotEmpty == true,
      'linkTokenCanonicalUuid': expected != null,
      'expectedTokenSuffix': suffix(persistedToken),
      if (suppliedToken != null) ...{
        'suppliedTokenPresent': suppliedToken.trim().isNotEmpty,
        'suppliedTokenSuffix': suffix(suppliedToken),
        'persistedVsSuppliedMatch': expected != null && expected == supplied
            ? 'YES'
            : 'NO',
      },
      if (returnedToken != null) ...{
        'returnedAppAccountTokenPresent': returnedToken.trim().isNotEmpty,
        'returnedTokenSuffix': suffix(returnedToken),
        'match': expected != null && expected == returned ? 'YES' : 'NO',
      } else if (event.contains('RETURNED'))
        'returnedAppAccountTokenPresent': false,
    });
  }

  void logVerify({
    required String event,
    required String orderId,
    required String storeProductId,
    String? transactionId,
    int? httpStatus,
    String? backendStatus,
  }) => log(event, {
    'orderId': redactIdentifier(orderId),
    'platform': 'ios',
    'storeProductId': storeProductId,
    'transactionIdSupplied': transactionId?.isNotEmpty == true,
    'transactionId': redactIdentifier(transactionId),
    'httpStatus': httpStatus,
    'backendStatus': backendStatus,
  });

  void logVerifyHttpResponse({
    required int httpStatus,
    required String responseBody,
  }) => log('BACKEND_VERIFY_HTTP_RESPONSE', {
    'httpStatus': httpStatus,
    'responseBody': _sanitizeResponseBody(responseBody),
  });

  void logError({
    required String stage,
    required Object error,
    int? httpStatus,
  }) => log('ERROR', {
    'stage': stage,
    'type': error.runtimeType.toString(),
    'message': _sanitizeError(error),
    'httpStatus': httpStatus,
  });

  static String safeErrorMessage(Object error) => _sanitizeError(error);

  static String redactIdentifier(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '<absent>';
    final suffix = text.length <= 4 ? text : text.substring(text.length - 4);
    return '****$suffix';
  }

  static String _sanitizeError(Object error) {
    var value = error.toString();
    value = value.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    value = value.replaceAll(
      RegExp(
        r'(linkToken|token|authorization|receipt|jws|secret)\s*[:=]\s*[^\s,;}]+',
        caseSensitive: false,
      ),
      '[REDACTED_SENSITIVE_FIELD]',
    );
    value = value.replaceAll(
      RegExp(
        r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
        caseSensitive: false,
      ),
      '[REDACTED_UUID]',
    );
    value = value.replaceAll(RegExp(r'\b\d{10,}\b'), '[REDACTED_LONG_ID]');
    value = value.replaceAll(
      RegExp(r'\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      '[REDACTED_JWT]',
    );
    return value.length <= 240 ? value : '${value.substring(0, 240)}…';
  }

  static Object? _sanitizeValue(String key, Object? value) {
    final normalized = key.toLowerCase();
    if (normalized.contains('verificationdata') ||
        normalized.contains('receipt') ||
        normalized.contains('jws') ||
        normalized == 'token' ||
        normalized.contains('accesstoken') ||
        normalized.contains('authorization')) {
      return value == null ? null : '<redacted>';
    }
    if (normalized.contains('linktoken') ||
        normalized.contains('appaccounttoken')) {
      return redactIdentifier(value?.toString());
    }
    if (value is Map) {
      return value.map(
        (key, item) =>
            MapEntry(key.toString(), _sanitizeValue(key.toString(), item)),
      );
    }
    if (value is Iterable) {
      return value.map((item) => _sanitizeValue(key, item)).toList();
    }
    if (value is String) return _sanitizeError(value);
    return value;
  }

  static String _sanitizeResponseBody(String body) {
    try {
      final decoded = jsonDecode(body);
      return jsonEncode(_sanitizeValue('response', decoded));
    } catch (_) {
      return _sanitizeError(body);
    }
  }

  static String _categoryFor(String event) {
    if (event.contains('QUERY') || event.contains('PRICE')) {
      return 'PRODUCT_QUERY';
    }
    if (event.contains('STREAM') || event.contains('UPDATE')) {
      return 'PURCHASE_STREAM';
    }
    if (event.contains('LIFECYCLE')) return 'LIFECYCLE';
    if (event.contains('CONTEXT') || event.contains('PERSIST')) {
      return 'CONTEXT';
    }
    if (event.contains('RECONCIL')) return 'RECONCILE';
    if (event.contains('BACKEND') ||
        event.contains('PREPARE') ||
        event.contains('VERIFY')) {
      return 'BACKEND';
    }
    if (event.contains('STATE') || event.contains('CANCEL')) return 'STATE';
    if (event.contains('PURCHASE') || event.contains('STOREKIT')) {
      return 'PURCHASE';
    }
    return 'CHECKOUT';
  }
}
