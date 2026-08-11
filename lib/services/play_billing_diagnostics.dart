import 'dart:convert';

import 'package:flutter/foundation.dart';

// TEMPORARY GOOGLE PLAY BILLING UI DIAGNOSTICS.
// REMOVE BEFORE PRODUCTION RELEASE.
const bool temporaryPlayBillingUiDebug = true;

const bool playBillingDiagnostics = bool.fromEnvironment(
  'PLAY_BILLING_DIAGNOSTICS',
);

void playBillingLog(String message) {
  if (kDebugMode || playBillingDiagnostics) {
    debugPrint('PLAY_BILLING_DEBUG $message');
  }
}

String sanitizePlayBillingDiagnostic(Object? value) {
  var sanitized = value?.toString() ?? 'null';
  sanitized = sanitized.replaceAll(
    RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(
      r'(purchaseToken|linkToken|access[_-]?token|refresh[_-]?token|token|authorization|jwt|secret|email|phone|address|card|upi|payment[_-]?method|accountId|obfuscatedAccountId)\s*[:=]\s*[^\s,;}]+',
      caseSensitive: false,
    ),
    '[REDACTED_SENSITIVE_FIELD]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    '[REDACTED_EMAIL]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
    '[REDACTED_JWT]',
  );
  return sanitized.length <= 300 ? sanitized : sanitized.substring(0, 300);
}

final class AndroidPaymentDiagnostic {
  const AndroidPaymentDiagnostic({
    required this.operation,
    required this.stage,
    this.httpStatus,
    this.backendStatus,
    this.safeCode,
    this.safeMessage,
    this.errorType,
    this.orderId,
    this.storeProductIds = const [],
    this.linkTokenPresent,
    this.accepted,
    this.paid,
  });

  final String operation;
  final String stage;
  final int? httpStatus;
  final String? backendStatus;
  final String? safeCode;
  final String? safeMessage;
  final String? errorType;
  final String? orderId;
  final List<String> storeProductIds;
  final bool? linkTokenPresent;
  final bool? accepted;
  final bool? paid;
}

typedef AndroidPaymentDiagnosticCallback =
    void Function(AndroidPaymentDiagnostic diagnostic);

final class AndroidBillingHttpException implements Exception {
  const AndroidBillingHttpException({
    required this.operation,
    required this.httpStatus,
    this.safeCode,
    this.safeMessage,
  });

  final String operation;
  final int httpStatus;
  final String? safeCode;
  final String? safeMessage;

  @override
  String toString() =>
      'AndroidBillingHttpException(operation=$operation, httpStatus=$httpStatus, '
      'code=${safeCode ?? 'unknown'}, message=${safeMessage ?? 'unavailable'})';
}

final class SafeAndroidBillingError {
  const SafeAndroidBillingError({this.code, this.message, this.status});

  final String? code;
  final String? message;
  final String? status;
}

SafeAndroidBillingError safeAndroidBillingErrorFromBody(String responseBody) {
  try {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map) return const SafeAndroidBillingError();
    var map = Map<String, dynamic>.from(decoded);
    if (map['data'] is Map) map = Map<String, dynamic>.from(map['data'] as Map);
    if (map['error'] is Map) {
      map = {...map, ...Map<String, dynamic>.from(map['error'] as Map)};
    }
    String? safeValue(List<String> keys) {
      for (final key in keys) {
        final value = map[key];
        if (value is String || value is num || value is bool) {
          final sanitized = sanitizePlayBillingDiagnostic(value);
          return sanitized.length <= 200
              ? sanitized
              : sanitized.substring(0, 200);
        }
      }
      return null;
    }

    return SafeAndroidBillingError(
      code: safeValue(const ['code', 'errorCode', 'error_code']),
      message: safeValue(const [
        'message',
        'errorMessage',
        'error_message',
        'error',
      ]),
      status: safeValue(const ['status']),
    );
  } catch (_) {
    return const SafeAndroidBillingError();
  }
}
