import '../models/ios_purchase.dart';
import 'ios_purchase_context_store.dart';
import 'storekit_purchase_service.dart';

typedef IosUnfinishedTransactionReader =
    Future<List<StoreKitTransaction>> Function();

final class StoreKitReadOnlySnapshot {
  const StoreKitReadOnlySnapshot({
    required this.context,
    required this.unfinishedTransactions,
  });

  final IosPurchaseContext? context;
  final List<StoreKitTransaction> unfinishedTransactions;
}

/// Read-only inspection boundary. It performs exactly one local context read
/// and one StoreKit 2 unfinished-transactions read.
final class StoreKitReadOnlySnapshotService {
  const StoreKitReadOnlySnapshotService({
    required IosPurchaseContextStorage contextStore,
    required IosUnfinishedTransactionReader readUnfinishedTransactions,
  }) : _contextStore = contextStore,
       _readUnfinishedTransactions = readUnfinishedTransactions;

  final IosPurchaseContextStorage _contextStore;
  final IosUnfinishedTransactionReader _readUnfinishedTransactions;

  Future<StoreKitReadOnlySnapshot> capture() async {
    final context = await _contextStore.load();
    final unfinished = await _readUnfinishedTransactions();
    return StoreKitReadOnlySnapshot(
      context: context,
      unfinishedTransactions: List.unmodifiable(unfinished),
    );
  }
}
