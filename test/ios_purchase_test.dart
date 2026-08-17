import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/models/mantra.dart';
import 'package:colab_app_ui/services/storekit_purchase_service.dart';
import 'package:colab_app_ui/services/storekit_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

void main() {
  Mantra mantra(String id, String storeId, {int quantity = 1}) => Mantra(
    songId: id,
    name: '$id Mantra',
    mantraFile: '$id.mp3',
    icon: '',
    storeProductIdAndroid: 'android_$storeId',
    storeProductIdIos: storeId,
    price: 999,
    cartQuantity: quantity,
  );

  IosPurchaseContext context({
    List<IosPurchaseUnit>? units,
    String state = 'prepared',
    int currentIndex = 0,
  }) => IosPurchaseContext(
    orderId: 'ORDER-1',
    linkToken: '123e4567-e89b-12d3-a456-426614174000',
    units:
        units ??
        const [
          IosPurchaseUnit(storeProductId: 'ios_a'),
          IosPurchaseUnit(storeProductId: 'ios_b'),
        ],
    currentIndex: currentIndex,
    state: state,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  test('store_product_id_ios parses without changing Android mapping', () {
    final parsed = Mantra.fromJson({
      'song_id': 'F-AARATI-001',
      'name': 'Aarati',
      'mantra_file': 'F-AARATI-001.mp3',
      'icon': '',
      'store_product_id_android': 'song_f_aarati_001',
      'store_product_id_ios': 'song_f_aarati_001_ios',
      'price': 99,
    });
    expect(parsed.storeProductIdIos, 'song_f_aarati_001_ios');
    expect(parsed.storeProductIdAndroid, 'song_f_aarati_001');
    expect(parsed.toJson()['store_product_id_ios'], 'song_f_aarati_001_ios');
  });

  test('iOS catalogue price never falls back to legacy local price', () {
    expect(
      iosCataloguePrice(storeProductId: 'ios_a', prices: const {}),
      'Price unavailable',
    );
    final details = ProductDetails(
      id: 'ios_a',
      title: 'A',
      description: '',
      price: '₹123.00',
      rawPrice: 123,
      currencyCode: 'INR',
    );
    expect(
      iosCataloguePrice(
        storeProductId: 'ios_a',
        prices: {
          'ios_a': StoreKitProductPrice(
            productId: 'ios_a',
            formattedPrice: details.price,
            rawPrice: details.rawPrice,
            currencyCode: details.currencyCode,
            details: details,
          ),
        },
      ),
      '₹123.00',
    );
  });

  test('Prepare Purchase iOS payload uses internal IDs and no local price', () {
    final products = buildIosCartProducts([mantra('F-AARATI-001', 'ios_a')]);
    expect(buildIosPreparePayload(currency: 'INR', products: products), {
      'platform': 'ios',
      'currency': 'inr',
      'products': [
        {
          'productId': 'F-AARATI-001',
          'productName': 'F-AARATI-001 Mantra',
          'quantity': 1,
        },
      ],
    });
  });

  test('Verify Purchase iOS payload contains real transaction fields', () {
    expect(
      buildIosVerifyPayload(
        orderId: 'ORDER-1',
        transactionId: '2000000123456789',
        storeProductId: 'ios_a',
      ),
      {
        'orderId': 'ORDER-1',
        'platform': 'ios',
        'transactionId': '2000000123456789',
        'storeProductId': 'ios_a',
      },
    );
  });

  test('linkToken requires canonical UUID shape', () {
    expect(isCanonicalUuid('123e4567-e89b-12d3-a456-426614174000'), isTrue);
    expect(isCanonicalUuid('not-a-uuid'), isFalse);
    expect(isCanonicalUuid('123e4567e89b12d3a456426614174000'), isFalse);
  });

  test('app account token comparison normalizes UUID case', () {
    const lower = '123e4567-e89b-12d3-a456-426614174000';
    const upper = '123E4567-E89B-12D3-A456-426614174000';
    expect(appAccountTokensMatch(lower, upper), isTrue);
    expect(appAccountTokensMatch(lower, null), isFalse);
    expect(appAccountTokensMatch(lower, 'not-a-uuid'), isFalse);
  });

  test('partially_paid persists accepted unit and advances', () {
    final purchased = context().recordTransaction(
      index: 0,
      transactionId: 'tx-a',
    );
    final partial = purchased.acceptTransaction(
      index: 0,
      backendStatus: 'partially_paid',
    );
    expect(partial.state, 'partially_paid');
    expect(partial.currentIndex, 1);
    expect(partial.units.first.backendAccepted, isTrue);
    expect(partial.units.last.backendAccepted, isFalse);
  });

  test('final paid progression retains per-unit completion', () {
    var current = context();
    current = current
        .recordTransaction(index: 0, transactionId: 'tx-a')
        .acceptTransaction(index: 0, backendStatus: 'partially_paid')
        .completeTransaction(0)
        .recordTransaction(index: 1, transactionId: 'tx-b')
        .acceptTransaction(index: 1, backendStatus: 'paid')
        .completeTransaction(1);
    expect(current.paid, isTrue);
    expect(current.units.every((item) => item.storeKitCompleted), isTrue);
  });

  test(
    'cancellation after partial completion leaves remaining unit pending',
    () {
      final partial = context()
          .recordTransaction(index: 0, transactionId: 'tx-a')
          .acceptTransaction(index: 0, backendStatus: 'partially_paid')
          .completeTransaction(0);
      expect(partial.acceptedStoreProductIds, {'ios_a'});
      expect(partial.units[1].transactionId, isNull);
      expect(partial.hasUnfinishedWork, isTrue);
    },
  );

  test('duplicate transaction callback is rejected', () {
    final deduplicator = IosTransactionDeduplicator();
    expect(deduplicator.begin('tx-a'), isTrue);
    expect(deduplicator.begin('tx-a'), isFalse);
  });

  test('restart context retains an unverified real transaction', () {
    final saved = context().recordTransaction(index: 0, transactionId: 'tx-a');
    final restored = IosPurchaseContext.fromJson(
      saved.toJson(includeLinkToken: false),
      linkToken: saved.linkToken,
    );
    expect(restored.units.first.transactionId, 'tx-a');
    expect(restored.units.first.backendAccepted, isFalse);
  });

  test('restart with backend already paid remains finalizable', () {
    final paid = context(
      units: const [
        IosPurchaseUnit(
          storeProductId: 'ios_a',
          transactionId: 'tx-a',
          backendAccepted: true,
        ),
      ],
      state: 'paid',
      currentIndex: 1,
    );
    expect(paid.paid, isTrue);
    expect(paid.hasUnfinishedWork, isTrue);
  });

  test('unresolved order blocks a conflicting cart', () {
    expect(
      iosOrderConflictsWithCart(
        context(),
        buildIosCartProducts([mantra('C', 'ios_c')]),
      ),
      isTrue,
    );
    expect(
      iosOrderConflictsWithCart(
        context(),
        buildIosCartProducts([mantra('A', 'ios_a'), mantra('B', 'ios_b')]),
      ),
      isFalse,
    );
  });

  test('same-product quantity is aggregated for one prepare order', () {
    final products = buildIosCartProducts([
      mantra('F-KRISHNA-001', 'ios_krishna', quantity: 2),
    ]);
    expect(products.single.quantity, 2);
    expect(buildIosPreparePayload(currency: 'INR', products: products), {
      'platform': 'ios',
      'currency': 'inr',
      'products': [
        {
          'productId': 'F-KRISHNA-001',
          'productName': 'F-KRISHNA-001 Mantra',
          'quantity': 2,
        },
      ],
    });
  });

  test('backend quantity expands into distinct persisted StoreKit units', () {
    final cart = buildIosCartProducts([
      mantra('F-KRISHNA-001', 'ios_krishna', quantity: 2),
    ]);
    final units = expandIosPreparedUnits(
      prepared: const [
        IosPreparedStoreProduct(
          storeProductId: 'ios_krishna',
          internalProductId: 'F-KRISHNA-001',
          quantity: 2,
        ),
      ],
      cart: cart,
    );
    expect(units, hasLength(2));
    expect(units.map((item) => item.storeProductId), [
      'ios_krishna',
      'ios_krishna',
    ]);
    expect(units.every((item) => item.transactionId == null), isTrue);
  });

  test('cart conflict comparison retains repeated-unit counts', () {
    final repeated = context(
      units: const [
        IosPurchaseUnit(storeProductId: 'ios_a'),
        IosPurchaseUnit(storeProductId: 'ios_a'),
      ],
    );
    expect(
      iosOrderConflictsWithCart(
        repeated,
        buildIosCartProducts([mantra('A', 'ios_a')]),
      ),
      isTrue,
    );
    expect(
      iosOrderConflictsWithCart(
        repeated,
        buildIosCartProducts([mantra('A', 'ios_a', quantity: 2)]),
      ),
      isFalse,
    );
  });

  test('StoreKit diagnostics redact sensitive identifiers and values', () {
    final diagnostics = StoreKitDiagnostics();
    diagnostics.logPrepareResponse(
      httpStatus: 201,
      orderIdPresent: true,
      orderId: 'ORDER-12345678',
      linkTokenPresent: true,
      linkTokenValid: true,
      storeProducts: [
        {
          'storeProductId': 'ios_a',
          'quantity': 1,
          'internalProductId': 'F-AARATI-001',
          'unexpectedToken': 'must-not-appear',
        },
      ],
    );
    diagnostics.logVerify(
      event: 'BACKEND_VERIFY_STARTED',
      orderId: 'ORDER-12345678',
      storeProductId: 'ios_a',
      transactionId: '2000000123456789',
    );
    diagnostics.logAppAccountTokenCorrelation(
      event: 'APP_ACCOUNT_TOKEN_RETURNED',
      persistedToken: '123e4567-e89b-12d3-a456-426614174000',
      returnedToken: '123E4567-E89B-12D3-A456-426614174000',
    );

    expect(diagnostics.text, contains('storeProductId: ios_a'));
    expect(diagnostics.text, contains('internalProductId: F-AARATI-001'));
    expect(diagnostics.text, contains('****5678'));
    expect(diagnostics.text, contains('****6789'));
    expect(diagnostics.text, isNot(contains('ORDER-12345678')));
    expect(diagnostics.text, isNot(contains('2000000123456789')));
    expect(diagnostics.text, isNot(contains('must-not-appear')));
    expect(diagnostics.text, contains('expectedTokenSuffix=4000'));
    expect(diagnostics.text, contains('returnedTokenSuffix=4000'));
    expect(diagnostics.text, contains('match=YES'));
    expect(diagnostics.text, isNot(contains('123e4567-e89b')));
  });

  test('Verify HTTP diagnostics retain safe backend error fields', () {
    final diagnostics = StoreKitDiagnostics();
    diagnostics.logVerifyHttpResponse(
      httpStatus: 500,
      responseBody: '''
        {
          "error": {
            "code": "APPLE_VERIFY_FAILED",
            "message": "Transaction 2000000123456789 failed for 123e4567-e89b-12d3-a456-426614174000"
          },
          "receipt": "secret-jws",
          "orderId": "ORDER-12345678",
          "status": "error"
        }
      ''',
    );

    expect(diagnostics.text, contains('httpStatus=500'));
    expect(diagnostics.text, contains('APPLE_VERIFY_FAILED'));
    expect(diagnostics.text, contains('status: error'));
    expect(diagnostics.text, contains('[REDACTED_LONG_ID]'));
    expect(diagnostics.text, contains('[REDACTED_UUID]'));
    expect(diagnostics.text, isNot(contains('2000000123456789')));
    expect(diagnostics.text, isNot(contains('123e4567-e89b')));
    expect(diagnostics.text, isNot(contains('secret-jws')));
    expect(diagnostics.text, isNot(contains('ORDER-12345678')));
  });
}
