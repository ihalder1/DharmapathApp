import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/services/ios_purchase_abandonment.dart';
import 'package:colab_app_ui/services/ios_purchase_context_store.dart';
import 'package:colab_app_ui/services/ios_purchase_reconciler.dart';
import 'package:colab_app_ui/services/storekit_purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

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
  String? transactionId,
  bool backendAccepted = false,
  bool storeKitCompleted = false,
  String state = 'prepared',
}) {
  final now = DateTime.utc(2026, 8, 21);
  return IosPurchaseContext(
    orderId: 'ORDER-PREPARED',
    linkToken: '123e4567-e89b-12d3-a456-426614174000',
    units: [
      IosPurchaseUnit(
        storeProductId: 'multi_04',
        transactionId: transactionId,
        backendAccepted: backendAccepted,
        storeKitCompleted: storeKitCompleted,
      ),
    ],
    currentIndex: 0,
    state: state,
    createdAt: now,
    updatedAt: now,
  );
}

StoreKitTransaction _transaction({
  String productId = 'multi_04',
  String token = '123e4567-e89b-12d3-a456-426614174000',
}) => StoreKitTransaction(
  productId: productId,
  status: PurchaseStatus.purchased,
  transactionId: '7307',
  appAccountToken: token,
);

void main() {
  test(
    'prepared context can be abandoned for Back or Apple cancellation',
    () async {
      for (final reason in [
        'user_back',
        'apple_cancelled',
        'storekit_error_no_transaction',
      ]) {
        final store = _MemoryStore(_context());
        final abandonment = IosPurchaseAbandonment(
          contextStore: store,
          unfinishedTransactions: () async => const [],
        );
        expect(
          await abandonment.abandonIfSafe(store.context!, reason: reason),
          isTrue,
        );
        expect(store.context, isNull);
        expect(store.clears, 1);
      }
    },
  );

  test(
    'transaction ID, backend acceptance, and completion prevent clearing',
    () async {
      for (final context in [
        _context(transactionId: '7307'),
        _context(backendAccepted: true),
        _context(storeKitCompleted: true),
      ]) {
        final store = _MemoryStore(context);
        final abandonment = IosPurchaseAbandonment(
          contextStore: store,
          unfinishedTransactions: () async => const [],
        );
        expect(
          await abandonment.abandonIfSafe(context, reason: 'user_back'),
          isFalse,
        );
        expect(store.context, same(context));
        expect(store.clears, 0);
      }
    },
  );

  test(
    'only matching product and canonical token prevent abandonment',
    () async {
      final context = _context();
      final matchingStore = _MemoryStore(context);
      final matching = IosPurchaseAbandonment(
        contextStore: matchingStore,
        unfinishedTransactions: () async => [_transaction()],
      );
      expect(
        await matching.abandonIfSafe(context, reason: 'startup_stale_prepare'),
        isFalse,
      );

      final unrelatedStore = _MemoryStore(context);
      final unrelated = IosPurchaseAbandonment(
        contextStore: unrelatedStore,
        unfinishedTransactions: () async => [
          _transaction(productId: 'multi_03'),
          _transaction(token: '223e4567-e89b-12d3-a456-426614174000'),
        ],
      );
      expect(
        await unrelated.abandonIfSafe(context, reason: 'startup_stale_prepare'),
        isTrue,
      );
      expect(unrelatedStore.context, isNull);
    },
  );

  test(
    'pending backend order without Apple evidence is cleared at startup',
    () async {
      final store = _MemoryStore(_context(state: 'opening_storekit'));
      final result = await IosPurchaseReconciler(
        contextStore: store,
        orderLookup: (_, _) async =>
            const IosPurchaseVerification(status: 'pending'),
        unfinishedTransactions: () async => const [],
        verifyPurchase: (_, __, ___, ____) async =>
            const IosPurchaseVerification(status: 'pending'),
        completeTransaction: (_) async {},
      ).reconcile();

      expect(result.resolved, isTrue);
      expect(store.context, isNull);
    },
  );
}
