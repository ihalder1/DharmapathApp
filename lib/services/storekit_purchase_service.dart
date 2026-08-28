import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

import 'storekit_diagnostics.dart';

final class StoreKitProductPrice {
  const StoreKitProductPrice({
    required this.productId,
    required this.formattedPrice,
    required this.rawPrice,
    required this.currencyCode,
    required this.details,
  });

  final String productId;
  final String formattedPrice;
  final double rawPrice;
  final String currencyCode;
  final ProductDetails details;
}

String iosCataloguePrice({
  required String? storeProductId,
  required Map<String, StoreKitProductPrice> prices,
}) {
  final id = storeProductId?.trim() ?? '';
  if (id.isEmpty) return 'Price unavailable';
  return prices[id]?.formattedPrice ?? 'Price unavailable';
}

final class StoreKitTransaction {
  const StoreKitTransaction({
    required this.productId,
    required this.status,
    this.transactionId,
    this.appAccountToken,
    this.purchaseDetails,
    this.runtimeTypeName,
    this.transactionDate,
    this.pendingCompletePurchase = false,
    this.verificationSource,
    this.serverVerificationDataPresent = false,
    this.localVerificationDataPresent = false,
    this.errorCode,
    this.errorMessage,
    this.errorDetails,
  });

  final String productId;
  final PurchaseStatus status;
  final String? transactionId;
  final String? appAccountToken;
  final PurchaseDetails? purchaseDetails;
  final String? runtimeTypeName;
  final String? transactionDate;
  final bool pendingCompletePurchase;
  final String? verificationSource;
  final bool serverVerificationDataPresent;
  final bool localVerificationDataPresent;
  final String? errorCode;
  final String? errorMessage;
  final Object? errorDetails;

  bool get purchased =>
      status == PurchaseStatus.purchased || status == PurchaseStatus.restored;
}

/// iOS-only StoreKit boundary. It deliberately has no Android billing imports.
final class StoreKitPurchaseService {
  StoreKitPurchaseService._() {
    _subscription = _iap.purchaseStream.listen(
      _handleUpdates,
      onError: _updates.addError,
    );
  }

  static final StoreKitPurchaseService instance = StoreKitPurchaseService._();
  final InAppPurchase _iap = InAppPurchase.instance;
  final StreamController<List<StoreKitTransaction>> _updates =
      StreamController<List<StoreKitTransaction>>.broadcast();
  // Retained for the lifetime of the singleton so StoreKit updates are
  // installed centrally as soon as this service is first used.
  // ignore: unused_field
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  Stream<List<StoreKitTransaction>> get purchaseUpdates => _updates.stream;

  Future<bool> isAvailable() => _iap.isAvailable();

  Future<Map<String, StoreKitProductPrice>> queryProducts(
    Iterable<String> productIds, {
    StoreKitDiagnostics? diagnostics,
  }) async {
    final ids = productIds
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      diagnostics?.log('STOREKIT_PRODUCT_QUERY_SKIPPED', {
        'reason': 'no_product_ids',
      });
      return const {};
    }
    final stopwatch = Stopwatch()..start();
    diagnostics?.log('STOREKIT_PRODUCT_QUERY_START', {
      'requestedProductIds': ids.toList(),
    });
    final response = await _iap.queryProductDetails(ids);
    diagnostics?.log('STOREKIT_QUERY_RESULT', {
      'platform': 'ios',
      'requestedProductIds': ids.toList(),
      'durationMs': stopwatch.elapsedMilliseconds,
      'returnedCount': response.productDetails.length,
      'foundProductIds': response.productDetails
          .map((item) => item.id)
          .toList(),
      'notFoundIDs': response.notFoundIDs,
      'hasError': response.error != null,
      'errorCode': response.error?.code,
      'errorMessage': response.error?.message,
      'products': response.productDetails
          .map(
            (item) => {
              'id': item.id,
              'title': item.title,
              'description': item.description,
              'price': item.price,
              'rawPrice': item.rawPrice,
              'currencyCode': item.currencyCode,
              'currencySymbol': item.currencySymbol,
            },
          )
          .toList(),
    });
    if (response.error != null) {
      throw StateError('storekit_product_query_failed');
    }
    return {
      for (final item in response.productDetails)
        item.id: StoreKitProductPrice(
          productId: item.id,
          formattedPrice: item.price,
          rawPrice: item.rawPrice,
          currencyCode: item.currencyCode,
          details: item,
        ),
    };
  }

  Future<bool> buyConsumable({
    required ProductDetails product,
    required String appAccountToken,
  }) => _iap.buyConsumable(
    purchaseParam: PurchaseParam(
      productDetails: product,
      applicationUserName: appAccountToken,
    ),
  );

  Future<void> complete(StoreKitTransaction transaction) async {
    final details = transaction.purchaseDetails;
    if (details != null) {
      if (details.pendingCompletePurchase) await _iap.completePurchase(details);
      return;
    }
    final id = int.tryParse(transaction.transactionId ?? '');
    if (id == null) throw StateError('storekit_transaction_id_invalid');
    await SK2Transaction.finish(id);
  }

  Future<List<StoreKitTransaction>> unfinishedTransactions() async {
    final transactions = await SK2Transaction.unfinishedTransactions();
    return transactions
        .map(
          (item) => StoreKitTransaction(
            productId: item.productId,
            transactionId: item.id,
            appAccountToken: item.appAccountToken,
            status: PurchaseStatus.purchased,
          ),
        )
        .toList(growable: false);
  }

  void _handleUpdates(List<PurchaseDetails> details) {
    final normalized = details
        .map(
          (item) => StoreKitTransaction(
            productId: item.productID,
            transactionId: item.purchaseID,
            appAccountToken: item is SK2PurchaseDetails
                ? item.appAccountToken
                : null,
            status: item.status,
            purchaseDetails: item,
            runtimeTypeName: item.runtimeType.toString(),
            transactionDate: item.transactionDate,
            pendingCompletePurchase: item.pendingCompletePurchase,
            verificationSource: item.verificationData.source,
            serverVerificationDataPresent:
                item.verificationData.serverVerificationData.isNotEmpty,
            localVerificationDataPresent:
                item.verificationData.localVerificationData.isNotEmpty,
            errorCode: item.error?.code,
            errorMessage: item.error?.message,
            errorDetails: item.error?.details,
          ),
        )
        .toList(growable: false);
    _updates.add(normalized);
  }
}
