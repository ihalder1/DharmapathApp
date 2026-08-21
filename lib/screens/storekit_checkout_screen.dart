import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/ios_purchase.dart';
import '../models/mantra.dart';
import '../services/ios_purchase_context_store.dart';
import '../services/ios_fail_closed_recovery.dart';
import '../services/ios_purchase_reconciler.dart';
import '../services/ios_storekit_purchase_coordinator.dart';
import '../services/mantra_service.dart';
import '../services/cart_quantity_policy.dart';
import '../services/payment_service.dart';
import '../services/storekit_purchase_service.dart';
import '../services/storekit_read_only_snapshot.dart';
import '../services/storekit_diagnostics.dart';

class StoreKitCheckoutScreen extends StatefulWidget {
  const StoreKitCheckoutScreen({super.key, required this.cartItems});

  final List<Mantra> cartItems;

  @override
  State<StoreKitCheckoutScreen> createState() => _StoreKitCheckoutScreenState();
}

String iosAggregateCheckoutTotal(StoreKitProductPrice? aggregateProduct) =>
    aggregateProduct?.formattedPrice ?? 'Price unavailable';

List<IosCartProduct> buildIosRecoveryDisplayProducts({
  required List<IosCartProduct> cartProducts,
  required IosPurchaseContext? purchaseContext,
}) {
  if (purchaseContext == null) return cartProducts;
  if (purchaseContext.isAggregate && purchaseContext.cartProducts.isNotEmpty) {
    return purchaseContext.cartProducts;
  }
  final remaining = <String, int>{};
  for (final unit in purchaseContext.units.where(
    (item) => !item.backendAccepted,
  )) {
    remaining.update(
      unit.storeProductId,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }
  return remaining.entries
      .map((entry) {
        IosCartProduct? cartItem;
        for (final candidate in cartProducts) {
          if (candidate.storeProductId == entry.key) {
            cartItem = candidate;
            break;
          }
        }
        return IosCartProduct(
          internalProductId: cartItem?.internalProductId ?? entry.key,
          productName: cartItem?.productName ?? entry.key,
          storeProductId: entry.key,
          quantity: entry.value,
        );
      })
      .toList(growable: false);
}

class _StoreKitCheckoutScreenState extends State<StoreKitCheckoutScreen>
    with WidgetsBindingObserver {
  final _storeKit = StoreKitPurchaseService.instance;
  final _contextStore = IosPurchaseContextStore();
  late final IosPurchaseReconciler _reconciler;
  late final IosFailClosedRecovery _failClosedRecovery;
  late final StoreKitReadOnlySnapshotService _readOnlySnapshot;
  late final StoreKitDiagnostics _diagnostics;
  StreamSubscription<List<StoreKitTransaction>>? _purchaseSubscription;
  late final List<IosCartProduct> _cartProducts;
  Map<String, StoreKitProductPrice> _prices = const {};
  StoreKitProductPrice? _aggregatePrice;
  IosPurchaseContext? _purchaseContext;
  Completer<StoreKitTransaction>? _purchaseCompleter;
  String? _waitingForProductId;
  final Set<String> _handledTransactionIds = {};
  bool _loading = true;
  bool _processing = false;
  bool _recovering = false;
  bool _blockedByPriorOrder = false;
  final _lifetime = IosStoreKitCheckoutLifetime();
  String? _activeAttemptId;
  String _status = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _diagnostics = StoreKitDiagnostics(
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _reconciler = IosPurchaseReconciler(
      contextStore: _contextStore,
      storeKit: _storeKit,
      diagnostics: _diagnostics,
    );
    _failClosedRecovery = IosFailClosedRecovery(_contextStore);
    _readOnlySnapshot = StoreKitReadOnlySnapshotService(
      contextStore: _contextStore,
      readUnfinishedTransactions: _storeKit.unfinishedTransactions,
    );
    try {
      _cartProducts = buildIosCartProducts(widget.cartItems);
      final totalUnits = iosCartTotalUnits(_cartProducts);
      if (totalUnits > iosMaxAggregateCartUnits) {
        throw const FormatException('ios_aggregate_cart_unit_limit_exceeded');
      }
      _diagnostics.log('CHECKOUT_SESSION_STARTED', {
        'platform': 'ios',
        'cartUnits': totalUnits,
      });
      _diagnostics.log('IOS_CART_SNAPSHOT', {
        'distinctSongs': _cartProducts.length,
        'quantities': iosCartQuantityDiagnostics(_cartProducts),
        'totalUnits': totalUnits,
      });
      _diagnostics.log('IOS_CHECKOUT_DISPLAY', {
        'products': iosCartQuantityDiagnostics(_cartProducts),
        'totalUnits': totalUnits,
      });
    } on FormatException catch (error) {
      _cartProducts = const [];
      _error = error.message == 'ios_aggregate_cart_unit_limit_exceeded'
          ? 'You can purchase up to 21 mantra credits in one Apple checkout.'
          : 'One or more mantras are not configured for Apple purchases.';
      _diagnostics.log('ERROR', {
        'stage': 'cart_validation',
        'type': 'FormatException',
        'message': 'Missing Apple product mapping',
      });
    }
    _purchaseSubscription = _storeKit.purchaseUpdates.listen(
      _handlePurchaseUpdates,
      onError: (_) => _failWaitingPurchase('Apple purchase update failed.'),
    );
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _diagnostics.log('IOS_CHECKOUT_ROUTE_DISPOSE', {
      'attemptId': _activeAttemptId,
      'processing': _processing,
      'waitingForPurchase': _purchaseCompleter?.isCompleted == false,
    });
    WidgetsBinding.instance.removeObserver(this);
    // Keep the listener alive while StoreKit owns native UI so the detached
    // checkout can finish transaction processing without an orphaned waiter.
    if (_lifetime.detach(purchaseProcessing: _processing)) {
      unawaited(_purchaseSubscription?.cancel());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _diagnostics.log('STOREKIT_CHECKOUT_LIFECYCLE', {
      'attemptId': _activeAttemptId,
      'state': state.name,
      'processing': _processing,
      'recovering': _recovering,
      'mounted': mounted,
    });
    if (state == AppLifecycleState.resumed && !_processing && !_recovering) {
      unawaited(_recover());
    }
  }

  Future<void> _initialize() async {
    try {
      await _recover();
      if (!mounted || _blockedByPriorOrder || _cartProducts.isEmpty) return;
      final available = await _storeKit.isAvailable();
      _diagnostics.log('STOREKIT_AVAILABILITY', {
        'platform': 'ios',
        'available': available,
      });
      if (!available) {
        throw StateError('storekit_unavailable');
      }
      final prices = await _storeKit.queryProducts(
        _cartProducts.map((item) => item.storeProductId),
        diagnostics: _diagnostics,
      );
      for (final item in _cartProducts) {
        final price = prices[item.storeProductId];
        _diagnostics.logProductLookup(
          internalProductId: item.internalProductId,
          metadataStoreProductId: item.storeProductId,
          queriedProductId: item.storeProductId,
          found: price != null,
          price: price?.formattedPrice,
          rawPrice: price?.rawPrice,
          currencyCode: price?.currencyCode,
        );
      }
      if (!mounted) return;
      setState(() => _prices = prices);
    } catch (error) {
      _diagnostics.logError(stage: 'store_initialization', error: error);
      _log('initialize_failed type=${error.runtimeType}');
      if (mounted) {
        setState(() => _error = 'Apple products could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _recover() async {
    if (_recovering || _processing) return;
    _recovering = true;
    if (mounted) setState(() {});
    try {
      final recovery = await _failClosedRecovery.recover(
        onContextEstablished: (persisted) {
          _purchaseContext = persisted;
          _blockedByPriorOrder = true;
          _status = 'Recovering your previous Apple purchase...';
          if (mounted) setState(() {});
        },
        beforeReconcile: () async {
          final snapshot = await _readOnlySnapshot.capture();
          _readOnlySnapshot.log(snapshot, _diagnostics);
        },
        reconcile: _reconciler.reconcile,
      );
      if (!mounted) return;
      if (recovery.error != null) {
        _diagnostics.logError(stage: 'reconciliation', error: recovery.error!);
        _purchaseContext = recovery.context;
        _blockedByPriorOrder = true;
        _status =
            'Your previous Apple purchase is still being verified. A new purchase cannot be started until it is resolved.';
        return;
      }
      if (recovery.paid) {
        Navigator.of(context).pop(true);
        return;
      }
      final stored = recovery.context;
      if (stored == null) {
        _purchaseContext = null;
        _blockedByPriorOrder = false;
        return;
      }
      _purchaseContext = stored;
      _blockedByPriorOrder = true;
      _status =
          'Your previous Apple purchase is still being verified. A new purchase cannot be started until it is resolved.';
    } catch (error) {
      _diagnostics.logError(stage: 'recovery_local', error: error);
      _log('recover_local_failed type=${error.runtimeType}');
      _blockedByPriorOrder = true;
      _status =
          'Apple purchase recovery could not confirm saved state. A new purchase cannot be started.';
    } finally {
      _recovering = false;
      if (mounted) setState(() {});
    }
  }

  bool get _allProductsLoaded =>
      _cartProducts.isNotEmpty &&
      _cartProducts.every((item) => _prices.containsKey(item.storeProductId));

  List<IosCartProduct> get _displayCartProducts {
    return buildIosRecoveryDisplayProducts(
      cartProducts: _cartProducts,
      purchaseContext: _purchaseContext,
    );
  }

  String get _total {
    final aggregatePrice = _aggregatePrice;
    return iosAggregateCheckoutTotal(aggregatePrice);
  }

  String? get _currency {
    final values = _cartProducts
        .map((item) => _prices[item.storeProductId]?.currencyCode)
        .whereType<String>()
        .toSet();
    return values.length == 1 ? values.single : null;
  }

  Future<void> _startOrContinueCheckout() async {
    if (_processing ||
        _recovering ||
        _blockedByPriorOrder ||
        !_allProductsLoaded ||
        _currency == null) {
      return;
    }
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      var active = _purchaseContext;
      if (active == null) {
        _setStatus('Preparing Apple purchase...');
        _diagnostics.log('IOS_CART_PREPARE', {
          'distinctSongs': _cartProducts.length,
          'totalUnits': iosCartTotalUnits(_cartProducts),
          'products': iosCartQuantityDiagnostics(_cartProducts),
        });
        _diagnostics.log('IOS_PREPARE_QUANTITIES', {
          'products': iosCartQuantityDiagnostics(_cartProducts),
        });
        final prepared = await _failClosedRecovery.runPrepareIfNoPending(
          () => PaymentService.prepareIosPurchase(
            currency: _currency!,
            products: _cartProducts,
            diagnostics: _diagnostics,
          ),
        );
        if (!isCanonicalUuid(prepared.linkToken)) {
          _log(
            'prepare_invalid_app_account_token order=${_short(prepared.orderId)}',
          );
          throw const _InvalidAppAccountToken();
        }
        final aggregate = requireIosAggregateStoreProduct(
          prepared.storeProducts,
        );
        _diagnostics.log('IOS_AGGREGATE_PRODUCT_RECEIVED', {
          'storeProductId': aggregate.storeProductId,
          'backendQuantity': aggregate.quantity,
        });
        final resolved = await _storeKit.queryProducts([
          aggregate.storeProductId,
        ], diagnostics: _diagnostics);
        final aggregatePrice = resolved[aggregate.storeProductId];
        _diagnostics.log('IOS_AGGREGATE_PRODUCT_LOOKUP', {
          'storeProductId': aggregate.storeProductId,
          'found': aggregatePrice != null,
          'price': aggregatePrice?.formattedPrice,
          'currencyCode': aggregatePrice?.currencyCode,
        });
        if (aggregatePrice == null) {
          throw const FormatException('ios_aggregate_product_not_found');
        }
        if (mounted) setState(() => _aggregatePrice = aggregatePrice);
        final now = DateTime.now().toUtc();
        active = IosPurchaseContext(
          orderId: prepared.orderId,
          linkToken: prepared.linkToken,
          units: [IosPurchaseUnit(storeProductId: aggregate.storeProductId)],
          currentIndex: 0,
          state: 'prepared',
          createdAt: now,
          updatedAt: now,
          cartProducts: _cartProducts,
        );
        await _contextStore.save(active);
        _diagnostics.log('CONTEXT_PERSISTED', {
          'orderId': StoreKitDiagnostics.redactIdentifier(active.orderId),
          'state': active.state,
        });
        _purchaseContext = active;
        _log('context_saved order=${_short(active.orderId)}');
      }

      var checkout = active;
      if (!checkout.isAggregate) {
        throw StateError('ios_legacy_context_requires_manual_recovery');
      }
      const index = 0;
      final unit = checkout.aggregateUnit;
      var price = _aggregatePrice;
      if (price == null) {
        final resolved = await _storeKit.queryProducts([
          unit.storeProductId,
        ], diagnostics: _diagnostics);
        price = resolved[unit.storeProductId];
        if (price == null) {
          throw StateError('ios_aggregate_product_not_found');
        }
        if (mounted) setState(() => _aggregatePrice = price);
      }
      if (!unit.backendAccepted) {
        checkout = checkout.copyWith(
          currentIndex: index,
          state: 'opening_storekit',
        );
        await _save(checkout);
        _diagnostics.logAppAccountTokenCorrelation(
          event: 'APP_ACCOUNT_TOKEN_SUPPLIED',
          persistedToken: checkout.linkToken,
          suppliedToken: checkout.linkToken,
        );
        final coordinator = IosStoreKitPurchaseCoordinator.instance;
        final attemptId = coordinator.createAttemptId();
        _diagnostics.log('STOREKIT_ATTEMPT_CREATED', {
          'attemptId': attemptId,
          'storeProductId': unit.storeProductId,
        });
        coordinator.acquire(attemptId: attemptId, diagnostics: _diagnostics);
        _activeAttemptId = attemptId;
        StoreKitTransaction transaction;
        try {
          _diagnostics.log('IOS_AGGREGATE_PURCHASE_START', {
            'attemptId': attemptId,
            'storeProductId': unit.storeProductId,
            'cartUnits': checkout.cartProducts.fold<int>(
              0,
              (sum, item) => sum + item.quantity,
            ),
          });
          transaction = await _launchAndWait(
            product: price.details,
            appAccountToken: checkout.linkToken,
            attemptId: attemptId,
          );
          coordinator.markResultProcessing(attemptId);
          final transactionId = transaction.transactionId?.trim() ?? '';
          if (transactionId.isEmpty) {
            throw StateError('storekit_transaction_id_missing');
          }
          _diagnostics.logAppAccountTokenCorrelation(
            event: 'APP_ACCOUNT_TOKEN_RETURNED',
            persistedToken: checkout.linkToken,
            returnedToken: transaction.appAccountToken,
          );
          if (!appAccountTokensMatch(
            checkout.linkToken,
            transaction.appAccountToken,
          )) {
            throw StateError('storekit_app_account_token_mismatch');
          }
          checkout = checkout.recordTransaction(
            index: index,
            transactionId: transactionId,
          );
          await _save(checkout);
          _diagnostics.log('IOS_AGGREGATE_TRANSACTION_RECEIVED', {
            'transactionId': StoreKitDiagnostics.redactIdentifier(
              transactionId,
            ),
          });
          _diagnostics.logPurchase(
            event: 'APPLE_PURCHASE_RECEIVED',
            storeProductId: unit.storeProductId,
            status: transaction.status.name,
            transactionId: transactionId,
          );

          _diagnostics.log('IOS_AGGREGATE_VERIFY_START', {
            'orderId': StoreKitDiagnostics.redactIdentifier(checkout.orderId),
            'storeProductId': unit.storeProductId,
          });
          final verification = await PaymentService.verifyIosPurchase(
            orderId: checkout.orderId,
            transactionId: transactionId,
            storeProductId: unit.storeProductId,
            diagnostics: _diagnostics,
          );
          if (verification.status == 'partially_paid') {
            await _save(checkout.copyWith(state: 'unexpected_partially_paid'));
            _diagnostics.log('IOS_AGGREGATE_UNEXPECTED_PARTIALLY_PAID', {
              'orderId': StoreKitDiagnostics.redactIdentifier(checkout.orderId),
            });
            throw StateError('ios_aggregate_unexpected_partially_paid');
          }
          if (!verification.paid) {
            throw StateError('backend_did_not_accept_storekit_transaction');
          }
          checkout = checkout.acceptTransaction(
            index: index,
            backendStatus: verification.status,
          );
          await _save(checkout);
          await _refreshCredits();
          _diagnostics.log('IOS_AGGREGATE_CREDIT_REFRESH_SUCCEEDED', {
            'distinctSongs': checkout.cartProducts.length,
            'units': checkout.cartProducts.fold<int>(
              0,
              (sum, item) => sum + item.quantity,
            ),
          });
          _diagnostics.log('IOS_AGGREGATE_VERIFY_PAID');
          await MantraService.consumeIosCartProducts(checkout.cartProducts);
          checkout = checkout.copyWith(cartFinalized: true);
          await _save(checkout);
          await _storeKit.complete(transaction);
          _diagnostics.log('IOS_AGGREGATE_STOREKIT_COMPLETED');
          _diagnostics.logPurchase(
            event: 'STOREKIT_COMPLETED',
            storeProductId: unit.storeProductId,
            status: transaction.status.name,
            transactionId: transactionId,
          );
          checkout = checkout.completeTransaction(index);
          await _save(checkout);
          _handledTransactionIds.add(transactionId);

          checkout = checkout.copyWith(state: 'paid');
          await _save(checkout);
          await _finishPaid(checkout);
          return;
        } finally {
          await coordinator.release(attemptId);
          _activeAttemptId = null;
        }
      }
    } on IosUnresolvedOrderConflict catch (conflict) {
      _purchaseContext = conflict.context;
      _blockedByPriorOrder = true;
      _diagnostics.log('PREPARE_BLOCKED_BY_PERSISTED_CONTEXT', {
        'orderId': StoreKitDiagnostics.redactIdentifier(
          conflict.context.orderId,
        ),
        'state': conflict.context.state,
      });
      _setError(
        'Your previous Apple purchase is still being verified. A new purchase cannot be started until it is resolved.',
      );
    } on _StoreKitCancelled {
      final saved = _purchaseContext;
      if (saved != null) {
        await _save(saved.copyWith(state: 'cancelled'));
      }
      _setStatus('Apple purchase was cancelled. You can try again when ready.');
    } on _StoreKitPending {
      final saved = _purchaseContext;
      if (saved != null) await _save(saved.copyWith(state: 'pending'));
      _setStatus(
        'This Apple purchase is pending approval. The saved order will be reconciled automatically.',
      );
    } on _InvalidAppAccountToken {
      _diagnostics.log('ERROR', {
        'stage': 'prepare_validation',
        'type': 'InvalidAppAccountToken',
        'message': 'linkToken is not a canonical UUID',
      });
      _setError(
        'Apple purchase configuration is invalid. No purchase was opened. Please contact support.',
      );
    } on FormatException catch (error) {
      _diagnostics.logError(stage: 'mapping_validation', error: error);
      _log('checkout_validation_failed type=${error.runtimeType}');
      _setError(
        'The backend Apple product mapping does not match this cart. No purchase was opened.',
      );
    } catch (error) {
      _diagnostics.logError(stage: 'checkout', error: error);
      _log('checkout_deferred type=${error.runtimeType}');
      _setError(
        'The purchase could not be completed safely. Your order was saved and will be reconciled.',
      );
    } finally {
      _purchaseCompleter = null;
      _waitingForProductId = null;
      if (mounted) setState(() => _processing = false);
      if (_lifetime.disposed) unawaited(_purchaseSubscription?.cancel());
    }
  }

  Future<StoreKitTransaction> _launchAndWait({
    required ProductDetails product,
    required String appAccountToken,
    required String attemptId,
  }) async {
    final completer = Completer<StoreKitTransaction>();
    _purchaseCompleter = completer;
    _waitingForProductId = product.id;
    _setStatus('Opening Apple purchase...');
    _diagnostics.logPurchase(
      event: 'APPLE_PURCHASE_STARTED',
      storeProductId: product.id,
      status: 'started',
    );
    final stopwatch = Stopwatch()..start();
    _diagnostics.log('STOREKIT_PURCHASE_CALL_START', {
      'attemptId': attemptId,
      'productId': product.id,
    });
    IosStoreKitPurchaseCoordinator.instance.markStoreKitActive(attemptId);
    bool launched;
    try {
      launched = await _storeKit.buyConsumable(
        product: product,
        appAccountToken: appAccountToken,
      );
    } finally {
      _diagnostics.log('STOREKIT_PURCHASE_CALL_RETURN', {
        'attemptId': attemptId,
        'productId': product.id,
        'elapsedMs': stopwatch.elapsedMilliseconds,
      });
    }
    if (!launched && !completer.isCompleted) {
      throw StateError('storekit_purchase_not_launched');
    }
    return completer.future.timeout(const Duration(minutes: 10));
  }

  void _handlePurchaseUpdates(List<StoreKitTransaction> updates) {
    final context = _purchaseContext;
    for (final transaction in updates) {
      _diagnostics.logPurchase(
        event: 'APPLE_PURCHASE_UPDATE',
        storeProductId: transaction.productId,
        status: transaction.status.name,
        transactionId: transaction.transactionId,
      );
      _diagnostics.log('STOREKIT_PURCHASE_STREAM_EVENT', {
        'attemptId': _activeAttemptId,
        'status': transaction.status.name,
        'productId': transaction.productId,
        'transactionId': StoreKitDiagnostics.redactIdentifier(
          transaction.transactionId,
        ),
      });
      if (context != null) {
        _diagnostics.logAppAccountTokenCorrelation(
          event: 'PURCHASE_STREAM_TOKEN_CORRELATION',
          persistedToken: context.linkToken,
          returnedToken: transaction.appAccountToken,
        );
      }
    }
    final completer = _purchaseCompleter;
    final expected = _waitingForProductId;
    if (completer == null || completer.isCompleted || expected == null) return;
    if (context == null) return;
    final persistedTransactionIds = context.units
        .map((item) => item.transactionId)
        .whereType<String>()
        .toSet();
    final matching = updates.where((item) {
      final id = item.transactionId?.trim();
      final terminalWithoutTransaction =
          item.status == PurchaseStatus.pending ||
          item.status == PurchaseStatus.canceled ||
          item.status == PurchaseStatus.error;
      if (terminalWithoutTransaction) return item.productId == expected;
      return id != null &&
          id.isNotEmpty &&
          item.productId == expected &&
          appAccountTokensMatch(context.linkToken, item.appAccountToken) &&
          !persistedTransactionIds.contains(id) &&
          !_handledTransactionIds.contains(id);
    });
    if (matching.isEmpty) return;
    final transaction = matching.last;
    switch (transaction.status) {
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        final id = transaction.transactionId;
        if (id != null && _handledTransactionIds.contains(id)) return;
        completer.complete(transaction);
      case PurchaseStatus.pending:
        completer.completeError(const _StoreKitPending());
      case PurchaseStatus.canceled:
        completer.completeError(const _StoreKitCancelled());
      case PurchaseStatus.error:
        completer.completeError(StateError('storekit_purchase_error'));
    }
  }

  void _failWaitingPurchase(String message) {
    final completer = _purchaseCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(message));
    }
  }

  Future<void> _save(IosPurchaseContext context) async {
    await _contextStore.save(context);
    _purchaseContext = context;
    _diagnostics.log('CONTEXT_PERSISTED', {
      'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
      'state': context.state,
      'currentIndex': context.currentIndex,
    });
    _log(
      'state order=${_short(context.orderId)} value=${context.state} index=${context.currentIndex}',
    );
  }

  Future<void> _finishPaid(IosPurchaseContext context) async {
    if (context.units.any(
      (item) => item.backendAccepted && !item.storeKitCompleted,
    )) {
      _setStatus(
        'Payment is paid and Apple transaction completion will retry.',
      );
      return;
    }
    await _contextStore.clear();
    _diagnostics.log('CONTEXT_CLEARED');
    _purchaseContext = null;
    if (!mounted) return;
    ScaffoldMessenger.of(
      this.context,
    ).showSnackBar(const SnackBar(content: Text('Purchase successful.')));
    _diagnostics.log('IOS_CHECKOUT_ROUTE_POP', {
      'attemptId': _activeAttemptId,
      'reason': 'paid',
    });
    Navigator.of(this.context).pop(true);
  }

  Future<void> _refreshCredits() async {
    _diagnostics.log('CREDIT_REFRESH_STARTED');
    try {
      await MantraService.refreshPurchasedCountsOnlyStrict();
      _diagnostics.log('CREDIT_REFRESH_SUCCEEDED');
    } catch (error) {
      _diagnostics.logError(stage: 'credit_refresh', error: error);
      _diagnostics.log('CREDIT_REFRESH_FAILED', {
        'type': error.runtimeType.toString(),
      });
      rethrow;
    }
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _setError(String value) {
    if (mounted) setState(() => _error = value);
  }

  void _log(String value) {
    if (kDebugMode) debugPrint('STOREKIT_DEBUG $value');
  }

  String _short(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  Widget _buildDiagnosticsPanel() {
    if (kReleaseMode) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.orange.shade300),
          borderRadius: BorderRadius.circular(8),
          color: Colors.orange.shade50,
        ),
        child: ExpansionTile(
          dense: true,
          title: const Text(
            'StoreKit Debug',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 220,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        _diagnostics.entries.isEmpty
                            ? 'No StoreKit diagnostic events yet.'
                            : _diagnostics.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: _diagnostics.entries.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _diagnostics.text),
                                );
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('StoreKit logs copied.'),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy Logs'),
                      ),
                      TextButton.icon(
                        onPressed: _diagnostics.entries.isEmpty
                            ? null
                            : _diagnostics.clear,
                        icon: const Icon(Icons.clear, size: 16),
                        label: const Text('Clear'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_processing,
      child: Scaffold(
        appBar: AppBar(title: const Text('Apple Checkout')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ListView(
                        children: [
                          for (final item in _displayCartProducts)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(item.productName),
                              subtitle: item.quantity > 1
                                  ? Text('Quantity: ${item.quantity}')
                                  : null,
                              trailing: Text(
                                _prices[item.storeProductId]?.formattedPrice ??
                                    '',
                              ),
                            ),
                          const Divider(),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Total',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            trailing: Text(
                              _total,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (_status.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(_status),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          if (!kReleaseMode) _buildDiagnosticsPanel(),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      onPressed:
                          _processing ||
                              _recovering ||
                              _blockedByPriorOrder ||
                              !_allProductsLoaded
                          ? null
                          : _startOrContinueCheckout,
                      child: _processing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text('Purchase with Apple'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

final class _StoreKitCancelled implements Exception {
  const _StoreKitCancelled();
}

final class _StoreKitPending implements Exception {
  const _StoreKitPending();
}

final class _InvalidAppAccountToken implements Exception {
  const _InvalidAppAccountToken();
}
