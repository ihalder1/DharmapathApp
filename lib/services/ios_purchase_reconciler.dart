import '../models/ios_purchase.dart';
import 'ios_purchase_context_store.dart';
import 'ios_purchase_abandonment.dart';
import 'mantra_service.dart';
import 'payment_service.dart';
import 'storekit_purchase_service.dart';
import 'storekit_diagnostics.dart';

typedef IosOrderLookup =
    Future<IosPurchaseVerification> Function(
      String orderId,
      StoreKitDiagnostics? diagnostics,
    );
typedef IosPurchaseVerificationOperation =
    Future<IosPurchaseVerification> Function(
      String orderId,
      String transactionId,
      String storeProductId,
      StoreKitDiagnostics? diagnostics,
    );
typedef IosUnfinishedTransactions =
    Future<List<StoreKitTransaction>> Function();
typedef IosCompleteTransaction =
    Future<void> Function(StoreKitTransaction transaction);

final class IosReconciliationResult {
  const IosReconciliationResult({
    this.context,
    this.resolved = false,
    this.paid = false,
  });

  final IosPurchaseContext? context;
  final bool resolved;
  final bool paid;
}

/// Reconciles only real persisted/unfinished StoreKit transactions. It never
/// launches a new Apple purchase.
final class IosPurchaseReconciler {
  IosPurchaseReconciler({
    IosPurchaseContextStorage? contextStore,
    StoreKitPurchaseService? storeKit,
    StoreKitDiagnostics? diagnostics,
    IosOrderLookup? orderLookup,
    IosPurchaseVerificationOperation? verifyPurchase,
    IosUnfinishedTransactions? unfinishedTransactions,
    IosCompleteTransaction? completeTransaction,
  }) : _contextStore = contextStore ?? IosPurchaseContextStore(),
       _diagnostics = diagnostics,
       _orderLookup =
           orderLookup ??
           ((orderId, diagnostics) => PaymentService.getIosPurchaseOrder(
             orderId,
             diagnostics: diagnostics,
           )),
       _verifyPurchase =
           verifyPurchase ??
           ((orderId, transactionId, storeProductId, diagnostics) =>
               PaymentService.verifyIosPurchase(
                 orderId: orderId,
                 transactionId: transactionId,
                 storeProductId: storeProductId,
                 diagnostics: diagnostics,
               )),
       _unfinishedTransactions =
           unfinishedTransactions ??
           (storeKit ?? StoreKitPurchaseService.instance)
               .unfinishedTransactions,
       _completeTransaction =
           completeTransaction ??
           (storeKit ?? StoreKitPurchaseService.instance).complete;

  final IosPurchaseContextStorage _contextStore;
  final StoreKitDiagnostics? _diagnostics;
  final IosOrderLookup _orderLookup;
  final IosPurchaseVerificationOperation _verifyPurchase;
  final IosUnfinishedTransactions _unfinishedTransactions;
  final IosCompleteTransaction _completeTransaction;
  static Future<IosReconciliationResult>? _active;

  Future<IosReconciliationResult> reconcile() {
    final running = _active;
    if (running != null) return running;
    final future = _reconcileSafely();
    _active = future;
    return future.whenComplete(() => _active = null);
  }

  Future<IosReconciliationResult> _reconcileSafely() async {
    try {
      return await _reconcile();
    } catch (error) {
      _diagnostics?.log('STOREKIT_RECONCILIATION_ERROR', {
        'errorType': error.runtimeType.toString(),
        'message': StoreKitDiagnostics.safeErrorMessage(error),
      });
      IosPurchaseContext? retained;
      try {
        retained = await _contextStore.load();
      } catch (_) {
        // The original error is already recorded. A storage failure remains
        // unresolved and must not be treated as a successful reconciliation.
      }
      return IosReconciliationResult(context: retained);
    }
  }

