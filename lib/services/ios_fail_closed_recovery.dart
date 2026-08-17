import '../models/ios_purchase.dart';
import 'ios_purchase_context_store.dart';
import 'ios_purchase_reconciler.dart';

typedef IosReconcileOperation = Future<IosReconciliationResult> Function();
typedef IosPersistedContextEstablished =
    void Function(IosPurchaseContext context);
typedef IosBeforeReconcile = Future<void> Function();
typedef IosPrepareOperation<T> = Future<T> Function();

final class IosUnresolvedOrderConflict implements Exception {
  const IosUnresolvedOrderConflict(this.context);
  final IosPurchaseContext context;

  @override
  String toString() => 'ios_unresolved_order_conflict';
}

final class IosFailClosedRecoveryResult {
  const IosFailClosedRecoveryResult({
    this.context,
    this.paid = false,
    this.error,
  });

  final IosPurchaseContext? context;
  final bool paid;
  final Object? error;
  bool get blocked => context != null;
}

/// Establishes local pending state before invoking any potentially throwing
/// reconciliation work.
final class IosFailClosedRecovery {
  const IosFailClosedRecovery(this._contextStore);

  final IosPurchaseContextStorage _contextStore;

  Future<IosFailClosedRecoveryResult> recover({
    required IosReconcileOperation reconcile,
    IosPersistedContextEstablished? onContextEstablished,
    IosBeforeReconcile? beforeReconcile,
  }) async {
    final initial = await _contextStore.load();
    if (initial == null) {
      try {
        await beforeReconcile?.call();
        return const IosFailClosedRecoveryResult();
      } catch (error) {
        return IosFailClosedRecoveryResult(error: error);
      }
    }
    onContextEstablished?.call(initial);
    try {
      await beforeReconcile?.call();
      final result = await reconcile();
      final persisted = await _contextStore.load();
      return IosFailClosedRecoveryResult(
        context: persisted ?? result.context,
        paid: result.paid && persisted == null,
      );
    } catch (error) {
      return IosFailClosedRecoveryResult(context: initial, error: error);
    }
  }

  Future<IosPurchaseContext?> pendingBeforePrepare() => _contextStore.load();

  Future<T> runPrepareIfNoPending<T>(IosPrepareOperation<T> operation) async {
    final persisted = await pendingBeforePrepare();
    if (persisted != null) throw IosUnresolvedOrderConflict(persisted);
    return operation();
  }
}
