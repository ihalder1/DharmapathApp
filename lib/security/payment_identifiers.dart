import 'package:uuid/uuid.dart';

abstract interface class OrderIdGenerator {
  String generate();
}

/// Generates an opaque client attempt identifier using uuid 4.6.0's default
/// CryptoRNG, which is backed by `Random.secure()` on supported platforms.
final class SecureOrderIdGenerator implements OrderIdGenerator {
  const SecureOrderIdGenerator();

  @override
  String generate() => 'order_${const Uuid().v4()}';
}

/// Stable idempotency context for exactly one logical payment creation attempt.
final class PaymentAttemptContext {
  PaymentAttemptContext({
    OrderIdGenerator generator = const SecureOrderIdGenerator(),
  }) : _generator = generator;

  final OrderIdGenerator _generator;
  String? _idempotencyKey;

  String get idempotencyKey {
    final existing = _idempotencyKey;
    if (existing != null) return existing;

    final generated = _generator.generate();
    if (!PaymentIdentifierPolicy.isValidClientAttemptId(generated)) {
      throw StateError('Generated payment attempt identifier is invalid');
    }
    return _idempotencyKey = generated;
  }
}

final class PaymentIdentifierPolicy {
  PaymentIdentifierPolicy._();

  static final RegExp _clientAttemptPattern = RegExp(
    r'^order_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static final RegExp _backendIdentifierPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  static bool isValidClientAttemptId(String value) {
    return value.length == 42 && _clientAttemptPattern.hasMatch(value);
  }

  static bool isValidBackendIdentifier(String value) {
    return value.isNotEmpty &&
        value.length <= 255 &&
        _backendIdentifierPattern.hasMatch(value);
  }

  /// The backend order ID is authoritative when present and valid. Stripe's
  /// backend-issued payment/session ID is the compatibility fallback.
  static String resolveAuthoritativeId({
    String? backendOrderId,
    required String backendPaymentId,
  }) {
    if (backendOrderId != null && isValidBackendIdentifier(backendOrderId)) {
      return backendOrderId;
    }
    if (!isValidBackendIdentifier(backendPaymentId)) {
      throw FormatException('Backend payment identifier is invalid');
    }
    return backendPaymentId;
  }
}
