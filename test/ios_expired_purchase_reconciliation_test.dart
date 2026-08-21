import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/screens/storekit_checkout_screen.dart';
import 'package:colab_app_ui/services/ios_purchase_context_store.dart';
import 'package:colab_app_ui/services/ios_purchase_reconciler.dart';
import 'package:colab_app_ui/services/storekit_purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

final class _MemoryContextStore implements IosPurchaseContextStorage {
  _MemoryContextStore(this.context);

  IosPurchaseContext? context;
  int clears = 0;

  @override
  Future<IosPurchaseContext?> load() async => context;

  @override
  Future<void> save(IosPurchaseContext value) async => context = value;

  @override
  Future<void> clear() async {
    clears++;
    context = null;
  }
}

IosPurchaseContext _context({
  String? transactionId,
  bool backendAccepted = false,
}) {
  final now = DateTime.utc(2026, 8, 18);
  return IosPurchaseContext(
    orderId: 'ORDER-EXPIRED',
    linkToken: '123e4567-e89b-12d3-a456-426614174000',
    units: [
      IosPurchaseUnit(
        storeProductId: 'song_f_shiva_001_ios',
        transactionId: transactionId,
        backendAccepted: backendAccepted,
      ),
      const IosPurchaseUnit(storeProductId: 'song_f_jagannath_001_ios'),
    ],
    currentIndex: 0,
    state: 'opening_storekit',
    createdAt: now,
    updatedAt: now,
  );
}

StoreKitTransaction _unfinished({
  required String productId,
  required String transactionId,
  String appAccountToken = '123e4567-e89b-12d3-a456-426614174000',
}) => StoreKitTransaction(
  productId: productId,
  status: PurchaseStatus.purchased,
  transactionId: transactionId,
  appAccountToken: appAccountToken,
);

IosPurchaseReconciler _reconciler({
  required _MemoryContextStore store,
  required List<StoreKitTransaction> unfinished,
}) => IosPurchaseReconciler(
  contextStore: store,
  orderLookup: (_, _) async => const IosPurchaseVerification(status: 'expired'),
  verifyPurchase: (_, __, ___, ____) async =>
      const IosPurchaseVerification(status: 'expired'),
  unfinishedTransactions: () async => unfinished,
  completeTransaction: (_) async {},
);

void main() {
  test(
    'expired Shiva/Jagannath context ignores unrelated Brahma/Aarati',
    () async {
      final store = _MemoryContextStore(_context());
      final result = await _reconciler(
        store: store,
        unfinished: [
          _unfinished(
            productId: 'song_f_brahma_001_ios',
            transactionId: '7307',
          ),
          _unfinished(
            productId: 'song_f_aarati_001_ios',
            transactionId: '4825',
          ),
        ],
      ).reconcile();

      expect(result.resolved, isTrue);
      expect(store.context, isNull);
      expect(store.clears, 1);
    },
  );

  test('cleared expired context permits a subsequent fresh checkout', () async {
    final store = _MemoryContextStore(_context());
    await _reconciler(store: store, unfinished: const []).reconcile();

    expect(await store.load(), isNull);
    final now = DateTime.utc(2026, 8, 18);
    final fresh = IosPurchaseContext(
      orderId: 'ORDER-FRESH',
      linkToken: '123e4567-e89b-12d3-a456-426614174001',
      units: const [IosPurchaseUnit(storeProductId: 'fresh_ios')],
      currentIndex: 0,
      state: 'prepared',
      createdAt: now,
      updatedAt: now,
    );
    await store.save(fresh);
    expect((await store.load())?.orderId, 'ORDER-FRESH');
  });

  test('expired context with a transaction ID remains fail closed', () async {
    final store = _MemoryContextStore(_context(transactionId: 'REAL-123'));
    final result = await _reconciler(
      store: store,
      unfinished: const [],
    ).reconcile();

    expect(store.clears, 0);
    expect(store.context, isNotNull);
    expect(result.resolved, isFalse);
  });

  test('expired context with backend acceptance remains fail closed', () async {
    final store = _MemoryContextStore(_context(backendAccepted: true));
    final result = await _reconciler(
      store: store,
      unfinished: const [],
    ).reconcile();

    expect(store.clears, 0);
    expect(store.context, isNotNull);
    expect(result.resolved, isFalse);
  });

  test(
    'expired context with a matching unfinished transaction is retained',
    () async {
      final store = _MemoryContextStore(_context());
      final result = await _reconciler(
        store: store,
        unfinished: [
          _unfinished(
            productId: 'song_f_shiva_001_ios',
            transactionId: 'REAL-456',
          ),
        ],
      ).reconcile();

      expect(store.clears, 0);
      // Old multi-unit contexts remain fail closed and are not rewritten into
      // the aggregate model, even when transaction evidence exists.
      expect(store.context?.units.first.transactionId, isNull);
      expect(result.resolved, isFalse);
    },
  );

  test('unrelated unfinished transactions are never assigned', () async {
    final store = _MemoryContextStore(_context(transactionId: 'KNOWN-1'));
    await _reconciler(
      store: store,
      unfinished: [
        _unfinished(productId: 'song_f_brahma_001_ios', transactionId: '7307'),
        _unfinished(productId: 'song_f_aarati_001_ios', transactionId: '4825'),
      ],
    ).reconcile();

    expect(store.context?.units[1].transactionId, isNull);
  });

  test('same product with another app account token is not evidence', () async {
    final store = _MemoryContextStore(_context());
    final result = await _reconciler(
      store: store,
      unfinished: [
        _unfinished(
          productId: 'song_f_shiva_001_ios',
          transactionId: 'OTHER-ACCOUNT',
          appAccountToken: '123e4567-e89b-12d3-a456-426614174099',
        ),
      ],
    ).reconcile();

    expect(result.resolved, isTrue);
    expect(store.context, isNull);
  });

  test(
    'mismatched persisted context remains renderable without firstWhere',
    () {
      final displayed = buildIosRecoveryDisplayProducts(
        cartProducts: const [
          IosCartProduct(
            internalProductId: 'BRAHMA',
            productName: 'Brahma',
            storeProductId: 'song_f_brahma_001_ios',
            quantity: 1,
          ),
        ],
        purchaseContext: _context(),
      );

      expect(displayed.map((item) => item.storeProductId), [
        'song_f_shiva_001_ios',
        'song_f_jagannath_001_ios',
      ]);
    },
  );

  test(
    'unexpected reconciliation exception is retained, not rethrown',
    () async {
      final store = _MemoryContextStore(_context(transactionId: 'REAL-123'));
      final reconciler = IosPurchaseReconciler(
        contextStore: store,
        orderLookup: (_, _) async => throw StateError('unexpected_lookup'),
        unfinishedTransactions: () async => const [],
        completeTransaction: (_) async {},
      );

      final result = await reconciler.reconcile();

      expect(result.resolved, isFalse);
      expect(result.context, isNotNull);
      expect(store.clears, 0);
    },
  );
}
