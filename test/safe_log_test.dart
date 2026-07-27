import 'package:colab_app_ui/utils/safe_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SafeLog sanitizer', () {
    test('redacts nested token fields', () {
      final sanitized =
          SafeLog.sanitize({
                'result': {
                  'access_token': 'access-value',
                  'nested': {'refreshToken': 'refresh-value'},
                },
              })
              as Map<String, Object?>;

      final result = sanitized['result'] as Map<String, Object?>;
      final nested = result['nested'] as Map<String, Object?>;
      expect(result['access_token'], SafeLog.redacted);
      expect(nested['refreshToken'], SafeLog.redacted);
    });

    test('redacts Authorization headers', () {
      final sanitized = SafeLog.sanitizeHeaders({
        'Authorization': 'Bearer credential',
        'Content-Type': 'application/json',
      });

      expect(sanitized['Authorization'], SafeLog.redacted);
      expect(sanitized['Content-Type'], 'application/json');
    });

    test('redacts Stripe client secrets in maps and strings', () {
      final sanitized =
          SafeLog.sanitize({
                'clientSecret': 'pi_123_secret_sensitive',
                'message': 'payment failed for pi_123_secret_sensitive',
              })
              as Map<String, Object?>;

      expect(sanitized['clientSecret'], SafeLog.redacted);
      expect(sanitized['message'], 'payment failed for <redacted>');
    });

    test('retains ordinary non-sensitive metadata', () {
      final sanitized = SafeLog.sanitize({
        'operation': 'createPaymentIntent',
        'statusCode': 201,
        'success': true,
        'elapsedMs': 42,
      });

      expect(sanitized, {
        'operation': 'createPaymentIntent',
        'statusCode': 201,
        'success': true,
        'elapsedMs': 42,
      });
    });

    test('debug logging is disabled for release builds', () {
      expect(SafeLog.shouldEmitDebug(debugBuild: false), isFalse);
      expect(SafeLog.shouldEmitDebug(debugBuild: true), isTrue);
    });

    test('retains a stable event name and redacts configuration metadata', () {
      final record = SafeLog.buildRecord(
        'payment_session_creation_failed',
        metadata: {
          'statusCode': 503,
          'backendUrl': 'https://internal.example/payments',
          'publishableKey': 'pk_test_sensitive',
        },
      );
      final metadata = record['metadata'] as Map<String, Object?>;

      expect(record['event'], 'payment_session_creation_failed');
      expect(metadata['statusCode'], 503);
      expect(metadata['backendUrl'], SafeLog.redacted);
      expect(metadata['publishableKey'], SafeLog.redacted);
    });

    test('exception messages and stack traces are not included in records', () {
      final record = SafeLog.buildRecord(
        'auth_login_failed',
        error: Exception(
          'https://backend.example?token=secret person@example.com',
        ),
      );
      final encoded = record.toString();

      expect(encoded, contains('Exception'));
      expect(encoded, isNot(contains('backend.example')));
      expect(encoded, isNot(contains('person@example.com')));
      expect(encoded, isNot(contains('secret')));
    });
  });
}
