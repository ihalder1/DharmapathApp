import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:intl/intl.dart';

import '../models/ios_purchase.dart';
import '../models/mantra.dart';
import '../services/ios_purchase_context_store.dart';
import '../services/ios_fail_closed_recovery.dart';
import '../services/ios_purchase_reconciler.dart';
import '../services/mantra_service.dart';
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
  IosPurchaseContext? _purchaseContext;
  Completer<StoreKitTransaction>? _purchaseCompleter;
  String? _waitingForProductId;
  final Set<String> _handledTransactionIds = {};
  bool _loading = true;
  bool _processing = false;
  bool _recovering = false;
  bool _blockedByPriorOrder = false;
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
      _diagnostics.log('CHECKOUT_SESSION_STARTED', {
        'platform': 'ios',
        'cartUnits': widget.cartItems.length,
      });
    } on FormatException {
      _cartProducts = const [];
      _error = 'One or more mantras are not configured for Apple purchases.';
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
    WidgetsBinding.instance.removeObserver(this);
    _purchaseSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
    final purchaseContext = _purchaseContext;
    if (purchaseContext == null) return _cartProducts;
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
          final cartItem = _cartProducts.firstWhere(
            (item) => item.storeProductId == entry.key,
          );
          return IosCartProduct(
            internalProductId: cartItem.internalProductId,
            productName: cartItem.productName,
            storeProductId: cartItem.storeProductId,
            quantity: entry.value,
          );
        })
        .toList(growable: false);
  }

  String get _total {
    String? currency;
    var amount = 0.0;
    for (final item in _displayCartProducts) {
      final price = _prices[item.storeProductId];
      if (price == null ||
          (currency != null && currency != price.currencyCode)) {
        return 'Price unavailable';
      }
      currency = price.currencyCode;
      amount += price.rawPrice * item.quantity;
    }
    if (currency == null) return 'Price unavailable';
    return NumberFormat.currency(name: currency).format(amount);
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
        for (var cartIndex = 0; cartIndex < _cartProducts.length; cartIndex++) {
          final cartItem = _cartProducts[cartIndex];
          final backendMatches = prepared.storeProducts.where(
            (backend) =>
                backend.internalProductId == cartItem.internalProductId ||
                backend.storeProductId == cartItem.storeProductId,
          );
          _diagnostics.logMapping(
            internalProductId: cartItem.internalProductId,
            metadataStoreProductId: cartItem.storeProductId,
            backendStoreProductId: backendMatches.isNotEmpty
                ? backendMatches.first.storeProductId
                : cartIndex < prepared.storeProducts.length
                ? prepared.storeProducts[cartIndex].storeProductId
                : null,
          );
        }
        validateIosPreparedProducts(
          cart: _cartProducts,
          prepared: prepared.storeProducts,
        );
        final resolved = await _storeKit.queryProducts(
          prepared.storeProducts.map((item) => item.storeProductId),
          diagnostics: _diagnostics,
        );
        if (resolved.length != prepared.storeProducts.length) {
          throw const FormatException(
            'A prepared Apple product is unavailable',
          );
        }
        final now = DateTime.now().toUtc();
        active = IosPurchaseContext(
          orderId: prepared.orderId,
          linkToken: prepared.linkToken,
          units: expandIosPreparedUnits(
            prepared: prepared.storeProducts,
            cart: _cartProducts,
          ),
          currentIndex: 0,
          state: 'prepared',
          createdAt: now,
          updatedAt: now,
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
      for (var index = 0; index < checkout.units.length; index++) {
        if (checkout.units[index].backendAccepted) continue;
        final unit = checkout.units[index];
        final price = _prices[unit.storeProductId];
        if (price == null) throw StateError('storekit_product_unavailable');
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
        final transaction = await _launchAndWait(
          product: price.details,
          appAccountToken: checkout.linkToken,
        );
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
        _diagnostics.logPurchase(
          event: 'APPLE_PURCHASE_RECEIVED',
          storeProductId: unit.storeProductId,
          status: transaction.status.name,
          transactionId: transactionId,
        );

        final verification = await PaymentService.verifyIosPurchase(
          orderId: checkout.orderId,
          transactionId: transactionId,
          storeProductId: unit.storeProductId,
          diagnostics: _diagnostics,
        );
        if (!verification.accepted) {
          throw StateError('backend_did_not_accept_storekit_transaction');
        }
        checkout = checkout.acceptTransaction(
          index: index,
          backendStatus: verification.status,
        );
        await _save(checkout);
        await _refreshCredits();
        await MantraService.consumeIosCartProductUnits(unit.storeProductId, 1);
        await _storeKit.complete(transaction);
        _diagnostics.logPurchase(
          event: 'STOREKIT_COMPLETED',
          storeProductId: unit.storeProductId,
          status: transaction.status.name,
          transactionId: transactionId,
        );
        checkout = checkout.completeTransaction(index);
        await _save(checkout);
        _handledTransactionIds.add(transactionId);

        if (verification.paid) {
          checkout = checkout.copyWith(state: 'paid');
          await _save(checkout);
          await _finishPaid(checkout);
          return;
        }
        _setStatus('Purchase accepted. Continuing with the next mantra...');
      }
      _setStatus(
        'Apple purchases are complete; waiting for the order to be paid.',
      );
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
        await _save(
          saved.copyWith(
            state: saved.acceptedStoreProductIds.isEmpty
                ? 'cancelled'
                : 'partially_paid',
          ),
        );
      }
      _setStatus(
        _purchaseContext?.acceptedStoreProductIds.isNotEmpty == true
            ? 'Part of your order was purchased. The remaining mantra stays in your cart.'
            : 'Apple purchase was cancelled. You can try again when ready.',
      );
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
    }
  }

  Future<StoreKitTransaction> _launchAndWait({
    required ProductDetails product,
    required String appAccountToken,
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
    final launched = await _storeKit.buyConsumable(
      product: product,
      appAccountToken: appAccountToken,
    );
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
    await _refreshCredits();
    await MantraService.removeIosCartProductsByStoreIds(
      context.acceptedStoreProductIds,
    );
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
                                    'Price unavailable',
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
                          : Text(
                              _purchaseContext?.state == 'partially_paid'
                                  ? 'Continue Remaining Purchase'
                                  : 'Purchase with Apple',
                            ),
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
