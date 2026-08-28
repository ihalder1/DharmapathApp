import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/ios_purchase.dart';
import '../models/mantra.dart';
import '../services/ios_purchase_context_store.dart';
import '../services/ios_purchase_abandonment.dart';
import '../services/ios_fail_closed_recovery.dart';
import '../services/ios_purchase_reconciler.dart';
import '../services/ios_storekit_purchase_coordinator.dart';
import '../services/mantra_service.dart';
import '../services/cart_quantity_policy.dart';
import '../services/payment_service.dart';
import '../services/storekit_purchase_service.dart';
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
  static int _nextDiagnosticInstance = 0;
  final _storeKit = StoreKitPurchaseService.instance;
  late final IosPurchaseContextStore _contextStore;
  late final IosPurchaseReconciler _reconciler;
  late final IosFailClosedRecovery _failClosedRecovery;
  late final IosPurchaseAbandonment _abandonment;
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
  bool _preparing = false;
  Future<void>? _preparationFuture;
  bool _processing = false;
  bool _recovering = false;
  bool _blockedByPriorOrder = false;
  final _lifetime = IosStoreKitCheckoutLifetime();
  String? _activeAttemptId;
  String _status = '';
  String? _error;
  late final String _checkoutInstanceId;
  String? _lastBuildDiagnosticSignature;

  @override
  void initState() {
    super.initState();
    _checkoutInstanceId =
        'CHK-${(++_nextDiagnosticInstance).toString().padLeft(4, '0')}';
    WidgetsBinding.instance.addObserver(this);
    _diagnostics = StoreKitDiagnostics(checkoutInstance: _checkoutInstanceId);
    _contextStore = IosPurchaseContextStore(diagnostics: _diagnostics);
    _diagnostics.log('NEW_APPLE_CHECKOUT_SESSION', {
      'separator':
          '============================================================',
      'platform': 'ios',
      'mounted': mounted,
      'rawCartCount': widget.cartItems.length,
      'songIds': widget.cartItems.map((item) => item.songId).toList(),
      'storeProductIds': widget.cartItems
          .map((item) => item.storeProductIdIos)
          .toList(),
    });
    _reconciler = IosPurchaseReconciler(
      contextStore: _contextStore,
      storeKit: _storeKit,
      diagnostics: _diagnostics,
    );
    _failClosedRecovery = IosFailClosedRecovery(_contextStore);
    _abandonment = IosPurchaseAbandonment(
      contextStore: _contextStore,
      unfinishedTransactions: _storeKit.unfinishedTransactions,
      diagnostics: _diagnostics,
    );
    try {
      _status = 'Loading Apple price...';
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
      _logCheckoutState('INIT_STATE_COMPLETE');
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
    _logCheckoutState('DISPOSE');
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
    _diagnostics.log('CHECKOUT_SESSION_END', {
      'separator':
          '============================================================',
    });
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
    _logCheckoutState('LIFECYCLE_${state.name.toUpperCase()}_BEFORE');
    if (state == AppLifecycleState.resumed && !_processing && !_recovering) {
      final current = _purchaseContext;
      if (current != null &&
          isReusableIosPreparedContext(current, _cartProducts)) {
        _diagnostics.log('IOS_ACTIVE_PREPARED_CONTEXT_RETAINED_ON_RESUME');
        _logCheckoutState('LIFECYCLE_RESUMED_AFTER_RETAIN');
        return;
      }
      unawaited(
        _recover().whenComplete(
          () => _logCheckoutState('LIFECYCLE_RESUMED_AFTER_RECOVERY'),
        ),
      );
    }
  }

  Future<void> _initialize() async {
    _logCheckoutState('PRODUCT_QUERY_INITIALIZE_START');
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
      _diagnostics.log('CHECKOUT_PRICES_ASSIGN_BEFORE', {
        'existingKeys': _prices.keys.toList(),
        'incomingKeys': prices.keys.toList(),
      });
      setState(() => _prices = prices);
      _logCheckoutState('CHECKOUT_PRICES_ASSIGN_AFTER');
      await _ensureAggregatePricePrepared();
    } catch (error) {
      _diagnostics.logError(stage: 'store_initialization', error: error);
      if (mounted) {
        setState(() {
          _status = '';
          _error =
              error is FormatException &&
                  error.message == 'ios_aggregate_product_not_found'
              ? 'The Apple price for this checkout is unavailable.'
              : 'The Apple checkout price could not be loaded.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
      _logCheckoutState('PRODUCT_QUERY_INITIALIZE_END');
    }
  }

  Future<void> _recover() async {
    if (_recovering || _processing) return;
    _logCheckoutState('RECONCILIATION_START');
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
      if (isReusableIosPreparedContext(stored, _cartProducts)) {
        _blockedByPriorOrder = false;
        _status = 'Loading Apple price...';
        _diagnostics.log('IOS_PREPARED_CONTEXT_REUSED', {
          'orderId': StoreKitDiagnostics.redactIdentifier(stored.orderId),
          'storeProductId': stored.aggregateStoreProductId,
        });
        return;
      }
      _blockedByPriorOrder = true;
      _status =
          'Your previous Apple purchase is still being verified. A new purchase cannot be started until it is resolved.';
    } catch (error) {
      _diagnostics.logError(stage: 'recovery_local', error: error);
      _blockedByPriorOrder = true;
      _status =
          'Apple purchase recovery could not confirm saved state. A new purchase cannot be started.';
    } finally {
      _recovering = false;
      if (mounted) setState(() {});
      _logCheckoutState('RECONCILIATION_END');
    }
  }

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

  bool get _readyForPurchase =>
      !_loading &&
      !_preparing &&
      !_recovering &&
      !_blockedByPriorOrder &&
      _purchaseContext?.isAggregate == true &&
      _aggregatePrice != null &&
      _error == null;

  Future<void> _ensureAggregatePricePrepared() {
    final running = _preparationFuture;
    if (running != null) return running;
    late final Future<void> future;
    future = _prepareAggregatePrice().whenComplete(() {
      if (identical(_preparationFuture, future)) _preparationFuture = null;
    });
    _preparationFuture = future;
    return future;
  }

  Future<void> _prepareAggregatePrice() async {
    if (_preparing || _blockedByPriorOrder || _aggregatePrice != null) return;
    final currency = _currency;
    if (currency == null) {
      throw StateError('ios_cart_currency_unavailable');
    }
    _preparing = true;
    _logCheckoutState('AGGREGATE_PRICE_PREPARE_START');
    if (mounted) setState(() => _status = 'Loading Apple price...');
    try {
      var active = _purchaseContext;
      if (active == null) {
        _diagnostics.log('IOS_CHECKOUT_PREPARE_START', {
          'distinctSongs': _cartProducts.length,
          'totalUnits': iosCartTotalUnits(_cartProducts),
        });
        _diagnostics.log('IOS_PREPARE_QUANTITIES', {
          'products': iosCartQuantityDiagnostics(_cartProducts),
          'totalUnits': iosCartTotalUnits(_cartProducts),
        });
        final prepared = await _failClosedRecovery.runPrepareIfNoPending(
          () => PaymentService.prepareIosPurchase(
            currency: currency,
            products: _cartProducts,
            diagnostics: _diagnostics,
          ),
        );
        if (!isCanonicalUuid(prepared.linkToken)) {
          throw const _InvalidAppAccountToken();
        }
        final aggregate = requireIosAggregateStoreProduct(
          prepared.storeProducts,
        );
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
        _purchaseContext = active;
        _diagnostics.log('IOS_CHECKOUT_PREPARE_SUCCEEDED', {
          'orderId': StoreKitDiagnostics.redactIdentifier(active.orderId),
        });
        _diagnostics.log('IOS_AGGREGATE_PRODUCT_RECEIVED', {
          'storeProductId': aggregate.storeProductId,
          'backendQuantity': aggregate.quantity,
        });
      }
      if (!active.isAggregate) {
        throw StateError('ios_legacy_context_requires_manual_recovery');
      }
      final storeProductId = active.aggregateStoreProductId;
      _diagnostics.log('IOS_AGGREGATE_PRICE_LOOKUP_START', {
        'storeProductId': storeProductId,
      });
      final resolved = await _storeKit.queryProducts([
        storeProductId,
      ], diagnostics: _diagnostics);
      final aggregatePrice = resolved[storeProductId];
      if (aggregatePrice == null) {
        throw const FormatException('ios_aggregate_product_not_found');
      }
      _diagnostics.log('AGGREGATE_PRICE_ASSIGN_BEFORE', {
        'existingProductId': _aggregatePrice?.productId,
        'incomingProductId': aggregatePrice.productId,
      });
      _aggregatePrice = aggregatePrice;
      _status = '';
      _logCheckoutState('AGGREGATE_PRICE_ASSIGN_AFTER');
      _diagnostics.log('IOS_AGGREGATE_PRICE_READY', {
        'storeProductId': storeProductId,
        'formattedPrice': aggregatePrice.formattedPrice,
        'currencyCode': aggregatePrice.currencyCode,
      });
      _diagnostics.log('IOS_CHECKOUT_READY_FOR_PURCHASE');
    } finally {
      _preparing = false;
      if (mounted) setState(() {});
      _logCheckoutState('AGGREGATE_PRICE_PREPARE_END');
    }
  }

  Future<void> _startOrContinueCheckout() async {
    _logCheckoutState('PURCHASE_BUTTON_TAP');
    if (_processing ||
        _recovering ||
        _blockedByPriorOrder ||
        !_readyForPurchase) {
      return;
    }
    _diagnostics.log('PROCESSING_STATE_CHANGE', {
      'from': _processing,
      'to': true,
    });
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      var checkout = _purchaseContext!;
      if (!checkout.isAggregate) {
        throw StateError('ios_legacy_context_requires_manual_recovery');
      }
      const index = 0;
      final unit = checkout.aggregateUnit;
      final price = _aggregatePrice!;
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
        coordinator.acquire(attemptId: attemptId);
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
          _diagnostics.log('COMPLETE_PURCHASE_BEFORE', {
            'status': transaction.status.name,
            'productId': transaction.productId,
            'transactionId': StoreKitDiagnostics.redactIdentifier(
              transaction.transactionId,
            ),
            'pendingCompletePurchase': transaction.pendingCompletePurchase,
          });
          await _storeKit.complete(transaction);
          _diagnostics.log('COMPLETE_PURCHASE_AFTER', {
            'productId': transaction.productId,
            'transactionId': StoreKitDiagnostics.redactIdentifier(
              transaction.transactionId,
            ),
          });
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
    } on _StoreKitCancelled catch (cancelled) {
      _logCheckoutState('CANCEL_BEFORE');
      if (cancelled.transactionId?.trim().isNotEmpty == true) {
        final saved = _purchaseContext;
        if (saved != null) {
          await _save(
            saved.recordTransaction(
              index: 0,
              transactionId: cancelled.transactionId!.trim(),
            ),
          );
        }
      }
      await _abandonAndReloadIfSafe(
        reason: 'apple_cancelled',
        status: 'Apple purchase was cancelled. Loading a fresh Apple price...',
      );
      _logCheckoutState('CANCEL_AFTER');
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
      _setError(
        'The backend Apple product mapping does not match this cart. No purchase was opened.',
      );
    } catch (error) {
      _logCheckoutState('ERROR_BEFORE');
      if (error is _StoreKitFailure &&
          error.transactionId?.trim().isNotEmpty == true) {
        final saved = _purchaseContext;
        if (saved != null) {
          await _save(
            saved.recordTransaction(
              index: 0,
              transactionId: error.transactionId!.trim(),
            ),
          );
        }
      }
      _diagnostics.logError(stage: 'checkout', error: error);
      final abandoned = await _abandonAndReloadIfSafe(
        reason: 'storekit_error_no_transaction',
        status: 'Reloading Apple checkout...',
      );
      if (!abandoned) {
        _setError(
          'The purchase could not be completed safely. Your order was saved and will be reconciled.',
        );
      }
      _logCheckoutState('ERROR_AFTER');
    } finally {
      _purchaseCompleter = null;
      _waitingForProductId = null;
      if (mounted) setState(() => _processing = false);
      _logCheckoutState('PURCHASE_ATTEMPT_FINALLY');
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
      'purchaseMethod': 'buyConsumable',
      'purchaseParamType': 'PurchaseParam',
      'applicationUsernameSuffix': StoreKitDiagnostics.redactIdentifier(
        appAccountToken,
      ),
    });
    IosStoreKitPurchaseCoordinator.instance.markStoreKitActive(attemptId);
    bool? launched;
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
        'launched': launched,
      });
    }
    if (launched == false && !completer.isCompleted) {
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
        'runtimeType': transaction.runtimeTypeName,
        'transactionDate': transaction.transactionDate,
        'pendingCompletePurchase': transaction.pendingCompletePurchase,
        'verificationSource': transaction.verificationSource,
        'serverVerificationDataPresent':
            transaction.serverVerificationDataPresent,
        'localVerificationDataPresent':
            transaction.localVerificationDataPresent,
        'errorPresent': transaction.errorCode != null,
        'errorCode': transaction.errorCode,
        'errorMessage': transaction.errorMessage,
        'errorDetails': transaction.errorDetails,
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
    _logCheckoutState('PURCHASE_STREAM_MATCHED_${transaction.status.name}');
    switch (transaction.status) {
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        final id = transaction.transactionId;
        if (id != null && _handledTransactionIds.contains(id)) return;
        completer.complete(transaction);
      case PurchaseStatus.pending:
        completer.completeError(const _StoreKitPending());
      case PurchaseStatus.canceled:
        completer.completeError(_StoreKitCancelled(transaction.transactionId));
      case PurchaseStatus.error:
        completer.completeError(_StoreKitFailure(transaction.transactionId));
    }
  }

  void _failWaitingPurchase(String message) {
    final completer = _purchaseCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(message));
    }
  }

  Future<void> _save(IosPurchaseContext context) async {
    _diagnostics.log('CONTEXT_SAVE_BEFORE', _contextFields(context));
    await _contextStore.save(context);
    _purchaseContext = context;
    _diagnostics.log('CONTEXT_PERSISTED', {
      'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
      'state': context.state,
      'currentIndex': context.currentIndex,
      ..._contextFields(context),
    });
  }

  Future<bool> _abandonAndReloadIfSafe({
    required String reason,
    required String status,
  }) async {
    final saved = _purchaseContext;
    if (saved == null) return true;
    final abandoned = await _abandonment.abandonIfSafe(saved, reason: reason);
    if (!abandoned) return false;
    _logCheckoutState('ABANDON_RELOAD_BEFORE_CLEAR_LOCAL_STATE');
    _purchaseContext = null;
    _aggregatePrice = null;
    _error = null;
    _logCheckoutState('ABANDON_RELOAD_AFTER_CLEAR_LOCAL_STATE');
    _setStatus(status);
    try {
      await _ensureAggregatePricePrepared();
    } catch (error) {
      _diagnostics.logError(stage: 'checkout_retry_prepare', error: error);
      _setError('The Apple checkout price could not be reloaded.');
    }
    return true;
  }

  Future<void> _handleBack() async {
    _logCheckoutState('BACK_NAVIGATION_REQUESTED');
    if (_processing) return;
    final preparing = _preparationFuture;
    if (preparing != null) {
      try {
        await preparing;
      } catch (_) {
        // A failed Prepare leaves no transaction-bearing context to protect.
      }
    }
    final saved = _purchaseContext;
    if (saved != null) {
      await _abandonment.abandonIfSafe(saved, reason: 'user_back');
    }
    if (mounted) {
      _diagnostics.log('IOS_CHECKOUT_ROUTE_POP', {'reason': 'user_back'});
      Navigator.of(context).pop();
    }
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

  Map<String, Object?> _contextFields(IosPurchaseContext context) => {
    'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
    'state': context.state,
    'productIds': context.units.map((item) => item.storeProductId).toList(),
    'quantities': context.cartProducts
        .map((item) => '${item.storeProductId}:${item.quantity}')
        .toList(),
    'totalUnits': context.cartProducts.fold<int>(
      0,
      (sum, item) => sum + item.quantity,
    ),
    'linkTokenSuffix': StoreKitDiagnostics.redactIdentifier(context.linkToken),
    'transactionIds': context.units
        .map((item) => StoreKitDiagnostics.redactIdentifier(item.transactionId))
        .toList(),
  };

  Map<String, Object?> _checkoutStateFields() {
    final purchase = _purchaseContext;
    final missing = purchase?.isAggregate == true
        ? <String>[
            if (_aggregatePrice == null) purchase!.aggregateStoreProductId,
          ]
        : _cartProducts
              .map((item) => item.storeProductId)
              .where((id) => !_prices.containsKey(id))
              .toList();
    final buttonEnabled = _readyForPurchase && !_processing;
    return {
      'mounted': mounted,
      'loading': _loading,
      'preparing': _preparing,
      'processing': _processing,
      'purchaseInProgress':
          _purchaseCompleter != null &&
          !(_purchaseCompleter?.isCompleted ?? true),
      'recovering': _recovering,
      'blockedByPriorOrder': _blockedByPriorOrder,
      'productDetailsCount': _prices.length,
      'productDetailsIds': _prices.keys.toList(),
      'aggregateProductId': _aggregatePrice?.productId,
      'priceAvailable': _aggregatePrice != null,
      'missingProductIds': missing,
      'total': _total,
      'status': _status,
      'checkoutError': _error,
      'pendingContextPresent': purchase != null,
      'pendingOrderId': StoreKitDiagnostics.redactIdentifier(purchase?.orderId),
      'pendingProductIds': purchase?.units
          .map((item) => item.storeProductId)
          .toList(),
      'pendingLinkTokenSuffix': StoreKitDiagnostics.redactIdentifier(
        purchase?.linkToken,
      ),
      'waitingForProductId': _waitingForProductId,
      'purchaseButtonEnabled': buttonEnabled,
      'purchaseButtonDisabledReasons': <String>[
        if (_loading) 'loading',
        if (_preparing) 'preparing',
        if (_recovering) 'recovering',
        if (_blockedByPriorOrder) 'blocked_by_prior_order',
        if (purchase?.isAggregate != true) 'aggregate_context_missing',
        if (_aggregatePrice == null) 'aggregate_price_missing',
        if (_error != null) 'checkout_error',
        if (_processing) 'processing',
      ],
    };
  }

  void _logCheckoutState(String event) {
    _diagnostics.log(event, _checkoutStateFields());
  }

  void _logBuildStateIfChanged() {
    final signature = [
      _loading,
      _preparing,
      _processing,
      _recovering,
      _blockedByPriorOrder,
      _prices.keys.join(','),
      _aggregatePrice?.productId,
      _error,
      _readyForPurchase,
    ].join('|');
    if (_lastBuildDiagnosticSignature == signature) return;
    _lastBuildDiagnosticSignature = signature;
    _logCheckoutState(
      _aggregatePrice == null && !_loading
          ? 'BUILD_PRICE_UNAVAILABLE'
          : 'BUILD_STATE_CHANGED',
    );
  }

  @override
  Widget build(BuildContext context) {
    _logBuildStateIfChanged();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Apple Checkout')),
        body: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Loading Apple price...'),
                  ],
                ),
              )
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
                        ],
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _readyForPurchase && !_processing
                          ? _startOrContinueCheckout
                          : null,
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
  const _StoreKitCancelled(this.transactionId);
  final String? transactionId;
}

final class _StoreKitFailure implements Exception {
  const _StoreKitFailure(this.transactionId);
  final String? transactionId;
}

final class _StoreKitPending implements Exception {
  const _StoreKitPending();
}

final class _InvalidAppAccountToken implements Exception {
  const _InvalidAppAccountToken();
}
