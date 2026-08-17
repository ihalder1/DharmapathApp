import 'package:flutter/foundation.dart';

import '../models/ios_purchase.dart';
import 'ios_purchase_context_store.dart';
import 'mantra_service.dart';
import 'payment_service.dart';
import 'storekit_purchase_service.dart';
import 'storekit_diagnostics.dart';

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
  }) : _contextStore = contextStore ?? IosPurchaseContextStore(),
       _storeKit = storeKit ?? StoreKitPurchaseService.instance,
       _diagnostics = diagnostics;

  final IosPurchaseContextStorage _contextStore;
  final StoreKitPurchaseService _storeKit;
  final StoreKitDiagnostics? _diagnostics;
  static Future<IosReconciliationResult>? _active;

  Future<IosReconciliationResult> reconcile() {
    final running = _active;
    if (running != null) return running;
    final future = _reconcile();
    _active = future;
    return future.whenComplete(() => _active = null);
  }

  Future<IosReconciliationResult> _reconcile() async {
    final loaded = await _contextStore.load();
    if (loaded == null) return const IosReconciliationResult(resolved: true);
    var context = loaded;
    _diagnostics?.log('RECONCILIATION_STARTED', {
      'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
      'state': context.state,
    });
    _log(
      'reconcile_start order=${_short(context.orderId)} state=${context.state}',
    );

    final backendOrder = await PaymentService.getIosPurchaseOrder(
      context.orderId,
      diagnostics: _diagnostics,
    );
    final unfinished = await _storeKit.unfinishedTransactions();
    final unfinishedById = {
      for (final item in unfinished)
        if (item.transactionId != null) item.transactionId!: item,
    };

    if (!backendOrder.paid) {
      final claimedTransactionIds = context.units
          .map((item) => item.transactionId)
          .whereType<String>()
          .toSet();
      for (var index = 0; index < context.units.length; index++) {
        var unit = context.units[index];
        var transactionId = unit.transactionId;
        if (transactionId == null || transactionId.isEmpty) {
          final matches =
              unfinished
                  .where(
                    (item) =>
                        item.productId == unit.storeProductId &&
                        appAccountTokensMatch(
                          context.linkToken,
                          item.appAccountToken,
                        ) &&
                        item.transactionId != null &&
                        !claimedTransactionIds.contains(item.transactionId),
                  )
                  .toList()
                ..sort(
                  (left, right) => (left.transactionId ?? '').compareTo(
                    right.transactionId ?? '',
                  ),
                );
          for (final item in unfinished.where(
            (item) => item.productId == unit.storeProductId,
          )) {
            _diagnostics?.logAppAccountTokenCorrelation(
              event: 'RECONCILIATION_TOKEN_CORRELATION',
              persistedToken: context.linkToken,
              returnedToken: item.appAccountToken,
            );
          }
          if (matches.isNotEmpty) {
            transactionId = matches.first.transactionId;
            if (transactionId != null && transactionId.isNotEmpty) {
              claimedTransactionIds.add(transactionId);
              context = context.recordTransaction(
                index: index,
                transactionId: transactionId,
              );
              await _contextStore.save(context);
              unit = context.units[index];
            }
          }
        }
        if (transactionId == null ||
            transactionId.isEmpty ||
            unit.backendAccepted) {
          continue;
        }
        final verification = await PaymentService.verifyIosPurchase(
          orderId: context.orderId,
          transactionId: transactionId,
          storeProductId: unit.storeProductId,
          diagnostics: _diagnostics,
        );
        if (!verification.accepted) continue;
        context = context.acceptTransaction(
          index: index,
          backendStatus: verification.status,
        );
        await _contextStore.save(context);
        _diagnostics?.log('CONTEXT_PERSISTED', {'state': context.state});
        await _refreshCredits();
        await MantraService.consumeIosCartProductUnits(unit.storeProductId, 1);
        if (verification.paid) break;
      }
    }

    final refreshedOrder = backendOrder.paid
        ? backendOrder
        : await PaymentService.getIosPurchaseOrder(
            context.orderId,
            diagnostics: _diagnostics,
          );
    if (refreshedOrder.paid) {
      context = context.acceptPaidOrder();
      await _contextStore.save(context);
      _diagnostics?.log('CONTEXT_PERSISTED', {'state': context.state});
    }

    for (var index = 0; index < context.units.length; index++) {
      final unit = context.units[index];
      if (!unit.backendAccepted || unit.storeKitCompleted) continue;
      final transaction = unfinishedById[unit.transactionId];
      if (transaction != null) await _storeKit.complete(transaction);
      context = context.completeTransaction(index);
      await _contextStore.save(context);
      _diagnostics?.log('STOREKIT_COMPLETED', {
        'storeProductId': unit.storeProductId,
        'transactionId': StoreKitDiagnostics.redactIdentifier(
          unit.transactionId,
        ),
      });
    }

    if (context.paid) {
      await _refreshCredits();
      await MantraService.removeIosCartProductsByStoreIds(
        context.acceptedStoreProductIds,
      );
      final allAcceptedCompleted = context.units
          .where((item) => item.backendAccepted)
          .every((item) => item.storeKitCompleted);
      if (allAcceptedCompleted) {
        await _contextStore.clear();
        _diagnostics?.log('CONTEXT_CLEARED');
        _diagnostics?.log('RECONCILIATION_FINISHED', {'result': 'paid'});
        _log('reconcile_paid order=${_short(context.orderId)}');
        return const IosReconciliationResult(resolved: true, paid: true);
      }
    }
    _diagnostics?.log('RECONCILIATION_FINISHED', {
      'result': 'pending',
      'state': context.state,
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

  void _log(String value) {
    if (kDebugMode) debugPrint('STOREKIT_DEBUG $value');
  }

  String _short(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}
