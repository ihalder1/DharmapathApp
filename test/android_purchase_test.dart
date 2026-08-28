import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:colab_app_ui/models/android_purchase.dart';
import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/models/mantra.dart';
import 'package:colab_app_ui/services/cart_quantity_policy.dart';
import 'package:colab_app_ui/services/android_purchase_context_store.dart';
import 'package:colab_app_ui/services/location_pricing_service.dart';
import 'package:colab_app_ui/services/mantra_service.dart';
import 'package:colab_app_ui/services/play_billing_service.dart';
import 'package:colab_app_ui/services/play_billing_diagnostics.dart';
import 'package:colab_app_ui/services/secure_session_storage.dart';

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const billingChannel = MethodChannel('com.idsai.mantrasutra/play_billing');
  Mantra mantra(String id, String storeId, String name) => Mantra(
    name: name,
    mantraFile: '$id.mp3',
    icon: '',
    storeProductIdAndroid: storeId,
    price: 999,
  );

  AndroidPurchaseContext purchaseContext(
    List<String> productIds, {
    String state = 'prepared',
    Set<String> verifiedStoreProductIds = const {},
  }) => AndroidPurchaseContext(
    orderId: 'ORDER-1',
    linkToken: 'LINK-1',
    products: productIds
        .map((id) => PreparedStoreProduct(storeProductId: id, quantity: 1))
        .toList(),
    verifiedStoreProductIds: verifiedStoreProductIds,
    currentIndex: 0,
    state: state,
    createdAt: DateTime.utc(2026),
  );

  List<AndroidCartProduct> cartProducts(List<String> ids) => ids
      .map(
        (id) => AndroidCartProduct(
          internalProductId: id.toUpperCase(),
          productName: 'Mantra',
          storeProductId: id,
          quantity: 1,
        ),
      )
      .toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MantraService.debugTargetPlatformOverride = TargetPlatform.android;
    await MantraService.clearCart();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(billingChannel, null);
    await MantraService.clearCart();
    MantraService.debugTargetPlatformOverride = null;
  });

  test('Android adding the same mantra twice preserves quantity one', () async {
    final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');

    expect(await MantraService.addToCart(aarati), isTrue);
    expect(await MantraService.addToCart(aarati), isFalse);
    expect(MantraService.getCart(), hasLength(1));
    expect(MantraService.getCart().single.cartQuantity, 1);
  });

  test(
    'Android removal immediately updates checkout items and permits re-add',
    () async {
      final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');
      final brahma = mantra('F-BRAHMA-001', 'song_f_brahma_001', 'Brahma');
      await MantraService.addToCart(aarati);
      await MantraService.addToCart(brahma);

      await MantraService.removeFromCart(aarati);
      await MantraService.removeFromCart(aarati);

      expect(
        MantraService.expandCartForCheckout().map(
          (item) => item.storeProductIdAndroid,
        ),
        ['song_f_brahma_001'],
      );
      expect(await MantraService.addToCart(aarati), isTrue);
      expect(
        MantraService.expandCartForCheckout().map(
          (item) => item.storeProductIdAndroid,
        ),
        ['song_f_brahma_001', 'song_f_aarati_001'],
      );
    },
  );

  test('Android legacy persisted quantity is normalized to one', () {
    expect(
      normalizedCartQuantity(2, platform: TargetPlatform.android, isWeb: false),
      1,
    );
  });

  test(
    'Android Purchase All behavior adds each distinct mantra once',
    () async {
      final visible = [
        mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati'),
        mantra('F-BRAHMA-001', 'song_f_brahma_001', 'Brahma'),
      ];
      for (final item in [...visible, ...visible]) {
        await MantraService.addToCart(item);
      }

      expect(MantraService.getCart(), hasLength(2));
      expect(MantraService.getCartTotalQuantity(), 2);
      expect(MantraService.expandCartForCheckout(), hasLength(2));
    },
  );

  test('Android prepare rows always include explicit quantity one', () async {
    final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');
    await MantraService.addToCart(aarati);

    final products = aggregateAndroidCart(
      MantraService.expandCartForCheckout(),
    );
    expect(products.single.toPrepareJson()['quantity'], 1);
  });

  test('iOS limit does not change the existing Android cart ceiling', () {
    expect(
      maxCartTotalQuantity(
        existingDefault: MantraService.maxCartTotalQuantity,
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      30,
    );
    expect(
      maxCartTotalQuantity(
        existingDefault: MantraService.maxCartTotalQuantity,
        platform: TargetPlatform.iOS,
        isWeb: false,
      ),
      21,
    );
  });

  test('iOS accepts unit 21 and rejects unit 22 before checkout', () async {
    MantraService.debugTargetPlatformOverride = TargetPlatform.iOS;
    final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');

    for (var unit = 1; unit <= 21; unit++) {
      expect(await MantraService.addToCart(aarati), isTrue);
    }
    expect(MantraService.getCartTotalQuantity(), 21);
    expect(await MantraService.addToCart(aarati), isFalse);
    expect(MantraService.getCartTotalQuantity(), 21);
  });

  test('iOS aggregate snapshot keeps quantity 4 as one row, not 16', () async {
    MantraService.debugTargetPlatformOverride = TargetPlatform.iOS;
    final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');
    for (var unit = 0; unit < 4; unit++) {
      expect(await MantraService.addToCart(aarati), isTrue);
    }

    final snapshot = MantraService.iosAggregateCartSnapshot();
    expect(snapshot, hasLength(1));
    expect(snapshot.single.cartQuantity, 4);
    expect(MantraService.getCartTotalQuantity(), 4);

    // This is deliberately *not* the iOS input: it demonstrates the old
    // double-expansion shape that produced four rows each carrying quantity 4.
    final legacyExpanded = MantraService.expandCartForCheckout();
    expect(legacyExpanded, hasLength(4));
    expect(legacyExpanded.every((item) => item.cartQuantity == 4), isTrue);
  });

  test('paid iOS quantity 4 finalizes exactly four cart units', () async {
    MantraService.debugTargetPlatformOverride = TargetPlatform.iOS;
    final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');
    for (var unit = 0; unit < 6; unit++) {
      expect(await MantraService.addToCart(aarati), isTrue);
    }
    await MantraService.consumeIosCartProducts(const [
      IosCartProduct(
        internalProductId: 'F-AARATI-001',
        productName: 'Aarati',
        storeProductId: 'ios_metadata_only',
        quantity: 4,
      ),
    ]);
    expect(MantraService.getCart().single.cartQuantity, 2);
  });

  test(
    'non-Android cart retains existing multiple quantity behavior',
    () async {
      MantraService.debugTargetPlatformOverride = TargetPlatform.iOS;
      final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');

      expect(await MantraService.addToCart(aarati), isTrue);
      expect(await MantraService.addToCart(aarati), isTrue);
      expect(MantraService.getCart().single.cartQuantity, 2);
      expect(MantraService.expandCartForCheckout(), hasLength(2));
    },
  );

  test('regional tax price labels follow country pricing tiers', () {
    expect(
      LocationPricingService.taxPriceLabel(PricingRegion.india),
      '95 INR + GST',
    );
    expect(
      LocationPricingService.taxPriceLabel(PricingRegion.southAsia),
      '1 USD + VAT/GST',
    );
    expect(
      LocationPricingService.taxPriceLabel(PricingRegion.other),
      '2 USD + VAT/GST',
    );
  });

  test('stale Aarati context does not match visible Brahma and Devi', () {
    final stale = purchaseContext(['song_f_aarati_001']);
    final visible = cartProducts(['song_f_brahma_001', 'song_f_devi_001']);

    expect(stale.matchesCart(visible), isFalse);
  });

  test('matching persisted context is accepted regardless of ordering', () {
    final stored = purchaseContext(['song_f_devi_001', 'song_f_brahma_001']);
    final visible = cartProducts(['song_f_brahma_001', 'song_f_devi_001']);

    expect(stored.matchesCart(visible), isTrue);
  });

  PlayPurchase playPurchase(
    List<String> ids, {
    int state = 1,
    String purchaseToken = 'TOKEN',
  }) => PlayPurchase(
    purchaseToken: purchaseToken,
    products: ids,
    purchaseState: state,
    quantity: 1,
    isAcknowledged: false,
  );

  test('launch validation rejects context outside visible cart', () {
    final active = purchaseContext(['song_f_aarati_001']);
    final visible = cartProducts(['song_f_brahma_001', 'song_f_devi_001']);

    expect(
      () => validatePlayLaunch(context: active, visibleCart: visible),
      throwsStateError,
    );
  });

  test('launch validation accepts complete visible order', () {
    final active = purchaseContext(['song_f_brahma_001', 'song_f_devi_001']);
    final visible = cartProducts(['song_f_brahma_001', 'song_f_devi_001']);

    expect(
      () => validatePlayLaunch(context: active, visibleCart: visible),
      returnsNormally,
    );
  });

  test('terminal order cannot launch Google Play', () {
    final active = purchaseContext(['song_f_brahma_001'], state: 'failed');
    final visible = cartProducts(['song_f_brahma_001']);

    expect(
      () => validatePlayLaunch(context: active, visibleCart: visible),
      throwsStateError,
    );
  });

  test('two products are sent in one multi-product platform call', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(billingChannel, (call) async {
          calls.add(call);
          return <String, Object?>{'responseCode': 0};
        });

    await PlayBillingService.launchMultiProductPurchase(
      productIds: const ['devi', 'brahma'],
      obfuscatedAccountId: 'LINK',
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'launchMultiProductPurchase');
    expect((calls.single.arguments as Map)['productIds'], ['devi', 'brahma']);
  });

  test('ten products are sent in one multi-product platform call', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(billingChannel, (call) async {
          calls.add(call);
          return <String, Object?>{'responseCode': 0};
        });
    final ids = List.generate(10, (index) => 'mantra_$index');

    await PlayBillingService.launchMultiProductPurchase(
      productIds: ids,
      obfuscatedAccountId: 'LINK',
    );

    expect(calls, hasLength(1));
    expect((calls.single.arguments as Map)['productIds'], ids);
  });

  test(
    'multi-product launch rejects duplicate product IDs before platform',
    () {
      expect(
        () => PlayBillingService.launchMultiProductPurchase(
          productIds: const ['devi', 'devi'],
          obfuscatedAccountId: 'LINK',
        ),
        throwsArgumentError,
      );
    },
  );

  test('launch validation rejects quantity other than one', () {
    final invalid = AndroidPurchaseContext(
      orderId: 'ORDER-1',
      linkToken: 'LINK-1',
      products: const [
        PreparedStoreProduct(storeProductId: 'devi', quantity: 2),
      ],
      verifiedStoreProductIds: const {},
      currentIndex: 0,
      state: 'prepared',
      createdAt: DateTime.utc(2026),
    );
    expect(
      () => validatePlayLaunch(
        context: invalid,
        visibleCart: cartProducts(['devi']),
      ),
      throwsStateError,
    );
  });

  test('purchase product set accepts ordering differences', () {
    final active = purchaseContext(['devi', 'brahma']);
    expect(
      purchaseProductsMatch(active, playPurchase(['brahma', 'devi'])),
      isTrue,
    );
  });

  test('purchase product set rejects a missing product', () {
    final active = purchaseContext(['devi', 'brahma']);
    expect(purchaseProductsMatch(active, playPurchase(['devi'])), isFalse);
  });

  test('purchase product set rejects an unexpected product', () {
    final active = purchaseContext(['devi', 'brahma']);
    expect(
      purchaseProductsMatch(active, playPurchase(['devi', 'hanuman'])),
      isFalse,
    );
  });

  test('purchase product set rejects duplicates', () {
    final active = purchaseContext(['devi', 'brahma']);
    expect(
      purchaseProductsMatch(active, playPurchase(['devi', 'devi'])),
      isFalse,
    );
  });

  test('one-product legacy purchase remains an exact transaction match', () {
    final active = purchaseContext(['devi']);
    expect(purchaseProductsMatch(active, playPurchase(['devi'])), isTrue);
  });

  test('prepared order cancelled without Play purchase allows retry', () {
    final decision = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'opening_play'),
      outstandingPurchases: const [],
    );

    expect(decision.shouldAbandon, isTrue);
  });

  test('backend pending without Play purchase does not block indefinitely', () {
    final decision = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'prepared'),
      outstandingPurchases: const [],
    );

    expect(decision.action, AndroidRecoveryAction.abandonUnownedPreparedOrder);
  });

  test('genuine Play PENDING purchase remains recoverable', () {
    final purchase = playPurchase(['devi'], state: 2);
    final decision = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'pending'),
      outstandingPurchases: [purchase],
    );

    expect(decision.action, AndroidRecoveryAction.reconcilePendingPurchase);
    expect(decision.matchingPurchase, same(purchase));
  });

  test('Play PURCHASED with pending verification remains recoverable', () {
    final purchase = playPurchase(['devi']);
    final decision = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'opening_play'),
      outstandingPurchases: [purchase],
    );

    expect(decision.action, AndroidRecoveryAction.reconcilePurchasedPurchase);
    expect(decision.matchingPurchase, same(purchase));
  });

  test('verified pending-consumption context is never abandoned', () {
    final decision = decideAndroidRecovery(
      context: purchaseContext(
        ['devi'],
        state: 'verified_pending_consumption',
        verifiedStoreProductIds: const {'devi'},
      ),
      outstandingPurchases: const [],
    );

    expect(decision.action, AndroidRecoveryAction.retainVerifiedContext);
  });

  test('reinstall-equivalent cleared local context stays cleared', () async {
    final secureStore = _MemorySecureStore();
    final store = AndroidPurchaseContextStore(secureStore: secureStore);
    await store.save(purchaseContext(['devi'], state: 'opening_play'));

    await store.clear();

    expect(await store.load(), isNull);
  });

  test('multiple cancel and retry decisions remain immediately eligible', () {
    for (var attempt = 0; attempt < 5; attempt++) {
      final decision = decideAndroidRecovery(
        context: purchaseContext(['devi'], state: 'opening_play'),
        outstandingPurchases: const [],
      );
      expect(decision.shouldAbandon, isTrue, reason: 'attempt $attempt');
    }
  });

  test('successful purchase after cancellation remains reconciled', () {
    final cancelled = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'opening_play'),
      outstandingPurchases: const [],
    );
    final purchased = playPurchase(['devi']);
    final retry = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'opening_play'),
      outstandingPurchases: [purchased],
    );

    expect(cancelled.shouldAbandon, isTrue);
    expect(retry.action, AndroidRecoveryAction.reconcilePurchasedPurchase);
  });

  test('successful consumed repurchase remains eligible', () {
    final decision = decideAndroidRecovery(
      context: purchaseContext(['devi'], state: 'prepared'),
      outstandingPurchases: const [],
    );

    expect(decision.shouldAbandon, isTrue);
  });

  test('selective completion does not clear unrelated current cart', () async {
    final brahma = mantra('F-BRAHMA-001', 'song_f_brahma_001', 'Brahma');
    final devi = mantra('F-DEVI-001', 'song_f_devi_001', 'Devi');
    await MantraService.addToCart(brahma);
    await MantraService.addToCart(devi);

    await MantraService.removeCartProductsByStoreIds(['song_f_aarati_001']);

    expect(MantraService.getCart().map((item) => item.name), [
      'Brahma',
      'Devi',
    ]);
  });

  test('consume ITEM_NOT_OWNED is idempotently complete', () {
    expect(const PlayConsumeResult(responseCode: 0).completed, isTrue);
    expect(const PlayConsumeResult(responseCode: 8).completed, isTrue);
    expect(const PlayConsumeResult(responseCode: 8).alreadyConsumed, isTrue);
    expect(const PlayConsumeResult(responseCode: -1).completed, isFalse);
  });

  test('aggregates Android cart into distinct quantity-one products', () {
    final aarati = mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati');
    final brahma = mantra('F-BRAHMA-001', 'song_f_brahma_001', 'Brahma');

    final result = aggregateAndroidCart([aarati, aarati, brahma]);

    expect(result, hasLength(2));
    expect(result[0].internalProductId, 'F-AARATI-001');
    expect(result[0].quantity, 1);
    expect(result[1].quantity, 1);
  });

  test('calculates Android Play total from distinct products only', () {
    final products = aggregateAndroidCart([
      mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati'),
      mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati'),
      mantra('F-BRAHMA-001', 'song_f_brahma_001', 'Brahma'),
    ]);
    final prices = {
      for (final id in ['song_f_aarati_001', 'song_f_brahma_001'])
        id: PlayProductPrice(
          productId: id,
          formattedPrice: '₹110.00',
          priceAmountMicros: 110000000,
          currencyCode: 'INR',
        ),
    };

    expect(googlePlayCartTotalMicros(products, prices), 220000000);
  });

  test('rejects mixed Play currencies', () {
    final products = aggregateAndroidCart([
      mantra('F-AARATI-001', 'song_f_aarati_001', 'Aarati'),
      mantra('F-BRAHMA-001', 'song_f_brahma_001', 'Brahma'),
    ]);
    final prices = {
      'song_f_aarati_001': const PlayProductPrice(
        productId: 'song_f_aarati_001',
        formattedPrice: '₹110.00',
        priceAmountMicros: 110000000,
        currencyCode: 'INR',
      ),
      'song_f_brahma_001': const PlayProductPrice(
        productId: 'song_f_brahma_001',
        formattedPrice: r'$1.00',
        priceAmountMicros: 1000000,
        currencyCode: 'USD',
      ),
    };

    expect(googlePlayCartTotalMicros(products, prices), isNull);
  });

  test('partially_paid is accepted but not final', () {
    final result = PurchaseVerification.fromJson({
      'data': {'status': 'partially_paid'},
    });

    expect(result.accepted, isTrue);
    expect(result.paid, isFalse);
  });

  test('paid verification is accepted and final', () {
    final result = PurchaseVerification.fromJson({
      'data': {
        'order': {'status': 'PAID'},
      },
    });

    expect(result.accepted, isTrue);
    expect(result.paid, isTrue);
  });

  test('failed verification is terminal and cannot permit consumption', () {
    final result = PurchaseVerification.fromJson({'status': 'failed'});

    expect(result.accepted, isFalse);
    expect(result.terminal, isTrue);
  });

  test('pending verification cannot permit consumption or entitlement', () {
    final result = PurchaseVerification.fromJson({
      'data': {'payment_status': 'pending'},
    });

    expect(result.accepted, isFalse);
    expect(result.paid, isFalse);
    expect(result.terminal, isFalse);
  });

  test('transient consume failure remains incomplete for retry', () {
    const disconnected = PlayConsumeResult(responseCode: -1);

    expect(disconnected.completed, isFalse);
    expect(disconnected.alreadyConsumed, isFalse);
  });

  test('billing error sanitizer redacts purchase secrets', () {
    final sanitized = sanitizePlayBillingDiagnostic(
      'purchaseToken=secret-1 linkToken:secret-2 '
      'email=user@example.com ordinary=kept',
    );

    expect(sanitized, isNot(contains('secret-1')));
    expect(sanitized, isNot(contains('secret-2')));
    expect(sanitized, isNot(contains('user@example.com')));
    expect(sanitized, contains('ordinary=kept'));
  });

  test('billing diagnostic sanitizer redacts JWT and access token', () {
    final sanitized = sanitizePlayBillingDiagnostic(
      'access_token=abc123 jwt=eyJheader.eyJpayload.signature',
    );

    expect(sanitized, isNot(contains('abc123')));
    expect(sanitized, isNot(contains('eyJheader')));
  });

  test('safe backend error extraction exposes only approved scalar fields', () {
    final safe = safeAndroidBillingErrorFromBody('''
      {
        "code": "unfinished_order",
        "message": "Previous purchase is active for user@example.com",
        "status": "conflict",
        "purchaseToken": "must-not-appear",
        "nested": {"secret": "must-not-appear"}
      }
    ''');

    expect(safe.code, 'unfinished_order');
    expect(safe.status, 'conflict');
    expect(safe.message, contains('[REDACTED_EMAIL]'));
    expect(safe.message, isNot(contains('user@example.com')));
    expect(safe.message, isNot(contains('must-not-appear')));
  });

  test('Android billing HTTP exception contains safe diagnostic mapping', () {
    const prepare = AndroidBillingHttpException(
      operation: 'prepare',
      httpStatus: 409,
      safeCode: 'unfinished_order',
      safeMessage: 'Previous purchase is active',
    );
    const verify = AndroidBillingHttpException(
      operation: 'verify',
      httpStatus: 422,
      safeCode: 'verification_rejected',
    );

    expect(prepare.operation, 'prepare');
    expect(prepare.httpStatus, 409);
    expect(verify.operation, 'verify');
    expect(verify.httpStatus, 422);
  });

  test('consume display model distinguishes success, owned and failure', () {
    const ok = PlayConsumeResult(responseCode: 0);
    const alreadyConsumed = PlayConsumeResult(responseCode: 8);
    const failed = PlayConsumeResult(responseCode: 2);

    expect(ok.completed, isTrue);
    expect(alreadyConsumed.alreadyConsumed, isTrue);
    expect(failed.completed, isFalse);
  });
}
