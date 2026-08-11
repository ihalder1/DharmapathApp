import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/android_purchase.dart';
import '../models/mantra.dart';
import '../services/android_purchase_context_store.dart';
import '../services/mantra_service.dart';
import '../services/payment_service.dart';
import '../services/play_billing_service.dart';
import '../services/play_billing_diagnostics.dart';

class GooglePlayCheckoutScreen extends StatefulWidget {
  const GooglePlayCheckoutScreen({super.key, required this.cartItems});

  /// Frozen checkout snapshot. HomeScreen supplies one entry per requested unit.
  final List<Mantra> cartItems;

  @override
  State<GooglePlayCheckoutScreen> createState() =>
      _GooglePlayCheckoutScreenState();
}

class _GooglePlayCheckoutScreenState extends State<GooglePlayCheckoutScreen>
    with WidgetsBindingObserver {
  final _contextStore = AndroidPurchaseContextStore();
  Map<String, PlayProductPrice> _prices = const {};
  late final List<AndroidCartProduct> _cartProducts;
  StreamSubscription<PlayPurchaseUpdate>? _purchaseSubscription;
  Completer<_PlayStepResult>? _purchaseCompleter;
  String? _waitingForStoreProductId;
  AndroidPurchaseContext? _purchaseContext;
  bool _loading = true;
  bool _processing = false;
  bool _recovering = false;
  bool _blockedByPriorOrder = false;
  String _status = '';
  String? _error;
  String? _processingStoreProductId;
  final Set<String> _verifyingTokens = {};
  String _debugStage = 'INITIALIZE';
  String? _debugProduct;
  String? _debugOrderId;
  String? _debugContextState;
  int? _debugCurrentIndex;
  int? _debugHttpStatus;
  String? _debugBackendStatus;
  bool? _debugAccepted;
  bool? _debugPaid;
  int? _debugBillingResponseCode;
  bool? _debugConsumedCompleted;
  bool? _debugAlreadyConsumed;
  String? _debugErrorType;
  String? _debugErrorMessage;
  final List<String> _debugEvents = [];

  bool get _showTemporaryDebugPanel =>
      temporaryPlayBillingUiDebug &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cartProducts = aggregateAndroidCart(widget.cartItems);
    _tempDebug(
      'INITIALIZE',
      detail:
          'cart=${_cartProducts.map((item) => item.storeProductId).toList()}',
    );
    playBillingLog(
      'checkout init cartProducts=${_cartProducts.map((item) => item.storeProductId).toList()}',
    );
    _purchaseSubscription = PlayBillingService.purchaseUpdates.listen(
      _handlePurchaseUpdate,
    );
    _initialize();
  }

  void _tempDebug(
    String stage, {
    String? product,
    String? orderId,
    String? contextState,
    int? currentIndex,
    int? httpStatus,
    String? backendStatus,
    bool? accepted,
    bool? paid,
    int? billingResponseCode,
    bool? consumedCompleted,
    bool? alreadyConsumed,
    Object? error,
    String? detail,
  }) {
    if (!_showTemporaryDebugPanel) return;
    try {
      final safeDetail = detail == null
          ? null
          : sanitizePlayBillingDiagnostic(detail);
      final safeError = error == null
          ? null
          : sanitizePlayBillingDiagnostic(error);
      final parts = <String>[
        stage,
        if (product != null) 'product=$product',
        if (orderId != null) 'order=$orderId',
        if (contextState != null) 'state=$contextState',
        if (currentIndex != null) 'index=$currentIndex',
        if (httpStatus != null) 'http=$httpStatus',
        if (backendStatus != null && backendStatus.isNotEmpty)
          'backend=$backendStatus',
        if (billingResponseCode != null) 'billing=$billingResponseCode',
        if (consumedCompleted != null) 'complete=$consumedCompleted',
        if (safeDetail != null && safeDetail.isNotEmpty) safeDetail,
      ];
      void update() {
        _debugStage = stage;
        _debugProduct = product ?? _debugProduct;
        _debugOrderId = orderId ?? _debugOrderId;
        _debugContextState = contextState ?? _debugContextState;
        _debugCurrentIndex = currentIndex ?? _debugCurrentIndex;
        _debugHttpStatus = httpStatus;
        _debugBackendStatus = backendStatus;
        _debugAccepted = accepted;
        _debugPaid = paid;
        _debugBillingResponseCode = billingResponseCode;
        _debugConsumedCompleted = consumedCompleted;
        _debugAlreadyConsumed = alreadyConsumed;
        _debugErrorType = error?.runtimeType.toString();
        _debugErrorMessage = safeError;
        _debugEvents.add(parts.join(' '));
        if (_debugEvents.length > 20) _debugEvents.removeAt(0);
      }

      if (mounted) {
        setState(update);
      } else {
        update();
      }
      playBillingLog(parts.join(' '));
    } catch (_) {
      // Diagnostics must never affect checkout behavior.
    }
  }

  void _handlePaymentDiagnostic(AndroidPaymentDiagnostic diagnostic) {
    final stage = switch ((diagnostic.operation, diagnostic.stage)) {
      ('prepare', 'http_success') => 'PREPARE_HTTP',
      ('prepare', 'parsed') => 'PREPARE_SUCCESS',
      ('prepare', 'http_failure') => 'PREPARE_FAILED',
      ('prepare', 'parse_failure') => 'PREPARE_PARSE_FAILED',
      ('verify', 'http_success') => 'VERIFY_HTTP',
      ('verify', 'parsed') => 'VERIFY_RESULT',
      ('verify', 'http_failure') => 'VERIFY_FAILED',
      ('verify', 'parse_failure') => 'VERIFY_PARSE_FAILED',
      ('order_lookup', 'parsed') => 'ORDER_LOOKUP',
      ('order_lookup', 'http_failure') => 'ORDER_LOOKUP_FAILED',
      _ => 'PAYMENT_DIAGNOSTIC',
    };
    _tempDebug(
      stage,
      orderId: diagnostic.orderId,
      httpStatus: diagnostic.httpStatus,
      backendStatus: diagnostic.backendStatus,
      accepted: diagnostic.accepted,
      paid: diagnostic.paid,
      error: diagnostic.errorType,
      detail: [
        if (diagnostic.safeCode != null) 'code=${diagnostic.safeCode}',
        if (diagnostic.safeMessage != null) 'message=${diagnostic.safeMessage}',
        if (diagnostic.storeProductIds.isNotEmpty)
          'products=${diagnostic.storeProductIds}',
        if (diagnostic.linkTokenPresent != null)
          'linkTokenPresent=${diagnostic.linkTokenPresent}',
      ].join(' '),
    );
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
      _recoverPurchase();
    }
  }

  Future<void> _initialize() async {
    final ids = _cartProducts.map((item) => item.storeProductId).toSet();
    try {
      _tempDebug('BILLING_CONNECT');
      await PlayBillingService.initialize();
      _tempDebug('BILLING_READY');
      _tempDebug('QUERY_PRODUCTS', detail: 'products=${ids.toList()}');
      final prices = await PlayBillingService.queryProducts(ids);
      _tempDebug(
        'PRODUCTS_LOADED',
        detail: 'products=${prices.keys.toList()} count=${prices.length}',
      );
      for (final missing in ids.difference(prices.keys.toSet())) {
        _tempDebug('PRODUCT_MISSING', product: missing);
      }
      if (!mounted) return;
      setState(() {
        _prices = prices;
      });
      await _recoverPurchase();
      if (mounted) setState(() => _loading = false);
    } on PlatformException catch (error) {
      _tempDebug(
        'BILLING_INIT_FAILED',
        error: error,
        detail: 'code=${error.code}',
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.code == 'billing_unavailable'
            ? 'Google Play Billing is unavailable on this device.'
            : 'Google Play products could not be loaded.';
      });
    } catch (error) {
      _tempDebug('BILLING_INIT_FAILED', error: error);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Google Play checkout could not be initialized.';
      });
    }
  }

  String? get _currency {
    final currencies = _cartProducts
        .map((item) => _prices[item.storeProductId]?.currencyCode)
        .whereType<String>()
        .toSet();
    return currencies.length == 1 ? currencies.single : null;
  }

  int? get _totalMicros => googlePlayCartTotalMicros(_cartProducts, _prices);

  String get _total {
    final currency = _currency;
    final micros = _totalMicros;
    if (currency == null || micros == null) return 'Price unavailable';
    return NumberFormat.currency(name: currency).format(micros / 1000000);
  }

  bool get _allLoaded {
    final mappedUnits = _cartProducts.fold<int>(
      0,
      (sum, product) => sum + product.quantity,
    );
    return _cartProducts.isNotEmpty &&
        mappedUnits == widget.cartItems.length &&
        _currency != null &&
        _totalMicros != null &&
        _cartProducts.every((item) => _prices.containsKey(item.storeProductId));
  }

  Future<void> _startOrContinueCheckout() async {
    if (_processing || _recovering || _blockedByPriorOrder || !_allLoaded) {
      return;
    }
    setState(() {
      _processing = true;
      _error = null;
    });
    _tempDebug(
      'CHECKOUT_START',
      contextState: _purchaseContext?.state,
      currentIndex: _purchaseContext?.currentIndex,
      detail:
          'cart=${_cartProducts.map((item) => item.storeProductId).toList()} currency=${_currency ?? 'unknown'}',
    );
    try {
      var context = _purchaseContext;
      if (context == null) {
        _setStatus('Preparing purchase...');
        PlayBillingService.debug('preparing backend order');
        playBillingLog(
          'prepare cartProducts=${_cartProducts.map((item) => item.storeProductId).toList()}',
        );
        _tempDebug(
          'PREPARE_REQUEST',
          detail:
              'currency=${_currency!} products=${_cartProducts.map((item) => '${item.storeProductId} x${item.quantity}').toList()}',
        );
        final prepared = await PaymentService.prepareAndroidPurchase(
          currency: _currency!,
          products: _cartProducts,
          onDiagnostic: _handlePaymentDiagnostic,
        );
        final expected = _cartProducts
            .map((item) => '${item.storeProductId} x${item.quantity}')
            .toList();
        final actual = prepared.storeProducts
            .map((item) => '${item.storeProductId} x${item.quantity}')
            .toList();
        _tempDebug(
          'PREPARE_MAPPING_VALIDATION',
          orderId: prepared.orderId,
          detail: 'expected=$expected actual=$actual',
        );
        try {
          _validatePreparedProducts(prepared.storeProducts);
          _tempDebug('PREPARE_MAPPING_OK', orderId: prepared.orderId);
        } catch (error) {
          _tempDebug(
            'PREPARE_MAPPING_FAILED',
            orderId: prepared.orderId,
            error: error,
            detail: 'expected=$expected actual=$actual',
          );
          rethrow;
        }
        playBillingLog(
          'prepared order=${prepared.orderId} products=${prepared.storeProducts.map((item) => item.storeProductId).toList()}',
        );
        context = AndroidPurchaseContext(
          orderId: prepared.orderId,
          linkToken: prepared.linkToken,
          products: prepared.storeProducts,
          verifiedStoreProductIds: const {},
          currentIndex: 0,
          state: 'prepared',
          createdAt: DateTime.now().toUtc(),
        );
        await _contextStore.save(context);
        _purchaseContext = context;
        _tempDebug(
          'CONTEXT_SAVED',
          orderId: context.orderId,
          contextState: context.state,
          currentIndex: context.currentIndex,
          detail: 'verified=${context.verifiedStoreProductIds.toList()}',
        );
        PlayBillingService.debug('backend order prepared');
      } else if (context.state == 'pending' ||
          context.state == 'verified_pending_consumption') {
        await _reconcileStoredContext(context, matchesCurrentCart: true);
        context = _purchaseContext;
        if (context == null ||
            context.state == 'pending' ||
            context.state == 'verified_pending_consumption') {
          return;
        }
      }

      if (!context.matchesCart(_cartProducts)) {
        throw const _CheckoutSafetyError();
      }

      playBillingLog(
        'sequence order=${context.orderId} active=${context.storeProductIds.toList()} '
        'visible=${_cartProducts.map((item) => item.storeProductId).toList()}',
      );
      await _runPurchaseSequence(context);
    } on _CheckoutCancelled {
      _setError('Payment was cancelled. You can try again when ready.');
    } on _CheckoutPending {
      _setStatus(
        'Payment is pending. Your mantra credits will be available after '
        'Google Play confirms the payment.',
      );
    } on _CheckoutSafetyError {
      _setError(
        'This order no longer matches the displayed cart. Google Play was not opened.',
      );
    } on _ConsumptionPending {
      _setStatus(
        'Payment was verified and is still being finalized with Google Play. '
        'Your saved order will retry automatically.',
      );
    } on _PriorOrderUnresolved {
      _blockedByPriorOrder = true;
      _setError(
        'An earlier Google Play purchase is still being resolved. Please '
        'complete or resolve it before starting this order.',
      );
    } on PlatformException catch (error) {
      _setError(
        error.code == 'billing_unavailable'
            ? 'Google Play Billing is unavailable right now.'
            : 'Google Play could not complete this payment. Please try again.',
      );
    } catch (error, stackTrace) {
      final active = _purchaseContext;
      playBillingLog(
        'checkout exception type=${error.runtimeType} '
        'message=${sanitizePlayBillingDiagnostic(error)} '
        'hasContext=${active != null} state=${active?.state ?? 'none'} '
        'currentIndex=${active?.currentIndex ?? -1} '
        'product=${_processingStoreProductId ?? 'unknown'} '
        'order=${active?.orderId ?? 'none'}',
      );
      _tempDebug(
        'UNHANDLED_CHECKOUT_ERROR',
        product: _processingStoreProductId,
        orderId: active?.orderId,
        contextState: active?.state,
        currentIndex: active?.currentIndex,
        error: error,
        detail: 'previousStage=$_debugStage',
      );
      if (playBillingDiagnostics) {
        debugPrintStack(
          label: 'PLAY_BILLING_DEBUG checkout stack',
          stackTrace: stackTrace,
        );
      }
      _setError(
        'We could not complete the payment safely. Your order has been saved '
        'and will be checked again.',
      );
    } finally {
      _processingStoreProductId = null;
      if (mounted) setState(() => _processing = false);
    }
  }

  void _validatePreparedProducts(List<PreparedStoreProduct> prepared) {
    final expected = {
      for (final item in _cartProducts) item.storeProductId: item.quantity,
    };
    final actual = {
      for (final item in prepared) item.storeProductId: item.quantity,
    };
    if (expected.length != actual.length ||
        expected.entries.any((entry) => actual[entry.key] != entry.value)) {
      throw const FormatException(
        'Backend store-product mapping does not match the cart',
      );
    }
  }

  Future<void> _runPurchaseSequence(AndroidPurchaseContext context) async {
    var active = context;
    for (
      var index = active.currentIndex;
      index < active.products.length;
      index++
    ) {
      final product = active.products[index];
      _processingStoreProductId = product.storeProductId;
      if (active.verifiedStoreProductIds.contains(product.storeProductId)) {
        continue;
      }
      _setStatus(
        'Processing item ${index + 1} of ${active.products.length}...',
      );
      _tempDebug(
        'PROCESS_ITEM ${index + 1}/${active.products.length}',
        product: product.storeProductId,
        orderId: active.orderId,
        contextState: active.state,
        currentIndex: index,
      );
      PlayBillingService.debug(
        'processing product ${index + 1} of ${active.products.length}',
      );
      active = active.copyWith(currentIndex: index, state: 'opening_play');
      await _saveContext(active);

      try {
        _tempDebug(
          'LAUNCH_VALIDATE',
          product: product.storeProductId,
          orderId: active.orderId,
          contextState: active.state,
          currentIndex: index,
          detail:
              'visible=${_cartProducts.map((item) => item.storeProductId).toList()}',
        );
        validatePlayLaunch(
          context: active,
          visibleCart: _cartProducts,
          selectedProduct: product,
          selectedIndex: index,
        );
        playBillingLog(
          'launch validation order=${active.orderId} '
          'product=${product.storeProductId} valid=true',
        );
        _tempDebug(
          'LAUNCH_VALID',
          product: product.storeProductId,
          orderId: active.orderId,
          contextState: active.state,
          currentIndex: index,
        );
      } catch (_) {
        playBillingLog(
          'launch validation order=${active.orderId} '
          'product=${product.storeProductId} valid=false',
        );
        _tempDebug(
          'LAUNCH_BLOCKED',
          product: product.storeProductId,
          orderId: active.orderId,
          contextState: active.state,
          currentIndex: index,
        );
        active = active.copyWith(state: 'safety_blocked');
        await _saveContext(active);
        throw const _CheckoutSafetyError();
      }

      final result = await _launchAndWait(active, product);
      if (result.pending) {
        active = active.copyWith(state: 'pending');
        await _saveContext(active);
        throw const _CheckoutPending();
      }
      final purchase = result.purchase!;
      final verification = await _verifyPurchase(active, product, purchase);
      final verified = {
        ...active.verifiedStoreProductIds,
        product.storeProductId,
      };
      active = active.copyWith(
        verifiedStoreProductIds: verified,
        currentIndex: index,
        state: 'verified_pending_consumption',
      );
      _tempDebug(
        'VERIFIED_PERSIST',
        product: product.storeProductId,
        orderId: active.orderId,
        contextState: active.state,
        currentIndex: active.currentIndex,
      );
      await _saveContext(active);
      _tempDebug(
        'VERIFIED_PERSISTED',
        product: product.storeProductId,
        orderId: active.orderId,
        contextState: active.state,
        currentIndex: active.currentIndex,
      );
      playBillingLog(
        'verification statePersisted product=${product.storeProductId} '
        'state=${active.state} currentIndex=${active.currentIndex}',
      );

      final consumed = await _consumeWithDiagnostics(
        context: active,
        productId: product.storeProductId,
        purchaseToken: purchase.purchaseToken,
      );
      if (!consumed.completed) {
        _tempDebug(
          'CONSUME_FAILED',
          product: product.storeProductId,
          billingResponseCode: consumed.responseCode,
          consumedCompleted: consumed.completed,
          alreadyConsumed: consumed.alreadyConsumed,
          error: consumed.safeDebugMessage,
        );
        throw const _ConsumptionPending();
      }
      _tempDebug(
        'CONSUME_COMPLETE',
        product: product.storeProductId,
        billingResponseCode: consumed.responseCode,
        consumedCompleted: consumed.completed,
        alreadyConsumed: consumed.alreadyConsumed,
      );
      active = active.copyWith(
        currentIndex: index + 1,
        state: verification.paid ? 'paid' : 'partially_paid',
      );
      await _saveContext(active);
      _tempDebug(
        'CONTEXT_ADVANCE',
        product: product.storeProductId,
        orderId: active.orderId,
        contextState: active.state,
        currentIndex: active.currentIndex,
      );
      playBillingLog(
        'consume stateAdvanced product=${product.storeProductId} '
        'state=${active.state} currentIndex=${active.currentIndex}',
      );

      if (verification.paid) {
        await _completePaidOrder(active, removeMatchingCartItems: true);
        return;
      }
    }

    final order = await PaymentService.getAndroidPurchaseOrder(
      active.orderId,
      onDiagnostic: _handlePaymentDiagnostic,
    );
    if (order.paid) {
      await _completePaidOrder(active, removeMatchingCartItems: true);
    } else {
      _setStatus(
        'Payment received. Waiting for the order to finish processing.',
      );
    }
  }

  Future<_PlayStepResult> _launchAndWait(
    AndroidPurchaseContext context,
    PreparedStoreProduct product,
  ) async {
    final completer = Completer<_PlayStepResult>();
    _purchaseCompleter = completer;
    _waitingForStoreProductId = product.storeProductId;
    _setStatus('Opening Google Play...');
    _tempDebug(
      'PLAY_LAUNCH_REQUEST',
      product: product.storeProductId,
      orderId: context.orderId,
      contextState: context.state,
      currentIndex: context.currentIndex,
      detail: 'quantity=${product.quantity}',
    );
    final launch = await PlayBillingService.launchProductPurchase(
      productId: product.storeProductId,
      quantity: product.quantity,
      obfuscatedAccountId: context.linkToken,
    );
    final responseCode = launch['responseCode'] as int? ?? -1;
    _tempDebug(
      'PLAY_LAUNCH_RESPONSE',
      product: product.storeProductId,
      billingResponseCode: responseCode,
    );
    if (responseCode == 7) {
      _purchaseCompleter = null;
      _waitingForStoreProductId = null;
      playBillingLog(
        'launch item-already-owned order=${context.orderId} '
        'product=${product.storeProductId}',
      );
      return _outstandingResultForProduct(context, product);
    }
    if (responseCode != 0) {
      _purchaseCompleter = null;
      _waitingForStoreProductId = null;
      throw PlatformException(code: 'billing_launch_failed');
    }
    return completer.future.timeout(const Duration(minutes: 10));
  }

  Future<_PlayStepResult> _outstandingResultForProduct(
    AndroidPurchaseContext context,
    PreparedStoreProduct product,
  ) async {
    final purchases = await _queryOutstandingWithDiagnostics();
    _logOutstanding(purchases);
    final matching = purchases.where(
      (purchase) =>
          purchase.products.contains(product.storeProductId) &&
          (purchase.obfuscatedAccountId == null ||
              purchase.obfuscatedAccountId == context.linkToken),
    );
    if (matching.isEmpty) throw const _PriorOrderUnresolved();
    final purchase = matching.first;
    if (purchase.isPending) return const _PlayStepResult.pending();
    if (purchase.isPurchased && purchase.purchaseToken.isNotEmpty) {
      return _PlayStepResult.purchased(purchase);
    }
    throw const _PriorOrderUnresolved();
  }

  void _handlePurchaseUpdate(PlayPurchaseUpdate update) {
    _tempDebug(
      'PURCHASE_UPDATE',
      billingResponseCode: update.responseCode,
      detail:
          'purchases=${update.purchases.map((purchase) => {'products': purchase.products, 'state': _purchaseStateName(purchase.purchaseState), 'ack': purchase.isAcknowledged}).toList()}',
    );
    final completer = _purchaseCompleter;
    final storeId = _waitingForStoreProductId;
    if (completer == null || completer.isCompleted || storeId == null) return;
    if (update.userCancelled) {
      completer.completeError(const _CheckoutCancelled());
      return;
    }
    final matching = update.purchases.where(
      (purchase) => purchase.products.contains(storeId),
    );
    if (matching.isEmpty) {
      if (update.responseCode != 0) {
        completer.completeError(PlatformException(code: 'purchase_failed'));
      }
      return;
    }
    final purchase = matching.first;
    if (purchase.isPending) {
      PlayBillingService.debug('purchase state=PENDING product=$storeId');
      completer.complete(const _PlayStepResult.pending());
    } else if (purchase.isPurchased && purchase.purchaseToken.isNotEmpty) {
      PlayBillingService.debug('purchase state=PURCHASED product=$storeId');
      completer.complete(_PlayStepResult.purchased(purchase));
    }
    _purchaseCompleter = null;
    _waitingForStoreProductId = null;
  }

  String _purchaseStateName(int state) => switch (state) {
    1 => 'PURCHASED',
    2 => 'PENDING',
    _ => 'UNSPECIFIED',
  };

  Future<PurchaseVerification> _verifyPurchase(
    AndroidPurchaseContext context,
    PreparedStoreProduct product,
    PlayPurchase purchase,
  ) async {
    if (!context.storeProductIds.contains(product.storeProductId) ||
        !purchase.products.contains(product.storeProductId)) {
      throw const _CheckoutSafetyError();
    }
    if (!_verifyingTokens.add(purchase.purchaseToken)) {
      throw StateError('Purchase verification is already in progress');
    }
    playBillingLog('verification start product=${product.storeProductId}');
    _tempDebug(
      'VERIFY_REQUEST',
      product: product.storeProductId,
      orderId: context.orderId,
      contextState: context.state,
      currentIndex: context.currentIndex,
    );
    try {
      _setStatus('Verifying purchase...');
      PlayBillingService.debug(
        'verifying purchase product=${product.storeProductId}',
      );
      final result = await PaymentService.verifyAndroidPurchase(
        orderId: context.orderId,
        purchaseToken: purchase.purchaseToken,
        storeProductId: product.storeProductId,
        onDiagnostic: _handlePaymentDiagnostic,
      );
      PlayBillingService.debug('backend verification status=${result.status}');
      if (!result.accepted) {
        _tempDebug(
          'VERIFY_REJECTED',
          product: product.storeProductId,
          orderId: context.orderId,
          backendStatus: result.status,
          accepted: result.accepted,
          paid: result.paid,
        );
        playBillingLog(
          'verification rejected product=${product.storeProductId} '
          'status=${result.status}',
        );
        throw StateError('Backend did not accept purchase verification');
      }
      playBillingLog(
        'verification accepted product=${product.storeProductId} '
        'status=${result.status}',
      );
      return result;
    } catch (error) {
      playBillingLog(
        'verification exception product=${product.storeProductId} '
        'type=${error.runtimeType}',
      );
      rethrow;
    } finally {
      _verifyingTokens.remove(purchase.purchaseToken);
    }
  }

  Future<void> _recoverPurchase() async {
    if (_processing || _recovering) return;
    _recovering = true;
    if (mounted) setState(() {});
    try {
      final stored = await _contextStore.load();
      if (stored == null || !mounted) {
        _tempDebug('RECOVERY_NONE');
        _blockedByPriorOrder = false;
        return;
      }
      final matchesCurrentCart = stored.matchesCart(_cartProducts);
      _tempDebug(
        'RECOVERY_CONTEXT',
        orderId: stored.orderId,
        contextState: stored.state,
        currentIndex: stored.currentIndex,
        detail:
            'products=${stored.storeProductIds.toList()} verified=${stored.verifiedStoreProductIds.toList()} matchesCart=$matchesCurrentCart',
      );
      if (!matchesCurrentCart) {
        _tempDebug(
          'RECOVERY_DIFFERENT_CART',
          orderId: stored.orderId,
          contextState: stored.state,
          currentIndex: stored.currentIndex,
        );
      }
      playBillingLog(
        'stored context order=${stored.orderId} products=${stored.storeProductIds.toList()} '
        'state=${stored.state} index=${stored.currentIndex} '
        'matchesCurrentCart=$matchesCurrentCart',
      );
      if (matchesCurrentCart) {
        _purchaseContext = stored;
        _blockedByPriorOrder = false;
      } else {
        _purchaseContext = null;
        _blockedByPriorOrder = true;
      }

      final resolved = await _reconcileStoredContext(
        stored,
        matchesCurrentCart: matchesCurrentCart,
      );
      if (!matchesCurrentCart) {
        _blockedByPriorOrder = !resolved;
        if (resolved) {
          _setStatus('Earlier Google Play order resolved. You may continue.');
        } else {
          _setError(
            'An earlier Google Play purchase is still being resolved. Please '
            'complete or resolve it before starting this order.',
          );
        }
      }
    } finally {
      _recovering = false;
      if (mounted) setState(() {});
    }
  }

  Future<bool> _reconcileStoredContext(
    AndroidPurchaseContext stored, {
    required bool matchesCurrentCart,
  }) async {
    try {
      await PlayBillingService.initialize();
      playBillingLog(
        'reconciliation start order=${stored.orderId} '
        'products=${stored.storeProductIds.toList()}',
      );
      final order = await PaymentService.getAndroidPurchaseOrder(
        stored.orderId,
        onDiagnostic: _handlePaymentDiagnostic,
      );
      playBillingLog(
        'reconciliation order=${stored.orderId} backendStatus=${order.status}',
      );
      if (order.paid) {
        _tempDebug('ORDER_PAID', orderId: stored.orderId);
        final consumptionComplete = await _finishPaidOrderConsumption(stored);
        if (!consumptionComplete) return false;
        await _completePaidOrder(
          stored,
          removeMatchingCartItems: matchesCurrentCart,
          closeCheckout: matchesCurrentCart,
        );
        return true;
      }
      if (order.terminal) {
        _tempDebug(
          'RECOVERY_TERMINAL',
          orderId: stored.orderId,
          backendStatus: order.status,
        );
        await _contextStore.clear();
        if (matchesCurrentCart) _purchaseContext = null;
        return true;
      }
      var active = stored;
      final purchases = await _queryOutstandingWithDiagnostics();
      _logOutstanding(purchases);
      for (final product in active.products) {
        final alreadyVerified = active.verifiedStoreProductIds.contains(
          product.storeProductId,
        );
        playBillingLog(
          'recovery product=${product.storeProductId} '
          'contextState=${active.state} alreadyVerified=$alreadyVerified',
        );
        final matches = purchases.where(
          (purchase) =>
              purchase.products.contains(product.storeProductId) &&
              (purchase.obfuscatedAccountId == null ||
                  purchase.obfuscatedAccountId == active.linkToken),
        );
        if (matches.isEmpty) {
          if (active.verifiedStoreProductIds.contains(product.storeProductId)) {
            active = active.copyWith(
              currentIndex: active.products.indexOf(product) + 1,
              state: 'partially_paid',
            );
            await _contextStore.save(active);
          }
          continue;
        }
        final purchase = matches.first;
        if (purchase.isPending) {
          _tempDebug(
            'RECOVERY_PENDING',
            product: product.storeProductId,
            orderId: active.orderId,
          );
          active = active.copyWith(state: 'pending');
          await _contextStore.save(active);
          if (matchesCurrentCart) _purchaseContext = active;
          _setStatus(
            'Payment is pending. Your mantra credits will be available after '
            'Google Play confirms the payment.',
          );
          return false;
        }
        if (purchase.isPurchased && purchase.purchaseToken.isNotEmpty) {
          _tempDebug(
            'RECOVERY_PURCHASED',
            product: product.storeProductId,
            orderId: active.orderId,
          );
          PurchaseVerification? verification;
          if (!alreadyVerified) {
            playBillingLog(
              'recovery retryVerification product=${product.storeProductId}',
            );
            verification = await _verifyPurchase(active, product, purchase);
            active = active.copyWith(
              verifiedStoreProductIds: {
                ...active.verifiedStoreProductIds,
                product.storeProductId,
              },
              currentIndex: active.products.indexOf(product),
              state: 'verified_pending_consumption',
            );
            await _contextStore.save(active);
          }

          if (alreadyVerified) {
            _tempDebug(
              'RECOVERY_VERIFY_ALREADY_RECORDED',
              product: product.storeProductId,
              orderId: active.orderId,
              detail: 'value=true',
            );
          }

          playBillingLog(
            'recovery retryConsumption product=${product.storeProductId} '
            'alreadyVerified=${active.verifiedStoreProductIds.contains(product.storeProductId)}',
          );
          _tempDebug(
            'RECOVERY_CONSUME_RETRY',
            product: product.storeProductId,
            orderId: active.orderId,
            contextState: active.state,
            currentIndex: active.currentIndex,
          );
          final consumed = await _consumeWithDiagnostics(
            context: active,
            productId: product.storeProductId,
            purchaseToken: purchase.purchaseToken,
          );
          playBillingLog(
            'recovery retryConsumptionResult product=${product.storeProductId} '
            'responseCode=${consumed.responseCode} completed=${consumed.completed}',
          );
          _tempDebug(
            'RECOVERY_CONSUME_RESULT',
            product: product.storeProductId,
            billingResponseCode: consumed.responseCode,
            consumedCompleted: consumed.completed,
            alreadyConsumed: consumed.alreadyConsumed,
          );
          if (!consumed.completed) {
            if (matchesCurrentCart) _purchaseContext = active;
            return false;
          }
          active = active.copyWith(
            currentIndex: active.products.indexOf(product) + 1,
            state: verification?.paid == true ? 'paid' : 'partially_paid',
          );
          await _contextStore.save(active);
          if (verification?.paid == true) {
            await _completePaidOrder(
              active,
              removeMatchingCartItems: matchesCurrentCart,
              closeCheckout: matchesCurrentCart,
            );
            return true;
          }
        }
      }
      final refreshedOrder = await PaymentService.getAndroidPurchaseOrder(
        active.orderId,
        onDiagnostic: _handlePaymentDiagnostic,
      );
      if (refreshedOrder.paid) {
        _tempDebug('ORDER_PAID', orderId: active.orderId);
        final consumptionComplete = await _finishPaidOrderConsumption(active);
        if (!consumptionComplete) return false;
        await _completePaidOrder(
          active,
          removeMatchingCartItems: matchesCurrentCart,
          closeCheckout: matchesCurrentCart,
        );
        return true;
      }
      if (refreshedOrder.terminal) {
        _tempDebug(
          'RECOVERY_TERMINAL',
          orderId: active.orderId,
          backendStatus: refreshedOrder.status,
        );
        await _contextStore.clear();
        if (matchesCurrentCart) _purchaseContext = null;
        return true;
      }
      active = active.copyWith(
        state: active.state == 'pending' ? 'prepared' : active.state,
      );
      await _contextStore.save(active);
      if (matchesCurrentCart) {
        _purchaseContext = active;
        _setStatus('An unfinished order was found. Tap continue to resume.');
      }
      playBillingLog(
        'reconciliation end order=${active.orderId} resolved=false',
      );
      return false;
    } catch (error) {
      playBillingLog(
        'reconciliation exception order=${stored.orderId} '
        'state=${stored.state} type=${error.runtimeType}',
      );
      if (matchesCurrentCart) {
        _setStatus('Your unfinished order is saved and will be checked again.');
      }
      return false;
    }
  }

  void _logOutstanding(List<PlayPurchase> purchases) {
    playBillingLog(
      'outstanding purchases=${purchases.map((purchase) => {'products': purchase.products, 'state': purchase.purchaseState}).toList()}',
    );
  }

  Future<List<PlayPurchase>> _queryOutstandingWithDiagnostics() async {
    _tempDebug('OUTSTANDING_QUERY');
    final purchases = await PlayBillingService.queryOutstandingPurchases();
    _tempDebug(
      'OUTSTANDING_RESULT',
      detail:
          'purchases=${purchases.map((purchase) => {'products': purchase.products, 'state': _purchaseStateName(purchase.purchaseState), 'ack': purchase.isAcknowledged}).toList()}',
    );
    return purchases;
  }

  Future<bool> _finishPaidOrderConsumption(
    AndroidPurchaseContext context,
  ) async {
    final purchases = await _queryOutstandingWithDiagnostics();
    _logOutstanding(purchases);
    for (final purchase in purchases) {
      final belongsToOrder = purchase.products.any(
        context.storeProductIds.contains,
      );
      final accountMatches =
          purchase.obfuscatedAccountId == null ||
          purchase.obfuscatedAccountId == context.linkToken;
      if (!belongsToOrder || !accountMatches) continue;
      if (!purchase.isPurchased || purchase.purchaseToken.isEmpty) return false;
      final productId = purchase.products.firstWhere(
        context.storeProductIds.contains,
      );
      playBillingLog(
        'recovery paidOrder retryConsumption product=$productId '
        'alreadyVerified=${context.verifiedStoreProductIds.contains(productId)}',
      );
      final consumed = await _consumeWithDiagnostics(
        context: context,
        productId: productId,
        purchaseToken: purchase.purchaseToken,
      );
      playBillingLog(
        'recovery paidOrder consumptionResult product=$productId '
        'responseCode=${consumed.responseCode} completed=${consumed.completed}',
      );
      if (!consumed.completed) return false;
    }
    return true;
  }

  Future<PlayConsumeResult> _consumeWithDiagnostics({
    required AndroidPurchaseContext context,
    required String productId,
    required String purchaseToken,
  }) async {
    playBillingLog(
      'consume start product=$productId state=${context.state} '
      'currentIndex=${context.currentIndex}',
    );
    _tempDebug(
      'CONSUME_START',
      product: productId,
      orderId: context.orderId,
      contextState: context.state,
      currentIndex: context.currentIndex,
    );
    _tempDebug('CONSUME_CHANNEL_CALL', product: productId);
    try {
      final consumed = await PlayBillingService.consumePurchase(
        purchaseToken,
        storeProductId: productId,
      );
      playBillingLog(
        'consume finish product=$productId responseCode=${consumed.responseCode} '
        'completed=${consumed.completed} '
        'alreadyConsumed=${consumed.alreadyConsumed}',
      );
      _tempDebug(
        'CONSUME_RESULT',
        product: productId,
        billingResponseCode: consumed.responseCode,
        consumedCompleted: consumed.completed,
        alreadyConsumed: consumed.alreadyConsumed,
        detail: consumed.safeDebugMessage == null
            ? null
            : 'message=${consumed.safeDebugMessage}',
      );
      return consumed;
    } on PlatformException catch (error) {
      playBillingLog(
        'consume platformException product=$productId code=${error.code} '
        'message=${sanitizePlayBillingDiagnostic(error.message)}',
      );
      _tempDebug(
        'CONSUME_PLATFORM_ERROR',
        product: productId,
        error: error,
        detail: 'code=${error.code}',
      );
      rethrow;
    }
  }

  Future<void> _saveContext(AndroidPurchaseContext context) async {
    _purchaseContext = context;
    await _contextStore.save(context);
    _tempDebug(
      'CONTEXT_SAVED',
      orderId: context.orderId,
      contextState: context.state,
      currentIndex: context.currentIndex,
      detail: 'verified=${context.verifiedStoreProductIds.toList()}',
    );
  }

  Future<void> _completePaidOrder(
    AndroidPurchaseContext paidContext, {
    required bool removeMatchingCartItems,
    bool closeCheckout = true,
  }) async {
    _tempDebug('ORDER_PAID', orderId: paidContext.orderId);
    _tempDebug('ENTITLEMENT_REFRESH', orderId: paidContext.orderId);
    await MantraService.refreshPurchasedCountsOnly();
    if (removeMatchingCartItems) {
      _tempDebug(
        'CART_REMOVE_MATCHING',
        orderId: paidContext.orderId,
        detail: 'products=${paidContext.storeProductIds.toList()}',
      );
      await MantraService.removeCartProductsByStoreIds(
        paidContext.storeProductIds,
      );
    }
    await _contextStore.clear();
    if (removeMatchingCartItems) _purchaseContext = null;
    PlayBillingService.debug('purchased credits refreshed');
    PlayBillingService.debug('checkout completed');
    _tempDebug('CHECKOUT_COMPLETE', orderId: paidContext.orderId);
    if (!mounted || !closeCheckout) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Purchase successful.')));
    Navigator.of(context).pop(true);
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _setError(String value) {
    if (mounted) setState(() => _error = value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Google Play checkout')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                for (final item in _cartProducts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(item.productName),
                    subtitle: Text(
                      item.quantity > 1
                          ? '${_prices[item.storeProductId]?.formattedPrice ?? 'Price unavailable'} × ${item.quantity}'
                          : item.storeProductId,
                    ),
                    trailing: Text(_lineTotal(item)),
                  ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Total'),
                  trailing: Text(_total),
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_status),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                if (!_allLoaded && _error == null)
                  const Text(
                    'One or more Google Play products are unavailable or use '
                    'a different currency.',
                  ),
                if (_showTemporaryDebugPanel) ...[
                  const SizedBox(height: 16),
                  _buildTemporaryDebugPanel(),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed:
                      _allLoaded &&
                          !_processing &&
                          !_recovering &&
                          !_blockedByPriorOrder
                      ? _startOrContinueCheckout
                      : null,
                  child: _processing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _purchaseContext == null
                              ? 'Pay with Google Play'
                              : 'Continue Google Play purchase',
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildTemporaryDebugPanel() {
    String value(Object? value) => value?.toString() ?? '-';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        border: Border.all(color: const Color(0xFFB26A00), width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.black,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TEMP PLAY BILLING DEBUG',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 6),
            SelectableText(
              'Stage: $_debugStage\n'
              'Product: ${value(_debugProduct)}\n'
              'Order: ${value(_debugOrderId)}\n'
              'Context: ${value(_debugContextState)}\n'
              'Index: ${value(_debugCurrentIndex)}\n'
              'HTTP: ${value(_debugHttpStatus)}\n'
              'Backend status: ${value(_debugBackendStatus)}\n'
              'Accepted: ${value(_debugAccepted)}\n'
              'Paid: ${value(_debugPaid)}\n'
              'Billing response: ${value(_debugBillingResponseCode)}\n'
              'Consume complete: ${value(_debugConsumedCompleted)}\n'
              'Already consumed: ${value(_debugAlreadyConsumed)}\n'
              'Error type: ${value(_debugErrorType)}\n'
              'Error: ${value(_debugErrorMessage)}',
            ),
            const SizedBox(height: 8),
            const Text(
              'History:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 3),
            SelectableText(_debugEvents.join('\n')),
          ],
        ),
      ),
    );
  }

  String _lineTotal(AndroidCartProduct item) {
    final price = _prices[item.storeProductId];
    if (price == null) return 'Price unavailable';
    return NumberFormat.currency(
      name: price.currencyCode,
    ).format(price.priceAmountMicros * item.quantity / 1000000);
  }
}

final class _PlayStepResult {
  const _PlayStepResult._({this.purchase, required this.pending});
  const _PlayStepResult.pending() : this._(pending: true);
  const _PlayStepResult.purchased(PlayPurchase purchase)
    : this._(purchase: purchase, pending: false);

  final PlayPurchase? purchase;
  final bool pending;
}

final class _CheckoutCancelled implements Exception {
  const _CheckoutCancelled();
}

final class _CheckoutPending implements Exception {
  const _CheckoutPending();
}

final class _CheckoutSafetyError implements Exception {
  const _CheckoutSafetyError();
}

final class _ConsumptionPending implements Exception {
  const _ConsumptionPending();
}

final class _PriorOrderUnresolved implements Exception {
  const _PriorOrderUnresolved();
}
