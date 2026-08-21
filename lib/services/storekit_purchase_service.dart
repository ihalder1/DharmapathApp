import 'dart:async';

import 'package:flutter/foundation.dart';
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
  });

  final String productId;
  final PurchaseStatus status;
  final String? transactionId;
  final String? appAccountToken;
  final PurchaseDetails? purchaseDetails;

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
      return const {};
    }
    final response = await _iap.queryProductDetails(ids);
    diagnostics?.log('STOREKIT_QUERY_RESULT', {
      'platform': 'ios',
      'queriedProductIds': ids.toList(),
      'foundProductIds': response.productDetails
          .map((item) => item.id)
          .toList(),
      'notFoundIDs': response.notFoundIDs,
      'hasError': response.error != null,
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
          ),
        )
        .toList(growable: false);
    if (kDebugMode) {
      for (final item in normalized) {
        debugPrint(
          'STOREKIT_DEBUG update product=${item.productId} '
          'status=${item.status.name} hasTransaction=${item.transactionId?.isNotEmpty == true}',
        );
      }
    }
    _updates.add(normalized);
  }
}
