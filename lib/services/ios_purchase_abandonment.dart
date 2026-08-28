import '../models/ios_purchase.dart';
import 'ios_purchase_context_store.dart';
import 'storekit_diagnostics.dart';
import 'storekit_purchase_service.dart';

typedef IosAbandonmentUnfinishedTransactions =
    Future<List<StoreKitTransaction>> Function();

final class IosPurchaseAbandonment {
  const IosPurchaseAbandonment({
    required IosPurchaseContextStorage contextStore,
    required IosAbandonmentUnfinishedTransactions unfinishedTransactions,
    StoreKitDiagnostics? diagnostics,
  }) : _contextStore = contextStore,
       _unfinishedTransactions = unfinishedTransactions,
       _diagnostics = diagnostics;

  final IosPurchaseContextStorage _contextStore;
  final IosAbandonmentUnfinishedTransactions _unfinishedTransactions;
  final StoreKitDiagnostics? _diagnostics;

  static bool hasMatchingUnfinishedTransaction(
    IosPurchaseContext context,
    Iterable<StoreKitTransaction> unfinished,
  ) => context.units.any(
    (unit) => unfinished.any(
      (transaction) =>
          transaction.productId == unit.storeProductId &&
          transaction.transactionId?.trim().isNotEmpty == true &&
          appAccountTokensMatch(context.linkToken, transaction.appAccountToken),
    ),
  );

  static bool canSafelyAbandon(
    IosPurchaseContext context, {
    required bool matchingUnfinishedTransaction,
  }) {
    final transactionPresent = context.units.any(
      (unit) => unit.transactionId?.trim().isNotEmpty == true,
    );
    final backendAccepted = context.units.any((unit) => unit.backendAccepted);
    final storeKitCompleted = context.units.any(
      (unit) => unit.storeKitCompleted,
    );
    return !transactionPresent &&
        !backendAccepted &&
        !storeKitCompleted &&
        !matchingUnfinishedTransaction;
  }

  Future<bool> abandonIfSafe(
    IosPurchaseContext context, {
    required String reason,
  }) async {
    final unfinished = await _unfinishedTransactions();
    return abandonIfSafeWithSnapshot(
      context,
      unfinished: unfinished,
      reason: reason,
    );
  }

  Future<bool> abandonIfSafeWithSnapshot(
    IosPurchaseContext context, {
    required Iterable<StoreKitTransaction> unfinished,
    required String reason,
  }) async {
    final transactionPresent = context.units.any(
      (unit) => unit.transactionId?.trim().isNotEmpty == true,
    );
    final backendAccepted = context.units.any((unit) => unit.backendAccepted);
    final matching = hasMatchingUnfinishedTransaction(context, unfinished);
    final safe = canSafelyAbandon(
      context,
      matchingUnfinishedTransaction: matching,
    );
    _diagnostics?.log('IOS_PREPARED_CONTEXT_ABANDON_CHECK', {
      'reason': reason,
      'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
      'state': context.state,
      'productIds': context.units.map((item) => item.storeProductId).toList(),
      'linkTokenSuffix': StoreKitDiagnostics.redactIdentifier(
        context.linkToken,
      ),
      'unfinishedTransactionCount': unfinished.length,
      'unfinishedTransactionIds': unfinished
          .map(
            (item) => StoreKitDiagnostics.redactIdentifier(item.transactionId),
          )
          .toList(),
      'transactionPresent': transactionPresent,
      'backendAccepted': backendAccepted,
      'matchingUnfinishedTransaction': matching,
      'safeToAbandon': safe,
    });
    if (!safe) {
      _diagnostics?.log('IOS_PREPARED_CONTEXT_RETAINED', {
        'reason': 'transaction_evidence',
      });
      return false;
    }
    await _contextStore.clear();
    _diagnostics?.log('IOS_PREPARED_CONTEXT_ABANDONED', {'reason': reason});
    return true;
  }
}
