import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' as foundation;

abstract interface class AppLogger {
  void debug(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  });

  void info(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  });

  void warning(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  });

  void error(
    String event, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> metadata = const <String, Object?>{},
  });
}

final class SafeAppLogger implements AppLogger {
  const SafeAppLogger();

  @override
  void debug(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => SafeLog.debug(event, metadata: metadata);

  @override
  void info(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => SafeLog.info(event, metadata: metadata);

  @override
  void warning(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => SafeLog.warning(event, metadata: metadata);

  @override
  void error(
    String event, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => SafeLog.error(
    event,
    error: error,
    stackTrace: stackTrace,
    metadata: metadata,
  );
}

const AppLogger appLogger = SafeAppLogger();

/// Debug-only application logging with mandatory recursive redaction.
///
/// Production builds never emit these messages. Callers should still prefer
/// small operational metadata over request/response payloads.
final class SafeLog {
  SafeLog._();

  static const String redacted = '<redacted>';

  static const Set<String> _sensitiveKeys = {
    'authorization',
    'accesstoken',
    'authtoken',
    'refreshtoken',
    'token',
    'password',
    'passwd',
    'secret',
    'clientsecret',
    'paymentintentclientsecret',
    'sessionid',
    'cookie',
    'setcookie',
    'recordingbase64',
    'audio',
    'base64',
    'fcmtoken',
    'idtoken',
    'oauthtoken',
    'email',
    'userid',
    'deviceid',
    'phone',
    'mobile',
    'name',
    'location',
    'recordingname',
    'filename',
    'url',
    'uri',
    'baseurl',
    'backendurl',
    'endpoint',
    'publishablekey',
    'firebaseid',
    'googleclientid',
    'facebookappid',
    'deeplink',
    'environment',
  };

  /// Runs application code in a zone that makes every legacy `print` and
  /// `debugPrint` call debug-only and sanitized at the final output sink.
  static Future<T> run<T>(Future<T> Function() action) {
    return runZoned(
      action,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          if (!foundation.kDebugMode) return;
          parent.print(zone, _sanitizeString(line));
        },
      ),
    );
  }

  static Object? sanitize(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _isSensitiveKey(entry.key.toString())
              ? redacted
              : sanitize(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(sanitize).toList(growable: false);
    }
    if (value is String) {
      return _sanitizeString(value);
    }
    return value;
  }

  static Map<String, String> sanitizeHeaders(Map<String, String> headers) {
    return <String, String>{
      for (final entry in headers.entries)
        entry.key: _isSensitiveKey(entry.key)
            ? redacted
            : _sanitizeString(entry.value),
    };
  }

  static Uri sanitizeUri(Uri uri) {
    if (uri.queryParameters.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{
        for (final entry in uri.queryParameters.entries)
          entry.key: _isSensitiveKey(entry.key)
              ? redacted
              : _sanitizeString(entry.value),
      },
    );
  }

  static void debug(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (!shouldEmitDebug(debugBuild: foundation.kDebugMode)) return;
    _emit('debug', event, metadata: metadata);
  }

  static void info(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (!foundation.kDebugMode) return;
    _emit('info', event, metadata: metadata);
  }

  static void warning(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (!foundation.kDebugMode) return;
    _emit('warning', event, metadata: metadata);
  }

  static void error(
    String event, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (!foundation.kDebugMode) return;
    // Raw exception messages and stack traces are deliberately excluded. An
    // approved crash reporter can consume a separately sanitized integration.
    _emit(
      'error',
      event,
      metadata:
          buildRecord(event, metadata: metadata, error: error)['metadata']
              as Map<String, Object?>,
    );
  }

  @foundation.visibleForTesting
  static bool shouldEmitDebug({required bool debugBuild}) => debugBuild;

  @foundation.visibleForTesting
  static Map<String, Object?> buildRecord(
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
    Object? error,
  }) {
    final safeMetadata = <String, Object?>{
      ...sanitize(metadata) as Map<String, Object?>,
      if (error != null) 'errorType': error.runtimeType.toString(),
    };
    return <String, Object?>{
      'event': _safeEventName(event),
      'metadata': safeMetadata,
    };
  }

  static void _emit(
    String level,
    String event, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final record = buildRecord(event, metadata: metadata);
    final safeMetadata = record['metadata'] as Map<String, Object?>;
    final suffix = safeMetadata.isEmpty ? '' : ' ${jsonEncode(safeMetadata)}';
    foundation.debugPrint('[App][$level] ${record['event']}$suffix');
  }

  static String _safeEventName(String event) {
    final normalized = event.trim().toLowerCase();
    return RegExp(r'^[a-z][a-z0-9_]{2,63}$').hasMatch(normalized)
        ? normalized
        : 'invalid_event';
  }

  static bool _isSensitiveKey(String key) {
    final normalized = key
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        .toLowerCase();
    return _sensitiveKeys.contains(normalized) ||
        normalized.endsWith('token') ||
        normalized.endsWith('password') ||
        normalized.endsWith('secret') ||
        normalized.contains('authorization') ||
        normalized.contains('cookie') ||
        normalized.contains('base64') ||
        normalized.endsWith('url') ||
        normalized.endsWith('uri');
  }

  static String _sanitizeString(String value) {
    final lower = value.toLowerCase();
    const payloadLabels = <String>[
      'request body',
      'response body',
      'response headers',
      'request headers',
      'json body',
      'exact payload',
      'full token',
    ];
    if (payloadLabels.any(lower.contains)) {
      final separator = value.indexOf(':');
      final label = separator >= 0 ? value.substring(0, separator) : 'payload';
      return '$label: <omitted>';
    }

    var sanitized = value;

    // JSON, header, query-string and key/value forms.
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'''(["']?(?:authorization|access[_-]?token|auth[_-]?token|refresh[_-]?token|id[_-]?token|fcm[_-]?token|token|password|passwd|client[_-]?secret|clientSecret|payment[_-]?intent[_-]?client[_-]?secret|paymentIntentClientSecret|session[_-]?id|cookie|set-cookie|recordingBase64|audio|base64)["']?\s*[:=]\s*)(["']?)[^,\s&}\]]+\2''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}$redacted',
    );

    // Bearer credentials can occur without an explicit Authorization key.
    sanitized = sanitized.replaceAll(
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer $redacted',
    );

    // Stripe client secrets have a recognizable value format.
    sanitized = sanitized.replaceAll(
      RegExp(r'\b(?:pi|seti|cs)_[A-Za-z0-9_]+_secret_[A-Za-z0-9]+\b'),
      redacted,
    );

    return sanitized;
  }
}
