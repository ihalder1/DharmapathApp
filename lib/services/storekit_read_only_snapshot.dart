import '../models/ios_purchase.dart';
import 'ios_purchase_context_store.dart';
import 'storekit_diagnostics.dart';
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

  void log(StoreKitReadOnlySnapshot snapshot, StoreKitDiagnostics diagnostics) {
    final context = snapshot.context;
    final assignedIds =
        context?.units
            .map((item) => item.transactionId)
            .whereType<String>()
            .toSet() ??
        const <String>{};
    diagnostics.log('STOREKIT_READ_ONLY_CONTEXT', {
      'contextPresent': context == null ? 'NO' : 'YES',
      'orderId': StoreKitDiagnostics.redactIdentifier(context?.orderId),
      'state': context?.state,
      'productIds': context?.units.map((item) => item.storeProductId).toList(),
      'units': context?.units.indexed.map((entry) {
        final unit = entry.$2;
        return {
          'index': entry.$1,
          'productId': unit.storeProductId,
          'transactionId': StoreKitDiagnostics.redactIdentifier(
            unit.transactionId,
          ),
          'backendAccepted': unit.backendAccepted,
          'storeKitCompleted': unit.storeKitCompleted,
        };
      }).toList(),
    });
    for (final transaction in snapshot.unfinishedTransactions) {
      final id = transaction.transactionId?.trim();
      final token = transaction.appAccountToken?.trim();
      diagnostics.log('STOREKIT_READ_ONLY_UNFINISHED', {
        'productId': transaction.productId,
        'transactionId': StoreKitDiagnostics.redactIdentifier(id),
        'appAccountTokenPresent': token?.isNotEmpty == true,
        'appAccountTokenSuffix': token == null || token.length < 4
            ? null
            : token.substring(token.length - 4),
        'matchesPersistedContextToken':
            context != null && appAccountTokensMatch(context.linkToken, token)
            ? 'YES'
            : 'NO',
        'assignedToPersistedUnit': id != null && assignedIds.contains(id)
            ? 'YES'
            : 'NO',
      });
    }
  }
}
