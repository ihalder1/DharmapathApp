import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:colab_app_ui/services/storekit_purchase_service.dart';

void main() {
  test('old unfinished token-mismatched transaction is isolated', () {
    const old = StoreKitTransaction(
      productId: 'aggregate.product',
      transactionId: 'old-3279',
      originalTransactionId: 'original-3279',
      appAccountToken: '00000000-0000-0000-0000-0000000018c9',
      status: PurchaseStatus.purchased,
      transactionDate: '2026-11-05',
      environment: 'Sandbox',
      signedTransactionData: 'signed-jws',
    );
    expect(
      isActiveCheckoutTransaction(
        transaction: old,
        expectedProductId: 'aggregate.product',
        expectedAppAccountToken: '00000000-0000-0000-0000-000000003688',
      ),
      isFalse,
    );
    expect(old.transactionId, 'old-3279');
    expect(old.originalTransactionId, 'original-3279');
    expect(old.signedTransactionData, 'signed-jws');
    expect(old.environment, 'Sandbox');
  });

  test('purchase stream has one application-level listener', () {
    final source = File(
      'lib/services/storekit_purchase_service.dart',
    ).readAsStringSync();
    expect(
      RegExp(r'_iap\.purchaseStream\.listen\(').allMatches(source),
      hasLength(1),
    );
    expect(source, contains('static final StoreKitPurchaseService instance'));
  });

  test('catalogue query completes before pending-order reconciliation', () {
    final source = File(
      'lib/screens/storekit_checkout_screen.dart',
    ).readAsStringSync();
    final initializeStart = source.indexOf('Future<void> _initialize()');
    final retryStart = source.indexOf('Future<void> _retryVerification()');
    final initialize = source.substring(initializeStart, retryStart);

    expect(
      initialize.indexOf('_storeKit.queryProducts('),
      greaterThanOrEqualTo(0),
    );
    expect(
      initialize.indexOf('setState(() {\n          _prices = prices;'),
      greaterThan(0),
    );
    expect(
      initialize.indexOf('_storeKit.queryProducts('),
      lessThan(initialize.indexOf('await _recover();')),
    );
  });

  test(
    'verification retry reconciles saved context without launching purchase',
    () {
      final source = File(
        'lib/screens/storekit_checkout_screen.dart',
      ).readAsStringSync();
      final retryStart = source.indexOf('Future<void> _retryVerification()');
      final retryEnd = source.indexOf(
        'List<IosCartProduct> get _displayCartProducts',
      );
      final retry = source.substring(retryStart, retryEnd);

      expect(retry, contains('await _recover();'));
      expect(retry, isNot(contains('buyConsumable(')));
      expect(retry, isNot(contains('prepareIosPurchase(')));
      expect(source, contains("Text('Retry Verification')"));
    },
  );

  test('native diagnostic events are dispatched on the main queue', () {
    final source = File(
      'third_party/in_app_purchase_storekit/darwin/in_app_purchase_storekit/Sources/in_app_purchase_storekit/InAppPurchasePlugin.swift',
    ).readAsStringSync();
    final bridgeStart = source.indexOf('final class StoreKitDiagnosticsBridge');
    final bridge = source.substring(bridgeStart);
    expect(bridge, contains('DispatchQueue.main.async'));
    expect(bridge, contains('invokeMethod("transactionSource"'));
  });

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
