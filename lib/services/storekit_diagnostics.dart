import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/ios_purchase.dart';

typedef StoreKitDiagnosticsListener = void Function();

/// In-memory, iOS-only diagnostic journal. It intentionally accepts structured
/// non-sensitive fields instead of arbitrary request/response bodies.
final class StoreKitDiagnostics {
  StoreKitDiagnostics({this.onChanged});

  final StoreKitDiagnosticsListener? onChanged;
  final List<String> _entries = [];

  List<String> get entries => List.unmodifiable(_entries);
  String get text => _entries.join('\n');

  void clear() {
    _entries.clear();
    onChanged?.call();
  }

  void log(String event, [Map<String, Object?> fields = const {}]) {
    final safeFields = fields.entries
        .where((entry) => entry.value != null)
        .map((entry) => '${entry.key}=${_sanitize(entry.value)}')
        .join(' ');
    final timestamp = DateTime.now().toIso8601String();
    _entries.add(
      '$timestamp $event${safeFields.isEmpty ? '' : ' $safeFields'}',
    );
    if (kDebugMode) {
      debugPrint(
        'STOREKIT_DEBUG $event${safeFields.isEmpty ? '' : ' $safeFields'}',
      );
    }
    onChanged?.call();
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
  }) {
    final decoded = _decodeBackendBody(responseBody);
    log('BACKEND_VERIFY_HTTP_RESPONSE', {
      'httpStatus': httpStatus,
      'responseBodyPresent': responseBody.trim().isNotEmpty,
      'responseBodyJson': decoded != null,
      'backendErrorCode': _firstBackendValue(decoded, const [
        'code',
        'errorCode',
        'error_code',
      ]),
      'backendMessage': _firstBackendValue(decoded, const [
        'message',
        'errorMessage',
        'error_message',
      ]),
      'responseFields': decoded == null
          ? responseBody.trim().isEmpty
                ? const <String, Object?>{}
                : {'text': responseBody}
          : _allowlistedBackendFields(decoded),
    });
  }

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

  static Map<String, dynamic>? _decodeBackendBody(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static Object? _firstBackendValue(
    Map<String, dynamic>? body,
    Iterable<String> keys,
  ) {
    if (body == null) return null;
    for (final key in keys) {
      if (body[key] != null) return body[key];
    }
    for (final container in const ['data', 'error']) {
      final value = body[container];
      if (value is! Map) continue;
      final nested = Map<String, dynamic>.from(value);
      for (final key in keys) {
        if (nested[key] != null) return nested[key];
      }
    }
    return null;
  }

  static Map<String, Object?> _allowlistedBackendFields(
    Map<String, dynamic> body,
  ) {
    const allowed = {
      'code',
      'errorCode',
      'error_code',
      'message',
      'errorMessage',
      'error_message',
      'status',
      'paymentStatus',
      'payment_status',
      'reason',
      'type',
      'platform',
      'storeProductId',
      'store_product_id',
      'productId',
      'product_id',
    };
    final result = <String, Object?>{};
    for (final entry in body.entries) {
      if (allowed.contains(entry.key)) {
        result[entry.key] = entry.value;
      } else if ((entry.key == 'data' || entry.key == 'error') &&
          entry.value is Map) {
        final nested = _allowlistedBackendFields(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (nested.isNotEmpty) result[entry.key] = nested;
      }
    }
    return result;
  }

  static String _sanitize(Object? value) {
    if (value == null) return 'null';
    if (value is Iterable) return '[${value.map(_sanitize).join(', ')}]';
    if (value is Map) {
      return '{${value.entries.map((entry) {
        final key = entry.key.toString();
        final sensitive = RegExp(r'(token|authorization|receipt|jws|secret)', caseSensitive: false).hasMatch(key);
        return '$key: ${sensitive ? '[REDACTED]' : _sanitize(entry.value)}';
      }).join(', ')}}';
    }
    return _sanitizeError(value);
  }
}
