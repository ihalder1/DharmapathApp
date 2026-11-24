import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/services/ios_purchase_context_store.dart';
import 'package:colab_app_ui/services/ios_purchase_reconciler.dart';
import 'package:colab_app_ui/services/storekit_purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

const _token = '123e4567-e89b-12d3-a456-426614174000';
const _product = 'song_f_aarati_001_ios';

final class _MemoryStore implements IosPurchaseContextStorage {
  _MemoryStore(this.context);
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
  String? transactionId = '9434',
  String state = 'purchased',
  bool cartFinalized = false,
}) {
  final now = DateTime.utc(2026, 11, 23);
  return IosPurchaseContext(
    orderId: 'ORDER-A2A6',
    linkToken: _token,
    units: [
      IosPurchaseUnit(storeProductId: _product, transactionId: transactionId),
    ],
    currentIndex: 0,
    state: state,
    createdAt: now,
    updatedAt: now,
    architecture: 'aggregate_v2',
    cartProducts: const [
      IosCartProduct(
        internalProductId: 'AARATI',
        productName: 'Aarati',
        storeProductId: _product,
        quantity: 1,
      ),
    ],
    cartFinalized: cartFinalized,
  );
}

StoreKitTransaction _unfinished({
  String id = '9434',
  String productId = _product,
  String token = _token,
}) => StoreKitTransaction(
  productId: productId,
  transactionId: id,
  appAccountToken: token,
  status: PurchaseStatus.purchased,
);

IosPurchaseReconciler _reconciler({
  required _MemoryStore store,
  required List<StoreKitTransaction> unfinished,
  required IosPurchaseVerification order,
  IosPurchaseVerification? verification,
  IosRefreshCreditsOperation? refreshCredits,
  IosFinalizeCartOperation? finalizeCart,
  IosCompleteTransaction? complete,
}) => IosPurchaseReconciler(
  contextStore: store,
  orderLookup: (_, _) async => order,
  verifyPurchase: (_, __, ___, ____) async =>
      verification ?? const IosPurchaseVerification(status: 'pending'),
  unfinishedTransactions: () async => unfinished,
  completeTransaction: complete ?? (_) async {},
  refreshCredits: refreshCredits ?? () async {},
  finalizeCart: finalizeCart ?? (_) async {},
);

void main() {
  test(
    'backend paid and matching unfinished transaction completes then clears',
    () async {
      final store = _MemoryStore(_context());
      final events = <String>[];
      final result = await _reconciler(
        store: store,
        unfinished: [_unfinished()],
        order: const IosPurchaseVerification(status: 'paid'),
        finalizeCart: (_) async => events.add('fulfil'),
        complete: (_) async => events.add('finish'),
      ).reconcile();

      expect(events, ['fulfil', 'finish']);
      expect(store.context, isNull);
      expect(store.clears, 1);
      expect(result.paid, isTrue);
    },
  );

  test(
    'backend paid without unfinished transaction remains pending safely',
    () async {
      final store = _MemoryStore(_context());
      var finishes = 0;
      var fulfilled = false;
      final result = await _reconciler(
        store: store,
        unfinished: const [],
        order: const IosPurchaseVerification(status: 'paid'),
        finalizeCart: (_) async => fulfilled = true,
        complete: (_) async => finishes++,
      ).reconcile();

      expect(fulfilled, isTrue);
      expect(finishes, 0);
      expect(store.clears, 0);
      expect(result.context, isNotNull);
    },
  );

  test('pending backend status retains context and never finishes', () async {
    final store = _MemoryStore(_context());
    var finishes = 0;
    final result = await _reconciler(
      store: store,
      unfinished: [_unfinished()],
      order: const IosPurchaseVerification(status: 'pending'),
      verification: const IosPurchaseVerification(status: 'pending'),
      complete: (_) async => finishes++,
    ).reconcile();

    expect(finishes, 0);
    expect(store.clears, 0);
    expect(result.context, isNotNull);
  });

  test('retry after HTTP 500 reuses the saved order and transaction', () async {
    final store = _MemoryStore(_context());
    final verifyRequests = <(String, String, String)>[];
    var finishes = 0;
    var finalizations = 0;
    final reconciler = IosPurchaseReconciler(
      contextStore: store,
      orderLookup: (_, _) async =>
          const IosPurchaseVerification(status: 'pending'),
      verifyPurchase: (orderId, transactionId, productId, _) async {
        verifyRequests.add((orderId, transactionId, productId));
        throw StateError('ios_verify_purchase_failed_500');
      },
      unfinishedTransactions: () async => [_unfinished()],
      completeTransaction: (_) async => finishes++,
      refreshCredits: () async {},
      finalizeCart: (_) async => finalizations++,
    );

    final first = await reconciler.reconcile();
    final second = await reconciler.reconcile();

    expect(first.context, isNotNull);
    expect(second.context, isNotNull);
    expect(verifyRequests, [
      ('ORDER-A2A6', '9434', _product),
      ('ORDER-A2A6', '9434', _product),
    ]);
    expect(finishes, 0);
    expect(finalizations, 0);
    expect(store.clears, 0);
    expect(store.context?.units.single.transactionId, '9434');
  });

  test(
    'transaction completion is not called before successful verification',
    () async {
      final store = _MemoryStore(_context());
      var finishes = 0;
      final result = await _reconciler(
        store: store,
        unfinished: [_unfinished()],
        order: const IosPurchaseVerification(status: 'pending'),
        verification: const IosPurchaseVerification(status: 'pending'),
        complete: (_) async => finishes++,
      ).reconcile();

      expect(result.context, isNotNull);
      expect(finishes, 0);
      expect(store.clears, 0);
    },
  );

  test('fulfilment failure retains paid context and does not finish', () async {
    final store = _MemoryStore(_context());
    var finishes = 0;
    final result = await _reconciler(
      store: store,
      unfinished: [_unfinished()],
      order: const IosPurchaseVerification(status: 'paid'),
      finalizeCart: (_) async => throw StateError('fulfilment_failed'),
      complete: (_) async => finishes++,
    ).reconcile();

    expect(finishes, 0);
    expect(store.clears, 0);
    expect(result.context, isNotNull);
  });

  test('unrelated multi_02 orphan does not match Aarati order', () async {
    final store = _MemoryStore(
      _context(transactionId: null, state: 'opening_storekit'),
    );
    final result = await _reconciler(
      store: store,
      unfinished: [
        _unfinished(
          id: '3279',
          productId: 'multi_02',
          token: 'different-token',
        ),
      ],
      order: const IosPurchaseVerification(status: 'expired'),
    ).reconcile();

    expect(result.resolved, isTrue);
    expect(store.clears, 1);
    expect(store.context, isNull);
  });

  test('legacy purchased state does not imply backend payment', () {
    final legacy = IosPurchaseContext.fromJson(
      _context().toJson(includeLinkToken: false),
      linkToken: _token,
    );
    expect(legacy.state, 'purchased');
    expect(legacy.paid, isFalse);
    expect(legacy.units.single.backendAccepted, isFalse);
  });
}
