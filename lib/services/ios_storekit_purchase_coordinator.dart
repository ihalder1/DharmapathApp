import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'ios_purchase_reconciler.dart';
import 'storekit_diagnostics.dart';

enum IosStoreKitAttemptState {
  idle,
  openingStoreKit,
  storeKitActive,
  processingTransaction,
  settling,
}

final class IosStoreKitPurchaseAlreadyInFlight implements Exception {
  const IosStoreKitPurchaseAlreadyInFlight();

  @override
  String toString() => 'ios_storekit_purchase_already_in_flight';
}

typedef IosDeferredReconciliation = Future<IosReconciliationResult> Function();

/// Keeps StoreKit result delivery alive when Flutter removes the owning route.
final class IosStoreKitCheckoutLifetime {
  bool _disposed = false;

  bool get disposed => _disposed;
  bool get mayNavigate => !_disposed;

  /// Returns whether the purchase subscription can be cancelled immediately.
  bool detach({required bool purchaseProcessing}) {
    _disposed = true;
    return !purchaseProcessing;
  }
}

/// Application-wide ownership of the one native StoreKit purchase presentation.
final class IosStoreKitPurchaseCoordinator {
  IosStoreKitPurchaseCoordinator._();

  static final IosStoreKitPurchaseCoordinator instance =
      IosStoreKitPurchaseCoordinator._();

  @visibleForTesting
  IosStoreKitPurchaseCoordinator.forTesting();

  IosStoreKitAttemptState _state = IosStoreKitAttemptState.idle;
  String? _activeAttemptId;
  StoreKitDiagnostics? _diagnostics;
  IosDeferredReconciliation? _deferredReconciliation;
  bool _checkoutRouteActive = false;

  bool get purchasePresentationActive =>
      _state == IosStoreKitAttemptState.openingStoreKit ||
      _state == IosStoreKitAttemptState.storeKitActive;
  bool get purchaseResultProcessingActive =>
      _state == IosStoreKitAttemptState.processingTransaction ||
      _state == IosStoreKitAttemptState.settling;
  bool get purchaseActive => _state != IosStoreKitAttemptState.idle;
  bool get reconciliationDeferred => _deferredReconciliation != null;
  String? get activeAttemptId => _activeAttemptId;
  IosStoreKitAttemptState get state => _state;

  bool tryAcquireCheckoutRoute() {
    if (_checkoutRouteActive) return false;
    _checkoutRouteActive = true;
    return true;
  }

  void releaseCheckoutRoute() => _checkoutRouteActive = false;

  void logGlobalLifecycle(AppLifecycleState state) {
    final fields = {
      'attemptId': _activeAttemptId,
      'state': state.name,
      'purchaseActive': purchaseActive,
    };
    _diagnostics?.log('STOREKIT_GLOBAL_LIFECYCLE', fields);
    if (kDebugMode && _diagnostics == null) {
      debugPrint(
        'STOREKIT_DEBUG STOREKIT_GLOBAL_LIFECYCLE '
        'state=${state.name} purchaseActive=$purchaseActive',
      );
    }
  }

  String createAttemptId() {
    final value = Random.secure().nextInt(0x10000);
    return 'IOSP-${value.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  }

  void acquire({required String attemptId, StoreKitDiagnostics? diagnostics}) {
    diagnostics?.log('STOREKIT_GLOBAL_LOCK_ACQUIRE_REQUEST', {
      'attemptId': attemptId,
      'purchaseActive': purchaseActive,
    });
    if (purchaseActive) {
      diagnostics?.log('STOREKIT_GLOBAL_LOCK_REJECTED', {
        'attemptId': attemptId,
        'activeAttemptId': _activeAttemptId,
      });
      throw const IosStoreKitPurchaseAlreadyInFlight();
    }
    _activeAttemptId = attemptId;
    _diagnostics = diagnostics;
    _state = IosStoreKitAttemptState.openingStoreKit;
    _log('STOREKIT_GLOBAL_LOCK_ACQUIRED');
  }

  void markStoreKitActive(String attemptId) {
    if (!_owns(attemptId)) return;
    _state = IosStoreKitAttemptState.storeKitActive;
  }

  void markResultProcessing(String attemptId) {
    if (!_owns(attemptId)) return;
    _state = IosStoreKitAttemptState.processingTransaction;
    _log('STOREKIT_RESULT_PROCESSING_START');
  }

  Future<bool> runOrDeferReconciliation(
    IosDeferredReconciliation operation,
  ) async {
    if (!purchaseActive) {
      await operation();
      return true;
    }
    _deferredReconciliation ??= operation;
    _log('STOREKIT_RECONCILIATION_DEFERRED');
    return false;
  }

  Future<void> release(String attemptId) async {
    if (!_owns(attemptId)) return;
    if (_state == IosStoreKitAttemptState.processingTransaction) {
      _log('STOREKIT_RESULT_PROCESSING_END');
    }
    _state = IosStoreKitAttemptState.settling;
    final deferred = _deferredReconciliation;
    _deferredReconciliation = null;
    _log('STOREKIT_GLOBAL_LOCK_RELEASED');
    if (deferred != null) {
      _log('STOREKIT_DEFERRED_RECONCILIATION_STARTED', attemptId: attemptId);
      try {
        await deferred();
      } catch (error) {
        _diagnostics?.logError(stage: 'deferred_reconciliation', error: error);
      } finally {
        _log('STOREKIT_DEFERRED_RECONCILIATION_FINISHED', attemptId: attemptId);
        _state = IosStoreKitAttemptState.idle;
        _activeAttemptId = null;
        _diagnostics = null;
      }
    } else {
      _state = IosStoreKitAttemptState.idle;
      _activeAttemptId = null;
      _diagnostics = null;
    }
  }

  bool _owns(String attemptId) =>
      purchaseActive && _activeAttemptId == attemptId;

  void _log(String event, {String? attemptId}) {
    final id = attemptId ?? _activeAttemptId;
    _diagnostics?.log(event, {'attemptId': id, 'state': _state.name});
    if (kDebugMode && _diagnostics == null) {
      debugPrint('STOREKIT_DEBUG $event attemptId=$id state=${_state.name}');
    }
  }
}
