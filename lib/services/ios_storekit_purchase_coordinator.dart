import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'ios_purchase_reconciler.dart';

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

  String createAttemptId() {
    final value = Random.secure().nextInt(0x10000);
    return 'IOSP-${value.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  }

  void acquire({required String attemptId}) {
    if (purchaseActive) {
      throw const IosStoreKitPurchaseAlreadyInFlight();
    }
    _activeAttemptId = attemptId;
    _state = IosStoreKitAttemptState.openingStoreKit;
  }

  void markStoreKitActive(String attemptId) {
    if (!_owns(attemptId)) return;
    _state = IosStoreKitAttemptState.storeKitActive;
  }

  void markResultProcessing(String attemptId) {
    if (!_owns(attemptId)) return;
    _state = IosStoreKitAttemptState.processingTransaction;
  }

  Future<bool> runOrDeferReconciliation(
    IosDeferredReconciliation operation,
  ) async {
    if (!purchaseActive) {
      await operation();
      return true;
    }
    _deferredReconciliation ??= operation;
    return false;
  }

  Future<void> release(String attemptId) async {
    if (!_owns(attemptId)) return;
    _state = IosStoreKitAttemptState.settling;
    final deferred = _deferredReconciliation;
    _deferredReconciliation = null;
    if (deferred != null) {
      try {
        await deferred();
      } catch (_) {
        // Durable reconciliation state remains available for the next retry.
      } finally {
        _state = IosStoreKitAttemptState.idle;
        _activeAttemptId = null;
      }
    } else {
      _state = IosStoreKitAttemptState.idle;
      _activeAttemptId = null;
    }
  }

  bool _owns(String attemptId) =>
      purchaseActive && _activeAttemptId == attemptId;
}
