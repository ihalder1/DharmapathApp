import 'package:colab_app_ui/security/stripe_checkout_url_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = StripeCheckoutUrlPolicy();
  const validSessionId = 'cs_test_1234567890abcdef';
  const validCheckoutUrl = 'https://checkout.stripe.com/c/pay/cs_test_example';

  group('initial Stripe Checkout URL', () {
    test('accepts exact checkout host and normalizes boundary whitespace', () {
      final accepted = <String>[
        validCheckoutUrl,
        'https://checkout.stripe.com/c/pay/cs_live_example',
        '  $validCheckoutUrl',
        '$validCheckoutUrl  ',
        '$validCheckoutUrl\n',
        'https://checkout.stripe.com:443/c/pay/cs_test_example',
        'https://checkout.stripe.com/c/pay/cs_test_example#fidn=test',
      ];

      for (final value in accepted) {
        final uri = policy.validateInitialCheckoutUrl(value);
        expect(uri, isNotNull, reason: value);
        expect(uri?.scheme, 'https');
        expect(uri?.host, 'checkout.stripe.com');
      }
    });

    test('rejects empty, malformed, relative and hostless URLs', () {
      final rejected = <String>[
        '',
        ' \t\n',
        '://not-a-url',
        '/c/pay/cs_test_example',
        'https:///c/pay/cs_test_example',
      ];

      for (final value in rejected) {
        expect(policy.validateInitialCheckoutUrl(value), isNull, reason: value);
      }
    });

    test('rejects insecure, lookalike and unapproved hosts', () {
      final rejected = <String>[
        'http://checkout.stripe.com/c/pay/cs_test_example',
        'https://stripe.com.attacker.example/c/pay/cs_test_example',
        'https://evilstripe.com/c/pay/cs_test_example',
      ];

      for (final value in rejected) {
        expect(policy.validateInitialCheckoutUrl(value), isNull, reason: value);
      }
    });

    test('rejects credentials, raw IP addresses and unexpected ports', () {
      final rejected = <String>[
        'https://user:password@checkout.stripe.com/c/pay/cs_test_example',
        'https://checkout.stripe.com:8443/c/pay/cs_test_example',
        'https://127.0.0.1/c/pay/cs_test_example',
        'https://[::1]/c/pay/cs_test_example',
      ];

      for (final value in rejected) {
        expect(policy.validateInitialCheckoutUrl(value), isNull, reason: value);
      }
    });
  });

  group('Stripe navigation', () {
    test('accepts exact approved Stripe hosts over HTTPS', () {
      final accepted = <String>[
        'https://checkout.stripe.com/c/pay/cs_test_example',
        'https://hooks.stripe.com/redirect/complete',
        'https://hooks.stripe.com:443/redirect/complete',
        'https://payments.stripe.com/payment_methods/test_payment',
        'https://pm-redirects.stripe.com/return/example?status=approved',
        'https://hooks.stripe.com/example',
      ];

      for (final value in accepted) {
        expect(policy.isAllowedStripeNavigation(value), isTrue, reason: value);
      }
    });

    test('rejects unknown hosts, lookalikes, HTTP, IPs and custom ports', () {
      final rejected = <String>[
        'https://example.com/pay',
        'https://stripe.com.attacker.example/pay',
        'http://payments.stripe.com/payment_methods/test_payment',
        'https://payments.stripe.com.attacker.example/payment_methods/test_payment',
        'https://evilstripe.com/',
        'https://payments.stripe.com:8443/payment_methods/test_payment',
        'http://pm-redirects.stripe.com/return/example',
        'https://pm-redirects.stripe.com.attacker.example/return/example',
        'https://pm-redirects.stripe.com:8443/return/example',
        'http://hooks.stripe.com/redirect',
        'https://127.0.0.1/redirect',
        'https://hooks.stripe.com:8443/redirect',
        'mailto:support@example.com',
      ];

      for (final value in rejected) {
        expect(policy.isAllowedStripeNavigation(value), isFalse, reason: value);
      }
    });
  });

  group('application callbacks', () {
    test('accepts exact success callbacks with one valid session ID', () {
      final accepted = <String>[
        'mantrasutra://payment/success?session_id=cs_test_example',
        'https://dharmapath.app/payment/success?session_id=cs_test_example',
      ];

      for (final value in accepted) {
        final callback = policy.classifyCallbackUrl(value);
        expect(
          callback.type,
          StripeCheckoutCallbackType.success,
          reason: value,
        );
        expect(callback.sessionId, 'cs_test_example', reason: value);
      }
    });

    test('accepts exact cancellation callback', () {
      final callback = policy.classifyCallbackUrl(
        'mantrasutra://payment/cancel',
      );

      expect(callback.type, StripeCheckoutCallbackType.cancel);
      expect(callback.sessionId, isNull);
    });

    test('rejects wrong scheme, host and path', () {
      final rejected = <String>[
        'other://payment/success?session_id=$validSessionId',
        'mantrasutra://other/success?session_id=$validSessionId',
        'mantrasutra://payment/unexpected?session_id=$validSessionId',
        'mantrasutra://payment/arbitrary/custom/path',
      ];

      for (final value in rejected) {
        expect(
          policy.classifyCallbackUrl(value).type,
          StripeCheckoutCallbackType.none,
          reason: value,
        );
      }
    });

    test('rejects missing, duplicate and malformed session IDs', () {
      final rejected = <String>[
        'mantrasutra://payment/success',
        'mantrasutra://payment/success?session_id=$validSessionId'
            '&session_id=cs_test_other12345',
        'mantrasutra://payment/success?session_id=short',
        'mantrasutra://payment/success?session_id=bad%0Aid',
        'mantrasutra://payment/success?session_id=bad%20id',
        'http://dharmapath.app/payment/success?session_id=cs_test_example',
        'https://evil.dharmapath.app/payment/success?session_id=cs_test_example',
        'https://dharmapath.app.attacker.example/payment/success'
            '?session_id=cs_test_example',
        'https://dharmapath.app/other?session_id=cs_test_example',
        'https://dharmapath.app/payment/success',
        'https://dharmapath.app/payment/success'
            '?session_id=one&session_id=two',
        'https://dharmapath.app:8443/payment/success'
            '?session_id=cs_test_example',
        r'https://dharmapath.app/payment/success?session_id=invalid$value',
      ];

      for (final value in rejected) {
        expect(
          policy.classifyCallbackUrl(value).type,
          StripeCheckoutCallbackType.none,
          reason: value,
        );
      }
    });

    test('rejects fragments, credentials and unexpected ports', () {
      final rejected = <String>[
        'mantrasutra://payment/success?session_id=$validSessionId#fragment',
        'mantrasutra://user:pass@payment/success'
            '?session_id=$validSessionId',
        'mantrasutra://payment:444/success?session_id=$validSessionId',
        'https://dharmapath.app/payment/success'
            '?session_id=cs_test_example#fragment',
      ];

      for (final value in rejected) {
        expect(
          policy.classifyCallbackUrl(value).type,
          StripeCheckoutCallbackType.none,
          reason: value,
        );
      }
    });
  });
}
