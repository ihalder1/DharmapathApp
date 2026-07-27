import 'package:colab_app_ui/security/payment_identifiers.dart';
import 'package:flutter_test/flutter_test.dart';

final class SequenceOrderIdGenerator implements OrderIdGenerator {
  int calls = 0;

  @override
  String generate() {
    calls++;
    return calls == 1
        ? 'order_123e4567-e89b-42d3-a456-426614174000'
        : 'order_123e4567-e89b-42d3-a456-426614174001';
  }
}

void main() {
  group('SecureOrderIdGenerator', () {
    test(
      'generates valid unique UUID v4 identifiers across a large sample',
      () {
        const generator = SecureOrderIdGenerator();
        final identifiers = <String>{};

        for (var index = 0; index < 10000; index++) {
          final identifier = generator.generate();
          expect(
            PaymentIdentifierPolicy.isValidClientAttemptId(identifier),
            isTrue,
          );
          identifiers.add(identifier);
        }

        expect(identifiers, hasLength(10000));
      },
    );

    test('does not include user or payment data', () {
      const generator = SecureOrderIdGenerator();
      final identifier = generator.generate();

      expect(identifier, isNot(contains('person@example.com')));
      expect(identifier, isNot(contains('411111')));
      expect(identifier, isNot(contains('user-123')));
      expect(identifier, isNot(contains(RegExp(r'\s'))));
    });
  });

  group('PaymentAttemptContext', () {
    test('retries for one logical payment reuse the same idempotency key', () {
      final generator = SequenceOrderIdGenerator();
      final attempt = PaymentAttemptContext(generator: generator);

      expect(attempt.idempotencyKey, attempt.idempotencyKey);
      expect(generator.calls, 1);
    });

    test('a new logical payment receives a new idempotency key', () {
      final generator = SequenceOrderIdGenerator();
      final first = PaymentAttemptContext(generator: generator);
      final second = PaymentAttemptContext(generator: generator);

      expect(first.idempotencyKey, isNot(second.idempotencyKey));
      expect(generator.calls, 2);
    });
  });

  group('authoritative backend identifiers', () {
    test('backend order ID takes precedence', () {
      expect(
        PaymentIdentifierPolicy.resolveAuthoritativeId(
          backendOrderId: 'backend_order_123',
          backendPaymentId: 'cs_test_1234567890',
        ),
        'backend_order_123',
      );
    });

    test('backend payment ID is the compatibility fallback', () {
      expect(
        PaymentIdentifierPolicy.resolveAuthoritativeId(
          backendOrderId: null,
          backendPaymentId: 'cs_test_1234567890',
        ),
        'cs_test_1234567890',
      );
    });

    test('rejects malformed backend identifiers', () {
      expect(
        () => PaymentIdentifierPolicy.resolveAuthoritativeId(
          backendOrderId: null,
          backendPaymentId: 'bad identifier\n',
        ),
        throwsFormatException,
      );
    });
  });
}