  Future<IosReconciliationResult> _reconcile() async {
    final stopwatch = Stopwatch()..start();
    final loaded = await _contextStore.load();
    if (loaded == null) {
      _diagnostics?.log('RECONCILIATION_FINISHED', {
        'result': 'no_context',
        'durationMs': stopwatch.elapsedMilliseconds,
      });
      return const IosReconciliationResult(resolved: true);
    }
    var context = loaded;
    _diagnostics?.log('RECONCILIATION_STARTED', {
      'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
      'state': context.state,
    });

    final unfinished = await _unfinishedTransactions();
    _diagnostics?.log('RECONCILIATION_UNFINISHED_TRANSACTIONS', {
      'count': unfinished.length,
      'transactions': unfinished
          .map(
            (item) => {
              'productId': item.productId,
              'status': item.status.name,
              'transactionId': StoreKitDiagnostics.redactIdentifier(
                item.transactionId,
              ),
              'appAccountTokenSuffix': StoreKitDiagnostics.redactIdentifier(
                item.appAccountToken,
              ),
            },
          )
          .toList(),
    });
    final backendOrder = await _orderLookup(context.orderId, _diagnostics);
    final abandonment = IosPurchaseAbandonment(
      contextStore: _contextStore,
      unfinishedTransactions: _unfinishedTransactions,
      diagnostics: _diagnostics,
    );
    if (!backendOrder.paid &&
        await abandonment.abandonIfSafeWithSnapshot(
          context,
          unfinished: unfinished,
          reason: 'startup_stale_prepare',
        )) {
      _diagnostics?.log('RECONCILIATION_FINISHED', {
        'result': 'abandoned_without_transaction',
        'durationMs': stopwatch.elapsedMilliseconds,
      });
      return const IosReconciliationResult(resolved: true);
    }
    final hasPersistedTransaction = context.units.any(
      (unit) => unit.transactionId?.trim().isNotEmpty == true,
    );
    final hasBackendAcceptedUnit = context.units.any(
      (unit) => unit.backendAccepted,
    );
    final hasMatchingUnfinishedTransaction = context.units.any(
      (unit) => unfinished.any(
        (transaction) =>
            transaction.productId == unit.storeProductId &&
            transaction.transactionId?.trim().isNotEmpty == true &&
            appAccountTokensMatch(
              context.linkToken,
              transaction.appAccountToken,
            ),
      ),
    );
    if (backendOrder.status == 'expired' &&
        !hasPersistedTransaction &&
        !hasBackendAcceptedUnit &&
        !hasMatchingUnfinishedTransaction) {
      await _contextStore.clear();
      _diagnostics?.log('RECONCILIATION_EXPIRED_CONTEXT_CLEARED', {
        'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
        'reason': 'no_transaction_evidence',
      });
      _diagnostics?.log('RECONCILIATION_FINISHED', {
        'result': 'expired_without_transaction',
        'durationMs': stopwatch.elapsedMilliseconds,
      });
      return const IosReconciliationResult(resolved: true);
    }

    // Phase-1 contexts may contain multiple per-song units. They are readable,
    // but are never reinterpreted as one aggregate transaction.
    if (!context.isAggregate) {
      _diagnostics?.log('RECONCILIATION_LEGACY_CONTEXT_RETAINED', {
        'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
        'hasTransactionEvidence': hasPersistedTransaction,
      });
      return IosReconciliationResult(context: context);
    }

    var unit = context.aggregateUnit;
    StoreKitTransaction? transaction;
    for (final candidate in unfinished.where(
      (item) => item.productId == unit.storeProductId,
    )) {
      _diagnostics?.logAppAccountTokenCorrelation(
        event: 'RECONCILIATION_TOKEN_CORRELATION',
        persistedToken: context.linkToken,
        returnedToken: candidate.appAccountToken,
      );
      final candidateId = candidate.transactionId?.trim();
      if (candidateId == null || candidateId.isEmpty) continue;
      if (!appAccountTokensMatch(
        context.linkToken,
        candidate.appAccountToken,
      )) {
        continue;
      }
      if (unit.transactionId == null || unit.transactionId == candidateId) {
        transaction = candidate;
        break;
      }
    }

    if ((unit.transactionId == null || unit.transactionId!.isEmpty) &&
        transaction != null) {
      context = context.recordTransaction(
        index: 0,
        transactionId: transaction.transactionId!,
      );
      await _contextStore.save(context);
      unit = context.aggregateUnit;
    }

    if (!backendOrder.paid &&
        !unit.backendAccepted &&
        unit.transactionId?.isNotEmpty == true) {
      _diagnostics?.log('IOS_AGGREGATE_VERIFY_START', {
        'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
        'storeProductId': unit.storeProductId,
      });
      final verification = await _verifyPurchase(
        context.orderId,
        unit.transactionId!,
        unit.storeProductId,
        _diagnostics,
      );
      if (verification.status == 'partially_paid') {
        context = context.copyWith(state: 'unexpected_partially_paid');
        await _contextStore.save(context);
        _diagnostics?.log('IOS_AGGREGATE_UNEXPECTED_PARTIALLY_PAID');
        return IosReconciliationResult(context: context);
      }
      if (verification.paid) {
        context = context.acceptTransaction(index: 0, backendStatus: 'paid');
        await _contextStore.save(context);
        _diagnostics?.log('IOS_AGGREGATE_VERIFY_PAID');
      }
    } else if (backendOrder.paid && !unit.backendAccepted) {
      context = context.acceptPaidOrder();
      await _contextStore.save(context);
    }

    if (context.paid) {
      await _refreshCredits();
      _diagnostics?.log('IOS_AGGREGATE_CREDIT_REFRESH_SUCCEEDED', {
        'distinctSongs': context.cartProducts.length,
        'units': context.cartProducts.fold<int>(
          0,
          (sum, item) => sum + item.quantity,
        ),
      });
      if (!context.cartFinalized) {
        await MantraService.consumeIosCartProducts(context.cartProducts);
        context = context.copyWith(cartFinalized: true);
        await _contextStore.save(context);
      }
      unit = context.aggregateUnit;
      if (!unit.storeKitCompleted) {
        if (transaction == null) {
          return IosReconciliationResult(context: context);
        }
        _diagnostics?.log('RECONCILIATION_COMPLETE_PURCHASE_BEFORE', {
          'status': transaction.status.name,
          'productId': transaction.productId,
          'transactionId': StoreKitDiagnostics.redactIdentifier(
            transaction.transactionId,
          ),
          'pendingCompletePurchase': transaction.pendingCompletePurchase,
        });
        await _completeTransaction(transaction);
        _diagnostics?.log('RECONCILIATION_COMPLETE_PURCHASE_AFTER', {
          'productId': transaction.productId,
          'transactionId': StoreKitDiagnostics.redactIdentifier(
            transaction.transactionId,
          ),
        });
        context = context.completeTransaction(0);
        await _contextStore.save(context);
        _diagnostics?.log('IOS_AGGREGATE_STOREKIT_COMPLETED');
      }
      await _contextStore.clear();
      _diagnostics?.log('CONTEXT_CLEARED');
      _diagnostics?.log('RECONCILIATION_FINISHED', {'result': 'paid'});
      return const IosReconciliationResult(resolved: true, paid: true);
    }
    _diagnostics?.log('RECONCILIATION_FINISHED', {
      'result': 'pending',
      'state': context.state,
      'durationMs': stopwatch.elapsedMilliseconds,
    });
    return IosReconciliationResult(context: context);
  }

  Future<void> _refreshCredits() async {
    _diagnostics?.log('CREDIT_REFRESH_STARTED');
    try {
      await MantraService.refreshPurchasedCountsOnlyStrict();
      _diagnostics?.log('CREDIT_REFRESH_SUCCEEDED');
    } catch (error) {
      _diagnostics?.log('CREDIT_REFRESH_FAILED', {
        'type': error.runtimeType.toString(),
      });
      rethrow;
    }
  }
}
