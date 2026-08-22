import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS consumable call uses the StoreKit-supported autoConsume default',
    () {
      final source = File(
        'lib/services/storekit_purchase_service.dart',
      ).readAsStringSync();
      final method = source.substring(
        source.indexOf('Future<bool> buyConsumable'),
        source.indexOf('Future<void> complete'),
      );

      expect(method, contains('_iap.buyConsumable('));
      expect(method, isNot(contains('autoConsume: false')));
    },
  );

  test(
    'verification, credit refresh, and completion ordering is preserved',
    () {
      final source = File(
        'lib/screens/storekit_checkout_screen.dart',
      ).readAsStringSync();
      final verify = source.indexOf('PaymentService.verifyIosPurchase(');
      final accepted = source.indexOf('if (!verification.paid)', verify);
      final refresh = source.indexOf('await _refreshCredits();', accepted);
      final cartGrant = source.indexOf(
        'await MantraService.consumeIosCartProducts(',
        refresh,
      );
      final complete = source.indexOf(
        'await _storeKit.complete(transaction);',
        cartGrant,
      );
      final persistCompletion = source.indexOf(
        'checkout = checkout.completeTransaction(index);',
        complete,
      );

      expect(verify, greaterThanOrEqualTo(0));
      expect(accepted, greaterThan(verify));
      expect(refresh, greaterThan(accepted));
      expect(cartGrant, greaterThan(refresh));
      expect(complete, greaterThan(cartGrant));
      expect(persistCompletion, greaterThan(complete));
    },
  );

  test(
    'iOS checkout contains one StoreKit purchase invocation and no loop',
    () {
      final source = File(
        'lib/screens/storekit_checkout_screen.dart',
      ).readAsStringSync();
      expect(
        RegExp(r'_storeKit\.buyConsumable\(').allMatches(source),
        hasLength(1),
      );
      expect(
        source,
        isNot(contains('for (var index = 0; index < checkout.units.length')),
      );
      expect(source, contains('requireIosAggregateStoreProduct'));
    },
  );

  test(
    'aggregate price is prepared during initialization and reused on tap',
    () {
      final source = File(
        'lib/screens/storekit_checkout_screen.dart',
      ).readAsStringSync();
      final initializeStart = source.indexOf('Future<void> _initialize()');
      final prepareCall = source.indexOf(
        'await _ensureAggregatePricePrepared();',
      );
      final purchaseStart = source.indexOf(
        'Future<void> _startOrContinueCheckout()',
      );
      final purchaseBody = source.substring(purchaseStart);

      expect(prepareCall, greaterThan(initializeStart));
      expect(prepareCall, lessThan(purchaseStart));
      expect(
        RegExp(r'PaymentService\.prepareIosPurchase\(').allMatches(source),
        hasLength(1),
      );
      expect(purchaseBody, isNot(contains('prepareIosPurchase(')));
      expect(source, contains("Text('Loading Apple price...')"));
      expect(source, contains('_readyForPurchase && !_processing'));
    },
  );

  test(
    'Android billing implementation is not routed through StoreKit service',
    () {
      final home = File('lib/screens/home_screen.dart').readAsStringSync();
      final checkoutHandler = home.indexOf('// Navigate to payment screen');
      final androidBranch = home.substring(
        home.indexOf('TargetPlatform.android', checkoutHandler),
        home.indexOf(
          'TargetPlatform.iOS',
          home.indexOf('TargetPlatform.android', checkoutHandler),
        ),
      );

      expect(androidBranch, contains('GooglePlayCheckoutScreen'));
      expect(androidBranch, isNot(contains('StoreKitCheckoutScreen')));
    },
  );
}
